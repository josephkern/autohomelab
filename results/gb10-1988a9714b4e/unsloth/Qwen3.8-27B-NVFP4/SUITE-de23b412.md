# Standard suite — runbooks/unsloth/Qwen3.8-27B-NVFP4/20260818_mtp-n3_tuned.sh
- date: 2026-08-18T20:58:37Z    config_hash: de23b412    eval cap: FULL
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=full think=off: `gsm8k=95.98`
    - resistant [mmlu_pro] limit=full think=off: `mmlu_pro=70.38`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 24.71 | 84.73 | 142.26 | 206.5 | 278.96 |
| coder(4096/1024) | 22.1 | 69.85 | 103.22 | 144.46 | 185.08 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
