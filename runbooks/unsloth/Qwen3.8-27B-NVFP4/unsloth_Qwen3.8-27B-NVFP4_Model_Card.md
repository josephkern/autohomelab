# unsloth/Qwen3.8-27B-NVFP4 — model card (autohomelab)

- HF id: unsloth/Qwen3.8-27B-NVFP4
- Revision (pinned): 7d6f8d4d72f56b92b3cdbf22f156b90e1bab0108
- Type: <general | reasoning | coder>   # drives eval suite: general→gsm8k+mmlu, coder→humaneval+mbpp
- Quantization: <e.g. NVFP4 (compressed-tensors W4A4)>
- Native context: <max_position_embeddings>
- Reasoning parser: <qwen3 | deepseek_r1 | nemotron_v3 | none>
- Tool-call parser: <hermes | qwen3_coder | llama3_json | glm47 | none>
- Recommended sampling: {"temperature":1.0,"top_p":0.95,"top_k":20}
- Quality reference: <recovery % / published eval scores from the HF card's Evaluation section>

## Notes
<intended use, known caveats, anything that affects the serve config>
