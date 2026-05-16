;;; claude-emacs-annotate-thread.el --- Per-thread view/edit buffers  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; A dedicated read-only buffer per annotation thread plus small
;; commit-style buffers for replies and comment edits.  There is no
;; singleton and no global edit state: every buffer carries its own
;; project root and thread id, so any number of threads can be viewed
;; and edited concurrently.  Commits go through the id-addressed API;
;; a thread deleted underneath an edit never loses the typed text --
;; it lands in the kill ring and the edit buffer survives.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-view)

(defvar-local claude-emacs-annotate--thread-root nil
  "Project root of the thread this buffer shows or edits.")

(defvar-local claude-emacs-annotate--thread-id nil
  "Id of the thread this buffer shows or edits.")

(defvar-local claude-emacs-annotate--thread-action nil
  "Pending edit-buffer action: (reply . PARENT-ID) or (edit . COMMENT-ID).")

;;;; Rendering

(defun claude-emacs-annotate--thread-insert-comment (node depth)
  "Insert comment tree NODE at DEPTH, tagging it with its comment id."
  (pcase-let* ((`(,comment . ,children) node)
               (indent (make-string (* 2 depth) ?\s))
               (start (point)))
    (insert indent
            (if (> depth 0) "↳ " "")
            (claude-emacs-annotate-comment-author comment)
            (format " (%s)" (claude-emacs-annotate--view-time
                             (claude-emacs-annotate-comment-timestamp
                              comment)))
            (if (plist-get comment :edited) " · edited" "")
            "\n")
    (dolist (line (claude-emacs-annotate--view-fill
                   (claude-emacs-annotate-comment-text comment)
                   (- (or claude-emacs-annotate-inline-fill-column 72)
                      (length indent))))
      (insert indent "  " line "\n"))
    (insert "\n")
    (put-text-property start (point) 'claude-emacs-annotate-comment-id
                       (claude-emacs-annotate-comment-id comment))
    (dolist (child children)
      (claude-emacs-annotate--thread-insert-comment child (1+ depth)))))

(defun claude-emacs-annotate--thread-render ()
  "Render this buffer's thread from the store."
  (let* ((store (claude-emacs-annotate-store-get
                 claude-emacs-annotate--thread-root t))
         (thread (and store
                      (claude-emacs-annotate-store-thread
                       store claude-emacs-annotate--thread-id)))
         (inhibit-read-only t))
    (erase-buffer)
    (if (null thread)
        (insert "(thread deleted)\n")
      (let* ((anchor (claude-emacs-annotate-thread-anchor thread))
             (badge (claude-emacs-annotate--view-state-badge
                     (plist-get anchor :state))))
        (insert (format "%s:%s"
                        (claude-emacs-annotate-thread-file thread)
                        (if (eq (plist-get anchor :kind) 'file)
                            "whole file"
                          (format "%d-%d"
                                  (plist-get anchor :start-line)
                                  (plist-get anchor :end-line)))))
        (when badge (insert " " badge))
        (insert "\n")
        (insert (format "[%s/%s]"
                        (claude-emacs-annotate-thread-status thread)
                        (claude-emacs-annotate-thread-priority thread)))
        (let ((tags (claude-emacs-annotate-thread-tags thread)))
          (when tags (insert " " (string-join tags ","))))
        (insert (format "  ·  created %s  ·  updated %s\n\n"
                        (claude-emacs-annotate--view-time
                         (claude-emacs-annotate-thread-created thread))
                        (claude-emacs-annotate--view-time
                         (claude-emacs-annotate-thread-updated thread))))
        (dolist (node (claude-emacs-annotate-comment-tree
                       (claude-emacs-annotate-thread-comments thread)))
          (claude-emacs-annotate--thread-insert-comment node 0))))
    (goto-char (point-min))))

;;;; Thread view mode

(defvar-keymap claude-emacs-annotate-thread-mode-map
  :doc "Keymap of `claude-emacs-annotate-thread-mode'."
  :parent special-mode-map
  "r" #'claude-emacs-annotate-thread-reply
  "e" #'claude-emacs-annotate-thread-edit-comment
  "s" #'claude-emacs-annotate-thread-set-status
  "d" #'claude-emacs-annotate-thread-delete-comment
  "RET" #'claude-emacs-annotate-thread-goto-source
  "j" #'claude-emacs-annotate-thread-goto-source
  "g" #'claude-emacs-annotate-thread-rerender)

(define-derived-mode claude-emacs-annotate-thread-mode special-mode
  "Annotation"
  "Major mode showing one annotation thread."
  (setq buffer-read-only t))

;;;###autoload
(defun claude-emacs-annotate-thread-open (root thread-id)
  "Open a view buffer for THREAD-ID's thread under ROOT; return it."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (thread (and store
                      (claude-emacs-annotate-store-thread store thread-id))))
    (unless thread
      (signal 'claude-emacs-annotate-not-found
              (list (format "no thread with id %s in this project"
                            thread-id))))
    (let* ((anchor (claude-emacs-annotate-thread-anchor thread))
           (buffer (get-buffer-create
                    (format "*claude-annotation: %s:%s %s*"
                            (file-name-nondirectory
                             (claude-emacs-annotate-thread-file thread))
                            (or (plist-get anchor :start-line) "file")
                            (substring thread-id
                                       (max 0 (- (length thread-id) 8)))))))
      (with-current-buffer buffer
        (unless (derived-mode-p 'claude-emacs-annotate-thread-mode)
          (claude-emacs-annotate-thread-mode))
        (setq claude-emacs-annotate--thread-root canon)
        (setq claude-emacs-annotate--thread-id thread-id)
        (claude-emacs-annotate--thread-render))
      buffer)))

(defun claude-emacs-annotate-thread-open-at-point ()
  "Open the thread view of the annotation at point."
  (interactive)
  (pcase-let ((`(,_store . ,thread)
               (claude-emacs-annotate--view-thread-at-point)))
    (pop-to-buffer
     (claude-emacs-annotate-thread-open
      claude-emacs-annotate--view-root
      (claude-emacs-annotate-thread-id thread)))))

;;;; Thread view commands

(defun claude-emacs-annotate--thread-current ()
  "Return this view buffer's thread from the store, or signal."
  (let* ((store (claude-emacs-annotate-store-get
                 claude-emacs-annotate--thread-root t))
         (thread (and store
                      (claude-emacs-annotate-store-thread
                       store claude-emacs-annotate--thread-id))))
    (unless thread
      (user-error "This thread no longer exists"))
    thread))

(defun claude-emacs-annotate--thread-comment-at-point ()
  "Return the comment id rendered at point, or nil."
  (get-text-property (point) 'claude-emacs-annotate-comment-id))

(defun claude-emacs-annotate-thread-reply ()
  "Reply to the comment at point (or the root comment)."
  (interactive)
  (let* ((thread (claude-emacs-annotate--thread-current))
         (parent-id (or (claude-emacs-annotate--thread-comment-at-point)
                        (claude-emacs-annotate-comment-id
                         (claude-emacs-annotate-thread-root-comment
                          thread)))))
    (pop-to-buffer
     (claude-emacs-annotate--thread-edit-buffer
      claude-emacs-annotate--thread-root
      claude-emacs-annotate--thread-id
      (cons 'reply parent-id)))))

(defun claude-emacs-annotate-thread-edit-comment ()
  "Edit the text of the comment at point."
  (interactive)
  (let* ((thread (claude-emacs-annotate--thread-current))
         (comment-id (or (claude-emacs-annotate--thread-comment-at-point)
                         (user-error "No comment at point")))
         (comment (claude-emacs-annotate-comment-by-id
                   (claude-emacs-annotate-thread-comments thread)
                   comment-id)))
    (pop-to-buffer
     (claude-emacs-annotate--thread-edit-buffer
      claude-emacs-annotate--thread-root
      claude-emacs-annotate--thread-id
      (cons 'edit comment-id)
      (claude-emacs-annotate-comment-text comment)))))

(defun claude-emacs-annotate-thread-set-status ()
  "Change this thread's status."
  (interactive)
  (claude-emacs-annotate--thread-current)
  (let ((status (completing-read "Status: "
                                 claude-emacs-annotate-thread-statuses
                                 nil t)))
    (claude-emacs-annotate-api-set-status
     claude-emacs-annotate--thread-root
     claude-emacs-annotate--thread-id
     status)))

(defun claude-emacs-annotate-thread-delete-comment ()
  "Delete the leaf comment at point; on the root, offer thread deletion."
  (interactive)
  (let* ((thread (claude-emacs-annotate--thread-current))
         (comment-id (or (claude-emacs-annotate--thread-comment-at-point)
                         (user-error "No comment at point")))
         (root-id (claude-emacs-annotate-comment-id
                   (claude-emacs-annotate-thread-root-comment thread))))
    (if (equal comment-id root-id)
        (when (y-or-n-p "Delete the whole thread? ")
          (claude-emacs-annotate-api-delete
           claude-emacs-annotate--thread-root
           claude-emacs-annotate--thread-id))
      (when (y-or-n-p "Delete this comment? ")
        (claude-emacs-annotate-api-delete-comment
         claude-emacs-annotate--thread-root
         claude-emacs-annotate--thread-id
         comment-id)))))

(defun claude-emacs-annotate-thread-goto-source ()
  "Jump to this thread's location in its source file."
  (interactive)
  (claude-emacs-annotate-view-goto-thread
   claude-emacs-annotate--thread-root
   claude-emacs-annotate--thread-id))

(defun claude-emacs-annotate-thread-rerender ()
  "Redraw this thread view from the store."
  (interactive)
  (claude-emacs-annotate--thread-render))

;;;; Edit buffers

(defvar-keymap claude-emacs-annotate-edit-mode-map
  :doc "Keymap of `claude-emacs-annotate-edit-mode'."
  "C-c C-c" #'claude-emacs-annotate-edit-commit
  "C-c C-k" #'claude-emacs-annotate-edit-cancel)

(define-derived-mode claude-emacs-annotate-edit-mode text-mode
  "Annotation-Edit"
  "Major mode for composing annotation text.
Used for new annotations, replies and comment edits.  Commit with
\\[claude-emacs-annotate-edit-commit]; cancel with
\\[claude-emacs-annotate-edit-cancel]."
  (setq-local fill-column claude-emacs-annotate-inline-fill-column)
  (setq header-line-format
        (substitute-command-keys
         " Commit: \\[claude-emacs-annotate-edit-commit]   Cancel: \\[claude-emacs-annotate-edit-cancel]"))
  (visual-line-mode 1))

(defun claude-emacs-annotate--thread-pop-to-edit (buffer)
  "Show the compose BUFFER in a small window below and select it."
  (condition-case nil
      (select-window
       (display-buffer buffer '((display-buffer-below-selected)
                                (window-height . 0.25))))
    (error (pop-to-buffer buffer)))
  buffer)

(defun claude-emacs-annotate--thread-compose-matches-p (buffer root file
                                                               start-line)
  "Return non-nil when BUFFER drafts a new thread at the same spot.
The spot is ROOT's project-relative FILE with an anchor starting at
START-LINE (nil for whole-file drafts)."
  (with-current-buffer buffer
    (pcase claude-emacs-annotate--thread-action
      (`(create . ,spec)
       (and (equal claude-emacs-annotate--thread-root root)
            (equal (plist-get spec :file) file)
            (equal (plist-get (plist-get spec :anchor) :start-line)
                   start-line))))))

(defun claude-emacs-annotate--thread-compose-create (root file anchor tag
                                                          start-line)
  "Return a compose buffer whose commit opens a new thread.
ROOT and project-relative FILE locate the annotation; ANCHOR was
captured from the originating buffer when the command fired, so the
annotated content is pinned even if that buffer changes while the
text is being written.  TAG optionally names the annotation set;
START-LINE labels the buffer name and, with ROOT and FILE, decides
which existing draft buffer counts as the same spot."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (buffer
          (or (seq-find (lambda (candidate)
                          (claude-emacs-annotate--thread-compose-matches-p
                           candidate canon file start-line))
                        (buffer-list))
              (generate-new-buffer
               (format "*claude-annotation new: %s:%s*"
                       (file-name-nondirectory file)
                       (or start-line "file"))))))
    (with-current-buffer buffer
      (claude-emacs-annotate-edit-mode)
      (setq claude-emacs-annotate--thread-root canon)
      (setq claude-emacs-annotate--thread-id nil)
      (setq claude-emacs-annotate--thread-action
            (cons 'create (list :file file :anchor anchor :tag tag))))
    ;; Deliberately no erase: commit and cancel both kill the buffer,
    ;; so any surviving content is an uncommitted draft the user typed
    ;; -- re-invoking create at the same spot must not clobber it.
    buffer))

(defun claude-emacs-annotate--thread-edit-buffer (root thread-id action
                                                       &optional initial)
  "Return an edit buffer for THREAD-ID under ROOT performing ACTION.
ACTION is (reply . PARENT-ID) or (edit . COMMENT-ID).  INITIAL
pre-fills the buffer (for edits).  One edit buffer exists per thread,
so edits on different threads never share state."
  (let ((buffer (get-buffer-create
                 (format "*claude-annotation edit: %s*"
                         (substring thread-id
                                    (max 0 (- (length thread-id) 8)))))))
    (with-current-buffer buffer
      (claude-emacs-annotate-edit-mode)
      (setq claude-emacs-annotate--thread-root
            (claude-emacs-annotate--normalize-root root))
      (setq claude-emacs-annotate--thread-id thread-id)
      (setq claude-emacs-annotate--thread-action action)
      (erase-buffer)
      (when initial (insert initial)))
    buffer))

(defun claude-emacs-annotate-edit-commit ()
  "Commit this edit buffer through the id-addressed API.
When the thread vanished meanwhile, the text is pushed to the kill
ring and the buffer survives so nothing typed is ever lost."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (root claude-emacs-annotate--thread-root)
        (thread-id claude-emacs-annotate--thread-id)
        (action claude-emacs-annotate--thread-action))
    (when (string-empty-p text)
      (user-error "Nothing to commit"))
    (condition-case nil
        (pcase action
          (`(reply . ,parent-id)
           (claude-emacs-annotate-api-reply root thread-id parent-id text
                                            :author
                                            (claude-emacs-annotate-author)
                                            :require-open nil
                                            :require-leaf nil))
          (`(edit . ,comment-id)
           (claude-emacs-annotate-api-edit-comment root thread-id comment-id
                                                   text))
          (`(create . ,spec)
           (let ((thread (claude-emacs-annotate-thread-create
                          (plist-get spec :file)
                          (plist-get spec :anchor)
                          text
                          (claude-emacs-annotate-author)
                          :tags (when-let* ((tag (plist-get spec :tag)))
                                  (list tag))))
                 (store (claude-emacs-annotate-store-get root)))
             (claude-emacs-annotate-store-mutate
              store
              (lambda ()
                (claude-emacs-annotate-store-insert-thread store thread)))))
          (_ (user-error "This buffer has no pending edit action")))
      (claude-emacs-annotate-not-found
       (kill-new text)
       (user-error
        "The thread no longer exists; your text is in the kill ring")))
    (claude-emacs-annotate-edit-cancel)))

(defun claude-emacs-annotate-edit-cancel ()
  "Abandon this edit buffer."
  (interactive)
  (let ((buffer (current-buffer)))
    (if (window-live-p (get-buffer-window buffer))
        (quit-window t (get-buffer-window buffer))
      (kill-buffer buffer))))

;;;; Store events keep thread views honest

(defun claude-emacs-annotate--thread-on-change (event)
  "Refresh thread view buffers touched by the store EVENT."
  (let ((root (plist-get event :root))
        (ids (plist-get event :thread-ids)))
    (claude-emacs-annotate--map-buffers
     (lambda ()
       (when (and (derived-mode-p 'claude-emacs-annotate-thread-mode)
                  (equal claude-emacs-annotate--thread-root root)
                  (member claude-emacs-annotate--thread-id ids))
         (claude-emacs-annotate--thread-render))))))

(add-hook 'claude-emacs-annotate-changed-hook
          #'claude-emacs-annotate--thread-on-change)

(provide 'claude-emacs-annotate-thread)
;;; claude-emacs-annotate-thread.el ends here
