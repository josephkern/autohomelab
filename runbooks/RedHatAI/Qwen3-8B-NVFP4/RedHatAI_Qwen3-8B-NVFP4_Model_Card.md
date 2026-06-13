# RedHatAI/Qwen3-8B-NVFP4 — model card (autohomelab)

- HF id: RedHatAI/Qwen3-8B-NVFP4
- Revision (pinned): e391349c110709b87bfc2ad2fde3f50dc5839fd8
- Type: <general | reasoning | coder>   # drives eval suite: general→gsm8k+mmlu, coder→humaneval+mbpp
- Quantization: <e.g. NVFP4 (compressed-tensors W4A4)>
- Native context: <max_position_embeddings>
- Reasoning parser: <qwen3 | deepseek_r1 | nemotron_v3 | none>
- Tool-call parser: <hermes | qwen3_coder | llama3_json | glm47 | none>
- Recommended sampling: {"temperature":0.6,"top_p":0.95,"top_k":20}
- Quality reference: <recovery % / published eval scores from the HF card's Evaluation section>

## Notes
<intended use, known caveats, anything that affects the serve config>
