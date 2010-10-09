;;; tirepl.el --- Read-Eval-Print Loop for Titanium written in Emacs Lisp

;; Local modifications for running with Titanium by Joel Boehland

;; This File uses code heavily ripped from SLIME, js-commint.
;; Therefore original authors are the creators of those files, but the
;; butchering is all my fault :-)

;; Original Author: Helmut Eller and others
;; Contributors: to many to mention
;; License: GNU GPL (same license as Emacs)
;; URL: http://github.com/jolby/TiREPL
;; Keywords: languages, javascript, titanium
;;
;;; Description:
;; This file implements a javascript Listener along with some niceties like
;; a persistent history for communicating with a remote Titanium
;; mobile device
;;
;;; Installation:
;; Place this file on your load-path and '(require 'tirepl)

;; tirepl

(provide 'tirepl)

(eval-when-compile
  (require 'cl))

(require 'json)
(require 'pp)
(require 'ido)

(defgroup tirepl nil
  "The Read-Eval-Print Loop for remote Titanium applications."
  :prefix "tirepl-"
  :group 'applications)

(defface tirepl-repl-prompt-face
  '((((class color) (background light)) (:foreground "Purple"))
    (((class color) (background dark)) (:foreground "Cyan"))
    (t (:weight bold)))
  "Face for the prompt in the TIREPL REPL."
  :group 'tirepl)

(defface tirepl-repl-output-face
  '((((class color) (background light)) (:foreground "RosyBrown"))
    (((class color) (background dark)) (:foreground "LightSalmon"))
  ;;'((((class color) (background light)) (:foreground "red"))
  ;; (((class color) (background dark)) (:foreground "red"))
    (t (:slant italic)))
  "Face for Lisp output in the TIREPL REPL."
  :group 'tirepl)

(defface tirepl-repl-input-face
  '((t (:bold t)))
  "Face for previous input in the TIREPL REPL."
  :group 'tirepl)

(defface tirepl-repl-result-face
  '((t ()))
  "Face for the result of an evaluation in the TIREPL REPL."
  :group 'tirepl)

(defface tirepl-repl-result-error-face
  '((((class color) (background light)) (:foreground "red"))
    (((class color) (background dark)) (:foreground "red"))
    (t (:weight bold)))
  "Face for the result of an evaluation that caused an error in the TIREPL REPL."
  :group 'tirepl)

(defcustom tirepl-repl-wrap-history nil
  "*T to wrap history around when the end is reached."
  :type 'boolean
  :group 'tirepl)

(make-variable-buffer-local
 (defvar tirepl-repl-output-start nil
   "Marker for the start of the output for the evaluation."))

(make-variable-buffer-local
 (defvar tirepl-repl-output-end nil
   "Marker for end of output. New output is inserted at this mark."))

(make-variable-buffer-local
 (defvar tirepl-repl-prompt-start-mark))

(make-variable-buffer-local
 (defvar tirepl-repl-input-start-mark))
 
(defvar tirepl-default-hostname "localhost"
  "*Hostname where titanium is running.")

(defvar tirepl-default-port 5051
  "*Default Port the TiRepl listener is listening on.")

(defvar tirepl-net-process-connect-hooks '()
  "List of functions called when a tirepl network connection connects.
 The functions are called with the process as their argument.")

(defvar tirepl-net-process-close-hooks '()
   "List of functions called when a tirepl network connection closes.
 The functions are called with the process as their argument.")

;;; Interface
(defun tirepl-net-connect (host port)
  "Establish a connection with a Titanium REPL."
  (let* ((proc (open-network-stream "TiREPL" nil host port))
         (buffer (tirepl-net-make-net-buffer "*tirepl-connection*")))
    (set-process-buffer proc buffer)
    (set-process-filter proc 'tirepl-net-filter)
    (set-process-sentinel proc 'tirepl-net-sentinel)
    (run-hook-with-args 'tirepl-net-process-connect-hooks proc)
    proc))

(defun tirepl-net-close (process)
  (run-hook-with-args 'tirepl-net-process-close-hooks process)
  ;; killing the buffer also closes the socket
  (kill-buffer (process-buffer process))
  (delete-process process))

(defun tirepl-net-close-all ()
  (mapcar 'tirepl-net-close tirepl-net-processes))

(defun tirepl-net-make-net-buffer (name)
  "Make a buffer suitable for a network process."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (buffer-disable-undo)
      (set (make-local-variable 'kill-buffer-query-functions) nil))
    buffer))

(defun tirepl-net-send-message(string proc)
  (let ((msg (format "/message %s\n" (base64-encode-string string t))))
    (process-send-string proc msg)))

(defun tirepl-net-send-raw (string proc)
  (message "sending raw string: %s" string)
  (process-send-string proc string))

(defun tirepl-net-sentinel (process message)
  (message "TiRepl connection closed unexpectedly: %s" message)
  (kill-buffer (process-buffer process)))

(defun tirepl-net-filter (process string)
  "Accept output from the socket and input all complete messages."
  (with-current-buffer (process-buffer process)
    (save-excursion
      (goto-char (point-max))
      (insert string))
    (goto-char (point-min))
    (tirepl-process-available-input process)))

(defun tirepl-buffer-for-callback (saved-buffer)
  (let ((alive (buffer-name saved-buffer)))
    (cond (alive saved-buffer)
          (t (generate-new-buffer (format "*killed %s*" saved-buffer))))))

(defun tirepl-process-available-input (process)
  "Process all complete messages that have arrived from remote Ti."
  (unwind-protect
      (let ((string (buffer-substring (point-min) (point-max))))
        (delete-region (point-min) (point-max))
        (when (string-match "^titanium-repl>>>" string))
        
        (when (string-match "^REPL> \\(.*\\)" string))

        (when (string-match "^Welcome \\(.*\\)" string))
        
        (when (string-match "^/session_id \\(.*\\)" string)
          (let ((session-id (match-string 1 string))
                (session (tirepl-session-find-by-proc-name (process-name process))))
            (when session 
              (tirepl-session-remove-session session)
              (plist-put session :id (match-string 1 string))
              (push `(,session-id . ,session) tirepl-sessions))))
        
        (when (string-match "^/message_response \\(.*\\)" string)
          (let ((json-str (base64-decode-string (match-string 1 string))))
            ;;(message "Got message json: %s" json-str)
            (let ((msg-plist (let ((json-object-type 'plist)) (json-read-from-string json-str))))
              ;;(message "Got message plist: %s" msg-plist)
              (tirepl-session-dispatch-message msg-plist)))))))

;;; RPCing
(defvar tirepl-sessions ()
  "An alist of (TIREPL-SESSION-ID . TIREPL-SESSION-ALIST) currently active.")

(defvar tirepl-session-counter 0
  "Counter to generate serial number for sessions.")

(defvar tirepl-default-session nil)

(make-variable-buffer-local
 (defvar tirepl-session-buffer-session nil
   "Users can locally override the session to use for interaction on a per buffer basis"))

(defun tirepl-session-new-session-id ()
  (incf tirepl-session-counter)
  (while (tirepl-session-find-by-id tirepl-session-counter)
    (incf tirepl-session-counter))
  tirepl-session-counter)

(defun tirepl-session-new-message-id (session)
  (plist-put session :message-id-counter (+ 1 (plist-get session :message-id-counter)))
  (plist-get session :message-id-counter))

(defun tirepl-session-add-callback (session callback-id callback)
  (let ((callbacks (plist-get session :callbacks)))
    (plist-put session :callbacks (push `(,callback-id . ,callback) callbacks))))

(defun tirepl-session-remove-callback (session callback-id)
  (let* ((callbacks (plist-get session :callbacks))
        (cb (assoc callback-id callbacks)))
    (when cb
      (plist-put session :callbacks (delete cb callbacks))
      (cdr cb) )))

(defun* tirepl-session-make-session
    (&optional (host tirepl-default-hostname) (port tirepl-default-port))
  "Create TiREPL session alist with connection to host, port and
push it on the tirepl-sessions list"
  (let* ((proc (tirepl-net-connect host port))
         (session-name (format "%s-%s" host port))
         (session-id (tirepl-session-new-session-id))
         (session `(:id ,session-id :name ,session-name :process ,proc :repl nil
                        :callbacks () :message-id-counter 0)))
    (push `(,session-id . ,session) tirepl-sessions)
    (unless (tirepl-session-find-default))
    (tirepl-session-set-default session)

    ;;get our uuid from the remote repl server
    (sleep-for 1) ;;XXX--Lame - need to rig up wait-for-input with timeout
    (tirepl-net-send-raw "/session_id\n" proc)
    (sleep-for 1)
    session))

(defun tirepl-session-make-session-prompt (host port)
  (interactive
   (list
    (read-from-minibuffer "Host: " tirepl-default-hostname)
    (read-from-minibuffer "Port: " (format "%s" tirepl-default-port))))
  (message "Starting session with host: %s, port: %s" host port)
  (tirepl-session-make-session host port))

(defun tirepl-session-remove-session (sess)
  (let* ((session-id (plist-get sess :id))
        (rec (assoc session-id tirepl-sessions)))
    (when rec (setq tirepl-sessions (delete rec tirepl-sessions)))))

(defun tirepl-session-end-session (sess)
  (let* ((session-id (plist-get sess :id))
         (proc (plist-get sess :process))
         (repl (plist-get sess :repl))
         (rec (assoc session-id tirepl-sessions)))
    (message "ending session: %s\nProc: %s\nrepl: %s\nrec: %s" sess proc repl rec)
    (when proc (tirepl-net-close proc))
    (when repl (kill-buffer repl))
    (when rec (setq tirepl-sessions (delete rec tirepl-sessions)))))

(defmacro tirepl-session-do-all (session-name &rest body)
  `(loop for ,session-name in (mapcar 'cdr tirepl-sessions) do
         ,@body))

(defun tirepl-session-all-names ()
  (mapcar '(lambda (x) (plist-get x :name))
          (mapcar 'cdr tirepl-sessions)))

(defun tirepl-session-end-all-sessions ()
  (tirepl-session-do-all s (tirepl-session-end-session s)))

(defun tirepl-session-find-by-id (id)
  (let ((s (assoc id tirepl-sessions)))
    (when s (cdr s))))

(defun tirepl-session-find-by-name (name)
  (loop for s in (mapcar 'cdr tirepl-sessions)
        when (string= (plist-get s :name) name)
        return s))

(defun tirepl-session-find-by-proc-name (name)
  (loop for s in (mapcar 'cdr tirepl-sessions)
        when (string= (process-name (plist-get s :process)) name)
        return s))

(defun tirepl-session-find-default ()
  (loop for s in (mapcar 'cdr tirepl-sessions)
        when (plist-get s :default)
        return s))

(defun tirepl-session-set-default (session)
  (tirepl-session-do-all s (plist-put s :default nil))
  (plist-put session :default t))

(defun tirepl-session-select ()
  (interactive)
  (let* ((candidates (tirepl-session-all-names))
         (choice (ido-completing-read "Select session: "
                                 candidates nil t nil)))
    (tirepl-session-find-by-name choice)))

(defun tirepl-session-current-session ()
  (or tirepl-session-buffer-session
      (tirepl-session-find-default)))

(defun tirepl-session-process (session)
  (plist-get session :process))

(defun tirepl-session-bind-repl-buffer (session repl-buffer)
  (save-excursion
    (with-current-buffer repl-buffer
      (setq tirepl-session-buffer-session session)
      (plist-put session :repl repl-buffer))))

(defun tirepl-session-bind-buffer ()
  "Bind active TiREPL session selected by user after prompt to current buffer"
  (interactive)
  (let ((session (tirepl-session-select)))
    (when session
      (set (make-local-variable 'tirepl-session-buffer-session) session))))

(defun tirepl-session-unbind-repl-buffer ()
  ;;meant bo be run during kill-buffer-hook. repl buffer is assumed to be current
  ;;buffer when run.
  (let ((session tirepl-session-buffer-session))
    (message "unbind-repl-buffer-hook")
    (when session
      (setq tirepl-session-buffer-session nil)
      (plist-put session :repl nil))))

(defun tirepl-session-encode-eval-message (session js-src msg-id)
  (json-encode-plist `(:session-id ,(plist-get session :id)
                                   :id ,msg-id :type "eval_src" :src ,js-src)))

(defun tirepl-text-keywordize-string (string)
  (intern (concat ":" (downcase string))))

(defun tirepl-session-eval-report-success (value)
  (message "Message success. Value: %s" value))

(defun tirepl-session-eval-report-error (value)
  (message "Message error. Value: %s" value))

(defun* tirepl-session-eval (session js-src &optional
                                     (success-cb 'tirepl-session-eval-report-success)
                                     (error-cb 'tirepl-session-eval-report-error))
  "Evaluate JS source in Ti and queue the continuation function CONT in the
callbacks list to call later with the result."
  (let ((id (tirepl-session-new-message-id session))
        (contwrap (lexical-let ((success-cb success-cb)
                                (error-cb error-cb)
                                (buffer (current-buffer))
                                (session session))
                    (lambda (status value)
                      ;;(message "in cb. status: %s, value: %s, success-cb: %s, error-cb: %s, buffer: %s, session: %s" status value success-cb error-cb buffer session)
                      (with-current-buffer (tirepl-buffer-for-callback buffer)
                        (ecase (tirepl-text-keywordize-string status)
                          (:ok (funcall success-cb value))
                          (:error (funcall error-cb value))
                          (error (message "Evaluation aborted: %s" value))))))))
    (tirepl-session-add-callback session id contwrap)    
    (tirepl-net-send-message (tirepl-session-encode-eval-message session js-src id)
                             (tirepl-session-process session))))

(defun tirepl-session-dispatch-message (msg)
  (let ((session-id (plist-get msg :session-id))
        (message-id (plist-get msg :id))
        (status (plist-get msg :status))
        (value (plist-get msg :result)))
    (unless session-id (error "No session-id in message: %s. Aborting dispatch." msg))
    (let ((session (tirepl-session-find-by-id session-id)))
      (unless session (error "No active session with id: %s for message: %s. Aborting dispatch."
                             session-id msg))
      (let ((cb (tirepl-session-remove-callback session message-id)))
        (unless cb (error "No callback with id: for message: %s. Aborting dispatch." msg))
        (funcall cb status value)))))

(defun tirepl-session-default-or-create ()
  (let ((session (tirepl-session-current-session)))
    (unless session
      (if (y-or-n-p "No active TiREPL sessions. Create one?")
          (setq session (call-interactively 'tirepl-session-make-session-prompt))))
  session))

(defun tirepl-eval-send-region (start end)
  (interactive "r")
  (let ((session (tirepl-session-default-or-create))
        (src (buffer-substring start end)))
    (message "sending region: %s" src)
    (tirepl-session-eval
     (tirepl-session-current-session) src
     (lambda (result) (message "%s" result)))))

(defun tirepl-eval-send-region-and-insert (start end)
  (interactive "r")
  (let ((session (tirepl-session-default-or-create))
        (src (buffer-substring start end)))
    (tirepl-session-eval
     (tirepl-session-current-session) src
     (lambda (result) (beginning-of-line 2) (insert result)))))

(defun tirepl-eval-echo-defun ()
  (interactive)
  (save-excursion
    (mark-defun)
    (let ((src (buffer-substring (point) (mark))))
      (message "defun: \n%s" src))))

(defun tirepl-eval-send-defun ()
  (interactive)
  (save-excursion
    (mark-defun)
    (tirepl-eval-send-region (point) (mark))))

(defun tirepl-eval-send-expression ()
  (interactive )
  )

(defun tirepl-eval-send-buffer ()
  (interactive)
  )

(defun tirepl-js-make-scratch-buffer (buffer-name)
  (interactive
   (list (read-from-minibuffer "Ti scratch buffer name: " "*TiScratch*")))
  (let ((buffer (generate-new-buffer buffer-name))
        (session (tirepl-session-default-or-create)))
    (with-current-buffer buffer
      (set (make-local-variable 'tirepl-session-buffer-session) session))
      (pop-to-buffer buffer)))

;;; REPL
(defmacro tirepl-repl-propertize-region (props &rest body)
   "Execute BODY and add PROPS to all the text it inserts.
 More precisely, PROPS are added to the region between the point's
 positions before and after executing BODY."
   (let ((start (gensym)))
     `(let ((,start (point)))
        (prog1 (progn ,@body)
          (add-text-properties ,start (point) ,props)))))

(defmacro tirepl-repl-save-marker (marker &rest body)
  (let ((pos (gensym "pos")))
    `(let ((,pos (marker-position ,marker)))
       (prog1 (progn . ,body)
         (set-marker ,marker ,pos)))))

(put 'tirepl-repl-save-marker 'lisp-indent-function 1)

(defun tirepl-repl-mark-input-start ()
  (set-marker tirepl-repl-input-start-mark (point) (current-buffer)))

(defun tirepl-repl-mark-output-start ()
  (set-marker tirepl-repl-output-start (point))
  (set-marker tirepl-repl-output-end (point)))

(defun tirepl-repl-mark-output-end ()
  (add-text-properties tirepl-repl-output-start tirepl-repl-output-end
                       '(;;face tirepl-repl-output-face 
                         rear-nonsticky (face))))

(defun tirepl-repl-reset-repl-markers ()
  (dolist (markname '(tirepl-repl-output-start
                      tirepl-repl-output-end
                      tirepl-repl-prompt-start-mark
                      tirepl-repl-input-start-mark))
    (set markname (make-marker))
    (set-marker (symbol-value markname) (point))))

(defun tirepl-repl-insert-prompt ()
  "Insert the prompt (before markers!).
Set point after the prompt.  
Return the position of the prompt beginning."
  (goto-char tirepl-repl-input-start-mark)
  (tirepl-repl-save-marker tirepl-repl-output-start
    (tirepl-repl-save-marker tirepl-repl-output-end

      (unless (bolp) (insert-before-markers "\n"))

      (let ((prompt-start (point))
            (prompt (format "%s> " "REPL"))) ;;change prompt later...
        (tirepl-repl-propertize-region
         '(face tirepl-repl-prompt-face read-only t intangible t
                tirepl-repl-prompt t
                rear-nonsticky (tirepl-repl-prompt read-only face intangible))
         (insert-before-markers prompt))
        (set-marker tirepl-repl-prompt-start-mark prompt-start)
        prompt-start))))

(defun tirepl-repl-update-banner ()
  (tirepl-repl-insert-banner)
  (goto-char (point-max))
  (tirepl-repl-mark-output-start)
  (tirepl-repl-mark-input-start)
  (tirepl-repl-insert-prompt))

(defun tirepl-repl-insert-banner ()
  (when (zerop (buffer-size))
    (let ((welcome "// TiREPL - Mobile Awesome Sauce!"))
      (insert welcome))))

(defun tirepl-repl-output-buffer ()
  (interactive)
  (let* ((session (tirepl-session-default-or-create))
         (repl-buffer (plist-get session :repl)))
    (if (and repl-buffer (buffer-live-p repl-buffer))
        repl-buffer
      ;;No repl buffer for this session, need to create
      (let* ((buffer-name (format "*TiREPL-%s*" (plist-get session :name)))
             (buffer (generate-new-buffer buffer-name)))
        (with-current-buffer buffer
          (tirepl-repl-mode)
          
          (tirepl-session-bind-repl-buffer session buffer)          
          (add-hook 'kill-buffer-hook 'tirepl-session-unbind-repl-buffer t t)

          (tirepl-repl-reset-repl-markers)
          (tirepl-repl-update-banner)
          (current-buffer))))))

(defun tirepl-repl-switch-to-output-buffer ()
  ""
  (interactive)
  (let ((buffer (tirepl-repl-output-buffer)))
    (switch-to-buffer buffer)
    (goto-char (point-max))
    buffer))

(defun tirepl-repl-show-maximum-output ()
  "Put the end of the buffer at the bottom of the window."
  (when (eobp)
    (let ((win (get-buffer-window (current-buffer))))
      (when win
        (with-selected-window win
          (set-window-point win (point-max)) 
          (recenter -1))))))

(defun tirepl-repl-send-string (string)
  (tirepl-session-eval (tirepl-session-current-session)
                       string
                       'tirepl-repl-emit-result
                       'tirepl-repl-emit-error))

(defun tirepl-repl-in-input-area-p ()
  (<= tirepl-repl-input-start-mark (point)))

(defun tirepl-repl-current-input (&optional until-point-p)
  (buffer-substring-no-properties
   tirepl-repl-input-start-mark
   (if until-point-p
       (point)
     (point-max))))

(defun tirepl-repl-echo-current-input ()
  (interactive)
  (message "%s" (tirepl-repl-current-input)))

(defun tirepl-repl-send-input ()
  "Goto to the end of the input and send the current input."
  (unless (tirepl-repl-in-input-area-p)
    (error "No input at point."))
  (goto-char (point-max))
  (let ((end (point))) ; end of input, without the newline
    (insert "\n")
    (tirepl-repl-add-to-input-history
     (buffer-substring tirepl-repl-input-start-mark end))
    (tirepl-repl-show-maximum-output)
    (let ((overlay (make-overlay tirepl-repl-input-start-mark end)))
      ;; These properties are on an overlay so that they won't be taken
      ;; by kill/yank.
      (overlay-put overlay 'read-only t)
      (overlay-put overlay 'face 'tirepl-repl-input-face)))
  
  (let ((input (tirepl-repl-current-input)))
    (goto-char (point-max))
    (tirepl-repl-mark-input-start)
    (tirepl-repl-mark-output-start)
    (tirepl-repl-send-string input)))

(defun tirepl-repl-return ()
  (interactive)
  ;;(tirepl-check-connected)  
  (tirepl-repl-send-input))

(defun tirepl-repl-emit-result (string &optional bol)
  ;; insert STRING and mark it as evaluation result
  (let ((string (if (stringp string) string (format "%s" string))))
    (with-current-buffer (tirepl-repl-output-buffer)
      (when string ;;only insert if not nil
        (save-excursion
          (tirepl-repl-save-marker tirepl-repl-output-start
            (tirepl-repl-save-marker tirepl-repl-output-end
              (goto-char tirepl-repl-input-start-mark)
              ;;(when (and bol (not (bolp))) (insert-before-markers "\n"))
              (when (not (bolp)) (insert-before-markers "\n"))
              (tirepl-repl-propertize-region `(face tirepl-repl-result-face
                                                    rear-nonsticky (face))
                                             (insert-before-markers string))))))
      (tirepl-repl-insert-prompt)
      (tirepl-repl-show-maximum-output))))

(defun tirepl-repl-emit-error (string &optional bol)
  ;; insert STRING and mark it as evaluation result
  (let ((string (if (stringp string) string (format "%s" string))))
    (with-current-buffer (tirepl-repl-output-buffer)
      (when string ;;only insert if not nil
        (save-excursion
          (tirepl-repl-save-marker tirepl-repl-output-start
            (tirepl-repl-save-marker tirepl-repl-output-end
              (goto-char tirepl-repl-input-start-mark)
              ;;(when (and bol (not (bolp))) (insert-before-markers "\n"))
              (when (not (bolp)) (insert-before-markers "\n"))
            
              (tirepl-repl-propertize-region
               `(face tirepl-repl-result-error-face rear-nonsticky (face))
               ;;`(face tirepl-repl-output-face rear-nonsticky (face))
               (insert-before-markers
                (format "Error during remote evaluation:\n")
                string))))))
      (tirepl-repl-insert-prompt)
      (tirepl-repl-show-maximum-output))))

(defun tirepl-repl-delete-current-input ()
  "Delete all text from the prompt."
  (interactive)
  (delete-region tirepl-repl-input-start-mark (point-max)))

(defun tirepl-repl-kill-input ()
  "Kill all text from the prompt to point."
  (interactive)
  (cond ((< (marker-position tirepl-repl-input-start-mark) (point))
         (kill-region tirepl-repl-input-start-mark (point)))
        ((= (point) (marker-position tirepl-repl-input-start-mark))
         (tirepl-repl-delete-current-input))))

(defun tirepl-repl-replace-input (string)
  (tirepl-repl-delete-current-input)
  (insert-and-inherit string))

;;; Repl navigation
(defun tirepl-repl-same-line-p (pos1 pos2)
  "Return t if buffer positions POS1 and POS2 are on the same line."
  (save-excursion (goto-char (min pos1 pos2))
                  (<= (max pos1 pos2) (line-end-position))))

(defun tirepl-repl-bol ()
  "Go to the beginning of line or the prompt."
  (interactive)
  (cond ((and (>= (point) tirepl-repl-input-start-mark)
              (tirepl-repl-same-line-p (point) tirepl-repl-input-start-mark))
         (goto-char tirepl-repl-input-start-mark))
        (t (beginning-of-line 1))))

(defun tirepl-repl-previous-prompt ()
  "Move backward to the previous prompt."
  (interactive)
  (tirepl-repl-find-prompt t))

(defun tirepl-repl-next-prompt ()
  "Move forward to the next prompt."
  (interactive)
  (tirepl-repl-find-prompt))
 
(defun tirepl-repl-find-prompt (&optional backward)
  (let ((origin (point))
        (prop 'tirepl-repl-prompt))
    (while (progn 
             (tirepl-repl-search-property-change prop backward)
             (not (or (tirepl-repl-end-of-proprange-p prop) (bobp) (eobp)))))
    (unless (tirepl-repl-end-of-proprange-p prop)
      (goto-char origin))))

(defun tirepl-repl-search-property-change (prop &optional backward)
  (cond (backward 
         (goto-char (previous-single-char-property-change (point) prop)))
        (t 
         (goto-char (next-single-char-property-change (point) prop)))))

(defun tirepl-repl-end-of-proprange-p (property)
  (and (get-char-property (max 1 (1- (point))) property)
       (not (get-char-property (point) property))))

;;; Repl History
(make-variable-buffer-local
 (defvar tirepl-repl-input-history '()
   "History list of strings read from the REPL buffer."))

(defun tirepl-repl-add-to-input-history (string)
  "Add STRING to the input history.
Empty strings and duplicates are ignored."
  (unless (or (equal string "")
              (equal string (car tirepl-repl-input-history)))
    (push string tirepl-repl-input-history)))

;; These two vars contain the state of the last history search.  We
;; only use them if `last-command' was 'tirepl-repl-history-replace,
;; otherwise we reinitialize them.

(defvar tirepl-repl-input-history-position -1
  "Newer items have smaller indices.")

(defvar tirepl-repl-history-pattern nil
  "The regexp most recently used for finding input history.")

(defun tirepl-repl-history-replace (direction &optional regexp)
  "Replace the current input with the next line in DIRECTION.
DIRECTION is 'forward' or 'backward' (in the history list).
If REGEXP is non-nil, only lines matching REGEXP are considered."
  (setq tirepl-repl-history-pattern regexp)
  (let* ((min-pos -1)
         (max-pos (length tirepl-repl-input-history))
         (pos0 (cond ((tirepl-repl-history-search-in-progress-p)
                      tirepl-repl-input-history-position)
                     (t min-pos)))
         (pos (tirepl-repl-position-in-history pos0 direction (or regexp "")))
         (msg nil))
    (cond ((and (< min-pos pos) (< pos max-pos))
           (tirepl-repl-replace-input (nth pos tirepl-repl-input-history))
           (setq msg (format "History item: %d" pos)))
          ((not tirepl-repl-wrap-history)
           (setq msg (cond ((= pos min-pos) "End of history")
                           ((= pos max-pos) "Beginning of history"))))
          (tirepl-repl-wrap-history
           (setq pos (if (= pos min-pos) max-pos min-pos))
           (setq msg "Wrapped history")))
    (when (or (<= pos min-pos) (<= max-pos pos))
      (when regexp
        (setq msg (concat msg "; no matching item"))))
    (message "%s%s" msg (cond ((not regexp) "")
                              (t (format "; current regexp: %s" regexp))))
    (setq tirepl-repl-input-history-position pos)
    (setq this-command 'tirepl-repl-history-replace)))

(defun tirepl-repl-history-search-in-progress-p ()
  (eq last-command 'tirepl-repl-history-replace))

(defun tirepl-repl-terminate-history-search ()
  (setq last-command this-command))

(defun tirepl-repl-position-in-history (start-pos direction regexp)
  "Return the position of the history item matching regexp.
Return -1 resp. the length of the history if no item matches"
  ;; Loop through the history list looking for a matching line
  (let* ((step (ecase direction
                 (forward -1)
                 (backward 1)))
         (history tirepl-repl-input-history)
         (len (length history)))
    (loop for pos = (+ start-pos step) then (+ pos step)
          if (< pos 0) return -1
          if (<= len pos) return len
          if (string-match regexp (nth pos history)) return pos)))

(defun tirepl-repl-previous-input ()
  "Cycle backwards through input history.
If the `last-command' was a history navigation command use the
same search pattern for this command.
Otherwise use the current input as search pattern."
  (interactive)
  (tirepl-repl-history-replace 'backward (tirepl-repl-history-pattern t)))

(defun tirepl-repl-next-input ()
  "Cycle forwards through input history.
See `tirepl-repl-previous-input'."
  (interactive)
  (tirepl-repl-history-replace 'forward (tirepl-repl-history-pattern t)))

(defun tirepl-repl-forward-input ()
  "Cycle forwards through input history."
  (interactive)
  (tirepl-repl-history-replace 'forward (tirepl-repl-history-pattern)))

(defun tirepl-repl-backward-input ()
  "Cycle backwards through input history."
  (interactive)
  (tirepl-repl-history-replace 'backward (tirepl-repl-history-pattern)))

(defun tirepl-repl-previous-matching-input (regexp)
  (interactive "sPrevious element matching (regexp): ")
  (tirepl-repl-terminate-history-search)
  (tirepl-repl-history-replace 'backward regexp))

(defun tirepl-repl-next-matching-input (regexp)
  (interactive "sNext element matching (regexp): ")
  (tirepl-repl-terminate-history-search)
  (tirepl-repl-history-replace 'forward regexp))

(defun tirepl-repl-history-pattern (&optional use-current-input)
  "Return the regexp for the navigation commands."
  (cond ((tirepl-repl-history-search-in-progress-p)
         tirepl-repl-history-pattern)
        (use-current-input
         (assert (<= tirepl-repl-input-start-mark (point)))
         (let ((str (tirepl-repl-current-input t)))
           (cond ((string-match "^[ \n]*$" str) nil)
                 (t (concat "^" (regexp-quote str))))))
        (t nil)))

(defun tirepl-repl-delete-from-input-history (string)
  "Delete STRING from the repl input history. 

When string is not provided then clear the current repl input and
use it as an input.  This is useful to get rid of unwanted repl
history entries while navigating the repl history."
  (interactive (list (tirepl-repl-current-input)))
  (let ((merged-history 
         (tirepl-repl-merge-histories tirepl-repl-input-history
                                     (tirepl-repl-read-history nil t))))
    (setq tirepl-repl-input-history
          (delete* string merged-history :test #'string=))
    (tirepl-repl-save-history))
  (tirepl-repl-delete-current-input))


;;; Mode
(defmacro tirepl-define-keys (keymap &rest key-command)
  "Define keys in KEYMAP. Each KEY-COMMAND is a list of (KEY COMMAND)."
  `(progn . ,(mapcar (lambda (k-c) `(define-key ,keymap . ,k-c))
                     key-command)))

(put 'tirepl-define-keys 'lisp-indent-function 1)

(defvar tirepl-eval-mode-map
  (let ((keymap (make-sparse-keymap)))
    keymap))

(tirepl-define-keys tirepl-eval-mode-map
  ("\C-c\C-r" 'tirepl-eval-send-region)
  ("\C-x\C-e" 'tirepl-eval-send-defun)
  ("\C-c :" 'tirepl-eval-send-expression)
  )

(define-minor-mode tirepl-eval-mode
  "Minor mode for interactive development with remote Titanium devices." nil " TiREPL-eval"
  :keymap tirepl-eval-mode-map
  :group 'tirepl
  :global nil)


(defvar tirepl-repl-mode-map
  (let ((keymap (make-sparse-keymap)))
    keymap))

(tirepl-define-keys tirepl-repl-mode-map
  ("\C-m" 'tirepl-repl-return)
  ([return] 'tirepl-repl-return)
  ("\C-a" 'tirepl-repl-bol)
  ([home] 'tirepl-repl-bol)
  ("\M-p" 'tirepl-repl-previous-input)
  ((kbd "M-<up>") 'tirepl-repl-backward-input)
  ("\M-n" 'tirepl-repl-next-input)
  ((kbd "M-<down>") 'tirepl-repl-forward-input)
  ("\C-c\C-n" 'tirepl-repl-next-prompt)
  ("\C-c\C-p" 'tirepl-repl-previous-prompt))

(easy-menu-define nil tirepl-repl-mode-map "TiREPL"
  '("TiREPL"
    ["Eval expression in remote Titanium device..." tirepl-eval-send-expression]))
    

(define-minor-mode tirepl-repl-mode
  "Minor mode for interactive development with remote Titanium devices." nil " TiREPL"
  :keymap tirepl-repl-mode-map
  :group 'tirepl
  :global nil)

;; (defun tirepl-mode ()
;;   "Major mode for interactive development with remote Titanium devices."
;;   (interactive)
;;   (kill-all-local-variables)
;;   (setq major-mode 'tirepl-mode)
;;   (setq mode-name "TiREPL")
;;   (use-local-map tirepl-mode-map)

;;   (set (make-local-variable 'scroll-conservatively) 20)
;;   (set (make-local-variable 'scroll-margin) 0)
  
;;   (run-hooks 'tirepl-mode-hook))

;;; Testing
;;; Commented out for now- most of this is particular to my setup, but
;;; feel free to use as a template for you own local testing
;;;
;; (defun tirepl-test-net-send ()
;;   (interactive)
;;   (let* ((proc (tirepl-net-connect "localhost" 5051)))
;;     (sleep-for 1)
;;     (tirepl-net-send-raw "repl.status();\n" proc)
;;     (sleep-for 5)
;;     (tirepl-net-close proc)))

;; (defun tirepl-test-create-session ()
;;   (interactive)
;;   (let* ((sess (tirepl-session-make-session "localhost" 5051)))
;;     (sleep-for 1)
;;     (message "Created session: %s" sess)))

;; (defun tirepl-test-create-session-iphone ()
;;   (interactive)
;;   (let* ((sess (tirepl-session-make-session "localhost" 5061)))
;;     (sleep-for 1)
;;     (message "Created session: %s" sess)))

;; (defun tirepl-test-round-trip-message ()
;;   (tirepl-session-end-all-sessions)
;;   (tirepl-session-make-session)
;;   (tirepl-session-eval (tirepl-session-current-session) "repl.isRunning();\nrepl.status();"
;;                        (lambda (info) (message "Got reply: %s" info)))
;;   (sleep-for 5)
;;   (tirepl-session-end-all-sessions))

;; (defun tirepl-test-round-trip-iphone ()
;;   (tirepl-session-end-all-sessions)
;;   (tirepl-session-make-session "localhost" 5061)
;;   (sleep-for 1)
;;   (tirepl-session-eval (tirepl-session-current-session) "replserver.isRunning();\nreplserver.status();"
;;                        (lambda (info) (message "Got reply: %s" info)))
;;   (sleep-for 5)
;;   (tirepl-session-end-all-sessions))

;; (defun tirepl-test-make-json-msg ()
;;   (let ((session-id 1)
;;         (msg-id 23)
;;         (js-src "win1.backgroundColor = 'red';"))
;;   (json-encode-plist `(:session-id ,session-id
;;                                    :id ,msg-id :type "eval_src" :src ,js-src))))

;; (defun tirepl-test-make-b64-msg ()
;;   (base64-encode-string  (tirepl-test-make-json-msg) t))


;;; Setting up testing workspaces
;; (defun ka ()
;;   "Kill all sessions, unload tirepl, then reload"
;;   (tirepl-session-end-all-sessions)
;;   (unload-feature 'tirepl)
;;   (eval-buffer "tirepl.el")

;; (defun ws ()
;;   "Set up workspace with a session connected to localhost on port 5061"
;;   (tirepl-session-make-session "localhost" 5061)
;;   (tirepl-repl-switch-to-output-buffer))
