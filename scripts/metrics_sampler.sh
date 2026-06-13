#!/usr/bin/env bash
# metrics_sampler.sh <out.csv> [interval_s] — sample GPU power/temp/util to a CSV timeseries while
# a benchmark runs, so thermal/power state (a real tok/s confounder on GB10) is recorded and
# throttling-driven variance is visible. On GB10, power & temperature report correctly via NVML
# (GPU-domain only); memory is N/A (unified), so we also log system used memory as a proxy.
#
# Run in the background around a sweep:
#   scripts/metrics_sampler.sh bundle/gpu_metrics.csv 5 & SP=$!
#   ... benchmark ...
#   kill "$SP"
# Summarize with:  scripts/metrics_sampler.sh --summary bundle/gpu_metrics.csv
set -euo pipefail

if [ "${1:-}" = "--summary" ]; then
  csv="${2:?usage: --summary <csv>}"
  [ -f "$csv" ] || { echo "thermal=na"; exit 0; }
  awk -F',' 'NR>1{ if($3>maxt)maxt=$3; pw+=$2; n++ } END{ if(n)printf "thermal=%.0fC/%.0fW", maxt, pw/n; else printf "thermal=na" }' "$csv"
  echo; exit 0
fi

OUT="${1:?usage: metrics_sampler.sh <out.csv> [interval_s]}"
INT="${2:-5}"
echo "ts,power_w,temp_c,util_pct,sm_clock_mhz,sys_used_gb" > "$OUT"
while :; do
  read -r pw tc ut clk < <(nvidia-smi --query-gpu=power.draw,temperature.gpu,utilization.gpu,clocks.sm \
    --format=csv,noheader,nounits 2>/dev/null | head -1 | tr ',' ' ') || true
  used="$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f",(t-a)/1048576}' /proc/meminfo)"
  printf '%s,%s,%s,%s,%s,%s\n' "$(date -u +%H:%M:%S)" "${pw:-na}" "${tc:-na}" "${ut:-na}" "${clk:-na}" "$used" >> "$OUT"
  sleep "$INT"
done
