# Goals

Draft runbooks and build benchmarks for different models and settings on a single node Dell Pro Max GB10.

## Materials

1. Docker
2. vllm
3. litellm
4. GuideLLM
5. `uv` pythong package manager
6. Huggingface downloader (called via `uvx hf`)

## Rules

1. Reproducability is very important. Prefer pinned releases to nightlies or release tags. (a release tag is fine as a starting point if used, but pin the release of the tag directly
2. For now, the benchmarking will be limited to tok/s at 1, 4, 8, 16, 32 concurrant sessions. Benchmarking will be completed through GuideLLM. 
3. Log book entries need all current drivers, firmware, and software versions used in the benchmark.
4. Any helper scripts should be either `bash` (for interacting with system services), or `python` using only `uv` or `uvx` in a venv.
5. .env will be ommited from git.
6. we will setup a github repo, I you may utlize all features for management, tickets, etc. Setup what you think is appropriate to track results and research notes. You may also setup a wiki, etc.
7. You will setup something like https://github.com/karpathy/autoresearch program.md and build appropriate tooling for using tok/s as your replcement for val_bpb. Read this repo before deciding on how to setup github.
8. Remember, this is supposed to be a repeatable process


## Directory Structure
README.md
CLAUDE.md -> AGENTS.md
AGENTS.md
.env

docs/
runbooks/
    <HFName>/
    <HFModelName>/
        HFName_ModelName_Model_Card.md
        BASLINE_LLVM_HFNAME_HFMODELNAME.sh 
        20260613_LLVM_HFNAME_HFMODELNAME_TUNED.sh
        benchmarks/
            HFName_HFModelName_Benchmark_Logbook.md
            data/
scripts/
    <general purpose scripts>

launchers/
    symlinks -> .sh files in runbooks

source/
    .gitkeep

