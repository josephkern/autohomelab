# DeepSeek-V4-Flash (antirez q2-imatrix GGUF) on ds4 "DwarfStar" — GB10 node #1

Host-process backend (antirez/ds4), NOT vLLM — no adapter/image.lock; the serve config is
`launchers/DS4-antirez_DeepSeek-V4-Flash_q2-imatrix.sh`, benched via `scripts/bench_ds4.sh`
(bench.sh sibling: same GuideLLM invocation + results.tsv schema, backend=`ds4@<sha>`).

## Session 20260721 — ds4 round 2: upstream 2026-07-18 drop (DSpark, session batching)

**Environment**
- Node: gb10-1988a9714b4e (GB10 DGX Spark, sm_121, 121.6 GiB unified LPDDR5X); driver 580.159.03, CUDA 13.0
- Backend: ds4 @ `efdadd4` (2026-07-20), built `make cuda-spark`; previous campaign was @ `80ebbc3` (2026-06-17)
- Model: `~/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf` (81 GiB, antirez/deepseek-v4-gguf)
- DSpark support GGUF: `DeepSeek-V4-Flash-DSpark-support.gguf` (5.6 GiB, same HF repo)
- GuideLLM 0.6.0, chat(512/256), seed 42, max-seconds 180, per-level isolation, **temperature 0 injected
  per-request** (ds4-server default is 1.0; DSpark engages on greedy requests only — all rows greedy)
- Memory plan at ctx=32768: KV 0.78 GiB + buffers + model = **81.8 GiB** (MLA KV is tiny)

**Context.** Upstream added: DSpark speculative decoding (DeepSeek's official draft model; replaces the
legacy one-stage MTP we benched ≈ no-gain), `--batched-session N` (GB10/single-GPU CUDA = *ordered exact
fallback*: concurrency + fairness, no native batched-kernel speedup), GLM 5.2 (no CUDA SSD streaming →
doesn't fit GB10; skipped). README now lists official GB10 q2 reference: 343.81 t/s prefill / 13.75 t/s decode.

**Harness note.** GuideLLM's default backend validation is `GET /health`, which ds4-server doesn't serve →
first 3 rows were harness errors (marked `discard`, HARNESS-ERROR in notes). bench_ds4.sh now validates via
`/v1/models`.

**Gate 1 (works), baseline serve:** smoke 3/3 PASS (chat, JSON, native DSML tool-call; reasoning n/a).
The "4We need to answer…" text in the smoke output is NOT a reasoning leak — smoke.sh concatenates
`content`+`reasoning_content` for its non-empty check; ds4 actually returns a clean separate
`reasoning_content` channel (verified 20260721: content `"8"`, reasoning in its own field).

**Runs** (results.tsv is the journal; keep/discard by N=3 median c1, chat shape):

| cfg | leg | median c1 tok/s | notes |
|---|---|---|---|
| baseline (target-only, ctx32768) | A | **17.96** | 17.51/17.98/17.96; smoke 3/3 PASS. Above README's 13.75 GB10 reference (that row is a 7047-tok ctx; ours is chat 512/256 + the 20260718 drop's kernel work) |
| dspark (--mtp dspark-support --dspark, conf 0.9) | B | 14.91 | 14.91/14.94/14.34; smoke 3/3 PASS. **DISCARD: −17% vs baseline** |
| batch4 (--batched-session 4) | C | 17.60 (c1) / 16.23 (c4 agg) | c1 17.54/17.66/17.60 (−2% vs baseline = noise); c4 15.75/16.23/18.07. Smoke 3/3 PASS. Load line: 4 resident sessions ≥4.12 GiB ctx buffers, shared prefill workspace 3.95 GiB, decode_coalesce 2ms |
| baseline single-session c4 | A′ | 16.95 (c4 agg) | 17.61/16.95/16.57 — same aggregate as batch4 within noise |

**Batched-session verdict (leg C): DISCARD as default (situational only).** As the README documents,
GB10/single-GPU CUDA runs the *ordered exact fallback* — and the numbers agree: c4 aggregate is flat
(16.23 batched vs 16.95 single-session ≈ noise), c1 unchanged, and per-request latency is *worse*
batched (mean 67–70s vs 56–57s at c4 chat) because 4-way shared decode drops every stream to ~4 t/s
(below reading speed) instead of one stream at full 17 t/s with queueing. TTFT max similar (36–53s
vs 48–61s). For this box's usage (primarily one interactive OWUI user) single-session is strictly
better; `BATCH=N` stays available in the launcher for genuine multi-user moments (N=2 → ~8.5 t/s
each may be acceptable).

