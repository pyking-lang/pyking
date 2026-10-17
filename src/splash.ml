(** tinyweb's splash screen, called where a program would otherwise
    start a sound no browser lets it play: a program any of whose
    modules can call tinyweb's `play` or `play_file` gets a call to
    `tinyweb.splash()` as the last statement of its own top level, and
    an import of tinyweb where it has none. Pyking AST in, Pyking AST
    out, run by `module.ml`'s `load` before the modules are made ready,
    so the call is checked and compiled like one the program wrote. See
    docs/libraries.md, "The splash screen".

    Functions:
      program name file modules main -- the main module's statements, with
        the call added where the program can play. *)

open Syntax

(** The module whose sounds need the splash. *)
let library = "tinyweb"

(** The library's functions that start a sound. *)
let players = [ "play"; "play_file" ]

(** The names one module reaches tinyweb by with a plain import.
    [stmt] -> [string] *)
let aliases stmts =
  List.filter_map
    (fun statement ->
      match statement with
      | SImport (_, name, local, false, _, _) when name = library -> Some local
      | _ -> None)
    stmts

(** Whether one module can call a function that starts a sound: it names
    one through a plain import of tinyweb, or takes one with `from`.
    [stmt] -> bool *)
let plays stmts =
  let reached = aliases stmts in
  List.exists
    (fun statement ->
      match statement with
      | SImport (_, name, _, true, fields, _) when name = library ->
          List.exists (fun (field, _) -> List.mem field players) fields
      | _ -> false)
    stmts
  || reached <> []
     && Walk.exists_stmts
          (fun node ->
            match node with
            | Walk.NExpr (EQualified (_, local, field, _)) ->
                List.mem local reached && List.mem field players
            | _ -> false)
          stmts

(** A name for the import this pass adds that the module does not use
    already: `tinyweb`, else `tinyweb2`, `tinyweb3`, ... [stmt] -> string *)
let fresh_alias stmts =
  let used =
    Walk.fold_stmts
      (fun used node ->
        match (node, Walk.name_field node) with
        | Walk.NStmt (SImport (_, _, local, _, fields, _)), _ ->
            (local :: List.map snd fields) @ used
        | _, Some name -> name :: used
        | _, None -> used)
      [] stmts
  in
  let rec pick n =
    let name = if n = 1 then library else library ^ string_of_int n in
    if List.mem name used then pick (n + 1) else name
  in
  pick 1

(** Where the added statements are said to be: the end of the module's
    last statement, or the start of `file` where it has none.
    string -> [stmt] -> info *)
let end_of file stmts =
  match List.rev stmts with
  | last :: _ ->
      let i = stmt_info last in
      { i with row1 = i.row2; col1 = i.col2 }
  | [] -> { Lexer.file; row1 = 1; col1 = 1; row2 = 1; col2 = 1 }

(** The main module's statements, with `tinyweb.splash()` added as the
    last of them where any module of the program can play a sound -- and
    an import of tinyweb first where the main module has no plain one.
    `modules` is every module of the program by name, the main one among
    them, and `file` the main module's path.
    string -> string -> [(string, [stmt])] -> [stmt] -> [stmt] *)
let program name file modules main =
  let playing =
    List.exists
      (fun (module_name, stmts) -> module_name <> library && plays stmts)
      modules
  in
  if name = library || not playing then main
  else
    let at = end_of file main in
    let alias, main =
      match aliases main with
      | alias :: _ -> (alias, main)
      | [] ->
          let alias = fresh_alias main in
          (alias, SImport (at, library, alias, false, [], 0) :: main)
    in
    let call =
      ECall (at, EQualified (at, alias, "splash", 0), [], 0)
    in
    main @ [ SExprStmt (at, call, 0) ]
