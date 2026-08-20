#!/usr/bin/env bash
# hostcfg.sh — config identity for HOST-PROCESS backends (ds4, llama.cpp).
#
# WHY THIS FILE EXISTS
# --------------------
# A vLLM row's `config_hash` is `sha256sum <runbook>` and that is honest: the runbook IS the
# config (image digest + model + every serving flag). A host-process backend has no runbook —
# `serve.sh` never runs, the operator starts `launchers/<ENGINE>-<org>_<model>.sh` by hand, and
# the only file the gates can hash is the `.smoke-runbook.sh` STUB, which carries `MODEL`,
# `SERVED_NAME`, `PROCESSOR` and parser markers and nothing else. Every ds4 config therefore
# hashed to the same 8 hex digits. AGENTS.md tracks the consequence: four ds4 gsm8k rows
# (60.0 / 76.0 / 74.0 / 74.0) all recorded under `config_hash 10b02344`, a ~3.7-sigma spread
# across rows that claim to be the same config. Two of those four differ in the loaded GGUF
# (the 0731 checkpoint refresh) and two differ in `--dspark`; the stub sees neither. That is not
# only a bookkeeping problem: `promote.sh` selects its supporting rows BY config_hash, so a
# collision means the validity gate can read rows from a different config.
#
# BOTH GATES USE THIS, OR THE DEFECT IS ONLY HALF FIXED
# -----------------------------------------------------
# The tracked defect is about four rows in **accuracy.tsv** (Gate 2, `eval.sh`), not results.tsv.
# The first version of this library was sourced only by `bench_ds4.sh`/`bench_llamacpp.sh`, so the
# bench path separated those configs while the eval path kept writing `10b02344` — the cited rows
# would not have separated, and a host config's quality row still could not be joined to its
# throughput row. `eval.sh` now computes the SAME identity from the SAME running process
# (`ahl_hostcfg_detect` finds it), so Gates 2 and 3 agree by construction.
#
# WHAT IS HASHED (scheme `hp3`)
# -----------------------------
#   1. the SERVED process's argv, read NUL-safely from /proc/<pid>/cmdline;
#   2. the tuning ENVIRONMENT that never reaches the cmdline — ds4's DSpark scheduler/exec knobs
#      are `DS4_DSPARK_*` / `DS4_MTP_*` env vars which `nohup` inherits and the launcher only
#      echoes to its log (see the launcher's `DS4_TUNING_ENV` block);
#   3. the RUNNING BINARY, identified by content through `/proc/<pid>/exe` — because for a host
#      backend the engine BUILD is part of the config in exactly the way the pinned image digest
#      is part of a vLLM runbook;
#   4. the scheme's own parameters (volatile-flag list, sample size, env regex), so the document
#      says how it was built and two documents built under different rules cannot be compared by
#      accident.
#
# ENGINE IDENTITY IS THE BINARY, NOT A SOURCE TREE (hp2 -> hp3)
# ------------------------------------------------------------
# hp2 hashed the caller's `ds4@<git-short-sha>` string, taken from `git -C "$DS4_DIR" rev-parse`.
# That is a claim about a directory on disk at bench time, not about the process under test:
# a `git pull` between two benches of the same still-running server minted a new hash for an
# unchanged process; a dirty worktree or an uncommitted `make` produced the same hash for a
# different binary; an unset `DS4_DIR` produced `unknown` and a third hash again. `/proc/<pid>/exe`
# is what actually ran. Reading THROUGH the symlink (never resolving it to a path first) also
# survives the two cases that matter most in a build loop: a binary rebuilt in place after the
# server started, and a deleted/replaced one — the inode the process is executing is still what
# gets hashed. The caller still passes an engine label; only the part before `@` is used, as a
# human-readable name. The git sha keeps living in the row's `backend` column, where it is
# provenance rather than identity. When `/proc/<pid>/exe` cannot be read at all (permissions, or
# the process died between the pgrep and the hash) the document records `exe=UNREADABLE` AND falls
# back to `argv0=<normalised argv[0]>`: "we could not identify the binary" is its own claim, and
# two engines we cannot identify must not collapse into one config for want of better evidence.
#
# HOW A VALUE IS NORMALISED — and the one rule that replaced basenaming
# --------------------------------------------------------------------
# hp2 reduced EVERY value containing `/` to its basename. That was wrong in both directions:
#   * `--chat-template-kwargs '{"a": "x/y"}'` collided with `'{"b": "z/y"}'` — a JSON blob is not
#     a path, and its basename is nonsense;
#   * far worse for the axis this library exists to separate, `snapshots/rev-AAAA/model.gguf` and
#     `snapshots/rev-BBBB/model.gguf` collided — which is exactly the layout `huggingface-cli
#     download` produces and exactly the checkpoint-refresh axis of the ds4 round-3b campaign.
# The rule now: a value that IS an existing readable regular file is identified by its CONTENT
# (`file:<size>:<16 hex over the first and last 4 MiB>`), which is path-independent in the right
# way — the same GGUF under a different mount is the same config, two different checkpoints with
# the same basename are not. Every other value is taken VERBATIM (escaped, see below): a directory
# path, a URL, a JSON blob and a number are all left alone. A moved DIRECTORY therefore mints a new
# hash; that is a false separation, deliberately preferred to a false collision, because this
# library cannot read a directory's contents cheaply enough to prove two paths are the same config.
#
# WHAT IS DELIBERATELY NOT HASHED (so the hash is stable across runs of the same config)
#   * pid — never read into the document, only used to locate /proc.
#   * bind address and port — `--host`/`--port`, dropped with their values. Benching the same
#     config on :8001 must not mint a new config.
#   * log destinations — `--log-file`/`--logfile`, dropped: a timestamped log name is not config.
#   * every environment variable outside the caller's explicit prefix regex — `PWD`, `_`,
#     `SSH_CONNECTION`, `SHLVL` and friends vary per session and are never admitted.
#
# WHAT IS ORDER-SENSITIVE, PRECISELY (the hp2 header overstated this)
# ------------------------------------------------------------------
#   * Distinct flags are order-INSENSITIVE: items are canonicalised to `flag=value` and sorted.
#   * REPEATED occurrences of the SAME flag are order-SENSITIVE, and must be. llama.cpp's
#     `--override-tensor`/`-ot` is first-match-wins, so `-ot 'blk\..*ffn=CPU' -ot 'blk\.0.*=CUDA0'`
#     and the reverse are two different offload layouts — a live GB10 tuning axis. hp2 sorted them
#     into the same document. They now carry an occurrence ordinal (`-ot#1`, `-ot#2`) which sorts
#     with the flag, so order matters within a repeated flag and nowhere else.
#   * POSITIONAL arguments are always order-sensitive (`pos1=`, `pos2=`): position is their whole
#     meaning.
#   * The parse binds "the next token that does not look like a flag" as a flag's value, because
#     flag ARITY is engine knowledge this library does not have. So a VALUELESS flag adjacent to a
#     positional (`--cors model.gguf`) binds that positional as its value, and moving that flag
#     changes the document. Same config, two hashes — a false separation, again deliberately
#     preferred to a false collision. `--flag=value` and `--flag value` are equivalent, including
#     when the value is a negative number in any of the forms an engine actually accepts
#     (`-1`, `-0.5`, `-.5`, `-1e-3`, `-inf`); anything else beginning with `-` is read as a flag.
#
# CONTROL CHARACTERS IN VALUES (hp2 could be made to collide on purpose)
# ---------------------------------------------------------------------
# hp2 built the document with `printf 'arg %s\n' … | sort`, so a value containing a newline became
# two lines that sorted independently: `--note $'foo\narg --dspark'` hashed identically to
# `--note foo --dspark`. The env leg was reachable by any operator `export`. Values are now
# C-escaped (`\\`, `\n`, `\t`, `\r`) before they enter the document, and the sort is NUL-delimited,
# so one argv token is always exactly one record and the map from argv to document is injective.
#
# VERSIONING — the hash carries its scheme in the value
# ----------------------------------------------------
# 315 committed rows carry the old semantics. This scheme emits `hp3-<8 hex>`, not bare hex: an old
# row and a new row are distinguishable by eye and by `grep`, no historical row is rewritten, and
# nothing appears to have changed retroactively. Consumers compare `config_hash` for equality only,
# so the prefix is inert to them. `hp1` = "whatever the old producer hashed" (the stub for the
# eval/smoke path, the space-joined cmdline for the bench path — never the same thing, which is
# itself part of the defect); `hp2` was the first repair of the bench path and was never written to
# a committed row; `hp3` is this document. `eval.sh` writes `stub-<8 hex>` when it is asked to
# evaluate a host-process stub and can find no engine process to identify — the legacy identity,
# labelled so it can never be mistaken for a served one.
#
# THE SCHEME'S PARAMETERS ARE FIXED, AND THEY ARE IN THE DOCUMENT
# --------------------------------------------------------------
# hp2 read its volatile-flag list from `AHL_HOSTCFG_VOLATILE_FLAGS`, an operator-overridable env
# var that appeared in no row, so a hash was not re-derivable without knowing the shell it was
# computed in. The list is now a constant, and it is printed into the canonical document along
# with the sample size and the env regex — the document is self-describing, and changing any of
# them changes the hash visibly instead of silently.
#
# Usage (source it; works from any CWD):
#     source "$REPO_ROOT/scripts/lib/hostcfg.sh"
#     ahl_hostcfg_hash     <pid> <engine_label> [env_ere]  # -> hp3-1a2b3c4d
#     ahl_hostcfg_canon    <pid> <engine_label> [env_ere]  # -> the exact document that was hashed
#     ahl_hostcfg_env_knob <pid> <env_ere>                 # -> `|`-joined K=V for the knobs column
#     ahl_hostcfg_detect   [port]                          # -> "<engine> <pid> <env_ere>"
#     ahl_hostcfg_env_re   <engine>                        # -> the engine's env regex
#
# Testing hook: AHL_PROC overrides `/proc`, so scripts/hostcfg_selftest.sh can hand this library
# a fabricated process directory and assert on the computed hash without a GPU, a server, or root.
# It is the ONLY env var this library reads.
#
# Deliberately NOT setting `set -euo pipefail`: this file is SOURCED into callers that set their
# own shell options, and flipping them underneath a caller is a footgun. Functions return codes.

