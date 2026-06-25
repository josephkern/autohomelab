# Standard suite — runbooks/unsloth/Qwen3.6-27B-NVFP4/baseline.sh
- date: 2026-06-25T04:36:46Z    config_hash: c8b4b165    eval cap: 100
- **Gate 1 functional (smoke): FAIL**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=off: `gsm8k=98.0`
    - general [mmlu] limit=100 think=on: `mmlu=84.26`
    - resistant [mmlu_pro] limit=100 think=off: `mmlu_pro=71.64`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 12.1 | 41.54 | 72.71 | 122.61 | 192.34 |
| coder(4096/1024) | 22.12 | 43.35 | 67.09 | 82.08 | 116.47 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
