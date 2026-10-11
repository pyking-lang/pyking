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
      resolve site path -- the file or directory a URL path names.
      serve site title port explicit lines -- serves a site until Ctrl+C. *)

type site = {
  mounts : (string * string) list;
  files : (string * string) list;
  answers : (string * ((unit -> string) * string)) list;
  listing : bool;
}

(** The port a tool serves on when none is asked for. int *)
let default_port = 8000

(** A URL path with its %XX escapes decoded and its query dropped.
    string -> string *)
let decode target =
  let path = match String.index_opt target '?' with Some i -> String.sub target 0 i | None -> target in
  let path = match String.index_opt path '#' with Some i -> String.sub path 0 i | None -> path in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let n = String.length path in
  let rec go i acc =
    if i >= n then String.concat "" (List.rev acc)
    else if path.[i] = '%' && i + 2 < n then
      match (hex path.[i + 1], hex path.[i + 2]) with
      | Some a, Some b -> go (i + 3) (String.make 1 (Char.chr ((a * 16) + b)) :: acc)
      | _ -> go (i + 1) ("%" :: acc)
    else go (i + 1) (String.make 1 path.[i] :: acc)
  in
  go 0 []

(** Whether s starts with prefix. string -> string -> bool *)
let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let resolve site path =
  match List.assoc_opt path site.files with
  | Some file -> Some file
  | None ->
      let parts = List.filter (fun p -> p <> "") (String.split_on_char '/' path) in
      if List.exists (fun p -> p.[0] = '.' || String.contains p '\\') parts then None
      else
        let longest =
          List.fold_left
            (fun best (prefix, directory) ->
              if starts_with prefix path then
                match best with
                | Some (p, _) when String.length p >= String.length prefix -> best
                | _ -> Some (prefix, directory)
              else best)
            None site.mounts
        in
        Option.map
          (fun (prefix, directory) ->
            let rest =
              List.filter (fun p -> p <> "")
                (String.split_on_char '/'
                   (String.sub path (String.length prefix)
                      (String.length path - String.length prefix)))
            in
            List.fold_left Filename.concat directory rest)
          longest

(** The content type a file is served with, by its suffix.
    string -> string *)
let content_type path =
  match String.lowercase_ascii (Filename.extension path) with
  | ".html" | ".htm" -> "text/html; charset=utf-8"
  | ".js" | ".mjs" | ".cjs" -> "text/javascript; charset=utf-8"
  | ".css" -> "text/css; charset=utf-8"
  | ".json" -> "application/json"
  | ".md" | ".markdown" -> "text/markdown; charset=utf-8"
  | ".svg" -> "image/svg+xml"
  | ".png" -> "image/png"
  | ".jpg" | ".jpeg" -> "image/jpeg"
  | ".gif" -> "image/gif"
  | ".ico" -> "image/x-icon"
  | ".wav" -> "audio/wav"
  | ".mp3" -> "audio/mpeg"
  | ".ogg" -> "audio/ogg"
  | ".woff2" -> "font/woff2"
  | ".woff" -> "font/woff"
  | ".ttf" -> "font/ttf"
  | ".wasm" -> "application/wasm"
  | ".pdf" -> "application/pdf"
  | ".txt" | ".pyk" | ".py" | ".ml" | ".mli" | ".c" | ".h" | ".java" | ".out" | ".in" ->
      "text/plain; charset=utf-8"
  | _ -> "application/octet-stream"

(** The whole of a file, or None where it cannot be read.
    string -> string option *)
let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () -> Some (really_input_string channel (in_channel_length channel)))
  with Sys_error _ | End_of_file -> None

(** Text with the characters HTML gives a meaning escaped.
    string -> string *)
let escape_html text =
  String.concat ""
    (List.map
       (fun c ->
         match c with
         | '&' -> "&amp;"
         | '<' -> "&lt;"
         | '>' -> "&gt;"
         | '"' -> "&quot;"
         | c -> String.make 1 c)
       (List.of_seq (String.to_seq text)))

(** A page listing a directory's entries, for a URL path ending in `/`.
    string -> string -> string *)
