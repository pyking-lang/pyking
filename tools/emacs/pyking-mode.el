;;; pyking-mode.el --- Major mode for editing Pyking (.pyk) source -*- lexical-binding: t; -*-

;; This file is part of the Pyking project.

;;; Commentary:

;; A syntax-highlighting major mode for Pyking, the small Python-like
;; language defined by this repository. The keyword list and grammar
;; used below are taken directly from `boot/lexer.py' / `boot/parser.py'
;; and documented in `PYKING.md' at the repository root; keep the two in
;; sync if the grammar changes.
;;
;; This mode provides syntax highlighting only -- no indentation support.
;; Pyking requires strict 4-space indentation (see "Indentation-based
;; blocks" in PYKING.md), so `indent-tabs-mode' is disabled and
;; `tab-width' set to 4, but no `indent-line-function' is defined.
;;
;; Usage: put this file on your `load-path' and add
;;
;;   (require 'pyking-mode)
;;
;; to your init file (or `M-x load-file' it directly). Files ending in
;; `.pyk' are then associated with `pyking-mode' automatically.

;;; Code:

(defconst pyking-mode-keywords
  '("for" "in" "if" "while" "else" "var" "def" "return" "match" "case")
  "Reserved keywords in Pyking.
Mirrors the `keywords' list in boot/lexer.py. Unlike Python, `match' and
`case' are always reserved here, not context-sensitive (\"soft\")
keywords.")

(defconst pyking-mode-keywords-regexp
  (regexp-opt pyking-mode-keywords 'symbols)
  "Regexp matching any Pyking keyword as a whole symbol.")

(defconst pyking-mode-types
  '("Int" "String" "Bool")
  "Reserved type names usable in parameter/return type annotations.
Mirrors the `keywords' list in boot/lexer.py: like `match'/`case', these
are always-reserved keywords, not identifiers the parser special-cases
only in type position -- see PYKING.md's \"Type annotations\" section.
Kept as a separate list (rather than folded into
`pyking-mode-keywords') so they get `font-lock-type-face' instead of
`font-lock-keyword-face', matching how other language modes distinguish
type names from control-flow/declaration keywords.")

(defconst pyking-mode-types-regexp
  (regexp-opt pyking-mode-types 'symbols)
  "Regexp matching any name in `pyking-mode-types' as a whole symbol.")

(defconst pyking-mode-builtins
  '("print" "range" "str")
  "Well-known Python builtin function names used in Pyking source.

Pyking's own grammar has no notion of a builtin -- any identifier can be
a call target (see `atom' in PYKING.md); this list exists purely so the
generated-Python builtins actually used across this repository's Pyking
source (tests/*.pyk and the examples in PYKING.md) get highlighted
distinctly from ordinary calls, the same way `python-mode' highlights
`print' et al. with `font-lock-builtin-face' instead of treating them as
plain symbols. Extend this list if a Pyking example starts using another
builtin (e.g. `len').")

(defconst pyking-mode-builtins-regexp
  (regexp-opt pyking-mode-builtins 'symbols)
  "Regexp matching any name in `pyking-mode-builtins' as a whole symbol.")

(defconst pyking-mode-font-lock-keywords
  (list
   ;; function_def = "def" , ident , "(" ... -- the declared function name.
   '("\\_<def\\_>[ \t]+\\(\\sw+\\)"
     1 font-lock-function-name-face)
   ;; var_decl = "var" , ident , "=" , expr -- the declared variable name.
   '("\\_<var\\_>[ \t]+\\(\\sw+\\)"
     1 font-lock-variable-name-face)
   ;; for_stmt = "for" , ident , "in" , expr , ":" , block -- loop variable.
   '("\\_<for\\_>[ \t]+\\(\\sw+\\)[ \t]+\\_<in\\_>"
     1 font-lock-variable-name-face)
   ;; mutation = ident , ":=" , expr -- Pyking's one deliberate departure
   ;; from plain Python assignment (see PYKING.md), worth calling out.
   '(":=" . font-lock-keyword-face)
   ;; int = digit , { digit } ; identifiers can't start with a digit, so
   ;; a symbol-boundary match is exactly the integer-literal case.
   '("\\_<[0-9]+\\_>" . font-lock-constant-face)
   ;; Known Python builtins (see `pyking-mode-builtins'); matched as a
   ;; plain symbol, not conditionally on being followed by "(", matching
   ;; `python-mode's own behavior.
   (cons pyking-mode-builtins-regexp 'font-lock-builtin-face)
   ;; Type annotation names (see `pyking-mode-types') -- highlighted with
   ;; the conventional type face, distinct from other keywords.
   (cons pyking-mode-types-regexp 'font-lock-type-face)
   ;; Every other reserved keyword.
   (cons pyking-mode-keywords-regexp 'font-lock-keyword-face))
  "Font-lock keyword table for `pyking-mode'.
Strings and comments are handled by the syntax table
\(`pyking-mode-syntax-table'), not listed here.")

(defvar pyking-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; ident = letter , { letter | digit } ; where `letter' includes `_'
    ;; (see `is_letter' in boot/lexer.py) -- `_' is part of the word,
    ;; not a symbol separator.
    (modify-syntax-entry ?_ "w" table)
    ;; Comments: "#" runs to end of line.
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    ;; string = "'" , { string_char } , "'" | '"' , { string_char } , '"' ;
    ;; both quote characters delimit strings, and "\\" is the escape
    ;; character for both (see `scan_string'/`_ESCAPES' in boot/lexer.py).
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\' "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    ;; call_tail = "(" , [ args ] , ")" ; list_lit = "[" , [ args ] , "]" ;
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    ;; Punctuation and operators with no special pairing.
    (modify-syntax-entry ?, "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?* "." table)
    (modify-syntax-entry ?/ "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?= "." table)
    table)
  "Syntax table for `pyking-mode'.")

;;;###autoload
(define-derived-mode pyking-mode prog-mode "Pyking"
  "Major mode for editing Pyking (.pyk) source files.

Provides syntax highlighting for Pyking's keywords (`for', `in', `if',
`while', `else', `var', `def', `return', `match', `case'), the `:='
mutation operator, string literals (with backslash escapes), `#'
comments, integer literals, type annotation names (`Int', `String',
`Bool', see `pyking-mode-types'), and well-known builtins (see
`pyking-mode-builtins'), consistent with the grammar documented in
PYKING.md and implemented in boot/lexer.py and boot/parser.py.

This mode does not implement indentation support."
  :syntax-table pyking-mode-syntax-table
  (setq-local font-lock-defaults '(pyking-mode-font-lock-keywords nil nil))
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 4))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.pyk\\'" . pyking-mode))

(provide 'pyking-mode)

;;; pyking-mode.el ends here
