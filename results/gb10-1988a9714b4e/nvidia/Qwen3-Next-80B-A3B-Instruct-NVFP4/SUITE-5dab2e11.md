# Standard suite — runbooks/nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4/baseline.sh
- date: 2026-06-21T06:24:23Z    config_hash: 5dab2e11    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k,mmlu] limit=100 think=on: `gsm8k=96.0;mmlu=84.88`
    - resistant [mmlu_pro] limit=100 think=on: `mmlu_pro=71.93`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 38.99 | 112.45 | 166.8 | 237.15 | 322.22 |
| coder(4096/1024) | 38.39 | 96.09 | 127.64 | 167.83 | 167.38 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
