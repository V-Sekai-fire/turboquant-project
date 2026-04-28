/-
  Formal verification of the UI state machine in turboquant_chat/core/main.gd.

  States are derived from observable UI configuration (send_button, loading_screen,
  prompt_input.editable, url_hbox). Transitions are derived from signal handlers.

  We prove which states are *recoverable* (can reach Ready) and which are one-way
  links (dead ends with no path back).
-/

inductive State where
  | Init          -- _ready: loading_screen visible, send disabled
  | Downloading   -- _start_download: _http active, loading_screen visible
  | LoadingLLM    -- _init_llm running, loading_screen visible
  | Ready         -- _on_context_created: send enabled, loading_screen hidden  (line 171-173)
  | Generating    -- _on_send_pressed: send disabled, prompt not editable      (line 187-188)
  | ErrorDownload -- download failed; loading_screen still visible, can retry via url change
  | ErrorModel    -- _on_model_failed: loading_screen hidden, send still disabled (line 179-181) ← BUG
  | ErrorContext  -- _on_context_failed: loading_screen hidden, send still disabled (line 175-177) ← BUG
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
  -- _on_model_failed (line 179)
  | load_fail_mdl  : Step .LoadingLLM .ErrorModel
  -- _on_context_failed (line 175)
  | load_fail_ctx  : Step .LoadingLLM .ErrorContext
  -- _on_send_pressed (line 183)
  | send           : Step .Ready .Generating
  -- _on_response (line 198) or _on_inference_failed (line 205)
  | done           : Step .Generating .Ready

/-- Reachability: reflexive-transitive closure of Step -/
inductive Reaches : State → State → Prop where
  | refl : Reaches s s
  | cons : Step s m → Reaches m t → Reaches s t

/-- A state is recoverable if the user can reach Ready from it -/
abbrev Recoverable (s : State) : Prop := Reaches s .Ready

-- ── Positive witnesses ────────────────────────────────────────────────────────

theorem ready_ok       : Recoverable .Ready        := .refl
theorem gen_ok         : Recoverable .Generating   := .cons .done .refl
theorem load_ok        : Recoverable .LoadingLLM   := .cons .load_ok .refl
theorem dl_ok          : Recoverable .Downloading  := .cons .dl_ok load_ok
theorem errordl_ok     : Recoverable .ErrorDownload := .cons .dl_retry dl_ok
theorem init_ok        : Recoverable .Init         := .cons .init_file load_ok

-- ── One-way link lemmas ───────────────────────────────────────────────────────

-- Neither ErrorModel nor ErrorContext appear as the *source* of any Step constructor.
private theorem no_out_error_model  : ∀ {t}, ¬ Step .ErrorModel  t := fun s => nomatch s
private theorem no_out_error_ctx    : ∀ {t}, ¬ Step .ErrorContext t := fun s => nomatch s

/--
  BUG: _on_model_failed (main.gd:179) hides the loading screen but never re-enables
  send_button or shows url_hbox. No transition out of this state exists.
-/
theorem error_model_not_recoverable : ¬ Recoverable .ErrorModel := by
  intro h
  cases h with
  | refl => exact absurd rfl (by decide : State.ErrorModel ≠ State.Ready)
  | cons step _ => exact no_out_error_model step

/--
  BUG: _on_context_failed (main.gd:175) hides the loading screen but never re-enables
  send_button or shows url_hbox. No transition out of this state exists.
-/
theorem error_ctx_not_recoverable : ¬ Recoverable .ErrorContext := by
  intro h
  cases h with
  | refl => exact absurd rfl (by decide : State.ErrorContext ≠ State.Ready)
  | cons step _ => exact no_out_error_ctx step

-- ── Summary ───────────────────────────────────────────────────────────────────
/-
  Recoverable:   Init, Downloading, LoadingLLM, Ready, Generating, ErrorDownload
  NOT recoverable: ErrorModel, ErrorContext

  Fix: add `Step .ErrorModel .Downloading` and `Step .ErrorContext .Downloading`
  by showing url_hbox in both handlers so the user can change URL and retry.
  In main.gd lines 176-177 and 180-181, add:
      url_hbox.show()
-/
