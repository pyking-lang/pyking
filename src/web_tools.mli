(** `pyk notebook` and `pyk playground`: finds the web tool beside this
    executable, checks that a new enough Python is installed, and hands
    the process over to the tool's own Python server. Nothing here serves
    a page; tools/webrun/server.py does. See docs/build.md ("The web
    tools").

    Data structures:
      tool -- which web tool.

    Functions:
      start tool port document -- replaces this process with the tool's
        server, or answers why it could not. *)

(** Which web tool: the notebook, which opens one Markdown document, or
    the playground. *)
type tool = Notebook | Playground

(** Replaces this process with the tool's Python server, on `port` if
    one is given, opening `document` for the notebook. Returns only when
    that could not be done, with the reason.
    tool -> int? -> string? -> string *)
val start : tool -> int option -> string option -> string
