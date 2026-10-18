;;; pyking-mode.el --- Major mode for editing Pyking (.pyk) source -*- lexical-binding: t; -*-

;; This file is part of the Pyking project.

;;; Commentary:

;; A syntax-highlighting major mode for Pyking, the small Python-like
;; language defined by this repository. The keyword list and grammar
;; used below are taken directly from `src/lexer.ml' / `src/parser.ml'
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
;; or, failing that, one level deeper than its `match' -- since a clause
;; carrying its block on its own line (`case 0: "zero"', see PYKING.md)
;; has no indented body, so consecutive `case's aren't reliably one level
;; below the previous line the way an `if'/`else' body always is. Any other line just
;; matches the previous line's indentation -- the same fallback
;; `python-mode' uses. Since that guess is always wrong on the line
;; after a block ends, pressing TAB again cycles through the shallower
;; enclosing columns (`pyking--indent-levels'), also as in `python-mode'.
;;
;; One case is not a guess at all: the line directly after something that
;; opens a block and leaves it empty -- a line *ending* in `:', or a
;; binding whose value is missing from the line (`x =', with the value on
;; the next line; see PYKING.md). A header that carries its block on its
;; own line (`def f(x): x * x') opens nothing for the next line, and is
;; not one of these. A block is never empty and Pyking indents in exact
;; 4-space steps, so exactly one column can parse there. That column is
;; forced: TAB puts the line at it and repeated TAB will not cycle it
;; away. `indent-region' (`pyking-indent-region') likewise fixes such a
;; line, while leaving alone any line already sitting at a column the
;; guess-plus-cycle set allows -- so it repairs continuation lines
;; without marching a correctly indented buffer rightward.
;;
;; The header those backward scans look for may itself be a binding, as
;; in the value form `x = if cond:' / `x = match e:' (see PYKING.md), so
;; they match `pyking--if-block-opener-regexp'/
;; `pyking--match-block-opener-regexp' rather than just a first word.
;; Being a heuristic, the scan does have a known blind spot, unrelated to
;; that form: it takes the first line at or above its own depth, so an
;; `else' that closes a block whose *own* last statement was an
;; `if'/`else' finds that inner `else' and aligns with it, one level too
;; deep. Correctly resolving it needs real block structure, not a
;; backward scan; as everywhere else here, TAB guesses and the user
;; adjusts.
;;
;; RET is bound (in `pyking-mode-map') to `newline-and-indent', so the
;; new line is indented by this mode itself rather than by whatever
;; `electric-indent-mode' happens to be doing in the user's
;; configuration; typing `:' on an `else'/`case' line reindents it the
;; same way, through `pyking-indent-post-self-insert-function'. Between
;; them, a whole file can be typed with no leading whitespace entered by
;; hand -- except where a block *ends*, the one thing that cannot be
;; derived, which is what TAB cycling is for.
;;
;; Usage: put this file on your `load-path' and add
;;
;;   (require 'pyking-mode)
;;
;; to your init file (or `M-x load-file' it directly). Files ending in
;; `.pyk' are then associated with `pyking-mode' automatically.
;;
;; The language server, `pyk lsp', is registered with eglot (built into
;; Emacs 29) once eglot is loaded; `M-x eglot' in a Pyking buffer starts
;; it. `pyking-lsp-command' says how it is started.

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
  '("for" "in" "if" "while" "loop" "break" "continue" "then" "let" "else"
    "var" "def" "return" "match" "case" "public" "implicit" "import" "from" "as"
    "datatype")
  "Reserved keywords in Pyking.
Mirrors the `keywords' list in src/lexer.ml, minus the names broken out
into `pyking-mode-types' and `pyking-mode-constants' below (each gets its
own face, the way other language modes distinguish literals and type
names from control-flow/declaration keywords). Unlike Python, `match' and
`case' are always reserved here, not context-sensitive (\"soft\")
keywords; `then' -- Pyking's `if cond then a else b' expression keyword --
has no Python counterpart at all. The last four are the module system's
\(see \"Modules\" in PYKING.md): `public' marks what a module exports,
and `import'/`from'/`as' are how another module reaches it. `implicit'
marks a definition an implicit argument may be resolved to, and an
implicit parameter in a header or a function type (see \"Implicits\").
`datatype' declares an algebraic data type (see \"Datatypes\").")

(defconst pyking-mode-keywords-regexp
  (regexp-opt pyking-mode-keywords 'symbols)
  "Regexp matching any Pyking keyword as a whole symbol.")

(defconst pyking-mode-types
  '("Int" "Float" "String" "Bool")
  "Reserved type names usable in type annotations.
Annotations appear on a parameter, on a `def' return value, and on an
immutable binding (`x: Int = 1' -- see `assignment' in PYKING.md's
grammar), which is the form the type checker fills in and prints back.
Mirrors the `keywords' list in src/lexer.ml: like `match'/`case', these
are always-reserved keywords, not identifiers the parser special-cases
only in type position -- see PYKING.md's \"Type annotations\" section.
Kept as a separate list (rather than folded into
`pyking-mode-keywords') so they get `font-lock-type-face' instead of
`font-lock-keyword-face', matching how other language modes distinguish
type names from control-flow/declaration keywords.")

(defconst pyking-mode-types-regexp
  (regexp-opt pyking-mode-types 'symbols)
  "Regexp matching any name in `pyking-mode-types' as a whole symbol.")

(defconst pyking-mode-constants
  '("true" "false")
  "Reserved literal keywords in Pyking, for values rather than control
flow or types. Mirrors the `keywords' list in src/lexer.ml: `true' and
`false' are Pyking's own lowercase spelling of the two boolean values,
not Python's capitalised `True'/`False' (which are therefore *not* in
this list -- they are ordinary, unbound identifiers in Pyking, not
keywords). Kept as a separate list (rather than folded into
`pyking-mode-keywords') so they get `font-lock-constant-face' instead of
`font-lock-keyword-face' -- the same face an integer literal gets (see
`pyking-mode-font-lock-keywords'), since a boolean literal is exactly as
much a literal value as `123' is, not a keyword like `if' or `return'.")

(defconst pyking-mode-constants-regexp
  (regexp-opt pyking-mode-constants 'symbols)
  "Regexp matching any name in `pyking-mode-constants' as a whole symbol.")

(defconst pyking-mode-builtins
  '("print" "debug" "range" "string" "len" "float" "int" "bool")
  "Well-known Python builtin function names used in Pyking source.

Pyking's own grammar has no notion of a builtin -- any identifier can be
a call target (see `atom' in PYKING.md); this list exists purely so the
generated-Python builtins actually used across this repository's Pyking
source (tests/*.pyk and the examples in PYKING.md) get highlighted
distinctly from ordinary calls, the same way `python-mode' highlights
`print' et al. with `font-lock-builtin-face' instead of treating them as
plain symbols. Extend this list if a Pyking example starts using another
builtin.")

(defconst pyking-mode-builtins-regexp
  (regexp-opt pyking-mode-builtins 'symbols)
  "Regexp matching any name in `pyking-mode-builtins' as a whole symbol.")

(defconst pyking-mode-font-lock-keywords
  (list
   ;; function_def = "def" , def_name , "(" ... -- the declared function
   ;; name, a submodule's path (`mymod.foo') included.
   '("\\_<def\\_>[ \t]+\\(\\(?:\\sw+\\.\\)*\\sw+\\)"
     1 font-lock-function-name-face)
   ;; datatype_stmt = "datatype" , [ sub_path , "." ] , upper_ident , ...
   ;; -- the declared type, with its submodule's path.
   '("\\_<datatype\\_>[ \t]+\\(\\(?:\\sw+\\.\\)*\\sw+\\)"
     1 font-lock-type-face)
   ;; var_decl = "var" , ident , "=" , expr -- the declared variable name.
   '("\\_<var\\_>[ \t]+\\(\\sw+\\)"
     1 font-lock-variable-name-face)
   ;; for_stmt = "for" , ident , "in" , expr , ":" , block -- loop variable.
   '("\\_<for\\_>[ \t]+\\(\\sw+\\)[ \t]+\\_<in\\_>"
     1 font-lock-variable-name-face)
   ;; assignment = target , [ ":" , type ] , "=" , bound_value -- the
   ;; annotated form declares a name, so it is highlighted like the
   ;; `def'/`var'/`for' declarations above. The annotation must actually
   ;; begin a `type' (see the grammar in PYKING.md): requiring that is
   ;; what stops a bare `else:' -- a word, a colon, and nothing more --
   ;; from being mistaken for a declaration of a variable called `else'.
   ;; A `public' in front of it declares the same name, so it is
   ;; skipped rather than mistaken for the name being declared.
   '("^[ \t]*\\(?:public[ \t]+\\)?\\(\\(?:\\sw+\\.\\)*\\sw+\\)[ \t]*:[ \t]*\\(?:Int\\|String\\|Bool\\|[][(]\\)"
     1 font-lock-variable-name-face)
   ;; mutation = ident , ":=" , expr -- Pyking's one deliberate departure
   ;; from plain Python assignment (see PYKING.md), worth calling out.
   '(":=" . font-lock-keyword-face)
   ;; `++' -- concatenation, and Pyking's deliberate departure from
   ;; Python's `+' meaning both addition and joining (see PYKING.md,
   ;; "Concatenation"). Called out for the same reason `:=' is. Escaped:
   ;; a bare "++" would be a regexp repeat and match a single `+' too.
   '("\\+\\+" . font-lock-keyword-face)
   ;; def_name = ident | qualified_name -- the `q::' of an overloaded
   ;; definition's name (see PYKING.md, "Static overloading"). The whole
   ;; thing is one identifier to the lexer; only the qualifier and the
   ;; `::' are highlighted, so the base name still reads as a name.
   '("\\_<\\(\\sw+::\\)\\sw" 1 font-lock-type-face)
   ;; lambda = lambda_params , "=>" , expr -- Pyking's lambda arrow (see
   ;; PYKING.md, "Lambdas"). Called out for the same reason `:=' and
   ;; `++' are: it is a marker with no Python spelling. Escaped so the
   ;; `=' is literal rather than a regexp operator's operand.
   '("=>" . font-lock-keyword-face)
   ;; `all a b.' -- the quantifier that binds type variables. Not in
   ;; `pyking-mode-keywords' because it is not in src/lexer.ml's
   ;; `keywords' either: it is recognized only in type position (see
   ;; `parse_type_atom' in src/parser.ml), so `all' stays usable as an
   ;; ordinary name everywhere else. Matched by its shape instead -- the
   ;; word, one or more lowercase variables, and the `.' that ends it --
   ;; and only the word itself is highlighted.
   '("\\_<\\(all\\)\\_>\\(?:[ \t]+[a-z]\\sw*\\)+[ \t]*\\."
     1 font-lock-keyword-face)
   ;; rest_marker = ".." , [ ident ] -- the list-pattern "rest" marker
   ;; (`..`/`..name`), Pyking's spelling of Python's `*_'/`*name' star
   ;; sub-pattern. Matched before any single-`.' rule could apply (there
   ;; isn't one currently, but this keeps the ordering future-proof).
   '("\\.\\." . font-lock-keyword-face)
   ;; int = digit , { digit } ; identifiers can't start with a digit, so
   ;; a symbol-boundary match is exactly the integer-literal case. `bool'
   ;; (`true'/`false', see `pyking-mode-constants') is folded into this
   ;; same rule -- one alternation, one face -- rather than a second,
   ;; separate rule that merely happens to specify the same face: a
   ;; literal value is a literal value, whether spelled with digits or
   ;; with `true'/`false', and this makes that a single fact in the code,
   ;; not two rules that could drift apart under a future edit.
   (cons (concat "\\_<[0-9]+\\_>\\|" pyking-mode-constants-regexp)
         'font-lock-constant-face)
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

(defun pyking--continuation-open-position ()
  "Return the position of the bracket keeping the current line open, or nil.
A line inside an unclosed `(' or `[' is a continuation of the line that
opened it: the lexer suspends its indentation rules there, so the line's
own indentation means nothing to the compiler (see \"Lines and
continuation\" in PYKING.md). `syntax-ppss' answers this directly,
because `pyking-mode-syntax-table' gives both bracket pairs paren
syntax."
  (save-excursion
    (beginning-of-line)
    (nth 1 (syntax-ppss))))

(defun pyking--goto-logical-line-start ()
  "Move to the first line of the logical line point is on.
A statement spanning several physical lines inside brackets starts at the
line that opened the outermost one; that is the line whose indentation
the statement actually has."
  (beginning-of-line)
  (let ((open (pyking--continuation-open-position)))
    (while open
      (goto-char open)
      (beginning-of-line)
      (setq open (pyking--continuation-open-position)))))

(defun pyking--line-ends-with-colon-p ()
  "Return non-nil if the current line's code (sans trailing comment) ends in `:'."
  (save-excursion
    (goto-char (pyking--code-end-position))
    (skip-chars-backward " \t")
    (eq (char-before) ?:)))

(defun pyking--line-ends-with-eq-p ()
  "Return non-nil if the current line's code (sans comment) ends in `=' or `:='.
Such a line is a binding whose value starts on the next line, indented
\(see \"the value may start on the next line\" in PYKING.md), so it opens
a block just as a `:' header does. `==', `<=' and `>=' are excluded --
a line ending in a comparison operator is incomplete, not a binding."
  (save-excursion
    (goto-char (pyking--code-end-position))
    (skip-chars-backward " \t")
    (and (eq (char-before) ?=)
         (not (memq (char-before (1- (point))) '(?= ?< ?>))))))

(defun pyking--line-first-word-matches-p (regexp)
  "Return non-nil if the current line matches REGEXP from its first word.
REGEXP is matched with `looking-at' at the line's first non-blank
character, so it usually just tests that word (`\\_<else\\_>' et al.),
but may describe more of the line -- see
`pyking--if-block-opener-regexp'."
  (save-excursion
    (beginning-of-line)
    (skip-chars-forward " \t")
    (looking-at regexp)))

(defconst pyking--if-block-opener-regexp
  "\\(?:[^=\n]*=[ \t]*\\)?\\_<if\\_>[^\n]*:"
  "Regexp matching a line that opens an `if_stmt' block, from its first word.
Covers the bare `if cond:' header, the value form `target = if cond:'
\(see \"`if'/`match' statements as bound values\" in PYKING.md) -- which
is why the `if' can't simply be required to be the line's first word --
and a header carrying its block on its own line (`if c: print(1)', see
\"A block on its header's own line\"), which an `else' below it still
dedents out of. A `:' somewhere after the `if' is required so an
`if_expr' line -- `x = if c then a else b', which opens no block -- is
never mistaken for a header. Both character classes exclude newlines
because `looking-at' would otherwise happily run past the end of the
line to find an `=' or a `:' several lines down.")

(defconst pyking--match-block-opener-regexp
  "\\(?:[^=\n]*=[ \t]*\\)?\\_<match\\_>"
  "Regexp matching a line that opens a `match_stmt', from its first word.
Like `pyking--if-block-opener-regexp', this covers both the bare `match
e:' header and the value form `target = match e:'. A `match' never sits
in a header's own-line block -- only an expression may be written there
(see \"A block on its header's own line\" in PYKING.md) -- so its header
is always the line's own. There is no match *expression* to tell it
apart from, so no trailing `:' is required here.")

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
  (pyking--backward-dedent-target
   "\\_<else\\_>" pyking--if-block-opener-regexp 0))

(defun pyking--case-target-indent ()
  "Indentation for a `case' line: aligned with the previous sibling
`case_clause' if there is one at the same depth, otherwise one
`pyking-indent-offset' deeper than the `match' header that opens the
`match_stmt' -- needed because a `case pattern -> expr' clause (see
PYKING.md) has no indented body of its own, so the next `case' isn't
necessarily one level below the previous line the way `else' always is."
  (pyking--backward-dedent-target
   "\\_<case\\_>" pyking--match-block-opener-regexp pyking-indent-offset))

(defun pyking--dedenter-line-p ()
  "Return non-nil if the current line is known to end its own block.
A `return_stmt' always ends the statement sequence it's part of, and so
do `break' and `continue': each leaves the block it stands in, and
src/parser.ml refuses a statement written after one of the latter two at
all (\"this statement cannot be reached\"). So the line after any of
the three dedents a `pyking-indent-offset'. Mirrors `python-mode's own
`python-indent-dedenters', and like it dedents exactly one level, not
however many blocks actually closed -- no context-free indent heuristic
can derive that; repeated TAB (see `pyking-indent-line') walks the rest.

A `case pattern -> expr' clause is *not* listed here, though it too has
no indented body: what follows such a clause is far more often the next
`case' of the same `match_stmt', at the same column, than a statement
after the block -- in every tests/*.pyk file using the arrow form, only
the last clause of each group is followed by a dedent. Guessing the
same column keeps the common case correct as it is typed; the rarer
dedent out of the block is one TAB away."
  (pyking--line-first-word-matches-p
   (regexp-opt '("return" "break" "continue") 'symbols)))

(defun pyking-calculate-indent ()
  "Compute the indentation column for the current line.
Mirrors `python-mode's own simple case: a `block' is one
`pyking-indent-offset' deeper than the `:'-terminated line that opens
it (see `block'/`if_stmt'/`match_stmt' et al. in PYKING.md's grammar),
`else'/`case' dedent back out of the block(s) they close (see
`pyking--else-target-indent'/`pyking--case-target-indent'), a line
continued inside an open bracket sits one level past the line that
opened it -- two for a `def' header, whose body already has the first
(see `pyking--continuation-open-position'), a line
following a `pyking--dedenter-line-p' line dedents one level, and any
other line matches the previous non-blank line's indentation --
leaving the user to dedent further manually, the same as `python-mode'
does for a plain statement following a multi-level nested block."
  (save-excursion
    (beginning-of-line)
    (cond
     ((bobp) 0)
     ;; A continuation line indents one level past the line that opened
     ;; the bracket. The compiler ignores it either way, so this is for
     ;; the reader.
     ((pyking--continuation-open-position)
      (save-excursion
        (goto-char (pyking--continuation-open-position))
        (beginning-of-line)
        ;; One level past the line holding the bracket, so nesting
        ;; brackets steps in once each -- and a second level for a `def'
        ;; header, whose body already occupies the first one. This is
        ;; PEP 8's hanging-indent rule, and for its reason: the compiler
        ;; ignores a continuation line's indentation entirely, so all it
        ;; has to do is stay clear of the block below it.
        (+ (current-indentation)
           pyking-indent-offset
           (if (pyking--line-first-word-matches-p "\\_<def\\_>")
               pyking-indent-offset
             0))))
     ((pyking--line-first-word-matches-p "\\_<else\\_>") (pyking--else-target-indent))
     ((pyking--line-first-word-matches-p "\\_<case\\_>") (pyking--case-target-indent))
     (t (let (prev-indent prev-opens-block prev-is-dedenter)
          (save-excursion
            (forward-line -1)
            (while (and (not (bobp)) (pyking--blank-or-comment-line-p))
              (forward-line -1))
            ;; The `:' or `=' that opens a block is at the end of the
            ;; statement, which for a multi-line one is its *last*
            ;; physical line -- where we now stand.
            (setq prev-opens-block (or (pyking--line-ends-with-colon-p)
                                       (pyking--line-ends-with-eq-p)))
            (pyking--goto-logical-line-start)
            ;; A `datatype' header may hold its first constructors after
            ;; its `:' (`datatype Bit: Zero, One'), and still have more
            ;; on indented lines under it.
            (when (pyking--line-first-word-matches-p "\\_<datatype\\_>")
              (setq prev-opens-block t))
            ;; Its indentation, though, is its first line's.
            (setq prev-indent (current-indentation))
            (setq prev-is-dedenter (pyking--dedenter-line-p)))
          (cond
           (prev-opens-block (+ prev-indent pyking-indent-offset))
           (prev-is-dedenter (max 0 (- prev-indent pyking-indent-offset)))
           (t prev-indent)))))))

(defun pyking-indent-post-self-insert-function ()
  "Reindent a dedenter line as soon as its `:' is typed.
Added to `post-self-insert-hook'. Without it, typing

    else:

under an `if' body leaves the line wherever RET guessed for it while it
was still empty -- one level too deep, since the guess can only copy the
previous line -- and nothing ever re-asks `pyking-calculate-indent',
which had the right answer all along. Only `else'/`case' lines are
touched: they are the forms whose correct column is a *dedent*, so the
typist cannot have landed on it already. A block-opening header
\(`if'/`for'/`while'/`def'/`match') is left alone, as in `python-mode'.

Reindenting on a self-inserted character is exactly what
`electric-indent-chars' would do, but this mode sets
`electric-indent-inhibit' (Pyking indentation is a guess, so RET must
not reindent the previous line), and `electric-indent-post-self-insert-
function' skips *all* non-newline reindentation whenever that flag is
set. `python-mode' resolves the same conflict the same way: keep the
inhibit, add `?:' to `electric-indent-chars' as the opt-in flag, and do
the colon handling in its own hook -- see
`python-indent-post-self-insert-function'."
  (when (and (eq ?: last-command-event)
             (eq (char-before) last-command-event)
             ;; The opt-out: this mode puts `?:' in `electric-indent-chars'
             ;; itself, so removing it there disables the reindent. Not
             ;; gated on `electric-indent-mode' -- `pyking-mode-map' binds
             ;; RET to indent regardless of that mode, and indentation
             ;; that half-works depending on a global toggle is worse than
             ;; either behavior consistently.
             (memq ?: electric-indent-chars)
             (not current-prefix-arg)
             ;; Only at end of line, and not on a doubled `::' -- both
             ;; mean the user is still mid-edit, not finishing a header.
             (eolp)
             (not (eq ?: (char-before (1- (point)))))
             ;; Never inside a string or comment (`nth 8' covers both).
             (not (nth 8 (syntax-ppss)))
             (or (pyking--line-first-word-matches-p "\\_<else\\_>")
                 (pyking--line-first-word-matches-p "\\_<case\\_>")))
    ;; Keep point where it is (end of line) across the reindent.
    (let ((savep (- (point-max) (point))))
      (indent-line-to (max (pyking-calculate-indent) 0))
      (goto-char (- (point-max) savep)))))

(defun pyking--previous-code-line-opens-block-p ()
  "Return non-nil if the previous non-blank, non-comment line opens a block
the next line must fill: a line *ending* in `:', or a binding whose
value is missing from it -- a trailing `=' or `:=', as in `x =' with the
value on the next line (see PYKING.md). A header carrying its block on
its own line (`def f(a): a + 1') ends in neither, and leaves nothing for
the next line to fill."
  (save-excursion
    (beginning-of-line)
    (unless (bobp)
      (forward-line -1)
      (while (and (not (bobp)) (pyking--blank-or-comment-line-p))
        (forward-line -1))
      (and (not (pyking--blank-or-comment-line-p))
           (or (pyking--line-ends-with-colon-p)
               (pyking--line-ends-with-eq-p))))))

(defun pyking--indent-levels ()
  "Every column the current line could plausibly be indented to, deepest first.
That is `pyking-calculate-indent's guess, then each shallower column an
enclosing line already sits at, then 0. Closing a block is the one thing
the guess cannot derive -- it never knows how many blocks a line ends --
so these are the levels repeated TAB offers instead (see
`pyking-indent-line').

Directly after a line that opens a block, though, there is nothing to
guess: the block cannot be empty and Pyking indents in exact 4-space
steps (see \"Indentation-based blocks\" in PYKING.md), so exactly one
column can parse. The single forced level is returned there, which is
what stops TAB from cycling a continuation line -- `x =' followed by an
indented `if'/`match'/expression -- back out to a column that is not
Pyking at all."
  (let ((guess (max (pyking-calculate-indent) 0))
        (levels '()))
    (if (pyking--previous-code-line-opens-block-p)
        (list guess)
      (save-excursion
        (beginning-of-line)
        (while (not (bobp))
          (forward-line -1)
          (unless (pyking--blank-or-comment-line-p)
            (let ((ind (current-indentation)))
              (when (and (< ind guess) (not (member ind levels)))
                (setq levels (cons ind levels)))))))
      (sort (delete-dups (cons guess (cons 0 levels))) #'>))))

(defun pyking--next-indent-level (current levels)
  "The level after CURRENT in LEVELS, wrapping around at the end."
  (let ((tail (cdr (member current levels))))
    (if tail (car tail) (car levels))))

(defun pyking-indent-line ()
  "Indent the current line as Pyking source.
The first TAB indents to `pyking-calculate-indent'. Pressing TAB again
without an intervening command cycles through `pyking--indent-levels' --
successively shallower enclosing columns, wrapping back around to the
first guess. This is `python-indent-line's behavior, and it is what
makes closing a block workable: the guess can only ever keep the
previous line's depth, which is right after most statements and wrong
after the last line of any block -- notably every branch of a value-form
`if'/`match' (see PYKING.md), whose branches all end in a bare
expression, so the statement after one always needs a dedent.

Cycling is deliberately restricted to an interactive TAB
\(`indent-for-tab-command' twice in a row); `indent-region' and friends
call this repeatedly within one command and must always get the plain
guess, never a walk down the levels.

Leaves point at the new indentation when point started within the
line's leading whitespace, otherwise keeps it fixed relative to the
end of the buffer -- the standard `indent-line-function' convention
(also followed by `python-indent-line')."
  (interactive)
  (let* ((savep (- (point-max) (point)))
         (levels (pyking--indent-levels))
         (cycling (and (eq this-command 'indent-for-tab-command)
                       (eq last-command 'indent-for-tab-command)
                       (member (current-indentation) levels)))
         (target (if cycling
                     (pyking--next-indent-level (current-indentation) levels)
                   (car levels))))
    (if (<= (current-column) (current-indentation))
        (indent-line-to target)
      (save-excursion (indent-line-to target)))
    (when (> (- (point-max) savep) (point))
      (goto-char (- (point-max) savep)))))

(defun pyking-indent-region (start end)
  "Indent the region as Pyking source, leaving already-plausible lines alone.
Plain `indent-region' applies `pyking-calculate-indent' to every line,
and that guess keeps the previous line's depth wherever a block *ends*
-- so running it over a correctly indented buffer marches steadily
rightward, each over-indented line dragging the next one further. A line
is therefore reindented only when its column is not among the ones
`pyking--indent-levels' accepts, which makes this idempotent on
well-indented source while still fixing a genuinely wrong line: after a
block opener that list holds a single forced column (see
`pyking--indent-levels'), so a continuation line such as the one under
`x =' is always corrected."
  (let ((end (copy-marker end)))
    (save-excursion
      (goto-char start)
      (beginning-of-line)
      (while (< (point) end)
        (unless (pyking--blank-or-comment-line-p)
          (let ((levels (pyking--indent-levels)))
            ;; Only a column no `pyking--indent-levels' entry allows is
            ;; overwritten. Notably an `else'/`case' line is *not* forced
            ;; to its scan result even though that result is computed
            ;; rather than inherited: the scan has a known blind spot
            ;; (see the Commentary), and forcing a wrong answer over an
            ;; already-correct line -- which is exactly what it does to a
            ;; nested `if'/`else' -- is worse than leaving the author's.
            (unless (member (current-indentation) levels)
              (indent-line-to (car levels)))))
        (forward-line 1)))
    (set-marker end nil)))

(defvar pyking-mode-map
  (let ((map (make-sparse-keymap)))
    ;; RET indents the line it opens, whatever the user's
    ;; `electric-indent-mode' setting is. Leaving that to
    ;; `electric-indent-mode' (as `python-mode' does) makes the mode's
    ;; indentation vanish for anyone who turns it off, remaps RET, or
    ;; edits through something that inserts newlines its own way -- and
    ;; the one column this mode is certain of, the forced one after a
    ;; block opener like `x =' (see `pyking--indent-levels'), is exactly
    ;; the column a user is most surprised to have to type by hand.
    ;; `newline-and-indent' also drops the whitespace left behind when
    ;; RET splits a line mid-way, so `z = |match y:' leaves `z =' with no
    ;; trailing space. Indenting again after `electric-indent-mode' has
    ;; already done it is a no-op, so the two coexist.
    (define-key map (kbd "RET") #'newline-and-indent)
    map)
  "Keymap for `pyking-mode'.")

(defvar pyking-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; ident = letter , { letter | digit } ; where `letter' includes `_'
    ;; (see `is_letter' in src/lexer.ml) -- `_' is part of the word,
    ;; not a symbol separator.
    (modify-syntax-entry ?_ "w" table)
    ;; Comments: "#" runs to end of line.
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    ;; string = "'" , { string_char } , "'" | '"' , { string_char } , '"' ;
    ;; both quote characters delimit strings, and "\\" is the escape
    ;; character for both (see `scan_string'/`_ESCAPES' in src/lexer.ml).
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
`while', `loop', `break', `continue', `then', `else', `var', `def',
`return', `match', `case'), the one keyword recognized only where it
is one (`all' in a type), the
`:=' mutation operator, the `..'/`..name' list-pattern rest marker,
string literals (with backslash escapes), `#' comments, the name an
annotated binding declares (`x: Int = 1'), integer and
boolean literals (`true'/`false', see `pyking-mode-constants', coloured
the same as an integer literal, not as a keyword), type annotation names
(`Int', `String', `Bool', see `pyking-mode-types'), and well-known
builtins (see `pyking-mode-builtins'), consistent with the grammar
documented in PYKING.md and implemented in src/lexer.ml and
src/parser.ml.

Also provides `python-mode'-style 4-space (`pyking-indent-offset')
indentation via `pyking-indent-line', including TAB-again cycling
through shallower levels to close blocks."
  :syntax-table pyking-mode-syntax-table
  (setq-local font-lock-defaults '(pyking-mode-font-lock-keywords nil nil))
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local comment-end "")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width pyking-indent-offset)
  (setq-local indent-line-function #'pyking-indent-line)
  (setq-local indent-region-function #'pyking-indent-region)
  ;; Reindent an `else:'/`case ...:' line as its `:' is typed -- see
  ;; `pyking-indent-post-self-insert-function' for why the work can't be
  ;; left to `electric-indent-chars' alone (`electric-indent-inhibit'
  ;; below suppresses every non-newline reindent Emacs would do itself,
  ;; so the char list serves only as the opt-in flag the hook consults).
  (setq-local electric-indent-chars (cons ?: electric-indent-chars))
  (add-hook 'post-self-insert-hook
            #'pyking-indent-post-self-insert-function 'append 'local)
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

(defcustom pyking-lsp-command '("pyk" "lsp")
  "Command that starts the Pyking language server, as a program and its
arguments. eglot runs it in a `pyking-mode' buffer; see
`pyking-eglot-contact'."
  :type '(repeat string)
  :group 'pyking)

(defvar eglot-server-programs)

(defun pyking-eglot-contact (_interactive)
  "The eglot contact for `pyking-mode': `pyking-lsp-command'.
Boolean -> [String]"
  pyking-lsp-command)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(pyking-mode . pyking-eglot-contact)))

(provide 'pyking-mode)

;;; pyking-mode.el ends here
