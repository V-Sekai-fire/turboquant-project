/-
  Formal verification of the adaptive download chunk size algorithm in
  turboquant_chat/core/main.gd (_chunk_for_throughput, _process adaptation).

  The algorithm uses TCP slow-start style mid-download adaptation:
    - Starts at MIN_CHUNK (256 KB) to get an initial throughput measurement quickly.
    - Every 50 ms (_process tick), measures bytes received in that window.
    - Computes optimal chunk = clamp(window_bps / 10, MIN_CHUNK, MAX_CHUNK).
    - Applies it immediately via HTTPRequest.download_chunk_size (live, no restart).
    - When chunk == MAX_CHUNK, declares saturation: network is the bottleneck,
      no further probing needed.

  This mirrors `perNeighborLatencyTicks` in the multiplayer-fabric codebase
  (Resources.lean), which converts a measured RTT (ms) into a tick-count buffer
  with a proved floor.  Here input is throughput (bytes/s), output is a byte
  count with proved floor and ceiling.

  Proved properties:
    (1) chunk_in_bounds   — always in [MIN_CHUNK, MAX_CHUNK]
    (2) chunk_monotone    — larger throughput → larger-or-equal chunk
    (3) chunk_zero        — zero throughput → MIN_CHUNK (safe default / slow-start seed)
    (4) chunk_saturates   — throughput ≥ MAX_CHUNK×10 → MAX_CHUNK (ceiling tight)
    (5) chunk_sat_ge      — any throughput above the saturation threshold → MAX_CHUNK
    (6) chunk_pos         — always positive (never 0)
    (7) saturated_iff     — saturation condition is equivalent to high throughput
-/

-- ── Constants (match main.gd) ────────────────────────────────────────────────

/-- 256 KB: slow-start seed; short first window gives throughput reading fast. -/
def minChunk : Nat := 256 * 1024

/-- 8 MB: saturation ceiling; beyond this OS socket buffering dominates. -/
def maxChunk : Nat := 8 * 1024 * 1024

/-- Saturation threshold (bytes/s): at or above this, chunk clamps to maxChunk. -/
def satThreshold : Nat := maxChunk * 10

-- Sanity check: floor < ceiling.
theorem min_lt_max : minChunk < maxChunk := by decide

-- ── Algorithm ────────────────────────────────────────────────────────────────

/-- Adaptive chunk size: target one chunk ≈ 100 ms of data at `throughputBps`.
    Applied every 50 ms in _process; HTTPRequest reads the property each iteration.
    GDScript: clampi(throughput_bps / 10, MIN_CHUNK, MAX_CHUNK) -/
def chunkForThroughput (throughputBps : Nat) : Nat :=
  (throughputBps / 10).max minChunk |>.min maxChunk

/-- Saturation: the chunk is at the ceiling, meaning network speed is the
    bottleneck and probing larger chunks cannot improve throughput.
    GDScript: saturated = (new_chunk >= MAX_CHUNK) -/
def saturated (throughputBps : Nat) : Bool :=
  chunkForThroughput throughputBps == maxChunk

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

-- ── (3) Zero default (slow-start seed) ───────────────────────────────────────

/-- Zero throughput → minChunk.  This is also the slow-start initial value:
    the first 50 ms window has no prior measurement, so we effectively start
    here and ramp up as real data arrives. -/
theorem chunk_zero : chunkForThroughput 0 = minChunk := by decide

-- ── (4) Concrete saturation ───────────────────────────────────────────────────

/-- At exactly the saturation threshold, result equals maxChunk. -/
theorem chunk_saturates : chunkForThroughput satThreshold = maxChunk := by
  native_decide

-- ── (5) General saturation ────────────────────────────────────────────────────

/-- Any throughput at or above satThreshold clamps to maxChunk. -/
theorem chunk_sat_ge (bps : Nat) (h : satThreshold ≤ bps) :
    chunkForThroughput bps = maxChunk := by
  unfold chunkForThroughput minChunk maxChunk satThreshold
  simp only [Nat.max_def, Nat.min_def]
  split_ifs <;> omega

-- ── (6) Positivity ────────────────────────────────────────────────────────────

/-- The chunk size is always strictly positive. -/
theorem chunk_pos (bps : Nat) : 0 < chunkForThroughput bps := by
  have ⟨h, _⟩ := chunk_in_bounds bps
  exact Nat.lt_of_lt_of_le (by decide) h

-- ── (7) Saturation iff ────────────────────────────────────────────────────────

/-- The saturated flag is true exactly when throughput ≥ satThreshold.
    Proved in both directions so the GDScript check `new_chunk >= MAX_CHUNK`
    faithfully reflects "we've found the network ceiling". -/
theorem saturated_iff (bps : Nat) :
    saturated bps = true ↔ satThreshold ≤ bps := by
  unfold saturated chunkForThroughput minChunk maxChunk satThreshold
  simp only [Nat.max_def, Nat.min_def, beq_iff_eq]
  split_ifs <;> omega

-- ── Evaluation examples ────────────────────────────────────────────────────────
-- These match the adaptation sequence seen on a fast connection (each line is
-- one 50 ms window reading after the chunk size was applied the previous tick).

#eval chunkForThroughput 0            -- 262144   (256 KB, slow-start seed)
#eval chunkForThroughput 2097152      -- 262144   (2 MB/s  → floor)
#eval chunkForThroughput 10485760     -- 1048576  (10 MB/s → 1 MB)
#eval chunkForThroughput 52428800     -- 5242880  (50 MB/s → 5 MB)
#eval chunkForThroughput 83886080     -- 8388608  (80 MB/s → 8 MB = MAX, saturated)
#eval saturated 83886080              -- true
#eval saturated 10485760              -- false
