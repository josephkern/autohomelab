#!/usr/bin/env python3
"""Gate 2 as a RELATIVE check: recovery % of a variant vs a reference (contamination largely
cancels in the delta). Reads accuracy.tsv scores ('task=score;...').

    uv run scripts/recovery.py --model RedHatAI/Qwen3-8B-NVFP4 \
        --variant <config_hash> --reference <config_hash | "gsm8k=87.0;mmlu=73.49"> [--tol 1.0]

Prints per-task delta + recovery %, and exits non-zero if any shared task drops more than --tol
absolute points (default 1.0). Use for the promotion gate.

CRITICAL: variant and reference MUST use the SAME eval settings (same --limit / task set). Full vs
LIMIT-sampled mmlu are different question sets and are NOT comparable — comparing them produces a
spurious delta. Compare LIMIT=100 to LIMIT=100, or full to full.
"""
from __future__ import annotations
import argparse, csv, sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def parse_scores(s: str) -> dict:
    return {k: float(v) for k, v in (p.split("=", 1) for p in s.split(";") if "=" in p)}


def scores_for(model: str, key: str) -> dict:
    """key = a config_hash present in accuracy.tsv, or a literal 'task=score;...' string."""
    if "=" in key:
        return parse_scores(key)
    org, name = model.split("/", 1) if "/" in model else ("_", model)
    rows = []
    for tsv in (REPO_ROOT / "results").glob(f"*/{org}/{name}/accuracy.tsv"):
        rows += list(csv.DictReader(tsv.open(), delimiter="\t"))
    hits = [r for r in rows if r.get("config_hash") == key]
    if not hits:
        sys.exit(f"no accuracy row for config_hash {key}")
    return parse_scores(hits[-1]["scores"])  # latest


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--variant", required=True, help="config_hash of the candidate")
    ap.add_argument("--reference", required=True, help="config_hash or 'task=score;...'")
    ap.add_argument("--tol", type=float, default=1.0, help="max allowed absolute drop per task")
    args = ap.parse_args()

    var, ref = scores_for(args.model, args.variant), scores_for(args.model, args.reference)
    shared = sorted(set(var) & set(ref))
    if not shared:
        sys.exit("no shared tasks between variant and reference")

    print(f"{'task':24} {'ref':>7} {'var':>7} {'delta':>7} {'recov%':>7}")
    worst, fails = 0.0, []
    for t in shared:
        d = var[t] - ref[t]
        rec = (var[t] / ref[t] * 100) if ref[t] else float("nan")
        flag = "" if d >= -args.tol else "  <-- REGRESSION"
        print(f"{t:24} {ref[t]:>7.2f} {var[t]:>7.2f} {d:>+7.2f} {rec:>6.1f}%{flag}")
        worst = min(worst, d)
        if d < -args.tol:
            fails.append(t)

    ok = not fails
    print(f"\nworst delta: {worst:+.2f} pts | tol: -{args.tol} | "
          f"{'PASS — within tolerance' if ok else 'FAIL — regression on: ' + ', '.join(fails)}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
