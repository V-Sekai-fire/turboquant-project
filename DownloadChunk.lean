/-
  Formal verification of the adaptive download chunk size algorithm in
  turboquant_chat/core/main.gd (_chunk_for_throughput).

  The algorithm selects `download_chunk_size` so that one chunk covers
  approximately 100 ms of data at the measured network throughput:

      target = throughput_bps / 10          -- integer bytes, 100 ms window
      chunk  = clamp(target, MIN_CHUNK, MAX_CHUNK)

  This mirrors `perNeighborLatencyTicks` in the multiplayer-fabric codebase
  (Resources.lean), which converts a measured RTT (ms) into a tick-count
  buffer with a provable floor.  Here the input is throughput (bytes/s) and
  the output is a byte count with proved floor and ceiling.

  We prove:
    (1) chunk_in_bounds   — result is always in [MIN_CHUNK, MAX_CHUNK]
    (2) chunk_monotone    — larger throughput yields larger-or-equal chunk
    (3) chunk_zero        — zero throughput → MIN_CHUNK (safe default)
    (4) chunk_saturates   — throughput ≥ MAX_CHUNK×10 → MAX_CHUNK (clamp tight)
    (5) chunk_pos         — result is always positive (never 0)
-/

-- ── Constants (match main.gd) ────────────────────────────────────────────────

/-- 256 KB: conservative floor; keeps progress smooth on slow links. -/
def minChunk : Nat := 256 * 1024

/-- 8 MB: ceiling; beyond this OS socket buffering dominates. -/
def maxChunk : Nat := 8 * 1024 * 1024

-- Sanity: floor is strictly below ceiling.
theorem min_lt_max : minChunk < maxChunk := by decide

-- ── Algorithm ────────────────────────────────────────────────────────────────

/-- Adaptive chunk size: target one chunk ≈ 100 ms of data at `throughputBps`.
    Matches `_chunk_for_throughput` in main.gd:
        return clampi(throughput_bps / 10, MIN_CHUNK, MAX_CHUNK)
    (throughput ≤ 0 is handled by the caller; here we model the general Nat case.) -/
def chunkForThroughput (throughputBps : Nat) : Nat :=
  (throughputBps / 10).max minChunk |>.min maxChunk

-- ── (1) Bounds ───────────────────────────────────────────────────────────────

/-- The chunk size always stays in [minChunk, maxChunk]. -/
theorem chunk_in_bounds (bps : Nat) :
    minChunk ≤ chunkForThroughput bps ∧ chunkForThroughput bps ≤ maxChunk := by
  unfold chunkForThroughput minChunk maxChunk
  simp only [Nat.max_def, Nat.min_def]
  split_ifs <;> omega

-- ── (2) Monotonicity ─────────────────────────────────────────────────────────

/-- Higher throughput never produces a smaller chunk. -/
theorem chunk_monotone (a b : Nat) (h : a ≤ b) :
    chunkForThroughput a ≤ chunkForThroughput b := by
  unfold chunkForThroughput
  have hdiv : a / 10 ≤ b / 10 := Nat.div_le_div_right h
  simp only [Nat.max_def, Nat.min_def]
  split_ifs <;> omega

-- ── (3) Zero default ─────────────────────────────────────────────────────────

/-- Zero throughput (first run, no saved measurement) yields minChunk. -/
theorem chunk_zero : chunkForThroughput 0 = minChunk := by decide

-- ── (4) Saturation ───────────────────────────────────────────────────────────

/-- At throughput ≥ maxChunk×10 the clamp is tight: result equals maxChunk. -/
theorem chunk_saturates : chunkForThroughput (maxChunk * 10) = maxChunk := by
  native_decide

/-- More generally: any throughput ≥ maxChunk×10 gives maxChunk. -/
theorem chunk_saturates_ge (bps : Nat) (h : maxChunk * 10 ≤ bps) :
    chunkForThroughput bps = maxChunk := by
  unfold chunkForThroughput minChunk maxChunk
  simp only [Nat.max_def, Nat.min_def]
  split_ifs <;> omega

-- ── (5) Positivity ───────────────────────────────────────────────────────────

/-- The chunk size is always strictly positive. -/
theorem chunk_pos (bps : Nat) : 0 < chunkForThroughput bps := by
  have ⟨h, _⟩ := chunk_in_bounds bps
  exact Nat.lt_of_lt_of_le (by decide) h

-- ── Summary ──────────────────────────────────────────────────────────────────
/-
  Proved properties:
    ∀ bps, minChunk ≤ chunkForThroughput bps ≤ maxChunk   (bounded)
    a ≤ b → chunkForThroughput a ≤ chunkForThroughput b   (monotone)
    chunkForThroughput 0 = minChunk                        (safe default)
    bps ≥ maxChunk*10 → chunkForThroughput bps = maxChunk  (clamp tight)
    0 < chunkForThroughput bps                             (never zero)

  Runtime behaviour (cross-session adaptation):
    - First download: throughput_bps = 0 → chunk = minChunk (256 KB, safe)
    - After download: measured throughput saved to settings.cfg
    - Next download: chunk = clamp(saved_bps / 10, MIN, MAX)
    - Example: 80 MB/s → chunk = clamp(8388608, 262144, 8388608) = 8 MB (maxChunk)
    - Example: 10 MB/s → chunk = clamp(1048576, 262144, 8388608) = 1 MB
    - Example:  2 MB/s → chunk = clamp(209715,  262144, 8388608) = 256 KB (floor)
-/
