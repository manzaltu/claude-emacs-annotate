#!/usr/bin/env bash
# List every skill-authored annotation (author = ANNOTATE_AUTHOR) in the
# current project's scope roots (see lib.sh::scope_roots) as a 5-column TSV:
#
#     <abs-file><TAB><start-line><TAB><end-line><TAB><status><TAB><text>
#
# - Line numbers are 1-based, computed from the stored buffer positions in the
#   simply-annotate database. The database stores buffer positions; this
#   script converts them to lines so the output keys directly against
#   `diff.sh` records.
# - `<status>` is one of "open" / "in-progress" / "resolved" / "closed". The
#   reconcile step in the procedure ignores closed entries and considers
#   only the rest as candidates for keep/edit/replace.
# - Embedded newlines in annotation text are encoded as the two-character
#   sequence "\n" (backslash + n), matching `batch.sh`'s decoder. Literal TAB
#   in annotation text is rejected loudly (it would corrupt the TSV); this
#   matches the same rule `batch.sh` enforces on input.
# - Annotations by other authors are skipped silently.
# - Annotations whose stored positions no longer map to lines in the current
#   file (file shrank/was rewritten since the annotation was written) are
#   skipped; a single warning summary is printed to stderr afterwards. The
#   caller should treat them as already-gone.
# - Annotations whose file no longer exists on disk are skipped silently
#   (the change went away with the file).
#
# Note: this output is NOT directly consumable by batch.sh — batch.sh expects
# 4 columns (no status). Drop the status column when reusing rows for create.
#
# Usage:  list-ai.sh
# Run this from within the project; scope is taken from scope_roots, NOT
# whatever buffer Emacs has current.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_git_repo

# Use an explicit temp file: emacsclient's -e captures the form's return
# value (sexp-printed), which mangles multi-line TSV. Have elisp write the
# TSV directly to a known path; we cat it back. The eval result carries the
# stale-skipped count so we can surface it on stderr.
TMP=$(mktemp -t annotate-list-ai.XXXXXX)
trap 'rm -f "$TMP"' EXIT

QTMP=$(elisp_quote "$TMP")

# emacs_eval prints the form's return value (a sexp like "(:stale 0)") to
# stdout. Capture it so we can parse the stale count.
RESULT=$(emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (let* ((roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r)))
                        $(roots_list_elisp)))
         (db (simply-annotate--load-database))
         (out (generate-new-buffer " *annotate-list*"))
         (stale 0))
    (unwind-protect
        (progn
          ;; Reuse one throwaway buffer for position->line conversion across
          ;; every file. Avoids find-file-noselect, which the user's
          ;; (find-file . simply-annotate-mode) hook would turn into a
          ;; per-file db reload and overlay rebuild. Use insert-file-contents
          ;; (decoded), not -literally: stored positions are character offsets,
          ;; not byte offsets, so multi-byte files would land on the wrong line.
          (with-temp-buffer
            (dolist (entry (or db nil))
              (let* ((key (car entry))
                     (anns (cdr entry))
                     (ai-anns (seq-filter
                               (lambda (a) (annotate--ai-p (alist-get 'text a)))
                               anns)))
                (when (and ai-anns
                           (stringp key)
                           (file-name-absolute-p key)
                           (file-exists-p key)
                           (seq-some (lambda (root) (file-in-directory-p key root)) roots))
                  (erase-buffer)
                  (insert-file-contents key)
                  (let ((max (point-max)))
                    (dolist (a ai-anns)
                      (let* ((data (alist-get 'text a))
                             (s (alist-get 'start a))
                             (e (alist-get 'end a)))
                        (cond
                         ((not (and (integerp s) (integerp e))) nil)
                         ((or (< s 1) (> s max) (> e max) (< e s))
                          (setq stale (1+ stale)))
                         (t
                          (let ((txt (simply-annotate--annotation-text data))
                                (status (annotate--status data)))
                            (when (string-match-p "\t" txt)
                              (error "annotation in %s contains literal TAB; refusing to emit" key))
                            (when (string-match-p "\t" status)
                              (error "annotation status in %s contains literal TAB; refusing to emit" key))
                            (let ((sline (line-number-at-pos s t))
                                  (eline (line-number-at-pos e t))
                                  ;; "\\\\n" survives the bash heredoc as the
                                  ;; 4-char source "\\n", which elisp reads as
                                  ;; the 2-char replacement string \ + n.
                                  (encoded (replace-regexp-in-string "\n" "\\\\n" txt t t)))
                              (with-current-buffer out
                                (insert (format "%s\t%d\t%d\t%s\t%s\n"
                                                key sline eline status encoded))))))))))))))
          (with-current-buffer out
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (point-min) (point-max) ${QTMP} nil 'silent))))
      (when (buffer-live-p out) (kill-buffer out)))
    (list :stale stale)))
EOF
)

# Surface stale count on stderr so the caller (and the SKILL.md) can rely on
# bash stderr — `(message ...)` in emacsclient -e lands in *Messages*, not on
# the calling shell's stderr, so we route via the form's return value instead.
stale=$(printf '%s' "$RESULT" | grep -oE ':stale [0-9]+' | awk '{print $2}')
if [[ -n "${stale:-}" && "$stale" != "0" ]]; then
  printf 'annotate list-ai: %s stale annotation(s) skipped (file shrank or was rewritten)\n' "$stale" >&2
fi

cat "$TMP"
