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
# WHAT IS HASHED (scheme `hp2`)
# -----------------------------
# The two things that actually determine a host-process run:
#   1. the SERVED process's argv, read NUL-safely from /proc/<pid>/cmdline;
#   2. the tuning ENVIRONMENT that never reaches the cmdline — ds4's DSpark scheduler/exec knobs
#      are `DS4_DSPARK_*` / `DS4_MTP_*` env vars which `nohup` inherits and the launcher only
#      echoes to its log (see the launcher's `DS4_TUNING_ENV` block).
# plus the engine identity string (`ds4@<git-short-sha>`), because for a host backend the engine
# BUILD is part of the config in exactly the way the pinned image digest is part of a vLLM
# runbook — and the vLLM hash covers the digest because the runbook contains it.
#
# WHAT IS DELIBERATELY NOT HASHED (so the hash is stable across runs of the same config)
#   * pid — never read into the document, only used to locate /proc.
#   * bind address and port — `--host`/`--port`, dropped with their values. Benching the same
#     config on :8001 must not mint a new config.
#   * log destinations — `--log-file`/`--logfile`, dropped: a timestamped log name is not config.
#   * DIRECTORIES. Every value containing `/` is reduced to its basename, so a GGUF or an engine
#     binary that moved between `$HOME/gguf` and a different mount is the same config. The hash is
#     blind to WHERE a file lives, never to WHICH file it is. The raw values survive in the row's
#     `knobs` column, so nothing is lost from the journal.
#   * flag ORDER and environment ORDER — items are canonicalised into `flag=value` pairs and
#     LC_ALL=C-sorted, so a launcher that reorders its argv does not mint a new config.
#   * every environment variable outside the caller's explicit prefix regex — `PWD`, `_`,
#     `SSH_CONNECTION`, `SHLVL` and friends vary per session and are never admitted.
#
# VERSIONING — the hash carries its scheme in the value
# ----------------------------------------------------
# 315 committed rows carry the old semantics. This scheme therefore emits `hp2-<8 hex>`, not bare
# hex: an old row and a new row are distinguishable by eye and by `grep`, no historical row is
# rewritten, and nothing appears to have changed retroactively. `hp2` = host-process scheme 2
# (scheme 1 = "whatever the old producer hashed" — the stub for the eval/smoke path, the
# space-joined cmdline for the bench path; they were never the same thing, which is itself part
# of the defect). Consumers compare `config_hash` for equality only, so the prefix is inert to
# them; the migration consequence is simply that rows from before this change never group with
# rows after it, which is correct — they were not proven to be the same config.
#
# Usage (source it; works from any CWD):
#     source "$REPO_ROOT/scripts/lib/hostcfg.sh"
#     ahl_hostcfg_hash     <pid> <engine_id> [env_ere]   # -> hp2-1a2b3c4d
#     ahl_hostcfg_canon    <pid> <engine_id> [env_ere]   # -> the exact document that was hashed
#     ahl_hostcfg_env_knob <pid> <env_ere>               # -> `|`-joined K=V for the knobs column
#     ahl_hostcfg_argv     <pid>                         # -> argv, one NUL-safe token per line
#
# Testing hook: AHL_PROC overrides `/proc`, so scripts/hostcfg_selftest.sh can hand this library
# a fabricated process directory and assert on the computed hash without a GPU, a server, or root.
#
# Deliberately NOT setting `set -euo pipefail`: this file is SOURCED into callers that set their
# own shell options, and flipping them underneath a caller is a footgun. Functions return codes.

# Flags dropped WITH their value before hashing. Space-separated; override per-engine if needed.
AHL_HOSTCFG_VOLATILE_FLAGS="${AHL_HOSTCFG_VOLATILE_FLAGS:---host --port --log-file --logfile}"
AHL_HOSTCFG_SCHEME="${AHL_HOSTCFG_SCHEME:-hp2}"
export AHL_HOSTCFG_VOLATILE_FLAGS AHL_HOSTCFG_SCHEME

# _ahl_hostcfg_norm <value> — a value containing `/` is reduced to its basename (see header).
_ahl_hostcfg_norm() {
  local v="$1"
  case "$v" in
    */*) while [ "${v%/}" != "$v" ]; do v="${v%/}"; done   # strip trailing slashes first
         printf '%s' "${v##*/}" ;;
    *)   printf '%s' "$v" ;;
  esac
}

# _ahl_hostcfg_volatile <flag> — 0 if the flag is dropped from the hash.
_ahl_hostcfg_volatile() {
  local f="$1" d
  for d in $AHL_HOSTCFG_VOLATILE_FLAGS; do [ "$f" = "$d" ] && return 0; done
  return 1
}

# ahl_hostcfg_argv <pid> — argv one token per line, split on NUL (never on spaces: a path with a
# space in it must not become two arguments).
ahl_hostcfg_argv() {
  local pid="$1" f="${AHL_PROC:-/proc}/$1/cmdline" tok=""
  [ -r "$f" ] || { echo "hostcfg: cannot read $f" >&2; return 1; }
  while IFS= read -r -d '' tok || [ -n "$tok" ]; do printf '%s\n' "$tok"; tok=""; done < "$f"
}

