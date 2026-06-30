;;; promptu.el --- Compose LLM prompts from building blocks -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Marcin Swieczkowski
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4.0"))
;; Keywords: convenience, tools
;; URL: https://github.com/mrcnski/promptu

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; promptu provides a transient menu that composes an LLM prompt from
;; user-customizable building blocks.
;;
;; The opposite of impromptu: composed, not off-the-cuff.
;;
;; Usage:
;;   M-x promptu
;;
;; Pick blocks one at a time; the menu stays open and shows a live preview
;; as blocks accumulate.  Blocks can prompt for runtime values and can be
;; negated.  Press RET to copy the composed prompt to the kill ring, or q
;; (or C-g) to abort.
;;
;; Keys inside the menu:
;;   <block keys>  add that block
;;   -             arm "negate next" (the next block added is negated)
;;   DEL           remove the most recently added block
;;   M-e           edit the most recently added block in the minibuffer
;;   RET           finish: copy the composed prompt to the kill ring
;;   q / C-g       abort with no output
;;
;; See `promptu-blocks' to customize the available blocks.

;;; Code:

(require 'transient)
(require 'subr-x)

(defgroup promptu nil
  "Compose LLM prompts from building blocks."
  :group 'convenience
  :prefix "promptu-")

(defcustom promptu-blocks
  '((:key "t" :desc "" :text "{type a command}" :placeholders ("type a command"))
    (:key "i" :desc "investigate"    :text "investigate {link}" :placeholders ("link"))
    (:key "b" :desc "create branch"  :text "create a branch")
    (:key "r" :desc "review changes" :text "review your changes")
    (:key "c" :desc "commit"         :text "commit")
    (:key "T" :desc "add tests"      :text "add tests")
    (:key "p" :desc "pause"          :text "pause")
    (:key "P" :desc "push"           :text "push when done" :negative "don't push")
    (:key "R" :desc "create a PR"    :text "create a PR")
    (:key "C" :desc "check CI"       :text "check CI"))
  "Building blocks available in the `promptu' menu.

Each block is a plist with these keys:

  :key          string, the transient trigger key (must avoid the
                reserved keys -, RET, DEL, M-e, q).
  :desc         string, the short menu description.
  :text         string, the affirmative text emitted into the prompt.
                May contain named placeholders written as {name}.
  :negative     optional string, the text emitted when the block is
                negated.  When absent, a negated block emits :text
                prefixed with `promptu-negation-prefix'.  May contain
                {name} placeholders, like :text.
  :placeholders optional list of placeholder names (strings).  The user
                is prompted in the minibuffer for each placeholder that
                appears as {name} in the emitted text (whether that is
                :text or :negative), and the value is substituted in
                before the block joins the prompt."
  :type '(repeat
          (plist :options ((:key string)
                           (:desc string)
                           (:text string)
                           (:negative string)
                           (:placeholders (repeat string)))))
  :group 'promptu)

(defcustom promptu-separator "\n- "
  "Separator placed between blocks in the composed prompt.

When the separator contains a newline, the text following its last
newline is also prepended to the first block as a line prefix, so the
default \"\\n- \" produces a fully bulleted list."
  :type 'string
  :group 'promptu)

(defcustom promptu-negation-prefix "don't "
  "Prefix prepended to a negated block's affirmative text.

Used only when a negated block does not define explicit :negative text."
  :type 'string
  :group 'promptu)

(defface promptu-preview-face
  '((t :inherit font-lock-doc-face))
  "Face for the composed-prompt preview shown at the bottom of the menu."
  :group 'promptu)

(defface promptu-placeholder-face
  '((t :inherit font-lock-variable-name-face))
  "Face for placeholder hints (e.g. <link>) shown in block descriptions."
  :group 'promptu)

;;; Pure compose core

(defun promptu--substitute (text values)
  "Substitute placeholders in TEXT using VALUES.
VALUES is an alist of (NAME . VALUE) where NAME is a placeholder name
string; each occurrence of {NAME} in TEXT is replaced with VALUE."
  (let ((result text))
    (dolist (pair values result)
      (setq result (string-replace (format "{%s}" (car pair)) (cdr pair) result)))))

(defun promptu--resolve (block negated)
  "Return BLOCK's emitted template before placeholder substitution.
When NEGATED is non-nil, return BLOCK's :negative text if defined, else
its :text prefixed with `promptu-negation-prefix'.  When NEGATED is nil,
return BLOCK's :text.  Either template may still contain {name}
placeholders, which the caller substitutes."
  (let ((text (plist-get block :text)))
    (if negated
        (or (plist-get block :negative)
            (concat promptu-negation-prefix text))
      text)))

(defun promptu--line-prefix (separator)
  "Return the text following the last newline in SEPARATOR, or \"\" if none."
  (if (string-match "\n\\([^\n]*\\)\\'" separator)
      (match-string 1 separator)
    ""))

