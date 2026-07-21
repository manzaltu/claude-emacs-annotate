;;; claude-emacs-annotate-table.el --- Project annotations table  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; A `tabulated-list-mode' view over a whole project store.  Rows are
;; rendered purely from store data -- line numbers come from anchors,
;; so listing a project never visits a single file buffer.  Actions
;; address threads by id and the table auto-refreshes on store change
;; events.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-view)

(defvar-local claude-emacs-annotate--table-root nil
  "Project root this annotations table lists.")

(defvar-local claude-emacs-annotate--table-filter-tag nil
  "Tag filter of this table, or nil for all tags.")

(defvar-local claude-emacs-annotate--table-filter-author nil
  "Root-author filter of this table, or nil for all authors.")

(defvar-local claude-emacs-annotate--table-filter-status nil
  "Status filter of this table, or nil for all statuses.")

;;;; Rendering

(defun claude-emacs-annotate--table-state-cell (anchor)
  "Return the ! column cell for a thread resolved to ANCHOR.
Fresh anchors show nothing; stale ones flag an S."
  (if (eq 'stale (plist-get anchor :state))
      (propertize "S" 'face 'claude-emacs-annotate-stale-face)
    ""))

(defun claude-emacs-annotate--table-lines-cell (anchor)
  "Return the Lines cell for a thread resolved to ANCHOR."
  (if (eq (plist-get anchor :kind) 'file)
      "file"
    (let ((start (plist-get anchor :start-line))
          (end (plist-get anchor :end-line)))
      (if (equal start end)
          (format "%d" start)
        (format "%d-%d" start end)))))

(defun claude-emacs-annotate--table-entry (thread anchor)
  "Return the tabulated-list entry for THREAD resolved to ANCHOR."
  (let* ((author (or (claude-emacs-annotate-thread-root-author thread) ""))
         (summary (car (split-string
                        (or (claude-emacs-annotate-comment-text
                             (claude-emacs-annotate-thread-root-comment
                              thread))
                            "")
                        "\n"))))
    (list (claude-emacs-annotate-thread-id thread)
          (vector (claude-emacs-annotate--table-state-cell anchor)
                  (claude-emacs-annotate-thread-file thread)
                  (claude-emacs-annotate--table-lines-cell anchor)
                  (claude-emacs-annotate-thread-status thread)
                  (claude-emacs-annotate-thread-priority thread)
                  (number-to-string
                   (length (claude-emacs-annotate-thread-comments thread)))
                  (string-join (claude-emacs-annotate-thread-tags thread)
                               ",")
                  (if (equal author claude-emacs-annotate-agent-author)
                      (propertize author 'face
                                  'claude-emacs-annotate-agent-author-face)
                    author)
                  summary))))

(defun claude-emacs-annotate--table-threads ()
  "Return this table's threads after applying its filters.
The buffer-local tag/author/status filters compose with the global
`claude-emacs-annotate-filter-tag'."
  (when-let* ((store (claude-emacs-annotate-store-get
                      claude-emacs-annotate--table-root t)))
    (seq-filter
     (lambda (thread)
       (and (not (claude-emacs-annotate-thread-filtered-p thread))
            (or (null claude-emacs-annotate--table-filter-tag)
                (member claude-emacs-annotate--table-filter-tag
                        (claude-emacs-annotate-thread-tags thread)))
            (or (null claude-emacs-annotate--table-filter-author)
                (equal (claude-emacs-annotate-thread-root-author thread)
                       claude-emacs-annotate--table-filter-author))
            (or (null claude-emacs-annotate--table-filter-status)
                (equal (claude-emacs-annotate-thread-status thread)
                       claude-emacs-annotate--table-filter-status))))
     (sort (claude-emacs-annotate-store-all-threads store)
           #'claude-emacs-annotate--api-thread<))))

(defun claude-emacs-annotate--table-refresh-entries ()
  "Recompute `tabulated-list-entries' from the store.
Anchors are resolved against on-disk content (in temp buffers, no
files are visited), so the state and line columns report the files
as they are now rather than as last persisted.  When any filter
hides threads, the mode line notes shown/total."
  (let* ((store (claude-emacs-annotate-store-get
                 claude-emacs-annotate--table-root t))
         (total (length (and store
                             (claude-emacs-annotate-store-all-threads
                              store))))
         (threads (claude-emacs-annotate--table-threads))
         (resolved (claude-emacs-annotate--api-resolve-anchors
                    claude-emacs-annotate--table-root threads)))
    (setq mode-line-process
          (and (< (length threads) total)
               (format ": %d/%d" (length threads) total)))
    (setq tabulated-list-entries
          (mapcar (lambda (thread)
                    (claude-emacs-annotate--table-entry
                     thread
                     (cdr (assq thread resolved))))
                  threads))))

;;;; Mode

(defvar-keymap claude-emacs-annotate-table-mode-map
  :doc "Keymap of `claude-emacs-annotate-table-mode'."
  :parent tabulated-list-mode-map
  "RET" #'claude-emacs-annotate-table-goto
  "D" #'claude-emacs-annotate-table-delete
  "s" #'claude-emacs-annotate-table-set-status
  "t" #'claude-emacs-annotate-table-filter-by-tag
  "a" #'claude-emacs-annotate-table-filter-by-author
  "o" #'claude-emacs-annotate-table-filter-by-status
  "g" #'claude-emacs-annotate-table-refresh
  "r" #'claude-emacs-annotate-table-reanchor)

(define-derived-mode claude-emacs-annotate-table-mode tabulated-list-mode
  "Annotations"
  "Major mode listing a project's annotation threads."
  (setq tabulated-list-format
        (vector (list "!" 1 t)
                (list "File" 28 t)
                (list "Lines" 8 nil)
                (list "Status" 11 t)
                (list "Pri" 8 t)
                (list "Cmts" 4 nil)
                (list "Tags" 16 t)
                (list "Author" 12 t)
                (list "Summary" 40 nil)))
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook
            #'claude-emacs-annotate--table-refresh-entries nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun claude-emacs-annotate-list (&optional root)
  "List the annotation threads of the project at ROOT.
ROOT defaults to the current buffer's project.  Return the table
buffer."
  (interactive)
  (let* ((canon (claude-emacs-annotate--normalize-root
                 (or root
                     (claude-emacs-annotate-project-root)
                     (user-error "Not inside a project"))))
         (buffer (get-buffer-create
                  (format "*claude-annotations: %s*"
                          (abbreviate-file-name canon)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-emacs-annotate-table-mode)
        (claude-emacs-annotate-table-mode))
      (setq claude-emacs-annotate--table-root canon)
      (revert-buffer))
    (when (called-interactively-p 'any)
      (pop-to-buffer buffer))
    buffer))

;;;; Actions

(defun claude-emacs-annotate--table-thread-id ()
  "Return the thread id of the row at point."
  (or (tabulated-list-get-id)
      (user-error "No annotation on this line")))

(defun claude-emacs-annotate-table-goto ()
  "Open the annotation at point in its source file."
  (interactive)
  (claude-emacs-annotate-view-goto-thread
   claude-emacs-annotate--table-root
   (claude-emacs-annotate--table-thread-id)))

(defun claude-emacs-annotate-table-delete ()
  "Delete the annotation thread at point, after confirmation."
  (interactive)
  (let ((id (claude-emacs-annotate--table-thread-id)))
    (when (y-or-n-p (format "Delete thread %s? " id))
      (claude-emacs-annotate-api-delete
       claude-emacs-annotate--table-root id))))

(defun claude-emacs-annotate-table-set-status ()
  "Change the status of the annotation thread at point."
  (interactive)
  (let ((id (claude-emacs-annotate--table-thread-id))
        (status (completing-read "Status: "
                                 claude-emacs-annotate-thread-statuses
                                 nil t)))
    (claude-emacs-annotate-api-set-status
     claude-emacs-annotate--table-root id status)))

(defun claude-emacs-annotate--table-read-filter (label candidates)
  "Read a LABEL filter value among CANDIDATES; empty input means all."
  (let ((choice (completing-read (format "%s (empty shows all): " label)
                                 candidates nil nil)))
    (unless (string-empty-p choice) choice)))

(defun claude-emacs-annotate-table-filter-by-tag ()
  "Filter this table by tag.
The candidates ignore the tag filter being replaced -- an active tag
must not narrow its own prompt to itself -- while the other filters
still scope them."
  (interactive)
  (let ((tags (let ((claude-emacs-annotate--table-filter-tag nil))
                (seq-uniq (mapcan (lambda (thread)
                                    (copy-sequence
                                     (claude-emacs-annotate-thread-tags
                                      thread)))
                                  (claude-emacs-annotate--table-threads))))))
    (setq claude-emacs-annotate--table-filter-tag
          (claude-emacs-annotate--table-read-filter "Tag" tags))
    (revert-buffer)))

(defun claude-emacs-annotate-table-filter-by-author ()
  "Filter this table by root author.
The candidates ignore the author filter being replaced, like the tag
prompt does with its own."
  (interactive)
  (setq claude-emacs-annotate--table-filter-author
        (claude-emacs-annotate--table-read-filter
         "Author"
         (let ((claude-emacs-annotate--table-filter-author nil))
           (seq-uniq (mapcar #'claude-emacs-annotate-thread-root-author
                             (claude-emacs-annotate--table-threads))))))
  (revert-buffer))

(defun claude-emacs-annotate-table-filter-by-status ()
  "Filter this table by status."
  (interactive)
  (setq claude-emacs-annotate--table-filter-status
        (claude-emacs-annotate--table-read-filter
         "Status" claude-emacs-annotate-thread-statuses))
  (revert-buffer))

(defun claude-emacs-annotate-table-refresh ()
  "Reload the store from disk and rebuild the table."
  (interactive)
  (when-let* ((store (claude-emacs-annotate-store-get
                      claude-emacs-annotate--table-root t)))
    (claude-emacs-annotate-store-refresh store))
  (revert-buffer))

(defun claude-emacs-annotate-table-reanchor ()
  "Jump to the stale annotation at point to re-anchor it."
  (interactive)
  (let* ((id (claude-emacs-annotate--table-thread-id))
         (store (claude-emacs-annotate-store-get
                 claude-emacs-annotate--table-root t))
         (thread (and store (claude-emacs-annotate-store-thread store id)))
         (resolved (and thread
                        (cdr (assq thread
                                   (claude-emacs-annotate--api-resolve-anchors
                                    claude-emacs-annotate--table-root
                                    (list thread)))))))
    (if (not (eq 'stale (plist-get resolved :state)))
        (message "Thread %s is not stale" id)
      (claude-emacs-annotate-table-goto)
      (message (concat "Select the region the annotation belongs to and"
                       " run claude-emacs-annotate-reanchor")))))

;;;; Auto-refresh on store events

(defun claude-emacs-annotate--table-on-change (event)
  "Refresh open tables of the project the store EVENT belongs to."
  (claude-emacs-annotate--map-buffers
   (lambda ()
     (when (and (derived-mode-p 'claude-emacs-annotate-table-mode)
                (equal claude-emacs-annotate--table-root
                       (plist-get event :root)))
       (revert-buffer)))))

(add-hook 'claude-emacs-annotate-changed-hook
          #'claude-emacs-annotate--table-on-change)

(provide 'claude-emacs-annotate-table)
;;; claude-emacs-annotate-table.el ends here
