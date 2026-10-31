(** The Pyking language server: a state and one function from a message an
    editor sent to the messages to send back. It checks a document with
    the compiler's own front end -- Module.load, Typesystem.type_check,
    Analyses.analyze_mutability -- and reads hover, definition, outline
    and completion out of what that produced. No file is opened here:
    the caller hands in where files come from, so the same server runs
    in `pyk lsp` and in the browser. See design/lsp.md.

    Data structures:
      state -- everything the server knows.

    Functions:
      create sources libs version -- a server that has seen nothing.
      handle state text -- one message received, and what to send back.
      idle state -- the diagnostics of every document due to be checked.
      exit_code state -- the status to exit with, once `exit` arrived.
      with_warnings state config -- the server reporting other warnings. *)

(** Everything the server knows: the open documents, the settings, what
    checking each document found, and where the protocol is. *)
type state

(** A server that has seen nothing: files are read from `sources` where
    no document is open, libraries are looked for in `libs`, and
    `version` is what `initialize` reports; `warnings` is what it reports
    until an editor's settings say otherwise.
    Warnings.config? -> Module.sources -> [Module.lib_entry] -> string -> state *)
val create : ?warnings:Warnings.config -> Module.sources -> Module.lib_entry list -> string -> state

(** One JSON-RPC message received, as text, and the messages to send
    back, each as text: a request's response, and a log message where
    answering it failed. A change only marks documents due; `idle`
    checks them. state -> string -> (state, [string]) *)
val handle : state -> string -> state * string list

(** A publishDiagnostics notification for every document due to be
    checked, which this checks. Called once the editor has been quiet
    for a while. state -> (state, [string]) *)
val idle : state -> state * string list

(** The status to exit with, once `exit` has arrived: 0 after
    `shutdown`, 1 without. state -> int? *)
val exit_code : state -> int option

(** The server with the warnings it reports set, as an editor's
    `warnings` setting would set them, and every open document due to be
    checked again. state -> Warnings.config -> state *)
val with_warnings : state -> Warnings.config -> state
