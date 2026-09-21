(** The OCaml code-generation backend. Unlike the other backends, it
    infers no types of its own: it reads translated expressions' types
    out of the checker's tmap, which pyk.ml fills and hands it -- so a
    program that does not type-check is refused before translation
    begins. Its subset is nearly all of what typesystem.ml accepts, less
    a short list of shapes OCaml cannot be given, each refused with a
    source position (docs/target_ocaml.md, "What is not supported"). It
    is also the one target compiled from the program as *written*: OCaml
    eliminates tail calls itself, so pyk.ml skips opt_tailcall.ml here
    rather than have a rewrite this module would only undo.
    See docs/target_ocaml.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      oexpr / oitem / obinding / opattern -- the OCaml AST.
      oprogram -- a translated module.
      ctx -- what a translation reads: the checker's types, the names
        plan, and the scopes it is inside.
      acc -- what a translation accumulates: the temporaries handed out
        and which preludes are wanted.

    Functions:
      translate_program stmts tmap context -- translates a whole module.
      pprint_ocaml_program program source -- the module as OCaml source.
      pprint_ocaml_interface program source -- the `.mli` a module the
        program imports is seen through. *)

open Lexer
open Syntax

(* The one OCaml target; its name is src/targets.ml's. *)
let target = List.hd (Targets.members Targets.Ocaml)
let extension = ".ml"

(* What a module the program imports says it exports, beside its own
   implementation. It is the whole of privacy on this target: a name not
   named here cannot be reached from outside the file. *)
let interface_extension = ".mli"

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of info * string

(* Raised where a `return` leaves a loop whose value is wanted where it
   stands: `function_binding` answers it by translating the body again
   with an escape in scope (docs/target_ocaml.md, "Leaving a function
   early"). *)
exception Needs_escape

(** Raises Unsupported at info with message. info -> string -> 'a *)
let unsupported info message = raise (Unsupported (info, message))

module SMap = Map.Make (String)

(* --- the OCaml AST ---

   OCaml is an expression language, so this is much smaller than the C,
   Java or Python ASTs: a block of Pyking statements becomes *one*
   expression, and the only statement-shaped thing left is the top
   level. *)

(** What a binding binds: a name, or a tuple taken apart. *)
type opattern = OPatName of string | OPatTuple of opattern list

type oexpr =
  | OInt of int
  | OFloat of float
  | OStr of string
  | OBool of bool
  | OUnit
  | OVar of string (* a name, already mangled *)
  | OApp of oexpr * oexpr list (* f x y *)
  | OTuple of oexpr list
  | OList of oexpr list
  | ONeg of string * oexpr (* `-` on an int, `-.` on a float *)
  | OMatch of oexpr * (string * oexpr option * oexpr) list
      (* the arms are (pattern text, body), in source order *)
  | OFun of (string * oexpr) list
      (* OCaml's `function`: a lambda that matches its one argument *)
  | OLambda of opattern list * oexpr (* fun x y -> body *)
  | OBin of string * oexpr * oexpr
  | OIf of oexpr * oexpr * oexpr option
  | OLet of obinding list * oexpr * bool (* let a = x and b = y in body *)
  | OSeq of oexpr * oexpr (* first; rest *)
  | ORef of oexpr (* ref e -- a mutable cell holding e *)
  | ODeref of string (* !x -- reading one *)
  | OAssign of string * oexpr (* x := e -- writing one *)
  | OIgnore of oexpr (* ignore (expr) *)
  | OEscape of string * string * string * oexpr
      (* a function body a `return` leaves early: the exception it is
         left by, the cell the value is put in, the name the value comes
         back under, and the body *)

and obinding = { bound : opattern; params : opattern list; value : oexpr }

(** One top-level definition. *)
type oitem = OItemLet of obinding list * bool | OItemUnit of oexpr

(** A translated module: its items, which of the generated prelude's
    printers the program uses, the module's own name, whether it is the
    program's own module (which nothing imports and so which has no
    interface), and each exported OCaml name with its type as the `.mli`
    writes them. *)
type oprogram = {
  items : oitem list;
  needs_list_printer : bool;
  needs_quote : bool;
  needs_float : bool;
  needs_range : bool;
  program_name : string;
  main : bool;
  interface : (string * string) list;
}

(* --- names ---

   An OCaml value name must start lowercase or underscore, and must not
   be a keyword; both are fixed by mangling, only when needed. See
   docs/target_ocaml.md, "Names".

   `_` is in the list because OCaml's is the wildcard pattern rather
   than a name: `let _ = 2` binds nothing and `_` is not an expression.
   It is an ordinary Pyking name, so it is mangled like any other word
   OCaml has taken. *)
let reserved =
  List.fold_left
    (fun set name -> StringSet.add name set)
    StringSet.empty
    (String.split_on_char ' '
       "and as assert asr begin class constraint do done downto else end \
        exception external false for fun function functor if in include \
        inherit initializer land lazy let lor lsl lsr lxor match method mod \
        module mutable new nonrec object of open or private rec sig struct \
        then to true try type val virtual when while with _")

(** name as a legal OCaml value name, before collisions are resolved.
    string -> string *)
let mangle_base name =
  if StringSet.mem name reserved then name ^ "_"
  else if String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' then
    "v_" ^ name
  else name

(** The OCaml name a module's public `name` is compiled under. A pure
    function of the name alone, unlike the names plan: the module that
    imports it must spell it the same without having seen the module it
    comes from. string -> string *)
let public_name name =
  let base = mangle_base name in
  if StringSet.mem base reserved then base ^ "2" else base

(** Every identifier used anywhere in a program. [stmt] -> StringSet.t *)
let collect_identifiers stmts =
  Walk.fold_stmts
    (fun found node ->
      match Walk.name_field node with
      | Some name -> StringSet.add name found
      | None -> found)
    StringSet.empty stmts

(** Chooses one OCaml name per Pyking name in stmts, so that no two of
    them land on the same one. A name OCaml already accepts keeps its own
    spelling; the rest take the first free `base`, `base2`, ... An
    exported name is settled first and by `public_name` alone, since the
    module that imports it spells it without seeing this one.
    [stmt] -> [string] -> string SMap.t *)
let plan_names stmts exported =
  let used = collect_identifiers stmts in
  let marked = Module.public_names stmts in
  let plan, taken =
    List.fold_left
      (fun (plan, taken) name ->
        let settled = public_name name in
        if StringSet.mem settled taken then
          unsupported
            (stmt_info (List.assoc name marked))
            (Printf.sprintf
               "'%s' and another name this module exports are both '%s' in \
                OCaml; give one of them another name"
               name settled)
        else (SMap.add name settled plan, StringSet.add settled taken))
      (SMap.empty, StringSet.empty) exported
  in
  (* A name that needs no change is settled next, so that the ones that
     do are what move out of the way -- keeping generated OCaml as close
     to the source's own spelling as it can be. *)
  let unchanged =
    StringSet.filter
      (fun n ->
        (not (SMap.mem n plan)) && mangle_base n = n && not (StringSet.mem n taken))
      used
  in
  let taken = StringSet.union taken unchanged in
  let plan = StringSet.fold (fun name plan -> SMap.add name name plan) unchanged plan in
  let rest =
    List.sort compare
      (StringSet.elements (StringSet.filter (fun n -> not (SMap.mem n plan)) used))
  in
  let plan, _ =
    List.fold_left
      (fun (plan, taken) name ->
        let base = mangle_base name in
        let rec go candidate suffix =
          if StringSet.mem candidate taken || StringSet.mem candidate reserved then
            go (Printf.sprintf "%s%d" base (suffix + 1)) (suffix + 1)
          else candidate
        in
        let candidate = go base 1 in
        (SMap.add name candidate plan, StringSet.add candidate taken))
      (plan, taken) rest
  in
  plan

(** The OCaml module a Pyking module is compiled to: OCaml names a module
    after its file, capitalised. string -> string *)
let ocaml_module name =
  if name = "" then name
  else String.make 1 (Char.uppercase_ascii name.[0]) ^ String.sub name 1 (String.length name - 1)

(** How a public name of another module is written here.
    string -> string -> string *)
let reached module_name field =
  Printf.sprintf "%s.%s" (ocaml_module module_name) (public_name field)

(** Every name a `from` line brings in, mapped to the OCaml name it reads
    as: a value of the module that exports it, reached through that
    module. Nothing is bound here for it -- the name simply means the
    other module's. [stmt] -> [(string, string)] *)
let imported_names external_fields stmts =
  List.concat_map
    (fun statement ->
      match statement with
      | SImport (_, name, _, true, fields, _) ->
          List.map
            (fun (exported, local) ->
              ( local,
                reached
                  (Module.reached_module external_fields name exported)
                  exported ))
            fields
      | _ -> [])
    stmts

(** A prefix no name in the program starts with, for the temporaries that
    fix evaluation order (docs/target_ocaml.md, "Evaluation order").
    [stmt] -> string *)
let unused_prefix stmts =
  let names = collect_identifiers stmts in
  let rec go prefix =
    if
      StringSet.exists
        (fun name ->
          String.length name >= String.length prefix
          && String.sub name 0 (String.length prefix) = prefix)
        names
    then go (prefix ^ "_")
    else prefix
  in
  go "tmp"

(* --- reading the checker's types --- *)

let is_int t = match t with TInt _ -> true | _ -> false
let is_float t = match t with TFloat _ -> true | _ -> false
let is_string t = match t with TString _ -> true | _ -> false
let is_bool t = match t with TBool _ -> true | _ -> false
let is_unit t = match t with TTuple (_, [], _) -> true | _ -> false

let is_list t = match t with TList _ -> true | _ -> false

(** t as it would be written in source. typ -> string *)
let name_of t = pprint_type default_config t

(** Whether an `all` appears anywhere inside a type -- the mark of
    polymorphism OCaml will not infer for a parameter. typ -> bool *)
let rec has_forall type_ =
  match type_ with
  | TForall _ -> true
  | TList (_, element, _) -> has_forall element
  | TTuple (_, elements, _) -> List.exists has_forall elements
  | TFunction (_, params, result, _, _, _, _) ->
      List.exists has_forall params || has_forall result
  | _ -> false

(* --- binding patterns ---

   A binding or a parameter is either a name or a tuple taken apart, and
   the three things done to one -- reading its names, printing it, and
   underscoring what nothing reads -- are the same either way. *)

(** Every name a binding pattern binds. opattern -> [string] *)
let rec pattern_names pattern =
  match pattern with
  | OPatName name -> [ name ]
  | OPatTuple parts -> List.concat_map pattern_names parts

(** A binding pattern as OCaml source text. opattern -> string *)
let rec pattern_text pattern =
  match pattern with
  | OPatName name -> name
  | OPatTuple parts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map pattern_text parts))

(** pattern with every name nothing in used reads renamed _name.
    opattern -> StringSet.t -> opattern *)
let rec pattern_polished pattern used =
  match pattern with
  | OPatTuple parts ->
      OPatTuple (List.map (fun part -> pattern_polished part used) parts)
  | OPatName name ->
      if StringSet.mem name used || (String.length name > 0 && name.[0] = '_') then
        pattern
      else OPatName ("_" ^ name)

(** A bound name as OCaml should spell it: `_name` where the body never
    reads it, so that a warning-free build stays warning-free.
    string -> StringSet.t option -> string *)
let unread name used =
  match used with
  | None -> name
  | Some used -> if StringSet.mem name used then name else "_" ^ name

(* --- free variables of the generated OCaml ---

   Every question this backend asks about names -- is this group
   recursive, does this function reach one written further down -- is a
   question about free variables, answered on the OCaml AST since that
   is where the binders are explicit. *)

let union_all sets = List.fold_left StringSet.union StringSet.empty sets

(** Every name e reads from outside itself. oexpr -> StringSet.t *)
let rec free e =
  match e with
  | OInt _ | OFloat _ | OStr _ | OBool _ | OUnit -> StringSet.empty
  | OVar name -> StringSet.singleton name
  | OIgnore e | ORef e -> free e
  | ODeref name -> StringSet.singleton name
  | OAssign (name, value) -> StringSet.add name (free value)
  | OApp (func, args) -> union_all (free func :: List.map free args)
  | OTuple elements | OList elements -> union_all (List.map free elements)
  | ONeg (_, operand) -> free operand
  | OMatch (subject, arms) ->
      (* An arm's own bindings are its pattern's, and a pattern is
         printed text by the time it is here -- so what an arm reads from
         outside is over-reported rather than under-reported, which is
         the safe direction for `let rec` grouping. *)
      union_all
        (free subject
        :: List.map
             (fun (_, guard, b) ->
               match guard with
               | None -> free b
               | Some guard -> StringSet.union (free guard) (free b))
             arms)
  | OFun arms -> union_all (List.map (fun (_, b) -> free b) arms)
  | OLambda (params, body) ->
      StringSet.diff (free body)
        (union_all
           (List.map (fun p -> StringSet.of_list (pattern_names p)) params))
  | OBin (_, left, right) -> StringSet.union (free left) (free right)
  | OIf (cond, then_, else_) ->
      let found = StringSet.union (free cond) (free then_) in
      (match else_ with None -> found | Some e -> StringSet.union found (free e))
  | OSeq (first, rest) -> StringSet.union (free first) (free rest)
  | OEscape (_, cell, _, inner) -> StringSet.remove cell (free inner)
  | OLet (bindings, body, recursive) ->
      let names =
        union_all
          (List.map (fun b -> StringSet.of_list (pattern_names b.bound)) bindings)
      in
      let values = union_all (List.map free_in_binding bindings) in
      let values = if recursive then StringSet.diff values names else values in
      StringSet.union values (StringSet.diff (free body) names)

(** A binding's free names: its value's, less its own parameters.
    obinding -> StringSet.t *)
and free_in_binding binding =
  let bound =
    union_all
      (List.map (fun p -> StringSet.of_list (pattern_names p)) binding.params)
  in
  StringSet.diff (free binding.value) bound

(** Whether a block always leaves what it is in -- a function by a
    `return`, a loop by a `break` or a `continue`. [stmt] -> bool *)
let rec definitely_exits stmts =
  match List.rev stmts with
  | last :: _ -> (
      match last with
      | SReturn _ | SReturnStmt _ | SBreak _ | SContinue _ -> true
      | SIf (_, _, then_body, else_body, _) -> (
          match else_body with
          | None -> false
          | Some else_body ->
              definitely_exits then_body && definitely_exits else_body)
      | _ -> false)
  | [] -> false

(* --- translation --- *)

(** One `loop` being translated: the local function that is the loop,
    what a `break`/`continue` uses, whether the loop was written with an
    accumulator at all, and whether the loop is the function's own
    value. *)
type oloop = {
  loop_name : string;
  loop_accumulator : oexpr;
  carries : bool;
  returning : bool;
  (* What is left of a `for`'s sequence, which the next turn walks on
     from; nothing for a loop written without one. *)
  walking : oexpr option;
}

(** Where a block's value goes: a function's, nowhere, or the
    accumulator the next turn of a loop carries. *)
type position = Tail | Effect | InLoop of oloop

(** What a translation reads. *)
type ctx = {
  tmap : typ IntMap.t;
  printing : Analyses.effects;
  prefix : string;
  (* The names currently declared `var`, which are OCaml `ref`s: a read
     of one is `!x` rather than `x`. Pyking refuses to shadow a `var`,
     so a name in here means the same cell wherever it is read. *)
  refs : StringSet.t;
  (* The `loop`s being translated, innermost last. *)
  loops : oloop list;
  (* What each definition's type variables turned out to be, and those
     of the one being translated now. *)
  specialisations : (string * typ) list IntMap.t;
  specialised : (string * typ) list;
  (* The exception a `return` raises to leave the function it is in, and
     the cell it leaves its value in; absent until a body is found to
     need one. *)
  escape : (string * string) option;
  (* What each name a module was imported under actually names, so that
     `nm.sum` finds the module `numerical`. *)
  modules : (string * string) list;
  (* Which of each module's names the target's own source provides, so
     that `foo.g1` reaches Foo_external and `foo.f1` reaches Foo. *)
  external_fields : (string * string list) list;
  (* This module's own name, and the names it declared rather than
     defined -- the host's half of it. *)
  own_module : string;
  own_external : string list;
  names : string SMap.t;
}

(** What a translation accumulates. *)
type acc = {
  temporaries : int;
  needs_quote : bool;
  needs_list_printer : bool;
  needs_float : bool;
  needs_range : bool;
}

(** The OCaml name a Pyking name is translated to, as `plan_names`
    settled it. ctx -> string -> string *)
let mangle ctx name =
  match SMap.find_opt name ctx.names with
  | Some found -> found
  | None -> mangle_base name

(** A fresh evaluation-order temporary name. ctx -> acc -> (string, acc) *)
let fresh_name ctx acc =
  let acc = { acc with temporaries = acc.temporaries + 1 } in
  (Printf.sprintf "%s%d" ctx.prefix acc.temporaries, acc)

(** A Pyking assignment target as an OCaml binding pattern.
    ctx -> assign_target -> opattern *)
let rec target_pattern ctx target =
  match target with
  | TargetName (_, name, _) -> OPatName (mangle ctx name)
  | TargetTuple (_, elements, _) ->
      OPatTuple (List.map (target_pattern ctx) elements)

(** A target read back as an expression: what a loop's accumulator holds
    on the turn it is bound. ctx -> assign_target -> oexpr *)
let rec target_expr ctx target =
  match target with
  | TargetName (_, name, _) -> OVar (mangle ctx name)
  | TargetTuple (_, elements, _) -> OTuple (List.map (target_expr ctx) elements)

(** The run of consecutive defs beginning at start.
    [stmt] -> int -> [stmt] *)
let function_run stmts start =
  let rec go index run =
    if index >= List.length stmts then List.rev run
    else
      match List.nth stmts index with
      | SFunctionDef _ as s -> go (index + 1) (s :: run)
      | _ -> List.rev run
  in
  go start []

(** The names the defs in stmts bind, as OCaml spells them.
    ctx -> [stmt] -> StringSet.t *)
let later_functions ctx stmts =
  List.fold_left
    (fun found s ->
      match s with
      | SFunctionDef (_, name, _, _, _, _, _, _, _) ->
          StringSet.add (mangle ctx name) found
      | _ -> found)
    StringSet.empty stmts

(** The names a statement binds where the rest of its block can see
    them, which is what makes moving a `def` past it change what that
    `def` reads. stmt -> StringSet.t *)
let bound_names stmt =
  let rec target_names target =
    match target with
    | TargetName (_, name, _) -> [ name ]
    | TargetTuple (_, parts, _) -> List.concat_map target_names parts
  in
  match stmt with
  | SLet (_, target, _, _, _, _, _) | SLetStmt (_, target, _, _, _, _) ->
      StringSet.of_list (target_names target)
  | SVar (_, name, _, _) -> StringSet.singleton name
  | SFunctionDef (_, name, _, _, _, _, _, _, _) -> StringSet.singleton name
  | _ -> StringSet.empty

(** stmts with every group of `def`s that name each other made
    consecutive, which is what `let rec ... and ...` needs: a `def`
    naming one written further down is moved to join it. A `def` binds
    no value and runs nothing, so moving one changes nothing -- unless
    something it moves past rebinds a name its body reads, which is
    refused. Only this list is reordered; a nested block is its own.
    [stmt] -> [stmt] *)
let regroup stmts =
  let all = Array.of_list stmts in
  let count = Array.length all in
  let def_name index =
    match all.(index) with
    | SFunctionDef (_, name, _, _, _, _, _, _, _) -> Some name
    | _ -> None
  in
  let defs = List.filter (fun i -> def_name i <> None) (List.init count Fun.id) in
  (* Over-reported on purpose: a name the body binds itself only puts two
     definitions in one group, which is always safe to write together. *)
  let reads = List.map (fun i -> (i, collect_identifiers [ all.(i) ])) defs in
  (* Only a reference *forward* makes a group: one written further down
     is already in scope where OCaml reads it, so a `def` naming an
     earlier one needs nothing done to it. *)
  let names_one_another i j =
    let forward earlier later =
      match def_name later with
      | Some other -> StringSet.mem other (List.assoc earlier reads)
      | None -> false
    in
    if i < j then forward i j else forward j i
  in
  let rec close group =
    let grown =
      List.filter
        (fun d ->
          List.mem d group || List.exists (fun g -> names_one_another d g) group)
        defs
    in
    if List.length grown = List.length group then group else close grown
  in
  let rec components left made =
    match left with
    | [] -> made
    | first :: _ ->
        let group = close [ first ] in
        components
          (List.filter (fun d -> not (List.mem d group)) left)
          (made @ [ group ])
  in
  let made = components defs [] in
  let joins = List.filter (fun group -> List.length group > 1) made in
  if joins = [] then stmts
  else
    let place =
      List.concat_map
        (fun group ->
          let last = List.fold_left max 0 group in
          List.map (fun index -> (index, last, group)) group)
        joins
    in
    List.iter
      (fun (index, last, group) ->
        let between =
          List.filter
            (fun j -> j > index && j <= last && not (List.mem j group))
            (List.init count Fun.id)
        in
        let passed =
          List.fold_left
            (fun found j -> StringSet.union found (bound_names all.(j)))
            StringSet.empty between
        in
        let mine = Option.value (def_name index) ~default:"" in
        let refuse reason =
          unsupported (stmt_info all.(index))
            (String.concat ""
               [
                 Printf.sprintf "`%s` names a `def` written further down: " mine;
                 "OCaml binds a group of mutually recursive functions with ";
                 "`let rec ... and ...`, which has to be written together, ";
                 "and this one cannot be moved down to join it -- ";
                 reason;
               ])
        in
        (* Moved past something that names it, it would be read before it
           is written; moved past something that binds a name its body
           reads, it would be given the later binding. *)
        if
          List.exists
            (fun j -> StringSet.mem mine (collect_identifiers [ all.(j) ]))
            between
        then refuse (Printf.sprintf "`%s` is named in between" mine);
        let shadowed = StringSet.inter passed (List.assoc index reads) in
        match StringSet.elements shadowed with
        | [] -> ()
        | first :: _ ->
            refuse
              (Printf.sprintf
                 "`%s` is bound again in between, so moving it would give it the later one"
                 first))
      place;
    let key index =
      match List.find_opt (fun (i, _, _) -> i = index) place with
      | Some (_, last, _) -> last
      | None -> index
    in
    List.map snd
      (List.stable_sort
         (fun (a, _) (b, _) -> compare (key a) (key b))
         (List.mapi (fun index stmt -> (index, stmt)) stmts))

(** Raises Unsupported if a def in run names one in later with something
    other than a def in between (docs/target_ocaml.md, "A def naming one
    written further down, with something in between").
    [stmt] -> [StringSet.t] -> StringSet.t -> () *)
let check_no_split_group run free_sets later =
  let names =
    List.fold_left
      (fun set f ->
        match f with
        | SFunctionDef (_, name, _, _, _, _, _, _, _) -> StringSet.add name set
        | _ -> set)
      StringSet.empty run
  in
  List.iter2
    (fun func used ->
      let reached =
        List.sort compare
          (StringSet.elements
             (StringSet.diff (StringSet.inter used later) names))
      in
      match reached with
      | [] -> ()
      | first :: _ ->
          let name =
            match func with
            | SFunctionDef (_, name, _, _, _, _, _, _, _) -> name
            | _ -> ""
          in
          unsupported (stmt_info func)
            (Printf.sprintf
               "`%s` names `%s`, which is written further down with something \
                in between: OCaml binds a group of mutually recursive \
                functions with `let rec ... and ...`, which has to be written \
                together"
               name first))
    run free_sets

(* What a `break`/`continue` OCaml cannot place is refused with. The
   guard rewrite in `block` covers the common shapes; this is what is
   left (docs/target_ocaml.md, "A break that is neither in tail position
   nor a guard"). *)
let no_early_exit =
  "a `break`/`continue` with statements after it: OCaml has no early exit, \
   so only one in tail position -- or one guarding the rest of the body -- \
   can be compiled"

(** The name of the statement node kind, for a refusal with nothing
    better to say. stmt -> string *)
let stmt_kind_name s =
  match s with
  | SLet _ -> "SLet"
  | SLetStmt _ -> "SLetStmt"
  | SVar _ -> "SVar"
  | SMutate _ -> "SMutate"
  | SReturn _ -> "SReturn"
  | SReturnStmt _ -> "SReturnStmt"
  | SExprStmt _ -> "SExprStmt"
  | SLoop _ -> "SLoop"
  | SBreak _ -> "SBreak"
  | SContinue _ -> "SContinue"
  | SIf _ -> "SIf"
  | SFunctionDef _ -> "SFunctionDef"
  | SFunctionSig _ -> "SFunctionSig"
  | SMatch _ -> "SMatch"
  | SImport _ -> "SImport"

let escape_char c =
  match c with
  | '\\' -> "\\\\"
  | '"' -> "\\\""
  | '\n' -> "\\n"
  | '\t' -> "\\t"
  | '\r' -> "\\r"
  | c -> String.make 1 c

(** s as a double-quoted OCaml string literal. string -> string *)
let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter (fun c -> Buffer.add_string buffer (escape_char c)) s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(** type_ with each named variable replaced by what it turned out to be.
    (string, typ) list -> typ -> typ *)
let rec substituted bindings type_ =
  if bindings = [] then type_
  else
    match type_ with
    | TVar (_, name, _, true) -> (
        match List.assoc_opt name bindings with
        | Some found -> found
        | None -> type_)
    | TList (info, element, sym) ->
        TList (info, substituted bindings element, sym)
    | TTuple (info, elements, sym) ->
        TTuple (info, List.map (substituted bindings) elements, sym)
    | TFunction (info, params, result, sym, tmsym, node, implicits) ->
        TFunction
          ( info,
            List.map (substituted bindings) params,
            substituted bindings result,
            sym,
            tmsym,
            node,
            implicits )
    | TForall (info, vars, inner, sym) ->
        TForall (info, vars, substituted bindings inner, sym)
    | type_ -> type_

(** The type the checker gave this expression. ctx -> expr -> typ *)
let type_of ctx e =
  let found = IntMap.find (expr_sym e) ctx.tmap in
  substituted ctx.specialised found

(* --- specialising a definition that prints a type variable ---

   OCaml has no runtime type, so a value of a type variable cannot be
   printed there at all. A definition every caller in this module uses at
   one type is compiled at that type instead, which is what the four
   `print`s of a parameter in the suite need. See
   docs/target_ocaml.md, "Printing a polymorphic value". *)

(** every variable in type_, in order of first appearance.
    typ -> [string] *)
let rec variables_in type_ =
  match type_ with
  | TVar (_, name, _, true) -> [ name ]
  | TList (_, element, _) -> variables_in element
  | TTuple (_, elements, _) -> List.concat_map variables_in elements
  | TFunction (_, params, result, _, _, _, _) ->
      List.concat_map variables_in params @ variables_in result
  | TForall (_, _, inner, _) -> variables_in inner
  | _ -> []

(** What declared's variables have to be for it to be actual. `None`
    where the two disagree about one of them.
    typ -> typ -> (string, typ) list -> (string, typ) list option *)
let rec matched declared actual found =
  match (declared, actual) with
  | TForall (_, _, inner, _), _ -> matched inner actual found
  | _, TForall (_, _, inner, _) -> matched declared inner found
  | TVar (_, name, _, true), _ -> (
      match List.assoc_opt name found with
      | None -> Some (found @ [ (name, actual) ])
      | Some already ->
          if Typesystem.same_type already actual then Some found else None)
  | TList (_, mine, _), TList (_, theirs, _) -> matched mine theirs found
  | TTuple (_, mine, _), TTuple (_, theirs, _)
    when List.length mine = List.length theirs ->
      List.fold_left2
        (fun found mine theirs ->
          match found with None -> None | Some found -> matched mine theirs found)
        (Some found) mine theirs
  | TFunction (_, mine, my_result, _, _, _, _),
    TFunction (_, theirs, their_result, _, _, _, _)
    when List.length mine = List.length theirs ->
      let found =
        List.fold_left2
          (fun found mine theirs ->
            match found with
            | None -> None
            | Some found -> matched mine theirs found)
          (Some found) mine theirs
      in
      (match found with
      | None -> None
      | Some found -> matched my_result their_result found)
  | _ -> Some found

(** One `def` per name in stmts, and only where that name is never used
    except as the callee of a call -- the two things that make reading
    a definition's instantiations off its call sites safe.
    [stmt] -> IntMap key is the def's symbol.
    [stmt] -> (string, stmt) list *)
let callable_definitions stmts =
  let counted =
    Walk.fold_stmts
      (fun found node ->
        match node with
        | Walk.NStmt (SFunctionDef (_, name, _, _, _, _, _, _, _) as node) ->
            (name, node) :: found
        | _ -> found)
      [] stmts
  in
  let names = List.map fst counted in
  let once name = List.length (List.filter (fun n -> n = name) names) = 1 in
  List.filter (fun (name, _) -> once name) counted

(** Every call in stmts, as (callee name, arguments).
    [stmt] -> (string, [expr]) list *)
let calls_in stmts =
  Walk.fold_stmts
    (fun found node ->
      match node with
      | Walk.NExpr (ECall (_, EVar (_, name, _), args, _)) ->
          found @ [ (name, arg_exprs args) ]
      | _ -> found)
    [] stmts

(** Whether name is read anywhere but as the callee of a call: a
    definition handed somewhere is used at whatever type that place
    wants, which its call sites do not say. [stmt] -> string -> bool *)
let used_as_value stmts name =
  let callees =
    Walk.fold_stmts
      (fun found node ->
        match node with
        | Walk.NExpr (ECall (_, (EVar (_, called, _) as callee), _, _))
          when called = name ->
            expr_sym callee :: found
        | _ -> found)
      [] stmts
  in
  Walk.exists_stmts
    (fun node ->
      match node with
      | Walk.NExpr (EVar (_, read, sym)) ->
          read = name && not (List.mem sym callees)
      | _ -> false)
    stmts

(** What each definition's type variables turn out to be, where every
    call in the module agrees and nothing else uses the name. A
    definition no entry names is compiled as written.
    [stmt] -> typ IntMap.t -> (string, typ) list IntMap.t *)
let specialisations stmts tmap =
  let calls = calls_in stmts in
  List.fold_left
    (fun found (name, node) ->
      let sym = stmt_sym node in
      match IntMap.find_opt sym tmap with
      | None -> found
      | Some declared ->
          if variables_in declared = [] || used_as_value stmts name then found
          else
            let params =
              match declared with
              | TForall (_, _, TFunction (_, params, _, _, _, _, _), _)
              | TFunction (_, params, _, _, _, _, _) ->
                  params
              | _ -> []
            in
            let mine = List.filter (fun (called, _) -> called = name) calls in
            if mine = [] then found
            else
              let settled =
                List.fold_left
                  (fun settled (_, args) ->
                    match settled with
                    | None -> None
                    | Some settled ->
                        if List.length args <> List.length params then None
                        else
                          List.fold_left2
                            (fun settled param arg ->
                              match (settled, IntMap.find_opt (expr_sym arg) tmap) with
                              | None, _ -> None
                              | Some settled, None -> Some settled
                              | Some settled, Some actual ->
                                  matched param actual settled)
                            (Some settled) params args)
                  (Some []) mine
              in
              (match settled with
              | None -> found
              | Some settled ->
                  if
                    List.for_all
                      (fun v -> List.mem_assoc v settled)
                      (variables_in declared)
                  then IntMap.add sym settled found
                  else found))
    IntMap.empty (callable_definitions stmts)


(* The prelude this backend has (docs/target_ocaml.md, "Builtins"): two
   printers for what OCaml has no printing of its own for. *)

let list_printer = "pyk_string_of_int_list"

let list_printer_def =
  Printf.sprintf
    "let %s xs =\n  \"[\" ^ String.concat \", \" (List.map string_of_int xs) ^ \"]\""
    list_printer

let float_helper = "pyk_float_str"

(* builtin.ml's rule, in OCaml. The same algorithm every other backend
   emits, so one .out file holds for all of them. *)
let float_helper_def =
  String.concat "\n"
    [
      Printf.sprintf "let %s x =" float_helper;
      "  if x <> x then \"nan\"";
      "  else if x = infinity then \"inf\"";
      "  else if x = neg_infinity then \"-inf\"";
      "  else";
      "    let negative = x < 0.0 || (x = 0.0 && 1.0 /. x < 0.0) in";
      "    let sign = if negative then \"-\" else \"\" in";
      "    let a = abs_float x in";
      "    if a = 0.0 then sign ^ \"0.0\"";
      "    else";
      "      let rec shortest p =";
      "        let s = Printf.sprintf \"%.*e\" p a in";
      "        if p >= 16 || float_of_string s = a then s else shortest (p + 1)";
      "      in";
      "      let s = shortest 0 in";
      "      let at = String.index s 'e' in";
      "      let digits =";
      "        String.concat \"\" (String.split_on_char '.' (String.sub s 0 at))";
      "      in";
      "      let rec trim n =";
      "        if n > 1 && digits.[n - 1] = '0' then trim (n - 1) else n";
      "      in";
      "      let digits = String.sub digits 0 (trim (String.length digits)) in";
      "      let len = String.length digits in";
      "      let decpt =";
      "        int_of_string (String.sub s (at + 1) (String.length s - at - 1))";
      "        + 1";
      "      in";
      "      let zeros n = String.make (max 0 n) '0' in";
      "      if decpt <= -4 || decpt > 16 then";
      "        let mantissa =";
      "          if len = 1 then digits";
      "          else String.sub digits 0 1 ^ \".\" ^ String.sub digits 1 (len - 1)";
      "        in";
      "        sign ^ mantissa ^ \"e\" ^ string_of_int (decpt - 1)";
      "      else if decpt <= 0 then sign ^ \"0.\" ^ zeros (-decpt) ^ digits";
      "      else if decpt >= len then sign ^ digits ^ zeros (decpt - len) ^ \".0\"";
      "      else";
      "        sign ^ String.sub digits 0 decpt ^ \".\"";
      "        ^ String.sub digits decpt (len - decpt)";
    ]

let range_helper = "pyk_range"

(* builtin.ml's rule, in OCaml: the Ints from start up to but not
   including stop, stepping by step. `List.init` covers the one-argument
   form on its own, so only the other two reach this. *)
let range_helper_def =
  String.concat "\n"
    [
      Printf.sprintf "let %s start stop step =" range_helper;
      "  if step = 0 then failwith \"'range' step must not be zero\";";
      "  let rec go n out =";
      "    if (step > 0 && n >= stop) || (step < 0 && n <= stop) then";
      "      List.rev out";
      "    else go (n + step) (n :: out)";
      "  in";
      "  go start []";
    ]

let quote_helper = "pyk_quote"

let quote_helper_def =
  String.concat "\n"
    [
      Printf.sprintf "let %s text =" quote_helper;
      "  let out = Buffer.create (String.length text + 2) in";
      "  Buffer.add_char out '\\'';";
      "  String.iter";
      "    (fun c ->";
      "      match c with";
      "      | '\\\\' -> Buffer.add_string out \"\\\\\\\\\"";
      "      | '\\'' -> Buffer.add_string out \"\\\\'\"";
      "      | '\\n' -> Buffer.add_string out \"\\\\n\"";
      "      | '\\t' -> Buffer.add_string out \"\\\\t\"";
      "      | '\\r' -> Buffer.add_string out \"\\\\r\"";
      "      | c -> Buffer.add_char out c)";
      "    text;";
      "  Buffer.add_char out '\\'';";
      "  Buffer.contents out";
    ]

(** The OCaml spelling of an arithmetic operator, which OCaml gives one
    set of for ints and another for floats. The comparisons need no such
    choice: OCaml's are polymorphic and, on two floats, IEEE's.
    ctx -> expr -> string -> string *)
let numeric ctx operand spelling =
  (* A node the tail-call pass synthesized carries no type -- it was not
     in the tree the checker walked -- and only an Int one can be, since
     that pass rewrites calls and never introduces arithmetic of its
     own. *)
  match IntMap.find_opt (expr_sym operand) ctx.tmap with
  | Some (TFloat _) -> spelling ^ "."
  | _ -> spelling

(** Translates one expression. ctx -> acc -> expr -> (oexpr, acc) *)
let rec expr ctx acc e =
  match e with
  | EInt (_, value, _) -> (OInt value, acc)
  | EFloat (_, value, _) -> (OFloat value, acc)
  | EString (_, value, _) -> (OStr value, acc)
  | EBool (_, value, _) -> (OBool value, acc)
  | EVar (_, name, _) ->
      (* A name this module *declared* rather than defined is the host's,
         and lives in the implementation beside this file -- the two
         halves are one module, so it is written unqualified here and
         reached through `<Module>_external` in the output. *)
      if List.mem name ctx.own_external then
        (OVar (reached (ctx.own_module ^ "_external") name), acc)
        (* A `var` is a cell, so reading it is a dereference. *)
      else if StringSet.mem name ctx.refs then (ODeref (mangle ctx name), acc)
      else (OVar (mangle ctx name), acc)
  | EQualified (_, alias, field, _) ->
      (* A public name of another module, which OCaml reaches the same
         way: through the module that holds it. *)
      let module_ = List.assoc alias ctx.modules in
      (OVar (reached (Module.reached_module ctx.external_fields module_ field) field), acc)
  | EIf (_, cond, then_expr, else_expr, _) ->
      let o_cond, acc = expr ctx acc cond in
      let o_then, acc = expr ctx acc then_expr in
      let o_else, acc = expr ctx acc else_expr in
      (OIf (o_cond, o_then, Some o_else), acc)
  (* The empty tuple is unit, in Pyking as in OCaml. *)
  | ETuple (_, [], _) -> (OUnit, acc)
  | ETuple (_, elements, _) ->
      let pieces, sequence, acc = in_order ctx acc elements in
      (sequence (OTuple pieces), acc)
  | ECall (_, EVar (_, name, _), args, _)
    when Builtin.crosses_host name ->
      print_call ctx acc e (arg_exprs args)
  | ECall (_, EVar (_, name, _), args, _) when List.mem name Builtin.pure_names ->
      builtin_call ctx acc e name (arg_exprs args)
  | ECall (_, func, args, _) ->
      let pieces, sequence, acc =
        in_order ctx acc (func :: arg_exprs args)
      in
      (* A call with no arguments passes unit, since that is what
         `function_binding` gave the definition to take. *)
      let func_piece = List.hd pieces in
      let arg_pieces = List.tl pieces in
      ( sequence
          (OApp (func_piece, if arg_pieces = [] then [ OUnit ] else arg_pieces)),
        acc )
  | EAdd (_, left, right, _) -> binary ctx acc (numeric ctx left "+") left right
  | EList (_, elements, _) ->
      let pieces, sequence, acc = in_order ctx acc elements in
      (sequence (OList pieces), acc)
  | ENeg (_, operand, _) ->
      let o_operand, acc = expr ctx acc operand in
      (ONeg (numeric ctx operand "-", o_operand), acc)
  | EListComp (_, element, clauses_list, _) -> clauses ctx acc clauses_list element
  | EConcat (_, left, right, _) -> (
      (* OCaml joins lists with `@` and strings with `^`; the checker has
         already said which this is. *)
      match type_of ctx e with
      | TList _ -> binary ctx acc "@" left right
      | _ -> binary ctx acc "^" left right)
  | ELambda (_, params, body, _) ->
      (* OCaml has no nullary function, so `() => e` takes unit -- the
         same rule a `def` with no parameters follows. *)
      let o_params =
        match params with
        | [] -> [ OPatTuple [] ]
        | params ->
            List.map
              (fun (Param (_, n, _, _, _)) -> OPatName (mangle ctx n))
              params
      in
      let value, acc = expr ctx acc body in
      (OLambda (o_params, value), acc)
  | ESub (_, left, right, _) -> binary ctx acc (numeric ctx left "-") left right
  | EMul (_, left, right, _) -> binary ctx acc (numeric ctx left "*") left right
  (* OCaml's `/` on ints truncates toward zero, which is Pyking's own
     rule, and `/.` on floats is IEEE's, which is Pyking's other one. *)
  | EDiv (_, left, right, _) -> binary ctx acc (numeric ctx left "/") left right
  | ELessThan (_, left, right, _) -> binary ctx acc "<" left right
  | ELessThanEq (_, left, right, _) -> binary ctx acc "<=" left right
  | EGreatThan (_, left, right, _) -> binary ctx acc ">" left right
  | EGreatThanEq (_, left, right, _) -> binary ctx acc ">=" left right
  (* OCaml's `=` is structural equality, which is what Pyking's `==`
     means for every type it compares. *)
  | EEq (_, left, right, _) -> binary ctx acc "=" left right

(** One binary operator application.
    ctx -> acc -> string -> expr -> expr -> (oexpr, acc) *)
and binary ctx acc op left right =
  let pieces, sequence, acc = in_order ctx acc [ left; right ] in
  match pieces with
  | [ a; b ] -> (sequence (OBin (op, a, b)), acc)
  | _ -> (OUnit, acc)

(** exprs translated, plus a wrapper pinning down their evaluation order
    where two or more can print (docs/target_ocaml.md, "Evaluation
    order"). ctx -> acc -> [expr] -> ([oexpr], oexpr -> oexpr, acc) *)
and in_order ctx acc exprs =
  let translated, acc =
    List.fold_left
      (fun (out, acc) e ->
        let o, acc = expr ctx acc e in
        (out @ [ o ], acc))
      ([], acc) exprs
  in
  let effectful =
    List.filteri
      (fun _ _ -> true)
      (List.concat
         (List.mapi
            (fun index e ->
              if Analyses.may_print ctx.printing e then [ index ] else [])
            exprs))
  in
  if List.length effectful < 2 then (translated, (fun result -> result), acc)
  else
    (* The last one may stay where it is: nothing after it can be pulled
       ahead of something that no longer has anything to say. *)
    let earlier =
      List.filteri (fun i _ -> i < List.length effectful - 1) effectful
    in
    let bindings, replacements, acc =
      List.fold_left
        (fun (bindings, replacements, acc) index ->
          let name, acc = fresh_name ctx acc in
          ( bindings
            @ [
                {
                  bound = OPatName name;
                  params = [];
                  value = List.nth translated index;
                };
              ],
            replacements @ [ (index, name) ],
            acc ))
        ([], [], acc) earlier
    in
    let translated =
      List.mapi
        (fun index t ->
          match List.assoc_opt index replacements with
          | Some name -> OVar name
          | None -> t)
        translated
    in
    let sequence result =
      List.fold_left
        (fun result binding -> OLet ([ binding ], result, false))
        result (List.rev bindings)
    in
    (translated, sequence, acc)

(** print(...): the arguments formatted per builtin.ml and
    written as one line. ctx -> acc -> expr -> [expr] -> (oexpr, acc) *)
and print_call ctx acc _call args =
  if args = [] then (OApp (OVar "print_newline", [ OUnit ]), acc)
  else
    let ordered, sequence, acc = in_order ctx acc args in
    let pieces, acc =
      List.fold_left2
        (fun (out, acc) a t ->
          let piece, acc = as_string ctx acc a (Some t) in
          (out @ [ piece ], acc))
        ([], acc) args ordered
    in
    let separated =
      match pieces with
      | [] -> []
      | first :: rest ->
          first :: List.concat_map (fun piece -> [ OStr " "; piece ]) rest
    in
    (* `^` is right-associative, so a chain nested to the right prints as
       `a ^ " " ^ b` with no parentheses at all. *)
    let text =
      match List.rev separated with
      | [] -> OStr ""
      | last :: earlier ->
          List.fold_left (fun text piece -> OBin ("^", piece, text)) last earlier
    in
    (sequence (OApp (OVar "print_endline", [ text ])), acc)

(** One printed argument, as an OCaml string expression. `translated` is
    arg's OCaml form when the caller already produced it.
    ctx -> acc -> expr -> oexpr option -> (oexpr, acc) *)
and as_string ctx acc arg translated =
  let translated, acc =
    match translated with
    | Some t -> (t, acc)
    | None -> expr ctx acc arg
  in
  string_of ctx acc (type_of ctx arg) translated (expr_info arg) true

(** A value of this type as a string, per builtin.ml's rules.
    `top` says the value is being printed on its own rather than from
    inside a tuple, which is the one thing that changes: a string prints
    bare there and quoted here.
    ctx -> acc -> typ -> oexpr -> info -> bool -> (oexpr, acc) *)
and string_of ctx acc type_ translated info top =
  if is_string type_ then
    if top then (translated, acc)
    else
      ( OApp (OVar quote_helper, [ translated ]),
        { acc with needs_quote = true } )
  else if is_int type_ then (OApp (OVar "string_of_int", [ translated ]), acc)
  else if is_float type_ then
    ( OApp (OVar float_helper, [ translated ]),
      { acc with needs_float = true } )
  else if is_bool type_ then (OApp (OVar "string_of_bool", [ translated ]), acc)
  else if is_unit type_ then
    (* Unit prints as `()`, and the expression still has to run:
       `(e; "()")` does both. *)
    if translated = OUnit then (OStr "()", acc)
    else (OSeq (translated, OStr "()"), acc)
  else
    match type_ with
    | TList (_, element, _) -> list_string ctx acc element translated info
    | TTuple (_, elements, _) -> tuple_string ctx acc elements translated info
    | TVar (_, _, _, false) ->
        (* Nothing ever constrained this type, so no value of it was
           made and this formatter is never reached. Answering without
           naming a type leaves the generated OCaml as polymorphic as
           the Pyking it came from. *)
        (OSeq (OIgnore translated, OStr ""), acc)
    | type_ ->
        unsupported info
          (Printf.sprintf "printing a value of type %s" (name_of type_))

(** A list as a string, in Pyking's own notation. The element formatter
    is built from the element's type the same way `tuple_string` builds a
    tuple's, so a list of anything printable prints -- including a list
    of lists. ctx -> acc -> typ -> oexpr -> info -> (oexpr, acc) *)
and list_string ctx acc element_type translated info =
  let name, acc = fresh_name ctx acc in
  let element, acc = string_of ctx acc element_type (OVar name) info false in
  let mapped = OApp (OVar "List.map", [ OFun [ (name, element) ]; translated ]) in
  let joined = OApp (OVar "String.concat", [ OStr ", "; mapped ]) in
  (OBin ("^", OStr "[", OBin ("^", joined, OStr "]")), acc)

(** A tuple as a string, in Pyking's own notation. OCaml has no printer
    of its own to reach for, so this takes the tuple apart and formats
    each element by its type -- which is what makes a nested one work as
    well. ctx -> acc -> [typ] -> oexpr -> info -> (oexpr, acc) *)
and tuple_string ctx acc element_types translated info =
  let names, acc =
    List.fold_left
      (fun (names, acc) _ ->
        let name, acc = fresh_name ctx acc in
        (names @ [ name ], acc))
      ([], acc) element_types
  in
  let pieces, acc =
    List.fold_left2
      (fun (out, acc) element name ->
        let piece, acc = string_of ctx acc element (OVar name) info false in
        (out @ [ piece ], acc))
      ([], acc) element_types names
  in
  (* A singleton keeps the comma that tells it from a parenthesized
     value, exactly as the source form does. *)
  let closing = if List.length pieces = 1 then ",)" else ")" in
  let text =
    match pieces with
    | [] -> OStr ""
    | first :: rest ->
        List.fold_left
          (fun text piece -> OBin ("^", text, OBin ("^", OStr ", ", piece)))
          first rest
  in
  let text = OBin ("^", OStr "(", OBin ("^", text, OStr closing)) in
  ( OLet
      ( [
          {
            bound = OPatTuple (List.map (fun n -> OPatName n) names);
            params = [];
            value = translated;
          };
        ],
        text,
        false ),
    acc )

(** Translates a call to str, len or range.
    ctx -> acc -> expr -> string -> [expr] -> (oexpr, acc) *)
and builtin_call ctx acc call name args =
  match (name, args) with
  | "str", [ value ] -> as_string ctx acc value None
  | "float", [ value ] ->
      let o_value, acc = expr ctx acc value in
      (OApp (OVar "float_of_int", [ o_value ]), acc)
  | "int", [ value ] ->
      (* OCaml's own conversion truncates toward zero, which is the
         rounding Pyking's `int` and `/` both do. *)
      let o_value, acc = expr ctx acc value in
      (OApp (OVar "int_of_float", [ o_value ]), acc)
  | "len", [ value ] -> (
      let type_ = type_of ctx value in
      let o_value, acc = expr ctx acc value in
      if is_string type_ then (OApp (OVar "String.length", [ o_value ]), acc)
      else if is_list type_ then
        (OApp (OVar "List.length", [ o_value ]), acc)
      else
        unsupported (expr_info call)
          (Printf.sprintf "`len` of a value of type %s" (name_of type_)))
  | "range", [ count ] ->
      (* `List.init` refuses a negative length where `range` answers with
         nothing, so the count is floored here. *)
      let o_count, acc = expr ctx acc count in
      ( OApp
          (OVar "List.init", [ OApp (OVar "max", [ OInt 0; o_count ]); OVar "Fun.id" ]),
        acc )
  | "range", ([ _; _ ] | [ _; _; _ ]) ->
      let ordered, pin, acc = in_order ctx acc args in
      let start, stop, step =
        match ordered with
        | [ start; stop ] -> (start, stop, OInt 1)
        | [ start; stop; step ] -> (start, stop, step)
        | _ -> (OUnit, OUnit, OUnit)
      in
      ( pin (OApp (OVar range_helper, [ start; stop; step ])),
        { acc with needs_range = true } )
  | _ ->
      unsupported (expr_info call)
        (Printf.sprintf "the builtin `%s` is not supported yet" name)

(** One Pyking pattern as OCaml pattern text, plus the two things OCaml
    cannot say there: the conditions the arm has to test with `when`,
    and the bindings its body has to open with. OCaml's own patterns
    line up with Pyking's for everything else, so that part is a
    spelling change rather than a translation: `..` is `_`, `..name` is
    `name`, and a list is written with `::` where a rest marker splits
    it. `used` is what the arm reads; a name it does not is written
    `_name`, the same convention an unread `let` binding follows, since
    this target is built warning-free.
    ctx -> acc -> pattern -> StringSet.t option
    -> ((string, [oexpr], [(string, oexpr)]), acc) *)
and matcher ctx acc p used =
  let plain text = ((text, [], []), acc) in
  match p with
  | PWildcard _ -> plain "_"
  | PCapture (_, name, _) -> plain (unread (mangle ctx name) used)
  | PInt (_, value, _) ->
      plain
        (if value >= 0 then string_of_int value
         else Printf.sprintf "(%d)" value)
  | PString (_, value, _) -> plain (quote value)
  | PBool (_, value, _) -> plain (if value then "true" else "false")
  | PTuple (_, elements, _) ->
      let parts, guards, extracts, acc =
        List.fold_left
          (fun (parts, guards, extracts, acc) element ->
            let (text, element_guards, element_extracts), acc =
              matcher ctx acc element used
            in
            ( parts @ [ text ],
              guards @ element_guards,
              extracts @ element_extracts,
              acc ))
          ([], [], [], acc) elements
      in
      ( ( Printf.sprintf "(%s)" (String.concat ", " parts),
          guards,
          extracts ),
        acc )
  | PText (_, prefix, middle, suffix, _) ->
      (* OCaml's patterns do not split a string, so the whole subject is
         bound and taken apart by the guard and the body: the length
         test comes first, which is what makes the `String.sub`s below
         it safe. *)
      let name, acc = fresh_name ctx acc in
      let subject = OVar name in
      let length = OApp (OVar "String.length", [ subject ]) in
      let front = String.length prefix and back = String.length suffix in
      let guards =
        [ OBin (">=", length, OInt (front + back)) ]
        @ (if front = 0 then []
           else
             [ OBin
                 ( "=",
                   OApp (OVar "String.sub", [ subject; OInt 0; OInt front ]),
                   OStr prefix ) ])
        @
        if back = 0 then []
        else
          [ OBin
              ( "=",
                OApp
                  ( OVar "String.sub",
                    [ subject; OBin ("-", length, OInt back); OInt back ] ),
                OStr suffix ) ]
      in
      let extracts =
        match middle with
        | None -> []
        | Some middle ->
            [ ( unread (mangle ctx middle) used,
                OApp
                  ( OVar "String.sub",
                    [
                      subject;
                      OInt front;
                      OBin ("-", OBin ("-", length, OInt back), OInt front);
                    ] ) );
            ]
      in
      ((name, guards, extracts), acc)
  | PList (_, prefix, rest, suffix, _) -> (
      match rest with
      | None ->
          let parts, guards, extracts, acc =
            List.fold_left
              (fun (parts, guards, extracts, acc) element ->
                let (text, element_guards, element_extracts), acc =
                  matcher ctx acc element used
                in
                ( parts @ [ text ],
                  guards @ element_guards,
                  extracts @ element_extracts,
                  acc ))
              ([], [], [], acc) prefix
          in
          ( ( Printf.sprintf "[%s]" (String.concat "; " parts),
              guards,
              extracts ),
            acc )
      | Some (ListRest (_, rest_name, _)) when suffix = [] ->
          let tail =
            match rest_name with
            | None -> "_"
            | Some name -> unread (mangle ctx name) used
          in
          let heads, guards, extracts, acc =
            List.fold_left
              (fun (heads, guards, extracts, acc) element ->
                let (text, element_guards, element_extracts), acc =
                  matcher ctx acc element used
                in
                ( heads @ [ text ],
                  guards @ element_guards,
                  extracts @ element_extracts,
                  acc ))
              ([], [], [], acc) prefix
          in
          let heads = String.concat "" (List.map (fun t -> t ^ " :: ") heads) in
          ( ( (if heads <> "" then Printf.sprintf "(%s%s)" heads tail else tail),
              guards,
              extracts ),
            acc )
      | Some (ListRest (_, rest_name, _)) ->
          (* Elements after `..`: OCaml matches a list from the front
             only, so the whole subject is bound and every element is
             taken by position, which needs a pattern a `let` can
             take. *)
          let bindable element =
            match element with
            | PWildcard _ | PCapture _ -> true
            | _ -> false
          in
          List.iter
            (fun element ->
              if not (bindable element) then
                unsupported (pattern_info element)
                  "an element of a list pattern with elements after `..`: \
                   this backend binds those by position, so each one has to \
                   be a plain name")
            (prefix @ suffix);
          let name, acc = fresh_name ctx acc in
          let subject = OVar name in
          let count = OApp (OVar "List.length", [ subject ]) in
          let front = List.length prefix and back = List.length suffix in
          let at index element extracts =
            match element with
            | PCapture (_, bound, _) ->
                extracts
                @ [
                    ( unread (mangle ctx bound) used,
                      OApp (OVar "List.nth", [ subject; index ]) );
                  ]
            | _ -> extracts
          in
          let extracts =
            List.fold_left
              (fun extracts (index, element) -> at index element extracts)
              []
              (List.mapi (fun i element -> (OInt i, element)) prefix)
          in
          let extracts =
            List.fold_left
              (fun extracts (index, element) -> at index element extracts)
              extracts
              (List.mapi
                 (fun i element ->
                   (OBin ("-", count, OInt (back - i)), element))
                 suffix)
          in
          let extracts =
            match rest_name with
            | None -> extracts
            | Some bound ->
                extracts
                @ [
                    ( unread (mangle ctx bound) used,
                      OApp
                        ( OVar "List.take",
                          [
                            OBin ("-", OBin ("-", count, OInt front), OInt back);
                            OApp (OVar "List.drop", [ OInt front; subject ]);
                          ] ) );
                  ]
          in
          ((name, [ OBin (">=", count, OInt (front + back)) ], extracts), acc))

(** One `case` as an OCaml arm: its pattern, what it has to test with
    `when`, and its body with the bindings the pattern could not make
    itself opened in front of it.
    ctx -> acc -> pattern -> oexpr -> ((string, oexpr?, oexpr), acc) *)
and arm_for ctx acc p body =
  let (text, guards, extracts), acc = matcher ctx acc p (Some (free body)) in
  let body =
    List.fold_left
      (fun body (name, value) ->
        OLet ([ { bound = OPatName name; params = []; value } ], body, false))
      body (List.rev extracts)
  in
  let guard =
    match guards with
    | [] -> None
    | first :: rest ->
        Some (List.fold_left (fun found one -> OBin ("&&", found, one)) first rest)
  in
  ((text, guard, body), acc)

(** Whether any arm tests something OCaml's own pattern matching cannot
    see, which is what makes a catch-all necessary however well the
    clauses cover. [(string, oexpr?, oexpr)] -> bool *)
and any_guard arms = List.exists (fun (_, guard, _) -> guard <> None) arms

(** The patterns of the arms OCaml can see: a `when` makes an arm
    invisible to its exhaustiveness check, so those are the only ones a
    catch-all has to be decided from.
    [match_case] -> [(string, oexpr?, oexpr)] -> [pattern] *)
and unguarded_patterns cases arms =
  List.filteri
    (fun index _ ->
      match List.nth_opt arms index with Some (_, None, _) -> true | _ -> false)
    (List.map (fun (MatchCase (_, p, _, _)) -> p) cases)

(** The fold for the clauses that are left: `[expr for p in seq if c
    ...]` as nested folds. Each `for` becomes a `List.concat_map` over
    its sequence, each `if` a guard, and a pattern that does not match
    filters the element out -- which is what Pyking's own comprehension
    does. ctx -> acc -> [comp_clause] -> expr -> (oexpr, acc) *)
and clauses ctx acc clause_list element =
  match clause_list with
  | [] ->
      let o_element, acc = expr ctx acc element in
      (OList [ o_element ], acc)
  | CompFor (_, p, sequence, _) :: rest ->
      let inner, acc = clauses ctx acc rest element in
      let (text, guard, inner), acc = arm_for ctx acc p inner in
      let arms = [ (text, guard, inner) ] in
      let arms =
        if guard = None && Typesystem.covers [ p ] then arms
        else arms @ [ ("_", None, OList []) ]
      in
      let o_sequence, acc = expr ctx acc sequence in
      (* A `function` takes no `when`, so a guarded pattern is matched
         inside the body instead. *)
      let taking, acc =
        match arms with
        | [ (text, None, inner) ] -> ([ (text, inner) ], acc)
        | _ when not (any_guard arms) ->
            (List.map (fun (text, _, inner) -> (text, inner)) arms, acc)
        | _ ->
            let name, acc = fresh_name ctx acc in
            ([ (name, OMatch (OVar name, arms)) ], acc)
      in
      (OApp (OVar "List.concat_map", [ OFun taking; o_sequence ]), acc)
  | CompIf (_, condition, _) :: rest ->
      let o_condition, acc = expr ctx acc condition in
      let inner, acc = clauses ctx acc rest element in
      (OIf (o_condition, inner, Some (OList [])), acc)

(** A match's clauses as (pattern, body) pairs. The body is translated
    first, so the pattern can tell which of the names it binds the arm
    actually reads. ctx -> acc -> [match_case] -> ([(string, oexpr)], acc) *)
and arms ctx acc cases =
  List.fold_left
    (fun (built, acc) (MatchCase (_, p, case_body, _)) ->
      let o_body, acc = body ctx acc case_body in
      let arm, acc = arm_for ctx acc p o_body in
      (built @ [ arm ], acc))
    ([], acc) cases

(** A `match` whose value is taken. OCaml requires every value to exist,
    so the clauses must cover -- which typesystem.ml has already required
    of a value-form match. ctx -> acc -> stmt -> (oexpr, acc) *)
and match_value ctx acc stmt =
  match stmt with
  | SMatch (_, subject, cases, _) ->
      let o_subject, acc = expr ctx acc subject in
      let o_arms, acc = arms ctx acc cases in
      (* A `when` hides coverage from OCaml, which then wants an arm for
         what the checker already proved cannot arrive. *)
      let o_arms =
        if Typesystem.covers (unguarded_patterns cases o_arms) then o_arms
        else o_arms @ [ ("_", None, OApp (OVar "assert", [ OBool false ])) ]
      in
      (OMatch (o_subject, o_arms), acc)
  | _ -> (OUnit, acc)

(** A `match` run for what it does. A Pyking `match` may match nothing
    and do nothing, so a catch-all arm is added unless the clauses
    already cover. ctx -> acc -> stmt -> (oexpr, acc) *)
and match_effects ctx acc stmt =
  match stmt with
  | SMatch (_, subject, cases, _) ->
      let o_arms, acc =
        List.fold_left
          (fun (built, acc) (MatchCase (_, p, case_body, _)) ->
            let o_body, acc = effects ctx acc case_body in
            let arm, acc = arm_for ctx acc p o_body in
            (built @ [ arm ], acc))
          ([], acc) cases
      in
      let o_arms =
        if Typesystem.covers (unguarded_patterns cases o_arms) then o_arms
        else o_arms @ [ ("_", None, OUnit) ]
      in
      let o_subject, acc = expr ctx acc subject in
      (OMatch (o_subject, o_arms), acc)
  | _ -> (OUnit, acc)

(** A function body: a block whose last statement is its value.
    ctx -> acc -> [stmt] -> (oexpr, acc) *)
and body ctx acc stmts = block ctx acc stmts Tail

(** A block run only for what it does -- the top level's statements, or a
    branch that produces nothing. ctx -> acc -> [stmt] -> (oexpr, acc) *)
and effects ctx acc stmts = block ctx acc stmts Effect

(** A statement sequence as one expression. `where` says whether the last
    statement supplies a value, the block runs for effect, or it is a
    loop body whose value is the next accumulator.
    ctx -> acc -> [stmt] -> position -> (oexpr, acc) *)
and block ctx acc stmts where =
  let stmts = regroup stmts in
  match stmts with
  | [] -> (OUnit, acc)
  | first :: rest -> (
      (* A guard (docs/target_ocaml.md, "A return that is neither in tail
         position nor a guard"): an `if` a branch of which always leaves
         -- by `return`, `break` or `continue` -- becomes an `if` whose
         other branch is the rest of the block. Nothing is duplicated,
         since a branch that leaves needs no continuation and a branch
         that does not is the only one carrying it. *)
      let guarded =
        match (rest, first) with
        | _ :: _, SIf (_, cond, then_body, else_body, _) ->
            let then_exits = definitely_exits then_body in
            let else_exits =
              match else_body with
              | None -> false
              | Some else_body -> definitely_exits else_body
            in
            if then_exits || else_exits then
              Some (cond, then_body, Option.value else_body ~default:[], then_exits, else_exits)
            else None
        | _ -> None
      in
      match guarded with
      | Some (cond, then_body, else_body, then_exits, else_exits) ->
          let o_cond, acc = expr ctx acc cond in
          let o_then, acc =
            block ctx acc (if then_exits then then_body else then_body @ rest) where
          in
          let o_else, acc =
            block ctx acc (if else_exits then else_body else else_body @ rest) where
          in
          (OIf (o_cond, o_then, Some o_else), acc)
      | None ->
          if rest = [] then last ctx acc first where
          else (
            match first with
            | SVar (_, name, e, _) ->
                (* A `var` is a `ref`, and its scope is the rest of this
                   block -- which is exactly what `let ... in` gives
                   it. *)
                let value, acc = expr ctx acc e in
                let inner_ctx = { ctx with refs = StringSet.add name ctx.refs } in
                let o_body, acc = block inner_ctx acc rest where in
                ( OLet
                    ( [
                        {
                          bound = OPatName (mangle ctx name);
                          params = [];
                          value = ORef value;
                        };
                      ],
                      o_body,
                      false ),
                  acc )
            | SMutate _ ->
                let head, acc = discard ctx acc first in
                let tail, acc = block ctx acc rest where in
                (OSeq (head, tail), acc)
            | SLet _ | SLetStmt _ ->
                let b, acc = binding ctx acc first in
                let o_body, acc = block ctx acc rest where in
                (OLet ([ b ], o_body, false), acc)
            | SFunctionDef _ ->
                let run = function_run stmts 0 in
                let after =
                  List.filteri (fun i _ -> i >= List.length run) stmts
                in
                let o_body, acc = block ctx acc after where in
                let later = later_functions ctx after in
                let built, acc = groups ctx acc run later in
                (* Innermost group last, so the `let`s nest in source
                   order. *)
                ( List.fold_left
                    (fun o_body (bindings, recursive) ->
                      OLet (bindings, o_body, recursive))
                    o_body (List.rev built),
                  acc )
            | SReturn _ | SReturnStmt _ ->
                (* Everything after it is unreachable, so the escape is
                   the whole of what this block is worth. *)
                escaping ctx acc first
            | SBreak _ | SContinue _ ->
                unsupported (stmt_info first) no_early_exit
            | _ ->
                let head, acc = discard ctx acc first in
                let tail, acc = block ctx acc rest where in
                (OSeq (head, tail), acc)))

(** The final statement of a block.
    ctx -> acc -> stmt -> position -> (oexpr, acc) *)
and last ctx acc statement where =
  match where with
  | InLoop loop -> loop_last ctx acc statement loop
  | _ -> (
      let tail = where = Tail in
      match statement with
      | SExprStmt (_, e, _) when tail -> expr ctx acc e
      | SReturn (_, e, _) -> expr ctx acc e
      | SReturnStmt (_, stmt, _) -> value_stmt ctx acc stmt
      | SIf (_, cond, then_body, else_body, _) -> (
          let o_cond, acc = expr ctx acc cond in
          match else_body with
          | None ->
              (* An `if` with no `else` supplies unit whatever its one
                 branch ends in, so the branch runs for what it does
                 (PYKING.md, "Type checking"). *)
              let o_then, acc = effects ctx acc then_body in
              (OIf (o_cond, o_then, None), acc)
          | Some else_body ->
              let o_then, acc = block ctx acc then_body where in
              let o_else, acc = block ctx acc else_body where in
              (OIf (o_cond, o_then, Some o_else), acc))
      | SMatch (_, _, cases, _)
        when tail
             && Typesystem.covers
                  (List.map (fun (MatchCase (_, p, _, _)) -> p) cases) ->
          match_value ctx acc statement
      | SMatch (_, _, cases, _) when tail ->
          (* A subject no arm takes leaves unit, where an arm that
             matches leaves what it ends in: two types for one
             expression, which OCaml has no way to write. *)
          List.iter
            (fun (MatchCase (_, _, case_body, _)) ->
              match List.rev case_body with
              | SExprStmt (info, e, _) :: _ -> (
                  match IntMap.find_opt (expr_sym e) ctx.tmap with
                  | Some type_ when not (is_unit type_) ->
                      unsupported info
                        "an arm of a `match` that does not cover, in a \
                         position whose value is taken: a subject no arm takes \
                         leaves unit where this one leaves its own value, and \
                         OCaml has one type for both"
                  | _ -> ())
              | _ -> ())
            cases;
          match_effects ctx acc statement
      (* A `match` no arm takes falls out of it as unit, so one that does
         not cover is worth unit wherever it stands -- and needs the
         fallthrough spelled out, which OCaml requires anyway. *)
      | SMatch _ -> match_effects ctx acc statement
      | SLoop _ when tail ->
          (* A loop is an expression here, so a function ending in one
             needs nothing said about it -- and a `return` inside it
             returns from the function, since the loop's value *is* the
             function's. *)
          loop ctx acc statement true
      | SVar (_, name, e, _) ->
          (* As for `=` below: the cell is unreachable from outside the
             block, so the block supplies unit. *)
          let value, acc = expr ctx acc e in
          ( OLet
              ( [
                  {
                    bound = OPatName (mangle ctx name);
                    params = [];
                    value = ORef value;
                  };
                ],
                OUnit,
                false ),
            acc )
      | SMutate _ ->
          (* A mutation is worth unit, which is what a block run for what
             it does supplies anyway. *)
          discard ctx acc statement
      | SLet _ | SLetStmt _ ->
          (* A block ending in a binding supplies unit; the binding
             itself is unreachable from outside the block. *)
          let b, acc = binding ctx acc statement in
          (OLet ([ b ], OUnit, false), acc)
      | SFunctionDef _ -> (
          let built, acc = groups ctx acc [ statement ] StringSet.empty in
          match built with
          | [ (bindings, recursive) ] -> (OLet (bindings, OUnit, recursive), acc)
          | _ -> (OUnit, acc))
      | statement when tail ->
          unsupported (stmt_info statement)
            (Printf.sprintf "%s as the value of a function"
               (stmt_kind_name statement))
      | statement -> discard ctx acc statement)

(** A loop, as a local recursive function applied at once
    (docs/target_ocaml.md, "loop"): the accumulator is the function's
    parameter, going round is a tail call, and breaking is the value the
    call returns. OCaml optimises the tail call, so this runs in constant
    space -- which is why this backend needs no imperative loop at all.
    ctx -> acc -> stmt -> bool -> (oexpr, acc) *)
and loop ctx acc s returning =
  match s with
  | SLoop (_, target, init, _, iterate, loop_body, _) ->
      let name, acc = fresh_name ctx acc in
      (* The accumulator is worked out before a `for`'s sequence, which
         is the order interpreter.ml uses. *)
      let carried =
        match (target, init) with Some _, Some init -> [ init ] | _ -> []
      in
      let walked =
        match iterate with
        | Some (ForIn (_, _, sequence, _)) -> [ sequence ]
        | _ -> []
      in
      let ordered, pin, acc = in_order ctx acc (carried @ walked) in
      let o_init, o_sequence =
        match (carried, ordered) with
        | [], [ sequence ] -> (OUnit, Some sequence)
        | _, [ o_init ] -> (o_init, None)
        | _, [ o_init; sequence ] -> (o_init, Some sequence)
        | _ -> (OUnit, None)
      in
      let parameter, accumulator, acc =
        match target with
        | None ->
            (* Nothing is carried, so the parameter is unit and the
               accumulator a `break` yields is unit too. *)
            let unused, acc = fresh_name ctx acc in
            (OPatName unused, OUnit, acc)
        | Some target ->
            (target_pattern ctx target, target_expr ctx target, acc)
      in
      (* A `for` carries what is left of the sequence as a second
         parameter, so the name has to exist before the body is
         translated: that is what `again` passes to the next turn. *)
      let remaining, acc =
        match iterate with
        | Some (ForIn _) ->
            let remaining, acc = fresh_name ctx acc in
            (Some remaining, acc)
        | _ -> (None, acc)
      in
      let this =
        {
          loop_name = name;
          loop_accumulator = accumulator;
          carries = target <> None;
          returning;
          walking = Option.map (fun remaining -> OVar remaining) remaining;
        }
      in
      let inner_ctx = { ctx with loops = ctx.loops @ [ this ] } in
      let o_body, acc = block inner_ctx acc loop_body (InLoop this) in
      let read = free o_body in
      let params, value, acc =
        match (iterate, remaining) with
        | Some (ForIn (_, element, _, _)), Some remaining ->
            (* Running out of sequence is leaving the loop, so the empty
               arm is worth what a `break` is worth. *)
            let sequence, acc = fresh_name ctx acc in
            let walking =
              Printf.sprintf "%s :: %s"
                (unread (mangle ctx element) (Some read))
                (unread remaining (Some read))
            in
            ( [ parameter; OPatName sequence ],
              OMatch
                ( OVar sequence,
                  [ ("[]", None, accumulator); (walking, None, o_body) ] ),
              acc )
        | Some (WhileTest (_, condition, _)), _ ->
            (* The test is asked with the accumulator in scope, and a
               turn that is not taken leaves the loop with it. *)
            let o_condition, acc = expr inner_ctx acc condition in
            ([ parameter ], OIf (o_condition, o_body, Some accumulator), acc)
        | _ -> ([ parameter ], o_body, acc)
      in
      let b = { bound = OPatName name; params; value } in
      (* `rec` only where the body actually goes round again: an
         unnecessary one is a warning, and the harness builds with
         warnings as errors. *)
      let recursive = StringSet.mem name (free_in_binding b) in
      let arguments =
        match o_sequence with
        | None -> [ o_init ]
        | Some sequence -> [ o_init; sequence ]
      in
      (pin (OLet ([ b ], OApp (OVar name, arguments), recursive)), acc)
  | _ -> (OUnit, acc)

(** A `return` that leaves the function from somewhere OCaml has no exit
    from: its value goes in the escape's cell and the exception carries
    control out. Raises Needs_escape where no escape is in scope yet.
    ctx -> acc -> stmt -> (oexpr, acc) *)
and escaping ctx acc statement =
  match ctx.escape with
  | None -> raise Needs_escape
  | Some (exc, cell) ->
      let value, acc =
        match statement with
        | SReturn (_, e, _) -> expr ctx acc e
        | SReturnStmt (_, inner, _) -> value_stmt ctx acc inner
        | _ -> (OUnit, acc)
      in
      ( OSeq
          ( OAssign (cell, OApp (OVar "Some", [ value ])),
            OApp (OVar "raise", [ OVar exc ]) ),
        acc )

(** The tail call that starts loop's next turn. oloop -> oexpr -> oexpr *)
and again this value =
  match this.walking with
  | None -> OApp (OVar this.loop_name, [ value ])
  | Some rest -> OApp (OVar this.loop_name, [ value; rest ])

(** The last statement of a loop body: what it produces is the
    accumulator the next turn carries, so it ends in either a call going
    round or the value the loop stops with.
    ctx -> acc -> stmt -> oloop -> (oexpr, acc) *)
and loop_last ctx acc statement this =
  match statement with
  | SReturn (_, e, _) when this.returning ->
      (* The loop is the function's value, so leaving the loop with this
         and leaving the function with it are one and the same. *)
      expr ctx acc e
  | SReturnStmt (_, inner, _) when this.returning -> value_stmt ctx acc inner
  | SReturn _ | SReturnStmt _ ->
      (* The loop's value is wanted where it stands, so leaving the loop
         and leaving the function are two acts: the second is the
         escape, which `function_binding` puts in scope. *)
      escaping ctx acc statement
  | SLoop _ ->
      (* A loop as the last statement of a loop body: its value is what
         the turn outside goes round with. *)
      let inner, acc = loop ctx acc statement false in
      (again this inner, acc)
  (* A `break` leaves with the accumulator this turn started with, which
     is what the loop is worth (PYKING.md, "Leaving a loop"). *)
  | SBreak _ -> (this.loop_accumulator, acc)
  | SContinue _ -> (again this this.loop_accumulator, acc)
  | SIf (_, cond, then_body, else_body, _) -> (
      match else_body with
      | Some else_body ->
          let o_cond, acc = expr ctx acc cond in
          let o_then, acc = block ctx acc then_body (InLoop this) in
          let o_else, acc = block ctx acc else_body (InLoop this) in
          (OIf (o_cond, o_then, Some o_else), acc)
      | None ->
          if this.carries then
            unsupported (stmt_info statement)
              "an `if` with no `else` as the last statement of a loop body: \
               one way through it would say nothing about what the next turn \
               carries";
          (* A loop carrying nothing: the branch runs for what it does,
             and the loop goes round either way. *)
          let o_cond, acc = expr ctx acc cond in
          let o_then, acc = effects ctx acc then_body in
          (OSeq (OIf (o_cond, o_then, None), again this OUnit), acc))
  | SMatch (_, subject, cases, _) ->
      (* Each arm is a path of its own, and a subject no arm takes goes
         round again -- which only a loop carrying nothing can do. *)
      let covers =
        Typesystem.covers (List.map (fun (MatchCase (_, p, _, _)) -> p) cases)
      in
      if this.carries && not covers then
        unsupported (stmt_info statement)
          "a `match` that does not cover as the last statement of a loop \
           body: a subject no arm takes would say nothing about what the \
           next turn carries";
      let o_subject, acc = expr ctx acc subject in
      let o_arms, acc =
        List.fold_left
          (fun (built, acc) (MatchCase (_, p, case_body, _)) ->
            let o_body, acc = block ctx acc case_body (InLoop this) in
            let arm, acc = arm_for ctx acc p o_body in
            (built @ [ arm ], acc))
          ([], acc) cases
      in
      let o_arms =
        if Typesystem.covers (unguarded_patterns cases o_arms) then o_arms
        else if covers then
          (* Covered, but a `when` hides that from OCaml. *)
          o_arms @ [ ("_", None, OApp (OVar "assert", [ OBool false ])) ]
        else o_arms @ [ ("_", None, again this OUnit) ]
      in
      (OMatch (o_subject, o_arms), acc)
  | SExprStmt (_, e, _) when this.carries ->
      let o, acc = expr ctx acc e in
      (again this o, acc)
  | statement when not this.carries ->
      (* Nothing is carried, so the turn's last statement is run the way
         any block run for what it does runs its last one. *)
      let head, acc = last ctx acc statement Effect in
      (OSeq (head, again this OUnit), acc)
  | statement ->
      unsupported (stmt_info statement)
        (Printf.sprintf
           "%s as the last statement of a loop body: every turn has to say \
            what the next one carries"
           (stmt_kind_name statement))

(** A statement in value form: `x = if c: ...`, `return if c: ...`, or a
    loop, whose value is the accumulator it stopped with.
    ctx -> acc -> stmt -> (oexpr, acc) *)
and value_stmt ctx acc stmt =
  match stmt with
  | SLoop _ -> loop ctx acc stmt false
  | SIf (_, cond, then_body, else_body, _) -> (
      match else_body with
      | None -> unsupported (stmt_info stmt) "a value-form `if` with no `else`"
      | Some else_body ->
          let o_cond, acc = expr ctx acc cond in
          let o_then, acc = block ctx acc then_body Tail in
          let o_else, acc = block ctx acc else_body Tail in
          (OIf (o_cond, o_then, Some o_else), acc))
  | SMatch _ -> match_value ctx acc stmt
  | stmt ->
      unsupported (stmt_info stmt)
        (Printf.sprintf "%s in value position" (stmt_kind_name stmt))

(** A statement run for its effect, its value thrown away.
    ctx -> acc -> stmt -> (oexpr, acc) *)
and discard ctx acc statement =
  match statement with
  | SExprStmt (_, e, _) ->
      let translated, acc = expr ctx acc e in
      if is_unit (type_of ctx e) then (translated, acc)
      else (OIgnore translated, acc)
  | SIf (_, cond, then_body, else_body, _) ->
      let o_cond, acc = expr ctx acc cond in
      let o_then, acc = effects ctx acc then_body in
      let o_else, acc =
        match else_body with
        | None -> (None, acc)
        | Some else_body ->
            let o, acc = effects ctx acc else_body in
            (Some o, acc)
      in
      (OIf (o_cond, o_then, o_else), acc)
  | SMatch _ -> match_effects ctx acc statement
  | SLoop (_, target, _, _, _, _, _) ->
      let translated, acc = loop ctx acc statement false in
      if target = None then (translated, acc) else (OIgnore translated, acc)
  | SMutate (_, name, e, _) ->
      let value, acc = expr ctx acc e in
      (OAssign (mangle ctx name, value), acc)
  | SBreak _ | SContinue _ -> unsupported (stmt_info statement) no_early_exit
  | statement ->
      unsupported (stmt_info statement)
        (Printf.sprintf "%s in this position" (stmt_kind_name statement))

(** A `=` binding, as one OCaml binding.
    ctx -> acc -> stmt -> (obinding, acc) *)
and binding ctx acc statement =
  match statement with
  | SLet (_, target, e, _, _, _, _) ->
      let value, acc = expr ctx acc e in
      ({ bound = target_pattern ctx target; params = []; value }, acc)
  | SLetStmt (_, target, stmt, _, _, _) ->
      let value, acc = value_stmt ctx acc stmt in
      ({ bound = target_pattern ctx target; params = []; value }, acc)
  | statement ->
      unsupported (stmt_info statement)
        (Printf.sprintf "%s as a binding" (stmt_kind_name statement))

(** Refuses a def with a polymorphic *parameter*. OCaml generalizes what
    a `let` binds, so a polymorphic definition needs nothing said about
    it here -- but a parameter used at two types inside one body is
    rank-2, and OCaml takes that only from an explicit `'a.` annotation,
    which this backend never writes (docs/target_ocaml.md, "Type
    variables"). ctx -> stmt -> () *)
and check_rank_one ctx func =
  let declared =
    match IntMap.find_opt (stmt_sym func) ctx.tmap with
    | Some (TForall (_, _, TFunction (_, params, _, _, _, _, _), _)) -> Some params
    | Some (TFunction (_, params, _, _, _, _, _)) -> Some params
    | _ -> None
  in
  match declared with
  | None -> ()
  | Some params ->
      let func_params =
        match func with
        | SFunctionDef (_, _, params, _, _, _, _, _, _) -> params
        | _ -> []
      in
      let rec go ps ts =
        match (ps, ts) with
        | Param (info, _, _, _, _) :: ps, type_ :: ts ->
            if has_forall type_ then
              unsupported info
                "a polymorphic parameter -- OCaml generalizes a `let`, not a \
                 parameter, and taking one needs an explicit `'a.` annotation \
                 this backend does not write"
            else go ps ts
        | _ -> ()
      in
      go func_params params

(** One def, as an obinding. ctx -> acc -> stmt -> (obinding, acc) *)
and function_binding ctx acc func =
  check_rank_one ctx func;
  let ctx =
    {
      ctx with
      specialised =
        Option.value
          (IntMap.find_opt (stmt_sym func) ctx.specialisations)
          ~default:[];
    }
  in
  match func with
  | SFunctionDef (_, name, params, func_body, _, _, _, _, _) ->
      (* OCaml has no nullary function, so a `def f():` takes unit -- the
         empty tuple pattern, which prints as `()`. Without it the
         binding would be a value, evaluated where it is written rather
         than where it is called, and a body that never returns would
         hang the program at start-up. *)
      let o_params =
        match params with
        | [] -> [ OPatTuple [] ]
        | params -> List.map (fun (Param (_, n, _, _, _)) -> OPatName (mangle ctx n)) params
      in
      let value, acc =
        try body ctx acc func_body
        with Needs_escape ->
          (* Translated again with an escape in scope: nothing was
             changed by the attempt that asked for one, so this starts
             from the same place it did. *)
          let exc, acc = fresh_name ctx acc in
          let cell, acc = fresh_name ctx acc in
          let bound, acc = fresh_name ctx acc in
          let exc = String.capitalize_ascii exc in
          let value, acc =
            body { ctx with escape = Some (exc, cell) } acc func_body
          in
          (OEscape (exc, cell, bound, value), acc)
      in
      ({ bound = OPatName (mangle ctx name); params = o_params; value }, acc)
  | _ -> ({ bound = OPatName ""; params = []; value = OUnit }, acc)

(** A run of consecutive defs, translated and split into the smallest
    groups that still see each other, each as (bindings, recursive)
    (docs/target_ocaml.md, "A def naming one written further down, with
    something in between").
    ctx -> acc -> [stmt] -> StringSet.t -> ([([obinding], bool)], acc) *)
and groups ctx acc run later =
  let bindings, acc =
    List.fold_left
      (fun (out, acc) f ->
        let b, acc = function_binding ctx acc f in
        (out @ [ b ], acc))
      ([], acc) run
  in
  let free_sets = List.map free_in_binding bindings in
  check_no_split_group run free_sets later;
  let count = List.length bindings in
  let slice low high list =
    List.filteri (fun i _ -> i >= low && i < high) list
  in
  let names_of bs =
    union_all (List.map (fun b -> StringSet.of_list (pattern_names b.bound)) bs)
  in
  let rec go start built =
    if start >= count then List.rev built
    else
      let rec widen end_ =
        if end_ >= count then end_
        else
          let reaching = union_all (slice start end_ free_sets) in
          if
            StringSet.is_empty
              (StringSet.inter reaching (names_of (slice end_ count bindings)))
          then end_
          else widen (end_ + 1)
      in
      let end_ = widen (start + 1) in
      let group = slice start end_ bindings in
      let names = names_of group in
      let recursive =
        not
          (StringSet.is_empty
             (StringSet.inter names (union_all (slice start end_ free_sets))))
      in
      go end_ ((group, recursive) :: built)
  in
  (go 0 [], acc)

(** The top level, as a list of OCaml items: each Pyking binding becomes
    a top-level let, and each run of non-binding statements one
    `let () = ...`. ctx -> acc -> [stmt] -> ([oitem], acc) *)
and items ctx acc stmts =
  let stmts = regroup stmts in
  let count = List.length stmts in
  let rec go index ctx acc built =
    if index >= count then (List.rev built, acc)
    else
      match List.nth stmts index with
      | SFunctionDef _ ->
          let run = function_run stmts index in
          let after =
            List.filteri (fun i _ -> i >= index + List.length run) stmts
          in
          let later = later_functions ctx after in
          let made, acc = groups ctx acc run later in
          go
            (index + List.length run)
            ctx acc
            (List.rev_append
               (List.map (fun (bindings, recursive) -> OItemLet (bindings, recursive)) made)
               built)
      | SVar (_, name, e, _) ->
          (* A top-level `var` is a top-level `ref`, in scope for
             everything after it, which is what the items are. *)
          let value, acc = expr ctx acc e in
          let item =
            OItemLet
              ( [
                  {
                    bound = OPatName (mangle ctx name);
                    params = [];
                    value = ORef value;
                  };
                ],
                false )
          in
          go (index + 1)
            { ctx with refs = StringSet.add name ctx.refs }
            acc (item :: built)
      | (SLet _ | SLetStmt _) as statement ->
          let b, acc = binding ctx acc statement in
          go (index + 1) ctx acc (OItemLet ([ b ], false) :: built)
      | SImport _ ->
          (* Nothing is emitted: a qualified name is written
             `Module.name` where it is used, and a name a `from` line
             brought in reads as that same thing. What makes the module's
             own top level run first is the order the files are linked
             in. *)
          go (index + 1) ctx acc built
      | _ ->
          (* A run of statements with nothing to bind: one `let () =`. *)
          let rec take i run =
            if i >= count then (List.rev run, i)
            else
              match List.nth stmts i with
              | SLet _ | SLetStmt _ | SVar _ | SFunctionDef _ | SImport _ ->
                  (List.rev run, i)
              | statement -> take (i + 1) (statement :: run)
          in
          let run, next = take index [] in
          let o, acc = effects ctx acc run in
          go next ctx acc (OItemUnit o :: built)
  in
  go 0 ctx acc []

(* --- unused names ---

   Renames every unread name to _name in advance, the way an OCaml
   programmer would, rather than leaving a warning a reader cannot act
   on. See docs/target_ocaml.md, "What the compiler would have said". *)

(** e with every unread let binding renamed _name. oexpr -> oexpr *)
let rec polish e =
  match e with
  | OInt _ | OFloat _ | OStr _ | OBool _ | OUnit | OVar _ | ODeref _ -> e
  | OIgnore inner -> OIgnore (polish inner)
  | ORef value -> ORef (polish value)
  | OAssign (name, value) -> OAssign (name, polish value)
  | OApp (func, args) -> OApp (polish func, List.map polish args)
  | OBin (op, left, right) -> OBin (op, polish left, polish right)
  | OIf (cond, then_, else_) ->
      OIf (polish cond, polish then_, Option.map polish else_)
  | OTuple elements -> OTuple (List.map polish elements)
  | OList elements -> OList (List.map polish elements)
  | ONeg (spelling, operand) -> ONeg (spelling, polish operand)
  | OMatch (subject, made) ->
      OMatch
        ( polish subject,
          List.map
            (fun (p, guard, b) -> (p, Option.map polish guard, polish b))
            made )
  | OFun made -> OFun (List.map (fun (p, b) -> (p, polish b)) made)
  | OLambda (params, body) ->
      let body = polish body in
      let used = free body in
      OLambda (List.map (fun p -> pattern_polished p used) params, body)
  | OSeq (first, rest) -> OSeq (polish first, polish rest)
  | OEscape (exc, cell, bound, inner) -> OEscape (exc, cell, bound, polish inner)
  | OLet (bindings, body, recursive) ->
      let bindings = List.map polish_binding bindings in
      let body = polish body in
      (* A binding a sibling reads is read, even if the body does not --
         which is how one half of a mutually recursive pair earns its
         name. *)
      let used = free body in
      let used =
        if recursive then
          StringSet.union used (union_all (List.map free_in_binding bindings))
        else used
      in
      let bindings =
        List.map
          (fun b -> { b with bound = pattern_polished b.bound used })
          bindings
      in
      OLet (bindings, body, recursive)

(** binding with its unread parameters renamed and its value polished.
    obinding -> obinding *)
and polish_binding binding =
  let value = polish binding.value in
  let used = free value in
  { binding with params = List.map (fun p -> pattern_polished p used) binding.params; value }

(** Every name item reads from outside itself. oitem -> StringSet.t *)
let free_in_item item =
  match item with
  | OItemLet (bindings, recursive) ->
      let found = union_all (List.map free_in_binding bindings) in
      if recursive then
        StringSet.diff found
          (union_all
             (List.map (fun b -> StringSet.of_list (pattern_names b.bound)) bindings))
      else found
  | OItemUnit e -> free e

(** The names item binds. oitem -> StringSet.t *)
let item_names item =
  match item with
  | OItemLet (bindings, _) ->
      union_all
        (List.map (fun b -> StringSet.of_list (pattern_names b.bound)) bindings)
  | OItemUnit _ -> StringSet.empty

(** binding, renamed _name if no item in later reads it before one
    rebinds it -- and, where the module has an interface saying it is not
    exported either, if nothing reads it at all. `reads` are items whose
    reads keep the binding alive but whose bindings are not a rebinding
    of it: its own group.
    obinding -> [oitem] -> [oitem] -> bool -> obinding *)
let rename_dead binding reads later dead_if_unread =
  let binding = polish_binding binding in
  let names = StringSet.of_list (pattern_names binding.bound) in
  let renamed =
    { binding with bound = pattern_polished binding.bound StringSet.empty }
  in
  let alive =
    List.exists
      (fun item -> not (StringSet.is_empty (StringSet.inter names (free_in_item item))))
      reads
  in
  if alive then binding
  else
    let rec go later =
      match later with
      | [] -> if dead_if_unread then renamed else binding
      | item :: rest ->
          if not (StringSet.is_empty (StringSet.inter names (free_in_item item)))
          then binding
          else if not (StringSet.is_empty (StringSet.inter names (item_names item)))
          then renamed
          else go rest
    in
    go later

(** What else in a binding's own group could read it: its siblings, and
    its own value where the group is recursive -- a `let rec f` whose
    only reader is itself keeps its name, since renaming it would leave
    the call inside it naming nothing. Not recursive as an item, so that
    a name bound here shows as read rather than as bound.
    oitem -> obinding -> bool -> [oitem] *)
let rest_of item binding recursive =
  match item with
  | OItemLet (bindings, _) ->
      let others =
        if recursive then bindings else List.filter (fun b -> b != binding) bindings
      in
      if others = [] then [] else [ OItemLet (others, false) ]
  | _ -> []

(** The top level, polished, read back to front since a binding's
    liveness depends only on what comes after it. `keep` names the
    bindings the module exports, which are read by whoever imports it and
    so are never dead. `interfaced` says the module has an `.mli` beside
    it, which makes a binding this module neither exports nor reads dead
    rather than merely quiet -- without one, every top-level binding is
    exported and none of them is.
    [oitem] -> StringSet.t -> bool -> [oitem] *)
let polish_items all keep interfaced =
  List.mapi
    (fun index item ->
      match item with
      | OItemLet (bindings, recursive) ->
          let later = List.filteri (fun i _ -> i > index) all in
          OItemLet
            ( List.map
                (fun b ->
                  if
                    not
                      (StringSet.is_empty
                         (StringSet.inter (StringSet.of_list (pattern_names b.bound)) keep))
                  then b
                  else rename_dead b (rest_of item b recursive) later interfaced)
                bindings,
              recursive )
      | OItemUnit e -> OItemUnit (polish e))
    all

(* --- printer: OCaml AST -> OCaml source text ---

   Precedence, loosest to tightest. Only what this backend emits is
   listed; a child printed where a tighter level is required gets
   parentheses, which is the whole of the rule. *)

let p_seq = 1
let p_let = 2
let p_if = 3
let p_cmp = 4
let p_concat = 5
let p_add = 6
let p_mul = 7
let p_app = 8
let p_atom = 9

let op_level op =
  match op with
  | "=" | "<" | "<=" | ">" | ">=" -> p_cmp
  (* `@` joins lists and `^` joins strings; both associate to the right
     at the same level in OCaml. *)
  | "^" | "@" -> p_concat
  | "+" | "-" | "+." | "-." -> p_add
  | "*" | "/" | "*." | "/." -> p_mul
  | _ -> p_cmp

(* Where a refusal that belongs to no node in the source points. *)
let builtin_info = { file = "<ocaml>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** One type as OCaml source text. `name` is what a refusal names. A
    function type is curried, which is how this backend compiles a Pyking
    function of several parameters. typ -> string -> bool -> string *)
let rec type_text type_ name top =
  match type_ with
  | TInt _ -> "int"
  | TFloat _ -> "float"
  | TString _ -> "string"
  | TBool _ -> "bool"
  | TList (_, element, _) -> Printf.sprintf "%s list" (type_text element name false)
  | TTuple (_, [], _) -> "unit"
  | TTuple (_, elements, _) ->
      let inner =
        String.concat " * " (List.map (fun e -> type_text e name false) elements)
      in
      if top then inner else Printf.sprintf "(%s)" inner
  | TFunction (_, params, result, _, _, _, _) ->
      let params = if params = [] then [ TTuple (builtin_info, [], 0) ] else params in
      let arrow =
        String.concat " -> "
          (List.map (fun p -> type_text p name false) params
          @ [ type_text result name true ])
      in
      if top then arrow else Printf.sprintf "(%s)" arrow
  (* OCaml generalises a `val` of its own accord, so the quantifier is
     left off and the variables written as they are. *)
  | TForall (_, _, inner, _) -> type_text inner name top
  | TVar (_, variable, _, _) -> Printf.sprintf "'%s" variable
  | type_ ->
      unsupported builtin_info
        (Printf.sprintf
           "'%s' is exported at a type this backend cannot write in an OCaml \
            interface: %s"
           name (name_of type_))

(** A public name's type, as a `.mli` writes it. The whole of what OCaml
    is told about a module from outside, so a type OCaml cannot be given
    here is refused rather than guessed at. typ -> string -> string *)
let interface_type type_ name = type_text type_ name true

(** text with level's worth of indent prefixed to each non-blank line.
    string -> int -> string *)
let indent text level =
  let pad = String.concat "" (List.init level (fun _ -> "  ")) in
  String.concat "\n"
    (List.map
       (fun line -> if line = "" then line else pad ^ line)
       (String.split_on_char '\n' text))

let has_newline text = String.contains text '\n'

let left_trim text =
  let length = String.length text in
  let rec start i = if i < length && text.[i] = ' ' then start (i + 1) else i in
  let i = start 0 in
  String.sub text i (length - i)

(** e as OCaml source text, parenthesized if it binds looser than need.
    oexpr -> int -> int -> string *)
let rec pprint e need level =
  let text, level_of = pprint_bare e level in
  if level_of < need then "(" ^ text ^ ")" else text

(** (text, precedence) for e, unparenthesized. oexpr -> int
    -> (string, int) *)
and pprint_bare e level =
  match e with
  (* A negative literal has to be parenthesized wherever it is used, so
     it is given the loosest level and the rule above does the rest. *)
  | OInt value -> (string_of_int value, if value >= 0 then p_atom else p_cmp)
  | OFloat value ->
      (* OCaml reads back every text Builtin.float_text writes but three:
         its own spellings for the two infinities and a NaN. *)
      let text =
        if value <> value then "Stdlib.nan"
        else if value = infinity then "Stdlib.infinity"
        else if value = neg_infinity then "Stdlib.neg_infinity"
        else Builtin.float_text value
      in
      (text, if value >= 0.0 then p_atom else p_cmp)
  | OStr value -> (quote value, p_atom)
  | OBool value -> ((if value then "true" else "false"), p_atom)
  | OUnit -> ("()", p_atom)
  | OVar name -> (name, p_atom)
  (* `!` is a prefix operator and binds tighter than anything else, so a
     dereference is an atom wherever it stands. *)
  | ODeref name -> ("!" ^ name, p_atom)
  | ORef value -> (Printf.sprintf "ref %s" (pprint value p_atom level), p_app)
  | OAssign (name, value) ->
      (Printf.sprintf "%s := %s" name (pprint value (p_let + 1) level), p_let)
  (* Always parenthesized, so it is an atom wherever it stands. *)
  | OTuple elements ->
      (* A `,` binds tighter than every form that extends to the right,
         so `if c then a else b, x` is one `if` yielding a pair. *)
      ( Printf.sprintf "(%s)"
          (String.concat ", "
             (List.map (fun el -> pprint el (p_if + 1) level) elements)),
        p_atom )
  | OList elements ->
      (* A `let`, `match` or sequence runs past the `;` that separates
         two elements; an `if` stops at it, so it needs no parentheses. *)
      ( Printf.sprintf "[%s]"
          (String.concat "; "
             (List.map (fun el -> pprint el p_if level) elements)),
        p_atom )
  | ONeg (spelling, operand) ->
      (* OCaml's unary minus on an application needs no parentheses
         (`-f x` is `-(f x)`), but on anything looser it does. *)
      let inner = pprint operand p_app level in
      (* A symbol straight after this one would lex as a single operator
         -- `--`, or `-!` before a dereference -- whatever the precedence
         says, so an operand that starts with one is parenthesized to
         break them apart. *)
      if String.length inner > 0 && String.contains "!$%&*+-./:<=>?@^|~" inner.[0]
      then
        (Printf.sprintf "%s(%s)" spelling inner, p_app)
      else (Printf.sprintf "%s%s" spelling inner, p_app)
  | OMatch (subject, made) ->
      let pad = String.concat "" (List.init level (fun _ -> "  ")) in
      let head = Printf.sprintf "match %s with" (pprint subject (p_seq + 1) level) in
      ( String.concat "\n"
          (head
          :: List.map
               (fun (p, guard, b) ->
                 let tested =
                   match guard with
                   | None -> p
                   | Some guard ->
                       Printf.sprintf "%s when %s" p
                         (pprint guard (p_seq + 1) (level + 1))
                 in
                 Printf.sprintf "%s  | %s -> %s" pad tested
                   (pprint b (p_seq + 1) (level + 1)))
               made),
        p_seq )
  | OLambda (params, body) ->
      ( Printf.sprintf "fun %s -> %s"
          (String.concat " "
             (List.map pattern_text
                (match params with [] -> [ OPatTuple [] ] | params -> params)))
          (pprint body (p_seq + 1) level),
        p_seq )
  | OFun made ->
      ( Printf.sprintf "function %s"
          (String.concat " "
             (List.map
                (fun (p, b) ->
                  Printf.sprintf "| %s -> %s" p (pprint b (p_seq + 1) level))
                made)),
        p_seq )
  | OIgnore inner ->
      (Printf.sprintf "ignore %s" (pprint inner p_atom level), p_app)
  | OEscape (exc, cell, bound, inner) ->
      (* The exception carries nothing, so OCaml needs no type written
         for it: the value travels in the cell, whose type it infers
         from what is put there. *)
      let pad = String.concat "" (List.init level (fun _ -> "  ")) in
      let recovered =
        Printf.sprintf
          "with %s -> (match !%s with Some %s -> %s | None -> assert false)"
          exc cell bound bound
      in
      ( String.concat ""
          [
            Printf.sprintf "let %s = ref None in\n" cell;
            Printf.sprintf "%slet exception %s in\n" pad exc;
            Printf.sprintf "%stry\n" pad;
            indent (left_trim (pprint inner p_seq (level + 1))) (level + 1);
            "\n";
            pad;
            recovered;
          ],
        p_seq )
  | OApp (func, args) ->
      (* Application associates to the left in OCaml, so a call of a call
         needs no parentheses: `compose f g 5` *is* `(compose f g) 5`,
         and that is how it is written. *)
      ( String.concat " "
          (pprint func p_app level :: List.map (fun a -> pprint a p_atom level) args),
        p_app )
  | OBin (op, left, right) ->
      let level_ = op_level op in
      (* Arithmetic and comparison associate to the left in OCaml, so
         only the right side of one of those needs parentheses. `^` needs
         neither: it associates to the right *and* joining strings is
         associative, so a chain of them prints flat however the
         translation happened to nest it. *)
      let right_need = if op = "^" then level_ else level_ + 1 in
      ( Printf.sprintf "%s %s %s" (pprint left level_ level) op
          (pprint right right_need level),
        level_ )
  | OIf (cond, then_, else_) -> (pprint_if cond then_ else_ level, p_if)
  | OLet (bindings, body, recursive) ->
      let keyword = if recursive then "let rec" else "let" in
      let lines =
        List.mapi
          (fun index binding ->
            pprint_binding binding (if index = 0 then keyword else "and") 0)
          bindings
      in
      let head = String.concat "\n" lines ^ " in" in
      let body_text = pprint body p_seq level in
      (* A short binding of a plain value reads as one line -- `let x = e
         in body` -- while a function definition keeps its body
         underneath, which is where a reader looks for it. *)
      let one_line = Printf.sprintf "%s %s" head body_text in
      if
        List.length bindings = 1
        && (List.hd bindings).params = []
        && (not (has_newline one_line))
        && String.length one_line + (2 * level) <= 66
      then (one_line, p_let)
      else (Printf.sprintf "%s\n%s" head body_text, p_let)
  | OSeq (first, rest) ->
      let head = pprint first (p_seq + 1) level in
      let tail = pprint rest p_seq level in
      let one_line = Printf.sprintf "%s; %s" head tail in
      if (not (has_newline one_line)) && String.length one_line + (2 * level) <= 66
      then (one_line, p_seq)
      else (Printf.sprintf "%s;\n%s" head tail, p_seq)

(** "keyword name params =" with its value, indented to level.
    obinding -> string -> int -> string *)
and pprint_binding binding keyword level =
  let pad = String.concat "" (List.init level (fun _ -> "  ")) in
  let head =
    String.concat " "
      ((keyword :: pattern_text binding.bound
        :: List.map pattern_text binding.params))
    ^ " ="
  in
  let value = pprint binding.value p_seq (level + 1) in
  if
    (not (has_newline value))
    && String.length pad + String.length head + 1 + String.length value <= 72
  then Printf.sprintf "%s%s %s" pad head (left_trim value)
  else Printf.sprintf "%s%s\n%s" pad head (indent value (level + 1))

(** One arm of an if: "head body" if it fits on a line, else body
    indented underneath. string -> string -> int -> string *)
and pprint_arm head body level =
  if
    (not (has_newline body))
    && String.length head + 1 + String.length body + (2 * level) <= 70
  then Printf.sprintf "%s %s" head body
  else Printf.sprintf "%s\n%s" head (indent body 1)

(** if c then a else b, one line if it fits, else one arm per line as a
    flat else-if chain. oexpr -> oexpr -> oexpr option -> int -> string *)
and pprint_if cond then_ else_ level =
  let condition = pprint cond p_cmp level in
  let then_text = pprint then_ (p_if + 1) level in
  let one_line =
    match else_ with
    | Some else_ ->
        Printf.sprintf "if %s then %s else %s" condition then_text
          (pprint else_ p_if level)
    | None -> Printf.sprintf "if %s then %s" condition then_text
  in
  if (not (has_newline one_line)) && String.length one_line + (2 * level) <= 70
  then one_line
  else
    (* Too long for one line: flatten the `else if` chain and give each
       arm a line of its own. *)
    let rec flatten cond then_ else_ made =
      let made = made @ [ (cond, then_) ] in
      match else_ with
      | Some (OIf (c, t, e)) -> flatten c t e made
      | else_ -> (made, else_)
    in
    let made, final = flatten cond then_ else_ [] in
    let lines =
      List.mapi
        (fun index (arm_cond, arm_then) ->
          let head =
            Printf.sprintf "%s %s then"
              (if index = 0 then "if" else "else if")
              (pprint arm_cond p_cmp level)
          in
          pprint_arm head (pprint arm_then (p_if + 1) level) level)
        made
    in
    let lines =
      match final with
      | None -> lines
      | Some final -> lines @ [ pprint_arm "else" (pprint final p_if level) level ]
    in
    String.concat "\n" lines

(** item as OCaml source text. oitem -> string *)
let pprint_item item =
  match item with
  | OItemLet (bindings, recursive) ->
      let keyword = if recursive then "let rec" else "let" in
      String.concat "\n"
        (List.mapi
           (fun index binding ->
             pprint_binding binding (if index = 0 then keyword else "and") 0)
           bindings)
  | OItemUnit e ->
      pprint_binding { bound = OPatName "()"; params = []; value = e } "let" 0

(** The interface a module the program imports is seen through: one `val`
    per name it exports, and nothing else, which is what makes everything
    else in the file private. oprogram -> string -> string *)
let pprint_ocaml_interface program source =
  let parts =
    [
      Printf.sprintf
        "(* Generated from %s by the Pyking compiler. Do not edit. *)" source;
      Printf.sprintf "(* What the module '%s' exports; everything else in"
        program.program_name;
      "   the file beside this one is private to it. *)";
    ]
  in
  String.concat "\n"
    (parts
    @ List.concat_map
        (fun (name, type_text) -> [ ""; Printf.sprintf "val %s : %s" name type_text ])
        program.interface)
  ^ "\n"

(** The whole module: a header, the prelude if needed, and the top-level
    items. oprogram -> string -> string *)
let pprint_ocaml_program program source =
  let parts =
    [
      Printf.sprintf
        "(* Generated from %s by the Pyking compiler. Do not edit. *)" source;
    ]
  in
  let parts =
    parts
    @
    if program.main then
      [
        Printf.sprintf "(* Target: %s. Compile with:  ocamlopt <this file>" target;
        "   or run it directly with:      ocaml <this file> *)";
      ]
    else
      [
        Printf.sprintf
          "(* Target: ocaml5.5. The module '%s' of the program; compile it\n   \
           before the ones that import it. *)"
          program.program_name;
      ]
  in
  let parts =
    parts @ if program.needs_list_printer then [ ""; list_printer_def ] else []
  in
  let parts = parts @ if program.needs_quote then [ ""; quote_helper_def ] else [] in
  let parts = parts @ if program.needs_range then [ ""; range_helper_def ] else [] in
  let parts =
    parts @ if program.needs_float then [ ""; float_helper_def ] else []
  in
  let parts =
    parts @ List.concat_map (fun item -> [ ""; pprint_item item ]) program.items
  in
  String.concat "\n" parts ^ "\n"

(** Translates one module of a program to an oprogram, reading the types
    the checker worked out rather than inferring any. pyk.ml runs the
    checker and hands the table here, so a program that does not check
    has been refused before this is called. `context` says what is true
    of the module only as part of a program.
    [stmt] -> typ IntMap.t -> Module.context -> oprogram *)
let translate_program stmts tmap (context : Module.context) =
  let own_sigmap =
    match List.assoc_opt context.context_name context.sigmaps with
    | Some sigmap -> sigmap
    | None -> []
  in
  (* Only what this file defines. A module is up to two files, and the
     names its declaration half offers are the implementation's: an
     importer reaches those through `<Module>_external`, so naming them
     in this interface would promise something this file never binds. *)
  let own_external =
    Option.value
      (List.assoc_opt context.context_name context.external_fields)
      ~default:[]
  in
  let exported =
    if context.main then []
    else
      (* The sigmap names what the *source* exports; what this file
         exports is the plain name the overloading pass gave it
         (docs/overloading.md). *)
      List.filter_map
        (fun (name, _, _) ->
          if List.mem name own_external then None
          else Some (Names.renamed name))
        own_sigmap
  in
  let names = plan_names stmts exported in
  let names =
    List.fold_left
      (fun names (local, reached) -> SMap.add local reached names)
      names (imported_names context.external_fields stmts)
  in
  let ctx =
    {
      tmap;
      printing = Analyses.effects stmts;
      prefix = unused_prefix stmts;
      refs = StringSet.empty;
      escape = None;
      specialisations = specialisations stmts tmap;
      specialised = [];
      loops = [];
      modules =
        List.filter_map
          (fun statement ->
            match statement with
            | SImport (_, module_, name, false, _, _) -> Some (name, module_)
            | _ -> None)
          stmts;
      external_fields = context.external_fields;
      own_module = context.context_name;
      own_external =
        Option.value
          (List.assoc_opt context.context_name context.external_fields)
          ~default:[];
      names;
    }
  in
  let acc =
    {
      temporaries = 0;
      needs_quote = false;
      needs_list_printer = false;
      needs_float = false;
      needs_range = false;
    }
  in
  let built, acc = items ctx acc stmts in
  let keep =
    List.fold_left
      (fun set name -> StringSet.add (public_name name) set)
      StringSet.empty exported
  in
  {
    items = polish_items built keep ((not context.main) && context.separate);
    needs_list_printer = acc.needs_list_printer;
    needs_quote = acc.needs_quote;
    needs_float = acc.needs_float;
    needs_range = acc.needs_range;
    program_name = context.context_name;
    main = context.main;
    interface =
      List.map
        (fun name ->
          ( public_name name,
            interface_type
              (List.find_map
                 (fun (n, t, _) ->
                   if Names.renamed n = name then
                     Some (Typesystem.without_implicits t)
                   else None)
                 own_sigmap
              |> Option.get)
              name ))
        exported;
  }
