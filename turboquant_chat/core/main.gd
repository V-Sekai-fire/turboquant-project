extends Control

@export var model_url: String = "https://huggingface.co/mradermacher/Qwen3.5-0.8B-heretic-ara-v2-GGUF/resolve/main/Qwen3.5-0.8B-heretic-ara-v2.Q4_K_S.gguf"
@export_file("*.gguf") var model_path: String = ""

@onready var status_label: Label = $VBox/StatusLabel
@onready var output_label: RichTextLabel = $VBox/OutputLabel
@onready var url_hbox: HBoxContainer = $VBox/URLHBox
@onready var url_input: LineEdit = $VBox/URLHBox/URLInput
@onready var url_apply_button: Button = $VBox/URLHBox/URLApplyButton
@onready var prompt_input: LineEdit = $VBox/HBox/PromptInput
@onready var send_button: Button = $VBox/HBox/SendButton
@onready var delete_button: Button = $VBox/HBox/DeleteButton
@onready var clear_button: Button = $VBox/HBox/ClearButton
@onready var loading_screen: CanvasLayer = $LoadingScreen
@onready var loading_label: Label = $LoadingScreen/Bg/OuterVBox/CenterWrapper/VBox/LoadingLabel
@onready var loading_url_input: LineEdit = $LoadingScreen/Bg/OuterVBox/BottomMargin/BottomBar/LoadingURLInput
@onready var loading_url_apply_button: Button = $LoadingScreen/Bg/OuterVBox/BottomMargin/BottomBar/LoadingURLApplyButton
@onready var loading_delete_button: Button = $LoadingScreen/Bg/OuterVBox/BottomMargin/BottomBar/LoadingDeleteButton

# Adaptive chunk bounds — proved in DownloadChunk.lean.
# chunkForThroughput(bps) = clamp(bps / 10, MIN_CHUNK, MAX_CHUNK)
const MIN_CHUNK: int = 256 * 1024       # 256 KB: starting point for slow-start probing
const MAX_CHUNK: int = 8 * 1024 * 1024  # 8 MB: saturation ceiling

var model: LLMModel
var ctx: LLMContext
var chat: LLMChat
var _http: HTTPRequest
var _http_head: HTTPRequest       # HEAD request to read Content-Length as string (int64-safe)
var _progress_timer: float = 0.0
var _messages: Array[Dictionary] = []
var _download_start_time: float = 0.0
var _total_bytes: int = 0         # parsed from Content-Length header (correct int64)
var _download_total_bytes: int = 0
var _tracked_downloaded: int = 0  # accumulated from per-tick deltas; immune to int32 wrap
var _last_raw_downloaded: int = 0
var _last_tick_time: float = 0.0

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		model_url = cfg.get_value("model", "url", model_url)

	send_button.disabled = true
	send_button.pressed.connect(_on_send_pressed)
	prompt_input.text_submitted.connect(func(_t): _on_send_pressed())
	delete_button.pressed.connect(_on_delete_pressed)
	loading_delete_button.pressed.connect(_on_delete_pressed)
	clear_button.pressed.connect(_on_clear_pressed)

	url_input.text = model_url
	loading_url_input.text = model_url
	var _apply_url := func(new_url: String) -> void:
		model_url = new_url
		url_input.text = new_url
		loading_url_input.text = new_url
		var c := ConfigFile.new()
		c.set_value("model", "url", model_url)
		c.save("user://settings.cfg")
		_cancel_download()
		_ensure_model()
	url_input.text_submitted.connect(_apply_url)
	url_apply_button.pressed.connect(func(): _apply_url.call(url_input.text))
	loading_url_input.text_submitted.connect(_apply_url)
	loading_url_apply_button.pressed.connect(func(): _apply_url.call(loading_url_input.text))

	_set_status("Checking for model file...")
	_ensure_model()

# chunkForThroughput: one chunk targets 100 ms of data at the current rate.
# Proved in DownloadChunk.lean: always in [MIN_CHUNK, MAX_CHUNK], monotone.
func _chunk_for_throughput(throughput_bps: int) -> int:
	if throughput_bps <= 0:
		return MIN_CHUNK
	@warning_ignore("INTEGER_DIVISION")
	return clampi(throughput_bps / 10, MIN_CHUNK, MAX_CHUNK)

