(** `pyk notebook`, `pyk playground` and `pyk serve`: finds the web
    tools beside this executable, works out what each serves, and serves
    it with web_server.ml in this process -- nothing else has to be
    installed. `pyk notebook --mode test` serves nothing and runs
    tools/notebook/check.js under node instead. See docs/build.md ("The
    web tools").

    Data structures:
      tool -- which web tool.

    Functions:
      start tool port mode path -- serves the tool, or answers why not. *)

type tool = Notebook | Playground | Help | Files

(** The directory the installation's tree is in: the repository in a
    checkout, the package's root in a distribution. () -> string *)
let root () = Install.root ()

(** A path under the installation's tree. [string] -> string *)
let under parts = List.fold_left Filename.concat (root ()) parts

(** The compiler bundle the pages run. () -> string *)
let bundle () = under [ "share"; "pyking.js" ]

(** The vendored browser libraries. () -> string *)
let vendor () = under [ "tools"; "webrun"; "vendor" ]

(** The modes the notebook may be opened in; the first is the default. *)
let modes = [ "student"; "teacher"; "test" ]

(** Text as a JSON string. string -> string *)
let json_string text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    text;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(** A JSON object from its fields, already encoded. [(string, string)] -> string *)
let json_object fields =
  "{" ^ String.concat ", " (List.map (fun (k, v) -> json_string k ^ ": " ^ v) fields) ^ "}"

(** A JSON array from its items, already encoded. [string] -> string *)
let json_array items = "[" ^ String.concat ", " items ^ "]"

(** Refuses where the compiler bundle is missing. string -> (unit, string) result *)
let check_bundle command =
  if Sys.file_exists (bundle ()) then Ok ()
  else
    Error
      (Printf.sprintf
         "%s: no compiler bundle at %s. `make` in the repository builds it; a \
          distribution ships it."
         command (bundle ()))

(** Refuses where the browser libraries were not downloaded, unless
    $PYKING_WEB_NO_VENDOR says the pages will not be rendered.
    string -> (unit, string) result *)
let check_vendor command =
  let wanted =
    [
      [ "ace"; "ace.js" ];
      [ "katex"; "katex.min.js" ];
      [ "katex"; "katex.min.css" ];
      [ "monaco"; "vs"; "loader.js" ];
      [ "monaco"; "vs"; "editor"; "editor.main.js" ];
    ]
  in
  let missing =
    List.filter (fun parts -> not (Sys.file_exists (List.fold_left Filename.concat (vendor ()) parts))) wanted
  in
  match Sys.getenv_opt "PYKING_WEB_NO_VENDOR" with
  | Some v when v <> "" -> Ok ()
  | _ when missing = [] -> Ok ()
  | _ ->
      Error
        (Printf.sprintf
           "%s: the browser libraries are not downloaded (nothing in %s). Run \
            `make vendor` in the repository once; it needs the network."
           command (vendor ()))

(** What the page's compiler worker boots from: the bundle's name and a
    stamp of its bytes, which the page re-reads to notice a rebuild under
    an open tab. () -> string *)
let bundle_manifest () =
  let stamp = String.sub (Digest.to_hex (Digest.file (bundle ()))) 0 16 in
  json_object
    [
      ("bundle", json_string "pyking.js");
      ("stamp", json_string stamp);
      ("note", json_string "share/pyking.js, built from src/ by dune");
    ]
  ^ "\n"

(** Refuses where the help's pages were not generated.
    string -> (unit, string) result *)
let check_help command =
  if Sys.file_exists (under [ "share"; "help"; "index.json" ]) then Ok ()
  else
    Error
      (Printf.sprintf
         "%s: the help is not generated (no %s). `make` in the repository \
          writes it; a distribution ships it."
         command (under [ "share"; "help" ]))

(** What every tool serves: the shared scripts, the vendored libraries,
    the compiler bundle, the standard library, the notebook's scripts
    (which run a cell anywhere), and the help: its page and scripts
    under /help/, and its generated pages under /help/pages/.
    () -> Web_server.site *)
let common_site () : Web_server.site =
  {
    mounts =
      [
        ("/webrun/", under [ "tools"; "webrun"; "assets" ]);
        ("/vendor/", vendor ());
        ("/lib/", under [ "lib" ]);
        ("/notebook/", under [ "tools"; "notebook"; "assets" ]);
        ("/help/", under [ "tools"; "help"; "assets" ]);
        ("/help/pages/", under [ "share"; "help" ]);
      ];
    files = [ ("/pyking/pyking.js", bundle ()) ];
    answers = [ ("/pyking/manifest.json", (bundle_manifest, "application/json")) ];
    listing = false;
  }

(** A site with more entries in front of another's, which win.
    Web_server.site -> Web_server.site -> Web_server.site *)
let extended (more : Web_server.site) (site : Web_server.site) : Web_server.site =
  {
    mounts = more.mounts @ site.mounts;
    files = more.files @ site.files;
    answers = more.answers @ site.answers;
    listing = site.listing || more.listing;
  }

(* --- the notebook --- *)

(** What the notebook serves for one document in one mode: the page, its
    scripts, the document's directory under doc/, and notebook.json.
    string -> string -> Web_server.site *)
let notebook_site document mode =
  let assets = under [ "tools"; "notebook"; "assets" ] in
  let index = Filename.concat assets "index.html" in
  let config =
    json_object [ ("document", json_string (Filename.basename document)); ("mode", json_string mode) ]
    ^ "\n"
  in
  extended
    {
      mounts = [ ("/notebook/", assets); ("/doc/", Filename.dirname document) ];
      files = [ ("/", index); ("/index.html", index) ];
      answers = [ ("/notebook.json", ((fun () -> config), "application/json")) ];
      listing = false;
    }
    (common_site ())

(** Checks a notebook with check.js under node and answers its exit
    status. string -> (int, string) result *)
let notebook_test document =
  let check = under [ "tools"; "notebook"; "check.js" ] in
  let arguments = [| "node"; check; document; bundle (); under [ "lib" ] |] in
  match Unix.create_process "node" arguments Unix.stdin Unix.stdout Unix.stderr with
  | exception Unix.Unix_error _ ->
      Error "pyk notebook --mode test runs the notebook's code under node, and node was not found."
  | pid -> (
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED 127 ->
          Error "pyk notebook --mode test runs the notebook's code under node, and node was not found."
      | Unix.WEXITED status -> Ok status
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Ok 1)

(* --- the playground --- *)

(** The targets the page offers, in the order its menu shows them, each
    with its label, the Ace mode its output is shown in, and how the page
    runs it, if it can. iweb24 is left out: the page already runs the
    interpreter. Kept in step with tools/playground/playground.py by
    tests/test_notebook.py. [(string, string, string, string?)] *)
let playground_targets =
  [
    ("pyking", "Pyking (the front end's own output)", "text", None);
    ("python14", "Python 3.14", "python", None);
    ("node24", "JavaScript - node 24", "javascript", Some "module");
    ("web24", "JavaScript - web (ES2024)", "html", Some "module");
    ("c89", "C89", "c_cpp", None);
    ("c99", "C99", "c_cpp", None);
    ("c23", "C23", "c_cpp", None);
    ("java8", "Java 8", "java", None);
    ("java17", "Java 17", "java", None);
    ("java21", "Java 21", "java", None);
    ("ocaml5.5", "OCaml 5.5", "ocaml", None);
  ]

(** The examples the page offers: src/examples.toml beside this
    executable, or none where it is missing. () -> [Examples.example] *)
let offered_examples () =
  try Examples.read (Module.read_whole_file (under [ Examples.file ])) with Sys_error _ -> []

(** What the playground page is driven by: the version, the targets, how
    each is shown and run, and the examples. Worked out per request.
    () -> string *)
let playground_manifest () =
  let examples =
    List.map
      (fun (e : Examples.example) ->
        json_object [ ("file", json_string e.name); ("description", json_string e.description) ])
      (offered_examples ())
  in
  json_object
    [
      ("version", json_string Version.version);
      ( "targets",
        json_array
          (List.map
             (fun (name, label, _, _) -> json_object [ ("name", json_string name); ("label", json_string label) ])
             playground_targets) );
      ("modes", json_object (List.map (fun (name, _, mode, _) -> (name, json_string mode)) playground_targets));
      ( "run",
        json_object
          (List.filter_map
             (fun (name, _, _, run) -> Option.map (fun r -> (name, json_string r)) run)
             playground_targets) );
      ("examples", json_array examples);
    ]
  ^ "\n"

(** What the playground serves: its page and scripts, the manifest, and
    each offered example under the name it is offered by.
    () -> Web_server.site *)
let playground_site () =
  let assets = under [ "tools"; "playground"; "assets" ] in
  let index = Filename.concat assets "index.html" in
  let examples =
    List.map
      (fun (e : Examples.example) -> ("/examples/" ^ e.name, under [ e.source ]))
      (offered_examples ())
  in
  extended
    {
      mounts = [ ("/assets/", assets) ];
      files = [ ("/", index); ("/index.html", index) ] @ examples;
      answers = [ ("/assets/playground.json", (playground_manifest, "application/json")) ];
      listing = false;
    }
    (common_site ())

(* --- the help --- *)

(** What `pyk pykhelp` serves: the help's own page at the root.
    () -> Web_server.site *)
let help_site () =
  let index = under [ "tools"; "help"; "assets"; "index.html" ] in
  extended
    { mounts = []; files = [ ("/", index); ("/index.html", index) ]; answers = []; listing = false }
    (common_site ())

(* --- starting one --- *)

(** Serves a site, answering 0 when it was stopped. Web_server.site ->
    string -> int option -> [string] -> (int, string) result *)
let serve ?page site title port lines =
  let chosen = Option.value ~default:Web_server.default_port port in
  Result.map (fun () -> 0) (Web_server.serve ?page site title chosen (port <> None) lines)

let ( let* ) = Result.bind

let start tool port mode path =
  match tool with
  | Files ->
      (* A file is served from its directory, and the link printed is
         the file's own -- what `--run` on a page target prints. *)
      let given = Module.absolute (Option.value ~default:"." path) in
      let directory, page =
        if Sys.file_exists given && not (Sys.is_directory given) then
          (Module.dirname given, Filename.basename given)
        else (given, "")
      in
      if not (Sys.file_exists directory && Sys.is_directory directory) then
        Error (Printf.sprintf "pyk serve: no such directory: %s" (Option.value ~default:"." path))
      else
        serve ~page
          { mounts = [ ("/", directory) ]; files = []; answers = []; listing = true }
          directory port []
  | Playground ->
      let* () = check_bundle "pyk playground" in
      let* () = check_vendor "pyk playground" in
      serve (playground_site ()) "Pyking playground" port []
  | Help ->
      let* () = check_bundle "pyk pykhelp" in
      let* () = check_vendor "pyk pykhelp" in
      let* () = check_help "pyk pykhelp" in
      serve (help_site ()) "Pyking help" port []
  | Notebook ->
      let given = Option.value ~default:"" path in
      let document = Module.absolute given in
      let extension = String.lowercase_ascii (Filename.extension document) in
      let mode = Option.value ~default:(List.hd modes) mode in
      if not (Sys.file_exists document) || Sys.is_directory document then
        Error (Printf.sprintf "pyk notebook: no such file: %s" given)
      else if extension <> ".md" && extension <> ".markdown" then
        Error (Printf.sprintf "pyk notebook: %s is not a Markdown file (.md)" given)
      else
        let* () = check_bundle "pyk notebook" in
        if mode = "test" then notebook_test document
        else
          let* () = check_vendor "pyk notebook" in
          serve (notebook_site document mode) "Pyking notebook" port
            [ Printf.sprintf "Notebook: %s (%s mode)" document mode; "" ]
