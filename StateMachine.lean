/-
  Formal verification of the UI state machine in turboquant_chat/core/main.gd.

  States are derived from observable UI configuration (send_button, loading_screen,
  prompt_input.editable, url_hbox). Transitions are derived from signal handlers.

  We prove which states are *recoverable* (can reach Ready) and which are one-way
  links (dead ends with no path back).

  Change log:
  - Added `clear` transition: Generating → Ready.
    _on_clear_pressed calls chat.cancel() (Erlang-style exit signal at each token
    boundary), awaits busy == false, then chat.reset(). This makes Generating
    directly recoverable without waiting for the response signal.
-/

inductive State where
  | Init          -- _ready: loading_screen visible, send disabled
  | Downloading   -- _start_download: _http active, loading_screen visible
  | LoadingLLM    -- _init_llm running, loading_screen visible
  | Ready         -- _on_context_created: send enabled, loading_screen hidden  (line 171-173)
  | Generating    -- _on_send_pressed: send disabled, prompt not editable      (line 187-188)
  | ErrorDownload -- download failed; loading_screen still visible, can retry via url change
  | ErrorModel    -- _on_model_failed: loading_screen hidden, url_hbox shown   (fixed)
  | ErrorContext  -- _on_context_failed: loading_screen hidden, url_hbox shown (fixed)
  deriving Repr, DecidableEq

/-- One-step transitions, one constructor per reachable event in main.gd -/
inductive Step : State → State → Prop where
  -- _ensure_model: web always downloads; native downloads if no cached file
  | init_no_file   : Step .Init .Downloading
  -- _ensure_model: native, cached file found → skip download
  | init_file      : Step .Init .LoadingLLM
  -- _on_download_complete success
  | dl_ok          : Step .Downloading .LoadingLLM
  -- _on_download_complete failure
  | dl_fail        : Step .Downloading .ErrorDownload
  -- user edits URL → _apply_url → _cancel_download → _ensure_model
  | dl_retry       : Step .ErrorDownload .Downloading
  -- _on_model_loaded → _on_context_created
  | load_ok        : Step .LoadingLLM .Ready
  -- _on_model_failed (url_hbox shown, so user can retry)
  | load_fail_mdl  : Step .LoadingLLM .ErrorModel
  -- _on_context_failed (url_hbox shown, so user can retry)
  | load_fail_ctx  : Step .LoadingLLM .ErrorContext
  -- ErrorModel / ErrorContext: user edits URL → _apply_url → _cancel_download → _ensure_model
  | err_mdl_retry  : Step .ErrorModel .Downloading
  | err_ctx_retry  : Step .ErrorContext .Downloading
  -- _on_send_pressed
  | send           : Step .Ready .Generating
  -- _on_response or _on_inference_failed: inference completed normally
  | done           : Step .Generating .Ready
  -- _on_clear_pressed while Generating:
  --   chat.cancel() sends Erlang-style exit signal → worker clears busy at next token boundary
  --   then chat.reset() and UI restored immediately (no signal needed)
  | clear          : Step .Generating .Ready

/-- Reachability: reflexive-transitive closure of Step -/
inductive Reaches : State → State → Prop where
  | refl : Reaches s s
  | cons : Step s m → Reaches m t → Reaches s t

/-- A state is recoverable if the user can reach Ready from it -/
abbrev Recoverable (s : State) : Prop := Reaches s .Ready

-- ── Positive witnesses ────────────────────────────────────────────────────────

theorem ready_ok       : Recoverable .Ready        := .refl
theorem gen_ok         : Recoverable .Generating   := .cons .done .refl
theorem gen_clear_ok   : Recoverable .Generating   := .cons .clear .refl
theorem load_ok        : Recoverable .LoadingLLM   := .cons .load_ok .refl
theorem dl_ok          : Recoverable .Downloading  := .cons .dl_ok load_ok
theorem errordl_ok     : Recoverable .ErrorDownload := .cons .dl_retry dl_ok
theorem init_ok        : Recoverable .Init         := .cons .init_file load_ok
theorem errormdl_ok    : Recoverable .ErrorModel   := .cons .err_mdl_retry dl_ok
theorem errorctx_ok    : Recoverable .ErrorContext := .cons .err_ctx_retry dl_ok

-- ── All states are recoverable ────────────────────────────────────────────────

theorem all_recoverable (s : State) : Recoverable s := by
  cases s
  · exact init_ok
  · exact dl_ok
  · exact load_ok
  · exact ready_ok
  · exact gen_ok
  · exact errordl_ok
  · exact errormdl_ok
  · exact errorctx_ok

-- ── Summary ───────────────────────────────────────────────────────────────────
/-
  All states are now recoverable:
    Init, Downloading, LoadingLLM, Ready, Generating,
    ErrorDownload, ErrorModel, ErrorContext

  Key fixes since the initial proof:
  1. ErrorModel / ErrorContext: added url_hbox.show() in both handlers so the
     user can change URL and retry → err_mdl_retry / err_ctx_retry transitions.
  2. Generating: added `clear` transition via chat.cancel() + chat.reset().
     cancel() uses an atomic abort_flag checked at each token boundary (Erlang-
     style exit signal), so the worker exits without a forced thread kill and
     clears busy, allowing reset() to run safely.
-/
