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
         (promptu--negate-next nil)
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
   (promptu--remove-last)
   (should (equal promptu--session '("a")))))

(ert-deftest promptu-remove-last-empty-noop ()
  (promptu-test--with-session
   (promptu--remove-last)
   (should (null promptu--session))))

(ert-deftest promptu-edit-last-replaces-last-entry ()
  (promptu-test--with-session
   (promptu--add '(:text "a"))
   (promptu--add '(:text "b"))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "B-edited")))
     (promptu--edit-last))
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
       (promptu--edit-last))
     (should (equal seen-initial "original")))))

(ert-deftest promptu-edit-last-empty-noop ()
  (promptu-test--with-session
   (cl-letf (((symbol-function 'read-string)
              (lambda (&rest _) (error "should not prompt on empty session"))))
     (promptu--edit-last))
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
   (setq promptu--negate-next t)
   (promptu--reset)
   (should (null promptu--session))
   (should (null promptu--negate-next))))

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

(ert-deftest promptu-reserved-key-p ()
  (should (promptu--reserved-key-p "-"))
  (should (promptu--reserved-key-p "RET"))
  (should (promptu--reserved-key-p "DEL"))
  (should (promptu--reserved-key-p "M-e"))
  (should (promptu--reserved-key-p "M-E"))
  (should (promptu--reserved-key-p "M-p"))
  (should (promptu--reserved-key-p "M-n"))
  (should (promptu--reserved-key-p "M-r"))
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
         (promptu--session nil)
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
   (promptu--remove-last)
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

(ert-deftest promptu-strip-line-prefix-removes-bullet ()
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--strip-line-prefix "- a\n- b") "a\n- b"))))

(ert-deftest promptu-strip-line-prefix-absent-noop ()
  "Text that does not start with the line prefix is returned unchanged."
  (let ((promptu-separator "\n- "))
    (should (equal (promptu--strip-line-prefix "a\n- b") "a\n- b"))))

(ert-deftest promptu-strip-line-prefix-inline-separator-noop ()
  "A separator with no line prefix strips nothing."
  (let ((promptu-separator ", "))
    (should (equal (promptu--strip-line-prefix "a, b, c") "a, b, c"))))

(ert-deftest promptu-edit-round-trips-composed-prompt ()
  "Stripping the prefix and recomposing as one entry returns the original."
  (let* ((promptu-separator "\n- ")
         (session '("review your changes" "commit" "don't push"))
         (composed (promptu--compose session))
         (entry (promptu--strip-line-prefix composed)))
    (should (equal (promptu--compose (list entry)) composed))))

(ert-deftest promptu-edit-collapses-multiline-into-one-entry ()
  "A multi-line edit becomes a single entry, preserving inner newlines."
  (let* ((promptu-separator "\n- ")
         (text "- review\n- here is an error:\nTraceback\nValueError: x")
         (entry (promptu--strip-line-prefix text)))
    (should (equal entry "review\n- here is an error:\nTraceback\nValueError: x"))
    (should (equal (promptu--compose (list entry)) text))))

(provide 'promptu-test)

;;; promptu-test.el ends here
