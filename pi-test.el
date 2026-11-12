;;; pi-test.el --- Tests for pi -*- lexical-binding: t; -*-

;; SPDX-FileCopyrightText: 2026 Florian Marrero Liestmann
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'flymake)
(require 'pi)

(setq pi-bridge-directory (file-name-as-directory (make-temp-file "pi-bridge-" t)))

(defun pi-test--make-project ()
  "Return a fresh directory that a pretend Pi serves."
  (let ((project (file-name-as-directory
                  (file-truename (make-temp-file "pi-project-" t)))))
    (make-directory (expand-file-name "sub/deeper" project) t)
    (pi-test--listen (pi--file project ".sock"))
    project))

(defun pi-test--listen (socket)
  (make-network-process :name "pi-test-pi" :server t :family 'local
                        :service socket :noquery t))

(defun pi-test--stop (socket)
  (dolist (process (process-list))
    (when (equal (process-contact process :service) socket)
      (delete-process process)))
  (delete-file socket))

(defun pi-test--remove-project (project)
  (dolist (buffer (buffer-list))
    (when (string-prefix-p project (or (buffer-file-name buffer) ""))
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (kill-buffer buffer)))
  (pi-test--stop (pi--file project ".sock"))
  (delete-directory project t))

(defmacro pi-test--with-project (&rest body)
  "Run BODY with `project' bound to a directory a pretend Pi serves."
  (declare (indent 0))
  `(let* ((project (pi-test--make-project))
          (default-directory project))
     (unwind-protect
         (progn ,@body)
       (pi-test--remove-project project))))

(defun pi-test--serve (socket reply)
  "Listen on SOCKET, answer each request with REPLY, return the requests seen.
A nil REPLY closes the connection without an answer.  The answer follows
the first chunk of a request, so a long request is cut short."
  (let ((requests (list nil)))
    (delete-file socket)
    (make-network-process
     :name "pi-test-server" :server t :family 'local :service socket :noquery t
     :filter (lambda (process string)
               (ignore-error json-error
                 (push (json-parse-string (string-trim string) :object-type 'alist)
                       (car requests)))
               (when reply
                 (process-send-string process (concat reply "\n")))
               (delete-process process)))
    requests))

(defun pi-test--serve-project (project reply)
  (pi-test--serve (pi--file project ".sock") reply))

(defun pi-test--texts (requests)
  (mapcar (lambda (request) (alist-get 'text request)) (car requests)))

(defmacro pi-test--answering (answer &rest body)
  "Run BODY with `read-string' answering ANSWER, or its initial input if nil."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'read-string)
              (lambda (_prompt &optional initial &rest _) (or ,answer initial))))
     ,@body))

(defun pi-test--visit (file content)
  (write-region content nil file)
  (set-buffer (find-file-noselect file))
  (transient-mark-mode))

(defun pi-test--select-lines (from to)
  (goto-char (point-min))
  (forward-line (1- from))
  (push-mark (point) t t)
  (forward-line (1+ (- to from))))