# ── Scheme parameters. Constants, not knobs: they are hashed INTO the document (see header). ──
AHL_HOSTCFG_SCHEME=hp3
# Flags dropped WITH their value before hashing.
_AHL_HOSTCFG_VOLATILE='--host --log-file --logfile --port'
# Bytes sampled from each end of a file when identifying it by content.
_AHL_HOSTCFG_SAMPLE=4194304
# Known host-process engines: <name>:<pgrep pattern for the binary>:<tuning-env regex>.
# The regexes MUST match the ones bench_ds4.sh / bench_llamacpp.sh pass, or Gate 2 and Gate 3 would
# hash different documents for one process; scripts/hostcfg_selftest.sh asserts they are equal.
_AHL_HOSTCFG_ENGINES='ds4:ds4-server:^(DS4_DSPARK|DS4_MTP) llamacpp:llama-server:^(LLAMA_|GGML_)'

# _ahl_hostcfg_esc <value> — C-escape so one value is always exactly one record (see header).
_ahl_hostcfg_esc() {
  local v="$1"
  v="${v//\\/\\\\}"; v="${v//$'\n'/\\n}"; v="${v//$'\t'/\\t}"; v="${v//$'\r'/\\r}"
  printf '%s' "$v"
}

# _ahl_hostcfg_fileid <path> — `<size>:<16 hex>` over the first and last _AHL_HOSTCFG_SAMPLE bytes.
# Read through whatever the path is (including /proc/<pid>/exe), never resolved to a name first.
_ahl_hostcfg_fileid() {
  local p="$1" sz h
  sz="$(stat -Lc %s "$p" 2>/dev/null)" || sz=na
  h="$( { head -c "$_AHL_HOSTCFG_SAMPLE" "$p"; tail -c "$_AHL_HOSTCFG_SAMPLE" "$p"; } 2>/dev/null \
        | sha256sum | cut -c1-16 )"
  printf '%s:%s' "$sz" "$h"
}

