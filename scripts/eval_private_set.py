#!/usr/bin/env python3
"""Tier-4 PRIVATE held-out eval — set parser, grader, transport, guard and bundle writer.

    uv run scripts/eval_private_set.py validate    --set DIR
    uv run scripts/eval_private_set.py run         --set DIR --bundle DIR \
            --target URL --model NAME [--limit N] [--conc N]
    uv run scripts/eval_private_set.py check-target --target URL [--allow-remote]
    uv run scripts/eval_private_set.py sniff       --file F [--path REL]
    uv run scripts/eval_private_set.py compare     --a BUNDLE --b BUNDLE
    uv run scripts/eval_private_set.py init        --dir DIR

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
code paths Gate 2 already uses. The private layer adds three tokens of its own:

| token              | rule                                                       | severity |
|--------------------|------------------------------------------------------------|----------|
| `small_n`          | fewer than `AHL_PRIVATE_MIN_ITEMS` (**30**) live items scored | suspect |
| `unchecked`        | a live item carries no authoring-time champion verdict        | suspect |
| `reasoning_routed` | the empty answers all had non-empty `reasoning_content`       | void    |

`small_n` is a *validity* token, never a tolerance test: it says "this sample is too small for the
number to mean anything", which is a structural fact about n, not a judgement about the value.

`reasoning_routed` exists because grading `content` only means a reasoning model that routes its
answer into `reasoning_content` scores 0 on every item — a systematic false signal that looks
exactly like the regression this gate is built to catch (AGENTS.md: the NemotronH think-off
failure). If every empty answer came with a non-empty `reasoning_content`, the run is void, not
zero.

Leakage rules enforced by this file (an adversarial verifier found 12 paths through the first
version of these; the ones this file owns are marked with their number)
------------------------------------------------------------------------------------------------
1. The bundle under `results/**/data/` NEVER receives item text or model output. Per item it
   records the id, a salted digest of the prompt, the verdict, latency and the output LENGTH.
   `results/**/data/` is gitignored, but gitignore is not a threat model: bundles are backed up,
   pasted into issues, and read by future agents.
   *(path 5)* The `reason` field is a CLOSED VOCABULARY — `must_not_contain:<index>`, never the
   author's 24 characters of forbidden string; `transport:<code>.<body-sha8>`, never the HTTP
   error body. An echoing gateway (this box runs LiteLLM) will happily reflect a short prompt in a
   400 body, and 200 characters of that used to land in the audit file.
   `_assert_leakproof()` re-checks every row against that vocabulary before it is written.
2. *(path 1, 8)* Transport is pinned to loopback at the SOCKET, not at the URL string. Proxies are
   disabled unconditionally (`ProxyHandler({})` — `urllib` honours `http_proxy` and does NOT
   bypass it for loopback, so a set could be exfiltrated verbatim while a URL-string check said
   "127.0.0.1, fine"), and the connection asserts `getpeername()` is a loopback address after
   connect. That is also what makes `127.0.0.1@evil.example`, `127.0.0.1.evil.example`,
   `[::ffff:127.0.0.1]`, `localhost.`, `LOCALHOST` and `2130706433` all resolve to the right
   answer instead of to whatever a prefix glob happened to think.
3. *(path 2, 3)* `visibility` is NOT self-declared. Item-shaped content is PRIVATE by default; the
   single blessed example is identified by exact repo path **and** content digest. A copy of the
   example — which the runner's own help text used to tell you to make — is therefore private the
   moment it is edited, and its inherited published salt is rejected by value.
4. *(path 6)* Transcripts (prompt + raw output) are opt-in, mode 0600, and are REFUSED anywhere
   inside the repo. `sniff` knows the transcript record shape, so one that lands in the tree
   anyway is blocked at commit.
5. The prompt digest is `sha256(salt ‖ prompt)` truncated to 16 hex, with the salt living only in
   the private manifest. A bare `sha256(prompt)` would be a confirmation oracle for anyone holding
   a guessed question; salted, it is not — which is why the salt has a minimum length and why the
   published example salt is rejected.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import concurrent.futures as futures
import csv
import hashlib
import http.client
import io
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))
import eval_validity as ev  # noqa: E402  (the shipped Gate-2 predicate — reused, never copied)

SCHEMA = "ahl-private-eval/1"
MARKER = "AHL-PRIVATE-EVAL-ITEMS"
ID_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,64}$")
GRADERS = ("exact", "contains", "regex", "numeric")

# ── the ONE blessed example ───────────────────────────────────────────────────
# Identified by exact path AND content digest. Nothing else in the universe is an "example" set,
# whatever its manifest says about itself. (path 2: `visibility: "example"` used to be a
# self-declared header that simultaneously defeated the in-repo refusal, the .gitignore patterns
# and the guard's exemption — three independent defences with one shared, forgeable input.)
EXAMPLE_REL = "evalsets/private-example"
EXAMPLE_SHA256 = {
    "manifest.json": "e10a084f1522b52681bf7c5f48a6f0008784658bef90637a92f625a3ce4e59f8",
    "items.jsonl": "aa8dbf1691971f797ce405b39acfd1a15069b60fba2bea11224e2c0951540751",
}
# The salt published in that example. Inheriting it makes every audit digest reconstructible by
# anyone who guesses a question — the oracle the salt exists to prevent. (path 3)
EXAMPLE_SALT = "EXAMPLE-SALT-PUBLISHED-ON-PURPOSE-NEVER-REUSE-THIS"
MIN_SALT_LEN = 32
MIN_SALT_DISTINCT = 8

V_SMALL_N = "small_n"
V_UNCHECKED = "unchecked"
V_REASONING_ROUTED = "reasoning_routed"
PRIVATE_SUSPECT = frozenset({V_SMALL_N, V_UNCHECKED})
PRIVATE_FATAL = frozenset({V_REASONING_ROUTED})


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    try:
        return int(raw) if raw not in (None, "") else default
    except ValueError:
        return default


def _env_flag(name: str) -> bool:
    return os.environ.get(name, "0") == "1"


MIN_ITEMS = _env_int("AHL_PRIVATE_MIN_ITEMS", 30)


class SetError(Exception):
    """The set on disk is not a valid set. Always fatal: a silently dropped item changes the
    population the score is over, which is the exact failure `short_sample` exists to catch."""


# ── blessing: path + digest, never a self-declared header ─────────────────────
def _sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _under(path: Path, root: Path) -> bool:
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except (ValueError, OSError):
        return False


def is_blessed_example_dir(set_dir) -> bool:
    """True only for <repo>/evalsets/private-example with byte-exact known contents."""
    try:
        d = Path(set_dir).resolve()
    except OSError:
        return False
    if d != (REPO_ROOT / EXAMPLE_REL).resolve():
        return False
    for name, want in EXAMPLE_SHA256.items():
        p = d / name
        if not p.is_file() or _sha256_bytes(p.read_bytes()) != want:
            return False
    return True


def is_blessed_example_file(rel_path, data: bytes) -> bool:
    """True only for a staged blob that IS one of the two blessed example files, byte for byte."""
    rel = str(rel_path).lstrip("./")
    for name, want in EXAMPLE_SHA256.items():
        if rel == "%s/%s" % (EXAMPLE_REL, name) and _sha256_bytes(data) == want:
            return True
    return False


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


_PLACEHOLDER = re.compile(r"(FILL[ -_]?ME|<[^>]*>|TODO|CHANGE[ -_]?ME|xxxx)", re.IGNORECASE)


def _check_champion(man) -> None:
    """Nobody can check the ground truth of a private set — a wrong answer key or an over-tight
    grader is a permanent, silent, systematic false signal indistinguishable from the regression
    this gate exists to catch. The one cheap defence is ATTRIBUTION: record which model produced
    which verdict at authoring time, so a later failure can be read as "the candidate changed" or
    "the item was always wrong". See docs/private-eval.md §7."""
    ch = man.get("champion")
    if not isinstance(ch, dict):
        raise SetError(
            'manifest.champion is required for a private set: {"model":"<HFOrg/Model>",'
            '"runbook":"runbooks/.../x_final.sh","date":"YYYYMMDD"}. Nobody can check this set\'s '
            "ground truth, so the authoring-time champion verdict is the only thing that lets a "
            "later failure be attributed to the candidate rather than to a wrong answer key "
            "(docs/private-eval.md §7)")
    for k in ("model", "date"):
        v = ch.get(k)
        if not isinstance(v, str) or not v.strip():
            raise SetError("manifest.champion.%s must be a non-empty string" % k)
        if _PLACEHOLDER.search(v):
            raise SetError("manifest.champion.%s is still a placeholder (%r) — fill it in with "
                           "the model you actually calibrated the items against" % (k, v))


def _check_salt(salt, blessed: bool) -> None:
    if not isinstance(salt, str) or not salt:
        raise SetError("manifest.salt must be a non-empty string (it makes the audit digests "
                       "non-guessable — see docs/private-eval.md)")
    if blessed:
        return                      # the blessed example's published salt is published on purpose
    if salt == EXAMPLE_SALT or "EXAMPLE-SALT" in salt:
        raise SetError(
            "manifest.salt is the PUBLISHED example salt. It is in this public repo, so every "
            "audit digest in every bundle would be reconstructible from a guessed question — the "
            "confirmation oracle the salt exists to prevent. Generate a fresh one: "
            "`scripts/eval_private.sh init` (or `python3 -c \"import secrets;"
            "print(secrets.token_urlsafe(32))\"`).")
    if len(salt) < MIN_SALT_LEN:
        raise SetError("manifest.salt is %d characters; the floor is %d. A short salt is "
                       "brute-forceable, which makes the digests an oracle again."
                       % (len(salt), MIN_SALT_LEN))
    if len(set(salt)) < MIN_SALT_DISTINCT:
        raise SetError("manifest.salt has only %d distinct characters — it is padding, not "
                       "entropy. Generate one with `scripts/eval_private.sh init`."
                       % len(set(salt)))


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
    blessed = is_blessed_example_dir(d)
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
    declared = man.get("visibility")
    if declared not in ("private", "example"):
        raise SetError("manifest.visibility must be \"private\" or \"example\", got %r" % declared)
    # PRIVATE BY DEFAULT. `visibility: "example"` is not a claim a set gets to make about itself:
    # it is a fact about being the one blessed set at the one blessed path with the one blessed
    # digest. (path 2)
    if declared == "example" and not blessed:
        raise SetError(
            'manifest.visibility is "example", but this is not the blessed example set.\n'
            "  \"example\" is reserved for %s/%s with its committed contents; it is the ONE set\n"
            "  that is allowed to be public, and it is identified by path + content digest, not\n"
            "  by this header. A copy of the example is a PRIVATE set the moment you edit it.\n"
            "  Set \"visibility\": \"private\" (and give it a fresh salt: eval_private.sh init)."
            % (REPO_ROOT.name, EXAMPLE_REL))
    vis = "example" if blessed else "private"
    _check_salt(man.get("salt"), blessed)
    if not blessed:
        _check_champion(man)

    records = _read_jsonl(items_p)
    if not records:
        raise SetError("items.jsonl is empty")
    lineno, header = records[0]
    if header.get("kind") != "header" or header.get("marker") != MARKER:
        raise SetError("items.jsonl line 1 must be the header record "
                       '{"schema":"%s","kind":"header","marker":"%s","visibility":"..."} — it is '
                       "what the pre-commit guard greps for" % (SCHEMA, MARKER))
    if header.get("visibility") != declared:
        raise SetError("items.jsonl header visibility %r disagrees with manifest %r"
                       % (header.get("visibility"), declared))

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
        chk = rec.get("checked")
        if chk is not None:
            if not isinstance(chk, dict):
                raise SetError('%s: `checked` must be an object {"verdict":"pass|fail",'
                               '"date":"YYYYMMDD"}' % where)
            if chk.get("verdict") not in ("pass", "fail"):
                raise SetError("%s: checked.verdict must be \"pass\" or \"fail\", got %r"
                               % (where, chk.get("verdict")))
        items.append(rec)

    live = [i for i in items if not i.get("burned")]
    burned = [i for i in items if i.get("burned")]
    unchecked = [i for i in live if not isinstance(i.get("checked"), dict)]
    # The set fingerprint travels in the task name so the committed journal records WHICH version
    # of the set a score is over, without revealing a byte of it.
    h = hashlib.sha256()
    h.update(man_p.read_bytes())
    h.update(items_p.read_bytes())
    return {
        "dir": d, "manifest": man, "set_id": set_id, "visibility": vis, "blessed": blessed,
        "salt": man["salt"], "items": items, "live": live, "burned": burned,
        "unchecked": unchecked, "set_fp": h.hexdigest()[:8],
    }


def task_name(s) -> str:
    return "private_%s.%s" % (s["set_id"], s["set_fp"])


# ── grading ───────────────────────────────────────────────────────────────────
_FENCE = re.compile(r"^```[A-Za-z0-9_+-]*\s*|\s*```$")
_NUM = re.compile(r"-?\d[\d,]*(?:\.\d+)?")
_BOXED = re.compile(r"\\boxed\{([^{}]*)\}")

# The CLOSED vocabulary a bundle `reason` may take. Anything else is a leak channel. (path 5)
REASON_RE = re.compile(
    r"^(empty_content|exact|contains|regex|numeric|no_number|unknown_grader"
    r"|must_not_contain:\d+"
    r"|transport:[a-z0-9_]+(\.[0-9a-f]{8})?(\.len\d+)?)$")


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
    evals.md), and an LLM judge would also mean shipping the item text to a second model.

    `reason` is drawn from a closed vocabulary and NEVER echoes item text: the old
    `must_not_contain:<first 24 chars of the author's forbidden string>` put author-written item
    bytes straight into `items.audit.jsonl`, which is exactly what the bundle must never hold."""
    g = item["grader"]
    text = output or ""
    if not text.strip():
        return False, "empty_content"
    for idx, bad in enumerate(g.get("must_not_contain", [])):
        if norm(bad) and norm(bad) in norm(text):
            return False, "must_not_contain:%d" % idx
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


