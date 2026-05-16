;;; claude-emacs-annotate-anchor-test.el --- Anchor engine tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; The resolve matrix: capture from buffers and files, then re-anchor
;; against changed content -- fresh (exact at lines, followed
;; elsewhere, or whitespace-normalized) and stale (context-located
;; change or unlocatable clamp), plus rescue and the stale latch.
;; Nothing may ever be silently dropped.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-anchor)

(defmacro cea-anchor-test--with-lines (lines &rest body)
  "Run BODY in a temp buffer whose content is LINES (a list form)."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert (string-join ,lines "\n") "\n")
     ,@body))

(defun cea-anchor-test--numbered-lines (n &optional prefix)
  "Return N distinct lines named with PREFIX."
  (cl-loop for i from 1 to n
           collect (format "%s line %03d" (or prefix "body") i)))

;;;; Capture

(ert-deftest cea-anchor-capture-basic ()
  (cea-anchor-test--with-lines '("one" "two" "three" "four" "five")
    (let ((anchor (claude-emacs-annotate-anchor-capture 2 3)))
      (should (eq 'region (plist-get anchor :kind)))
      (should (= 2 (plist-get anchor :start-line)))
      (should (= 3 (plist-get anchor :end-line)))
      (should (= 2 (plist-get anchor :line-count)))
      (should (equal "two\nthree" (plist-get anchor :text)))
      (should (null (plist-get anchor :text-cap)))
      (should (equal (sha1 "two\nthree") (plist-get anchor :text-hash)))
      (should (equal '("one") (plist-get anchor :before)))
      (should (equal '("four" "five") (plist-get anchor :after)))
      (should (eq 'fresh (plist-get anchor :state))))))

(ert-deftest cea-anchor-capture-context-clamped-at-bounds ()
  (cea-anchor-test--with-lines '("a" "b" "c")
    (let ((anchor (claude-emacs-annotate-anchor-capture 1 3)))
      (should (equal nil (plist-get anchor :before)))
      (should (equal nil (plist-get anchor :after))))))

(ert-deftest cea-anchor-capture-validates-range ()
  (cea-anchor-test--with-lines '("a" "b")
    (should-error (claude-emacs-annotate-anchor-capture 1 5)
                  :type 'claude-emacs-annotate-invalid)
    (should-error (claude-emacs-annotate-anchor-capture 0 1)
                  :type 'claude-emacs-annotate-invalid)
    (should-error (claude-emacs-annotate-anchor-capture 2 1)
                  :type 'claude-emacs-annotate-invalid)))

(ert-deftest cea-anchor-capture-file-matches-buffer-capture ()
  (cea-test-with-env
    (let ((path (cea-test-project-file "src/x.txt" "one\ntwo\nthree\n")))
      (let ((from-file (claude-emacs-annotate-anchor-capture-file path 2 2)))
        (should (equal "two" (plist-get from-file :text)))
        (should-not (find-buffer-visiting path))))))

(ert-deftest cea-anchor-capture-file-range-error-message ()
  (cea-test-with-env
    (let ((path (cea-test-project-file "short.txt" "only\n")))
      (let ((err (should-error (claude-emacs-annotate-anchor-capture-file
                                path 3 4)
                               :type 'claude-emacs-annotate-invalid)))
        (should (string-match-p "line range 3\\.\\.4 exceeds .*(1 lines)"
                                (cadr err)))))))

(ert-deftest cea-anchor-capture-huge-region-capped ()
  (let* ((lines (cea-anchor-test--numbered-lines 130))
         (full (string-join lines "\n")))
    (cea-anchor-test--with-lines lines
      (let ((anchor (claude-emacs-annotate-anchor-capture 1 130)))
        (should (null (plist-get anchor :text)))
        (should (equal (string-join (seq-take lines 10) "\n")
                       (plist-get (plist-get anchor :text-cap) :first)))
        (should (equal (string-join (seq-drop lines 120) "\n")
                       (plist-get (plist-get anchor :text-cap) :last)))
        (should (equal (sha1 full) (plist-get anchor :text-hash)))
        (should (= 130 (plist-get anchor :line-count)))))))

(ert-deftest cea-anchor-capture-whole-file ()
  (let ((anchor (claude-emacs-annotate-anchor-capture-whole-file)))
    (should (eq 'file (plist-get anchor :kind)))
    (should (eq 'fresh (plist-get anchor :state)))))

;;;; Resolve: fresh

(ert-deftest cea-anchor-resolve-fresh-at-recorded-lines ()
  (cea-anchor-test--with-lines '("one" "two" "three" "four")
    (let ((anchor (claude-emacs-annotate-anchor-capture 2 3)))
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 2 (plist-get resolution :start-line)))
        (should (= 3 (plist-get resolution :end-line)))))))

(ert-deftest cea-anchor-resolve-file-kind-always-fresh ()
  (let ((anchor (claude-emacs-annotate-anchor-capture-whole-file)))
    (cea-anchor-test--with-lines '("a" "b" "c")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 1 (plist-get resolution :start-line)))
        (should (= 3 (plist-get resolution :end-line)))))
    ;; Empty buffer must not blow up.
    (with-temp-buffer
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 1 (plist-get resolution :start-line)))))))

;;;; Resolve: followed silently (exact or normalized match elsewhere)

(ert-deftest cea-anchor-resolve-follows-insertion-above ()
  (let ((anchor (cea-anchor-test--with-lines '("one" "two" "three" "four")
                  (claude-emacs-annotate-anchor-capture 2 3))))
    (cea-anchor-test--with-lines '("new" "new" "new" "one" "two" "three" "four")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (eq 'exact-search (plist-get resolution :method)))
        (should (= 5 (plist-get resolution :start-line)))
        (should (= 6 (plist-get resolution :end-line)))))))

(ert-deftest cea-anchor-resolve-follow-picks-nearest-duplicate ()
  (let* ((block '("dup a" "dup b"))
         (anchor (cea-anchor-test--with-lines
                     (append (cea-anchor-test--numbered-lines 15)
                             block
                             (cea-anchor-test--numbered-lines 3 "tail"))
                   ;; Recorded at lines 16-17.
                   (claude-emacs-annotate-anchor-capture 16 17))))
    ;; New buffer: duplicates at 2-3 and 14-15; recorded start 16 → nearest 14.
    (cea-anchor-test--with-lines
        (append '("x") block
                (cea-anchor-test--numbered-lines 10 "mid")
                block
                '("y"))
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 14 (plist-get resolution :start-line)))))))

(ert-deftest cea-anchor-resolve-duplicate-tie-broken-by-context ()
  (let* ((anchor (cea-anchor-test--with-lines
                     '("ctx before" "same" "ctx after" "pad")
                   (claude-emacs-annotate-anchor-capture 2 2))))
    ;; Two "same" lines equidistant from recorded line 2 (lines 1 and 3);
    ;; only line 3 sits between the matching context lines.
    (cea-anchor-test--with-lines
        '("same" "ctx before" "same" "ctx after" "pad")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 3 (plist-get resolution :start-line)))))))

(ert-deftest cea-anchor-resolve-follows-whitespace-normalized ()
  (let ((anchor (cea-anchor-test--with-lines '("one" "  foo(bar)" "three")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    (cea-anchor-test--with-lines '("one" "\t\tfoo(bar)" "three")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (eq 'ws-search (plist-get resolution :method)))
        (should (= 2 (plist-get resolution :start-line)))))))

(ert-deftest cea-anchor-resolve-is-case-sensitive ()
  (let ((anchor (cea-anchor-test--with-lines '("ctx" "Target" "ctx2")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    ;; Only a case-variant exists now; exact/ws search must NOT take it.
    (cea-anchor-test--with-lines '("other" "target" "thing")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should-not (eq 'fresh (plist-get resolution :state)))))))

(ert-deftest cea-anchor-resolve-capped-anchor-follows ()
  (let* ((lines (cea-anchor-test--numbered-lines 125))
         (anchor (cea-anchor-test--with-lines lines
                   (claude-emacs-annotate-anchor-capture 1 125))))
    (cea-anchor-test--with-lines (append '("pad one" "pad two") lines)
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (= 3 (plist-get resolution :start-line)))
        (should (= 127 (plist-get resolution :end-line)))))))

(ert-deftest cea-anchor-resolve-whitespace-only-anchor-never-follows ()
  "A blank-line anchor must not silently adopt some other blank line.
Whitespace-only text matches every blank line in the file, so the
search rungs carry no information; context must decide instead."
  (let ((anchor (cea-anchor-test--with-lines '("head" "" "tail")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    ;; Unchanged content still resolves fresh at the recorded lines.
    (cea-anchor-test--with-lines '("head" "" "tail")
      (should (eq 'fresh (plist-get
                          (claude-emacs-annotate-anchor-resolve anchor)
                          :state))))
    ;; The blank got filled; another blank exists at line 1.  The
    ;; search rungs would grab it -- context must win instead, marking
    ;; the true spot stale.
    (cea-anchor-test--with-lines '("" "head" "filled" "tail")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'stale (plist-get resolution :state)))
        (should (eq 'context (plist-get resolution :method)))
        (should (= 3 (plist-get resolution :start-line)))))))

;;;; Resolve: stale via context (content changed in place)

(ert-deftest cea-anchor-resolve-stale-between-contexts ()
  (let ((anchor (cea-anchor-test--with-lines
                    '("before a" "before b" "old body" "after a" "after b")
                  (claude-emacs-annotate-anchor-capture 3 3))))
    (cea-anchor-test--with-lines
        '("before a" "before b" "totally new body" "second new line"
          "after a" "after b")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'stale (plist-get resolution :state)))
        (should (eq 'context (plist-get resolution :method)))
        (should (= 3 (plist-get resolution :start-line)))
        (should (= 4 (plist-get resolution :end-line)))))))

(ert-deftest cea-anchor-resolve-stale-region-deleted-entirely ()
  (let ((anchor (cea-anchor-test--with-lines
                    '("before a" "before b" "gone" "after a" "after b")
                  (claude-emacs-annotate-anchor-capture 3 3))))
    (cea-anchor-test--with-lines '("before a" "before b" "after a" "after b")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'stale (plist-get resolution :state)))
        (should (= 3 (plist-get resolution :start-line)))
        (should (= 3 (plist-get resolution :end-line)))))))

(ert-deftest cea-anchor-resolve-stale-only-before-context ()
  (let ((anchor (cea-anchor-test--with-lines
                    '("before a" "before b" "old body" "tail x" "tail y")
                  (claude-emacs-annotate-anchor-capture 3 3))))
    ;; After-context gone, body changed; before-context intact.
    (cea-anchor-test--with-lines
        '("before a" "before b" "different body" "unrelated" "stuff")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'stale (plist-get resolution :state)))
        (should (= 3 (plist-get resolution :start-line)))
        (should (= 3 (plist-get resolution :end-line)))))))

;;;; Resolve: stale via clamp (unlocatable)

(ert-deftest cea-anchor-resolve-unlocatable-keeps-lines-clamped ()
  (let ((anchor (cea-anchor-test--with-lines
                    (cea-anchor-test--numbered-lines 20)
                  (claude-emacs-annotate-anchor-capture 15 18))))
    (cea-anchor-test--with-lines '("completely" "different" "content")
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'stale (plist-get resolution :state)))
        (should (eq 'clamp (plist-get resolution :method)))
        ;; Clamped into the 3-line buffer for display.
        (should (<= (plist-get resolution :end-line) 3))
        (should (>= (plist-get resolution :start-line) 1))))
    ;; The anchor record itself must be untouched by resolution.
    (should (= 15 (plist-get anchor :start-line)))
    (should (equal 'fresh (plist-get anchor :state)))))

(ert-deftest cea-anchor-resolve-stale-rescued-when-content-returns ()
  (let ((anchor (cea-anchor-test--with-lines '("aa" "bb" "cc")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    (cea-anchor-test--with-lines '("zz")
      (should (eq 'stale (plist-get
                          (claude-emacs-annotate-anchor-resolve anchor)
                          :state))))
    (cea-anchor-test--with-lines '("aa" "bb" "cc")
      (should (eq 'fresh (plist-get
                          (claude-emacs-annotate-anchor-resolve anchor)
                          :state))))))

;;;; Adoption

(ert-deftest cea-anchor-adopt-clean-resolution-is-eq ()
  (cea-anchor-test--with-lines '("one" "two" "three")
    (let* ((anchor (claude-emacs-annotate-anchor-capture 2 2))
           (resolution (claude-emacs-annotate-anchor-resolve anchor)))
      ;; Nothing changed: adoption must return the identical object so
      ;; a clean re-open writes nothing to the store.
      (should (eq anchor (claude-emacs-annotate-anchor-adopt
                          anchor resolution))))))

(ert-deftest cea-anchor-adopt-follow-blesses-fresh ()
  (let ((anchor (cea-anchor-test--with-lines '("ctx1" "body" "ctx2")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    (cea-anchor-test--with-lines '("new0" "ctx1" "body" "ctx2")
      (let* ((resolution (claude-emacs-annotate-anchor-resolve anchor))
             (adopted (claude-emacs-annotate-anchor-adopt anchor resolution)))
        (should (eq 'fresh (plist-get adopted :state)))
        (should (= 3 (plist-get adopted :start-line)))
        (should (equal '("new0" "ctx1") (plist-get adopted :before)))
        ;; Untouched original.
        (should (= 2 (plist-get anchor :start-line)))
        (should (eq 'fresh (plist-get
                            (claude-emacs-annotate-anchor-resolve adopted)
                            :state)))))))

(ert-deftest cea-anchor-adopt-stale-context-is-a-latch ()
  "Context adoption takes the located lines but keeps the content.
Recapturing the new text would make the next resolve exact-match it
and silently bless the thread fresh -- the latch must hold until the
original content returns or the thread is explicitly re-pinned."
  (let ((anchor (cea-anchor-test--with-lines
                    '("before a" "before b" "old" "after a" "after b")
                  (claude-emacs-annotate-anchor-capture 3 3))))
    (cea-anchor-test--with-lines
        '("pad" "before a" "before b" "brand new" "after a" "after b")
      (let* ((resolution (claude-emacs-annotate-anchor-resolve anchor))
             (adopted (claude-emacs-annotate-anchor-adopt anchor resolution)))
        (should (eq 'stale (plist-get adopted :state)))
        ;; Located lines adopted; original content preserved.
        (should (= 4 (plist-get adopted :start-line)))
        (should (equal "old" (plist-get adopted :text)))
        (should (equal (sha1 "old") (plist-get adopted :text-hash)))
        (should (equal '("before a" "before b") (plist-get adopted :before)))
        ;; The latch holds on a subsequent resolve of the same content.
        (should (eq 'stale (plist-get
                            (claude-emacs-annotate-anchor-resolve adopted)
                            :state))))
      ;; And the preserved content still powers the rescue.
      (let ((adopted (claude-emacs-annotate-anchor-adopt
                      anchor (claude-emacs-annotate-anchor-resolve anchor))))
        (cea-anchor-test--with-lines
            '("before a" "before b" "old" "after a" "after b")
          (should (eq 'fresh (plist-get
                              (claude-emacs-annotate-anchor-resolve adopted)
                              :state))))))))

(ert-deftest cea-anchor-adopt-unlocatable-preserves-content-fields ()
  (let ((anchor (cea-anchor-test--with-lines '("aa" "bb" "cc")
                  (claude-emacs-annotate-anchor-capture 2 2))))
    (cea-anchor-test--with-lines '("zz")
      (let* ((resolution (claude-emacs-annotate-anchor-resolve anchor))
             (adopted (claude-emacs-annotate-anchor-adopt anchor resolution)))
        (should (eq 'stale (plist-get adopted :state)))
        ;; Original text and recorded lines kept for a later rescue.
        (should (equal "bb" (plist-get adopted :text)))
        (should (= 2 (plist-get adopted :start-line)))))))

;;;; Environment robustness

(ert-deftest cea-anchor-ops-widen-narrowed-buffers ()
  (cea-anchor-test--with-lines '("one" "two" "three" "four" "five")
    (narrow-to-region (progn (goto-char (point-min))
                             (forward-line 2) (point))
                      (point-max))
    (let ((anchor (claude-emacs-annotate-anchor-capture 2 2)))
      (should (equal "two" (plist-get anchor :text)))
      (should (eq 'fresh (plist-get
                          (claude-emacs-annotate-anchor-resolve anchor)
                          :state))))
    ;; Narrowing itself must survive.
    (should (buffer-narrowed-p))))

(ert-deftest cea-anchor-capture-file-handles-crlf ()
  (cea-test-with-env
    (let ((path (expand-file-name "dos.txt" cea-test-project)))
      (let ((coding-system-for-write 'utf-8-dos))
        (write-region "one\ntwo\nthree\n" nil path nil 'silent))
      (let ((anchor (claude-emacs-annotate-anchor-capture-file path 2 2)))
        (should (equal "two" (plist-get anchor :text)))))))

(ert-deftest cea-anchor-capped-rewritten-middle-not-fresh ()
  "A capped anchor whose middle changed must not resolve fresh.
Capped anchors compare only head and tail blocks line-wise; the
normalized rung must still reject a rewritten middle via the
whitespace-normalized full-content hash."
  (with-temp-buffer
    (dotimes (i 124) (insert (format "line-%03d contents" i) "\n"))
    (let ((anchor (claude-emacs-annotate-anchor-capture 1 124)))
      (should (plist-get anchor :text-cap))
      (erase-buffer)
      (dotimes (i 124)
        (insert (if (or (< i 10) (>= i 114))
                    (format "line-%03d contents" i)
                  (format "rewritten-%03d" i))
                "\n"))
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should-not (eq 'fresh (plist-get resolution :state)))))))

(ert-deftest cea-anchor-capped-whitespace-reflow-still-fresh ()
  "A capped anchor still resolves fresh across whitespace-only reflow."
  (with-temp-buffer
    (dotimes (i 124) (insert (format "line-%03d \tcontents" i) "\n"))
    (let ((anchor (claude-emacs-annotate-anchor-capture 1 124)))
      (erase-buffer)
      (insert "preamble\n")
      (dotimes (i 124) (insert (format "  line-%03d contents" i) "\n"))
      (let ((resolution (claude-emacs-annotate-anchor-resolve anchor)))
        (should (eq 'fresh (plist-get resolution :state)))
        (should (eq 'ws-search (plist-get resolution :method)))
        (should (= 2 (plist-get resolution :start-line)))))))

(provide 'claude-emacs-annotate-anchor-test)
;;; claude-emacs-annotate-anchor-test.el ends here
