#!/usr/bin/env bash
# eval_private.sh <runbook.sh> — Gate 2, TIER 4: the private held-out eval.
#
#   scripts/eval_private.sh <runbook.sh>        # grade the private set against the live endpoint
#   scripts/eval_private.sh validate [SET_DIR]  # parse + schema-check a set (no model needed)
#   scripts/eval_private.sh guard               # pre-commit check: is a private set being staged?
#   scripts/eval_private.sh install-guard       # install `guard` as this clone's pre-commit hook
#
# Why (AGENTS.md follow-up "Build a small PRIVATE held-out eval (tier 4)"):
# every other quality signal here is public and therefore contaminable — gsm8k/mmlu are memorised,
# mmlu_pro is tier 2, LiveBench is tier 3 and decays. A set we author and never publish is the only
# fully-uncontaminated signal available for a promotion decision. It is also a WEAK one: it is
# small, so its standard error is large, and it decays as our own blind spots become apparent.
# Read docs/private-eval.md before quoting a number from it.
#
# THE CONSTRAINT THAT SHAPES THIS SCRIPT: github.com/josephkern/autohomelab is PUBLIC. A private
# eval committed to it is published the moment it is pushed and is worth nothing forever. So:
#   - the ITEMS live outside the repo ($AHL_PRIVATE_EVAL_DIR, default
#     ${XDG_DATA_HOME:-~/.local/share}/autohomelab/private-eval), optionally encrypted at rest;
#   - the runner, the schema and the docs live in the repo;
#   - the bundle this writes under results/**/data/ contains NO item text — only ids, salted
#     digests and verdicts (results/**/data/ is gitignored, but gitignore is not a threat model);
#   - a non-loopback TARGET is REFUSED unless AHL_PRIVATE_ALLOW_REMOTE=1, because sending the set
#     to a hosted API publishes it into someone else's request log;
#   - a set whose manifest says visibility=private is REFUSED if it sits inside this repo.
#
# Contract (identical to eval.sh, deliberately — an operator meets ONE concept, not two):
#   * writes a 16-column accuracy.tsv row (schema from scripts/eval_validity.py accuracy-header)
#   * validity tokens are task-tagged and `+`-joined, status is floored measured/suspect/void
#   * exit ladder 3 > 4 > 1 > 0:
#       3  the run was killed by a signal (no row: a partial private run is not a measurement)
#       4  the row IS written but is NOT citable
#       1  the run completed with transport failures, OR the private set is not installed here
#       2  refused before running (bad usage, unusable set, unsafe target)
#       0  citable
#   * "set not installed" is the COMMON case for anyone who clones this repo. It exits 1 with an
#     explanation and writes NOTHING. An integrator must treat that as GATE NOT RUN — never PASS.
#     There is no configuration under which a missing set produces exit 0.
#
# Env: AHL_PRIVATE_EVAL_DIR, AHL_PRIVATE_EVAL_DECRYPT (a command emitting a tar stream of the set
#      on stdout — for a set kept encrypted at rest), AHL_PRIVATE_MIN_ITEMS (30),
#      AHL_PRIVATE_ALLOW_REMOTE, AHL_PRIVATE_KEEP_TRANSCRIPT (0; 1 writes prompts+outputs to the
#      PRIVATE dir, 0600, never the bundle), AHL_PRIVATE_TRANSPORT (self-test seam),
#      CONC (1), LIMIT, THINK (on), AHL_PRIVATE_MAX_TOKENS (2048), AHL_PRIVATE_TIMEOUT (600).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

DEFAULT_SET_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/autohomelab/private-eval"
SET_DIR="${AHL_PRIVATE_EVAL_DIR:-$DEFAULT_SET_DIR}"

# Charter rule 4 (python via uv, python3 fallback — eval_private_set.py is stdlib-only).
ahl_py() {
  if [ -n "${AHL_PYTHON:-}" ]; then
    # shellcheck disable=SC2086
    $AHL_PYTHON "$@"
  elif command -v uv >/dev/null 2>&1; then
    uv run --project "$REPO_ROOT" --quiet python "$@"
  else
    python3 "$@"
  fi
}

