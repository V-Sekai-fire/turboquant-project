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

## Most of this already exists

Commons is largely an **assembly**, not a new build. Surveying the orgs turned up
working pieces for most of the ladder, several of them formally specified. The
expensive mistake here would be rebuilding any of it.

| piece | repo | covers |
|---|---|---|
| the one action surface | `v-sekai-multiplayer-fabric/contract-command` | "a command in, reply bytes out, and nothing about how the command arrived" — **and its gate**: `proof/roundtrip.c` drives an interactor with no transport at all |
| GTN planner | `V-Sekai/godot-goal-task-planner` | a C++ Godot module shaped exactly like `modules/llm`; `PlannerDomain`, `PlannerState`, `PlannerMultigoal`, `PlannerPlan`, with TLA+ specs for HTN backtracking |
| personas, capabilities, belief | `PlannerPersona`, `PlannerBeliefManager` | "a persona (human, AI, or hybrid) with capabilities and ego-centric beliefs … beliefs about others" |
| ReBAC | `v-sekai-multiplayer-fabric/entities-lean-rebac` | dependency-free authorization core in Lean, with proofs |
| tick loop | `v-sekai-multiplayer-fabric/interactor-authority` | "one zone's single writer, ticking at 20 Hz on the harness ring" |
| needs / inventory | `v-sekai-multiplayer-fabric/progression` | profile and inventory rules, affinity gate |
| transports | `transport-gateway`, `fabric-wt-harness` | H3/WebTransport termination, and a role-swapping test client |
| avatars | `V-Sekai/godot-vrm` | VRM import/export, MToon |
| telemetry | `V-Sekai-fire/opentelemetry-godot` | deadline-miss and latency measurement |
| terminal client | `weftspun/runpod-chat-tui` | a starting point for the slash-command client |

`PlannerPersona` deserves emphasis: **"human, AI, or hybrid"** with capabilities
and ego-centric beliefs is the dual-driver design and the observation-equity rule
already built. A genie planning from its persona's beliefs does not get
omniscience for free — the equity constraint is architectural rather than a
policy we have to remember to enforce.

`godot-goal-task-planner` and RECTGTN are both GTPyhop-lineage (multigoal is a
GTPyhop concept), so the bridge between them is a serialization mapping, not a
semantic gap.

**What is actually new**, and it is a short list: grammar-constrained RECTGTN
emission from `modules/llm`; the RECTGTN ↔ `PlannerDomain` bridge; the Commons
content itself; the event stream and its renderers; and residual FSQ codes much
later.

**Rung zero for this path is therefore: does `godot-goal-task-planner` build
against `turboquant-godot`?** It was last touched 2026-05-02 against a different
Godot point than this fork. That question is free to answer and everything above
depends on it, so it goes first.

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

### Equity: same budget, not handicapped output

Genies will outperform players, and soon. A shared surface makes them
*interoperable*; it does not make them *equitable*. Sharing `submit_action` while
being allowed to call it thirty times a tick, from omniscient state, with
unbounded recall, is not a fair contest — and a world where plan-driven
residents quietly dominate player-driven ones is a bad game regardless of what
the benchmark says.

The fix is to equalise the **budget**, never to handicap the output. Nerfing a
genie's competence is unfalsifiable hand-tuning; equalising what a driver is
*given* is measurable:

| dimension | rule | negative control |
|---|---|---|
| action rate | ≤ 1 action per resident per tick | a driver submitting 2 in one tick must be **rejected** |
| observation | a pure function of that resident's position and relations | a request for global state must be **rejected** |
| deadline | the same wall-clock tick; a miss is a `pass` for both | a driver exempt from the deadline must **fail** the gate |
| memory | a bounded recent window, plus an in-world journal action | a read beyond the window must be **rejected** |
| plan privacy | no driver reads another resident's pending plan | a cross-read must be **rejected** |

