;;; promptu-test.el --- Tests for promptu -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the pure compose core, session mutators, and finalize
;; behavior of promptu.  Run with:
;;
;;   emacs -batch -L . -l promptu-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'promptu)

;;; promptu--resolve (R5, AE1)

(ert-deftest promptu-resolve-negated-without-explicit-negative ()
  "Covers AE1: negated block with no :negative gets the default prefix."
  (let ((promptu-negation-prefix "don't "))
    (should (equal (promptu--resolve '(:key "p" :text "push when done") t)
                   "don't push when done"))))

(ert-deftest promptu-resolve-negated-with-explicit-negative ()
  "Covers AE1: negated block with :negative returns that template."
  (should (equal (promptu--resolve '(:key "t" :text "add tests"
                                     :negative "skip the tests")
                                   t)
                 "skip the tests")))

(ert-deftest promptu-resolve-not-negated-returns-affirmative ()
  (should (equal (promptu--resolve '(:key "p" :text "push when done") nil)
                 "push when done")))

(ert-deftest promptu-resolve-negation-prefix-configurable ()
  (let ((promptu-negation-prefix "do not "))
    (should (equal (promptu--resolve '(:text "push") t)
                   "do not push"))))

;;; promptu--substitute (R4, AE2)

(ert-deftest promptu-substitute-single-placeholder ()
  "Covers AE2."
  (should (equal (promptu--substitute "investigate {link}"
                                      '(("link" . "https://example.com/issue/42")))
                 "investigate https://example.com/issue/42")))

(ert-deftest promptu-substitute-multiple-placeholders ()
  (should (equal (promptu--substitute "{a} and {b}"
                                      '(("a" . "x") ("b" . "y")))
                 "x and y")))

(ert-deftest promptu-substitute-no-values-unchanged ()
  (should (equal (promptu--substitute "plain text" nil) "plain text")))

(ert-deftest promptu-substitute-unfilled-token-left-literal ()
  (should (equal (promptu--substitute "investigate {link}" nil)
                 "investigate {link}")))

;;; promptu--compose (R10, KTD5, AE3)

(ert-deftest promptu-compose-default-separator-bulleted ()
  "Covers AE3: three blocks join as a fully bulleted list."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose '("review your changes" "commit" "don't push"))
                   "- review your changes\n- commit\n- don't push"))))

(ert-deftest promptu-compose-single-entry-gets-line-prefix ()
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose '("review your changes"))
                   "- review your changes"))))

