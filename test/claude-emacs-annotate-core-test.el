;;; claude-emacs-annotate-core-test.el --- Core data-layer tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT coverage for the pure data layer: ids, timestamps, ingest
;; normalization, constructors, comment trees, validation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-emacs-annotate-core)

;;;; Ids and timestamps

(ert-deftest cea-core-thread-id-shape ()
  (should (string-match-p "\\`th-[0-9]+-[0-9a-f]\\{8\\}\\'"
                          (claude-emacs-annotate--id "th"))))

(ert-deftest cea-core-comment-id-shape ()
  (should (string-match-p "\\`c-[0-9]+-[0-9a-f]\\{8\\}\\'"
                          (claude-emacs-annotate--id "c"))))

(ert-deftest cea-core-ids-unique ()
  (let ((ids (cl-loop repeat 200
                      collect (claude-emacs-annotate--id "th"))))
    (should (= (length ids) (length (delete-dups ids))))))

(ert-deftest cea-core-timestamp-format-utc-ms ()
  (should (string-match-p
           (concat "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
                   "T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\.[0-9]\\{3\\}Z\\'")
           (claude-emacs-annotate--timestamp))))

(ert-deftest cea-core-timestamps-monotonic-as-strings ()
  (let* ((a (claude-emacs-annotate--timestamp))
         (b (claude-emacs-annotate--timestamp)))
    (should-not (string> a b))))

;;;; Ingest normalization

(ert-deftest cea-core-clean-string-strips-properties ()
  (let ((cleaned (claude-emacs-annotate--clean-string
                  (propertize "hello" 'face 'bold))))
    (should (equal cleaned "hello"))
    (should (null (text-properties-at 0 cleaned)))))