Memory is the sharpest inequity and the most interesting fix. A genie has
perfect recall of everything it has seen; a person does not. Rather than
truncating the genie arbitrarily, memory becomes a **resource spent through the
surface**: recall beyond a short window requires having written a journal entry,
and writing one is an action that costs a tick like any other. Both drivers then
face the same trade — spend time remembering, or spend it doing. The asymmetry
becomes a design element instead of an advantage.

### The A/A equity test

The gate that makes "equitable" falsifiable rather than aspirational: drive a
resident with **the same scripted policy** through the player harness and
through the genie harness, on identical seeds, and compare returns. They must be
statistically indistinguishable.

If the identical policy scores higher as a genie, the budgets differ and the
harness is leaking an advantage — extra actions, wider observation, laxer
deadline, longer memory. The test says nothing about how clever either driver
is, which is exactly why it isolates the harness. Run it in CI; it is cheap,
deterministic, and it fails on the day someone adds a convenience.

### Setting: gated enclaves, vast distance, strangers

Cyberprep rather than pastoral. Corp-run residential enclaves — each marketed as
a *commons*, none of them common — scattered across a landmass, separated by
distances nobody crosses casually, occupied by people who do not know their
neighbours.

The fiction is chosen because it makes RECTGTN's three letters load-bearing
instead of decorative:

- **R — access is credentialed, not social.** A gate is not a closed door you
  could knock on; it is a transit permission you either hold or do not. `goto`
  can therefore *fail on arrival*, and `DELEGATED_TO` is someone literally
  granting you passage. This is ReBAC as the enclave operator would actually
  implement it.
- **C — capabilities are certifications, and they lapse.** This fixes a real
  defect in the earlier design: teaching granted capabilities permanently, a
  faucet with no sink, so a long run ended with everyone able to do everything
  and every guard guarding nothing. Certs expiring is the sink, and it is
  diegetic rather than bolted on. Star Wars Galaxies' economy worked because
  items decayed; the same logic applies to competence.
- **T — distance and expiry both run on the clock.** A cert that lapses at 18:00
  and a four-hour walk are the same kind of constraint, and a plan has to
  reconcile them.

**Not knowing your neighbours is the fourth mechanic.** You do not know who holds
which credential until you interact, so `PlannerBeliefManager`'s ego-centric
"beliefs about others" does real work and *information itself becomes valuable*.
The planner acts under uncertainty about who can help, which is a much harder and
more interesting problem than the omniscient version — and it is the honest
equity story too, since a genie planning from its persona's beliefs cannot see
the whole board either.

It also sharpens the failure rung 0 already exposed. A greedy resident does not
merely waste four hours walking; it walks four hours and is **refused at the
gate**. That is a legible, watchable failure, and one no reactive policy can
avoid — it requires committing to a plan that checks permission before spending
the daylight.

### World: a scattered settlement, not a house

Many commons across a landmass **200–400 km** wide, in one continuous coordinate
space. Each is a handful of rooms — kitchen, workshop, garden, private rooms —
with contended resources: one stove, one workbench, limited daylight. What makes
the scenario is the distance *between* them.

**Travel is a planning cost.** Reaching another commons takes hours of in-world
time, so a `goto` action carries a real `duration` and eats the same daylight the
work does. That turns capability scarcity into a spatial problem: the nearest
resident who can mend is forty minutes away, the workshop closes at dusk, and
`CAN_ENTER` may refuse you when you arrive. Distance, time, capability and
permission all bear on one plan, which is the whole reason the planner is an
HTN with temporal and ReBAC guards rather than a behaviour tree.

### Why this needs double precision

Single-precision floats carry a 24-bit mantissa, so absolute resolution degrades
linearly with distance from origin:

| distance from origin | float32 resolution |
|---|---|
| 1 km | 0.12 mm |
| 8 km | ~1 mm |
| 100 km | ~12 mm |
| 400 km | ~48 mm |

Sub-millimetre holds only to about 8 km. At settlement scale a character's foot
placement quantises to centimetres, which reads as foot-sliding and physics
jitter — the artefacts double precision exists to remove.

