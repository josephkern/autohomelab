// dgx-settings-research — multi-agent research loop that mines the best-known vLLM serving
// settings for DGX/GB10 (sm_121), adversarially verifies them for our pinned stack, and emits a
// ranked candidate queue for the EMPIRICAL tuning loop (run_experiment.sh) to arbitrate.
//
// Research finds CANDIDATES; the empirical loop decides WINNERS (nothing is adopted until it beats
// the best config on real c16 tok/s). Online advice is frequently wrong for this exact box/version
// (e.g. "cu130-nightly is newer" → it was 0.19.2-dev), so every candidate is version/sm_121 vetted.
//
// Launch (after review):  Workflow({ scriptPath: "research/dgx-settings-research.workflow.js" })

export const meta = {
  name: 'dgx-settings-research',
  description: 'Research + verify best-known vLLM serving settings for DGX/GB10 (sm_121); emit a ranked candidate queue',
  phases: [
    { title: 'Sweep',      detail: 'parallel readers: NVIDIA / vLLM GitHub / community / per-knob' },
    { title: 'Verify',     detail: 'adversarially verify each candidate for v0.22.0 + sm_121' },
    { title: 'Synthesize', detail: 'dedup, drop already-tested, rank into an experiment queue' },
  ],
}

const CTX = `
TARGET: NVIDIA GB10 (DGX Spark family), compute capability sm_121, aarch64, CUDA 13.0, 128GB UNIFIED memory (~273 GB/s).
BACKEND: vLLM v0.22.0 pinned by digest (torch 2.11.0+cu130). Models: RedHatAI NVFP4 (compressed-tensors W4A4), dense (Qwen3-8B-NVFP4) + MoE.
OBJECTIVE: MAXIMIZE serving THROUGHPUT (output tokens/sec at concurrency 1/16/32 via GuideLLM). NOT accuracy/quality, NOT latency-only.
ALREADY TESTED on our box (do NOT re-propose): native NVFP4 W4A4 [drop --linear-backend marlin] = KEEP (+6.4% c16); --kv-cache-dtype fp8_e4m3 = CRASH (c16 deadlock); --async-scheduling and --attention-backend FLASHINFER = within ±3% noise.
HARD RULES: only settings valid for vLLM v0.22.0 on sm_121 count. FLAG version-specific or stale advice. Nightly/snapshot tags drift and mislead. Prefer primary sources (NVIDIA, vLLM). Always give source URLs + the vLLM version the advice applies to.
`

const CANDIDATE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['candidates'],
  properties: { candidates: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['flag', 'value', 'rationale', 'confidence'],
    properties: {
      flag: { type: 'string', description: 'vLLM serve flag or env var, e.g. --max-num-batched-tokens' },
      value: { type: 'string' },
      rationale: { type: 'string', description: 'why it should raise throughput on sm_121' },
      source_url: { type: 'string' },
      vllm_scope: { type: 'string', description: 'vLLM version(s) the advice applies to' },
      sm121_specific: { type: 'boolean' },
      confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    },
  } } },
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reason'],
  properties: {
    verdict: { type: 'string', enum: ['applicable', 'inapplicable', 'uncertain'] },
    reason: { type: 'string' },
    valid_for_v0_22: { type: 'boolean' },
    corroborating_sources: { type: 'array', items: { type: 'string' } },
  },
}

const QUEUE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['queue'],
  properties: { queue: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['slug', 'change', 'expected_effect', 'risk'],
    properties: {
      slug: { type: 'string', description: 'kebab slug for new_variant.sh, e.g. batched-tokens-16k' },
      change: { type: 'string', description: 'exact flag/env delta to apply to the current best runbook' },
      expected_effect: { type: 'string', description: 'expected c16/c32 tok/s effect' },
      risk: { type: 'string', description: 'crash/instability risk on sm_121' },
      provenance: { type: 'string' },
    },
  } } },
}

