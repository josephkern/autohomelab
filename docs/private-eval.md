# The tier-4 private held-out eval

> **Status: the mechanism is built, adversarially reviewed and self-tested; no real set exists
> yet.** What is committed is the runner (`scripts/eval_private.sh`), the schema, the guard, and a
> deliberately fake worked example (`evalsets/private-example/`). Authoring the real items is a
> human job and is the whole of the remaining work.
>
> **Read §8 before you author anything.** An adversarial verifier found twelve leakage paths
> through the first version of this layer — four of them HIGH — while its own 139-check self-test
> reported green. All twelve are closed and each has a regression test that fails without its fix.
> Two structural weaknesses are *not* closed, because they cannot be closed by code; §8 states
> them plainly instead of leaving a warning nobody can obey.

Every quality signal this project has is public, and therefore contaminable:

| tier | signal | why it is not enough |
|---|---|---|
| 1 | `gsm8k`, `mmlu` | scraped into every pretraining corpus; useful only as a **recovery delta** |
| 2 | `mmlu_pro` | harder and less memorised, still public and still scraped |
| 3 | LiveBench, LiveCodeBench | resistant only for problems postdating a model's cutoff, and the public refresh has lapsed before (docs/contamination-resistant-evals.md) |
| **4** | **this** | **the only fully-uncontaminated signal available for a promotion decision** |

