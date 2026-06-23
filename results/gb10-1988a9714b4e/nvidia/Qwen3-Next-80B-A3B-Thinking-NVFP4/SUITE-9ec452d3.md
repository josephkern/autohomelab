# Standard suite — runbooks/nvidia/Qwen3-Next-80B-A3B-Thinking-NVFP4/baseline.sh
- date: 2026-06-22T19:32:19Z    config_hash: 9ec452d3    eval cap: 100
- **Gate 1 functional (smoke): PASS**
- **Gate 2 quality:** general=error, resistant=error
    - general [mmlu] limit=100 think=on: `mmlu=84.32`
- **Gate 3 throughput (ok):** full sweep, tok/s

| shape | c1 | c4 | c8 | c16 | c32 |
|---|---|---|---|---|---|
| chat(512/256) | 42.3 | 121.47 | 176.55 | 256.85 | 361.92 |
| coder(4096/1024) | 49.33 | 107.34 | 165.2 | 219.15 | 248.59 |

Compare quality to the model card's recovery reference; throughput objective = median c16 (chat).