**Campaign outcome.** The pre-existing launcher default (target-only, single-session, ctx 32768)
**remains the validated config** — no candidate cleared the >3% KEEP rule. Baseline c1 median
**17.96 tok/s** on ds4@efdadd4 (up from the ~13.75 t/s decode class of the pre-drop engine per the
README's own GB10 row — the 20260718 kernel/stability work is the real win of this update). Since
the kept config is *unchanged* from the previous campaign (only the engine build moved), no
accuracy gate was run: no numeric-risky knob was kept, smoke passed 3/3 on every serve. No full
1–32 sweep either: beyond c4 a single-GPU ordered-fallback host backend only measures queue depth,
not the engine. Server left up on :8000 (baseline config) for OWUI.

**DSpark verdict (leg B): DISCARD.** −17% on the synthetic chat objective, and the *best case* is no
better: a predictable code-continuation probe on the same serve (greedy DSpark vs near-greedy sampled
= target-only path) gave **14.2 vs 17.2 tok/s (−18%)**. On GB10 decode is LPDDR5X-bandwidth-bound;
the 3-stage draft (block 5, hidden-state capture on layers 40–42) + verification passes cost more
bandwidth than accepted tokens save. Matches the legacy one-stage MTP result (≈ no gain) — spec
decode in ds4 is not worth it on this box regardless of acceptance. Load-time detect line:
`stages=3 block=5 markov_rank=256 tensors=81`. Server emits no acceptance counters in the log, so
acceptance rate itself was not observable; the wall-clock verdict stands either way.

---

## 20260808 — round 3: engine update efdadd4 → b030961 (2026-08-05 upstream, 123 commits)

**Environment.** GB10 sm_121, driver 580.159.03, CUDA 13.0 (V13.0.88), host backend (no docker).
Engine ds4@b030961 (`b0309611041655f4e45671cfd9c9886aff161406`), built `make cuda-spark` — the
target now compiles **native `sm_121a` with `-DDS4_CUDA_HAVE_MXF4=1`** (FP4 matrix instructions)
and links the **vendored llama.cpp MMQ prefill tier** (`cuda/mmq/`, from the Entrpi batched-serving
fork). Model unchanged: DeepSeek-V4-Flash q2-imatrix GGUF (81 GiB, pre-0731 checkpoint — loads and
serves cleanly on the new engine; fixtures are versioned by checkpoint upstream). GuideLLM 0.6.0
via bench_ds4.sh, greedy (temp 0), chat(512/256), N=3, seed 42. Box quiesced (no vLLM serve; only
the idle OWUI app plane).

**What's in the drop (relevant to GB10):** decode-island CUDA graph capture for serial decode (ON
by default, `DS4_CUDA_DECODE_GRAPHS=0` disables; upstream measured +1–2% on a GB10 with this exact
model and byte-identical greedy output); SM121-specific attention work (token-tiled HMMA indexed
attention, heads8 occupancy pinning, register-blocked + MXFP4 indexer scoring); MMQ prefill tier +
aligned self-load repack (load log: iq2 44.34 GiB / q2k 28.22 GiB / q8 6.15 GiB aligned-repacked in
~20 s); DSpark greedy-identity correctness fixes (partial accepts replayed through ordinary decode);
new Flash **0731** checkpoint + native MXFP4 quant (~156 GB — exceeds GB10's 121.6 GiB, not
serveable resident here; q2 remains our fit) + 0731-specific DSpark support GGUF.

**Leg A — engine A/B, config unchanged (target-only, single-session, ctx 32768):**

| config | c1 runs | median | vs efdadd4 |
|---|---|---|---|
| engine-b030961 | 19.72 / 19.62 / 19.63 | **19.63** | **+9.3%** (17.96) → **KEEP** |

Smoke 3/3 PASS (chat, JSON, native DSML tool-call). TTFT (c1 chat mean) **2729 ms → 658 ms (−76%)**
— the MMQ prefill tier; request latency 15.79 s → 14.20 s. Spread is tight (0.10 t/s), well past
the >3% KEEP rule. Upstream's own refreshed `speed-bench/gb10.csv` (ds4-bench, 2048-tok ctx steps)
shows 18.05 t/s gen @2k / 825–900 t/s prefill — consistent with what we see on the server path.

