;;; claude-emacs-annotate-api.el --- Programmatic API + JSON transport  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; The contract external clients (the annotation skill scripts) build
;; against.  Every function takes an explicit project root, depends on
;; no current buffer or minor mode, anchors creations against on-disk
;; content, and signals typed errors.  Mutations accept an optional
;; `:expect-file' precondition that refuses to touch a thread anchored
;; elsewhere.
;;
;; `claude-emacs-annotate-api-call' wraps any operation for the
;; emacsclient transport: it never signals; it writes a JSON envelope
;; -- {"ok":true,"result":...} or {"ok":false,"error":{"type","message"}}
;; -- to a caller-supplied file, keeping stdout down to a tiny ack.
;; JSON object keys are snake_case; arrays are never null.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'claude-emacs-annotate-core)
(require 'claude-emacs-annotate-store)
(require 'claude-emacs-annotate-anchor)

;;;; Argument plumbing

(defun claude-emacs-annotate--api-relative-file (root file)
  "Return FILE as a project-relative name under ROOT.
FILE may be absolute or already relative; symlinked spellings are
resolved.  Signal `claude-emacs-annotate-invalid' when FILE falls
outside ROOT.  FILE need not exist."
  (let* ((abs (expand-file-name file root))
         (true (file-truename abs))
         (root-dir (file-name-as-directory root)))
    (cond
     ((string-prefix-p root-dir true) (file-relative-name true root-dir))
     ((string-prefix-p root-dir abs) (file-relative-name abs root-dir))
     (t (signal 'claude-emacs-annotate-invalid
                (list (format "file %s is outside project %s" abs root)))))))

(defun claude-emacs-annotate--api-check-expect (root thread expect-file)
  "Refuse when THREAD is not anchored in EXPECT-FILE under ROOT.
No-op when EXPECT-FILE is nil.  Signal
`claude-emacs-annotate-expectation' on a mismatch."
  (when expect-file
    (let ((expected (claude-emacs-annotate--api-relative-file
                     root expect-file))
          (actual (claude-emacs-annotate-thread-file thread)))
      (unless (equal expected actual)
        (signal 'claude-emacs-annotate-expectation
                (list (format "thread %s is anchored to %s, not %s"
                              (claude-emacs-annotate-thread-id thread)
                              actual expected)))))))

(defun claude-emacs-annotate--api-kind (kind)
  "Normalize a spec KIND designator to the symbol `region' or `file'."
  (pcase kind
    ((or 'nil 'region "region") 'region)
    ((or 'file "file") 'file)
    (_ (signal 'claude-emacs-annotate-invalid
               (list (format "invalid anchor kind: %S" kind))))))

(defun claude-emacs-annotate--api-require-string (value what)
  "Return VALUE when it is a non-blank string, else signal about WHAT."
  (unless (and (stringp value) (not (string-empty-p (string-trim value))))
    (signal 'claude-emacs-annotate-invalid
            (list (format "%s is required" what))))
  value)

(defun claude-emacs-annotate--api-prepare-thread (root spec)
  "Validate SPEC and return a fresh thread anchored on disk under ROOT."
  (let* ((kind (claude-emacs-annotate--api-kind (plist-get spec :kind)))
         (file (claude-emacs-annotate--api-require-string
                (plist-get spec :file) "file"))
         (text (claude-emacs-annotate--api-require-string
                (plist-get spec :text) "text"))
         (author (claude-emacs-annotate--api-require-string
                  (plist-get spec :author) "author"))
         (tags (or (plist-get spec :tags)
                   (when-let* ((tag (plist-get spec :tag))) (list tag))))
         (abs (expand-file-name file root))
         (relative (claude-emacs-annotate--api-relative-file root abs)))
    (unless (file-exists-p abs)
      (signal 'claude-emacs-annotate-invalid
              (list (format "no such file: %s" abs))))
    (let ((anchor (if (eq kind 'file)
                      (claude-emacs-annotate-anchor-capture-whole-file)
                    (claude-emacs-annotate-anchor-capture-file
                     abs
                     (plist-get spec :start-line)
                     (plist-get spec :end-line)))))
      (claude-emacs-annotate-thread-create
       relative anchor text author
       :tags tags
       :status (plist-get spec :status)
       :priority (plist-get spec :priority)))))

(defun claude-emacs-annotate--api-thread-match-p (thread root-author tag)
  "Return non-nil when THREAD matches ROOT-AUTHOR and TAG.
A nil ROOT-AUTHOR or TAG matches everything; otherwise ROOT-AUTHOR
compares against the root comment's author and TAG must be among the
thread's tags."
  (and (or (null root-author)
           (equal (claude-emacs-annotate-thread-root-author thread)
                  root-author))
       (or (null tag)
           (member tag (claude-emacs-annotate-thread-tags thread)))))

(defun claude-emacs-annotate--api-find-comment (comments comment-id thread-id)
  "Return COMMENT-ID's comment among COMMENTS.
Signal `claude-emacs-annotate-not-found' naming THREAD-ID otherwise."
  (or (claude-emacs-annotate-comment-by-id comments comment-id)
      (signal 'claude-emacs-annotate-not-found
              (list (format "no comment %s in thread %s"
                            comment-id thread-id)))))

(defun claude-emacs-annotate--api-with-thread (root thread-id expect-file fn)
  "Run FN on THREAD-ID's thread inside the mutation gate.
FN receives (STORE THREAD) and returns (VALUE . EVENT); the event is
dispatched by the store and VALUE is returned.  EXPECT-FILE is the
optional anchoring precondition.  Signal
`claude-emacs-annotate-not-found' for an unknown thread under ROOT."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (missing (format "no thread with id %s in this project" thread-id))
         (value nil))
    (unless store
      (signal 'claude-emacs-annotate-not-found (list missing)))
    (claude-emacs-annotate-store-mutate
     store
     (lambda ()
       (let ((thread (claude-emacs-annotate-store-thread store thread-id)))
         (unless thread
           (signal 'claude-emacs-annotate-not-found (list missing)))
         (claude-emacs-annotate--api-check-expect canon thread expect-file)
         (pcase-let ((`(,result . ,event) (funcall fn store thread)))
           (setq value result)
           event))))
    value))

;;;; Creation

(defun claude-emacs-annotate-api-create (root spec)
  "Create one annotation thread under ROOT from SPEC; return a copy.
SPEC is a plist with :file (absolute or project-relative; must
exist), :text and :author (required), :kind (`region' default, or
`file' for a whole-file anchor), :start-line/:end-line (region kind),
:tag or :tags, :status and :priority.  Anchoring reads the file's
on-disk content; no buffer is visited."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon))
         (thread (claude-emacs-annotate--api-prepare-thread canon spec)))
    (claude-emacs-annotate-store-mutate
     store
     (lambda () (claude-emacs-annotate-store-insert-thread store thread)))
    (copy-tree thread)))

(defun claude-emacs-annotate-api-create-batch (root specs)
  "Create many annotation threads under ROOT in one write.
SPECS is a list of `claude-emacs-annotate-api-create' spec plists.
Failing specs are collected, not fatal.  Return a plist with
:created, :failed, :threads (per-created plists of :thread-id, :file,
:start-line, :end-line) and :failures (per-failure plists of :file,
:start-line, :end-line, :error)."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon))
         (threads nil)
         (failures nil))
    (claude-emacs-annotate-store-mutate
     store
     (lambda ()
       (let (ids files)
         (dolist (spec specs)
           (condition-case err
               (let ((thread (claude-emacs-annotate--api-prepare-thread
                              canon spec)))
                 (claude-emacs-annotate-store-insert-thread store thread)
                 (push (claude-emacs-annotate-thread-id thread) ids)
                 (push (claude-emacs-annotate-thread-file thread) files)
                 (let ((anchor (claude-emacs-annotate-thread-anchor thread)))
                   (push (list :thread-id (claude-emacs-annotate-thread-id
                                           thread)
                               :file (claude-emacs-annotate-thread-file
                                      thread)
                               :start-line (plist-get anchor :start-line)
                               :end-line (plist-get anchor :end-line))
                         threads)))
             (error
              (push (list :file (plist-get spec :file)
                          :start-line (plist-get spec :start-line)
                          :end-line (plist-get spec :end-line)
                          :error (claude-emacs-annotate--api-error-message
                                  err))
                    failures))))
         (when ids
           (claude-emacs-annotate--store-event
            store 'created (nreverse ids)
            (seq-uniq (nreverse files)))))))
    (list :created (length threads)
          :failed (length failures)
          :threads (nreverse threads)
          :failures (nreverse failures))))

;;;; Thread mutations

(cl-defun claude-emacs-annotate-api-reply
    (root thread-id parent-comment-id text
          &key author (require-open t) (require-leaf t) expect-file)
  "Append a reply under PARENT-COMMENT-ID in THREAD-ID's thread.
ROOT scopes the project; TEXT and AUTHOR fill the new comment.  With
REQUIRE-OPEN (the default) the thread must have status \"open\"; with
REQUIRE-LEAF (the default) the parent must not already have a reply.
EXPECT-FILE optionally asserts the thread's anchoring file.  Return a
copy of the new comment."
  (claude-emacs-annotate--api-require-string text "text")
  (claude-emacs-annotate--api-require-string author "author")
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store thread)
     (when (and require-open
                (not (equal (claude-emacs-annotate-thread-status thread)
                            "open")))
       (signal 'claude-emacs-annotate-conflict
               (list (format "thread %s is not open (status: %s)"
                             thread-id
                             (claude-emacs-annotate-thread-status thread)))))
     (let ((comments (claude-emacs-annotate-thread-comments thread)))
       (claude-emacs-annotate--api-find-comment comments parent-comment-id
                                                thread-id)
       (when (and require-leaf
                  (not (claude-emacs-annotate-comment-leaf-p
                        comments parent-comment-id)))
         (signal 'claude-emacs-annotate-conflict
                 (list (format "comment %s already has a reply"
                               parent-comment-id))))
       (let ((comment (claude-emacs-annotate-comment-create
                       parent-comment-id author text)))
         (plist-put thread :comments (append comments (list comment)))
         (cons (copy-tree comment)
               (claude-emacs-annotate-store-update-thread store thread)))))))

(cl-defun claude-emacs-annotate-api-edit-comment
    (root thread-id comment-id new-text &key expect-file)
  "Replace COMMENT-ID's text with NEW-TEXT in THREAD-ID under ROOT.
The comment keeps its id, author and timestamp; an `:edited' stamp
records the change.  EXPECT-FILE optionally asserts the thread's
anchoring file.  Return a copy of the updated thread."
  (claude-emacs-annotate--api-require-string new-text "text")
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store thread)
     (let ((comment (claude-emacs-annotate--api-find-comment
                     (claude-emacs-annotate-thread-comments thread)
                     comment-id thread-id)))
       (plist-put comment :text (claude-emacs-annotate--clean-string
                                 new-text))
       (plist-put comment :edited (claude-emacs-annotate--timestamp))
       (let ((event (claude-emacs-annotate-store-update-thread
                     store thread)))
         (cons (copy-tree thread) event))))))

(defun claude-emacs-annotate--api-repin-anchor (root thread)
  "Re-pin THREAD's anchor against its file's on-disk content under ROOT.
Editing the annotation means its prose now describes the code as it
stands, so a locatable anchor recaptures at the located lines and a
stale latch clears; an unlocatable anchor (missing file included)
latches, or stays, stale with its recorded content preserved.  File
anchors are never stale and pass through untouched."
  (let ((anchor (claude-emacs-annotate-thread-anchor thread)))
    (unless (eq (plist-get anchor :kind) 'file)
      (let ((abs (expand-file-name (claude-emacs-annotate-thread-file thread)
                                   root)))
        (plist-put
         thread :anchor
         (if (not (file-exists-p abs))
             (claude-emacs-annotate-anchor-latch-stale anchor)
           (with-temp-buffer
             (insert-file-contents abs)
             (let ((resolution (claude-emacs-annotate-anchor-resolve
                                anchor)))
               (if (eq (plist-get resolution :method) 'clamp)
                   (claude-emacs-annotate-anchor-adopt anchor resolution)
                 (claude-emacs-annotate-anchor-capture
                  (plist-get resolution :start-line)
                  (plist-get resolution :end-line)))))))))))

(cl-defun claude-emacs-annotate-api-edit-root-text
    (root thread-id new-text &key expect-file)
  "Replace the root comment's text in THREAD-ID under ROOT.
The thread's id, replies and comment identity are preserved, and the
anchor is re-pinned: rewriting the annotation against the current
code clears a stale latch whenever its spot can still be located.
NEW-TEXT is the replacement prose; EXPECT-FILE optionally asserts the
thread's anchoring file.  Return a copy of the updated thread."
  (claude-emacs-annotate--api-require-string new-text "text")
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store thread)
     (let ((comment (claude-emacs-annotate-thread-root-comment thread)))
       (plist-put comment :text (claude-emacs-annotate--clean-string
                                 new-text))
       (plist-put comment :edited (claude-emacs-annotate--timestamp))
       (claude-emacs-annotate--api-repin-anchor
        (claude-emacs-annotate-store-root store) thread)
       (let ((event (claude-emacs-annotate-store-update-thread
                     store thread)))
         (cons (copy-tree thread) event))))))

(cl-defun claude-emacs-annotate-api-set-status
    (root thread-id status &key expect-file)
  "Set THREAD-ID's status to STATUS under ROOT.
EXPECT-FILE optionally asserts the thread's anchoring file.  Return a
plist of :thread-id, :previous-status and :thread (a copy)."
  (claude-emacs-annotate--check-status status)
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store thread)
     (let ((previous (claude-emacs-annotate-thread-status thread)))
       (if (equal previous status)
           ;; Idempotent by contract (close.sh): an equal status must
           ;; not rewrite the store or advance :updated, the merge key.
           (cons (list :thread-id thread-id
                       :previous-status previous
                       :thread (copy-tree thread))
                 nil)
         (plist-put thread :status status)
         (let ((event (claude-emacs-annotate-store-update-thread
                       store thread)))
           (cons (list :thread-id thread-id
                       :previous-status previous
                       :thread (copy-tree thread))
                 event)))))))

(cl-defun claude-emacs-annotate-api-delete (root thread-id &key expect-file)
  "Delete THREAD-ID's thread under ROOT, leaving a tombstone.
EXPECT-FILE optionally asserts the thread's anchoring file.  Return
THREAD-ID."
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store _thread)
     (cons thread-id
           (claude-emacs-annotate-store-delete-thread store thread-id)))))

(cl-defun claude-emacs-annotate-api-delete-comment
    (root thread-id comment-id &key expect-file)
  "Delete leaf comment COMMENT-ID from THREAD-ID under ROOT.
The root comment refuses (delete the thread instead) and so does a
comment that has replies.  EXPECT-FILE optionally asserts the
thread's anchoring file.  Return COMMENT-ID."
  (claude-emacs-annotate--api-with-thread
   root thread-id expect-file
   (lambda (store thread)
     (let* ((comments (claude-emacs-annotate-thread-comments thread))
            (comment (claude-emacs-annotate--api-find-comment
                      comments comment-id thread-id)))
       (when (null (claude-emacs-annotate-comment-parent-id comment))
         (signal 'claude-emacs-annotate-invalid
                 (list "cannot delete the root comment; delete the thread")))
       (unless (claude-emacs-annotate-comment-leaf-p comments comment-id)
         (signal 'claude-emacs-annotate-conflict
                 (list (format "comment %s has replies" comment-id))))
       (plist-put thread :comments (delq comment comments))
       (cons comment-id
             (claude-emacs-annotate-store-update-thread store thread))))))

;;;; Resolving anchors for the read paths

(defun claude-emacs-annotate--api-anchor-resolved (anchor resolution)
  "Return a report copy of ANCHOR carrying RESOLUTION's lines and state."
  (let ((copy (copy-sequence anchor)))
    (plist-put copy :start-line (plist-get resolution :start-line))
    (plist-put copy :end-line (plist-get resolution :end-line))
    (plist-put copy :state (plist-get resolution :state))
    copy))

(defun claude-emacs-annotate--api-resolve-anchors (root threads)
  "Resolve THREADS' anchors against ROOT's current on-disk content.
Return an alist mapping each thread (by identity) to a report copy of
its anchor with current lines and state.  The store is not touched --
reads stay pure; persistence happens whenever a buffer attaches.
Region anchors whose file is missing resolve to stale; whole-file
anchors span whatever exists and never go stale."
  (let ((by-file (make-hash-table :test #'equal))
        (result nil))
    (dolist (thread threads)
      (push thread (gethash (claude-emacs-annotate-thread-file thread)
                            by-file)))
    (maphash
     (lambda (file file-threads)
       (let ((abs (expand-file-name file root)))
         (if (not (file-exists-p abs))
             (dolist (thread file-threads)
               (let ((anchor (claude-emacs-annotate-thread-anchor thread)))
                 (push (cons thread
                             (if (eq (plist-get anchor :kind) 'file)
                                 anchor
                               (claude-emacs-annotate-anchor-latch-stale
                                anchor)))
                       result)))
           (with-temp-buffer
             (insert-file-contents abs)
             (dolist (thread file-threads)
               (let ((anchor (claude-emacs-annotate-thread-anchor thread)))
                 (push (cons thread
                             (if (eq (plist-get anchor :kind) 'file)
                                 anchor
                               (claude-emacs-annotate--api-anchor-resolved
                                anchor
                                (claude-emacs-annotate-anchor-resolve
                                 anchor))))
                       result)))))))
     by-file)
    result))

;;;; Queries

(cl-defun claude-emacs-annotate-api-query
    (root &key root-author tag status file)
  "Return copies of ROOT's threads matching all given filters.
ROOT-AUTHOR matches the root comment's author; TAG membership in the
thread's tags; STATUS the thread status; FILE the anchoring file,
absolute or project-relative.  Results sort by file, then anchor
start line, then id."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (relative-file (and file (claude-emacs-annotate--api-relative-file
                                   canon file))))
    (when store
      (let* ((matches
              (seq-filter
               (lambda (thread)
                 (and (claude-emacs-annotate--api-thread-match-p
                       thread root-author tag)
                      (or (null status)
                          (equal (claude-emacs-annotate-thread-status thread)
                                 status))
                      (or (null relative-file)
                          (equal (claude-emacs-annotate-thread-file thread)
                                 relative-file))))
               (claude-emacs-annotate-store-all-threads store)))
             (resolved (claude-emacs-annotate--api-resolve-anchors
                        canon matches))
             (copies (mapcar
                      (lambda (thread)
                        (let ((copy (copy-tree thread)))
                          (plist-put copy :anchor
                                     (copy-sequence
                                      (cdr (assq thread resolved))))
                          copy))
                      matches)))
        (sort copies #'claude-emacs-annotate--api-thread<)))))

(defun claude-emacs-annotate--api-order< (file-a line-a id-a
                                                 file-b line-b id-b)
  "Order item (FILE-A LINE-A ID-A) before (FILE-B LINE-B ID-B).
Files compare first, then anchor start lines (nil counts as 0), then
ids break the tie."
  (if (not (equal file-a file-b))
      (string< file-a file-b)
    (let ((line-a (or line-a 0))
          (line-b (or line-b 0)))
      (if (/= line-a line-b)
          (< line-a line-b)
        (string< id-a id-b)))))

(defun claude-emacs-annotate--api-thread< (a b)
  "Order threads A and B by file, anchor start line, then id."
  (claude-emacs-annotate--api-order<
   (claude-emacs-annotate-thread-file a)
   (plist-get (claude-emacs-annotate-thread-anchor a) :start-line)
   (claude-emacs-annotate-thread-id a)
   (claude-emacs-annotate-thread-file b)
   (plist-get (claude-emacs-annotate-thread-anchor b) :start-line)
   (claude-emacs-annotate-thread-id b)))

(defun claude-emacs-annotate--api-ancestors (comments comment)
  "Return COMMENT's ancestor chain in COMMENTS, root first."
  (let ((by-id (make-hash-table :test #'equal))
        (chain nil)
        (parent-id (claude-emacs-annotate-comment-parent-id comment)))
    (dolist (candidate comments)
      (puthash (claude-emacs-annotate-comment-id candidate) candidate by-id))
    (while parent-id
      (let ((parent (gethash parent-id by-id)))
        (if (null parent)
            (setq parent-id nil)
          (push parent chain)
          (setq parent-id (claude-emacs-annotate-comment-parent-id
                           parent)))))
    chain))

(cl-defun claude-emacs-annotate-api-pending
    (root &key tag (agent-author claude-emacs-annotate-agent-author))
  "Return the comments awaiting a reply under ROOT.
A comment is pending when its thread is open, its author differs from
AGENT-AUTHOR, and it is a structural leaf of the comment tree.  With
TAG, only threads carrying that tag participate.  Each item is a
plist of :thread-id, :comment-id, :author, :text, :timestamp, :file,
:anchor (a copy), :thread-status, :tags and :ancestors (the
root-to-parent chain as plists of :comment-id, :author, :text)."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (items nil))
    (when store
      (let* ((candidates
              (seq-filter
               (lambda (thread)
                 (and (equal "open" (claude-emacs-annotate-thread-status
                                     thread))
                      (or (null tag)
                          (member tag (claude-emacs-annotate-thread-tags
                                       thread)))))
               (claude-emacs-annotate-store-all-threads store)))
             (resolved (claude-emacs-annotate--api-resolve-anchors
                        canon candidates)))
        (dolist (thread candidates)
          (let ((comments (claude-emacs-annotate-thread-comments thread)))
            (dolist (comment comments)
              (when (and (not (equal (claude-emacs-annotate-comment-author
                                      comment)
                                     agent-author))
                         (claude-emacs-annotate-comment-leaf-p
                          comments
                          (claude-emacs-annotate-comment-id comment)))
                (push (list :thread-id (claude-emacs-annotate-thread-id
                                        thread)
                            :comment-id (claude-emacs-annotate-comment-id
                                         comment)
                            :author (claude-emacs-annotate-comment-author
                                     comment)
                            :text (claude-emacs-annotate-comment-text
                                   comment)
                            :timestamp
                            (claude-emacs-annotate-comment-timestamp comment)
                            :file (claude-emacs-annotate-thread-file thread)
                            :anchor (copy-sequence
                                     (cdr (assq thread resolved)))
                            :thread-status
                            (claude-emacs-annotate-thread-status thread)
                            :tags (claude-emacs-annotate-thread-tags thread)
                            :ancestors
                            (mapcar
                             (lambda (ancestor)
                               (list :comment-id
                                     (claude-emacs-annotate-comment-id
                                      ancestor)
                                     :author
                                     (claude-emacs-annotate-comment-author
                                      ancestor)
                                     :text
                                     (claude-emacs-annotate-comment-text
                                      ancestor)))
                             (claude-emacs-annotate--api-ancestors
                              comments comment)))
                      items)))))))
    (sort (nreverse items)
          (lambda (a b)
            (claude-emacs-annotate--api-order<
             (plist-get a :file)
             (plist-get (plist-get a :anchor) :start-line)
             (plist-get a :comment-id)
             (plist-get b :file)
             (plist-get (plist-get b :anchor) :start-line)
             (plist-get b :comment-id))))))

(cl-defun claude-emacs-annotate-api-count (root &key root-author tag)
  "Summarize ROOT's threads matching ROOT-AUTHOR and TAG.
Return a plist of :root, :author, :total, :files, :by-status (a hash
of status name to count, seeded with every configured status),
:open-by-tag (a hash of tag name to open-thread count, \"\" for
untagged), :open-stale and :anchor-states (a hash over fresh and
stale)."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (by-status (make-hash-table :test #'equal))
         (open-by-tag (make-hash-table :test #'equal))
         (anchor-states (make-hash-table :test #'equal))
         (files (make-hash-table :test #'equal))
         (open-stale 0)
         (total 0))
    (dolist (status claude-emacs-annotate-thread-statuses)
      (puthash status 0 by-status))
    (dolist (state '("fresh" "stale"))
      (puthash state 0 anchor-states))
    (when store
      (let* ((matches
              (seq-filter
               (lambda (thread)
                 (claude-emacs-annotate--api-thread-match-p
                  thread root-author tag))
               (claude-emacs-annotate-store-all-threads store)))
             (resolved (claude-emacs-annotate--api-resolve-anchors
                        canon matches)))
        (dolist (thread matches)
          (cl-incf total)
          (puthash (claude-emacs-annotate-thread-file thread) t files)
          (let ((status (claude-emacs-annotate-thread-status thread))
                (state (symbol-name
                        (or (plist-get (cdr (assq thread resolved)) :state)
                            'fresh)))
                (open (equal (claude-emacs-annotate-thread-status thread)
                             "open")))
            (cl-incf (gethash status by-status 0))
            (cl-incf (gethash state anchor-states 0))
            (when open
              (when (equal state "stale")
                (cl-incf open-stale))
              (let ((tags (claude-emacs-annotate-thread-tags thread)))
                (if (null tags)
                    (cl-incf (gethash "" open-by-tag 0))
                  (dolist (thread-tag tags)
                    (cl-incf (gethash thread-tag open-by-tag 0))))))))))
    (list :root canon
          :author root-author
          :total total
          :files (hash-table-count files)
          :by-status by-status
          :open-by-tag open-by-tag
          :open-stale open-stale
          :anchor-states anchor-states)))

(cl-defun claude-emacs-annotate-api-clear (root &key root-author tag all)
  "Remove threads under ROOT, scoped explicitly.
ALL removes everything; otherwise ROOT-AUTHOR (matching the root
comment's author) and/or TAG must be given -- clearing without an
explicit scope signals `claude-emacs-annotate-invalid'.  Return a
plist of :removed and :files."
  (unless (or all root-author tag)
    (signal 'claude-emacs-annotate-invalid
            (list (concat "refusing to clear without an explicit scope"
                          " (:root-author, :tag or :all)"))))
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (store (claude-emacs-annotate-store-get canon t))
         (result (list :removed 0 :files 0)))
    (when store
      (claude-emacs-annotate-store-mutate
       store
       (lambda ()
         (let* ((victims
                 (seq-filter
                  (lambda (thread)
                    (or all
                        (claude-emacs-annotate--api-thread-match-p
                         thread root-author tag)))
                  (claude-emacs-annotate-store-all-threads store)))
                (ids (mapcar #'claude-emacs-annotate-thread-id victims))
                (files (seq-uniq (mapcar #'claude-emacs-annotate-thread-file
                                         victims))))
           (setq result (list :removed (length ids)
                              :files (length files)))
           (when ids
             (dolist (id ids)
               (claude-emacs-annotate-store-delete-thread store id t))
             (claude-emacs-annotate--store-event store 'cleared
                                                 ids files))))))
    result))

;;;; JSON conversion

(defun claude-emacs-annotate--json-anchor (anchor)
  "Return ANCHOR as a JSON-ready plist."
  (if (eq (plist-get anchor :kind) 'file)
      (list :kind "file"
            :start_line :null
            :end_line :null
            :line_count :null
            :state (symbol-name (or (plist-get anchor :state) 'fresh)))
    (list :kind "region"
          :start_line (plist-get anchor :start-line)
          :end_line (plist-get anchor :end-line)
          :line_count (plist-get anchor :line-count)
          :state (symbol-name (or (plist-get anchor :state) 'fresh)))))

(defun claude-emacs-annotate--json-comment-node (node)
  "Return comment tree NODE as a JSON-ready plist."
  (pcase-let ((`(,comment . ,children) node))
    (list :id (claude-emacs-annotate-comment-id comment)
          :parent_id (or (claude-emacs-annotate-comment-parent-id comment)
                         :null)
          :author (claude-emacs-annotate-comment-author comment)
          :timestamp (claude-emacs-annotate-comment-timestamp comment)
          :text (claude-emacs-annotate-comment-text comment)
          :edited (or (plist-get comment :edited) :null)
          :children (vconcat (mapcar
                              #'claude-emacs-annotate--json-comment-node
                              children)))))

(defun claude-emacs-annotate--json-thread (thread)
  "Return THREAD as a JSON-ready plist."
  (let ((comments (claude-emacs-annotate-thread-comments thread)))
    (list :id (claude-emacs-annotate-thread-id thread)
          :file (claude-emacs-annotate-thread-file thread)
          :status (claude-emacs-annotate-thread-status thread)
          :priority (claude-emacs-annotate-thread-priority thread)
          :tags (vconcat (claude-emacs-annotate-thread-tags thread))
          :created (claude-emacs-annotate-thread-created thread)
          :updated (claude-emacs-annotate-thread-updated thread)
          :root_author (or (claude-emacs-annotate-thread-root-author thread)
                           :null)
          :comment_count (length comments)
          :anchor (claude-emacs-annotate--json-anchor
                   (claude-emacs-annotate-thread-anchor thread))
          :comments (vconcat
                     (mapcar #'claude-emacs-annotate--json-comment-node
                             (claude-emacs-annotate-comment-tree
                              comments))))))

(defun claude-emacs-annotate--json-pending-item (item)
  "Return pending ITEM as a JSON-ready plist."
  (list :thread_id (plist-get item :thread-id)
        :comment_id (plist-get item :comment-id)
        :author (plist-get item :author)
        :text (plist-get item :text)
        :timestamp (plist-get item :timestamp)
        :file (plist-get item :file)
        :anchor (claude-emacs-annotate--json-anchor (plist-get item :anchor))
        :thread_status (plist-get item :thread-status)
        :tags (vconcat (plist-get item :tags))
        :ancestors (vconcat
                    (mapcar (lambda (ancestor)
                              (list :comment_id (plist-get ancestor
                                                           :comment-id)
                                    :author (plist-get ancestor :author)
                                    :text (plist-get ancestor :text)))
                            (plist-get item :ancestors)))))

(defun claude-emacs-annotate--api-read-specs (path)
  "Read a JSON array of create specs from PATH.
Keys arrive snake_case per the wire contract and are converted to the
internal spec shape."
  (let ((parsed (with-temp-buffer
                  (insert-file-contents path)
                  (json-parse-buffer :object-type 'plist
                                     :array-type 'array
                                     :null-object nil
                                     :false-object nil))))
    (unless (vectorp parsed)
      (signal 'claude-emacs-annotate-invalid
              (list (format "%s: not a JSON array of specs" path))))
    (cl-loop for spec across parsed
             for index from 0
             unless (and (listp spec) (keywordp (car-safe spec)))
             do (signal 'claude-emacs-annotate-invalid
                        (list (format "%s: element %d is not a spec object"
                                      path index)))
             collect (list :file (plist-get spec :file)
                           :start-line (plist-get spec :start_line)
                           :end-line (plist-get spec :end_line)
                           :kind (when-let* ((kind (plist-get spec :kind)))
                                   (intern kind))
                           :text (plist-get spec :text)
                           :tag (plist-get spec :tag)
                           :author (plist-get spec :author)))))

;;;; The transport entry point

(defun claude-emacs-annotate--api-error-type (err)
  "Return the wire error type string for the signal ERR."
  (pcase (car err)
    ('claude-emacs-annotate-not-found "not_found")
    ('claude-emacs-annotate-conflict "conflict")
    ('claude-emacs-annotate-expectation "expectation_failed")
    ('claude-emacs-annotate-invalid "invalid")
    ('claude-emacs-annotate-io-error "io")
    ('claude-emacs-annotate-schema-error "schema")
    (_ "internal")))

(defun claude-emacs-annotate--api-error-message (err)
  "Return a human-readable message for the signal ERR."
  (let ((data (cdr err)))
    (if (and (consp data) (stringp (car data)))
        (car data)
      (error-message-string err))))

(defun claude-emacs-annotate--api-dispatch (op root args)
  "Execute operation OP for project ROOT with ARGS; return the result."
  ;; The scripts create threads with the default status and hardcode
  ;; "open"/"closed"; refuse up front when a customization breaks that
  ;; contract instead of failing quietly downstream.
  (unless (and (equal (car claude-emacs-annotate-thread-statuses) "open")
               (member "closed" claude-emacs-annotate-thread-statuses))
    (signal 'claude-emacs-annotate-invalid
            (list (concat "claude-emacs-annotate-thread-statuses must keep"
                          " \"open\" first and include \"closed\" for the"
                          " annotation scripts to work"))))
  (pcase (if (stringp op) (intern op) op)
    ('create
     (list :thread (claude-emacs-annotate--json-thread
                    (claude-emacs-annotate-api-create root args))))
    ('create-batch
     (let* ((specs-file (or (plist-get args :specs-file)
                            (signal 'claude-emacs-annotate-invalid
                                    (list "create-batch requires :specs-file"))))
            (specs (claude-emacs-annotate--api-read-specs specs-file))
            (result (claude-emacs-annotate-api-create-batch root specs)))
       (list :created (plist-get result :created)
             :failed (plist-get result :failed)
             :threads (vconcat
                       (mapcar (lambda (entry)
                                 (list :thread_id (plist-get entry
                                                             :thread-id)
                                       :file (plist-get entry :file)
                                       :start_line (or (plist-get
                                                        entry :start-line)
                                                       :null)
                                       :end_line (or (plist-get
                                                      entry :end-line)
                                                     :null)))
                               (plist-get result :threads)))
             :failures (vconcat
                        (mapcar (lambda (failure)
                                  (list :file (or (plist-get failure :file)
                                                  :null)
                                        :start_line (or (plist-get
                                                         failure
                                                         :start-line)
                                                        :null)
                                        :end_line (or (plist-get
                                                       failure :end-line)
                                                      :null)
                                        :error (plist-get failure :error)))
                                (plist-get result :failures))))))
    ('reply
     (let ((comment (claude-emacs-annotate-api-reply
                     root
                     (plist-get args :thread-id)
                     (plist-get args :parent-comment-id)
                     (plist-get args :text)
                     :author (plist-get args :author)
                     :expect-file (plist-get args :expect-file))))
       (list :thread_id (plist-get args :thread-id)
             :comment_id (claude-emacs-annotate-comment-id comment))))
    ('edit-root-text
     (let ((thread (claude-emacs-annotate-api-edit-root-text
                    root
                    (plist-get args :thread-id)
                    (plist-get args :text)
                    :expect-file (plist-get args :expect-file))))
       (list :thread_id (claude-emacs-annotate-thread-id thread)
             :thread (claude-emacs-annotate--json-thread thread))))
    ('set-status
     (let ((result (claude-emacs-annotate-api-set-status
                    root
                    (plist-get args :thread-id)
                    (plist-get args :status)
                    :expect-file (plist-get args :expect-file))))
       (list :thread_id (plist-get result :thread-id)
             :previous_status (plist-get result :previous-status)
             :thread (claude-emacs-annotate--json-thread
                      (plist-get result :thread)))))
    ('delete
     (list :thread_id (claude-emacs-annotate-api-delete
                       root
                       (plist-get args :thread-id)
                       :expect-file (plist-get args :expect-file))))
    ('query
     (let ((threads (claude-emacs-annotate-api-query
                     root
                     :root-author (plist-get args :root-author)
                     :tag (plist-get args :tag)
                     :status (plist-get args :status)
                     :file (plist-get args :file))))
       (list :count (length threads)
             :threads (vconcat (mapcar #'claude-emacs-annotate--json-thread
                                       threads)))))
    ('pending
     (let ((items (claude-emacs-annotate-api-pending
                   root
                   :tag (plist-get args :tag)
                   :agent-author (or (plist-get args :agent-author)
                                     claude-emacs-annotate-agent-author))))
       (list :count (length items)
             :pending (vconcat
                       (mapcar #'claude-emacs-annotate--json-pending-item
                               items)))))
    ('count
     (let ((result (claude-emacs-annotate-api-count
                    root
                    :root-author (plist-get args :root-author)
                    :tag (plist-get args :tag))))
       (list :root (plist-get result :root)
             :author (or (plist-get result :author) :null)
             :total (plist-get result :total)
             :files_with_annotations (plist-get result :files)
             :by_status (plist-get result :by-status)
             :open_by_tag (plist-get result :open-by-tag)
             :open_stale (plist-get result :open-stale)
             :anchor_states (plist-get result :anchor-states))))
    ('clear
     (let* ((all (plist-get args :all))
            (tag (plist-get args :tag))
            (result (claude-emacs-annotate-api-clear
                     root
                     :root-author (plist-get args :root-author)
                     :tag tag
                     :all all)))
       (list :removed (plist-get result :removed)
             :files (plist-get result :files)
             :mode (cond (all "all") (tag "tag") (t "author"))
             :tag (or tag :null))))
    (op-symbol
     (signal 'claude-emacs-annotate-invalid
             (list (format "unknown operation: %s" op-symbol))))))

(defun claude-emacs-annotate-api-call (op root args out-file)
  "Run operation OP for project ROOT with ARGS; reply into OUT-FILE.
This is the emacsclient transport entry point.  Operation errors
never signal: the envelope {\"ok\":false,\"error\":{...}} is written
instead, so the caller's stdout stays a tiny ack.  Only a failure to
write OUT-FILE itself propagates.  Return t."
  (let ((payload
         (condition-case err
             (list :ok t
                   :result (claude-emacs-annotate--api-dispatch
                            op root args))
           (error
            (list :ok :false
                  :error (list :type (claude-emacs-annotate--api-error-type
                                      err)
                               :message
                               (claude-emacs-annotate--api-error-message
                                err)))))))
    (let ((coding-system-for-write 'utf-8))
      (with-temp-file out-file
        (insert (json-serialize payload))))
    t))

(provide 'claude-emacs-annotate-api)
;;; claude-emacs-annotate-api.el ends here
