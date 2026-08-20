#!/usr/bin/env bash
# eval_private.sh <runbook.sh> — Gate 2, TIER 4: the private held-out eval.
#
#   scripts/eval_private.sh <runbook.sh>            # grade the private set against the endpoint
#   scripts/eval_private.sh init [DIR]              # create a set OUTSIDE the repo, fresh salt
#   scripts/eval_private.sh validate [SET_DIR]      # parse + schema-check a set (no model needed)
#   scripts/eval_private.sh compare <bundleA> <bundleB>   # the paired McNemar reading (THE gate)
#   scripts/eval_private.sh guard                   # pre-commit check: is a set being committed?
#   scripts/eval_private.sh guard-push              # pre-push check (reads refs on stdin)
#   scripts/eval_private.sh install-guard           # install both hooks in this clone
#   scripts/eval_private.sh scrub                   # delete transcripts + stale decrypted sets
#
# Why (AGENTS.md follow-up "Build a small PRIVATE held-out eval (tier 4)"):
# every other quality signal here is public and therefore contaminable — gsm8k/mmlu are memorised,
# mmlu_pro is tier 2, LiveBench is tier 3 and decays. A set we author and never publish is the only
# fully-uncontaminated signal available for a promotion decision. It is also a WEAK one: it is
# small, so its standard error is large, and it decays as our own blind spots become apparent.
# Read docs/private-eval.md before quoting anything from it.
#
# THE CONSTRAINT THAT SHAPES THIS SCRIPT: github.com/josephkern/autohomelab is PUBLIC. A private
# eval committed to it is published the moment it is pushed and is worth nothing forever. So:
#   - the ITEMS live outside the repo ($AHL_PRIVATE_EVAL_DIR, default
#     ${XDG_DATA_HOME:-~/.local/share}/autohomelab/private-eval), optionally encrypted at rest;
#   - the runner, the schema and the docs live in the repo;
#   - the bundle this writes under results/**/data/ contains NO item text — only ids, salted
#     digests and verdicts (results/**/data/ is gitignored, but gitignore is not a threat model);
#   - the transport is pinned to a LOOPBACK PEER and proxies are disabled unconditionally;
#   - `visibility: example` is not a claim a set can make about itself — item-shaped content is
#     PRIVATE by default, and the one blessed example is identified by path + content digest;
#   - the guard FAILS CLOSED: if it cannot evaluate a blob, it refuses the commit.
#
# THE ABSOLUTE SCORE IS NOT WRITTEN TO accuracy.tsv AND IS NOT PRINTED. Column 10 is `na`. A
# number that exists gets quoted, and the only defensible reading of a set this small is the
# PAIRED one — `eval_private.sh compare <champion-bundle> <candidate-bundle>` prints it as one
# sentence for the logbook. See docs/private-eval.md §5.
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
#      AHL_PRIVATE_ALLOW_REMOTE, AHL_PRIVATE_KEEP_TRANSCRIPT (0; 1 writes prompts+outputs outside
#      the repo, 0600, never the bundle), AHL_PRIVATE_TRANSCRIPT_DIR, AHL_PRIVATE_TRANSPORT
#      (self-test seam), AHL_PRIVATE_ALLOW_DISK_TMP, CONC (1), LIMIT, THINK (on),
#      AHL_PRIVATE_MAX_TOKENS (2048), AHL_PRIVATE_TIMEOUT (600).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a

DEFAULT_SET_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/autohomelab/private-eval"
SET_DIR="${AHL_PRIVATE_EVAL_DIR:-$DEFAULT_SET_DIR}"
HELPER="$SCRIPT_DIR/eval_private_set.py"

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
# for the contributor who runs `git add -A` after authoring in the wrong place — and for the AGENT
# who does, since this repo's operator usually is one.
#
# It FAILS CLOSED. The previous version did not, in two ways that both produced `guard: ok` over a
# verbatim staged set:
#   * `sniff`'s exit code alone was the verdict, and ANY non-zero read as "not private" — so
#     AHL_PYTHON=/bin/false (exit 1) waved everything through;
#   * `git show ":$f" | head -c 262144 | sniff` killed `git show` with SIGPIPE under `pipefail`,
#     making the pipeline exit 141 — i.e. "not private" — for every items file over 256 KiB, and
#     twenty 4K-token long-context items is ~320 KB, a class docs/private-eval.md recommends.
# Now: the blob is read whole into a temp file (no pipe, no truncation), `sniff` must PRINT a
# verdict token, and anything that is not a clean PRIVATE/CLEAN answer blocks the commit.
GUARD_HITS=0
GUARD_SOFT=0

