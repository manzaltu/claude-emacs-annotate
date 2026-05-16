;;; claude-emacs-annotate-store-test.el --- Store/persistence tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT coverage for the per-project store: path mapping, atomic
;; write-through, schema validation, the mtime guard, merge semantics
;; (last-writer-wins, comment union, tombstones) and change events.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-store)

(defun cea-store-test--fresh-registry-thread-ids ()
  "Read the on-disk store through a fresh registry; return thread ids."
  (cea-test-with-fresh-registry
    (let ((store (claude-emacs-annotate-store-get cea-test-project)))
      (mapcar #'claude-emacs-annotate-thread-id
              (claude-emacs-annotate-store-all-threads store)))))

(defun cea-store-test--write-divergent-file (threads tombstones)
  "Hand-write the project DB file with THREADS and TOMBSTONES.
Simulates a divergent writer (another process, a restored backup)
whose state never passed through this process's merge."
  (cea-test-write-file
   (claude-emacs-annotate-store-path cea-test-project)
   (let ((print-length nil) (print-level nil))
     (concat ";; test fixture\n"
             (prin1-to-string
              (list :version 1
                    :root (directory-file-name
                           (file-truename cea-test-project))
                    :threads threads
                    :tombstones tombstones))
             "\n"))))

;;;; The headline test: clear must never be undone by a stale writer

(ert-deftest cea-store-clear-not-resurrected-by-stale-writer ()
  "A stale in-memory store must not resurrect cleared threads.
Two stores share one DB file (simulating two Emacs processes).  After
store A deletes a thread and writes, a later write from store B --
which still holds the thread live in memory -- must honor A's
tombstone instead of resurrecting the thread."
  (cea-test-with-env
    (let* ((store-a (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store-a
                                    (cea-test-make-thread "a.el" "text")))
           (id (claude-emacs-annotate-thread-id thread))
           ;; Second registry = second process holding the thread live.
           (store-b (cea-test-with-fresh-registry
                      (claude-emacs-annotate-store-get cea-test-project))))
      (should (claude-emacs-annotate-store-thread store-b id))
      ;; A deletes (tombstone) and writes.
      (claude-emacs-annotate-store-mutate
       store-a
       (lambda () (claude-emacs-annotate-store-delete-thread store-a id)))
      ;; B, unaware, performs an unrelated mutation and writes.
      (claude-emacs-annotate-store-mutate
       store-b
       (lambda ()
         (claude-emacs-annotate-store-insert-thread
          store-b (cea-test-make-thread "b.el" "other"))))
      ;; The cleared thread must be gone everywhere.
      (should-not (claude-emacs-annotate-store-thread store-b id))
      (should-not (member id (cea-store-test--fresh-registry-thread-ids))))))

;;;; Paths and roots

(ert-deftest cea-store-path-sanitization ()
  (cea-test-with-env
    (let ((path (claude-emacs-annotate-store-path "/a/b!c")))
      (should (equal (file-name-nondirectory path) "!a!b!!c.eld"))
      (should (string-prefix-p (expand-file-name
                                claude-emacs-annotate-directory)
                               path)))))

(ert-deftest cea-store-root-normalized-through-symlink ()
  (cea-test-with-env
    (let ((link (expand-file-name "link" cea-test-home)))
      (make-symbolic-link cea-test-project link)
      (let ((via-real (claude-emacs-annotate-store-get cea-test-project))
            (via-link (claude-emacs-annotate-store-get link)))
        (should (eq via-real via-link))))))

(ert-deftest cea-store-get-no-create ()
  (cea-test-with-env
    (should-not (claude-emacs-annotate-store-get cea-test-project t))
    (let ((store (claude-emacs-annotate-store-get cea-test-project)))
      (should store)
      (should (eq store (claude-emacs-annotate-store-get cea-test-project t))))))

;;;; Round trip and atomicity

(ert-deftest cea-store-write-read-round-trip ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert
                    store
                    (cea-test-make-thread
                     "src/a.el" "line one\nline two" :tags '("changes")
                     :anchor '(:kind region :start-line 3 :end-line 4
                               :line-count 2 :text "x\ny" :text-cap nil
                               :text-hash "abc" :before ("b") :after ("a")
                               :state fresh)))))
      (should (file-exists-p (claude-emacs-annotate-store-path
                              cea-test-project)))
      (cea-test-with-fresh-registry
        (let* ((reloaded (claude-emacs-annotate-store-get cea-test-project))
               (got (claude-emacs-annotate-store-thread
                     reloaded (claude-emacs-annotate-thread-id thread))))
          (should got)
          (should (equal got thread)))))))