**Not revisited this round (with reasons):** DSpark — the round-2 −17% was a bandwidth argument;
this drop's DSpark changes are correctness fixes that replay accepts through ordinary decode
(strictly more work), and our support GGUF is the pre-0731 one (0731 support must not pair with the
old model) → verdict stands. batched-session — the vendored fork tier is prefill-side; single-GPU
decode is still the ordered exact fallback, and the box is single-user → situational verdict stands.
MXFP4 model — doesn't fit (above). Decode-graph isolation (`DS4_CUDA_DECODE_GRAPHS=0`) not run: the
keep decision doesn't need the attribution split (upstream's own A/B attributes ~1–2 of the ~9 points
to graphs; the rest is the SM121a/native-arch + attention kernel work).

**Campaign outcome.** Launcher default config **unchanged and remains validated**; the engine build
moves to **ds4@b030961**, new baseline **c1 median 19.63 tok/s** (was 17.96 on efdadd4, 13.75-class
pre-July). Same rationale as round 2 for skipping the accuracy gate: no serving knob changed, greedy
smoke passes, and the decode-graph path is documented byte-identical upstream. Server left up on
:8000 (baseline config) for OWUI. Old binary parked at `/tmp/ds4-server-efdadd4` (session-scoped;
rebuild from git for a true rollback).

---

## 20260808 — round 3b: Flash 0731 checkpoint refresh (q2-imatrix) — DISCARD

**Candidate.** `DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf`
(82.7 GB, antirez/deepseek-v4-gguf `ds4f-q2` target — same quant recipe as our validated file, new
DeepSeek "0731" checkpoint). Engine held fixed at ds4@b030961. This is a MODEL change, so unlike
rounds 2–3 the quality gate ran: matched same-session pairs, gsm8k 5-shot LIMIT=100, greedy
(temp 0), GEN_TOKS=4096, chat endpoint (THINK=off harness path; ds4 has no server-side thinking
toggle — reasoning streams to `reasoning_content`, lm-eval scores `content`), CONC=4,
tokenizer deepseek-ai/DeepSeek-V4-Flash via eval.sh's new `TOKENIZER` env (harness fix this
round: the ds4 stub's MODEL is a journal identity, not a resolvable HF repo).

| leg | c1 (N=3 median) | gsm8k strict | gsm8k flexible |
|---|---|---|---|
| pre-0731 (validated) | 19.63 | **76.0** | **99.0** |
| 0731 refresh | 19.61 (19.68/19.61/19.55) | 60.0 | 82.0 |

**Verdict: DISCARD.** Throughput identical (same recipe/size, as expected — the checkpoint doesn't
change the arithmetic), smoke 3/3 PASS, but quality is decisively worse: −16 strict / −17 flexible,
~3σ beyond the ±4–5 stderr. Flexible-extract dropping to 82 means ~18% of answers had no extractable
number at all — consistent with the 0731 checkpoint thinking much longer and hitting the 4096-token
cap before answering (one observed request spent 3650+ tokens still in reasoning; upstream also
notes behavioral quirks in the new checkpoint, e.g. b030961 "the new DS4F checkpoint struggles with
anchored [upto] edits"). **Caveat:** a GEN_TOKS=8192 matched re-pair would disambiguate "dumber"
from "chattier-and-truncated"; either way, at equal serving budget the old checkpoint wins, so the
default stands. 0731 GGUF kept on disk (`~/gguf/…-0731.gguf`) for a possible re-pair or a future
engine drop tuned for it.

**State after round 3b:** launcher default unchanged (pre-0731 q2-imatrix, ds4@b030961, c1 19.63);
pre-0731 model re-served on :8000 for OWUI. accuracy.tsv gains the two matched rows.

**20260808 addendum — CTX default 32768 → 65536 (user-directed, for pi.dev agent use).** MLA keeps
it cheap: context buffers 1053.75 → 1739.75 MiB (compressed_kv_rows 8194 → 16386; raw rows
unchanged — sized to the prefill chunk, not ctx). Smoke 3/3 PASS; single c1 sanity 19.44 (vs 19.63
N=3 median at 32K = noise; short-context decode unaffected by the allocation, and long-context
taper ~18→14 t/s across 2K→64K per upstream gb10.csv applies as contexts actually fill). The ds4
model is also now registered in pi's `~/.pi/agent/models.json` (id deepseek-v4-flash, 64K window,
8K gen cap) alongside the vLLM 35B — the two share :8000, only one live at a time.

---

## Round 4 — 20260809 — **DSpark PROMOTED** (engine `ds4@84cc882`, +7.0% c1, quality neutral)