guard_check_blob() { # guard_check_blob <rev-or-empty> <path> ; sets GUARD_HITS/GUARD_SOFT
  local rev="$1" f="$2" tmp out rc tier reason
  case "$f" in
    *.age|*.gpg|*.private.jsonl|*.private.json|private-eval/*|*/private-eval/*|transcripts/*|*/transcripts/*)
      echo "  BLOCK $f  (filename/path shape reserved for private-eval material)" >&2
      GUARD_HITS=$((GUARD_HITS+1)); return ;;
  esac
  tmp="$(mktemp "${TMPDIR:-/tmp}/ahl-guard.XXXXXX")"
  if ! git -C "$REPO_ROOT" cat-file blob "$rev:$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "  BLOCK $f  (could not read the staged blob — the guard fails CLOSED)" >&2
    GUARD_HITS=$((GUARD_HITS+1)); return
  fi
  rc=0
  out="$(ahl_py "$HELPER" sniff --file "$tmp" --path "$f" 2>/dev/null)" || rc=$?
  rm -f "$tmp"
  case "$out" in
    PRIVATE*)
      tier="$(printf '%s' "$out" | cut -f2)"; reason="$(printf '%s' "$out" | cut -f3-)"
      if [ "$tier" = hard ]; then
        echo "  BLOCK $f  ($reason)" >&2; GUARD_HITS=$((GUARD_HITS+1))
      else
        echo "  WARN  $f  ($reason)" >&2; GUARD_SOFT=$((GUARD_SOFT+1))
      fi ;;
    CLEAN*) : ;;
    *)
      echo "  BLOCK $f  (the guard could not evaluate this blob: sniff exit $rc, output '${out:-<none>}')" >&2
      GUARD_HITS=$((GUARD_HITS+1)) ;;
  esac
}

guard_preflight() { # a guard that cannot run must not report success
  local out rc=0
  out="$(ahl_py "$HELPER" selfcheck 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] || [ "$out" != "GUARD-READY" ]; then
    cat >&2 <<EOF
REFUSING: the private-eval guard could not start (python exit $rc, output '${out:-<none>}').

A guard that cannot evaluate a blob must not say "ok" — this repo is PUBLIC and the whole point
of the check is that a mistake here is irreversible. Fix the interpreter (AHL_PYTHON=$([ -n "${AHL_PYTHON:-}" ] && echo "$AHL_PYTHON" || echo "<unset>"))
and commit again.
EOF
    return 1
  fi
  return 0
}

guard_verdict() {
  if [ "$GUARD_HITS" -gt 0 ]; then
    cat >&2 <<'EOF'

REFUSING: the staged/pushed changes look like a tier-4 PRIVATE eval set.

github.com/josephkern/autohomelab is PUBLIC. Pushing an item publishes it, and a published
question is burned forever — you cannot un-leak it, and `git rm` in a later commit does not
help because the blob stays in the history and in every clone.

Move the set outside the tree instead:
    scripts/eval_private.sh init ~/.local/share/autohomelab/private-eval
    git restore --staged <the files>        # unstage
    mv <the files> ~/.local/share/autohomelab/private-eval/

IF YOU ARE AN AGENT: do not retry this with `--no-verify`, and do not disable the hook. This is
the one failure in this repo that cannot be undone by a follow-up commit. Ask the operator.

Override (you had better be sure): AHL_PRIVATE_GUARD_ALLOW=1 git commit ...
EOF
    if [ "${AHL_PRIVATE_GUARD_ALLOW:-0}" = 1 ]; then
      echo "guard: OVERRIDDEN by AHL_PRIVATE_GUARD_ALLOW=1" >&2; return 0
    fi
    return 1
  fi
  if [ "$GUARD_SOFT" -gt 0 ]; then
    cat >&2 <<'EOF'

REFUSING on WEAK evidence: something staged looks item-shaped but is not conclusive (a single
item-like object, the marker string in prose, or a CSV with prompt/answer columns).

This tier exists because the structural test only ever recognised two of eleven realistic
shapes. If this really is documentation or a fixture, say so with the narrow override — it does
NOT disable the hard structural block:

    AHL_PRIVATE_GUARD_SOFT_OK=1 git commit ...
EOF
    if [ "${AHL_PRIVATE_GUARD_SOFT_OK:-0}" = 1 ] || [ "${AHL_PRIVATE_GUARD_ALLOW:-0}" = 1 ]; then
      echo "guard: weak-evidence warning OVERRIDDEN" >&2; return 0
    fi
    return 1
  fi
  echo "guard: ok — no private-eval material staged" >&2
  return 0
}

guard_cmd() {
  local staged f
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "guard: not a git repo — nothing to check" >&2; return 0
  fi
  guard_preflight || return 1
  staged="$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR || true)"
  [ -z "$staged" ] && { echo "guard: nothing staged" >&2; return 0; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    guard_check_blob "" "$f"
  done <<<"$staged"
  guard_verdict
}

# pre-push: the hook is per-clone, and an agent that hits a blocking pre-commit may well retry with
# `--no-verify`. pre-push is the last moment before the leak becomes irreversible, so check the
# commits actually being pushed, not the index.
guard_push_cmd() {
  local local_ref local_sha remote_ref remote_sha range files f
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "guard-push: not a git repo" >&2; return 0
  fi
  guard_preflight || return 1
  local any=0
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -z "${local_sha:-}" ] && continue
    [ "$local_sha" = "0000000000000000000000000000000000000000" ] && continue   # branch deletion
    any=1
    if [ "${remote_sha:-}" = "0000000000000000000000000000000000000000" ] || [ -z "${remote_sha:-}" ]; then
      # new branch: everything on it that is not already on some remote
      files="$(git -C "$REPO_ROOT" log --name-only --pretty=format: "$local_sha" --not --remotes 2>/dev/null | sort -u)"
    else
      files="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=ACMR "$remote_sha" "$local_sha" 2>/dev/null || true)"
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      git -C "$REPO_ROOT" cat-file -e "$local_sha:$f" 2>/dev/null || continue
      guard_check_blob "$local_sha" "$f"
    done <<<"$files"
  done
  [ "$any" = 0 ] && { echo "guard-push: nothing to push" >&2; return 0; }
  guard_verdict
}

write_hook() { # write_hook <name> <guard-subcommand>
  local hook
  hook="$(git -C "$REPO_ROOT" rev-parse --git-path "hooks/$1")"
  hook="$(cd "$REPO_ROOT" && realpath -m "$hook")"
  if [ -e "$hook" ]; then
    echo "a $1 hook already exists: $hook" >&2
    echo "add this line to it yourself:  \"$SCRIPT_DIR/eval_private.sh\" $2 || exit 1" >&2
    return 2
  fi
  mkdir -p "$(dirname "$hook")"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
# installed by scripts/eval_private.sh install-guard — blocks a tier-4 private eval set from
# reaching this PUBLIC repo. Lives in .git/hooks (per-clone, never committed).
exec "$SCRIPT_DIR/eval_private.sh" $2
EOF
  chmod +x "$hook"
  echo "installed $hook" >&2
}

install_guard_cmd() {
  local rc=0 r2=0
  write_hook pre-commit guard || rc=$?
  write_hook pre-push guard-push || r2=$?
  [ "$rc" = 0 ] || return "$rc"
  [ "$r2" = 0 ] || return "$r2"
  return 0
}

# ── scrub: transcripts and stale decrypted sets are plaintext items ───────────
scrub_cmd() {
  local n=0 d
  local tdir="${AHL_PRIVATE_TRANSCRIPT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/autohomelab/private-eval-transcripts}"
  for d in "$tdir" "$SET_DIR/transcripts"; do
    [ -d "$d" ] || continue
    n=$((n + $(find "$d" -maxdepth 1 -name '*.jsonl' | wc -l)))
    find "$d" -maxdepth 1 -name '*.jsonl' -delete
    echo "scrubbed transcripts in $d" >&2
  done
  # Sweep orphans only: a decrypted set whose owner is still alive belongs to a run in progress,
  # and scrub must not pull the items out from under it.
  sweep_stale_runtime_dirs
  echo "scrub: removed $n transcript file(s)" >&2
}

# SIGKILL cannot be trapped, so a decrypted set (and its SALT) can survive in $XDG_RUNTIME_DIR.
# Sweep any directory whose owning process is gone, on every invocation. This does not make the
# window zero — see docs/private-eval.md §2, "what SIGKILL leaves behind".
sweep_stale_runtime_dirs() { # sweep_stale_runtime_dirs [force]
  local base d pid
  base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  [ -d "$base" ] || return 0
  for d in "$base"/ahl-private.*; do
    [ -d "$d" ] || continue
    pid=""; [ -f "$d/.owner-pid" ] && pid="$(cat "$d/.owner-pid" 2>/dev/null || true)"
    if [ "${1:-0}" = 1 ] || [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$d"
      echo "swept a stale decrypted private set: $d (owner pid ${pid:-unknown} is gone)" >&2
    fi
  done
  return 0
}

# ── set resolution ────────────────────────────────────────────────────────────
DECRYPT_TMP=""
# `return 0` is load-bearing: under `set -e` bash takes the EXIT trap's last status as the
# script's exit status, so a bare failing `[ -n "" ]` here turned every clean exit into 1.
cleanup() { [ -n "$DECRYPT_TMP" ] && rm -rf "$DECRYPT_TMP"; return 0; }
trap cleanup EXIT
# EXIT alone does not fire for an uncaught SIGTERM/SIGINT/SIGHUP in every bash configuration; be
# explicit, so the plaintext set outlives the process only when the kernel gives us no choice.
trap 'cleanup; trap - INT; kill -INT $$' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

resolve_set() {
  # Encrypted-at-rest path: AHL_PRIVATE_EVAL_DECRYPT emits a tar stream of the set directory on
  # stdout (e.g. `age -d -i ~/.ssh/ahl.key ~/private-eval.tar.age`). It is unpacked into a 0700
  # directory under $XDG_RUNTIME_DIR (tmpfs, per-user, wiped on logout) and removed on exit. It is
  # never unpacked inside the repo.
  if [ -n "${AHL_PRIVATE_EVAL_DECRYPT:-}" ]; then
    sweep_stale_runtime_dirs
    local base="${XDG_RUNTIME_DIR:-}"
    if [ -z "$base" ]; then
      if [ "${AHL_PRIVATE_ALLOW_DISK_TMP:-0}" != 1 ]; then
        cat >&2 <<'EOF'
REFUSED: $XDG_RUNTIME_DIR is not set, so the decrypted set would be unpacked onto ORDINARY DISK
(under $TMPDIR), where it survives a crash, a reboot and a backup. The point of the encrypted-at-
rest workflow is that plaintext items only ever exist in tmpfs.

Either run under a session that provides XDG_RUNTIME_DIR, point it at a tmpfs yourself, or accept
the risk explicitly:  AHL_PRIVATE_ALLOW_DISK_TMP=1
EOF
        return 1
      fi
      base="${TMPDIR:-/tmp}"
      echo "WARN: unpacking the decrypted set onto disk ($base) — AHL_PRIVATE_ALLOW_DISK_TMP=1." >&2
      echo "      Run 'scripts/eval_private.sh scrub' when you are done." >&2
    fi
    DECRYPT_TMP="$(mktemp -d "$base/ahl-private.XXXXXX")"
    chmod 700 "$DECRYPT_TMP"
    echo $$ > "$DECRYPT_TMP/.owner-pid"
    if ! eval "$AHL_PRIVATE_EVAL_DECRYPT" | tar -x -C "$DECRYPT_TMP" 2>/dev/null; then
      echo "AHL_PRIVATE_EVAL_DECRYPT failed — the set could not be decrypted/unpacked." >&2
      return 1
    fi
    # tolerate both `tar -c manifest.json items.jsonl` and `tar -c private-eval/`
    if [ -f "$DECRYPT_TMP/manifest.json" ]; then SET_DIR="$DECRYPT_TMP"
    else SET_DIR="$(find "$DECRYPT_TMP" -maxdepth 2 -name manifest.json -printf '%h\n' | head -1)"; fi
    [ -n "$SET_DIR" ] || { echo "decrypted stream contains no manifest.json" >&2; return 1; }
    export AHL_PRIVATE_SET_EPHEMERAL=1   # the helper must not write transcripts into this tmpfs
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

  scripts/eval_private.sh init "$SET_DIR"       # fresh random salt, mode 0600, outside the repo
  \$EDITOR "$SET_DIR/manifest.json"              # fill in champion.model and champion.runbook
  \$EDITOR "$SET_DIR/items.jsonl"                # one item per line, each with a champion verdict
  scripts/eval_private.sh validate "$SET_DIR"

Do NOT copy evalsets/private-example — its salt is published in this repo, which makes every audit
digest a confirmation oracle, and a copy is a PRIVATE set that only looks exempt.
EOF
}

# ── subcommands ───────────────────────────────────────────────────────────────
case "${1:-}" in
  guard)          guard_cmd || exit $?; exit 0 ;;
  guard-push)     guard_push_cmd || exit $?; exit 0 ;;
  install-guard)  install_guard_cmd || exit $?; exit 0 ;;
  scrub)          scrub_cmd; exit 0 ;;
  init)
    [ -n "${2:-}" ] && SET_DIR="$2"
    ahl_py "$HELPER" init --dir "$SET_DIR" \
      ${AHL_PRIVATE_SET_ID:+--set-id "$AHL_PRIVATE_SET_ID"} || exit $?
    exit 0 ;;
  compare)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || {
      echo "usage: scripts/eval_private.sh compare <reference-bundle> <candidate-bundle>" >&2
      echo "  the bundles are results/<node>/<org>/<model>/data/<run_id>-private/ dirs" >&2
      exit 2; }
    ahl_py "$HELPER" compare --a "$2" --b "$3" || exit $?
    exit 0 ;;
  validate)
    [ -n "${2:-}" ] && SET_DIR="$2"
    resolve_set || { explain_absent; exit 1; }
    ahl_py "$HELPER" validate --set "$SET_DIR" || exit $?
    exit 0 ;;
  ""|-h|--help)
    sed -n '2,40p' "$0" >&2
    exit 2 ;;
esac

RUNBOOK="$1"
[ -f "$RUNBOOK" ] || { echo "no such runbook: $RUNBOOK" >&2; exit 2; }
TARGET="${TARGET:-http://${AHL_HOST:-127.0.0.1}:${AHL_PORT:-8000}}"
CONC="${CONC:-1}"; THINK="${THINK:-on}"
ALLOW_REMOTE=()
[ "${AHL_PRIVATE_ALLOW_REMOTE:-0}" = 1 ] && ALLOW_REMOTE=(--allow-remote)

# ── refuse to ship the set off-box ────────────────────────────────────────────
# A hosted endpoint logs prompts, may retain them, and may train on them. That is not a risk to
# manage, it is the end of the set. The check is NOT on the URL text — it resolves the host and
# asserts every resolved address is loopback, and the transport asserts the connected PEER again
# after connect(). Proxies are disabled unconditionally in the helper: urllib honours http_proxy
# and does not bypass it for loopback, so the old string check let `http_proxy=http://collector`
# exfiltrate every prompt while printing nothing at all.
TGT_OUT=""; TGT_RC=0
TGT_OUT="$(ahl_py "$HELPER" check-target --target "$TARGET" "${ALLOW_REMOTE[@]+"${ALLOW_REMOTE[@]}"}" 2>&1)" || TGT_RC=$?
if [ "$TGT_RC" != 0 ]; then
  echo "$TGT_OUT" >&2
  cat >&2 <<EOF

REFUSED: TARGET is $TARGET.

The private set is only worth something while it is unpublished. A remote endpoint logs the
prompts it is sent — a hosted provider's log is a publication with extra steps, and it is
irreversible. If this really is a machine you control end to end, say so explicitly:

  AHL_PRIVATE_ALLOW_REMOTE=1 scripts/eval_private.sh $RUNBOOK
EOF
  exit 2
fi
if [ "${AHL_PRIVATE_ALLOW_REMOTE:-0}" = 1 ]; then
  echo "WARN: AHL_PRIVATE_ALLOW_REMOTE=1 — sending private items to $TARGET. Every item you" >&2
  echo "      send is one that host's operator could retain. Consider the set burned if unsure." >&2
fi
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
  if [ -n "${!v:-}" ]; then
    echo "note: $v is set in this environment. It is IGNORED — the private transport builds its" >&2
    echo "      own opener with ProxyHandler({}) and re-checks the connected peer." >&2
    break
  fi
done

resolve_set || { explain_absent; exit 1; }

# Parse + schema-check BEFORE serving anything: a malformed set is refused, never partially run.
META="$(ahl_py "$HELPER" taskname --set "$SET_DIR")" || {
  echo >&2
  echo "REFUSED: the private set at $SET_DIR did not parse (see the error above)." >&2
  echo "A partially-parseable set is not a set: dropping the unreadable items silently changes" >&2
  echo "the population the score is over. Fix it, then: scripts/eval_private.sh validate" >&2
  exit 2
}
IFS=$'\t' read -r TASK SET_ID VISIBILITY N_LIVE N_BURNED <<<"$META"

# A set must not be sitting inside a public repo. VISIBILITY here is the EFFECTIVE visibility the
# helper computed (blessed example = path + digest), not what the manifest claims about itself.
case "$(realpath "$SET_DIR")" in
  "$REPO_ROOT"/*|"$REPO_ROOT")
    if [ "$VISIBILITY" != example ]; then
      echo "REFUSED: a private set is inside this PUBLIC repo ($SET_DIR)." >&2
      echo "Only evalsets/private-example, byte-for-byte as committed, may live in the tree." >&2
      echo "Move it out: scripts/eval_private.sh init \"$DEFAULT_SET_DIR\" — see docs/private-eval.md." >&2
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
EV_LINE="$(ahl_py "$HELPER" run \
             --set "$SET_DIR" --bundle "$BUNDLE" --target "$TARGET" --model "$SERVED_NAME" \
             --run-id "$RUN_ID" --conc "$CONC" "${ALLOW_REMOTE[@]+"${ALLOW_REMOTE[@]}"}" \
             ${LIMIT:+--limit "$LIMIT"})"
RUN_RC=$?
set -e

# Killed by a signal: no row. A partial private run is not a measurement, and unlike lm-eval there
# is no bundle worth adjudicating later — the items that did not run simply did not run.
if [ "$RUN_RC" -ge 128 ]; then
  echo "!! private eval was killed by a signal (rc=$RUN_RC) — no row written" >&2
  rm -rf "$BUNDLE"
  exit 3
fi
# Refused by the helper (unusable set, unsafe target) — it printed why.
[ "$RUN_RC" = 2 ] && { rm -rf "$BUNDLE"; exit 2; }

SCORES=""; SAMPLES=""; VALIDITY=""; EV_STATUS=""; EV_CONC=""; EV_CITABLE=""
IFS=$'\t' read -r SCORES SAMPLES VALIDITY EV_STATUS EV_CONC EV_CITABLE <<<"$(printf '%s' "$EV_LINE" | tail -1)" || true
# Fail CLOSED (contract A6): no verdict is never a pass.
if [ -z "${VALIDITY:-}" ]; then
  SAMPLES=na; VALIDITY=na; EV_STATUS=na; EV_CONC="$CONC"; EV_CITABLE=0
  echo "WARN: the private runner produced no verdict — recording validity=na (NOT citable)" >&2
fi
# THE ABSOLUTE SCORE NEVER REACHES THE COMMITTED JOURNAL. The helper already prints `na` here;
# this is the belt to that braces, because a number in a public column WILL be quoted, and the
# only defensible reading of this gate is `compare`'s paired one (docs/private-eval.md §5).
SCORES=na

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
  "$RUN_ID" "$COMMIT" "$NODE_FP" "$MODEL" "$CONFIG_HASH" "$SCRIPT_REL" "private-attest" "$TASK" \
  "${LIMIT:-full}" "$SCORES" "$DATA_REL" "$THINK" "${EV_CONC:-$CONC}" "$SAMPLES" "$VALIDITY" \
  "$EV_STATUS" >> "$TSV"

echo >&2
echo "samples: $SAMPLES   conc: ${EV_CONC:-$CONC}" >&2
echo "validity: $VALIDITY   status: $EV_STATUS" >&2
echo "scores: na — the absolute percentage is deliberately NOT recorded (docs/private-eval.md §5)." >&2
echo "row -> $(realpath --relative-to="$REPO_ROOT" "$TSV")" >&2

rc=0
[ "$RUN_RC" -ne 0 ] && rc=1
[ "${EV_CITABLE:-0}" = 1 ] || rc=4
if [ "$rc" = 4 ]; then
  echo "!! private gate NOT CITABLE: validity=$VALIDITY status=$EV_STATUS — the row is written," >&2
  echo "   and nothing from this run may be compared or promoted on (docs/private-eval.md)." >&2
fi
if [ "$rc" = 0 ]; then
  echo >&2
  echo "This row is an ATTESTATION, not a measurement: it records that an unpublished set of a" >&2
  echo "known fingerprint was run, and nobody but the holder of the set can check it. The gate" >&2
  echo "reading is the PAIRED one against the champion's bundle, in the same session:" >&2
  echo "   scripts/eval_private.sh compare <champion-bundle> $DATA_REL" >&2
  echo "which prints the one sentence to put in the logbook." >&2
fi
exit "$rc"
