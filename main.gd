extends Control

@onready var status_label: Label = $VBox/StatusLabel
@onready var output_label: Label = $VBox/OutputLabel
@onready var prompt_input: LineEdit = $VBox/HBox/PromptInput
@onready var send_button: Button = $VBox/HBox/SendButton

var model: LLMModel
var ctx: LLMContext
var chat: LLMChat

func _ready() -> void:
	send_button.disabled = true
	_set_status("Initialising LLM...")
	_init_llm()

func _init_llm() -> void:
	model = LLMModel.new()
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

func _on_model_failed(error: String) -> void:
	_set_status("Model load failed: " + error)

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
	print(msg)
