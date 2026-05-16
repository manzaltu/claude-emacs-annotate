;;; cea-test-helpers.el --- Shared test scaffolding  -*- lexical-binding: t; -*-

;;; Commentary:
;; Common fixtures for the claude-emacs-annotate test suites: an
;; isolated environment macro (fresh store registry, temp database
;; directory, pinned project root, watcher off) and small data
;; builders.

;;; Code:

(require 'cl-lib)
(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-api)

(defvar cea-test-home nil
  "Root temp directory of the active `cea-test-with-env' environment.")

(defvar cea-test-project nil
  "Project directory of the active `cea-test-with-env' environment.")

(defmacro cea-test-with-env (&rest body)
  "Run BODY in an isolated annotation environment.
Binds `cea-test-home' (a fresh temp dir), `cea-test-project' (a
project dir inside it), points `claude-emacs-annotate-directory' at a
temp db dir, resets the store registry, disables the file watcher and
pins `claude-emacs-annotate-project-root-function' to the project."
  (declare (indent 0) (debug t))
  `(let* ((cea-test-home (make-temp-file "cea-test-" t))
          (cea-test-project (expand-file-name "project" cea-test-home))
          (claude-emacs-annotate-directory
           (expand-file-name "db" cea-test-home))
          (claude-emacs-annotate--stores (make-hash-table :test #'equal))
          (claude-emacs-annotate-use-file-watcher nil)
          (claude-emacs-annotate-project-root-function
           (lambda (&optional _dir) cea-test-project)))
     (make-directory cea-test-project t)
     (unwind-protect
         (progn ,@body)
       (delete-directory cea-test-home t))))

(defmacro cea-test-with-fresh-registry (&rest body)
  "Run BODY against a fresh store registry.
Reading the project store inside BODY simulates a second Emacs
process that shares only the on-disk database."
  (declare (indent 0) (debug t))
  `(let ((claude-emacs-annotate--stores (make-hash-table :test #'equal)))
     ,@body))

(defun cea-test-api-create (file start end &rest keys)
  "Create an annotation on FILE lines START..END via the API.
KEYS ride through to `claude-emacs-annotate-api-create'; :text
defaults to \"note\" and :author to \"claude-code\"."
  (claude-emacs-annotate-api-create
   cea-test-project
   (append (list :file file :start-line start :end-line end
                 :text (or (plist-get keys :text) "note")
                 :author (or (plist-get keys :author) "claude-code"))
           (cl-loop for (key value) on keys by #'cddr
                    unless (memq key '(:text :author))
                    append (list key value)))))

(defun cea-test-api-call (op args)
  "Run `claude-emacs-annotate-api-call' and return the parsed envelope."
  (let ((out (expand-file-name (format "out-%s.json" op) cea-test-home)))
    (claude-emacs-annotate-api-call op cea-test-project args out)
    (with-temp-buffer
      (insert-file-contents out)
      (json-parse-string (buffer-string)))))

(defun cea-test-make-thread (file text &rest keys)
  "Return a new thread on FILE with root TEXT.
KEYS may contain :author (default \"claude-code\") plus the
`claude-emacs-annotate-thread-create' keywords :tags, :status,
:priority and an :anchor override."
  (apply #'claude-emacs-annotate-thread-create
         file
         (or (plist-get keys :anchor) '(:kind file :state fresh))
         text
         (or (plist-get keys :author) "claude-code")
         (cl-loop for (key value) on keys by #'cddr
                  unless (memq key '(:author :anchor))
                  append (list key value))))

(defun cea-test-insert (store thread)
  "Insert THREAD into STORE through the mutation gate."
  (claude-emacs-annotate-store-mutate
   store
   (lambda () (claude-emacs-annotate-store-insert-thread store thread)))
  thread)

(defun cea-test-write-file (path content)
  "Write CONTENT to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region content nil path nil 'silent))
  path)

(defun cea-test-project-file (name content)
  "Create project file NAME with CONTENT; return its absolute path."
  (cea-test-write-file (expand-file-name name cea-test-project) content))

(defun cea-test-file-lines (name lines)
  "Create project file NAME containing LINES; return its absolute path."
  (cea-test-project-file name (concat (string-join lines "\n") "\n")))

(provide 'cea-test-helpers)
;;; cea-test-helpers.el ends here
