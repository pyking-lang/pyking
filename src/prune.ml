(** What a program uses of the modules it imports: every module but the
    program's own with the definitions nothing reaches taken out, and
    every import narrowed to the names the importing module uses. Run by
    pyk.ml for the C and Java targets only, which compile a subset of the
    language and would otherwise refuse a library for a function the
    program never calls -- `sys.env_get`, which walks a list, keeps
    `sys.exit` out of C. See docs/modules.md, "What a program uses".

    A definition is kept when an importer names it, when a statement at
    the module's top level does, or when a kept definition does. Every
    top-level statement that is not a definition is kept: it runs when
    the module does. The test is by name, so a local that happens to
    share a definition's name keeps that definition too -- which costs
    output and never correctness.

    Functions:
      program units -- every module of a program, dependencies first,
        with what the program does not use removed. *)

open Syntax

module SSet = Set.Make (String)

(** The plain names and the qualified `alias.field` pairs a statement
    sequence mentions. [stmt] -> (SSet, [(string, string)]) *)
let references stmts =
  Walk.fold_stmts
    (fun (names, qualified) node ->
      match node with
      | Walk.NExpr (EVar (_, name, _)) -> (SSet.add name names, qualified)
      | Walk.NExpr (EQualified (_, alias, field, _)) ->
          (names, (alias, field) :: qualified)
      | _ -> (names, qualified))
    (SSet.empty, []) stmts

(** The name a top-level definition or signature binds, or None for any
    other statement. stmt -> string option *)
let defined statement =
  match statement with
  | SFunctionDef (_, name, _, _, _, _, _, _, _) | SFunctionSig (_, name, _, _, _) ->
      Some name
  | _ -> None

(** The definitions of stmts that `roots` reach, closed over what each
    kept definition's body names. [stmt] -> SSet -> SSet *)
let reached stmts roots =
  let bodies =
    List.filter_map
      (fun statement ->
        match statement with
        | SFunctionDef (_, name, _, _, _, _, _, _, _) -> Some (name, [ statement ])
        | _ -> None)
      stmts
  in
  let rec close kept pending =
    match pending with
    | [] -> kept
    | name :: rest ->
        let names, _ =
          match List.assoc_opt name bodies with
          | Some body -> references body
          | None -> (SSet.empty, [])
        in
        let fresh = SSet.elements (SSet.diff names kept) in
        close (SSet.union kept names) (rest @ fresh)
  in
  close roots (SSet.elements roots)

(** A module's statements with only what `roots` and its own top level
    reach. [stmt] -> SSet -> [stmt] *)
let kept_statements stmts roots =
  let top_level, _ =
    references (List.filter (fun statement -> defined statement = None) stmts)
  in
  let kept = reached stmts (SSet.union roots top_level) in
  List.filter
    (fun statement ->
      match defined statement with
      | Some name -> SSet.mem name kept
      | None -> true)
    stmts

(** Each import narrowed to the names the module uses of it: a field of a
    plain import where `alias.field` is written, and a name a `from` line
    takes where it is named. Answers the imports and, per module
    imported, the fields used. [stmt] -> ([stmt], [(string, SSet)]) *)
let narrowed_imports stmts =
  let names, qualified = references stmts in
  let note module_ field used =
    let held = Option.value (List.assoc_opt module_ used) ~default:SSet.empty in
    (module_, SSet.add field held) :: List.remove_assoc module_ used
  in
  let stmts, used =
    List.fold_left
      (fun (stmts, used) statement ->
        match statement with
        | SImport (info, module_, local, selected, fields, sym) ->
            let fields =
              List.filter
                (fun (exported, name) ->
                  if selected then SSet.mem name names
                  else List.mem (local, exported) qualified)
                fields
            in
            let used =
              List.fold_left
                (fun used (exported, _) -> note module_ exported used)
                used fields
            in
            (stmts @ [ SImport (info, module_, local, selected, fields, sym) ], used)
        | statement -> (stmts @ [ statement ], used))
      ([], []) stmts
  in
  (stmts, used)

(** Every module of a program, dependencies first and the program's own
    last, with the definitions nothing reaches removed from each module
    it imports and every import narrowed to what is used of it.
    [(Module.t, 'a)] -> [(Module.t, 'a)] *)
let program units =
  let count = List.length units in
  (* From the program's own module back to the first it imports, so a
     module is pruned only once everything that imports it has said what
     it needs. *)
  let _, pruned =
    List.fold_left
      (fun (needed, pruned) (index, ((unit : Module.t), extra)) ->
        let stmts =
          if index = count - 1 then unit.stmts
          else
            kept_statements unit.stmts
              (Option.value (List.assoc_opt unit.name needed) ~default:SSet.empty)
        in
        let stmts, used = narrowed_imports stmts in
        let needed =
          List.fold_left
            (fun needed (module_, fields) ->
              let held =
                Option.value (List.assoc_opt module_ needed) ~default:SSet.empty
              in
              (module_, SSet.union held fields) :: List.remove_assoc module_ needed)
            needed used
        in
        (needed, ({ unit with stmts }, extra) :: pruned))
      ([], [])
      (List.rev (List.mapi (fun index unit -> (index, unit)) units))
  in
  pruned
