;;; smtp.el --- basic functions to send mail with SMTP server

;; Copyright (C) 1995, 1996, 1998, 1999 Free Software Foundation, Inc.

;; Author: Tomoji Kagatani <kagatani@rbc.ncl.omron.co.jp>
;;	Simon Leinen <simon@switch.ch> (ESMTP support)
;;	Shuhei KOBAYASHI <shuhei@aqua.ocn.ne.jp>
;;	Daiki Ueno <ueno@unixuser.org>
;; Keywords: SMTP, mail

;; This file is part of FLIM (Faithful Library about Internet Message).

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(require 'poe)
(require 'poem)
(require 'pcustom)
(require 'mail-utils)			; mail-strip-quoted-names

(eval-when-compile (require 'cl))	; push

(require 'tram)

(eval-and-compile
  (luna-define-class smtp-stream (tram-stream)
		     (process
		      extensions))

  (luna-define-internal-accessors 'smtp-stream))

(defgroup smtp nil
  "SMTP protocol for sending mail."
  :group 'mail)

(defcustom smtp-default-server nil
  "Specify default SMTP server."
  :type '(choice (const nil) string)
  :group 'smtp)

(defcustom smtp-server (or (getenv "SMTPSERVER") smtp-default-server)
  "The name of the host running SMTP server.  It can also be a function
called from `smtp-via-smtp' with arguments SENDER and RECIPIENTS."
  :type '(choice (string :tag "Name")
		 (function :tag "Function"))
  :group 'smtp)

(defcustom smtp-service "smtp"
  "SMTP service port number. \"smtp\" or 25."
  :type '(choice (integer :tag "25" 25)
                 (string :tag "smtp" "smtp"))
  :group 'smtp)

(defcustom smtp-use-8bitmime t
  "If non-nil, use ESMTP 8BITMIME if available."
  :type 'boolean
  :group 'smtp)

(defcustom smtp-local-domain nil
  "Local domain name without a host name.
If the function (system-name) returns the full internet address,
don't define this value."
  :type '(choice (const nil) string)
  :group 'smtp)

(defcustom smtp-notify-success nil
  "If non-nil, notification for successful mail delivery is returned 
 to user (RFC1891)."
  :type 'boolean
  :group 'smtp)

(defvar smtp-transaction-compose-function
  #'smtp-default-transaction-compose-function)

(defvar smtp-open-connection-function (function open-network-stream))

(defvar smtp-read-point nil)

(defun smtp-make-fqdn ()
  "Return user's fully qualified domain name."
  (let ((system-name (system-name)))
    (cond
     (smtp-local-domain
      (concat system-name "." smtp-local-domain))
     ((string-match "[^.]\\.[^.]" system-name)
      system-name)
     (t
      (error "Cannot generate valid FQDN. Set `smtp-local-domain' correctly.")))))

(defun smtp-greeting (trans)
  (let ((response
	 (smtp-read-response
	  (smtp-stream-process-internal trans))))
    (or (smtp-check-response response)
	(tram-stream-error trans 'greeting))
    trans))
  
(defun smtp-ehlo (trans)
  (smtp-send-command
   (smtp-stream-process-internal trans)
   (format "EHLO %s" (smtp-make-fqdn)))
  (let ((response
	 (smtp-read-response 
	  (smtp-stream-process-internal trans))))
    (or (smtp-check-response response)
	(tram-stream-error trans 'ehlo))
    (smtp-stream-set-extensions-internal
     trans (mapcar
	    (lambda (extension)
	      (car (read-from-string (downcase extension))))
	    (cdr response)))
    trans))

(defun smtp-helo (trans)
  (smtp-send-command
   (smtp-stream-process-internal trans)
   (format "HELO %s" (smtp-make-fqdn)))
  (let ((response
	 (smtp-read-response
	  (smtp-stream-process-internal trans))))
    (or (smtp-check-response response)
	(tram-stream-error trans 'helo))
    trans))

(defun smtp-mailfrom (sender trans)
  (smtp-send-command
   (smtp-stream-process-internal trans)
   (format "MAIL FROM:<%s>%s"
	   sender
	   ;; SIZE --- Message Size Declaration (RFC1870)
;;;	   (if (memq 'size
;;;		     (smtp-stream-extensions-internal trans))
;;;	       (format " SIZE=%d"
;;;		       (save-excursion
;;;			 (set-buffer buffer)
;;;			 (+ (- (point-max) (point-min))
;;;			    ;; Add one byte for each change-of-line
;;;			    ;; because or CR-LF representation:
;;;			    (count-lines (point-min) (point-max))
;;;			    ;; For some reason, an empty line is
;;;			    ;; added to the message.	Maybe this
;;;			    ;; is a bug, but it can't hurt to add
;;;			    ;; those two bytes anyway:
;;;			    2)))
;;;	     "")
	   ;; 8BITMIME --- 8bit-MIMEtransport (RFC1652)
	   (if (and (memq '8bitmime
			  (smtp-stream-extensions-internal trans))
		    smtp-use-8bitmime)
	       " BODY=8BITMIME"
	     "")))
  (let ((response
	 (smtp-read-response
	  (smtp-stream-process-internal trans))))
    (or (smtp-check-response response)
	(tram-stream-error trans 'mailfrom))
    trans))

(defun smtp-rcptto (recipient trans)
  (let (response)
    (smtp-send-command
     (smtp-stream-process-internal trans)
     (format
      (if smtp-notify-success
	  "RCPT TO:<%s> NOTIFY=SUCCESS"
	"RCPT TO:<%s>")
      recipient))
    (setq response
	  (smtp-read-response
	   (smtp-stream-process-internal trans)))
    (or (smtp-check-response response)
	(tram-stream-error trans 'rcptto))
    trans))

(defun smtp-data (buffer trans)
  (smtp-send-command
   (smtp-stream-process-internal trans)
   "DATA")
  (let ((response
	 (smtp-read-response
	  (smtp-stream-process-internal trans))))
    (or (smtp-check-response response)
	(tram-stream-error trans 'data))

    ;; Mail contents
    (smtp-send-data 
     (smtp-stream-process-internal trans)
     buffer)
    ;; DATA end "."
    (smtp-send-command
     (smtp-stream-process-internal trans)
     ".")
    (setq response
	  (smtp-read-response
	   (smtp-stream-process-internal trans)))
    (or (smtp-check-response response)
	(tram-stream-error trans 'data))
    trans))

(defun smtp-default-transaction-compose-function (sender recipients buffer)
  (tram-compose-transaction
   `(&& smtp-greeting
	(|| smtp-ehlo smtp-helo)
	,(closure-partial-call #'smtp-mailfrom sender)
	,@(mapcar
	   (lambda (recipient)
	     (closure-partial-call #'smtp-rcptto recipient))
	   recipients)
	,(closure-partial-call #'smtp-data buffer))))

(defun smtp-via-smtp (sender recipients smtp-text-buffer)
  (let ((server (if (functionp smtp-server)
		    (funcall smtp-server sender recipients)
		  smtp-server))
	process response extensions trans error)
    (save-excursion
      (set-buffer
       (get-buffer-create
	(format "*trace of SMTP session to %s*" server)))
      (buffer-disable-undo)
      (erase-buffer)
      (make-local-variable 'smtp-read-point)
      (setq smtp-read-point (point-min))
      (unwind-protect
	  (let ((function
		 (funcall smtp-transaction-compose-function
			  sender recipients smtp-text-buffer)))
	    (or (functionp function)
		(error "Unable to compose SMTP commands"))
	    (if (eq (car-safe function) 'lambda)
		(setq function (byte-compile function)))
	    (as-binary-process
	     (setq process
		   (funcall smtp-open-connection-function
			    "SMTP" (current-buffer) server smtp-service)))
	    (when process
	      (set-process-filter process 'smtp-process-filter)
	      (setq trans
		    (luna-make-entity 'smtp-stream :process process)
		    error
		    (catch (tram-stream-error-name trans)
		      (funcall function trans)
		      nil))
	      (not error)))
	(when (and process
		   (memq (process-status process) '(open run)))
	  ;; QUIT
	  (smtp-send-command process "QUIT")
	  (delete-process process))))))

(defun smtp-process-filter (process output)
  (save-excursion
    (set-buffer (process-buffer process))
    (goto-char (point-max))
    (insert output)))

(defun smtp-read-response (process)
  (let ((case-fold-search nil)
	response
	(response-continue t)
	match-end)
    (while response-continue
      (goto-char smtp-read-point)
      (while (not (search-forward "\r\n" nil t))
	(accept-process-output process)
	(goto-char smtp-read-point))
      (setq match-end (point))
      (setq response
	    (nconc response
		   (list (buffer-substring (+ 4 smtp-read-point)
					   (- match-end 2)))))
      (goto-char smtp-read-point)
      (when (looking-at "[1-5][0-9][0-9] ")
	(setq response-continue nil)
	(push (read (point-marker)) response))
      (setq smtp-read-point match-end))
    response))

(defun smtp-check-response (response)
  (memq (/ (car response) 100) '(2 3)));; XXX

(defun smtp-send-command (process command)
  (goto-char (point-max))
  (insert command "\r\n")
  (setq smtp-read-point (point))
  (process-send-string process command)
  (process-send-string process "\r\n"))

(defun smtp-send-data-1 (process data)
  (goto-char (point-max))
  (setq smtp-read-point (point))
  ;; Escape "." at start of a line.
  (if (eq (string-to-char data) ?.)
      (process-send-string process "."))
  (process-send-string process data)
  (process-send-string process "\r\n"))

(defun smtp-send-data (process buffer)
  (let ((data-continue t)
	(sending-data nil)
	this-line
	this-line-end)

    (save-excursion
      (set-buffer buffer)
      (goto-char (point-min)))

    (while data-continue
      (save-excursion
	(set-buffer buffer)
	(beginning-of-line)
	(setq this-line (point))
	(end-of-line)
	(setq this-line-end (point))
	(setq sending-data nil)
	(setq sending-data (buffer-substring this-line this-line-end))
	(if (or (/= (forward-line 1) 0) (eobp))
	    (setq data-continue nil)))

      (smtp-send-data-1 process sending-data))))

(defun smtp-deduce-address-list (smtp-text-buffer header-start header-end)
  "Get address list suitable for smtp RCPT TO:<address>."
  (let ((simple-address-list "")
	this-line
	this-line-end
	addr-regexp
	(smtp-address-buffer (generate-new-buffer " *smtp-mail*")))
    (unwind-protect
	(save-excursion
	  ;;
	  (set-buffer smtp-address-buffer)
	  (setq case-fold-search t)
	  (erase-buffer)
	  (insert (save-excursion
		    (set-buffer smtp-text-buffer)
		    (buffer-substring-no-properties header-start header-end)))
	  (goto-char (point-min))
	  ;; RESENT-* fields should stop processing of regular fields.
	  (save-excursion
	    (if (re-search-forward "^RESENT-TO:" header-end t)
		(setq addr-regexp
		      "^\\(RESENT-TO:\\|RESENT-CC:\\|RESENT-BCC:\\)")
	      (setq addr-regexp	 "^\\(TO:\\|CC:\\|BCC:\\)")))

	  (while (re-search-forward addr-regexp header-end t)
	    (replace-match "")
	    (setq this-line (match-beginning 0))
	    (forward-line 1)
	    ;; get any continuation lines.
	    (while (and (looking-at "^[ \t]+") (< (point) header-end))
	      (forward-line 1))
	    (setq this-line-end (point-marker))
	    (setq simple-address-list
		  (concat simple-address-list " "
			  (mail-strip-quoted-names
			   (buffer-substring this-line this-line-end)))))
	  (erase-buffer)
	  (insert-string " ")
	  (insert-string simple-address-list)
	  (insert-string "\n")
	  ;; newline --> blank
	  (subst-char-in-region (point-min) (point-max) 10 ?  t)
	  ;; comma   --> blank
	  (subst-char-in-region (point-min) (point-max) ?, ?  t)
	  ;; tab     --> blank
	  (subst-char-in-region (point-min) (point-max)	 9 ?  t)

	  (goto-char (point-min))
	  ;; tidyness in case hook is not robust when it looks at this
	  (while (re-search-forward "[ \t]+" header-end t) (replace-match " "))

	  (goto-char (point-min))
	  (let (recipient-address-list)
	    (while (re-search-forward " \\([^ ]+\\) " (point-max) t)
	      (backward-char 1)
	      (setq recipient-address-list
		    (cons (buffer-substring (match-beginning 1) (match-end 1))
			  recipient-address-list)))
	    recipient-address-list))
      (kill-buffer smtp-address-buffer))))

(provide 'smtp)

;;; smtp.el ends here
