#!/usr/bin/env python3
"""Tier-4 PRIVATE held-out eval — set parser, grader, and bundle writer.

    uv run scripts/eval_private_set.py validate --set DIR
    uv run scripts/eval_private_set.py run --set DIR --bundle DIR \
            --target URL --model NAME [--limit N] [--conc N]

`scripts/eval_private.sh` is the runner; this file is the part that must not be written in bash.
It is deliberately stdlib-only (no `requests`, no `openai`) so it runs under a bare `python3` in
the self-test, exactly as `eval_validity.py` does.

Why this exists (AGENTS.md follow-up, docs/private-eval.md)
-----------------------------------------------------------
Every quality signal this project has is public and therefore contaminable: gsm8k and mmlu are
memorised, `mmlu_pro` is tier 2, LiveBench is tier 3 and its resistance decays with every refresh
lapse. A small set we author and never publish is the only fully-uncontaminated signal available
for a promotion decision. It is also, honestly, a *weak* one — see the sample-size section of
docs/private-eval.md before quoting a number from it.

One vocabulary, not two
-----------------------
This module does **not** re-implement the Gate-2 acceptance predicate. It writes the graded run
into a bundle in lm-eval's own on-disk shape and then calls the SHIPPED
`scripts/eval_validity.py::assess` on it, so `no_score` / `nonfinite` / `short_sample` /
`zero_score` / `no_samples`, the void/suspect status floor, and the `citable` rule are the same
code paths Gate 2 already uses. The private layer adds exactly ONE token of its own:

| token     | rule                                                          | severity |
|-----------|---------------------------------------------------------------|----------|
| `small_n` | fewer than `AHL_PRIVATE_MIN_ITEMS` (**30**) live items scored  | suspect  |

`small_n` is a *validity* token, never a tolerance test: it says "this sample is too small for the
number to mean anything", which is a structural fact about n, not a judgement about the value. At
n=20 the binomial standard error is ~11 points; a set that small cannot support a keep/discard
decision and must not mint a citable row. (Consequence, deliberately: the committed
`evalsets/private-example` set has 3 live items, so running it can NEVER produce a citable row.)

Nothing here compares a score against a reference or a floor, for the reason stated in
docs/validity-contract.md v1.2: a threshold on the VALUE would imply a precision the sample size
cannot deliver.

Leakage rules enforced by this file
-----------------------------------
1. The bundle under `results/**/data/` NEVER receives item text or model output. Per item it
   records the id, a salted digest of the prompt, the verdict, latency and the output LENGTH.
   `results/**/data/` is gitignored, but gitignore is not a threat model: bundles are backed up,
   pasted into issues, and read by future agents.
2. Transcripts (prompt + raw output), which you genuinely need when debugging a failed item, are
   opt-in (`AHL_PRIVATE_KEEP_TRANSCRIPT=1`) and are written into the private set's own directory
   OUTSIDE the repo, mode 0600 — never into the bundle.
3. The prompt digest is `sha256(salt || prompt)` truncated to 16 hex, with the salt living only in
   the private manifest. A bare `sha256(prompt)` would be a confirmation oracle for anyone holding
   a guessed question; salted, it is not.
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import eval_validity as ev  # noqa: E402  (the shipped Gate-2 predicate — reused, never copied)

SCHEMA = "ahl-private-eval/1"
MARKER = "AHL-PRIVATE-EVAL-ITEMS"
ID_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,64}$")
GRADERS = ("exact", "contains", "regex", "numeric")

V_SMALL_N = "small_n"
PRIVATE_SUSPECT = frozenset({V_SMALL_N})
PRIVATE_FATAL = frozenset()


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    try:
        return int(raw) if raw not in (None, "") else default
    except ValueError:
        return default


MIN_ITEMS = _env_int("AHL_PRIVATE_MIN_ITEMS", 30)


class SetError(Exception):
    """The set on disk is not a valid set. Always fatal: a silently dropped item changes the
    population the score is over, which is the exact failure `short_sample` exists to catch."""


# ── the set ───────────────────────────────────────────────────────────────────
def _read_jsonl(path: Path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SetError("%s:%d: not valid JSON (%s)" % (path.name, lineno, exc)) from None
            if not isinstance(rec, dict):
                raise SetError("%s:%d: expected a JSON object, got %s"
                               % (path.name, lineno, type(rec).__name__))
            out.append((lineno, rec))
    return out


def _check_grader(where: str, g) -> None:
    if not isinstance(g, dict):
        raise SetError("%s: `grader` must be an object" % where)
    typ = g.get("type")
    if typ not in GRADERS:
        raise SetError("%s: grader.type %r not one of %s" % (where, typ, ", ".join(GRADERS)))
    if typ in ("exact", "contains"):
        answers = g.get("answers") or ([g["answer"]] if "answer" in g else [])
        if not answers or not all(isinstance(a, str) and a.strip() for a in answers):
            raise SetError("%s: grader %s needs a non-empty `answer` or `answers`" % (where, typ))
    elif typ == "regex":
        pat = g.get("pattern")
        if not isinstance(pat, str) or not pat:
            raise SetError("%s: grader regex needs a `pattern`" % where)
        try:
            re.compile(pat)
        except re.error as exc:
            raise SetError("%s: grader regex `pattern` does not compile: %s" % (where, exc)) from None
    elif typ == "numeric":
        if not isinstance(g.get("answer"), (int, float)) or isinstance(g.get("answer"), bool):
            raise SetError("%s: grader numeric needs a numeric `answer`" % where)
    mnc = g.get("must_not_contain", [])
    if not isinstance(mnc, list) or not all(isinstance(s, str) for s in mnc):
        raise SetError("%s: grader.must_not_contain must be a list of strings" % where)


def load_set(set_dir):
    """Parse + validate a private set directory. Returns a dict; raises SetError on anything
    malformed. Fail CLOSED: a set that is 95% parseable is not a set."""
    d = Path(set_dir)
    man_p, items_p = d / "manifest.json", d / "items.jsonl"
    if not d.is_dir():
        raise SetError("no such directory: %s" % d)
    if not man_p.is_file():
        raise SetError("missing manifest.json in %s" % d)
    if not items_p.is_file():
        raise SetError("missing items.jsonl in %s" % d)
    try:
        man = json.loads(man_p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SetError("manifest.json is not valid JSON: %s" % exc) from None
    if not isinstance(man, dict):
        raise SetError("manifest.json must be a JSON object")
    if man.get("schema") != SCHEMA:
        raise SetError("manifest.schema is %r, expected %r" % (man.get("schema"), SCHEMA))
    set_id = man.get("set_id")
    if not isinstance(set_id, str) or not ID_RE.match(set_id):
        raise SetError("manifest.set_id %r must match %s" % (set_id, ID_RE.pattern))
    vis = man.get("visibility")
    if vis not in ("private", "example"):
        raise SetError("manifest.visibility must be \"private\" or \"example\", got %r" % vis)
    salt = man.get("salt")
    if not isinstance(salt, str) or not salt:
        raise SetError("manifest.salt must be a non-empty string (it makes the audit digests "
                       "non-guessable — see docs/private-eval.md)")

    records = _read_jsonl(items_p)
    if not records:
        raise SetError("items.jsonl is empty")
    lineno, header = records[0]
    if header.get("kind") != "header" or header.get("marker") != MARKER:
        raise SetError("items.jsonl line 1 must be the header record "
                       '{"schema":"%s","kind":"header","marker":"%s","visibility":"..."} — it is '
                       "what the pre-commit guard greps for" % (SCHEMA, MARKER))
    if header.get("visibility") != vis:
        raise SetError("items.jsonl header visibility %r disagrees with manifest %r"
                       % (header.get("visibility"), vis))

    items, seen = [], set()
    for lineno, rec in records[1:]:
        where = "items.jsonl:%d" % lineno
        iid = rec.get("id")
        if not isinstance(iid, str) or not ID_RE.match(iid):
            raise SetError("%s: id %r must match %s" % (where, iid, ID_RE.pattern))
        if iid in seen:
            raise SetError("%s: duplicate id %r" % (where, iid))
        seen.add(iid)
        if not isinstance(rec.get("prompt"), str) or not rec["prompt"].strip():
            raise SetError("%s: `prompt` must be a non-empty string" % where)
        _check_grader(where, rec.get("grader"))
        burned = rec.get("burned")
        if burned not in (None, False) and not isinstance(burned, dict):
            raise SetError("%s: `burned` must be absent, false, or an object "
                           '{"date":"YYYYMMDD","reason":"..."}' % where)
        items.append(rec)

    live = [i for i in items if not i.get("burned")]
    burned = [i for i in items if i.get("burned")]
    # The set fingerprint travels in the task name so the committed journal records WHICH version
    # of the set a score is over, without revealing a byte of it.
    h = hashlib.sha256()
    h.update(man_p.read_bytes())
    h.update(items_p.read_bytes())
    return {
        "dir": d, "manifest": man, "set_id": set_id, "visibility": vis, "salt": salt,
        "items": items, "live": live, "burned": burned, "set_fp": h.hexdigest()[:8],
    }


def task_name(s) -> str:
    return "private_%s.%s" % (s["set_id"], s["set_fp"])


# ── grading ───────────────────────────────────────────────────────────────────
_FENCE = re.compile(r"^```[A-Za-z0-9_+-]*\s*|\s*```$")
_NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")
_BOXED = re.compile(r"\\boxed\{([^{}]*)\}")


def norm(s) -> str:
    s = (s or "").strip()
    s = _FENCE.sub("", s).strip()
    s = s.replace("**", "").replace("*", "").replace("`", "")
    s = re.sub(r"\s+", " ", s).strip()
    return s.strip(" .!?\"'").lower()


def _candidates(out):
    lines = [ln for ln in (out or "").splitlines() if ln.strip()]
    cands = [out]
    if lines:
        cands.append(lines[-1])
    return [norm(c) for c in cands]


def _as_number(text):
    m = _BOXED.findall(text or "")
    blob = m[-1] if m else (text or "")
    nums = _NUM.findall(blob)
    if not nums and m:
        nums = _NUM.findall(text or "")
    if not nums:
        return None
    try:
        return float(nums[-1].replace(",", ""))
    except ValueError:
        return None


def grade(item, output):
    """-> (passed: bool, reason: str). Objective graders only — no LLM judge. The repo's own
    contamination research prefers objective ground-truth grading (docs/contamination-resistant-
    evals.md), and an LLM judge would also mean shipping the item text to a second model."""
    g = item["grader"]
    text = output or ""
    if not text.strip():
        return False, "empty_content"
    for bad in g.get("must_not_contain", []):
        if norm(bad) and norm(bad) in norm(text):
            return False, "must_not_contain:%s" % bad[:24]
    typ = g["type"]
    if typ in ("exact", "contains"):
        answers = g.get("answers") or [g["answer"]]
        cands = _candidates(text)
        for a in answers:
            na = norm(a)
            if typ == "exact" and any(c == na for c in cands):
                return True, "exact"
            if typ == "contains" and na and na in norm(text):
                return True, "contains"
        return False, typ
    if typ == "regex":
        flags = re.MULTILINE | (0 if g.get("case_sensitive") else re.IGNORECASE)
        if g.get("dotall"):
            flags |= re.DOTALL
        return (True, "regex") if re.search(g["pattern"], text, flags) else (False, "regex")
    if typ == "numeric":
        got = _as_number(text)
        if got is None:
            return False, "no_number"
        tol = float(g.get("tol", 1e-6))
        return (abs(got - float(g["answer"])) <= tol, "numeric")
    return False, "unknown_grader"      # unreachable: load_set() rejects unknown types


# ── transport ─────────────────────────────────────────────────────────────────
class TransportError(Exception):
    pass


def _http_chat(target, payload, timeout):
    req = urllib.request.Request(
        target.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode()[:200]
        except Exception:                                   # noqa: BLE001
            pass
        raise TransportError("HTTP %s %s" % (exc.code, body)) from None
    except Exception as exc:                                # noqa: BLE001
        raise TransportError(str(exc)) from None


def _stub_chat(cmd, payload, timeout):
    """`AHL_PRIVATE_TRANSPORT` seam: a command that reads the request JSON on stdin and writes an
    OpenAI-shaped response JSON on stdout. This is how the self-test proves THIS script's grading
    and bundle-writing run, with no server and no GPU (mirrors eval.sh's `AHL_LM_EVAL` seam)."""
    try:
        p = subprocess.run(cmd, shell=True, input=json.dumps(payload).encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise TransportError("stub transport timed out") from None
    if p.returncode != 0:
        raise TransportError("stub transport exit %d" % p.returncode)
    try:
        return json.loads(p.stdout.decode() or "{}")
    except json.JSONDecodeError as exc:
        raise TransportError("stub transport emitted non-JSON: %s" % exc) from None


def ask(target, model, item, timeout, max_tokens):
    msgs = []
    if item.get("system"):
        msgs.append({"role": "system", "content": item["system"]})
    msgs.append({"role": "user", "content": item["prompt"]})
    payload = {"model": model, "messages": msgs, "temperature": 0, "top_p": 1.0,
               "max_tokens": int(item.get("max_tokens", max_tokens))}
    stub = os.environ.get("AHL_PRIVATE_TRANSPORT")
    doc = _stub_chat(stub, payload, timeout) if stub else _http_chat(target, payload, timeout)
    try:
        msg = doc["choices"][0]["message"]
    except Exception as exc:                                # noqa: BLE001
        raise TransportError("unparseable response (%s)" % exc) from None
    # Grade `content` only. A reasoning model that routes everything into `reasoning_content` and
    # leaves `content` empty scores 0 — which is the NemotronH think-off failure (AGENTS.md), and
    # is meant to surface as `zero_score`, not to be papered over by grading the CoT.
    return (msg.get("content") or ""), (msg.get("reasoning_content") or "")


# ── run ───────────────────────────────────────────────────────────────────────
def _digest(salt, prompt) -> str:
    return hashlib.sha256((salt + "\x00" + prompt).encode()).hexdigest()[:16]


def run(args) -> int:
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("private set is not usable: %s" % exc, file=sys.stderr)
        return 2

    live = sorted(s["live"], key=lambda i: i["id"])
    requested_all = len(live)
    if args.limit:
        live = live[:int(args.limit)]
    task = task_name(s)
    conc = max(1, int(args.conc or 1))
    interrupted = {"sig": 0}

    def _onsig(signum, _frame):
        interrupted["sig"] = signum
        raise KeyboardInterrupt

    for sg in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sg, _onsig)
        except ValueError:                                  # not the main thread
            pass

    rows, transport_failures = [], 0

    def one(item):
        t0 = time.time()
        try:
            content, reasoning = ask(args.target, args.model, item,
                                     float(args.timeout), int(args.max_tokens))
        except TransportError as exc:
            return {"id": item["id"], "verdict": "error", "reason": str(exc)[:120],
                    "latency_ms": int((time.time() - t0) * 1000), "output_chars": 0,
                    "prompt_sha": _digest(s["salt"], item["prompt"])}
        passed, reason = grade(item, content)
        return {"id": item["id"], "verdict": "pass" if passed else "fail", "reason": reason,
                "latency_ms": int((time.time() - t0) * 1000), "output_chars": len(content),
                "reasoning_chars": len(reasoning),
                "prompt_sha": _digest(s["salt"], item["prompt"]),
                "_text": {"prompt": item["prompt"], "output": content}}

    try:
        if conc == 1:
            rows = [one(i) for i in live]
        else:
            with futures.ThreadPoolExecutor(max_workers=conc) as pool:
                rows = list(pool.map(one, live))
    except KeyboardInterrupt:
        sig = interrupted["sig"] or signal.SIGINT
        print("interrupted by signal %d — no row is written for a partial run" % sig,
              file=sys.stderr)
        return 128 + int(sig)

    # Transcripts NEVER enter the bundle. Opt-in, 0600, inside the private set dir (outside the
    # repo). See the leakage rules in this module's docstring.
    transcript_path = "na"
    keep = os.environ.get("AHL_PRIVATE_KEEP_TRANSCRIPT", "0") == "1"
    if keep:
        tdir = Path(os.environ.get("AHL_PRIVATE_TRANSCRIPT_DIR") or (s["dir"] / "transcripts"))
        tdir.mkdir(parents=True, exist_ok=True, mode=0o700)
        tp = tdir / ("%s.jsonl" % args.run_id)
        fd = os.open(str(tp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for r in rows:
                t = r.get("_text") or {}
                fh.write(json.dumps({"id": r["id"], "verdict": r["verdict"],
                                     "prompt": t.get("prompt"), "output": t.get("output")}) + "\n")
        transcript_path = str(tp)
    for r in rows:
        r.pop("_text", None)                # the single point where item text leaves this process

    graded = [r for r in rows if r["verdict"] in ("pass", "fail")]
    transport_failures = len(rows) - len(graded)
    passes = sum(1 for r in graded if r["verdict"] == "pass")
    requested = len(live) if not args.limit else min(int(args.limit), requested_all)

    bundle = Path(args.bundle)
    (bundle / "private").mkdir(parents=True, exist_ok=True)
    metrics = {"alias": task}
    if graded:
        p = passes / len(graded)
        metrics["acc,none"] = p
        metrics["acc_stderr,none"] = (p * (1 - p) / len(graded)) ** 0.5
    doc = {
        "config": {"limit": (int(args.limit) if args.limit else None),
                   "model": args.model,
                   "model_args": {"num_concurrent": conc, "model": args.model}},
        "group_subtasks": {}, "results": {task: metrics},
        "n-samples": {task: {"effective": len(graded), "original": requested_all}},
        # provenance only — no item text, by construction (see the module docstring)
        "ahl_private": {
            "schema": SCHEMA, "set_id": s["set_id"], "set_fp": s["set_fp"],
            "visibility": s["visibility"], "authored": s["manifest"].get("authored", "na"),
            "items_total": len(s["items"]), "items_live": requested_all,
            "items_burned": len(s["burned"]), "items_scored": len(graded),
            "items_requested": requested, "passes": passes,
            "transport_failures": transport_failures,
            "empty_content": sum(1 for r in graded if r["reason"] == "empty_content"),
            "min_items": MIN_ITEMS, "transcript": transcript_path,
            "ran_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }
    outdir = bundle / re.sub(r"[^A-Za-z0-9_.\-]", "__", args.model)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / ("results_%s.json" % args.run_id)).write_text(json.dumps(doc, indent=1))
    # The per-item bitmap: ids + verdicts, no text. This is what a later PAIRED comparison
    # (McNemar on discordant items — docs/private-eval.md) needs, and it is the reason the
    # bundle is worth keeping at all.
    with open(bundle / "private" / "items.audit.jsonl", "w", encoding="utf-8") as fh:
        for r in sorted(rows, key=lambda x: x["id"]):
            fh.write(json.dumps(r, sort_keys=True) + "\n")

    # ── the SHIPPED Gate-2 predicate, then the one private token ──────────────
    res = ev.assess(str(bundle), task, limit=(args.limit or None), conc=conc)
    verds = [v for v in ev.parse_validity(res["validity"]) if v != ev.V_OK]
    if len(graded) < MIN_ITEMS:
        verds.append(ev.tag_verdict(V_SMALL_N, task))
    floor = ev.status_floor(verds)
    bases = {ev.verdict_base(v) for v in verds}
    if floor == "ok" and (bases & PRIVATE_SUSPECT):
        floor = ev.STATUS_SUSPECT
    if bases & PRIVATE_FATAL:
        floor = ev.STATUS_VOID
    validity = ev.format_validity(verds)
    status = ev.apply_status(ev.STATUS_MEASURED, floor)
    is_citable = ev.citable(validity, status)

    print("\t".join((res["scores"], res["samples"], validity, status, str(conc),
                     "1" if is_citable else "0")))
    for r in res["reasons"]:
        print("  ! " + r, file=sys.stderr)
    if len(graded) < MIN_ITEMS:
        print("  ! %s: %d live items scored, floor is %d (AHL_PRIVATE_MIN_ITEMS). At n=20 the "
              "binomial SE is ~11 points — a set this small cannot support a keep/discard "
              "decision, so the row is recorded and NOT citable." % (task, len(graded), MIN_ITEMS),
              file=sys.stderr)
    if s["burned"]:
        print("  i %d item(s) marked burned were excluded; the score is over %d live items, a "
              "different population than earlier rows (see `samples`)."
              % (len(s["burned"]), requested_all), file=sys.stderr)
    if transport_failures:
        print("  ! %d item(s) never got a response — those are missing samples, not wrong "
              "answers." % transport_failures, file=sys.stderr)
    if s["visibility"] == "example":
        print("  ! this is the COMMITTED EXAMPLE set (visibility=example). It is fake and public; "
              "no number from it is a quality signal.", file=sys.stderr)
    return 1 if transport_failures else 0


def cmd_validate(args) -> int:
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("INVALID: %s" % exc, file=sys.stderr)
        return 2
    print("ok  set_id=%s fp=%s visibility=%s items=%d live=%d burned=%d task=%s"
          % (s["set_id"], s["set_fp"], s["visibility"], len(s["items"]), len(s["live"]),
             len(s["burned"]), task_name(s)))
    if len(s["live"]) < MIN_ITEMS:
        print("WARN: %d live items is below AHL_PRIVATE_MIN_ITEMS=%d — runs will record "
              "`small_n` and will not be citable." % (len(s["live"]), MIN_ITEMS), file=sys.stderr)
    return 0


def cmd_sniff(_args) -> int:
    """Read a file's bytes on stdin; exit 0 if they ARE private-eval material, 1 if not.

    The pre-commit guard needs to tell a set from a file that merely TALKS about one. The first
    implementation grepped for the marker string and promptly blocked this repo's own
    `docs/private-eval.md`, `eval_private_selftest.sh` and this very module — a guard that fires on
    its own documentation is a guard the next operator disables, which would leave the real thing
    unprotected. So the test is structural: it must PARSE as a manifest or as an items file.
    """
    text = sys.stdin.read()
    try:
        obj = json.loads(text)
        if isinstance(obj, dict) and obj.get("schema") == SCHEMA \
                and obj.get("visibility") == "private":
            return 0                                    # a private manifest.json
    except Exception:                                   # noqa: BLE001
        pass
    lines = [ln for ln in text.splitlines() if ln.strip()]
    # a blob truncated by the caller may end mid-line; that tail is not evidence either way
    if len(lines) >= 2 and text and not text.endswith("\n"):
        lines = lines[:-1]
    if len(lines) < 2:
        return 1
    recs = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except Exception:                               # noqa: BLE001
            return 1                                    # prose/code around it -> not an items file
        if not isinstance(rec, dict):
            return 1
        recs.append(rec)
    head = recs[0]
    if head.get("kind") == "header" and head.get("marker") == MARKER \
            and head.get("visibility") != "example":
        return 0                                        # a private items.jsonl
    return 1


def cmd_taskname(args) -> int:
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("INVALID: %s" % exc, file=sys.stderr)
        return 2
    print("%s\t%s\t%s\t%d\t%d" % (task_name(s), s["set_id"], s["visibility"],
                                  len(s["live"]), len(s["burned"])))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate", help="parse + schema-check a private set")
    v.add_argument("--set", dest="set_dir", required=True)
    v.set_defaults(fn=cmd_validate)

    s = sub.add_parser("sniff", help="stdin IS private-eval material? exit 0 yes / 1 no")
    s.set_defaults(fn=cmd_sniff)

    t = sub.add_parser("taskname", help="print task<TAB>set_id<TAB>visibility<TAB>live<TAB>burned")
    t.add_argument("--set", dest="set_dir", required=True)
    t.set_defaults(fn=cmd_taskname)

    r = sub.add_parser("run", help="grade the set against a live endpoint, write the bundle")
    r.add_argument("--set", dest="set_dir", required=True)
    r.add_argument("--bundle", required=True)
    r.add_argument("--target", required=True)
    r.add_argument("--model", required=True)
    r.add_argument("--run-id", dest="run_id", default="run")
    r.add_argument("--limit", default=None)
    r.add_argument("--conc", default=1)
    r.add_argument("--timeout", default=os.environ.get("AHL_PRIVATE_TIMEOUT", "600"))
    r.add_argument("--max-tokens", dest="max_tokens",
                   default=os.environ.get("AHL_PRIVATE_MAX_TOKENS", "2048"))
    r.set_defaults(fn=run)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
