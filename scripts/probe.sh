#!/usr/bin/env bash
# probe.sh — capture this node's hardware/stack as DATA.
# Emits results/<node_fp>/node_profile.json and prints <node_fp> on stdout.
# No pipefail: hardware queries pipe into head/grep which close early (SIGPIPE) by design.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found (NVIDIA node required)" >&2; exit 1; }

q() { nvidia-smi --query-gpu="$1" --format=csv,noheader 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//'; }

GPU_NAME="$(q name)"
GPU_COUNT="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
COMPUTE_CAP="$(q compute_cap)"
DRIVER="$(q driver_version)"
VBIOS="$(q vbios_version)"
CUDA="$(nvidia-smi -q 2>/dev/null | grep -m1 'CUDA Version' | awk -F': ' '{print $2}' | tr -d ' ')"
ARCH="$(uname -m)"
KERNEL="$(uname -r)"
OS="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
SYS_RAM_MB="$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)"

# Unified-memory parts (e.g. GB10) report [N/A] for GPU memory. Fall back to the system pool.
GPU_MEM_RAW="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
if [[ "$GPU_MEM_RAW" =~ ^[0-9]+$ ]]; then
  MEM_KIND="dedicated"; GPU_MEM_MB="$GPU_MEM_RAW"; EFFECTIVE_MEM_MB="$GPU_MEM_RAW"
else
  MEM_KIND="unified";   GPU_MEM_MB="null";        EFFECTIVE_MEM_MB="$SYS_RAM_MB"
fi

# Stable fingerprint over hardware identity (not driver/firmware, which vary over time).
FP_INPUT="${GPU_NAME}|${GPU_COUNT}|${ARCH}|${COMPUTE_CAP}|${MEM_KIND}"
FP="$(printf '%s' "$FP_INPUT" | sha256sum | cut -c1-12)"
SLUG="$(printf '%s' "$GPU_NAME" | tr '[:upper:] ' '[:lower:]-' | sed 's/^nvidia-//;s/[^a-z0-9-]//g')"
NODE_FP="${SLUG}-${FP}"

OUT_DIR="$REPO_ROOT/results/$NODE_FP"
mkdir -p "$OUT_DIR"
PROBED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$OUT_DIR/node_profile.json" <<JSON
{
  "node_fp": "$NODE_FP",
  "probed_at": "$PROBED_AT",
  "gpu": {
    "name": "$GPU_NAME",
    "count": $GPU_COUNT,
    "compute_capability": "$COMPUTE_CAP",
    "memory_kind": "$MEM_KIND",
    "gpu_memory_mb": $GPU_MEM_MB,
    "effective_mem_mb": $EFFECTIVE_MEM_MB
  },
  "arch": "$ARCH",
  "system_ram_mb": $SYS_RAM_MB,
  "stack": {
    "driver": "$DRIVER",
    "cuda": "$CUDA",
    "vbios": "$VBIOS",
    "kernel": "$KERNEL",
    "os": "$OS"
  }
}
JSON

# Scaffold the per-box hardware narrative (only once; never clobber human notes).
NOTES="$OUT_DIR/node_notes.md"
if [ ! -f "$NOTES" ]; then
  cat > "$NOTES" <<NOTE
# Node notes — $NODE_FP

$GPU_NAME x$GPU_COUNT ($MEM_KIND memory), $ARCH. Driver $DRIVER, CUDA $CUDA, VBIOS $VBIOS.
Platform family: see docs/hardware/ for the shared platform reference.

## Observations (firmware quirks, thermals, anything explaining tok/s variance)
NOTE
fi

echo "wrote $OUT_DIR/node_profile.json" >&2
echo "$NODE_FP"