# ahl_hostcfg_env_knob <pid> <env_ere> — the selected tuning environment as ONE knobs-column
# value: sorted `K=V`, `|`-joined, with `,` and TAB neutralised so the value can never contain
# the pair separator (validity-contract.md §2 encoding). Empty output = nothing was set.
# This is the SINGLE extraction of the tuning environment: ahl_hostcfg_canon consumes the same
# selection, so the hash and the human-readable knob can never disagree about what was set.
ahl_hostcfg_env_knob() {
  local pid="$1" ere="${2:-}" f="${AHL_PROC:-/proc}/$1/environ"
  [ -n "$ere" ] || return 0
  [ -r "$f" ] || { echo "hostcfg: cannot read $f (tuning env not recorded)" >&2; return 0; }
  # `|| true`: callers run with `set -o pipefail`, and grep exits 1 when the tuning environment is
  # simply empty — the overwhelmingly common case. Without this, "no DSpark env set" would abort
  # the bench under `set -e` instead of recording `none`.
  tr '\0' '\n' < "$f" | grep -E "$ere" | LC_ALL=C sort | tr ',\t' ';:' | paste -sd'|' - || true
}

# ahl_hostcfg_canon <pid> <engine_id> [env_ere] — the canonical document that gets hashed.
# Printed, not just hashed, so a disagreement between two runs is diffable instead of a mystery.
ahl_hostcfg_canon() {
  local pid="$1" engine="${2:-unknown}" ere="${3:-}"
  local envf="${AHL_PROC:-/proc}/$pid/environ"
  local cmdf="${AHL_PROC:-/proc}/$pid/cmdline"
  local -a argv=() items=()
  local tok=""
  # Read argv here rather than through ahl_hostcfg_argv: a command substitution or a `read` loop
  # over its LINES would re-split any argument containing a newline, and process substitution
  # hides the read failure. NUL is the only safe separator.
  [ -r "$cmdf" ] || { echo "hostcfg: cannot read $cmdf" >&2; return 1; }
  while IFS= read -r -d '' tok || [ -n "$tok" ]; do argv+=("$tok"); tok=""; done < "$cmdf"
  [ "${#argv[@]}" -gt 0 ] || { echo "hostcfg: empty cmdline for pid $pid" >&2; return 1; }

  items+=("bin=$(_ahl_hostcfg_norm "${argv[0]}")")
  local i=1 n="${#argv[@]}" t flag val nxt has_val
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
            # A value is the next token unless it looks like another flag. A negative number IS
            # a value (`-ngl -1`), so numerics are admitted even though they start with `-`.
            if [ "${nxt#-}" = "$nxt" ] || [[ "$nxt" =~ ^-[0-9]+([.][0-9]+)?$ ]]; then
              val="$nxt"; has_val=1; i=$((i+1))
            fi
          fi
        fi
        _ahl_hostcfg_volatile "$flag" && { i=$((i+1)); continue; }
        if [ "$has_val" = 1 ]; then items+=("$flag=$(_ahl_hostcfg_norm "$val")")
        else                          items+=("$flag"); fi
        ;;
      *)  items+=("+$(_ahl_hostcfg_norm "$t")") ;;
    esac
    i=$((i+1))
  done

  printf 'ahl-hostcfg/2\n'
  printf 'engine=%s\n' "$engine"
  printf 'arg %s\n' "${items[@]}" | LC_ALL=C sort
  if [ -n "$ere" ]; then
    if [ -r "$envf" ]; then
      # Same selection as ahl_hostcfg_env_knob, one K=V per line, path values normalised the
      # same way as argv values so the two halves of the document follow one rule.
      # `|| true` for the same reason as ahl_hostcfg_env_knob: an empty selection is normal and
      # must not fail the pipeline under the caller's `set -o pipefail`.
      { tr '\0' '\n' < "$envf" | grep -E "$ere" | LC_ALL=C sort || true; } | while IFS= read -r kv; do
        printf 'env %s=%s\n' "${kv%%=*}" "$(_ahl_hostcfg_norm "${kv#*=}")"
      done
    else
      # An unreadable environ is a provenance defect, not an empty environment — say so IN the
      # document so the hash differs from a run whose tuning env was genuinely empty.
      printf 'env UNREADABLE\n'
    fi
  fi
}

# ahl_hostcfg_hash <pid> <engine_id> [env_ere] — `<scheme>-<8 hex>`; rc 1 if the process is gone.
ahl_hostcfg_hash() {
  local doc
  doc="$(ahl_hostcfg_canon "$@")" || return 1
  printf '%s-%s\n' "$AHL_HOSTCFG_SCHEME" "$(printf '%s\n' "$doc" | sha256sum | cut -c1-8)"
}
