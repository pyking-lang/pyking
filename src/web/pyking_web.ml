(** The browser-side entry point to the Pyking compiler: the same stages
    pyk.ml runs, exposed as functions the page can call and answering
    JSON strings rather than reading argv or touching a filesystem.
    Compiled to JavaScript by js_of_ocaml (see docs/build.md and
    tools/playground/README.md).

    The boundary is four functions on the global object, registered by
    the primitives in stub.js:

      pykCompile(source, target, name)  compile, as JSON
      pykRun(source, name)              run with the interpreter, as JSON
      pykTargets()                      the targets, as JSON
      pykFormatHelper()                 the JS value formatter's source
      pykKeywords() / pykBuiltins()     the language's own word lists

    A running program's output goes to `pykOnPrint`, one line at a time
    as it is produced, so output made before a program hangs is still
    seen -- which is the case worth seeing.

    Functions:
      compile_source source target name -- compile, as a JSON string.
      run_source source name -- run, as a JSON string.
      targets_json () / format_helper () -- what the page reads out of
        the compiler rather than guessing at. *)

external register0 : string -> (unit -> string) -> unit = "pyk_register0"
external register1 : string -> (string -> string) -> unit = "pyk_register1"

external register3 : string -> (string -> string -> string -> string) -> unit
  = "pyk_register3"

external emit : string -> unit = "pyk_emit"

(* --- JSON, written out ---
   Nothing here needs to read JSON, so this is an encoder and no more. *)

let json_string s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let json_object pairs =
  "{"
  ^ String.concat ","
      (List.map (fun (key, value) -> json_string key ^ ":" ^ value) pairs)
  ^ "}"

let json_array items = "[" ^ String.concat "," items ^ "]"
let json_int n = string_of_int n
let json_bool b = if b then "true" else "false"

(* --- the compiler's answers --- *)

(** A refusal as data: the line the CLI would print, plus the raw span so
    the editor can underline it. Rows are 1-based and columns 0-based,
    exactly as Lexer.info records them.
    string -> info -> string -> string *)
let failed stage (info : Lexer.info) message =
  json_object
    [
      ("ok", json_bool false);
      ("stage", json_string stage);
      ("message", json_string message);
      ( "text",
        json_string
          (Printf.sprintf "%s %s: %s" (Lexer.pprint_info info) stage message) );
      ( "info",
        json_object
          [
            ("row1", json_int info.row1);
            ("col1", json_int info.col1);
            ("row2", json_int info.row2);
            ("col2", json_int info.col2);
          ] );
    ]

(** The stage label each front-end error is reported under, the same
    words pyk.ml uses. exn -> (string, info, string) option *)
let front_end_error error =
  match error with
  | Lexer.Lex_error (info, message) -> Some ("Lexing error", info, message)
  | Parser.Parse_error (info, message) -> Some ("Parsing error", info, message)
  | Module.Module_error (info, message) -> Some ("Module error", info, message)
  | Analyses.Analysis_error (info, message) -> Some ("Name error", info, message)
  | Typesystem.Type_error (info, message) -> Some ("Type error", info, message)
  | Interpreter.Runtime_error (info, message) ->
      Some ("Runtime error", info, message)
  | _ -> None

(** The stem a generated file is named from: the source name without its
    extension. string -> string *)
let stem_of name = Filename.remove_extension name

(** The front end, as far as every target needs it: the program the
    checker accepted, with the types it worked out and the loops the
    tail-call pass built. Raises the front end's own errors.
    string -> string -> bool -> ([stmt], typ IntMap.t) *)
let front_end source name natively =
  let program =
    Parser.parse (Lexer.lexing name (Lexer.chars_of_string source))
  in
  let program = Analyses.symbolize program in
  (* The half of the module system that needs only this file: what it
     exports, and that it exports one thing under one name. The other
     half reads files the page does not have, and an `import` is refused
     by the checker below for exactly that reason. *)
  ignore (Module.check_publics program);
  (* Pyking is statically typed: this is not a mode. The checker carries
     a name environment of its own, so an unbound name is reported here
     too -- as the name error it is (pyk.ml draws the same line). *)
  let tmap = Typesystem.type_check program [] in
  (* The one rule types do not state: only a `var` may be written to. *)
  Analyses.analyze_mutability program;
  (* Tail calls become loops before any backend reads the program, so
     the page shows what `pyk compile` would produce. OCaml is the
     exception it is in pyk.ml: that host eliminates them itself, so the
     pass would only be undone (docs/optimization.md). *)
  if natively then (program, tmap)
  else
    let program, tmap = Optimization.optimize program tmap in
    (Analyses.symbolize program, tmap)

(** The context a backend is given for a page that has one file: a
    program of one module, compiled exactly as it was before there were
    modules. string -> Module.context *)
let lone_context () =
  Module.
    { context_name = ""; main = true; separate = false; starts = []; sigmaps = [] }

(** Compile `source` for `target`.
    Answers `{"ok":true,"files":{label:source},"views":[label,...]}` --
    several files for `esm`, which really does emit four -- or a refusal
    as `failed` builds it. Never raises for a bad program, and never
    touches a filesystem. string -> string -> string -> string *)
let compile_source source target name =
  let done_ ?(views = []) files =
    json_object
      [
        ("ok", json_bool true);
        ( "files",
          json_object
            (List.map (fun (label, text) -> (label, json_string text)) files) );
        ("views", json_array (List.map json_string views));
      ]
  in
  let natively = target = Target_ocaml.target in
  match front_end source name natively with
  | exception e -> (
      match front_end_error e with
      | Some (stage, info, message) -> failed stage info message
      | None -> raise e)
  | program, tmap -> (
      let stem = stem_of name in
      try
        if target = "pyking" then
          (* Pyking back out again: the AST every backend starts from,
             printed against `tmap`, so what it shows is what the checker
             inferred. Such a file is listed in `views`: it is what the
             front end *saw*, not code any host could run. *)
          let out = stem ^ ".pyking.pyk" in
          done_ ~views:[ out ]
            [ (out, Syntax.pprint_program program false (Some tmap)) ]
        else
          (* A `def name : type` line is another spelling of the
             annotations a header could carry, so it is folded onto the
             header before any backend reads the program -- after the
             `pyking` view above, which shows it as it stands. pyk.ml
             does the same. *)
          let program = Analyses.apply_signatures program in
          if target = "python" then
            done_
              [
                ( stem ^ ".py",
                  Target_python.pprint_py_program
                    (Target_python.translate_program program tmap)
                  ^ "\n" );
              ]
          else if List.mem target Target_js_packaging.targets then
            let js = Target_js_core.translate_program program in
            let out =
              stem ^ List.assoc target Target_js_packaging.primary_extensions
            in
            let unit =
              Module.
                {
                  name = stem;
                  path = name;
                  tokens = [];
                  stmts = program;
                  imports = [];
                  publics = [];
                  sigmap = None;
                }
            in
            let files, _ =
              Target_js_packaging.package_program target [ (unit, js) ]
                (Some out) false
            in
            done_ files
          else if List.mem target Target_c.standards then
            let c = Target_c.translate_program program (lone_context ()) in
            done_ [ (stem ^ ".c", Target_c.pprint_c_program c target name) ]
          else if List.mem target Target_java.versions then
            (* Java requires the file and its public class to share a
               name. *)
            let cls = Target_java.default_class_name stem in
            let j = Target_java.translate_program program (lone_context ()) in
            done_
              [
                ( cls ^ ".java",
                  Target_java.pprint_java_program j target cls name );
              ]
          else if target = Target_ocaml.target then
            (* The one backend that infers nothing: it reads the types
               back out of `tmap`. *)
            let o = Target_ocaml.translate_program program tmap (lone_context ()) in
            done_
              [
                ( stem ^ Target_ocaml.extension,
                  Target_ocaml.pprint_ocaml_program o name );
              ]
          else
            json_object
              [
                ("ok", json_bool false);
                ("stage", json_string "Usage error");
                ( "message",
                  json_string (Printf.sprintf "unknown target '%s'" target) );
                ( "text",
                  json_string
                    (Printf.sprintf "Usage error: unknown target '%s'" target) );
              ]
      with
      (* Each backend raises its own refusal; all of them carry an info,
         so all of them underline in the editor like any other error. *)
      | Target_js_core.Unsupported (info, message)
      | Target_c.Unsupported (info, message)
      | Target_java.Unsupported (info, message)
      | Target_ocaml.Unsupported (info, message) ->
          failed (Printf.sprintf "Unsupported by target '%s'" target) info message)

(** Run `source` with the interpreter, printing each line through
    `pykOnPrint` as it is produced. Answers `{"ok":true}`, a refusal in
    `compile_source`'s own shape (so the page underlines it the same
    way), or `{"ok":false,"text":...}` for a runtime error.
    string -> string -> string *)
