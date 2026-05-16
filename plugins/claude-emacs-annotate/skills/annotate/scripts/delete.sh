#!/usr/bin/env bash
# Delete a single skill-authored annotation matched by file + line range.
#
# Usage:  delete.sh <abs-file> <start-line> <end-line>

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $# -eq 3 ]] || die "usage: delete.sh <abs-file> <start-line> <end-line>"
FILE=$1
SLINE=$2
ELINE=$3

[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ "$SLINE" =~ ^[0-9]+$ && "$ELINE" =~ ^[0-9]+$ ]] || die "line numbers must be integers"

QFILE=$(elisp_quote "$FILE")

emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (let* ((file ${QFILE})
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
                (let* ((target-end (line-end-position))
                       (ov (annotate--unique-overlay
                            (lambda (ov)
                              (and (annotate--ai-p (overlay-get ov 'simply-annotation))
                                   (= (overlay-start ov) target-start)
                                   (= (overlay-end ov) target-end)))
                            (format "%s lines %d-%d" file sline eline))))
                  (simply-annotate--remove-overlay ov)
                  (simply-annotate--save-annotations)
                  (list :deleted t))))))
      (when (and created-buf (buffer-live-p buf))
        (unless (buffer-modified-p buf) (kill-buffer buf))))))
EOF
