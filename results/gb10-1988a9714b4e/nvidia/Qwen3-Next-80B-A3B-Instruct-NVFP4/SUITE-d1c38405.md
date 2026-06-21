# Standard suite — runbooks/nvidia/Qwen3-Next-80B-A3B-Instruct-NVFP4/20260621_mtp-n1_tuned.sh
- date: 2026-06-21T11:07:06Z    config_hash: d1c38405    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=on: `gsm8k=94.0`
    - resistant [mmlu_pro] limit=100 think=on: `mmlu_pro=71.29`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 50.81 | 127.66 | 185.3 | 266.74 | 362.54 |
| coder(4096/1024) | 50.68 | 112.89 | 158.4 | 196.38 | 210.7 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
