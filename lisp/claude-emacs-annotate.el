;;; claude-emacs-annotate.el --- Threaded, resilient code annotations  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/manzaltu/claude-emacs-annotate

;;; Commentary:
;; Threaded annotations anchored to code by content, with a
;; per-project store that survives external file edits, buffer
;; reverts and concurrent writers.  Designed to be driven
;; programmatically (the bundled annotation skills talk to it through
;; `claude-emacs-annotate-api-call') while keeping a first-class
;; interactive UI: tinted or highlighted overlays with inline thread
;; boxes, a project-wide annotations table, and per-thread view/edit
;; buffers.
;;
;; The store is the source of truth; overlays are a view.  Every
;; mutation writes through to disk atomically, positions re-anchor by
;; content matching whenever buffers attach, and annotations are
;; never silently dropped -- at worst they are badged stale and can
;; be re-pinned with `claude-emacs-annotate-reanchor'.
;;
;; Enable `claude-emacs-annotate-global-mode' to activate annotated
;; buffers automatically, and bind `claude-emacs-annotate-command-map'
;; to a convenient prefix.

;;; Code:

(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-anchor)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-view)
(require 'claude-emacs-annotate-table)
(require 'claude-emacs-annotate-thread)

;;;; Global mode

(defun claude-emacs-annotate--maybe-enable ()
  "Enable the buffer mode for project files that carry annotations.
The check costs one project-root lookup and one `file-exists-p' on
the project's store file."
  (when (and buffer-file-name
             (not (minibufferp))
             (when-let* ((root (claude-emacs-annotate-project-root
                                (file-name-directory buffer-file-name))))
               (file-exists-p (claude-emacs-annotate-store-path root))))
    (claude-emacs-annotate-mode 1)))

;;;###autoload
(define-globalized-minor-mode claude-emacs-annotate-global-mode
  claude-emacs-annotate-mode
  claude-emacs-annotate--maybe-enable
  :group 'claude-emacs-annotate
  (unless claude-emacs-annotate-global-mode
    (claude-emacs-annotate-store-shutdown-all)))

;;;; DWIM entry point

;;;###autoload
(defun claude-emacs-annotate-dwim ()
  "Open the annotation at point, or create one here.
With an annotation under point, show its thread; otherwise annotate
the active region or the current line."
  (interactive)
  (if (and claude-emacs-annotate-mode
           (claude-emacs-annotate--view-overlays-at (point)))
      (claude-emacs-annotate-thread-open-at-point)
    (unless claude-emacs-annotate-mode
      (claude-emacs-annotate-mode 1))
    (unless claude-emacs-annotate-mode
      (user-error "Not in a project file"))
    (call-interactively #'claude-emacs-annotate-create)))

;;;; Command map

;;;###autoload
(defvar claude-emacs-annotate-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'claude-emacs-annotate-dwim)
    (define-key map (kbd "c") #'claude-emacs-annotate-create)
    (define-key map (kbd "n") #'claude-emacs-annotate-next)
    (define-key map (kbd "p") #'claude-emacs-annotate-previous)
    (define-key map (kbd "l") #'claude-emacs-annotate-list)
    (define-key map (kbd "j") #'claude-emacs-annotate-jump)
    (define-key map (kbd "t") #'claude-emacs-annotate-thread-open-at-point)
    (define-key map (kbd "i") #'claude-emacs-annotate-toggle-inline)
    (define-key map (kbd "o") #'claude-emacs-annotate-toggle-inline-at-point)
    (define-key map (kbd "s") #'claude-emacs-annotate-set-status-at-point)
    (define-key map (kbd "d") #'claude-emacs-annotate-delete-at-point)
    (define-key map (kbd "f") #'claude-emacs-annotate-filter-by-tag)
    (define-key map (kbd "a") #'claude-emacs-annotate-reanchor)
    (define-key map (kbd "g") #'claude-emacs-annotate-refresh)
    map)
  "Prefix keymap with the main annotation commands.
Bind it wherever convenient, for example:
  (keymap-set global-map \"C-c a\" claude-emacs-annotate-command-map)")

(provide 'claude-emacs-annotate)
;;; claude-emacs-annotate.el ends here