(ert-deftest cea-core-clean-string-rejects-non-strings ()
  (should-error (claude-emacs-annotate--clean-string 42)
                :type 'claude-emacs-annotate-invalid)
  (should-error (claude-emacs-annotate--clean-string nil)
                :type 'claude-emacs-annotate-invalid))

;;;; Thread construction

(ert-deftest cea-core-thread-create-defaults ()
  (let* ((anchor '(:kind file :state fresh))
         (thread (claude-emacs-annotate-thread-create
                  "src/a.el" anchor "root text" "claude-code"
                  :tags '("changes"))))
    (should (string-match-p "\\`th-" (claude-emacs-annotate-thread-id thread)))
    (should (equal (claude-emacs-annotate-thread-file thread) "src/a.el"))
    (should (equal (claude-emacs-annotate-thread-status thread) "open"))
    (should (equal (claude-emacs-annotate-thread-priority thread) "normal"))
    (should (equal (claude-emacs-annotate-thread-tags thread) '("changes")))
    (should (eq (claude-emacs-annotate-thread-anchor thread) anchor))
    (should (equal (claude-emacs-annotate-thread-created thread)
                   (claude-emacs-annotate-thread-updated thread)))
    (let ((root (claude-emacs-annotate-thread-root-comment thread)))
      (should (equal (claude-emacs-annotate-comment-author root) "claude-code"))
      (should (equal (claude-emacs-annotate-comment-text root) "root text"))
      (should (null (claude-emacs-annotate-comment-parent-id root))))
    (should (equal (claude-emacs-annotate-thread-root-author thread)
                   "claude-code"))))

(ert-deftest cea-core-thread-create-cleans-text-properties ()
  (let* ((thread (claude-emacs-annotate-thread-create
                  "f" '(:kind file :state fresh)
                  (propertize "styled" 'face 'bold)
                  (propertize "someone" 'face 'italic)))
         (root (claude-emacs-annotate-thread-root-comment thread)))
    (should (null (text-properties-at
                   0 (claude-emacs-annotate-comment-text root))))
    (should (null (text-properties-at
                   0 (claude-emacs-annotate-comment-author root))))))

(ert-deftest cea-core-thread-create-validates-status ()
  (should-error (claude-emacs-annotate-thread-create
                 "f" '(:kind file :state fresh) "t" "a" :status "bogus")
                :type 'claude-emacs-annotate-invalid))

(ert-deftest cea-core-thread-create-validates-priority ()
  (should-error (claude-emacs-annotate-thread-create
                 "f" '(:kind file :state fresh) "t" "a" :priority "asap")
                :type 'claude-emacs-annotate-invalid))

(ert-deftest cea-core-thread-create-validates-tags ()
  (should-error (claude-emacs-annotate-thread-create
                 "f" '(:kind file :state fresh) "t" "a" :tags '("bad tag"))
                :type 'claude-emacs-annotate-invalid))

;;;; Tag validation charset

(ert-deftest cea-core-tag-charset ()
  (dolist (ok '("changes" "a" "A1" "x.y_z-2" "review-cmdline-filtering"))
    (should (equal ok (claude-emacs-annotate--check-tag ok))))
  (dolist (bad '("" "-x" ".x" "_x" "a b" "a\tb" "a\nb" "héllo" "a/b" "a,b"))
    (should-error (claude-emacs-annotate--check-tag bad)
                  :type 'claude-emacs-annotate-invalid)))

;;;; Comments

(ert-deftest cea-core-comment-create-shape ()
  (let ((comment (claude-emacs-annotate-comment-create
                  "r1" "someone" "reply body")))
    (should (string-match-p "\\`c-" (claude-emacs-annotate-comment-id comment)))
    (should (equal (claude-emacs-annotate-comment-parent-id comment) "r1"))
    (should (equal (claude-emacs-annotate-comment-author comment) "someone"))
    (should (equal (claude-emacs-annotate-comment-text comment) "reply body"))
    (should (stringp (claude-emacs-annotate-comment-timestamp comment)))))

(ert-deftest cea-core-comment-tree-structure ()
  (let* ((r1 '(:id "r1" :parent-id nil :author "u" :text "a"))
         (c1 '(:id "c1" :parent-id "r1" :author "u" :text "b"))
         (c2 '(:id "c2" :parent-id "r1" :author "u" :text "c"))
         (g1 '(:id "g1" :parent-id "c1" :author "u" :text "d"))
         (r2 '(:id "r2" :parent-id nil :author "u" :text "e"))
         (tree (claude-emacs-annotate-comment-tree (list r1 c1 c2 g1 r2))))
    (should (= 2 (length tree)))
    (should (equal "r1" (plist-get (car (nth 0 tree)) :id)))
    (should (equal "r2" (plist-get (car (nth 1 tree)) :id)))
    (let ((r1-children (cdr (nth 0 tree))))
      (should (equal '("c1" "c2")
                     (mapcar (lambda (node) (plist-get (car node) :id))
                             r1-children)))
      (should (equal '("g1")
                     (mapcar (lambda (node) (plist-get (car node) :id))
                             (cdr (nth 0 r1-children))))))))

(ert-deftest cea-core-comment-tree-dangling-parent-is-root ()
  (let ((tree (claude-emacs-annotate-comment-tree
               '((:id "x" :parent-id "gone" :author "u" :text "t")))))
    (should (= 1 (length tree)))
    (should (equal "x" (plist-get (car (nth 0 tree)) :id)))))

(ert-deftest cea-core-leaf-p-structural ()
  (let ((comments '((:id "r" :parent-id nil)
                    (:id "a" :parent-id "r")
                    (:id "b" :parent-id "r"))))
    (should-not (claude-emacs-annotate-comment-leaf-p comments "r"))
    ;; Two siblings are both leaves: structural, not chronological.
    (should (claude-emacs-annotate-comment-leaf-p comments "a"))
    (should (claude-emacs-annotate-comment-leaf-p comments "b"))))

(ert-deftest cea-core-root-comment-found-by-parent-id ()
  (let ((thread (list :id "t"
                      :comments '((:id "c" :parent-id "r" :author "x")
                                  (:id "r" :parent-id nil :author "u")))))
    (should (equal "r" (plist-get
                        (claude-emacs-annotate-thread-root-comment thread)
                        :id)))
    (should (equal "u" (claude-emacs-annotate-thread-root-author thread)))))

;;;; Mutation helpers

(ert-deftest cea-core-thread-touch-bumps-updated ()
  (let ((thread (claude-emacs-annotate-thread-create
                 "f" '(:kind file :state fresh) "t" "a")))
    (setq thread (plist-put thread :updated "2000-01-01T00:00:00.000Z"))
    (setq thread (claude-emacs-annotate-thread-touch thread))
    (should (string< "2000-01-01T00:00:00.000Z"
                     (claude-emacs-annotate-thread-updated thread)))))

(ert-deftest cea-core-thread-touch-strictly-increases ()
  "Same-millisecond touches must still produce increasing stamps.
The `:updated' stamp is the merge's last-writer-wins key; a repeated
stamp would make an update indistinguishable from the state it
replaced."
  (let ((thread (claude-emacs-annotate-thread-create
                 "f" '(:kind file :state fresh) "t" "a")))
    (dotimes (_ 5)
      (let ((before (claude-emacs-annotate-thread-updated thread)))
        (setq thread (claude-emacs-annotate-thread-touch thread))
        (should (string< before
                         (claude-emacs-annotate-thread-updated thread)))))))

;;;; Author resolution

(ert-deftest cea-core-author-resolution ()
  (let ((claude-emacs-annotate-default-author "Me"))
    (should (equal (claude-emacs-annotate-author) "Me")))
  (let ((claude-emacs-annotate-default-author nil)
        (user-full-name "Full Name"))
    (should (equal (claude-emacs-annotate-author) "Full Name")))
  (let ((claude-emacs-annotate-default-author nil)
        (user-full-name ""))
    (should (equal (claude-emacs-annotate-author) (user-login-name)))))

(ert-deftest cea-core-touch-future-stamp-returns-promptly ()
  "Touching a thread whose `:updated' is ahead of the clock must not spin.
A merged stamp from a clock step must advance by computation, not by
waiting for wall-clock time to catch up."
  (let* ((future (format-time-string "%FT%T.%3NZ" (time-add nil 3) t))
         (thread (list :id "th-x" :updated future))
         (start (float-time)))
    (claude-emacs-annotate-thread-touch thread)
    (should (< (- (float-time) start) 1.0))
    (should (string< future (plist-get thread :updated)))))

(ert-deftest cea-core-timestamp-after-advances-minimally ()
  "The successor stamp is strictly greater and handles the 999 carry."
  (should (equal (claude-emacs-annotate--timestamp-after
                  "2026-07-16T20:27:04.488Z")
                 "2026-07-16T20:27:04.489Z"))
  (should (equal (claude-emacs-annotate--timestamp-after
                  "2026-07-16T20:27:04.999Z")
                 "2026-07-16T20:27:05.000Z"))
  (should (equal (claude-emacs-annotate--timestamp-after
                  "2026-12-31T23:59:59.999Z")
                 "2027-01-01T00:00:00.000Z")))

(provide 'claude-emacs-annotate-core-test)
;;; claude-emacs-annotate-core-test.el ends here
