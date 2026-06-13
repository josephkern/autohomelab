---
name: New node profile
about: Onboard a new NVIDIA node into autohomelab
title: "node: <gpu> (<arch>)"
labels: ["node-profile"]
---

## Hardware
- GPU(s):
- VRAM (GB):
- Compute capability:
- Arch (x86_64 / aarch64):
- CPU / RAM:

## Stack
- NVIDIA driver:
- CUDA:
- Firmware / VBIOS (if known):
- Backend image digest to use:

## Checklist
- [ ] `scripts/probe.sh` runs and produces `node_profile.json` + fingerprint
- [ ] Docker NVIDIA runtime registered (`--gpus all` works)
- [ ] Backend image digest pinned in `backends/<name>/image.lock`
- [ ] First green run committed (`results/<node_fp>/<model>/`)