let listing path directory =
  let names = try Array.to_list (Sys.readdir directory) with Sys_error _ -> [] in
  let names = List.sort compare (List.filter (fun n -> n.[0] <> '.') names) in
  let item name =
    let shown = if Sys.is_directory (Filename.concat directory name) then name ^ "/" else name in
    Printf.sprintf "<li><a href=\"%s\">%s</a></li>\n" (escape_html shown) (escape_html shown)
  in
  Printf.sprintf
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>%s</title></head>\n\
     <body><h1>%s</h1>\n<ul>\n%s</ul></body></html>\n"
    (escape_html path) (escape_html path)
    (String.concat "" (List.map item names))

(** A response: status, reason, headers and body. *)
type response = { status : int; reason : string; headers : (string * string) list; body : string }

(** A response with no special headers. int -> string -> string -> string -> response *)
let plain status reason kind body =
  { status; reason; headers = [ ("Content-Type", kind) ]; body }

(** What a GET of a URL path answers. site -> string -> response *)
let respond site path =
  let not_found = plain 404 "Not Found" "text/plain; charset=utf-8" "404 Not Found\n" in
  match List.assoc_opt path site.answers with
  | Some (make, kind) -> plain 200 "OK" kind (make ())
  | None -> (
      match resolve site path with
      | None -> not_found
      | Some file when Sys.file_exists file && Sys.is_directory file ->
          if path = "" || path.[String.length path - 1] <> '/' then
            { status = 301; reason = "Moved Permanently";
              headers = [ ("Location", path ^ "/") ]; body = "" }
          else
            let index = Filename.concat file "index.html" in
            if Sys.file_exists index then
              match read_file index with
              | Some body -> plain 200 "OK" (content_type index) body
              | None -> not_found
            else if site.listing then plain 200 "OK" "text/html; charset=utf-8" (listing path file)
            else not_found
      | Some file -> (
          match if Sys.file_exists file then read_file file else None with
          | Some body -> plain 200 "OK" (content_type file) body
          | None -> not_found))

(** The bytes sent for a response, with the body left out for a HEAD.
    string -> response -> bool -> bool -> string *)
let encode path response head keep =
  (* The vendored libraries are version-pinned and may be cached; the
     rest is served from where it is edited and must not be. *)
  let cache = if starts_with "/vendor/" path then "public, max-age=86400" else "no-store" in
  let headers =
    response.headers
    @ [
        ("Content-Length", string_of_int (String.length response.body));
        ("Cache-Control", cache);
        ("Connection", if keep then "keep-alive" else "close");
      ]
  in
  Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n%s" response.status response.reason
    (String.concat "" (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") headers))
    (if head then "" else response.body)

(** Where the blank line ending a request's head is, if it has arrived.
    string -> int option *)
let head_end text =
  let rec go i =
    if i + 3 >= String.length text then None
    else if String.sub text i 4 = "\r\n\r\n" then Some (i + 4)
    else go (i + 1)
  in
  go 0

(** A request head's method, target, version and headers (names in lower
    case), or None where it is not one. string -> (string, string, string,
    [(string, string)])? *)
let parse_head head =
  match String.split_on_char '\n' head with
  | [] -> None
  | first :: rest -> (
      let header line =
        let line = String.trim line in
        match String.index_opt line ':' with
        | Some i ->
            Some
              ( String.lowercase_ascii (String.sub line 0 i),
                String.trim (String.sub line (i + 1) (String.length line - i - 1)) )
        | None -> None
      in
      match List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.trim first)) with
      | [ meth; target; version ] -> Some (meth, target, version, List.filter_map header rest)
      | _ -> None)

(** Writes all of text to a socket. Unix.file_descr -> string -> () *)
let write_all fd text =
  let bytes = Bytes.unsafe_of_string text in
  let rec go offset =
    if offset < Bytes.length bytes then
      go (offset + Unix.write fd bytes offset (Bytes.length bytes - offset))
  in
  go 0

(** Answers every whole request in what a connection has sent, and says
    what is left over and whether the connection stays open.
    site -> Unix.file_descr -> string -> (string, bool) *)
