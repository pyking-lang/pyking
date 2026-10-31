(** Warnings: what a program that checks may still have wrong. Today
    that is a name bound and never used -- a binding, a function, a
    `var`, a parameter, a loop variable or a pattern variable -- and
    the binding that shadows a name in an enclosing block and is then
    never used, which is what writing `x = ...` for `x := ...` looks
    like. See docs/warnings.md, and PYKING.md ("Warnings").

    The pass is one walk over a module's statements as the checker saw
    them, binding names exactly as analyses.ml and scopes.ml do: every
    `def` of a block before any of the block, everything else from where
    it is written on. Each use of a name is charged to the binding it
    reaches. A call that overload resolution or an implicit argument
    settled is charged through what the checker recorded (`qmap`), so
    a definition reached only that way is used.

    A function is used if something that runs calls it: a use outside
    any function, or one inside a function that is itself used. A
    function that only calls itself, or a group of functions that only
    call one another, is reported -- each one whose every use is inside
    that group. A function used only by another unused one is not
    reported as well: that one is the one to look at.

    Which warnings are reported, and which of them are errors, is a
    `config`, built from GCC-style flags: `-W<name>`, `-Wno-<name>`,
    `-Wall`, `-w`, `-Werror`, `-Wno-error`, `-Werror=<name>` and
    `-Wno-error=<name>`, applied in order.

    Data structures:
      kind -- one warning: its flag names it.
      config -- which warnings are on, and which are errors.
      warning -- one warning found: where, which, what it says, and
        whether it is an error.

    Functions:
      kinds -- every kind, in the order they are listed.
      name kind / of_name name -- a kind's flag name, and back.
      description kind -- what a kind reports, in a sentence.
      default_on kind -- whether a kind is on with no flag given.
      default -- the config with no flag given.
      enabled config kind / is_error config kind -- what a config says.
      flag config text -- one flag applied to a config.
      is_flag text -- whether a command-line word is a warning flag.
      of_flags flags -- the config a list of flags makes.
      to_flags config -- the shortest flags that make a config.
      check config tokens stmts -- every warning in a module.
      format w -- a warning as `'file' r:c-r:c Warning: ... [-Wname]`.
      has_error ws -- whether any of the warnings is an error. *)

open Syntax

module SMap = Map.Make (String)

(* --- the warnings, and the flags that turn them on --- *)

type kind =
  | Unused_binding
  | Unused_function
  | Unused_var
  | Shadowed_update
  | Unused_pattern_var
  | Unused_parameter
  | Unused_loop_var

let kinds =
  [
    Unused_binding;
    Unused_function;
    Unused_var;
    Shadowed_update;
    Unused_pattern_var;
    Unused_parameter;
    Unused_loop_var;
  ]

let name = function
  | Unused_binding -> "unused-binding"
  | Unused_function -> "unused-function"
  | Unused_var -> "unused-var"
  | Shadowed_update -> "shadowed-update"
  | Unused_pattern_var -> "unused-pattern-var"
  | Unused_parameter -> "unused-parameter"
  | Unused_loop_var -> "unused-loop-var"

let of_name text = List.find_opt (fun k -> name k = text) kinds

let description = function
  | Unused_binding ->
      "A name bound with '=' (or a 'let') that nothing in its scope uses."
  | Unused_function ->
      "A function defined with 'def' that is never called or passed on, \
       or that only calls itself."
  | Unused_var ->
      "A mutable variable declared with 'var' that is never read: \
       writing to it with ':=' does not count as reading it."
  | Shadowed_update ->
      "A name bound with '=' inside a block, never used, while the same \
       name is bound outside the block: an update written as a new \
       binding. Says how to make it a variable instead."
  | Unused_pattern_var ->
      "A name a 'case' pattern binds that its arm never uses."
  | Unused_parameter ->
      "A parameter of a function or a lambda that its body never uses."
  | Unused_loop_var ->
      "A loop's accumulator, a 'for' variable, or a name a comprehension \
       binds, that the loop never uses."

let default_on = function
  | Unused_binding | Unused_function | Unused_var | Shadowed_update -> true
  | Unused_pattern_var | Unused_parameter | Unused_loop_var -> false

