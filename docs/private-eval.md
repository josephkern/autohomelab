# The tier-4 private held-out eval

> **Status: the mechanism is built and self-tested; no real set exists yet.** What is committed is
> the runner (`scripts/eval_private.sh`), the schema, the guard, and a deliberately fake worked
> example (`evalsets/private-example/`). Authoring the real items is a human job and is the whole
> of the remaining work.

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
| 1 | **`git push`** | `github.com/josephkern/autohomelab` is PUBLIC. A committed item is published the moment it is pushed, and `git rm` later does not help — the blob stays in the history and in every clone that already fetched it | items live **outside the tree** by default; `.gitignore` patterns; `scripts/eval_private.sh guard` as a pre-commit hook; the runner **refuses** to run a `visibility: private` set that sits inside the repo |
| 2 | **the eval bundle under `results/**/data/`** | this is the one that catches people. The runner writes a bundle exactly like `eval.sh` does, and the obvious implementation writes prompts and completions into it. `results/**/data/` is gitignored — but gitignore is not a threat model: bundles get tarred into bug reports, copied to another machine, read by a future agent, and swept up by backups | **the bundle never receives item text at all.** Per item it records the id, a *salted* digest of the prompt, the verdict, latency and the output length — enough for a paired comparison, not enough to reconstruct a question. Verified by the self-test, which greps the whole bundle tree for a canary string planted in every prompt |
| 3 | **backups** | a nightly backup of `$HOME` copies `~/.local/share/autohomelab/private-eval` off the box, often to a third party | keep the set **encrypted at rest** and decrypt only into tmpfs — see §2. Then a backup holds ciphertext |
| 4 | **the model provider's request log** | a hosted endpoint logs prompts, may retain them, and may train on them. Sending the set to one is a publication with extra steps | the runner **refuses a non-loopback `TARGET`** unless `AHL_PRIVATE_ALLOW_REMOTE=1`, and warns loudly even then |
| 5 | **the serving engine's own logs** | vLLM can log request bodies at debug level, and `docker logs` output lands in `.ahl_*.log` on this box | do not raise vLLM log verbosity while the private gate runs; the `.ahl_*.log` files are gitignored, but treat them as containing items and delete them after a debug session |
| 6 | **an AI coding agent** (including whichever one you are talking to) | an agent working in this repo reads files and ships their contents to a model provider as context. If the set lived in the tree, running an agent here would publish it — quietly, and with no commit to notice afterwards | items outside the tree; **never paste an item into an agent session, an issue, or a chat**, not even to debug one |
| 7 | **the transcript you write while debugging a failed item** | you will want the prompt and the raw output when an item fails, and that file is exactly the leak | transcripts are **opt-in** (`AHL_PRIVATE_KEEP_TRANSCRIPT=1`), written mode `0600` into the private set's own directory outside the repo, never into the bundle |
| 8 | **the committed `accuracy.tsv` row** | it is public, and it carries the score | a score is not an item. The row carries the *set fingerprint* (`private_<set_id>.<fp8>`) so a reader can tell which version of the set produced it, and nothing about the content. Publishing scores over time reveals nothing that would let anyone reconstruct a question |

**Why the digest is salted.** `sha256(prompt)` would be a *confirmation oracle*: anyone holding a
guessed question could hash it and check the bundle. The digest is `sha256(salt ‖ prompt)`, and the
salt lives only in `manifest.json`, which never leaves the private directory. It still identifies
an item across runs, which is all the paired comparison needs.

**Out of scope, stated rather than implied.** An attacker with read access to your home directory
and your decryption key has the set. This design does not defend against that; it defends against
*accident* — the commit nobody meant to make, the bundle nobody thought about, the endpoint nobody
checked. Every real leak this project is likely to suffer is an accident.

---

## 2. Storage layout

```
~/.local/share/autohomelab/private-eval/       <- $AHL_PRIVATE_EVAL_DIR (default). NOT in the repo.
├── manifest.json        set_id, visibility=private, salt, authoring notes
├── items.jsonl          line 1 = header record, then one item per line
└── transcripts/         only if AHL_PRIVATE_KEEP_TRANSCRIPT=1; mode 0600

<repo>/evalsets/private-example/               <- committed, FAKE, visibility=example
<repo>/scripts/eval_private.sh                 <- the runner
<repo>/scripts/eval_private_set.py             <- parser + graders + bundle writer
<repo>/scripts/eval_private_selftest.sh        <- 139 checks, no GPU
```

