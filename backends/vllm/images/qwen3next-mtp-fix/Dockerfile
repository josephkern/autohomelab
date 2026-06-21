# Patched vLLM image — unblocks qwen3_next MTP speculative decoding on NVFP4 (ModelOpt) checkpoints
# on DGX Spark / GB10 (sm_121). Two image-side patches (the checkpoint-side patch #2 is applied
# separately by scripts/patch_qwen3next_mtp_ignore.py). Source: vLLM issue #35031, @alkari's
# DGX-Spark report (same GB10 + nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4). Everything else is the
# pinned 0.23.0 image byte-for-byte.
#
#   docker build -t vllm-openai:0.23.0-qwen3nextmtp-fix backends/vllm/images/qwen3next-mtp-fix
FROM vllm/vllm-openai@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f

# Patch #1 — vLLM #35031: qwen3_next_mtp.py packed_modules_mapping had the wrong gate_up_proj split
# ("up_proj","down_proj" instead of "gate_proj","up_proj") → AssertionError loading the fused MTP MLP.
RUN F=/usr/local/lib/python3.12/dist-packages/vllm/model_executor/models/qwen3_next_mtp.py && \
    sed -i 's/"gate_up_proj": \["up_proj", "down_proj"\]/"gate_up_proj": ["gate_proj", "up_proj"]/' "$F" && \
    grep -q '"gate_up_proj": \["gate_proj", "up_proj"\]' "$F" || (echo "PATCH#1 FAILED" && exit 1)

# Patch #3 — DGX Spark (unified memory): MTP init triggers a 2nd nvmlShutdown() → NVML_ERROR_UNINITIALIZED,
# which vLLM's bundled pynvml._nvmlCheckReturn() raises and aborts engine init. Tolerate it.
RUN P=/usr/local/lib/python3.12/dist-packages/vllm/third_party/pynvml.py && \
    python3 - "$P" <<'PY' && grep -q 'NVML_ERROR_UNINITIALIZED:' "$P" || (echo "PATCH#3 FAILED" && exit 1)
import sys
p=sys.argv[1]; s=open(p).read()
old="def _nvmlCheckReturn(ret):\n    if (ret != NVML_SUCCESS):\n        raise NVMLError(ret)\n    return ret"
new="def _nvmlCheckReturn(ret):\n    if (ret != NVML_SUCCESS):\n        if ret == NVML_ERROR_UNINITIALIZED:\n            return None\n        raise NVMLError(ret)\n    return ret"
assert old in s, "expected _nvmlCheckReturn body not found"
open(p,"w").write(s.replace(old,new,1))
PY
