(** Pyking source as coloured text that stays text: `pyk highlight` and
    the browser's `pykHighlight`. The source is cut into spans by the
    compiler's own lexer, one line at a time, so the colours follow the
    real language; each span is given a class the way the playground's
    Monaco tokenizer (tools/webrun/assets/pyking-monaco.js) gives one,
    and coloured with that file's `pyking-light` or `pyking-dark`
    theme. The same spans are then written as an HTML fragment with
    every style inline, as an RTF document, or as plain text -- what a
    slide program such as Keynote pastes and keeps as text. Indentation
    is written with non-breaking spaces (U+00A0) by default, since
    exporting a slide to PDF and copying the code back out tends to lose
    leading spaces. Also finds a notebook's Pyking blocks, for
    highlighting a notebook. See docs/source.md ("highlight.ml").

    Data structures:
      kind -- a span's class: keyword, type, constant, number, string,
        comment, function, builtin, operator or plain.
      span -- a run of a line's text and its kind.
      line -- one line: its indentation and its spans.
      theme / background / spaces / options -- how a snippet is written.
      palette -- a theme's colours.
      block -- one Pyking block of a notebook, numbered from 1.
      piece -- a notebook as prose, Pyking blocks and output blocks.

    Functions:
      classify source -- the source's lines, as spans.
      palette theme -- a theme's colours.
      html / rtf / text options source -- one snippet in one format.
      rtf_document / text_document options pieces -- several snippets,
        and prose, in one document.
      parse_theme / parse_font / parse_size / parse_background /
        parse_spaces -- an option's value, as the command line and the
        browser write it.
      options_of_json value -- the browser's options object.
      notebook_pieces markdown -- a notebook's prose and blocks.
      notebook_blocks markdown -- its Pyking blocks alone.
      marked_markdown pieces / fill_markers options pieces html -- the
        notebook's Markdown with each block a marker, and the rendered
        HTML with each marker the block's snippet. *)

(** A span's class. Mirrors the tokens of pyking-monaco.js: `Type` is a
    type keyword or a capitalised name, `Constant` is true or false,
    `String` a String or Char literal, `Function` the name after `def`,
    `Builtin` one of the compiler's builtins, and `Plain` anything left
    uncoloured -- names, brackets, `,` `:` `.`, spaces, and the part of
    a line that does not lex. *)
type kind =
  | Keyword
  | Type
  | Constant
  | Number
  | String
  | Comment
  | Function
  | Builtin
  | Operator
  | Plain

(** A run of a line's text, all of one kind. *)
type span = { kind : kind; text : string }

(** One line: how many spaces it starts with, and the rest as spans. *)
type line = { indent : int; spans : span list }

(** The kind's name, as the tests and the documentation write it.
    kind -> string *)
val kind_name : kind -> string

(** Every kind, in the order the documentation lists them. [kind] *)
val kinds : kind list

(** Pyking source as lines of spans. Tabs become four spaces and a
    carriage return is dropped first; a non-breaking space counts as a
    space wherever a space may stand. Each line is lexed on its own,
    after its leading spaces, so a fragment that does not lex as a whole
    still highlights; where a line fails to lex, it is coloured up to the
    longest prefix that lexes and the rest is `Plain`.
    string -> [line] *)
val classify : string -> line list

(** Which of the two Monaco themes. *)
type theme = Light | Dark

(** What is behind the text: nothing (the slide's own background), the
    theme's, or a colour, `#rrggbb` in lower case. *)
type background = No_background | Theme_background | Colour of string

(** How spaces are written: leading spaces as U+00A0 (the default),
    every space but those inside a String or Char literal as U+00A0
    (which are what the program prints, and stay as written), or every
    space as an ordinary one. *)
type spaces = Indent | All | Ordinary

(** How a snippet is written: theme (default light), font (default
    "Menlo", with a monospace fallback in HTML), size in points (None
    leaves it to the application), background and spaces. *)
type options = {
  theme : theme;
  font : string;
  size : int option;
  background : background;
  spaces : spaces;
}

(** The defaults: light, Menlo, no size, no background, indentation as
    U+00A0. options *)
val default_options : options

(** A theme's colours, each `#rrggbb`: the text's, the background's, and
    each kind's where it has one (`Plain` has none, and is the text's
    colour); `italic` is the kinds written in italic. *)
type palette = {
  foreground : string;
  background_colour : string;
  colour : kind -> string option;
  italic : kind -> bool;
}

(** The colours of pyking-monaco.js's `pyking-light` or `pyking-dark`.
    theme -> palette *)
val palette : theme -> palette

(** One snippet as an HTML fragment: a `<pre>` whose style attribute
    holds the font, `white-space:pre`, the foreground colour, the
    background where one is asked for and the size where one is given,
    holding a `<span style="color:...">` per coloured run. No classes and
    no stylesheet, so it pastes as it shows. Text is escaped, every
    character outside ASCII as a character reference, so the fragment
    reads the same in whatever encoding it is opened. No newline after
    the last line. options -> string -> string *)
val html : options -> string -> string

(** One snippet as a complete RTF document: a font table with the font,
    a colour table, `\fsN` where a size is given, a line per `\par`,
    U+00A0 as `\~` and every other character outside ASCII as `\uN?`.
    options -> string -> string *)
val rtf : options -> string -> string

(** One snippet as plain text with `options.spaces` applied, a newline
    after the last line where the source has one: what "Paste and Match
    Style" keeps. options -> string -> string *)
val text : options -> string -> string

(** One Pyking block of a notebook: its number (from 1, in the order
    written), its info string (`pyking norun`, ...) and its source. *)
type block = { number : int; info : string; source : string }

(** A notebook as `whole` mode writes it: the Markdown between blocks,
    a Pyking block, or the text of a block a program reads or writes
    (stdin, stdout, stderr), shown as it is. The notebook's other blocks
    -- quizzes, rules, tests' events and arguments -- are left out. *)
type piece = Prose of string | Code of block | Output of string

(** A notebook's Markdown as prose and blocks, in order. A front matter
    block is kept in the prose, for the notebook's renderer to read the
    title from; the RTF and plain text leave it out. string -> [piece] *)
val notebook_pieces : string -> piece list

(** A notebook's Pyking blocks, numbered from 1 in the order written:
    every ```pyking or ```pyk block, whatever its attributes -- a cell,
    a norun fragment, an error cell, a task's starting code, a solution.
    string -> [block] *)
val notebook_blocks : string -> block list

(** Several snippets and prose as one RTF document: each Pyking block
    highlighted, each output block in the same font uncoloured, and the
    prose as plain paragraphs in Helvetica, one per run of lines between
    blank lines. options -> [piece] -> string *)
val rtf_document : options -> piece list -> string

(** The same as plain text: the prose as written, each block with
    `options.spaces` applied, a blank line between pieces.
    options -> [piece] -> string *)
val text_document : options -> piece list -> string

(** The Markdown of the pieces with each block an HTML marker of its
    own, `<div data-pyk-piece="K"></div>`, for the notebook's own
    renderer to render the prose around. [piece] -> string *)
val marked_markdown : piece list -> string

(** HTML rendered from `marked_markdown pieces` with each marker
    replaced by its piece's snippet, an output block's uncoloured.
    options -> [piece] -> string -> string *)
val fill_markers : options -> piece list -> string -> string

(** Several snippets as an HTML fragment: each block's `<pre>`, in
    order, one per line. options -> [piece] -> string *)
val html_snippets : options -> piece list -> string

(** A standalone HTML page around a body: the title, UTF-8, and the
    stylesheet given. string -> string -> string -> string *)
val html_page : title:string -> style:string -> string -> string

(** An option's value as the command line or the browser writes it, or
    the message refusing it, which starts with `name` (`--theme` on the
    command line, `theme` in the browser). Each is a string -> string ->
    (value, string) result: name, then the text given. *)
val parse_theme : string -> string -> (theme, string) result

val parse_font : string -> string -> (string, string) result
val parse_size : string -> string -> (int, string) result
val parse_background : string -> string -> (background, string) result
val parse_spaces : string -> string -> (spaces, string) result

(** The browser's options object -- {theme, font, size, background,
    spaces}, every field optional and null meaning the default -- or why
    it is refused. Json.t -> (options, string) result *)
val options_of_json : Json.t -> (options, string) result