The split is deliberate: **the code, the schema and the docs are public; only the items are not.**
Anyone can read how the gate works, audit the graders, and run the whole thing against the example
set. What they cannot do is see the questions.

### Encrypted at rest (recommended once a real set exists)

`AHL_PRIVATE_EVAL_DECRYPT` is a command that emits a **tar stream of the set on stdout**. The
runner unpacks it into a `0700` directory under `$XDG_RUNTIME_DIR` (tmpfs, per-user, gone at
logout) and deletes it on exit. Nothing is ever unpacked inside the repo.

```bash
# once, to seal it (age: https://github.com/FiloSottile/age)
tar -C ~/.local/share/autohomelab/private-eval -c manifest.json items.jsonl \
  | age -R ~/.ssh/id_ed25519.pub > ~/private-eval.tar.age

# per run
export AHL_PRIVATE_EVAL_DECRYPT="age -d -i ~/.ssh/id_ed25519 ~/private-eval.tar.age"
scripts/eval_private.sh runbooks/<org>/<model>/<config>.sh
```

A failed decrypt fails **closed**: exit 1, no row, no gate.

### The guard

```bash
scripts/eval_private.sh install-guard    # writes .git/hooks/pre-commit (per-clone, not committed)
scripts/eval_private.sh guard            # or run it by hand
```

It blocks a staged blob that **parses** as a private manifest or items file (`eval_private_set.py
sniff`), plus a few reserved filename shapes (`*.age`, `*.private.jsonl`, `private-eval/*`). The
parse matters: the first version grepped for the marker string and blocked this very document, the
self-test and the helper module, all of which only mention it — and a guard that fires on its own
documentation is one the next operator switches off. It is still a **heuristic** and it is the
third line of defence, not the first: the first is that the set is not in the tree at all. `AHL_PRIVATE_GUARD_ALLOW=1` overrides it and says
so out loud.

---

## 3. The schema

`manifest.json`:

```json
{
  "schema": "ahl-private-eval/1",
  "set_id": "ahl-holdout-1",          // [A-Za-z0-9_.-]; travels in the task name
  "visibility": "private",            // "private" | "example" — private sets are refused inside the repo
  "salt": "<32+ random chars, generated once, never published>",
  "authored": "20260820"
}
```

`items.jsonl` — **line 1 is a header record**, then one item per line:

```json
{"schema":"ahl-private-eval/1","kind":"header","marker":"AHL-PRIVATE-EVAL-ITEMS","visibility":"private"}
{"id":"h1-001","authored":"20260820","tags":["multi-step"],"prompt":"...","grader":{"type":"exact","answers":["..."]}}
```

Item fields: `id` (unique), `prompt`, `grader`, and optionally `system`, `tags`, `max_tokens`,
`authored`, `note`, `burned`.

| grader | rule |
|---|---|
| `exact` | the normalised whole reply **or its last non-empty line** equals one of `answers` |
| `contains` | a normalised `answers` entry appears anywhere in the reply |
| `regex` | `re.search(pattern, reply, MULTILINE\|IGNORECASE)`; `case_sensitive`/`dotall` opt in |
| `numeric` | the last `\boxed{…}`, else the last number in the reply, within `tol` (default 0) |

Normalisation lowercases, strips code fences, `**`, `` ` ``, collapses whitespace and trims
trailing `.!?"'`. Any grader may carry `must_not_contain`, checked **first** — it fails the item
outright even if the answer is present (use it for refusal boilerplate, or for a distractor the
model must not repeat).

