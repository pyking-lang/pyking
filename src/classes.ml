(** What a backend needs to know of a module's classes and interfaces
    (PYKING.md, "Classes and interfaces"), read from their declarations
    once the checker has accepted them: each class's fields with the
    class declaring them, its methods, the order they are declared in,
    which class's body a method runs, and which classes something
    extends. Every backend writes its own classes from this, so the five
    agree on what a class has.

    Data structures:
      field -- one field, where it is declared.
      meth -- one method a class or interface declares.
      cls -- one class or interface.
      table -- every class and interface of a program, by name.

    Functions:
      table stmts -- the classes these statements declare.
      find, supers, all_fields, field_owner, field_of, own_method,
      resolve, declaring, has_method, method_names, extended, interfaces,
      ordered -- what the backends ask of it. *)

open Syntax

module SMap = Map.Make (String)

(** One field, its own class's: header fields that only pass an
    inherited field on are not fields of their own. *)
type field = {
  f_name : string;
  f_sym : int; (* the declaration's symbol: the checker recorded its type there *)
  f_var : bool;
  f_private : bool;
  f_owner : string;
  f_init : expr option; (* a body field's first value; None for a header field *)
}

(** One method a class or interface declares. *)
type meth = {
  m_name : string;
  m_sym : int; (* the checker recorded the method's type there *)
  m_params : param list; (* without `self` *)
  m_body : stmt list option; (* None: abstract, or an interface's signature *)
  m_private : bool;
  m_override : bool;
  m_owner : string;
  m_info : Lexer.info;
}

(** One class or interface. *)
type cls = {
  name : string;
  kind : class_kind;
  params : string list;
  parent : string option;
  parent_args : (string option * expr) list; (* what the parent's constructor is given *)
  parent_sym : int; (* the checker recorded the parent, at its type arguments, there *)
  interfaces : (string * int) list; (* each named in the header, and its symbol *)
  header : (string * int) list; (* what the constructor takes, in order, with symbols *)
  own_header : string list; (* the header's fields that are this class's own *)
  fields : field list; (* this class's own fields: its own header's, then its body's *)
  methods : meth list;
  decl : class_decl;
  info : Lexer.info;
}

type table = cls SMap.t

(** The class or interface of this name. table -> string -> cls? *)
let find table name = SMap.find_opt name table

(** A class, its parent, its parent's parent, ... nearest first.
    table -> string -> [string] *)
let chain table name =
  let rec go seen n =
    if List.mem n seen then List.rev seen
    else
      match find table n with
      | Some { parent = Some p; _ } -> go (n :: seen) p
      | _ -> List.rev (n :: seen)
  in
  go [] name

(** Every supertype, itself first: the class chain, then each interface
    reached from it, nearest first. table -> string -> [string] *)
let supers table name =
  let rec go seen queue =
    match queue with
    | [] -> List.rev seen
    | n :: rest when List.mem n seen -> go seen rest
    | n :: rest -> (
        match find table n with
        | Some c -> go (n :: seen) (rest @ Option.to_list c.parent @ List.map fst c.interfaces)
        | None -> go (n :: seen) rest)
  in
  go [] (chain table name)

(** Every field an object of this class has, its parents' first.
    table -> string -> [field] *)
let all_fields table name =
  List.concat_map
    (fun n -> match find table n with Some c -> c.fields | None -> [])
    (List.rev (chain table name))

(** The class that declares a field reached on this class.
    table -> string -> string -> string? *)
let field_owner table name field =
  List.find_map
    (fun f -> if f.f_name = field then Some f.f_owner else None)
    (all_fields table name)

(** The field itself. table -> string -> string -> field? *)
let field_of table name field = List.find_opt (fun f -> f.f_name = field) (all_fields table name)

(** The method of this name a class or interface declares itself.
    table -> string -> string -> meth? *)
let own_method table name m =
  match find table name with
  | Some c -> List.find_opt (fun x -> x.m_name = m) c.methods
  | None -> None

(** The class or interface whose body runs for `m` on an object of class
    `name`: a body in the class chain first, then an interface's default,
    nearest first. None where only a declaration without a body is above
    -- an abstract class's or an interface's own.
    table -> string -> string -> string? *)
let resolve table name m =
  let with_body n = match own_method table n m with Some x when x.m_body <> None -> true | _ -> false in
  match List.find_opt with_body (chain table name) with
  | Some n -> Some n
  | None -> List.find_opt with_body (supers table name)

(** The class or interface where `m` is first declared, above `name` or
    at it: where its signature, and its defaults, come from.
    table -> string -> string -> string? *)
let declaring table name m =
  List.fold_left
    (fun found n -> match own_method table n m with Some _ -> Some n | None -> found)
    None (supers table name)

(** Whether a class reached by this name declares or inherits `m`.
    table -> string -> string -> bool *)
let has_method table name m = declaring table name m <> None

(** Every method a value of this class or interface has, by name, in the
    order first declared from the top. table -> string -> [string] *)
let method_names table name =
  List.fold_left
    (fun names n ->
      match find table n with
      | Some c -> List.fold_left (fun names x -> if List.mem x.m_name names then names else names @ [ x.m_name ]) names c.methods
      | None -> names)
    [] (List.rev (supers table name))

(** Whether some class of the program extends this one, or a class or
    interface builds on this interface. table -> string -> bool *)
let extended table name =
  SMap.exists (fun _ c -> c.parent = Some name || List.mem_assoc name c.interfaces) table

(** Every interface an object of this class is, nearest first.
    table -> string -> [string] *)
let interfaces table name =
  List.filter
    (fun n -> match find table n with Some { kind = ClassInterface; _ } -> true | _ -> false)
    (supers table name)

(** Every class and interface these statements declare, each after
    everything it names and otherwise in the order written: what a
    language that declares a parent before its child needs.
    table -> [stmt] -> [string] *)
let ordered table stmts =
  let rec visit done_ n =
    if List.mem n done_ then done_
    else
      match find table n with
      | None -> done_
      | Some c ->
          let done_ = List.fold_left visit done_ (Option.to_list c.parent @ List.map fst c.interfaces) in
          if List.mem n done_ then done_ else done_ @ [ n ]
  in
  List.fold_left visit [] (List.filter_map (function SClass (_, c, _) -> Some c.c_name | _ -> None) stmts)

(** The classes and interfaces these statements declare, added to
    `known` -- what imported modules declared. table -> [stmt] -> table *)
let add known stmts =
  let decls = List.filter_map (function SClass (i, c, _) -> Some (i, c) | _ -> None) stmts in
  let rec add_one table (i, c) =
    if SMap.mem c.c_name table then table
    else
      let parent = Option.map (fun (ClassRef (_, _, n, _, _, _)) -> n) c.c_extends in
      let table =
        match parent with
        | Some p -> (
            match List.find_opt (fun (_, d) -> d.c_name = p) decls with
            | Some decl -> add_one table decl
            | None -> table)
        | None -> table
      in
      let inherited =
        match parent with Some p -> List.map (fun f -> f.f_name) (all_fields table p) | None -> []
      in
      let header = List.map (fun (MemberField (_, n, _, _, _, _, s)) -> (n, s)) c.c_header in
      let own_header = List.filter (fun n -> not (List.mem n inherited)) (List.map fst header) in
      let field (MemberField (_, n, _, v, var, private_, s)) init =
        { f_name = n; f_sym = s; f_var = var; f_private = private_; f_owner = c.c_name; f_init = (if init then v else None) }
      in
      let fields =
        List.filter_map
          (fun (MemberField (_, n, _, _, _, _, _) as m) -> if List.mem n own_header then Some (field m false) else None)
          c.c_header
        @ List.map (fun m -> field m true) c.c_fields
      in
      let methods =
        List.map
          (fun (MethodDecl (mi, n, params, _, body, override, private_, s)) ->
            {
              m_name = n;
              m_sym = s;
              m_params = params;
              m_body = body;
              m_private = private_;
              m_override = override;
              m_owner = c.c_name;
              m_info = mi;
            })
          c.c_methods
      in
      SMap.add c.c_name
        {
          name = c.c_name;
          kind = c.c_kind;
          params = c.c_params;
          parent;
          parent_args = (match c.c_extends with Some (ClassRef (_, _, _, _, args, _)) -> args | None -> []);
          parent_sym = (match c.c_extends with Some (ClassRef (_, _, _, _, _, s)) -> s | None -> 0);
          interfaces = List.map (fun (ClassRef (_, _, n, _, _, s)) -> (n, s)) c.c_implements;
          header;
          own_header;
          fields;
          methods;
          decl = c;
          info = i;
        }
        table
  in
  List.fold_left add_one known decls

(** The classes and interfaces these statements declare. [stmt] -> table *)
let table stmts = add SMap.empty stmts
