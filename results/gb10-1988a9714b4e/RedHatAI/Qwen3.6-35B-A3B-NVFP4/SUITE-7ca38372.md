# Standard suite — runbooks/RedHatAI/Qwen3.6-35B-A3B-NVFP4/20260704_v0.24.0_baseline.sh
- date: 2026-07-04T18:58:52Z    config_hash: 7ca38372    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=off: `gsm8k=98.0`
    - general [mmlu] limit=100 think=on: `mmlu=82.82`
    - resistant [mmlu_pro] limit=100 think=off: `mmlu_pro=68.21`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 55.52 | 151.45 | 234 | 337.66 | 472.99 |
| coder(4096/1024) | 57.55 | 150.09 | 222.04 | 299.6 | 398.35 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
