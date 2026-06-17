# launchers/

Self-contained, executable `docker run` scripts — one per promoted `_final.sh` — that serve a
**canonical, fully-validated** vLLM config (passed all three gates: works / good / fast).

Each launcher inlines the **pinned image digest + model + revision + exact serving flags**, so it has
**no dependency** on this repo, `adapter.sh`, or `image.lock` — copy it to any GB10-class host with
Docker + the NVIDIA runtime and run it.

```bash
./VLLM-23-WeiboAI_VibeThinker-3B.sh             # serve in the foreground; Ctrl-C stops + removes the container
PORT=8001 NAME=foo ./VLLM-23-…​.sh               # override the port / container name
HF_TOKEN=hf_… ./VLLM-23-…​.sh                    # set if weights aren't already in the HF cache
```

Serves the OpenAI-compatible API on `http://0.0.0.0:${PORT:-8000}/v1`. Weights load from the host HF
cache (`$HF_HOME` or `~/.cache/huggingface`); set `HF_TOKEN` to pull on first run.

These are **generated** — don't hand-edit. Regenerate after promoting a new winner:

```bash
scripts/gen_launcher.sh runbooks/<org>/<model>/VLLM-23-…_final.sh        # one
scripts/gen_launcher.sh $(find runbooks -name 'VLLM-23-*_final.sh')      # all
```

The launcher mirrors `backends/vllm/adapter.sh cmd_up()` exactly, except it runs **foreground** with
`--rm` (the adapter runs detached for benchmarking).
</content>