# _ahl_hostcfg_value <value> — an existing readable regular file is identified by CONTENT;
# everything else is taken verbatim (escaped). See the header for why basenaming was removed.
_ahl_hostcfg_value() {
  local v="$1"
  if [ -f "$v" ] && [ -r "$v" ]; then printf 'file:%s' "$(_ahl_hostcfg_fileid "$v")"
  else _ahl_hostcfg_esc "$v"; fi
}

# _ahl_hostcfg_volatile <flag> — 0 if the flag is dropped from the hash.
_ahl_hostcfg_volatile() {
  local f="$1" d
  for d in $_AHL_HOSTCFG_VOLATILE; do [ "$f" = "$d" ] && return 0; done
  return 1
}

# _ahl_hostcfg_isnum <token> — is this `-…` token a negative NUMBER (a value) rather than a flag?
# `-1`, `-0.5`, `-.5`, `-1e-3`, `-inf` are all values an engine accepts; hp2 admitted only the
# first two and therefore hashed `--temp=-.5` and `--temp -.5` differently.
_ahl_hostcfg_isnum() {
  [[ "$1" =~ ^-([0-9]+|[0-9]*\.[0-9]+)([eE][-+]?[0-9]+)?$ ]] && return 0
  [[ "$1" =~ ^-([Ii][Nn][Ff]([Ii][Nn][Ii][Tt][Yy])?|[Nn][Aa][Nn])$ ]] && return 0
  return 1
}

