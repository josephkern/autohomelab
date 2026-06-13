# Research-loop candidate queue (run wf_c90cf209, 2026-06-13)

From `research/dgx-settings-research.workflow.js` against vLLM **v0.22.0** / GB10 sm_121.
Swept 41 → 40 unique → **11 verified-applicable** → ranked queue below. Each verified for
v0.22.0/sm_121; objective = throughput (c16/c32). Research proposes; the empirical loop
(`run_experiment.sh`) decides. Re-verify against 0.23.0 at transition.

## Ranked candidates (apply to the native-FP4 best, one change each)

1. **`max-num-batched-tokens-16384`** *(highest-confidence NEW lever, low risk)* — add
   `--max-num-batched-tokens 16384` (V1 online default is 8192). Lets chunked-prefill co-schedule
   more prefill alongside decodes under c16/c32 → modest single-digit % lift, flat at c1, tapers
   (bandwidth-bound). Fits memory (KV @ c32×8192 ≈ 37GB + weights ≈ 5GB under util 0.5).
2. **`gpu-mem-util-0point8`** *(enabler, low-med risk)* — `--gpu-memory-utilization 0.5 → 0.8`.
   KV already fits at c32, so standalone gain likely small; main value is headroom for #3. Unified
   pool shared with OS → raise gradually (0.7→0.8), watch metrics_sampler.
3. **`batched-tokens-32768`** *(diminishing-returns probe)* — `--max-num-batched-tokens 32768` WITH
   util 0.8; run only after #1 and #2 pass. Confirms whether 16384 was the knee.
4. **`max-num-seqs-guardrail-1024`** *(NO-OP guardrail)* — leave `--max-num-seqs` UNSET; confirm
   v0.22.0 resolves it to ~1024 on this GB10 (server context, ≥70GiB). **Do NOT adopt the DGX Spark
   blog's `--max-num-seqs 4`** — that's a latency recipe that would hard-cap the batch and collapse
   c16/c32. (We already don't set it → already correct.)
5. **`moe-backend-auto-vs-marlin`** *(MoE models only, medium risk)* — on the NVFP4 **MoE** runbook
   (Qwen3-Coder / Nemotron), test `--moe-backend auto` (native sm_12x b12x/cutedsl) vs `marlin`;
   could mirror the dense +6.4% native-over-marlin win. **Do NOT force `flashinfer_cutlass`**
   (errors on sm_120 NVFP4 MoE, issue #33333).

## Stale/anti-pattern advice the loop rejected (do NOT copy)

- `--max-num-batched-tokens 131072` (bjk110 SPARK) — from vLLM 0.17.0rc1 nightly tuned for a 122B
  MoE; wrong magnitude for a dense 8B.
- `--max-num-seqs 4` (DGX Spark blog) — single-stream/latency recipe on a drifting nightly tag;
  destroys the throughput objective.
- `--moe-backend marlin` hard-set (NVIDIA dgx-spark-playbooks) — nightly-aarch64 default; `auto`
  should pick the faster native path on Blackwell.

Cost of this run: 45 agents, ~1.08M tokens, ~22 min.
