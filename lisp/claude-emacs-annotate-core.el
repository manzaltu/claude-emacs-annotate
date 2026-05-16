;;; claude-emacs-annotate-core.el --- Data model for claude-emacs-annotate  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; Pure data layer for claude-emacs-annotate: customization options,
;; shared faces, error conditions, id and timestamp generation, thread
;; and comment constructors with ingest normalization, comment-tree
;; building, and validation.  No I/O and no buffer dependence lives
;; here; everything is unit-testable in isolation.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defgroup claude-emacs-annotate nil
  "Threaded, line-anchored annotations with a per-project store."
  :group 'tools
  :prefix "claude-emacs-annotate-")

(defcustom claude-emacs-annotate-directory
  (locate-user-emacs-file "claude-emacs-annotate/")
  "Directory holding the per-project annotation databases."
  :type 'directory
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-thread-statuses
  '("open" "in-progress" "resolved" "closed")
  "Valid thread status values.
The first entry is the default status for new threads.  The
annotation scripts rely on \"open\" staying first and \"closed\"
staying a member: creation uses the default, pending scans open
threads, and closing sets \"closed\".  The wire transport refuses to
run when a customization drops either."
  :type '(repeat string)
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-priorities
  '("normal" "low" "high" "critical")
  "Valid thread priority values.
The first entry is the default priority for new threads."
  :type '(repeat string)
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-agent-author
  "claude-code"
  "Author string identifying threads opened by the annotation skills.
Used for display affordances; ownership checks in queries always take
the author as an explicit parameter."
  :type 'string
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-default-author nil
  "Author recorded on interactively created comments.
When nil, the variable `user-full-name' is used, falling back to the
login name."
  :type '(choice (const :tag "Use user-full-name" nil) string)
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-tombstone-ttl-days 30
  "Days a deletion tombstone is kept before being garbage collected.
Tombstones prevent deleted threads from being resurrected when
concurrent writers merge their stores."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-anchor-context-lines 3
  "Number of context lines captured before and after an anchor."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-anchor-huge-region-lines 120
  "Region line count above which anchors store a capped form.
Capped anchors keep only the leading and trailing blocks plus a hash
of the full region text."
  :type 'natnum
  :group 'claude-emacs-annotate)

(defcustom claude-emacs-annotate-anchor-huge-region-head-tail 10
  "Lines kept at each end of a capped anchor."
  :type 'natnum
  :group 'claude-emacs-annotate)

;;;; Faces shared across views

(defface claude-emacs-annotate-stale-face
  '((t :inherit error))
  "Face for badges of stale annotations.
Stale means the anchored content changed or can no longer be
located; the badge persists until the thread is re-pinned or its
content returns."
  :group 'claude-emacs-annotate)

(defface claude-emacs-annotate-agent-author-face
  '((t :inherit font-lock-function-name-face))
  "Face for the agent author in tables and thread buffers."
  :group 'claude-emacs-annotate)

;;;; Error conditions

(define-error 'claude-emacs-annotate-error
              "claude-emacs-annotate error")
(define-error 'claude-emacs-annotate-schema-error
              "Annotation database schema error" 'claude-emacs-annotate-error)
(define-error 'claude-emacs-annotate-not-found
              "Annotation not found" 'claude-emacs-annotate-error)
(define-error 'claude-emacs-annotate-conflict
              "Annotation state conflict" 'claude-emacs-annotate-error)
(define-error 'claude-emacs-annotate-expectation
              "Annotation precondition failed" 'claude-emacs-annotate-error)
(define-error 'claude-emacs-annotate-invalid
              "Invalid annotation input" 'claude-emacs-annotate-error)
(define-error 'claude-emacs-annotate-io-error
              "Annotation database I/O error" 'claude-emacs-annotate-error)

;;;; Ids and timestamps

(defun claude-emacs-annotate--id (prefix)
  "Return a fresh id string starting with PREFIX.
The id embeds the current epoch milliseconds and a random 32-bit
suffix; ids never rely on `sxhash' and are stable to compare across
sessions."
  (format "%s-%d-%08x"
          prefix
          (floor (* 1000 (float-time)))
          (random #x100000000)))

(defun claude-emacs-annotate--timestamp (&optional time)
  "Return TIME (default: now) as an ISO-8601 UTC string with milliseconds.
The format sorts lexicographically, which the store's merge logic
relies on for last-writer-wins comparisons."
  (format-time-string "%FT%T.%3NZ" time t))

(defun claude-emacs-annotate--timestamp-after (stamp)
  "Return the smallest timestamp strictly greater than STAMP.
STAMP is a string in the fixed-width format produced by
`claude-emacs-annotate--timestamp'; the result advances it by one
millisecond."
  (let ((millis (string-to-number (substring stamp 20 23))))
    (if (< millis 999)
        (format "%s%03dZ" (substring stamp 0 20) (1+ millis))
      (claude-emacs-annotate--timestamp
       (time-add (date-to-time (concat (substring stamp 0 19) "Z")) 1)))))

;;;; Ingest normalization and validation

(defun claude-emacs-annotate--clean-string (object)
  "Return OBJECT as a string stripped of text properties.
Signal `claude-emacs-annotate-invalid' when OBJECT is not a string.
Every string entering the data model passes through here so that
propertized text can never reach the store or the disk."
  (unless (stringp object)
    (signal 'claude-emacs-annotate-invalid
            (list (format "expected a string, got %s" (type-of object)))))
  (substring-no-properties object))

(defun claude-emacs-annotate--check-tag (tag)
  "Validate TAG and return it.
Tags must start with an alphanumeric character and may contain
alphanumerics, dots, underscores and dashes.  Signal
`claude-emacs-annotate-invalid' otherwise."
  (unless (and (stringp tag)
               (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" tag))
    (signal 'claude-emacs-annotate-invalid
            (list (format "invalid tag: %S" tag))))
  tag)

(defun claude-emacs-annotate--check-member (value valid what)
  "Validate VALUE against the VALID string list, naming WHAT in errors.
Return VALUE, or signal `claude-emacs-annotate-invalid'."
  (unless (member value valid)
    (signal 'claude-emacs-annotate-invalid
            (list (format "invalid %s: %S (valid: %s)" what value
                          (string-join valid ", ")))))
  value)

(defun claude-emacs-annotate--check-status (status)
  "Validate STATUS against `claude-emacs-annotate-thread-statuses'.
Return STATUS, or signal `claude-emacs-annotate-invalid'."
  (claude-emacs-annotate--check-member
   status claude-emacs-annotate-thread-statuses "status"))

(defun claude-emacs-annotate--check-priority (priority)
  "Validate PRIORITY against `claude-emacs-annotate-priorities'.
Return PRIORITY, or signal `claude-emacs-annotate-invalid'."
  (claude-emacs-annotate--check-member
   priority claude-emacs-annotate-priorities "priority"))

;;;; Constructors

(defun claude-emacs-annotate-comment-create (parent-id author text)
  "Return a new comment plist.
PARENT-ID is the id of the comment being replied to, or nil for a
thread's root comment.  AUTHOR and TEXT are normalized strings."
  (list :id (claude-emacs-annotate--id "c")
        :parent-id (and parent-id
                        (claude-emacs-annotate--clean-string parent-id))
        :author (claude-emacs-annotate--clean-string author)
        :timestamp (claude-emacs-annotate--timestamp)
        :text (claude-emacs-annotate--clean-string text)
        :edited nil))

(cl-defun claude-emacs-annotate-thread-create
    (file anchor text author &key tags status priority)
  "Return a new thread plist anchored in FILE.
FILE is a project-relative file name.  ANCHOR is an anchor plist as
produced by the anchor module.  TEXT becomes the root comment's body,
authored by AUTHOR.  TAGS is a list of tag strings; STATUS and
PRIORITY default to the first entries of their defcustom lists."
  (let ((now (claude-emacs-annotate--timestamp)))
    (list :id (claude-emacs-annotate--id "th")
          :file (claude-emacs-annotate--clean-string file)
          :created now
          :updated now
          :status (claude-emacs-annotate--check-status
                   (or status (car claude-emacs-annotate-thread-statuses)))
          :priority (claude-emacs-annotate--check-priority
                     (or priority (car claude-emacs-annotate-priorities)))
          :tags (mapcar (lambda (tag)
                          (claude-emacs-annotate--check-tag
                           (claude-emacs-annotate--clean-string tag)))
                        tags)
          :anchor anchor
          :comments (list (claude-emacs-annotate-comment-create
                           nil author text)))))

;;;; Accessors

(defun claude-emacs-annotate-thread-id (thread)
  "Return THREAD's id."
  (plist-get thread :id))

(defun claude-emacs-annotate-thread-file (thread)
  "Return THREAD's project-relative file name."
  (plist-get thread :file))

(defun claude-emacs-annotate-thread-created (thread)
  "Return THREAD's creation timestamp."
  (plist-get thread :created))

(defun claude-emacs-annotate-thread-updated (thread)
  "Return THREAD's last-update timestamp."
  (plist-get thread :updated))

(defun claude-emacs-annotate-thread-status (thread)
  "Return THREAD's status string."
  (plist-get thread :status))

(defun claude-emacs-annotate-thread-priority (thread)
  "Return THREAD's priority string."
  (plist-get thread :priority))

(defun claude-emacs-annotate-thread-tags (thread)
  "Return THREAD's list of tag strings."
  (plist-get thread :tags))

(defun claude-emacs-annotate-thread-anchor (thread)
  "Return THREAD's anchor plist."
  (plist-get thread :anchor))

(defun claude-emacs-annotate-thread-comments (thread)
  "Return THREAD's flat list of comment plists."
  (plist-get thread :comments))

(defun claude-emacs-annotate-thread-root-comment (thread)
  "Return THREAD's root comment.
The root is the comment without a parent; the first comment serves as
a defensive fallback for malformed data."
  (let ((comments (claude-emacs-annotate-thread-comments thread)))
    (or (seq-find (lambda (comment) (null (plist-get comment :parent-id)))
                  comments)
        (car comments))))

(defun claude-emacs-annotate-thread-root-author (thread)
  "Return the author of THREAD's root comment, or nil.
The root comment's author is the ownership discriminator used to tell
skill-authored threads apart from user-authored ones."
  (plist-get (claude-emacs-annotate-thread-root-comment thread) :author))

(defun claude-emacs-annotate-comment-id (comment)
  "Return COMMENT's id."
  (plist-get comment :id))

(defun claude-emacs-annotate-comment-by-id (comments id)
  "Return the comment with ID among COMMENTS, or nil."
  (seq-find (lambda (comment)
              (equal (claude-emacs-annotate-comment-id comment) id))
            comments))

(defun claude-emacs-annotate-comment-parent-id (comment)
  "Return COMMENT's parent comment id, or nil for a root comment."
  (plist-get comment :parent-id))

(defun claude-emacs-annotate-comment-author (comment)
  "Return COMMENT's author string."
  (plist-get comment :author))

(defun claude-emacs-annotate-comment-timestamp (comment)
  "Return COMMENT's creation timestamp."
  (plist-get comment :timestamp))

(defun claude-emacs-annotate-comment-text (comment)
  "Return COMMENT's body text."
  (plist-get comment :text))

;;;; Mutation helpers

(defun claude-emacs-annotate-thread-touch (thread)
  "Stamp THREAD's `:updated' with the current time and return THREAD.
The new stamp is guaranteed to be strictly greater than the previous
one even within the same millisecond, because `:updated' serves as the
last-writer-wins key when concurrent stores merge."
  (let ((previous (plist-get thread :updated))
        (now (claude-emacs-annotate--timestamp)))
    (when (and previous (not (string< previous now)))
      (setq now (claude-emacs-annotate--timestamp-after previous)))
    (plist-put thread :updated now)))

;;;; Comment trees

(defun claude-emacs-annotate-comment-tree (comments)
  "Build a tree from the flat COMMENTS list.
Return a list of (COMMENT . CHILDREN) nodes where CHILDREN has the
same shape.  Roots are comments without a parent id; a comment whose
parent id names no comment in COMMENTS is treated as a root rather
than dropped.  Sibling order follows the order in COMMENTS."
  (let ((known (make-hash-table :test #'equal))
        (children (make-hash-table :test #'equal))
        (roots nil))
    (dolist (comment comments)
      (puthash (plist-get comment :id) t known))
    (dolist (comment comments)
      (let ((parent-id (plist-get comment :parent-id)))
        (if (and parent-id (gethash parent-id known))
            (push comment (gethash parent-id children))
          (push comment roots))))
    (cl-labels ((build (comment)
                  (cons comment
                        (mapcar #'build
                                (reverse (gethash (plist-get comment :id)
                                                  children))))))
      (mapcar #'build (nreverse roots)))))

(defun claude-emacs-annotate-comment-leaf-p (comments comment-id)
  "Return non-nil when COMMENT-ID is a leaf within COMMENTS.
A comment is a leaf when no other comment names it as parent.  The
test is structural, not chronological: two replies to the same parent
are both leaves."
  (not (seq-some (lambda (comment)
                   (equal (plist-get comment :parent-id) comment-id))
                 comments)))

;;;; Environment helpers

(defun claude-emacs-annotate-author ()
  "Return the author string for interactively created comments."
  (or claude-emacs-annotate-default-author
      (and (stringp user-full-name)
           (not (string-empty-p user-full-name))
           user-full-name)
      (user-login-name)))

(provide 'claude-emacs-annotate-core)
;;; claude-emacs-annotate-core.el ends here
