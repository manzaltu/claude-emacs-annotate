;;; claude-emacs-annotate-thread-test.el --- Thread buffer tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Per-thread view/edit buffers: rendering with comment-id text
;; properties, commit-style reply/edit buffers addressed by id, and
;; the no-singleton guarantee -- two threads edit concurrently without
;; clobbering each other.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-thread)

(defun cea-thread-test--make (file text &rest keys)
  "Create a thread on line 1 of FILE with TEXT."
  (cea-test-project-file file "line one\nline two\n")
  (apply #'cea-test-api-create file 1 1 :text text keys))

(defun cea-thread-test--open (thread)
  "Open THREAD's view buffer; return it."
  (claude-emacs-annotate-thread-open
   cea-test-project (claude-emacs-annotate-thread-id thread)))

(defun cea-thread-test--goto-comment (comment-id)
  "Move point to the rendered block of COMMENT-ID in this buffer."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (equal (get-text-property (point)
                                    'claude-emacs-annotate-comment-id)
                 comment-id)
          (setq found t)
        (goto-char (or (next-single-property-change
                        (point) 'claude-emacs-annotate-comment-id)
                       (point-max)))))
    (unless found (error "Comment %s not rendered" comment-id))))

;;;; Rendering

(ert-deftest cea-thread-open-renders-thread ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "a.el" "root prose"
                                          :tag "changes"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread))))
      (claude-emacs-annotate-api-reply cea-test-project id root-id
                                       "user reply" :author "Jane Doe")
      (let ((buffer (cea-thread-test--open thread)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((content (buffer-string)))
                (should (string-match-p "a\\.el" content))
                (should (string-match-p "open" content))
                (should (string-match-p "changes" content))
                (should (string-match-p "root prose" content))
                (should (string-match-p "↳" content))
                (should (string-match-p "user reply" content))
                (should (string-match-p "Jane Doe" content)))
              ;; Comment blocks carry their ids as text properties.
              (cea-thread-test--goto-comment root-id)
              (should (derived-mode-p 'claude-emacs-annotate-thread-mode)))
          (kill-buffer buffer))))))

;;;; Reply / edit commits

(ert-deftest cea-thread-reply-commit-by-id ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "b.el" "needs answer"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (claude-emacs-annotate-default-author "Tester"))
      (let ((edit (claude-emacs-annotate--thread-edit-buffer
                   cea-test-project id (cons 'reply root-id))))
        (unwind-protect
            (with-current-buffer edit
              (insert "the answer\nwith two lines")
              (claude-emacs-annotate-edit-commit))
          (when (buffer-live-p edit) (kill-buffer edit))))
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (stored (claude-emacs-annotate-store-thread store id))
             (comments (claude-emacs-annotate-thread-comments stored)))
        (should (= 2 (length comments)))
        (should (equal "the answer\nwith two lines"
                       (claude-emacs-annotate-comment-text (cadr comments))))
        (should (equal "Tester"
                       (claude-emacs-annotate-comment-author
                        (cadr comments))))))))

(ert-deftest cea-thread-edit-commit-preserves-identity ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "c.el" "original text"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread))))
      (let ((edit (claude-emacs-annotate--thread-edit-buffer
                   cea-test-project id (cons 'edit root-id) "original text")))
        (unwind-protect
            (with-current-buffer edit
              (erase-buffer)
              (insert "rewritten text")
              (claude-emacs-annotate-edit-commit))
          (when (buffer-live-p edit) (kill-buffer edit))))
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (stored (claude-emacs-annotate-store-thread store id))
             (root (claude-emacs-annotate-thread-root-comment stored)))
        (should (equal root-id (claude-emacs-annotate-comment-id root)))
        (should (equal "rewritten text"
                       (claude-emacs-annotate-comment-text root)))))))

