#!/usr/bin/env bash
# Remove every skill-authored annotation (author = ANNOTATE_AUTHOR) whose
# file lives inside the current project's scope roots (see lib.sh::scope_roots).
# Other authors' annotations and annotations in other projects are left
# untouched.
#
# Usage:  clear-ai.sh
# Run this from within the project (it uses scope_roots from the script's CWD,
# NOT whatever buffer Emacs has current).

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
         ;; Walk db entries, not just keys: pre-filter to files that have
         ;; at least one skill-authored annotation. Avoids opening buffers
         ;; for files whose only entries are by other authors.
         (in-project
          (mapcar #'car
                  (seq-filter
                   (lambda (entry)
                     (let ((k (car entry)))
                       (and (stringp k)
                            (file-name-absolute-p k)
                            ;; file-in-directory-p avoids /repo matching /repo-other.
                            (seq-some (lambda (root) (file-in-directory-p k root)) roots)
                            (seq-some (lambda (a)
                                        (annotate--ai-p (alist-get 'text a)))
                                      (cdr entry)))))
                   (or db nil))))
         (cleared 0)
         (visited 0)
         (untouched 0))
    (dolist (key in-project)
      (when (file-exists-p key)
        (let* ((existing (find-buffer-visiting key))
               (buf (or existing (find-file-noselect key)))
               (created-buf (not existing))
               (removed-here 0))
          (setq visited (1+ visited))
          (unwind-protect
              (with-current-buffer buf
                (let ((targets
                       (seq-filter
                        (lambda (ov)
                          (annotate--ai-p (overlay-get ov 'simply-annotation)))
                        (copy-sequence simply-annotate-overlays))))
                  (dolist (ov targets)
                    (simply-annotate--remove-overlay ov)
                    (setq removed-here (1+ removed-here)))
                  (when (> removed-here 0)
                    (simply-annotate--save-annotations))
                  (setq cleared (+ cleared removed-here))
                  (when (zerop removed-here) (setq untouched (1+ untouched)))))
            (when (and created-buf (buffer-live-p buf))
              (unless (buffer-modified-p buf) (kill-buffer buf)))))))
    (list :roots roots
          :files-considered (length in-project)
          :files-visited visited
          :annotations-removed cleared
          :files-with-no-ai-annotations untouched)))
EOF
