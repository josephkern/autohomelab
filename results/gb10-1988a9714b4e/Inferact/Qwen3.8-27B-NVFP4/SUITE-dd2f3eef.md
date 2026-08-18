# Standard suite — runbooks/Inferact/Qwen3.8-27B-NVFP4/20260816_mtp-n3_tuned.sh
- date: 2026-08-17T19:48:25Z    config_hash: dd2f3eef    eval cap: FULL
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=full think=off: `gsm8k=95.45`
    - resistant [mmlu_pro] limit=full think=off: `mmlu_pro=66.81`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 17.15 | 67.08 | 109.73 | 171.12 | 214.33 |
| coder(4096/1024) | 24.06 | 65.95 | 70.88 | 68.88 | 256.19 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
