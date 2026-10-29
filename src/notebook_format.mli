(** Notebooks as JSON: a notebook's Markdown read into one structured
    value -- the text between its blocks kept as it is, each task
    with its solution, tests and the blocks loosening how it is
    compared, each quiz with its answer, each cell with the tests
    under it -- and that value written back as the same Markdown,
    character for character. Also the JSON
    Schema such a value follows. See docs/notebook.md ("JSON").

    Data structures:
      Format_error -- a JSON value that is not a notebook.
      value -- an attribute's value: a string, a number or a boolean.
      fence -- one notebook block as the Markdown writes it.
      piece -- the text between blocks, or a block.

    Functions:
      scan text -- the text as the pieces between and of its blocks.
      of_markdown text -- the notebook text holds, as JSON.
      to_markdown value -- the Markdown a notebook's JSON stands for.
      schema -- the JSON Schema every notebook's JSON follows. *)

(** A JSON value that is not a notebook, saying where. *)
exception Format_error of string

(** An attribute's value, typed: a number for `max`, `points` and the
    rest that count, true or false for `visible` and a bare word, and a
    string otherwise. *)
type value = VString of string | VNumber of float | VBool of bool

(** One notebook block as the Markdown writes it. *)
type fence = {
  language : string;  (** lowercased, as written *)
  attrs : (string * value) list;  (** in the order written *)
  info : string;  (** what follows the fence marker on its line *)
  marker : string;  (** the opening ``` or ~~~ *)
  body : string;  (** the lines between, each with its newline *)
  close : string option;  (** the closing line, or None at the end of the text *)
  gap : string option;  (** the blank lines before it, where a block is right before *)
}

(** The text between notebook blocks, or a block. *)
type piece = Text of string | Fence of fence

(** The text split into the text between notebook blocks and the
    blocks, found where markdown.js finds them: a fence at the left
    margin in one of the notebook's languages, outside another fenced
    block, an HTML block, display math and the front matter. Blank text
    between two blocks is the second one's `gap` rather than a piece.
    What highlight.ml finds a notebook's Pyking blocks with.
    string -> [piece] *)
val scan : string -> piece list

(** The notebook text holds, as JSON: the Markdown between its blocks as
    written, and each block a notebook reads, grouped as the notebook
    page groups them. string -> Json *)
val of_markdown : string -> Json.t

(** The Markdown a notebook's JSON stands for: what of_markdown read
    from, where the value came from it. Raises Format_error where the
    value is not a notebook. Json -> string *)
val to_markdown : Json.t -> string

(** The JSON Schema every notebook's JSON follows, as text. string *)
val schema : string
