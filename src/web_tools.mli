(** `pyk notebook`, `pyk playground`, `pyk help` and `pyk serve`: finds the web
    tools beside this executable, works out what each serves, and serves
    it with web_server.ml in this process -- nothing else has to be
    installed. `pyk notebook --mode test` serves nothing and runs
    tools/notebook/check.js under node instead. See docs/build.md ("The
    web tools").

    Data structures:
      tool -- which web tool.

    Functions:
      start tool port mode path -- serves the tool, or answers why not. *)

(** Which web tool: the notebook, which opens one Markdown document, the
    playground, the help, or a directory's files as they are. *)
type tool = Notebook | Playground | Help | Files

(** Serves the tool until Ctrl+C, on `port` if one is given: the
    notebook opening the document `path` in `mode` (student, teacher or
    test, which runs it under node instead), or the directory `path` (by
    default the current one). Answers the exit status, or why it could
    not start. tool -> int? -> string? -> string? -> (int, string) result *)
val start : tool -> int option -> string option -> string option -> (int, string) result