# ── transport: loopback pinned at the socket, proxies disabled ────────────────
# (paths 1 and 8.) urllib honours http_proxy/https_proxy/ALL_PROXY and does NOT bypass a proxy for
# a loopback target. A URL-string check therefore proved nothing: `TARGET=http://127.0.0.1:8000`
# with `http_proxy=http://collector:3128` sent every prompt verbatim to the collector while the
# refusal printed nothing at all. And the string check itself was a prefix glob, so
# `127.0.0.1@evil.example` and `127.0.0.1.evil.example` passed while `[::ffff:127.0.0.1]`,
# `localhost.`, `LOCALHOST` and `2130706433` were refused. Both bugs are the same bug: the URL
# text is not the peer. Resolve, then check the peer, then check it AGAIN after connect().
class TransportError(Exception):
    def __init__(self, code: str, detail: str = ""):
        super().__init__(code)
        self.code = code
        self.detail = detail

    def __str__(self) -> str:
        return self.code


class TargetRefused(Exception):
    pass


_ALLOW_REMOTE = False


def _is_loopback_ip(ip: str) -> bool:
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    mapped = getattr(a, "ipv4_mapped", None)
    if mapped is not None:
        a = mapped
    # `is_unspecified` (0.0.0.0 / ::) can only ever reach this host, so it counts as local.
    return bool(a.is_loopback or a.is_unspecified)


