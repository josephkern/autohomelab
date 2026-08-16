# Standard suite — runbooks/Inferact/Qwen3.8-27B-NVFP4/baseline.sh
- date: 2026-08-15T17:06:32Z    config_hash: 92de8fb3    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=off: `gsm8k=97.0`
    - general [mmlu] limit=100 think=on: `mmlu=82.61`
    - resistant [mmlu_pro] limit=100 think=off: `mmlu_pro=67.79`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 10.34 | 37.49 | 68.92 | 116.63 | 177.34 |
| coder(4096/1024) | 12.62 | 32.21 | 54.65 | 82.98 | 102.02 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
