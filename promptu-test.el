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
  (should (promptu--reserved-key-p "q"))
  (should-not (promptu--reserved-key-p "p"))
  (should-not (promptu--reserved-key-p "i")))

(provide 'promptu-test)

;;; promptu-test.el ends here
