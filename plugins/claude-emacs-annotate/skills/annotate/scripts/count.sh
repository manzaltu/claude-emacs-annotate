#!/usr/bin/env bash
# Count skill-authored annotations (author = ANNOTATE_AUTHOR) whose file
# lives inside the current project's scope roots (see lib.sh::scope_roots).
# Used after a run to verify the database actually persisted what the agent
# thinks it wrote.
#
# Output is split by status:
#   :ai-open    -- thread.status == "open" exactly. Matches the reconcile
#                  rule in /annotate's procedure ("filter to status=open").
#                  Resolved/in-progress are NOT included; the user can use
#                  those statuses to manually park threads outside the
#                  reconcile flow.
#   :ai-closed  -- thread.status == "closed". Historical entries closed
#                  by a prior reconcile pass.
#   :ai-other   -- any other status (resolved/in-progress/...). Surfaced
#                  separately so a non-zero count is visible.
#   :ai-stale   -- entries whose file is missing on disk. Counted but
#                  excluded from per-status buckets to keep them honest.
#
# Verify step in SKILL.md compares (kept + edited + created) against :ai-open.
#
# Usage:  count.sh
# Output: a sexp like
#   (:roots ("/abs/path1/") :files-with-ai 29
#    :ai-open 142 :ai-closed 5 :ai-other 0 :ai-stale 0
#    :ai-annotations 147)

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_git_repo

emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (let* ((roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r)))
                        $(roots_list_elisp)))
         (db (simply-annotate--load-database))
         (files-with-ai 0)
         (ai-open 0)
         (ai-closed 0)
         (ai-other 0)
         (ai-stale 0))
    (dolist (entry (or db nil))
      (let ((key (car entry))
            (anns (cdr entry)))
        (when (and (stringp key)
                   (file-name-absolute-p key)
                   (seq-some (lambda (root) (file-in-directory-p key root)) roots))
          (let ((file-exists (file-exists-p key))
                (here 0))
            (dolist (a anns)
              (let ((data (alist-get 'text a)))
                (when (annotate--ai-p data)
                  (cond
                   ((not file-exists)
                    (setq ai-stale (1+ ai-stale)))
                   ((annotate--open-p data)
                    (setq here (1+ here))
                    (setq ai-open (1+ ai-open)))
                   ((string= (annotate--status data) "closed")
                    (setq here (1+ here))
                    (setq ai-closed (1+ ai-closed)))
                   (t
                    (setq here (1+ here))
                    (setq ai-other (1+ ai-other)))))))
            (when (> here 0)
              (setq files-with-ai (1+ files-with-ai)))))))
    (list :roots roots
          :files-with-ai files-with-ai
          :ai-open ai-open
          :ai-closed ai-closed
          :ai-other ai-other
          :ai-stale ai-stale
          :ai-annotations (+ ai-open ai-closed ai-other))))
EOF
