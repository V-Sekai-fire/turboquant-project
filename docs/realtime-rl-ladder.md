# Commons: the scenario and the ladder

Gall's Law: a working complex system grows from a working simple one. Every rung
below runs, is measurable, and is useful alone. A rung is not started until the
one beneath it is green, and no rung introduces two new things at once.

Rung 0 already exists in this repo: `turboquant_chat` drives `LLMModel` /
`LLMContext` / `LLMChat` and generates text on demand. The ladder grows out of
that scene rather than replacing it — the chat window stays as the debug view
for every rung above.

## The model

**Qwen3.5-4B, Q4_K_M.** One model, not a family.

| why | |
|---|---|
| same `qwen35` arch as `interactor-qwen35-defiant` | the NextN/MTP path, TurboQuant KV config and finetune recipe transfer |
| ~2.5 GB | fits a Steam Deck's 16 GB *unified* pool with the game in it |
| carries MTP heads | `mtp_num_hidden_layers = 1`, verified across every Qwen3.5 size |
| Apache-2.0 | no licence question |

9B is the tempting alternative since Defiant already exists, but at ~5.6 GB it
is roughly 20 tok/s on a Deck — a 300-token plan takes ~15 s against a 20 s
horizon, leaving no margin for replan. The Deck is bandwidth-bound at 88 GB/s
(LCD) and that, not VRAM capacity, is the binding constraint. Size for the Deck
and every mainstream desktop is comfortable; size for the median desktop
(RTX 3060, ~360 GB/s) and the Deck falls over.

## The scenario: Commons

A shared residence on a daily clock. Six to eight residents live in it. A
resident is driven either by a **generated plan** or by a **player**, and the
world cannot tell which — both go through one action surface, the way an
Artifacts-style world is driven through an API rather than a keyboard.

The genre is the domestic life-sim. It is deliberately *not* a re-skin of any
existing title, and uses none of their names, assets, or systems.

### One surface, two drivers

This is a hard architectural constraint, not a convenience, and it pays for
itself three times:

- **Human play becomes training data for free.** A player's session is already a
  valid policy trace, because it was produced by the same calls a policy makes.
  No separate demonstration-capture path to keep in sync.
- **The human baseline becomes real.** HNS wants a human reference. With a
  shared surface, a player and a policy face identical affordances on identical
  seeds, so the comparison is honest rather than a scripted stand-in.
- **A policy can take over an absent player**, and a player can take over a
  resident mid-day, with no special-case code.

The failure this prevents is specific and common: the policy quietly gets a
privileged path — direct state mutation, an action the UI cannot express, a
validation step skipped for speed — while the player goes through the full
surface. Traces then no longer describe what the policy can do, and imitation
learning breaks silently, months later, with no error message.

### Gate: the surfaces are the same one

The claim "player and policy share an API" is worthless unless it can fail. It
is gated by three properties, each with a negative control, because a gate never
shown to fail certifies nothing:

| property | check | negative control |
|---|---|---|
| **parity** | cross-replay: a recorded player trace replays through the policy path and is accepted, and vice versa | a deliberately policy-only action (`teleport`) must be **rejected** |
| **no bypass** | world state changes only via `submit_action` | a direct state write in a test must **fail**, not silently succeed |
| **indistinguishability** | strip the provenance field from a trace; both validate identically | a trace carrying a policy-only field must **fail** validation |

Cross-replay is the load-bearing one. It fails loudly the moment someone adds a
shortcut, which is exactly when the mistake is cheap to fix rather than a year
later when the corpus is already poisoned. Provenance is recorded as metadata
*about* a trace, never as a difference *in* it.

### World

A handful of rooms — kitchen, workshop, garden, private rooms — with a day cut
into ticks. Contended resources: one stove, one workbench, limited daylight.

### Each resident has

- **Needs** that decay: rest, food, company, purpose. Crossing a threshold
  raises a goal.
- **Skills as capabilities**: `HAS_CAPABILITY` over cook, mend, garden, teach.
  Residents do **not** all have the same skills, and that asymmetry is the
  engine of the whole scenario.
- **Relationships as ReBAC edges**: `IS_MEMBER_OF` the household, `PARTNER_OF`,
  `DELEGATED_TO` for chores, `CAN_ENTER` for private rooms.
- **A VRM avatar** with its own expression and bone capability set, which is a
  *second, independent* capability axis — see below.

### Actions carry real durations

`cook_meal` is `PT45M`, `mend_coat` `PT30M`, `teach_skill` `PT1H`. The `temporal`
block returned with a plan is therefore a literal daily schedule, not a
metaphor, and animation clip lengths are the same numbers.

### What makes it RECTGTN rather than plain HTN

Two guards do load-bearing work, and a planner without them cannot express the
problem:

1. **Capability delegation.** A resident who cannot cook must ask one who can,
   or be *taught* — and teaching is itself a planned action with a duration that
   permanently changes the capability graph. The plan must sometimes invest in
   capability before it can satisfy a goal.
2. **Social access.** `CAN_ENTER` gates private rooms. A plan that routes
   through someone's room without the relation is invalid, not merely rude.

### Recovery is continuous, not contrived

Replan triggers arise from ordinary life: someone else took the stove; the
resident you delegated a chore to went to sleep; a need crossed a threshold
mid-plan; daylight ran out. Because these happen constantly, `replan` is
exercised every simulated day rather than in a special failure test.

### The VRM tie-in

Avatars out of a creation platform have wildly heterogeneous rigs — one has the
full VRM 1.0 expression set, the next has five blendshapes and a stub jaw. A
performance authored against a rich rig silently breaks on a minimal one. So the
avatar's expression and bone set is a **second capability axis**, discovered from
the file and guarded exactly like a skill. The plan stages what each specific
avatar can actually do, and degrades rather than fails.

