#!/usr/bin/env bash
# minimize_bundle.sh — turn a real (multi-MB, gitignored) GuideLLM 0.6.0 level JSON into a small
# committed fixture, keeping the exact field SHAPE the validity layer reads.
#
#   tests/tools/minimize_bundle.sh <src level_cN.json> <dst level_cN.json>
#
# Kept: .metadata, a trimmed .args (rate/max_seconds/profile/random_seed/processor/data), and
# .benchmarks[0] with only the metrics the layer needs + scheduler_state counters.
# Dropped: .benchmarks[0].requests (the per-request array — 99% of the bytes) and every
# `percentiles`/`pdf` block inside the kept metrics.
#
# Provenance for every fixture generated this way is recorded in tests/fixtures/PROVENANCE.md.
# Rerun this instead of hand-editing a fixture, so fixtures keep matching real GuideLLM output.
set -euo pipefail
SRC="${1:?usage: minimize_bundle.sh <src.json> <dst.json>}"
DST="${2:?usage: minimize_bundle.sh <src.json> <dst.json>}"
mkdir -p "$(dirname "$DST")"
jq 'def slim: if type=="object" then with_entries(select(.key|IN("percentiles","pdf")|not)) else . end;
{ metadata,
  args: { rate: .args.rate, max_seconds: .args.max_seconds, profile: .args.profile,
          random_seed: .args.random_seed, processor: .args.processor, data: .args.data },
  benchmarks: [ .benchmarks[0] | {
    type_, start_time, end_time, duration,
    metrics: (.metrics | {
      request_totals,
      output_tokens_per_second: (.output_tokens_per_second | map_values(slim)),
      request_concurrency:      (.request_concurrency      | map_values(slim)),
      output_token_count:       (.output_token_count       | map_values(slim)),
      prompt_token_count:       (.prompt_token_count       | map_values(slim)),
      requests_per_second:      (.requests_per_second      | map_values(slim)),
      request_latency:          (.request_latency          | map_values(slim)) }),
    scheduler_state: (.scheduler_state | { created_requests, processed_requests,
      successful_requests, errored_requests, cancelled_requests }) } ] }' "$SRC" > "$DST"
echo "$DST  ($(wc -c <"$DST") bytes)"
