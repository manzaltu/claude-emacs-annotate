;;; claude-emacs-annotate-api-test.el --- API + JSON transport tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; The programmatic contract the skill scripts build against: explicit
;; project roots, no buffer dependence, typed errors, expect-file
;; preconditions, and the JSON envelope written by
;; `claude-emacs-annotate-api-call'.  The JSON shape assertions here
;; are the frozen wire contract -- change them deliberately or not at
;; all.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-api)

(defun cea-api-test--file (name &optional lines)
  "Create project file NAME with LINES (default 8 numbered lines)."
  (cea-test-file-lines
   name
   (or lines
       (cl-loop for i from 1 to 8 collect (format "%s line %d" name i)))))

(defun cea-api-test--create (file start end &rest keys)
  "Create an annotation on FILE lines START..END; return the thread."
  (apply #'cea-test-api-create file start end
         :text (or (plist-get keys :text) "annotation body") keys))

;;;; create

(ert-deftest cea-api-create-anchors-from-disk-without-buffers ()
  (cea-test-with-env
    (let ((path (cea-api-test--file "src/a.el")))
      (let ((thread (cea-api-test--create path 2 3 :tag "review-x")))
        (should (equal "src/a.el"
                       (claude-emacs-annotate-thread-file thread)))
        (should (equal '("review-x")
                       (claude-emacs-annotate-thread-tags thread)))
        (should (equal "src/a.el line 2\nsrc/a.el line 3"
                       (plist-get (claude-emacs-annotate-thread-anchor thread)
                                  :text)))
        (should-not (find-buffer-visiting path))
        ;; Persisted.
        (let ((store (claude-emacs-annotate-store-get cea-test-project)))
          (should (claude-emacs-annotate-store-thread
                   store (claude-emacs-annotate-thread-id thread))))))))

(ert-deftest cea-api-create-accepts-relative-file ()
  (cea-test-with-env
    (cea-api-test--file "rel.el")
    (let ((thread (cea-api-test--create "rel.el" 1 1)))
      (should (equal "rel.el" (claude-emacs-annotate-thread-file thread))))))

(ert-deftest cea-api-create-returns-a-copy ()
  (cea-test-with-env
    (cea-api-test--file "c.el")
    (let* ((thread (cea-api-test--create "c.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread)))
      (plist-put thread :status "closed")
      (let ((store (claude-emacs-annotate-store-get cea-test-project)))
        (should (equal "open"
                       (claude-emacs-annotate-thread-status
                        (claude-emacs-annotate-store-thread store id))))))))

(ert-deftest cea-api-create-whole-file-kind ()
  (cea-test-with-env
    (cea-api-test--file "whole.el")
    (let ((thread (claude-emacs-annotate-api-create
                   cea-test-project
                   (list :file "whole.el" :kind 'file
                         :text "covers everything" :author "claude-code"))))
      (should (eq 'file (plist-get
                         (claude-emacs-annotate-thread-anchor thread)
                         :kind))))))

(ert-deftest cea-api-create-validation-errors ()
  (cea-test-with-env
    (cea-api-test--file "v.el")
    ;; Missing file on disk.
    (should-error (cea-api-test--create "missing.el" 1 1)
                  :type 'claude-emacs-annotate-invalid)
    ;; Outside the project.
    (let ((outside (cea-test-write-file
                    (expand-file-name "elsewhere/out.el" cea-test-home)
                    "x\n")))
      (should-error (cea-api-test--create outside 1 1)
                    :type 'claude-emacs-annotate-invalid))
    ;; Line range exceeding the file.
    (let ((err (should-error (cea-api-test--create "v.el" 7 99)
                             :type 'claude-emacs-annotate-invalid)))
      (should (string-match-p "line range 7\\.\\.99 exceeds" (cadr err))))
    ;; Missing text / author.
    (should-error (claude-emacs-annotate-api-create
                   cea-test-project
                   '(:file "v.el" :start-line 1 :end-line 1 :text "x"))
                  :type 'claude-emacs-annotate-invalid)
    (should-error (claude-emacs-annotate-api-create
                   cea-test-project
                   '(:file "v.el" :start-line 1 :end-line 1
                     :author "claude-code"))
                  :type 'claude-emacs-annotate-invalid)))

;;;; create-batch

(ert-deftest cea-api-create-batch-collects-failures ()
  (cea-test-with-env
    (cea-api-test--file "b1.el")
    (cea-api-test--file "b2.el")
    (let* ((events nil)
           (claude-emacs-annotate-changed-hook
            (list (lambda (event) (push event events))))
           (result (claude-emacs-annotate-api-create-batch
                    cea-test-project
                    (list (list :file "b1.el" :start-line 1 :end-line 2
                                :text "first" :author "claude-code"
                                :tags '("changes"))
                          (list :file "b2.el" :kind 'file
                                :text "whole" :author "claude-code"
                                :tags '("changes"))
                          (list :file "b1.el" :start-line 50 :end-line 60
                                :text "broken" :author "claude-code"
                                :tags '("changes"))))))
      (should (= 2 (plist-get result :created)))
      (should (= 1 (plist-get result :failed)))
      (let ((threads (plist-get result :threads)))
        (should (= 2 (length threads)))
        (should (equal "b1.el" (plist-get (car threads) :file)))
        (should (= 1 (plist-get (car threads) :start-line)))
        ;; Whole-file spec reports no lines.
        (should (null (plist-get (cadr threads) :start-line))))
      (let ((failure (car (plist-get result :failures))))
        (should (equal "b1.el" (plist-get failure :file)))
        (should (string-match-p "line range 50\\.\\.60 exceeds"
                                (plist-get failure :error))))
      ;; One consolidated created event for the whole batch.
      (let ((created (seq-filter (lambda (event)
                                   (eq 'created (plist-get event :type)))
                                 events)))
        (should (= 1 (length created)))
        (should (= 2 (length (plist-get (car created) :thread-ids))))))))

;;;; reply

(ert-deftest cea-api-reply-happy-path ()
  (cea-test-with-env
    (cea-api-test--file "r.el")
    (let* ((thread (cea-api-test--create "r.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (comment (claude-emacs-annotate-api-reply
                     cea-test-project id root-id "user reply"
                     :author "Jane Doe")))
      (should (equal root-id
                     (claude-emacs-annotate-comment-parent-id comment)))
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (stored (claude-emacs-annotate-store-thread store id)))
        (should (= 2 (length (claude-emacs-annotate-thread-comments
                              stored))))))))

(ert-deftest cea-api-reply-guards ()
  (cea-test-with-env
    (cea-api-test--file "g.el")
    (let* ((thread (cea-api-test--create "g.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread))))
      (should-error (claude-emacs-annotate-api-reply
                     cea-test-project "th-bogus" root-id "x" :author "u")
                    :type 'claude-emacs-annotate-not-found)
      (should-error (claude-emacs-annotate-api-reply
                     cea-test-project id "c-bogus" "x" :author "u")
                    :type 'claude-emacs-annotate-not-found)
      ;; First reply is fine; a second reply to the same parent is not.
      (claude-emacs-annotate-api-reply cea-test-project id root-id "one"
                                       :author "u")
      (should-error (claude-emacs-annotate-api-reply
                     cea-test-project id root-id "two" :author "u")
                    :type 'claude-emacs-annotate-conflict)
      ;; Closed thread refuses replies unless relaxed.
      (claude-emacs-annotate-api-set-status cea-test-project id "closed")
      (let ((leaf-id
             (claude-emacs-annotate-comment-id
              (car (last (claude-emacs-annotate-thread-comments
                          (claude-emacs-annotate-store-thread
                           (claude-emacs-annotate-store-get cea-test-project)
                           id)))))))
        (should-error (claude-emacs-annotate-api-reply
                       cea-test-project id leaf-id "x" :author "u")
                      :type 'claude-emacs-annotate-conflict)
        (should (claude-emacs-annotate-api-reply
                 cea-test-project id leaf-id "forced" :author "u"
                 :require-open nil))))))

;;;; edits

(ert-deftest cea-api-edit-root-text-preserves-identity ()
  (cea-test-with-env
    (cea-api-test--file "e.el")
    (let* ((thread (cea-api-test--create "e.el" 1 1 :text "original"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread))))
      (claude-emacs-annotate-api-reply cea-test-project id root-id "reply"
                                       :author "u")
      (let* ((updated (claude-emacs-annotate-api-edit-root-text
                       cea-test-project id "rewritten"))
             (root (claude-emacs-annotate-thread-root-comment updated)))
        (should (equal id (claude-emacs-annotate-thread-id updated)))
        (should (equal root-id (claude-emacs-annotate-comment-id root)))
        (should (equal "rewritten" (claude-emacs-annotate-comment-text root)))
        (should (stringp (plist-get root :edited)))
        (should (= 2 (length (claude-emacs-annotate-thread-comments
                              updated))))))))

(ert-deftest cea-api-edit-comment-not-found ()
  (cea-test-with-env
    (cea-api-test--file "e2.el")
    (let ((thread (cea-api-test--create "e2.el" 1 1)))
      (should-error (claude-emacs-annotate-api-edit-comment
                     cea-test-project
                     (claude-emacs-annotate-thread-id thread)
                     "c-bogus" "x")
                    :type 'claude-emacs-annotate-not-found))))

;;;; status / priority / delete

(ert-deftest cea-api-set-status-reports-previous ()
  (cea-test-with-env
    (cea-api-test--file "s.el")
    (let* ((thread (cea-api-test--create "s.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread))
           (result (claude-emacs-annotate-api-set-status
                    cea-test-project id "closed")))
      (should (equal "open" (plist-get result :previous-status)))
      ;; Idempotent close.
      (should (equal "closed"
                     (plist-get (claude-emacs-annotate-api-set-status
                                 cea-test-project id "closed")
                                :previous-status)))
      (should-error (claude-emacs-annotate-api-set-status
                     cea-test-project id "bogus")
                    :type 'claude-emacs-annotate-invalid))))

(ert-deftest cea-api-delete-thread ()
  (cea-test-with-env
    (cea-api-test--file "d.el")
    (let* ((thread (cea-api-test--create "d.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-delete cea-test-project id)
      (should-error (claude-emacs-annotate-api-delete cea-test-project id)
                    :type 'claude-emacs-annotate-not-found)
      ;; Tombstoned on disk: a fresh registry does not see it.
      (cea-test-with-fresh-registry
        (should-not (claude-emacs-annotate-store-thread
                     (claude-emacs-annotate-store-get cea-test-project)
                     id))))))

(ert-deftest cea-api-delete-comment-rules ()
  (cea-test-with-env
    (cea-api-test--file "dc.el")
    (let* ((thread (cea-api-test--create "dc.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (reply (claude-emacs-annotate-api-reply
                   cea-test-project id root-id "r1" :author "u"))
           (reply-2 (claude-emacs-annotate-api-reply
                     cea-test-project id
                     (claude-emacs-annotate-comment-id reply)
                     "r2" :author "u")))
      ;; Root refuses; non-leaf refuses; leaf deletes.
      (should-error (claude-emacs-annotate-api-delete-comment
                     cea-test-project id root-id)
                    :type 'claude-emacs-annotate-invalid)
      (should-error (claude-emacs-annotate-api-delete-comment
                     cea-test-project id
                     (claude-emacs-annotate-comment-id reply))
                    :type 'claude-emacs-annotate-conflict)
      (claude-emacs-annotate-api-delete-comment
       cea-test-project id (claude-emacs-annotate-comment-id reply-2))
      (should (= 2 (length (claude-emacs-annotate-thread-comments
                            (claude-emacs-annotate-store-thread
                             (claude-emacs-annotate-store-get
                              cea-test-project)
                             id))))))))

;;;; expect-file

(ert-deftest cea-api-expect-file-precondition ()
  (cea-test-with-env
    (cea-api-test--file "x.el")
    (let* ((thread (cea-api-test--create "x.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread)))
      (let ((err (should-error (claude-emacs-annotate-api-set-status
                                cea-test-project id "closed"
                                :expect-file "other.el")
                               :type 'claude-emacs-annotate-expectation)))
        (should (string-match-p "anchored to x\\.el, not other\\.el"
                                (cadr err))))
      ;; Absolute spelling of the right file passes.
      (should (claude-emacs-annotate-api-set-status
               cea-test-project id "closed"
               :expect-file (expand-file-name "x.el" cea-test-project))))))

;;;; query

(ert-deftest cea-api-query-filters ()
  (cea-test-with-env
    (cea-api-test--file "q1.el")
    (cea-api-test--file "q2.el")
    (let ((a (cea-api-test--create "q1.el" 1 1 :tag "changes"))
          (b (cea-api-test--create "q2.el" 1 1 :tag "review-x"))
          (c (cea-api-test--create "q2.el" 2 2 :tag "review-x"
                                   :author "Jane Doe")))
      (claude-emacs-annotate-api-set-status
       cea-test-project (claude-emacs-annotate-thread-id b) "closed")
      (should (= 3 (length (claude-emacs-annotate-api-query
                            cea-test-project))))
      (should (= 2 (length (claude-emacs-annotate-api-query
                            cea-test-project :root-author "claude-code"))))
      (should (= 1 (length (claude-emacs-annotate-api-query
                            cea-test-project :tag "changes"))))
      (should (= 1 (length (claude-emacs-annotate-api-query
                            cea-test-project :status "closed"))))
      (should (= 2 (length (claude-emacs-annotate-api-query
                            cea-test-project :file "q2.el"))))
      (should (= 1 (length (claude-emacs-annotate-api-query
                            cea-test-project
                            :root-author "claude-code"
                            :file "q2.el"))))
      (should (equal (claude-emacs-annotate-thread-id a)
                     (claude-emacs-annotate-thread-id
                      (car (claude-emacs-annotate-api-query
                            cea-test-project :tag "changes")))))
      (should (equal (claude-emacs-annotate-thread-id c)
                     (claude-emacs-annotate-thread-id
                      (car (claude-emacs-annotate-api-query
                            cea-test-project :root-author "Jane Doe"))))))))

;;;; pending

(ert-deftest cea-api-pending-semantics ()
  (cea-test-with-env
    (cea-api-test--file "p.el")
    (let* ((answered (cea-api-test--create "p.el" 1 1 :tag "changes"))
           (asked (cea-api-test--create "p.el" 2 2 :tag "changes"))
           (user-thread (cea-api-test--create "p.el" 3 3
                                              :author "Jane Doe"))
           (closed (cea-api-test--create "p.el" 4 4 :tag "other")))
      ;; answered: user replied, then claude-code replied back → not pending.
      (let* ((id (claude-emacs-annotate-thread-id answered))
             (root (claude-emacs-annotate-comment-id
                    (claude-emacs-annotate-thread-root-comment answered)))
             (user-comment (claude-emacs-annotate-api-reply
                            cea-test-project id root "why?"
                            :author "Jane Doe")))
        (claude-emacs-annotate-api-reply
         cea-test-project id
         (claude-emacs-annotate-comment-id user-comment)
         "because" :author "claude-code"))
      ;; asked: user replied and waits → pending.
      (let* ((id (claude-emacs-annotate-thread-id asked))
             (root (claude-emacs-annotate-comment-id
                    (claude-emacs-annotate-thread-root-comment asked))))
        (claude-emacs-annotate-api-reply cea-test-project id root
                                         "what about X?" :author "Jane Doe"))
      ;; closed thread with a user leaf → not pending.
      (let* ((id (claude-emacs-annotate-thread-id closed))
             (root (claude-emacs-annotate-comment-id
                    (claude-emacs-annotate-thread-root-comment closed))))
        (claude-emacs-annotate-api-reply cea-test-project id root
                                         "late question" :author "Jane Doe")
        (claude-emacs-annotate-api-set-status cea-test-project id "closed"))
      (let ((pending (claude-emacs-annotate-api-pending cea-test-project)))
        ;; The user's waiting reply + the user-opened thread's root.
        (should (= 2 (length pending)))
        (let ((authors (mapcar (lambda (item) (plist-get item :author))
                               pending)))
          (should (equal '("Jane Doe" "Jane Doe") authors)))
        (let ((user-root-item
               (seq-find (lambda (item)
                           (equal (plist-get item :thread-id)
                                  (claude-emacs-annotate-thread-id
                                   user-thread)))
                         pending)))
          (should user-root-item)
          (should (null (plist-get user-root-item :ancestors)))))
      ;; Tag scoping: only the tagged thread's pending comment remains.
      (let ((pending (claude-emacs-annotate-api-pending cea-test-project
                                                        :tag "changes")))
        (should (= 1 (length pending)))
        (should (equal (claude-emacs-annotate-thread-id asked)
                       (plist-get (car pending) :thread-id)))))))

(ert-deftest cea-api-pending-ancestors-chain ()
  (cea-test-with-env
    (cea-api-test--file "anc.el")
    (let* ((thread (cea-api-test--create "anc.el" 1 1 :text "root text"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread)))
           (mid (claude-emacs-annotate-api-reply
                 cea-test-project id root-id "mid reply"
                 :author "claude-code"))
           (_leaf (claude-emacs-annotate-api-reply
                   cea-test-project id
                   (claude-emacs-annotate-comment-id mid)
                   "user leaf" :author "Jane Doe")))
      (let* ((pending (claude-emacs-annotate-api-pending cea-test-project))
             (item (car pending))
             (ancestors (plist-get item :ancestors)))
        (should (= 1 (length pending)))
        (should (equal "user leaf" (plist-get item :text)))
        (should (= 2 (length ancestors)))
        (should (equal "root text" (plist-get (car ancestors) :text)))
        (should (equal "mid reply" (plist-get (cadr ancestors) :text)))))))

;;;; count

(ert-deftest cea-api-count-buckets ()
  (cea-test-with-env
    (cea-api-test--file "c1.el")
    (cea-api-test--file "c2.el")
    (let ((a (cea-api-test--create "c1.el" 1 1 :tag "changes"))
          (_b (cea-api-test--create "c1.el" 2 2 :tag "changes"))
          (_c (cea-api-test--create "c2.el" 1 1 :tag "review-x"))
          (untagged (cea-api-test--create "c2.el" 2 2))
          (_user (cea-api-test--create "c2.el" 3 3 :author "Jane Doe")))
      (claude-emacs-annotate-api-set-status
       cea-test-project (claude-emacs-annotate-thread-id a) "closed")
      (ignore untagged)
      ;; Make c2.el's agent threads stale for real: the file disappears.
      (delete-file (expand-file-name "c2.el" cea-test-project))
      (let ((count (claude-emacs-annotate-api-count
                    cea-test-project :root-author "claude-code")))
        (should (= 4 (plist-get count :total)))
        (should (= 2 (plist-get count :files)))
        (should (= 1 (gethash "closed" (plist-get count :by-status))))
        (should (= 3 (gethash "open" (plist-get count :by-status))))
        (should (= 0 (gethash "resolved" (plist-get count :by-status))))
        (should (= 1 (gethash "changes" (plist-get count :open-by-tag))))
        (should (= 1 (gethash "review-x" (plist-get count :open-by-tag))))
        (should (= 1 (gethash "" (plist-get count :open-by-tag))))
        (should (= 2 (plist-get count :open-stale)))
        (should (= 2 (gethash "fresh" (plist-get count :anchor-states))))
        (should (= 2 (gethash "stale" (plist-get count :anchor-states))))))))

;;;; clear

(ert-deftest cea-api-clear-scoping ()
  (cea-test-with-env
    (cea-api-test--file "cl.el")
    (let* ((mine-1 (cea-api-test--create "cl.el" 1 1 :tag "changes"))
           (_mine-2 (cea-api-test--create "cl.el" 2 2 :tag "review-x"))
           (user-thread (cea-api-test--create "cl.el" 3 3
                                              :author "Jane Doe")))
      ;; The user thread gets a claude-code REPLY; root author still user.
      (claude-emacs-annotate-api-reply
       cea-test-project
       (claude-emacs-annotate-thread-id user-thread)
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment user-thread))
       "agent answer" :author "claude-code")
      (should-error (claude-emacs-annotate-api-clear cea-test-project)
                    :type 'claude-emacs-annotate-invalid)
      ;; Tag scope removes one set.
      (let ((result (claude-emacs-annotate-api-clear
                     cea-test-project
                     :root-author "claude-code" :tag "changes")))
        (should (= 1 (plist-get result :removed))))
      (should-not (claude-emacs-annotate-store-thread
                   (claude-emacs-annotate-store-get cea-test-project)
                   (claude-emacs-annotate-thread-id mine-1)))
      ;; Author scope removes remaining agent threads, keeps the user's.
      (let ((result (claude-emacs-annotate-api-clear
                     cea-test-project :root-author "claude-code")))
        (should (= 1 (plist-get result :removed))))
      (should (claude-emacs-annotate-store-thread
               (claude-emacs-annotate-store-get cea-test-project)
               (claude-emacs-annotate-thread-id user-thread)))
      ;; :all wipes everything.
      (let ((result (claude-emacs-annotate-api-clear cea-test-project
                                                     :all t)))
        (should (= 1 (plist-get result :removed))))
      (should (= 0 (length (claude-emacs-annotate-api-query
                            cea-test-project)))))))

;;;; Read paths resolve anchors against current disk content

(ert-deftest cea-api-query-follows-relocated-anchor-from-disk ()
  "Reads report where the content IS now, without any buffer attaching."
  (cea-test-with-env
    (cea-api-test--file "mv.el" '("aa" "bb" "cc"))
    (let* ((thread (cea-api-test--create "mv.el" 2 2))
           (id (claude-emacs-annotate-thread-id thread)))
      ;; External edit shifts the content down by two lines.
      (cea-test-project-file "mv.el" "x1\nx2\naa\nbb\ncc\n")
      (let* ((result (car (claude-emacs-annotate-api-query
                           cea-test-project)))
             (anchor (claude-emacs-annotate-thread-anchor result)))
        (should (eq 'fresh (plist-get anchor :state)))
        (should (= 4 (plist-get anchor :start-line))))
      ;; The read was pure: the stored anchor is untouched.
      (let ((stored (claude-emacs-annotate-store-thread
                     (claude-emacs-annotate-store-get cea-test-project)
                     id)))
        (should (= 2 (plist-get (claude-emacs-annotate-thread-anchor stored)
                                :start-line)))
        (should (eq 'fresh (plist-get
                            (claude-emacs-annotate-thread-anchor stored)
                            :state)))))))

(ert-deftest cea-api-query-resolves-stale-anchor-from-disk ()
  (cea-test-with-env
    (cea-api-test--file "or.el" '("k1" "k2" "k3"))
    (cea-api-test--create "or.el" 2 2)
    (cea-test-project-file "or.el" "totally\nrewritten\n")
    (let ((results (claude-emacs-annotate-api-query cea-test-project)))
      ;; Never dropped, flagged stale.
      (should (= 1 (length results)))
      (should (eq 'stale
                  (plist-get (claude-emacs-annotate-thread-anchor
                              (car results))
                             :state))))
    ;; A deleted file also reports stale rather than vanishing.
    (delete-file (expand-file-name "or.el" cea-test-project))
    (let ((results (claude-emacs-annotate-api-query cea-test-project)))
      (should (= 1 (length results)))
      (should (eq 'stale
                  (plist-get (claude-emacs-annotate-thread-anchor
                              (car results))
                             :state))))))

(ert-deftest cea-api-count-uses-resolved-anchor-states ()
  (cea-test-with-env
    (cea-api-test--file "cs.el" '("p1" "p2" "p3"))
    (cea-api-test--create "cs.el" 2 2)
    (cea-test-project-file "cs.el" "gone\n")
    (let ((count (claude-emacs-annotate-api-count cea-test-project)))
      (should (= 1 (plist-get count :open-stale)))
      (should (= 1 (gethash "stale" (plist-get count :anchor-states))))
      (should (= 0 (gethash "fresh" (plist-get count :anchor-states)))))))

(ert-deftest cea-api-pending-reports-current-lines ()
  (cea-test-with-env
    (cea-api-test--file "pl.el" '("q1" "q2" "q3"))
    (let* ((thread (cea-api-test--create "pl.el" 3 3))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-reply
       cea-test-project id
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment thread))
       "waiting" :author "Jane Doe")
      (cea-test-project-file "pl.el" "new0\nq1\nq2\nq3\n")
      (let* ((pending (claude-emacs-annotate-api-pending cea-test-project))
             (anchor (plist-get (car pending) :anchor)))
        (should (= 1 (length pending)))
        (should (= 4 (plist-get anchor :start-line)))
        (should (eq 'fresh (plist-get anchor :state)))))))

(ert-deftest cea-api-edit-root-text-repins-located-stale-thread ()
  "Editing the annotation against current code re-pins the thread.
The rewritten prose is about the code as it stands, so the anchor
recaptures at the located lines and the latch clears."
  (cea-test-with-env
    (cea-api-test--file "rp.el" '("ctx a" "old body" "ctx b"))
    (let* ((thread (cea-api-test--create "rp.el" 2 2 :text "old remark"))
           (id (claude-emacs-annotate-thread-id thread)))
      ;; The subject is rewritten externally: the thread goes stale.
      (cea-test-project-file "rp.el" "ctx a\nnew body\nctx b\n")
      (claude-emacs-annotate-api-edit-root-text
       cea-test-project id "remark about the new body")
      (let ((anchor (claude-emacs-annotate-thread-anchor
                     (claude-emacs-annotate-store-thread
                      (claude-emacs-annotate-store-get cea-test-project)
                      id))))
        (should (eq 'fresh (plist-get anchor :state)))
        (should (= 2 (plist-get anchor :start-line)))
        (should (equal "new body" (plist-get anchor :text)))))))

(ert-deftest cea-api-edit-root-text-keeps-unlocatable-thread-stale ()
  (cea-test-with-env
    (cea-api-test--file "rp2.el" '("ctx a" "old body" "ctx b"))
    (let* ((thread (cea-api-test--create "rp2.el" 2 2 :text "old remark"))
           (id (claude-emacs-annotate-thread-id thread)))
      ;; Nothing of the anchor or its context survives.
      (cea-test-project-file "rp2.el" "entirely\nunrelated\n")
      (claude-emacs-annotate-api-edit-root-text
       cea-test-project id "updated remark")
      (let ((anchor (claude-emacs-annotate-thread-anchor
                     (claude-emacs-annotate-store-thread
                      (claude-emacs-annotate-store-get cea-test-project)
                      id))))
        (should (eq 'stale (plist-get anchor :state)))
        ;; Original content preserved for a later rescue.
        (should (equal "old body" (plist-get anchor :text)))))))

;;;; JSON transport

(ert-deftest cea-api-set-status-same-value-is-noop ()
  "Setting a thread's current status again must not rewrite the store.
close.sh promises re-closing is a no-op; a redundant write would also
advance `:updated' -- the merge key -- letting an unchanged thread
beat a concurrent real edit."
  (cea-test-with-env
    (cea-api-test--file "s.el")
    (let* ((thread (cea-api-test--create "s.el" 1 1))
           (id (claude-emacs-annotate-thread-id thread))
           (path (claude-emacs-annotate-store-path cea-test-project))
           (store (claude-emacs-annotate-store-get cea-test-project)))
      (claude-emacs-annotate-api-set-status cea-test-project id "closed")
      (let ((updated-before (plist-get
                             (claude-emacs-annotate-store-thread store id)
                             :updated))
            (bytes-before (with-temp-buffer
                            (insert-file-contents path)
                            (buffer-string)))
            (events nil))
        (let* ((claude-emacs-annotate-changed-hook
                (list (lambda (event) (push event events))))
               (result (claude-emacs-annotate-api-set-status
                        cea-test-project id "closed")))
          (should (equal "closed" (plist-get result :previous-status)))
          (should-not events))
        (should (equal updated-before
                       (plist-get
                        (claude-emacs-annotate-store-thread store id)
                        :updated)))
        (should (equal bytes-before
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string))))))))