(defun pi-test--context ()
  (json-parse-string (decode-coding-string (base64-decode-string (pi-context-json))
                                           'utf-8)
                     :object-type 'alist :array-type 'list))

(defmacro pi-test--with-magit-diff (name lines &rest body)
  "Run BODY in a Magit diff of NAME, whose lines 1 to 20 changed to LINES.
LINES maps line numbers to their new text, or nil to keep them.  The
diff is against the index, so the repository needs no commit."
  (declare (indent 2))
  `(let ((file (expand-file-name ,name project)))
     (write-region (mapconcat (lambda (n) (format "%d\n" n)) (number-sequence 1 20) "")
                   nil file)
     (dolist (args (list (list "init" "-q") (list "add" "-f" ,name)))
       (should (zerop (apply #'call-process "git" nil nil nil args))))
     (write-region (mapconcat (lambda (n) (format "%s\n" (or (funcall ,lines n) n)))
                              (number-sequence 1 20) "")
                   nil file)
     (with-current-buffer (magit-diff-unstaged)
       (unwind-protect
           (progn ,@body)
         (kill-buffer)))))

;;;; Finding the Pi

(ert-deftest pi-test-key-matches-the-extension ()
  (should (equal (pi--key "/tmp/pi-test-\u00f6/")
                 "60a925c15103ba01df3d05d29ade3004c905cd7e")))

(ert-deftest pi-test-served-directory-is-the-nearest-ancestor ()
  (pi-test--with-project
    (let ((default-directory (expand-file-name "sub/deeper/" project)))
      (should (equal (pi--find-served-directory default-directory) project))
      (should (equal (pi--status-file) (pi--file project ".json"))))))

(ert-deftest pi-test-socket-of-a-crashed-pi-does-not-hide-its-parent ()
  (pi-test--with-project
    (let* ((sub (expand-file-name "sub/" project))
           (stale (pi--file sub ".sock"))
           (default-directory (expand-file-name "deeper/" sub)))
      (write-region "" nil stale)
      (unwind-protect
          (should (equal (pi--find-served-directory default-directory) project))
        (delete-file stale)))))

(ert-deftest pi-test-served-directory-is-nil-without-a-pi ()
  (let ((default-directory (file-name-as-directory (make-temp-file "pi-none-" t))))
    (unwind-protect
        (progn
          (should-not (pi--status-file))
          (should-error (pi-abort) :type 'user-error))
      (delete-directory default-directory))))

(ert-deftest pi-test-status-file-cache-follows-pis-starting ()
  (let* ((project (file-name-as-directory
                   (file-truename (make-temp-file "pi-late-" t))))
         (default-directory project)
         (socket (pi--file project ".sock")))
    (unwind-protect
        (progn
          (should-not (pi--status-file))
          (pi-test--listen socket)
          (should-not (pi--status-file))
          (pi--directory-changed (list nil 'created socket))
          (should (equal (pi--status-file) (pi--file project ".json"))))
      (pi-test--stop socket)
      (delete-directory project t))))

;;;; Requests

(ert-deftest pi-test-request-gives-up-after-pi-timeout ()
  (pi-test--with-project
    (let ((pi-timeout 0.2))
      (should (equal (cadr (should-error (pi-abort) :type 'user-error))
                     "Pi did not answer")))))

(ert-deftest pi-test-prompt-sends-the-request ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-prompt "hello \u00fc" t)
      (should (equal (car requests)
                     '(((type . "prompt") (text . "hello \u00fc") (deliverAs . "steer"))))))))

(ert-deftest pi-test-prompt-follows-up-by-default ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-prompt "later")
      (should (equal (alist-get 'deliverAs (caar requests)) "followUp")))))

(ert-deftest pi-test-request-reports-pi-errors ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":false,\"error\":\"Pi is busy\"}")
    (should (equal (cadr (should-error (pi-new-session) :type 'user-error))
                   "Pi: Pi is busy"))))

(ert-deftest pi-test-request-ignores-a-dead-socket ()
  (pi-test--with-project
    (pi-test--stop (pi--file project ".sock"))
    (write-region "" nil (pi--file project ".sock"))
    (should (string-prefix-p "No Pi serves"
                             (cadr (should-error (pi-abort) :type 'user-error))))))

(ert-deftest pi-test-request-reports-a-connection-closed-without-answer ()
  (pi-test--with-project
    (pi-test--serve-project project nil)
    (let ((start (float-time)))
      (should (string-match-p "closed the connection"
                              (cadr (should-error (pi-abort) :type 'user-error))))
      (should (< (- (float-time) start) 2)))))

(ert-deftest pi-test-request-refused-before-it-is-sent ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":false,\"error\":\"request too large\"}")
    (should (equal (cadr (should-error (pi-prompt (make-string 200000 ?\u00fc))
                                       :type 'user-error))
                   "Pi: request too large"))))

(ert-deftest pi-test-request-leaves-no-process-behind ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":true}")
    (pi-abort)
    (should-not (seq-find (lambda (process)
                            (string-prefix-p "pi-request" (process-name process)))
                          (process-list)))))

(ert-deftest pi-test-run-command-sends-the-command ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-run-command "review-staged" "error handling")
      (should (equal (pi-test--texts requests) '("/review-staged error handling"))))))

(ert-deftest pi-test-run-command-without-arguments ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-run-command "prove" "")
      (should (equal (pi-test--texts requests) '("/prove"))))))

(ert-deftest pi-test-commands-come-from-the-pi ()
  (pi-test--with-project
    (pi-test--serve-project
     project
     "{\"ok\":true,\"data\":{\"commands\":[{\"name\":\"prove\",\"description\":\"Run the tests\"},{\"name\":\"skill:debugging\"}]}}")
    (should (equal (pi--commands project)
                   '(("prove" . "Run the tests") ("skill:debugging"))))))

(ert-deftest pi-test-last-text-is-the-last-answer ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":true,\"data\":{\"text\":\"All green\"}}")
    (should (equal (pi-last-text) "All green"))))

(ert-deftest pi-test-last-text-is-nil-without-an-answer ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":true,\"data\":{\"text\":null}}")
    (should-not (pi-last-text))))

(ert-deftest pi-test-last-shows-the-answer ()
  (pi-test--with-project
    (pi-test--serve-project project "{\"ok\":true,\"data\":{\"text\":\"All green\"}}")
    (pi-last)
    (with-current-buffer "*Pi*"
      (unwind-protect
          (progn
            (should (equal (buffer-string) "All green"))
            (should buffer-read-only))
        (kill-buffer)))))

;;;; Locations

(ert-deftest pi-test-location-of-a-region-is-relative-to-the-pi ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "sub/f.txt" project) "one\ntwo\nthree\nfour\n")
    (pi-test--select-lines 2 3)
    (should (equal (pi--location project) "@sub/f.txt#L2-3"))
    (deactivate-mark)
    (should (equal (pi--location project) "@sub/f.txt#L4"))))

(ert-deftest pi-test-location-through-a-symlink ()
  (pi-test--with-project
    (let ((link (make-temp-file "pi-link-")))
      (delete-file link)
      (unwind-protect
          (progn
            (make-symbolic-link project link)
            (pi-test--visit (expand-file-name "f.txt" link) "x\n")
            (should (equal (pi--location project) "@f.txt#L1")))
        (delete-file link)))))

(ert-deftest pi-test-location-needs-a-file ()
  (pi-test--with-project
    (with-temp-buffer
      (should-error (pi--location project) :type 'user-error))))

(ert-deftest pi-test-send-location-starts-with-the-location ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\n")
      (forward-line 1)
      (pi-test--answering nil (pi-send-location))
      (should (equal (pi-test--texts requests) '("@f.txt#L2 "))))))

(declare-function magit-diff-unstaged "magit-diff")

(ert-deftest pi-test-location-in-a-magit-hunk ()
  (skip-unless (require 'magit nil t))
  (pi-test--with-project
    (pi-test--with-magit-diff "f.txt" (lambda (n) (pcase n (4 "four") (6 "six") (18 "eighteen")))
      (goto-char (point-min))
      (search-forward "+six")
      (should (equal (pi--location project) "@f.txt#L6"))
      (transient-mark-mode)
      (goto-char (point-min))
      (search-forward "+four")
      (push-mark (line-beginning-position) t t)
      (search-forward "+six")
      (should (equal (pi--location project) "@f.txt#L4-6"))
      (search-forward "+eighteen")
      (should-error (pi--location project) :type 'user-error))))

(ert-deftest pi-test-magit-section-buffer-without-magit ()
  "Packages like org-roam use magit-section without loading Magit."
  (skip-unless (locate-library "magit-section"))
  (let ((process-environment (cons (concat "EMACSLOADPATH="
                                           (string-join load-path path-separator))
                                   process-environment)))
    ;; Separate --eval forms, so magit-insert-section is a macro when read.
    (should (zerop (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil nil nil "-Q" "--batch"
                    "-L" (file-name-directory (locate-library "pi"))
                    "--eval" "(progn (require 'magit-section) (require 'pi))"
                    "--eval"
                    (prin1-to-string
                     '(progn
                        (cl-assert (not (featurep 'magit-diff)))
                        (switch-to-buffer "roam")
                        (magit-section-mode)
                        (let ((inhibit-read-only t))
                          (magit-insert-section (magit-section 'root)
                            (magit-insert-section (magit-section 'node)
                              (insert "backlink\n"))))
                        (goto-char (point-min))
                        (cl-assert (magit-section-at))
                        (cl-assert (not (pi--magit-place)))
                        (pi-context-json))))))))

(ert-deftest pi-test-location-of-a-whole-magit-hunk ()
  (skip-unless (require 'magit nil t))
  (pi-test--with-project
    (pi-test--with-magit-diff "f.txt" (lambda (n) (pcase n (4 "four") (18 "eighteen")))
      (transient-mark-mode)
      (goto-char (point-min))
      (search-forward "+four")
      (push-mark (line-beginning-position) t t)
      (search-forward "@@" nil nil 2)
      (goto-char (line-beginning-position))
      (should (equal (pi--location project) "@f.txt#L4-7")))))

(ert-deftest pi-test-location-in-a-narrowed-buffer ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project) "1\n2\n3\n4\n5\n6\n7\n8\n")
    (forward-line 4)
    (narrow-to-region (point) (point-max))
    (forward-line 1)
    (should (equal (pi--location project) "@f.txt#L6"))))

;;;; Diagnostics

(put 'pi-test--flymake-backend 'flymake-always-safe t)

(defun pi-test--flymake-backend (report-fn &rest _)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (funcall report-fn (list (flymake-make-diagnostic (current-buffer)
                                                      (line-beginning-position)
                                                      (line-end-position)
                                                      :error "boom")))))

(defun pi-test--with-diagnostic-on-line-2 ()
  (setq-local flymake-diagnostic-functions (list #'pi-test--flymake-backend))
  (flymake-mode)
  (flymake-start nil t)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (flymake-diagnostics)) (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (should (flymake-diagnostics)))

(ert-deftest pi-test-send-diagnostic-of-the-line ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\nthree\n")
      (pi-test--with-diagnostic-on-line-2)
      (goto-char (point-min))
      (should-error (pi-test--answering nil (pi-send-diagnostic)) :type 'user-error)
      (forward-line 1)
      (pi-test--answering nil (pi-send-diagnostic))
      (should (equal (pi-test--texts requests) '("Fix at @f.txt#L2: boom"))))))

(ert-deftest pi-test-send-diagnostic-of-the-region ()
  (pi-test--with-project
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\nthree\n")
      (pi-test--with-diagnostic-on-line-2)
      (pi-test--select-lines 1 3)
      (pi-test--answering nil (pi-send-diagnostic))
      (should (equal (pi-test--texts requests) '("Fix at @f.txt#L1-3: boom"))))))

;;;; Review comments

(ert-deftest pi-test-comments-go-to-the-pi-they-were-made-for ()
  (pi-test--with-project
    (let ((other (pi-test--make-project)))
      (unwind-protect
          (progn
            (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\n")
            (pi-test--answering "rename this" (call-interactively #'pi-add-comment))
            (forward-line 1)
            (pi-add-comment "and this")
            (let ((default-directory other))
              (should-error (pi-send-comments) :type 'user-error))
            (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
              (pi-send-comments)
              (should (equal (pi-test--texts requests)
                             '("Address these review comments:\n- @f.txt#L1 rename this\n- @f.txt#L2 and this"))))
            (should-error (pi-send-comments) :type 'user-error))
        (pi-test--remove-project other)))))

(ert-deftest pi-test-comments-survive-a-failed-send ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project) "one\n")
    (pi-add-comment "keep me")
    (should-error (pi-send-comments) :type 'user-error)
    (let ((requests (pi-test--serve-project project "{\"ok\":true}")))
      (pi-send-comments)
      (should (equal (pi-test--texts requests)
                     '("Address these review comments:\n- @f.txt#L1 keep me"))))))

;;;; emacs_context

(ert-deftest pi-test-context-describes-the-selected-window ()
  (pi-test--with-project
    (let ((file (expand-file-name "\u00e4.py" project)))
      (pi-test--visit file "a = 1\nb = 2\nc = 3\n")
      (switch-to-buffer (current-buffer))
      (pi-test--select-lines 2 2)
      (let ((context (pi-test--context)))
        (should (equal (alist-get 'file context) file))
        (should (equal (alist-get 'line context) 3))
        (should (equal (alist-get 'column context) 1))
        (should (equal (alist-get 'region context)
                       '((start . 2) (end . 2) (text . "b = 2\n")
                         (truncated . :false))))
        (should (eq (alist-get 'magit context) :null))
        (should (equal (alist-get 'diagnostics context) nil))
        (should (equal (alist-get 'visible context) nil))))))

(ert-deftest pi-test-context-truncates-a-long-region ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "long.txt" project)
                    (make-string pi--max-region-bytes ?\u00fc))
    (switch-to-buffer (current-buffer))
    (push-mark (point-min) t t)
    (goto-char (point-max))
    (let ((region (alist-get 'region (pi-test--context))))
      ;; U+00FC takes two bytes in UTF-8.
      (should (equal (alist-get 'text region)
                     (make-string (/ pi--max-region-bytes 2) ?\u00fc)))
      (should (eq (alist-get 'truncated region) t)))))

(ert-deftest pi-test-context-counts-the-diagnostics-left-out ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project)
                    (make-string (+ pi--max-diagnostics 3) ?\n))
    (switch-to-buffer (current-buffer))
    (let* ((buffer (current-buffer))
           (diagnostics (mapcar (lambda (position)
                                  (flymake-make-diagnostic buffer position
                                                           (1+ position)
                                                           :error "boom"))
                                (number-sequence 1 (+ pi--max-diagnostics 3))))
           (flymake-mode t))
      (cl-letf (((symbol-function 'flymake-diagnostics)
                 (lambda (&rest _) diagnostics)))
        (let ((context (pi-test--context)))
          (should (= (length (alist-get 'diagnostics context))
                     pi--max-diagnostics))
          (should (= (alist-get 'moreDiagnostics context) 3)))))))

(ert-deftest pi-test-context-includes-diagnostics ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\n")
    (switch-to-buffer (current-buffer))
    (pi-test--with-diagnostic-on-line-2)
    (should (equal (alist-get 'diagnostics (pi-test--context))
                   '(((line . 2) (type . ":error") (text . "boom")))))))

(ert-deftest pi-test-context-leaves-out-a-secret-region ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name ".env" project) "TOKEN=x\n")
    (switch-to-buffer (current-buffer))
    (push-mark (point-min) t t)
    (goto-char (point-max))
    (should (eq (alist-get 'region (pi-test--context)) :null))))

(ert-deftest pi-test-context-reports-a-magit-hunk-place ()
  (skip-unless (require 'magit nil t))
  (pi-test--with-project
    (pi-test--with-magit-diff "f.txt" (lambda (n) (and (= n 6) "six"))
      (switch-to-buffer (current-buffer))
      (goto-char (point-min))
      (search-forward "+six")
      (let ((context (pi-test--context)))
        (should (equal (alist-get 'magit context)
                       `((file . ,file) (start . 6) (end . 6))))
        (should (eq (alist-get 'file context) :null))))))

(ert-deftest pi-test-context-leaves-out-a-secret-region-in-magit ()
  (skip-unless (require 'magit nil t))
  (pi-test--with-project
    (pi-test--with-magit-diff ".env" (lambda (n) (and (= n 6) "TOKEN=x"))
      (switch-to-buffer (current-buffer))
      (transient-mark-mode)
      (goto-char (point-min))
      (search-forward "+TOKEN")
      (push-mark (line-beginning-position) t t)
      (forward-line 1)
      (let ((context (pi-test--context)))
        (should (equal (alist-get 'magit context)
                       `((file . ,file) (start . 6) (end . 6))))
        (should (eq (alist-get 'region context) :null))))))

(ert-deftest pi-test-context-shows-a-region-in-one-magit-hunk-only ()
  (skip-unless (require 'magit nil t))
  (pi-test--with-project
    (pi-test--with-magit-diff "f.txt" (lambda (n) (pcase n (4 "four") (18 "eighteen")))
      (switch-to-buffer (current-buffer))
      (transient-mark-mode)
      (goto-char (point-min))
      (search-forward "+four")
      (push-mark (line-beginning-position) t t)
      (forward-line 1)
      (should (consp (alist-get 'region (pi-test--context))))
      (search-forward "+eighteen")
      (should (eq (alist-get 'region (pi-test--context)) :null)))))

(ert-deftest pi-test-context-of-a-narrowed-buffer-counts-from-the-file-start ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project) "1\n2\n3\n4\n5\n6\n7\n8\n")
    (switch-to-buffer (current-buffer))
    (pi-test--with-diagnostic-on-line-2)
    (forward-line 4)
    (narrow-to-region (point) (point-max))
    (forward-line 1)
    (push-mark (point) t t)
    (forward-line 1)
    (let ((context (pi-test--context)))
      (should (equal (alist-get 'line context) 7))
      (should (equal (alist-get 'region context)
                     '((start . 6) (end . 6) (text . "6\n")
                       (truncated . :false))))
      (should (equal (mapcar (lambda (d) (alist-get 'line d))
                             (alist-get 'diagnostics context))
                     '(2))))))

(ert-deftest pi-test-context-looks-past-the-minibuffer ()
  (pi-test--with-project
    (pi-test--visit (expand-file-name "f.txt" project) "one\ntwo\n")
    (switch-to-buffer (current-buffer))
    (forward-line 1)
    (let ((window (selected-window)))
      (cl-letf (((symbol-function 'minibuffer-window-active-p) #'always)
                ((symbol-function 'minibuffer-selected-window) (lambda () window)))
        (with-selected-window (minibuffer-window)
          (let ((context (pi-test--context)))
            (should (equal (alist-get 'file context)
                           (buffer-file-name (window-buffer window))))
            (should (equal (alist-get 'line context) 2))))))))

(ert-deftest pi-test-secret-files ()
  (dolist (file '("/home/u/.ssh/id_ed25519" "/home/u/.authinfo.gpg" "/srv/app/.env"
                  "/srv/app/.env.local" "/srv/secrets/token"))
    (should (pi-secret-file-p file)))
  (dolist (file '("/srv/app/env.py" "/srv/app/.envrc" "/home/u/.sshrc"))
    (should-not (pi-secret-file-p file))))

(declare-function eglot-shutdown-all "eglot")

(ert-deftest pi-test-eglot-diagnostics-reach-emacs-context ()
  (skip-unless (executable-find "basedpyright-langserver"))
  (require 'eglot)
  (require 'python)
  (pi-test--with-project
    (unwind-protect
        (progn
          (pi-test--visit (expand-file-name "a.py" project) "x = undefined_name\n")
          (switch-to-buffer (current-buffer))
          (python-mode)
          (eglot-ensure)
          (run-hooks 'post-command-hook)
          (let ((deadline (+ (float-time) 60)))
            (while (and (not (flymake-diagnostics)) (< (float-time) deadline))
              (flymake-start nil t)
              (accept-process-output nil 0.2)))
          (should (seq-some (lambda (diagnostic)
                              (string-search "\"undefined_name\" is not defined"
                                             (alist-get 'text diagnostic)))
                            (alist-get 'diagnostics (pi-test--context)))))
      (eglot-shutdown-all))))

;;;; Mode line and mode

(ert-deftest pi-test-status-file-drives-the-mode-line ()
  (pi-test--with-project
    (let ((status (pi--file project ".json"))
          (cwd (directory-file-name project)))
      (write-region (format "{\"state\":\"busy\",\"tool\":\"edit\",\"cwd\":%S}" cwd)
                    nil status)
      (pi--directory-changed (list nil 'created status))
      (should (equal (pi--mode-line) " π:edit"))
      (write-region (format "{\"state\":\"busy\",\"tool\":\"edit\",\"path\":\"%s/f.txt\",\"cwd\":%S}"
                            cwd cwd)
                    nil status)
      (pi--directory-changed (list nil 'changed status))
      (should (equal (pi--mode-line) " π:edit f.txt"))
      (write-region (format "{\"state\":\"idle\",\"aborted\":true,\"cwd\":%S}" cwd)
                    nil status)
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (&rest args) (push (apply #'format-message args) messages))))
          (pi--directory-changed (list nil 'renamed (concat status ".tmp") status)))
        (should (equal messages
                       (list (format "Pi is done in %s (aborted)"
                                     (abbreviate-file-name cwd))))))
      (should (equal (pi--mode-line) " π"))
      (delete-file status)
      (pi--directory-changed (list nil 'deleted status))
      (should-not (pi--mode-line)))))

(ert-deftest pi-test-mode-line-lighter-is-customizable ()
  (pi-test--with-project
    (let ((status (pi--file project ".json"))
          (pi-mode-line-lighter " Pi"))
      (write-region "{\"state\":\"busy\",\"tool\":\"bash\",\"cwd\":\"/p\"}" nil status)
      (pi--directory-changed (list nil 'created status))
      (should (equal (pi--mode-line) " Pi:bash"))
      (delete-file status)
      (pi--directory-changed (list nil 'deleted status)))))

(ert-deftest pi-test-mode-turns-everything-on-and-off ()
  (unwind-protect
      (progn
        (pi-mode 1)
        (should pi--watch)
        (pi-mode 1)
        (should (file-notify-valid-p pi--watch))
        (pi-mode -1)
        (should-not pi--watch)
        (should (= (hash-table-count pi--states) 0)))
    (pi-mode -1)))

;; `format-mode-line' returns "" in batch mode, so only the integration
;; test in a running Emacs sees the lighter itself.
(ert-deftest pi-test-mode-lighter-asks-for-the-state ()
  (should (equal (assq 'pi-mode minor-mode-alist)
                 '(pi-mode (:eval (pi--mode-line))))))

(ert-deftest pi-test-malformed-status-does-no-harm ()
  (pi-test--with-project
    (let ((status (pi--file project ".json")))
      (write-region "[1]" nil status)
      (pi--directory-changed (list nil 'created status))
      (should-not (pi--mode-line))
      (write-region "{\"state\":\"busy\",\"tool\":1,\"path\":null}" nil status)
      (pi--directory-changed (list nil 'changed status))
      (should (equal (pi--mode-line) " π:..."))
      (write-region "{\"state\":\"idle\"}" nil status)
      (pi--directory-changed (list nil 'changed status))
      (should (equal (pi--mode-line) " π"))
      (delete-file status)
      (pi--directory-changed (list nil 'deleted status)))))

(defun pi-test--run-timers ()
  (accept-process-output nil 0.05))

(defmacro pi-test--with-mode (&rest body)
  "Run BODY with `pi-mode' on, and turn it off afterwards."
  (declare (indent 0))
  `(let ((pi-mode-hook nil))
     (unwind-protect
         (progn (pi-mode 1) ,@body)
       (pi-mode -1))))

(ert-deftest pi-test-mode-recovers-a-deleted-directory ()
  (pi-test--with-mode
    (let ((old pi--watch)
          (hook-runs 0))
      (add-hook 'pi-mode-hook (lambda () (cl-incf hook-runs)))
      (delete-directory pi-bridge-directory t)
      (pi--directory-changed (list old 'stopped pi-bridge-directory))
      (should-not pi--watch)
      (pi-test--run-timers)
      (should (file-directory-p pi-bridge-directory))
      (should (file-notify-valid-p pi--watch))
      (should (= hook-runs 0)))))

(ert-deftest pi-test-mode-warns-when-it-cannot-watch-again ()
  (pi-test--with-mode
    (let* ((watch pi--watch)
           (pi-bridge-directory (expand-file-name "sub/" (make-temp-file "pi-file-")))
           (warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (pi--directory-changed (list watch 'stopped pi-bridge-directory))
        (pi-test--run-timers))
      (should (string-prefix-p "Cannot watch" (car warnings)))
      (should-not pi--watch)
      (should pi-mode))))

(ert-deftest pi-test-mode-turned-off-is-not-watched-again ()
  (pi-test--with-mode
    (let ((watch pi--watch))
      (pi--directory-changed (list watch 'stopped pi-bridge-directory))
      (pi-mode -1)
      (pi-test--run-timers)
      (should-not pi--watch))))

(ert-deftest pi-test-command-map-is-a-prefix-command ()
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c a" 'pi-command-map)
    (should (eq (keymap-lookup map "C-c a a") #'pi-prompt))))

;;; pi-test.el ends here