# _ahl_hostcfg_env_pairs <pid> <ere> — the SELECTED tuning environment, one RAW `K=V` record per
# NUL, LC_ALL=C-sorted. Read AND written NUL-delimited: an exported value containing a newline must
# stay one record, or an operator `export DS4_MTP_NOTE=$'a\nDS4_MTP_FORGED=b'` forges a second
# tuning knob into the identity (hp2 read this with `tr '\0' '\n' | grep`, and did).
# This is the SINGLE selection: ahl_hostcfg_canon and ahl_hostcfg_env_knob both consume it, so the
# hash and the knobs column can never disagree about WHAT WAS SELECTED. They render it
# differently — the knob shows escaped raw values, the document normalises file values — and the
# readability of /proc/<pid>/environ is tested by each caller, because a rc cannot cross the
# NUL-delimited pipe that carries the records.
_ahl_hostcfg_env_pairs() {
  local pid="$1" ere="$2" f="${AHL_PROC:-/proc}/$1/environ" kv=""
  [ -r "$f" ] || return 2
  while IFS= read -r -d '' kv || [ -n "$kv" ]; do
    [[ "$kv" =~ $ere ]] && printf '%s\0' "$kv"
    kv=""
  done < "$f" | LC_ALL=C sort -z
}

# ahl_hostcfg_env_knob <pid> <env_ere> — the selected tuning environment as ONE knobs-column
# value: sorted `K=V`, `|`-joined, with `,` and TAB neutralised so the value can never contain the
# pair separator (validity-contract.md §2 encoding). Empty output = nothing was set; `unreadable`
# = we could not tell, which is NOT the same claim and must not render as `none` in the row
# (hp2's knob said `ds4_env=none` while its document said `env UNREADABLE`).
ahl_hostcfg_env_knob() {
  local pid="$1" ere="${2:-}" f="${AHL_PROC:-/proc}/$1/environ" out="" kv=""
  [ -n "$ere" ] || return 0
  if [ ! -r "$f" ]; then
    echo "hostcfg: cannot read $f (tuning env not recorded)" >&2
    printf 'unreadable\n'; return 0
  fi
  while IFS= read -r -d '' kv; do
    out="${out:+$out|}$(_ahl_hostcfg_esc "${kv//,/;}")"
  done < <(_ahl_hostcfg_env_pairs "$pid" "$ere")
  printf '%s\n' "$out"
}

# ahl_hostcfg_env_re <engine> — the tuning-env regex for a known engine (empty + rc 1 if unknown).
ahl_hostcfg_env_re() {
  local want="$1" e name pat re
  for e in $_AHL_HOSTCFG_ENGINES; do
    IFS=: read -r name pat re <<<"$e"
    [ "$name" = "$want" ] && { printf '%s\n' "$re"; return 0; }
  done
  return 1
}

# ahl_hostcfg_detect [port] — find the host-process engine serving <port>. Prints
# "<engine> <pid> <env_ere>"; rc 1 if no known engine is serving it (the normal case for a vLLM
# runbook, which must keep hashing its runbook file). Matches `--port N` and `--port=N` alike.
ahl_hostcfg_detect() {
  local port="${1:-8000}" e name pat re pid
  for e in $_AHL_HOSTCFG_ENGINES; do
    IFS=: read -r name pat re <<<"$e"
    pid="$(pgrep -f "$pat .*--port[ =]$port([^0-9]|\$)" 2>/dev/null | head -1)"
    [ -n "$pid" ] || continue
    [ -r "${AHL_PROC:-/proc}/$pid/cmdline" ] || continue
    printf '%s %s %s\n' "$name" "$pid" "$re"; return 0
  done
  return 1
}

# ahl_hostcfg_canon <pid> <engine_label> [env_ere] — the canonical document that gets hashed.
# Printed, not just hashed, so a disagreement between two runs is diffable instead of a mystery.
ahl_hostcfg_canon() {
  local pid="$1" engine="${2:-unknown}" ere="${3:-}"
  engine="${engine%%@*}"          # `ds4@84cc882` -> `ds4`: the sha is provenance, not identity
  local proc="${AHL_PROC:-/proc}"
  local cmdf="$proc/$pid/cmdline" exef="$proc/$pid/exe"
  local -a argv=() keys=() vals=() hasv=() items=()
  local tok=""
  # Read argv here rather than through a helper: a command substitution or a `read` loop over its
  # LINES would re-split any argument containing a newline. NUL is the only safe separator.
  [ -r "$cmdf" ] || { echo "hostcfg: cannot read $cmdf" >&2; return 1; }
  while IFS= read -r -d '' tok || [ -n "$tok" ]; do argv+=("$tok"); tok=""; done < "$cmdf"
  [ "${#argv[@]}" -gt 0 ] || { echo "hostcfg: empty cmdline for pid $pid" >&2; return 1; }

  # ── pass 1: parse argv into (key, value) pairs, dropping volatile flags ──
  local i=1 n="${#argv[@]}" t flag val nxt has_val npos=0
  while [ "$i" -lt "$n" ]; do
    t="${argv[$i]}"
    case "$t" in
      -*)
        if [ "${t#*=}" != "$t" ]; then                  # --flag=value
          flag="${t%%=*}"; val="${t#*=}"; has_val=1
        else
          flag="$t"; val=""; has_val=0
          if [ "$((i+1))" -lt "$n" ]; then
            nxt="${argv[$((i+1))]}"
            if [ "${nxt#-}" = "$nxt" ] || _ahl_hostcfg_isnum "$nxt"; then
              val="$nxt"; has_val=1; i=$((i+1))
            fi
          fi
        fi
        if ! _ahl_hostcfg_volatile "$flag"; then
          keys+=("$flag"); vals+=("$val"); hasv+=("$has_val")
        fi
        ;;
      *)  npos=$((npos+1)); keys+=("pos$npos"); vals+=("$t"); hasv+=(1) ;;
    esac
    i=$((i+1))
  done

  # ── pass 2: emit. A flag that occurs more than once carries its occurrence ordinal, so order
  # is significant within a repeated flag (llama.cpp `-ot` is first-match-wins) and nowhere else.
  declare -A occ=() seen=()
  local k
  for k in ${keys[@]+"${keys[@]}"}; do occ["$k"]=$(( ${occ["$k"]:-0} + 1 )); done
  local m="${#keys[@]}" label
  i=0
  while [ "$i" -lt "$m" ]; do
    k="${keys[$i]}"
    if [ "${occ[$k]}" -gt 1 ]; then
      seen["$k"]=$(( ${seen["$k"]:-0} + 1 )); label="$k#${seen[$k]}"
    else
      label="$k"
    fi
    if [ "${hasv[$i]}" = 1 ]; then items+=("arg $label=$(_ahl_hostcfg_value "${vals[$i]}")")
    else                            items+=("arg $label"); fi
    i=$((i+1))
  done

  printf 'ahl-hostcfg/3\n'
  printf 'scheme volatile=%s\n' "$(printf '%s\n' $_AHL_HOSTCFG_VOLATILE | LC_ALL=C sort | paste -sd, -)"
  printf 'scheme sample_bytes=%s\n' "$_AHL_HOSTCFG_SAMPLE"
  printf 'scheme env_re=%s\n' "$(_ahl_hostcfg_esc "$ere")"
  printf 'engine=%s\n' "$(_ahl_hostcfg_esc "$engine")"
  # The binary that is ACTUALLY RUNNING, by content. Unreadable /proc/<pid>/exe (permissions, or
  # the process died between the pgrep and here) is recorded as such: "we could not identify the
  # binary" is a different claim from any particular binary, and fails closed.
  if [ -r "$exef" ]; then
    printf 'exe=file:%s\n' "$(_ahl_hostcfg_fileid "$exef")"
  else
    # Fail closed twice over: say that the binary could not be identified, AND fall back to argv[0]
    # (normalised like any other value), so two different engines whose /proc we cannot read do not
    # collapse into one config just because we lost the better evidence.
    printf 'exe=UNREADABLE\n'
    printf 'argv0=%s\n' "$(_ahl_hostcfg_value "${argv[0]}")"
  fi
  # NUL-delimited sort: an item can never be split by a separator that cannot occur inside it.
  [ "${#items[@]}" -gt 0 ] && printf '%s\0' "${items[@]}" | LC_ALL=C sort -z | tr '\0' '\n'
  if [ -n "$ere" ]; then
    if [ -r "$proc/$pid/environ" ]; then
      # Values normalised the same way argv values are, so both halves follow one rule.
      local kv=""
      while IFS= read -r -d '' kv; do
        printf 'env %s=%s\n' "$(_ahl_hostcfg_esc "${kv%%=*}")" "$(_ahl_hostcfg_value "${kv#*=}")"
      done < <(_ahl_hostcfg_env_pairs "$pid" "$ere")
    else
      # An unreadable environ is a provenance defect, not an empty environment — say so IN the
      # document so the hash differs from a run whose tuning env was genuinely empty.
      printf 'env UNREADABLE\n'
    fi
  fi
}

# ahl_hostcfg_hash <pid> <engine_label> [env_ere] — `<scheme>-<8 hex>`; rc 1 if the process is gone.
ahl_hostcfg_hash() {
  local doc
  doc="$(ahl_hostcfg_canon "$@")" || return 1
  printf '%s-%s\n' "$AHL_HOSTCFG_SCHEME" "$(printf '%s\n' "$doc" | sha256sum | cut -c1-8)"
}