That is the entire argument for building it. It is not an argument that it is a *strong* signal —
see [What this cannot support](#what-this-signal-cannot-support), and read that section before you
quote a number from it.

---

## 1. Threat model

The asset is **the unpublished-ness of a few dozen short questions**. It has one failure mode,
irreversible: once an item is in a corpus a future model might train on, it is burned, permanently.
There is no revocation, no rotation that recovers the old items, and no way to know for certain
that it happened. So every control below is about *preventing* disclosure, never about detecting or
recovering from it.

| # | vector | why it is real | control |
|---|---|---|---|
| 1 | **`git push`** | `github.com/josephkern/autohomelab` is PUBLIC. A committed item is published the moment it is pushed, and `git rm` later does not help — the blob stays in the history and in every clone that already fetched it | items live **outside the tree** by default; `.gitignore` patterns; `scripts/eval_private.sh guard` as a **pre-commit AND pre-push** hook; the runner **refuses** to run any set that sits inside the repo except the byte-exact blessed example |
| 2 | **the eval bundle under `results/**/data/`** | this is the one that catches people. The runner writes a bundle exactly like `eval.sh` does, and the obvious implementation writes prompts and completions into it. `results/**/data/` is gitignored — but gitignore is not a threat model: bundles get tarred into bug reports, copied to another machine, read by a future agent, and swept up by backups | **the bundle never receives item text at all.** Per item it records the id, a *salted* digest of the prompt, the verdict, latency and the output length. Verdict `reason`s come from a **closed vocabulary** enforced by `_assert_leakproof()`, so neither an author-written `must_not_contain` string nor an HTTP error body can ride along |
| 3 | **backups** | a nightly backup of `$HOME` copies `~/.local/share/autohomelab/private-eval` off the box, often to a third party | keep the set **encrypted at rest** and decrypt only into tmpfs — see §2. Then a backup holds ciphertext |
| 4 | **the model provider's request log** | a hosted endpoint logs prompts, may retain them, and may train on them. Sending the set to one is a publication with extra steps | the runner **resolves the target and pins the connected peer to loopback**, and disables proxies unconditionally. Non-loopback needs `AHL_PRIVATE_ALLOW_REMOTE=1` and warns loudly even then |
| 5 | **an HTTP proxy** | `urllib` honours `http_proxy`/`https_proxy`/`ALL_PROXY` and does **not** bypass a proxy for a loopback URL. A URL-string check therefore proves nothing: `TARGET=http://127.0.0.1:8000` with `http_proxy` set sends every prompt to the proxy operator, silently, while the refusal prints nothing | the opener is built with `ProxyHandler({})`; the environment is never consulted for a proxy, and the runner says so when it sees one set |
| 6 | **the serving engine's own logs** | vLLM can log request bodies at debug level, and `docker logs` output lands in `.ahl_*.log` on this box | do not raise vLLM log verbosity while the private gate runs; the `.ahl_*.log` files are gitignored, but treat them as containing items and delete them after a debug session |
| 7 | **an AI coding agent** (including whichever one you are talking to) | an agent working in this repo reads files and ships their contents to a model provider as context. If the set lived in the tree, running an agent here would publish it — quietly, and with no commit to notice afterwards | items outside the tree; **never paste an item into an agent session, an issue, or a chat**. See §8, which is honest about what that costs |
| 8 | **the transcript you write while debugging a failed item** | you will want the prompt and the raw output when an item fails, and that file is exactly the leak: it is pure item text with no digesting and no redaction | transcripts are **opt-in** (`AHL_PRIVATE_KEEP_TRANSCRIPT=1`), written mode `0600` outside the repo, **refused** anywhere under `$REPO_ROOT`, and recognised by the guard's `sniff` by record shape even with the marker stripped |
| 9 | **the committed `accuracy.tsv` row** | it is public, and it used to carry the score | the score is no longer written. Column 10 is `na`; the row carries the *set fingerprint* (`private_<set_id>.<fp8>`) so a reader can tell which version of the set produced it, and nothing else. See §5 |
| 10 | **a self-declared `visibility` header** | `"visibility": "example"` was one forgeable field that simultaneously disabled the in-repo refusal, missed every `.gitignore` pattern and exempted the file from the guard — and the way to get it was to copy the example, which the runner's own help text told you to do | item-shaped content is **private by default**. `"example"` is a fact about being *this path* with *these bytes* (both sha256s are pinned in `eval_private_set.py`), not a claim a file can make about itself |

**Why the digest is salted, and why the salt has rules.** `sha256(prompt)` would be a *confirmation
oracle*: anyone holding a guessed question could hash it and check the bundle. The digest is
`sha256(salt ‖ prompt)`, and the salt lives only in `manifest.json`. That only works if the salt is
actually secret and actually long, so the runner **rejects the published example salt by value**,
rejects anything under 32 characters, and rejects padding with fewer than 8 distinct characters.
`scripts/eval_private.sh init` generates one with `secrets.token_urlsafe(32)`. Never copy a salt,
and never rotate one — rotating breaks comparison against every bundle you already have.

**Out of scope, stated rather than implied.** An attacker with read access to your home directory
and your decryption key has the set. This design does not defend against that; it defends against
*accident* — the commit nobody meant to make, the bundle nobody thought about, the proxy nobody
knew was set. Every real leak this project is likely to suffer is an accident.

---

## 2. Storage layout

```
~/.local/share/autohomelab/private-eval/       <- $AHL_PRIVATE_EVAL_DIR (default). NOT in the repo.
├── manifest.json        set_id, visibility=private, salt, champion, authoring notes
└── items.jsonl          line 1 = header record, then one item per line

~/.local/share/autohomelab/private-eval-transcripts/   <- only with AHL_PRIVATE_KEEP_TRANSCRIPT=1

<repo>/evalsets/private-example/               <- committed, FAKE, blessed by path + sha256
<repo>/scripts/eval_private.sh                 <- the runner
<repo>/scripts/eval_private_set.py             <- parser + graders + transport + guard + compare
<repo>/scripts/eval_private_selftest.sh        <- the acceptance suite, no GPU
```

The split is deliberate: **the code, the schema and the docs are public; only the items are not.**
Anyone can read how the gate works, audit the graders, and run the whole thing against the example
set. What they cannot do is see the questions.

Create a set with `init` — never by copying the example, whose salt is published in this repo:

```bash
scripts/eval_private.sh init                      # default location, fresh salt, mode 0600
$EDITOR ~/.local/share/autohomelab/private-eval/manifest.json    # fill in champion.model
scripts/eval_private.sh validate
```

### Encrypted at rest (recommended once a real set exists)

`AHL_PRIVATE_EVAL_DECRYPT` is a command that emits a **tar stream of the set on stdout**. The
runner unpacks it into a `0700` directory under `$XDG_RUNTIME_DIR` (tmpfs, per-user, gone at
logout) and deletes it on exit. Nothing is ever unpacked inside the repo, and if `$XDG_RUNTIME_DIR`
is unset the runner **refuses** rather than unpacking plaintext onto ordinary disk
(`AHL_PRIVATE_ALLOW_DISK_TMP=1` overrides, loudly).

```bash
# once, to seal it (age: https://github.com/FiloSottile/age)
tar -C ~/.local/share/autohomelab/private-eval -c manifest.json items.jsonl \
  | age -R ~/.ssh/id_ed25519.pub > ~/private-eval.tar.age

# per run
export AHL_PRIVATE_EVAL_DECRYPT="age -d -i ~/.ssh/id_ed25519 ~/private-eval.tar.age"
scripts/eval_private.sh runbooks/<org>/<model>/<config>.sh
```

A failed decrypt fails **closed**: exit 1, no row, no gate.

**What SIGKILL leaves behind — the honest version.** `SIGTERM`, `SIGINT`, `SIGHUP` and normal exit
all clean up. `SIGKILL` cannot be trapped, so `kill -9`, an OOM kill or a power cut leaves a `0700`
directory in `$XDG_RUNTIME_DIR` containing **the full plaintext set and the salt**. Two
consequences, both real:

- it is tmpfs, so it does not survive a reboot and is never backed up — but it does survive until
  logout, readable by anything running as you (including an agent);
- **the salt exposure is retroactive**: anyone who reads that directory can recompute the digests
  in every bundle you have ever archived, turning them back into the confirmation oracle the salt
  exists to prevent.

Mitigations that exist: an owner pid is recorded in the directory, and **every** subsequent
invocation of `eval_private.sh` sweeps orphans whose owner is gone. `scripts/eval_private.sh scrub`
sweeps immediately and also deletes transcripts. The residual window — between the SIGKILL and the
next invocation — is not zero and cannot be made zero from inside the process.

### The guard

```bash
scripts/eval_private.sh install-guard    # writes .git/hooks/pre-commit AND pre-push (per-clone)
scripts/eval_private.sh guard            # or run it by hand
```

Two tiers, because the first version's single structural test recognised **2 of 11** realistic
shapes an item file actually takes:

- **HARD (blocks).** Reserved filename/path shapes (`*.age`, `*.private.jsonl`, `private-eval/`,
  `transcripts/`); a header record carrying the marker; a manifest object; **two or more**
  item-shaped objects (`id`+`prompt`+`grader`) or transcript records (`id`+`verdict`+`prompt`/
  `output`) found anywhere in the blob — as JSONL, as a JSON array, nested under another key,
  pasted into markdown prose, behind a prose preamble, or base64-encoded. Override:
  `AHL_PRIVATE_GUARD_ALLOW=1`, which announces itself.
- **WEAK (blocks, with a narrower override).** One item-shaped object, the marker string in prose,
  a CSV whose header has `prompt` plus an answer column. Override: `AHL_PRIVATE_GUARD_SOFT_OK=1`,
  which does **not** disable the hard tier.

It **fails closed**. `sniff` must print `PRIVATE` or `CLEAN`; an exit code alone is not a verdict,
because `/bin/false` exits 1 and the old contract read that as "clean". A blob it cannot read, an
interpreter it cannot start, or any answer it does not understand blocks the commit. The blob is
read whole into a temp file rather than piped through `head -c`, because that pipe died on SIGPIPE
under `pipefail` and waved every items file over 256 KiB straight through.

A **path allowlist** (`docs/`, `scripts/`, and the blessed example) keeps the guard off its own
documentation — the first version grepped for the marker and blocked this very file, which is how a
guard gets switched off. The allowlist carries a **budget** (default 8 item-shaped records, tunable
with `AHL_PRIVATE_GUARD_DOC_BUDGET`) that is far below `AHL_PRIVATE_MIN_ITEMS`, so it cannot hold a
usable set; exceed it and the file blocks like anything else. Residual, stated: a determined author
could spread a few items per file across many allowlisted files. The guard is the third line of
defence, not the first — the first is that the set is not in the tree at all.

**If you are an agent** and a hook blocks you: do not retry with `--no-verify`, and do not disable
the hook. This is the one failure in this repo that a follow-up commit cannot undo. The `pre-push`
hook exists precisely because that retry is the predictable next move.

---

## 3. The schema

`manifest.json`:

```json
{
  "schema": "ahl-private-eval/1",
  "set_id": "ahl-holdout-1",
  "visibility": "private",
  "salt": "<32+ random chars from `init`, never published, never rotated>",
  "authored": "20260820",
  "champion": {"model": "Qwen/Qwen3-x", "runbook": "runbooks/.../x_final.sh", "date": "20260820"}
}
```

`champion` is **required** and may not contain a placeholder. It records which model's verdicts
calibrated the items; §7 is why.

`items.jsonl` — **line 1 is a header record**, then one item per line. Fields: `id` (unique),
`prompt`, `grader`, `checked`, and optionally `system`, `tags`, `max_tokens`, `authored`, `note`,
`burned`. One line, for shape:

```json
{"id":"h1-001","tags":["multi-step"],"prompt":"...","grader":{"type":"exact","answers":["..."]},"checked":{"verdict":"pass","date":"20260820"},"note":"what this tests"}
```

The header record is `{"schema":"ahl-private-eval/1","kind":"header","marker":"…","visibility":"private"}`
— the guard recognises it, and its `visibility` must agree with the manifest's.

| grader | rule |
|---|---|
| `exact` | the normalised whole reply **or its last non-empty line** equals one of `answers` |
| `contains` | a normalised `answers` entry appears anywhere in the reply |
| `regex` | `re.search(pattern, reply, MULTILINE\|IGNORECASE)`; `case_sensitive`/`dotall` opt in |
| `numeric` | the last `\boxed{…}`, else the last number in the reply, within `tol` (default 0) |

Normalisation lowercases, strips code fences, `**`, `` ` ``, collapses whitespace and trims
trailing `.!?"'`. Any grader may carry `must_not_contain`, checked **first** — it fails the item
outright even if the answer is present. The bundle records only its **index**, never the string.

**Objective graders only. There is deliberately no LLM judge**: it would ship every item to a
second model (threat #4), and the repo's own contamination research prefers objective ground-truth
grading anyway. If an item cannot be graded by string or number, it does not belong in this set.

`burned` marks an item as compromised: `{"date":"20260820","reason":"pasted into a public issue"}`.
Burned items **stay in the file forever** (the project's "experiments are the record" rule) and are
excluded from scoring. The live count drops, which shows up in the row's `samples` column — that is
how a population change stays auditable rather than silently shifting the score.

Validate before you trust anything: `scripts/eval_private.sh validate`. A set that is 95%
parseable is **not** a set — any bad line is refused outright (exit 2, no row), because silently
dropping an unreadable item changes the population the score is over, which is precisely the defect
`short_sample` exists to catch on Gate 2.

---

## 4. Running it

```bash
scripts/serve.sh runbooks/<org>/<model>/<config>.sh      # the endpoint must already be up
scripts/eval_private.sh runbooks/<org>/<model>/<config>.sh
```

It writes one row to the **same 16-column `accuracy.tsv`** as `eval.sh`, with the same validity
vocabulary and the same exit ladder — one concept, not two:

```
suite=private-attest   tasks=private_<set_id>.<fp8>   scores=na
samples=private_<set_id>.<fp8>=40/40   validity=ok   status=measured
```

`suite` says `private-attest` and `scores` says `na` on purpose. §5.

| exit | meaning |
|---|---|
| `0` | citable — an **attestation**, and still a small-sample one, see §5 |
| `1` | **the set is not installed on this node** (no row), or the run finished with transport failures |
| `2` | refused before running: unusable set, non-loopback target, private set inside the repo, transcript dir inside the repo |
| `3` | killed by a signal — **no row**, because a partial private run is not a measurement |
| `4` | the row is written and is **not citable** |

**Exit 1 with no set is the common case for anyone who clones this repo.** It prints an explanation
and how to author one. An integrator must read it as **GATE NOT RUN**, never as PASS; there is no
configuration under which a missing set exits 0.

Verdict tokens are the shipped Gate-2 ones (`no_score`, `nonfinite`, `short_sample`, `zero_score`,
`no_samples` — `scripts/eval_validity.py`, computed by that same code, not a copy), plus three of
its own:

| token | rule | severity |
|---|---|---|
| `small_n` | fewer than `AHL_PRIVATE_MIN_ITEMS` (**30**) live items scored | suspect |
| `unchecked` | a scored item carries no authoring-time champion verdict (§7) | suspect |
| `reasoning_routed` | every empty answer came with a non-empty `reasoning_content` | **void** |

None of these is a tolerance test: each is a structural fact about the run, never a judgement about
a value. Nothing in this layer compares a score to a reference or a floor, for the reason in
docs/validity-contract.md — a threshold on the value would imply a precision the sample size cannot
deliver.

`reasoning_routed` deserves its own line. The grader reads `content` only, deliberately (AGENTS.md:
NemotronH think-off generates zero tokens into `content`). A model that routes its answer into
`reasoning_content` therefore scores **0 on every item** — a systematic false signal shaped exactly
like the catastrophic regression this gate exists to catch. When the empties all carry reasoning
text, the run is void, not zero.

Two consequences worth knowing in advance. The committed example set has **3 live items**, so
running it can never produce a citable row — the example structurally cannot be mistaken for the
gate. And running the example is also harmless in the other direction: its salt is published, so
its digests are an oracle by design.

---

## 5. What the number is, and why it is not written down

**The absolute percentage is not computed into any committed column, and is not printed.** It lives
only in the gitignored bundle. That is a deliberate reversal of the obvious design, and the reason
is behavioural rather than statistical: the first version computed the percentage automatically,
printed it as the headline, and wrote it into column 10 of a **public, committed** `accuracy.tsv`,
while the correct reading required hand-counting discordant items out of a file **nothing in the
repo read**. A number that exists gets quoted. So the wrong number is no longer produced and the
right one is produced by a command.

### How many items are enough?

**30 is the floor the runner enforces, 60–80 is the number to aim for, and even at 80 this cannot
resolve a small regression.** Binomial standard error is `sqrt(p(1-p)/n)`:

| n | SE at p=0.5 | SE at p=0.8 | 95% CI half-width at p=0.8 |
|---|---|---|---|
| 20 | 11.2 pts | 8.9 pts | ±17 pts |
| 30 | 9.1 | 7.3 | ±14 |
| 60 | 6.5 | 5.2 | ±10 |
| 80 | 5.6 | 4.5 | ±9 |
| 100 | 5.0 | 4.0 | ±8 |

For scale: the repo already records that `LIMIT=100` on gsm8k/mmlu (SE ~4.3 pts) is **wider than
the KEEP rule's ~1% tolerance** and can only catch gross breakage. A private set of 60 is *worse*
than that on the absolute number. If you read one row of this table, read that one.

### The paired reading is the gate

Run reference and candidate against the same set in the same session, then:

```bash
scripts/eval_private.sh compare <champion-bundle> <candidate-bundle>
```

It reads both `private/items.audit.jsonl` bitmaps, checks the prompt digests agree (so you cannot
silently compare two different sets), counts the discordant items — the ones one config passes and
the other fails — and prints the McNemar exact two-sided p and **the one sentence to paste into the
logbook**:

```
private gate: no class-level break against the champion (b/c = 2/1, p = 1.000).
```

That sentence is the whole claim this gate is entitled to make. Not a percentage, not a comparison
of percentages.

**Where the sentence lives.** `accuracy.tsv` has no free-text column — the 16 are fixed by
`scripts/eval_validity.py` and this layer does not own that file — so the paired result goes in the
model's `logbook.md`, beside the row's `run_id`. `compare` prints it ready to paste. The committed
row's job is only to say *which* set fingerprint ran against *which* config on *which* date; the
logbook says what it meant.

**Significance depends on DIRECTION, not on count: 6-vs-0 is p=0.031, but 6-vs-1 is p=0.125
and 8-vs-2 is p=0.109.** This is the fragility the previous version of
this document had exactly one clause about, which is how an operator ends up applying a "six items"
rule to a 6-vs-2 result:

| b vs c (one way vs the other) | exact two-sided p | verdict at α=0.05 |
|---|---|---|
| 4 vs 0 | 0.125 | not significant |
| 5 vs 0 | 0.063 | not significant |
| **6 vs 0** | **0.031** | **significant** |
| 6 vs 1 | 0.125 | **not** significant |
| 7 vs 0 | 0.016 | significant |
| 7 vs 1 | 0.070 | not significant |
| 8 vs 2 | 0.109 | not significant |
| 9 vs 1 | 0.021 | significant |

Six discordants is only a break if they nearly all point one way. `compare` computes it so you do
not have to remember this table; the table is here so you can check `compare`.

The design consequence: a candidate that breaks a whole *class* of behaviour shows up even at
n=40, while a uniform 2-point degradation never will at any size you will realistically author. So
build the set as **6–8 capability classes with at least 5 items each** (instruction-format
compliance, multi-step arithmetic, long-context recall, tool-shaped output, refusal-free factual
recall, negation/distractor handling, …), so a class-wide break produces a class-sized discordance.

Practical consequence for the loop: this gate belongs at **finalize**, against the promotion
candidate and the current champion, in one session. It does not belong in the per-candidate tuning
loop — its power is too low to adjudicate a 3% throughput trade, and every run is an extra
opportunity to leak.

---

## 6. Authoring items that resist contamination

1. **Invent the ground truth.** An item whose answer exists on the public internet is a memorisation
   probe with extra steps. Prefer questions about facts you construct — a small fictional system with
   consistent rules, a computation over numbers you chose, a document you wrote.
2. **Make the answer short and mechanically checkable.** One token, one number, one exact line. If
   you find yourself wanting a judge, rewrite the item.
3. **Test capability, not trivia.** Multi-step composition, format compliance, holding a constraint
   across a long prompt, noticing a distractor. Trivia is exactly what public benchmarks already
   cover and exactly what contamination inflates.
4. **Calibrate the difficulty against the models you actually serve.** An item every model passes
   and an item every model fails both contribute zero discordant pairs, which is the only currency
   this gate spends. Aim for items around 50–80% pass rate on the current champion — and record
   what it answered, in `checked` (§7).
5. **Tag by class**, and keep the classes balanced — see the McNemar argument in §5.
6. **Write down what you meant to test** in `note`. In six months the item's *purpose* is the part
   you will have forgotten, and it is what tells you whether a failure is a regression or a bad item.
7. **Never source items from anything the model may have seen you write**: your public repos, your
   issues, your blog, or a chat session with a hosted model.

### How to tell an item has been burned

You mostly cannot, which is why prevention is the whole design. What you can act on:

- **Disclosure you know about.** The item was pasted into an issue, a chat with a hosted model, a
  screenshot, a talk, a backup you no longer control. Mark it burned the same day; do not
  rationalise it.
- **A verbatim-phrasing tell.** A model reproduces your exact wording, your variable names, or an
  incidental detail of the prompt that the answer did not require. Memorisation echoes the surface
  form; capability does not.
- **A discontinuous jump.** An item that models of a given class reliably failed is suddenly passed
  by a *newer* model of the same class, while the rest of its class stays flat. One item moving on
  its own is a contamination signal; the whole set moving is capability.
- **Impossible confidence on invented facts.** A model answers a question about your fictional
  system with detail you never provided in the prompt.
- **Time.** Any item that has existed through several model generations on a networked box should be
  treated as decaying even with no specific evidence. Rotate a fraction of the set periodically and
  record `authored` dates so the age distribution is visible.

Burning an item is cheap and un-burning is impossible: when in doubt, mark it.

---

## 7. How to tell an item is WRONG (not burned) — and why `checked` is required

Everything in §6 is about an item that has leaked. There is a second failure that is worse because
it is silent: **an item whose answer key is wrong, or whose grader is tighter than the question.**

Nobody can check this set's ground truth. It is unpublished, so there is no second opinion, no
upstream fixture, no other lab's number to compare with. A wrong key or an over-tight `exact`
produces a permanent, systematic false signal that looks *exactly* like the regression the gate
exists to catch — and it will look that way in every future run, against every future candidate.
The `reasoning_routed` case is the same failure at set scale: grading `content` only means a model
routing into `reasoning_content` scores 0 on everything.

The cheap defence is **attribution, recorded at authoring time**:

```json
"checked": {"verdict": "pass", "date": "20260820", "model": "Qwen/Qwen3-x"}
```

Write down what the champion actually answered when you wrote the item. Then:

- an item that the champion **passed** at authoring and a candidate now fails is a *candidate*
  signal — that is the discordant pair the gate is built on;
- an item that the champion **failed** at authoring and still fails is an item you have not
  calibrated, not evidence about anything;
- an item that fails for *every* model you have ever run, including the one you wrote it against,
  is a **wrong item**. Fix it or delete it. It is not measuring capability.

The runner records each item's live verdict against its `checked` verdict, prints the ids that
regressed against authoring, and emits the `unchecked` validity token — not citable — if any scored
item has no `checked` field. `manifest.champion` is required for the same reason at set scale: six
months from now, "which model said these answers were right?" must have an answer.

**Concretely, when an item fails:** first ask whether the *champion* still passes it in the same
session. If it does, you have a candidate regression. If it does not, you have a burned item, a
wrong item, or a serving defect — and `reasoning_routed` / `zero_score` / `empty_content` in the
validity column tell you which of those it is before you go looking at the item at all.

---

## 8. Two weaknesses this design does not solve

Written down rather than mitigated, because a control that cannot work is worse than an
acknowledged gap.

### The gate cannot be debugged by its only worker

**This project is operated by AI agents.** The threat model (vector #7) forbids pasting an item
into an agent session — and the debugging loop that the transcript feature exists to serve *is*
that step. When an item fails and you want to know why, the thing you need to look at is precisely
the thing you may not show the worker.

That is a **structural conflict**, not an oversight, and it plays out mechanically in two of the
twelve closed paths. Path 6: the transcript is the one artefact with no redaction, the recommended
encrypted-at-rest workflow made writing it a silent no-op, and the natural fix an operator reaches
for is to relocate it somewhere convenient — which is beside the code, in the repo. Path 9: the
decrypted plaintext survives a `kill -9` in `$XDG_RUNTIME_DIR`, where anything running as you can
read it, an agent included.

What this layer does about it: refuse the repo, refuse the tmpfs no-op, `0600` everything, sweep
orphans, and ship `scrub`. What it cannot do is make the debugging loop safe. So the operating
rule, stated as a rule rather than as a warning:

> **A failing private item is debugged by a human, at a terminal, with the agent not in the loop —
> or it is not debugged.** If that is not possible, mark the item `burned` and write a replacement.
> Burning one item costs less than leaking the set, and it is the only exit that is not a
> rationalisation.

An agent asked to investigate a private-eval failure should say this, and stop.

### Nobody can check the ground truth, so the row is an attestation

A `results.tsv` throughput row can be re-run by a stranger with the same hardware. A private-eval
row cannot be checked by anyone but the holder of the set — which sits in direct tension with
charter rule 1 ("reproducibility is paramount"). The fingerprint in the task name tells a reader
*which* unpublished set produced the row; it does not tell them how to verify it, and no design can.

So the row is labelled what it is: `suite=private-attest`, `scores=na`. It **attests** that a set
of a known fingerprint was run against a known config on a known date and produced a bitmap. It is
not a measurement anyone can audit. Treat it as an internal gate, never as a published claim about
the model, and never quote it without the `compare` sentence beside it.

---

## What this signal cannot support

Stated plainly, because the reason to build this is that it is the *only* uncontaminated signal,
not that it is a good one.

- **It has weak statistical power.** §5 is the whole story: ±10–17 points at realistic sizes on the
  absolute number. It can catch a config that is broken. It cannot adjudicate a 1% quality
  difference, and no amount of care in authoring changes that — it is arithmetic.
- **It measures our blind spots, not the model's.** We author the items, so the set tests what we
  thought to test. A capability nobody here thought of is invisible to it, permanently and silently.
  Public benchmarks are contaminated but broad; this is clean and narrow. They are not substitutes
  for each other.
- **It decays from use, not just from leaks.** Every promotion decision made against the same 60
  items fits the serving stack a little more tightly to those 60 items. That is overfitting with a
  human in the loop, and it is invisible in the score.
- **It cannot be reproduced by anyone else**, and its ground truth cannot be checked by anyone at
  all. See §7 and §8.
- **It never produces a number worth quoting on its own.** Cite it as "passed the private gate"
  plus the `compare` sentence. An absolute private-eval percentage in a logbook is a number
  nobody — including its author, six months later — can interpret, which is why the runner no
  longer produces one.

---

## Integration status and what it needs from files this layer does not own

`scripts/eval_private.sh` is standalone today. Folding it into `scripts/suite.sh` as an optional
Gate-2 tier needs three small changes in files owned elsewhere, listed here so they are not
rediscovered:

1. **`suite.sh`**: call it after `eval.sh` at finalize, and map its exit **1 to "GATE NOT RUN"**,
   not to a failure and never to a pass. A clone with no set must report the gate as absent.
2. **`scripts/eval_validity.py`**: register `small_n`, `unchecked` and `reasoning_routed` in the
   documented token table so this layer's extensions are part of the shared vocabulary rather than
   an appendix here. (The runner already computes its status floor correctly; this is documentation
   of record, not behaviour.)
3. **`AGENTS.md`**: add `private-attest` to the `suite` column's value list in the `accuracy.tsv`
   schema, and the three tokens to the Gate-2 token table, in the same commit as (2).

Self-test: `scripts/eval_private_selftest.sh` — synthetic sets, stub servers, a loopback stdlib
HTTP server for the real transport path, and a section that is one regression check per closed
leakage path. No docker, no serve, no lm-eval, no GPU.