(defun promptu--compose (entries)
  "Join ENTRIES (a list of resolved strings) into the composed prompt.
Entries are joined with `promptu-separator'; when the separator contains
a newline, its trailing line prefix is also applied to the first entry."
  (if (null entries)
      ""
    (concat (promptu--line-prefix promptu-separator)
            (string-join entries promptu-separator))))

;;; Session state

(defvar promptu--session nil
  "Ordered list of resolved block strings for the current compose session.
Oldest first; the most recently added block is last.")

(defvar promptu--negate-next nil
  "When non-nil, the next block added is negated, then this resets to nil.")

(defun promptu--reset ()
  "Clear the compose session and the negate-next flag."
  (setq promptu--session nil
        promptu--negate-next nil))

(defun promptu--placeholder-values (template placeholders)
  "Prompt the minibuffer for each of PLACEHOLDERS that occurs in TEMPLATE.
Returns an alist of (NAME . VALUE).  A placeholder not present as {name}
in TEMPLATE is not prompted for."
  (delq nil
        (mapcar (lambda (name)
                  (when (string-search (format "{%s}" name) template)
                    (cons name (read-string (format "%s: " name)))))
                placeholders)))

(defun promptu--add (block)
  "Resolve BLOCK and append its emitted text to the session.
Picks the affirmative or :negative template per `promptu--negate-next',
prompts only for placeholders that appear in that template, substitutes
them, then resets the negate flag."
  (let* ((negate promptu--negate-next)
         (template (promptu--resolve block negate))
         (values (promptu--placeholder-values template (plist-get block :placeholders)))
         (resolved (promptu--substitute template values)))
    (setq promptu--session (append promptu--session (list resolved))
          promptu--negate-next nil)))

(defun promptu--remove-last ()
  "Remove the most recently added block from the session.
Safe no-op when the session is empty."
  (interactive)
  (when promptu--session
    (setq promptu--session (butlast promptu--session))))

(defun promptu--edit-last ()
  "Edit the most recently added block's text in the minibuffer.
Pre-fills the minibuffer with the current last entry and replaces it
with the edited value.  Safe no-op when the session is empty."
  (interactive)
  (when promptu--session
    (let ((edited (read-string "Edit: " (car (last promptu--session)))))
      (setq promptu--session
            (append (butlast promptu--session) (list edited))))))

(defun promptu--toggle-negate ()
  "Toggle the negate-next flag."
  (interactive)
  (setq promptu--negate-next (not promptu--negate-next)))

;;; Finalize and abort

(defun promptu--finish ()
  "Copy the composed prompt to the kill ring and report.
A no-op (no kill-ring change) when the session is empty."
  (interactive)
  (if (null promptu--session)
      (message "promptu: nothing to copy")
    (let ((text (promptu--compose promptu--session))
          (n (length promptu--session)))
      (kill-new text)
      (message "promptu: copied %d block%s to kill ring" n (if (= n 1) "" "s")))))

;;; Transient menu

(defconst promptu--reserved-keys '("-" "RET" "DEL" "M-e" "q")
  "Keys reserved for menu control; block keys must avoid these.")

(defun promptu--reserved-key-p (key)
  "Return non-nil when KEY is a reserved control key."
  (and (member key promptu--reserved-keys) t))

(defun promptu--add-command-symbol (key)
  "Return the interned command symbol for the block bound to KEY."
  (intern (concat "promptu--add-" key)))

(defun promptu--make-add-command (block)
  "Return an interactive command that adds BLOCK to the session."
  (lambda ()
    (interactive)
    (promptu--add block)))

(defun promptu--block-description (block)
  "Return BLOCK's menu description with faced <placeholder> hints appended.
A block with no :placeholders returns its :desc unchanged.  When :desc is
empty, the hints stand alone with no leading space."
  (let* ((desc (or (plist-get block :desc) ""))
         (placeholders (plist-get block :placeholders))
         (hints (and placeholders
                     (mapconcat (lambda (name)
                                  (propertize (format "<%s>" name)
                                              'face 'promptu-placeholder-face))
                                placeholders " "))))
    (cond ((not hints) desc)
          ((string-empty-p desc) hints)
          (t (concat desc " " hints)))))

(defun promptu--block-suffixes (_)
  "Build transient suffixes from `promptu-blocks'.
One stay-open suffix per block; blocks whose key collides with a reserved
key are skipped with a warning.  Each suffix gets an explicit command
symbol keyed on its :key, so blocks sharing a :desc do not collide on a
description-derived command symbol."
  (transient-parse-suffixes
   'promptu
   (let (specs)
     (dolist (block promptu-blocks)
       (let ((key (plist-get block :key)))
         (if (promptu--reserved-key-p key)
             (lwarn 'promptu :warning
                    "block key %S collides with a reserved key; skipping" key)
           (let ((command (promptu--add-command-symbol key)))
             (fset command (promptu--make-add-command block))
             (push (list key
                         (promptu--block-description block)
                         command
                         :transient t)
                   specs)))))
     (nreverse specs))))

(defun promptu--preview ()
  "Render the live preview block shown at the bottom of the menu."
  (concat
   (propertize "Preview" 'face 'transient-heading)
   (when promptu--negate-next
     (concat "  " (propertize "[negate next]" 'face 'warning)))
   "\n"
   (if promptu--session
       (propertize (promptu--compose promptu--session) 'face 'promptu-preview-face)
     (propertize "(empty -- pick blocks above)" 'face 'shadow))))

;;;###autoload
(transient-define-prefix promptu ()
  "Compose an LLM prompt from building blocks."
  ["Blocks"
   :class transient-column
   :setup-children promptu--block-suffixes]
  ["Controls"
   ("-"   "negate next" promptu--toggle-negate :transient t)
   ("DEL" "remove last" promptu--remove-last   :transient t)
   ("M-e" "edit last"   promptu--edit-last      :transient t)
   ("q"   "abort"       transient-quit-one)]
  [:description promptu--preview
   ("RET" "finish (copy)" promptu--finish)]
  (interactive)
  (promptu--reset)
  (transient-setup 'promptu))

(provide 'promptu)

;;; promptu.el ends here
