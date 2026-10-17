(** Exhaustiveness and reachability of `match`: every `match` has to
    match every value of its subject's type, and every case has to be
    reachable by some value the cases above it do not take. Run by the
    type checker once a module's types are worked out, since what a
    pattern can match is a question about its type. See
    docs/exhaustive.md.

    The question is answered by usefulness (Maranget, "Warnings for
    pattern matching"): a pattern is useful after some rows when a value
    matches it and none of them. A case is reachable when its pattern is
    useful after the unguarded cases above it, and a `match` is
    exhaustive when `_` is not useful after all its unguarded cases --
    and when it is, what made it useful is a value no case matches,
    which is what the refusal names.

    Data structures:
      Refused -- a `match` missing a value, or a case no value reaches.
      head -- the outermost shape of a value a pattern looks at.
      pat -- a pattern as the algorithm reads it.

    Functions:
      check datatype tmap stmts -- refuses the first `match` in stmts
        that misses a value or has a case nothing reaches.
      covers datatype type_ patterns -- whether the patterns between them
        match every value of the type. *)

open Lexer
open Syntax

(** A `match` that misses a value, or a case no value reaches. *)
exception Refused of info * string

(** The outermost shape of a value: what one constructor of its type
    says. A list is told apart by its length, with every length past the
    longest pattern written as one shape. *)
type head =
  | HData of string (* a datatype's constructor *)
  | HBool of bool (* true / false *)
  | HTuple of int (* a tuple of this many elements *)
  | HInt of int (* an Int literal *)
  | HString of string (* a String literal *)
  | HText of string * string (* a String split around this prefix and suffix *)
  | HLength of int (* a list of exactly this many elements *)
  | HLonger of int (* a list of this many elements or more *)

(** A pattern as the algorithm reads it: what it binds no longer
    matters, only what it matches. *)
type pat =
  | Any (* _, a name *)
  | Con of head * pat list (* a shape and the patterns of its parts *)
  | Or of pat list (* p1 | p2 *)
  | Rest of pat list * pat list (* [prefix, .., suffix] *)

(** The pattern the algorithm reads for one Pyking pattern.
    pattern -> pat *)
let rec of_pattern p =
  match p with
  | PWildcard _ | PCapture _ -> Any
  | PAs (_, inner, _, _) -> of_pattern inner
  | POr (_, alternatives, _) -> Or (List.map of_pattern alternatives)
  | PInt (_, v, _) -> Con (HInt v, [])
  | PString (_, v, _) -> Con (HString v, [])
  | PBool (_, v, _) -> Con (HBool v, [])
  | PTuple (_, elements, _) ->
      Con (HTuple (List.length elements), List.map of_pattern elements)
  | PList (_, prefix, None, suffix, _) ->
      let elements = prefix @ suffix in
      Con (HLength (List.length elements), List.map of_pattern elements)
  | PList (_, prefix, Some _, suffix, _) ->
      Rest (List.map of_pattern prefix, List.map of_pattern suffix)
  | PText (_, prefix, _, suffix, _) -> Con (HText (prefix, suffix), [])
  | PConstructor (_, _, name, fields, _, _) ->
      Con (HData name, List.map of_pattern fields)

(* --- types --- *)

(** type_ with each type variable `mapping` names replaced.
    [(string, typ)] -> typ -> typ *)
let rec substitute mapping type_ =
  match type_ with
  | TVar (_, name, _, _) -> (
      match List.assoc_opt name mapping with Some t -> t | None -> type_)
  | TList (i, e, s) -> TList (i, substitute mapping e, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (substitute mapping) es, s)
  | TCon (i, n, args, s) -> TCon (i, n, List.map (substitute mapping) args, s)
  | _ -> type_

(** The types of a shape's parts, where the type of the whole says what
    they are. (string -> datatype?) -> typ? -> head -> [typ?]? *)
let part_types datatype type_ head =
  match (head, type_) with
  | HData name, Some (TCon (_, canonical, args, _)) -> (
      match datatype canonical with
      | Some (Datatype (_, params, constructors)) -> (
          match List.assoc_opt name constructors with
          | Some fields when List.length params = List.length args ->
              let mapping = List.combine params args in
              Some (List.map (fun (_, t) -> Some (substitute mapping t)) fields)
          | _ -> None)
      | None -> None)
  | HTuple n, Some (TTuple (_, elements, _)) when List.length elements = n ->
      Some (List.map Option.some elements)
  | (HLength n | HLonger n), Some (TList (_, element, _)) ->
      Some (List.init n (fun _ -> Some element))
  | _ -> None

(** How many parts a shape has: from the type where it says, and from
    the patterns of the column otherwise.
    (string -> datatype?) -> typ? -> head -> [pat] -> int *)
let arity datatype type_ head column =
  match part_types datatype type_ head with
  | Some parts -> List.length parts
  | None -> (
      match head with
      | HTuple n | HLength n | HLonger n -> n
      | _ ->
          let rec find = function
            | [] -> 0
            | Con (h, ps) :: _ when h = head -> List.length ps
            | Or alternatives :: rest -> find (alternatives @ rest)
            | _ :: rest -> find rest
          in
          find column)

(** The types of a shape's parts, unknown where nothing says.
    (string -> datatype?) -> typ? -> head -> int -> [typ?] *)
let parts_or_unknown datatype type_ head count =
  match part_types datatype type_ head with
  | Some parts when List.length parts = count -> parts
  | _ -> List.init count (fun _ -> None)

(* --- the shapes of a column --- *)

(** The longest list a column's patterns fix: every length past it is
    one shape. [pat] -> int *)
let longest column =
  let rec go found p =
    match p with
    | Con (HLength n, _) -> max found n
    | Rest (prefix, suffix) -> max found (List.length prefix + List.length suffix)
    | Or alternatives -> List.fold_left go found alternatives
    | _ -> found
  in
  List.fold_left go 0 column

(** The shapes a pattern takes, with lists cut at `longest`.
    int -> pat -> [head] *)
let rec heads longest p =
  match p with
  | Any -> []
  | Con (h, _) -> [ h ]
  | Or alternatives -> List.concat_map (heads longest) alternatives
  | Rest (prefix, suffix) ->
      let fixed = List.length prefix + List.length suffix in
      List.init (max 0 (longest - fixed + 1)) (fun i -> HLength (fixed + i))
      @ [ HLonger (longest + 1) ]

(** Every shape a value of this type can have, where there are finitely
    many: the type says which, or failing that the shapes written.
    (string -> datatype?) -> typ? -> int -> [head] -> [head]? *)
let signature datatype type_ longest written =
  let lists = List.init (longest + 1) (fun n -> HLength n) @ [ HLonger (longest + 1) ] in
  match type_ with
  | Some (TBool _) -> Some [ HBool true; HBool false ]
  | Some (TTuple (_, elements, _)) -> Some [ HTuple (List.length elements) ]
  | Some (TList _) -> Some lists
  | Some (TCon (_, canonical, _, _)) -> (
      match datatype canonical with
      | Some (Datatype (_, _, constructors)) ->
          Some (List.map (fun (name, _) -> HData name) constructors)
      | None -> None)
  | _ -> (
      match written with
      | HBool _ :: _ -> Some [ HBool true; HBool false ]
      | HTuple n :: _ -> Some [ HTuple n ]
      | (HLength _ | HLonger _) :: _ -> Some lists
      | _ -> None)

(* --- the matrix --- *)

(** The rows a row becomes once the value is known to have shape `head`
    with `count` parts: the parts' patterns in place of the first, or
    nothing where the first pattern cannot take that shape.
    head -> int -> [pat] -> [[pat]] *)
let rec specialize head count row =
  match row with
  | [] -> []
  | first :: rest -> (
      match first with
      | Any -> [ List.init count (fun _ -> Any) @ rest ]
      | Or alternatives ->
          List.concat_map (fun one -> specialize head count (one :: rest)) alternatives
      | Con (h, parts) -> if h = head then [ parts @ rest ] else []
      | Rest (prefix, suffix) -> (
          let fixed = List.length prefix + List.length suffix in
          match head with
          | (HLength n | HLonger n) when n >= fixed ->
              [ prefix @ List.init (n - fixed) (fun _ -> Any) @ suffix @ rest ]
          | _ -> []))

(** The rows a row becomes for a value whose shape no row names: only a
    first pattern matching anything keeps it. [pat] -> [[pat]] *)
let rec default row =
  match row with
  | Any :: rest -> [ rest ]
  | Or alternatives :: rest ->
      List.concat_map (fun one -> default (one :: rest)) alternatives
  | _ -> []

(** The first of `options` for which f answers something. *)
let rec first_some f options =
  match options with
  | [] -> None
  | one :: rest -> ( match f one with Some answer -> Some answer | None -> first_some f rest)

(** The first n elements of a list, and the rest. int -> ['a] -> (['a], ['a]) *)
let split n items =
  let rec go n taken rest =
    if n = 0 then (List.rev taken, rest)
    else match rest with x :: xs -> go (n - 1) (x :: taken) xs | [] -> (List.rev taken, [])
  in
  go n [] items

(** A literal of an Int or String column that none of its shapes takes,
    where one is needed to name a value no case matches.
    [head] -> pat *)
let unmatched_literal written =
  let ints = List.filter_map (function HInt n -> Some n | _ -> None) written in
  let strings = List.filter_map (function HString s -> Some s | _ -> None) written in
  let texts = List.filter_map (function HText (p, s) -> Some (p, s) | _ -> None) written in
  let starts_with s p = String.length s >= String.length p && String.sub s 0 (String.length p) = p in
  let ends_with s x =
    String.length s >= String.length x
    && String.sub s (String.length s - String.length x) (String.length x) = x
  in
  if ints <> [] then
    let rec free n = if List.mem n ints then free (n + 1) else n in
    Con (HInt (free 0), [])
  else if strings <> [] || texts <> [] then
    let taken s =
      List.mem s strings
      || List.exists
           (fun (p, x) ->
             String.length s >= String.length p + String.length x
             && starts_with s p && ends_with s x)
           texts
    in
    let rec free s = if taken s then free (s ^ "?") else s in
    Con (HString (free ""), [])
  else Any

(** A value that `q` matches and no row does, as one pattern per column,
    or None where every value q matches some row matches too.
    (string -> datatype?) -> [[pat]] -> [pat] -> [typ?] -> [pat]? *)
let rec useful datatype rows q types =
  match q with
  | [] -> if rows = [] then Some [] else None
  | first :: rest -> (
      let type_, rest_types =
        match types with t :: ts -> (t, ts) | [] -> (None, [])
      in
      let column = List.filter_map (function p :: _ -> Some p | [] -> None) rows in
      let longest = longest (first :: column) in
      let through head count =
        let parts = parts_or_unknown datatype type_ head count in
        match
          useful datatype
            (List.concat_map (specialize head count) rows)
            (List.init count (fun _ -> Any) @ rest)
            (parts @ rest_types)
        with
        | Some witness ->
            let mine, others = split count witness in
            Some (Con (head, mine) :: others)
        | None -> None
      in
      match first with
      | Or alternatives ->
          first_some (fun one -> useful datatype rows (one :: rest) types) alternatives
      | Con (head, parts) -> (
          let count = List.length parts in
          let types = parts_or_unknown datatype type_ head count @ rest_types in
          match
            useful datatype
              (List.concat_map (specialize head count) rows)
              (parts @ rest) types
          with
          | Some witness ->
              let mine, others = split count witness in
              Some (Con (head, mine) :: others)
          | None -> None)
      | Rest _ ->
          (* A list pattern of open length is every length it takes, one
             after another. *)
          first_some
            (fun head ->
              let count = arity datatype type_ head [] in
              match specialize head count (first :: rest) with
              | [ expanded ] -> useful datatype rows expanded types
              | _ -> None)
            (heads longest first)
      | Any -> (
          let written = List.sort_uniq compare (List.concat_map (heads longest) column) in
          match signature datatype type_ longest written with
          | Some full when List.for_all (fun h -> List.mem h written) full ->
              first_some
                (fun head -> through head (arity datatype type_ head column))
                full
          | full -> (
              match useful datatype (List.concat_map default rows) rest rest_types with
              | None -> None
              | Some witness ->
                  let missing =
                    (* A column nothing was written in is matched by
                       nothing, so `_` names what it misses. *)
                    if written = [] then Any
                    else
                      match full with
                      | Some full -> (
                          match List.find_opt (fun h -> not (List.mem h written)) full with
                          | Some head ->
                              Con
                                ( head,
                                  List.init (arity datatype type_ head column) (fun _ -> Any)
                                )
                          | None -> Any)
                      | None -> unmatched_literal written
                  in
                  Some (missing :: witness))))

(* --- the messages --- *)

(** A string as a Pyking literal. string -> string *)
let quoted s =
  let escaped =
    String.concat ""
      (List.map
         (function
           | '\\' -> "\\\\" | '\'' -> "\\'" | '\n' -> "\\n" | '\t' -> "\\t"
           | '\r' -> "\\r" | c -> String.make 1 c)
         (List.of_seq (String.to_seq s)))
  in
  "'" ^ escaped ^ "'"

(** A value no case matches, written as the pattern that would match it.
    pat -> string *)
let rec shown p =
  let all ps = String.concat ", " (List.map shown ps) in
  match p with
  | Any -> "_"
  | Or (one :: _) -> shown one
  | Or [] -> "_"
  | Rest (prefix, suffix) ->
      "[" ^ String.concat ", " (List.map shown prefix @ [ ".." ] @ List.map shown suffix) ^ "]"
  | Con (HData name, []) -> name
  | Con (HData name, parts) -> name ^ "(" ^ all parts ^ ")"
  | Con (HBool b, _) -> if b then "true" else "false"
  | Con (HTuple _, [ single ]) -> "(" ^ shown single ^ ",)"
  | Con (HTuple _, parts) -> "(" ^ all parts ^ ")"
  | Con (HInt n, _) -> string_of_int n
  | Con (HString s, _) -> quoted s
  | Con (HText (prefix, suffix), _) -> quoted (prefix ^ suffix)
  | Con (HLength _, parts) -> "[" ^ all parts ^ "]"
  | Con (HLonger _, parts) -> "[" ^ all parts ^ ", ..]"

(* --- the walk --- *)

(** Refuses one `match` that misses a value or has a case nothing
    reaches. (string -> datatype?) -> typ IntMap.t -> stmt -> () *)
let check_match datatype tmap statement =
  match statement with
  | SMatch (info, subject, cases, _) ->
      let type_ = IntMap.find_opt (expr_sym subject) tmap in
      let rows =
        List.map
          (fun case -> (case, of_pattern (case_pattern case), case_guard case <> None))
          cases
      in
      let _ =
        List.fold_left
          (fun before (case, pattern, guarded) ->
            if useful datatype before [ pattern ] [ type_ ] = None then
              raise
                (Refused
                   ( pattern_info (case_pattern case),
                     "this case is never reached: every value it matches is \
                      matched by a case above it" ));
            if guarded then before else before @ [ [ pattern ] ])
          [] rows
      in
      let unguarded =
        List.filter_map (fun (_, p, guarded) -> if guarded then None else Some [ p ]) rows
      in
      (match useful datatype unguarded [ Any ] [ type_ ] with
      | Some (witness :: _) ->
          raise
            (Refused
               ( info,
                 Printf.sprintf
                   "this 'match' does not match every value: no case matches \
                    %s%s. Add a case for it, or a 'case _'"
                   (shown witness)
                   (if List.exists (fun (_, _, guarded) -> guarded) rows then
                      " (a case with a guard does not count, since its guard \
                       may be false)"
                    else "") ))
      | _ -> ())
  | _ -> ()

(** Refuses the first `match` in stmts that misses a value or has a case
    nothing reaches, given the datatype each canonical name denotes and
    the types the checker worked out.
    (string -> datatype?) -> typ IntMap.t -> [stmt] -> () *)
let check datatype tmap stmts =
  Walk.fold_stmts
    (fun () node ->
      match node with Walk.NStmt statement -> check_match datatype tmap statement | _ -> ())
    () stmts

(** Whether these patterns between them match every value of a type,
    where the type is known: what a backend whose host checks
    exhaustiveness itself asks, for the cases it can see.
    (string -> datatype?) -> typ? -> [pattern] -> bool *)
let covers datatype type_ patterns =
  useful datatype (List.map (fun p -> [ of_pattern p ]) patterns) [ Any ] [ type_ ]
  = None
