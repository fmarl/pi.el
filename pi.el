;;; pi.el --- Talk to the Pi coding agent -*- lexical-binding: t; -*-

;; SPDX-FileCopyrightText: 2026 Florian Marrero Liestmann
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Florian Marrero Liestmann <f.m.liestmann@fx-ttr.de>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/fmarl/pi.el

;;; Commentary:

;; Emacs <-> Pi bridge

;;; Code:

(require 'filenotify)
(require 'seq)
(require 'subr-x)
(require 'xdg)

(defgroup pi nil
  "Talk to the Pi coding agent next to Emacs."
  :group 'tools
  :prefix "pi-")

(defun pi-secret-file-p (file)
  "Return non-nil if FILE looks like it holds credentials."
  (string-match-p
   (rx (or (seq "/." (or "aws" "gnupg" "kube" "password-store" "ssh") "/")
           "/secrets/"
           (seq "/." (or "authinfo" "netrc") (? ".gpg") eos)
           (seq ".env" (? "." (* (not "/"))) eos)))
   file))

(defcustom pi-secret-file-predicate #'pi-secret-file-p
  "Function of a file name that returns non-nil if the file holds secrets.
`pi-context-json' does not show Pi the region of such a file."
  :type '(choice (function-item pi-secret-file-p) function))

(defcustom pi-timeout 5
  "Seconds to wait for Pi to answer a request."
  :type 'number)

(defcustom pi-mode-line-lighter " π"
  "What `pi-mode' shows in the mode line while a Pi serves the buffer.
While Pi runs a tool, the tool and its file follow after a colon."
  :type 'string)

(defvar pi-bridge-directory
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (expand-file-name "pi/emacs/"
                      (if (and runtime (file-name-absolute-p runtime))
                          runtime
                        (xdg-cache-home))))
  "Directory in which the emacs-bridge extension puts sockets and states.")

(defconst pi--max-region-bytes 20000
  "UTF-8 bytes of the region `pi-context-json' shows at most.")

(defconst pi--max-diagnostics 50
  "Diagnostics `pi-context-json' shows at most.")

(defvar pi--comments (make-hash-table :test #'equal)
  "Review comments not sent yet, newest first, by the directory of their Pi.")

(defvar pi--states (make-hash-table :test #'equal)
  "The last state each Pi reported, by its status file.")

(defvar pi--generation 0
  "Counts Pis starting and stopping; a new value invalidates `pi--cache'.")

(defvar pi--watch nil)

(defvar pi--history nil)

(defvar-local pi--cache nil
  "(DEFAULT-DIRECTORY GENERATION . STATUS-FILE) of the buffer's last lookup.")

;;;; Finding the Pi for a buffer

(defun pi--key (directory)
  "Return the name the bridge gives the Pi serving DIRECTORY."
  (secure-hash 'sha1 (encode-coding-string
                      (directory-file-name (file-truename directory))
                      'utf-8)))

(defun pi--file (directory extension)
  "Return the bridge file with EXTENSION of the Pi serving DIRECTORY."
  (expand-file-name (concat (pi--key directory) extension) pi-bridge-directory))

(defun pi--answers-p (socket)
  "Return non-nil if something listens on SOCKET."
  (condition-case nil
      (progn
        (delete-process (make-network-process :name "pi-probe" :family 'local
                                              :service socket :noquery t
                                              :sentinel #'ignore))
        t)
    (file-error nil)))

(defun pi--find-served-directory (directory)
  "Return the nearest of DIRECTORY and its parents that a Pi serves, or nil."
  (unless (file-remote-p directory)
    (when-let* ((found (locate-dominating-file
                        (file-truename directory)
                        (lambda (parent)
                          ;; A Pi that crashed leaves its socket behind.
                          (let ((socket (pi--file parent ".sock")))
                            (and (file-exists-p socket)
                                 (pi--answers-p socket)))))))
      (file-truename found))))

(defun pi--require-directory ()
  "Return the directory the Pi of this buffer serves, or signal an error."
  (or (pi--find-served-directory default-directory)
      (user-error "No Pi serves %s" (abbreviate-file-name default-directory))))

(defun pi--status-file ()
  "Return the status file of the Pi serving this buffer, or nil.
Cache it until a Pi starts or stops, as the mode line asks often."
  (unless (and (equal (car pi--cache) default-directory)
               (eql (cadr pi--cache) pi--generation))
    (setq pi--cache
          (cons default-directory
                (cons pi--generation
                      (when-let* ((directory (pi--find-served-directory
                                              default-directory)))
                        (pi--file directory ".json"))))))
  (cddr pi--cache))

;;;; Requests

(defun pi--send (directory request)
  "Send REQUEST, an alist, to the Pi serving DIRECTORY and return its data."
  (let ((socket (pi--file directory ".sock"))
        (buffer (generate-new-buffer " *pi-request*" t))
        process)
    (unwind-protect
        (progn
          (setq process
                (condition-case err
                    (make-network-process :name "pi-request" :family 'local
                                          :service socket :buffer buffer
                                          :coding 'utf-8 :noquery t
                                          :sentinel #'ignore)
                  (file-error
                   (user-error "Pi is not answering on %s: %s"
                               socket (error-message-string err)))))
          ;; Pi answers and closes before reading all of a request it
          ;; refuses, such as one too large; its answer is still there.
          (ignore-error error
            (process-send-string process
                                 (concat (json-serialize request) "\n")))
          (with-current-buffer buffer
            (with-timeout (pi-timeout (user-error "Pi did not answer"))
              (while (progn (goto-char (point-min))
                            (not (search-forward "\n" nil t)))
                (unless (process-live-p process)
                  (user-error "Pi closed the connection without an answer"))
                (accept-process-output process 0.1)))
            (let ((response (json-parse-string
                             (buffer-substring (point-min) (point))
                             :object-type 'alist :array-type 'list)))
              (unless (eq (alist-get 'ok response) t)
                (user-error "Pi: %s" (alist-get 'error response)))
              (alist-get 'data response))))
      (when process
        (delete-process process))
      (kill-buffer buffer))))

(defun pi--prompt (directory text steer)
  "Send TEXT to the Pi serving DIRECTORY; STEER is as in `pi-prompt'."
  (pi--send directory `((type . "prompt") (text . ,text)
                        (deliverAs . ,(if steer "steer" "followUp"))))
  (message "Sent to Pi"))

(defun pi--read-prompt (&optional initial)
  "Read a prompt for Pi, starting with INITIAL."
  (read-string "Pi: " initial 'pi--history))

;;;###autoload
(defun pi-prompt (text &optional steer)
  "Send TEXT to Pi.
Pi takes it up once it is done or, with STEER (interactively, the
prefix argument), right after its current tool step."
  (interactive (progn (pi--require-directory)
                      (list (pi--read-prompt) current-prefix-arg)))
  (pi--prompt (pi--require-directory) text steer))

;;;###autoload
(defun pi-abort ()
  "Abort what Pi is doing."
  (interactive)
  (pi--send (pi--require-directory) '((type . "abort")))
  (message "Pi aborted"))

;;;###autoload
(defun pi-new-session ()
  "Make Pi start a new session."
  (interactive)
  (pi--send (pi--require-directory) '((type . "new")))
  (message "Pi starts a new session"))

(defun pi--commands (directory)
  "Return the commands of the Pi serving DIRECTORY as (NAME . DESCRIPTION)."
  (mapcar (lambda (command)
            (cons (alist-get 'name command) (alist-get 'description command)))
          (alist-get 'commands (pi--send directory '((type . "commands"))))))

;;;###autoload
(defun pi-run-command (command arguments &optional steer)
  "Run Pi's COMMAND with ARGUMENTS, a string.
STEER is as in `pi-prompt'."
  (interactive
   (let* ((commands (pi--commands (pi--require-directory)))
          (completion-extra-properties
           (list :annotation-function
                 (lambda (name)
                   (when-let* ((description (cdr (assoc name commands))))
                     (concat "  " description))))))
     (list (completing-read "Pi command: " commands nil t)
           (read-string "Arguments: ")
           current-prefix-arg)))
  (pi--prompt (pi--require-directory)
              (string-trim (format "/%s %s" command arguments))
              steer))

;;;###autoload
(defun pi-last-text ()
  "Return Pi's last answer, or nil if it has not answered yet."
  (let ((text (alist-get 'text (pi--send (pi--require-directory)
                                         '((type . "last"))))))
    (unless (eq text :null)
      text)))

;;;###autoload
(defun pi-last ()
  "Show Pi's last answer."
  (interactive)
  (if-let* ((text (pi-last-text)))
      (with-current-buffer (get-buffer-create "*Pi*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text))
        (special-mode)
        (goto-char (point-min))
        (display-buffer (current-buffer)))
    (message "Pi has not answered yet")))

;;;; Locations

(declare-function magit-section-at "magit-section")
(declare-function magit-diff-hunk-line "magit-diff")
(declare-function magit-file-at-point "magit-git")
(declare-function magit-hunk-section-p "magit-diff")

(defun pi--region-end ()
  "Return the position of the last character of the region.
A region ending at the start of a line does not cover that line."
  (max (region-beginning) (1- (region-end))))

(defun pi--line (&optional position)
  "Return the line of POSITION, default point, counted from the file start."
  ;; `line-number-at-pos' with ABSOLUTE hangs on positions outside the
  ;; narrowing, which Flymake diagnostics can have.
  (save-restriction
    (widen)
    (line-number-at-pos position)))

(defun pi--lines ()
  "Return the first and last position of the region or of point."
  (if (use-region-p)
      (cons (region-beginning) (pi--region-end))
    (cons (point) (point))))

(defun pi--hunk-line (section position)
  "Return the file line at POSITION in the Magit hunk SECTION."
  (save-excursion
    (goto-char position)
    (magit-diff-hunk-line section nil)))

(defun pi--magit-place ()
  "Return (FILE START END) of the lines at point in a Magit hunk, or nil."
  (pcase-let ((`(,beg . ,end) (pi--lines)))
    (when-let* (;; Other packages use magit-section without Magit.
                ((featurep 'magit-diff))
                ;; Point may already be on the next hunk.
                (section (magit-section-at beg))
                ((magit-hunk-section-p section))
                (file (save-excursion
                        (goto-char beg)
                        (magit-file-at-point t))))
      (unless (eq (magit-section-at end) section)
        (user-error "The region spans more than one hunk"))
      (list file (pi--hunk-line section beg) (pi--hunk-line section end)))))

(defun pi--place ()
  "Return (FILE START END) of the region or line at point."
  (or (pi--magit-place)
      (pcase-let ((`(,beg . ,end) (pi--lines)))
        (list (or buffer-file-name (user-error "Buffer is not visiting a file"))
              (pi--line beg)
              (pi--line end)))))

(defun pi--location (directory)
  "Return the region or line at point as @FILE#LSTART-END.
FILE is relative to DIRECTORY."
  (pcase-let ((`(,file ,start ,end) (pi--place)))
    (format "@%s#L%d%s"
            (file-relative-name (file-truename file) directory)
            start
            (if (= start end) "" (format "-%d" end)))))

;;;###autoload
(defun pi-send-location (&optional steer)
  "Ask Pi about the region or line at point, starting with its location.
STEER is as in `pi-prompt'."
  (interactive "P")
  (let ((directory (pi--require-directory)))
    (pi--prompt directory
                (pi--read-prompt (concat (pi--location directory) " "))
                steer)))

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-type "flymake")

(defun pi--diagnostic-text (diagnostic)
  "Return the text of DIAGNOSTIC.
Flymake pads missing origin and code parts with spaces."
  (string-trim (flymake-diagnostic-text diagnostic)))

;;;###autoload
(defun pi-send-diagnostic (&optional steer)
  "Ask Pi to fix the diagnostics in the region or on the current line.
STEER is as in `pi-prompt'."
  (interactive "P")
  (require 'flymake)
  (let* ((directory (pi--require-directory))
         (diagnostics (if (use-region-p)
                          (flymake-diagnostics (region-beginning) (region-end))
                        (flymake-diagnostics (line-beginning-position)
                                             (line-end-position)))))
    (unless diagnostics
      (user-error "No diagnostic here"))
    (pi--prompt directory
                (pi--read-prompt
                 (format "Fix at %s: %s" (pi--location directory)
                         (mapconcat #'pi--diagnostic-text diagnostics "; ")))
                steer)))

;;;; Review comments

;;;###autoload
(defun pi-add-comment (comment)
  "Note COMMENT on the region or line at point, for `pi-send-comments'."
  (interactive
   (list (read-string (format "Comment on %s: "
                              (pi--location (pi--require-directory))))))
  (let ((directory (pi--require-directory)))
    (push (format "- %s %s" (pi--location directory) comment)
          (gethash directory pi--comments))
    (message "%d comment(s) for the Pi in %s"
             (length (gethash directory pi--comments))
             (abbreviate-file-name directory))))

;;;###autoload
(defun pi-send-comments (&optional steer)
  "Send the review comments noted for this buffer's Pi as one prompt.
STEER is as in `pi-prompt'."
  (interactive "P")
  (let* ((directory (pi--require-directory))
         (comments (or (gethash directory pi--comments)
                       (user-error "No comments for the Pi in %s"
                                   (abbreviate-file-name directory)))))
    (pi--prompt directory
                (string-join (cons "Address these review comments:"
                                   (reverse comments))
                             "\n")
                steer)
    (remhash directory pi--comments)))

(declare-function magit-status "magit-status")
(declare-function project-root "project")

;;;###autoload
(defun pi-review ()
  "Review what Pi changed in the current project, with Magit if installed."
  (interactive)
  (let ((root (project-root (project-current t))))
    (if (fboundp 'magit-status)
        (magit-status root)
      (vc-dir root))))

;;;; Pi's emacs_context tool

(defun pi--diagnostic-alist (diagnostic)
  "Return the line, type and text of the Flymake DIAGNOSTIC as an alist."
  `((line . ,(pi--line (flymake-diagnostic-beg diagnostic)))
    (type . ,(format "%s" (flymake-diagnostic-type diagnostic)))
    (text . ,(pi--diagnostic-text diagnostic))))

(defun pi--region ()
  "Return the lines and text of the region as an alist."
  (let* ((text (buffer-substring-no-properties (region-beginning)
                                               (region-end)))
         (shown (decode-coding-string
                 (string-limit text pi--max-region-bytes nil 'utf-8)
                 'utf-8)))
    `((start . ,(pi--line (region-beginning)))
      (end . ,(pi--line (pi--region-end)))
      (text . ,shown)
      (truncated . ,(if (< (length shown) (length text)) t :false)))))

(defun pi--region-shown-p (place)
  "Return non-nil if Pi may see the region; PLACE is its Magit place or nil.
In a Magit buffer, only a region within one hunk tells whose file it shows."
  (if (derived-mode-p 'magit-section-mode)
      (and place (not (funcall pi-secret-file-predicate (car place))))
    (not (and buffer-file-name
              (funcall pi-secret-file-predicate buffer-file-name)))))

(defun pi--or-null (value)
  "Return VALUE, or JSON null if it is nil."
  (or value :null))

(defun pi--context-window ()
  "Return the window the user works in, the one before an active minibuffer."
  (or (and (minibuffer-window-active-p (selected-window))
           (minibuffer-selected-window))
      (selected-window)))

;;;###autoload
(defun pi-context-json ()
  "Return what the user's window shows as base64 of JSON, for emacs_context.
Leave out regions of files matching `pi-secret-file-predicate'."
  (with-selected-window (pi--context-window)
    (let* ((others (seq-keep (lambda (window)
                               (buffer-file-name (window-buffer window)))
                             (delq (selected-window) (window-list nil 'never))))
           (place (ignore-error user-error (pi--magit-place)))
           (diagnostics (and (bound-and-true-p flymake-mode)
                             (flymake-diagnostics)))
           (shown (seq-take diagnostics pi--max-diagnostics)))
      (base64-encode-string
       (encode-coding-string
        (json-serialize
         `((file . ,(pi--or-null buffer-file-name))
           (buffer . ,(buffer-name))
           (mode . ,(symbol-name major-mode))
           (line . ,(pi--line))
           (column . ,(1+ (current-column)))
           (region . ,(pi--or-null (and (use-region-p)
                                        (pi--region-shown-p place)
                                        (pi--region))))
           (magit . ,(pcase place
                       (`(,file ,start ,end)
                        `((file . ,file) (start . ,start) (end . ,end)))
                       (_ :null)))
           (diagnostics . ,(vconcat (mapcar #'pi--diagnostic-alist shown)))
           (moreDiagnostics . ,(- (length diagnostics) (length shown)))
           (visible . ,(vconcat others))))
        'utf-8)
       t))))

;;;; Mode line

(defun pi--read-state (file)
  "Return the state in the status FILE, or nil if there is none."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let ((state (json-parse-buffer :object-type 'alist)))
          (and (listp state) state)))
    ((file-missing json-error) nil)))

(defun pi--state-changed (file)
  "Take the state from the status FILE and report a Pi that is done."
  (let ((old (gethash file pi--states))
        (new (pi--read-state file)))
    (if new
        (puthash file new pi--states)
      (remhash file pi--states))
    (when (and (equal (alist-get 'state old) "busy")
               (equal (alist-get 'state new) "idle")
               (stringp (alist-get 'cwd new)))
      (message "Pi is done in %s%s"
               (abbreviate-file-name (alist-get 'cwd new))
               (if (eq (alist-get 'aborted new) t) " (aborted)" "")))))

(defun pi--watch-directory ()
  "Create and watch `pi-bridge-directory' and read the states in it."
  (clrhash pi--states)
  (with-file-modes #o700
    (make-directory pi-bridge-directory t))
  (dolist (file (directory-files pi-bridge-directory t (rx ".json" eos)))
    (pi--state-changed file))
  (setq pi--watch (file-notify-add-watch pi-bridge-directory '(change)
                                         #'pi--directory-changed)))

(defvar pi-mode)

(defun pi--rewatch-directory ()
  "Watch `pi-bridge-directory' again, unless `pi-mode' was turned off."
  (when (and pi-mode (not pi--watch))
    (setq pi--generation (1+ pi--generation))
    (condition-case err
        (pi--watch-directory)
      (error (display-warning
              'pi (format "Cannot watch %s: %s" pi-bridge-directory
                          (error-message-string err)))))
    (force-mode-line-update t)))

(defun pi--directory-changed (event)
  "Handle the file notification EVENT in `pi-bridge-directory'."
  (pcase-let* ((`(,watch ,action ,file ,new-file) event)
               (file (if (eq action 'renamed) new-file file)))
    (cond ((eq action 'stopped)
           ;; `pi-mode' forgets a watch before removing it, so this one
           ;; stopped by itself, as when its directory is deleted.  Do not
           ;; check for that: a Pi may have created it again already.
           (when (equal watch pi--watch)
             (setq pi--watch nil)
             ;; A new watch now would get the descriptor filenotify is
             ;; still removing, and be removed with it.
             (run-at-time 0 nil #'pi--rewatch-directory)))
          ((stringp file)
           (cond ((string-suffix-p ".sock" file)
                  (setq pi--generation (1+ pi--generation)))
                 ((string-suffix-p ".json" file)
                  (pi--state-changed file)))
           (force-mode-line-update t)))))

(defun pi--mode-line ()
  "Return the mode line text of the Pi serving this buffer, or nil."
  (when-let* ((file (pi--status-file))
              (state (gethash file pi--states)))
    (let-alist state
      (if (equal .state "busy")
          (concat pi-mode-line-lighter ":" (if (stringp .tool) .tool "...")
                  (when (and (stringp .path) (not (string-empty-p .path)))
                    (concat " " (file-name-nondirectory .path))))
        pi-mode-line-lighter))))

;;;; Keys and the mode

;;;###autoload (autoload 'pi-command-map "pi" nil t 'keymap)
(defvar-keymap pi-command-map
  :doc "Keymap of the commands that talk to Pi."
  :prefix 'pi-command-map
  "a" #'pi-prompt
  "l" #'pi-send-location
  "d" #'pi-send-diagnostic
  "c" #'pi-add-comment
  "s" #'pi-send-comments
  "p" #'pi-run-command
  "k" #'pi-abort
  "n" #'pi-new-session
  "m" #'pi-last
  "r" #'pi-review)

;;;###autoload
(define-minor-mode pi-mode
  "Show the state of the Pi serving the current buffer in the mode line."
  :global t
  :lighter (:eval (pi--mode-line))
  (when-let* ((watch pi--watch))
    ;; Removing the watch reports it stopped; that must not restart it.
    (setq pi--watch nil)
    (file-notify-rm-watch watch))
  (if pi-mode
      (pi--watch-directory)
    (clrhash pi--states))
  (setq pi--generation (1+ pi--generation))
  (force-mode-line-update t))

(provide 'pi)
;;; pi.el ends here
