;;; helm-octopus.el --- Helm interface for octopus -*- lexical-binding: t -*-

;; Copyright (C) 2021 Akira Komamura

;; Author: Akira Komamura <akira.komamura@gmail.com>
;; Version: 0.1
;; Package-Requires: ((emacs "27.1") (org "9.3") (helm "3.6") (octopus "0.1") (dash "2.18"))
;; Keywords: convenience tools outlines
;; URL: https://github.com/akirak/octopus.el

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a Helm interface to octopus.

;;; Code:

(require 'octopus)
(require 'org)
(require 'helm)
(require 'dash)

(defgroup helm-octopus nil
  "Helm interface to octopus."
  :group 'octopus
  :group 'helm)

;;;; Org markers

(defun helm-octopus-show-marker (marker)
  "Show an Org MARKER and narrow to it."
  (switch-to-buffer (marker-buffer marker))
  (widen)
  (goto-char marker)
  (org-show-entry)
  (org-show-children)
  ;; Show the property drawer
  (save-excursion
    (when (re-search-forward org-property-drawer-re (org-entry-end-position) t)
      (org-cycle)))
  (org-narrow-to-subtree))

(defun helm-octopus-clock-in-marker (marker)
  "Clock in to the MARKER."
  (org-with-point-at marker
    (org-clock-in)))

(defun helm-octopus-mark-as-done (_marker)
  "Set the marked Helm candidates as done."
  (dolist (marker (helm-marked-candidates))
    (org-with-point-at marker
      (org-todo 'done))))

(defun helm-octopus-set-todo-state (marker)
  "Change the todo state of an entry at MARKER."
  (save-window-excursion
    (org-goto-marker-or-bmk marker)
    (org-with-wide-buffer
     (org-narrow-to-subtree)
     (org-todo))))

(cl-defun helm-octopus--org-marker-sync-source (name markers
                                                     &key action)
  "Build a sync Helm source for Org markers.

NAME will be the name of the Helm source.

It creates an interface that lets the user select an item from MARKERS.

`octopus-headline-format' is used to format each candidate.

You must specify the ACTION of the Helm source."
  (declare (indent 1))
  (helm-build-sync-source name
    :candidates
    (-map (lambda (marker)
            (cons (org-with-point-at marker
                    (funcall octopus-headline-format))
                  marker))
          markers)
    :persistent-action #'helm-octopus-show-marker
    :action action))

;;;###autoload
(cl-defun helm-octopus-org-marker (prompt markers &key name)
  "Let the user select an Org marker via Helm.

PROMPT is the prompt of the minibuffer.

It lets the user select one of MARKERS.

NAME will be the name of the Helm sync source."
  (helm :prompt prompt
        :sources
        (helm-octopus--org-marker-sync-source name
          markers :action #'identity)))

;;;; Project directories

(defcustom helm-octopus-project-persistent-action
  'display-org-marker
  "Persistent action of `helm-octopus-project'.

This can be a symbol in `octopus-org-project-actions'."
  :type '(choice symbol null))

(defclass helm-octopus-project-source (helm-source-sync)
  ((multiline :initform t)))

;;;###autoload
(cl-defun helm-octopus-project (&key predicate action)
  "Switch to a project directory.

PREDICATE is an Org Ql predicate as passed to
`octopus-org-project-groups'.

Optionally, you can specify an ACTION."
  (interactive)
  (helm :project "Switch to a project: "
        :sources (helm-make-source "Projects" 'helm-octopus-project-source
                   :candidates
                   (helm-octopus--project-group-candidates
                    (or predicate '(any-project)))
                   :persistent-action
                   (helm-octopus--project-persistent-action)
                   :action
                   (or action (helm-octopus--project-action)))))

(defun helm-octopus--project-group-candidates (predicate)
  "Build Helm candidates matching a PREDICATE."
  (->> (octopus-org-project-groups predicate)
       (-map (lambda (it)
               (cons (octopus-format-candidate-multiline it)
                     it)))))

(defun helm-octopus--project-persistent-action ()
  "Build a persistent action for projects."
  (-partial #'octopus--run-action
            helm-octopus-project-persistent-action))

(defun helm-octopus--project-action ()
  "Build a action alist for projects."
  (-map (pcase-lambda (`(,symbol . ,plist))
          (cons (plist-get plist :description)
                (-partial #'octopus--run-action symbol)))
        octopus-org-project-actions))

;;;; Project-scoped helm-org-ql

(defvar helm-octopus-scoped-ql-root-olps)
(defvar helm-octopus-window-width)
(defvar helm-octopus-scoped-ql-project-query)

(defmacro helm-octopus--action-as-command (func)
  "Define an interactive command calling FUNC on the selection."
  `(lambda ()
     (interactive)
     (,func (helm-get-selection))))

(defcustom helm-octopus-entry-action
  (helm-make-actions
   "Display"
   #'helm-octopus-show-marker
   "Clock in"
   #'helm-octopus-clock-in-marker
   "Mark as done"
   #'helm-octopus-mark-as-done)
  "Alist of actions in entry sources.

This is used in `helm-octopus-project-scoped-ql' and
`helm-octopus-global-ql'.

Note that those commands use a different action for the
persistent action."
  :type '(alist :key-type string
                :value-type function))

(defcustom helm-octopus-scoped-ql-sort-fn
  #'helm-octopus-scoped-ql-default-sort
  "Function used to sort candidates in `helm-octopus-project-scoped-ql'.

This should be a 2-ary function that takes org elements as arguments.
The result will be used by `-sort' to sort items."
  :type 'function)

(defcustom helm-octopus-entry-snooze-days 3
  "The span within which to consider in sorting.

`helm-octopus-scoped-ql-default-sort' prioritizes unfinished
entries with scheduled or deadline timestamps. Entries with those
timestamps are shown at top in the selection interface.

If this variable is set to a number, timestamps in N days or
later will be ignored, so they won't be shown at top."
  :type '(choice nil number))

(defun helm-octopus-scoped-ql-default-sort (a b)
  "The default sorting function for `helm-octopus-project-scoped-ql'.


A and B must be Org elements."
  (let ((threshold 50)
        (time-limit (when helm-octopus-entry-snooze-days
                      (ts-unix (octopus-ts-midnight-in-n-days
                                helm-octopus-entry-snooze-days)))))
    (or (let ((time-a (unless (eql 'done (org-element-property :todo-type a))
                        (-some->> (or (org-element-property :scheduled a)
                                      (org-element-property :deadline a))
                          (org-timestamp-to-time)
                          (octopus-time-ignore-later-than time-limit))))
              (time-b (unless (eql 'done (org-element-property :todo-type b))
                        (-some->> (or (org-element-property :scheduled b)
                                      (org-element-property :deadline b))
                          (org-timestamp-to-time)
                          (octopus-time-ignore-later-than time-limit)))))
          (if (and time-a time-b)
              (time-less-p time-a time-b)
            (and time-a (not time-b))))
        (let ((frec-a (org-element-property :frecency-score a))
              (frec-b (org-element-property :frecency-score b)))
          (if (and frec-a frec-b)
              (or (and (>= frec-a threshold)
                       (>= frec-b threshold)
                       (> frec-a frec-b))
                  (and (>= frec-a threshold)
                       (< frec-b threshold)))
            (and frec-a
                 (>= frec-a threshold)))))))

(defcustom helm-octopus-dim-blocked-tasks t
  "Whether to dim candidates of blocked tasks."
  :type 'boolean)

(defun helm-octopus-scoped-ql--candidates ()
  "Build candidates for `helm-octopus-project-scoped-ql'."
  (->> (octopus--ql-select `(default-and (ancestors ,helm-octopus-scoped-ql-project-query)
                              ,(org-ql--query-string-to-sexp helm-pattern))
         :action
         ;; This is unnecessary if org-ql runs `org-show-all' on every buffer.
         '(org-save-outline-visibility t
            (org-show-all)
            (font-lock-ensure (point-at-bol) (point-at-eol))
            (let* ((olp (org-get-outline-path nil t))
                   (blocked (when helm-octopus-dim-blocked-tasks
                              (org-entry-blocked-p)))
                   (local-olp (cl-some (lambda (root-olp)
                                         (let ((n (length root-olp)))
                                           (when (equal root-olp (-take n olp))
                                             (-drop (max 1 (1- n)) olp))))
                                       helm-octopus-scoped-ql-root-olps)))
              (when local-olp
                (-let* ((ts-info (octopus--entry-timestamp-info))
                        (element (-> (org-element-headline-parser (org-entry-end-position))
                                     (org-element-put-property
                                      :frecency-score (octopus-timestamp-info-frecency ts-info)))))
                  (cons element
                        (cons (helm-octopus-scoped-ql--format element
                                :local-olp local-olp
                                :dim-blocked blocked
                                :last-ts (octopus-timestamp-info-last-ts ts-info))
                              (point-marker))))))))
       (-non-nil)
       (-sort (-on helm-octopus-scoped-ql-sort-fn #'car))
       (-map #'cdr)))

(defun helm-octopus---global-candidates ()
  "Build candidates for `helm-octopus-global-ql'."
  (->> (octopus--ql-select `(default-and ,(org-ql--query-string-to-sexp helm-pattern))
         :action
         '(org-save-outline-visibility t
            (org-show-all)
            (font-lock-ensure (point-at-bol) (point-at-eol))
            (let* ((olp (org-get-outline-path nil t))
                   (ts-info (octopus--entry-timestamp-info))
                   (element (-> (org-element-headline-parser (org-entry-end-position))
                                (org-element-put-property
                                 :frecency-score (octopus-timestamp-info-frecency ts-info)))))
              (cons element
                    (cons (helm-octopus-scoped-ql--format element
                            :include-buffer-name t
                            :local-olp olp
                            :last-ts (octopus-timestamp-info-last-ts ts-info))
                          (point-marker))))))
       (-non-nil)
       (-sort (-on helm-octopus-scoped-ql-sort-fn #'car))
       (-map #'cdr)))

(cl-defun helm-octopus-scoped-ql--format (element &key local-olp last-ts
                                                  include-buffer-name
                                                  dim-blocked)
  "Format each candidate from the data.

ELEMENT, LOCAL-OLP, LAST-TS, and INCLUDE-BUFFER-NAME are passed
from `helm-octopus-scoped-ql--candidates'.

If DIM-BLOCKED is non-nil, the heading will be dimmed."
  (declare (indent 1))
  (concat (if include-buffer-name
              (concat (buffer-name) ": ")
            "")
          (substring-no-properties (org-format-outline-path
                                    local-olp helm-octopus-window-width))
          "/"
          (if dim-blocked
              (propertize (org-get-heading) 'face 'org-agenda-dimmed-todo-face)
            (org-get-heading))
          " "
          (if-let (scheduled (org-element-property :scheduled element))
              (concat " SCHEDULED:" (propertize (org-element-property :raw-value scheduled)
                                                'face 'org-scheduled))
            "")
          " "
          (if last-ts
              (propertize (octopus--format-time (ts-unix last-ts))
                          'face 'font-lock-comment-face)
            "")))

(defvar helm-octopus-project-scoped-ql-source
  (helm-make-source "Project-scoped entries" 'helm-source-sync
    :candidates #'helm-octopus-scoped-ql--candidates
    :match #'identity
    :fuzzy-match nil
    :multimatch nil
    :nohighlight t
    :persistent-action #'helm-octopus-show-marker
    :action 'helm-octopus-entry-action
    :volatile t))

(defalias 'helm-octopus-org-todo-persistent-command
  (helm-octopus--action-as-command helm-octopus-set-todo-state)
  "Change the todo state of the selection.")

(defvar helm-octopus-ql-map
  (let ((m (make-composed-keymap helm-map)))
    (define-key m (kbd "C-c C-t") #'helm-octopus-org-todo-persistent-command)
    m))

;;;###autoload
(defun helm-octopus-project-scoped-ql (&optional arg)
  "Project-scoped helm-org-ql.

If a single prefix argument is given, it lets the user select a project.

If two prefix arguments are given as ARG,
`helm-octopus-global-ql' is run.

If a directory is given as the argument, it will be used as the
project root."
  (interactive "P")
  (pcase arg
    ((pred stringp)
     (let* ((root arg)
            (project-query `(project ,root)))
       (setq helm-octopus-scoped-ql-root-olps (octopus--ql-select project-query
                                                :action '(org-get-outline-path t t))
             helm-octopus-window-width (window-width (helm-window))
             helm-octopus-scoped-ql-project-query project-query)
       (helm :prompt (format "Org ql [project: %s]: " (abbreviate-file-name root))
             :sources
             'helm-octopus-project-scoped-ql-source
             :keymap 'helm-octopus-ql-map)))
    ('(16)
     (helm-octopus-global-ql))
    ('(4)
     (helm-octopus-project
      :action (-partial #'octopus--run-action
                        (list :slot 'project-dir
                              :verify #'file-directory-p
                              :dispatch #'helm-octopus-project-scoped-ql))))
    (_
     (helm-octopus-project-scoped-ql (or (and octopus-org-dwim-commands
                                              (derived-mode-p 'org-mode)
                                              (octopus--org-project-root))
                                         (octopus--project-root)
                                         (error "Cannot find a root"))))))

(defvar helm-octopus-global-ql-source
  (helm-make-source "Global" 'helm-source-sync
    :candidates #'helm-octopus---global-candidates
    :match #'identity
    :fuzzy-match nil
    :multimatch nil
    :nohighlight t
    :persistent-action #'helm-octopus-show-marker
    :action 'helm-octopus-entry-action
    :volatile t))

;;;###autoload
(defun helm-octopus-global-ql ()
  "Org-ql from all entries in `octopus-org-files'."
  (interactive)
  (setq helm-octopus-window-width (window-width (helm-window)))
  (helm :prompt "Org ql: "
        :sources 'helm-octopus-global-ql-source))

(provide 'helm-octopus)
;;; helm-octopus.el ends here
