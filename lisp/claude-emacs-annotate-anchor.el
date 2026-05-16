;;; claude-emacs-annotate-anchor.el --- Content anchors  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; Anchors tie threads to file content by line range plus the region's
;; exact text and a few surrounding context lines -- never by bare
;; offsets.  Capture builds an anchor from a buffer or straight from a
;; file on disk; resolve re-locates an anchor against current buffer
;; content and returns one of two verdicts: `fresh' (exact at the
;; recorded lines, found elsewhere, or whitespace-normalized -- the
;; position is silently followed) or `stale' (context located the
;; spot but the content changed, or nothing matches and the lines are
;; clamped -- kept, never dropped).  All operations widen temporarily
;; and search case-sensitively.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'claude-emacs-annotate-core)

;;;; Buffer content as lines

(defun claude-emacs-annotate--buffer-line-list ()
  "Return the widened buffer's lines as a list of strings.
A trailing newline contributes no phantom empty final line, matching
`count-lines' semantics."
  (save-excursion
    (save-restriction
      (widen)
      (let ((lines (split-string (buffer-substring-no-properties
                                  (point-min) (point-max))
                                 "\n")))
        (if (equal (car (last lines)) "")
            (butlast lines)
          lines)))))

(defun claude-emacs-annotate--normalize-line (line)
  "Return LINE with blank sequences collapsed and ends trimmed."
  (string-trim (replace-regexp-in-string "[ \t]+" " " line)))

(defun claude-emacs-annotate--normalized-vector (lines)
  "Return a vector of the normalized forms of the LINES vector."
  (let* ((total (length lines))
         (normalized (make-vector total nil)))
    (dotimes (i total)
      (aset normalized i (claude-emacs-annotate--normalize-line
                          (aref lines i))))
    normalized))

;;;; Capture

(defun claude-emacs-annotate--anchor-from-lines (lines start-line end-line)
  "Build a region anchor over LINES (a list) at START-LINE..END-LINE."
  (let* ((count (1+ (- end-line start-line)))
         (region (seq-subseq lines (1- start-line) end-line))
         (text (string-join region "\n"))
         (capped (> count claude-emacs-annotate-anchor-huge-region-lines))
         (head-tail claude-emacs-annotate-anchor-huge-region-head-tail)
         (context claude-emacs-annotate-anchor-context-lines))
    (list :kind 'region
          :start-line start-line
          :end-line end-line
          :line-count count
          :text (unless capped text)
          :text-cap (when capped
                      (list :first (string-join (seq-take region head-tail)
                                                "\n")
                            :last (string-join (seq-drop region
                                                         (- count head-tail))
                                               "\n")))
          :text-hash (sha1 text)
          :ws-hash (when capped
                     (sha1 (string-join
                            (mapcar #'claude-emacs-annotate--normalize-line
                                    region)
                            "\n")))
          :before (seq-subseq lines
                              (max 0 (- start-line 1 context))
                              (1- start-line))
          :after (seq-subseq lines
                             end-line
                             (min (length lines) (+ end-line context)))
          :state 'fresh)))

(defun claude-emacs-annotate-anchor-capture (start-line end-line
                                                        &optional label)
  "Capture a region anchor for START-LINE..END-LINE of this buffer.
Lines are 1-based and inclusive; the anchored region always spans
whole lines.  LABEL names the content in error messages (defaults to
the buffer name).  Signal `claude-emacs-annotate-invalid' when the
range is malformed or exceeds the buffer."
  (unless (and (integerp start-line) (integerp end-line)
               (<= 1 start-line) (<= start-line end-line))
    (signal 'claude-emacs-annotate-invalid
            (list (format "invalid line range %s..%s" start-line end-line))))
  (let* ((lines (claude-emacs-annotate--buffer-line-list))
         (total (length lines)))
    (unless (<= end-line total)
      (signal 'claude-emacs-annotate-invalid
              (list (format "line range %d..%d exceeds %s (%d lines)"
                            start-line end-line
                            (or label (buffer-name)) total))))
    (claude-emacs-annotate--anchor-from-lines lines start-line end-line)))

