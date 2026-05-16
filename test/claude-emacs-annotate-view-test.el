;;; claude-emacs-annotate-view-test.el --- View/overlay layer tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; The integration-critical layer: overlays as a pure view over the
;; store, the flush engine, and the revert brackets.  These tests
;; simulate the production failure mode -- external file writes under
;; buffers with live overlays -- in batch mode.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cea-test-helpers)
(require 'claude-emacs-annotate-api)
(require 'claude-emacs-annotate-view)

(defmacro cea-view-test--with-buffer (file &rest body)
  "Visit project FILE with the annotation mode enabled around BODY."
  (declare (indent 1) (debug t))
  `(let ((buffer (find-file-noselect
                  (expand-file-name ,file cea-test-project))))
     (unwind-protect
         (with-current-buffer buffer
           (claude-emacs-annotate-mode 1)
           ,@body)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer)))))

(defun cea-view-test--overlay-for (thread)
  "Return the current buffer's overlay carrying THREAD's id."
  (seq-find (lambda (overlay)
              (equal (overlay-get overlay 'claude-emacs-annotate-id)
                     (claude-emacs-annotate-thread-id thread)))
            (claude-emacs-annotate--view-overlays)))

(defun cea-view-test--store-anchor (thread)
  "Return THREAD's current anchor as persisted in the store."
  (claude-emacs-annotate-thread-anchor
   (claude-emacs-annotate-store-thread
    (claude-emacs-annotate-store-get cea-test-project)
    (claude-emacs-annotate-thread-id thread))))

;;;; Attach

(ert-deftest cea-view-attach-places-overlays-at-anchor ()
  (cea-test-with-env
    (cea-test-file-lines "a.el" '("one" "two" "three" "four"))
    (let ((thread (cea-test-api-create "a.el" 2 3)))
      (cea-view-test--with-buffer "a.el"
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should overlay)
          (should (= 2 (line-number-at-pos (overlay-start overlay) t)))
          (should (= 3 (line-number-at-pos (overlay-end overlay) t))))))))

(ert-deftest cea-view-attach-clean-file-writes-nothing ()
  (cea-test-with-env
    (cea-test-file-lines "b.el" '("one" "two" "three"))
    (cea-test-api-create "b.el" 2 2)
    (let* ((path (claude-emacs-annotate-store-path cea-test-project))
           (mtime (file-attribute-modification-time
                   (file-attributes path))))
      (cea-view-test--with-buffer "b.el"
        (should (= 1 (length (claude-emacs-annotate--view-overlays)))))
      (should (time-equal-p mtime
                            (file-attribute-modification-time
                             (file-attributes path)))))))

(ert-deftest cea-view-attach-blesses-followed-position ()
  "Content found elsewhere is silently followed: fresh at the new lines.
The bless is eager -- persisted at attach, not deferred to a flush."
  (cea-test-with-env
    (cea-test-file-lines "c.el" '("alpha" "beta" "gamma"))
    (let ((thread (cea-test-api-create "c.el" 2 2)))
      ;; The file gains two lines on top while no buffer is watching.
      (cea-test-file-lines "c.el" '("new1" "new2" "alpha" "beta" "gamma"))
      (cea-view-test--with-buffer "c.el"
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should (= 4 (line-number-at-pos (overlay-start overlay) t))))
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (eq 'fresh (plist-get anchor :state)))
          (should (= 4 (plist-get anchor :start-line)))))
      ;; Leaving the buffer changes nothing further.
      (let ((anchor (cea-view-test--store-anchor thread)))
        (should (eq 'fresh (plist-get anchor :state)))
        (should (= 4 (plist-get anchor :start-line)))))))

(ert-deftest cea-view-attach-renders-current-verdict ()
  "The render an attach produces reflects THAT attach's resolution.
Adoptions must persist before the boxes are drawn -- decorating
first shows the previous attach's state, a stale badge one revert
late (or a phantom one after a rescue)."
  (cea-test-with-env
    (cea-test-file-lines "rb.el" '("ctx a" "the body" "ctx b"))
    (let ((thread (cea-test-api-create "rb.el" 2 2 :text "note")))
      (cea-view-test--with-buffer "rb.el"
        (should-not (string-match-p
                     "STALE"
                     (or (overlay-get (cea-view-test--overlay-for thread)
                                      'after-string)
                         "")))
        ;; Content changes on disk; the revert's attach must badge it
        ;; immediately.
        (cea-test-file-lines "rb.el" '("ctx a" "rewritten" "ctx b"))
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)
        (should (string-match-p
                 "STALE"
                 (or (overlay-get (cea-view-test--overlay-for thread)
                                  'after-string)
                     "")))
        ;; And a rescue drops the badge on its own render just as
        ;; immediately.
        (cea-test-file-lines "rb.el" '("ctx a" "the body" "ctx b"))
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)
        (should-not (string-match-p
                     "STALE"
                     (or (overlay-get (cea-view-test--overlay-for thread)
                                      'after-string)
                         "")))))))

(ert-deftest cea-view-stale-latch-survives-visit-and-kill ()
  "A stale thread stays stale through visit, flush and kill.
Only a rescue (original content back), an explicit reanchor or a
root-text edit clears the latch -- never a mere visit."
  (cea-test-with-env
    (cea-test-file-lines "lt.el" '("ctx a" "the subject" "ctx b"))
    (let ((thread (cea-test-api-create "lt.el" 2 2 :text "about it")))
      ;; The subject is rewritten while no buffer is watching.
      (cea-test-file-lines "lt.el" '("ctx a" "rewritten body" "ctx b"))
      (cea-view-test--with-buffer "lt.el"
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (eq 'stale (plist-get anchor :state)))
          (should (= 2 (plist-get anchor :start-line)))
          ;; The latch preserves the original content for the rescue.
          (should (equal "the subject" (plist-get anchor :text))))
        ;; A flush while visiting must not re-bless it.
        (claude-emacs-annotate-view-flush (current-buffer)))
      ;; Still stale after the kill flush.
      (should (eq 'stale (plist-get (cea-view-test--store-anchor thread)
                                    :state)))
      ;; Rescue: the original content returns; the next visit clears it.
      (cea-test-file-lines "lt.el" '("ctx a" "the subject" "ctx b"))
      (cea-view-test--with-buffer "lt.el"
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (eq 'fresh (plist-get anchor :state)))
          (should (= 2 (plist-get anchor :start-line))))))))

;;;; The original bug, simulated: external edit + revert

(ert-deftest cea-view-external-edit-and-revert-reanchors ()
  "External write shifts content; revert re-anchors from content.
This is the exact production failure being designed out: an agent
edits the file on disk while a buffer shows it with live overlays."
  (cea-test-with-env
    (cea-test-file-lines "d.el" '("aa" "bb" "cc" "dd"))
    (let ((thread (cea-test-api-create "d.el" 3 3 :text "about cc")))
      (cea-view-test--with-buffer "d.el"
        (should (= 3 (line-number-at-pos
                      (overlay-start (cea-view-test--overlay-for thread))
                      t)))
        ;; External writer inserts three lines on top (as a formatter or
        ;; an agent edit would), then the buffer reverts silently.
        ;; PRESERVE-MODES matches `auto-revert-mode', the production
        ;; revert path; manual reverts re-enter through the global
        ;; mode's `after-change-major-mode-hook' instead.
        (cea-test-file-lines "d.el" '("x1" "x2" "x3" "aa" "bb" "cc" "dd"))
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should overlay)
          (should (= 6 (line-number-at-pos (overlay-start overlay) t))))
        ;; And the store followed.
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (= 6 (plist-get anchor :start-line)))
          (should (eq 'fresh (plist-get anchor :state))))))))

(ert-deftest cea-view-revert-with-unsaved-edits-loses-nothing ()
  (cea-test-with-env
    (cea-test-file-lines "e.el" '("l1" "l2" "l3" "l4"))
    (let ((thread (cea-test-api-create "e.el" 3 3 :text "about l3")))
      (cea-view-test--with-buffer "e.el"
        ;; Unsaved buffer edit above the annotation drifts the overlay.
        (goto-char (point-min))
        (insert "unsaved line\n")
        ;; The buffer reverts to disk content (discarding the edit).
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should overlay)
          (should (= 3 (line-number-at-pos (overlay-start overlay) t))))
        (should (claude-emacs-annotate-store-thread
                 (claude-emacs-annotate-store-get cea-test-project)
                 (claude-emacs-annotate-thread-id thread)))))))

;;;; Flush

(ert-deftest cea-view-flush-updates-store-after-buffer-edit ()
  (cea-test-with-env
    (cea-test-file-lines "f.el" '("m1" "m2" "m3"))
    (let ((thread (cea-test-api-create "f.el" 2 2)))
      (cea-view-test--with-buffer "f.el"
        (goto-char (point-min))
        (insert "top line\n")
        ;; The idle timer never fires in batch: flush directly.
        (claude-emacs-annotate-view-flush (current-buffer))
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (= 3 (plist-get anchor :start-line)))
          (should (eq 'fresh (plist-get anchor :state)))
          (should (equal '("top line" "m1") (plist-get anchor :before))))))))

(ert-deftest cea-view-flush-marks-deleted-region-stale ()
  (cea-test-with-env
    (cea-test-file-lines "g.el" '("k1" "k2" "k3" "k4"))
    (let ((thread (cea-test-api-create "g.el" 2 3)))
      (cea-view-test--with-buffer "g.el"
        ;; Delete the whole annotated region.
        (goto-char (point-min))
        (forward-line 1)
        (delete-region (point) (progn (forward-line 2) (point)))
        (claude-emacs-annotate-view-flush (current-buffer))
        ;; Record kept, latched stale, original text preserved.
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (eq 'stale (plist-get anchor :state)))
          (should (equal "k2\nk3" (plist-get anchor :text))))))))

(ert-deftest cea-view-mutations-flush-pending-buffers-first ()
  "The store's before-mutate hook must flush live positions."
  (cea-test-with-env
    (cea-test-file-lines "h.el" '("p1" "p2" "p3"))
    (let ((thread (cea-test-api-create "h.el" 2 2)))
      (cea-view-test--with-buffer "h.el"
        (goto-char (point-min))
        (insert "pushed\n")
        ;; No manual flush: the API mutation must see fresh lines.
        (claude-emacs-annotate-api-set-status
         cea-test-project
         (claude-emacs-annotate-thread-id thread) "resolved")
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (= 3 (plist-get anchor :start-line))))))))

;;;; Events refresh live buffers

(ert-deftest cea-view-api-mutation-refreshes-overlay-display ()
  (cea-test-with-env
    (cea-test-file-lines "i.el" '("q1" "q2"))
    (let ((thread (cea-test-api-create "i.el" 1 1 :text "old prose")))
      (cea-view-test--with-buffer "i.el"
        (let ((claude-emacs-annotate-inline t))
          (claude-emacs-annotate-view-attach)
          (claude-emacs-annotate-api-edit-root-text
           cea-test-project
           (claude-emacs-annotate-thread-id thread) "new prose")
          (let* ((overlay (cea-view-test--overlay-for thread))
                 (inline (overlay-get overlay 'after-string)))
            (should inline)
            (should (string-match-p "new prose" inline))
            (should-not (string-match-p "old prose" inline))))))))

(ert-deftest cea-view-delete-event-removes-overlay ()
  (cea-test-with-env
    (cea-test-file-lines "j.el" '("r1" "r2"))
    (let ((thread (cea-test-api-create "j.el" 1 1)))
      (cea-view-test--with-buffer "j.el"
        (should (cea-view-test--overlay-for thread))
        (claude-emacs-annotate-api-delete
         cea-test-project (claude-emacs-annotate-thread-id thread))
        (should-not (cea-view-test--overlay-for thread))))))

;;;; Inline rendering (pure string assertions)

(ert-deftest cea-view-inline-renders-thread-tree ()
  (cea-test-with-env
    (cea-test-file-lines "k.el" '("s1" "s2"))
    (let* ((thread (cea-test-api-create "k.el" 1 1
                                        :text "root prose here"
                                        :tag "changes"))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-reply
       cea-test-project id
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment thread))
       "a reply from the user" :author "Jane Doe")
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (stored (claude-emacs-annotate-store-thread store id))
             (rendered (claude-emacs-annotate--view-inline-string stored)))
        (should (string-match-p "open" rendered))
        (should (string-match-p "changes" rendered))
        (should (string-match-p "root prose here" rendered))
        (should (string-match-p "↳" rendered))
        (should (string-match-p "Jane Doe" rendered))
        (should (string-match-p "a reply from the user" rendered))
        (should (string-match-p "┌" rendered))
        (should (string-match-p "└" rendered))))))

(ert-deftest cea-view-inline-gutter-structure-and-faces ()
  "Left-gutter box: aligned by construction, prose never dimmed."
  (cea-test-with-env
    (cea-test-file-lines "gs.el" '("x1"))
    (let* ((thread (cea-test-api-create "gs.el" 1 1
                                        :text "prose body here"
                                        :tag "changes"))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-reply
       cea-test-project id
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment thread))
       "a reply" :author "Jane Doe")
      (let* ((stored (claude-emacs-annotate-store-thread
                      (claude-emacs-annotate-store-get cea-test-project) id))
             (rendered (claude-emacs-annotate--view-inline-string stored))
             (lines (split-string rendered "\n")))
        ;; Structure: header row, gutter rows, short footer — and no
        ;; right-hand border anywhere (alignment by construction).
        (should (string-prefix-p "┌─ ✎" (car lines)))
        (dolist (line (butlast (cdr lines)))
          (should (string-prefix-p "│ " line)))
        (should (equal "└─" (car (last lines))))
        (dolist (line lines)
          (should-not (string-suffix-p "│" line)))
        ;; Faces: comment text is doc-colored, meta is dimmed.
        (let* ((text-row (seq-find (lambda (line)
                                     (string-match-p "prose body here" line))
                                   lines))
               (text-pos (string-match "prose" text-row)))
          (should (eq 'claude-emacs-annotate-inline-face
                      (get-text-property text-pos 'face text-row))))
        (let* ((meta-row (seq-find (lambda (line) (string-match-p "↳" line))
                                   lines))
               (meta-pos (string-match "↳" meta-row)))
          (should (eq 'claude-emacs-annotate-inline-meta-face
                      (get-text-property meta-pos 'face meta-row))))
        ;; The header carries the header face.
        (let ((header-pos (string-match "✎" (car lines))))
          (should (eq 'claude-emacs-annotate-inline-header-face
                      (get-text-property header-pos 'face (car lines)))))))))

(ert-deftest cea-view-inline-reply-meta-lightened ()
  "Reply author/time lines ride a foreground lighter than the meta face's."
  (cea-test-with-env
    (cea-test-file-lines "mf.el" '("z1"))
    (let* ((thread (cea-test-api-create "mf.el" 1 1 :text "root text"))
           (id (claude-emacs-annotate-thread-id thread)))
      (claude-emacs-annotate-api-reply
       cea-test-project id
       (claude-emacs-annotate-comment-id
        (claude-emacs-annotate-thread-root-comment thread))
       "a reply" :author "Jane Doe")
      ;; Batch has no real colors: pin the meta face's foreground, and
      ;; parse hex specs exactly -- frameless `color-values' snaps them
      ;; to the built-in tty palette, which would test the palette
      ;; approximation instead of the lightening arithmetic.
      (cl-letf (((symbol-function 'face-foreground)
                 (lambda (&rest _) "#5b6268"))
                ((symbol-function 'color-values)
                 (lambda (spec &optional _frame)
                   (tty-color-standard-values spec))))
        (pcase-let* ((claude-emacs-annotate--view-shade-cache nil)
                     (stored (claude-emacs-annotate-store-thread
                              (claude-emacs-annotate-store-get cea-test-project)
                              id))
                     (`(,_header . ,body)
                      (claude-emacs-annotate-view-thread-lines stored 70))
                     (meta-row (seq-find (lambda (line)
                                           (string-match-p "↳" line))
                                         body))
                     (meta-pos (string-match "↳" meta-row))
                     (face (get-text-property meta-pos 'face meta-row)))
          ;; Front entry: a foreground strictly lighter than the pinned
          ;; one; the meta face itself still rides behind it for slant.
          (should (consp face))
          (let ((foreground (plist-get (car face) :foreground)))
            (should (stringp foreground))
            (should-not (equal (downcase foreground) "#5b6268")))
          (should (memq 'claude-emacs-annotate-inline-meta-face face)))))))

(ert-deftest cea-view-shift-darkens-on-light-themes ()
  "Tint and meta shifts flip toward black on light theme backgrounds.
Lighten-only shading clamps light backgrounds into invisible white
and washes the meta foreground out; the direction must follow the
theme."
  (let ((claude-emacs-annotate--view-shade-cache nil)
        (theme-background "#fafafa"))
    (cl-letf (((symbol-function 'face-background)
               (lambda (&rest _) theme-background))
              ((symbol-function 'face-foreground)
               (lambda (&rest _) "#7f7f7f"))
              ((symbol-function 'color-values)
               (lambda (spec &optional _frame)
                 (tty-color-standard-values spec))))
      ;; Backgrounds darken instead of clamping into invisible white.
      (should (equal (color-darken-name
                      "#fafafa" claude-emacs-annotate-tint-percent)
                     (claude-emacs-annotate--view-tint-color)))
      (should (equal (color-darken-name
                      "#fafafa" claude-emacs-annotate-inline-tint-percent)
                     (claude-emacs-annotate--view-inline-tint-color)))
      ;; The meta foreground darkens toward black for contrast.
      (let ((light-face (claude-emacs-annotate--view-meta-face)))
        (should (equal (color-darken-name
                        "#7f7f7f"
                        claude-emacs-annotate-inline-meta-shift-percent)
                       (plist-get (car light-face) :foreground)))
        ;; Flipping the theme flips the direction -- through the same
        ;; cache, so direction must be part of the cache key.
        (setq theme-background "#282c34")
        (let ((dark-face (claude-emacs-annotate--view-meta-face)))
          (should (equal (color-lighten-name
                          "#7f7f7f"
                          claude-emacs-annotate-inline-meta-shift-percent)
                         (plist-get (car dark-face) :foreground)))
          (should-not (equal (plist-get (car light-face) :foreground)
                             (plist-get (car dark-face) :foreground))))))))

(ert-deftest cea-view-state-badges-name-staleness ()
  "Stale is the only badged state; fresh shows nothing."
  (should (equal "[STALE]"
                 (substring-no-properties
                  (claude-emacs-annotate--view-state-badge 'stale))))
  (should-not (claude-emacs-annotate--view-state-badge 'fresh)))

(ert-deftest cea-view-inline-box-lighter-than-region ()
  "The box panel uses its own tint, lighter than the region's."
  (cea-test-with-env
    (cea-test-file-lines "bg.el" '("y1"))
    (let ((thread (cea-test-api-create "bg.el" 1 1 :text "panel text")))
      ;; Batch has no real colors: pin the theme background, and parse
      ;; hex specs exactly -- frameless `color-values' snaps them to
      ;; the built-in tty palette, where a dark background can land on
      ;; pure black and collapse both tints to the same color.
      (cl-letf (((symbol-function 'face-background)
                 (lambda (&rest _) "#282c34"))
                ((symbol-function 'color-values)
                 (lambda (spec &optional _frame)
                   (tty-color-standard-values spec))))
        (let* ((claude-emacs-annotate--view-shade-cache nil)
               (region-tint (claude-emacs-annotate--view-tint-color))
               (panel-tint (claude-emacs-annotate--view-inline-tint-color))
               (rendered (claude-emacs-annotate--view-inline-string thread)))
          (should (stringp region-tint))
          (should (stringp panel-tint))
          (should-not (equal region-tint "#282c34"))
          ;; The panel is strictly lighter than the region tint.
          (should (> claude-emacs-annotate-inline-tint-percent
                     claude-emacs-annotate-tint-percent))
          (should-not (equal panel-tint region-tint))
          ;; Every char -- newlines included, so the fill reaches the
          ;; window edge -- carries the panel tint as its
          ;; HIGHEST-priority face, so no content face (e.g. one
          ;; inheriting `default', whose background is the plain buffer
          ;; color) can beat the panel behind the text.
          (dotimes (i (length rendered))
            (let* ((face (get-text-property i 'face rendered))
                   (front (if (and (consp face) (keywordp (car face)))
                              face
                            (car (ensure-list face)))))
              (should (equal (list :background panel-tint :extend t)
                             front)))))))))

(ert-deftest cea-view-inline-wraps-and-truncates ()
  (cea-test-with-env
    (cea-test-file-lines "l.el" '("t1"))
    (let* ((long-text (mapconcat (lambda (i) (format "paragraph %d" i))
                                 (number-sequence 1 40) "\n"))
           (thread (cea-test-api-create "l.el" 1 1 :text long-text))
           (claude-emacs-annotate-inline-max-lines 6))
      (let ((rendered (claude-emacs-annotate--view-inline-string thread)))
        (should (string-match-p "\\+[0-9]+ more" rendered))
        (should (< (length (split-string rendered "\n")) 15))))))

(ert-deftest cea-view-inline-shows-anchor-badges ()
  (cea-test-with-env
    (cea-test-file-lines "m.el" '("u1"))
    (let ((thread (cea-test-api-create "m.el" 1 1)))
      (plist-put (claude-emacs-annotate-thread-anchor thread)
                 :state 'stale)
      (should (string-match-p "STALE"
                              (claude-emacs-annotate--view-inline-string
                               thread))))))

;;;; Navigation and commands

(ert-deftest cea-view-next-previous-cycle ()
  (cea-test-with-env
    (cea-test-file-lines "n.el" '("v1" "v2" "v3" "v4" "v5"))
    (cea-test-api-create "n.el" 2 2)
    (cea-test-api-create "n.el" 4 4)
    (cea-view-test--with-buffer "n.el"
      (goto-char (point-min))
      (claude-emacs-annotate-next)
      (should (= 2 (line-number-at-pos (point) t)))
      (claude-emacs-annotate-next)
      (should (= 4 (line-number-at-pos (point) t)))
      ;; Wraps around.
      (claude-emacs-annotate-next)
      (should (= 2 (line-number-at-pos (point) t)))
      (claude-emacs-annotate-previous)
      (should (= 4 (line-number-at-pos (point) t))))))

(ert-deftest cea-view-create-anchors-from-buffer-content ()
  (cea-test-with-env
    (cea-test-file-lines "o.el" '("w1" "w2" "w3"))
    (cea-view-test--with-buffer "o.el"
      ;; Unsaved edit first: creation must anchor to BUFFER content.
      (goto-char (point-min))
      (insert "fresh top\n")
      (goto-char (point-min))
      (forward-line 2)                  ; on "w2", now line 3
      (claude-emacs-annotate-view-create-thread
       (line-number-at-pos (point) t) (line-number-at-pos (point) t)
       "about w2" nil)
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (threads (claude-emacs-annotate-store-threads-for-file
                       store "o.el"))
             (anchor (claude-emacs-annotate-thread-anchor (car threads))))
        (should (= 1 (length threads)))
        (should (= 3 (plist-get anchor :start-line)))
        (should (equal "w2" (plist-get anchor :text)))
        ;; And an overlay is live in the buffer.
        (should (= 1 (length (claude-emacs-annotate--view-overlays))))))))

(ert-deftest cea-view-create-command-composes-in-buffer ()
  "The create command opens a compose buffer, never the echo area."
  (cea-test-with-env
    (cea-test-file-lines "cc.el" '("a1" "a2" "a3"))
    (cea-view-test--with-buffer "cc.el"
      (goto-char (point-min))
      (forward-line 1)                  ; on "a2", line 2
      ;; Only the short tag prompt may use the minibuffer.
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
        (claude-emacs-annotate-create (line-beginning-position)
                                      (line-end-position)))
      (let ((edit (get-buffer "*claude-annotation new: cc.el:2*")))
        (should edit)
        (unwind-protect
            (with-current-buffer edit
              (should (derived-mode-p 'claude-emacs-annotate-edit-mode))
              (insert "composed prose\nsecond line")
              (claude-emacs-annotate-edit-commit))
          (when (buffer-live-p edit) (kill-buffer edit))))
      (let* ((store (claude-emacs-annotate-store-get cea-test-project))
             (threads (claude-emacs-annotate-store-threads-for-file
                       store "cc.el"))
             (anchor (claude-emacs-annotate-thread-anchor (car threads))))
        (should (= 1 (length threads)))
        (should (= 2 (plist-get anchor :start-line)))
        (should (equal "a2" (plist-get anchor :text)))
        (should (equal "composed prose\nsecond line"
                       (claude-emacs-annotate-comment-text
                        (claude-emacs-annotate-thread-root-comment
                         (car threads)))))))))

(ert-deftest cea-view-create-rejects-invalid-tag-before-composing ()
  (cea-test-with-env
    (cea-test-file-lines "vt.el" '("b1" "b2"))
    (cea-view-test--with-buffer "vt.el"
      (goto-char (point-min))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "bad tag!")))
        (should-error (claude-emacs-annotate-create
                       (line-beginning-position) (line-end-position))
                      :type 'user-error))
      ;; No compose buffer was opened.
      (should-not (get-buffer "*claude-annotation new: vt.el:1*")))))

(ert-deftest cea-view-reanchor-repairs-stale ()
  (cea-test-with-env
    (cea-test-file-lines "p.el" '("z1" "z2" "z3"))
    (let ((thread (cea-test-api-create "p.el" 2 2 :text "about z2")))
      ;; Rewrite the file entirely: the anchor goes stale.
      (cea-test-file-lines "p.el" '("completely" "new" "content" "here"))
      (cea-view-test--with-buffer "p.el"
        (should (eq 'stale
                    (plist-get (cea-view-test--store-anchor thread) :state)))
        ;; Repair: re-pin the thread to lines 3..3.
        (claude-emacs-annotate-view-reanchor-thread
         (claude-emacs-annotate-thread-id thread) 3 3)
        (let ((anchor (cea-view-test--store-anchor thread)))
          (should (eq 'fresh (plist-get anchor :state)))
          (should (= 3 (plist-get anchor :start-line)))
          (should (equal "content" (plist-get anchor :text))))
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should (= 3 (line-number-at-pos (overlay-start overlay) t))))))))

(ert-deftest cea-view-mode-off-detaches ()
  (cea-test-with-env
    (cea-test-file-lines "q.el" '("y1" "y2"))
    (cea-test-api-create "q.el" 1 1)
    (cea-view-test--with-buffer "q.el"
      (should (= 1 (length (claude-emacs-annotate--view-overlays))))
      (claude-emacs-annotate-mode -1)
      (should (= 0 (length (claude-emacs-annotate--view-overlays)))))))

(ert-deftest cea-view-whole-file-anchor-spans-buffer ()
  (cea-test-with-env
    (cea-test-file-lines "r.el" '("f1" "f2" "f3"))
    (let ((thread (claude-emacs-annotate-api-create
                   cea-test-project
                   '(:file "r.el" :kind file :text "whole"
                     :author "claude-code"))))
      (cea-view-test--with-buffer "r.el"
        (let ((overlay (cea-view-test--overlay-for thread)))
          (should overlay)
          (should (= (point-min) (overlay-start overlay)))
          ;; Editing the buffer never marks a whole-file thread stale.
          (goto-char (point-min))
          (insert "prefix\n")
          (claude-emacs-annotate-view-flush (current-buffer))
          (should (eq 'fresh
                      (plist-get (cea-view-test--store-anchor thread)
                                 :state))))))))

(ert-deftest cea-view-choose-thread-disambiguates-duplicates ()
  "Overlapping threads with identical summaries are all selectable.
Bare summary keys make `assoc' return the first thread for every
choice; duplicate keys must carry a distinguishing suffix."
  (cea-test-with-env
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (t1 (cea-test-insert store
                                (cea-test-make-thread "dup.el" "same text")))
           (t2 (cea-test-insert store
                                (cea-test-make-thread "dup.el" "same text"))))
      (should (eq t1 (claude-emacs-annotate--view-choose-thread
                      "Annotation: " (list t1))))
      (let ((chosen
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (_prompt collection &rest _)
                          (car (nth 1 collection)))))
               (claude-emacs-annotate--view-choose-thread
                "Annotation: " (list t1 t2)))))
        (should (eq chosen t2)))
      ;; Short foreign ids must not break the disambiguating suffix.
      (plist-put t1 :id "t1")
      (plist-put t2 :id "t2")
      (let ((chosen
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (_prompt collection &rest _)
                          (car (nth 1 collection)))))
               (claude-emacs-annotate--view-choose-thread
                "Annotation: " (list t1 t2)))))
        (should (eq chosen t2))))))

(ert-deftest cea-view-reanchor-region-ending-at-point-max ()
  "Re-anchoring a region that reaches point-max must not signal.
The BOL-exclusive end rule and the phantom-line clamp must match
`claude-emacs-annotate-create': a trailing newline's phantom line is
not part of the region."
  (cea-test-with-env
    (cea-test-project-file "r.el" "one\ntwo\nthree\n")
    (let* ((store (claude-emacs-annotate-store-get cea-test-project))
           (thread (cea-test-make-thread
                    "r.el" "note"
                    :anchor '(:kind region :start-line 1 :end-line 1
                              :line-count 1 :text "vanished"
                              :state stale))))
      (cea-test-insert store thread)
      (let ((buffer (find-file-noselect
                     (expand-file-name "r.el" cea-test-project))))
        (unwind-protect
            (with-current-buffer buffer
              (claude-emacs-annotate-mode 1)
              (goto-char (point-min))
              (forward-line 1)
              (claude-emacs-annotate-reanchor (point) (point-max))
              (let* ((updated (claude-emacs-annotate-store-thread
                               store
                               (claude-emacs-annotate-thread-id thread)))
                     (anchor (claude-emacs-annotate-thread-anchor updated)))
                (should (eq 'fresh (plist-get anchor :state)))
                (should (= 2 (plist-get anchor :start-line)))
                (should (= 3 (plist-get anchor :end-line)))))
          (kill-buffer buffer))))))

(ert-deftest cea-view-mode-double-enable-keeps-inline-toggle ()
  "A redundant enable must not reset the inline toggle."
  (cea-test-with-env
    (cea-test-project-file "h.el" "one\ntwo\n")
    (let ((buffer (find-file-noselect
                   (expand-file-name "h.el" cea-test-project))))
      (unwind-protect
          (with-current-buffer buffer
            (claude-emacs-annotate-mode 1)
            (should claude-emacs-annotate-mode)
            (setq claude-emacs-annotate-inline nil)
            (claude-emacs-annotate-mode 1)
            (should-not claude-emacs-annotate-inline))
        (kill-buffer buffer)))))

(provide 'claude-emacs-annotate-view-test)
;;; claude-emacs-annotate-view-test.el ends here