def resolve_target(url: str):
    """-> (host, port, [ips]). Raises TargetRefused with an explanation. Resolution is the check:
    the host TEXT is never consulted for a decision."""
    parts = urlsplit(url or "")
    if parts.scheme not in ("http", "https"):
        raise TargetRefused("TARGET %r has scheme %r; only http/https are understood"
                            % (url, parts.scheme))
    try:
        host = parts.hostname
        port = parts.port
    except ValueError as exc:
        raise TargetRefused("TARGET %r has an unparseable host/port (%s)" % (url, exc)) from None
    if not host:
        raise TargetRefused("TARGET %r has no host" % url)
    port = port or (443 if parts.scheme == "https" else 80)
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise TargetRefused("TARGET host %r does not resolve (%s)" % (host, exc)) from None
    ips = sorted({i[4][0] for i in infos})
    if not ips:
        raise TargetRefused("TARGET host %r resolved to nothing" % host)
    bad = [ip for ip in ips if not _is_loopback_ip(ip)]
    if bad and not _ALLOW_REMOTE:
        raise TargetRefused(
            "TARGET %s resolves to %s, which is not loopback.\n"
            "  (The host TEXT is irrelevant: `127.0.0.1@evil.example` and "
            "`127.0.0.1.evil.example` are\n"
            "   ordinary remote names, and wildcard-DNS services make the second one trivial.)"
            % (url, ", ".join(bad)))
    return host, port, ips


def _check_peer(sock) -> None:
    if _ALLOW_REMOTE:
        return
    try:
        peer = sock.getpeername()[0]
    except OSError as exc:
        raise TransportError("transport:nopeer", str(exc)) from None
    if not _is_loopback_ip(peer):
        raise TransportError(
            "transport:offbox",
            "connected peer %s is not loopback — refusing to send an item" % peer)


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        super().connect()
        try:
            _check_peer(self.sock)
        except TransportError:
            self.close()
            raise


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        super().connect()
        try:
            _check_peer(self.sock)
        except TransportError:
            self.close()
            raise


class _PinnedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_PinnedHTTPConnection, req)


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_PinnedHTTPSConnection, req,
                            context=getattr(self, "_context", None) or ssl.create_default_context())


def build_opener():
    """ProxyHandler({}) is load-bearing, not hygiene: it is what makes `http_proxy` unable to
    intercept the run. Nothing here ever consults the environment for a proxy."""
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}), _PinnedHTTPHandler(), _PinnedHTTPSHandler())


_OPENER = None


def _opener():
    global _OPENER
    if _OPENER is None:
        _OPENER = build_opener()
    return _OPENER


def _body_fingerprint(raw: bytes) -> str:
    """A code and a hash, never the bytes. An echoing gateway reflects the request — and for a
    short item the request IS the question. (path 5)"""
    return "%s.len%d" % (_sha256_bytes(raw)[:8], len(raw))


