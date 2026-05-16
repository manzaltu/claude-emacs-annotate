#!/usr/bin/env bash
# Set the status of a single skill-authored annotation to "closed" so it
# stays in the database as inert history rather than being deleted. The
# annotation stops participating in subsequent reconcile passes (list-ai.sh
# still emits it, but with status=closed; the SKILL procedure ignores closed
# entries when matching diff records). The original prose is preserved.
#
# Usage:  close.sh <abs-file> <start-line> <end-line>
#
# - Line range must match an existing skill-authored annotation exactly.
# - If multiple match, the script errors out.
# - Already-closed annotations are a no-op (idempotent re-close is fine but
#   reported as "already closed" so the caller can see something's odd).

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $# -eq 3 ]] || die "usage: close.sh <abs-file> <start-line> <end-line>"
FILE=$1
SLINE=$2
ELINE=$3

[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ "$SLINE" =~ ^[0-9]+$ && "$ELINE" =~ ^[0-9]+$ ]] || die "line numbers must be integers"
(( SLINE >= 1 && ELINE >= SLINE )) || die "invalid line range: $SLINE..$ELINE"

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
                            (format "%s lines %d-%d" file sline eline)))
                       (thread (overlay-get ov 'simply-annotation))
                       (already-closed
                        (string= (alist-get 'status thread) "closed")))
                  (simply-annotate--set-thread-property
                   thread 'status "closed"
                   simply-annotate-thread-statuses)
                  (overlay-put ov 'simply-annotation thread)
                  (overlay-put ov 'help-echo
                               (simply-annotate--annotation-summary thread))
                  (simply-annotate--refresh-overlay-display ov)
                  (simply-annotate--save-annotations)
                  (list :closed t
                        :was-already-closed already-closed
                        :start target-start :end target-end))))))
      (when (and created-buf (buffer-live-p buf))
        (unless (buffer-modified-p buf) (kill-buffer buf))))))
EOF