(* Which warnings are on, which kinds an `-Werror=` or `-Wno-error=` said
   something about, and what `-Werror` says of the rest. *)
type config = { on : kind list; errors : (kind * bool) list; all_errors : bool }

let default = { on = List.filter default_on kinds; errors = []; all_errors = false }

let enabled config kind = List.mem kind config.on

let is_error config kind =
  match List.assoc_opt kind config.errors with
  | Some error -> error
  | None -> config.all_errors

let switch config kind on =
  let rest = List.filter (fun k -> k <> kind) config.on in
  { config with on = (if on then List.filter (fun k -> k = kind || List.mem k rest) kinds else rest) }

let say_error config kind error =
  { config with errors = (kind, error) :: List.remove_assoc kind config.errors }

let names_list () = String.concat ", " (List.map name kinds)

let flag config text =
  let unknown which =
    Error
      (Printf.sprintf "'%s' names no warning: the warnings are %s, and 'all'" which
         (names_list ()))
  in
  let after prefix = String.sub text (String.length prefix) (String.length text - String.length prefix) in
  let starts prefix = String.starts_with ~prefix text in
  if text = "-Wall" then Ok { config with on = kinds }
  else if text = "-w" then Ok { config with on = [] }
  else if text = "-Werror" then Ok { config with all_errors = true }
  else if text = "-Wno-error" then Ok { config with all_errors = false }
  else if starts "-Werror=" then
    match after "-Werror=" with
    | "all" -> Ok { on = kinds; errors = []; all_errors = true }
    | which -> (
        (* As in GCC, making a warning an error turns it on. *)
        match of_name which with
        | Some kind -> Ok (say_error (switch config kind true) kind true)
        | None -> unknown which)
  else if starts "-Wno-error=" then
    match after "-Wno-error=" with
    | "all" -> Ok { config with errors = List.map (fun k -> (k, false)) kinds }
    | which -> (
        match of_name which with
        | Some kind -> Ok (say_error config kind false)
        | None -> unknown which)
  else if starts "-Wno-" then
    match after "-Wno-" with
    | "all" -> Ok { config with on = [] }
    | which -> (
        match of_name which with Some kind -> Ok (switch config kind false) | None -> unknown which)
  else if starts "-W" then
    let which = after "-W" in
    match of_name which with Some kind -> Ok (switch config kind true) | None -> unknown which
  else Error (Printf.sprintf "'%s' is not a warning flag" text)

let is_flag text = text = "-w" || (String.starts_with ~prefix:"-W" text && String.length text > 2)

let of_flags flags =
  List.fold_left
    (fun config text -> match config with Error _ -> config | Ok config -> flag config text)
    (Ok default) flags

let to_flags config =
  let turned =
    List.filter_map
      (fun k ->
        match (enabled config k, default_on k) with
        | true, false -> Some ("-W" ^ name k)
        | false, true -> Some ("-Wno-" ^ name k)
        | _ -> None)
      kinds
  in
  let errors =
    List.filter_map
      (fun (k, error) ->
        if error = config.all_errors then None
        else Some ((if error then "-Werror=" else "-Wno-error=") ^ name k))
      (List.sort compare config.errors)
  in
  turned @ (if config.all_errors then [ "-Werror" ] else []) @ errors

(* --- what was found --- *)

type warning = { at : Lexer.info; kind : kind; message : string; error : bool }

let format w =
  Printf.sprintf "%s %s: %s [%s]" (Lexer.pprint_info w.at)
    (if w.error then "Error" else "Warning")
    w.message
    ((if w.error then "-Werror=" else "-W") ^ name w.kind)

let has_error warnings = List.exists (fun w -> w.error) warnings

exception Refused of warning list

(* --- the walk --- *)

