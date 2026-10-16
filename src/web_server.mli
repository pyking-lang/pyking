(** A small static HTTP/1.1 server on localhost, which `pyk notebook`,
    `pyk playground` and `pyk serve` run in this process: what each
    serves is a `site`, URL paths mapped to files and directories where
    they sit and to answers worked out per request. One thread, with
    `select` over every connection, so a browser's idle speculative
    connection never holds up the files a page is waiting for. See
    docs/build.md ("The web tools").

    Data structures:
      site -- URL prefixes mapped to directories, URL paths to files, and
        URL paths to answers computed per request.

    Functions:
      serve site title port explicit lines -- serves a site until Ctrl+C. *)

(** What one tool serves. `mounts` maps a URL prefix ending in `/` to a
    directory, `files` an exact URL path to a file, `answers` an exact
    URL path to the function making its body and its content type, and
    `listing` says whether a directory with no index.html is listed. A
    path with a component starting with `.` names nothing. *)
type site = {
  mounts : (string * string) list;
  files : (string * string) list;
  answers : (string * ((unit -> string) * string)) list;
  listing : bool;
}

(** The port a tool serves on when none is asked for. int *)
val default_port : int

(** Serves a site on 127.0.0.1, or on $PYKING_WEB_HOST, and prints a link to it, with `lines`
    after it, until Ctrl+C: on `port` when `explicit`, else on the first
    free port of twenty from it. Answers why it could not listen.
    site -> string -> int -> bool -> [string] -> (unit, string) result *)
val serve : site -> string -> int -> bool -> string list -> (unit, string) result
