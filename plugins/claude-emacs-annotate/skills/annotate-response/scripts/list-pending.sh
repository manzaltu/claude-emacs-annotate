#!/usr/bin/env bash
# List every comment in scope that is pending a response from this skill.
#
# Output: 7-column TSV, one row per pending comment.
#
#   <abs-file><TAB><start-line><TAB><end-line><TAB><thread-id><TAB><comment-id><TAB><author><TAB><text>
#
# A comment is "pending" iff all three conditions hold:
#   1. Its thread's status == "open" (closed/resolved/in-progress threads
#      are out of scope; the user owns those transitions).
#   2. Its author != ANNOTATE_AUTHOR (it's the user's, not ours).
#   3. It is a leaf in the parent-id tree (no other comment names it as
#      parent-id). "Leaf" is structural, not chronological -- two top-level
#      user comments under the same parent are both leaves.
#
# - <start-line>/<end-line> are the *thread*'s line range (comments don't
#   carry positions). Position->line conversion uses the same with-temp-buffer
#   + insert-file-contents trick as list-ai.sh, avoiding the user's
#   (find-file . simply-annotate-mode) hook reloading the db per file.
# - Embedded newlines in text are encoded as the two-character sequence
#   "\n" (matches batch.sh's decoder); literal TAB in author/text is
#   rejected loudly to keep the TSV well-formed.
# - Stale stored positions (file shrank/was rewritten) are skipped; a
#   summary count is printed to stderr.
#
# Usage:  list-pending.sh

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_git_repo

TMP=$(mktemp -t annotate-list-pending.XXXXXX)
trap 'rm -f "$TMP"' EXIT
QTMP=$(elisp_quote "$TMP")

RESULT=$(emacs_eval <<EOF
(cl-labels $(ai_helpers_elisp)
  (cl-labels
      (;; Walk a comment tree depth-first and write a TSV row for every leaf
       ;; whose author isn't ours. Embedded newlines encode as "\n"
       ;; (replacement "\\\\n" -> bash heredoc -> "\\n" -> elisp 2-char \+n).
       (emit-leaves (file sline eline thread-id nodes out)
         (dolist (node nodes)
           (let* ((c (car node))
                  (children (cdr node))
                  (author (or (alist-get 'author c) "")))
             (when (and (null children)
                        (not (string= author "${ANNOTATE_AUTHOR}")))
               (let ((cid (alist-get 'id c))
                     (text (or (alist-get 'text c) "")))
                 (when (string-match-p "\t" author)
                   (error "comment author in %s contains literal TAB; refusing to emit" file))
                 (when (string-match-p "\t" text)
                   (error "comment text in %s contains literal TAB; refusing to emit" file))
                 (with-current-buffer out
                   (insert (format "%s\t%d\t%d\t%s\t%s\t%s\t%s\n"
                                   file sline eline
                                   (or thread-id "")
                                   (or cid "")
                                   author
                                   (replace-regexp-in-string "\n" "\\\\n" text t t))))))
             (emit-leaves file sline eline thread-id children out)))))
    (let* ((roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r)))
                          $(roots_list_elisp)))
           (db (simply-annotate--load-database))
           (out (generate-new-buffer " *annotate-list-pending*"))
           (stale 0))
      (unwind-protect
          (progn
            (with-temp-buffer
              (dolist (entry (or db nil))
                (let* ((key (car entry))
                       (anns (cdr entry))
                       (open-threads
                        (seq-filter
                         (lambda (a)
                           (let ((data (alist-get 'text a)))
                             (and (simply-annotate--thread-p data)
                                  (annotate--open-p data))))
                         anns)))
                  (when (and open-threads
                             (stringp key)
                             (file-name-absolute-p key)
                             (file-exists-p key)
                             (seq-some (lambda (root) (file-in-directory-p key root)) roots))
                    (erase-buffer)
                    (insert-file-contents key)
                    (let ((max (point-max)))
                      (dolist (a open-threads)
                        (let ((data (alist-get 'text a))
                              (s (alist-get 'start a))
                              (e (alist-get 'end a)))
                          (cond
                           ((not (and (integerp s) (integerp e))) nil)
                           ((or (< s 1) (> s max) (> e max) (< e s))
                            (setq stale (1+ stale)))
                           (t
                            (emit-leaves
                             key
                             (line-number-at-pos s t)
                             (line-number-at-pos e t)
                             (alist-get 'id data)
                             (simply-annotate--build-comment-tree
                              (alist-get 'comments data))
                             out))))))))))
            (with-current-buffer out
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (point-min) (point-max) ${QTMP} nil 'silent))))
        (when (buffer-live-p out) (kill-buffer out)))
      (list :stale stale))))
EOF
)

stale=$(printf '%s' "$RESULT" | grep -oE ':stale [0-9]+' | awk '{print $2}')
if [[ -n "${stale:-}" && "$stale" != "0" ]]; then
  printf 'annotate list-pending: %s stale comment(s) skipped (file shrank or was rewritten)\n' "$stale" >&2
fi

cat "$TMP"
