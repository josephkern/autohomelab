# Standard suite — runbooks/unsloth/Qwen3.8-27B-NVFP4/baseline.sh
- date: 2026-08-18T09:29:22Z    config_hash: 8cfcfcac    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=off: `gsm8k=95.0`
    - general [mmlu] limit=100 think=on: `mmlu=79.89`
    - resistant [mmlu_pro] limit=100 think=off: `mmlu_pro=70.43`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 13.6 | 45.03 | 77.86 | 136.36 | 205.42 |
| coder(4096/1024) | 14.23 | 40.54 | 73.13 | 102.83 | 137.32 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