(ert-deftest cea-api-pending-explicit-agent-author-wins ()
  "An explicit :agent-author overrides the display defcustom.
The scripts pass their author literal explicitly, so a customized
`claude-emacs-annotate-agent-author' must not change what the wire
reports as pending."
  (cea-test-with-env
    (cea-api-test--file "p.el")
    (let* ((thread (cea-api-test--create "p.el" 1 1 :tag "changes"))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (car (claude-emacs-annotate-thread-comments thread)))))
      ;; With no replies the claude-code root is the leaf: it counts as
      ;; pending only for a DIFFERENT agent author.
      (let ((claude-emacs-annotate-agent-author "someone-else"))
        (should (= 0 (length (claude-emacs-annotate-api-pending
                              cea-test-project
                              :agent-author "claude-code"))))
        (should (= 1 (length (claude-emacs-annotate-api-pending
                              cea-test-project)))))
      ;; A user reply becomes the leaf: pending for claude-code even
      ;; when the defcustom is customized away.
      (claude-emacs-annotate-api-reply cea-test-project id root-id "ping"
                                       :author "Jane Doe")
      (let ((claude-emacs-annotate-agent-author "someone-else"))
        (should (= 1 (length (claude-emacs-annotate-api-pending
                              cea-test-project
                              :agent-author "claude-code"))))))))

(ert-deftest cea-api-whole-file-anchor-survives-file-deletion ()
  "A whole-file anchor stays fresh when its file disappears.
Region anchors latch stale on a missing file; file-kind anchors span
whatever exists and never go stale."
  (cea-test-with-env
    (cea-api-test--file "gone.el")
    (claude-emacs-annotate-api-create
     cea-test-project
     (list :file "gone.el" :kind 'file :text "whole file note"
           :author "claude-code"))
    (delete-file (expand-file-name "gone.el" cea-test-project))
    (let ((count (claude-emacs-annotate-api-count
                  cea-test-project :root-author "claude-code")))
      (should (= 0 (plist-get count :open-stale)))
      (should (= 1 (gethash "fresh" (plist-get count :anchor-states) 0)))
      (should (= 0 (gethash "stale" (plist-get count :anchor-states) 0))))))

(defun cea-api-test--keys (object)
  "Return OBJECT's (a parsed JSON hash) keys, sorted."
  (sort (hash-table-keys object) #'string<))

(ert-deftest cea-api-call-create-envelope-shape ()
  (cea-test-with-env
    (cea-api-test--file "j.el")
    (let ((envelope (cea-test-api-call
                     'create
                     '(:file "j.el" :start-line 2 :end-line 3
                       :text "body line one\nline two" :tag "changes"
                       :author "claude-code"))))
      (should (eq t (gethash "ok" envelope)))
      (should (equal '("ok" "result") (cea-api-test--keys envelope)))
      (let ((thread (gethash "thread" (gethash "result" envelope))))
        (should (equal '("anchor" "comment_count" "comments" "created"
                         "file" "id" "priority" "root_author" "status"
                         "tags" "updated")
                       (cea-api-test--keys thread)))
        (should (equal "j.el" (gethash "file" thread)))
        (should (equal ["changes"] (gethash "tags" thread)))
        (let ((anchor (gethash "anchor" thread)))
          (should (equal '("end_line" "kind" "line_count" "start_line"
                           "state")
                         (cea-api-test--keys anchor)))
          (should (equal "region" (gethash "kind" anchor)))
          (should (= 2 (gethash "start_line" anchor)))
          (should (equal "fresh" (gethash "state" anchor))))
        (let ((root (aref (gethash "comments" thread) 0)))
          (should (equal '("author" "children" "edited" "id" "parent_id"
                           "text" "timestamp")
                         (cea-api-test--keys root)))
          (should (eq :null (gethash "parent_id" root)))
          (should (equal "body line one\nline two"
                         (gethash "text" root)))
          (should (equal [] (gethash "children" root))))))))

(ert-deftest cea-api-call-error-envelope ()
  (cea-test-with-env
    (let ((envelope (cea-test-api-call
                     'set-status '(:thread-id "th-none" :status "closed"))))
      (should (eq :false (gethash "ok" envelope)))
      (let ((error-object (gethash "error" envelope)))
        (should (equal '("message" "type") (cea-api-test--keys error-object)))
        (should (equal "not_found" (gethash "type" error-object)))))
    (let ((envelope (cea-test-api-call 'frobnicate nil)))
      (should (equal "invalid"
                     (gethash "type" (gethash "error" envelope)))))))

(ert-deftest cea-api-call-guards-status-wire-contract ()
  "The wire refuses to run when the statuses defcustom breaks the scripts.
The scripts create threads with the default status and hardcode
\"open\" and \"closed\"; a customization removing either fails
quietly (empty pending) or loudly (invalid close) downstream, so the
transport rejects it up front with a clear message."
  (cea-test-with-env
    (let ((claude-emacs-annotate-thread-statuses '("triage" "closed")))
      (let ((envelope (cea-test-api-call 'query nil)))
        (should (eq :false (gethash "ok" envelope)))
        (should (equal "invalid"
                       (gethash "type" (gethash "error" envelope))))
        (should (string-match-p
                 "claude-emacs-annotate-thread-statuses"
                 (gethash "message" (gethash "error" envelope))))))
    (let ((claude-emacs-annotate-thread-statuses '("open" "in-progress")))
      (let ((envelope (cea-test-api-call 'query nil)))
        (should (eq :false (gethash "ok" envelope)))))
    ;; The default configuration passes.
    (should (eq t (gethash "ok" (cea-test-api-call 'query nil))))))

(ert-deftest cea-api-call-batch-rejects-non-array-specs ()
  "A specs document that is not a JSON array must signal invalid.
A JSON object parses to a plist and null/false parse to nil, all of
which pass `listp'; the wire must reject them, not misread them."
  (cea-test-with-env
    (cea-api-test--file "na.el")
    (dolist (payload (list "{\"file\": \"na.el\", \"text\": \"x\"}"
                           "null"
                           "false"
                           "42"
                           "[{\"file\": \"na.el\"}, 7]"))
      (let ((specs (expand-file-name "bad-specs.json" cea-test-home)))
        (cea-test-write-file specs payload)
        (let ((envelope (cea-test-api-call 'create-batch
                                            (list :specs-file specs))))
          (should (eq :false (gethash "ok" envelope)))
          (should (equal "invalid"
                         (gethash "type"
                                  (gethash "error" envelope)))))))
    ;; The valid empty array still succeeds.
    (let ((specs (expand-file-name "empty-specs.json" cea-test-home)))
      (cea-test-write-file specs "[]")
      (let ((envelope (cea-test-api-call 'create-batch
                                          (list :specs-file specs))))
        (should (eq t (gethash "ok" envelope)))
        (should (= 0 (gethash "created" (gethash "result" envelope))))))))

