/-
  Formal verification of the adaptive download chunk size algorithm in
  turboquant_chat/core/main.gd (_chunk_for_throughput).

  chunk = clamp(throughput_bps / 10, MIN_CHUNK, MAX_CHUNK)
  — one chunk targets 100 ms of data at the measured rate.

  Proved with core Lean 4 only (no Mathlib).
  Tactic notes:
  - split_ifs is Mathlib; we use by_cases + rw [if_pos/if_neg] instead.
  - le_refl is not in scope without Mathlib; omega handles reflexive ≤.
  - simp only [*] doesn't reliably reduce ite with negative hyps; explicit rw does.
-/

-- ── Constants ────────────────────────────────────────────────────────────────

def minChunk : Nat := 256 * 1024
def maxChunk : Nat := 8 * 1024 * 1024
def satThreshold : Nat := maxChunk * 10

theorem min_lt_max : minChunk < maxChunk := by decide

-- ── Algorithm ────────────────────────────────────────────────────────────────

def chunkForThroughput (bps : Nat) : Nat :=
  let t := bps / 10
  if t ≤ minChunk then minChunk
  else if maxChunk ≤ t then maxChunk
  else t

def saturated (bps : Nat) : Bool := chunkForThroughput bps == maxChunk

-- convenience: unfold everything to numeric literals for the proofs below
private abbrev LO : Nat := 256 * 1024
private abbrev HI : Nat := 8 * 1024 * 1024

private theorem chunk_unfold (bps : Nat) :
    chunkForThroughput bps =
      if bps / 10 ≤ LO then LO else if HI ≤ bps / 10 then HI else bps / 10 := rfl

-- ── (1) Bounds ───────────────────────────────────────────────────────────────

theorem chunk_in_bounds (bps : Nat) :
    minChunk ≤ chunkForThroughput bps ∧ chunkForThroughput bps ≤ maxChunk := by
  rw [chunk_unfold]; simp only [minChunk, maxChunk, LO, HI]
  by_cases h1 : bps / 10 ≤ 256 * 1024
  · rw [if_pos h1]; constructor <;> omega
  · by_cases h2 : 8 * 1024 * 1024 ≤ bps / 10
    · rw [if_neg h1, if_pos h2]; constructor <;> omega
    · rw [if_neg h1, if_neg h2]; constructor <;> omega

-- ── (2) Monotonicity ─────────────────────────────────────────────────────────

theorem chunk_monotone (a b : Nat) (h : a ≤ b) :
    chunkForThroughput a ≤ chunkForThroughput b := by
  rw [chunk_unfold a, chunk_unfold b]
  simp only [LO, HI]
  have hd : a / 10 ≤ b / 10 := Nat.div_le_div_right h
  by_cases h1 : a / 10 ≤ 256 * 1024
  · rw [if_pos h1]
    by_cases h3 : b / 10 ≤ 256 * 1024
    · rw [if_pos h3]; omega
    · by_cases h4 : 8 * 1024 * 1024 ≤ b / 10
      · rw [if_neg h3, if_pos h4]; omega
      · rw [if_neg h3, if_neg h4]; omega
  · by_cases h2 : 8 * 1024 * 1024 ≤ a / 10
    · rw [if_neg h1, if_pos h2]
      by_cases h3 : b / 10 ≤ 256 * 1024
      · omega
      · by_cases h4 : 8 * 1024 * 1024 ≤ b / 10
        · rw [if_neg h3, if_pos h4]; omega
        · omega
    · rw [if_neg h1, if_neg h2]
      by_cases h3 : b / 10 ≤ 256 * 1024
      · omega
      · by_cases h4 : 8 * 1024 * 1024 ≤ b / 10
        · rw [if_neg h3, if_pos h4]; omega
        · rw [if_neg h3, if_neg h4]; omega

-- ── (3) Zero default ─────────────────────────────────────────────────────────

theorem chunk_zero : chunkForThroughput 0 = minChunk := by decide

-- ── (4) Concrete saturation ───────────────────────────────────────────────────

theorem chunk_saturates : chunkForThroughput satThreshold = maxChunk := by
  native_decide

-- ── (5) General saturation ────────────────────────────────────────────────────

theorem chunk_sat_ge (bps : Nat) (h : satThreshold ≤ bps) :
    chunkForThroughput bps = maxChunk := by
  rw [chunk_unfold]; simp only [maxChunk, LO, HI]
  have h' : 8 * 1024 * 1024 * 10 ≤ bps := by
    simp only [satThreshold, maxChunk] at h; omega
  by_cases h1 : bps / 10 ≤ 256 * 1024
  · exfalso; omega
  · by_cases h2 : 8 * 1024 * 1024 ≤ bps / 10
    · rw [if_neg h1, if_pos h2]
    · exfalso; omega

-- ── (6) Positivity ────────────────────────────────────────────────────────────

theorem chunk_pos (bps : Nat) : 0 < chunkForThroughput bps :=
  Nat.lt_of_lt_of_le (by decide) (chunk_in_bounds bps).1

-- ── (7) Saturation iff ────────────────────────────────────────────────────────

theorem saturated_iff (bps : Nat) :
    saturated bps = true ↔ satThreshold ≤ bps := by
  simp only [saturated, beq_iff_eq, satThreshold, maxChunk]
  rw [chunk_unfold]; simp only [LO, HI]
  by_cases h1 : bps / 10 ≤ 256 * 1024
  · rw [if_pos h1]
    constructor <;> intro <;> omega
  · by_cases h2 : 8 * 1024 * 1024 ≤ bps / 10
    · rw [if_neg h1, if_pos h2]
      constructor <;> intro <;> omega
    · rw [if_neg h1, if_neg h2]
      constructor <;> intro <;> omega

-- ── Evaluation examples ────────────────────────────────────────────────────────

#eval chunkForThroughput 0            -- 262144  (256 KB floor)
#eval chunkForThroughput 2097152      -- 262144  (2 MB/s  → floor)
#eval chunkForThroughput 10485760     -- 1048576 (10 MB/s → 1 MB)
#eval chunkForThroughput 52428800     -- 5242880 (50 MB/s → 5 MB)
#eval chunkForThroughput 83886080     -- 8388608 (80 MB/s → 8 MB, saturated)
#eval saturated 83886080              -- true
#eval saturated 10485760              -- false
