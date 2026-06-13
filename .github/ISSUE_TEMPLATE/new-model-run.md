---
name: New model run
about: Benchmark (and optionally tune) a model on an existing node
title: "run: <org>/<model> on <node>"
labels: ["model-run"]
---

## Target
- Model (HF id @ revision):
- Node fingerprint:
- Backend:

## Plan
- [ ] `gen_baseline.py <model>` → `runbooks/<org>/<model>/baseline.sh`
- [ ] Baseline green run (probe → serve → bench → results.tsv row)
- [ ] Logbook environment block recorded
- [ ] (optional) Phase-2 tuning loop — target tok/s:

## Notes / results
<!-- link results.tsv rows and logbook narrative here -->
