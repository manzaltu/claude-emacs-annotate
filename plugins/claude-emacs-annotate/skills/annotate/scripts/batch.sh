#!/usr/bin/env bash
# Create many annotations authored by ANNOTATE_AUTHOR (see lib.sh) in a
# single Emacs round-trip.
#
# Reads TSV records from stdin, one per line:
#     <abs-file><TAB><start-line><TAB><end-line><TAB><annotation-text>
#
# - Text MUST NOT contain literal TAB. Embedded newlines: encode as two-char
#   sequence "\n" (backslash + n); the script decodes them back to newlines
#   before sending to Emacs.
# - Records with empty/blank lines are skipped silently.
# - Each annotation is wrapped in a simply-annotate thread with
#   author=ANNOTATE_AUTHOR and status="open".
#
# Output: a sexp like
#     (:created 145 :failed 0 :files-touched 29
#      :failures (("/abs/foo" 12 12 "no such line range") ...))
#
# This is much faster than calling annotate.sh per record (one emacsclient
# invocation instead of N) and gathers all errors in one pass.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# Build the elisp records list while reading stdin. We escape each piece for
# inclusion in elisp (elisp_quote handles backslashes and double quotes).
records_elisp=""
n=0
while IFS=$'\t' read -r file sline eline text; do
  # Skip blank lines.
  [[ -z "${file:-}" && -z "${sline:-}" && -z "${eline:-}" && -z "${text:-}" ]] && continue
  [[ -z "${file:-}" || -z "${sline:-}" || -z "${eline:-}" || -z "${text:-}" ]] \
    && die "malformed record (need 4 TAB-separated fields): file='$file' sline='$sline' eline='$eline' text='${text:0:40}'"
  [[ "$sline" =~ ^[0-9]+$ ]] || die "start-line must be a positive integer: $sline (file=$file)"
  [[ "$eline" =~ ^[0-9]+$ ]] || die "end-line must be a positive integer: $eline (file=$file)"
  (( sline >= 1 && eline >= sline )) || die "invalid line range: $sline..$eline (file=$file)"

  # Decode literal "\n" -> newline. Other backslash sequences pass through.
  # Use a Python helper to keep the decoding deterministic and safe.
  decoded=$(printf '%s' "$text" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("\\n","\n"))')

  qfile=$(elisp_quote "$file")
  qtext=$(elisp_quote "$decoded")
  records_elisp+=$'\n      (list '"$qfile"' '"$sline"' '"$eline"' '"$qtext"')'
  n=$((n + 1))
done

[[ $n -gt 0 ]] || { printf '(:created 0 :failed 0 :files-touched 0 :failures nil)\n'; exit 0; }

emacs_eval <<EOF
(let* ((records (list${records_elisp}))
       (created 0)
       (failed 0)
       (failures nil)
       (touched-files (make-hash-table :test 'equal))
       (open-buffers (make-hash-table :test 'equal))
       (buffers-we-created nil))
  (unwind-protect
      (dolist (rec records)
        (let* ((file (nth 0 rec))
               (sline (nth 1 rec))
               (eline (nth 2 rec))
               (text (nth 3 rec))
               (existing (find-buffer-visiting file))
               (buf (or (gethash file open-buffers)
                        existing
                        (let ((b (find-file-noselect file)))
                          (push b buffers-we-created)
                          b))))
          (puthash file buf open-buffers)
          (condition-case err
              (with-current-buffer buf
                (unless simply-annotate-mode (simply-annotate-mode 1))
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (point-min))
                    (forward-line (1- sline))
                    (let ((start (line-beginning-position)))
                      (goto-char (point-min))
                      (forward-line (1- eline))
                      (let* ((end (line-end-position))
                             (thread (simply-annotate--create-thread
                                      text "${ANNOTATE_AUTHOR}")))
                        ;; Force open: some installs ship a stale
                        ;; create-thread that defaults to "closed".
                        (setf (alist-get 'status thread) "open")
                        (let ((ov (simply-annotate--create-overlay
                                   start end thread)))
                          (push ov simply-annotate-overlays)
                          (puthash file t touched-files)
                          (setq created (1+ created))))))))
            (error
             (setq failed (1+ failed))
             (push (list file sline eline (error-message-string err)) failures)))))
    ;; One save per touched file, after all overlays are in place.
    (maphash
     (lambda (file _v)
       (let ((buf (gethash file open-buffers)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (simply-annotate--save-annotations)))))
     touched-files)
    ;; Close buffers we opened that weren't dirtied by the save.
    (dolist (b buffers-we-created)
      (when (buffer-live-p b)
        (unless (buffer-modified-p b) (kill-buffer b)))))
  (list :created created
        :failed failed
        :files-touched (hash-table-count touched-files)
        :failures (nreverse failures)))
EOF
