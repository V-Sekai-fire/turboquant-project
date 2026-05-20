extends Control

# ── Download constants ────────────────────────────────────────────────────────
const MIN_CHUNK: int = 256 * 1024
const MAX_CHUNK: int = 8 * 1024 * 1024

# ── File drop ─────────────────────────────────────────────────────────────────
const _TEXT_EXTS: PackedStringArray = [
	"txt", "md", "gd", "py", "json", "yaml", "yml", "toml", "cfg", "ini",
	"csv", "log", "sh", "lua", "js", "ts", "html", "css", "xml",
	"rs", "go", "java", "c", "cpp", "h", "hpp",
]

# ── UI refs ───────────────────────────────────────────────────────────────────
@onready var status_label: Label = $VBox/StatusLabel
@onready var output_label: RichTextLabel = $VBox/OutputLabel
@onready var prompt_input: TextEdit = $VBox/HBox/PromptInput
@onready var send_button: Button = $VBox/HBox/SendButton
@onready var switch_model_button: Button = $VBox/HBox/SwitchModelButton
@onready var clear_button: Button = $VBox/HBox/ClearButton
@onready var loading_screen: CanvasLayer = $LoadingScreen
@onready var loading_label: Label = $LoadingScreen/Bg/OuterVBox/CenterWrapper/VBox/LoadingLabel
@onready var add_url_input: LineEdit = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/AddBar/AddURLInput
@onready var add_url_button: Button = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/AddBar/AddURLButton
@onready var browse_button: Button = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/AddBar/BrowseButton
@onready var back_bar: HBoxContainer = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/BackBar
@onready var current_model_label: Label = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/BackBar/CurrentModelLabel
@onready var back_button: Button = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/BackBar/BackButton
@onready var model_list_vbox: VBoxContainer = $LoadingScreen/Bg/OuterVBox/BottomPanel/VBox/ModelListScroll/ModelListVBox
@onready var file_dialog: FileDialog = $FileDialog

# ── LLM objects ───────────────────────────────────────────────────────────────
var model: LLMModel
var ctx: LLMContext
var chat: LLMChat

# ── Download state ────────────────────────────────────────────────────────────
var _http: HTTPRequest
var _http_head: HTTPRequest
var _progress_timer: float = 0.0
var _download_start_time: float = 0.0
var _total_bytes: int = 0
var _download_total_bytes: int = 0
var _tracked_downloaded: int = 0
var _last_raw_downloaded: int = 0
var _last_tick_time: float = 0.0
var _last_logged_pct: int = -1

# ── App state ─────────────────────────────────────────────────────────────────
var _messages: Array[Dictionary] = []
var _model_urls: Array[String] = []  # remote URLs and local file paths
var _active_url: String = ""         # URL/path currently being downloaded or loaded
var _loaded_url: String = ""         # URL/path of the model currently in memory


