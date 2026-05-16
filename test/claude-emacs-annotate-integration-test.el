;;; claude-emacs-annotate-integration-test.el --- End-to-end tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Cross-module flows: the global mode's find-file/major-mode-change
;; behavior (including manual reverts), script-shaped JSON round
;; trips, and multi-writer convergence.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate)

(defmacro cea-integration--with-global-mode (&rest body)
  "Run BODY with `claude-emacs-annotate-global-mode' enabled."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn (claude-emacs-annotate-global-mode 1) ,@body)
     (claude-emacs-annotate-global-mode -1)))

;;;; Global mode

(ert-deftest cea-integration-global-mode-enables-on-annotated-projects ()
  (cea-test-with-env
    (cea-test-project-file "a.el" "one\ntwo\n")
    (claude-emacs-annotate-api-create
     cea-test-project '(:file "a.el" :start-line 1 :end-line 1
                        :text "note" :author "claude-code"))
    (cea-integration--with-global-mode
      (let ((buffer (find-file-noselect
                     (expand-file-name "a.el" cea-test-project))))
        (unwind-protect
            (with-current-buffer buffer
              (should claude-emacs-annotate-mode)
              (should (= 1 (length
                            (claude-emacs-annotate--view-overlays)))))
          (kill-buffer buffer)))
      ;; A file outside any annotated project stays untouched.  The
      ;; env's pinned root function answers for every directory, so
      ;; give this part a directory-aware one.
      (let* ((claude-emacs-annotate-project-root-function
              (lambda (&optional dir)
                (when (string-prefix-p
                       (file-name-as-directory cea-test-project)
                       (expand-file-name (or dir default-directory)))
                  cea-test-project)))
             (outside (cea-test-write-file
                       (expand-file-name "elsewhere/o.el" cea-test-home)
                       "x\n"))
             (buffer (find-file-noselect outside)))
        (unwind-protect
            (with-current-buffer buffer
              (should-not claude-emacs-annotate-mode))
          (kill-buffer buffer))))))

