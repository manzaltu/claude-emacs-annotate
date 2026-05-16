;;; claude-emacs-annotate-store.el --- Per-project annotation store  -*- lexical-binding: t; -*-

;; Author: Yoav Orot
;; Keywords: tools

;;; Commentary:
;; The persistence heart of claude-emacs-annotate.  One in-memory
;; store per project is the runtime source of truth; its database file
;; is a durable mirror written through atomically on every mutation.
;; Overlays and other views never hold data of their own -- losing
;; them can never lose annotations.
;;
;; Concurrency: before every write the file's mtime is compared with
;; the one cached at the last read; when it changed underneath us the
;; disk state is merged in per thread id (last-writer-wins on the
;; `:updated' stamp, deletion tombstones, and a comment union so
;; concurrent replies are never lost).  Writes go to a temp file in
;; the same directory followed by a rename.
;;
;; All mutations pass through `claude-emacs-annotate-store-mutate',
;; which runs `claude-emacs-annotate-store-before-mutate-hook' (views
;; flush live buffer positions there), refreshes from disk, applies
;; the mutation, persists, and finally dispatches change events to
;; `claude-emacs-annotate-changed-hook'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'filenotify)
(require 'project)
(require 'vc-git)
(require 'claude-emacs-annotate-core)

;;;; Options, hooks, state

(defcustom claude-emacs-annotate-use-file-watcher t
  "When non-nil, watch each project database file for external changes.
External writes are merged in automatically and views refresh."
  :type 'boolean
  :group 'claude-emacs-annotate)

(defvar claude-emacs-annotate-changed-hook nil
  "Hook run after the store changes, with one EVENT plist argument.
EVENT has the shape (:type TYPE :root ROOT :thread-ids IDS :files
FILES) where TYPE is one of `created', `updated', `deleted',
`cleared', `anchors-updated' and `reloaded'.")

(defvar claude-emacs-annotate-store-before-mutate-hook nil
  "Hook run with the store as argument before every mutation.
The view layer uses this to flush pending live-buffer positions so
mutations always operate on fresh anchors.")

(defvar claude-emacs-annotate--stores (make-hash-table :test #'equal)
  "Registry of loaded stores, keyed by canonical project root.")

(cl-defstruct (claude-emacs-annotate-store
               (:constructor claude-emacs-annotate-store--create)
               (:conc-name claude-emacs-annotate-store--)
               (:copier nil))
  "In-memory annotation store of one project."
  root path threads by-file tombstones mtime size
  watch-desc watch-timer disk-missing)

(defun claude-emacs-annotate-store-root (store)
  "Return STORE's canonical project root."
  (claude-emacs-annotate-store--root store))

;;;; Roots and paths

(defun claude-emacs-annotate--default-project-root (&optional dir)
  "Return the project root of DIR, or nil when DIR is in no project.
DIR defaults to `default-directory'.  Tries `project-current' first
and falls back to `vc-git-root'."
  (let ((default-directory (or dir default-directory)))
    (or (when-let* ((project (project-current nil)))
          (expand-file-name (project-root project)))
        (when-let* ((root (vc-git-root default-directory)))
          (expand-file-name root)))))

(defcustom claude-emacs-annotate-project-root-function
  #'claude-emacs-annotate--default-project-root
  "Function returning the project root for a directory.
Called with one optional argument, a directory (defaulting to
`default-directory'), and expected to return an absolute directory
name or nil when the directory belongs to no project."
  :type 'function
  :group 'claude-emacs-annotate)

(defun claude-emacs-annotate--normalize-root (root)
  "Return the canonical form of the project ROOT.
Resolves symlinks via `file-truename' and drops any trailing slash so
that every path spelling of the same project keys the same store."
  (unless (and (stringp root) (not (string-empty-p root)))
    (signal 'claude-emacs-annotate-invalid
            (list "project root must be a non-empty string")))
  (directory-file-name (file-truename (expand-file-name root))))

(defun claude-emacs-annotate-project-root (&optional dir)
  "Return the canonical project root of DIR, or nil outside a project.
DIR defaults to `default-directory'; resolution goes through
`claude-emacs-annotate-project-root-function'."
  (when-let* ((root (funcall claude-emacs-annotate-project-root-function dir)))
    (claude-emacs-annotate--normalize-root root)))

(defun claude-emacs-annotate-store-path (root)
  "Return the database file path for the project ROOT.
The file name is the canonical root with `!' doubled and `/' replaced
by `!', the same transform Emacs uses for auto-save file names."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (sanitized (replace-regexp-in-string
                     "/" "!"
                     (replace-regexp-in-string "!" "!!" canon nil t)
                     nil t)))
    (expand-file-name (concat sanitized ".eld")
                      claude-emacs-annotate-directory)))

;;;; Reading and validating the on-disk form

(defun claude-emacs-annotate--store-read (path)
  "Read and validate the database file at PATH; return its plist.
Signal `claude-emacs-annotate-io-error' for unreadable content and
`claude-emacs-annotate-schema-error' for unknown schema shapes or
versions.  The file is never modified by a failed read."
  (let ((data (condition-case err
                  (with-temp-buffer
                    (insert-file-contents path)
                    (read (current-buffer)))
                (error
                 (signal 'claude-emacs-annotate-io-error
                         (list (format "cannot read %s: %s" path
                                       (error-message-string err))))))))
    (unless (and (listp data) (keywordp (car-safe data)))
      (signal 'claude-emacs-annotate-schema-error
              (list (format "%s: not an annotation database" path))))
    (let ((version (plist-get data :version)))
      (unless (integerp version)
        (signal 'claude-emacs-annotate-schema-error
                (list (format "%s: missing schema version" path))))
      (unless (= version 1)
        (signal 'claude-emacs-annotate-schema-error
                (list (format
                       "%s: schema version %d is newer than supported (1)"
                       path version)))))
    (unless (proper-list-p (plist-get data :threads))
      (signal 'claude-emacs-annotate-schema-error
              (list (format "%s: malformed thread list" path))))
    (dolist (thread (plist-get data :threads))
      (unless (and (proper-list-p thread)
                   (keywordp (car-safe thread))
                   (stringp (plist-get thread :id))
                   (let ((anchor (plist-get thread :anchor)))
                     (or (null anchor)
                         (and (proper-list-p anchor)
                              (keywordp (car-safe anchor))))))
        (signal 'claude-emacs-annotate-schema-error
                (list (format "%s: malformed thread record" path)))))
    (unless (proper-list-p (plist-get data :tombstones))
      (signal 'claude-emacs-annotate-schema-error
              (list (format "%s: malformed tombstone list" path))))
    (dolist (tomb (plist-get data :tombstones))
      (unless (and (proper-list-p tomb)
                   (keywordp (car-safe tomb))
                   (stringp (plist-get tomb :id))
                   (stringp (plist-get tomb :deleted)))
        (signal 'claude-emacs-annotate-schema-error
                (list (format "%s: malformed tombstone record" path)))))
    (dolist (thread (plist-get data :threads))
      (when-let* ((anchor (plist-get thread :anchor)))
        (plist-put anchor :state
                   (claude-emacs-annotate--normalize-anchor-state
                    (plist-get anchor :state)))))
    data))

(defun claude-emacs-annotate--normalize-anchor-state (state)
  "Map STATE onto the two-state model.
Anything but `fresh' counts as stale, so an unrecognized state
surfaces rather than passing as current."
  (if (eq state 'fresh) 'fresh 'stale))

;;;; Serialization

(defun claude-emacs-annotate--store-sorted-threads (store)
  "Return STORE's threads as a deterministically sorted list."
  (let (threads)
    (maphash (lambda (_id thread) (push thread threads))
             (claude-emacs-annotate-store--threads store))
    (sort threads
          (lambda (a b)
            (let ((created-a (plist-get a :created))
                  (created-b (plist-get b :created)))
              (if (equal created-a created-b)
                  (string< (plist-get a :id) (plist-get b :id))
                (string< created-a created-b)))))))

(defun claude-emacs-annotate--store-sorted-tombstones (store)
  "Return STORE's tombstones as a deterministically sorted plist list."
  (let (tombs)
    (maphash (lambda (id deleted)
               (push (list :id id :deleted deleted) tombs))
             (claude-emacs-annotate-store--tombstones store))
    (sort tombs (lambda (a b) (string< (plist-get a :id)
                                       (plist-get b :id))))))

(defun claude-emacs-annotate--store-serialize (store)
  "Return STORE's full serializable plist."
  (list :version 1
        :root (claude-emacs-annotate-store--root store)
        :threads (claude-emacs-annotate--store-sorted-threads store)
        :tombstones (claude-emacs-annotate--store-sorted-tombstones store)))

(defun claude-emacs-annotate--store-in-sync-p (store disk)
  "Return non-nil when STORE's memory equals the DISK plist."
  (and (equal (claude-emacs-annotate--store-sorted-threads store)
              (plist-get disk :threads))
       (equal (claude-emacs-annotate--store-sorted-tombstones store)
              (plist-get disk :tombstones))))

;;;; Indexes

(defun claude-emacs-annotate--store-reindex (store)
  "Rebuild STORE's file index from its thread table."
  (let ((by-file (make-hash-table :test #'equal)))
    (dolist (thread (claude-emacs-annotate--store-sorted-threads store))
      (let ((file (plist-get thread :file)))
        (puthash file
                 (append (gethash file by-file)
                         (list (plist-get thread :id)))
                 by-file)))
    (setf (claude-emacs-annotate-store--by-file store) by-file)))

;;;; Loading

(defun claude-emacs-annotate--store-adopt (store data)
  "Replace STORE's memory with the disk plist DATA."
  (let ((threads (make-hash-table :test #'equal))
        (tombstones (make-hash-table :test #'equal)))
    (dolist (thread (plist-get data :threads))
      (puthash (plist-get thread :id) thread threads))
    (dolist (tomb (plist-get data :tombstones))
      (puthash (plist-get tomb :id) (plist-get tomb :deleted) tombstones))
    (setf (claude-emacs-annotate-store--threads store) threads)
    (setf (claude-emacs-annotate-store--tombstones store) tombstones)
    (claude-emacs-annotate--store-reindex store)))

(defun claude-emacs-annotate--store-cache-file-state (store)
  "Record the database file's current mtime and size in STORE."
  (let ((attributes (file-attributes
                     (claude-emacs-annotate-store--path store))))
    (setf (claude-emacs-annotate-store--mtime store)
          (file-attribute-modification-time attributes))
    (setf (claude-emacs-annotate-store--size store)
          (and attributes (file-attribute-size attributes)))))

(defun claude-emacs-annotate--store-gc-temps (path)
  "Delete stale temp files left next to PATH by interrupted writes."
  (let ((directory (file-name-directory path))
        (pattern (concat "\\`" (regexp-quote
                                (file-name-nondirectory path))
                         "\\.tmp-"))
        (cutoff (time-subtract nil (* 60 60))))
    (when (file-directory-p directory)
      (dolist (stale (directory-files directory t pattern t))
        (when (time-less-p (file-attribute-modification-time
                            (file-attributes stale))
                           cutoff)
          (ignore-errors (delete-file stale)))))))

(defun claude-emacs-annotate-store-get (root &optional no-create)
  "Return the store for the project ROOT, loading it on first use.
With NO-CREATE non-nil, return nil instead of creating a fresh store
when neither a loaded store nor a database file exists."
  (let* ((canon (claude-emacs-annotate--normalize-root root))
         (existing (gethash canon claude-emacs-annotate--stores)))
    (or existing
        (let ((path (claude-emacs-annotate-store-path canon)))
          (when (or (not no-create) (file-exists-p path))
            (let ((store (claude-emacs-annotate-store--create
                          :root canon
                          :path path
                          :threads (make-hash-table :test #'equal)
                          :by-file (make-hash-table :test #'equal)
                          :tombstones (make-hash-table :test #'equal))))
              (claude-emacs-annotate--store-gc-temps path)
              (when (file-exists-p path)
                (claude-emacs-annotate--store-adopt
                 store (claude-emacs-annotate--store-read path))
                (claude-emacs-annotate--store-cache-file-state store))
              (puthash canon store claude-emacs-annotate--stores)
              (when claude-emacs-annotate-use-file-watcher
                (claude-emacs-annotate--store-watch store))
              store))))))

;;;; Atomic writes

(defun claude-emacs-annotate--store-write (store)
  "Persist STORE atomically to its database file.
Writes a temp file in the same directory and renames it over the
target; failures signal `claude-emacs-annotate-io-error'."
  (let* ((path (claude-emacs-annotate-store--path store))
         (directory (file-name-directory path)))
    (claude-emacs-annotate--store-gc-tombstones store)
    (condition-case err
        (progn
          (make-directory directory t)
          (let ((temp (make-temp-file (concat path ".tmp-"))))
            (unwind-protect
                (progn
                  (with-temp-file temp
                    (let ((print-length nil)
                          (print-level nil)
                          (print-circle t)
                          (coding-system-for-write 'utf-8-unix))
                      (insert ";; -*- mode: lisp-data; coding: utf-8-unix -*-\n"
                              ";; claude-emacs-annotate project database."
                              "  Machine-written; do not hand-edit while"
                              " Emacs is running.\n")
                      (prin1 (claude-emacs-annotate--store-serialize store)
                             (current-buffer))
                      (insert "\n")))
                  (when (file-exists-p path)
                    (set-file-modes temp (file-modes path)))
                  (rename-file temp path t))
              (when (file-exists-p temp)
                (ignore-errors (delete-file temp))))))
      (error
       (signal 'claude-emacs-annotate-io-error
               (list (format "cannot write %s: %s" path
                             (error-message-string err))))))
    (claude-emacs-annotate--store-cache-file-state store)
    (setf (claude-emacs-annotate-store--disk-missing store) nil)))

(defun claude-emacs-annotate--store-gc-tombstones (store)
  "Drop STORE's tombstones older than the configured TTL."
  (let ((cutoff (claude-emacs-annotate--timestamp
                 (time-subtract
                  nil (days-to-time claude-emacs-annotate-tombstone-ttl-days))))
        (tombstones (claude-emacs-annotate-store--tombstones store))
        expired)
    (maphash (lambda (id deleted)
               (when (string< deleted cutoff) (push id expired)))
             tombstones)
    (dolist (id expired) (remhash id tombstones))))

;;;; Merging divergent state

(defun claude-emacs-annotate--store-merge-live (mine theirs)
  "Merge two live copies MINE and THEIRS of the same thread.
The copy with the greater `:updated' stamp wins scalars and anchor;
exact ties break deterministically on the serialized form.  Comments
are unioned by id so concurrent replies all survive."
  (let* ((my-stamp (plist-get mine :updated))
         (their-stamp (plist-get theirs :updated))
         (winner (cond ((string< my-stamp their-stamp) theirs)
                       ((string< their-stamp my-stamp) mine)
                       ((string< (prin1-to-string mine)
                                 (prin1-to-string theirs))
                        theirs)
                       (t mine)))
         (loser (if (eq winner mine) theirs mine))
         (seen (mapcar (lambda (comment) (plist-get comment :id))
                       (plist-get winner :comments)))
         (extra (seq-remove (lambda (comment)
                              (member (plist-get comment :id) seen))
                            (plist-get loser :comments))))
    (if (null extra)
        winner
      (let ((merged (copy-sequence winner)))
        (plist-put merged :comments
                   (append (plist-get winner :comments)
                           (sort extra
                                 (lambda (a b)
                                   (string< (or (plist-get a :timestamp) "")
                                            (or (plist-get b :timestamp) ""))))))
        merged))))

(defun claude-emacs-annotate--store-merge (store disk)
  "Merge the DISK plist into STORE's memory; return changed thread ids.
Per thread id the newer of live record and tombstone wins; on a
timestamp tie the tombstone wins (deletion is deliberate).  A live
record strictly newer than a tombstone resurrects the thread."
  (let ((mem-threads (claude-emacs-annotate-store--threads store))
        (mem-tombs (claude-emacs-annotate-store--tombstones store))
        (disk-threads (make-hash-table :test #'equal))
        (disk-tombs (make-hash-table :test #'equal))
        (ids (make-hash-table :test #'equal))
        (changed nil))
    (dolist (thread (plist-get disk :threads))
      (puthash (plist-get thread :id) thread disk-threads))
    (dolist (tomb (plist-get disk :tombstones))
      (puthash (plist-get tomb :id) (plist-get tomb :deleted) disk-tombs))
    (dolist (table (list mem-threads mem-tombs disk-threads disk-tombs))
      (maphash (lambda (id _value) (puthash id t ids)) table))
    (maphash
     (lambda (id _)
       (let* ((mem-live (gethash id mem-threads))
              (mem-tomb (gethash id mem-tombs))
              (live (cond ((and mem-live (gethash id disk-threads))
                           (claude-emacs-annotate--store-merge-live
                            mem-live (gethash id disk-threads)))
                          (mem-live)
                          ((gethash id disk-threads))))
              (tomb (let ((a mem-tomb) (b (gethash id disk-tombs)))
                      (cond ((and a b) (if (string< a b) b a))
                            (a)
                            (b)))))
         (cond
          ;; Tombstone wins unless the live record is strictly newer.
          ((and tomb (or (null live)
                         (not (string< tomb (plist-get live :updated)))))
           (when mem-live
             (remhash id mem-threads)
             (push id changed))
           (unless (equal mem-tomb tomb)
             (puthash id tomb mem-tombs)))
          (live
           (when mem-tomb (remhash id mem-tombs))
           (unless (equal mem-live live)
             (puthash id live mem-threads)
             (push id changed))))))
     ids)
    (when changed
      (claude-emacs-annotate--store-reindex store))
    changed))

;;;; Refresh (the mtime guard)

(defun claude-emacs-annotate--store-refresh-internal (store)
  "Reconcile STORE with its file if it changed on disk.
Return a plist (:events EVENTS :dirty DIRTY) where EVENTS are pending
change events and DIRTY means memory now differs from disk and a
write is required."
  (let ((path (claude-emacs-annotate-store--path store)))
    (cond
     ((not (file-exists-p path))
      (cond
       ;; We never had a file: dirty only if there is something to write.
       ((null (claude-emacs-annotate-store--mtime store))
        (list :events nil
              :dirty (> (hash-table-count
                         (claude-emacs-annotate-store--threads store))
                        0)))
       (t
        (unless (claude-emacs-annotate-store--disk-missing store)
          (setf (claude-emacs-annotate-store--disk-missing store) t)
          (display-warning
           'claude-emacs-annotate
           (format "database file disappeared: %s (keeping memory state)"
                   path)))
        (list :events nil :dirty t))))
     (t
      (let* ((attributes (file-attributes path))
             (mtime (file-attribute-modification-time attributes))
             (size (file-attribute-size attributes)))
        (if (and (claude-emacs-annotate-store--mtime store)
                 (time-equal-p mtime (claude-emacs-annotate-store--mtime store))
                 (equal size (claude-emacs-annotate-store--size store)))
            (list :events nil :dirty nil)
          (let* ((disk (claude-emacs-annotate--store-read path))
                 (changed (claude-emacs-annotate--store-merge store disk)))
            (setf (claude-emacs-annotate-store--mtime store) mtime)
            (setf (claude-emacs-annotate-store--size store) size)
            (setf (claude-emacs-annotate-store--disk-missing store) nil)
            (list :events
                  (when changed
                    (list (claude-emacs-annotate--store-event
                           store 'reloaded changed
                           (claude-emacs-annotate--store-files-of
                            store changed))))
                  :dirty (not (claude-emacs-annotate--store-in-sync-p
                               store disk))))))))))

(defun claude-emacs-annotate--store-files-of (store ids)
  "Return the distinct files of the threads IDS in STORE.
Ids no longer present (deleted by a merge) contribute nothing."
  (seq-uniq
   (delq nil
         (mapcar (lambda (id)
                   (when-let* ((thread (gethash
                                        id
                                        (claude-emacs-annotate-store--threads
                                         store))))
                     (plist-get thread :file)))
                 ids))))

;;;; The mutation gate

(defun claude-emacs-annotate-store-mutate (store fn)
  "Run the mutation FN on STORE through the full write-through cycle.
Runs `claude-emacs-annotate-store-before-mutate-hook', reconciles
external changes, calls FN (which mutates via the store helpers and
returns one event plist, a list of them, or nil), persists when
anything changed, and dispatches all events.  Returns FN's events."
  (run-hook-with-args 'claude-emacs-annotate-store-before-mutate-hook store)
  (let* ((refresh (claude-emacs-annotate--store-refresh-internal store))
         (result (funcall fn))
         (events (cond ((null result) nil)
                       ((keywordp (car result)) (list result))
                       (t result))))
    (when (or events (plist-get refresh :dirty))
      (claude-emacs-annotate--store-write store))
    (dolist (event (append (plist-get refresh :events) events))
      (run-hook-with-args 'claude-emacs-annotate-changed-hook event))
    events))

(defun claude-emacs-annotate-store-refresh (store)
  "Reconcile STORE with its file, merging and persisting differences."
  (claude-emacs-annotate-store-mutate store #'ignore))

;;;; Mutation helpers (call within `claude-emacs-annotate-store-mutate')

(defun claude-emacs-annotate--map-buffers (fn)
  "Call FN with each live buffer current.
The event handlers refreshing thread, table and file views all walk
the buffer list this way; the per-view conditions stay with them.
The liveness check is load-bearing: FN runs reverts and mode hooks
that may kill buffers later in the snapshot."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (funcall fn)))))

(defun claude-emacs-annotate--store-event (store type ids files)
  "Build a change event plist for STORE with TYPE, thread IDS and FILES."
  (list :type type
        :root (claude-emacs-annotate-store--root store)
        :thread-ids ids
        :files files))

(defun claude-emacs-annotate-store-insert-thread (store thread)
  "Insert THREAD into STORE; return the change event."
  (let ((id (plist-get thread :id))
        (file (plist-get thread :file)))
    (when (gethash id (claude-emacs-annotate-store--threads store))
      (signal 'claude-emacs-annotate-conflict
              (list (format "thread %s already exists" id))))
    (remhash id (claude-emacs-annotate-store--tombstones store))
    (puthash id thread (claude-emacs-annotate-store--threads store))
    (claude-emacs-annotate--store-reindex store)
    (claude-emacs-annotate--store-event store 'created
                                        (list id) (list file))))

(defun claude-emacs-annotate-store-delete-thread (store id &optional cleared)
  "Delete thread ID from STORE, leaving a tombstone.
Return the change event, typed `cleared' when CLEARED is non-nil."
  (let ((thread (gethash id (claude-emacs-annotate-store--threads store))))
    (unless thread
      (signal 'claude-emacs-annotate-not-found
              (list (format "no thread with id %s in this project" id))))
    (let ((file (plist-get thread :file)))
      (remhash id (claude-emacs-annotate-store--threads store))
      ;; The tombstone must outrank the record it deletes, or a merge
      ;; against a writer still holding the record live resurrects it.
      (puthash id (let ((now (claude-emacs-annotate--timestamp))
                        (updated (plist-get thread :updated)))
                    (if (and updated (not (string< updated now)))
                        (claude-emacs-annotate--timestamp-after updated)
                      now))
               (claude-emacs-annotate-store--tombstones store))
      (claude-emacs-annotate--store-reindex store)
      (claude-emacs-annotate--store-event store (if cleared 'cleared 'deleted)
                                          (list id) (list file)))))

(defun claude-emacs-annotate-store-update-thread (store thread)
  "Record THREAD (already mutated in place) as updated in STORE.
Bumps the `:updated' stamp and returns the change event."
  (let* ((id (plist-get thread :id))
         (current (gethash id (claude-emacs-annotate-store--threads store))))
    (unless current
      (signal 'claude-emacs-annotate-not-found
              (list (format "no thread with id %s in this project" id))))
    (claude-emacs-annotate-thread-touch thread)
    (unless (eq current thread)
      (puthash id thread (claude-emacs-annotate-store--threads store))
      (unless (equal (plist-get current :file) (plist-get thread :file))
        (claude-emacs-annotate--store-reindex store)))
    (claude-emacs-annotate--store-event store 'updated
                                        (list id)
                                        (list (plist-get thread :file)))))

(defun claude-emacs-annotate-store-update-anchors (store updates)
  "Set per-thread anchors in STORE.
UPDATES is an alist of (THREAD-ID . ANCHOR).  Thread ids that
vanished meanwhile are skipped silently (a live buffer may flush
moments after a deletion).  Return the change event, or nil when
nothing applied."
  (let (ids files)
    (dolist (update updates)
      (when-let* ((thread (gethash (car update)
                                   (claude-emacs-annotate-store--threads
                                    store))))
        (plist-put thread :anchor (cdr update))
        (claude-emacs-annotate-thread-touch thread)
        (push (car update) ids)
        (push (plist-get thread :file) files)))
    (when ids
      (claude-emacs-annotate--store-event store 'anchors-updated
                                          (nreverse ids)
                                          (seq-uniq (nreverse files))))))

;;;; Reads

(defun claude-emacs-annotate-store-thread (store id)
  "Return the thread with ID in STORE, or nil."
  (gethash id (claude-emacs-annotate-store--threads store)))

(defun claude-emacs-annotate-store-all-threads (store)
  "Return all of STORE's threads, deterministically ordered."
  (claude-emacs-annotate--store-sorted-threads store))

(defun claude-emacs-annotate-store-threads-for-file (store file)
  "Return STORE's threads anchored in the project-relative FILE."
  (mapcar (lambda (id)
            (gethash id (claude-emacs-annotate-store--threads store)))
          (gethash file (claude-emacs-annotate-store--by-file store))))

;;;; File watching

(defun claude-emacs-annotate--store-watch (store)
  "Start watching STORE's database directory for external writes."
  (unless (claude-emacs-annotate-store--watch-desc store)
    (let ((directory (file-name-directory
                      (claude-emacs-annotate-store--path store))))
      (ignore-errors (make-directory directory t))
      (when (file-directory-p directory)
        (condition-case nil
            (setf (claude-emacs-annotate-store--watch-desc store)
                  (file-notify-add-watch
                   directory '(change)
                   (lambda (event)
                     (claude-emacs-annotate--store-watch-callback
                      store event))))
          (file-notify-error nil))))))

(defun claude-emacs-annotate--store-watch-callback (store event)
  "Debounce a file-notify EVENT for STORE's database file.
Atomic writes arrive as rename events whose target is the fourth
element; both file slots are checked."
  (let ((path (claude-emacs-annotate-store--path store))
        (file (nth 2 event))
        (target (nth 3 event)))
    (when (or (and (stringp file)
                   (string= (expand-file-name file) path))
              (and (stringp target)
                   (string= (expand-file-name target) path)))
      (when (timerp (claude-emacs-annotate-store--watch-timer store))
        (cancel-timer (claude-emacs-annotate-store--watch-timer store)))
      (setf (claude-emacs-annotate-store--watch-timer store)
            (run-with-timer
             0.5 nil
             (lambda ()
               (setf (claude-emacs-annotate-store--watch-timer store) nil)
               (condition-case err
                   ;; Refresh no-ops when the change was our own write
                   ;; (cached mtime matches).
                   (claude-emacs-annotate-store-refresh store)
                 (error
                  (display-warning
                   'claude-emacs-annotate
                   (format "auto-refresh failed: %s"
                           (error-message-string err)))))))))))

(defun claude-emacs-annotate-store-shutdown (store)
  "Stop STORE's watcher and timers and drop it from the registry."
  (when (timerp (claude-emacs-annotate-store--watch-timer store))
    (cancel-timer (claude-emacs-annotate-store--watch-timer store))
    (setf (claude-emacs-annotate-store--watch-timer store) nil))
  (when (claude-emacs-annotate-store--watch-desc store)
    (ignore-errors
      (file-notify-rm-watch (claude-emacs-annotate-store--watch-desc store)))
    (setf (claude-emacs-annotate-store--watch-desc store) nil))
  (remhash (claude-emacs-annotate-store--root store)
           claude-emacs-annotate--stores))

(defun claude-emacs-annotate-store-shutdown-all ()
  "Shut down every loaded store."
  (let (stores)
    (maphash (lambda (_root store) (push store stores))
             claude-emacs-annotate--stores)
    (mapc #'claude-emacs-annotate-store-shutdown stores)))

(provide 'claude-emacs-annotate-store)
;;; claude-emacs-annotate-store.el ends here
