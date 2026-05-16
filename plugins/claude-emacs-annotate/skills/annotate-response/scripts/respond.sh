#!/usr/bin/env bash
# Reply to a single pending comment as ANNOTATE_AUTHOR. The reply is added
# under <parent-comment-id> in the thread identified by <thread-id>; the
# thread's status is NOT touched (the user owns status transitions).
#
# Usage:  respond.sh <abs-file> <thread-id> <parent-comment-id>
#         echo "reply prose" | respond.sh ...
#
# Atomic: refuses to reply if any precondition fails (no overlay matches
# the thread id, the parent comment is gone, the parent already has
# children, or the thread is no longer status="open"). Failure means
# nothing is saved and the model should re-run list-pending.sh and try
# again with a fresh row.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[[ $# -eq 3 ]] || die "usage: respond.sh <abs-file> <thread-id> <parent-comment-id>"
FILE=$1
THREAD_ID=$2
PARENT_ID=$3

[[ -f "$FILE" ]] || die "file not found: $FILE"
[[ -n "$THREAD_ID" ]] || die "thread-id is empty"
[[ -n "$PARENT_ID" ]] || die "parent-comment-id is empty"

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "reply text is empty (read from stdin)"

QFILE=$(elisp_quote "$FILE")
QTHREAD=$(elisp_quote "$THREAD_ID")
QPARENT=$(elisp_quote "$PARENT_ID")
QTEXT=$(elisp_quote "$TEXT")

emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (let* ((file ${QFILE})
         (thread-id ${QTHREAD})
         (parent-id ${QPARENT})
         (reply-text ${QTEXT})
         (existing (find-buffer-visiting file))
         (buf (or existing (find-file-noselect file)))
         (created-buf (not existing)))
    (unwind-protect
        (with-current-buffer buf
          (let* ((ov (annotate--unique-overlay
                      (lambda (ov)
                        (let ((data (overlay-get ov 'simply-annotation)))
                          (and (simply-annotate--thread-p data)
                               (string= (alist-get 'id data) thread-id))))
                      (format "thread %s in %s" thread-id file)))
                 (thread (overlay-get ov 'simply-annotation))
                 (comments (alist-get 'comments thread))
                 (parent (cl-find-if
                          (lambda (c) (string= (alist-get 'id c) parent-id))
                          comments))
                 (has-children (cl-some
                                (lambda (c) (string= (alist-get 'parent-id c) parent-id))
                                comments)))
            (cond
             ((not parent)
              (error "no comment with id %s in thread %s" parent-id thread-id))
             (has-children
              (error "comment %s in thread %s already has children; not a leaf"
                     parent-id thread-id))
             ((not (annotate--open-p thread))
              (error "thread %s is not open (status=%s); refusing to reply"
                     thread-id (annotate--status thread)))
             (t
              (simply-annotate--add-reply thread reply-text "${ANNOTATE_AUTHOR}" parent-id)
              (overlay-put ov 'simply-annotation thread)
              (overlay-put ov 'help-echo
                           (simply-annotate--annotation-summary thread))
              (simply-annotate--refresh-overlay-display ov)
              (simply-annotate--save-annotations)
              (let ((new-id (alist-get 'id (car (last (alist-get 'comments thread))))))
                (list :replied t :thread-id thread-id
                      :reply-comment-id new-id))))))
      (when (and created-buf (buffer-live-p buf))
        (unless (buffer-modified-p buf) (kill-buffer buf))))))
EOF