(ert-deftest promptu-compose-inline-separator-no-prefix ()
  (let ((promptu-separator ", "))
    (should (equal (promptu--compose '("a" "b" "c")) "a, b, c"))))

(ert-deftest promptu-compose-plain-newline-no-prefix ()
  (let ((promptu-separator "\n"))
    (should (equal (promptu--compose '("a" "b" "c")) "a\nb\nc"))))

(ert-deftest promptu-compose-empty-list ()
  (should (equal (promptu--compose nil) "")))

;;; Session mutators (R3, R4, R8, KTD1, KTD8)

(defmacro promptu-test--with-session (&rest body)
  "Run BODY with a fresh, isolated promptu session."
  `(let ((promptu--session nil)
         (promptu--point nil)
         (promptu--negate-next nil)
         (promptu--undo-stack nil)
         (promptu--redo-stack nil)
         (promptu--history-index nil)
         (promptu--history-stash nil)
         (promptu-negation-prefix "don't "))
     ,@body))

(ert-deftest promptu-add-appends-in-order ()
  (promptu-test--with-session
   (promptu--add '(:text "review your changes"))
   (promptu--add '(:text "commit"))
   (should (equal promptu--session '("review your changes" "commit")))))

(ert-deftest promptu-add-same-block-twice ()
  (promptu-test--with-session
   (promptu--add '(:text "commit"))
   (promptu--add '(:text "commit"))
   (should (equal promptu--session '("commit" "commit")))))

(ert-deftest promptu-add-consumes-negate-next ()
  (promptu-test--with-session
   (setq promptu--negate-next t)
   (promptu--add '(:text "push when done"))
   (should (equal promptu--session '("don't push when done")))
   (should (null promptu--negate-next))))

(ert-deftest promptu-add-negated-with-explicit-negative-skips-prompt ()
  "A negated block whose :negative has no placeholder must not prompt."
  (promptu-test--with-session
   (setq promptu--negate-next t)
   (cl-letf (((symbol-function 'read-string)
              (lambda (&rest _) (error "should not prompt when no token present"))))
     (promptu--add '(:text "investigate {link}"
                     :placeholders ("link")
                     :negative "skip it")))
   (should (equal promptu--session '("skip it")))
   (should (null promptu--negate-next))))

(ert-deftest promptu-add-negative-with-placeholder-substitutes ()
  "A placeholder inside :negative is prompted for and substituted."
  (promptu-test--with-session
   (setq promptu--negate-next t)
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "PR-7")))
     (promptu--add '(:text "review {pr}"
                     :placeholders ("pr")
                     :negative "ignore {pr}")))
   (should (equal promptu--session '("ignore PR-7")))))

(ert-deftest promptu-add-negated-default-prefix-substitutes-text-placeholder ()
  "A negated block with no :negative substitutes the {token} in :text."
  (promptu-test--with-session
   (setq promptu--negate-next t)
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "X")))
     (promptu--add '(:text "investigate {link}" :placeholders ("link"))))
   (should (equal promptu--session '("don't investigate X")))))

(ert-deftest promptu-add-placeholder-substitutes ()
  (promptu-test--with-session
   (cl-letf (((symbol-function 'read-string)
              (lambda (&rest _) "https://example.com/issue/42")))
     (promptu--add '(:text "investigate {link}" :placeholders ("link"))))
   (should (equal promptu--session
                  '("investigate https://example.com/issue/42")))))

(ert-deftest promptu-remove-last ()
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))
   (promptu--remove-entry)
   (should (equal promptu--session '("a")))))

(ert-deftest promptu-remove-last-empty-noop ()
  (promptu-test--with-session
   (promptu--remove-entry)
   (should (null promptu--session))))

(ert-deftest promptu-edit-last-replaces-last-entry ()
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "B-edited")))
     (promptu--edit-entry))
   (should (equal promptu--session '("a" "B-edited")))))

(ert-deftest promptu-edit-last-prefills-current-value ()
  "The minibuffer is pre-filled with the current last entry."
  (promptu-test--with-session
   (promptu--add '(:text "original"))
   (let (seen-initial)
     (cl-letf (((symbol-function 'read-string)
                (lambda (_prompt &optional initial &rest _)
                  (setq seen-initial initial)
                  "kept")))
       (promptu--edit-entry))
     (should (equal seen-initial "original")))))

(ert-deftest promptu-edit-last-empty-noop ()
  (promptu-test--with-session
   (cl-letf (((symbol-function 'read-string)
              (lambda (&rest _) (error "should not prompt on empty session"))))
     (promptu--edit-entry))
   (should (null promptu--session))))

(ert-deftest promptu-toggle-negate ()
  (promptu-test--with-session
   (promptu--toggle-negate)
   (should promptu--negate-next)
   (promptu--toggle-negate)
   (should (null promptu--negate-next))))

(ert-deftest promptu-reset-clears-all ()
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (setq promptu--negate-next t
         promptu--point 0)
   (promptu--reset)
   (should (null promptu--session))
   (should (null promptu--negate-next))
   (should (null promptu--point))))

;;; Finalize (R9, R11, AE3)

(ert-deftest promptu-finish-copies-composed-prompt ()
  "Covers AE3: finish places the bulleted prompt on the kill ring."
  (promptu-test--with-session
   (let ((kill-ring nil)
         (kill-ring-yank-pointer nil)
         (promptu-separator "\n- ")
         (promptu--session '("review your changes" "commit" "don't push")))
     (promptu--finish)
     (should (equal (current-kill 0)
                    "- review your changes\n- commit\n- don't push")))))

(ert-deftest promptu-finish-empty-no-kill-ring-change ()
  (let ((kill-ring '("previous"))
        (kill-ring-yank-pointer nil)
        (promptu--session nil))
    (promptu--finish)
    (should (equal (car kill-ring) "previous"))))

(ert-deftest promptu-abort-leaves-kill-ring-untouched ()
  "Aborting (reset without finish) must not touch the kill ring."
  (let ((kill-ring '("previous"))
        (kill-ring-yank-pointer nil)
        (promptu--session '("a" "b")))
    (promptu--reset)
    (should (equal (car kill-ring) "previous"))))

;;; Reserved-key collision guard (KTD6)

;;; Block description with placeholder hints

(ert-deftest promptu-block-description-no-placeholders ()
  (should (equal (promptu--block-description '(:desc "commit"))
                 "commit")))

(ert-deftest promptu-block-description-appends-placeholder-hint ()
  (let ((desc (promptu--block-description
               '(:desc "investigate" :placeholders ("link")))))
    (should (equal (substring-no-properties desc) "investigate <link>"))
    ;; the <link> hint carries the placeholder face
    (should (eq (get-text-property (string-search "<" desc) 'face desc)
                'promptu-placeholder-face))))

(ert-deftest promptu-block-description-empty-desc-no-leading-space ()
  (should (equal (substring-no-properties
                  (promptu--block-description
                   '(:desc "" :placeholders ("type a command"))))
                 "<type a command>")))

(ert-deftest promptu-block-description-multiple-placeholders ()
  (should (equal (substring-no-properties
                  (promptu--block-description
                   '(:desc "link" :placeholders ("from" "to"))))
                 "link <from> <to>")))

(ert-deftest promptu-block-suffixes-unique-commands-per-key ()
  "Blocks sharing a :desc must not collide; each key gets its own command."
  (let ((promptu-blocks '((:key "a" :desc "dup" :text "FIRST")
                          (:key "b" :desc "dup" :text "SECOND")))
        (promptu--session nil)
        (promptu--negate-next nil))
    (promptu--block-suffixes nil) ; defines the per-key commands
    (should (fboundp (promptu--add-command-symbol "a")))
    (should (fboundp (promptu--add-command-symbol "b")))
    (funcall (promptu--add-command-symbol "a"))
    (funcall (promptu--add-command-symbol "b"))
    (should (equal promptu--session '("FIRST" "SECOND")))))

(ert-deftest promptu-block-suffixes-skips-reserved-key-silently ()
  "Building suffixes must not warn: `:refresh-suffixes' re-runs it per keystroke.
The reserved-key collision is reported by `promptu--warn-key-collisions'
instead, so no `lwarn' fires from the refresh path."
  (let ((promptu-blocks '((:key "DEL" :desc "bad" :text "X")
                          (:key "a"   :desc "ok"  :text "Y")))
        (warned nil))
    (cl-letf (((symbol-function 'lwarn)
               (lambda (&rest _) (setq warned t))))
      (promptu--block-suffixes nil))
    (should-not warned)
    ;; The reserved key is dropped; only the valid block gets a command.
    (should-not (fboundp (promptu--add-command-symbol "DEL")))
    (should (fboundp (promptu--add-command-symbol "a")))))

(ert-deftest promptu-warn-key-collisions-warns-once-per-reserved-key ()
  "`promptu--warn-key-collisions' warns for each colliding block, valid ones aside."
  (let ((promptu-blocks '((:key "DEL" :desc "bad" :text "X")
                          (:key "a"   :desc "ok"  :text "Y")))
        (warnings nil))
    (cl-letf (((symbol-function 'lwarn)
               (lambda (&rest args) (push args warnings))))
      (promptu--warn-key-collisions))
    (should (= (length warnings) 1))))

(ert-deftest promptu-blocks-defaults-to-default-blocks ()
  "`promptu-blocks' ships equal to the public `promptu-default-blocks' constant,
so users can extend it with (append promptu-default-blocks ...)."
  (should (consp promptu-default-blocks))
  (should (equal (default-value 'promptu-blocks) promptu-default-blocks)))

(ert-deftest promptu-reserved-key-p ()
  (should (promptu--reserved-key-p "-"))
  (should (promptu--reserved-key-p "RET"))
  (should (promptu--reserved-key-p "DEL"))
  (should (promptu--reserved-key-p "M-e"))
  (should (promptu--reserved-key-p "M-E"))
  (should (promptu--reserved-key-p "M-p"))
  (should (promptu--reserved-key-p "M-n"))
  (should (promptu--reserved-key-p "M-r"))
  (should (promptu--reserved-key-p "C-p"))
  (should (promptu--reserved-key-p "C-n"))
  (should (promptu--reserved-key-p "C-/"))
  (should (promptu--reserved-key-p "C-M-/"))
  (should (promptu--reserved-key-p "q"))
  (should-not (promptu--reserved-key-p "p"))
  (should-not (promptu--reserved-key-p "i")))

;;; History

(defmacro promptu-test--with-history (&rest body)
  "Run BODY with a fresh, isolated promptu history and session."
  `(let ((promptu-history nil)
         (promptu-history-max 50)
         (promptu-history-file nil)
         (promptu--history-loaded t)
         (promptu--history-index nil)
         (promptu--history-stash nil)
         (promptu--undo-stack nil)
         (promptu--redo-stack nil)
         (promptu--session nil)
         (promptu--point nil)
         (promptu--negate-next nil)
         (promptu-negation-prefix "don't ")
         (promptu-separator "\n- "))
     ,@body))

(ert-deftest promptu-history-finish-records-session ()
  "Finishing pushes the session (a list of strings) onto history."
  (promptu-test--with-history
   (let ((kill-ring nil) (kill-ring-yank-pointer nil))
     (setq promptu--session '("review your changes" "commit"))
     (promptu--finish)
     (should (equal promptu-history '(("review your changes" "commit")))))))

(ert-deftest promptu-history-add-dedup-moves-to-front ()
  (promptu-test--with-history
   (promptu--history-add '("a"))
   (promptu--history-add '("b"))
   (promptu--history-add '("a"))
   (should (equal promptu-history '(("a") ("b"))))))

(ert-deftest promptu-history-add-truncates-to-max ()
  (promptu-test--with-history
   (setq promptu-history-max 2)
   (promptu--history-add '("a"))
   (promptu--history-add '("b"))
   (promptu--history-add '("c"))
   (should (equal promptu-history '(("c") ("b"))))))

(ert-deftest promptu-history-add-empty-noop ()
  (promptu-test--with-history
   (promptu--history-add nil)
   (should (null promptu-history))))

(ert-deftest promptu-history-stores-session-not-composed-text ()
  "History keeps the block list, so recall recomposes with the live separator."
  (promptu-test--with-history
   (setq promptu-history '(("a" "b")))
   (let ((promptu-separator " | "))
     (should (equal (promptu--compose (car promptu-history)) "a | b")))))

(ert-deftest promptu-history-prev-steps-older-and-clamps ()
  (promptu-test--with-history
   (setq promptu-history '(("new") ("mid") ("old")))
   (promptu--history-prev)
   (should (equal promptu--session '("new")))
   (should (equal promptu--history-index 0))
   (promptu--history-prev)
   (should (equal promptu--session '("mid")))
   (promptu--history-prev)
   (should (equal promptu--session '("old")))
   (promptu--history-prev)               ; clamp at oldest
   (should (equal promptu--session '("old")))
   (should (equal promptu--history-index 2))))

(ert-deftest promptu-history-next-restores-in-progress-session ()
  (promptu-test--with-history
   (setq promptu-history '(("new") ("old"))
         promptu--session '("draft"))
   (promptu--history-prev)               ; stash ("draft"), load ("new")
   (should (equal promptu--session '("new")))
   (promptu--history-prev)               ; ("old")
   (should (equal promptu--session '("old")))
   (promptu--history-next)               ; back to ("new")
   (should (equal promptu--session '("new")))
   (promptu--history-next)               ; back to the stashed draft
   (should (equal promptu--session '("draft")))
   (should (null promptu--history-index))))

(ert-deftest promptu-history-prev-empty-noop ()
  (promptu-test--with-history
   (promptu--history-prev)
   (should (null promptu--session))
   (should (null promptu--history-index))))

(ert-deftest promptu-history-next-not-navigating-noop ()
  (promptu-test--with-history
   (setq promptu--session '("x"))
   (promptu--history-next)
   (should (equal promptu--session '("x")))
   (should (null promptu--history-index))))

(ert-deftest promptu-history-add-clears-navigation-index ()
  "Adding a block after recalling leaves history navigation."
  (promptu-test--with-history
   (setq promptu-history '(("new") ("old")))
   (promptu--history-prev)
   (should (equal promptu--history-index 0))
   (promptu--add '(:text "extra"))
   (should (null promptu--history-index))
   (should (equal promptu--session '("new" "extra")))))

(ert-deftest promptu-history-remove-last-clears-index ()
  (promptu-test--with-history
   (setq promptu-history '(("a" "b")))
   (promptu--history-prev)
   (promptu--remove-entry)
   (should (null promptu--history-index))
   (should (equal promptu--session '("a")))))

(ert-deftest promptu-history-pick-loads-session ()
  (promptu-test--with-history
   (setq promptu-history '(("a" "b") ("c")))
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (promptu--compose '("a" "b")))))
     (promptu--history-pick))
   (should (equal promptu--session '("a" "b")))
   (should (null promptu--history-index))))

(ert-deftest promptu-recall-copies-with-current-separator ()
  (promptu-test--with-history
   (setq promptu-history '(("review your changes" "commit")))
   (let ((kill-ring nil) (kill-ring-yank-pointer nil)
         (promptu-separator ", "))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (&rest _) "review your changes, commit")))
       (promptu-recall))
     (should (equal (current-kill 0) "review your changes, commit")))))

(ert-deftest promptu-history-read-empty-returns-nil ()
  (promptu-test--with-history
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (error "should not prompt on empty history"))))
     (should (null (promptu--history-read))))))

(ert-deftest promptu-history-reset-keeps-data-clears-nav ()
  (promptu-test--with-history
   (setq promptu-history '(("a"))
         promptu--history-index 0
         promptu--history-stash '("draft"))
   (promptu--reset)
   (should (equal promptu-history '(("a"))))
   (should (null promptu--history-index))
   (should (null promptu--history-stash))))

(ert-deftest promptu-history-no-file-no-load ()
  "With no file configured, ensure-loaded leaves history untouched."
  (let ((promptu-history-file nil)
        (promptu--history-loaded nil)
        (promptu-history '(("kept"))))
    (promptu--history-ensure-loaded)
    (should (equal promptu-history '(("kept"))))))

(ert-deftest promptu-history-persists-to-disk ()
  "Saving then loading round-trips the history through a file."
  (let* ((file (make-temp-file "promptu-history-"))
         (promptu-history-file file)
         (promptu-history-max 50))
    (unwind-protect
        (progn
          (let ((promptu-history '(("a" "b") ("c"))))
            (promptu--history-save))
          (let ((promptu-history nil)
                (promptu--history-loaded nil))
            (promptu--history-ensure-loaded)
            (should (equal promptu-history '(("a" "b") ("c"))))))
      (delete-file file))))

;;; Editing the whole prompt

(ert-deftest promptu-edit-round-trips-composed-prompt ()
  "Free text recomposes verbatim, keeping the prefix the user kept."
  (let* ((promptu-separator "\n- ")
         (session '("review your changes" "commit" "don't push"))
         (composed (promptu--compose session)))
    (should (equal (promptu--compose (list (promptu--make-entry composed t)))
                   composed))))

(ert-deftest promptu-edit-deleted-prefix-stays-deleted ()
  "Free text whose leading prefix was deleted composes without it."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose (list (promptu--make-entry "a\n- b" t)))
                   "a\n- b"))))

(ert-deftest promptu-edit-collapses-multiline-into-one-entry ()
  "A multi-line edit becomes a single verbatim entry."
  (let* ((promptu-separator "\n- ")
         (text "- review\n- here is an error:\nTraceback\nValueError: x"))
    (should (equal (promptu--compose (list (promptu--make-entry text t)))
                   text))))

;;; Typed session entries: blocks (strings) vs free-text regions (plists)

(ert-deftest promptu-entry-text-and-free-p ()
  (should (equal (promptu--entry-text "block") "block"))
  (should (equal (promptu--entry-text '(:text "ft" :free t)) "ft"))
  (should-not (promptu--entry-free-p "block"))
  (should (promptu--entry-free-p '(:text "ft" :free t))))

(ert-deftest promptu-make-entry-preserves-kind ()
  (should (equal (promptu--make-entry "b" nil) "b"))
  (should (equal (promptu--make-entry "f" t) '(:text "f" :free t))))

(ert-deftest promptu-compose-mixes-block-and-free-text ()
  "Compose reads text from both bare-string blocks and :text plists."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose (list "review" '(:text "err:\nx" :free t)))
                   "- review\nerr:\nx"))))

(ert-deftest promptu-compose-no-prefix-before-mid-list-free-text ()
  "A free entry after blocks keeps its own prefix; none is prepended.
Regression: inserting blocks before an M-E entry doubled the bullet."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose (list "commit" '(:text "- push" :free t)))
                   "- commit\n- push"))
    (should (equal (promptu--compose (list "commit" '(:text "push" :free t)))
                   "- commit\npush")))
  (let ((promptu-separator ", "))
    ;; no line prefix to drop: the full separator still applies
    (should (equal (promptu--compose (list "commit" '(:text "push" :free t)))
                   "commit, push"))))

(ert-deftest promptu-compose-free-text-first-no-prefix ()
  "No line prefix before leading free text; later blocks still separate."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--compose (list '(:text "intro" :free t) "commit"))
                   "intro\n- commit"))))

(ert-deftest promptu-edit-last-needs-buffer-p ()
  "Free-text and multi-line entries need the buffer; single-line blocks don't."
  (should-not (promptu--edit-needs-buffer-p "single line"))
  (should (promptu--edit-needs-buffer-p "two\nlines"))
  (should (promptu--edit-needs-buffer-p '(:text "ft" :free t))))

(ert-deftest promptu-replace-entry-preserves-kind ()
  (promptu-test--with-session
   (setq promptu--session '("a" "b"))
   (promptu--replace-entry 1 "B2" nil)
   (should (equal promptu--session '("a" "B2")))
   (promptu--replace-entry 1 "B3" t)
   (should (equal promptu--session '("a" (:text "B3" :free t))))
   (promptu--replace-entry 0 "A2" nil)
   (should (equal promptu--session '("A2" (:text "B3" :free t))))))

(ert-deftest promptu-set-whole-entry-marks-free-text ()
  "M-E collapses to one verbatim free-text entry that round-trips."
  (promptu-test--with-session
   (let ((promptu-separator "\n- "))
     (setq promptu--session '("a" "b"))
     (promptu--set-whole-entry "- a\n- b")
     (should (equal promptu--session '((:text "- a\n- b" :free t))))
     (should (promptu--entry-free-p (car promptu--session)))
     (should (equal (promptu--compose promptu--session) "- a\n- b")))))

(ert-deftest promptu-edit-last-single-line-block-uses-minibuffer ()
  "A single-line block edits in the minibuffer and stays a plain block."
  (promptu-test--with-session
   (setq promptu--session '("a" "b"))
   (cl-letf (((symbol-function 'run-at-time)
              (lambda (&rest _) (error "should not defer a single-line block")))
             ((symbol-function 'read-string) (lambda (&rest _) "B-edited")))
     (promptu--edit-entry))
   (should (equal promptu--session '("a" "B-edited")))))

(ert-deftest promptu-edit-last-multiline-block-defers-to-buffer ()
  "A multi-line block goes to the buffer editor, not the minibuffer."
  (promptu-test--with-session
   (setq promptu--session '("a\nb"))
   (let (deferred)
     (cl-letf (((symbol-function 'read-string)
                (lambda (&rest _) (error "should not use minibuffer for multi-line")))
               ((symbol-function 'run-at-time)
                (lambda (&rest _) (setq deferred t))))
       (promptu--edit-entry))
     (should deferred))))

(ert-deftest promptu-edit-last-free-text-defers-to-buffer ()
  "A free-text region goes to the buffer editor even when single-line."
  (promptu-test--with-session
   (setq promptu--session (list (promptu--make-entry "hello" t)))
   (let (deferred)
     (cl-letf (((symbol-function 'read-string)
                (lambda (&rest _) (error "should not use minibuffer for free text")))
               ((symbol-function 'run-at-time)
                (lambda (&rest _) (setq deferred t))))
       (promptu--edit-entry))
     (should deferred))))

(ert-deftest promptu-preview-body-faces-leading-prefix ()
  "The leading line prefix is faced like the separators, not left bare."
  (let ((promptu-separator "\n- ")
        (promptu--session '("a" "b")))
    (let ((body (promptu--preview-body)))
      ;; first char is the leading "-"; it must carry the preview face
      (should (eq (get-text-property 0 'face body) 'promptu-preview-face)))))

(ert-deftest promptu-preview-body-faces-free-text-region ()
  "A free-text entry is faced with `promptu-free-text-face'."
  (let* ((promptu-separator "\n- ")
         (promptu--session (list (promptu--make-entry "blob" t)))
         (body (promptu--preview-body)))
    ;; no prefix is added before free text; it starts the preview
    (should (equal (substring-no-properties body) "blob"))
    (should (eq (get-text-property 0 'face body) 'promptu-free-text-face))))

(ert-deftest promptu-single-free-text-p ()
  (let ((promptu--session nil))
    (should-not (promptu--single-free-text-p)))
  (let ((promptu--session '("a")))
    (should-not (promptu--single-free-text-p)))
  (let ((promptu--session (list (promptu--make-entry "x" t) "b")))
    (should-not (promptu--single-free-text-p)))
  (let ((promptu--session (list (promptu--make-entry "x" t))))
    (should (promptu--single-free-text-p))))

(ert-deftest promptu-control-descriptions-reflect-state ()
  "DEL/M-e labels follow the point and the single-free-text state."
  (let ((promptu--session '("a" "b")) (promptu--point nil))
    (should (equal (promptu--remove-description) "remove last"))
    (should (equal (promptu--edit-description) "edit last")))
  (let ((promptu--session '("a" "b")) (promptu--point 1))
    (should (equal (promptu--remove-description) "remove at point"))
    (should (equal (promptu--edit-description) "edit at point")))
  (let ((promptu--session (list (promptu--make-entry "blob" t)))
        (promptu--point nil))
    (should (equal (promptu--remove-description) "remove all (free text)"))
    (should (equal (promptu--edit-description) "edit all (free text)"))))

(ert-deftest promptu-do-edit-last-exits-only-for-buffer-edit ()
  "The M-e pre-command stays transient for a minibuffer edit and exits for a
buffer edit, so the menu tears down before the edit buffer appears.  The real
`transient--do-*' functions touch prefix state that only exists inside a live
transient, so stub them to sentinels and check which one is chosen."
  (promptu-test--with-session
   (cl-letf (((symbol-function 'transient--do-call) (lambda () 'stay))
             ((symbol-function 'transient--do-exit) (lambda () 'exit)))
     ;; empty session: stay (nothing to edit, no crash on the nil entry)
     (should (eq (promptu--do-edit-entry) 'stay))
     ;; single-line block: stay (edits in the minibuffer)
     (setq promptu--session '("a" "b"))
     (should (eq (promptu--do-edit-entry) 'stay))
     ;; multi-line block: exit (goes to the buffer editor)
     (setq promptu--session '("a\nb"))
     (should (eq (promptu--do-edit-entry) 'exit))
     ;; free-text region: exit
     (setq promptu--session (list (promptu--make-entry "x" t)))
     (should (eq (promptu--do-edit-entry) 'exit))
     ;; the point retargets the check: multi-line above the point, plain last
     (setq promptu--session '("a\nb" "c") promptu--point 1)
     (should (eq (promptu--do-edit-entry) 'exit))
     (setq promptu--point nil)
     (should (eq (promptu--do-edit-entry) 'stay)))))

(ert-deftest promptu-history-round-trips-free-text-entry ()
  "A free-text region keeps its provenance when persisted and reloaded."
  (let* ((file (make-temp-file "promptu-history-"))
         (promptu-history-file file)
         (promptu-history-max 50))
    (unwind-protect
        (progn
          (let ((promptu-history (list (list "a" (list :text "b\nc" :free t)))))
            (promptu--history-save))
          (let ((promptu-history nil)
                (promptu--history-loaded nil))
            (promptu--history-ensure-loaded)
            (should (equal promptu-history
                           (list (list "a" (list :text "b\nc" :free t)))))
            (should (promptu--entry-free-p (nth 1 (car promptu-history))))))
      (delete-file file))))

;;; Stripping surrounding newlines from typed input

(ert-deftest promptu-strip-surrounding-newlines ()
  "Only leading/trailing newlines go; spaces, tabs, and inner newlines stay."
  (should (equal (promptu--strip-surrounding-newlines "\n\nhi\n\n") "hi"))
  (should (equal (promptu--strip-surrounding-newlines "\n  hi  \n") "  hi  "))
  (should (equal (promptu--strip-surrounding-newlines "\thi\t") "\thi\t"))
  (should (equal (promptu--strip-surrounding-newlines "\na\n\nb\n") "a\n\nb"))
  (should (equal (promptu--strip-surrounding-newlines "\r\nhi\r\n") "hi"))
  (should (equal (promptu--strip-surrounding-newlines "hi") "hi"))
  (should (equal (promptu--strip-surrounding-newlines "") "")))

(ert-deftest promptu-add-strips-surrounding-newlines-from-placeholder ()
  "A placeholder value's surrounding newlines are stripped; spaces are kept."
  (promptu-test--with-session
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "\n error text \n")))
     (promptu--add '(:text "note: {msg}" :placeholders ("msg"))))
   (should (equal promptu--session '("note:  error text ")))))

(ert-deftest promptu-edit-last-strips-surrounding-newlines ()
  "The minibuffer edit path strips surrounding newlines from the result."
  (promptu-test--with-session
   (setq promptu--session '("a"))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "\nedited\n")))
     (promptu--edit-entry))
   (should (equal promptu--session '("edited")))))

(ert-deftest promptu-edit-last-blank-is-noop ()
  "Editing an entry to blank leaves the session and undo untouched."
  (promptu-test--with-session
   (setq promptu--session '("a" "b"))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "   \n")))
     (promptu--edit-entry))
   (should (equal promptu--session '("a" "b")))
   (should (null promptu--undo-stack))))

;;; Grayed-out (inapt) controls

(ert-deftest promptu-history-prev-inapt-p ()
  "M-p is inapt when history is empty or navigation is at the oldest entry."
  (let ((promptu-history nil) (promptu--history-index nil))
    (should (promptu--history-prev-inapt-p)))            ; empty history
  (let ((promptu-history '(("a") ("b") ("c"))) (promptu--history-index nil))
    (should-not (promptu--history-prev-inapt-p)))         ; not navigating yet
  (let ((promptu-history '(("a") ("b") ("c"))) (promptu--history-index 0))
    (should-not (promptu--history-prev-inapt-p)))         ; room to step older
  (let ((promptu-history '(("a") ("b") ("c"))) (promptu--history-index 2))
    (should (promptu--history-prev-inapt-p))))            ; already at the oldest

;;; Point

(ert-deftest promptu-point-set-normalizes ()
  "End (or past it) stores nil; negative clamps to the start."
  (let ((promptu--session '("a" "b")) (promptu--point nil))
    (promptu--point-set 1)
    (should (equal promptu--point 1))
    (promptu--point-set 2)
    (should (null promptu--point))
    (promptu--point-set -1)
    (should (equal promptu--point 0))))

(ert-deftest promptu-target-entry ()
  "Target is the entry above the point; nil at the start or when empty."
  (let ((promptu--session '("a" "b")) (promptu--point nil))
    (should (equal (promptu--target-entry) "b"))
    (setq promptu--point 1)
    (should (equal (promptu--target-entry) "a"))
    (setq promptu--point 0)
    (should (null (promptu--target-entry))))
  (let ((promptu--session nil) (promptu--point nil))
    (should (null (promptu--target-entry)))))

(ert-deftest promptu-point-up-down-walks-and-clamps ()
  (promptu-test--with-session
   (setq promptu--session '("a" "b"))
   (promptu--point-up)
   (should (equal promptu--point 1))
   (promptu--point-up)
   (should (equal promptu--point 0))
   (promptu--point-up)                   ; clamp at the start
   (should (equal promptu--point 0))
   (promptu--point-down)
   (should (equal promptu--point 1))
   (promptu--point-down)                 ; back to the end
   (should (null promptu--point))))

(ert-deftest promptu-point-navigation-does-not-checkpoint ()
  (promptu-test--with-session
   (setq promptu--session '("a" "b"))
   (promptu--point-up)
   (promptu--point-down)
   (should (null promptu--undo-stack))))

(ert-deftest promptu-point-up-inapt-p ()
  (let ((promptu--session nil) (promptu--point nil))
    (should (promptu--point-up-inapt-p)))
  (let ((promptu--session '("a")) (promptu--point nil))
    (should-not (promptu--point-up-inapt-p)))
  (let ((promptu--session '("a")) (promptu--point 0))
    (should (promptu--point-up-inapt-p))))

(ert-deftest promptu-add-inserts-at-point ()
  (promptu-test--with-session
   (setq promptu--session '("a" "c") promptu--point 1)
   (promptu--add '(:text "b"))
   (should (equal promptu--session '("a" "b" "c")))
   (should (equal promptu--point 2))))

(ert-deftest promptu-add-at-start ()
  (promptu-test--with-session
   (setq promptu--session '("b") promptu--point 0)
   (promptu--add '(:text "a"))
   (should (equal promptu--session '("a" "b")))
   (should (equal promptu--point 1))))

(ert-deftest promptu-remove-above-point ()
  (promptu-test--with-session
   (setq promptu--session '("a" "b" "c") promptu--point 2)
   (promptu--remove-entry)
   (should (equal promptu--session '("a" "c")))
   (should (equal promptu--point 1))))

(ert-deftest promptu-remove-at-start-noop ()
  "Nothing above the point: session, point, and undo all untouched."
  (promptu-test--with-session
   (setq promptu--session '("a") promptu--point 0)
   (promptu--remove-entry)
   (should (equal promptu--session '("a")))
   (should (equal promptu--point 0))
   (should (null promptu--undo-stack))))

(ert-deftest promptu-edit-above-point-minibuffer ()
  (promptu-test--with-session
   (setq promptu--session '("a" "b" "c") promptu--point 2)
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "B2")))
     (promptu--edit-entry))
   (should (equal promptu--session '("a" "B2" "c")))
   (should (equal promptu--point 2))))

(ert-deftest promptu-edit-above-point-buffer-captures-index ()
  "The deferred buffer edit replaces the entry captured at command time."
  (promptu-test--with-session
   (setq promptu--session '("x\ny" "z") promptu--point 1)
   (let (thunk)
     (cl-letf (((symbol-function 'run-at-time)
                (lambda (_time _repeat fn) (setq thunk fn)))
               ((symbol-function 'promptu--edit-open)
                (lambda (_text apply-fn _header) (funcall apply-fn "edited"))))
       (promptu--edit-entry)
       (funcall thunk)))
   (should (equal promptu--session '("edited" "z")))))

(ert-deftest promptu-undo-restores-point ()
  "Undo returns the point to where it stood before the change."
  (promptu-test--with-session
   (setq promptu--session '("a" "b") promptu--point 1)
   (promptu--add '(:text "x"))
   (should (equal promptu--session '("a" "x" "b")))
   (should (equal promptu--point 2))
   (promptu--undo)
   (should (equal promptu--session '("a" "b")))
   (should (equal promptu--point 1))
   (promptu--redo)
   (should (equal promptu--session '("a" "x" "b")))
   (should (equal promptu--point 2))))

(ert-deftest promptu-point-resets-on-history-and-whole-edit ()
  (promptu-test--with-history
   (setq promptu-history '(("old"))
         promptu--session '("a" "b")
         promptu--point 1)
   (promptu--history-prev)
   (should (null promptu--point))
   (setq promptu--session '("a" "b") promptu--point 1)
   (promptu--set-whole-entry "all")
   (should (null promptu--point))))

(ert-deftest promptu-preview-marker-at-point ()
  "Marker sits at the gap: own line for multi-line separators, else inline."
  (let ((promptu-separator "\n- ")
        (promptu--session '("a" "b")))
    (let ((promptu--point 1))
      (should (equal (substring-no-properties (promptu--preview-body))
                     "- a\n▮\n- b")))
    (let ((promptu--point 0))
      (should (equal (substring-no-properties (promptu--preview-body))
                     "▮\n- a\n- b")))
    (let ((promptu--point nil))
      (should-not (string-search "▮" (promptu--preview-body)))))
  (let ((promptu-separator ", ")
        (promptu--session '("a" "b"))
        (promptu--point 1))
    (should (equal (substring-no-properties (promptu--preview-body))
                   "a▮, b"))))

(ert-deftest promptu-preview-marker-face ()
  (let* ((promptu-separator "\n- ")
         (promptu--session '("a"))
         (promptu--point 0)
         (body (promptu--preview-body)))
    (should (eq (get-text-property 0 'face body) 'promptu-point-face))))

;;; Undo / redo

(ert-deftest promptu-undo-redo-adds ()
  "Undo steps back through adds; redo replays them."
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))
   (should (equal promptu--session '("a" "b")))
   (promptu--undo)
   (should (equal promptu--session '("a")))
   (promptu--undo)
   (should (null promptu--session))
   (promptu--redo)
   (should (equal promptu--session '("a")))
   (promptu--redo)
   (should (equal promptu--session '("a" "b")))))

(ert-deftest promptu-undo-empty-reports ()
  "Undo/redo with nothing to do leaves the session untouched."
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--undo)                       ; back to empty
   (promptu--undo)                       ; nothing to undo
   (should (null promptu--session))
   (promptu--redo)                       ; back to ("a")
   (promptu--redo)                       ; nothing to redo
   (should (equal promptu--session '("a")))))

(ert-deftest promptu-new-change-clears-redo ()
  "A fresh change after an undo discards the redo history."
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))
   (promptu--undo)                       ; ("a"), redo has ("a" "b")
   (promptu--add '(:text "c"))           ; new change clears redo
   (should (equal promptu--session '("a" "c")))
   (should (null promptu--redo-stack))
   (promptu--redo)                       ; nothing to redo
   (should (equal promptu--session '("a" "c")))))

(ert-deftest promptu-undo-covers-remove-edit-and-whole ()
  "Remove-last, edit-last, and M-E collapse are all undoable."
  (promptu-test--with-session
   (let ((promptu-separator "\n- "))
     (promptu--add '(:text "a"))
     (promptu--add '(:text "b"))
     (promptu--remove-entry)               ; ("a")
     (promptu--undo)
     (should (equal promptu--session '("a" "b")))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "B2")))
       (promptu--edit-entry))              ; ("a" "B2")
     (should (equal promptu--session '("a" "B2")))
     (promptu--undo)
     (should (equal promptu--session '("a" "b")))
     (promptu--set-whole-entry "- a\n- b") ; one free-text entry
     (should (promptu--single-free-text-p))
     (promptu--undo)
     (should (equal promptu--session '("a" "b"))))))

(ert-deftest promptu-undo-leaves-history-navigation ()
  "Undo resets history navigation state."
  (promptu-test--with-session
   (setq promptu--history-index 2
         promptu--history-stash '("draft"))
   (promptu--add '(:text "a"))
   (promptu--undo)
   (should (null promptu--history-index))
   (should (null promptu--history-stash))))

(ert-deftest promptu-reset-clears-undo-stacks ()
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--undo)
   (should promptu--redo-stack)
   (promptu--reset)
   (should (null promptu--undo-stack))
   (should (null promptu--redo-stack))))

(ert-deftest promptu-history-prev-clears-undo ()
  "Recalling from history starts a fresh undo slate, so undo cannot reach
back into a different prompt's edits and switch to it."
  (promptu-test--with-history
   (setq promptu-history '(("old")))
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))          ; undo stack now holds draft snapshots
   (promptu--history-prev)              ; jump to ("old")
   (should (equal promptu--session '("old")))
   (should (null promptu--undo-stack))
   (should (null promptu--redo-stack))
   ;; undo here is a no-op: it neither switches prompts nor errors
   (promptu--undo)
   (should (equal promptu--session '("old")))))

(ert-deftest promptu-history-pick-clears-undo ()
  "Loading a prompt with M-r also clears undo; it is not itself undoable."
  (promptu-test--with-history
   (setq promptu-history '(("a" "b") ("c"))
         promptu--session '("draft"))
   (promptu--add '(:text "x"))          ; build some undo history on the draft
   (cl-letf (((symbol-function 'completing-read)
              (lambda (&rest _) (promptu--compose '("a" "b")))))
     (promptu--history-pick))
   (should (equal promptu--session '("a" "b")))
   (should (null promptu--undo-stack))
   (promptu--undo)                      ; nothing to undo; stays on loaded prompt
   (should (equal promptu--session '("a" "b")))))

(ert-deftest promptu-undo-works-after-recall ()
  "After recalling, edits to the recalled prompt are undoable within it."
  (promptu-test--with-history
   (setq promptu-history '(("old")))
   (promptu--add '(:text "a"))
   (promptu--history-prev)              ; session ("old"), undo cleared
   (promptu--add '(:text "extra"))      ; edit the recalled prompt
   (should (equal promptu--session '("old" "extra")))
   (promptu--undo)                      ; reverts within the recalled prompt
   (should (equal promptu--session '("old")))
   (should (null promptu--history-index))))

;;; promptu-blocks-from-json

(ert-deftest promptu-blocks-from-json-maps-fields ()
  "JSON objects map 1:1 onto block plists, omitting absent keys."
  (let ((file (make-temp-file
               "promptu-blocks" nil ".json"
               (concat "[{\"key\": \"P\", \"desc\": \"push\","
                       "  \"text\": \"push when done\","
                       "  \"negative\": \"don't push\"},"
                       " {\"key\": \"i\", \"desc\": \"investigate\","
                       "  \"text\": \"investigate {link}\","
                       "  \"placeholders\": [\"link\"]}]"))))
    (unwind-protect
        (let* ((blocks (promptu-blocks-from-json file))
               (push-block (nth 0 blocks))
               (inv-block (nth 1 blocks)))
          (should (= (length blocks) 2))
          (should (equal (plist-get push-block :key) "P"))
          (should (equal (plist-get push-block :desc) "push"))
          (should (equal (plist-get push-block :text) "push when done"))
          (should (equal (plist-get push-block :negative) "don't push"))
          (should-not (plist-member push-block :placeholders))
          (should (equal (plist-get inv-block :placeholders) '("link")))
          (should-not (plist-member inv-block :negative)))
      (delete-file file))))

(ert-deftest promptu-blocks-from-json-blocks-resolve ()
  "Blocks loaded from JSON work with the compose core."
  (let ((file (make-temp-file
               "promptu-blocks" nil ".json"
               (concat "[{\"key\": \"P\", \"desc\": \"push\","
                       "  \"text\": \"push when done\","
                       "  \"negative\": \"don't push\"}]"))))
    (unwind-protect
        (let ((block (car (promptu-blocks-from-json file))))
          (should (equal (promptu--resolve block nil) "push when done"))
          (should (equal (promptu--resolve block t) "don't push")))
      (delete-file file))))

(provide 'promptu-test)

;;; promptu-test.el ends here