**The usual escape hatch is closed here, and that is the actual argument.** Large
worlds normally avoid double precision by rebasing the origin around the local
player. That works when each client renders its own neighbourhood. It does not
work for Commons, because the authority is a **single server-side simulation
holding every resident in one coordinate space at once** — `interactor-authority`
is "one zone's single writer, ticking at 20 Hz." There is no per-client origin to
rebase to when the tick must advance every agent across the whole landmass in the
same frame of reference. Double precision is the clean answer rather than a
preference.

It also means the scenario finally exercises the parts of the fabric that a
single house would leave idle: `transport-fanout`'s interest filtering has
something to filter, and `lean-spatial-oracle`'s ghost expansion has a space to
predict over.

**Consequence for the engine.** No official Godot build ships double precision —
verified across every release asset, and the standing proposal for it is
unresolved. So "stock Godot" here means *unmodified source built with
`precision=double`*, signed by us, not the official binary. `godot-images` is
already engine build infrastructure; the new cost is signing and notarisation per
platform per Godot release. godot-sandbox ships `.double.` variants for every
target including web wasm32, so UGC is unaffected by the choice.

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
| `greedy` | scripted housekeeper | **the 1.0 point** — free, deterministic, reruns identically |
| `human` | a player, same surface, same seeds | a reported row, not the denominator |
| `genie` | plan-driven, same surface, same seeds | a reported row |

**The human is deliberately not the denominator.** Anchoring on human play is the
literature default and it fails exactly when it matters: once genies outperform
people, every score is `> 1` and the metric saturates into noise — the same way
human-normalised Atari scores stopped discriminating once agents went
superhuman. A denominator that a subject routinely exceeds has stopped
measuring.

So the scripted greedy housekeeper is the 1.0 point. It is boring, which is the
virtue: it is deterministic, free to rerun, and does not improve over time, so a
score means the same thing next year as this year. Human and genie are both
*rows measured against it*, which keeps the pair directly comparable to each
other as the genie improves past the person.

Report per configuration: HNS IQM, raw return, **deadline-miss rate**, **replan
count**, and the floor in the same table.

## Broadcast: one event stream, many renderers

The world emits a **structured, timestamped event stream**. Everything else is a
renderer or a sink over it. Video is not the primary output; it is one optional
renderer among several.

```
Commons world ──emits──> event stream (structured, timestamped)
                            │
                            ├──> asciinema cast v2  ──> browser player   (primary, cheap)
                            ├──> slash commands     <── viewer input, into submit_action
                            └──> Godot 3D render    ──> RTMP             (later, optional)
```

The cost difference is not marginal, and it is what makes 24/7 operation
affordable — which was the structural advantage over human streamers in the
first place:

| renderer | bandwidth | GPU for pixels |
|---|---|---|
| asciinema cast | ~1–10 KB/min | none |
| 1080p60 video | ~34 MB/min | render + encode |

Three to four orders of magnitude, and the GPU is then needed **only** for the
genie's inference.

**Slash commands are not a feature, they are the player driver.** A viewer typing
`/takeover alice` then `/cook` is driving a resident through the same
`submit_action` a genie uses. Three consequences fall out for free: the player
rung and the broadcast rung become one rung; the command log *is* the training
trace, with no separate capture path to keep in sync; and the surface-parity and
A/A equity gates cover viewer input unchanged.

A terminal stream is a niche audience and will not by itself reach the 5–20
viewers-per-channel life-sim categories. That is why the event stream stays
renderer-agnostic: asciinema is the always-on development and dogfooding
channel, the 3D render is the marketing channel, and neither forecloses the
other. The event stream is the invariant.

## Where each piece runs: Fly and RunPod

The world is **CPU-cheap and must be always on**. The genie is **GPU-expensive
and only wanted occasionally**. Putting both on one always-on GPU box is the
expensive mistake, and it is the one I was heading for.

