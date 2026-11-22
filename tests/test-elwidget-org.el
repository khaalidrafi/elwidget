;;; test-elwidget-org.el --- ERT tests for elwidget-org.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'org)
(require 'elwidget-org)
(require 'cl-lib)

(defvar org-file nil "Sandbox org file, dynamically bound.")

(defmacro with-org-widget-sandbox (&rest body)
  "Run BODY with temp org files and a temp elwidget dir."
  `(let* ((dir (make-temp-file "ew-org-" t))
          (org-file (expand-file-name "test.org" dir))
          (elwidget-dir (expand-file-name "elwidget/" dir))
          (elwidget-registry nil)
          (elwidget--event-cursor nil)
          (elwidget-org-agenda-files (list org-file))
          (org-agenda-files (list org-file))
          (org-id-locations-file (expand-file-name ".org-id" dir))
          (today (format-time-string "%Y-%m-%d")))
     ,@body))

(defun ewo--write-org (text)
  "Write TEXT to the sandbox org file."
  (with-temp-file org-file
    (insert text)))

(ert-deftest elwidget-org-agenda-finds-today ()
  "Scheduled and deadlined entries for today appear, sorted."
  (with-org-widget-sandbox
   (ewo--write-org
    (concat
     "* Fixed appointment\n"
     "SCHEDULED: <" today " " (format-time-string "%a") " 09:30>\n"
     "* Deadline tonight\n"
     "DEADLINE: <" today " " (format-time-string "%a") " 21:00>\n"
     "* Not today\n"
     "SCHEDULED: <2020-01-01 Wed 08:00>\n"
     "* No timestamp at all\n"))
   (let ((entries (elwidget-org--entries-for-today)))
     (should (equal 2 (length entries)))
     (should (equal "09:30" (car (nth 0 entries))))
     (should (equal "Fixed appointment" (nth 1 (nth 0 entries))))
     (should (equal "21:00" (car (nth 1 entries)))))))

(ert-deftest elwidget-org-agenda-render-no-entries ()
  "The render tree degrades to a friendly message."
  (with-org-widget-sandbox
   (ewo--write-org "* Nothing scheduled\n")
   (let ((tree (elwidget-org--agenda-render)))
     (should (cl-some
              (lambda (n)
                (and (eq (car n) :text)
                     (string-match "Nothing scheduled" (nth 1 n))))
              tree)))))

(ert-deftest elwidget-org-tasks-tree-has-checks ()
  "TODO entries become check rows with org-todo actions."
  (with-org-widget-sandbox
   (ewo--write-org
    "* TODO First thing\n* TODO Second thing\n* DONE Already done\n* Plain heading\n")
   (let* ((entries (elwidget-org--todo-entries)))
     (should (equal 2 (length entries)))
     (should (equal "First thing" (nth 0 (nth 0 entries)))))))

(ert-deftest elwidget-org-clock-idle ()
  "Without a clock and no history the widget says so, without erroring."
  (with-org-widget-sandbox
   (let ((tree (elwidget-org--clock-render)))
     (should (equal 1 (length tree)))
     (should (string-match "Not clocked" (nth 1 (car tree)))))))

(ert-deftest elwidget-org-table-rows ()
  "Named tables render their data rows, separators skipped."
  (with-org-widget-sandbox
   (ewo--write-org
    "#+NAME: elwidget-demo\n| A | B |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\n")
   (let ((rows (elwidget-org--table-rows org-file "elwidget-demo")))
     (should (equal 3 (length rows)))
     (should (equal '("A" "B") (nth 0 rows)))
     (should (equal '("1" "2") (nth 1 rows))))))

(ert-deftest elwidget-org-agenda-repeater-due-today ()
  "A cyclic timestamp is due on its next occurrence, not only its start.
`org-time-string-to-absolute' does the date arithmetic (Owner
order 2026-11-18: reuse existing Org features)."
  (with-org-widget-sandbox
   (ewo--write-org
    (concat
     "* Daily chore\n"
     "SCHEDULED: <2020-01-01 Wed 08:00 +1d>\n"
     "* Far future cycle\n"
     "SCHEDULED: <2120-01-01 Wed 07:00 +30d>\n"))
   (let ((entries (elwidget-org--entries-for-today)))
     (should (equal 1 (length entries)))
     (should (equal "08:00" (car (nth 0 entries))))
     (should (equal "Daily chore" (nth 1 (nth 0 entries)))))))

(ert-deftest elwidget-org-tasks-ids-stable-and-tappable ()
  "Ids are minted once at the collected entry; an org-todo tap cycles it."
  (with-org-widget-sandbox
   (ewo--write-org "* TODO Tap me\n")
   (let* ((first (elwidget-org--todo-entries))
          (id (nth 3 (nth 0 first)))
          (second (elwidget-org--todo-entries)))
     (should (equal 1 (length first)))
     (should (stringp id))
     (should (equal id (nth 3 (nth 0 second))))
     (should (elwidget-org--todo-on-event "org-todo" id))
     (should (null (elwidget-org--todo-entries))))))

(ert-deftest elwidget-org-habits-builtin-fallback ()
  "Without loophabits, STYLE=habit entries render with toggle taps
(the shadow-state word, so the app flips the check instantly)."
  (with-org-widget-sandbox
   (ewo--write-org
    (concat
     "* TODO Brush teeth\n"
     "SCHEDULED: <2020-01-01 Wed +1d>\n"
     ":PROPERTIES:\n:STYLE: habit\n:END:\n"
     "* TODO Not a habit\n"))
   (skip-unless (require 'org-habit nil t))
   (let ((tree (elwidget-org--habits-render)))
     (should (cl-some
              (lambda (n)
                (and (eq (car n) :row)
                     (cl-some (lambda (c)
                                (and (eq (car c) :check)
                                     (equal "toggle"
                                            (plist-get (cddr c) :action))))
                              (cdr n))))
              tree))
     (should (cl-some
              (lambda (n)
                (and (eq (car n) :row)
                     (cl-some (lambda (c)
                                (and (eq (car c) :text)
                                     (string-match "Brush" (nth 1 c))))
                              (cdr n))))
              tree))
     (should-not (cl-some
                  (lambda (n)
                    (and (eq (car n) :text)
                         (string-match "loophabits" (nth 1 n))))
                  tree)))))

(ert-deftest elwidget-org-register-widgets ()
  "Registration defines all five built-ins."
  (with-org-widget-sandbox
   (elwidget-org-register-widgets)
   (dolist (name '("org-agenda" "org-tasks" "org-habits"
                   "org-clock" "org-table"))
     (should (elwidget-get name)))))

;;; --- v0.3.0: interactive clock, habit done-today, shadow state -------------

(ert-deftest elwidget-org-clock-idle-is-a-node-list ()
  "The idle clock render is a LIST of nodes (single-plist trees drop
every node after the first when wrapped by `elwidget-render')."
  (with-org-widget-sandbox
   (let ((tree (elwidget-org--clock-render)))
     (should (listp tree))
     (should (eq :text (car (car tree))))
     (should (string-match "Not clocked" (nth 1 (car tree)))))))

(ert-deftest elwidget-org-clock-idle-offers-recents ()
  "Idle with clock history: one clock-in button per recent entry,
most recent first, deduplicated, with org-id args."
  (with-org-widget-sandbox
   (ewo--write-org "* TODO Write the report\n* TODO Buy milk\n")
   (let* ((buf (find-file-noselect org-file))
          (mark-at (lambda (heading)
                     (save-match-data
                       (with-current-buffer buf
                         (save-excursion
                           (save-restriction
                             (widen)
                             (goto-char (point-min))
                             (re-search-forward
                              (concat "^\\*+ \\(?:TODO \\)?" (regexp-quote heading)))
                             (point-marker)))))))
          (m1 (funcall mark-at "Write the report"))
          (m2 (funcall mark-at "Buy milk"))
          (org-clock-history (list m1 m2 m1)))
     (unwind-protect
         (let* ((tree (elwidget-org--clock-render))
                (buttons (seq-filter
                          (lambda (n) (eq (car n) :button)) tree)))
           (should (string-match "Not clocked" (nth 1 (car tree))))
           (should (equal 2 (length buttons))) ; m1 deduplicated
           (should (equal "Write the report" (nth 1 (car buttons))))
           (should (equal "clock-in" (plist-get (cddr (car buttons)) :action)))
           (should (string-match
                    "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
                    (plist-get (cddr (car buttons)) :arg))))
       (with-current-buffer buf (set-buffer-modified-p nil))
       (kill-buffer buf)))))

(ert-deftest elwidget-org-clock-in-and-out-events ()
  "A clock-in tap starts Org's clock at the tapped entry; the render
gains a Clock out button; a clock-out tap stops it again."
  (with-org-widget-sandbox
   (ewo--write-org "* TODO Write the report\n")
   (let* ((buf (find-file-noselect org-file))
          (org-clock-history nil))
     (unwind-protect
         (let* ((entries (elwidget-org--todo-entries))
                (id (nth 3 (car entries))))
           (should id)
           ;; Idle first.
           (should-not (elwidget-org--clock-running-p))
           ;; Tap clock-in.
           (should (elwidget-org--clock-on-event "clock-in" id))
           (should (elwidget-org--clock-running-p))
           (let ((tree (elwidget-org--clock-render)))
             (should (cl-some (lambda (n)
                                (and (eq (car n) :row)
                                     (cl-some (lambda (c)
                                                (and (eq (car c) :button)
                                                     (equal "Clock out" (nth 1 c))))
                                              (cdr n))))
                              tree))
             (should (cl-some (lambda (n)
                                (and (eq (car n) :text)
                                     (string-match "Write the report" (nth 1 n))))
                              tree)))
           ;; Tap clock-out.
           (should (elwidget-org--clock-on-event "clock-out" "now"))
           (should-not (elwidget-org--clock-running-p))
           ;; The entry now has a closed CLOCK line (position-
           ;; independent: read the whole buffer, org may leave
           ;; point anywhere).
           (let ((contents (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
             (message "ewo buffer after clock out: %s" contents)
             (should (string-match ":LOGBOOK:" contents))
             (should (string-match "CLOCK: \\[" contents))))
       (ignore-errors (org-clock-out))
       (with-current-buffer buf (set-buffer-modified-p nil))
       (kill-buffer buf)))))

(ert-deftest elwidget-org-habits-done-today-from-logbook ()
  "\"Done today\" is Org's own reading: the LOGBOOK done-date the
consistency graph parses, not the TODO keyword."
  (with-org-widget-sandbox
   (let ((today (format-time-string "%Y-%m-%d %a")))
     (ewo--write-org
      (concat
       "* TODO Exercise\n"
       "SCHEDULED: <" today " .+1d>\n"
       ":PROPERTIES:\n:STYLE: habit\n:END:\n"
       ":LOGBOOK:\n"
       "- State \"DONE\"       from \"TODO\"       [" today " 09:00]\n"
       ":END:\n"
       "* TODO Meditate\n"
       "SCHEDULED: <" today " .+1d>\n"
       ":PROPERTIES:\n:STYLE: habit\n:END:\n"))
   (let* ((entries (elwidget-org--habit-entries))
          (by-title (lambda (title)
                      (cl-find title entries :key #'car :test #'equal))))
     (should (equal 2 (length entries)))
     (should (nth 2 (funcall by-title "Exercise")))
     (should-not (nth 2 (funcall by-title "Meditate")))
     ;; And the shadow state agrees: 1 for done, 0 for not.
     (let* ((state (elwidget-org--habits-state))
            (state-of (lambda (title)
                        (cdr (assoc (nth 3 (funcall by-title title))
                                    state)))))
       (should (equal 1 (funcall state-of "Exercise")))
       (should (equal 0 (funcall state-of "Meditate"))))))))

(ert-deftest elwidget-org-tasks-state-all-unchecked ()
  "Shadow state for org-tasks: one 0 per open task id."
  (with-org-widget-sandbox
   (ewo--write-org "* TODO First\n* TODO Second\n* DONE Done\n")
   (let ((state (elwidget-org--tasks-state)))
     (should (equal 2 (length state)))
     (should (cl-every (lambda (cell) (equal 0 (cdr cell))) state)))))

(ert-deftest elwidget-org-tasks-toggle-event-cycles-todo ()
  "The shadow-state \"toggle\" action runs org-todo, and the older
\"org-todo\" spelling keeps working."
  (with-org-widget-sandbox
   (ewo--write-org "* TODO First\n")
   (let* ((buf (find-file-noselect org-file))
          (id (nth 3 (car (elwidget-org--todo-entries)))))
     (unwind-protect
         (let ((state-now
                (lambda ()
                  (with-current-buffer buf
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (point-min))
                        (org-get-todo-state)))))))
           ;; org-todo cycles TODO -> DONE -> (none) -> TODO.
           (should (elwidget-org--todo-on-event "toggle" id))
           (should (equal "DONE" (funcall state-now)))
           (should (elwidget-org--todo-on-event "org-todo" id))
           (should (null (funcall state-now)))
           (should (elwidget-org--todo-on-event "toggle" id))
           (should (equal "TODO" (funcall state-now))))
       (with-current-buffer buf (set-buffer-modified-p nil))
       (kill-buffer buf)))))

(provide 'test-elwidget-org)
;;; test-elwidget-org.el ends here
