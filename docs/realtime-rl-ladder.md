# Realtime RL: the ladder, RECTGTN, and the scenarios

Gall's Law: a working complex system grows from a working simple one. Each rung
below runs, is measurable, and is useful alone. A rung is not started until the
rung beneath it is green, and no rung introduces two new things at once.

Rung 0 already exists: `turboquant_chat` drives `LLMModel` / `LLMContext` /
`LLMChat` and generates text on demand. Nothing here rewrites it.

## The policy speaks RECTGTN

The policy does not emit an action. It emits a **plan**, in
[RECTGTN](https://github.com/taskweft/taskweft/blob/main/docs/rectgtn.md)
— Relationship-Enabled Capability-Temporal Goal-Task-Network, an HTN planning
model in JSON-LD, exposed through `plan` and `replan`.

That choice resolves a contradiction that would otherwise sink this.

**The contradiction.** A per-tick action is one to three tokens. The published
`qwen38-mtp` finding is that speculative decoding needs long generations — under
roughly 400 output tokens the overhead can dominate. Our stage 0 measured +65.7%
at exactly 400 tokens, on the boundary. So a per-tick token-sized policy is the
regime where MTP is worth least, and where per-call latency is worst amortised.

**The resolution.** An HTN plan is a long generation that covers *many* ticks.
Generation lands in the regime MTP is good at; execution of the resulting plan
costs no inference at all. One 2 s plan spanning 40 ticks is 50 ms/tick
amortised, and the tick loop never blocks on a model.

| | per-tick action | RECTGTN plan |
|---|---|---|
| tokens per inference | 1–3 | hundreds |
| inferences per tick | 1 | ~0 (amortised) |
| MTP regime | worst | best |
| recovery | ad-hoc | `replan` |

**Recovery is native.** "If a policy takes too long it has to recover" is
`replan`. And because actions carry `"duration": "<ISO 8601>"` and plan responses
return a `temporal` block with `start`/`end`/`total` per step, the executor
already knows when a step *should* have finished. Deadline detection is a
property of the plan, not a bolted-on timer: the step overruns its temporal
block, the executor fires `replan`. Recovery becomes a first-class transition
rather than an error path.

## Teaching the model RECTGTN

Three layers, each falsifiable, in increasing order of desperation.

**1. Constrain, do not hope.** `priv/schemas/rectgtn_domain.schema.json`
(309 lines; required keys `@type` and `name`) converts to GBNF through
`common/json-schema-to-grammar.cpp`, already in our tree. llama.cpp exposes this
as `--json-schema` on the server and as `llama_sampler_init_grammar` in the C
API — the latter matters because `LLMChat` builds its own sampler chain in
`llm_chat.cpp` and can add a grammar sampler in-process. Under a grammar,
syntactically invalid RECTGTN is *impossible*, not merely unlikely. Prompting a
model to "please emit valid JSON" is the thing this replaces.

**2. Few-shot for sense.** The grammar guarantees shape, never meaning. A
grammar-valid plan can still refill a lantern that does not exist. The worked
examples from the RECTGTN doc — simple calls, goal methods, a capability guard —
go in the prompt to carry semantics.

**3. Validate, then replan.** Schema-validate every emitted plan before
executing it. This doubles as the negative control: **if layer 1 is correct,
validation should never fail.** A validation failure is therefore real signal —
either the grammar is wrong or the schema drifted — and not a check that quietly
passes forever. Log the rate; a gate that has never failed is certifying
nothing.

Note the ordering is deliberate. Layer 3 catching things routinely means layer 1
is broken, and the fix belongs in the grammar, not in a retry loop.

## The scenarios

Two, each stressing a different half of RECTGTN. A scenario that only exercised
task decomposition would be testing HTN, not RECTGTN — the **R** and the **T**
have to be load-bearing or we are just measuring JSON generation.

### Distinctness

A web search for realtime LLM-policy benchmarks returns fighting games
(Street-Fighter), high-frequency trading (HFTBench), arcade/general video game
play (GVGAI-LLM), real-time strategy (SC2Arena), and the classic normalised
suites (Atari 100k, Procgen). Both scenarios below are deliberately none of
those. In each, the obstacle is **authority and timing**, not reflex, market
prediction, or unit micro. Neither is a re-skin of a published environment.

### Scenario A — "Night Shift" (relationship/capability dominant)

A facility across a shift. The policy is a coordinator, not an actor: it cannot
do the work itself, only route it.

- **Entities** hold capabilities (`HAS_CAPABILITY`) and stand in relations —
  `SUPERVISOR_OF`, `DELEGATED_TO`, `IS_MEMBER_OF`, `CAN_ENTER`.
- **Jobs** arrive requiring a capability, and often no *available* worker holds
  it. The plan must delegate, escalate to a supervisor, or route around a
  locked area — the ReBAC guard is the puzzle.
- **Temporal**: every job has a duration; the shift ends. Work not finished
  scores nothing.
- **Disruption**: a worker goes offline mid-plan, invalidating a delegation.
  The plan's remaining steps become unsatisfiable and `replan` must fire.

This is the scenario that would break a plain HTN planner: the hard part is not
decomposition, it is that permission changes underneath a valid plan.

### Scenario B — "Tide Lock" (temporal dominant)

A canal staircase where passage windows open and close on a tide schedule.

- **Vessels** queue, each with a draught; `CAN_ENTER` guards which basins admit
  which draughts at the current level.
- **Temporal is the whole problem**: each lock cycle has a fixed duration and
  windows close. A plan that is correct but late is worthless, which makes the
  `temporal` block's `start`/`end`/`total` the primary signal rather than
  decoration.
- **Disruption**: a cycle overruns, cascading every downstream window.

Where Night Shift perturbs *who may act*, Tide Lock perturbs *when*. Together
they cover both halves of the acronym.

## Normalisation

The standard is the human-normalised score,
`HNS = (agent − random) / (reference − random)`, as used across Atari 100k, and
reported as an **interquartile mean over seeds** rather than a mean, because a
mean over few seeds is dominated by outliers.

`reference` here is **not** a human. It is a scripted greedy policy — earliest
feasible assignment for Night Shift, earliest feasible window for Tide Lock.
Greedy is not optimal under either ruleset, so it is a strong reference and not
a ceiling, and an agent may legitimately exceed `1.0`. Saying so is the point;
calling it "optimal" or "human" would be exactly the unfalsifiable phrasing that
hides a weak result.

Both ends are exact, deterministic, and cost microseconds:

| baseline | policy | role |
|---|---|---|
| `random` | uniform over legal actions | floor |
| `reference` | scripted greedy | the 1.0 point |

Report per configuration: HNS interquartile mean over ≥ 10 seeds, raw return,
**deadline-miss rate**, **replan count**, and the floor in the same table. A
number without its baseline beside it is not a measurement.

## The ladder

| rung | adds | question it answers | still absent |
|---|---|---|---|
| 0 | *(exists)* chat, human waits | does on-device generation work | everything below |
| 1 | wall-clock deadline + `cancel()` | can we abort cleanly and fall back | grammar, env, learning |
| 2 | grammar-constrained RECTGTN | can the model emit a valid plan at all | env, learning |
| 3 | executor + `temporal` deadline detection | can a plan be run and overruns caught | env, learning |
| 4 | scenario + score + baselines | is the policy better than random | learning |
| 5 | `replan` under disruption | does it recover, and at what cost | learning |
| 6 | reward logging, offline traces | is there signal worth learning from | online updates |
| 7 | online policy updates | does it improve in play | — |

**Rung 1 needs no new inference work.** `LLMChat::cancel()` is already an
"Erlang-style exit signal … checked at every token boundary", so the abort path
exists; rung 1 only supplies the deadline that fires it and the fallback to fall
back to. Recovery is built first, not last — if a late policy cannot be
survived, no rung above it matters.

**Rung 2 is a validity gate, not a quality one.** It asks only whether the
grammar produces schema-valid RECTGTN, measured as a validation-failure rate
that should be zero.

**Rung 5 is where MTP is finally worth measuring**, because that is the first
rung generating plans under time pressure with a real recovery cost. Three arms,
same seeds, same budget: spec off; `--spec-type draft-mtp --spec-draft-n-max 2`;
and the same gated with `--spec-draft-p-min 0.60`. Report p95/p99 plan latency
and deadline-miss rate, not mean throughput — a deadline is missed by the tail.

## Sources

- [RECTGTN specification](https://github.com/taskweft/taskweft/blob/main/docs/rectgtn.md)
- [Atari 100k benchmark and human-normalised score](https://www.emergentmind.com/topics/atari-100k-benchmark)
- [Deep RL at the Edge of the Statistical Precipice — IQM over few seeds](https://arxiv.org/pdf/2108.13264)
- [Real-Time Reasoning Agents in Evolving Environments](https://arxiv.org/pdf/2511.04898)
- [Win Fast or Lose Slow: latency-sensitive LLM decisions](https://arxiv.org/pdf/2505.19481)
- [GVGAI-LLM: LLM agents are orders of magnitude slower than symbolic search](https://arxiv.org/pdf/2508.08501)