**Objective graders only. There is deliberately no LLM judge**: it would ship every item to a
second model (threat #4), and the repo's own contamination research prefers objective ground-truth
grading anyway. If an item cannot be graded by string or number, it does not belong in this set.

`burned` marks an item as compromised:

```json
"burned": {"date":"20260820","reason":"pasted into a public issue while debugging"}
```

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
suite=private   tasks=private_<set_id>.<fp8>   scores=private_<set_id>.<fp8>=87.5
samples=private_<set_id>.<fp8>=40/40   validity=ok   status=measured
```

| exit | meaning |
|---|---|
| `0` | citable — and still a small-sample number, see §5 |
| `1` | **the set is not installed on this node** (no row), or the run finished with transport failures |
| `2` | refused before running: unusable set, non-loopback target, private set inside the repo |
| `3` | killed by a signal — **no row**, because a partial private run is not a measurement |
| `4` | the row is written and is **not citable** |

**Exit 1 with no set is the common case for anyone who clones this repo.** It prints an explanation
and how to author one. An integrator must read it as **GATE NOT RUN**, never as PASS; there is no
configuration under which a missing set exits 0.

Verdict tokens are the shipped Gate-2 ones (`no_score`, `nonfinite`, `short_sample`, `zero_score`,
`no_samples` — `scripts/eval_validity.py`, computed by that same code, not a copy), plus exactly one
of its own:

| token | rule | severity |
|---|---|---|
| `small_n` | fewer than `AHL_PRIVATE_MIN_ITEMS` (**30**) live items scored | suspect |

`small_n` is a validity token, not a tolerance test: it is a structural fact about *n*, never a
judgement about the value. Nothing in this layer compares a score to a reference or a floor, for the
reason in docs/validity-contract.md — a threshold on the value would imply a precision the sample
size cannot deliver.

Two consequences worth knowing in advance. The committed example set has **3 live items**, so
running it can never produce a citable row — the example structurally cannot be mistaken for the
gate. And a model that answers *nothing* (the NemotronH think-off failure: everything routed into
`reasoning_content`, `content` empty) scores 0.0 and lands as `zero_score`, suspect, not as a
quality result.

---

## 5. How many items are enough?

Short answer: **30 is the floor the runner enforces, 60–80 is the number to aim for, and even at
80 this cannot resolve a small regression.** The arithmetic, so nobody has to take that on trust —
binomial standard error is `sqrt(p(1-p)/n)`:

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

**The absolute score is not the useful reading. The paired one is.** Run reference and candidate
against the same set in the same session and compare *per item*, which is what the bundle's
`items.audit.jsonl` bitmap exists for. For paired binary outcomes the right test is McNemar's, over
the **discordant** items only — the ones one config passes and the other fails:

| one-directional discordant items | exact two-sided p |
|---|---|
| 4 | 0.125 |
| 5 | 0.063 |
| **6** | **0.031** |
| 7 | 0.016 |

So **six items that the reference passes and the candidate fails, with none the other way, is
significant at p<0.05 regardless of how big the set is** — a candidate that breaks a whole class of
behaviour shows up even at n=40, while a uniform 2-point degradation never will at any size you
will realistically author. Design for that: the set should contain **6–8 capability classes with at
least 5 items each** (instruction-format compliance, multi-step arithmetic, long-context recall,
tool-shaped output, refusal-free factual recall, negation/distractor handling, …), so a class-wide
break produces a class-sized discordance.

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
   this gate spends. Aim for items around 50–80% pass rate on the current champion.
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
- **It cannot be reproduced by anyone else** — which sits in direct tension with charter rule 1
  ("reproducibility is paramount"). A `results.tsv` throughput row can be re-run by a stranger with
  the same hardware; a private-eval row cannot be checked by anyone but the person holding the set.
  The set fingerprint in the task name is the honest mitigation: a reader can at least tell *which*
  unpublished set a number came from, and the same box can re-run it. Treat the row as an internal
  gate, never as a published claim about the model.
- **It never produces a number worth quoting on its own.** Cite it as "passed the private gate" plus
  the paired discordance against the champion. An absolute private-eval percentage in a logbook is
  a number nobody — including its author, six months later — can interpret.

---

## Integration status and what it needs from files this layer does not own

`scripts/eval_private.sh` is standalone today. Folding it into `scripts/suite.sh` as an optional
Gate-2 tier needs three small changes in files owned elsewhere, listed here so they are not
rediscovered:

1. **`suite.sh`**: call it after `eval.sh` at finalize, and map its exit **1 to "GATE NOT RUN"**,
   not to a failure and never to a pass. A clone with no set must report the gate as absent.
2. **`scripts/eval_validity.py`**: register `small_n` in the documented token table so the private
   layer's one extension is part of the shared vocabulary rather than an appendix here. (The runner
   already computes its status floor correctly; this is documentation of record, not behaviour.)
3. **`AGENTS.md`**: add `private` to the `suite` column's value list in the `accuracy.tsv` schema,
   and `small_n` to the Gate-2 token table, in the same commit as (2).

Self-test: `scripts/eval_private_selftest.sh` — **139 checks**, synthetic sets, a stub model, and a
loopback stdlib HTTP server for the real transport path. No docker, no serve, no lm-eval, no GPU.