let run_source source name =
  match front_end source name false with
  | exception e -> (
      match front_end_error e with
      | Some (stage, info, message) -> failed stage info message
      | None -> raise e)
  | program, _ -> (
      let program = Analyses.apply_signatures program in
      let host = Interpreter.callback_host (fun line -> emit (line ^ "\n")) in
      let state = Interpreter.run_program program host in
      match Interpreter.failure state with
      | None -> json_object [ ("ok", json_bool true) ]
      | Some error ->
          let text =
            match front_end_error error with
            | Some (stage, info, message) ->
                Printf.sprintf "%s %s: %s" (Lexer.pprint_info info) stage message
            | None -> "Runtime error"
          in
          let trace =
            List.map
              (fun (function_name, info) ->
                Printf.sprintf "  in '%s', called at %s" function_name
                  (Lexer.pprint_info info))
              (Interpreter.stack_trace state)
          in
          json_object
            [
              ("ok", json_bool false);
              ("text", json_string (String.concat "\n" (text :: trace)));
            ])

(** Every target the compiler has, in the order the dropdown shows them
    (pyking first). () -> string *)
let targets_json () =
  json_array
    (List.map json_string
       ([ "pyking"; "python" ]
       @ Target_js_packaging.targets
       @ Target_c.standards @ Target_java.versions
       @ [ Target_ocaml.target ]))

(** The `pykFormat` helper the JavaScript backend generates, read out of
    the backend rather than hand-copied. () -> string *)
let format_helper () = Target_js_packaging.format_js

let () =
  register3 "pykCompile" compile_source;
  register1 "pykRun" (fun request ->
      (* One string in, so the name travels with the source: the first
         line is the file name the errors are reported against, the rest
         is the program. *)
      match String.index_opt request '\n' with
      | None -> run_source request "playground.pyk"
      | Some i ->
          run_source
            (String.sub request (i + 1) (String.length request - i - 1))
            (String.sub request 0 i));
  register0 "pykTargets" targets_json;
  register0 "pykFormatHelper" format_helper;
  register0 "pykKeywords" (fun () ->
      json_array (List.map json_string Lexer.keywords));
  register0 "pykBuiltins" (fun () ->
      json_array (List.map json_string Analyses.builtins))