Triggered by 32 upstream commits since the round-3 pin `b030961`, notably
`0e89a0e dspark: commit accepted verifier state directly` (ds4.c +135) and
`84cc882 rocm: enable DSpark speculative decoding` (the feature maturing across a third backend).
Also landed: server-side client-disconnect cancellation (`e9ded97`/`8a703b6` — relevant, GuideLLM
cancels at stage end) and tool-call recovery / OpenAI tool-schema spelling (`0ead8a8`/`3196149`,
Gate-1 surface). Rebuilt with `make cuda-spark` (sm_121a, clean).

**PROVENANCE CORRECTION.** Two things the earlier record implied that are wrong:
`--dspark-confidence` is **not** a new flag — it existed at `b030961` with the same 0.7 CUDA
default. And the DSpark DISCARD was **round 1** (20260721, engine `efdadd4`): c1 median 14.91 vs a
17.96 baseline = −17%, measured at confidence **0.9**, not the default. Round 3 never re-tested
DSpark; it carried round 1's verdict forward. **Before this round, DSpark had never been measured
at its default threshold on any engine we've pinned.**

### Gate 3 — c1, N=3 median, greedy, same-session target-only base **19.27**

| candidate | c1 | Δ | per-run spread |
|---|---|---|---|
| target-only baseline | 19.27 | — | 0.05% |
| `--dspark-strict` (control) | 19.30 | +0.2% → discard | 0.2% |
| DSpark conf 0.0 | 20.50 | +6.4% | — |
| DSpark conf 0.3 | 20.52 | +6.5% | 0.4% |
| DSpark conf 0.5 | 21.56 | +11.9% | **7.2%** |
| **DSpark conf 0.7 (default) — WINNER** | **20.61** | **+7.0%** | 2.6% |
| DSpark conf 0.85 | 20.50 | +6.4% | 4.9% |

1. **The `--dspark-strict` control at +0.2% is what makes this trustworthy**: loading the DSpark
   support GGUF while keeping target-only decode costs nothing, so the whole gain is speculation.
2. **The confidence axis is FLAT.** Four settings land within 0.11 tok/s (20.50 / 20.52 / 20.61 /
   20.50). DSpark configs are **10–100× noisier** than target-only decode (acceptance depends on
   generated content; target-only is fixed work per token) — c05's runs spanned 20.28–21.75. Its
   21.56 median is therefore most likely a **noise excursion, not a peak**; four identical neighbours
   are the stronger evidence. → take the default, carry no extra flag.
3. **Attribution: the engine, not the threshold.** At a near-identical threshold to round 1
   (0.85 vs 0.9) the result moved **−17% → +6.4%**, a ~24-point swing confidence cannot explain.

### Gate 2 — matched pair, SAME SESSION (mandatory: DSpark is not greedy-lossless)

| config | gsm8k strict | flexible |
|---|---|---|
| target-only | 74.0 | 97.0 |
| **DSpark @ 0.7** | **74.0** | 98.0 |

`LIMIT=100`, think-off, `TOKENIZER=deepseek-ai/DeepSeek-V4-Flash`. **Strict-match identical.** The
divergence upstream documents is real in principle but costs nothing measurable here — and this is
the same gate that correctly killed the 0731 checkpoint at 76→60, so it has demonstrated teeth.
Note the same-session target-only leg came in at **74.0 vs round 3b's stored 76.0** on an identical
GGUF+config: a 2-point cross-session drift, wider than the ~1 pt AGENTS.md records for mmlu, and
exactly why the matched pair was worth the extra hour instead of comparing against the stored value.

Gate 1: smoke 3/3 PASS on every DSpark leg (the queue smoke-gates each candidate).

### PROMOTED: `DSPARK=1` is now the launcher default

⚠️ **The +7% applies to GREEDY requests only.** Upstream: "Sampled decoding does not use DSpark
proposals." Benchmarks pin `temp=0` (DSpark's best case), so typical OWUI chat at temp>0 will see
**no** speedup; the win lands on agent/tool/structured traffic. Enabled by default anyway — no
measured downside, and it costs one extra ~6 GB support GGUF (peak ~110 GB used of 121). Disable
with `DSPARK= ./DS4-….sh`.

### Not run / follow-ups

- `--mtp-margin F` (verifier acceptance margin, default 3) — never swept; a plausible next axis.
- A higher-N (N≥7) 0.5-vs-0.7 head-to-head would settle whether 0.5 is real. Low prior given the
  four flat neighbours; skipped as a poor use of box time.
- DSpark × `--batched-session` interaction untested (batched was discarded solo in round 1).
