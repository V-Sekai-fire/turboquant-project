/-
  Formal verification of the multi-model UI state machine in turboquant_chat/core/main.gd.

  Audit (2026-04-28) — gaps fixed in this revision:
  1. ErrorDownload, ErrorModel, ErrorContext removed: the code never enters these
     states.  Download and load failures both call _show_selector() immediately,
     collapsing directly back to Idle.
  2. dl_done added (Downloading → Idle): on native platforms a successful download
     does NOT auto-load the model — the user must click Use.  The Lean proof
     previously only modelled dl_ok (Downloading → LoadingLLM), which is the Web
     path.  dl_done covers the native success path.
  3. idle_cancel added (Idle → Ready): after switch_model the loaded model and chat
     session remain valid.  The user must be able to dismiss the selector and return
     to the existing session without reloading.  This required a "Back to Chat"
     button in the UI (added in the same commit).
  4. load_fail merged: _on_model_failed and _on_context_failed both call
     _show_selector() and return to Idle; they are a single Lean transition.
  5. grab_focus precondition: idle_download and idle_load require the user to
     interact with AddURLInput or the model list.  _show_selector() now calls
     add_url_input.grab_focus() so keyboard input (including paste) is routed
     correctly on entry — a liveness precondition for both transitions.
-/

inductive State where
  | Idle        -- model selector shown; no operation in progress
  | Downloading -- one model downloading; selector still visible
  | LoadingLLM  -- LLM initialising with chosen model
  | Ready       -- model loaded, chat active
  | Generating  -- inference running
  deriving Repr, DecidableEq

/-- One-step transitions matching the GDScript signal handlers in main.gd -/
inductive Step : State → State → Prop where
  -- _on_download_model: user clicks Download
  | idle_download : Step .Idle .Downloading
  -- _on_use_model: user clicks Use on a downloaded model
  | idle_load     : Step .Idle .LoadingLLM
  -- _on_switch_model_pressed + back button: dismiss selector, return to existing session
  | idle_cancel   : Step .Idle .Ready
  -- _on_download_complete (Web): download complete, auto-loads immediately
  | dl_ok         : Step .Downloading .LoadingLLM
  -- _on_download_complete (native, success): returns to Idle; user clicks Use to load
  | dl_done       : Step .Downloading .Idle
  -- _on_download_complete (failure): returns to Idle with error in status label
  | dl_fail       : Step .Downloading .Idle
  -- _on_remove_model while downloading: cancel_download, _active_url cleared
  | dl_cancel     : Step .Downloading .Idle
  -- _on_context_created: model and context ready
  | load_ok       : Step .LoadingLLM .Ready
  -- _on_model_failed / _on_context_failed: both call _show_selector, return to Idle
  | load_fail     : Step .LoadingLLM .Idle
  -- _on_send_pressed
  | send          : Step .Ready .Generating
  -- _on_response or _on_inference_failed
  | done          : Step .Generating .Ready
  -- _on_clear_pressed: chat.cancel() (Erlang exit signal) + chat.reset()
  | clear         : Step .Generating .Ready
  -- _on_switch_model_pressed: show selector while keeping model in memory
  | switch_model  : Step .Ready .Idle

/-- Reachability: reflexive-transitive closure of Step -/
inductive Reaches : State → State → Prop where
  | refl : Reaches s s
  | cons : Step s m → Reaches m t → Reaches s t

/-- A state is recoverable if the user can reach Ready from it -/
abbrev Recoverable (s : State) : Prop := Reaches s .Ready

-- ── Positive witnesses ────────────────────────────────────────────────────────

theorem ready_ok    : Recoverable .Ready      := .refl
theorem gen_ok      : Recoverable .Generating := .cons .done .refl
theorem load_ok_thm : Recoverable .LoadingLLM := .cons .load_ok .refl
theorem dl_ok_thm   : Recoverable .Downloading := .cons .dl_ok load_ok_thm
theorem idle_ok     : Recoverable .Idle       := .cons .idle_load load_ok_thm

-- ── All states are recoverable ────────────────────────────────────────────────

theorem all_recoverable (s : State) : Recoverable s := by
  cases s
  · exact idle_ok
  · exact dl_ok_thm
  · exact load_ok_thm
  · exact ready_ok
  · exact gen_ok

-- ── Determinism-adjacent: no state is a dead end ─────────────────────────────
-- Every state has at least one outgoing Step.

theorem no_dead_ends (s : State) : ∃ t, Step s t := by
  cases s
  · exact ⟨_, .idle_download⟩
  · exact ⟨_, .dl_ok⟩
  · exact ⟨_, .load_ok⟩
  · exact ⟨_, .send⟩
  · exact ⟨_, .done⟩

-- ── Summary ───────────────────────────────────────────────────────────────────
/-
  All 5 states (Idle, Downloading, LoadingLLM, Ready, Generating) are recoverable
  and no state is a dead end.

  Transitions map 1-to-1 to GDScript signal handlers:
    idle_download  ← _on_download_model
    idle_load      ← _on_use_model / startup auto-load
    idle_cancel    ← Back to Chat button (_loaded_url preserved)
    dl_ok          ← _on_download_complete (Web, auto-load)
    dl_done        ← _on_download_complete (native, success → Idle)
    dl_fail        ← _on_download_complete (failure → Idle)
    dl_cancel      ← _on_remove_model during active download
    load_ok        ← _on_context_created
    load_fail      ← _on_model_failed / _on_context_failed (both → Idle)
    send           ← _on_send_pressed
    done           ← _on_response / _on_inference_failed
    clear          ← _on_clear_pressed
    switch_model   ← _on_switch_model_pressed
-/
