;;; checkdoc-batch.el --- Batch checkdoc runner  -*- lexical-binding: t; -*-

;;; Commentary:
;; Run checkdoc over the files given on the command line and exit
;; non-zero when any issue is reported.  Used by the Makefile's
;; `checkdoc' target.

;;; Code:

(require 'checkdoc)

(let ((issues 0))
  (dolist (file command-line-args-left)
    (with-current-buffer (find-file-noselect file)
      (let ((checkdoc-autofix-flag 'never)
            (checkdoc-diagnostic-buffer "*checkdoc-batch*")
            (checkdoc-create-error-function
             (lambda (text start _end &optional _unfixable)
               (setq issues (1+ issues))
               (message "%s:%d: %s"
                        (buffer-file-name)
                        (if start (line-number-at-pos start) 0)
                        text)
               nil)))
        (checkdoc-current-buffer t))))
  (setq command-line-args-left nil)
  (if (> issues 0)
      (progn
        (message "checkdoc: %d issue(s) found" issues)
        (kill-emacs 1))
    (kill-emacs 0)))

;;; checkdoc-batch.el ends here