func _ready() -> void:
	_load_model_list()
	send_button.disabled = true
	switch_model_button.disabled = true
	send_button.pressed.connect(_on_send_pressed)
	prompt_input.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and not e.shift_pressed and e.keycode == KEY_ENTER:
			_on_send_pressed()
			get_viewport().set_input_as_handled())
	switch_model_button.pressed.connect(_on_switch_model_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	add_url_button.pressed.connect(func(): _on_add_url(add_url_input.text.strip_edges()))
	add_url_input.text_submitted.connect(func(t): _on_add_url(t.strip_edges()))
	browse_button.pressed.connect(_on_browse_pressed)
	back_button.pressed.connect(_hide_selector)
	file_dialog.file_selected.connect(_on_file_selected)
	get_viewport().files_dropped.connect(_on_files_dropped)

	var last := _load_last_url()
	if last in _model_urls and _is_available(last):
		loading_screen.show()
		_refresh_model_list()
		_set_selector_status("Loading last model...")
		_start_load(last)
	else:
		_show_selector("Select or add a model to begin.")


# ── Model list persistence ────────────────────────────────────────────────────

func _load_model_list() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		_model_urls.assign(cfg.get_value("models", "urls", PackedStringArray()) as PackedStringArray)

func _save_model_list() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("models", "urls", PackedStringArray(_model_urls))
	cfg.save("user://settings.cfg")

func _load_last_url() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		return cfg.get_value("models", "last_url", "")
	return ""

func _save_last_url(url: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("models", "last_url", url)
	cfg.save("user://settings.cfg")


# ── Model helpers ─────────────────────────────────────────────────────────────

func _is_remote(url: String) -> bool:
	return url.begins_with("http://") or url.begins_with("https://")

func _model_display_name(url: String) -> String:
	return url.get_file()

func _model_load_path(url: String) -> String:
	if _is_remote(url):
		return "user://" + url.get_file()
	return url

func _is_available(url: String) -> bool:
	return FileAccess.file_exists(_model_load_path(url))

# chunkForThroughput: one chunk ≈ 100 ms at measured rate.
# Proved in DownloadChunk.lean: always in [MIN_CHUNK, MAX_CHUNK], monotone.
func _chunk_for_throughput(throughput_bps: int) -> int:
	if throughput_bps <= 0:
		return MIN_CHUNK
	@warning_ignore("INTEGER_DIVISION")
	return clampi(throughput_bps / 10, MIN_CHUNK, MAX_CHUNK)


# ── Selector UI ───────────────────────────────────────────────────────────────

func _show_selector(status: String) -> void:
	loading_screen.show()
	back_bar.visible = _loaded_url != ""
	if _loaded_url != "":
		current_model_label.text = "Current: " + _model_display_name(_loaded_url)
	_set_selector_status(status)
	_refresh_model_list()
	add_url_input.grab_focus()

func _hide_selector() -> void:
	loading_screen.hide()

func _set_selector_status(msg: String) -> void:
	loading_label.text = msg
	print(msg)

func _set_selector_status_silent(msg: String) -> void:
	loading_label.text = msg

func _refresh_model_list() -> void:
	for child in model_list_vbox.get_children():
		child.queue_free()
	if _model_urls.is_empty():
		var hint := Label.new()
		hint.text = "No models added. Paste a .gguf URL above or click Load File."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		model_list_vbox.add_child(hint)
		return
	for url in _model_urls:
		_append_model_row(url)

func _append_model_row(url: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_lbl := Label.new()
	name_lbl.text = _model_display_name(url)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	name_lbl.tooltip_text = url
	row.add_child(name_lbl)

	var status_lbl := Label.new()
	if url == _active_url:
		status_lbl.text = "..."
	elif not _is_remote(url):
		status_lbl.text = "Local"
	elif _is_available(url):
		status_lbl.text = "Downloaded"
	else:
		status_lbl.text = "Not downloaded"
	row.add_child(status_lbl)

	var busy := _active_url != ""
	var captured := url

	if _is_available(url) and url != _active_url:
		var use_btn := Button.new()
		use_btn.text = "Use"
		use_btn.disabled = busy
		use_btn.pressed.connect(func(): _on_use_model(captured))
		row.add_child(use_btn)
	elif _is_remote(url) and not _is_available(url) and url != _active_url:
		var dl_btn := Button.new()
		dl_btn.text = "Download"
		dl_btn.disabled = busy
		dl_btn.pressed.connect(func(): _on_download_model(captured))
		row.add_child(dl_btn)

	var rm_btn := Button.new()
	rm_btn.text = "Remove"
	rm_btn.disabled = url == _active_url
	rm_btn.pressed.connect(func(): _on_remove_model(captured))
	row.add_child(rm_btn)

	model_list_vbox.add_child(row)


# ── Model actions ─────────────────────────────────────────────────────────────

func _on_add_url(url: String) -> void:
	if url.is_empty() or not url.ends_with(".gguf"):
		_set_selector_status("Enter a valid .gguf URL.")
		return
	if url in _model_urls:
		_set_selector_status("Already in list: " + _model_display_name(url))
		return
	_model_urls.append(url)
	_save_model_list()
	add_url_input.text = ""
	_refresh_model_list()

func _on_browse_pressed() -> void:
	file_dialog.popup_centered(Vector2(900, 600))

func _on_file_selected(path: String) -> void:
	if path in _model_urls:
		_set_selector_status("Already in list: " + _model_display_name(path))
		return
	_model_urls.append(path)
	_save_model_list()
	_refresh_model_list()
	_set_selector_status("Added: " + _model_display_name(path))

func _on_remove_model(url: String) -> void:
	if url == _active_url:
		_cancel_download()
		_active_url = ""
	_model_urls.erase(url)
	_save_model_list()
	if _is_remote(url):
		var path := "user://" + url.get_file()
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_refresh_model_list()

func _on_download_model(url: String) -> void:
	_active_url = url
	_refresh_model_list()
	_set_selector_status("Starting download...")
	_start_head_request(url)

func _on_use_model(url: String) -> void:
	_active_url = url
	_refresh_model_list()
	_set_selector_status("Initialising LLM...")
	_start_load(url)

func _on_switch_model_pressed() -> void:
	_show_selector("Select a model.")


# ── Download pipeline ─────────────────────────────────────────────────────────

func _cancel_download() -> void:
	if _http_head != null:
		_http_head.cancel_request()
		_http_head.queue_free()
		_http_head = null
	if _http != null:
		_http.cancel_request()
		_http.queue_free()
		_http = null

func _start_head_request(url: String) -> void:
	_total_bytes = 0
	_http_head = HTTPRequest.new()
	add_child(_http_head)
	_http_head.request_completed.connect(_on_head_complete)
	var err := _http_head.request(url, [], HTTPClient.METHOD_HEAD)
	if err != OK:
		_http_head.queue_free()
		_http_head = null
		_start_get(url)

func _on_head_complete(_result: int, _code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_head.queue_free()
	_http_head = null
	for h in headers:
		if h.to_lower().begins_with("content-length:"):
			_total_bytes = int(h.substr(h.find(":") + 1).strip_edges())
			break
	_start_get(_active_url)

func _start_get(url: String) -> void:
	_set_selector_status("Downloading — please wait...")
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.download_chunk_size = MAX_CHUNK
	_download_start_time = Time.get_ticks_msec() / 1000.0
	_download_total_bytes = _total_bytes
	_tracked_downloaded = 0
	_last_raw_downloaded = 0
	_last_tick_time = _download_start_time
	_last_logged_pct = -1
	_http.download_file = "user://" + url.get_file()
	add_child(_http)
	_http.request_completed.connect(_on_download_complete)
	var err := _http.request(url)
	if err != OK:
		_http.queue_free()
		_http = null
		_active_url = ""
		_refresh_model_list()
		_set_selector_status("Download request failed: %d" % err)

func _process(_delta: float) -> void:
	if _http == null:
		return
	_progress_timer += _delta
	if _progress_timer < 0.05:
		return
	_progress_timer = 0.0
	var now := Time.get_ticks_msec() / 1000.0
	var raw := _http.get_downloaded_bytes()
	var delta: int
	if raw >= _last_raw_downloaded:
		delta = raw - _last_raw_downloaded
	else:
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
		var msg := "Downloading %s... %d%% (%d / %d MB) @ %d MB/s" % [
			_model_display_name(_active_url), pct, dl_mb, total_mb, speed_mb]
		if pct != _last_logged_pct:
			_last_logged_pct = pct
			_set_selector_status(msg)
		else:
			_set_selector_status_silent(msg)
	else:
		_set_selector_status_silent("Downloading %s... %d MB @ %d MB/s" % [
			_model_display_name(_active_url), dl_mb, speed_mb])
	_last_tick_time = now

func _on_download_complete(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
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
		_active_url = ""
		_refresh_model_list()
		_set_selector_status("Download failed (result=%d, http=%d)" % [result, response_code])
		return
	var display_name := _model_display_name(_active_url)
	_active_url = ""
	_refresh_model_list()
	_set_selector_status("Downloaded %s. Click Use to load." % display_name)


# ── LLM init pipeline ─────────────────────────────────────────────────────────

func _start_load(url: String) -> void:
	_active_url = url
	_init_llm(_model_load_path(url))

func _init_llm(path: String) -> void:
	model = LLMModel.new()
	model.model_path = path
	model.n_gpu_layers = -1
	model.loaded.connect(_on_model_loaded)
	model.load_failed.connect(_on_model_failed)
	var err := model.load()
	if err != OK:
		_active_url = ""
		_show_selector("model.load() returned error %d" % err)

func _on_model_loaded() -> void:
	_set_selector_status("Model loaded. Creating context (TurboQuant KV cache)...")
	ctx = LLMContext.new()
	ctx.n_ctx = 262144
	ctx.cache_type_k = "q8_0"
	ctx.cache_type_v = "turbo4"
	ctx.flash_attn = true
	ctx.created.connect(_on_context_created)
	ctx.create_failed.connect(_on_context_failed)
	var err := ctx.create(model)
	if err != OK:
		_active_url = ""
		_show_selector("ctx.create() failed: %d" % err)

func _on_context_created() -> void:
	chat = LLMChat.new()
	chat.setup(model, ctx)
	chat.max_tokens = 262144
	chat.enable_thinking = true
	chat.temperature = 0.7
	chat.token_generated.connect(_on_token)
	chat.response_received.connect(_on_response)
	chat.inference_failed.connect(_on_inference_failed)
	_loaded_url = _active_url
	_active_url = ""
	_save_last_url(_loaded_url)
	_set_status("Ready. Model: " + _model_display_name(_loaded_url))
	send_button.disabled = false
	switch_model_button.disabled = false
	_hide_selector()

func _on_model_failed(error: String) -> void:
	_active_url = ""
	_show_selector("Model load failed: " + error)

func _on_context_failed(error: String) -> void:
	_active_url = ""
	_show_selector("Context creation failed: " + error)


# ── Chat ──────────────────────────────────────────────────────────────────────

func _on_send_pressed() -> void:
	var prompt := prompt_input.text.strip_edges()
	if prompt.is_empty() or chat == null or chat.is_busy():
		return
	send_button.disabled = true
	switch_model_button.disabled = true
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
	_set_status("Ready. Model: " + _model_display_name(_loaded_url))
	send_button.disabled = false
	switch_model_button.disabled = false
	prompt_input.editable = true

func _on_inference_failed(error: String) -> void:
	_messages.pop_back()
	_set_status("Inference failed: " + error)
	send_button.disabled = false
	switch_model_button.disabled = false
	prompt_input.editable = true

func _on_clear_pressed() -> void:
	if chat != null:
		if chat.is_busy():
			chat.cancel()
			while chat.is_busy():
				await get_tree().process_frame
		chat.reset()
	_messages.clear()
	output_label.clear()
	send_button.disabled = false
	switch_model_button.disabled = _loaded_url.is_empty()
	prompt_input.editable = true
	_set_status("Conversation cleared.")


# ── File drop ─────────────────────────────────────────────────────────────────

func _on_files_dropped(files: PackedStringArray) -> void:
	var parts: PackedStringArray = []
	for path in files:
		var ext := path.get_extension().to_lower()
		if ext == "gguf":
			_on_file_selected(path)
			return
		elif ext in _TEXT_EXTS:
			var f := FileAccess.open(path, FileAccess.READ)
			if f:
				parts.append("```%s\n%s\n```" % [ext, f.get_as_text()])
		else:
			parts.append("[Dropped: %s — binary/image files not yet supported]" % path.get_file())
	if parts.is_empty():
		return
	var joined := "\n\n".join(parts)
	var existing := prompt_input.text.strip_edges()
	prompt_input.text = (existing + "\n\n" + joined) if existing else joined
	prompt_input.grab_focus()


# ── Status ────────────────────────────────────────────────────────────────────

func _set_status(msg: String) -> void:
	status_label.text = msg
	print(msg)