(ert-deftest cea-store-write-leaves-no-temp-debris ()
  (cea-test-with-env
    (let ((store (claude-emacs-annotate-store-get cea-test-project)))
      (cea-test-insert store (cea-test-make-thread "a.el" "t"))
      (let ((dir (file-name-directory
                  (claude-emacs-annotate-store-path cea-test-project))))
        (should-not (directory-files dir nil "\\.tmp-"))))))

(ert-deftest cea-store-stale-temp-files-collected-at-load ()
  (cea-test-with-env
    (let* ((path (claude-emacs-annotate-store-path cea-test-project))
           (stale (concat path ".tmp-stale")))
      (cea-test-write-file stale "junk")
      (set-file-times stale (time-subtract nil (* 2 60 60)))
      (claude-emacs-annotate-store-get cea-test-project)
      (should-not (file-exists-p stale)))))

(ert-deftest cea-store-immune-to-ambient-print-settings ()
  "Persisted data must not be truncated by ambient print variables."
  (cea-test-with-env
    (let ((store (claude-emacs-annotate-store-get cea-test-project))
          (thread (cea-test-make-thread "a.el" "root")))
      ;; Grow the comment list beyond a tiny print-length.
      (dotimes (i 8)
        (setq thread
              (plist-put thread :comments
                         (append (plist-get thread :comments)
                                 (list (claude-emacs-annotate-comment-create
                                        (claude-emacs-annotate-comment-id
                                         (claude-emacs-annotate-thread-root-comment
                                          thread))
                                        "u" (format "reply %d" i)))))))
      (let ((print-length 3) (print-level 2))
        (cea-test-insert store thread))
      (cea-test-with-fresh-registry
        (let* ((reloaded (claude-emacs-annotate-store-get cea-test-project))
               (got (claude-emacs-annotate-store-thread
                     reloaded (claude-emacs-annotate-thread-id thread))))
          (should (= 9 (length
                        (claude-emacs-annotate-thread-comments got)))))))))

(ert-deftest cea-store-serialized-form-carries-no-text-properties ()
  (cea-test-with-env
    (let ((store (claude-emacs-annotate-store-get cea-test-project)))
      (cea-test-insert store
                       (cea-test-make-thread
                        "a.el" (propertize "styled" 'face 'bold)))
      (with-temp-buffer
        (insert-file-contents (claude-emacs-annotate-store-path
                               cea-test-project))
        (should-not (search-forward "#(" nil t))))))

;;;; Schema validation

(ert-deftest cea-store-rejects-newer-schema-version ()
  (cea-test-with-env
    (cea-test-write-file (claude-emacs-annotate-store-path cea-test-project)
                         "(:version 999 :root \"/x\" :threads nil)")
    (should-error (claude-emacs-annotate-store-get cea-test-project)
                  :type 'claude-emacs-annotate-schema-error)))

(ert-deftest cea-store-rejects-corrupt-file-and-keeps-it ()
  (cea-test-with-env
    (let ((path (claude-emacs-annotate-store-path cea-test-project)))
      (cea-test-write-file path "((( not lisp data")
      (should-error (claude-emacs-annotate-store-get cea-test-project)
                    :type 'claude-emacs-annotate-io-error)
      ;; The broken file must not be overwritten by the failed load.
      (with-temp-buffer
        (insert-file-contents path)
        (should (string-match-p "not lisp data" (buffer-string)))))))

;;;; The mtime guard and merge

(defun cea-store-test--second-process-write (fn)
  "Run FN on a store loaded in a fresh registry, as a second process."
  (cea-test-with-fresh-registry
    (let ((store (claude-emacs-annotate-store-get cea-test-project)))
      (claude-emacs-annotate-store-mutate store (lambda () (funcall fn store))))))

(ert-deftest cea-store-mtime-guard-merges-external-write ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (mine (cea-test-insert store (cea-test-make-thread "a.el" "mine"))))
      ;; External process adds a second thread.
      (let (other-id)
        (cea-store-test--second-process-write
         (lambda (other-store)
           (let ((thread (cea-test-make-thread "b.el" "theirs")))
             (setq other-id (claude-emacs-annotate-thread-id thread))
             (claude-emacs-annotate-store-insert-thread other-store thread))))
        ;; Our next mutation must merge, not clobber.
        (claude-emacs-annotate-store-mutate
         store
         (lambda ()
           (claude-emacs-annotate-store-insert-thread
            store (cea-test-make-thread "c.el" "third"))))
        (let ((ids (cea-store-test--fresh-registry-thread-ids)))
          (should (member (claude-emacs-annotate-thread-id mine) ids))
          (should (member other-id ids))
          (should (= 3 (length ids))))))))

(ert-deftest cea-store-merge-last-writer-wins-by-updated ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (id (claude-emacs-annotate-thread-id thread)))
      ;; External process closes the thread (newer :updated).
      (cea-store-test--second-process-write
       (lambda (other-store)
         (let ((theirs (claude-emacs-annotate-store-thread other-store id)))
           (plist-put theirs :status "closed")
           (claude-emacs-annotate-store-update-thread other-store theirs))))
      ;; Our memory still says "open" with the older stamp; a mutation
      ;; must adopt the newer disk state.
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (claude-emacs-annotate-store-insert-thread
          store (cea-test-make-thread "b.el" "unrelated"))))
      (should (equal "closed"
                     (claude-emacs-annotate-thread-status
                      (claude-emacs-annotate-store-thread store id)))))))

