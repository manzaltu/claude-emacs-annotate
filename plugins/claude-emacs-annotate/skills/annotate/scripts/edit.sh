#!/usr/bin/env bash
# Replace the text of a single skill-authored annotation matched by file +
# line range. The annotation's identity (id, status, comment metadata) is
# preserved; only the root comment's text changes.
#
# Usage:  edit.sh <abs-file> <start-line> <end-line>
#         echo "new prose" | edit.sh ...
#
# Line range must match an existing skill-authored annotation exactly. If
# multiple match, the script errors out and asks the caller to disambiguate.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $# -eq 3 ]] || die "usage: edit.sh <abs-file> <start-line> <end-line>"
FILE=$1
SLINE=$2
ELINE=$3

[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ "$SLINE" =~ ^[0-9]+$ && "$ELINE" =~ ^[0-9]+$ ]] || die "line numbers must be integers"

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "new annotation text is empty (read from stdin)"

QFILE=$(elisp_quote "$FILE")
QTEXT=$(elisp_quote "$TEXT")

emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (let* ((file ${QFILE})
         (new-text ${QTEXT})
         (sline ${SLINE})
         (eline ${ELINE})
         (existing (find-buffer-visiting file))
         (buf (or existing (find-file-noselect file)))
         (created-buf (not existing)))
    (unwind-protect
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min)) (forward-line (1- sline))
              (let ((target-start (line-beginning-position)))
                (goto-char (point-min)) (forward-line (1- eline))
                ;; Edit semantics are "replace the prose", not "append a
                ;; reply" -- rewrite the root comment in place.
                (let* ((target-end (line-end-position))
                       (ov (annotate--unique-overlay
                            (lambda (ov)
                              (and (annotate--ai-p (overlay-get ov 'simply-annotation))
                                   (= (overlay-start ov) target-start)
                                   (= (overlay-end ov) target-end)))
                            (format "%s lines %d-%d" file sline eline)))
                       (current (overlay-get ov 'simply-annotation))
                       (next (simply-annotate--update-thread-first-comment
                              current new-text)))
                  (overlay-put ov 'simply-annotation next)
                  (overlay-put ov 'help-echo
                               (simply-annotate--annotation-summary next))
                  (simply-annotate--refresh-overlay-display ov)
                  (simply-annotate--save-annotations)
                  (list :edited t :start target-start :end target-end))))))
      (when (and created-buf (buffer-live-p buf))
        (unless (buffer-modified-p buf) (kill-buffer buf))))))
EOF