(ert-deftest cea-thread-commit-against-deleted-thread-rescues-text ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "d.el" "doomed"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (edit (claude-emacs-annotate--thread-edit-buffer
                  cea-test-project id (cons 'reply root-id))))
      (unwind-protect
          (progn
            (claude-emacs-annotate-api-delete cea-test-project id)
            (with-current-buffer edit
              (insert "precious words")
              (should-error (claude-emacs-annotate-edit-commit)
                            :type 'user-error)
              ;; The buffer survives and the text reached the kill ring.
              (should (buffer-live-p edit))
              (should (equal "precious words" (current-kill 0)))))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest cea-thread-two-threads-edit-independently ()
  "The singleton regression test: concurrent edits never clobber."
  (cea-test-with-env
    (let* ((thread-a (cea-thread-test--make "e.el" "thread a"))
           (thread-b (cea-thread-test--make "f.el" "thread b"))
           (id-a (claude-emacs-annotate-thread-id thread-a))
           (id-b (claude-emacs-annotate-thread-id thread-b))
           (root-a (claude-emacs-annotate-comment-id
                    (claude-emacs-annotate-thread-root-comment thread-a)))
           (root-b (claude-emacs-annotate-comment-id
                    (claude-emacs-annotate-thread-root-comment thread-b)))
           (claude-emacs-annotate-default-author "Tester")
           (edit-a (claude-emacs-annotate--thread-edit-buffer
                    cea-test-project id-a (cons 'reply root-a)))
           (edit-b (claude-emacs-annotate--thread-edit-buffer
                    cea-test-project id-b (cons 'reply root-b))))
      (unwind-protect
          (progn
            (should-not (eq edit-a edit-b))
            (with-current-buffer edit-a (insert "for thread a"))
            (with-current-buffer edit-b (insert "for thread b"))
            ;; Commit B first, then A: both land on their own threads.
            (with-current-buffer edit-b (claude-emacs-annotate-edit-commit))
            (with-current-buffer edit-a (claude-emacs-annotate-edit-commit))
            (let ((store (claude-emacs-annotate-store-get cea-test-project)))
              (should (equal "for thread a"
                             (claude-emacs-annotate-comment-text
                              (cadr (claude-emacs-annotate-thread-comments
                                     (claude-emacs-annotate-store-thread
                                      store id-a))))))
              (should (equal "for thread b"
                             (claude-emacs-annotate-comment-text
                              (cadr (claude-emacs-annotate-thread-comments
                                     (claude-emacs-annotate-store-thread
                                      store id-b))))))))
        (when (buffer-live-p edit-a) (kill-buffer edit-a))
        (when (buffer-live-p edit-b) (kill-buffer edit-b))))))

;;;; Compose-buffer creation

(ert-deftest cea-thread-compose-create-commits-new-thread ()
  (cea-test-with-env
    (cea-test-project-file "n.el" "line one\nline two\n")
    (let* ((claude-emacs-annotate-default-author "Tester")
           (anchor (with-temp-buffer
                     (insert "line one\nline two\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "n.el" anchor "my-notes" 1)))
      (unwind-protect
          (with-current-buffer edit
            (insert "multi line\nannotation body")
            (claude-emacs-annotate-edit-commit))
        (when (buffer-live-p edit) (kill-buffer edit)))
      (let ((threads (claude-emacs-annotate-api-query cea-test-project)))
        (should (= 1 (length threads)))
        (let ((thread (car threads)))
          (should (equal "n.el" (claude-emacs-annotate-thread-file thread)))
          (should (equal '("my-notes")
                         (claude-emacs-annotate-thread-tags thread)))
          (should (equal "Tester"
                         (claude-emacs-annotate-thread-root-author thread)))
          (should (equal "multi line\nannotation body"
                         (claude-emacs-annotate-comment-text
                          (claude-emacs-annotate-thread-root-comment
                           thread))))
          (should (= 1 (plist-get (claude-emacs-annotate-thread-anchor
                                   thread)
                                  :start-line))))))))

(ert-deftest cea-thread-compose-distinct-buffers-for-same-basename ()
  "Compose drafts for same-named files must not share a buffer.
A pending draft for one file must never be silently retargeted at
another file sharing its basename and start line."
  (cea-test-with-env
    (let ((anchor '(:kind region :start-line 1 :end-line 1 :state fresh))
          buffer-a buffer-b)
      (unwind-protect
          (progn
            (setq buffer-a (claude-emacs-annotate--thread-compose-create
                            cea-test-project "one/same.el" anchor
                            "changes" 1))
            (with-current-buffer buffer-a (insert "draft for one"))
            (setq buffer-b (claude-emacs-annotate--thread-compose-create
                            cea-test-project "two/same.el" anchor
                            "changes" 1))
            (should-not (eq buffer-a buffer-b))
            (with-current-buffer buffer-a
              (should (equal "draft for one" (buffer-string)))
              (should (equal "one/same.el"
                             (plist-get
                              (cdr claude-emacs-annotate--thread-action)
                              :file))))
            ;; Re-invoking at the second spot reuses its own buffer.
            (should (eq buffer-b
                        (claude-emacs-annotate--thread-compose-create
                         cea-test-project "two/same.el" anchor
                         "changes" 1))))
        (when buffer-a (kill-buffer buffer-a))
        (when buffer-b (kill-buffer buffer-b))))))

(ert-deftest cea-thread-compose-create-preserves-existing-draft ()
  "Re-invoking create at the same spot must not clobber a typed draft."
  (cea-test-with-env
    (cea-test-project-file "d.el" "line one\nline two\n")
    (let* ((anchor-1 (with-temp-buffer
                       (insert "line one\nline two\n")
                       (claude-emacs-annotate-anchor-capture 1 1)))
           (anchor-2 (with-temp-buffer
                       (insert "line one\nline two\n")
                       (claude-emacs-annotate-anchor-capture 1 2)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "d.el" anchor-1 nil 1)))
      (unwind-protect
          (progn
            (with-current-buffer edit
              (insert "half-written draft"))
            ;; Same file and start line → same compose buffer.
            (let ((again (claude-emacs-annotate--thread-compose-create
                          cea-test-project "d.el" anchor-2 nil 1)))
              (should (eq edit again)))
            (with-current-buffer edit
              (should (equal "half-written draft" (buffer-string)))
              ;; The action was refreshed to the newest anchor.
              (claude-emacs-annotate-edit-commit)))
        (when (buffer-live-p edit) (kill-buffer edit)))
      (let ((thread (car (claude-emacs-annotate-api-query cea-test-project))))
        (should (equal "half-written draft"
                       (claude-emacs-annotate-comment-text
                        (claude-emacs-annotate-thread-root-comment thread))))
        (should (= 2 (plist-get (claude-emacs-annotate-thread-anchor thread)
                                :end-line)))))))

(ert-deftest cea-thread-edit-set-tag-attaches-to-committed-thread ()
  (cea-test-with-env
    (cea-test-project-file "tg.el" "line one\n")
    (let* ((anchor (with-temp-buffer
                     (insert "line one\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "tg.el" anchor nil 1)))
      (unwind-protect
          (with-current-buffer edit
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "review-1")))
              (claude-emacs-annotate-edit-set-tag))
            ;; The header line advertises the tag about to be attached.
            (should (string-match-p
                     "review-1" (claude-emacs-annotate--thread-edit-header)))
            (insert "tagged body")
            (claude-emacs-annotate-edit-commit))
        (when (buffer-live-p edit) (kill-buffer edit)))
      (let ((thread (car (claude-emacs-annotate-api-query cea-test-project))))
        (should (equal '("review-1")
                       (claude-emacs-annotate-thread-tags thread)))))))

(ert-deftest cea-thread-edit-set-tag-completes-over-project-tags ()
  "The tag prompt offers the project's existing tags as candidates.
Free input still names a brand-new tag: the completion never
requires a match."
  (cea-test-with-env
    (cea-test-project-file "ta.el" "line one\n")
    (cea-test-api-create "ta.el" 1 1 :tag "existing-set")
    (let* ((anchor (with-temp-buffer
                     (insert "line one\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "ta.el" anchor nil 1))
           (candidates nil)
           (matched nil))
      (unwind-protect
          (with-current-buffer edit
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection _predicate require-match
                                        &rest _)
                         (setq candidates collection)
                         (setq matched require-match)
                         "brand-new")))
              (claude-emacs-annotate-edit-set-tag))
            (should (member "existing-set" candidates))
            (should-not matched)
            (should (equal "brand-new"
                           (plist-get
                            (cdr claude-emacs-annotate--thread-action)
                            :tag))))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest cea-thread-edit-set-tag-empty-input-clears ()
  (cea-test-with-env
    (cea-test-project-file "tc.el" "line one\n")
    (let* ((anchor (with-temp-buffer
                     (insert "line one\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "tc.el" anchor "pre-set" 1)))
      (unwind-protect
          (with-current-buffer edit
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "")))
              (claude-emacs-annotate-edit-set-tag))
            (insert "untagged body")
            (claude-emacs-annotate-edit-commit))
        (when (buffer-live-p edit) (kill-buffer edit)))
      (let ((thread (car (claude-emacs-annotate-api-query cea-test-project))))
        (should (null (claude-emacs-annotate-thread-tags thread)))))))

(ert-deftest cea-thread-edit-set-tag-rejects-invalid ()
  (cea-test-with-env
    (cea-test-project-file "ti.el" "line one\n")
    (let* ((anchor (with-temp-buffer
                     (insert "line one\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "ti.el" anchor "good" 1)))
      (unwind-protect
          (with-current-buffer edit
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "bad tag!")))
              (should-error (claude-emacs-annotate-edit-set-tag)
                            :type 'user-error))
            ;; The draft keeps its previous tag.
            (should (equal "good"
                           (plist-get
                            (cdr claude-emacs-annotate--thread-action)
                            :tag))))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest cea-thread-edit-set-tag-refuses-outside-create ()
  (cea-test-with-env
    (let ((edit (claude-emacs-annotate--thread-edit-buffer
                 cea-test-project "th-x" (cons 'reply "c-x"))))
      (unwind-protect
          (with-current-buffer edit
            (should-error (claude-emacs-annotate-edit-set-tag)
                          :type 'user-error))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest cea-thread-compose-create-reuse-keeps-draft-tag ()
  "Re-invoking create at the same spot keeps the tag like the text."
  (cea-test-with-env
    (let ((anchor '(:kind region :start-line 1 :end-line 1 :state fresh))
          edit)
      (unwind-protect
          (progn
            (setq edit (claude-emacs-annotate--thread-compose-create
                        cea-test-project "k.el" anchor nil 1))
            (with-current-buffer edit
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "kept-tag")))
                (claude-emacs-annotate-edit-set-tag)))
            (should (eq edit (claude-emacs-annotate--thread-compose-create
                              cea-test-project "k.el" anchor nil 1)))
            (with-current-buffer edit
              (should (equal "kept-tag"
                             (plist-get
                              (cdr claude-emacs-annotate--thread-action)
                              :tag))))
            ;; An explicit tag still wins over the kept one.
            (claude-emacs-annotate--thread-compose-create
             cea-test-project "k.el" anchor "explicit" 1)
            (with-current-buffer edit
              (should (equal "explicit"
                             (plist-get
                              (cdr claude-emacs-annotate--thread-action)
                              :tag)))))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest cea-thread-compose-create-empty-commit-refuses ()
  (cea-test-with-env
    (cea-test-project-file "m.el" "only line\n")
    (let* ((anchor (with-temp-buffer
                     (insert "only line\n")
                     (claude-emacs-annotate-anchor-capture 1 1)))
           (edit (claude-emacs-annotate--thread-compose-create
                  cea-test-project "m.el" anchor nil 1)))
      (unwind-protect
          (with-current-buffer edit
            (should-error (claude-emacs-annotate-edit-commit)
                          :type 'user-error)
            (should (buffer-live-p edit)))
        (when (buffer-live-p edit) (kill-buffer edit)))
      (should (= 0 (length (claude-emacs-annotate-api-query
                            cea-test-project)))))))

;;;; Comment deletion

(ert-deftest cea-thread-delete-comment-at-point-leaf-only ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "g.el" "root"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (reply (claude-emacs-annotate-api-reply
                   cea-test-project id root-id "a reply"
                   :author "Tester")))
      (let ((buffer (cea-thread-test--open thread)))
        (unwind-protect
            (with-current-buffer buffer
              (cea-thread-test--goto-comment
               (claude-emacs-annotate-comment-id reply))
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (claude-emacs-annotate-thread-delete-comment))
              (let* ((store (claude-emacs-annotate-store-get
                             cea-test-project))
                     (stored (claude-emacs-annotate-store-thread store id)))
                (should (= 1 (length (claude-emacs-annotate-thread-comments
                                      stored))))))
          (kill-buffer buffer))))))

;;;; Events keep thread buffers honest

(ert-deftest cea-thread-buffer-rerenders-on-update-event ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "h.el" "before edit"))
           (id (claude-emacs-annotate-thread-id thread))
           (buffer (cea-thread-test--open thread)))
      (unwind-protect
          (progn
            (claude-emacs-annotate-api-edit-root-text
             cea-test-project id "after edit")
            (with-current-buffer buffer
              (should (string-match-p "after edit" (buffer-string)))
              (should-not (string-match-p "before edit" (buffer-string)))))
        (kill-buffer buffer)))))

(ert-deftest cea-thread-buffer-shows-deleted-placeholder ()
  (cea-test-with-env
    (let* ((thread (cea-thread-test--make "i.el" "short lived"))
           (id (claude-emacs-annotate-thread-id thread))
           (buffer (cea-thread-test--open thread)))
      (unwind-protect
          (progn
            (claude-emacs-annotate-api-delete cea-test-project id)
            (with-current-buffer buffer
              (should (string-match-p "deleted" (buffer-string)))))
        (kill-buffer buffer)))))

(provide 'claude-emacs-annotate-thread-test)
;;; claude-emacs-annotate-thread-test.el ends here