def _http_chat(target, payload, timeout):
    req = urllib.request.Request(
        target.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with _opener().open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raw = b""
        try:
            raw = exc.read()
        except Exception:                                   # noqa: BLE001
            pass
        raise TransportError("transport:http_%d.%s" % (exc.code, _body_fingerprint(raw)),
                             "HTTP %s (body withheld: %d bytes)" % (exc.code, len(raw))) from None
    except TransportError:
        raise
    except socket.timeout:
        raise TransportError("transport:timeout") from None
    except urllib.error.URLError as exc:
        reason = exc.reason
        if isinstance(reason, TransportError):
            raise reason from None
        code = "transport:unreachable"
        if isinstance(reason, socket.timeout) or "timed out" in str(reason).lower():
            code = "transport:timeout"
        elif isinstance(reason, ConnectionRefusedError):
            code = "transport:refused"
        elif isinstance(reason, socket.gaierror):
            code = "transport:dns"
        elif isinstance(reason, ssl.SSLError):
            code = "transport:tls"
        raise TransportError(code, "%s: %s" % (type(reason).__name__, reason)) from None
    except json.JSONDecodeError:
        raise TransportError("transport:nonjson") from None
    except Exception as exc:                                # noqa: BLE001
        raise TransportError("transport:other", type(exc).__name__) from None


def _stub_chat(cmd, payload, timeout):
    """`AHL_PRIVATE_TRANSPORT` seam: a command that reads the request JSON on stdin and writes an
    OpenAI-shaped response JSON on stdout. This is how the self-test proves THIS script's grading
    and bundle-writing run, with no server and no GPU (mirrors eval.sh's `AHL_LM_EVAL` seam)."""
    try:
        p = subprocess.run(cmd, shell=True, input=json.dumps(payload).encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise TransportError("transport:timeout", "stub transport timed out") from None
    if p.returncode != 0:
        raise TransportError("transport:stub_exit", "stub transport exit %d" % p.returncode)
    try:
        return json.loads(p.stdout.decode() or "{}")
    except json.JSONDecodeError as exc:
        raise TransportError("transport:nonjson", str(exc)) from None


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
    except Exception:                                       # noqa: BLE001
        raise TransportError("transport:unparseable") from None
    # Grade `content` only. A reasoning model that routes everything into `reasoning_content` and
    # leaves `content` empty scores 0 — which is the NemotronH think-off failure (AGENTS.md). That
    # used to surface only as `zero_score`; it now also raises `reasoning_routed`, because a
    # systematic 0 from a routing mistake is indistinguishable from the regression this gate
    # exists to catch, and the two must not share a verdict.
    return (msg.get("content") or ""), (msg.get("reasoning_content") or "")


# ── run ───────────────────────────────────────────────────────────────────────
def _digest(salt, prompt) -> str:
    return hashlib.sha256((salt + "\x00" + prompt).encode()).hexdigest()[:16]


def _assert_leakproof(rows) -> int:
    """Last line of defence before the bundle is written: every `reason` must be in the closed
    vocabulary, and every row must carry only the allowed keys. A row that fails is REDACTED, not
    dropped (dropping would change the population) — and it is announced, because it means a code
    path grew a new string and this check caught it."""
    allowed = {"id", "verdict", "reason", "latency_ms", "output_chars", "reasoning_chars",
               "prompt_sha", "checked", "vs_authored"}
    redacted = 0
    for r in rows:
        for k in list(r):
            if k not in allowed:
                r.pop(k)
                redacted += 1
        if not REASON_RE.match(str(r.get("reason", ""))):
            r["reason"] = "transport:other"
            redacted += 1
    return redacted


def run(args) -> int:
    global _ALLOW_REMOTE
    _ALLOW_REMOTE = bool(getattr(args, "allow_remote", False))
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("private set is not usable: %s" % exc, file=sys.stderr)
        return 2

    # Resolve and pin the target BEFORE a single item is read into a request body. The runner
    # checks this too; doing it here as well means the helper is safe to call directly and the
    # rule has exactly one implementation.
    if not os.environ.get("AHL_PRIVATE_TRANSPORT"):
        try:
            host, port, ips = resolve_target(args.target)
        except TargetRefused as exc:
            print("REFUSED: %s" % exc, file=sys.stderr)
            return 2
        if _ALLOW_REMOTE:
            print("  ! AHL_PRIVATE_ALLOW_REMOTE=1 — items will be sent to %s (%s). Every item you"
                  " send is one that host's operator could retain." % (host, ", ".join(ips)),
                  file=sys.stderr)

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
        chk = item.get("checked") if isinstance(item.get("checked"), dict) else None
        base = {"id": item["id"], "latency_ms": 0, "output_chars": 0, "reasoning_chars": 0,
                "prompt_sha": _digest(s["salt"], item["prompt"]),
                "checked": (chk or {}).get("verdict", "na")}
        try:
            content, reasoning = ask(args.target, args.model, item,
                                     float(args.timeout), int(args.max_tokens))
        except TransportError as exc:
            base.update(verdict="error", reason=exc.code, vs_authored="na",
                        latency_ms=int((time.time() - t0) * 1000))
            if exc.detail:
                print("  . %s: %s" % (item["id"], exc.detail), file=sys.stderr)
            return base
        passed, reason = grade(item, content)
        vs = "na"
        if base["checked"] in ("pass", "fail"):
            got = "pass" if passed else "fail"
            vs = "same" if got == base["checked"] else ("regressed" if base["checked"] == "pass"
                                                        else "improved")
        base.update(verdict="pass" if passed else "fail", reason=reason,
                    latency_ms=int((time.time() - t0) * 1000), output_chars=len(content),
                    reasoning_chars=len(reasoning), vs_authored=vs,
                    _text={"prompt": item["prompt"], "output": content})
        return base

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

    # Transcripts NEVER enter the bundle, and never enter the repo. Opt-in, 0600. (path 6)
    transcript_path = "na"
    if _env_flag("AHL_PRIVATE_KEEP_TRANSCRIPT"):
        try:
            transcript_path = _write_transcript(s, rows, args.run_id)
        except SetError as exc:
            print("REFUSED: %s" % exc, file=sys.stderr)
            return 2
    for r in rows:
        r.pop("_text", None)                # the single point where item text leaves this process

    graded = [r for r in rows if r["verdict"] in ("pass", "fail")]
    transport_failures = len(rows) - len(graded)
    passes = sum(1 for r in graded if r["verdict"] == "pass")
    requested = len(live) if not args.limit else min(int(args.limit), requested_all)
    empties = [r for r in graded if r["reason"] == "empty_content"]
    routed = [r for r in empties if r.get("reasoning_chars", 0) > 0]
    regressed = sorted(r["id"] for r in graded if r.get("vs_authored") == "regressed")
    unchecked_scored = [r for r in graded if r.get("checked") not in ("pass", "fail")]
    redacted = _assert_leakproof(rows)

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
            "champion": s["manifest"].get("champion", "na"),
            "items_total": len(s["items"]), "items_live": requested_all,
            "items_burned": len(s["burned"]), "items_scored": len(graded),
            "items_requested": requested, "passes": passes,
            "transport_failures": transport_failures,
            "empty_content": len(empties), "empty_with_reasoning": len(routed),
            "unchecked_items": len(unchecked_scored),
            "regressed_vs_authored": regressed,
            "redacted_fields": redacted,
            "min_items": MIN_ITEMS, "transcript": transcript_path,
            "ran_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    }
    outdir = bundle / re.sub(r"[^A-Za-z0-9_.\-]", "__", args.model)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / ("results_%s.json" % args.run_id)).write_text(json.dumps(doc, indent=1))
    # The per-item bitmap: ids + verdicts, no text. This is what a later PAIRED comparison
    # (`eval_private.sh compare` — McNemar on discordant items) needs, and it is the reason the
    # bundle is worth keeping at all.
    with open(bundle / "private" / "items.audit.jsonl", "w", encoding="utf-8") as fh:
        for r in sorted(rows, key=lambda x: x["id"]):
            fh.write(json.dumps(r, sort_keys=True) + "\n")

    # ── the SHIPPED Gate-2 predicate, then this layer's own tokens ────────────
    res = ev.assess(str(bundle), task, limit=(args.limit or None), conc=conc)
    verds = [v for v in ev.parse_validity(res["validity"]) if v != ev.V_OK]
    if len(graded) < MIN_ITEMS:
        verds.append(ev.tag_verdict(V_SMALL_N, task))
    if unchecked_scored:
        verds.append(ev.tag_verdict(V_UNCHECKED, task))
    # SYSTEMATIC routing only. One truncated answer that happens to carry reasoning text is not a
    # serving defect; a fifth of the set answering into the wrong channel is.
    routed_floor = max(2, len(graded) // 5)
    systematically_routed = bool(empties) and len(routed) == len(empties) \
        and len(empties) >= routed_floor
    if systematically_routed:
        verds.append(ev.tag_verdict(V_REASONING_ROUTED, task))
    floor = ev.status_floor(verds)
    bases = {ev.verdict_base(v) for v in verds}
    if floor == "ok" and (bases & PRIVATE_SUSPECT):
        floor = ev.STATUS_SUSPECT
    if bases & PRIVATE_FATAL:
        floor = ev.STATUS_VOID
    validity = ev.format_validity(verds)
    status = ev.apply_status(ev.STATUS_MEASURED, floor)
    is_citable = ev.citable(validity, status)

    # THE ABSOLUTE SCORE IS NOT PRINTED AND IS NOT WRITTEN TO THE COMMITTED JOURNAL.
    # A number that exists gets quoted, and the only defensible reading of this gate is the paired
    # one (docs/private-eval.md §5). `scores=na` travels to accuracy.tsv; the raw value stays in
    # the gitignored bundle for `compare` to use.
    print("\t".join((ev.NA, res["samples"], validity, status, str(conc),
                     "1" if is_citable else "0")))
    for r in res["reasons"]:
        # assess()'s reasons quote the score; keep the value out of the operator's terminal too.
        print("  ! " + re.sub(r"is (exactly )?[-0-9.]+", "is <withheld>", r), file=sys.stderr)
    if len(graded) < MIN_ITEMS:
        print("  ! %s: %d live items scored, floor is %d (AHL_PRIVATE_MIN_ITEMS). At n=20 the "
              "binomial SE is ~11 points — a set this small cannot support a keep/discard "
              "decision, so the row is recorded and NOT citable." % (task, len(graded), MIN_ITEMS),
              file=sys.stderr)
    if unchecked_scored:
        print("  ! %d scored item(s) carry no authoring-time `checked` verdict. Nobody can check "
              "this set's ground truth, so without it a failure cannot be attributed to the "
              "candidate rather than to a wrong answer key (docs/private-eval.md §7)."
              % len(unchecked_scored), file=sys.stderr)
    if systematically_routed:
        print("  ! every empty answer (%d) came with a non-empty `reasoning_content`: the model is "
              "routing its answer into the reasoning channel, which this grader does not read. "
              "That is a serving/template defect, not a quality result — the row is VOID."
              % len(routed), file=sys.stderr)
    if regressed:
        print("  i %d item(s) the champion passed at authoring now fail: %s"
              % (len(regressed), ", ".join(regressed[:12])), file=sys.stderr)
    if redacted:
        print("  ! %d bundle field(s) were REDACTED by the leak-proofing check — a code path "
              "produced a value outside the closed vocabulary. File a bug." % redacted,
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


def _write_transcript(s, rows, run_id) -> str:
    """A transcript is pure item text — the one artefact with no redaction at all. It may not live
    in the repo, and under the encrypted-at-rest workflow it may not live in the tmpfs either (it
    would be deleted on exit, which is what pushed operators to relocate it, and the obvious place
    is beside the code)."""
    raw = os.environ.get("AHL_PRIVATE_TRANSCRIPT_DIR")
    if raw:
        tdir = Path(raw).expanduser()
    elif _env_flag("AHL_PRIVATE_SET_EPHEMERAL"):
        # The set came from AHL_PRIVATE_EVAL_DECRYPT and lives in a directory this process is
        # about to delete. Writing there is a silent no-op; write to a durable private location
        # instead and say so.
        tdir = Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local/share")) \
            / "autohomelab" / "private-eval-transcripts"
        print("  i AHL_PRIVATE_KEEP_TRANSCRIPT=1 with a decrypted (tmpfs) set: the transcript "
              "would be deleted on exit, so it is written to %s instead. It is PLAINTEXT ITEMS. "
              "Delete it when you are done: scripts/eval_private.sh scrub" % tdir, file=sys.stderr)
    else:
        tdir = Path(s["dir"]) / "transcripts"
    tdir = tdir.expanduser()
    if _under(tdir, REPO_ROOT) or _under(tdir.parent, REPO_ROOT):
        raise SetError(
            "transcript directory %s is inside this PUBLIC repo (%s).\n"
            "  A transcript is the one file that is pure item text — no digests, no redaction.\n"
            "  Put it outside the tree: AHL_PRIVATE_TRANSCRIPT_DIR=~/.local/share/autohomelab/"
            "private-eval-transcripts" % (tdir, REPO_ROOT))
    tdir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(tdir, 0o700)
    except OSError:
        pass
    tp = tdir / ("%s.jsonl" % run_id)
    fd = os.open(str(tp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for r in rows:
            t = r.get("_text") or {}
            fh.write(json.dumps({"schema": SCHEMA, "kind": "transcript", "marker": MARKER,
                                 "id": r["id"], "verdict": r["verdict"],
                                 "prompt": t.get("prompt"), "output": t.get("output")}) + "\n")
    return str(tp)


# ── validate / taskname ───────────────────────────────────────────────────────
def cmd_validate(args) -> int:
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("INVALID: %s" % exc, file=sys.stderr)
        return 2
    print("ok  set_id=%s fp=%s visibility=%s items=%d live=%d burned=%d task=%s"
          % (s["set_id"], s["set_fp"], s["visibility"], len(s["items"]), len(s["live"]),
             len(s["burned"]), task_name(s)))
    rc = 0
    if len(s["live"]) < MIN_ITEMS:
        print("WARN: %d live items is below AHL_PRIVATE_MIN_ITEMS=%d — runs will record "
              "`small_n` and will not be citable." % (len(s["live"]), MIN_ITEMS), file=sys.stderr)
    if s["unchecked"] and not s["blessed"]:
        print("WARN: %d live item(s) have no `checked` verdict — runs will record `unchecked` and "
              "will not be citable. Record what the champion answered when you authored the item; "
              "it is the only way a later failure can be attributed (docs/private-eval.md §7)."
              % len(s["unchecked"]), file=sys.stderr)
    checked = [i for i in s["live"] if isinstance(i.get("checked"), dict)]
    if checked and all(i["checked"]["verdict"] == "pass" for i in checked):
        print("WARN: the champion passed EVERY checked item. An item the champion always passes "
              "contributes no discordant pair, which is the only currency this gate spends — aim "
              "for 50-80% champion pass rate (docs/private-eval.md §6).", file=sys.stderr)
    return rc


def cmd_taskname(args) -> int:
    try:
        s = load_set(args.set_dir)
    except SetError as exc:
        print("INVALID: %s" % exc, file=sys.stderr)
        return 2
    print("%s\t%s\t%s\t%d\t%d" % (task_name(s), s["set_id"], s["visibility"],
                                  len(s["live"]), len(s["burned"])))
    return 0


def cmd_check_target(args) -> int:
    global _ALLOW_REMOTE
    _ALLOW_REMOTE = bool(args.allow_remote)
    try:
        host, port, ips = resolve_target(args.target)
    except TargetRefused as exc:
        print("REFUSED: %s" % exc, file=sys.stderr)
        return 2
    print("ok\t%s\t%d\t%s" % (host, port, ",".join(ips)))
    return 0


# ── init ──────────────────────────────────────────────────────────────────────
def cmd_init(args) -> int:
    d = Path(args.dir).expanduser()
    if _under(d, REPO_ROOT):
        print("REFUSED: %s is inside this PUBLIC repo. The set must live outside the tree — the "
              "default is ~/.local/share/autohomelab/private-eval." % d, file=sys.stderr)
        return 2
    man_p, items_p = d / "manifest.json", d / "items.jsonl"
    if man_p.exists() or items_p.exists():
        print("REFUSED: %s already contains a set — init never overwrites (that would destroy the "
              "salt, and with it every earlier bundle's ability to be compared)." % d,
              file=sys.stderr)
        return 2
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    salt = secrets.token_urlsafe(32)
    man = {
        "schema": SCHEMA,
        "set_id": args.set_id,
        "visibility": "private",
        "salt": salt,
        "authored": datetime.now(timezone.utc).strftime("%Y%m%d"),
        "champion": {
            "model": args.champion or "",
            "runbook": args.runbook or "",
            "date": datetime.now(timezone.utc).strftime("%Y%m%d"),
        },
        "authoring_notes": (
            "salt: generated by `eval_private.sh init`, never published, never rotated (rotating "
            "it breaks comparison against every earlier bundle). champion: the model whose "
            "verdicts calibrated these items - fill in model and runbook before validating. Every "
            "item needs a `checked` verdict; see docs/private-eval.md sections 3, 6 and 7."),
    }
    fd = os.open(str(man_p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(man, fh, indent=2)
        fh.write("\n")
    fd = os.open(str(items_p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"schema": SCHEMA, "kind": "header", "marker": MARKER,
                             "visibility": "private"}) + "\n")
    print("initialised %s" % d)
    print("  manifest.json  fresh %d-char salt, mode 0600" % len(salt))
    print("  items.jsonl    header record only — add one item per line")
    print()
    print("Next: fill in manifest.champion.model and .runbook (validate refuses placeholders),")
    print("then author items. Each needs an authoring-time champion verdict:")
    print('  {"id":"h1-001","prompt":"...","grader":{"type":"exact","answers":["..."]},')
    print('   "checked":{"verdict":"pass","date":"%s"},"note":"what this item tests"}'
          % datetime.now(timezone.utc).strftime("%Y%m%d"))
    print("Then: scripts/eval_private.sh validate %s" % d)
    return 0


# ── compare: the ONLY defensible reading of this gate ─────────────────────────
def _mcnemar_exact_p(b: int, c: int) -> float:
    """Exact two-sided binomial (sign) test over the discordant pairs. Significance depends on
    DIRECTION, not count: 6-vs-0 is p=0.031 but 6-vs-1 is p=0.125 and 8-vs-2 is p=0.109. An
    operator who remembers "six items" and applies it to 6-vs-2 is reading a null as a break."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    total = 0
    for i in range(k + 1):
        total += _binom(n, i)
    p = 2.0 * total / (2.0 ** n)
    return min(1.0, p)


def _binom(n: int, k: int) -> int:
    num, den = 1, 1
    for i in range(k):
        num *= (n - i)
        den *= (i + 1)
    return num // den


def _load_audit(bundle):
    p = Path(bundle)
    if p.is_dir():
        cand = p / "private" / "items.audit.jsonl"
        if not cand.is_file():
            found = sorted(p.glob("**/private/items.audit.jsonl"))
            cand = found[0] if found else cand
    else:
        cand = p
    if not cand.is_file():
        raise SetError("no items.audit.jsonl under %s — that bundle was not written by the "
                       "private runner (or predates the bitmap)" % bundle)
    out = {}
    with open(cand, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            r = json.loads(line)
            out[r["id"]] = r
    return cand, out


def cmd_compare(args) -> int:
    """`compare` exists because nothing in the repo read the bitmap. The correct reading of this
    gate required hand-counting discordant items out of a file no tool touched, while an absolute
    percentage was printed as a headline and committed to a public column. A number that exists
    gets quoted; the fix is to compute the RIGHT number automatically and stop computing the wrong
    one at all."""
    try:
        pa, a = _load_audit(args.a)
        pb, b_rows = _load_audit(args.b)
    except (SetError, json.JSONDecodeError) as exc:
        print("cannot compare: %s" % exc, file=sys.stderr)
        return 2

    ids = sorted(set(a) & set(b_rows))
    only_a = sorted(set(a) - set(b_rows))
    only_b = sorted(set(b_rows) - set(a))
    if not ids:
        print("cannot compare: the two bundles share no item ids", file=sys.stderr)
        return 2
    mismatched = [i for i in ids
                  if a[i].get("prompt_sha") and b_rows[i].get("prompt_sha")
                  and a[i]["prompt_sha"] != b_rows[i]["prompt_sha"]]

    def _ok(r):
        return r.get("verdict") == "pass"

    def _graded(r):
        return r.get("verdict") in ("pass", "fail")

    usable = [i for i in ids if _graded(a[i]) and _graded(b_rows[i])]
    ungraded = len(ids) - len(usable)
    b_cnt = sum(1 for i in usable if _ok(a[i]) and not _ok(b_rows[i]))     # A pass, B fail
    c_cnt = sum(1 for i in usable if not _ok(a[i]) and _ok(b_rows[i]))     # A fail, B pass
    disc_b = [i for i in usable if _ok(a[i]) and not _ok(b_rows[i])]
    disc_c = [i for i in usable if not _ok(a[i]) and _ok(b_rows[i])]
    p = _mcnemar_exact_p(b_cnt, c_cnt)
    alpha = float(os.environ.get("AHL_PRIVATE_ALPHA", "0.05"))
    broke = (p < alpha) and (b_cnt > c_cnt)

    print("A (reference) : %s" % pa)
    print("B (candidate) : %s" % pb)
    print("paired items  : %d graded in both (%d ungraded, %d only in A, %d only in B)"
          % (len(usable), ungraded, len(only_a), len(only_b)))
    if mismatched:
        print("WARNING       : %d item(s) have DIFFERENT prompt digests in the two bundles — the "
              "set changed between runs, so this is not a paired comparison of the same "
              "population." % len(mismatched))
    print("discordant    : b = %d (A passed, B failed)   c = %d (A failed, B passed)"
          % (b_cnt, c_cnt))
    if disc_b:
        print("  A>B ids     : %s" % ", ".join(disc_b))
    if disc_c:
        print("  B>A ids     : %s" % ", ".join(disc_c))
    print("McNemar exact two-sided p = %.4f  (alpha %.3g)" % (p, alpha))
    print()
    verdict = ("CLASS-LEVEL BREAK against the champion" if broke
               else "no class-level break against the champion")
    print("private gate: %s (b/c = %d/%d, p = %.3f)." % (verdict, b_cnt, c_cnt, p))
    print()
    print("Paste that one sentence into the logbook. Do not add a percentage: the absolute number")
    print("is not recorded in accuracy.tsv on purpose (docs/private-eval.md §5).")
    print("Significance depends on DIRECTION, not count: 6/0 is p=0.031 but 6/1 is p=0.125 and")
    print("8/2 is p=0.109. Six discordants is only a break if they nearly all point one way.")
    if len(usable) < MIN_ITEMS:
        print()
        print("NOTE: only %d paired items. This comparison cannot detect anything but a "
              "class-sized break." % len(usable))
    return 4 if broke else 0


# ── the guard: what may be committed to a public repo ─────────────────────────
# (paths 2, 4, 6, 7.) The first guard had one test — "does this blob PARSE as a private manifest
# or a private items file?" — and eleven realistic shapes walked past it. It also failed OPEN:
# `sniff`'s stderr was discarded and ANY non-zero exit read as "not private", so `AHL_PYTHON=
# /bin/false` staged a verbatim set with `guard: ok`, and a >256 KiB items file died on SIGPIPE
# under `pipefail` (exit 141) and was likewise waved through. A security guard must fail closed,
# and it must be told what it is looking at rather than asked to guess from one shape.
#
# Two tiers:
#   HARD  structural evidence that the blob CONTAINS item records, a private manifest, or a
#         transcript. Blocks. Override: AHL_PRIVATE_GUARD_ALLOW=1 (loud).
#   WEAK  one item-shaped object, the marker string in prose, a CSV with prompt+answer columns.
#         Blocks with a narrower, separate override: AHL_PRIVATE_GUARD_SOFT_OK=1.
# A path allowlist (docs/, scripts/, the blessed example) keeps the guard off its own
# documentation — with a small budget, so the allowlist is not a hiding place.
GUARD_ALLOWLIST = ("docs/", "scripts/")
DOC_BUDGET_ITEMS = _env_int("AHL_PRIVATE_GUARD_DOC_BUDGET", 8)
DOC_BUDGET_MANIFESTS = 2
DOC_BUDGET_HEADERS = 2
_B64 = re.compile(rb"[A-Za-z0-9+/=\s]{96,}")


def _walk_json(obj, depth=0):
    if depth > 12:
        return
    yield obj
    if isinstance(obj, dict):
        for v in obj.values():
            yield from _walk_json(v, depth + 1)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_json(v, depth + 1)


def _item_shaped(o) -> bool:
    return (isinstance(o, dict) and isinstance(o.get("id"), str)
            and isinstance(o.get("prompt"), str) and isinstance(o.get("grader"), dict))


def _transcript_shaped(o) -> bool:
    return (isinstance(o, dict) and "id" in o and "verdict" in o
            and (isinstance(o.get("prompt"), str) or isinstance(o.get("output"), str)))


def _manifest_shaped(o) -> bool:
    return isinstance(o, dict) and o.get("schema") == SCHEMA and "salt" in o


def _header_shaped(o) -> bool:
    return isinstance(o, dict) and o.get("marker") == MARKER


def _whole_doc(text: str):
    try:
        yield from _walk_json(json.loads(text))
    except Exception:                                       # noqa: BLE001
        return


def _per_line(text: str):
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith(("{", "[")):
            continue
        try:
            obj = json.loads(line)
        except Exception:                                   # noqa: BLE001
            continue
        yield from _walk_json(obj)


def _embedded(text: str):
    """JSON objects embedded in prose — items pasted into a markdown fence, or a file with a
    prose preamble. Three of the eleven shapes that used to walk through the guard."""
    dec = json.JSONDecoder()
    seen = 0
    for m in re.finditer(r"\{", text):
        seen += 1
        if seen > 20000:
            break
        try:
            obj, _ = dec.raw_decode(text, m.start())
        except Exception:                                   # noqa: BLE001
            continue
        yield from _walk_json(obj)


def _count(objs):
    c = {"items": 0, "transcripts": 0, "manifests": 0, "headers": 0}
    for o in objs:
        if _header_shaped(o):
            c["headers"] += 1
        elif _manifest_shaped(o):
            c["manifests"] += 1
        elif _item_shaped(o):
            c["items"] += 1
        elif _transcript_shaped(o):
            c["transcripts"] += 1
    return c


def _csv_shaped(text: str) -> bool:
    head = "\n".join(text.splitlines()[:40])
    if "," not in head and "\t" not in head:
        return False
    try:
        rows = list(csv.reader(io.StringIO(head)))
    except Exception:                                       # noqa: BLE001
        return False
    for row in rows[:3]:
        cols = {c.strip().strip('"').lower() for c in row}
        if "prompt" in cols and cols & {"answer", "answers", "grader", "expected", "ground_truth"}:
            return True
    return False


def _scan(text: str, depth: int = 0):
    """-> dict of counts + flags. Recurses once into base64 payloads."""
    # The three extraction strategies overlap — a JSONL line is found by the per-line pass AND by
    # the embedded-object scan — so take the elementwise MAX, never the sum. Summing made one
    # item-shaped object look like three and turned the weak tier into a hard block.
    ev_ = {"items": 0, "transcripts": 0, "manifests": 0, "headers": 0,
           "marker": MARKER in text, "csv": _csv_shaped(text), "b64_hard": False}
    # The embedded-object scan is the expensive one (a raw_decode attempt per `{`). Above a few
    # MiB it is skipped, NOT the whole scan — the whole-document and per-line passes still cover
    # every JSONL and JSON shape, so a big blob is never waved through the way the old 256 KiB
    # `head -c` pipe waved one through.
    strategies = (_whole_doc, _per_line) if len(text) > 4 * 1024 * 1024 \
        else (_whole_doc, _per_line, _embedded)
    for strategy in strategies:
        c = _count(strategy(text))
        for k, v in c.items():
            ev_[k] = max(ev_[k], v)
    if depth == 0:
        for m in _B64.finditer(text.encode("utf-8", "replace")):
            chunk = re.sub(rb"\s", b"", m.group(0))
            if len(chunk) < 96:
                continue
            try:
                raw = base64.b64decode(chunk + b"=" * (-len(chunk) % 4), validate=True)
                inner = raw.decode("utf-8")
            except (binascii.Error, ValueError, UnicodeDecodeError):
                continue
            sub = _scan(inner, depth + 1)
            if _hard(sub):
                ev_["b64_hard"] = True
                for k in ("items", "transcripts", "manifests", "headers"):
                    ev_[k] += sub[k]
                break
    return ev_


def _hard(ev_) -> bool:
    return bool(ev_["b64_hard"] or ev_["headers"] or ev_["manifests"]
                or ev_["items"] >= 2 or ev_["transcripts"] >= 2)


def _weak(ev_) -> bool:
    return bool(ev_["marker"] or ev_["csv"] or ev_["items"] == 1 or ev_["transcripts"] == 1)


def _allowlisted(rel) -> bool:
    rel = str(rel or "").lstrip("./")
    return rel.startswith(GUARD_ALLOWLIST)


def classify(data: bytes, rel_path=None):
    """-> (tier, reason). tier is "hard" | "weak" | "clean"."""
    rel = str(rel_path or "").lstrip("./")
    if rel and is_blessed_example_file(rel, data):
        return "clean", "the blessed example set, byte-exact"
    # A file at the blessed PATH whose bytes have changed is not the example any more.
    if rel.startswith(EXAMPLE_REL + "/") and not is_blessed_example_file(rel, data):
        try:
            text = data.decode("utf-8", "replace")
        except Exception:                                   # noqa: BLE001
            text = ""
        ev_ = _scan(text)
        if _hard(ev_) or _weak(ev_):
            return "hard", ("the blessed example path with CHANGED contents — an edited example "
                            "is a private set")
    for pat in ("*.age", "*.gpg", "*.private.jsonl", "*.private.json"):
        if _fnmatch(rel, pat):
            return "hard", "filename shape reserved for private-eval material"
    if "private-eval" in rel.split("/") or rel.startswith("private-eval"):
        return "hard", "path reserved for private-eval material"
    if "transcripts" in rel.split("/"):
        return "hard", "path reserved for private-eval transcripts"
    text = data.decode("utf-8", "replace")
    ev_ = _scan(text)
    detail = ("items=%d transcripts=%d manifests=%d headers=%d marker=%s csv=%s b64=%s"
              % (ev_["items"], ev_["transcripts"], ev_["manifests"], ev_["headers"],
                 ev_["marker"], ev_["csv"], ev_["b64_hard"]))
    if _allowlisted(rel):
        over = (ev_["items"] > DOC_BUDGET_ITEMS or ev_["manifests"] > DOC_BUDGET_MANIFESTS
                or ev_["headers"] > DOC_BUDGET_HEADERS or ev_["transcripts"] > 0
                or ev_["b64_hard"])
        if over:
            return "hard", ("allowlisted path (%s) but far past the documentation budget: %s"
                            % (rel, detail))
        return "clean", ("allowlisted path (%s); evidence within the documentation budget: %s"
                         % (rel, detail))
    if _hard(ev_):
        return "hard", "structural: %s" % detail
    if _weak(ev_):
        return "weak", "weak evidence: %s" % detail
    return "clean", "no private-eval evidence"


def _fnmatch(name, pat) -> bool:
    import fnmatch as _fn
    return _fn.fnmatch(name, pat) or _fn.fnmatch(os.path.basename(name), pat)


def cmd_sniff(args) -> int:
    """Contract with the guard, deliberately POSITIVE-CONFIRMATION on both sides:

        exit 0 + stdout "PRIVATE<TAB>hard|weak<TAB>reason"   -> private-eval material
        exit 1 + stdout "CLEAN<TAB>reason"                   -> not
        anything else                                        -> the guard must FAIL CLOSED

    `/bin/false` exits 1, and under the old exit-code-only contract that read as "clean". Requiring
    a token on stdout means a broken interpreter cannot impersonate a verdict. (path 4)"""
    if getattr(args, "file", None):
        try:
            data = Path(args.file).read_bytes()
        except OSError as exc:
            print("SNIFF-ERROR\tcannot read %s: %s" % (args.file, exc), file=sys.stderr)
            return 3
    else:
        data = sys.stdin.buffer.read()
    tier, reason = classify(data, getattr(args, "path", None))
    if tier == "clean":
        print("CLEAN\t%s" % reason)
        return 1
    print("PRIVATE\t%s\t%s" % (tier, reason))
    return 0


def cmd_selfcheck(_args) -> int:
    """The guard runs this first. If the interpreter cannot get this far, the guard refuses the
    commit instead of assuming everything is clean."""
    probe = json.dumps({"schema": SCHEMA, "kind": "header", "marker": MARKER,
                        "visibility": "private"}).encode()
    tier, _ = classify(probe, "somewhere/items.jsonl")
    if tier != "hard":
        print("SELFCHECK-FAILED\tthe guard does not recognise its own header record",
              file=sys.stderr)
        return 3
    if classify(b"nothing to see here\n", "README.md")[0] != "clean":
        print("SELFCHECK-FAILED\tthe guard fires on plain prose", file=sys.stderr)
        return 3
    print("GUARD-READY")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate", help="parse + schema-check a private set")
    v.add_argument("--set", dest="set_dir", required=True)
    v.set_defaults(fn=cmd_validate)

    s = sub.add_parser("sniff", help="is this blob private-eval material? PRIVATE/CLEAN on stdout")
    s.add_argument("--file", default=None, help="read the blob from a file (avoids SIGPIPE)")
    s.add_argument("--path", default=None, help="the blob's repo-relative path, for the allowlist")
    s.set_defaults(fn=cmd_sniff)

    sc = sub.add_parser("selfcheck", help="prove the guard can evaluate anything at all")
    sc.set_defaults(fn=cmd_selfcheck)

    t = sub.add_parser("taskname", help="print task<TAB>set_id<TAB>visibility<TAB>live<TAB>burned")
    t.add_argument("--set", dest="set_dir", required=True)
    t.set_defaults(fn=cmd_taskname)

    ct = sub.add_parser("check-target", help="resolve a TARGET and prove the peer is loopback")
    ct.add_argument("--target", required=True)
    ct.add_argument("--allow-remote", action="store_true")
    ct.set_defaults(fn=cmd_check_target)

    c = sub.add_parser("compare", help="McNemar over two bundles' item bitmaps")
    c.add_argument("--a", required=True, help="reference bundle (the champion)")
    c.add_argument("--b", required=True, help="candidate bundle")
    c.set_defaults(fn=cmd_compare)

    i = sub.add_parser("init", help="create a private set with a fresh salt, outside the repo")
    i.add_argument("--dir", required=True)
    i.add_argument("--set-id", dest="set_id", default="ahl-holdout-1")
    i.add_argument("--champion", default="")
    i.add_argument("--runbook", default="")
    i.set_defaults(fn=cmd_init)

    r = sub.add_parser("run", help="grade the set against a live endpoint, write the bundle")
    r.add_argument("--set", dest="set_dir", required=True)
    r.add_argument("--bundle", required=True)
    r.add_argument("--target", required=True)
    r.add_argument("--model", required=True)
    r.add_argument("--run-id", dest="run_id", default="run")
    r.add_argument("--limit", default=None)
    r.add_argument("--conc", default=1)
    r.add_argument("--allow-remote", dest="allow_remote", action="store_true")
    r.add_argument("--timeout", default=os.environ.get("AHL_PRIVATE_TIMEOUT", "600"))
    r.add_argument("--max-tokens", dest="max_tokens",
                   default=os.environ.get("AHL_PRIVATE_MAX_TOKENS", "2048"))
    r.set_defaults(fn=run)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