(* What a binding is, as far as which warning it may become goes. *)
type role =
  | RValue (* name = ..., let name = ... in *)
  | RFunction
  | RVariable
  | RPattern
  | RParameter of string option (* the function's name; None for a lambda *)
  | RLoop of string (* "the loop" or "the comprehension" *)

(* One name bound: where, how, whether anything reads it, and -- for an
   `=` in a nested block -- the binding of the same name it shadows
   from outside that block. *)
type binding = {
  id : int;
  bname : string;
  span : Lexer.info;
  role : role;
  block : int;
  mutable exempt : bool;
  shadows : binding option;
  mutable read : bool;
  mutable written : bool;
}

(* What the walk is told, and what it collects as it goes. *)
type walk = {
  tokens : Lexer.token list;
  qmap : Typesystem.resolution IntMap.t;
  toplevel_used : bool;
  public : string list;
  display : string -> string;
  mutable next : int;
  mutable all : binding list;
  (* every use of a function: the function, and the functions the use
     is inside, innermost first *)
  mutable calls : (binding * binding list) list;
  (* every function, with the function it is defined in *)
  mutable parents : (binding * binding option) list;
}

(* The walk's position: what is in scope, which block, and which
   functions the walk is inside, innermost first. *)
type here = { env : binding SMap.t; block : int; inside : binding list }

let fresh w =
  w.next <- w.next + 1;
  w.next

(** The span of the first identifier `name` at or after where a span
    starts. A submodule's member is written `shapes.area` and bound as
    `shapes__area`, and its span is that of `area`. *)
let name_span w name (from : Lexer.info) =
  let written = w.display name in
  let last =
    match String.rindex_opt written '.' with
    | Some at -> String.sub written (at + 1) (String.length written - at - 1)
    | None -> written
  in
  let found =
    List.find_map
      (fun token ->
        match token with
        | Lexer.TokIdent (i, n)
          when (n = name || n = last) && compare (i.row1, i.col1) (from.row1, from.col1) >= 0 ->
            Some i
        | _ -> None)
      w.tokens
  in
  match found with
  | Some i -> i
  | None -> { from with row2 = from.row1; col2 = from.col1 + String.length name }

let generated name =
  Desugar_args.generated_name name || Elaborate.generated_name name

let bind w here ?(toplevel = false) role name span =
  let shadows =
    match (role, SMap.find_opt name here.env) with
    | RValue, Some outer when outer.block <> here.block -> Some outer
    | _ -> None
  in
  let b =
    {
      id = fresh w;
      bname = name;
      span;
      role;
      block = here.block;
      exempt =
        String.starts_with ~prefix:"_" name
        || generated name
        || (toplevel && (w.toplevel_used || List.mem name w.public));
      shadows;
      read = false;
      written = false;
    }
  in
  w.all <- b :: w.all;
  ({ here with env = SMap.add name b here.env }, b)

let bind_ w here ?toplevel role name span = fst (bind w here ?toplevel role name span)

let charge w here b =
  match b.role with
  | RFunction -> w.calls <- (b, here.inside) :: w.calls
  | _ -> b.read <- true

(** A name used: charged to what it reaches. A name no binding holds is
    an overloaded one written without its qualifier, or one the walk
    does not follow (a builtin, an earlier REPL entry); the first is
    charged to every definition it may mean. *)
let use w here name =
  match SMap.find_opt name here.env with
  | Some b -> charge w here b
  | None ->
      SMap.iter
        (fun bound b -> if Names.is_qualified bound && Names.base bound = name then charge w here b)
        here.env

(** What the checker settled at one node: the definition a call reaches,
    and every implicit argument it supplies. *)
let resolved w here sym =
  let rec argument = function
    | Typesystem.Direct (n, _) -> use w here n
    | Typesystem.Wrapped (n, _, _, args) ->
        use w here n;
        List.iter argument args
  in
  match IntMap.find_opt sym w.qmap with
  | Some (Typesystem.Call (target, args)) ->
      (match target with Some (n, _) -> use w here n | None -> ());
      List.iter argument args
  | Some (Typesystem.Adapted (_, _, args)) -> List.iter argument args
  | None -> ()

let rec target_names = function
  | TargetName (i, n, _) -> [ (n, i) ]
  | TargetTuple (_, ts, _) -> List.concat_map target_names ts

let rec pattern_names w = function
  | PCapture (i, n, _) -> [ (n, name_span w n i) ]
  | PTuple (_, ps, _) -> List.concat_map (pattern_names w) ps
  | PList (_, before, rest, after, _) ->
      List.concat_map (pattern_names w) before
      @ (match rest with Some (ListRest (i, Some n, _)) -> [ (n, name_span w n i) ] | _ -> [])
      @ List.concat_map (pattern_names w) after
  | PText (i, _, Some n, _, _) -> [ (n, name_span w n i) ]
  | PConstructor (_, _, _, ps, named, _) -> List.concat_map (pattern_names w) (ps @ List.map snd named)
  | POr (_, first :: _, _) -> pattern_names w first
  | PAs (i, inner, n, _) ->
      let inner_names = pattern_names w inner in
      (* The name after `as` is the last one written in the pattern. *)
      let after = { i with row1 = i.row2; col1 = 0 } in
      let span = name_span w n (if List.mem_assoc n inner_names then after else i) in
      inner_names @ [ (n, span) ]
  | POr (_, [], _) | PInt _ | PString _ | PChar _ | PBool _ | PWildcard _ | PText _ -> []

let param_span (Param (i, n, _, _, _)) = { i with row2 = i.row1; col2 = i.col1 + String.length n }

let bind_params w here role params =
  List.fold_left
    (fun here (Param (_, n, _, _, _) as p) -> bind_ w here role n (param_span p))
    here params

let rec expr w here e =
  let go = expr w here in
  resolved w here (expr_sym e);
  match e with
  | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ -> ()
  | EVar (_, n, _) -> use w here n
  | EAdd (_, a, b, _) | ESub (_, a, b, _) | EMul (_, a, b, _) | EDiv (_, a, b, _)
  | EConcat (_, a, b, _) | ELessThan (_, a, b, _) | ELessThanEq (_, a, b, _)
  | EGreatThan (_, a, b, _) | EGreatThanEq (_, a, b, _) | EEq (_, a, b, _)
  | EBinary (_, _, a, b, _) | EIndex (_, a, b, _) ->
      go a;
      go b
  | ENeg (_, a, _) | EUnary (_, _, a, _) | EField (_, a, _, _) -> go a
  | ECall (_, f, args, s) ->
      (* A call overload resolution settled is charged to the one
         definition it reaches, above; its unqualified name, walked, would
         be charged to every definition it may mean. *)
      (match (f, IntMap.find_opt s w.qmap) with
      | EVar _, Some (Typesystem.Call (Some _, _)) -> ()
      | _ -> go f);
      List.iter go (arg_exprs args)
  | EList (_, es, _) | ETuple (_, es, _) -> List.iter go es
  | EIf (_, c, a, b, _) ->
      go c;
      go a;
      go b
  | EQualified (_, m, n, _) ->
      (* A submodule's member is bound under a plain name already; one
         of an imported module is that module's to report. *)
      use w here (m ^ "." ^ n)
  | EListComp (_, body, clauses, _) ->
      let inner = { here with block = fresh w } in
      let inner =
        List.fold_left
          (fun inner clause ->
            match clause with
            | CompFor (_, pattern, sequence, _) ->
                expr w inner sequence;
                List.fold_left
                  (fun inner (n, span) -> bind_ w inner (RLoop "the comprehension") n span)
                  inner (pattern_names w pattern)
            | CompIf (_, c, _) ->
                expr w inner c;
                inner)
          inner clauses
      in
      expr w inner body
  | ELambda (_, params, body, _) ->
      let inner = bind_params w { here with block = fresh w } (RParameter None) params in
      expr w inner body
  | ELet (_, target, _, value, body, _) ->
      go value;
      let inner =
        List.fold_left (fun inner (n, span) -> bind_ w inner RValue n span) { here with block = fresh w }
          (target_names target)
      in
      expr w inner body
  | EConstruct (_, _, _, args, _) -> List.iter go (arg_exprs args)

(** A nested block, in a scope of its own. *)
and block w here stmts = ignore (statements w { here with block = fresh w } stmts)

(** A block's statements in the block `here` names: its `def`s first,
    then each statement in turn. Answers the scope after the last. *)
and statements w here stmts =
  let toplevel = here.inside = [] && here.block = 0 in
  let here =
    List.fold_left
      (fun here stmt ->
        match stmt with
        | SFunctionDef (i, n, _, _, _, _, public, _, _) ->
            let here, b = bind w here ~toplevel RFunction n (name_span w n i) in
            if public && toplevel then b.exempt <- true;
            w.parents <- (b, match here.inside with p :: _ -> Some p | [] -> None) :: w.parents;
            here
        | _ -> here)
      here stmts
  in
  List.fold_left (fun here stmt -> statement w here ~toplevel stmt) here stmts

and statement w here ~toplevel stmt =
  let bind_target here role public target =
    List.fold_left
      (fun here (n, span) ->
        let here, b = bind w here ~toplevel role n span in
        if public then b.exempt <- true;
        here)
      here (target_names target)
  in
  match stmt with
  | SLet (_, target, e, _, _, public, _) ->
      expr w here e;
      bind_target here RValue public target
  | SLetStmt (_, target, inner, _, _, public) ->
      ignore (statement w here ~toplevel:false inner);
      bind_target here RValue public target
  | SVar (i, n, e, _) ->
      expr w here e;
      bind_ w here ~toplevel RVariable n (name_span w n i)
  | SMutate (_, n, e, _) ->
      expr w here e;
      Option.iter (fun b -> b.written <- true) (SMap.find_opt n here.env);
      here
  | SReturn (_, e, _) | SExprStmt (_, e, _) ->
      expr w here e;
      here
  | SBreak (_, Some e, _) | SContinue (_, Some e, _) ->
      expr w here e;
      here
  | SReturnStmt (_, inner, _) ->
      ignore (statement w here ~toplevel:false inner);
      here
  | SLoop (_, target, init, _, iter, body, _) ->
      Option.iter (expr w here) init;
      let inner = { here with block = fresh w } in
      let inner =
        match target with
        | Some t ->
            List.fold_left (fun inner (n, span) -> bind_ w inner (RLoop "the loop") n span) inner
              (target_names t)
        | None -> inner
      in
      let inner =
        match iter with
        | Some (ForIn (fi, n, sequence, _)) ->
            expr w here sequence;
            bind_ w inner (RLoop "the loop") n (name_span w n fi)
        | Some (WhileTest (_, c, _)) ->
            expr w inner c;
            inner
        | None -> inner
      in
      ignore (statements w inner body);
      here
  | SIf (_, c, then_, else_, _) ->
      expr w here c;
      block w here then_;
      Option.iter (block w here) else_;
      here
  | SMatch (_, subject, cases, _) ->
      expr w here subject;
      List.iter
        (fun (MatchCase (_, pattern, guard, body, _)) ->
          let inner =
            List.fold_left
              (fun inner (n, span) -> bind_ w inner RPattern n span)
              { here with block = fresh w } (pattern_names w pattern)
          in
          Option.iter (expr w inner) guard;
          ignore (statements w inner body))
        cases;
      here
  | SFunctionDef (_, n, params, body, _, _, _, implicits, _) ->
      List.iter (fun (Param (_, _, _, default, _)) -> Option.iter (expr w here) default) params;
      let self = SMap.find n here.env in
      let inner = { here with block = fresh w; inside = self :: here.inside } in
      let inner = bind_params w inner (RParameter (Some n)) (params @ implicits) in
      ignore (statements w inner body);
      here
  | SFunctionSig _ | SDatatype _ | SImport _ | SBreak _ | SContinue _ -> here

(* --- what is reported --- *)

(** The functions something that runs calls: those used outside any
    function, and those used inside one that is itself used. *)
let live_functions w =
  let live = Hashtbl.create 16 in
  List.iter (fun b -> if b.role = RFunction && b.exempt then Hashtbl.replace live b.id ()) w.all;
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun (f, inside) ->
        if not (Hashtbl.mem live f.id) then
          let counts =
            (not (List.exists (fun g -> g.id = f.id) inside))
            && match inside with [] -> true | g :: _ -> Hashtbl.mem live g.id
          in
          if counts then (
            Hashtbl.replace live f.id ();
            changed := true))
      w.calls
  done;
  live

(** Whether `g` is reached from `f`: called in its body, or defined in
    it, one step after another. *)
let reaches w f g =
  let next x =
    List.filter_map
      (fun (callee, inside) -> match inside with y :: _ when y.id = x.id -> Some callee | _ -> None)
      w.calls
    @ List.filter_map (fun (child, parent) -> match parent with Some p when p.id = x.id -> Some child | _ -> None)
        w.parents
  in
  let seen = Hashtbl.create 16 in
  let rec go x =
    if x.id = g.id then true
    else if Hashtbl.mem seen x.id then false
    else (
      Hashtbl.replace seen x.id ();
      List.exists go (next x))
  in
  List.exists go (next f)

let check ?(qmap = IntMap.empty) ?(toplevel_used = false) ?(public = []) ?(display = Fun.id)
    ?(outer = []) config tokens stmts =
  let w = { tokens; qmap; toplevel_used; public; display; next = 0; all = []; calls = []; parents = [] } in
  (* What is in scope before the first statement -- an earlier REPL
     entry's names -- is bound in a block of its own, outside this one,
     and is never reported here. *)
  let around =
    List.fold_left
      (fun here (n, span) ->
        let here, b = bind w here RValue n span in
        b.exempt <- true;
        here)
      { env = SMap.empty; block = -1; inside = [] }
      outer
  in
  let here = { around with block = 0 } in
  ignore (statements w here stmts);
  let live = live_functions w in
  let say kind at message =
    if enabled config kind then Some { at; kind; message; error = is_error config kind } else None
  in
  let line (i : Lexer.info) = i.row1 in
  let report b =
    let shown = display b.bname in
    match b.role with
    | _ when b.exempt -> None
    | RFunction ->
        if Hashtbl.mem live b.id then None
        else
          (* Reported unless a function outside its own group uses it:
             that one is unused too, and is the one reported. *)
          let users = List.filter_map (fun (f, inside) -> if f.id = b.id then Some inside else None) w.calls in
          let outside =
            List.exists
              (fun inside ->
                match inside with
                | g :: _ when not (List.exists (fun x -> x.id = b.id) inside) -> not (reaches w b g)
                | _ -> false)
              users
          in
          if outside then None
          else
            let callers =
              List.sort_uniq compare
                (List.filter_map
                   (fun inside ->
                     match inside with
                     | g :: _ when not (List.exists (fun x -> x.id = b.id) inside) -> Some (display g.bname)
                     | _ -> None)
                   users)
            in
            let why =
              match (users, callers) with
              | [], _ -> ""
              | _, [] -> " (it is only called from inside itself)"
              | _, callers ->
                  Printf.sprintf " (it is only called from %s, which %s never used either)"
                    (String.concat " and " (List.map (fun c -> "'" ^ c ^ "'") callers))
                    (if List.length callers = 1 then "is" else "are")
            in
            say Unused_function b.span (Printf.sprintf "Function '%s' is defined but never used%s." shown why)
    | _ when b.read -> None
    | RValue -> (
        let unused =
          Printf.sprintf "Unused binding '%s', bound on line %d: it is never used in its scope." shown
            (line b.span)
        in
        match b.shadows with
        | Some outer when enabled config Shadowed_update ->
            say Shadowed_update b.span
              (Printf.sprintf
                 "%s Did you try to update %s as a variable? Name %s is bound on line %d, but is \
                  not defined as a mutable variable. The declaration on line %d is shadowing %s, \
                  and then never used in the scope. To update it, declare it with 'var %s = ...' \
                  (after 'use mutation') and write '%s := ...'."
                 unused shown shown (line outer.span) (line b.span) shown shown shown)
        | _ -> say Unused_binding b.span unused)
    | RVariable ->
        say Unused_var b.span
          (Printf.sprintf "Unused variable '%s', declared on line %d: it is %s." shown (line b.span)
             (if b.written then "updated with ':=' but never read" else "never read"))
    | RPattern ->
        say Unused_pattern_var b.span
          (Printf.sprintf "Unused pattern variable '%s', bound on line %d: its case never uses it."
             shown (line b.span))
    | RParameter whose ->
        say Unused_parameter b.span
          (Printf.sprintf "Unused parameter '%s' of %s, on line %d: the body never uses it." shown
             (match whose with Some f -> "'" ^ display f ^ "'" | None -> "a lambda")
             (line b.span))
    | RLoop what ->
        say Unused_loop_var b.span
          (Printf.sprintf "Unused loop variable '%s', bound on line %d: %s never uses it." shown
             (line b.span) what)
  in
  List.filter_map report w.all
  |> List.sort (fun a b -> compare (a.at.row1, a.at.col1) (b.at.row1, b.at.col1))
