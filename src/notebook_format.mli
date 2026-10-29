(** Notebooks as JSON: a notebook's Markdown read into one structured
    value -- the text between its blocks kept as it is, each task
    with its solution, tests and the blocks loosening how it is
    compared, each quiz with its answer, each cell with the tests
    under it -- and that value written back as the same Markdown,
    character for character. Also the JSON
    Schema such a value follows. See docs/notebook.md ("JSON").

    Data structures:
      Format_error -- a JSON value that is not a notebook.

    Functions:
      of_markdown text -- the notebook text holds, as JSON.
      to_markdown value -- the Markdown a notebook's JSON stands for.
      schema -- the JSON Schema every notebook's JSON follows. *)

(** A JSON value that is not a notebook, saying where. *)
exception Format_error of string

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
