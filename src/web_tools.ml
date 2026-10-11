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

type tool = Notebook | Playground | Files

(** The directory the installation's tree is in: the repository in a
    checkout, the package's root in a distribution. () -> string *)
let root () = Install.root ()

(** A path under the installation's tree. [string] -> string *)
let under parts = List.fold_left Filename.concat (root ()) parts

(** The compiler bundle the pages run. () -> string *)
let bundle () = under [ "build"; "pyking.js" ]

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
      ("note", json_string "build/pyking.js, built from src/ by dune");
    ]
  ^ "\n"

(** What every tool serves: the shared scripts, the vendored libraries,
    the compiler bundle and the standard library. () -> Web_server.site *)
let common_site () : Web_server.site =
  {
    mounts =
      [
        ("/webrun/", under [ "tools"; "webrun"; "assets" ]);
        ("/vendor/", vendor ());
        ("/lib/", under [ "lib" ]);
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

(** A case of tests/test_cases.toml: its file, targets, modules and libs. *)
type case = { file : string; targets : string list; modules : string list; libs : string list }

(** The strings written in a TOML value. string -> [string] *)
let quoted value =
  let rec go i acc =
    match String.index_from_opt value i '"' with
    | None -> List.rev acc
    | Some start -> (
        match String.index_from_opt value (start + 1) '"' with
        | None -> List.rev acc
        | Some stop -> go (stop + 1) (String.sub value (start + 1) (stop - start - 1) :: acc))
  in
  go 0 []

(** The cases of tests/test_cases.toml: each `[[cases]]` table's
    `file`, `targets`, `modules` and `libs`, an array allowed to span
    lines. string -> [case] *)
let read_cases text =
  let strip line =
    match String.index_opt line '#' with Some i -> String.sub line 0 i | None -> line
  in
  let lines = List.map (fun l -> String.trim (strip l)) (String.split_on_char '\n' text) in
  let empty = { file = ""; targets = []; modules = []; libs = [] } in
  let set case key value =
    match key with
    | "file" -> { case with file = (match quoted value with f :: _ -> f | [] -> "") }
    | "targets" -> { case with targets = quoted value }
    | "modules" -> { case with modules = quoted value }
    | "libs" -> { case with libs = quoted value }
    | _ -> case
  in
  let balanced value =
    let count c = List.length (List.filter (( = ) c) (List.of_seq (String.to_seq value))) in
    count '[' <= count ']'
  in
  let rec go lines current acc =
    match lines with
    | [] -> List.rev (match current with Some c -> c :: acc | None -> acc)
    | "[[cases]]" :: rest ->
        go rest (Some empty) (match current with Some c -> c :: acc | None -> acc)
    | line :: rest -> (
        match (current, String.index_opt line '=') with
        | Some case, Some i ->
            let key = String.trim (String.sub line 0 i) in
            let rec gather value rest =
              if balanced value then (value, rest)
              else match rest with next :: more -> gather (value ^ " " ^ next) more | [] -> (value, [])
            in
            let value, rest = gather (String.sub line (i + 1) (String.length line - i - 1)) rest in
            go rest (Some (set case key value)) acc
        | _ -> go rest current acc)
  in
  go lines None []

(** The tests/ directory, which a checkout has and a package does not.
    () -> string *)
let tests () = under [ "tests" ]

(** Which tests/*.pyk the page offers and on which targets, from
    tests/test_cases.toml: a program of several modules, or one using a
    library, is left out, since the page compiles one file. Each is
    (file, targets, universal). () -> [(string, [string], bool)] *)
let offered_examples () =
  let manifest = Filename.concat (tests ()) "test_cases.toml" in
  match Module.read_whole_file manifest with
  | exception Sys_error _ -> []
  | text ->
      let cases = read_cases text in
      let code = List.map (fun (t, _, _, _) -> t) playground_targets in
      let skipped =
        List.filter_map (fun c -> if c.modules <> [] || c.libs <> [] then Some c.file else None) cases
        @ List.concat_map (fun c -> c.modules) cases
      in
      let known = List.filter (fun c -> not (List.mem c.file skipped)) cases in
      let declared = List.sort_uniq compare (List.concat_map (fun c -> c.targets) known) in
      let every = List.filter (fun t -> List.mem t code) declared in
      let files =
        List.sort compare
          (List.filter
             (fun f -> Filename.check_suffix f ".pyk")
             (try Array.to_list (Sys.readdir (tests ())) with Sys_error _ -> []))
      in
      List.filter_map
        (fun file ->
          if List.mem file skipped then None
          else
            let claimed =
              match List.find_opt (fun c -> c.file = file) known with
              | Some c -> c.targets
              | None -> [ "python" ]
            in
            let targets = List.filter (fun t -> List.mem t code) claimed in
            Some (file, targets, targets <> [] && List.length targets = List.length every))
        files

(** What the playground page is driven by: the targets, how each is shown
    and run, and the examples. Worked out per request. () -> string *)
let playground_manifest () =
  let examples =
    List.map
      (fun (file, targets, universal) ->
        json_object
          [
            ("file", json_string file);
            ("name", json_string (String.map (fun c -> if c = '_' then ' ' else c) (Filename.remove_extension file)));
            ("targets", json_array (List.map json_string targets));
            ("universal", if universal then "true" else "false");
          ])
      (offered_examples ())
  in
  json_object
    [
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
    each offered example from tests/. () -> Web_server.site *)
let playground_site () =
  let assets = under [ "tools"; "playground"; "assets" ] in
  let index = Filename.concat assets "index.html" in
  let examples =
    List.map
      (fun (file, _, _) -> ("/examples/" ^ file, Filename.concat (tests ()) file))
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

(* --- starting one --- *)

(** Serves a site, answering 0 when it was stopped. Web_server.site ->
    string -> int option -> [string] -> (int, string) result *)
let serve site title port lines =
  let chosen = Option.value ~default:Web_server.default_port port in
  Result.map (fun () -> 0) (Web_server.serve site title chosen (port <> None) lines)

let ( let* ) = Result.bind

let start tool port mode path =
  match tool with
  | Files ->
      let directory = Module.absolute (Option.value ~default:"." path) in
      if not (Sys.file_exists directory && Sys.is_directory directory) then
        Error (Printf.sprintf "pyk serve: no such directory: %s" (Option.value ~default:"." path))
      else
        serve
          { mounts = [ ("/", directory) ]; files = []; answers = []; listing = true }
          directory port []
  | Playground ->
      let* () = check_bundle "pyk playground" in
      let* () = check_vendor "pyk playground" in
      serve (playground_site ()) "Pyking playground" port []
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
