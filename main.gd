extends Control

@export var model_url: String = "https://huggingface.co/mradermacher/Qwen3.5-0.8B-heretic-ara-v2-GGUF/resolve/main/Qwen3.5-0.8B-heretic-ara-v2.Q4_K_S.gguf"
@export_file("*.gguf") var model_path: String = ""

@onready var status_label: Label = $VBox/StatusLabel
@onready var output_label: Label = $VBox/OutputLabel
@onready var url_hbox: HBoxContainer = $VBox/URLHBox
@onready var url_input: LineEdit = $VBox/URLHBox/URLInput
@onready var prompt_input: LineEdit = $VBox/HBox/PromptInput
@onready var send_button: Button = $VBox/HBox/SendButton
@onready var delete_button: Button = $VBox/HBox/DeleteButton
@onready var loading_screen: CanvasLayer = $LoadingScreen
@onready var loading_label: Label = $LoadingScreen/Bg/OuterVBox/CenterWrapper/VBox/LoadingLabel
@onready var loading_url_input: LineEdit = $LoadingScreen/Bg/OuterVBox/BottomMargin/BottomBar/LoadingURLInput
@onready var loading_delete_button: Button = $LoadingScreen/Bg/OuterVBox/BottomMargin/BottomBar/LoadingDeleteButton

var model: LLMModel
var ctx: LLMContext
var chat: LLMChat
var _http: HTTPRequest
var _progress_timer: float = 0.0

func _ready() -> void:
	_setup_font()
	send_button.disabled = true
	send_button.pressed.connect(_on_send_pressed)
	prompt_input.text_submitted.connect(func(_t): _on_send_pressed())
	delete_button.pressed.connect(_on_delete_pressed)
	loading_delete_button.pressed.connect(_on_delete_pressed)

	# Sync URL inputs with the exported model_url property
	url_input.text = model_url
	loading_url_input.text = model_url
	var _apply_url := func(new_url: String) -> void:
		model_url = new_url
		url_input.text = new_url
		loading_url_input.text = new_url
		_cancel_download()
		_ensure_model()
	url_input.text_submitted.connect(_apply_url)
	loading_url_input.text_submitted.connect(_apply_url)

	_set_status("Checking for model file...")
	_ensure_model()

func _cancel_download() -> void:
	if _http == null:
		return
	_http.cancel_request()
	_http.queue_free()
	_http = null

func _setup_font() -> void:
	var emoji_font := SystemFont.new()
	emoji_font.font_names = PackedStringArray([
		"Apple Color Emoji",   # macOS / iOS
		"Segoe UI Emoji",      # Windows
		"Noto Color Emoji",    # Linux
		"Android Emoji",
	])

	var base_font := SystemFont.new()
	base_font.font_names = PackedStringArray(["Helvetica Neue", "Arial", "sans-serif"])
	base_font.fallbacks = [emoji_font]

	var t := Theme.new()
	for ctrl_type in ["Label", "Button", "LineEdit", "RichTextLabel"]:
		t.set_font("font", ctrl_type, base_font)
	theme = t

func _model_filename() -> String:
	return model_url.get_file()

func _ensure_model() -> void:
	var filename := _model_filename()
	if FileAccess.file_exists("user://" + filename):
		model_path = ProjectSettings.globalize_path("user://" + filename)
		_set_status("Initialising LLM...")
		_init_llm()
		return
	_start_download()

func _start_download() -> void:
	_set_status("Downloading model — please wait...")
	_http = HTTPRequest.new()
	_http.download_file = "user://" + _model_filename()
	add_child(_http)
	_http.request_completed.connect(_on_download_complete)
	var err := _http.request(model_url)
	if err != OK:
		_set_status("Download request failed: %d" % err)

func _process(delta: float) -> void:
	if _http == null:
		return
	_progress_timer += delta
	if _progress_timer < 0.05:
		return
	_progress_timer = 0.0
	var downloaded := _http.get_downloaded_bytes()
	var total := _http.get_body_size()
	if total > 0:
		_set_status("Downloading model... %d%% (%d / %d MB)" % [
			int(100.0 * downloaded / total),
			downloaded / 1048576,
			total / 1048576,
		])
	else:
		_set_status("Downloading model... %d MB received" % [downloaded / 1048576])

func _on_delete_pressed() -> void:
	var path := "user://" + _model_filename()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_set_status("Model deleted.")
		url_hbox.show()
	else:
		_set_status("No downloaded model to delete.")

func _on_download_complete(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http = null
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Download failed (result=%d, http=%d)" % [result, response_code])
		return
	model_path = ProjectSettings.globalize_path("user://" + _model_filename())
	_set_status("Download complete. Initialising LLM...")
	_init_llm()

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

	var err := ctx.create(model)
	if err != OK:
		_set_status("ctx.create() failed: %d" % err)
		return

	chat = LLMChat.new()
	chat.setup(model, ctx)
	chat.max_tokens = 256
	chat.enable_thinking = false
	chat.temperature = 0.7
	chat.token_generated.connect(_on_token)
	chat.response_received.connect(_on_response)
	chat.inference_failed.connect(_on_inference_failed)

	_set_status("Ready. Enter a prompt and press Send.")
	send_button.disabled = false
	url_hbox.hide()
	loading_screen.hide()

func _on_model_failed(error: String) -> void:
	_set_status("Model load failed: " + error)
	loading_screen.hide()

func _on_send_pressed() -> void:
	var prompt := prompt_input.text.strip_edges()
	if prompt.is_empty() or chat.is_busy():
		return
	output_label.text = ""
	send_button.disabled = true
	prompt_input.editable = false
	_set_status("Generating...")
	chat.complete([{"role": "user", "content": prompt}])

func _on_token(token: String) -> void:
	output_label.text += token

func _on_response(_text: String) -> void:
	_set_status("Done.")
	send_button.disabled = false
	prompt_input.editable = true

func _on_inference_failed(error: String) -> void:
	_set_status("Inference failed: " + error)
	send_button.disabled = false
	prompt_input.editable = true

func _set_status(msg: String) -> void:
	status_label.text = msg
	loading_label.text = msg
	print(msg)
