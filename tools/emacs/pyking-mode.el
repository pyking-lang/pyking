;;; pyking-mode.el --- Major mode for editing Pyking (.pyk) source -*- lexical-binding: t; -*-

;; This file is part of the Pyking project.

;;; Commentary:

;; A syntax-highlighting major mode for Pyking, the small Python-like
;; language defined by this repository. The keyword list and grammar
;; used below are taken directly from `boot/lexer.py' / `boot/parser.py'
;; and documented in `PYKING.md' at the repository root; keep the two in
;; sync if the grammar changes.
;;
;; Pyking requires strict 4-space indentation (see "Indentation-based
;; blocks" in PYKING.md), so `indent-tabs-mode' is disabled and
;; `tab-width'/`pyking-indent-offset' set to 4, matching `python-mode's
;; own defaults. `pyking-indent-line' provides TAB-to-indent support: a
;; line is indented one `pyking-indent-offset' deeper than the previous
;; non-blank line when that line ends in `:' (opening a new `block', see
;; PYKING.md's grammar); a line starting with `else' or `case' instead
;; scans backward for the construct it dedents out of -- `else' aligns
;; with its `if' (which covers `else if' ladders too: such a line starts
;; with `else' like any other, and ends in `:', so its body indents from
;; it the same way), `case' aligns with the previous sibling `case_clause'
;; or, failing that, one level deeper than its `match' -- since a
;; `case pattern -> expr' clause (see PYKING.md) has no indented body,
;; so consecutive `case's aren't reliably one level below the previous
;; line the way an `if'/`else' body always is. Any other line just
;; matches the previous line's indentation, leaving further dedents to
;; the user -- the same fallback `python-mode' uses.
;;
;; Usage: put this file on your `load-path' and add
;;
;;   (require 'pyking-mode)
;;
;; to your init file (or `M-x load-file' it directly). Files ending in
;; `.pyk' are then associated with `pyking-mode' automatically.

;;; Code:

(defgroup pyking nil
  "Major mode for editing Pyking (.pyk) source."
  :group 'languages)

(defcustom pyking-indent-offset 4
  "Number of columns per indentation level in Pyking source.
Pyking's grammar requires exactly 4-space indentation steps (see
\"Indentation-based blocks\" in PYKING.md), so this should not normally
be changed, but is exposed as a customizable option the same way
`python-indent-offset' is."
  :type 'integer
  :group 'pyking)

(defconst pyking-mode-keywords
  '("for" "in" "if" "while" "then" "else" "var" "def" "return" "match" "case")
  "Reserved keywords in Pyking.
Mirrors the `keywords' list in boot/lexer.py. Unlike Python, `match' and
`case' are always reserved here, not context-sensitive (\"soft\")
keywords; `then' -- Pyking's `if cond then a else b' expression keyword --
has no Python counterpart at all.")

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
   ;; rest_marker = ".." , [ ident ] -- the list-pattern "rest" marker
   ;; (`..`/`..name`), Pyking's spelling of Python's `*_'/`*name' star
   ;; sub-pattern. Matched before any single-`.' rule could apply (there
   ;; isn't one currently, but this keeps the ordering future-proof).
   '("\\.\\." . font-lock-keyword-face)
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

(defun pyking--blank-or-comment-line-p ()
  "Return non-nil if the current line has no code, only whitespace/comment."
  (save-excursion
    (beginning-of-line)
    (looking-at "[ \t]*\\(#.*\\)?$")))

(defun pyking--code-end-position ()
  "Return the buffer position where code on the current line ends.
This is the line's end position, or the position of a trailing `#'
comment, whichever comes first -- a `#' inside a string literal is
skipped over via `syntax-ppss' so it isn't mistaken for one."
  (save-excursion
    (let ((eol (line-end-position)))
      (beginning-of-line)
      (or (catch 'found
            (while (re-search-forward "#" eol t)
              (unless (nth 3 (syntax-ppss (match-beginning 0)))
                (throw 'found (match-beginning 0)))))
          eol))))

(defun pyking--line-ends-with-colon-p ()
  "Return non-nil if the current line's code (sans trailing comment) ends in `:'."
  (save-excursion
    (goto-char (pyking--code-end-position))
    (skip-chars-backward " \t")
    (eq (char-before) ?:)))

(defun pyking--line-first-word-matches-p (regexp)
  "Return non-nil if the current line's first word matches REGEXP."
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward " \t")
    (looking-at regexp)))

(defun pyking--backward-dedent-target (self-regexp opener-regexp opener-offset)
  "Scan backward from point for the line a dedent keyword should align with.
Walks upward tracking the shallowest indentation seen so far (starting
unbounded); the first line at or below that depth is the answer,
because anything deeper is nested inside a block the scan has already
passed. If that line's first word matches SELF-REGEXP (a sibling at
the same depth, e.g. a previous `case_clause'), its own indentation is
the answer. If it matches OPENER-REGEXP instead (the construct being
dedented out of, e.g. `if' for `else'), its indentation plus
OPENER-OFFSET is the answer. Falls back to 0 if neither is ever found
\(only possible for malformed/partial input, e.g. mid-edit)."
  (save-excursion
    (let (min-indent)
      (catch 'done
        (while (not (bobp))
          (forward-line -1)
          (unless (pyking--blank-or-comment-line-p)
            (let ((ind (current-indentation)))
              (when (or (null min-indent) (<= ind min-indent))
                (cond
                 ((pyking--line-first-word-matches-p self-regexp)
                  (throw 'done ind))
                 ((pyking--line-first-word-matches-p opener-regexp)
                  (throw 'done (+ ind opener-offset)))
                 (t (setq min-indent ind)))))))
        0))))

(defun pyking--else-target-indent ()
  "Indentation for an `else' line: aligned with its `if_stmt's own `if'.
An `else if' chain (see PYKING.md -- Pyking spells Python's `elif' with
those two keywords) does put sibling `else' lines at the same depth, so
unlike the single-`else' case the scan may resolve via SELF-REGEXP
instead; either way the answer is the same column, since every line of
one chain aligns with the `if' that opens it."
  (pyking--backward-dedent-target "\\_<else\\_>" "\\_<if\\_>" 0))

(defun pyking--case-target-indent ()
  "Indentation for a `case' line: aligned with the previous sibling
`case_clause' if there is one at the same depth, otherwise one
`pyking-indent-offset' deeper than the `match' header that opens the
`match_stmt' -- needed because a `case pattern -> expr' clause (see
PYKING.md) has no indented body of its own, so the next `case' isn't
necessarily one level below the previous line the way `else' always is."
  (pyking--backward-dedent-target "\\_<case\\_>" "\\_<match\\_>" pyking-indent-offset))

(defun pyking--dedenter-line-p ()
  "Return non-nil if the current line is known to end its own block.
A `return_stmt' always ends the statement sequence it's part of in
every one of this repository's tests/*.pyk files (Pyking has no
`pass'/`break'/`continue' to also check, unlike Python); a `case
pattern -> expr' clause (see PYKING.md) is self-contained the same
way, since it has no indented body at all. Mirrors `python-mode's own
`python-indent-dedenters': after either one, the following line dedents
one `pyking-indent-offset', matching `python-indent-line's real
behavior (confirmed by testing it directly) of dedenting exactly one
level after `return' -- not fully re-deriving arbitrarily many closed
block levels, which no context-free indent heuristic can do reliably;
the user dedents further manually same as in `python-mode'."
  (or (pyking--line-first-word-matches-p "\\_<return\\_>")
      (and (pyking--line-first-word-matches-p "\\_<case\\_>")
           (not (pyking--line-ends-with-colon-p)))))

(defun pyking-calculate-indent ()
  "Compute the indentation column for the current line.
Mirrors `python-mode's own simple case: a `block' is one
`pyking-indent-offset' deeper than the `:'-terminated line that opens
it (see `block'/`if_stmt'/`match_stmt' et al. in PYKING.md's grammar),
`else'/`case' dedent back out of the block(s) they close (see
`pyking--else-target-indent'/`pyking--case-target-indent'), a line
following a `pyking--dedenter-line-p' line dedents one level, and any
other line matches the previous non-blank line's indentation --
leaving the user to dedent further manually, the same as `python-mode'
does for a plain statement following a multi-level nested block."
  (save-excursion
    (beginning-of-line)
    (cond
     ((bobp) 0)
     ((pyking--line-first-word-matches-p "\\_<else\\_>") (pyking--else-target-indent))
     ((pyking--line-first-word-matches-p "\\_<case\\_>") (pyking--case-target-indent))
     (t (let (prev-indent prev-ends-with-colon prev-is-dedenter)
          (save-excursion
            (forward-line -1)
            (while (and (not (bobp)) (pyking--blank-or-comment-line-p))
              (forward-line -1))
            (setq prev-indent (current-indentation))
            (setq prev-ends-with-colon (pyking--line-ends-with-colon-p))
            (setq prev-is-dedenter (pyking--dedenter-line-p)))
          (cond
           (prev-ends-with-colon (+ prev-indent pyking-indent-offset))
           (prev-is-dedenter (max 0 (- prev-indent pyking-indent-offset)))
           (t prev-indent)))))))

(defun pyking-indent-line ()
  "Indent the current line as Pyking source.
Leaves point at the new indentation when point started within the
line's leading whitespace, otherwise keeps it fixed relative to the
end of the buffer -- the standard `indent-line-function' convention
(also followed by `python-indent-line')."
  (interactive)
  (let ((savep (- (point-max) (point)))
        (target (max (pyking-calculate-indent) 0)))
    (if (<= (current-column) (current-indentation))
        (indent-line-to target)
      (save-excursion (indent-line-to target)))
    (when (> (- (point-max) savep) (point))
      (goto-char (- (point-max) savep)))))

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
`while', `then', `else', `var', `def', `return', `match', `case'), the `:='
mutation operator, the `..'/`..name' list-pattern rest marker, string
literals (with backslash escapes), `#' comments, integer literals, type
annotation names (`Int', `String', `Bool', see `pyking-mode-types'), and
well-known builtins (see `pyking-mode-builtins'), consistent with the
grammar documented in PYKING.md and implemented in boot/lexer.py and
boot/parser.py.

Also provides `python-mode'-style 4-space (`pyking-indent-offset')
indentation via `pyking-indent-line'."
  :syntax-table pyking-mode-syntax-table
  (setq-local font-lock-defaults '(pyking-mode-font-lock-keywords nil nil))
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width pyking-indent-offset)
  (setq-local indent-line-function #'pyking-indent-line)
  ;; Pyking indentation, like Python's, is not redundant -- the same
  ;; code can be validly indented at more than one level (see
  ;; `pyking-calculate-indent's fallback case), so `pyking-indent-line'
  ;; can only guess. `electric-indent-mode' normally reindents the
  ;; *previous* (already-typed) line whenever RET is pressed, on top of
  ;; auto-indenting the new one; for a guess-only indenter that means
  ;; RET can silently overwrite a line's deliberate indentation with a
  ;; wrong guess. Setting `electric-indent-inhibit' opts out of just
  ;; that previous-line reindent (the new line is still auto-indented)
  ;; -- `python-mode' sets this same variable for the same reason, per
  ;; its own comment: "Because indentation is not redundant, we cannot
  ;; safely reindent code."
  (setq-local electric-indent-inhibit t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.pyk\\'" . pyking-mode))

(provide 'pyking-mode)

;;; pyking-mode.el ends here