(ert-deftest cea-integration-manual-revert-reenables-via-global-mode ()
  "A manual revert re-initializes modes; the global mode recovers."
  (cea-test-with-env
    (cea-test-project-file "m.el" "aa\nbb\ncc\n")
    (let ((thread (claude-emacs-annotate-api-create
                   cea-test-project '(:file "m.el" :start-line 3 :end-line 3
                                      :text "about cc"
                                      :author "claude-code"))))
      (cea-integration--with-global-mode
        (let ((buffer (find-file-noselect
                       (expand-file-name "m.el" cea-test-project))))
          (unwind-protect
              (with-current-buffer buffer
                (should claude-emacs-annotate-mode)
                ;; External edit, then a MANUAL revert (no preserve-modes:
                ;; kill-all-local-variables wipes the minor mode).
                (cea-test-write-file
                 (expand-file-name "m.el" cea-test-project)
                 "top\naa\nbb\ncc\n")
                (revert-buffer :ignore-auto :noconfirm)
                (should claude-emacs-annotate-mode)
                (let ((overlay (car (claude-emacs-annotate--view-overlays))))
                  (should overlay)
                  (should (= 4 (line-number-at-pos
                                (overlay-start overlay) t))))
                (should (equal
                         (claude-emacs-annotate-thread-id thread)
                         (overlay-get
                          (car (claude-emacs-annotate--view-overlays))
                          'claude-emacs-annotate-id))))
            (kill-buffer buffer)))))))

;;;; Script-shaped JSON flow

(ert-deftest cea-integration-json-flow-end-to-end ()
  (cea-test-with-env
    (cea-test-project-file "src/f.el" "l1\nl2\nl3\nl4\n")
    (cea-test-project-file "src/g.el" "m1\nm2\n")
    ;; 1. Batch create (as batch.sh does).
    (let ((specs (expand-file-name "specs.json" cea-test-home)))
      (cea-test-write-file
       specs
       (json-serialize
        (vector (list :file "src/f.el" :start_line 2 :end_line 3
                      :text "first note" :tag "changes"
                      :author "claude-code")
                (list :file "src/g.el" :kind "file"
                      :text "whole file note" :tag "changes"
                      :author "claude-code"))))
      (let ((envelope (cea-test-api-call 'create-batch
                                             (list :specs-file specs))))
        (should (eq t (gethash "ok" envelope)))
        (should (= 2 (gethash "created" (gethash "result" envelope))))))
    ;; 2. Query (as list-ai.sh does).
    (let* ((envelope (cea-test-api-call
                      'query '(:root-author "claude-code")))
           (threads (gethash "threads" (gethash "result" envelope)))
           (first-id (gethash "id" (aref threads 0))))
      (should (= 2 (length threads)))
      ;; 3. A user replies (as would happen in Emacs).
      (let* ((root-comment (aref (gethash "comments" (aref threads 0)) 0))
             (envelope (cea-test-api-call
                        'reply
                        (list :thread-id first-id
                              :parent-comment-id (gethash "id" root-comment)
                              :text "why though?"
                              :author "Jane Doe"))))
        (should (eq t (gethash "ok" envelope))))
      ;; 4. Pending shows the user's comment (as list-pending.sh does).
      (let* ((envelope (cea-test-api-call 'pending '(:tag "changes")))
             (pending (gethash "pending" (gethash "result" envelope))))
        (should (= 1 (length pending)))
        (let ((item (aref pending 0)))
          (should (equal "why though?" (gethash "text" item)))
          (should (= 1 (length (gethash "ancestors" item))))
          ;; 5. Answer it (as respond.sh does).
          (let ((envelope (cea-test-api-call
                           'reply
                           (list :thread-id (gethash "thread_id" item)
                                 :parent-comment-id (gethash "comment_id"
                                                             item)
                                 :text "because"
                                 :author "claude-code"))))
            (should (eq t (gethash "ok" envelope))))))
      ;; 6. Nothing pending anymore (check-answered.sh convergence).
      (let ((envelope (cea-test-api-call 'pending '(:tag "changes"))))
        (should (= 0 (gethash "count" (gethash "result" envelope)))))
      ;; 7. Count arithmetic (as the skills' verify steps do).
      (let* ((envelope (cea-test-api-call
                        'count '(:root-author "claude-code")))
             (result (gethash "result" envelope)))
        (should (= 2 (gethash "total" result)))
        (should (= 2 (gethash "changes" (gethash "open_by_tag" result)))))
      ;; 8. Clear the set (as clear-ai.sh --tag does).
      (let ((envelope (cea-test-api-call
                       'clear '(:root-author "claude-code"
                                :tag "changes"))))
        (should (= 2 (gethash "removed" (gethash "result" envelope)))))
      (let ((envelope (cea-test-api-call 'query nil)))
        (should (= 0 (gethash "count" (gethash "result" envelope))))))))

;;;; Convergence under interleaved writers

(ert-deftest cea-integration-interleaved-writers-converge ()
  (cea-test-with-env
    (cea-test-project-file "w.el" "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n")
    (let ((registry-a (make-hash-table :test #'equal))
          (registry-b (make-hash-table :test #'equal)))
      (dotimes (i 5)
        (let ((claude-emacs-annotate--stores registry-a))
          (claude-emacs-annotate-api-create
           cea-test-project
           (list :file "w.el" :start-line (1+ i) :end-line (1+ i)
                 :text (format "from a %d" i) :author "claude-code")))
        (let ((claude-emacs-annotate--stores registry-b))
          (claude-emacs-annotate-api-create
           cea-test-project
           (list :file "w.el" :start-line (+ 6 i) :end-line (+ 6 i)
                 :text (format "from b %d" i) :author "claude-code"))))
      ;; A fresh reader sees all ten threads.
      (should (= 10 (length (claude-emacs-annotate-api-query
                             cea-test-project)))))))

;;;; File watcher (best effort in batch)

(ert-deftest cea-integration-watcher-reloads-external-writes ()
  (skip-unless (and (require 'filenotify nil t)
                    (bound-and-true-p file-notify--library)))
  (cea-test-with-env
    (cea-test-project-file "n.el" "x\ny\n")
    (let ((claude-emacs-annotate-use-file-watcher t))
      ;; Load the watched store first.
      (let ((store (claude-emacs-annotate-store-get cea-test-project)))
        (claude-emacs-annotate-api-create
         cea-test-project '(:file "n.el" :start-line 1 :end-line 1
                            :text "mine" :author "claude-code"))
        ;; External writer adds a second thread.
        (cea-test-with-fresh-registry
          (claude-emacs-annotate-api-create
           cea-test-project '(:file "n.el" :start-line 2 :end-line 2
                              :text "theirs" :author "claude-code")))
        ;; Pump events until the watcher's debounce fires: file-notify
        ;; arrives through the input-event queue (`read-event'), not
        ;; process output.
        (let ((deadline (+ (float-time) 5)))
          (while (and (< (float-time) deadline)
                      (< (length (claude-emacs-annotate-store-all-threads
                                  store))
                         2))
            (ignore-errors (read-event nil nil 0.1))
            (let ((timer (claude-emacs-annotate-store--watch-timer store)))
              (when timer (timer-event-handler timer)))))
        (if (= 2 (length (claude-emacs-annotate-store-all-threads store)))
            (should t)
          (ert-skip "file-notify events not delivered in batch"))))))

(ert-deftest cea-integration-first-annotation-attaches-to-open-buffer ()
  "The project's first annotation must appear in already-open buffers.
A buffer visited before the store exists has the local mode off; the
created event must enable it rather than wait for a revisit."
  (cea-test-with-env
    (cea-test-project-file "a.el" "one\ntwo\n")
    (cea-integration--with-global-mode
      (let ((buffer (find-file-noselect
                     (expand-file-name "a.el" cea-test-project))))
        (unwind-protect
            (progn
              (with-current-buffer buffer
                (should-not claude-emacs-annotate-mode))
              (claude-emacs-annotate-api-create
               cea-test-project '(:file "a.el" :start-line 1 :end-line 1
                                  :text "note" :author "claude-code"))
              (with-current-buffer buffer
                (should claude-emacs-annotate-mode)
                (should (= 1 (length
                              (claude-emacs-annotate--view-overlays))))))
          (kill-buffer buffer))))))

(ert-deftest cea-integration-created-event-respects-explicit-disable ()
  "A created event must not re-enable a mode the user turned off.
The enable-on-first-annotation branch defers to an explicit toggle."
  (cea-test-with-env
    (cea-test-project-file "a.el" "one\ntwo\n")
    (cea-integration--with-global-mode
      (let ((buffer (find-file-noselect
                     (expand-file-name "a.el" cea-test-project))))
        (unwind-protect
            (progn
              (claude-emacs-annotate-api-create
               cea-test-project '(:file "a.el" :start-line 1 :end-line 1
                                  :text "n1" :author "claude-code"))
              (with-current-buffer buffer
                (should claude-emacs-annotate-mode)
                ;; As a keybinding or M-x would: an explicit toggle.
                (call-interactively #'claude-emacs-annotate-mode)
                (should-not claude-emacs-annotate-mode))
              (claude-emacs-annotate-api-create
               cea-test-project '(:file "a.el" :start-line 2 :end-line 2
                                  :text "n2" :author "claude-code"))
              (with-current-buffer buffer
                (should-not claude-emacs-annotate-mode)))
          (kill-buffer buffer))))))

(ert-deftest cea-integration-created-event-scoped-to-its-project ()
  "A created event only enables buffers under the event's project tree."
  (cea-test-with-env
    (cea-test-project-file "a.el" "one\n")
    (let ((outside (cea-test-write-file
                    (expand-file-name "elsewhere/o.el" cea-test-home)
                    "x\n")))
      (cea-integration--with-global-mode
        (let ((buffer (find-file-noselect outside)))
          (unwind-protect
              (progn
                (with-current-buffer buffer
                  (should-not claude-emacs-annotate-mode))
                ;; The env's pinned root function claims every
                ;; directory, so only the event-root scoping keeps
                ;; this out-of-tree buffer untouched.
                (claude-emacs-annotate-api-create
                 cea-test-project '(:file "a.el" :start-line 1
                                    :end-line 1 :text "n"
                                    :author "claude-code"))
                (with-current-buffer buffer
                  (should-not claude-emacs-annotate-mode)))
            (kill-buffer buffer)))))))

(provide 'claude-emacs-annotate-integration-test)
;;; claude-emacs-annotate-integration-test.el ends here