(ert-deftest cea-store-merge-unions-concurrent-replies ()
  "Replies added by two divergent writers must both survive a merge."
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "root")))
           (id (claude-emacs-annotate-thread-id thread))
           (root-id (claude-emacs-annotate-comment-id
                     (claude-emacs-annotate-thread-root-comment thread))))
      ;; Our unwritten memory gains a reply.
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (let ((ours (claude-emacs-annotate-store-thread store id)))
           (plist-put ours :comments
                      (append (plist-get ours :comments)
                              (list (claude-emacs-annotate-comment-create
                                     root-id "us" "our reply"))))
           (claude-emacs-annotate-store-update-thread store ours))))
      ;; A divergent writer's file carries a DIFFERENT reply on a copy
      ;; that never saw ours, with a newer :updated stamp (they win the
      ;; scalar merge; our reply must still be unioned in).
      (let ((theirs (copy-sequence thread)))
        (setq theirs (copy-tree theirs))
        (plist-put theirs :comments
                   (list (claude-emacs-annotate-thread-root-comment thread)
                         (claude-emacs-annotate-comment-create
                          root-id "them" "their reply")))
        (plist-put theirs :updated "2999-01-01T00:00:00.000Z")
        (cea-store-test--write-divergent-file (list theirs) nil))
      (claude-emacs-annotate-store-refresh store)
      ;; Both replies must survive.
      (let* ((merged (claude-emacs-annotate-store-thread store id))
             (authors (mapcar #'claude-emacs-annotate-comment-author
                              (claude-emacs-annotate-thread-comments merged))))
        (should (member "them" authors))
        (should (member "us" authors))
        (should (= 3 (length authors)))))))

(ert-deftest cea-store-tombstone-wins-timestamp-tie ()
  "A live record and a tombstone with the same stamp: the tombstone wins."
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (id (claude-emacs-annotate-thread-id thread))
           (stamp (claude-emacs-annotate-thread-updated thread)))
      ;; Divergent file: a tombstone stamped exactly like our live copy.
      (cea-store-test--write-divergent-file
       nil (list (list :id id :deleted stamp)))
      (claude-emacs-annotate-store-refresh store)
      (should-not (claude-emacs-annotate-store-thread store id))
      (should-not (member id (cea-store-test--fresh-registry-thread-ids))))))

(ert-deftest cea-store-edit-after-delete-resurrects ()
  "A live record strictly newer than a tombstone wins (deliberate edit)."
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (id (claude-emacs-annotate-thread-id thread)))
      ;; We delete (tombstone stamped now).
      (claude-emacs-annotate-store-mutate
       store
       (lambda () (claude-emacs-annotate-store-delete-thread store id)))
      ;; Divergent file: the thread live again with a far newer stamp.
      (let ((revived (copy-tree thread)))
        (plist-put revived :updated "2999-01-01T00:00:00.000Z")
        (cea-store-test--write-divergent-file (list revived) nil))
      (claude-emacs-annotate-store-refresh store)
      (should (claude-emacs-annotate-store-thread store id))
      (should (member id (cea-store-test--fresh-registry-thread-ids))))))

