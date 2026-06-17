# Standard suite — runbooks/RedHatAI/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/20260616_mtp-n1_tuned.sh
- date: 2026-06-16T15:55:06Z    config_hash: 479fc3da    eval cap: FULL
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=error, resistant=ok
    - general [gsm8k] limit=full think=off: `gsm8k=59.36`
    - resistant [mmlu_pro] limit=full think=off: `mmlu_pro=74.16`
- **Gate 3 throughput (crash):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 22.44 | 52.53 | 69.52 | 93.68 | 120.52 |
| coder(4096/1024) | hang | na | na | na | na |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
