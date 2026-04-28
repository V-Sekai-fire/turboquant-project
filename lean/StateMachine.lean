/-
  Formal verification of the multi-model UI state machine in turboquant_chat/core/main.gd.

  Changes from the single-model version:
  - `Init` renamed to `Idle`: the selector is always visible in Idle, so the user
    can add/remove URLs, trigger downloads, or pick an already-downloaded model.
  - New `switch_model` transition (Ready → Idle): the user opens the model selector
    to swap models without losing the chat UI until a new load begins.
  - New `dl_cancel` transition (Downloading → Idle): the user cancels or removes the
    model entry while a download is in progress.
  - New `idle_download` (Idle → Downloading) and `idle_load` (Idle → LoadingLLM):
    replaces the old `init_no_file` / `init_file` pair; in the multi-model UI the
    selector is always reachable from Idle.
  - Error recovery routes now go back to `Idle` (not `Downloading`): `err_dl_idle`,
    `err_mdl_idle`, `err_ctx_idle`.  A separate `err_dl_retry` still allows retrying
    the same download without returning to Idle first.
  - All 8 states remain recoverable (can reach Ready).
-/

inductive State where
  | Idle          -- model selector shown; user can add/remove URLs, download, or load
  | Downloading   -- one model downloading; selector still visible
  | LoadingLLM    -- LLM initialising with chosen model
  | Ready         -- model loaded, chat active
  | Generating    -- inference running
  | ErrorDownload -- download failed
  | ErrorModel    -- _on_model_failed
  | ErrorContext  -- _on_context_failed
  deriving Repr, DecidableEq

/-- One-step transitions, one constructor per reachable event in main.gd -/
inductive Step : State → State → Prop where
  -- user clicks Download in the model selector
  | idle_download  : Step .Idle .Downloading
  -- user clicks Use on an already-downloaded model
  | idle_load      : Step .Idle .LoadingLLM
  -- download completed successfully
  | dl_ok          : Step .Downloading .LoadingLLM
  -- download failed
  | dl_fail        : Step .Downloading .ErrorDownload
  -- user cancels or removes the model entry while downloading
  | dl_cancel      : Step .Downloading .Idle
  -- user dismisses the download error and picks a different model
  | err_dl_idle    : Step .ErrorDownload .Idle
  -- user retries the same download from the error banner
  | err_dl_retry   : Step .ErrorDownload .Downloading
  -- model loaded and context created successfully
  | load_ok        : Step .LoadingLLM .Ready
  -- _on_model_failed
  | load_fail_mdl  : Step .LoadingLLM .ErrorModel
  -- _on_context_failed
  | load_fail_ctx  : Step .LoadingLLM .ErrorContext
  -- returns to selector (user picks a different model)
  | err_mdl_idle   : Step .ErrorModel .Idle
  -- returns to selector
  | err_ctx_idle   : Step .ErrorContext .Idle
  -- _on_send_pressed
  | send           : Step .Ready .Generating
  -- _on_response or _on_inference_failed
  | done           : Step .Generating .Ready
  -- _on_clear_pressed: chat.cancel() + chat.reset(), UI restored immediately
  | clear          : Step .Generating .Ready
  -- user opens model selector to switch models
  | switch_model   : Step .Ready .Idle

/-- Reachability: reflexive-transitive closure of Step -/
inductive Reaches : State → State → Prop where
  | refl : Reaches s s
  | cons : Step s m → Reaches m t → Reaches s t

/-- A state is recoverable if the user can reach Ready from it -/
abbrev Recoverable (s : State) : Prop := Reaches s .Ready

-- ── Positive witnesses ────────────────────────────────────────────────────────

theorem ready_ok        : Recoverable .Ready        := .refl
theorem gen_ok          : Recoverable .Generating   := .cons .done .refl
theorem gen_clear_ok    : Recoverable .Generating   := .cons .clear .refl
theorem load_ok_thm     : Recoverable .LoadingLLM   := .cons .load_ok .refl
theorem dl_ok_thm       : Recoverable .Downloading  := .cons .dl_ok load_ok_thm
theorem idle_ok         : Recoverable .Idle         := .cons .idle_load load_ok_thm
theorem errordl_ok      : Recoverable .ErrorDownload := .cons .err_dl_idle idle_ok
theorem errormdl_ok     : Recoverable .ErrorModel   := .cons .err_mdl_idle idle_ok
theorem errorctx_ok     : Recoverable .ErrorContext := .cons .err_ctx_idle idle_ok

-- ── All states are recoverable ────────────────────────────────────────────────

theorem all_recoverable (s : State) : Recoverable s := by
  cases s
  · exact idle_ok
  · exact dl_ok_thm
  · exact load_ok_thm
  · exact ready_ok
  · exact gen_ok
  · exact errordl_ok
  · exact errormdl_ok
  · exact errorctx_ok

-- ── Summary ───────────────────────────────────────────────────────────────────
/-
  All 8 states are recoverable:
    Idle, Downloading, LoadingLLM, Ready, Generating,
    ErrorDownload, ErrorModel, ErrorContext

  Key differences from the single-model version:
  1. Idle (was Init): selector always visible, so idle_load gives a direct path
     to Ready without requiring a download first.
  2. switch_model (Ready → Idle): allows model swapping; Ready remains recoverable
     because switch_model leads back to Idle which reaches Ready via idle_load.
  3. dl_cancel (Downloading → Idle): download can be aborted cleanly.
  4. Error states return to Idle, not Downloading, keeping the selector as the
     canonical recovery point; err_dl_retry still allows a fast re-download.
-/
