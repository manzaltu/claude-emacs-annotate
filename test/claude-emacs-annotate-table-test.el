;;; claude-emacs-annotate-table-test.el --- Table tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; The project-wide annotations table: rendered purely from the store
;; (no buffer visits), filterable, id-addressed actions, auto-refresh
;; on store events.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-table)

(defun cea-table-test--make (file start end &rest keys)
  "Create a thread on FILE lines START..END via the API."
  (apply #'cea-test-api-create file start end
         :text (or (plist-get keys :text) "note text") keys))

(defmacro cea-table-test--with-table (&rest body)
  "Open the annotations table for the test project around BODY."
  (declare (indent 0) (debug t))
  `(let ((buffer (claude-emacs-annotate-list cea-test-project)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun cea-table-test--column (row name)
  "Return column NAME of the table entry vector ROW as plain text."
  (let* ((columns (mapcar (lambda (column) (car column))
                          tabulated-list-format))
         (index (seq-position columns name)))
    (substring-no-properties (aref row index))))

(defun cea-table-test--rows ()
  "Return the current table's rows as (ID . VECTOR)."
  (mapcar (lambda (entry) (cons (car entry) (cadr entry)))
          tabulated-list-entries))

;;;; Rendering

(ert-deftest cea-table-renders-without-visiting-files ()
  (cea-test-with-env
    (cea-test-project-file "src/a.el" "one\ntwo\nthree\n")
    (cea-test-project-file "src/b.el" "x\ny\n")
    (cea-table-test--make "src/a.el" 2 3 :tag "changes"
                          :text "first line summary\nsecond line")
    (cea-table-test--make "src/b.el" 1 1 :author "Jane Doe")
    (claude-emacs-annotate-api-create
     cea-test-project '(:file "src/b.el" :kind file :text "whole file"
                        :author "claude-code"))
    (let ((buffers-before (buffer-list)))
      (cea-table-test--with-table
        (let ((rows (cea-table-test--rows)))
          (should (= 3 (length rows)))
          (let ((row (cdr (seq-find (lambda (row)
                                      (equal "src/a.el"
                                             (cea-table-test--column
                                              (cdr row) "File")))
                                    rows))))
            (should (equal "2-3" (cea-table-test--column row "Lines")))
            (should (equal "open" (cea-table-test--column row "Status")))
            (should (equal "changes" (cea-table-test--column row "Tags")))
            (should (equal "claude-code"
                           (cea-table-test--column row "Author")))
            (should (equal "first line summary"
                           (cea-table-test--column row "Summary"))))
          ;; Whole-file row shows "file" in Lines.
          (should (seq-find (lambda (row)
                              (equal "file" (cea-table-test--column
                                             (cdr row) "Lines")))
                            rows))))
      ;; Building the table opened no file buffers.
      (should (equal buffers-before
                     (seq-remove (lambda (buffer)
                                   (string-prefix-p
                                    "*claude-annotations" (buffer-name
                                                           buffer)))
                                 (buffer-list)))))))

(ert-deftest cea-table-resolves-anchors-against-disk ()
  "The list reports current staleness and lines, not persisted state.
Content changed on disk shows its S -- and shifted content its new
lines -- with no buffer ever visiting the files."
  (cea-test-with-env
    (cea-test-project-file "d.el" "ctx a\nthe body\nctx b\n")
    (cea-test-project-file "e.el" "one\ntwo\nthree\n")
    (cea-table-test--make "d.el" 2 2)
    (cea-table-test--make "e.el" 2 2)
    ;; Both files change while nothing watches; the store still holds
    ;; fresh anchors at the old lines.
    (cea-test-project-file "d.el" "ctx a\nrewritten\nctx b\n")
    (cea-test-project-file "e.el" "new0\none\ntwo\nthree\n")
    (cea-table-test--with-table
      (let ((rows (cea-table-test--rows)))
        (should (equal "S" (cea-table-test--column (cdr (nth 0 rows)) "!")))
        (should (equal "" (cea-table-test--column (cdr (nth 1 rows)) "!")))
        (should (equal "3" (cea-table-test--column
                            (cdr (nth 1 rows)) "Lines")))))))

(ert-deftest cea-table-state-column-badges ()
  "The ! cell flags stale anchors with the stale face, empty otherwise."
  (let ((stale-cell (claude-emacs-annotate--table-state-cell
                     '(:kind region :state stale))))
    (should (equal "S" (substring-no-properties stale-cell)))
    (should (eq 'claude-emacs-annotate-stale-face
                (get-text-property 0 'face stale-cell))))
  (should (equal "" (claude-emacs-annotate--table-state-cell
                     '(:kind region :state fresh)))))

;;;; Filters

(ert-deftest cea-table-filter-prompts-ignore-their-own-filter ()
  "An active tag or author filter must not narrow its own prompt.
Re-filtering offers every value the other filters leave visible, not
just the one currently selected."
  (cea-test-with-env
    (cea-test-project-file "h.el" "a\nb\n")
    (cea-table-test--make "h.el" 1 1 :tag "keep")
    (cea-table-test--make "h.el" 2 2 :tag "drop" :author "Jane Doe")
    (cea-table-test--with-table
      (setq claude-emacs-annotate--table-filter-tag "keep")
      (revert-buffer)
      (should (= 1 (length (cea-table-test--rows))))
      (let (candidates)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (setq candidates collection)
                     "")))
          (claude-emacs-annotate-table-filter-by-tag))
        (should (member "keep" candidates))
        (should (member "drop" candidates)))
      ;; The empty choice above cleared the tag filter; authors too.
      (setq claude-emacs-annotate--table-filter-author "claude-code")
      (revert-buffer)
      (let (candidates)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _)
                     (setq candidates collection)
                     "")))
          (claude-emacs-annotate-table-filter-by-author))
        (should (member "claude-code" candidates))
        (should (member "Jane Doe" candidates))))))

(ert-deftest cea-table-filters-compose ()
  (cea-test-with-env
    (cea-test-project-file "f.el" "a\nb\nc\nd\n")
    (cea-table-test--make "f.el" 1 1 :tag "changes")
    (cea-table-test--make "f.el" 2 2 :tag "review-x")
    (cea-table-test--make "f.el" 3 3 :tag "review-x" :author "Jane Doe")
    (let ((closed (cea-table-test--make "f.el" 4 4 :tag "review-x")))
      (claude-emacs-annotate-api-set-status
       cea-test-project (claude-emacs-annotate-thread-id closed) "closed"))
    (cea-table-test--with-table
      (should (= 4 (length (cea-table-test--rows))))
      (setq claude-emacs-annotate--table-filter-tag "review-x")
      (revert-buffer)
      (should (= 3 (length (cea-table-test--rows))))
      (setq claude-emacs-annotate--table-filter-author "claude-code")
      (revert-buffer)
      (should (= 2 (length (cea-table-test--rows))))
      (setq claude-emacs-annotate--table-filter-status "open")
      (revert-buffer)
      (should (= 1 (length (cea-table-test--rows))))
      (setq claude-emacs-annotate--table-filter-tag nil
            claude-emacs-annotate--table-filter-author nil
            claude-emacs-annotate--table-filter-status nil)
      (revert-buffer)
      (should (= 4 (length (cea-table-test--rows)))))))

;;;; Actions

(ert-deftest cea-table-goto-opens-file-at-overlay ()
  (cea-test-with-env
    (cea-test-project-file "g.el" "m1\nm2\nm3\n")
    (let ((thread (cea-table-test--make "g.el" 2 2)))
      (cea-table-test--with-table
        (goto-char (point-min))
        (claude-emacs-annotate-table-goto)
        (should (equal "g.el"
                       (file-relative-name buffer-file-name
                                           cea-test-project)))
        (should (= 2 (line-number-at-pos (point) t)))
        (should (equal (claude-emacs-annotate-thread-id thread)
                       (overlay-get (car (claude-emacs-annotate--view-overlays-at
                                          (point)))
                                    'claude-emacs-annotate-id)))
        (kill-buffer (current-buffer))))))

(ert-deftest cea-table-delete-row ()
  (cea-test-with-env
    (cea-test-project-file "d.el" "n1\nn2\n")
    (cea-table-test--make "d.el" 1 1)
    (cea-table-test--with-table
      (goto-char (point-min))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (claude-emacs-annotate-table-delete))
      (should (= 0 (length (cea-table-test--rows))))
      (should (= 0 (length (claude-emacs-annotate-api-query
                            cea-test-project)))))))

;;;; Refresh

(ert-deftest cea-table-auto-refreshes-on-store-events ()
  (cea-test-with-env
    (cea-test-project-file "r.el" "p1\np2\n")
    (cea-table-test--make "r.el" 1 1)
    (cea-table-test--with-table
      (should (= 1 (length (cea-table-test--rows))))
      ;; A new thread lands while the table is open.
      (cea-table-test--make "r.el" 2 2)
      (should (= 2 (length (cea-table-test--rows)))))))

(ert-deftest cea-table-refresh-pulls-external-changes ()
  (cea-test-with-env
    (cea-test-project-file "x.el" "q1\nq2\n")
    (cea-table-test--make "x.el" 1 1)
    (cea-table-test--with-table
      (should (= 1 (length (cea-table-test--rows))))
      ;; A second process adds a thread directly on disk.
      (cea-test-with-fresh-registry
        (claude-emacs-annotate-api-create
         cea-test-project '(:file "x.el" :start-line 2 :end-line 2
                            :text "external" :author "claude-code")))
      (claude-emacs-annotate-table-refresh)
      (should (= 2 (length (cea-table-test--rows)))))))

(ert-deftest cea-table-distinct-buffers-for-same-basename-roots ()
  "Tables of two projects sharing a basename must not share a buffer.
Reusing one buffer silently retargets the first project's table at
the second project."
  (cea-test-with-env
    (let ((root-a (expand-file-name "alpha/same" cea-test-home))
          (root-b (expand-file-name "beta/same" cea-test-home)))
      (make-directory root-a t)
      (make-directory root-b t)
      (let ((buffer-a (claude-emacs-annotate-list root-a))
            (buffer-b (claude-emacs-annotate-list root-b)))
        (unwind-protect
            (progn
              (should-not (eq buffer-a buffer-b))
              (with-current-buffer buffer-a
                (should (equal (claude-emacs-annotate--normalize-root root-a)
                               claude-emacs-annotate--table-root)))
              (with-current-buffer buffer-b
                (should (equal (claude-emacs-annotate--normalize-root root-b)
                               claude-emacs-annotate--table-root))))
          (kill-buffer buffer-a)
          (kill-buffer buffer-b))))))

(provide 'claude-emacs-annotate-table-test)
;;; claude-emacs-annotate-table-test.el ends here