| concern | host | why |
|---|---|---|
| world tick (20 Hz), needs, ReBAC, planner execution | **Fly** | CPU-only, must run 24/7, cheap |
| event stream, asciinema cast, clip extraction | **Fly** | text; kilobytes per minute |
| web client, chat widget, WS + H3/WT termination | **Fly** | edge, always-on, existing Plug/Bandit pattern |
| trace persistence | **Fly** volume | small, append-only |
| **plan generation (the genie)** | **RunPod Serverless** | GPU, bursty, scales to zero between plans |
| model weights | RunPod **network volume** | ~$1.40/mo, shared across workers |
| finetuning, offline A/B benchmarking | RunPod **pods** | batch GPU, torn down after |

`transport-runpod` already exists for exactly this shape — "takes jobs from an
endpoint queue and hands each to an interactor" — and
`interactor-qwen35-defiant` already runs a Qwen3.5 with NextN speculative
decoding, TurboQuant KV, and a **network-volume slot cache**, which is the
durable token cache that makes serverless cold starts survivable. The genie is
therefore a solved deployment, not a new one.

An always-on GPU pod is roughly **$240/mo** at the community A6000 rate. A Fly
instance carrying the world is on the order of **$20/mo**. That gap is the
difference between a hobby and a living wage, and it exists only because plans
amortise: the tick loop never blocks on a model.

### The plan horizon is a cost knob

Whether the genie belongs on serverless or a pod is not a matter of taste, it is
a duty-cycle calculation:

```
duty cycle ≈ (residents × seconds per plan) ÷ plan horizon in seconds
```

Community pod is $0.33/hr against $1.22/hr serverless, so **a pod wins above
roughly 27% duty cycle** and serverless wins below it. With six residents and a
2 s plan: a 20 s horizon is 60% — take the pod; a 120 s horizon is 10% — take
serverless and pay nothing between plans.

So **lengthening the plan horizon is directly a cost reduction**, which is one
more argument for RECTGTN plans over per-tick actions, and a reason to measure
horizon length as a first-class number rather than an incidental one.

## The web client: a renderer slot and a chat widget

The test surface is a web page with two parts — a **feed** and a **chat widget** —
deployed on the existing Fly.io pattern (`weftspun-studio` is Plug/Bandit on Fly,
`weftspun-usd-viewer` is already its own Fly deploy target, and
`multiplayer-fabric-infra` is Terraform + Actions for exactly this).

The feed is a **slot**, not a fixed choice. Three renderers fill it, and the
middle one is the important one:

| renderer | where pixels are made | server cost | use |
|---|---|---|---|
| asciinema player | browser, from text | ~1–10 KB/min, no GPU | always-on, dev, dogfooding |
| **Godot web export (WASM)** | **the viewer's browser** | **events only, no GPU** | the 3D view, cheaply |
| server render → WebRTC/RTMP | server GPU | encode + Mbps | only where a platform demands pixels |

**Streaming events instead of pixels means 3D costs almost nothing.** A Godot
HTML5 export renders the scene client-side from the same event stream the
asciinema cast is built from — so the viewer gets full 3D at text-stream
bandwidth, with no server GPU and no encoder. Server-side rendering is then
needed *only* for RTMP to a platform that will not run our client, which is a
marketing decision rather than an architectural one. The org already ships WASM
3D in a browser (`usd-viewer`, `weftspun-3d-studio`), so this is a known path.

The chat widget carries slash commands, which are the player driver, so it is
not a separate feature — it is the input half of the same channel the feed comes
down. Phoenix Channels give the WS half directly on the existing Elixir stack.

### Renderer parity

The fourth instance of the same gate: **every renderer consumes the same event
stream, and swapping renderers must not change what the world does.**

| check | negative control |
|---|---|
| asciinema, WASM, and video renderings of one recorded stream agree on world state | a renderer requiring a bespoke event the others do not receive must **fail** |

