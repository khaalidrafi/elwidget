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
  "Without a clock the widget says so, without erroring."
  (with-org-widget-sandbox
   (should (string-match "Not clocked"
                         (nth 1 (elwidget-org--clock-render))))))

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
  "Without loophabits, STYLE=habit entries render with org-todo taps."
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
                                     (equal "org-todo"
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

(provide 'test-elwidget-org)
;;; test-elwidget-org.el ends here
