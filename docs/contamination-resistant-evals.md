# Contamination-resistant eval suite (Gate 2 upgrade)

Goal: harder-to-contaminate **capability** benchmarks for the "good" gate, one per category. (Throughput
is GuideLLM/Gate 3 and has no contamination concept.) Derived from a 2026-06 deep-research pass
(102 claims → 25 adversarially verified, 23 confirmed). **Keep `gsm8k`/`mmlu`/`mmlu_pro`/`aime` as the
fast in-loop reference**; these are the *resistant* tier you reach for when you want a cleaner signal.

## The suite

| Category | Pick | Mechanism | Runner | Integration |
|---|---|---|---|---|
| General/reasoning | **LiveBench** | time-gated monthly refresh + objective ground-truth grading (no LLM judge) | `scripts/eval_livebench.sh` | 🟢 `--api-base` flag |
| Tool-calling | **BFCL V4** | — (capability only; see caveat) | `scripts/eval_bfcl.sh` | 🟢 `bfcl --skip-server-setup` |
| Coding | **LiveCodeBench** | date-gated (per-problem release dates → score only post-cutoff) | `scripts/eval_livecodebench.sh` | 🟡 registry edit + sandbox |
| Math | **AIME** (kept) | recent contests; small-N variance | `eval.sh math` (aime24,aime25) | 🟢 lm-eval task |

Alternates: general → **BeyondBench** (algorithmically generated, >10¹⁵ space, never decays) / **MMLU-CF**
(closed test set). Coding gold-standard (heavy) → **SWE-bench Verified** (Docker, x86_64 → aarch64/GB10 friction).
Tool-calling heavier → **tau2-bench** (multi-turn, LiteLLM).

## Honest flags (the research was adversarial about its own picks)
- **BFCL is NOT contamination-resistant** — two such claims were *refuted* (votes 1-2, 0-3). Use it as a
  **capability** gate for tool-calling (the suite had none), not a contamination gate.
- **Time-gated picks decay.** LiveBench's public refresh lapsed (~2025-04) and LiveCodeBench is documented
  through v6/Apr-2025. Their resistance holds **only for problems postdating each model's training cutoff**.
  **Protocol every campaign:** (1) pull the newest release; (2) set the post-cutoff window per model
  (`--livebench-release-option`; LCB `compute_scores --start_date <model_cutoff>`). Older pools = contaminated.
- **Math gap:** no math-specific contamination-resistant benchmark survived verification (FrontierMath/HMMT/
  MathArena/PutnamBench all unverified) — hence keeping AIME. Open follow-up.
- BHI "healthiest benchmark" rankings (HLE, SimpleQA, SWE-bench-Verified, LiveCodeBench, ARC-AGI-2) measure
  discrimination/anti-saturation, **not** contamination directly.

## Status
All three runners are **v1, NOT yet end-to-end validated** — each needs a served model + (LiveBench/LCB) a
repo install under gitignored `source/`, and the score-parse is best-effort (tighten on first real run).
BFCL needs a model it has a handler for (our **Qwen3-8B → `Qwen/Qwen3-8B-FC`**; Nemotron-3-Super/gemma-4/
VibeThinker have none). Validation was deferred to avoid contending with the live VibeThinker/pi serve.

## Open follow-ups
- Validate all three end-to-end (serve Qwen3-8B for BFCL; clone+install LiveBench/LCB repos).
- Fill the **math** slot (dedicated research: FrontierMath access, AIME-2026 live, MathArena).
- Wire the runners into `suite.sh` as optional gates (currently standalone).
- Pin tool versions (`bfcl-eval`, LiveBench/LCB commits) for reproducibility.
</content>
