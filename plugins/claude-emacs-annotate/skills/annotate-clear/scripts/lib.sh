#!/usr/bin/env bash
# Shared helpers for the /annotate skill.
# Sourced by every script in this directory; do not execute directly.

set -euo pipefail

die() { printf 'annotate: %s\n' "$*" >&2; exit 1; }

require_git_repo() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git repository"
}

# Memoized to avoid repeated `git rev-parse` subprocess overhead.
git_root() {
  if [[ -z "${_GIT_ROOT:-}" ]]; then
    _GIT_ROOT=$(git rev-parse --show-toplevel)
  fi
  printf '%s\n' "$_GIT_ROOT"
}

# Roots over which annotation operations (count, clear) should be scoped.
# /annotate annotates a single project, so this is just git_root.
# Output: one absolute path per line.
scope_roots() {
  git_root
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
# Handles backslash and double-quote; everything else passes through verbatim.
elisp_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Run a single elisp form via emacsclient. The form is read from stdin.
# Output (the printed sexp value) goes to stdout. Errors propagate.
#
# A `(require 'simply-annotate)` is wrapped around the form so the package's
# internals (used by every script's body) are available even on a fresh
# Emacs server where the user hasn't yet visited a file or invoked any
# autoloaded simply-annotate command.
emacs_eval() {
  local form
  form=$(cat)
  command -v emacsclient >/dev/null 2>&1 || die "emacsclient not on PATH"
  if ! emacsclient -e "(progn (require 'simply-annotate) $form)"; then
    die "emacsclient eval failed (is the Emacs server running?)"
  fi
}

# Emit `(list "root1" "root2" ...)` from scope_roots stdout. Used by count.sh
# and clear-ai.sh to inject the scope into elisp without per-script bash
# loops.
roots_list_elisp() {
  local out="(list" r
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    out+=" $(elisp_quote "$r")"
  done < <(scope_roots)
  out+=")"
  printf '%s' "$out"
}

# Author string written to the `author` field of every annotation this skill
# creates. It's also the discriminator: annotate--ai-p returns true exactly
# when the root comment's author matches this value. Bash-side and
# elisp-side share the same literal so the two stay in lockstep.
ANNOTATE_AUTHOR='claude-code'

# Print elisp `(cl-labels (...))` bindings that every script's form should
# wrap its body in. Each helper operates on the raw "annotation payload" --
# the value of the `text` key in a db entry, or the value of an overlay's
# `simply-annotation` property. Skill-authored annotations are always thread
# alists; plain-string payloads predate this skill's switch to threads and
# are treated as not-ours.
#
#   (annotate--ai-p data)     -- t iff data is a thread whose root comment's
#                                author equals ANNOTATE_AUTHOR.
#   (annotate--status data)   -- "open" / "in-progress" / "resolved" / "closed".
#                                Reads thread.status; non-thread payloads
#                                return "open" but should not occur for our
#                                annotations.
#   (annotate--open-p data)   -- t iff annotate--status is "open". The skill
#                                only acts on open threads.
#   (annotate--unique-overlay pred ctx)
#                             -- find the single overlay in
#                                simply-annotate-overlays for which (pred ov)
#                                is non-nil, signaling a clean error when
#                                zero or multiple match. CTX is a short
#                                string (e.g. "thread X in <file>") used
#                                in the error message. The predicate
#                                receives the overlay so callers can match
#                                on bounds and payload together.
ai_helpers_elisp() {
  cat <<ELISP
((annotate--ai-p (data)
   (and (simply-annotate--thread-p data)
        (let ((root (car (alist-get 'comments data))))
          (and root
               (string= (alist-get 'author root) "${ANNOTATE_AUTHOR}")))))
 (annotate--status (data)
   (or (and (simply-annotate--thread-p data)
            (alist-get 'status data))
       "open"))
 (annotate--open-p (data)
   (string= (annotate--status data) "open"))
 (annotate--unique-overlay (pred ctx)
   (let ((matches (seq-filter pred simply-annotate-overlays)))
     (cond
      ((null matches) (error "no annotation matches %s" ctx))
      ((cdr matches)  (error "multiple annotations match %s (%d found)"
                             ctx (length matches)))
      (t              (car matches))))))
ELISP
}

