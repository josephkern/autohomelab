#!/usr/bin/env bash
# build_llamacpp.sh — build ggml-org/llama.cpp with CUDA for GB10 (Grace-Blackwell, sm_121).
#
# One-time (or on-update) setup for the llama.cpp HOST-process backend — the GGUF sibling of the
# vLLM docker path. Unlike vLLM (pinned by image digest, AGENTS.md rule 1), llama.cpp is pinned by
# the GIT SHA this prints; bench_llamacpp.sh reads it back for the `backend=llamacpp@<sha>` column,
# so every result row records the exact engine build.
#
#   scripts/build_llamacpp.sh          # clone-or-update ~/code/llama.cpp, then build
#
# sm_121 is passed explicitly: CMake's native detection reads the GB10 as 12.1 but the CUDA 13.0
# toolkit needs the arch spelled out to emit sm_121 rather than falling back to a PTX-only build.
set -euo pipefail
SRC="${LCPP_DIR:-$HOME/code/llama.cpp}"

if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth 1 origin master && git -C "$SRC" reset --hard origin/master
else
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC"
fi
echo "=== llama.cpp sha: $(git -C "$SRC" rev-parse --short HEAD) ==="

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121 \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DLLAMA_BUILD_SERVER=ON

cmake --build "$SRC/build" --config Release -j 16 --target llama-server llama-cli llama-bench

echo "=== BUILD OK ==="
ls -la "$SRC/build/bin/llama-server" "$SRC/build/bin/llama-bench"
"$SRC/build/bin/llama-server" --version 2>&1 | head -5 || true