If a renderer ever needs its own event, the event belongs in the stream for
everyone or it does not exist. That rule is what keeps the cheap path and the
marketing path from silently diverging.

## Transport: WebSockets and H3/WebTransport, both

Both are required. WebSockets are the compatibility floor and work in every
browser; H3/WebTransport gives multiplexed streams, unreliable datagrams for
tick state, and no head-of-line blocking. A cast file alone cannot carry slash
commands back, so the live channel is bidirectional either way.

This is precisely what `contract-command` exists for — the interactor has "no
idea how the command arrived" — so two transports over one interactor is the
architecture working as designed rather than a special case. `transport-gateway`
already terminates client transport, and `fabric-wt-harness` already tests the
Godot H3/WT implementation by swapping roles.

## `modules/goal_task_planner` must stay RECTGTN-compatible

The planner core exists in two implementations and they must not drift:

| implementation | binding | consumer |
|---|---|---|
| `taskweft_nif` (hex `0.2.0-dev.16`, `elixir_make`) | Erlang NIF | `taskweft`'s `plan`/`replan` MCP tools, `taskweft_rebac` |
| `V-Sekai/godot-goal-task-planner` | GDCLASS | `turboquant-godot` |

Same GTPyhop-lineage vocabulary, two bindings. If the Godot side is edited to
plan differently, the two disagree and RECTGTN stops being a shared interchange
format — plans authored against one silently misbehave on the other.

**Gate: cross-implementation conformance.** A corpus of RECTGTN domain documents
runs through both planners and the resulting plans must agree.

| check | negative control |
|---|---|
| each domain in the corpus yields the same plan from `taskweft_nif` and from the Godot module | a domain exercising a feature only one implements must **fail**, not silently produce a plausible plan |

This is the sixth instance of the one gate: the interchange format cannot tell
which implementation is executing it.

Edits to the Godot module that are **build-compatibility only** — headers,
includes, Godot API renames — are safe and do not require re-running the corpus.
Anything touching `src/plan.cpp`, `src/backtracking.cpp`, `src/domain.cpp`
semantics does, and should go upstream to the shared core rather than being
patched locally.

## The three parity gates are one gate

Driver, transport, and sink each get a parity gate, and they are the same gate
three times: **the core cannot tell which adapter it is talking to.** That is the
hexagonal claim, made falsifiable instead of asserted.

| gate | invariant | negative control |
|---|---|---|
| driver parity | player and genie are indistinguishable to the world | a policy-only action must be **rejected** |
| transport parity | the same command over WS, over H3/WT, and over no transport at all yields identical results | a transport-specific field reaching the interactor must **fail** |
| sink parity | asciinema and video render the same event stream; only the sink differs | a config differing above the sink line must **fail** |

`proof/roundtrip.c` — an interactor driven with no transport whatsoever — is
already the degenerate third case of transport parity, and it is the strongest
of the three because it cannot be satisfied by accident.

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
| A | `godot-goal-task-planner` builds against `turboquant-godot` | does the assembly plan hold at all |
| 0 | *(exists)* chat, human waits | does on-device generation work |
| 1 | wall-clock deadline + `cancel()` | can we abort cleanly and fall back |
| 2 | event stream + asciinema cast + slash commands over WS | can a human live a day, and can it be watched |
| 3 | H3/WT alongside WS; the three parity gates; A/A equity test | one surface, two transports, equal budgets |
| 4 | GBNF from the RECTGTN schema | can the model emit a schema-valid plan |
| 5 | RECTGTN ↔ `PlannerDomain` bridge; genie as second driver | can a plan drive a resident |
| 6 | `temporal` overrun detection → `replan` | are overruns caught and recovered |
| 7 | several residents, capability + `CAN_ENTER` guards, skill budget | does delegation and access routing work |
| 8 | score; random and greedy denominators, human and genie rows | is the genie better than random, and where does a person sit |
| 9 | VRM avatars; Godot render as a second sink | does it survive heterogeneous rigs, and does it film |
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