(ert-deftest cea-store-tombstones-garbage-collected ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (let ((event (claude-emacs-annotate-store-delete-thread store id)))
           ;; Age the tombstone past the TTL.
           (puthash id "2000-01-01T00:00:00.000Z"
                    (claude-emacs-annotate-store--tombstones store))
           event)))
      ;; Any later write drops the expired tombstone from the file.
      (cea-test-insert store (cea-test-make-thread "b.el" "u"))
      (with-temp-buffer
        (insert-file-contents (claude-emacs-annotate-store-path
                               cea-test-project))
        (should-not (search-forward id nil t))))))

(ert-deftest cea-store-recreates-deleted-db-file ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (path (claude-emacs-annotate-store-path cea-test-project)))
      (delete-file path)
      (cea-test-insert store (cea-test-make-thread "b.el" "u"))
      (should (file-exists-p path))
      (should (member (claude-emacs-annotate-thread-id thread)
                      (cea-store-test--fresh-registry-thread-ids))))))

;;;; Indexes and reads

(ert-deftest cea-store-file-index ()
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (a (cea-test-insert store (cea-test-make-thread "a.el" "1")))
           (b (cea-test-insert store (cea-test-make-thread "b.el" "2"))))
      (cea-test-insert store (cea-test-make-thread "a.el" "3"))
      (should (= 2 (length (claude-emacs-annotate-store-threads-for-file
                            store "a.el"))))
      (should (equal (list (claude-emacs-annotate-thread-id b))
                     (mapcar #'claude-emacs-annotate-thread-id
                             (claude-emacs-annotate-store-threads-for-file
                              store "b.el"))))
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (claude-emacs-annotate-store-delete-thread
          store (claude-emacs-annotate-thread-id a))))
      (should (= 1 (length (claude-emacs-annotate-store-threads-for-file
                            store "a.el")))))))

;;;; Events and hooks