let rec answer site fd pending =
  match head_end pending with
  | None -> (pending, String.length pending < 65536)
  | Some stop -> (
      let head = String.sub pending 0 stop in
      match parse_head head with
      | None ->
          write_all fd (encode "" (plain 400 "Bad Request" "text/plain" "400 Bad Request\n") false false);
          ("", false)
      | Some (meth, target, version, headers) ->
          let length =
            match List.assoc_opt "content-length" headers with
            | Some n -> ( try int_of_string n with Failure _ -> 0)
            | None -> 0
          in
          if String.length pending < stop + length then (pending, true)
          else
            let rest = String.sub pending (stop + length) (String.length pending - stop - length) in
            let connection = String.lowercase_ascii (Option.value ~default:"" (List.assoc_opt "connection" headers)) in
            let keep = if version = "HTTP/1.0" then connection = "keep-alive" else connection <> "close" in
            let path = decode target in
            let response =
              match meth with
              | "GET" | "HEAD" -> respond site path
              | _ -> plain 501 "Not Implemented" "text/plain" "501 Not Implemented\n"
            in
            write_all fd (encode path response (meth = "HEAD") keep);
            if keep then answer site fd rest else ("", false))

(** A socket listening on 127.0.0.1: on port itself when it was asked for
    explicitly, else on the first free one of twenty from it.
    int -> bool -> (Unix.file_descr * int, string) result *)
let listen port explicit =
  let tries = if explicit then 1 else 20 in
  let rec go p =
    if p >= port + tries then
      Error
        (if explicit then Printf.sprintf "serve: port %d is in use" port
         else Printf.sprintf "serve: no free port in %d..%d" port (port + tries - 1))
    else
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      match
        Unix.setsockopt socket Unix.SO_REUSEADDR true;
        Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, p));
        Unix.listen socket 64
      with
      | () -> Ok (socket, p)
      | exception Unix.Unix_error _ ->
          Unix.close socket;
          go (p + 1)
  in
  go port

(** Closes a socket, ignoring a socket already gone. Unix.file_descr -> () *)
let close fd = try Unix.close fd with Unix.Unix_error _ -> ()

(** Serves forever: accepts connections and answers what each has sent,
    with each connection's unanswered bytes threaded through as a value.
    site -> Unix.file_descr -> () *)
let run site listener =
  let buffer = Bytes.create 65536 in
  let rec loop clients =
    let ready, _, _ =
      try Unix.select (listener :: List.map fst clients) [] [] (-1.0)
      with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
    in
    let accepted =
      if List.mem listener ready then
        match Unix.accept ~cloexec:true listener with
        | fd, _ -> [ (fd, "") ]
        | exception Unix.Unix_error _ -> []
      else []
    in
    let step (fd, pending) =
      if not (List.mem fd ready) then Some (fd, pending)
      else
        match Unix.read fd buffer 0 (Bytes.length buffer) with
        | 0 ->
            close fd;
            None
        | n -> (
            match answer site fd (pending ^ Bytes.sub_string buffer 0 n) with
            | rest, true -> Some (fd, rest)
            | _, false ->
                close fd;
                None
            | exception Unix.Unix_error _ ->
                close fd;
                None)
        | exception Unix.Unix_error _ ->
            close fd;
            None
    in
    loop (List.filter_map step clients @ accepted)
  in
  loop []

let serve site title port explicit lines =
  match listen port explicit with
  | Error message -> Error message
  | Ok (listener, port) -> (
      (* A browser closing a connection mid-reply must not end the server. *)
      if not Sys.win32 then Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      Sys.catch_break true;
      print_newline ();
      Printf.printf "  %s is being served.\n\n" title;
      Printf.printf "      http://localhost:%d/\n\n" port;
      List.iter (fun line -> Printf.printf "  %s\n" line) lines;
      print_string
        "  Open that link in a browser (ctrl/cmd-click it in most\n\
        \  terminals). Press Ctrl+C to stop.\n\n";
      flush stdout;
      (try run site listener with Sys.Break -> print_string "\nserve: stopped.\n");
      Ok ())