const SOURCES = [
  { key: 'nvidia', prompt: `Search NVIDIA PRIMARY sources (developer.nvidia.com blogs + forums, DGX Spark docs, NGC notes, NVIDIA dev blog perf posts) for recommended vLLM serving flags/env to maximize throughput on GB10/sm_121. ${CTX}` },
  { key: 'vllm-gh', prompt: `Search the vLLM project (the DGX Spark blog, GitHub issues/PRs/discussions, recipes) for sm_121/NVFP4 throughput flags, kernel/backend recommendations, and known-good vs known-bad combos. Read actual issues/commits. ${CTX}` },
  { key: 'community', prompt: `Search community repos/blogs/HF model cards (e.g. adadrag/qwen3.5-dgx-spark, nologik/vllm-dgx-spark, elevata, Reddit/forums) for WORKING vLLM throughput configs on DGX Spark, with the exact flags they used. ${CTX}` },
  { key: 'spark-arena', prompt: `Read the Spark Arena project — the GB10/DGX-Spark community benchmark leaderboard (spark-arena.com/leaderboard) and its recipe repos github.com/eugr/spark-vllm-docker (per-model serving recipes under recipes/) + github.com/eugr/llama-benchy (the benchmark harness) + github.com/spark-arena/sparkrun. Extract the EXACT vLLM serve recipe for the target model if present (flags, quantization, max-model-len, gpu-memory-utilization, kv-cache-dtype, tensor/pipeline-parallel, moe/attention backend, image, any model-specific chat-template/mod patches), plus any cross-model sm_121 knob patterns. NOTE the leaderboard ranks PERFORMANCE ONLY (llama-benchy: prompt+gen tok/s, peak t/s, TTFR/TTFT, decode@concurrency; default pp=2048/tg=32) — no accuracy/quality and the leaderboard UI does not expose the serve config, so the value is in the recipe repos, not the rankings. Also note its workload differs from ours (GuideLLM chat 512/256 + coder 4096/1024) so tok/s are not directly comparable. ${CTX}` },
  { key: 'knobs', prompt: `For EACH vLLM serving knob — linear-backend, moe-backend, attention-backend, kv-cache-dtype, max-num-batched-tokens, max-num-seqs, gpu-memory-utilization, async-scheduling, cudagraph sizes, speculative_config, and env vars (VLLM_*, FLASHINFER_*) — find what's recommended for sm_121 NVFP4 THROUGHPUT and any sm_121-specific caveats. ${CTX}` },
]

phase('Sweep')
const swept = (await parallel(SOURCES.map(s => () =>
  agent(s.prompt, { label: `sweep:${s.key}`, phase: 'Sweep', schema: CANDIDATE_SCHEMA, agentType: 'general-purpose' })
))).filter(Boolean).flatMap(r => r.candidates || [])

// dedup by flag=value
const seen = new Set(), uniq = []
for (const c of swept) { const k = `${c.flag}=${c.value}`; if (!seen.has(k)) { seen.add(k); uniq.push(c) } }
log(`swept ${swept.length} candidate settings → ${uniq.length} unique`)

phase('Verify')
const verified = (await parallel(uniq.map(c => () =>
  agent(`Adversarially verify this vLLM setting for GB10 sm_121 + vLLM v0.22.0. Try to REFUTE it; default to "uncertain" unless there is solid v0.22.0/sm_121 evidence it helps throughput and is stable. Candidate: ${JSON.stringify(c)}. ${CTX}`,
    { label: `verify:${c.flag}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: 'general-purpose' })
    .then(v => ({ ...c, ...v }))
))).filter(Boolean)
const applicable = verified.filter(v => v.verdict === 'applicable')
log(`verified ${verified.length} → ${applicable.length} applicable for v0.22.0/sm_121`)

phase('Synthesize')
const queue = await agent(
  `Build a RANKED experiment queue of vLLM settings to try on our empirical tok/s loop, applied to the current best runbook (native NVFP4 W4A4, v0.22.0). EXCLUDE anything already tested (native-fp4 KEEP, fp8-kv CRASH, async-scheduling + flashinfer NOISE). Rank by expected c16/c32 gain vs sm_121 stability risk. Verified-applicable candidates: ${JSON.stringify(applicable)}. ${CTX}`,
  { phase: 'Synthesize', schema: QUEUE_SCHEMA })

return { swept: swept.length, unique: uniq.length, applicable: applicable.length, queue: queue.queue }