(defun claude-emacs-annotate-anchor-capture-file (file start-line end-line)
  "Capture a region anchor from FILE's on-disk content.
The file is read decoded into a temp buffer; no buffer visits FILE
and no file hooks run.  START-LINE and END-LINE are as in
`claude-emacs-annotate-anchor-capture'."
  (with-temp-buffer
    (insert-file-contents file)
    (claude-emacs-annotate-anchor-capture start-line end-line
                                          (abbreviate-file-name file))))

(defun claude-emacs-annotate-anchor-capture-whole-file ()
  "Return a whole-file anchor.
File anchors span whatever the file contains and are never stale."
  (list :kind 'file :state 'fresh))

;;;; Matching machinery

(defun claude-emacs-annotate--block-matches-p (lines index block)
  "Return non-nil when BLOCK (a string list) equals LINES at INDEX."
  (and (>= index 0)
       (<= (+ index (length block)) (length lines))
       (cl-loop for line in block
                for i from index
                always (equal line (aref lines i)))))

(defun claude-emacs-annotate--anchor-needle (anchor normalized)
  "Return matching data for ANCHOR as (COUNT FIRST-BLOCK LAST-BLOCK HASH).
FIRST-BLOCK is the leading lines to compare (the whole region for
uncapped anchors); LAST-BLOCK is the trailing lines of a capped
anchor; HASH verifies a capped anchor's full content -- the exact
hash normally, the whitespace-normalized hash when NORMALIZED."
  (let* ((cap (plist-get anchor :text-cap))
         (first-block (split-string (or (and cap (plist-get cap :first))
                                        (plist-get anchor :text)
                                        "")
                                    "\n"))
         (last-block (and cap (split-string (plist-get cap :last) "\n"))))
    (when normalized
      (setq first-block (mapcar #'claude-emacs-annotate--normalize-line
                                first-block))
      (setq last-block (and last-block
                            (mapcar #'claude-emacs-annotate--normalize-line
                                    last-block))))
    (list (plist-get anchor :line-count)
          first-block
          last-block
          (and cap (plist-get anchor
                              (if normalized :ws-hash :text-hash))))))

(defun claude-emacs-annotate--needle-matches-p (needle lines index)
  "Return non-nil when NEEDLE matches at INDEX.
LINES is the vector compared against (possibly normalized); the
needle's hash is verified over the same vector, so an exact needle
checks raw content and a normalized needle checks normalized content."
  (pcase-let ((`(,count ,first-block ,last-block ,hash) needle))
    (and (<= (+ index count) (length lines))
         (claude-emacs-annotate--block-matches-p lines index first-block)
         (or (null last-block)
             (claude-emacs-annotate--block-matches-p
              lines (+ index count (- (length last-block))) last-block))
         (or (null hash)
             (equal hash
                    (sha1 (string-join
                           (cl-loop for i from index below (+ index count)
                                    collect (aref lines i))
                           "\n")))))))

(defun claude-emacs-annotate--context-score (anchor lines index count)
  "Count ANCHOR context lines matching LINES around INDEX..INDEX+COUNT."
  (let ((score 0)
        (total (length lines)))
    (cl-loop for line in (reverse (plist-get anchor :before))
             for i downfrom (1- index)
             do (when (and (>= i 0) (equal line (aref lines i)))
                  (cl-incf score)))
    (cl-loop for line in (plist-get anchor :after)
             for i from (+ index count)
             do (when (and (< i total) (equal line (aref lines i)))
                  (cl-incf score)))
    score))

(defun claude-emacs-annotate--pick-nearest (anchor raw-lines candidates count)
  "Pick from CANDIDATES (0-based indices) the best match for ANCHOR.
Nearest to the recorded line wins; ties break on the RAW-LINES
context score around the COUNT-line region, then on the lowest index,
making the choice fully deterministic."
  (let ((recorded (1- (plist-get anchor :start-line))))
    (car (sort (copy-sequence candidates)
               (lambda (a b)
                 (let ((distance-a (abs (- a recorded)))
                       (distance-b (abs (- b recorded))))
                   (cond
                    ((/= distance-a distance-b) (< distance-a distance-b))
                    (t (let ((score-a (claude-emacs-annotate--context-score
                                       anchor raw-lines a count))
                             (score-b (claude-emacs-annotate--context-score
                                       anchor raw-lines b count)))
                         (cond ((/= score-a score-b) (> score-a score-b))
                               (t (< a b))))))))))))