Plans ship *alongside* the VRM, never embedded as `KHR_interactivity` graphs
inside it. The shared Khronos namespace is an authoring convenience; the
manifest's rule that glTF exports carry pure data only still binds.

## Normalisation

`HNS = (agent − random) / (reference − random)`, reported as an interquartile
mean over ≥ 10 seeds, because a mean over few seeds is dominated by outliers.

`reference` is a scripted greedy housekeeper — satisfy the most urgent need with
the nearest capable resident. It is **not** optimal and **not** a human, so an
agent may legitimately exceed 1.0. Saying so is the point; calling it "optimal"
would be the unfalsifiable phrasing that hides a weak result.

| baseline | driver | role |
|---|---|---|
| `random` | uniform over legal actions | floor |
| `greedy` | scripted housekeeper | cheap, deterministic reference |
| `human` | a player, same surface, same seeds | the honest 1.0 point |

Because players and policies share one surface, the human row is a genuine
measurement on identical affordances rather than a stand-in — which is the
denominator HNS actually asks for. Report the greedy row too: it is free,
deterministic, and reruns identically, so it catches regressions between the
rare and expensive human sessions.

Report per configuration: HNS IQM, raw return, **deadline-miss rate**, **replan
count**, and the floor in the same table.

## Wire format: verbose first, codes later

JSON-LD is too verbose — a ~300-token plan is ~6.8 s at 4B+MTP on a Deck, and
that dominates everything. A terser DSL is the wrong fix: it buys a constant
factor of two or three while *losing* the JSON-Schema→GBNF pipeline that makes
constrained decoding free.

The right fix changes the units — residual FSQ codes over plan space, ~16–32
indices instead of ~300 syntax tokens. FSQ specifically, because it has no
learned codebook to collapse on a small corpus, because its coarse-to-fine
residual structure mirrors HTN decomposition, and above all because **it is
anytime**: truncate the residual sequence and a valid, coarser plan still
decodes. Deadline degradation becomes a property of the representation instead
of a bolted-on fallback.

But the ordering is forced. **A codebook cannot be fitted over plan space until
plans exist**, so the verbose planner is the thing that produces the corpus. It
is a prerequisite, not a detour. The RECTGTN schema stays the arbiter after the
wire format changes — decode codes → JSON-LD → validate — so a decoder bug
surfaces as a validation failure rather than a plausible-but-wrong plan.

## The ladder

| rung | adds | question it answers |
|---|---|---|
| 0 | *(exists)* chat, human waits | does on-device generation work |
| 1 | wall-clock deadline + `cancel()` | can we abort cleanly and fall back |
| 2 | `submit_action`, clock, needs, **player-driven**, text log | can a human live a day through the surface |
| 3 | trace recording + the three surface gates | is there exactly one surface |
| 4 | GBNF from the RECTGTN schema | can the model emit a schema-valid plan |
| 5 | policy as a **second** consumer of the same surface | can a plan drive a resident |
| 6 | `temporal` overrun detection → `replan` | are overruns caught and recovered |
| 7 | several residents, capability + `CAN_ENTER` guards | does delegation and access routing work |
| 8 | score; random, greedy, and **human** baselines | is the policy better than random, and than a person |
| 9 | VRM avatars render the schedule | does it survive heterogeneous rigs |
| 10 | residual FSQ codes, fitted on rungs 2–8 traces | is it fast enough for the Deck |
| 11 | online policy updates | does it improve in play |

The player rung comes **before** the policy rung deliberately. A human clicking
buttons is the simplest possible driver — no model, no grammar, no deadline —
so the surface gets designed and exercised against the cheap consumer first. The
policy then arrives as a *second* consumer that must fit an existing surface,
rather than the surface growing around whatever the policy found convenient.
Build it the other way and the private fast path is already load-bearing by the
time a player needs one.

Rung 3 gating the surface before any model touches it is the same argument: the
cross-replay gate is trivial to satisfy when there is one consumer, and that is
precisely when it should be locked in.

**Rung 1 needs no new inference work.** `LLMChat::cancel()` is already an
"Erlang-style exit signal … checked at every token boundary", so the abort path
exists; rung 1 supplies only the deadline that fires it and the fallback to fall
back to. Recovery is built first, not last.

**Rung 2 is a validity gate, not a quality one** — a validation-failure rate
that should be zero. If it is ever non-zero the grammar is wrong, and the fix
belongs in the grammar, not in a retry loop.

**Rung 3 renders as a text log.** No art, no avatars, no 3D. It runs inside the
existing chat scene. Art arrives at rung 7, by which point the simulation is
already scored and correct.

**Rung 6 is the first rung where MTP is worth measuring**, because it is the
first with plans under time pressure and a real recovery cost. Three arms, same
seeds: spec off; `--spec-type draft-mtp --spec-draft-n-max 2`; the same gated
with `--spec-draft-p-min 0.60`. Report p95/p99 plan latency and deadline-miss
rate, never mean throughput — a deadline is missed by the tail.

## Sources

- [RECTGTN specification](https://github.com/taskweft/taskweft/blob/main/docs/rectgtn.md)
- [Atari 100k benchmark and human-normalised score](https://www.emergentmind.com/topics/atari-100k-benchmark)
- [Deep RL at the Edge of the Statistical Precipice — IQM over few seeds](https://arxiv.org/pdf/2108.13264)
- [Steam survey July 2026 — 16 GB overtakes 8 GB](https://wccftech.com/steam-hardware-survey-july-2026-16-gb-gpus/)
- [Steam Deck 88 GB/s bandwidth confirmed](https://www.resetera.com/threads/official-steam-deck-specs-corrected-88gb-s-bandwidth-confirmed.459321/)