# ── guard: keep the items out of the public repo by accident ──────────────────
# The real protection is that the set lives outside the tree. This is the second line of defence
# for the contributor who runs `git add -A` after authoring in the wrong place. It is a heuristic
# and says so: it blocks a few reserved filename shapes, and asks `eval_private_set.py sniff`
# whether a staged blob PARSES as a private manifest or items file.
#
# It does not grep. The grep version blocked docs/private-eval.md, this script's own self-test and
# eval_private_set.py, all of which merely mention the marker — and a guard that fires on its own
# documentation is one the next operator switches off, which is worse than no guard at all.
guard_cmd() {
  local staged f blob hits=0
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "guard: not a git repo — nothing to check" >&2; return 0
  fi
  staged="$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR || true)"
  [ -z "$staged" ] && { echo "guard: nothing staged" >&2; return 0; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.age|*.gpg|*.private.jsonl|*.private.json|private-eval/*|*/private-eval/*)
        echo "  BLOCK $f  (filename shape reserved for private-eval material)" >&2
        hits=$((hits+1)); continue ;;
    esac
    if git -C "$REPO_ROOT" show ":$f" 2>/dev/null | head -c 262144 \
         | ahl_py "$SCRIPT_DIR/eval_private_set.py" sniff 2>/dev/null; then
      echo "  BLOCK $f  (parses as a private-eval manifest / items file)" >&2
      hits=$((hits+1))
    fi
  done <<<"$staged"
  if [ "$hits" -gt 0 ]; then
    cat >&2 <<'EOF'

REFUSING THE COMMIT: the staged changes look like a tier-4 PRIVATE eval set.

github.com/josephkern/autohomelab is PUBLIC. Pushing an item publishes it, and a published
question is burned forever — you cannot un-leak it, and `git rm` in a later commit does not
help because the blob stays in the history and in every clone.

Move the set outside the tree instead:
    mkdir -p ~/.local/share/autohomelab/private-eval
    git restore --staged <the files>        # unstage
    mv <the files> ~/.local/share/autohomelab/private-eval/

If you are certain this is the FAKE example set, it must carry "visibility": "example".
Override (you had better be sure): AHL_PRIVATE_GUARD_ALLOW=1 git commit ...
EOF
    [ "${AHL_PRIVATE_GUARD_ALLOW:-0}" = 1 ] && { echo "guard: OVERRIDDEN by AHL_PRIVATE_GUARD_ALLOW=1" >&2; return 0; }
    return 1
  fi
  echo "guard: ok — no private-eval material staged" >&2
  return 0
}

install_guard_cmd() {
  local hook; hook="$(git -C "$REPO_ROOT" rev-parse --git-path hooks/pre-commit)"
  hook="$(cd "$REPO_ROOT" && realpath -m "$hook")"
  if [ -e "$hook" ]; then
    echo "a pre-commit hook already exists: $hook" >&2
    echo "add this line to it yourself:  \"$SCRIPT_DIR/eval_private.sh\" guard || exit 1" >&2
    return 2
  fi
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
# installed by scripts/eval_private.sh install-guard — blocks a tier-4 private eval set from
# being committed to this PUBLIC repo. Lives in .git/hooks (per-clone, never committed).
exec "$SCRIPT_DIR/eval_private.sh" guard
EOF
  chmod +x "$hook"
  echo "installed $hook" >&2
}

# ── set resolution ────────────────────────────────────────────────────────────
DECRYPT_TMP=""
# `return 0` is load-bearing: under `set -e` bash takes the EXIT trap's last status as the
# script's exit status, so a bare failing `[ -n "" ]` here turned every clean exit into 1.
cleanup() { [ -n "$DECRYPT_TMP" ] && rm -rf "$DECRYPT_TMP"; return 0; }
trap cleanup EXIT

resolve_set() {
  # Encrypted-at-rest path: AHL_PRIVATE_EVAL_DECRYPT emits a tar stream of the set directory on
  # stdout (e.g. `age -d -i ~/.ssh/ahl.key ~/private-eval.tar.age`). It is unpacked into a 0700
  # directory under $XDG_RUNTIME_DIR (tmpfs, per-user, wiped on logout) and removed on exit. It is
  # never unpacked inside the repo.
  if [ -n "${AHL_PRIVATE_EVAL_DECRYPT:-}" ]; then
    DECRYPT_TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/ahl-private.XXXXXX")"
    chmod 700 "$DECRYPT_TMP"
    if ! eval "$AHL_PRIVATE_EVAL_DECRYPT" | tar -x -C "$DECRYPT_TMP" 2>/dev/null; then
      echo "AHL_PRIVATE_EVAL_DECRYPT failed — the set could not be decrypted/unpacked." >&2
      return 1
    fi
    # tolerate both `tar -c manifest.json items.jsonl` and `tar -c private-eval/`
    if [ -f "$DECRYPT_TMP/manifest.json" ]; then SET_DIR="$DECRYPT_TMP"
    else SET_DIR="$(find "$DECRYPT_TMP" -maxdepth 2 -name manifest.json -printf '%h\n' | head -1)"; fi
    [ -n "$SET_DIR" ] || { echo "decrypted stream contains no manifest.json" >&2; return 1; }
  fi
  [ -d "$SET_DIR" ] && [ -f "$SET_DIR/manifest.json" ]
}

explain_absent() {
  cat >&2 <<EOF

Gate 2 tier-4 (private held-out) NOT RUN: no private eval set is installed on this node.

  looked in : $SET_DIR
  override  : AHL_PRIVATE_EVAL_DIR=/path/to/set   (or AHL_PRIVATE_EVAL_DECRYPT=<cmd emitting tar>)

This is the expected state for a fresh clone. The items are deliberately NOT in this repo — it is
public, and a published question is contaminated forever. Nothing was measured, so no row was
written, and this exits 1: treat it as GATE NOT RUN, never as PASS.

To author one (docs/private-eval.md has the full procedure and the honest statement of what this
signal can and cannot support):

  mkdir -p "$SET_DIR"
  cp evalsets/private-example/manifest.json "$SET_DIR/"        # then edit it
  # then: set visibility=private, generate a fresh random salt, and write items.jsonl
  #       (its first line must be the header record — copy it from the example)
  scripts/eval_private.sh validate "$SET_DIR"
EOF
}

# ── subcommands ───────────────────────────────────────────────────────────────
case "${1:-}" in
  guard)          guard_cmd || exit $?; exit 0 ;;
  install-guard)  install_guard_cmd || exit $?; exit 0 ;;
  validate)
    [ -n "${2:-}" ] && SET_DIR="$2"
    resolve_set || { explain_absent; exit 1; }
    ahl_py "$SCRIPT_DIR/eval_private_set.py" validate --set "$SET_DIR" || exit $?
    exit 0 ;;
  ""|-h|--help)
    sed -n '2,30p' "$0" >&2
    exit 2 ;;
esac

RUNBOOK="$1"
[ -f "$RUNBOOK" ] || { echo "no such runbook: $RUNBOOK" >&2; exit 2; }
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
CONC="${CONC:-1}"; THINK="${THINK:-on}"

# ── refuse to ship the set off-box ────────────────────────────────────────────
# A hosted endpoint logs prompts, may retain them, and may train on them. That is not a risk to
# manage, it is the end of the set. Loopback only, unless the operator says otherwise out loud.
HOSTPART="${TARGET#*://}"; HOSTPART="${HOSTPART%%/*}"
case "$HOSTPART" in
  \[*\]*) HOSTPART="${HOSTPART#\[}"; HOSTPART="${HOSTPART%%\]*}" ;;   # [::1]:8000 -> ::1
  *)       HOSTPART="${HOSTPART%%:*}" ;;
esac
case "$HOSTPART" in
  127.*|localhost|::1|0.0.0.0) : ;;
  *)
    if [ "${AHL_PRIVATE_ALLOW_REMOTE:-0}" != 1 ]; then
      cat >&2 <<EOF
REFUSED: TARGET is $TARGET (host: $HOSTPART), which is not loopback.

The private set is only worth something while it is unpublished. A remote endpoint logs the
prompts it is sent — a hosted provider's log is a publication with extra steps, and it is
irreversible. If this really is a machine you control end to end, say so explicitly:

  AHL_PRIVATE_ALLOW_REMOTE=1 scripts/eval_private.sh $RUNBOOK
EOF
      exit 2
    fi
    echo "WARN: AHL_PRIVATE_ALLOW_REMOTE=1 — sending private items to $HOSTPART. Every item you" >&2
    echo "      send is one that host's operator could retain. Consider the set burned if unsure." >&2 ;;
esac

resolve_set || { explain_absent; exit 1; }

# Parse + schema-check BEFORE serving anything: a malformed set is refused, never partially run.
META="$(ahl_py "$SCRIPT_DIR/eval_private_set.py" taskname --set "$SET_DIR")" || {
  echo >&2
  echo "REFUSED: the private set at $SET_DIR did not parse (see the error above)." >&2
  echo "A partially-parseable set is not a set: dropping the unreadable items silently changes" >&2
  echo "the population the score is over. Fix it, then: scripts/eval_private.sh validate" >&2
  exit 2
}
IFS=$'\t' read -r TASK SET_ID VISIBILITY N_LIVE N_BURNED <<<"$META"

# A set marked private must not be sitting inside a public repo, whatever .gitignore says.
case "$(realpath "$SET_DIR")" in
  "$REPO_ROOT"/*|"$REPO_ROOT")
    if [ "$VISIBILITY" = private ]; then
      echo "REFUSED: a set with visibility=private is inside this PUBLIC repo ($SET_DIR)." >&2
      echo "Move it out: mv \"$SET_DIR\" \"$DEFAULT_SET_DIR\" — see docs/private-eval.md." >&2
      exit 2
    fi ;;
esac

MODEL=""; SERVED_NAME=""
# shellcheck disable=SC1090
source "$RUNBOOK"; : "${MODEL:?runbook must set MODEL}"; : "${SERVED_NAME:=$MODEL}"
ORG="${MODEL%%/*}"; [ "$ORG" = "$MODEL" ] && ORG="_"; NAME="${MODEL##*/}"
NODE_FP="$(find "$REPO_ROOT/results" -maxdepth 2 -name node_profile.json -printf '%h\n' 2>/dev/null | head -1 | xargs -r basename)"

RUN_ID="$(date -u +%Y%m%d-%H%M%S)-private"
OUT_DIR="$REPO_ROOT/results/$NODE_FP/$ORG/$NAME"; BUNDLE="$OUT_DIR/data/$RUN_ID"; mkdir -p "$BUNDLE"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
CONFIG_HASH="$(sha256sum "$RUNBOOK" | cut -c1-8)"
SCRIPT_REL="$(realpath --relative-to="$REPO_ROOT" "$RUNBOOK")"

echo "== private eval [$TASK] live=$N_LIVE burned=$N_BURNED conc=$CONC think=$THINK -> $SERVED_NAME ==" >&2

RUN_RC=0
set +e
EV_LINE="$(ahl_py "$SCRIPT_DIR/eval_private_set.py" run \
             --set "$SET_DIR" --bundle "$BUNDLE" --target "$TARGET" --model "$SERVED_NAME" \
             --run-id "$RUN_ID" --conc "$CONC" ${LIMIT:+--limit "$LIMIT"})"
RUN_RC=$?
set -e

# Killed by a signal: no row. A partial private run is not a measurement, and unlike lm-eval there
# is no bundle worth adjudicating later — the items that did not run simply did not run.
if [ "$RUN_RC" -ge 128 ]; then
  echo "!! private eval was killed by a signal (rc=$RUN_RC) — no row written" >&2
  rm -rf "$BUNDLE"
  exit 3
fi
# Refused by the helper (unusable set) — it printed why.
[ "$RUN_RC" = 2 ] && { rm -rf "$BUNDLE"; exit 2; }

SCORES=""; SAMPLES=""; VALIDITY=""; EV_STATUS=""; EV_CONC=""; EV_CITABLE=""
IFS=$'\t' read -r SCORES SAMPLES VALIDITY EV_STATUS EV_CONC EV_CITABLE <<<"$(printf '%s' "$EV_LINE" | tail -1)" || true
# Fail CLOSED (contract A6): no verdict is never a pass.
if [ -z "${VALIDITY:-}" ]; then
  SCORES="${SCORES:-na}"; SAMPLES=na; VALIDITY=na; EV_STATUS=na; EV_CONC="$CONC"; EV_CITABLE=0
  echo "WARN: the private runner produced no verdict — recording validity=na (NOT citable)" >&2
fi

DATA_REL="$(realpath --relative-to="$REPO_ROOT" "$BUNDLE")"
TSV="$OUT_DIR/accuracy.tsv"
# One header definition, five callers (scripts/eval_validity.py) — the defect issue #1 opened on.
HDR="$(ahl_py "$SCRIPT_DIR/eval_validity.py" accuracy-header)"
if [ ! -f "$TSV" ]; then
  echo "$HDR" > "$TSV"
elif [ "$(head -1 "$TSV")" != "$HDR" ]; then
  echo "migrating $TSV to the 16-column schema (docs/validity-contract.md A9)" >&2
  ahl_py "$SCRIPT_DIR/migrate_accuracy_tsv.py" --tsv "$TSV" --bundle-root "$REPO_ROOT" --write >&2
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" "private" "$TASK" \
  "${LIMIT:-full}" "$SCORES" "$DATA_REL" "$THINK" "${EV_CONC:-$CONC}" "$SAMPLES" "$VALIDITY" \
  "$EV_STATUS" >> "$TSV"

echo >&2
echo "scores: $SCORES   samples: $SAMPLES   conc: ${EV_CONC:-$CONC}" >&2
echo "validity: $VALIDITY   status: $EV_STATUS" >&2
echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2

rc=0
[ "$RUN_RC" -ne 0 ] && rc=1
[ "${EV_CITABLE:-0}" = 1 ] || rc=4
if [ "$rc" = 4 ]; then
  echo "!! private gate NOT CITABLE: validity=$VALIDITY status=$EV_STATUS — the row is written," >&2
  echo "   the score must NOT be quoted, compared or promoted on (docs/private-eval.md)." >&2
fi
# Even a citable private row is a SMALL-SAMPLE result. It cannot resolve a 1% regression at any
# set size you will realistically author; it exists to catch gross, contamination-hidden breakage.
[ "$rc" = 0 ] && echo "note: citable, but see docs/private-eval.md — n is small; use the paired" >&2
[ "$rc" = 0 ] && echo "      (reference vs candidate, same session) reading, not the absolute number." >&2
exit "$rc"
