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

# --- Memory bandwidth (platform table) ---------------------------------------
# Peak theoretical DRAM/HBM bandwidth in GB/s, keyed on the exact `nvidia-smi
# --query-gpu=name` string. Consumed by the roofline check in
# docs/validity-contract.md section 4:
#   ceiling(level) = SAFETY * level * (mem_bw_gbs / bytes_per_token_GB)
# The probe does NOT measure bandwidth (a probe must never run a GPU workload on
# a box that may be serving), so this is a vendor SPEC figure and says so in
# `gpu.mem_bw_source`.
#
# RULE: emit `null` for any GPU not listed. A wrong bandwidth silently loosens or
# tightens a correctness bound on every future row; the contract SKIPS the check
# when the field is null/absent, which is strictly better than a plausible guess.
# Add a row only when you can confirm BOTH the exact nvidia-smi name string AND
# the vendor's published bandwidth for that exact SKU — SKUs of the same chip
# differ a lot (H100 SXM 3350 vs H100 PCIe 2039), which is why the key is the
# full name and not the compute capability. When in doubt, leave it out.
mem_bw_for_gpu() {
  case "$1" in
    # NVIDIA GB10 / DGX Spark reference board: 128 GB LPDDR5X, 256-bit @ 8533 MT/s.
    # Source: NVIDIA DGX Spark spec; see docs/hardware/gb10-dgx-spark.md.
    # Corroborated in-lab at 255 GB/s (93% of peak) — llama.cpp FF711 campaign 20260809.
    "NVIDIA GB10")                    echo 273  ;;
    # Datacenter parts — NVIDIA product-page specs, per exact SKU name.
    "NVIDIA H200")                    echo 4800 ;;  # HBM3e
    "NVIDIA H100 80GB HBM3")          echo 3350 ;;  # SXM5
    "NVIDIA H100 PCIe")               echo 2039 ;;  # HBM2e
    "NVIDIA A100-SXM4-80GB")          echo 2039 ;;
    "NVIDIA A100 80GB PCIe")          echo 1935 ;;
    "NVIDIA A100-SXM4-40GB")          echo 1555 ;;
    "NVIDIA A100-PCIE-40GB")          echo 1555 ;;
    "NVIDIA L40S")                    echo 864  ;;
    # Workstation / consumer — NVIDIA product-page specs.
    "NVIDIA GeForce RTX 5090")        echo 1792 ;;  # GDDR7, 512-bit
    "NVIDIA GeForce RTX 4090")        echo 1008 ;;  # GDDR6X, 384-bit
    "NVIDIA RTX 6000 Ada Generation") echo 960  ;;
    *)                                echo null ;;
  esac
}

MEM_BW="$(mem_bw_for_gpu "$GPU_NAME")"
if [ "$MEM_BW" = "null" ]; then
  MEM_BW_SRC="unknown - '$GPU_NAME' is not in the probe.sh platform table; the roofline check is SKIPPED (validity-contract section 4). Add a cited row to mem_bw_for_gpu() rather than guessing."
else
  MEM_BW_SRC="platform-table:scripts/probe.sh mem_bw_for_gpu() - vendor SPEC figure, NOT measured by this probe run."
fi
# Operator escape hatch for a known-good (e.g. locally measured) figure.
if [ -n "${AHL_MEM_BW_GBS:-}" ]; then
  if [[ "$AHL_MEM_BW_GBS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    MEM_BW="$AHL_MEM_BW_GBS"
    MEM_BW_SRC="env:AHL_MEM_BW_GBS=$AHL_MEM_BW_GBS - operator-supplied override; provenance is the operator's."
  else
    echo "probe.sh: ignoring non-numeric AHL_MEM_BW_GBS='$AHL_MEM_BW_GBS'" >&2
  fi
fi

# Stable fingerprint over hardware identity (not driver/firmware, which vary over time).
# DO NOT add fields to FP_INPUT — node_fp keys every row under results/. mem_bw_gbs is a
# derived platform constant, not hardware identity, and is deliberately NOT an input here.
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
    "effective_mem_mb": $EFFECTIVE_MEM_MB,
    "mem_bw_gbs": $MEM_BW,
    "mem_bw_source": "$MEM_BW_SRC"
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
Peak memory bandwidth: ${MEM_BW} GB/s — $MEM_BW_SRC

## Observations (firmware quirks, thermals, anything explaining tok/s variance)
NOTE
fi

echo "wrote $OUT_DIR/node_profile.json" >&2
echo "$NODE_FP"