(defun claude-emacs-annotate--find-block (raw-lines block)
  "Find BLOCK in RAW-LINES; return 0-based start indices.
Exact occurrences win; when there are none, whitespace-normalized
occurrences are returned instead."
  (when block
    (let ((exact (cl-loop for i from 0
                          to (- (length raw-lines) (length block))
                          when (claude-emacs-annotate--block-matches-p
                                raw-lines i block)
                          collect i)))
      (or exact
          (let ((normalized (claude-emacs-annotate--normalized-vector
                             raw-lines))
                (normalized-block (mapcar
                                   #'claude-emacs-annotate--normalize-line
                                   block)))
            (cl-loop for i from 0
                     to (- (length normalized) (length normalized-block))
                     when (claude-emacs-annotate--block-matches-p
                           normalized i normalized-block)
                     collect i))))))

;;;; Resolution steps

(defun claude-emacs-annotate--resolve-exact-at (anchor raw-lines)
  "Step 2: ANCHOR's text still at its recorded lines in RAW-LINES."
  (let ((needle (claude-emacs-annotate--anchor-needle anchor nil))
        (index (1- (plist-get anchor :start-line))))
    (when (and (>= index 0)
               (claude-emacs-annotate--needle-matches-p
                needle raw-lines index))
      (list :state 'fresh
            :start-line (plist-get anchor :start-line)
            :end-line (plist-get anchor :end-line)
            :method 'exact-at-lines))))

(defun claude-emacs-annotate--anchor-whitespace-only-p (anchor)
  "Return non-nil when ANCHOR's captured text is whitespace-only.
Such text matches every blank line, so a search hit carries no
information about where the anchor's subject actually is."
  (let ((cap (plist-get anchor :text-cap)))
    (seq-every-p (lambda (line)
                   (string-empty-p
                    (claude-emacs-annotate--normalize-line line)))
                 (split-string
                  (if cap
                      (concat (plist-get cap :first) "\n"
                              (plist-get cap :last))
                    (or (plist-get anchor :text) ""))
                  "\n"))))

(defun claude-emacs-annotate--resolve-search (anchor raw-lines normalized)
  "Find ANCHOR's text elsewhere in RAW-LINES and follow it as fresh.
This is the third and fourth stage of the resolve procedure; with
NORMALIZED, comparison is whitespace-insensitive.  Whitespace-only
anchors never match here -- any blank line would do, so only the
context stage can place them meaningfully."
  (unless (claude-emacs-annotate--anchor-whitespace-only-p anchor)
    (let* ((lines (if normalized
                      (claude-emacs-annotate--normalized-vector raw-lines)
                    raw-lines))
           (needle (claude-emacs-annotate--anchor-needle anchor normalized))
           (count (plist-get anchor :line-count))
           (candidates (cl-loop for i from 0 to (- (length lines) count)
                                when (claude-emacs-annotate--needle-matches-p
                                      needle lines i)
                                collect i)))
      (when candidates
        (let ((best (claude-emacs-annotate--pick-nearest
                     anchor raw-lines candidates count)))
          (list :state 'fresh
                :start-line (1+ best)
                :end-line (+ best count)
                :method (if normalized 'ws-search 'exact-search)))))))

(defun claude-emacs-annotate--resolve-context (anchor raw-lines)
  "Step 5: locate ANCHOR's context in RAW-LINES; the body changed."
  (let* ((count (plist-get anchor :line-count))
         (total (length raw-lines))
         (recorded (plist-get anchor :start-line))
         (before-ends
          ;; 1-based line numbers of the last line of each occurrence.
          (mapcar (lambda (i) (+ i (length (plist-get anchor :before))))
                  (claude-emacs-annotate--find-block
                   raw-lines (plist-get anchor :before))))
         (after-starts
          (mapcar #'1+ (claude-emacs-annotate--find-block
                        raw-lines (plist-get anchor :after))))
         (candidates nil))
    (cond
     ((and before-ends after-starts)
      (dolist (before-end before-ends)
        (dolist (after-start after-starts)
          (when (< before-end after-start)
            (let ((start (1+ before-end)))
              (push (cons (min start total)
                          (max (min start total)
                               (min total (1- after-start))))
                    candidates))))))
     (before-ends
      (dolist (before-end before-ends)
        (let ((start (1+ before-end)))
          (when (<= start total)
            (push (cons start (min total (+ before-end count)))
                  candidates)))))
     (after-starts
      (dolist (after-start after-starts)
        (let ((end (1- after-start)))
          (when (>= end 1)
            (push (cons (max 1 (- after-start count)) end)
                  candidates))))))
    (when candidates
      (let ((best (car (sort candidates
                             (lambda (a b)
                               (let ((distance-a (abs (- (car a) recorded)))
                                     (distance-b (abs (- (car b) recorded))))
                                 (if (/= distance-a distance-b)
                                     (< distance-a distance-b)
                                   (< (car a) (car b)))))))))
        (list :state 'stale
              :start-line (car best)
              :end-line (cdr best)
              :method 'context)))))

(defun claude-emacs-annotate--resolve-clamp (anchor total)
  "Step 6: ANCHOR is unlocatable; clamp its lines into TOTAL for display."
  (let* ((limit (max 1 total))
         (start (max 1 (min (plist-get anchor :start-line) limit)))
         (end (max start (min (plist-get anchor :end-line) limit))))
    (list :state 'stale :start-line start :end-line end :method 'clamp)))

;;;; Entry points

(defun claude-emacs-annotate-anchor-resolve (anchor)
  "Resolve ANCHOR against the current buffer's content.
Return a plist (:state STATE :start-line N :end-line N :method M)
where STATE is `fresh' or `stale' and M is the rung that decided:
`file', `exact-at-lines', `exact-search', `ws-search', `context' or
`clamp'.  Positions are re-derived from content, never trusted from
the stored lines; nothing is ever reported as missing -- the worst
outcome is a stale resolution clamped into the buffer."
  (save-excursion
    (save-restriction
      (widen)
      (if (eq (plist-get anchor :kind) 'file)
          (list :state 'fresh
                :start-line 1
                :end-line (max 1 (count-lines (point-min) (point-max)))
                :method 'file)
        (let* ((case-fold-search nil)
               (raw-lines (vconcat (claude-emacs-annotate--buffer-line-list))))
          (or (claude-emacs-annotate--resolve-exact-at anchor raw-lines)
              (claude-emacs-annotate--resolve-search anchor raw-lines nil)
              (claude-emacs-annotate--resolve-search anchor raw-lines t)
              (claude-emacs-annotate--resolve-context anchor raw-lines)
              (claude-emacs-annotate--resolve-clamp anchor
                                                     (length raw-lines))))))))

(defun claude-emacs-annotate-anchor-latch-stale (anchor)
  "Return ANCHOR latched stale.
An already-stale ANCHOR is returned itself (`eq'), letting callers
skip a store write.  Otherwise a stale copy is returned with the
recorded content untouched -- stale is a latch, and the recorded
text is what a rescue looks for."
  (if (eq (plist-get anchor :state) 'stale)
      anchor
    (plist-put (copy-sequence anchor) :state 'stale)))

(defun claude-emacs-annotate-anchor-adopt (anchor resolution)
  "Return ANCHOR updated to RESOLUTION against the current buffer.
A fresh resolution recaptures position, text and context at the
resolved lines.  A stale resolution is a latch and never recaptures
content -- the recorded text is what a rescue looks for, and
recapturing would make the next resolve bless the changed content as
fresh: a context-located resolution adopts the located lines only,
an unlocatable one changes just the state, keeping the recorded
lines.  When nothing changed, ANCHOR itself is returned (`eq') so
callers can skip a store write."
  (cond
   ((eq (plist-get anchor :kind) 'file)
    (if (eq (plist-get anchor :state) 'fresh)
        anchor
      (plist-put (copy-sequence anchor) :state 'fresh)))
   ((eq (plist-get resolution :state) 'fresh)
    (let ((captured (claude-emacs-annotate-anchor-capture
                     (plist-get resolution :start-line)
                     (plist-get resolution :end-line))))
      (if (equal captured anchor) anchor captured)))
   ((eq (plist-get resolution :method) 'context)
    (let ((updated (copy-sequence anchor)))
      (setq updated (plist-put updated :state 'stale))
      (setq updated (plist-put updated :start-line
                               (plist-get resolution :start-line)))
      (setq updated (plist-put updated :end-line
                               (plist-get resolution :end-line)))
      (if (equal updated anchor) anchor updated)))
   (t (claude-emacs-annotate-anchor-latch-stale anchor))))

(provide 'claude-emacs-annotate-anchor)
;;; claude-emacs-annotate-anchor.el ends here
