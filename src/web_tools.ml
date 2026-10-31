(** `pyk notebook`, `pyk playground` and `pyk serve`: finds the web
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
    posts = [];
    listing = false;
  }

(** A site with more entries in front of another's, which win.
    Web_server.site -> Web_server.site -> Web_server.site *)
let extended (more : Web_server.site) (site : Web_server.site) : Web_server.site =
  {
    mounts = more.mounts @ site.mounts;
    files = more.files @ site.files;
    answers = more.answers @ site.answers;
    posts = more.posts @ site.posts;
    listing = site.listing || more.listing;
  }

(* --- the notebook --- *)

let ( let* ) = Result.bind

(** Whether a notebook is written as JSON. string -> bool *)
let is_json document = String.lowercase_ascii (Filename.extension document) = ".json"

(** The Markdown a .json notebook stands for, or why it is not one.
    string -> (string, string) result *)
let notebook_markdown document =
  match In_channel.with_open_bin document In_channel.input_all with
  | exception Sys_error message -> Error message
  | text -> (
      match Notebook_format.to_markdown (Json.parse text) with
      | markdown -> Ok markdown
      | exception Json.Parse_error message -> Error (Printf.sprintf "pyk notebook: %s is not JSON: %s" document message)
      | exception Notebook_format.Format_error message ->
          Error (Printf.sprintf "pyk notebook: %s is not a notebook: %s" document message))

(** Writes a picture a notebook made into its document's directory:
    `path` a .png file under `directory`, named by plain parts with no
    `..` and none hidden. Leaves a file already holding those bytes
    alone. string -> string -> string -> (unit, string) result *)
let save_picture directory path bytes =
  let parts = String.split_on_char '/' path in
  let plain part =
    part <> "" && part.[0] <> '.'
    && String.for_all (fun c -> match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true | _ -> false) part
  in
  if not (List.for_all plain parts) || not (Filename.check_suffix path ".png") then
    Error "only a .png file beside the notebook can be saved"
  else
    let file = List.fold_left Filename.concat directory parts in
    let same =
      Sys.file_exists file
      && In_channel.with_open_bin file In_channel.input_all = bytes
    in
    if same then Ok ()
    else if not (Sys.file_exists (Filename.dirname file)) then Error "no such directory"
    else
      try
        Out_channel.with_open_bin file (fun out -> Out_channel.output_string out bytes);
        Ok ()
      with Sys_error message -> Error message

(** What the notebook serves for one document in one mode: the page, its
    scripts, the document's directory under doc/, notebook.json, which
    also tells the page to reload when the document changes and where it
    saves a picture, and save/, where it does.
    string -> string -> Web_server.site *)
let notebook_site ?(warnings = []) document mode =
  let assets = under [ "tools"; "notebook"; "assets" ] in
  let index = Filename.concat assets "index.html" in
  (* A .json notebook is served as the Markdown it stands for, worked out
     again on every request so the page sees it change. *)
  let json = is_json document in
  let shown = if json then Filename.remove_extension (Filename.basename document) ^ ".md" else Filename.basename document in
  let converted () =
    match notebook_markdown document with
    | Ok text -> text
    | Error message -> "# This notebook could not be read\n\n" ^ message ^ "\n"
  in
  let config =
    json_object
      [
        ("document", json_string shown);
        ("mode", json_string mode);
        ("warnings", json_array (List.map json_string warnings));
        ("watch", "true");
        ("save", json_string "save/");
      ]
    ^ "\n"
  in
  extended
    {
      mounts = [ ("/notebook/", assets); ("/doc/", Filename.dirname document) ];
      files = [ ("/", index); ("/index.html", index) ];
      answers =
        [ ("/notebook.json", ((fun () -> config), "application/json")) ]
        @ (if json then [ ("/doc/" ^ shown, (converted, "text/markdown; charset=utf-8")) ] else []);
      posts = [ ("/save/", save_picture (Filename.dirname document)) ];
      listing = false;
    }
    (common_site ())

(** Checks a notebook with check.js under node and answers its exit
    status: a .json one as the Markdown it stands for, written to a file
    of its own for the run and reported under the name it was given.
    string -> string -> (int, string) result *)
let notebook_test document given =
  let check = under [ "tools"; "notebook"; "check.js" ] in
  let* markdown, shown =
    if is_json document then
      let* text = notebook_markdown document in
      let file = Filename.temp_file "pyk-notebook-" ".md" in
      Out_channel.with_open_bin file (fun out -> Out_channel.output_string out text);
      Ok (file, [| given |])
    else Ok (document, [||])
  in
  let arguments = Array.append [| "node"; check; markdown; bundle (); under [ "lib" ] |] shown in
  let finish result =
    if markdown <> document then (try Sys.remove markdown with Sys_error _ -> ());
    result
  in
  finish @@
  match Unix.create_process "node" arguments Unix.stdin Unix.stdout Unix.stderr with
  | exception Unix.Unix_error _ ->
      Error "pyk notebook --mode test runs the notebook's code under node, and node was not found."
  | pid -> (
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED 127 ->
          Error "pyk notebook --mode test runs the notebook's code under node, and node was not found."
      | Unix.WEXITED status -> Ok status
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Ok 1)

