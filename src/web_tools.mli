(** `pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve`: finds the web
    tools beside this executable, works out what each serves, and serves
    it with web_server.ml in this process -- nothing else has to be
    installed. `pyk notebook --mode test` serves nothing and runs
    tools/notebook/check.js under node instead. See docs/build.md ("The
    web tools").

    Data structures:
      tool -- which web tool.

    Functions:
      start tool port mode path -- serves the tool, or answers why not.
      render_markdown markdown -- a notebook's Markdown as the page
        renders it, under node, for `pyk highlight`.
      notebook_stylesheet () -- the notebook page's stylesheet. *)

(** Which web tool: the notebook, which opens one Markdown document, the
    playground, the help, or a directory's files as they are. *)
type tool = Notebook | Playground | Help | Files

(** Serves the tool until Ctrl+C, on `port` if one is given: the
    notebook opening the document `path` -- Markdown, or a notebook's
    JSON, served as the Markdown it stands for -- in `mode` (student,
    teacher or test, which runs it under node instead), or the directory
    `path` (by default the current one). `warnings` is the -W flags the
    notebook's page checks each block with. Answers the exit status, or
    why it could not start.
    [string]? -> tool -> int? -> string? -> string? -> (int, string) result *)
val start : ?warnings:string list -> tool -> int option -> string option -> string option -> (int, string) result

(** A notebook's Markdown rendered as the notebook's page renders it --
    tools/notebook/assets/markdown.js's renderMarkdown, run under node
    -- as its HTML and its title, or why it could not be: node missing,
    first of all. string -> (string * string, string) result *)
val render_markdown : string -> (string * string, string) result

(** The notebook page's stylesheet, tools/notebook/assets/notebook.css,
    or "" where it is missing. () -> string *)
val notebook_stylesheet : unit -> string
