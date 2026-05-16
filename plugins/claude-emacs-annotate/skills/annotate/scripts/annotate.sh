#!/usr/bin/env bash
# Create one annotation authored by ANNOTATE_AUTHOR (see lib.sh) in a file.
#
# Usage:  annotate.sh <abs-file> <start-line> <end-line>
#         echo -e "prose...\nmore prose" | annotate.sh ...
#
# The annotation text is read from stdin (so multi-line prose with quotes
# survives the shell). The text is wrapped in a simply-annotate thread with
# author=ANNOTATE_AUTHOR and status="open"; reconciliation downstream uses
# the author field as the discriminator.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $# -eq 3 ]] || die "usage: annotate.sh <abs-file> <start-line> <end-line>"
FILE=$1
SLINE=$2
ELINE=$3

[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ "$SLINE" =~ ^[0-9]+$ ]] || die "start-line must be a positive integer: $SLINE"
[[ "$ELINE" =~ ^[0-9]+$ ]] || die "end-line must be a positive integer: $ELINE"
(( SLINE >= 1 && ELINE >= SLINE )) || die "invalid line range: $SLINE..$ELINE"

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "annotation text is empty (read from stdin)"

QFILE=$(elisp_quote "$FILE")
QTEXT=$(elisp_quote "$TEXT")

emacs_eval <<EOF
(let* ((file ${QFILE})
       (text ${QTEXT})
       (sline ${SLINE})
       (eline ${ELINE})
       (existing (find-buffer-visiting file))
       (buf (or existing (find-file-noselect file)))
       (created-buf (not existing)))
  (unwind-protect
      (with-current-buffer buf
        (unless simply-annotate-mode (simply-annotate-mode 1))
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (forward-line (1- sline))
            (let* ((start (line-beginning-position))
                   (_ (progn (goto-char (point-min))
                             (forward-line (1- eline))))
                   (end (line-end-position))
                   (thread (simply-annotate--create-thread text "${ANNOTATE_AUTHOR}")))
              ;; Some installs ship a stale create-thread that defaults to
              ;; status="closed"; force open explicitly.
              (setf (alist-get 'status thread) "open")
              (let ((ov (simply-annotate--create-overlay start end thread)))
                (push ov simply-annotate-overlays)
                (simply-annotate--save-annotations)
                (list :start start :end end :sline sline :eline eline))))))
    (when (and created-buf (buffer-live-p buf))
      ;; Only kill if we opened it AND nothing else dirtied it.
      (unless (buffer-modified-p buf) (kill-buffer buf)))))
EOF
