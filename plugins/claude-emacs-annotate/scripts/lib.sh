#!/usr/bin/env bash
# Shared helpers for the annotate skills.
# Sourced by every script in this directory; do not execute directly.

set -euo pipefail

die() { printf 'annotate: %s\n' "$*" >&2; exit 1; }

# Also primes the git_root memo, so the check and the lookup every script
# needs cost one `git rev-parse` subprocess total.
require_git_repo() {
  _GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
}

# Memoized (normally by require_git_repo) to avoid repeated `git rev-parse`
# subprocess overhead.
git_root() {
  if [[ -z "${_GIT_ROOT:-}" ]]; then
    _GIT_ROOT=$(git rev-parse --show-toplevel)
  fi
  printf '%s\n' "$_GIT_ROOT"
}

# Require jq: the whole transport is JSON, so a missing jq is fatal up front
# rather than as a confusing parse error mid-pipeline.
require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq not on PATH (required by the annotate skills)"
}

# Refuse creation for files outside the current project (git_root). An
# annotation keyed by an out-of-scope absolute path would be created fine but
# stay invisible to every project-scoped read (list-ai.sh, count.sh,
# clear-ai.sh) — an orphan the next run duplicates. The usual cause is a wrong
# CWD (invoking from a nested repo), so fail loudly at create time instead of
# as a count mismatch later.
# Guard, not boundary: accept when either the literal path or its
# symlink-resolved form falls under the root, so in-scope symlinks never
# false-positive.
require_in_scope() {
  local file=$1 real root canon
  root=$(git_root)
  real=$(readlink -f -- "$file" 2>/dev/null) || real=$file
  canon=$(readlink -f -- "$root" 2>/dev/null) || canon=$root
  if [[ "$file" == "$root"/* || "$real" == "$canon"/* ]]; then
    return 0
  fi
  die "file is outside the current project scope (wrong cwd? cd to the project root first): $file"
}

# Resolve the primary branch for `branch` baseline. Prefer `main`; fall back to
# `master`; otherwise use the upstream of HEAD; otherwise fail loudly.
primary_branch() {
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  local upstream
  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    printf '%s\n' "$upstream"
    return 0
  fi
  die "no 'main' or 'master' branch and HEAD has no upstream; cannot resolve 'branch' baseline"
}

# Resolve a baseline argument to a commit SHA.
#   ""        → branch (default)
#   "branch"  → merge-base(primary, HEAD)
#   <ref>     → git rev-parse --verify
resolve_baseline() {
  local baseline="${1:-branch}"
  case "$baseline" in
    branch|"")
      local pb
      pb=$(primary_branch)
      git merge-base "$pb" HEAD || die "no merge-base between $pb and HEAD"
      ;;
    *)
      git rev-parse --verify "$baseline^{commit}" 2>/dev/null \
        || die "cannot resolve baseline: $baseline"
      ;;
  esac
}

# Escape a shell string for safe inclusion inside an elisp double-quoted string.
# Handles backslash and double-quote; everything else (including raw newlines,
# which are legal inside an elisp string literal) passes through verbatim.
elisp_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Author string written to the `author` field of every comment the annotate
# skills create -- root comments of threads the annotating skills open and
# replies the reply skill posts. It's also the discriminator: threads whose
# root comment author matches this value are the skill's own. Bash-side and
# elisp-side (claude-emacs-annotate-agent-author) share the same literal so the
# two stay in lockstep.
ANNOTATE_AUTHOR='claude-code'

# Validate a tag argument. Tags ride in the thread's native per-thread `tags`
# list and discriminate annotation sets: the diff skill always uses "changes";
# the instruction-driven skill mints one kebab-case tag per task. A
# conservative charset keeps tags a clean set token and safe to embed in the
# elisp forms and jq programs the scripts build.
require_valid_tag() {
  local tag=$1
  [[ -n "$tag" ]] || die "tag must not be empty"
  [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "invalid tag '$tag' (allowed: alphanumerics, '.', '_', '-'; must start alphanumeric)"
}

# Parse an optional `--tag <tag>` from the remaining arguments; print the
# validated tag (empty when absent) and die with USAGE on anything else.
#
#   TAG=$(parse_optional_tag "list-pending.sh [--tag <tag>]" "$@")
parse_optional_tag() {
  local usage=$1; shift
  local tag=
  if [[ $# -gt 0 ]]; then
    case "$1" in
      --tag)
        [[ $# -eq 2 ]] || die "usage: $usage"
        require_valid_tag "$2"
        tag=$2
        shift 2
        ;;
      *) die "usage: $usage" ;;
    esac
  fi
  [[ $# -eq 0 ]] || die "usage: $usage"
  printf '%s' "$tag"
}

# Parse an optional trailing `--expect-file <path>` from the remaining
# arguments into EXPECT_FILE (empty when absent); die with USAGE on anything
# else. Shared by every script taking the flag.
parse_expect_file() {
  local usage=$1; shift
  EXPECT_FILE=
  if [[ $# -gt 0 ]]; then
    case "$1" in
      --expect-file)
        [[ $# -eq 2 ]] || die "usage: $usage"
        EXPECT_FILE=$2
        shift 2
        ;;
      *) die "usage: $usage" ;;
    esac
  fi
  [[ $# -eq 0 ]] || die "usage: $usage"
}

# Print the elisp args-tail for EXPECT_FILE, empty when it is unset.
expect_file_args() {
  if [[ -n "${EXPECT_FILE:-}" ]]; then
    printf ' :expect-file %s' "$(elisp_quote "$EXPECT_FILE")"
  fi
}

# All temp files the scripts create live under one per-process directory, so a
# single EXIT trap cleans up the lot. A directory (rather than an array of
# paths) is deliberate: cea_mktemp is almost always called as `f=$(cea_mktemp)`,
# whose command-substitution subshell would discard any array append -- but the
# directory it writes into was created here, in the parent, and the parent's
# trap removes it wholesale.
_CEA_TMPDIR=$(mktemp -d -t cea.XXXXXX)
trap 'rm -rf "$_CEA_TMPDIR"' EXIT

# Create a temp file under the per-process temp dir and print its path. The
# file is cleaned up by the lib-level EXIT trap; no per-caller bookkeeping.
cea_mktemp() {
  mktemp -p "$_CEA_TMPDIR" cea.XXXXXX
}

# Run one annotation API operation in Emacs and print its result payload
# (compact JSON) to stdout.
#
#   cea_call OP ARGS-ELISP
#
# OP is a dispatch symbol (create, create-batch, reply, edit-root-text,
# set-status, delete, query, pending, count, clear). ARGS-ELISP is the already
# built elisp for the args plist body -- keyword/value pairs that appear inside
# a QUOTED list, e.g. ':thread-id "th-…" :status "closed"' (empty for no-arg
# ops). Because the plist is quoted, string values must be `elisp_quote`d but
# atoms like the anchor kind ride as the bare symbols `region'/`file'. The
# project root (git_root) is injected as the operation's ROOT argument.
#
# The elisp entry point never signals for operation errors: it writes a JSON
# envelope {"ok":true,"result":…} | {"ok":false,"error":{"type","message"}} to
# a response file and prints a tiny ack to stdout. This function reads that
# file and unwraps it, translating the documented failure modes into friendly
# die messages.
cea_call() {
  local op=$1
  local args=${2:-}
  local root resp form out rc

  command -v emacsclient >/dev/null 2>&1 || die "emacsclient not on PATH"
  root=$(git_root)
  resp=$(cea_mktemp)

  # A single self-contained form: require the package (so a fresh server that
  # has never visited a file still has the API available), then dispatch. The
  # args plist is quoted so its keywords, string literals and bare symbols
  # reach the API verbatim without evaluation. The response goes to RESP;
  # stdout carries only the ack.
  form="(progn (require 'claude-emacs-annotate-api) \
(claude-emacs-annotate-api-call '${op} $(elisp_quote "$root") \
'(${args}) $(elisp_quote "$resp")))"

  set +e
  out=$(emacsclient -e "$form" 2>&1)
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    # Classify the emacsclient failure, most specific first. The package
    # failing to load surfaces as a void-function or a missing load file
    # naming claude-emacs-annotate; checked ahead of the socket patterns so
    # its "Cannot open load file" wording isn't mistaken for an unreachable
    # server.
    if printf '%s' "$out" | grep -qiE 'void-function|cannot open load file.*claude-emacs-annotate'; then
      die "claude-emacs-annotate is not loaded in Emacs; install it and retry"
    fi
    # A server that isn't running, or a socket we cannot reach, reports a
    # connection/socket error on stderr.
    if printf '%s' "$out" | grep -qiE "socket|can.?t reach|refused|server.*not running"; then
      die "cannot reach the Emacs server (start it with M-x server-start): $out"
    fi
    # Anything else: relay what emacsclient said.
    die "$out"
  fi

  # The response file must exist, be non-empty, and parse as JSON.
  if [[ ! -s "$resp" ]] || ! jq -e . "$resp" >/dev/null 2>&1; then
    die "Emacs wrote no valid response (claude-emacs-annotate version mismatch?)"
  fi

  # Operation-level failure: relay the typed error message.
  if [[ "$(jq -r '.ok' "$resp")" != "true" ]]; then
    local msg
    msg=$(jq -r '.error.message // "unknown error"' "$resp")
    die "${op} failed: ${msg}"
  fi

  # Success: hand the result payload (compact) to the caller for post-processing.
  jq -c '.result' "$resp"
}

# Pretty-print a JSON document read from stdin. The scripts' final stdout is
# always run through this so a human (and the SKILL prose) reads formatted JSON.
cea_pp() {
  jq .
}
