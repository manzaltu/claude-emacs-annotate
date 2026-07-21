;;; claude-emacs-annotate-view.el --- Overlays as a view over the store  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; The live-buffer layer.  Overlays carry nothing but a thread id --
;; all data lives in the store -- so losing overlays can never lose
;; annotations, only position freshness, which the anchor engine
;; recovers by content matching whenever a buffer attaches (find-file,
;; after-revert, external reload).
;;
;; The flush engine mirrors live overlay drift back into the store:
;; debounced after edits, synchronously before saves, reverts, buffer
;; kills and every store mutation.  `revert-buffer' -- including the
;; silent reverts of `global-auto-revert-mode' when files change on
;; disk underneath Emacs -- is bracketed by a flush/detach before and
;; a content-driven re-attach after; stored positions are never
;; trusted across a revert.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'color)
(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-anchor)
(require 'claude-emacs-annotate-api)

(declare-function claude-emacs-annotate--maybe-enable "claude-emacs-annotate")

;;;; Options and faces

(defcustom claude-emacs-annotate-display-style 'tint
  "How annotated regions are painted.
`tint' shades the default background (lighter on dark themes,
darker on light ones); `highlight' uses
`claude-emacs-annotate-highlight-face'."
  :type '(choice (const tint) (const highlight))
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-tint-percent 10
  "Percentage by which the tint style shifts the background.
Tints lighten the background on dark themes and darken it on light
ones."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-tint-hue 60
  "Hue of the region tint, in degrees on the color wheel.
The default of 60 is yellow; 120 is green, 240 blue.  Applied at
`claude-emacs-annotate-tint-saturation-percent' saturation."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-tint-saturation-percent 6
  "Saturation percentage of the region tint's hue.
The hue is applied at the exact lightness of the neutral
`claude-emacs-annotate-tint-percent' shade, so it changes the tint's
color, never its intensity.  Zero keeps the neutral tint."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-tint-percent 35
  "Percentage by which the inline box panel shifts the background.
Kept above `claude-emacs-annotate-tint-percent' so the thread box
stands out against the annotated region."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-meta-shift-percent 20
  "Percentage by which reply author/time foregrounds shift for contrast.
Lifts the meta lines away from the dim color they inherit -- toward
white on dark themes, toward black on light ones -- so they stay
readable on the inline panel background."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-default t
  "Whether buffers expose annotation threads inline by default."
  :type 'boolean
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-position 'below
  "Where the inline thread box renders relative to the region."
  :type '(choice (const below) (const above))
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-fill-column 72
  "Wrap width for inline thread rendering."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-inline-max-lines 20
  "Maximum body lines an inline thread box shows before truncating."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-fringe-indicator 'left-fringe
  "Fringe carrying the per-thread expand/collapse indicator, nil for none.
The indicator marks the last line of each annotated region: a plus
sign while the thread box is collapsed, a minus sign while it is
expanded (`claude-emacs-annotate-toggle-inline-at-point')."
  :type '(choice (const left-fringe) (const right-fringe)
                 (const :tag "No indicator" nil))
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-flush-idle-delay 1.0
  "Idle seconds after an edit before overlay drift flushes to the store."
  :type 'number
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-highlight-face
  '((t :inherit highlight :extend t))
  "Face for annotated regions under the `highlight' display style."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-inline-face
  '((t :inherit default))
  "Face for the comment text of inline thread boxes."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-inline-header-face
  '((t :inherit font-lock-doc-face))
  "Face for the status/tags header of inline thread boxes."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-inline-meta-face
  '((t :inherit shadow :slant italic))
  "Face for reply author/time lines in inline thread boxes."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-inline-border-face
  '((t :inherit shadow :weight light))
  "Face for inline thread box borders."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-fringe-face
  '((t :inherit success))
  "Face for the per-thread expand/collapse fringe indicator."
  :group 'claude-emacs-annotate)

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'claude-emacs-annotate-fringe-plus
    [#b00000000
     #b00011000
     #b00011000
     #b01111110
     #b01111110
     #b00011000
     #b00011000
     #b00000000])
  (define-fringe-bitmap 'claude-emacs-annotate-fringe-minus
    [#b00000000
     #b00000000
     #b00000000
     #b01111110
     #b01111110
     #b00000000
     #b00000000
     #b00000000]))

;;;; State

(defvar claude-emacs-annotate-mode)

(defvar-local claude-emacs-annotate--view-root nil
  "Canonical project root of this annotated buffer.")

(defvar-local claude-emacs-annotate--view-relative-file nil
  "Project-relative file name of this annotated buffer.")

(defvar-local claude-emacs-annotate--view-pending-flush nil
  "Non-nil when this buffer has unflushed overlay drift.")

(defvar-local claude-emacs-annotate-inline nil
  "Non-nil when this buffer renders annotation threads inline.")

(defvar-local claude-emacs-annotate--view-inline-overrides nil
  "Alist of (THREAD-ID . SHOWN) per-thread inline overrides.
Entries flip single threads away from the buffer-wide
`claude-emacs-annotate-inline' default; the buffer-wide toggle
clears them.")

(defvar claude-emacs-annotate--view-pending-buffers nil
  "Buffers whose overlay drift awaits a flush.")

(defvar claude-emacs-annotate--view-flush-timer nil
  "One-shot idle timer draining the pending flush list.")

(defvar claude-emacs-annotate--view-suppress-events nil
  "Non-nil while the view itself mutates the store.
The view's change-event handler skips refreshes it caused, breaking
the attach-persist-refresh cycle after one pass.")

(defvar claude-emacs-annotate--view-shade-cache nil
  "Alist caching shifted colors: ((COLOR . DELTA) . SHIFTED).
DELTA is the shift percentage, its sign carrying the direction:
positive toward white, negative toward black.")

;;;; Overlay bookkeeping

(defun claude-emacs-annotate--view-overlays (&optional buffer)
  "Return BUFFER's annotation overlays (default: current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (seq-filter (lambda (overlay)
                    (overlay-get overlay 'claude-emacs-annotate-id))
                  (overlays-in (point-min) (point-max))))))

(defun claude-emacs-annotate--view-overlay-for (thread-id)
  "Return this buffer's overlay carrying THREAD-ID, or nil."
  (seq-find (lambda (overlay)
              (equal (overlay-get overlay 'claude-emacs-annotate-id)
                     thread-id))
            (claude-emacs-annotate--view-overlays)))

(defun claude-emacs-annotate--view-overlays-at (position)
  "Return annotation overlays at POSITION, most specific first."
  (sort (seq-filter (lambda (overlay)
                      (overlay-get overlay 'claude-emacs-annotate-id))
                    (overlays-at position))
        (lambda (a b)
          (< (- (overlay-end a) (overlay-start a))
             (- (overlay-end b) (overlay-start b))))))

(defun claude-emacs-annotate--view-store ()
  "Return this buffer's project store, or nil when none exists yet."
  (and claude-emacs-annotate--view-root
       (claude-emacs-annotate-store-get claude-emacs-annotate--view-root t)))

(defun claude-emacs-annotate--view-line-bounds (start-line end-line)
  "Return buffer positions (START . END) spanning START-LINE..END-LINE."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- start-line))
      (let ((start (point)))
        (goto-char (point-min))
        (forward-line (1- end-line))
        (cons start (line-end-position))))))

;;;; Rendering

(defun claude-emacs-annotate--view-fill (text width)
  "Return TEXT wrapped at WIDTH as a list of lines."
  (with-temp-buffer
    (insert text)
    (let ((fill-column (max 20 width)))
      (fill-region (point-min) (point-max)))
    (split-string (buffer-string) "\n")))

(defun claude-emacs-annotate--view-time (timestamp)
  "Return TIMESTAMP rendered as a short local time, or an empty string."
  (condition-case nil
      (format-time-string "%m/%d %H:%M" (date-to-time timestamp))
    (error "")))

(defun claude-emacs-annotate--view-state-badge (state)
  "Return the badge string for anchor STATE, or nil.
Stale is the only badged state -- the thread's content changed or is
gone -- and the badge persists until the thread is re-pinned or its
content returns."
  (when (eq state 'stale)
    (propertize "[STALE]" 'face 'claude-emacs-annotate-stale-face)))

(defun claude-emacs-annotate-view-thread-lines (thread width)
  "Render THREAD as (HEADER . BODY-LINES) wrapped at WIDTH.
Used by the inline boxes; the thread buffers render their own richer
layout in `claude-emacs-annotate--thread-render'.  The header and
every body line carry their display faces: comment text uses
`claude-emacs-annotate-inline-face', reply author/time lines
`claude-emacs-annotate-inline-meta-face' with a lightened foreground
riding in front when the display provides one."
  (let* ((state (plist-get (claude-emacs-annotate-thread-anchor thread)
                           :state))
         (badge (claude-emacs-annotate--view-state-badge state))
         (tags (claude-emacs-annotate-thread-tags thread))
         (header (concat (propertize
                          (concat (format "✎ [%s/%s]"
                                          (claude-emacs-annotate-thread-status
                                           thread)
                                          (claude-emacs-annotate-thread-priority
                                           thread))
                                  (when tags
                                    (concat " " (string-join tags ","))))
                          'face 'claude-emacs-annotate-inline-header-face)
                         (when badge (concat " " badge))))
         (body nil))
    (cl-labels
        ((render (node depth)
           (pcase-let ((`(,comment . ,children) node))
             (let* ((indent (make-string (* 2 depth) ?\s))
                    (text-indent (if (> depth 0) (concat indent "  ") indent)))
               (when (> depth 0)
                 (push (propertize
                        (format "%s↳ %s (%s)"
                                indent
                                (claude-emacs-annotate-comment-author comment)
                                (claude-emacs-annotate--view-time
                                 (claude-emacs-annotate-comment-timestamp
                                  comment)))
                        'face (claude-emacs-annotate--view-meta-face))
                       body))
               (dolist (line (claude-emacs-annotate--view-fill
                              (claude-emacs-annotate-comment-text comment)
                              (- width (length text-indent))))
                 (push (propertize (concat text-indent line)
                                   'face 'claude-emacs-annotate-inline-face)
                       body))
               (dolist (child children)
                 (render child (1+ depth)))))))
      (dolist (node (claude-emacs-annotate-comment-tree
                     (claude-emacs-annotate-thread-comments thread)))
        (render node 0)))
    (cons header (nreverse body))))

(defun claude-emacs-annotate--view-inline-string (thread)
  "Render THREAD as a left-gutter inline block.
Rows share only the gutter prefix, never a right-hand border, so
alignment holds regardless of glyph widths in the comment text."
  (pcase-let* ((`(,header . ,body)
                (claude-emacs-annotate-view-thread-lines
                 thread claude-emacs-annotate-inline-fill-column))
               (max-lines claude-emacs-annotate-inline-max-lines)
               (border 'claude-emacs-annotate-inline-border-face))
    (when (> (length body) max-lines)
      (setq body (append (seq-take body max-lines)
                         (list (propertize
                                (format "… +%d more"
                                        (- (length body) max-lines))
                                'face
                                (claude-emacs-annotate--view-meta-face))))))
    (let ((rendered
           (string-join
            (append (list (concat (propertize "┌─ " 'face border) header))
                    (mapcar (lambda (line)
                              (concat (propertize "│ " 'face border) line))
                            body)
                    (list (propertize "└─" 'face border)))
            "\n")))
      ;; The panel tint as a background over every char -- the
      ;; newlines carry it too, so with :extend it fills each row to
      ;; the window edge; lighter than the region tint so the box
      ;; stands out against the annotated lines.
      ;; Prepended (highest priority): content faces inheriting
      ;; `default' resolve the plain buffer background, which must not
      ;; punch black holes into the panel behind the text.
      (when-let* ((background
                   (claude-emacs-annotate--view-inline-tint-color)))
        (add-face-text-property 0 (length rendered)
                                (list :background background :extend t)
                                nil rendered))
      rendered)))

(defun claude-emacs-annotate--view-summary (thread)
  "Return a one-line summary of THREAD for the echo area."
  (let ((root (claude-emacs-annotate-thread-root-comment thread)))
    (format "[%s/%s]%s %s · %s"
            (claude-emacs-annotate-thread-status thread)
            (claude-emacs-annotate-thread-priority thread)
            (let ((tags (claude-emacs-annotate-thread-tags thread)))
              (if tags (concat " " (string-join tags ",")) ""))
            (claude-emacs-annotate-thread-root-author thread)
            (car (split-string
                  (or (claude-emacs-annotate-comment-text root) "")
                  "\n")))))

(defun claude-emacs-annotate--view-dark-theme-p ()
  "Return non-nil when the theme background is dark.
Dark backgrounds shift colors toward white, light ones toward
black.  An unresolvable background counts as dark, keeping the
historical lighten-only behavior on displays without color
information."
  (let* ((background (face-background 'default nil t))
         (rgb (and (stringp background)
                   (color-defined-p background)
                   (color-name-to-rgb background))))
    (or (null rgb) (color-dark-p rgb))))

(defun claude-emacs-annotate--view-shift (color percent)
  "Return COLOR shifted by PERCENT for contrast, or nil.
Shifts toward white on dark theme backgrounds and toward black on
light ones, so tints and lifted foregrounds keep their contrast on
both kinds of themes.  A nil argument, an undefined COLOR or a
computation failure all yield nil.  Results are cached in
`claude-emacs-annotate--view-shade-cache'."
  (when (and percent (stringp color) (color-defined-p color))
    (let* ((delta (if (claude-emacs-annotate--view-dark-theme-p)
                      percent
                    (- percent)))
           (key (cons color delta))
           (cached (assoc key claude-emacs-annotate--view-shade-cache)))
      (if cached
          (cdr cached)
        (let ((shifted (condition-case nil
                           (color-lighten-name color delta)
                         (error nil))))
          (push (cons key shifted)
                claude-emacs-annotate--view-shade-cache)
          shifted)))))

(defun claude-emacs-annotate--view-shade (percent)
  "Return the default background shifted by PERCENT, or nil."
  (claude-emacs-annotate--view-shift
   (face-background 'default nil t) percent))

(defun claude-emacs-annotate--view-meta-face ()
  "Return the face for reply author/time and truncation lines.
When the meta face's foreground can be shifted for contrast, the
shifted foreground rides in front of the face; otherwise the plain
face."
  (let ((lifted (claude-emacs-annotate--view-shift
                 (face-foreground
                  'claude-emacs-annotate-inline-meta-face nil t)
                 claude-emacs-annotate-inline-meta-shift-percent)))
    (if lifted
        (list (list :foreground lifted)
              'claude-emacs-annotate-inline-meta-face)
      'claude-emacs-annotate-inline-meta-face)))

(defun claude-emacs-annotate--view-rehue (color hue percent)
  "Return COLOR re-hued to HUE degrees at PERCENT saturation.
Only the hue and saturation move; COLOR's lightness is kept, so the
tint's intensity never changes.  A nil or undefined COLOR yields
nil; a zero PERCENT yields COLOR unchanged."
  (cond ((not (and (stringp color) (color-defined-p color))) nil)
        ((zerop percent) color)
        (t (pcase-let* ((`(,red ,green ,blue) (color-name-to-rgb color))
                        (`(,_hue ,_saturation ,lightness)
                         (color-rgb-to-hsl red green blue)))
             (apply #'color-rgb-to-hex
                    (append (color-hsl-to-rgb (/ hue 360.0)
                                              (/ percent 100.0)
                                              lightness)
                            (list 2)))))))

(defun claude-emacs-annotate--view-tint-color ()
  "Return the annotated region's tint color, or nil when unavailable.
The default background shifted for contrast, then re-hued per
`claude-emacs-annotate-tint-hue' so annotated lines read as
annotated at a glance."
  (claude-emacs-annotate--view-rehue
   (claude-emacs-annotate--view-shade claude-emacs-annotate-tint-percent)
   claude-emacs-annotate-tint-hue
   claude-emacs-annotate-tint-saturation-percent))

(defun claude-emacs-annotate--view-inline-tint-color ()
  "Return the inline box panel's tint color, or nil when unavailable."
  (claude-emacs-annotate--view-shade
   claude-emacs-annotate-inline-tint-percent))

(defun claude-emacs-annotate--view-inline-shown-p (thread-id)
  "Return non-nil when THREAD-ID's box renders inline in this buffer."
  (let ((override (assoc thread-id
                         claude-emacs-annotate--view-inline-overrides)))
    (if override (cdr override) claude-emacs-annotate-inline)))

(defun claude-emacs-annotate--view-fringe-string (expanded)
  "Return the expand/collapse fringe indicator string, or nil.
EXPANDED selects the minus bitmap, collapsed the plus.  Nil when the
indicator is disabled or this Emacs has no fringe bitmaps."
  (when (and claude-emacs-annotate-fringe-indicator
             (fboundp 'define-fringe-bitmap))
    (propertize (if expanded "-" "+")
                'display (list claude-emacs-annotate-fringe-indicator
                               (if expanded
                                   'claude-emacs-annotate-fringe-minus
                                 'claude-emacs-annotate-fringe-plus)
                               'claude-emacs-annotate-fringe-face))))

(defun claude-emacs-annotate--view-decorate (overlay thread)
  "Paint OVERLAY for THREAD according to the display options.
The before/after strings are always assigned: per-thread toggles
re-decorate a live overlay, so collapsing must clear the box it
rendered.  The fringe indicator rides in the after-string, whose
position is the end of the region's last line."
  (let* ((expanded (claude-emacs-annotate--view-inline-shown-p
                    (claude-emacs-annotate-thread-id thread)))
         (above (eq claude-emacs-annotate-inline-position 'above))
         (box (and expanded
                   (claude-emacs-annotate--view-inline-string thread)))
         (indicator (claude-emacs-annotate--view-fringe-string expanded)))
    (overlay-put overlay 'face
                 (or (and (eq claude-emacs-annotate-display-style 'tint)
                          (when-let* ((color
                                       (claude-emacs-annotate--view-tint-color)))
                            (list :background color :extend t)))
                     'claude-emacs-annotate-highlight-face))
    (overlay-put overlay 'help-echo
                 (claude-emacs-annotate--view-summary thread))
    (overlay-put overlay 'before-string
                 (and box above (concat box "\n")))
    (overlay-put overlay 'after-string
                 (cond ((and box (not above))
                        (concat (or indicator "") "\n" box))
                       (indicator)))))

;;;; Attach / detach

(defun claude-emacs-annotate-view-detach (&optional buffer)
  "Delete BUFFER's annotation overlays (default: current buffer)."
  (dolist (overlay (claude-emacs-annotate--view-overlays buffer))
    (delete-overlay overlay)))

(defun claude-emacs-annotate--view-persist-anchors (store updates)
  "Persist pending anchor edits to STORE.
UPDATES is a reversed list of (ID . ANCHOR) conses.  Change events
stay suppressed during the write: the buffer that produced the drift
is already current, and re-attaching from its own flush would loop."
  (when updates
    (let ((claude-emacs-annotate--view-suppress-events t))
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (claude-emacs-annotate-store-update-anchors
          store (nreverse updates)))))))

(defun claude-emacs-annotate-view-attach (&optional buffer)
  "Rebuild BUFFER's overlays from the store by content matching.
Every thread of the buffer's file is resolved against current buffer
content; changed anchor states and positions are persisted in one
batched mutation BEFORE the overlays render, so each box shows this
attach's verdict rather than the previous one's.  A buffer whose
content still matches writes nothing."
  (with-current-buffer (or buffer (current-buffer))
    (when (and claude-emacs-annotate-mode
               claude-emacs-annotate--view-relative-file)
      (claude-emacs-annotate-view-detach)
      (when-let* ((store (claude-emacs-annotate--view-store)))
        (let (updates placements)
          (dolist (thread (claude-emacs-annotate-store-threads-for-file
                           store claude-emacs-annotate--view-relative-file))
            (let* ((anchor (claude-emacs-annotate-thread-anchor thread))
                   (resolution (claude-emacs-annotate-anchor-resolve anchor))
                   (adopted (claude-emacs-annotate-anchor-adopt
                             anchor resolution)))
              (unless (eq adopted anchor)
                (push (cons (claude-emacs-annotate-thread-id thread) adopted)
                      updates))
              (push (cons (claude-emacs-annotate-thread-id thread) resolution)
                    placements)))
          (claude-emacs-annotate--view-persist-anchors store updates)
          (dolist (placement (nreverse placements))
            ;; Re-fetch by id: the mutation above updated the stored
            ;; anchors, and its merge may even have removed a thread.
            (when-let* ((thread (claude-emacs-annotate-store-thread
                                 store (car placement))))
              (pcase-let ((`(,start . ,end)
                           (claude-emacs-annotate--view-line-bounds
                            (plist-get (cdr placement) :start-line)
                            (plist-get (cdr placement) :end-line))))
                (let ((overlay (make-overlay start end)))
                  (overlay-put overlay 'claude-emacs-annotate-id
                               (car placement))
                  (overlay-put overlay 'claude-emacs-annotate-root
                               claude-emacs-annotate--view-root)
                  (claude-emacs-annotate--view-decorate
                   overlay thread))))))))))

;;;; Flush engine

(defun claude-emacs-annotate-view-flush (&optional buffer)
  "Mirror BUFFER's overlay drift back into the store.
Dead or zero-width overlays mark their thread's anchor stale without
touching its recorded content.  Live overlays over fresh threads
recapture lines, text and context; stale threads are a latch -- only
their lines drift, never their content or state.  All deltas land in
one batched mutation; nothing changed means nothing written."
  (with-current-buffer (or buffer (current-buffer))
    (setq claude-emacs-annotate--view-pending-flush nil)
    (setq claude-emacs-annotate--view-pending-buffers
          (delq (current-buffer) claude-emacs-annotate--view-pending-buffers))
    (when (and claude-emacs-annotate-mode
               claude-emacs-annotate--view-relative-file)
      (when-let* ((store (claude-emacs-annotate--view-store)))
        (let (updates)
          (save-restriction
            (widen)
            (dolist (overlay (claude-emacs-annotate--view-overlays))
              (let* ((id (overlay-get overlay 'claude-emacs-annotate-id))
                     (thread (claude-emacs-annotate-store-thread store id))
                     (anchor (and thread
                                  (claude-emacs-annotate-thread-anchor
                                   thread))))
                (cond
                 ((null thread)
                  (delete-overlay overlay))
                 ((eq (plist-get anchor :kind) 'file))
                 ((= (overlay-start overlay) (overlay-end overlay))
                  (let ((latched (claude-emacs-annotate-anchor-latch-stale
                                  anchor)))
                    (unless (eq latched anchor)
                      (push (cons id latched) updates)))
                  (delete-overlay overlay))
                 (t
                  (let* ((start-line (line-number-at-pos
                                      (overlay-start overlay) t))
                         (end (overlay-end overlay))
                         (end-line (save-excursion
                                     (goto-char end)
                                     (if (and (bolp)
                                              (> end (overlay-start overlay)))
                                         (1- (line-number-at-pos end t))
                                       (line-number-at-pos end t))))
                         (updated
                          (if (eq 'stale (plist-get anchor :state))
                              ;; The latch: drift the lines, never
                              ;; recapture content or re-bless.
                              (let ((drifted (copy-sequence anchor)))
                                (setq drifted (plist-put drifted :start-line
                                                         start-line))
                                (plist-put drifted :end-line
                                           (max start-line end-line)))
                            (claude-emacs-annotate-anchor-capture
                             start-line (max start-line end-line)))))
                    (unless (equal updated anchor)
                      (push (cons id updated) updates))))))))
          (claude-emacs-annotate--view-persist-anchors store updates))))))

(defun claude-emacs-annotate--view-after-change (_beg _end _len)
  "Mark this buffer's overlay drift for an idle flush."
  (unless claude-emacs-annotate--view-pending-flush
    (setq claude-emacs-annotate--view-pending-flush t)
    (cl-pushnew (current-buffer) claude-emacs-annotate--view-pending-buffers)
    (unless (timerp claude-emacs-annotate--view-flush-timer)
      (setq claude-emacs-annotate--view-flush-timer
            (run-with-idle-timer claude-emacs-annotate-flush-idle-delay nil
                                 #'claude-emacs-annotate--view-flush-pending)))))

(defun claude-emacs-annotate--view-flush-pending ()
  "Flush every buffer with pending overlay drift."
  (setq claude-emacs-annotate--view-flush-timer nil)
  (dolist (buffer (copy-sequence claude-emacs-annotate--view-pending-buffers))
    (if (buffer-live-p buffer)
        (claude-emacs-annotate-view-flush buffer)
      (setq claude-emacs-annotate--view-pending-buffers
            (delq buffer claude-emacs-annotate--view-pending-buffers)))))

(defun claude-emacs-annotate--view-flush-project (store)
  "Flush pending buffers of STORE's project before a mutation."
  (let ((root (claude-emacs-annotate-store-root store)))
    (dolist (buffer (copy-sequence
                     claude-emacs-annotate--view-pending-buffers))
      (when (and (buffer-live-p buffer)
                 (equal (buffer-local-value 'claude-emacs-annotate--view-root
                                            buffer)
                        root))
        (claude-emacs-annotate-view-flush buffer)))))

;;;; Revert and kill brackets

(defun claude-emacs-annotate--view-flush-and-detach ()
  "Persist overlay drift, then drop the overlays about to die.
Runs before reverts and buffer kills; after a revert, re-attachment
matches the new content rather than trusting stored offsets."
  (claude-emacs-annotate-view-flush (current-buffer))
  (claude-emacs-annotate-view-detach))

;;;; Store events → live refresh

(defun claude-emacs-annotate--view-on-change (event)
  "Refresh live buffers affected by the store EVENT."
  (unless claude-emacs-annotate--view-suppress-events
    (let ((root (plist-get event :root))
          (files (plist-get event :files))
          (type (plist-get event :type)))
      (claude-emacs-annotate--map-buffers
       (lambda ()
         ;; The project's first annotation: when this buffer was
         ;; visited no store file existed, so global mode left the
         ;; local mode off.  Enabling it attaches the overlays.  Scope
         ;; to the event's own project tree, and never override a mode
         ;; the user turned off explicitly.
         (when (and (not claude-emacs-annotate-mode)
                    buffer-file-name
                    (memq type '(created reloaded))
                    (bound-and-true-p claude-emacs-annotate-global-mode)
                    (not (bound-and-true-p
                          claude-emacs-annotate-mode-set-explicitly))
                    (string-prefix-p (file-name-as-directory root)
                                     (file-truename buffer-file-name)))
           (claude-emacs-annotate--maybe-enable))
         (when (and claude-emacs-annotate-mode
                    (equal claude-emacs-annotate--view-root root)
                    (or (memq type '(reloaded cleared))
                        (member claude-emacs-annotate--view-relative-file
                                files)))
           (claude-emacs-annotate-view-attach)))))))

;;;; The buffer minor mode

(defvar claude-emacs-annotate-mode-map (make-sparse-keymap)
  "Keymap of `claude-emacs-annotate-mode'.
Empty by default; commands are reachable through
`claude-emacs-annotate-command-map'.")

;;;###autoload
(define-minor-mode claude-emacs-annotate-mode
  "Show and track annotation threads in this buffer.
Overlays are a pure view over the per-project store; buffer edits
flush back on idle, before saves, reverts and kills, and reverts
re-anchor by content."
  :lighter " ✎"
  :keymap claude-emacs-annotate-mode-map
  (if claude-emacs-annotate-mode
      ;; A non-nil view root means the view is already installed:
      ;; re-enabling must not reset the inline toggle or re-add hooks.
      (unless claude-emacs-annotate--view-root
        (let ((root (and buffer-file-name
                         (claude-emacs-annotate-project-root
                          (file-name-directory buffer-file-name)))))
          (if (null root)
              (setq claude-emacs-annotate-mode nil)
            (setq claude-emacs-annotate--view-root root)
            (setq claude-emacs-annotate--view-relative-file
                  (file-relative-name (file-truename buffer-file-name)
                                      (file-name-as-directory root)))
            (setq claude-emacs-annotate-inline
                  claude-emacs-annotate-inline-default)
            (add-hook 'after-change-functions
                      #'claude-emacs-annotate--view-after-change nil t)
            (add-hook 'before-save-hook
                      #'claude-emacs-annotate-view-flush nil t)
            (add-hook 'before-revert-hook
                      #'claude-emacs-annotate--view-flush-and-detach nil t)
            (add-hook 'after-revert-hook
                      #'claude-emacs-annotate-view-attach nil t)
            (add-hook 'kill-buffer-hook
                      #'claude-emacs-annotate--view-flush-and-detach nil t)
            (claude-emacs-annotate-view-attach))))
    (when claude-emacs-annotate--view-relative-file
      (claude-emacs-annotate-view-flush (current-buffer)))
    (claude-emacs-annotate-view-detach)
    (remove-hook 'after-change-functions
                 #'claude-emacs-annotate--view-after-change t)
    (remove-hook 'before-save-hook
                 #'claude-emacs-annotate-view-flush t)
    (remove-hook 'before-revert-hook
                 #'claude-emacs-annotate--view-flush-and-detach t)
    (remove-hook 'after-revert-hook
                 #'claude-emacs-annotate-view-attach t)
    (remove-hook 'kill-buffer-hook
                 #'claude-emacs-annotate--view-flush-and-detach t)
    (setq claude-emacs-annotate--view-root nil)
    (setq claude-emacs-annotate--view-relative-file nil)
    (setq claude-emacs-annotate--view-inline-overrides nil)))

;;;; Programmatic buffer operations

(defun claude-emacs-annotate-view-create-thread (start-line end-line text tag)
  "Create a thread over this buffer's lines START-LINE..END-LINE.
The anchor captures current BUFFER content -- live edits are the
truth here; the anchor converges with the file at the next save.
TEXT is the root prose and TAG an optional set tag.  Return the new
thread."
  (unless (and claude-emacs-annotate-mode claude-emacs-annotate--view-root)
    (user-error "Enable claude-emacs-annotate-mode in a project file first"))
  (let* ((anchor (claude-emacs-annotate-anchor-capture start-line end-line))
         (thread (claude-emacs-annotate-thread-create
                  claude-emacs-annotate--view-relative-file
                  anchor text (claude-emacs-annotate-author)
                  :tags (and tag (list tag))))
         (store (claude-emacs-annotate-store-get
                 claude-emacs-annotate--view-root)))
    (claude-emacs-annotate-store-mutate
     store
     (lambda () (claude-emacs-annotate-store-insert-thread store thread)))
    thread))

(defun claude-emacs-annotate-view-reanchor-thread (thread-id start-line
                                                             end-line)
  "Re-pin THREAD-ID to this buffer's lines START-LINE..END-LINE."
  (unless (and claude-emacs-annotate-mode claude-emacs-annotate--view-root)
    (user-error "Enable claude-emacs-annotate-mode in a project file first"))
  (let ((store (claude-emacs-annotate--view-store))
        (anchor (claude-emacs-annotate-anchor-capture start-line end-line)))
    (unless (and store (claude-emacs-annotate-store-thread store thread-id))
      (signal 'claude-emacs-annotate-not-found
              (list (format "no thread with id %s in this project"
                            thread-id))))
    (claude-emacs-annotate-store-mutate
     store
     (lambda ()
       (claude-emacs-annotate-store-update-anchors
        store (list (cons thread-id anchor)))))))

(defun claude-emacs-annotate-view-goto-thread (root thread-id)
  "Open THREAD-ID's file under ROOT and move point to its region."
  (let* ((store (claude-emacs-annotate-store-get root t))
         (thread (and store
                      (claude-emacs-annotate-store-thread store thread-id))))
    (unless thread
      (signal 'claude-emacs-annotate-not-found
              (list (format "no thread with id %s in this project"
                            thread-id))))
    (pop-to-buffer
     (find-file-noselect
      (expand-file-name (claude-emacs-annotate-thread-file thread) root)))
    (unless claude-emacs-annotate-mode
      (claude-emacs-annotate-mode 1))
    (let ((overlay (claude-emacs-annotate--view-overlay-for thread-id)))
      (if overlay
          (goto-char (overlay-start overlay))
        (goto-char (point-min))
        (forward-line (1- (or (plist-get
                               (claude-emacs-annotate-thread-anchor thread)
                               :start-line)
                              1)))))))

;;;; Interactive commands

(defun claude-emacs-annotate--view-thread-at-point ()
  "Return (STORE . THREAD) for the annotation at point, prompting on overlap."
  (let* ((store (or (claude-emacs-annotate--view-store)
                    (user-error "No annotations in this project")))
         (overlays (claude-emacs-annotate--view-overlays-at (point)))
         (threads (delq nil
                        (mapcar (lambda (overlay)
                                  (claude-emacs-annotate-store-thread
                                   store
                                   (overlay-get overlay
                                                'claude-emacs-annotate-id)))
                                overlays))))
    (unless threads (user-error "No annotation at point"))
    (cons store
          (claude-emacs-annotate--view-choose-thread "Annotation: "
                                                     threads))))

(defun claude-emacs-annotate--view-choose-thread (prompt threads)
  "Pick one of THREADS by summary via PROMPT.
A single candidate is returned without prompting.  Duplicate
summaries gain a start-line and thread-id suffix, so every candidate
stays selectable."
  (if (null (cdr threads))
      (car threads)
    (let* ((summaries (mapcar #'claude-emacs-annotate--view-summary threads))
           (candidates
            (cl-mapcar
             (lambda (thread summary)
               (cons (if (cdr (seq-filter (lambda (other)
                                            (equal other summary))
                                          summaries))
                         (let ((id (claude-emacs-annotate-thread-id thread)))
                           (format "%s [%s %s]"
                                   summary
                                   (or (plist-get
                                        (claude-emacs-annotate-thread-anchor
                                         thread)
                                        :start-line)
                                       "file")
                                   (substring id (max 0 (- (length id)
                                                           8)))))
                       summary)
                     thread))
             threads summaries))
           (choice (completing-read prompt candidates nil t)))
      (cdr (assoc choice candidates)))))

(defun claude-emacs-annotate--view-overlay-starts ()
  "Return this buffer's annotation start positions, sorted.
Signal a `user-error' when the buffer has none."
  (or (sort (mapcar #'overlay-start (claude-emacs-annotate--view-overlays))
            #'<)
      (user-error "No annotations in this buffer")))

(defun claude-emacs-annotate-next ()
  "Move point to the next annotation, wrapping around."
  (interactive)
  (let ((starts (claude-emacs-annotate--view-overlay-starts)))
    (goto-char (or (seq-find (lambda (start) (> start (point))) starts)
                   (car starts)))))

(defun claude-emacs-annotate-previous ()
  "Move point to the previous annotation, wrapping around."
  (interactive)
  (let ((starts (claude-emacs-annotate--view-overlay-starts)))
    (goto-char (or (car (last (seq-filter (lambda (start)
                                            (< start (point)))
                                          starts)))
                   (car (last starts))))))

(declare-function claude-emacs-annotate--thread-compose-create
                  "claude-emacs-annotate-thread")
(declare-function claude-emacs-annotate--thread-pop-to-edit
                  "claude-emacs-annotate-thread")

(defun claude-emacs-annotate-create (start end)
  "Annotate the active region or the current line (START to END).
The annotation text is written in a compose buffer shown in a small
window below -- commit it with \\<claude-emacs-annotate-edit-mode-map>\
\\[claude-emacs-annotate-edit-commit], cancel with
\\[claude-emacs-annotate-edit-cancel], and attach an optional tag
with \\[claude-emacs-annotate-edit-set-tag].  The anchor is captured
from the buffer the moment this command fires, so the selection stays
pinned while the text is being written."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (line-beginning-position) (line-end-position))))
  (unless claude-emacs-annotate-mode
    (claude-emacs-annotate-mode 1))
  (unless (and claude-emacs-annotate-mode claude-emacs-annotate--view-root)
    (user-error "Not in a project file"))
  (pcase-let* ((`(,start-line . ,end-line)
                (claude-emacs-annotate--view-region-lines start end))
               (anchor (claude-emacs-annotate-anchor-capture
                        start-line end-line)))
    (deactivate-mark)
    (require 'claude-emacs-annotate-thread)
    (claude-emacs-annotate--thread-pop-to-edit
     (claude-emacs-annotate--thread-compose-create
      claude-emacs-annotate--view-root
      claude-emacs-annotate--view-relative-file
      anchor nil start-line))))

(defun claude-emacs-annotate-set-status-at-point ()
  "Change the status of the annotation at point."
  (interactive)
  (pcase-let ((`(,_store . ,thread)
               (claude-emacs-annotate--view-thread-at-point)))
    (let ((status (completing-read
                   "Status: " claude-emacs-annotate-thread-statuses nil t)))
      (claude-emacs-annotate-api-set-status
       claude-emacs-annotate--view-root
       (claude-emacs-annotate-thread-id thread)
       status))))

(defun claude-emacs-annotate-delete-at-point ()
  "Delete the annotation thread at point, after confirmation."
  (interactive)
  (pcase-let ((`(,_store . ,thread)
               (claude-emacs-annotate--view-thread-at-point)))
    (when (y-or-n-p (format "Delete annotation %s? "
                            (claude-emacs-annotate--view-summary thread)))
      (claude-emacs-annotate-api-delete
       claude-emacs-annotate--view-root
       (claude-emacs-annotate-thread-id thread)))))

(defun claude-emacs-annotate-toggle-inline ()
  "Toggle inline thread rendering in this buffer.
Per-thread toggles (`claude-emacs-annotate-toggle-inline-at-point')
are reset: every thread lands on the new buffer-wide state."
  (interactive)
  (setq claude-emacs-annotate-inline (not claude-emacs-annotate-inline))
  (setq claude-emacs-annotate--view-inline-overrides nil)
  (claude-emacs-annotate-view-attach)
  (message "Inline annotations %s"
           (if claude-emacs-annotate-inline "on" "off")))

(defun claude-emacs-annotate-toggle-inline-at-point ()
  "Toggle the inline thread box of the annotation at point.
Overlapping annotations prompt for one, like the other at-point
commands.  The per-thread state rides on top of the buffer-wide
`claude-emacs-annotate-toggle-inline', which resets it."
  (interactive)
  (pcase-let* ((`(,_store . ,thread)
                (claude-emacs-annotate--view-thread-at-point))
               (id (claude-emacs-annotate-thread-id thread))
               (shown (not (claude-emacs-annotate--view-inline-shown-p id))))
    (setq claude-emacs-annotate--view-inline-overrides
          (assoc-delete-all id
                            claude-emacs-annotate--view-inline-overrides))
    (unless (eq shown (and claude-emacs-annotate-inline t))
      (push (cons id shown) claude-emacs-annotate--view-inline-overrides))
    (when-let* ((overlay (claude-emacs-annotate--view-overlay-for id)))
      (claude-emacs-annotate--view-decorate overlay thread))
    (message "Annotation %s" (if shown "expanded" "collapsed"))))

(defun claude-emacs-annotate-refresh ()
  "Rebuild this buffer's annotation overlays from the store."
  (interactive)
  (when-let* ((store (claude-emacs-annotate--view-store)))
    (claude-emacs-annotate-store-refresh store))
  (claude-emacs-annotate-view-attach)
  (message "Annotations refreshed"))

(defun claude-emacs-annotate--view-region-lines (start end)
  "Return the region START..END as inclusive lines (START-LINE . END-LINE).
A region whose end sits at the beginning of a line does not include
that line, and the phantom line after a trailing newline clamps to
the last real line, so a region reaching `point-max' never exceeds
the buffer."
  (let ((start-line (line-number-at-pos start t))
        (end-line (line-number-at-pos (if (and (> end start)
                                               (save-excursion
                                                 (goto-char end)
                                                 (bolp)))
                                          (1- end)
                                        end)
                                      t))
        (total (save-excursion
                 (save-restriction
                   (widen)
                   (max 1 (count-lines (point-min) (point-max)))))))
    (cons (min start-line total)
          (min (max start-line end-line) total))))

(defun claude-emacs-annotate-reanchor (start end)
  "Re-pin a stale thread of this file to the region (START to END)."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list (line-beginning-position) (line-end-position))))
  (let* ((store (or (claude-emacs-annotate--view-store)
                    (user-error "No annotations in this project")))
         (stale (seq-filter
                 (lambda (thread)
                   (eq 'stale
                       (plist-get (claude-emacs-annotate-thread-anchor
                                   thread)
                                  :state)))
                 (claude-emacs-annotate-store-threads-for-file
                  store claude-emacs-annotate--view-relative-file))))
    (unless stale
      (user-error "No stale annotations in this file"))
    (let ((thread (claude-emacs-annotate--view-choose-thread "Re-anchor: "
                                                             stale)))
      (pcase-let ((`(,start-line . ,end-line)
                   (claude-emacs-annotate--view-region-lines start end)))
        (claude-emacs-annotate-view-reanchor-thread
         (claude-emacs-annotate-thread-id thread)
         start-line end-line))
      (deactivate-mark))))

;;;; Wiring into the store

(add-hook 'claude-emacs-annotate-store-before-mutate-hook
          #'claude-emacs-annotate--view-flush-project)
(add-hook 'claude-emacs-annotate-changed-hook
          #'claude-emacs-annotate--view-on-change)
(add-hook 'kill-emacs-hook #'claude-emacs-annotate--view-flush-pending)

(provide 'claude-emacs-annotate-view)
;;; claude-emacs-annotate-view.el ends here