func _cancel_download() -> void:
	if _http_head != null:
		_http_head.cancel_request()
		_http_head.queue_free()
		_http_head = null
	if _http != null:
		_http.cancel_request()
		_http.queue_free()
		_http = null

func _model_filename() -> String:
	return model_url.get_file()

func _ensure_model() -> void:
	if OS.get_name() == "Web":
		_start_download()
		return
	var filename := _model_filename()
	if FileAccess.file_exists("user://" + filename):
		model_path = "user://" + filename
		_set_status("Initialising LLM...")
		_init_llm()
		return
	_start_download()

func _start_download() -> void:
	# Phase 1: HEAD request to read Content-Length as a string and parse it as
	# int64. get_body_size() stores the value as int32 internally, which wraps
	# at ~2 GB and gives a wrong total for large models.
	_total_bytes = 0
	_set_status("Checking file size...")
	_http_head = HTTPRequest.new()
	add_child(_http_head)
	_http_head.request_completed.connect(_on_head_complete)
	var err := _http_head.request(model_url, [], HTTPClient.METHOD_HEAD)
	if err != OK:
		_http_head.queue_free()
		_http_head = null
		_start_get()

func _on_head_complete(_result: int, _code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_head.queue_free()
	_http_head = null
	for h in headers:
		if h.to_lower().begins_with("content-length:"):
			_total_bytes = int(h.substr(h.find(":") + 1).strip_edges())
			break
	_start_get()

func _start_get() -> void:
	_set_status("Downloading model — please wait...")
	_http = HTTPRequest.new()
	_http.use_threads = true
	# Godot doesn't allow changing download_chunk_size mid-request.
	_http.download_chunk_size = MAX_CHUNK

	_download_start_time = Time.get_ticks_msec() / 1000.0
	_download_total_bytes = _total_bytes
	_tracked_downloaded = 0
	_last_raw_downloaded = 0
	_last_tick_time = _download_start_time

	# On web, receive body as PackedByteArray (WASM linear memory, pthread-accessible).
	# download_file uses IDBFS which pthreads cannot access (emscripten#8624).
	if OS.get_name() != "Web":
		_http.download_file = "user://" + _model_filename()
	add_child(_http)
	_http.request_completed.connect(_on_download_complete)
	var err := _http.request(model_url)
	if err != OK:
		_set_status("Download request failed: %d" % err)

func _process(_delta: float) -> void:
	if _http == null:
		return
	_progress_timer += _delta
	if _progress_timer < 0.05:
		return
	_progress_timer = 0.0

	var now := Time.get_ticks_msec() / 1000.0

	# Accumulate downloaded bytes via per-tick deltas to survive int32 wrapping.
	# get_downloaded_bytes() may wrap at 2 GB if Godot's counter is int32.
	# By tracking only the delta each tick we never depend on the absolute value.
	var raw := _http.get_downloaded_bytes()
	var delta: int
	if raw >= _last_raw_downloaded:
		delta = raw - _last_raw_downloaded
	else:
		# Counter wrapped — add the distance from last position to the wrap boundary,
		# then add whatever raw shows in the new cycle.
		delta = maxi(0, raw) + maxi(0, 0x7FFFFFFF - _last_raw_downloaded)
	_tracked_downloaded += maxi(0, delta)
	_last_raw_downloaded = raw

	var dt := now - _last_tick_time
	var window_bps := 0
	if dt > 0.001 and delta > 0:
		window_bps = int(delta / dt)

	var dl_mb    := _tracked_downloaded >> 20
	var total_mb := _total_bytes >> 20
	var speed_mb := maxi(0, window_bps) >> 20
	if _total_bytes > 0:
		var pct := clampi(int(100.0 * _tracked_downloaded / _total_bytes), 0, 100)
		_set_status("Downloading model... %d%% (%d / %d MB) @ %d MB/s" % [
			pct, dl_mb, total_mb, speed_mb,
		])
	else:
		_set_status("Downloading model... %d MB received @ %d MB/s" % [dl_mb, speed_mb])

	_last_tick_time = now

func _on_delete_pressed() -> void:
	_cancel_download()
	var path := "user://" + _model_filename()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_set_status("Model deleted.")
	else:
		_set_status("No downloaded model to delete.")
	url_hbox.show()
	loading_screen.hide()

func _on_clear_pressed() -> void:
	if chat != null:
		if chat.is_busy():
			# Erlang-style: send exit signal and wait for the worker to reach the
			# next token boundary and clear busy itself. cancel() is fire-and-forget;
			# reset() becomes safe as soon as busy drops.
			chat.cancel()
			while chat.is_busy():
				await get_tree().process_frame
		chat.reset()
	_messages.clear()
	output_label.clear()
	send_button.disabled = false
	prompt_input.editable = true
	_set_status("Conversation cleared.")

func _on_download_complete(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# Measure and persist final throughput before releasing _http.
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var elapsed := Time.get_ticks_msec() / 1000.0 - _download_start_time
		if elapsed > 0.5 and _download_total_bytes > 0:
			var throughput := int(_download_total_bytes / elapsed)
			var cfg := ConfigFile.new()
			cfg.load("user://settings.cfg")
			cfg.set_value("download", "throughput_bps", throughput)
			cfg.save("user://settings.cfg")
	_http = null
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Download failed (result=%d, http=%d)" % [result, response_code])
		return
	_set_status("Download complete. Initialising LLM...")
	if OS.get_name() == "Web":
		_init_llm_from_buffer(body)
	else:
		model_path = "user://" + _model_filename()
		_init_llm()

func _init_llm_from_buffer(data: PackedByteArray) -> void:
	model = LLMModel.new()
	model.n_gpu_layers = -1
	model.loaded.connect(_on_model_loaded)
	model.load_failed.connect(_on_model_failed)
	var err := model.load_from_buffer(data)
	if err != OK:
		_set_status("model.load_from_buffer() returned error %d" % err)

func _init_llm() -> void:
	model = LLMModel.new()
	model.model_path = model_path
	model.n_gpu_layers = -1
	model.loaded.connect(_on_model_loaded)
	model.load_failed.connect(_on_model_failed)

	var err := model.load()
	if err != OK:
		_set_status("model.load() returned error %d" % err)

func _on_model_loaded() -> void:
	_set_status("Model loaded. Creating context (TurboQuant KV cache)...")

	ctx = LLMContext.new()
	ctx.n_ctx = 4096
	ctx.cache_type_k = "q8_0"
	ctx.cache_type_v = "turbo4"
	ctx.flash_attn = true
	ctx.created.connect(_on_context_created)
	ctx.create_failed.connect(_on_context_failed)

	var err := ctx.create(model)
	if err != OK:
		_set_status("ctx.create() failed: %d" % err)

func _on_context_created() -> void:
	chat = LLMChat.new()
	chat.setup(model, ctx)
	chat.max_tokens = 0  # 0 = no limit; generates until EOS or context full
	chat.enable_thinking = false
	chat.temperature = 0.7
	chat.token_generated.connect(_on_token)
	chat.response_received.connect(_on_response)
	chat.inference_failed.connect(_on_inference_failed)

	_set_status("Ready. Enter a prompt and press Send.")
	send_button.disabled = false
	url_hbox.hide()
	loading_screen.hide()

func _on_context_failed(error: String) -> void:
	_set_status("Context creation failed: " + error)
	loading_screen.hide()
	url_hbox.show()

func _on_model_failed(error: String) -> void:
	_set_status("Model load failed: " + error)
	loading_screen.hide()
	url_hbox.show()

func _on_send_pressed() -> void:
	var prompt := prompt_input.text.strip_edges()
	if prompt.is_empty() or chat.is_busy():
		return
	send_button.disabled = true
	prompt_input.editable = false
	prompt_input.text = ""
	_set_status("Generating...")
	_messages.append({"role": "user", "content": prompt})
	output_label.append_text("\n[User] " + prompt + "\n[Assistant] ")
	chat.complete(_messages)

func _on_token(token: String) -> void:
	output_label.append_text(token)

func _on_response(text: String) -> void:
	_messages.append({"role": "assistant", "content": text})
	output_label.append_text("\n")
	_set_status("Done.")
	send_button.disabled = false
	prompt_input.editable = true

func _on_inference_failed(error: String) -> void:
	# Roll back the user message that didn't get a response.
	_messages.pop_back()
	_set_status("Inference failed: " + error)
	send_button.disabled = false
	prompt_input.editable = true

func _set_status(msg: String) -> void:
	status_label.text = msg
	loading_label.text = msg
	print(msg)