(ert-deftest cea-api-call-batch-via-specs-file ()
  (cea-test-with-env
    (cea-api-test--file "sf.el")
    (let ((specs (expand-file-name "specs.json" cea-test-home)))
      (cea-test-write-file
       specs
       (json-serialize
        (vector (list :file "sf.el" :start_line 1 :end_line 2
                      :text "from batch\nwith newline" :tag "changes"
                      :author "claude-code")
                (list :file "sf.el" :kind "file"
                      :text "whole file spec" :tag "changes"
                      :author "claude-code")
                (list :file "sf.el" :start_line 90 :end_line 91
                      :text "broken" :tag "changes"
                      :author "claude-code"))))
      (let* ((envelope (cea-test-api-call 'create-batch
                                           (list :specs-file specs)))
             (result (gethash "result" envelope)))
        (should (eq t (gethash "ok" envelope)))
        (should (= 2 (gethash "created" result)))
        (should (= 1 (gethash "failed" result)))
        (should (= 2 (length (gethash "threads" result))))
        (let ((entry (aref (gethash "threads" result) 0)))
          (should (equal '("end_line" "file" "start_line" "thread_id")
                         (cea-api-test--keys entry))))
        ;; Whole-file entry: null lines.
        (should (eq :null (gethash "start_line"
                                   (aref (gethash "threads" result) 1))))
        (should (= 1 (length (gethash "failures" result))))
        ;; Multi-line text survived byte-exact.
        (let* ((listing (cea-test-api-call
                         'query '(:root-author "claude-code")))
               (threads (gethash "threads" (gethash "result" listing)))
               (texts (mapcar (lambda (thread)
                                (gethash "text"
                                         (aref (gethash "comments" thread)
                                               0)))
                              (append threads nil))))
          (should (member "from batch\nwith newline" texts)))))))

