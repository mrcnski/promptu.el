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
;; Finished prompts are remembered in `promptu-history'.  Inside the menu,
;; step back through past prompts with M-p / M-n, or browse them with M-r;
;; the recalled prompt becomes the live session, so it can be edited and
;; re-finished.  `M-x promptu-recall' picks a past prompt and copies it to
;; the kill ring without opening the menu.  History is kept in memory by
;; default; set `promptu-history-file' to persist it across sessions.
;;
;; Keys inside the menu:
;;   <block keys>  add that block
;;   -             arm "negate next" (the next block added is negated)
;;   DEL           remove the most recently added block
;;   M-e           edit the most recently added entry (in a buffer when it
;;                 spans multiple lines or is free text, else the minibuffer)
;;   M-E           edit the whole prompt as free text (saved as one entry)
;;   C-/           undo the last session change
;;   C-M-/         redo an undone change
;;   M-p           recall an older prompt from history
;;   M-n           recall a newer prompt (or return to the in-progress draft)
;;   M-r           browse history and load a past prompt
;;   RET           finish: copy the composed prompt to the kill ring
;;   q / C-g       abort with no output
;;
;; See `promptu-blocks' to customize the available blocks.

;;; Code:

(require 'transient)
(require 'subr-x)
(require 'seq)

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

  :key          string, the transient trigger key.  Must avoid the keys
                reserved for menu control; see `promptu--reserved-keys'.
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

(defcustom promptu-history-max 50
  "Maximum number of past prompts kept in `promptu-history'.
When this is an integer, the oldest entries are dropped once the limit is
exceeded.  A non-integer value (e.g. nil) keeps history unbounded."
  :type '(choice (const :tag "Unbounded" nil) integer)
  :group 'promptu)

(defcustom promptu-history-file nil
  "File used to persist `promptu-history' across Emacs sessions.

When nil (the default), history is kept only in memory for the current
Emacs session, like the kill ring.  When set to a file path, history is
loaded from it on first use and saved after each finished prompt.

Note: composed prompts can include values you typed for placeholders, so
enabling persistence writes those values to this file in plain text."
  :type '(choice (const :tag "In-memory only" nil) file)
  :group 'promptu)

(defface promptu-preview-face
  '((t :inherit font-lock-doc-face))
  "Face for the composed-prompt preview shown at the bottom of the menu."
  :group 'promptu)

(defface promptu-placeholder-face
  '((t :inherit font-lock-variable-name-face))
  "Face for placeholder hints (e.g. <link>) shown in block descriptions."
  :group 'promptu)

(defface promptu-free-text-face
  '((t :inherit font-lock-string-face))
  "Face for free-text regions in the composed-prompt preview.
A region becomes free text when the whole prompt is edited with `M-E'; it
is shown distinctly so it is clear that part is one free-form unit rather
than a discrete building block.  Inherit or override to taste."
  :group 'promptu)

;;; Pure compose core

(defun promptu--strip-surrounding-newlines (text)
  "Return TEXT with leading and trailing newlines removed.
Unlike `string-trim', spaces and tabs at the edges are preserved; only
newline (and carriage-return) characters are stripped.  Used to drop
incidental blank lines from typed input without touching intentional
surrounding spaces."
  (string-trim text "[\n\r]+" "[\n\r]+"))

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

;; A session entry is either a plain string (a building block, the common
;; case) or a plist `(:text STRING :free t)' marking a free-text region --
;; text produced by editing the whole prompt with `M-E', which no longer
;; maps onto a single block.  Blocks stay bare strings so existing history
;; files (lists of strings) still load, treated as blocks.

(defun promptu--make-entry (text free)
  "Return a session entry holding TEXT.
When FREE is non-nil the entry is a free-text region; otherwise it is a
plain block, represented as the bare string TEXT."
  (if free (list :text text :free t) text))

(defun promptu--entry-text (entry)
  "Return the text string of session ENTRY (a string or a :text plist)."
  (if (stringp entry) entry (plist-get entry :text)))

(defun promptu--entry-free-p (entry)
  "Non-nil when session ENTRY is a free-text region rather than a block."
  (and (not (stringp entry)) (plist-get entry :free) t))

(defun promptu--edit-last-needs-buffer-p (entry)
  "Non-nil when ENTRY should be edited in a buffer, not the minibuffer.
True for free-text regions and for any entry whose text spans multiple
lines, since the one-line minibuffer handles neither well."
  (or (promptu--entry-free-p entry)
      (and (string-search "\n" (promptu--entry-text entry)) t)))

(defun promptu--compose (entries)
  "Join ENTRIES into the composed prompt.
Each entry is a session entry (see `promptu--entry-text').  Entries are
joined with `promptu-separator'; when the separator contains a newline,
its trailing line prefix is also applied to the first entry."
  (if (null entries)
      ""
    (concat (promptu--line-prefix promptu-separator)
            (string-join (mapcar #'promptu--entry-text entries)
                         promptu-separator))))

;;; Session state

(defvar promptu--session nil
  "Ordered list of entries for the current compose session.
Oldest first; the most recently added entry is last.  Each entry is
either a bare string (a building block) or a free-text region -- a plist
`(:text STRING :free t)' produced by `M-E'; see `promptu--make-entry'.")

(defvar promptu--negate-next nil
  "When non-nil, the next block added is negated, then this resets to nil.")

(defvar promptu-history nil
  "List of past prompts, most recent first.
Each element is a session: a list of entries the same shape as
`promptu--session' (bare-string blocks and/or free-text plists).
Recompose one with `promptu--compose', which re-applies the current
`promptu-separator'.")

(defvar promptu--history-index nil
  "Position in `promptu-history' while stepping with M-p / M-n.
Nil means the live session is shown (not navigating); an integer is an
index into `promptu-history' where 0 is the most recent entry.")

(defvar promptu--history-stash nil
  "The in-progress session saved when history navigation begins.
Restored by `promptu--history-next' when stepping back past the most
recent entry.")

(defvar promptu--history-loaded nil
  "Non-nil once persisted history has been loaded from `promptu-history-file'.")

(defvar promptu--undo-stack nil
  "Stack of prior `promptu--session' states, newest first, for undo.
Each element is a session snapshot; `promptu--checkpoint' pushes one
before a session-changing command runs.")

(defvar promptu--redo-stack nil
  "Stack of session states undone via `promptu--undo', for redo.
Cleared by `promptu--checkpoint' whenever a new change is made.")

(defun promptu--reset ()
  "Clear the compose session, negate-next flag, history navigation, and undo.
Does not clear `promptu-history' itself."
  (setq promptu--session nil
        promptu--negate-next nil
        promptu--history-index nil
        promptu--history-stash nil
        promptu--undo-stack nil
        promptu--redo-stack nil))

(defun promptu--checkpoint ()
  "Save the current session for undo, discarding any pending redo history.
Call at the start of a command, before it mutates `promptu--session', so
the change can be reverted.  A new change invalidates the redo stack."
  (push (copy-sequence promptu--session) promptu--undo-stack)
  (setq promptu--redo-stack nil))

(defun promptu--undo ()
  "Restore the session to before the last change.
Pushes the current session onto the redo stack and leaves history
navigation.  Reports when there is nothing to undo."
  (interactive)
  (if (null promptu--undo-stack)
      (message "promptu: nothing to undo")
    (push (copy-sequence promptu--session) promptu--redo-stack)
    (setq promptu--session (pop promptu--undo-stack)
          promptu--history-index nil
          promptu--history-stash nil)))

(defun promptu--redo ()
  "Reapply the most recently undone change.
Pushes the current session onto the undo stack and leaves history
navigation.  Reports when there is nothing to redo."
  (interactive)
  (if (null promptu--redo-stack)
      (message "promptu: nothing to redo")
    (push (copy-sequence promptu--session) promptu--undo-stack)
    (setq promptu--session (pop promptu--redo-stack)
          promptu--history-index nil
          promptu--history-stash nil)))

(defun promptu--forget-undo ()
  "Discard undo/redo history.
Called when history navigation switches the session to a different
prompt, so undo stays scoped to edits of the prompt currently shown and
never reverts a change made to a different one."
  (setq promptu--undo-stack nil
        promptu--redo-stack nil))

(defun promptu--placeholder-values (template placeholders)
  "Prompt the minibuffer for each of PLACEHOLDERS that occurs in TEMPLATE.
Returns an alist of (NAME . VALUE).  A placeholder not present as {name}
in TEMPLATE is not prompted for."
  (delq nil
        (mapcar (lambda (name)
                  (when (string-search (format "{%s}" name) template)
                    (cons name (promptu--strip-surrounding-newlines
                                (read-string (format "%s: " name))))))
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
    (promptu--checkpoint)
    (setq promptu--session (append promptu--session (list resolved))
          promptu--negate-next nil
          promptu--history-index nil)))

(defun promptu--remove-last ()
  "Remove the most recently added block from the session.
Safe no-op when the session is empty."
  (interactive)
  (when promptu--session
    (promptu--checkpoint)
    (setq promptu--session (butlast promptu--session)
          promptu--history-index nil)))

(defun promptu--replace-last-entry (text free)
  "Replace the session's last entry with TEXT, marked free-text when FREE.
Checkpoints for undo and leaves history navigation.  Assumes a non-empty
session."
  (promptu--checkpoint)
  (setq promptu--session
        (append (butlast promptu--session)
                (list (promptu--make-entry text free)))
        promptu--history-index nil))

(defun promptu--edit-last ()
  "Edit the most recently added entry, preserving whether it is free text.
A single-line block is edited in the minibuffer, pre-filled with its
current text.  A free-text region or a multi-line entry is edited in a
dedicated buffer instead, since the minibuffer handles neither well.
Safe no-op when the session is empty."
  (interactive)
  (when promptu--session
    (let* ((entry (car (last promptu--session)))
           (text (promptu--entry-text entry))
           (free (promptu--entry-free-p entry)))
      (if (promptu--edit-last-needs-buffer-p entry)
          ;; Open after this command returns and the transient has torn
          ;; down, as with `promptu--edit-prompt'.
          (run-at-time
           0 nil
           (lambda ()
             (promptu--edit-open
              text
              (lambda (edited) (promptu--replace-last-entry edited free))
              (concat "Editing the last entry.  "
                      "\\[promptu--edit-commit] save, "
                      "\\[promptu--edit-abort] cancel."))))
        (let ((edited (promptu--strip-surrounding-newlines
                       (read-string "Edit: " text))))
          ;; Blank input leaves the entry unchanged, like the buffer path;
          ;; removing an entry is DEL's job.
          (if (string-blank-p edited)
              (message "promptu: empty; nothing saved")
            (promptu--replace-last-entry edited free)))))))

(defun promptu--toggle-negate ()
  "Toggle the negate-next flag."
  (interactive)
  (setq promptu--negate-next (not promptu--negate-next)))

;;; History

(defun promptu--history-load ()
  "Read persisted history from `promptu-history-file' into `promptu-history'.
A missing or unreadable file leaves history untouched; a corrupt file is
reported via `lwarn' and otherwise ignored."
  (when (and promptu-history-file (file-readable-p promptu-history-file))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents promptu-history-file)
          (let ((data (read (current-buffer))))
            (when (listp data)
              (setq promptu-history data))))
      (error
       (lwarn 'promptu :warning "failed to read history file %s: %S"
              promptu-history-file err)))))

(defun promptu--history-ensure-loaded ()
  "Load persisted history once when `promptu-history-file' is configured."
  (when (and promptu-history-file (not promptu--history-loaded))
    (setq promptu--history-loaded t)
    (promptu--history-load)))

(defun promptu--history-save ()
  "Write `promptu-history' to `promptu-history-file' when configured.
Creates the containing directory if needed; write errors are reported via
`lwarn' rather than signalled."
  (when promptu-history-file
    (condition-case err
        (progn
          (let ((dir (file-name-directory promptu-history-file)))
            (when dir (make-directory dir t)))
          (with-temp-file promptu-history-file
            (let ((print-length nil) (print-level nil))
              (prin1 promptu-history (current-buffer)))))
      (error
       (lwarn 'promptu :warning "failed to write history file %s: %S"
              promptu-history-file err)))))

(defun promptu--history-add (session)
  "Record SESSION (a list of session entries) at the front of history.
Moves an identical existing entry to the front, truncates to
`promptu-history-max', and persists when configured.  No-op for an empty
SESSION."
  (when session
    (setq promptu-history
          (cons (copy-sequence session)
                (seq-remove (lambda (entry) (equal entry session))
                            promptu-history)))
    (when (and (integerp promptu-history-max)
               (> (length promptu-history) promptu-history-max))
      (setq promptu-history (seq-take promptu-history promptu-history-max)))
    (promptu--history-save)))

(defun promptu--history-read ()
  "Read a past prompt via completion and return its session, or nil.
Loads persisted history first when `promptu-history-file' is set; reports
an empty history and returns nil.  Candidates are the composed prompts in
most-recent-first order."
  (promptu--history-ensure-loaded)
  (if (null promptu-history)
      (progn (message "promptu: history is empty") nil)
    (let* ((pairs (mapcar (lambda (s) (cons (promptu--compose s) s))
                          promptu-history))
           (table (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action (mapcar #'car pairs)
                                            string pred))))
           (choice (completing-read "Past prompt: " table nil t)))
      (cdr (assoc choice pairs)))))

(defun promptu--history-prev ()
  "Recall an older prompt from history into the session.
Stashes the in-progress session the first time navigation starts so
`promptu--history-next' can return to it; clamps at the oldest entry.
Recalling starts a fresh undo slate (see `promptu--forget-undo')."
  (interactive)
  (promptu--history-ensure-loaded)
  (if (null promptu-history)
      (message "promptu: history is empty")
    (when (null promptu--history-index)
      (setq promptu--history-stash promptu--session))
    (promptu--forget-undo)
    (setq promptu--history-index
          (if (null promptu--history-index)
              0
            (min (1+ promptu--history-index) (1- (length promptu-history))))
          promptu--session
          (copy-sequence (nth promptu--history-index promptu-history)))))

(defun promptu--history-next ()
  "Recall a newer prompt from history into the session.
Stepping back past the most recent entry restores the in-progress session
saved by `promptu--history-prev'.  Like `promptu--history-prev', this
starts a fresh undo slate."
  (interactive)
  (cond
   ((null promptu--history-index)
    (message "promptu: not navigating history"))
   ((zerop promptu--history-index)
    (promptu--forget-undo)
    (setq promptu--session promptu--history-stash
          promptu--history-stash nil
          promptu--history-index nil))
   (t
    (promptu--forget-undo)
    (setq promptu--history-index (1- promptu--history-index)
          promptu--session
          (copy-sequence (nth promptu--history-index promptu-history))))))

(defun promptu--history-pick ()
  "Pick a past prompt via completion and load it into the session.
Loading starts a fresh undo slate (see `promptu--forget-undo'), so undo
stays scoped to the loaded prompt."
  (interactive)
  (when-let ((session (promptu--history-read)))
    (promptu--forget-undo)
    (setq promptu--session (copy-sequence session)
          promptu--history-index nil)))

;;;###autoload
(defun promptu-recall ()
  "Pick a past prompt from history and copy it to the kill ring.
Composes the chosen entry with the current `promptu-separator'.  Useful
for reusing a prompt without opening the `promptu' menu."
  (interactive)
  (when-let ((session (promptu--history-read)))
    (kill-new (promptu--compose session))
    (message "promptu: copied recalled prompt to kill ring")))

;;; Editing in a dedicated buffer

;; Shared machinery for editing free-form text in a buffer, used both by
;; `M-E' (edit the whole prompt) and by `M-e' when the last entry is too
;; big for the minibuffer.  A caller supplies the initial text, a header,
;; and an apply function run with the trimmed buffer text on commit.

(defconst promptu--edit-buffer-name "*promptu prompt*"
  "Name of the buffer used to edit prompt text.")

(defvar-local promptu--edit-window-config nil
  "Window configuration to restore when the prompt-edit buffer closes.")

(defvar-local promptu--edit-apply nil
  "Function run with the trimmed buffer text when the edit is committed.")

(defvar promptu-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'promptu--edit-commit)
    (define-key map (kbd "C-c C-k") #'promptu--edit-abort)
    map)
  "Keymap for `promptu-edit-mode'.")

(define-derived-mode promptu-edit-mode text-mode "Promptu-Edit"
  "Major mode for editing promptu prompt text as free text.
Committing runs the edit's apply function on the buffer contents; see
`promptu--edit-open'.  The header line describes the specific edit.")

(defun promptu--strip-line-prefix (text)
  "Remove a single leading `promptu-separator' line prefix from TEXT.
`promptu--compose' prepends the separator's trailing line prefix (e.g.
\"- \") to the prompt's first line; stripping it here lets the edited
text round-trip back through `promptu--compose' as a single entry.
Returns TEXT unchanged when the separator has no line prefix or TEXT
does not start with it."
  (let ((prefix (promptu--line-prefix promptu-separator)))
    (if (and (not (string-empty-p prefix))
             (string-prefix-p prefix text))
        (substring text (length prefix))
      text)))

(defun promptu--set-whole-entry (text)
  "Replace the whole session with TEXT as a single free-text entry.
Strips the leading line prefix so TEXT round-trips through
`promptu--compose', checkpoints for undo, and leaves history navigation."
  (promptu--checkpoint)
  (setq promptu--session
        (list (promptu--make-entry (promptu--strip-line-prefix text) t))
        promptu--history-index nil))

(defun promptu--edit-prompt ()
  "Edit the entire running prompt as free text in a dedicated buffer.
The buffer is pre-filled with the composed prompt, so any part -- not
just the last entry -- can be edited or deleted, and multi-line text
\(such as a pasted error) can be added freely.  Saving collapses the
whole prompt into a single free-text entry.  Safe no-op when the session
is empty."
  (interactive)
  (if (null promptu--session)
      (message "promptu: nothing to edit")
    ;; Open after this command returns and the transient has torn down, so
    ;; transient's own window-configuration restore does not clobber the
    ;; edit window.
    (run-at-time
     0 nil
     (lambda ()
       (promptu--edit-open
        (promptu--compose promptu--session)
        #'promptu--set-whole-entry
        (concat "Editing the whole prompt.  "
                "\\[promptu--edit-commit] save as one entry (replaces all), "
                "\\[promptu--edit-abort] cancel."))))))

(defun promptu--edit-open (initial apply-fn header)
  "Pop up the edit buffer showing INITIAL text with HEADER on the header line.
APPLY-FN is stored buffer-locally and run with the trimmed buffer text
when the edit is committed.  HEADER is passed through
`substitute-command-keys'."
  (let ((config (current-window-configuration))
        (buf (get-buffer-create promptu--edit-buffer-name)))
    (with-current-buffer buf
      (promptu-edit-mode)
      (erase-buffer)
      (insert initial)
      (goto-char (point-min))
      (setq promptu--edit-window-config config
            promptu--edit-apply apply-fn
            header-line-format (substitute-command-keys header)))
    (pop-to-buffer buf)))

(defun promptu--edit-commit ()
  "Apply the buffer text via this edit's apply function and return to the menu.
`C-c C-c' is itself the confirmation.  A blank buffer leaves the session
unchanged."
  (interactive)
  (let ((text (promptu--strip-surrounding-newlines (buffer-string)))
        (config promptu--edit-window-config)
        (apply-fn promptu--edit-apply))
    (if (string-blank-p text)
        (message "promptu: prompt is empty; nothing saved")
      (funcall apply-fn text)
      (promptu--edit-finish config))))

(defun promptu--edit-abort ()
  "Discard the edit and return to the menu unchanged."
  (interactive)
  (promptu--edit-finish promptu--edit-window-config))

(defun promptu--edit-finish (config)
  "Kill the edit buffer, restore window CONFIG, and reopen the promptu menu."
  (let ((buf (current-buffer)))
    (when (window-configuration-p config)
      (set-window-configuration config))
    (when (buffer-live-p buf)
      (kill-buffer buf)))
  (transient-setup 'promptu))

;;; Finalize and abort

(defun promptu--finish ()
  "Copy the composed prompt to the kill ring and report.
A no-op (no kill-ring change) when the session is empty."
  (interactive)
  (if (null promptu--session)
      (message "promptu: nothing to copy")
    (let ((text (promptu--compose promptu--session))
          (n (length promptu--session)))
      (promptu--history-add promptu--session)
      (kill-new text)
      (message "promptu: copied %d block%s to kill ring" n (if (= n 1) "" "s")))))

;;; Transient menu

(defconst promptu--reserved-keys
  '("-" "RET" "DEL" "M-e" "M-E" "M-p" "M-n" "M-r" "C-/" "C-M-/" "q")
  "Keys reserved for menu control; block keys must avoid these.")

(defun promptu--reserved-key-p (key)
  "Return non-nil when KEY is a reserved control key."
  (and (member key promptu--reserved-keys) t))

(defun promptu--warn-key-collisions ()
  "Warn about `promptu-blocks' entries whose :key is reserved.
Such blocks are skipped when building the menu.  This runs once when the
menu opens rather than inside `promptu--block-suffixes', which
`:refresh-suffixes' re-runs on every command -- warning there would spam
one message per keystroke."
  (dolist (block promptu-blocks)
    (let ((key (plist-get block :key)))
      (when (promptu--reserved-key-p key)
        (lwarn 'promptu :warning
               "block key %S collides with a reserved key; skipping" key)))))

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
key are skipped silently here (the collision is reported once by
`promptu--warn-key-collisions' when the menu opens).  Each suffix gets an
explicit command symbol keyed on its :key, so blocks sharing a :desc do not
collide on a description-derived command symbol."
  (transient-parse-suffixes
   'promptu
   (let (specs)
     (dolist (block promptu-blocks)
       (let ((key (plist-get block :key)))
         (unless (promptu--reserved-key-p key)
           (let ((command (promptu--add-command-symbol key)))
             (fset command (promptu--make-add-command block))
             (push (list key
                         (promptu--block-description block)
                         command
                         :transient t)
                   specs)))))
     (nreverse specs))))

(defun promptu--preview-body ()
  "Render the composed prompt, facing free-text regions distinctly.
Each entry's text is faced with `promptu-free-text-face' when it is a
free-text region and `promptu-preview-face' otherwise, so a free-form
region stands out from the surrounding blocks."
  (concat
   (propertize (promptu--line-prefix promptu-separator)
               'face 'promptu-preview-face)
   (mapconcat (lambda (entry)
                (propertize (promptu--entry-text entry)
                            'face (if (promptu--entry-free-p entry)
                                      'promptu-free-text-face
                                    'promptu-preview-face)))
              promptu--session
              (propertize promptu-separator 'face 'promptu-preview-face))))

(defun promptu--preview ()
  "Render the live preview block shown at the bottom of the menu."
  (concat
   (propertize "Preview" 'face 'transient-heading)
   (when promptu--negate-next
     (concat "  " (propertize "[negate next]" 'face 'warning)))
   "\n"
   (if promptu--session
       (promptu--preview-body)
     (propertize "(empty -- pick blocks above)" 'face 'shadow))))

(defun promptu--single-free-text-p ()
  "Non-nil when the session is exactly one free-text entry.
This is the state `M-E' produces (and that editing that entry again
preserves): the whole prompt is one free-form region, so `DEL' and `M-e',
which act on the last entry, act on the entire prompt."
  (and promptu--session
       (null (cdr promptu--session))
       (promptu--entry-free-p (car promptu--session))))

(defun promptu--remove-last-description (&rest _)
  "Dynamic label for the `DEL' suffix.
Reflects that removing the last entry removes the whole prompt when it is
a single free-text region."
  (if (promptu--single-free-text-p) "remove all (free text)" "remove last"))

(defun promptu--edit-last-description (&rest _)
  "Dynamic label for the `M-e' suffix.
Reflects that editing the last entry edits the whole prompt when it is a
single free-text region."
  (if (promptu--single-free-text-p) "edit all (free text)" "edit last"))

(defun promptu--history-prev-inapt-p ()
  "Non-nil when `M-p' would do nothing.
That is when history is empty, or navigation is already at the oldest
entry so stepping older would only clamp in place."
  (or (null promptu-history)
      (and promptu--history-index
           (= promptu--history-index (1- (length promptu-history))))))

(defun promptu--do-edit-last ()
  "Transient pre-command for `M-e' (`promptu--edit-last').
Stay transient for a quick minibuffer edit, but exit -- like `M-E' --
when the last entry needs the buffer editor, so the menu tears down and
the edit buffer can take over input.  Transient uses this as a
suffix's pre-command because its name contains `--do-'; the return value
must come from a `transient--do-*' function."
  (if (and promptu--session
           (promptu--edit-last-needs-buffer-p (car (last promptu--session))))
      (transient--do-exit)
    (transient--do-call)))

;;;###autoload
(transient-define-prefix promptu ()
  "Compose an LLM prompt from building blocks."
  ;; Re-evaluate the :inapt-if* predicates on every command so keys that
  ;; would do nothing (e.g. undo with an empty stack) gray out live.
  :refresh-suffixes t
  ["Blocks"
   :class transient-column
   :setup-children promptu--block-suffixes]
  ["Controls"
   ("-"   "negate next" promptu--toggle-negate :transient t)
   ("DEL" promptu--remove-last
    :description promptu--remove-last-description
    :inapt-if-nil promptu--session :transient t)
   ("M-e" promptu--edit-last
    :description promptu--edit-last-description
    :inapt-if-nil promptu--session
    :transient promptu--do-edit-last)
   ("M-E" "edit all" promptu--edit-prompt :inapt-if-nil promptu--session)
   ("C-/"   "undo" promptu--undo :inapt-if-nil promptu--undo-stack :transient t)
   ("C-M-/" "redo" promptu--redo :inapt-if-nil promptu--redo-stack :transient t)
   ("q"   "abort"       transient-quit-one)]
  ["History"
   ("M-p" "older"  promptu--history-prev
    :inapt-if promptu--history-prev-inapt-p :transient t)
   ("M-n" "newer"  promptu--history-next
    :inapt-if-nil promptu--history-index :transient t)
   ("M-r" "browse" promptu--history-pick
    :inapt-if-nil promptu-history :transient t)]
  [:description promptu--preview
                ("RET" "finish (copy)" promptu--finish :inapt-if-nil promptu--session)]
  (interactive)
  (promptu--reset)
  (promptu--history-ensure-loaded)
  (promptu--warn-key-collisions)
  (transient-setup 'promptu))

(provide 'promptu)

;;; promptu.el ends here
