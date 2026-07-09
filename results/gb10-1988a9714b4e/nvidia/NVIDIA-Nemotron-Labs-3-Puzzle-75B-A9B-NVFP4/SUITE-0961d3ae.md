# Standard suite — runbooks/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-NVFP4/baseline.sh
- date: 2026-07-09T04:59:23Z    config_hash: 0961d3ae    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=ok, resistant=ok
    - general [gsm8k] limit=100 think=off: `gsm8k=95.0`
    - general [mmlu] limit=100 think=on: `mmlu=83.51`
    - resistant [mmlu_pro] limit=100 think=off: `mmlu_pro=71.93`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 20.42 | 64.31 | 102.77 | 154.3 | 211.29 |
| coder(4096/1024) | 22.7 | 59.92 | 73.34 | 111.83 | 70.69 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