(* --- a notebook's prose, for `pyk highlight` --- *)

(* What renders the prose: markdown.js's renderMarkdown, under node, as
   the notebook's page renders it. The Markdown is read from the file
   named second, and {html, title} is printed. *)
let render_script =
  "import fs from 'node:fs';\n\
   import { pathToFileURL } from 'node:url';\n\
   const [renderer, input] = process.argv.slice(1);\n\
   const { renderMarkdown } = await import(pathToFileURL(renderer).href);\n\
   const rendered = renderMarkdown(fs.readFileSync(input, 'utf8'));\n\
   process.stdout.write(JSON.stringify({ html: rendered.html, title: rendered.title }));\n"

let render_markdown markdown =
  let refuse =
    "--notebook whole renders the prose with the notebook's own renderer, which runs under node, and node was not found"
  in
  let renderer = under [ "tools"; "notebook"; "assets"; "markdown.js" ] in
  if not (Sys.file_exists renderer) then Error (Printf.sprintf "no notebook renderer at %s" renderer)
  else
    let input = Filename.temp_file "pyk-highlight-" ".md" in
    let output = Filename.temp_file "pyk-highlight-" ".json" in
    let clean () = List.iter (fun f -> try Sys.remove f with Sys_error _ -> ()) [ input; output ] in
    Out_channel.with_open_bin input (fun out -> Out_channel.output_string out markdown);
    let result =
      let out = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let arguments = [| "node"; "--input-type=module"; "-e"; render_script; renderer; input |] in
      let ran =
        match Unix.create_process "node" arguments Unix.stdin out Unix.stderr with
        | exception Unix.Unix_error _ -> Error refuse
        | pid -> (
            match snd (Unix.waitpid [] pid) with
            | Unix.WEXITED 0 -> Ok ()
            | Unix.WEXITED 127 -> Error refuse
            | _ -> Error "the notebook's renderer failed under node")
      in
      Unix.close out;
      let* () = ran in
      match Json.parse (In_channel.with_open_bin output In_channel.input_all) with
      | exception Json.Parse_error message -> Error ("the notebook's renderer answered no JSON: " ^ message)
      | value ->
          let field name = Option.value ~default:"" (Json.to_string_option (Json.member name value)) in
          Ok (field "html", field "title")
    in
    clean ();
    result

let notebook_stylesheet () =
  match In_channel.with_open_bin (under [ "tools"; "notebook"; "assets"; "notebook.css" ]) In_channel.input_all with
  | text -> text
  | exception Sys_error _ -> ""

(* --- the playground --- *)

(** The targets the page offers, in the order its menu shows them, each
    with its label, the Ace mode its output is shown in, and how the page
    runs it, if it can. iweb is left out: the page already runs the
    interpreter. Kept in step with tools/playground/playground.py by
    tests/test_notebook.py. [(string, string, string, string?)] *)
let playground_targets =
  [
    ("pyking", "Pyking (the front end's own output)", "text", None);
    ("python12", "Python 3.12", "python", None);
    ("python14", "Python 3.14", "python", None);
    ("node22", "JavaScript - node 22 (ES2020)", "javascript", Some "module");
    ("node24", "JavaScript - node 24 (ES2024)", "javascript", Some "module");
    ("web2020", "JavaScript - web (ES2020)", "html", Some "module");
    ("web2024", "JavaScript - web (ES2024)", "html", Some "module");
    ("c89", "C89", "c_cpp", None);
    ("c99", "C99", "c_cpp", None);
    ("c23", "C23", "c_cpp", None);
    ("java8", "Java 8", "java", None);
    ("java17", "Java 17", "java", None);
    ("java21", "Java 21", "java", None);
    ("ocaml4.14", "OCaml 4.14", "ocaml", None);
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
      posts = [];
      listing = false;
    }
    (common_site ())

(* --- the help --- *)

(** What `pyk pykhelp` serves: the help's own page at the root.
    () -> Web_server.site *)
let help_site () =
  let index = under [ "tools"; "help"; "assets"; "index.html" ] in
  extended
    { mounts = []; files = [ ("/", index); ("/index.html", index) ]; answers = []; posts = []; listing = false }
    (common_site ())

(* --- starting one --- *)

(** Serves a site, answering 0 when it was stopped. Web_server.site ->
    string -> int option -> [string] -> (int, string) result *)
let serve ?page site title port lines =
  let chosen = Option.value ~default:Web_server.default_port port in
  Result.map (fun () -> 0) (Web_server.serve ?page site title chosen (port <> None) lines)

let start ?(warnings = []) tool port mode path =
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
          { mounts = [ ("/", directory) ]; files = []; answers = []; posts = []; listing = true }
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
      else if extension <> ".md" && extension <> ".markdown" && extension <> ".json" then
        Error (Printf.sprintf "pyk notebook: %s is not a Markdown file (.md) or a notebook's JSON (.json)" given)
      else
        let* () = if is_json document then Result.map (fun _ -> ()) (notebook_markdown document) else Ok () in
        let* () = check_bundle "pyk notebook" in
        if mode = "test" then notebook_test document given
        else
          let* () = check_vendor "pyk notebook" in
          serve (notebook_site ~warnings document mode) "Pyking notebook" port
            [ Printf.sprintf "Notebook: %s (%s mode)" document mode; "" ]