(ert-deftest cea-api-call-empty-arrays-not-null ()
  (cea-test-with-env
    (let ((out (expand-file-name "empty.json" cea-test-home)))
      (claude-emacs-annotate-api-call 'query cea-test-project nil out)
      (with-temp-buffer
        (insert-file-contents out)
        (should (string-match-p "\"threads\":\\[\\]" (buffer-string)))))))

(ert-deftest cea-api-call-pending-shape ()
  (cea-test-with-env
    (cea-api-test--file "pj.el")
    (let* ((thread (cea-api-test--create "pj.el" 1 2 :tag "changes"))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-reply
       cea-test-project id
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment thread))
       "waiting" :author "Jane Doe")
      (let* ((envelope (cea-test-api-call 'pending '(:tag "changes")))
             (result (gethash "result" envelope))
             (item (aref (gethash "pending" result) 0)))
        (should (= 1 (gethash "count" result)))
        (should (equal '("ancestors" "anchor" "author" "comment_id"
                         "file" "tags" "text" "thread_id" "thread_status"
                         "timestamp")
                       (cea-api-test--keys item)))
        (should (equal id (gethash "thread_id" item)))
        (should (= 1 (length (gethash "ancestors" item))))
        (let ((ancestor (aref (gethash "ancestors" item) 0)))
          (should (equal '("author" "comment_id" "text")
                         (cea-api-test--keys ancestor))))))))

(ert-deftest cea-api-call-count-shape ()
  (cea-test-with-env
    (cea-api-test--file "cj.el")
    (cea-api-test--create "cj.el" 1 1 :tag "changes")
    (let* ((envelope (cea-test-api-call 'count
                                         '(:root-author "claude-code")))
           (result (gethash "result" envelope)))
      (should (equal '("anchor_states" "author" "by_status"
                       "files_with_annotations" "open_by_tag"
                       "open_stale" "root" "total")
                     (cea-api-test--keys result)))
      (should (= 0 (gethash "closed" (gethash "by_status" result))))
      (should (= 1 (gethash "changes" (gethash "open_by_tag" result))))
      (should (= 1 (gethash "fresh" (gethash "anchor_states" result)))))))

(provide 'claude-emacs-annotate-api-test)
;;; claude-emacs-annotate-api-test.el ends here
