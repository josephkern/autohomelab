# unsloth/Qwen3.6-35B-A3B-NVFP4-Fast — model card (autohomelab)

- HF id: unsloth/Qwen3.6-35B-A3B-NVFP4-Fast
- Revision (pinned): 1c3f884bc99aac2524f6d49bcbac8c88401afd66
- Type: <general | reasoning | coder>   # drives eval suite: general→gsm8k+mmlu, coder→humaneval+mbpp
- Quantization: <e.g. NVFP4 (compressed-tensors W4A4)>
- Native context: <max_position_embeddings>
- Reasoning parser: <qwen3 | deepseek_r1 | nemotron_v3 | none>
- Tool-call parser: <hermes | qwen3_coder | llama3_json | glm47 | none>
- Recommended sampling: {"temperature":1.0,"top_p":0.95,"top_k":20}
- Quality reference: <recovery % / published eval scores from the HF card's Evaluation section>

## Notes
<intended use, known caveats, anything that affects the serve config>
