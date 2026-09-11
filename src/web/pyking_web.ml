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

(* Reaching a module implemented in JavaScript: the module's name, the
   field, and the arguments as a JSON array -- or the empty string for a
   value rather than a call. Answers the result as JSON. *)
external external_call : string -> string -> string -> string = "pyk_external"

(* The program's own files, which the page supplies rather than a
   directory: what lets a program of several modules run in a browser. *)
external file_exists : string -> string = "pyk_file_exists"
external file_read : string -> string = "pyk_file_read"

(* --- JSON ---
   Written out for every answer this module gives, and read back for the
   one thing that comes the other way: what an external module's
   JavaScript answered (see `externals` below). *)

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

(* --- values across the boundary ---

   What may cross is what a declaration may name: Int, String, Bool,
   unit, tuples and lists (docs/modules.md, "What may cross the
   boundary"). JSON carries all of them, with `null` for unit and an
   array for both a tuple and a list -- the declaration says which, so
   nothing is lost. *)

(** A Pyking value as JSON, for an argument crossing to JavaScript.
    Interpreter.value -> string *)
let rec json_of_value value =
  match value with
  | Interpreter.VInt n -> string_of_int n
  | Interpreter.VString text -> json_string text
  | Interpreter.VBool b -> json_bool b
  | Interpreter.VUnit -> "null"
  | Interpreter.VList elements | Interpreter.VTuple elements ->
      json_array (List.map json_of_value elements)
  | other ->
      raise
        (Interpreter.Trap
           ( Lexer.
               { file = "<external>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 },
             Printf.sprintf "%s cannot be passed to a module implemented in a target language"
               (Interpreter.describe other) ))

(** A JSON text as a Pyking value: what an external module answered.
    A number is an Int, an array a list, `null` unit. string -> value *)
let value_of_json text =
  let length = String.length text in
  let fail () =
    raise
      (Interpreter.Trap
         ( Lexer.{ file = "<external>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 },
           "a module implemented in a target language answered something \
            Pyking has no value for" ))
  in
  let rec skip i =
    if i < length && (text.[i] = ' ' || text.[i] = '\n' || text.[i] = '\t' || text.[i] = '\r')
    then skip (i + 1)
    else i
  in
  let literal i word = 
    let n = String.length word in
    i + n <= length && String.sub text i n = word
  in
  let rec value i =
    let i = skip i in
    if i >= length then fail ()
    else
      match text.[i] with
      | 'n' when literal i "null" -> (Interpreter.VUnit, i + 4)
      | 't' when literal i "true" -> (Interpreter.VBool true, i + 4)
      | 'f' when literal i "false" -> (Interpreter.VBool false, i + 5)
      | '"' -> string_at (i + 1) (Buffer.create 16)
      | '[' -> array_at (skip (i + 1)) []
      (* A tuple, which an array cannot say it is: stub.js writes one as
         {"pyk_tuple":[...]} so that the marker a list carries in
         JavaScript is not lost to JSON. *)
      | '{' -> tuple_at (i + 1)
      | c when c = '-' || (c >= '0' && c <= '9') -> number_at i
      | _ -> fail ()
  and number_at i =
    let j = ref i in
    if !j < length && text.[!j] = '-' then incr j;
    while !j < length && text.[!j] >= '0' && text.[!j] <= '9' do incr j done;
    (* A fraction or an exponent is not an Int, and Pyking has no other
       number, so it is refused rather than rounded. *)
    if !j < length && (text.[!j] = '.' || text.[!j] = 'e' || text.[!j] = 'E') then fail ();
    match int_of_string_opt (String.sub text i (!j - i)) with
    | Some n -> (Interpreter.VInt n, !j)
    | None -> fail ()
  and string_at i out =
    if i >= length then fail ()
    else
      match text.[i] with
      | '"' -> (Interpreter.VString (Buffer.contents out), i + 1)
      | '\\' ->
          if i + 1 >= length then fail ()
          else
            let c = text.[i + 1] in
            let next =
              match c with
              | 'n' -> "\n"
              | 't' -> "\t"
              | 'r' -> "\r"
              | '"' -> "\""
              | '\\' -> "\\"
              | '/' -> "/"
              | _ -> fail ()
            in
            Buffer.add_string out next;
            string_at (i + 2) out
      | c ->
          Buffer.add_char out c;
          string_at (i + 1) out
  and tuple_at i =
    let marker = "\"pyk_tuple\":" in
    let i = skip i in
    if not (literal i marker) then fail ()
    else
      let i = skip (i + String.length marker) in
      if i >= length || text.[i] <> '[' then fail ()
      else
        match array_at (skip (i + 1)) [] with
        | Interpreter.VList elements, j ->
            let j = skip j in
            if j < length && text.[j] = '}' then (Interpreter.VTuple elements, j + 1)
            else fail ()
        | _ -> fail ()
  and array_at i acc =
    let i = skip i in
    if i < length && text.[i] = ']' then (Interpreter.VList (List.rev acc), i + 1)
    else
      let element, i = value i in
      let i = skip i in
      if i < length && text.[i] = ',' then array_at (i + 1) (element :: acc)
      else if i < length && text.[i] = ']' then
        (Interpreter.VList (List.rev (element :: acc)), i + 1)
      else fail ()
  in
  fst (value 0)

(** How the interpreter reaches a module implemented in JavaScript: the
    page puts the imported modules in `pykExternals`, and this asks it
    for a value or calls one of its functions. Interpreter.externals *)
let externals =
  Interpreter.
    {
      field = (fun module_ field -> value_of_json (external_call module_ field ""));
      call =
        (fun module_ field args ->
          value_of_json
            (external_call module_ field
               (json_array (List.map json_of_value args))));
    }

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
    let program, tmap = Opt_tailcall.optimize program tmap in
    (Analyses.symbolize program, tmap)

(** The context a backend is given for a page that has one file: a
    program of one module, compiled exactly as it was before there were
    modules. string -> Module.context *)
let lone_context () =
  Module.
    {
      context_name = "";
      main = true;
      separate = false;
      starts = [];
      external_fields = [];
      sigmaps = [];
      externals = [];
    }

(** The program's files, as the module system reads them: supplied by
    the page rather than by a directory. Module.sources *)
let browser_sources =
  Module.{ exists = (fun name -> file_exists name = "1"); contents = file_read }

(** Runs a whole program -- the file named, and every module it reaches
    -- with the interpreter, in a browser. The sources come from the
    page (`pykSources`), and a module implemented in JavaScript is
    reached through `pykExternals`, so a program that imports one runs
    here where `pyk <file>` refuses it: this host really can call the
    target language. string -> string *)
let run_program main =
  match
    try
      let units = Module.load ~from:browser_sources main in
      (* The same sequence pyk.ml runs, module by module in dependency
         order: each is checked against what the ones it imports export,
         and an external module contributes what it declared. *)
      (* The tail-call pass builds nodes and so hands out more symbols;
         they continue past the highest in the whole program, since one
         numbering spans every module of it. pyk.ml does the same. *)
      let highest =
        List.fold_left
          (fun highest (unit : Module.t) ->
            max highest (Analyses.highest_sym unit.stmts))
          0 units
      in
      let _, _, checked =
        List.fold_left
          (fun (sigmaps, highest, checked) (unit : Module.t) ->
            if unit.is_external then
              ( sigmaps @ [ (unit.name, Module.external_sigmap unit.declarations) ],
                highest,
                checked @ [ unit ] )
            else
              let declared = Module.external_signatures unit.declarations in
              let tmap =
                Typesystem.type_check ~declared unit.stmts
                  (Module.sigmaps_for unit sigmaps)
              in
              Analyses.analyze_mutability unit.stmts;
              let sigmap =
                Module.module_sigmap unit.stmts unit.declarations tmap
              in
              let optimized, _ = Opt_tailcall.optimize unit.stmts tmap in
              (* Without this the nodes the pass built keep symbol 0,
                 and the interpreter's call-free table -- which is keyed
                 by symbol -- would answer for the wrong node. *)
              let optimized = Analyses.symbolize ~start:highest optimized in
              ( sigmaps @ [ (unit.name, sigmap) ],
                max highest (Analyses.highest_sym optimized),
                checked @ [ { unit with stmts = optimized } ] ))
          ([], highest, []) units
      in
      Ok checked
    with e -> Error e
  with
  | Error e -> (
      match front_end_error e with
      | Some (stage, info, message) -> failed stage info message
      (* Anything else is a bug in the compiler rather than in the
         program, but a page that stops answering is no way to find out,
         so it is reported like any other refusal. *)
      | None ->
          json_object
            [
              ("ok", json_bool false);
              ("stage", json_string "Internal error");
              ("text", json_string (Printexc.to_string e));
            ])
  | Ok checked -> (
      let host =
        Interpreter.callback_host ~externals (fun line -> emit (line ^ "\n"))
      in
      let state =
        Interpreter.run_modules
          (List.map
             (fun (unit : Module.t) ->
               (* The two halves stay apart: `apply_signatures` folds a
                  signature onto the definition it describes and drops
                  every one it cannot, which would empty a declaration. *)
               ( unit.name,
                 Analyses.apply_signatures unit.stmts,
                 unit.declarations ))
             checked)
          host
      in
      match Interpreter.failure state with
      | None -> json_object [ ("ok", json_bool true) ]
      | Some error ->
          let text =
            match front_end_error error with
            | Some (stage, info, message) ->
                Printf.sprintf "%s %s: %s" (Lexer.pprint_info info) stage message
            | None -> "Runtime error"
          in
          json_object
            [
              ("ok", json_bool false);
              ("stage", json_string "Runtime error");
              ("text", json_string text);
            ])

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
  let natively = Targets.family_of target = Targets.Ocaml in
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
          if Targets.family_of target = Targets.Python then
            done_
              [
                ( stem ^ ".py",
                  Target_python.pprint_py_program
                    (Target_python.translate_program program tmap)
                  ^ "\n" );
              ]
          else if List.mem (Targets.family_of target) [ Targets.Node; Targets.Web ]
          then
            let js, renames =
              Target_js_core.translate_program
                ~external_fields:(lone_context ()).external_fields
                ~externals:(lone_context ()).externals program
            in
            let out = stem ^ Targets.extension target in
            let unit =
              Module.
                {
                  name = stem;
                  path = name;
                  tokens = [];
                  stmts = program;
                  declarations = [];
                  declaration_path = None;
                  imports = [];
                  publics = [];
                  sigmap = None;
                  is_external = false;
                }
            in
            let files, _ =
              Target_js_packaging.package_program target
                [ (unit, js, renames) ]
                (Some out) false
            in
            done_ files
          else if Targets.family_of target = Targets.C then
            let c = Target_c.translate_program program (lone_context ()) in
            done_ [ (stem ^ ".c", Target_c.pprint_c_program c target name) ]
          else if Targets.family_of target = Targets.Java then
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
  (* Every target the compiler has, `pyking` first because it is what a
     reader looks at to see the front end's own answer. The list itself
     is src/targets.ml's, so the page cannot offer one the compiler does
     not have. *)
  json_array
    (List.map json_string
       ("pyking" :: List.filter (fun t -> t <> "pyking") Targets.all))

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
  register1 "pykRunProgram" run_program;
  register0 "pykTargets" targets_json;
  register0 "pykFormatHelper" format_helper;
  register0 "pykKeywords" (fun () ->
      json_array (List.map json_string Lexer.keywords));
  register0 "pykBuiltins" (fun () ->
      json_array (List.map json_string Builtin.names))