(ert-deftest cea-store-change-events ()
  (cea-test-with-env
    (let* ((events nil)
           (claude-emacs-annotate-changed-hook
            (list (lambda (event) (push event events))))
           (store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-insert store (cea-test-make-thread "a.el" "t")))
           (id (claude-emacs-annotate-thread-id thread)))
      (should (eq 'created (plist-get (car events) :type)))
      (should (equal (list id) (plist-get (car events) :thread-ids)))
      (should (equal (list "a.el") (plist-get (car events) :files)))
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (claude-emacs-annotate-store-update-thread
          store (claude-emacs-annotate-store-thread store id))))
      (should (eq 'updated (plist-get (car events) :type)))
      (claude-emacs-annotate-store-mutate
       store
       (lambda () (claude-emacs-annotate-store-delete-thread store id)))
      (should (eq 'deleted (plist-get (car events) :type))))))

(ert-deftest cea-store-external-change-fires-reloaded-event ()
  (cea-test-with-env
    (let* ((events nil)
           (store (claude-emacs-annotate-store-get cea-test-project)))
      (cea-test-insert store (cea-test-make-thread "a.el" "t"))
      (cea-store-test--second-process-write
       (lambda (other-store)
         (claude-emacs-annotate-store-insert-thread
          other-store (cea-test-make-thread "b.el" "u"))))
      (let ((claude-emacs-annotate-changed-hook
             (list (lambda (event) (push event events)))))
        (claude-emacs-annotate-store-refresh store))
      (should (memq 'reloaded (mapcar (lambda (e) (plist-get e :type))
                                      events))))))

(ert-deftest cea-store-before-mutate-hook-runs-first ()
  (cea-test-with-env
    (let* ((order nil)
           (store (claude-emacs-annotate-store-get cea-test-project))
           (claude-emacs-annotate-store-before-mutate-hook
            (list (lambda (_store) (push 'hook order)))))
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (push 'mutation order)
         (claude-emacs-annotate-store-insert-thread
          store (cea-test-make-thread "a.el" "t"))))
      (should (equal '(mutation hook) order)))))

(ert-deftest cea-store-refresh-without-changes-writes-nothing ()
  "Refreshing an in-sync store must not touch the file (no write ping-pong)."
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project)))
      (cea-test-insert store (cea-test-make-thread "a.el" "t"))
      (let* ((path (claude-emacs-annotate-store-path cea-test-project))
             (before (file-attribute-modification-time
                      (file-attributes path))))
        (claude-emacs-annotate-store-refresh store)
        (should (time-equal-p before
                              (file-attribute-modification-time
                               (file-attributes path))))))))

(ert-deftest cea-store-read-normalizes-unknown-anchor-states ()
  "Stored anchor states map onto the two-state model at read time.
Anything but `fresh' latches as stale, so an unrecognized state
surfaces rather than passing as current."
  (cea-test-with-env
    (cea-store-test--write-divergent-file
     (mapcar (lambda (state)
               (cea-test-make-thread
                "legacy.el" (symbol-name state)
                :anchor (list :kind 'region :start-line 1 :end-line 1
                              :line-count 1 :text "x"
                              :text-hash (sha1 "x")
                              :before nil :after nil :state state)))
             '(fresh stale bogus))
     nil)
    (cea-test-with-fresh-registry
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (states (mapcar
                      (lambda (thread)
                        (cons (claude-emacs-annotate-comment-text
                               (claude-emacs-annotate-thread-root-comment
                                thread))
                              (plist-get
                               (claude-emacs-annotate-thread-anchor thread)
                               :state)))
                      (claude-emacs-annotate-store-all-threads store))))
        (should (eq 'fresh (cdr (assoc "fresh" states))))
        (should (eq 'stale (cdr (assoc "stale" states))))
        (should (eq 'stale (cdr (assoc "bogus" states))))))))

(ert-deftest cea-store-map-buffers-survives-killed-buffers ()
  "A callback that kills buffers must not abort the walk.
Event handlers run reverts and mode hooks that may kill buffers later
in the snapshot; dead ones are skipped, not selected."
  (let ((b1 (generate-new-buffer " cea-map-1"))
        (b2 (generate-new-buffer " cea-map-2"))
        (visited 0))
    (unwind-protect
        (progn
          (claude-emacs-annotate--map-buffers
           (lambda ()
             (setq visited (1+ visited))
             (dolist (buffer (list b1 b2))
               (when (and (not (eq buffer (current-buffer)))
                          (buffer-live-p buffer))
                 (kill-buffer buffer)))))
          (should (> visited 0)))
      (when (buffer-live-p b1) (kill-buffer b1))
      (when (buffer-live-p b2) (kill-buffer b2)))))

(ert-deftest cea-store-read-rejects-malformed-records ()
  "Malformed thread and tombstone records signal a typed schema error.
The reader's contract is io-error or schema-error only; a raw
`wrong-type-argument' from the anchor-normalization loop must not
leak to the wire as an internal error."
  (cea-test-with-env
    (let ((path (expand-file-name "bad.eld" cea-test-home)))
      (dolist (content
               (list
                "(:version 1 :threads ((:id \"th-1\" :file \"a\" :anchor 5)))"
                "(:version 1 :threads (garbage))"
                "(:version 1 :threads ((:id 42)))"
                "(:version 1 :threads ((:id \"th-1\" . \"dotted\")))"
                "(:version 1 :threads nil :tombstones (bad))"
                "(:version 1 :threads nil :tombstones ((:id \"th-1\")))"))
        (cea-test-write-file path content)
        (should-error (claude-emacs-annotate--store-read path)
                      :type 'claude-emacs-annotate-schema-error)))))

(ert-deftest cea-store-delete-of-future-dated-thread-sticks ()
  "Deleting a thread whose `:updated' is ahead of the clock must persist.
The tombstone must outrank the record it deletes, or a stale writer
that still holds the record live resurrects it on merge."
  (cea-test-with-env
    (let* ((store-a (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-make-thread "a.el" "text"))
           (id (claude-emacs-annotate-thread-id thread)))
      (plist-put thread :updated
                 (format-time-string "%FT%T.%3NZ" (time-add nil 300) t))
      (cea-test-insert store-a thread)
      ;; Second registry = second process holding the thread live.
      (let ((store-b (cea-test-with-fresh-registry
                       (claude-emacs-annotate-store-get cea-test-project))))
        (should (claude-emacs-annotate-store-thread store-b id))
        ;; A deletes (tombstone) and writes.
        (claude-emacs-annotate-store-mutate
         store-a
         (lambda () (claude-emacs-annotate-store-delete-thread store-a id)))
        ;; B, unaware, performs an unrelated mutation and writes.
        (claude-emacs-annotate-store-mutate
         store-b
         (lambda ()
           (claude-emacs-annotate-store-insert-thread
            store-b (cea-test-make-thread "b.el" "other"))))
        ;; The deleted thread must stay gone everywhere.
        (should-not (claude-emacs-annotate-store-thread store-b id))
        (should-not
         (member id (cea-store-test--fresh-registry-thread-ids)))))))

(provide 'claude-emacs-annotate-store-test)
;;; claude-emacs-annotate-store-test.el ends here
