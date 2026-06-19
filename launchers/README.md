# launchers/

Self-contained, executable `docker run` scripts — one per promoted `_final.sh` — that serve a
**canonical, fully-validated** vLLM config (passed all three gates: works / good / fast).

Each launcher inlines the **pinned image digest + model + revision + exact serving flags**, so it has
**no dependency** on this repo, `adapter.sh`, or `image.lock` — copy it to any GB10-class host with
Docker + the NVIDIA runtime and run it. They follow the hand-written `~/bin/docker-vllm-*.sh` house
style: `export VLLM_IMAGE / MODEL / MAX_MODEL_LEN` up top, flags inlined into the `docker run`, and
the container started **detached** (`docker run -d`).

```bash
./VLLM-23-WeiboAI_VibeThinker-3B.sh             # start the container detached (prints the container id)
docker logs -f  vllm-vibethinker-3b             # follow startup / serving logs
docker rm   -f  vllm-vibethinker-3b             # stop + remove the container
PORT=8001 NAME=foo ./VLLM-23-…​.sh               # override the published port / container name
HF_TOKEN=hf_… ./VLLM-23-…​.sh                    # set if weights aren't already in the HF cache
```

Serves the OpenAI-compatible API on `http://0.0.0.0:${PORT:-8000}/v1`. Weights load from the host HF
cache (`$HF_HOME` or `~/.cache/huggingface`); set `HF_TOKEN` to pull on first run. Each launcher first
`docker rm -f`s any prior container of the same `NAME`, so re-running replaces a running instance.

These are **generated** — don't hand-edit. Regenerate after promoting a new winner:

```bash
scripts/gen_launcher.sh runbooks/<org>/<model>/VLLM-23-…_final.sh        # one
scripts/gen_launcher.sh $(find runbooks -name 'VLLM-23-*_final.sh')      # all
```

The launcher serves the same image + model + flags as `backends/vllm/adapter.sh cmd_up()`, but is a
standalone `docker run -d` (no runbook/adapter sourcing) modeled on the `~/bin/docker-vllm-*.sh`
scripts — `--max-model-len` is hoisted into an exported `MAX_MODEL_LEN` for easy editing; flag order
is otherwise vLLM-insensitive.
</content>
