;;; test-elwidget.el --- ERT tests for elwidget.el -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'elwidget)

(defmacro with-elwidget-sandbox (&rest body)
  "Run BODY with `elwidget-dir' in a temp directory and a clean registry."
  `(let ((elwidget-dir (make-temp-file "elwidget-" t))
         (elwidget-registry nil)
         (elwidget--event-cursor nil)
         (elwidget--timers nil))
     ,@body))

(ert-deftest elwidget-define-and-render ()
  "Defining a widget writes a spec file with the right skeleton."
  (with-elwidget-sandbox
   (elwidget-define "hello" :size [4 1]
     :render (lambda () '(:text "Hello!" :size 16)))
   (let ((file (elwidget-render "hello")))
     (should (file-exists-p file))
     (let ((doc (json-read-file file)))
       (should (equal 1 (cdr (assq 'version doc))))
       (should (equal "hello" (cdr (assq 'spec doc))))
       (should (equal 4 (aref (cdr (assq 'size doc)) 0)))
       (should (equal 1 (aref (cdr (assq 'size doc)) 1)))
       (let ((children (cdr (assq 'children doc))))
         (should (= 1 (length children)))
         (should (equal "text" (cdr (assq 'type (aref children 0)))))
         (should (equal "Hello!" (cdr (assq 'text (aref children 0))))))))))

(ert-deftest elwidget-render-wraps-single-node ()
  "A single node list and a lone node both become one child."
  (with-elwidget-sandbox
   (elwidget-define "one" :render (lambda () '(:text "single")))
   (elwidget-render "one")
   (should (= 1 (length (cdr (assq 'children
                                   (json-read-file
                                    (elwidget-spec-file "one")))))))))

(ert-deftest elwidget-node-types ()
  "Every node type serializes with its type tag."
  (with-elwidget-sandbox
   (let ((tree `(:column
                 (:row (:text "a") (:gap :height 4))
                 (:check t :action "toggle" :arg "habit:water")
                 (:check off :label "x" :action "toggle" :arg "i")
                 (:check skip :action "toggle" :arg "i2")
                 (:button "Go" :action "open" :arg "agenda")
                 (:progress :value 3 :max 8 :label "3/8")
                 (:bar :height 2 :color "#111111"))))
     (let ((json (mapcar #'elwidget--tree-to-json
                         (if (keywordp (car tree)) (list tree) tree))))
       (should (equal "column" (cdr (assq 'type (car json)))))
       (let ((kids (cdr (assq 'children (car json)))))
         (should (equal "row" (cdr (assq 'type (nth 0 kids)))))
         (should (equal "check" (cdr (assq 'type (nth 1 kids)))))
         (should (equal "on" (cdr (assq 'state (nth 1 kids)))))
         (should (equal "toggle" (cdr (assq 'action (nth 1 kids)))))
         (should (equal "habit:water" (cdr (assq 'arg (nth 1 kids)))))
         (should (equal "off" (cdr (assq 'state (nth 2 kids)))))
         (should (equal "skip" (cdr (assq 'state (nth 3 kids)))))
         (should (equal "button" (cdr (assq 'type (nth 4 kids)))))
         (should (equal "open" (cdr (assq 'action (nth 4 kids)))))
         (should (equal "progress" (cdr (assq 'type (nth 5 kids)))))
         (should (equal 3 (cdr (assq 'value (nth 5 kids)))))
         (should (equal 8 (cdr (assq 'max (nth 5 kids)))))
         (should (equal "bar" (cdr (assq 'type (nth 6 kids)))))
         ;; the row's own children are [text, gap]
         (let ((rkids (cdr (assq 'children (nth 0 kids)))))
           (should (equal "text" (cdr (assq 'type (nth 0 rkids)))))
           (should (equal "gap" (cdr (assq 'type (nth 1 rkids)))))))))))

(ert-deftest elwidget-bad-nodes-error ()
  "Malformed nodes fail loudly, not silently."
  (with-elwidget-sandbox
   (should-error (elwidget--tree-to-json '(:text 42)))
   (should-error (elwidget--tree-to-json '(:bogus "x")))
   (should-error (elwidget--tree-to-json '("text" "not a keyword")))
   (should-error (elwidget--tree-to-json '(:progress :value 1)))
   (should-error (elwidget--tree-to-json '(:text "x" :align 'sideways)))))

(ert-deftest elwidget-state-file-written ()
  ":state functions feed the instant-toggle shadow state."
  (with-elwidget-sandbox
   (elwidget-define "h" :render (lambda () '(:text "hi"))
     :state (lambda () '(("habit:water" . t) ("habit:book" . 3))))
   (elwidget-render "h")
   (let ((state (json-read-file (elwidget--file "state.json"))))
     (should (equal 1 (cdr (assq (intern "habit:water") state))))
     (should (equal 3 (cdr (assq (intern "habit:book") state)))))))

(ert-deftest elwidget-events-drain-and-dispatch ()
  "Events are drained once, dispatched to :on-event, cursor saved."
  (with-elwidget-sandbox
   (let* ((taps nil))
     (elwidget-define "tapper" :render (lambda () '(:text "t"))
       :on-event (lambda (action arg)
                   (push (cons action arg) taps)
                   nil))
     (with-temp-file (elwidget--events-file)
       (insert "{\"id\":1,\"spec\":\"tapper\",\"action\":\"toggle\",\"arg\":\"habit:water\"}\n"
               "{\"id\":2,\"spec\":\"tapper\",\"action\":\"toggle\",\"arg\":\"habit:book\"}\n"
               "{\"id\":2,\"spec\":\"tapper\",\"action\":\"toggle\",\"arg\":\"dup\"}\n"))
     (should (= 2 (elwidget-read-events)))
     (should (= 0 (elwidget-read-events)))  ; id 2 seen again: dedup
     (should (equal 2 (length taps)))
     ;; ordering: push -> reversed; first event is last in list
     (should (equal "habit:book" (cdr (nth 0 taps))))
     (should (equal 2 elwidget--event-cursor))
     (should (equal 2 (cdr (assq 'id (json-read-file
                                       (elwidget--event-cursor-file)))))))))

(ert-deftest elwidget-default-toggle-triggers-refresh ()
  "With no handler, a toggle event asks for a refresh."
  (with-elwidget-sandbox
   (elwidget-define "nohandler" :render (lambda () '(:text "n")))
   (with-temp-file (elwidget--events-file)
     (insert "{\"id\":7,\"spec\":\"nohandler\",\"action\":\"toggle\",\"arg\":\"x\"}\n"))
   ;; elwidget--dispatch returns non-nil for toggle without handler
   (should (elwidget--dispatch '((spec . "nohandler")
                                 (action . "toggle")
                                 (arg . "x"))))
   (should (not (elwidget--dispatch '((spec . "nohandler")
                                      (action . "open")
                                      (arg . "x")))))))

(ert-deftest elwidget-define-validates ()
  "Bad definitions are rejected up front."
  (with-elwidget-sandbox
   (should-error (elwidget-define "" :render (lambda () nil)))
   (should-error (elwidget-define "x" :render "not a function"))
   (should-error (elwidget-define "x" :render (lambda () nil) :size '(4 2)))))

(ert-deftest elwidget-progress-stepper-fields ()
  "Progress nodes carry action/arg/fmt for the inc/dec steppers."
  (let ((json (elwidget--tree-to-json
               '(:progress :value 5 :max 30
                           :label "5/30 pages"
                           :fmt "{v}/30 pages"
                           :action "inc" :arg "Read a book#value"
                           :color "#7dcfff"))))
    (should (equal "progress" (cdr (assq 'type json))))
    (should (equal 5 (cdr (assq 'value json))))
    (should (equal 30 (cdr (assq 'max json))))
    (should (equal "5/30 pages" (cdr (assoc "label" json))))
    (should (equal "{v}/30 pages" (cdr (assoc "fmt" json))))
    (should (equal "inc" (cdr (assq 'action json))))
    (should (equal "Read a book#value" (cdr (assq 'arg json))))
    (should (equal "#7dcfff" (cdr (assoc "color" json))))))

(ert-deftest elwidget-progress-plain-stays-plain ()
  "A progress node without action/arg/fmt keeps the old shape."
  (let ((json (elwidget--tree-to-json
               '(:progress :value 3 :max 8 :label "3/8"))))
    (should (equal "progress" (cdr (assq 'type json))))
    (should (not (assq 'action json)))
    (should (not (assq 'arg json)))
    (should (not (assq 'fmt json)))))

(ert-deftest elwidget-progress-validates ()
  "Stepper progress fields are checked, not silently dropped."
  (should-error (elwidget--tree-to-json
                 '(:progress :value 1 :max 2 :fmt "no placeholder")))
  (should-error (elwidget--tree-to-json
                 '(:progress :value 1 :max 2 :fmt 42)))
  (should-error (elwidget--tree-to-json
                 '(:progress :value 1 :max 2 :action 'bogus :arg "x"
                             :fmt "{v}/{m}"))))

(provide 'test-elwidget)
;;; test-elwidget.el ends here
