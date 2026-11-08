(** The type checker, in a functional style, over one module -- or a
    whole one-file program, which is the same thing. A function whose
    type was not written down is worked out the first time something
    calls it, from its own body: its parameters go in as metavariables
    and the body's demands solve them, which is Hindley-Milner's rule
    reached without a constraint solver. See docs/typesystem.md and
    docs/type_inference.md.

    `type_check stmts sigmaps` is the entry point: it answers the table
    mapping each node's symbol to the type worked out for it, and raises
    Type_error for the first thing that does not check out.

    One function per AST datatype -- `check_stmts`, `check_stmt`,
    `check_expr`, `check_param`, `same_type` -- each taking a node of
    exactly that type and answering exactly one kind of answer. No
    function here dispatches on which *sort* of node it was handed.

    Nothing in this module changes anything. An environment, a store, a
    type: each is handed on, extended by being rebuilt, and left alone
    by whoever passed it. `tmap`, the pass's result, is a field of the
    store, which is threaded and handed back everywhere already -- so
    "a function given a store returns one" covers the result as well.

    Data structures:
      Type_error -- a type failure, with the source position.
      env -- a name's type, in scope; a name not in it is not in scope.
      sigmap -- what one module exports, and at what type.
      given -- one `return`, or the value a body ends in.
      frame -- what the current inference has gathered.
      expected -- what a `return` is checked against.
      store -- everything inference has worked out, threaded as a value.

    Functions:
      type_check stmts sigmaps -- checks a whole module; answers its tmap.
      check_stmts / check_stmt / check_expr / check_param -- one per
        AST datatype.
      same_type a b / accepts expected actual -- type comparison.
      unify one other store -- the store in which two types are one.
      declare_functions stmts env store -- binds every def of a block.
      declare_datatypes stmts store -- the datatypes a module declares
        and imports.
      check_matches stmts store -- refuses a non-exhaustive `match`.
      builtin_env () -- the environment a program starts in.
      available module info store -- what a module exports, or a refusal.
      check_exports stmts store -- refuses an export whose type the
        source does not write down.
      zonk type_ store -- a type read back through what was solved. *)

open Lexer
open Syntax

(** A type-check failure, or a refusal of an unsupported construct, with
    the source position. *)
exception Type_error of info * string

module SMap = Map.Make (String)

(* What a name denotes: its type, and whether the binding was written
   `implicit` -- which is what an implicit argument may be resolved to
   and what an ordinary name never is (PYKING.md, "Implicits"). *)
type binding = { btype : typ; bimplicit : bool; bvar : bool (* bound by `var` *) }

(* `env` maps a name to what it denotes, and to nothing else: a name it
   does not hold is a name that is not in scope. The host operations are
   in it under TBuiltin, which is a type like any other here -- see
   `check_builtin_call`, which is what a call to one is checked by. *)
type env = binding SMap.t

(** What one module exports, at what type, and whether it is implicit --
    all of it another module sees (Module.make_sigmap). *)
type sigmap = (string * typ * bool) list

(** What one node denotes once overloading and implicits are resolved. *)
type resolution =
  | Call of (string * typ) option * argument list
      (* a call: the name overload resolution chose for it and that
         definition's type (None where the source named it outright),
         and one argument per implicit parameter, in order *)
  | Adapted of typ * int * argument list
      (* an argument whose implicit parameters are not the ones wanted:
         a lambda of that type stands in its place, passing the first
         `int` of its own parameters to what was written and then these
         (docs/implicits.md) *)
  | Upcast of typ
      (* recorded under the expression's symbol negated: its object seen
         as this supertype (PYKING.md, "Classes and interfaces") *)
  | Method_call of string * (string * expr option) list
      (* `obj.m(args)` calling a method: the class or interface whose
         declaration the call reaches, and each parameter with its
         default, by which elaborate.ml puts every argument in place *)
  | Method_value of int
      (* `obj.m` used as a value: a method taking this many arguments *)
  | Super_owner of string * (string * expr option) list
      (* `super.m(args)`: the class or interface whose body runs, and the
         method's parameters, as for Method_call *)
  | Object_eq of bool
      (* `a == b` (true) or `a != b` (false) on objects: a call of `eq` *)

and argument =
  | Direct of string * typ
      (* a name in scope, used at this type *)
  | Wrapped of string * typ * int * argument list
      (* a lambda of that function type, passing the first `int` of its
         own parameters to the name and then these -- what a function
         whose implicit parameters are not the ones wanted needs, in
         either direction (docs/implicits.md) *)

(* --- building types ---
   The Python leaves the symbol, and a function type's two inference
   fields, to the dataclass defaults. These say the same thing once. *)

let t_int info = TInt (info, 0)
let t_float info = TFloat (info, 0)
let t_string info = TString (info, 0)
let t_char info = TChar (info, 0)
let t_bool info = TBool (info, 0)
let t_list info element = TList (info, element, 0)
let t_tuple info elements = TTuple (info, elements, 0)
let t_unknown info = TUnknown (info, 0)
let t_builtin info name = TBuiltin (info, name, 0)
let t_var info name = TVar (info, name, 0, true)
let t_meta info name = TVar (info, name, 0, false)
let t_function ?(implicits = []) info params result =
  TFunction (info, params, result, 0, 0, None, implicits)
let t_forall info vars body = TForall (info, vars, body, 0)

(* `Array(T)`: a builtin datatype of one parameter, with no constructors
   a program can name -- an array is made by `array(...)` alone
   (PYKING.md, "Arrays"). *)
let array_name = "Array"
let t_array info element = TCon (info, array_name, [ element ], 0)

(** The element type of an array type, or None for anything else.
    typ -> typ option *)
let array_element type_ =
  match type_ with TCon (_, name, [ element ], _) when name = array_name -> Some element | _ -> None

(* `DynArray(T)`: an array that grows, made by `dynarray(...)` alone and changed by
   `push`, `pop`, `insert`, `remove` and `clear` (PYKING.md, "DynArrays"). *)
let dynarray_name = "DynArray"
let t_dynarray info element = TCon (info, dynarray_name, [ element ], 0)

(** The element type of a DynArray type, or None for anything else.
    typ -> typ option *)
let dynarray_element type_ =
  match type_ with TCon (_, name, [ element ], _) when name = dynarray_name -> Some element | _ -> None

(* `MutMap(K, V)`: a mutable map, insertion-ordered, made by `mutmap(...)`
   alone (PYKING.md, "MutMaps"). *)
let mutmap_name = "MutMap"
let t_mutmap info key value = TCon (info, mutmap_name, [ key; value ], 0)

(** The key and value types of a MutMap type, or None for anything else.
    typ -> (typ * typ) option *)
let mutmap_parts type_ =
  match type_ with TCon (_, name, [ key; value ], _) when name = mutmap_name -> Some (key, value) | _ -> None

(* `Ptr(T)`: a pointer to a place holding a T -- a `var`, an array's or a
   view's element, a var struct's field -- made by `&` alone (PYKING.md,
   "Pointers"). *)
let ptr_name = "Ptr"
let t_ptr info target = TCon (info, ptr_name, [ target ], 0)

(** What a Ptr type points at, or None for anything else.
    typ -> typ option *)
let ptr_target type_ =
  match type_ with TCon (_, name, [ target ], _) when name = ptr_name -> Some target | _ -> None

(* `Slice(T)`: a view of a run of an array's elements, shared with it,
   made by `view(a, i, j)` alone (PYKING.md, "Slices"). *)
let slice_name = "Slice"
let t_slice info element = TCon (info, slice_name, [ element ], 0)

(** The element type of a Slice type, or None for anything else.
    typ -> typ option *)
let slice_element type_ =
  match type_ with TCon (_, name, [ element ], _) when name = slice_name -> Some element | _ -> None

(** The element type of an array, a DynArray or a Slice -- a store of
    elements read and written by index -- or None for anything else.
    typ -> typ option *)
let store_element type_ =
  match array_element type_ with
  | Some element -> Some element
  | None -> ( match dynarray_element type_ with Some element -> Some element | None -> slice_element type_)

(* --- kind variables ---

   An unannotated parameter a body indexes, slices, walks or writes by
   index is *some* store of elements, and which store -- a list, an
   array, a DynArray, a view or a String -- is left to its first call
   (docs/type_inference.md, "The kind of an indexed parameter"). Its
   type is `TCon (?kN:LADVS, [element])`: a kind variable applied to the
   element type. The name says which kinds are still allowed, one letter
   each, so `kind_matches` can answer without the store; narrowing it
   makes a new variable and links the old one to it. Its solution lives
   in `store.solutions` beside the metavariables': another kind
   variable, a link, as `TCon (_, name, [], _)`, or the container it
   became, as that type with its element left `TUnknown`. `prune` reads
   a decided one back as the type it stands for. Only the kind is
   shared; the element is an ordinary metavariable, generalised as any
   other is, so one definition serves `[Int]` and `[String]` once its
   first call has said "a list". *)

(** A kind a kind variable may become. *)
type container = CList | CArray | CDynArray | CSlice | CString

(** Every kind, in the order a kind variable nothing decided picks the
    first of. *)
let all_containers = [ CList; CArray; CDynArray; CSlice; CString ]

(** The kinds whose elements are written by index. *)
let writable_containers = [ CArray; CDynArray; CSlice ]

let container_letter = function CList -> 'L' | CArray -> 'A' | CDynArray -> 'D' | CSlice -> 'V' | CString -> 'S'

(** A kind as a message names it. container -> string *)
let container_words = function
  | CList -> "a list"
  | CArray -> "an array"
  | CDynArray -> "a DynArray"
  | CSlice -> "a view"
  | CString -> "a String"

(** A kind variable's name: `?k`, a number, and the kinds it allows.
    int -> [container] -> string *)
let kind_var_name number allowed =
  Printf.sprintf "?k%d:%s" number (String.of_seq (List.to_seq (List.map container_letter allowed)))

(** Whether a TCon's name is a kind variable's. string -> bool *)
let is_kind_name name = String.length name > 2 && name.[0] = '?' && name.[1] = 'k'

(** The kinds a kind variable's name allows. string -> [container] *)
let kind_allowed name =
  match String.index_opt name ':' with
  | None -> all_containers
  | Some at ->
      let letters = String.sub name (at + 1) (String.length name - at - 1) in
      List.filter (fun c -> String.contains letters (container_letter c)) all_containers

(** A kind variable's name and element, or None for anything else.
    typ -> (string * typ) option *)
let kind_var_parts type_ =
  match type_ with TCon (_, name, [ element ], _) when is_kind_name name -> Some (name, element) | _ -> None

(** The type a kind stands for, over an element (a String's is Char,
    so its element is not kept). container -> info -> typ -> typ *)
let container_type kind info element =
  match kind with
  | CList -> t_list info element
  | CArray -> t_array info element
  | CDynArray -> t_dynarray info element
  | CSlice -> t_slice info element
  | CString -> t_string info

(** The kind a settled type is, or None for one that is none of them.
    typ -> container option *)
let container_of type_ =
  match type_ with
  | TList _ -> Some CList
  | TString _ -> Some CString
  | settled when array_element settled <> None -> Some CArray
  | settled when dynarray_element settled <> None -> Some CDynArray
  | settled when slice_element settled <> None -> Some CSlice
  | _ -> None

(** Several kinds as a message names them: "a list, an array or a
    view". [container] -> string *)
let containers_words kinds =
  match List.rev (List.map container_words kinds) with
  | [] -> "nothing"
  | [ one ] -> one
  | last :: rest -> String.concat ", " (List.rev rest) ^ " or " ^ last

(** The type a definition has once its implicit parameters are ordinary
    ones: what every stage after `elaborate.ml` sees of it. typ -> typ *)
let rec without_implicits type_ =
  match type_ with
  | TForall (info, vars, body, sym) ->
      TForall (info, vars, without_implicits body, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          params @ List.map (fun (IParam (_, t)) -> t) implicits,
          result,
          sym,
          tmsym,
          definition,
          [] )
  | type_ -> type_

(** How many parameters a function type takes, counting an implicit one
    like any other; 0 for anything that is not a function. typ -> int *)
let arity type_ =
  match type_ with
  | TFunction (_, params, _, _, _, _, implicits) ->
      List.length params + List.length implicits
  | _ -> 0

(** The types of a list of implicit parameters, in order.
    [implicit_param] -> [typ] *)
let implicit_types implicits = List.map (fun (IParam (_, t)) -> t) implicits

(** The names of a list of implicit parameters, in order.
    [implicit_param] -> [string] *)
let implicit_names implicits = List.map (fun (IParam (n, _)) -> n) implicits

(** implicits with each type replaced by f of it.
    (typ -> typ) -> [implicit_param] -> [implicit_param] *)
let map_implicits f implicits =
  List.map (fun (IParam (n, t)) -> IParam (n, f t)) implicits

(** The unit type, (), an empty tuple type. info -> typ *)
let unit_type info = t_tuple info []

(** Whether t is the unit type. typ -> bool *)
let is_unit t = match t with TTuple (_, [], _) -> true | _ -> false

(* The source position a TBuiltin carries, since a builtin is written in
   no file. *)
let builtin_info = { file = "<builtin>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(* Where a block with no statements at all is said to be. *)
let empty_info = { file = "<empty>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(** One `return` in the body being inferred, or the value its body ends
    in: where it is written, and what it gives. *)
type given = { given_info : info; given_type : typ }

(** What the current inference has gathered: the `return`s the body
    being worked out has shown so far. *)
type frame = { returns : given list }

(** What a `return` is checked against: the declared type of the
    function whose body is being checked, `Inferring` while one is being
    worked out, and `No_function` at the top level, where a `return` has
    nothing to return from. *)
type expected = No_function | Inferring | Declared of typ

(** What the checker knows of one class or interface (PYKING.md, "Classes
    and interfaces"): every type in it written in terms of the class's own
    parameters, which are rigid. *)
type class_info = {
  cl_name : string;
  cl_kind : class_kind;
  cl_params : string list;
  cl_parent : (string * typ list) option; (* the parent class, at its arguments *)
  cl_interfaces : (string * typ list) list; (* the interfaces named in the header *)
  cl_header : (string * typ) list; (* what the constructor takes *)
  cl_fields : field_info list; (* the fields it declares itself *)
  cl_methods : method_info list; (* the methods it declares itself *)
  cl_info : info;
}

and field_info = { fd_name : string; fd_type : typ; fd_var : bool; fd_private : bool; fd_info : info }

and method_info = {
  md_name : string;
  md_params : (string * typ * expr option) list; (* each with its default, where it has one *)
  md_return : typ;
  md_abstract : bool; (* no body: an abstract method, or an interface's signature *)
  md_private : bool;
  md_override : bool;
  md_info : info;
}

(** Everything inference has worked out, threaded through the pass as a
    value.

    environments -- where each definition was written, by its symbol; a
      deferred body is checked in its own scope, never the call site's.
    instances -- what each definition was worked out to be. A cache, and
      what makes mutual recursion terminate.
    checking -- the definitions whose bodies are being checked right
      now, which is what stops the walk going round for ever.
    frame -- what this inference has gathered.
    signatures -- a `def`'s type where the source wrote it on a line of
      its own (`def foo : (a) -> a`), keyed by the definition's symbol.
      Given rather than worked out, and here so that reaching it costs
      no new parameter on every function that might need it.
    fresh -- how many metavariables have been handed out.
    solutions -- what each metavariable was worked out to be, or nothing
      where it is still open. One is never re-solved, so this only
      grows.
    groups -- the `def`s of the block each definition was written in,
      keyed by its symbol. They may name each other, so they are worked
      out together and generalised together. Given, like signatures.
    captured -- metavariables a definition could not generalise because
      the scope it was written in already held them. One left open at
      the end is a type Pyking cannot write down, so it prints as none
      at all rather than as a variable claiming to be anyone's to
      choose.
    modules -- the signature of every module this one imports: the whole
      of what one module can see of another. Given, like signatures.
    tmap -- symbol -> the type worked out for that node: the pass's
      result.
    qmap -- a call's symbol -> what that call denotes, once overloading
      and implicits are resolved: the pass's other result, and what
      elaborate.ml rewrites the program by.
    types -- each datatype name in scope, as the source spells it
      (`Tree`, `m.Tree`), and the canonical name the checker's types use.
    datatypes -- every datatype this module can see, by canonical name,
      with its parameters and its constructors' field types.
    constructors -- each constructor in scope, as the source spells it,
      and the canonical name of the datatype it builds.
    field_defaults -- each field written with no type, by the name of the
      def holding its default: the metavariable standing for its type
      until that def is reached, and the field's name. *)
type store = {
  environments : env IntMap.t;
  instances : typ IntMap.t;
  checking : IntSet.t;
  frame : frame;
  signatures : typ IntMap.t;
  fresh : int;
  solutions : typ SMap.t;
  groups : stmt list IntMap.t;
  captured : StringSet.t;
  modules : (string * sigmap) list;
  tmap : typ IntMap.t;
  qmap : resolution IntMap.t;
  types : string SMap.t;
  datatypes : datatype SMap.t;
  constructors : string SMap.t;
  field_defaults : (typ * string) SMap.t;
  pending_plus : (typ * info) list;
  open_kinds : string list;
      (* every kind variable handed out, decided at the end if nothing
         else did (`settle_kinds`) *)
  kind_origins : (info * string) SMap.t;
      (* a decided kind variable: the call that decided it, and what it
         decided -- "vec_add1's parameter v1" and so on -- for the
         message a later call that disagrees gets *)
  mutation : bool; (* whether the module has `use mutation` *)
  classes : class_info SMap.t; (* every class and interface in scope, by canonical name *)
  current_class : string option; (* the class whose method is being checked *)
  upcasts : typ IntMap.t;
      (* each expression whose object is seen as a supertype where it
         stands, and that supertype: elaborate.ml wraps it in an EUpcast *)
}

(** The store a program starts checking in, holding the signature of
    every module it imports. [(string, sigmap)] -> store *)
let empty_store sigmaps =
  {
    environments = IntMap.empty;
    instances = IntMap.empty;
    checking = IntSet.empty;
    frame = { returns = [] };
    signatures = IntMap.empty;
    fresh = 0;
    solutions = SMap.empty;
    groups = IntMap.empty;
    captured = StringSet.empty;
    modules = sigmaps;
    tmap = IntMap.empty;
    qmap = IntMap.empty;
    types =
      List.fold_left (fun m n -> SMap.add n n m) SMap.empty [ array_name; dynarray_name; mutmap_name; slice_name; ptr_name ];
    datatypes = SMap.empty;
    constructors = SMap.empty;
    field_defaults = SMap.empty;
    pending_plus = [];
    open_kinds = [];
    kind_origins = SMap.empty;
    mutation = true;
    classes = SMap.empty;
    current_class = None;
    upcasts = IntMap.empty;
  }

(* The names a generalised variable is given, in order: a, b, ... z,
   a1, ... *)
let letters = "abcdefghijklmnopqrstuvwxyz"

(* What a construct nothing here has reasoned about is refused with. *)
let unsupported_message = "Construct is not supported"

(** Raises Type_error refusing a node at this position. info -> 'a *)
let unsupported info = raise (Type_error (info, unsupported_message))

(** A type as an error message names it, with nothing left to solve.
    typ -> string *)
let printed type_ = pprint_type default_config type_

(** A type as an error message names it, parenthesised where a bare
    function type would read wrongly beside other text. typ -> string *)
let printed_nested type_ = pprint_type_nested default_config type_

(* --- metavariables ---

   A metavariable is a type the checker has not worked out yet, and is
   `TVar` with `rigid = false` -- the same node a written `a` uses, told
   apart by that one field. The two are exact opposites, which is why
   one constructor serves both: a rigid variable is a type the *caller*
   chose, so a body may assume nothing about it; a metavariable is a
   type *this* check is still choosing, so anything may still be assumed
   of it.

   Its name is `?n`, unwritable in source, and its solution lives in
   `store.solutions` rather than in the node -- so a type is a value
   like every other type here, and what has been worked out is one more
   thing the store carries. `zonk` is what reads a solution back. *)

(** A metavariable nothing has solved, and the store that handed it out.
    info -> store -> (typ, store) *)
let fresh_meta info store =
  ( t_meta info (Printf.sprintf "?%d" store.fresh),
    { store with fresh = store.fresh + 1 } )

(** `count` metavariables, and the store that handed them out.
    int -> info -> store -> ([typ], store) *)
let fresh_metas count info store =
  let rec go n made store =
    if n = 0 then (List.rev made, store)
    else
      let one, store = fresh_meta info store in
      go (n - 1) (one :: made) store
  in
  go count [] store

(** When a metavariable was handed out, from its name. Older is smaller.
    string -> int *)
let meta_age name = int_of_string (String.sub name 1 (String.length name - 1))

(** Whether this type is a metavariable -- something this check is still
    choosing, as against a rigid variable its caller chose.
    typ -> bool *)
let is_meta type_ =
  match type_ with TVar (_, _, _, rigid) -> not rigid | _ -> false

(** store with the metavariable `name` solved to type_. Nothing is ever
    re-solved: `unify` looks through a solved variable rather than
    binding it again. store -> string -> typ -> store *)
let solving store name type_ =
  { store with solutions = SMap.add name type_ store.solutions }

(** type_ with its *outermost* constructor settled: a metavariable that
    has been solved is replaced by its solution, as far as that goes.
    Cheap, and enough for deciding which case a type is.
    typ -> store -> typ *)
let prune type_ store =
  let rec go type_ seen =
    match type_ with
    | TVar (_, name, _, false) ->
        if StringSet.mem name seen then type_
        else (
          match SMap.find_opt name store.solutions with
          | None -> type_
          | Some answer -> go answer (StringSet.add name seen))
    | TCon (info, name, [ element ], sym) when is_kind_name name -> (
        (* A kind variable linked on is read as the one it links to, and
           a decided one as the type it became. *)
        match SMap.find_opt name store.solutions with
        | Some (TCon (_, next, [], _)) when is_kind_name next -> go (TCon (info, next, [ element ], sym)) seen
        | Some decided -> (
            match container_of decided with
            | Some kind -> container_type kind info element
            | None -> type_)
        | None -> type_)
    | type_ -> type_
  in
  go type_ StringSet.empty

(** The variables of `vars` that stand, somewhere in type_, for the
    elements of a kind variable that became a String.
    typ -> [string] -> store -> [string] *)
let char_elements type_ vars store =
  let rec walk found t =
    match t with
    | TCon (_, name, [ TVar (_, v, _, true) ], _) when is_kind_name name && List.mem v vars -> (
        match prune t store with TString _ when not (List.mem v found) -> v :: found | _ -> found)
    | TCon (_, _, args, _) | TTuple (_, args, _) -> List.fold_left walk found args
    | TList (_, element, _) -> walk found element
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk (List.fold_left walk found (params @ implicit_types implicits)) result
    | TForall (_, _, body, _) -> walk found body
    | TVar (_, name, _, false) -> (
        match SMap.find_opt name store.solutions with Some answer -> walk found answer | None -> found)
    | _ -> found
  in
  walk [] type_

(** type_ with each rigid variable of `vars` a Char. typ -> [string] -> typ *)
let rec as_chars type_ vars =
  match type_ with
  | TVar (info, name, _, true) when List.mem name vars -> t_char info
  | TList (i, e, s) -> TList (i, as_chars e vars, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (fun e -> as_chars e vars) es, s)
  | TCon (i, c, es, s) -> TCon (i, c, List.map (fun e -> as_chars e vars) es, s)
  | TFunction (i, ps, r, a, b, c, d) ->
      TFunction (i, List.map (fun e -> as_chars e vars) ps, as_chars r vars, a, b, c,
                 map_implicits (fun t -> as_chars t vars) d)
  | TForall (i, vs, b, s) -> TForall (i, vs, as_chars b (List.filter (fun v -> not (List.mem v vs)) vars), s)
  | type_ -> type_

(** type_ with every metavariable in it replaced by what it was solved
    to, as deep as the solutions go. This is what turns a type the
    checker was still working on into one it can report.
    typ -> store -> typ *)
let rec zonk type_ store =
  let type_ = prune type_ store in
  match type_ with
  | TList (info, element, sym) -> TList (info, zonk element store, sym)
  | TTuple (info, elements, sym) ->
      TTuple (info, List.map (fun e -> zonk e store) elements, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          List.map (fun p -> zonk p store) params,
          zonk result store,
          sym,
          tmsym,
          definition,
          map_implicits (fun t -> zonk t store) implicits )
  | TForall (info, vars, body, sym) ->
      (* A variable this scheme binds may share its name with one a
         solution inside it brings in -- an enclosing definition's,
         generalised after this one was -- which would then be read as
         this scheme's own. Such a variable is renamed first. *)
      let arriving = solution_names body store in
      let taken = StringSet.union arriving (rigid_names body) in
      let renamed, _ =
        List.fold_left
          (fun (renamed, taken) v ->
            if not (StringSet.mem v arriving) then (renamed @ [ (v, v) ], taken)
            else
              let rec pick n =
                let candidate = v ^ string_of_int n in
                if StringSet.mem candidate taken then pick (n + 1) else candidate
              in
              let fresh = pick 2 in
              (renamed @ [ (v, fresh) ], StringSet.add fresh taken))
          ([], taken) vars
      in
      let body =
        if List.for_all (fun (v, w) -> v = w) renamed then body
        else rename_rigid body renamed
      in
      (* A variable standing for the elements of a kind variable that
         became a String is a Char: the String carries no element to say
         so once it is read back. *)
      let chars = char_elements body (List.map snd renamed) store in
      let body = if chars = [] then body else as_chars body chars in
      (match List.filter (fun v -> not (List.mem v chars)) (List.map snd renamed) with
      | [] -> zonk body store
      | vars -> TForall (info, vars, zonk body store, sym))
  | TCon (info, name, args, sym) ->
      TCon (info, name, List.map (fun a -> zonk a store) args, sym)
  | TData (info, Datatype (name, params, constructors, writable), sym) ->
      (* A field written with no type is a metavariable its default
         solves. *)
      TData
        ( info,
          Datatype
            ( name,
              params,
              List.map
                (fun (cname, fields) ->
                  (cname, List.map (fun (label, t) -> (label, zonk t store)) fields))
                constructors,
              writable ),
          sym )
  | type_ -> type_

(** The rigid variables named in a type, solutions not looked through.
    typ -> StringSet.t *)
and rigid_names type_ =
  match type_ with
  | TVar (_, name, _, true) -> StringSet.singleton name
  | TList (_, e, _) -> rigid_names e
  | TTuple (_, es, _) | TCon (_, _, es, _) ->
      List.fold_left (fun s e -> StringSet.union s (rigid_names e)) StringSet.empty es
  | TFunction (_, ps, r, _, _, _, _) ->
      List.fold_left (fun s e -> StringSet.union s (rigid_names e)) (rigid_names r) ps
  | TForall (_, _, b, _) -> rigid_names b
  | _ -> StringSet.empty

(** The rigid variables the solutions of a type's metavariables bring in.
    typ -> store -> StringSet.t *)
and solution_names type_ store =
  let rec walk seen t =
    match t with
    | TVar (_, name, _, false) -> (
        if StringSet.mem name seen then StringSet.empty
        else
          match SMap.find_opt name store.solutions with
          | None -> StringSet.empty
          | Some answer ->
              StringSet.union (rigid_names answer) (walk (StringSet.add name seen) answer))
    | TList (_, e, _) -> walk seen e
    | TTuple (_, es, _) | TCon (_, _, es, _) ->
        List.fold_left (fun s e -> StringSet.union s (walk seen e)) StringSet.empty es
    | TFunction (_, ps, r, _, _, _, _) ->
        List.fold_left (fun s e -> StringSet.union s (walk seen e)) (walk seen r) ps
    | TForall (_, _, b, _) -> walk seen b
    | _ -> StringSet.empty
  in
  walk StringSet.empty type_

(** type_ with each rigid variable `renamed` names given its new name.
    typ -> [(string, string)] -> typ *)
and rename_rigid type_ renamed =
  match type_ with
  | TVar (info, name, sym, true) -> (
      match List.assoc_opt name renamed with
      | Some fresh -> TVar (info, fresh, sym, true)
      | None -> type_)
  | TList (i, e, s) -> TList (i, rename_rigid e renamed, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (fun e -> rename_rigid e renamed) es, s)
  | TCon (i, c, es, s) -> TCon (i, c, List.map (fun e -> rename_rigid e renamed) es, s)
  | TFunction (i, ps, r, a, b, c, d) ->
      TFunction (i, List.map (fun e -> rename_rigid e renamed) ps, rename_rigid r renamed, a, b, c, d)
  | TForall (i, vs, b, s) ->
      let inner = List.filter (fun (v, _) -> not (List.mem v vs)) renamed in
      TForall (i, vs, rename_rigid b inner, s)
  | type_ -> type_

(** Every metavariable name left unsolved in type_, in the order met and
    without repeats. typ -> store -> [string] *)
let metas_in type_ store =
  let rec walk found t =
    match prune t store with
    | TVar (_, name, _, false) ->
        if List.mem name found then found else found @ [ name ]
    | TList (_, element, _) -> walk found element
    | TTuple (_, elements, _) -> List.fold_left walk found elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk
          (List.fold_left walk found (params @ implicit_types implicits))
          result
    | TForall (_, _, body, _) -> walk found body
    | TCon (_, _, args, _) -> List.fold_left walk found args
    | _ -> found
  in
  walk [] type_

(** Whether the metavariable `name` appears inside type_. Solving it to a
    type that mentions it would build an infinite type, which is what
    this refuses. string -> typ -> store -> bool *)
let occurs name type_ store = List.mem name (metas_in type_ store)

(** The variables type_ leaves free, in the order written and without
    repeats. typ -> [string] *)
let free_vars_under type_ bound =
  let rec walk found bound t =
    match t with
    | TVar (_, name, _, _) ->
        if StringSet.mem name bound || List.mem name found then found
        else found @ [ name ]
    | TForall (_, vars, body, _) ->
        walk found
          (List.fold_left (fun b v -> StringSet.add v b) bound vars)
          body
    | TList (_, element, _) -> walk found bound element
    | TTuple (_, elements, _) ->
        List.fold_left (fun found e -> walk found bound e) found elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk
          (List.fold_left
             (fun found p -> walk found bound p)
             found
             (params @ implicit_types implicits))
          bound result
    | TCon (_, _, args, _) ->
        List.fold_left (fun found a -> walk found bound a) found args
    | _ -> found
  in
  walk [] bound type_

let free_vars type_ = free_vars_under type_ StringSet.empty

(** type_ with each variable `mapping` names replaced. A nested `all`
    shadows what it binds. typ -> [(string, typ)] -> typ *)
let rec substitute type_ mapping =
  match type_ with
  | TVar (_, name, _, _) -> (
      match List.assoc_opt name mapping with
      | Some replacement -> replacement
      | None -> type_)
  | TForall (info, vars, body, sym) ->
      let inner = List.filter (fun (k, _) -> not (List.mem k vars)) mapping in
      TForall (info, vars, substitute body inner, sym)
  | TList (info, element, sym) -> TList (info, substitute element mapping, sym)
  | TTuple (info, elements, sym) ->
      TTuple (info, List.map (fun e -> substitute e mapping) elements, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          List.map (fun p -> substitute p mapping) params,
          substitute result mapping,
          sym,
          tmsym,
          definition,
          map_implicits (fun t -> substitute t mapping) implicits )
  | TCon (info, name, args, sym) ->
      TCon (info, name, List.map (fun a -> substitute a mapping) args, sym)
  | type_ -> type_

(** type_ with the variables `vars` renamed to their positions, so that
    two types differing only in the names they bind compare equal.
    typ -> [string] -> typ *)
let canonical type_ vars =
  let info = type_info type_ in
  substitute type_
    (List.mapi (fun i name -> (name, t_var info (Printf.sprintf "%%%d" i))) vars)

(** Every type-variable name written anywhere in type_, bound or free. A
    name a new variable picks has to avoid all of them, not just the free
    ones: reusing one an inner `all` binds would shadow it, and the
    printed signature would read as saying something else.
    typ -> StringSet.t *)
let rec names_in type_ =
  match type_ with
  | TVar (_, name, _, _) -> StringSet.singleton name
  | TForall (_, vars, body, _) ->
      List.fold_left (fun s v -> StringSet.add v s) (names_in body) vars
  | TList (_, element, _) -> names_in element
  | TTuple (_, elements, _) ->
      List.fold_left
        (fun s e -> StringSet.union s (names_in e))
        StringSet.empty elements
  | TFunction (_, params, result, _, _, _, _) ->
      List.fold_left
        (fun s p -> StringSet.union s (names_in p))
        (names_in result) params
  | TCon (_, _, args, _) ->
      List.fold_left
        (fun s a -> StringSet.union s (names_in a))
        StringSet.empty args
  | _ -> StringSet.empty

(** The index'th type-variable name that is not already spoken for.
    int -> StringSet.t -> string *)
let rec next_name index taken =
  let name =
    Printf.sprintf "%c%s"
      letters.[index mod 26]
      (if index < 26 then "" else string_of_int (index / 26))
  in
  if StringSet.mem name taken then next_name (index + 1) taken else name

(** A type's quantified variables and its body; a type with no `all` on
    it answers ([], itself). typ -> ([string], typ) *)
let instantiated type_ =
  match type_ with TForall (_, vars, body, _) -> (vars, body) | _ -> ([], type_)

(** A written type with its free variables quantified, or the type
    itself when it has none. typ -> typ *)
let generalize type_ =
  match free_vars type_ with
  | [] -> type_
  | variables -> t_forall (type_info type_) variables type_

(** One use of a polymorphic type: its outermost `all` stripped and every
    variable it bound replaced by a fresh metavariable. A type with no
    `all` on it is its own only use.

    This is where a definition serves two callers at two types, and it is
    also what stops inference ever producing a higher rank: an argument
    arrives here as its instances rather than as the `all` itself, so no
    `all` can be carried into a parameter type the checker is working
    out. typ -> store -> (typ, store) *)
let rec instantiate type_ store =
  match type_ with
  | TForall (info, vars, body, _) ->
      let metas, store = fresh_metas (List.length vars) info store in
      let body = substitute body (List.combine vars metas) in
      (body, strings_of_chars body store)
  | type_ -> (type_, store)

(** store with the element of every kind variable in type_ that became
    a String solved to Char. A decided kind variable reads back as its
    type, and a String's has no element to carry, so each fresh instance
    of a scheme holding one is told here what its element is.
    typ -> store -> store *)
and strings_of_chars type_ store =
  let rec walk store t =
    match t with
    | TCon (_, name, [ element ], _) when is_kind_name name -> (
        let store = walk store element in
        match (prune t store, prune element store) with
        | TString _, TVar (info, meta, _, false) -> solving store meta (t_char info)
        | _ -> store)
    | TList (_, element, _) -> walk store element
    | TTuple (_, elements, _) | TCon (_, _, elements, _) -> List.fold_left walk store elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk (List.fold_left walk store (params @ implicit_types implicits)) result
    | TVar (_, name, _, false) -> (
        match SMap.find_opt name store.solutions with Some answer -> walk store answer | None -> store)
    | _ -> store
  in
  walk store type_

(** type_ with the metavariables nothing solved named `a`, `b`, ... A
    metavariable is not a type anyone can write, but one left open
    stands for a type nothing decided -- which is what a variable says,
    and which is what `[]` on its own is worth. typ -> store -> typ *)
let rec displayed type_ store =
  match metas_in type_ store with
  | [] -> indexed_named type_
  | open_metas ->
      let taken = names_in type_ in
      let _, chosen =
        List.fold_left
          (fun (names, chosen) meta ->
            if StringSet.mem meta store.captured then
              (* An enclosing scope's, so not this type's to name: `?`,
                 which prints as no annotation at all rather than as a
                 variable claiming to be anyone's to choose. *)
              (names, chosen @ [ (meta, t_unknown (type_info type_)) ])
            else
              let name =
                next_name (List.length names)
                  (List.fold_left
                     (fun s n -> StringSet.add n s)
                     taken names)
              in
              ( names @ [ name ],
                chosen @ [ (meta, t_meta (type_info type_) name) ] ))
          ([], []) open_metas
      in
      indexed_named (substitute type_ chosen)

(** type_ with every kind variable still open named `Indexed`: a store
    of elements whose kind its first call will say, as a message or a
    hover shows it. A kind variable's own name is bookkeeping.
    typ -> typ *)
and indexed_named type_ =
  match type_ with
  | TCon (info, name, args, sym) ->
      TCon (info, (if is_kind_name name then "Indexed" else name), List.map indexed_named args, sym)
  | TList (info, element, sym) -> TList (info, indexed_named element, sym)
  | TTuple (info, elements, sym) -> TTuple (info, List.map indexed_named elements, sym)
  | TFunction (info, params, result, sym, tmsym, definition, implicits) ->
      TFunction
        ( info,
          List.map indexed_named params,
          indexed_named result,
          sym,
          tmsym,
          definition,
          map_implicits indexed_named implicits )
  | TForall (info, vars, body, sym) -> TForall (info, vars, indexed_named body, sym)
  | type_ -> type_

(** type_ as an error message should name it: solved as far as the store
    goes, with anything still open named `a`, `b`, ... A metavariable's
    own name is bookkeeping and must never reach a message.
    typ -> store -> string *)
let shown type_ store = printed (displayed (zonk type_ store) store)

(** `shown`, parenthesised where a bare function type would read wrongly
    beside other text. typ -> store -> string *)
let shown_nested type_ store =
  printed_nested (displayed (zonk type_ store) store)

(* --- comparing types --- *)

(** Whether two types are the same type, structurally -- never OCaml's
    own equality, since a type node carries an info and a symbol that
    also differ. typ -> typ -> bool *)
let rec same_type a b =
  match (a, b) with
  | TInt _, TInt _
  | TFloat _, TFloat _
  | TString _, TString _
  | TChar _, TChar _
  | TBool _, TBool _ ->
      true
  | TBuiltin (_, x, _), TBuiltin (_, y, _) ->
      (* Each host operation is its own type, and no two of them are the
         same one. *)
      x = y
  | TUnknown _, TUnknown _ ->
      (* Two types nothing has decided are the same lack of a decision. *)
      true
  | TList (_, x, _), TList (_, y, _) -> same_type x y
  | TTuple (_, xs, _), TTuple (_, ys, _) ->
      List.length xs = List.length ys && List.for_all2 same_type xs ys
  | TFunction (_, ps, r, _, _, _, mine), TFunction (_, qs, s, _, _, _, theirs)
    ->
      (* A function *is* its parameters and its result. The other two
         fields -- the symbol of the definition it came from and that
         definition -- say what is left to do about it, which is not part
         of what it means. Its implicit parameters are: they are matched
         by name as well as by type, since the name is half of what
         resolves one (PYKING.md, "Implicits"). *)
      List.length ps = List.length qs
      && List.for_all2 same_type ps qs
      && same_implicits mine theirs
      && same_type r s
  | TVar (_, x, _, true), TVar (_, y, _, true) ->
      (* A variable is rigid: inside a body it stands for a type the
         caller picked, so it is the same type as itself and nothing
         else. That is the whole of what makes a polymorphic body
         honest -- no substitution is needed to enforce it. *)
      x = y
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) ->
      (* A flexible one is not named by the source, so what tells two
         apart is which handing-out made them. A flexible and a rigid
         variable are never the same type, whatever they are called. *)
      mine = theirs
  | TForall (_, mine, my_body, _), TForall (_, theirs, their_body, _) ->
      (* Two polytypes are one type when they differ only in the names
         they bind, so both are renamed by position first. *)
      List.length mine = List.length theirs
      && same_type (canonical my_body mine) (canonical their_body theirs)
  | TCon (_, x, xs, _), TCon (_, y, ys, _) ->
      (* A datatype is its name, which the checker has made canonical,
         applied to its parameters. *)
      x = y && List.length xs = List.length ys && List.for_all2 same_type xs ys
  | _ -> false

(** Whether two lists of implicit parameters are the same, name by name
    and type by type. [implicit_param] -> [implicit_param] -> Bool *)
and same_implicits mine theirs =
  List.length mine = List.length theirs
  && List.for_all2
       (fun (IParam (a, x)) (IParam (b, y)) -> a = b && same_type x y)
       mine theirs

let is_forall type_ = match type_ with TForall _ -> true | _ -> false

(** Whether a value of type actual may be used where expected is wanted,
    deciding nothing: this is `same_type` plus the one place a scheme is
    used at an instance of itself.

    Where a type is still open, `unify` is what answers instead --
    `accepts` is for the two places nothing may be solved: an annotation
    the source wrote, and `verified`'s re-check with the variables
    rigid. typ -> typ -> bool *)
let rec accepts expected actual =
  match (expected, actual) with
  | TForall (_, _, body, _), _ when not (is_forall actual) ->
      (* The outermost `all` of a written annotation says the type is
         polymorphic; whether a value is, is decided by the body with
         its variables rigid. *)
      accepts body actual
  | _, TForall (_, vars, body, _) when not (is_forall expected) ->
      (* The other way round: a polymorphic value stands wherever one of
         its instances is wanted, since every instance of it exists. *)
      instance_for body expected
        (List.fold_left (fun s v -> StringSet.add v s) StringSet.empty vars)
        []
      <> None
  | _ -> same_type expected actual

(** The bindings that make `general` -- the body of a polymorphic type --
    into `wanted`, or None where no instantiation of it does. One way and
    with no solver, exactly as a call is decided: a variable is settled
    the first time it is met and has to agree with every later meeting. A
    `?` in `wanted` is a demand nothing has made yet, so it decides
    nothing and refuses nothing.
    typ -> typ -> StringSet.t -> [(string, typ)] -> [(string, typ)] option *)
and instance_for general wanted quantified chosen =
  let each mine theirs chosen =
    List.fold_left2
      (fun answer one other ->
        match answer with
        | None -> None
        | Some chosen -> instance_for one other quantified chosen)
      (Some chosen) mine theirs
  in
  match wanted with
  | TUnknown _ -> Some chosen
  | _ -> (
      match (general, wanted) with
      | TVar (_, name, _, _), _ when StringSet.mem name quantified -> (
          match List.assoc_opt name chosen with
          | None -> Some ((name, wanted) :: chosen)
          | Some earlier ->
              if same_type earlier wanted then Some chosen else None)
      | TList (_, element, _), TList (_, other, _) ->
          instance_for element other quantified chosen
      | TTuple (_, mine, _), TTuple (_, theirs, _)
        when List.length mine = List.length theirs ->
          each mine theirs chosen
      | TCon (_, x, mine, _), TCon (_, y, theirs, _)
        when x = y && List.length mine = List.length theirs ->
          each mine theirs chosen
      | ( TFunction (_, mine, my_result, _, _, _, my_implicits),
          TFunction (_, theirs, their_result, _, _, _, their_implicits) )
        when List.length mine = List.length theirs
             && implicit_names my_implicits = implicit_names their_implicits
        -> (
          match
            each
              (mine @ implicit_types my_implicits)
              (theirs @ implicit_types their_implicits)
              chosen
          with
          | None -> None
          | Some chosen ->
              instance_for my_result their_result quantified chosen)
      | _ -> if accepts general wanted then Some chosen else None)

(* --- unification --- *)

(** The store in which these two types are the same type, or None where
    no solution makes them so.

    First-order and eager: it is called at the places a type is demanded
    -- a call's arguments, an operator's operands, two branches -- and it
    answers there and then. Nothing is remembered for later, which is
    what keeps it local (docs/type_inference.md, "Unification, and how
    little of it there is"). typ -> typ -> store -> store option *)
let rec unify one other store =
  let one, other = (prune one store, prune other store) in
  match (one, other) with
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) when mine = theirs ->
      Some store
  | TVar (_, mine, _, false), TVar (_, theirs, _, false) ->
      (* Two metavariables, one type: the *younger* is solved to the
         older. Which way round matters, and only here. A metavariable
         handed out earlier may belong to an enclosing scope, and solving
         that one to a fresh inner variable would lose exactly the fact
         that stops a nested `def` generalising its enclosing function's
         parameter (see `generalise`). Names count upwards, so the order
         they were handed out in is the order of their names. *)
      if meta_age mine <= meta_age theirs then Some (solving store theirs one)
      else Some (solving store mine other)
  | TVar (_, name, _, false), _ ->
      if occurs name other store then None else Some (solving store name other)
  | _, TVar (_, name, _, false) ->
      if occurs name one store then None else Some (solving store name one)
  | TList (_, mine, _), TList (_, theirs, _) -> unify mine theirs store
  | TTuple (_, mine, _), TTuple (_, theirs, _)
    when List.length mine = List.length theirs ->
      unify_each mine theirs store
  | TCon (info, x, [ mine ], _), TCon (_, y, [ theirs ], _) when is_kind_name x && is_kind_name y ->
      (* Two kind variables are one: both link to a new one allowing
         what both allowed. None allowed by both, no solution. *)
      if x = y then unify mine theirs store
      else (
        match List.filter (fun k -> List.mem k (kind_allowed y)) (kind_allowed x) with
        | [] -> None
        | common ->
            let name = kind_var_name store.fresh common in
            let link = TCon (info, name, [], 0) in
            let store =
              { store with fresh = store.fresh + 1; open_kinds = name :: store.open_kinds }
            in
            unify mine theirs (solving (solving store x link) y link))
  | TCon (_, name, [ element ], _), other when is_kind_name name -> decide_kind name element other store
  | other, TCon (_, name, [ element ], _) when is_kind_name name -> decide_kind name element other store
  | TCon (_, x, mine, _), TCon (_, y, theirs, _)
    when x = y && List.length mine = List.length theirs ->
      unify_each mine theirs store
  | ( TFunction (_, mine, my_result, _, _, _, my_implicits),
      TFunction (_, theirs, their_result, _, _, _, their_implicits) )
    when List.length mine = List.length theirs
         && implicit_names my_implicits = implicit_names their_implicits -> (
      match unify_each mine theirs store with
      | None -> None
      | Some store -> (
          match
            unify_each
              (implicit_types my_implicits)
              (implicit_types their_implicits)
              store
          with
          | None -> None
          | Some store -> unify my_result their_result store))
  | TForall (_, mine, my_body, _), TForall (_, theirs, their_body, _)
    when List.length mine = List.length theirs ->
      unify_under mine my_body theirs their_body store
  (* Everything else -- two ground types, two rigid variables -- is
     decided by `same_type`: there is nothing to solve, so either they
     already are one type or no solution makes them one. *)
  | _ -> if same_type one other then Some store else None

(** The store in which the open kind variable `name`, over `element`, is
    the settled type `other`: the kind it is, where the variable allows
    it, and the element its element -- a String's a Char. None where
    `other` is no kind it allows. string -> typ -> typ -> store -> store option *)
and decide_kind name element other store =
  match container_of other with
  | Some kind when List.mem kind (kind_allowed name) -> (
      let info = type_info other in
      let store = solving store name (container_type kind info (t_unknown info)) in
      match other with
      | TString _ -> unify element (t_char info) store
      | TList (_, theirs, _) -> unify element theirs store
      | TCon (_, _, [ theirs ], _) -> unify element theirs store
      | _ -> None)
  | _ -> None

(** The store in which each of these types is the one beside it, or None
    where no solution makes them so.
    [typ] -> [typ] -> store -> store option *)
and unify_each mine theirs store =
  List.fold_left2
    (fun answer x y ->
      match answer with None -> None | Some store -> unify x y store)
    (Some store) mine theirs

(** The store in which two schemes are one scheme: both binders are
    renamed to the same fresh rigid variables and the bodies unified, so
    a metavariable inside either is solved rather than compared. None
    where no solution makes them one, or where one would let a bound
    variable escape (docs/type_inference.md, "Unifying under a
    quantifier").
    [string] -> typ -> [string] -> typ -> store -> store option *)
and unify_under mine my_body theirs their_body store =
  let free =
    List.fold_left
      (fun s name -> StringSet.add name s)
      (List.fold_left
         (fun s name -> StringSet.add name s)
         StringSet.empty (metas_in my_body store))
      (metas_in their_body store)
  in
  let info = type_info my_body in
  (* `!` is unwritable in source, so these collide with no name a
     program could have chosen. *)
  let shared_names =
    List.init (List.length mine) (fun i ->
        Printf.sprintf "!%d" (store.fresh + i))
  in
  let shared = List.map (fun name -> t_var info name) shared_names in
  let store = { store with fresh = store.fresh + List.length mine } in
  match
    unify
      (substitute my_body (List.combine mine shared))
      (substitute their_body (List.combine theirs shared))
      store
  with
  | None -> None
  | Some answer ->
      (* A metavariable free before the two met belongs to a scope where
         these variables mean nothing, so one solved to a type naming
         them would name a type nobody there can name. *)
      let bound =
        List.fold_left (fun s name -> StringSet.add name s) StringSet.empty
          shared_names
      in
      if
        StringSet.exists
          (fun meta ->
            List.exists
              (fun loose -> StringSet.mem loose bound)
              (free_vars (zonk (t_meta info meta) answer)))
          free
      then None
      else Some answer

(** The store in which `actual` is `wanted`, or a Type_error saying what
    wanted it. This is how a construct asks for a type: `unify` where the
    answer is still open, an ordinary comparison where it is not, and one
    message either way. typ -> typ -> info -> string -> store -> store *)
let demand actual wanted info what store =
  match unify wanted actual store with
  | Some answer -> answer
  | None ->
      raise
        (Type_error
           ( info,
             Printf.sprintf "%s must be %s, not %s" what (shown wanted store)
               (shown actual store) ))

(** A fresh store of elements whose kind is left to its first call: a
    kind variable allowing `allowed`, over a fresh element. Answers the
    type, the element and the store. info -> [container] -> store -> (typ, typ, store) *)
let fresh_indexed info allowed store =
  let element, store = fresh_meta info store in
  let name = kind_var_name store.fresh allowed in
  ( TCon (info, name, [ element ], 0),
    element,
    { store with fresh = store.fresh + 1; open_kinds = name :: store.open_kinds } )

(** The store in which the open kind variable `name` allows no more than
    `allowed`: unchanged where it already does, linked to a new variable
    allowing what both do otherwise. None where nothing is left.
    info -> string -> [container] -> store -> store option *)
let narrow_kind info name allowed store =
  let mine = kind_allowed name in
  match List.filter (fun k -> List.mem k allowed) mine with
  | [] -> None
  | common when List.length common = List.length mine -> Some store
  | common ->
      let fresh = kind_var_name store.fresh common in
      Some
        (solving
           { store with fresh = store.fresh + 1; open_kinds = fresh :: store.open_kinds }
           name (TCon (info, fresh, [], 0)))

(** The type a use that indexes, slices or walks `actual` gives it, and
    its element: what it already is where that is settled; a store of
    elements left to the first call where nothing has decided it --
    allowing `allowed` -- or, for one already left so, the same one
    narrowed to `allowed`. None where it is a kind variable allowing
    none of `allowed`, or for a settled type (the caller says what then).
    typ -> info -> [container] -> store -> (typ * typ * store) option *)
let indexed_kind actual info allowed store =
  match prune actual store with
  | settled when is_meta settled ->
      let made, element, store = fresh_indexed info allowed store in
      Option.map (fun store -> (made, element, store)) (unify settled made store)
  | settled when kind_var_parts settled <> None -> (
      let name, element = Option.get (kind_var_parts settled) in
      match narrow_kind info name allowed store with
      | Some store -> Some (prune settled store, element, store)
      | None -> None)
  | _ -> None

(** The store in which `actual` is a list, and the type of its elements.
    typ -> info -> string -> store -> (typ, store) *)
let demand_list actual info what store =
  let element, store = fresh_meta info store in
  (element, demand actual (t_list info element) info what store)

(** What a `for` or a comprehension walks: a String's Chars, or a list's
    elements. typ -> info -> string -> store -> (typ, store) *)
let demand_sequence actual info what store =
  match prune actual store with
  | TString _ -> (TChar (info, 0), store)
  | settled when store_element settled <> None -> (Option.get (store_element settled), store)
  | settled when mutmap_parts settled <> None -> (fst (Option.get (mutmap_parts settled)), store)
  | settled when is_meta settled || kind_var_parts settled <> None -> (
      (* Nothing has said what is walked: its first call will. *)
      match indexed_kind settled info all_containers store with
      | Some (_, element, store) -> (element, store)
      | None -> demand_list actual info what store)
  | _ -> demand_list actual info what store

(* --- what the store records --- *)

(** store recording where the definition tmsym was written.
    store -> int -> env -> store *)
let with_environment store tmsym env =
  { store with environments = IntMap.add tmsym env store.environments }

(** Where tmsym was written, or None. store -> int -> env option *)
let environment_of store tmsym = IntMap.find_opt tmsym store.environments

(** What tmsym was worked out to be, or None if nothing has called it
    yet. A definition is worked out once, so there is at most one.
    store -> int -> typ option *)
let instance_of store tmsym = IntMap.find_opt tmsym store.instances

(** store with tmsym's worked-out type recorded.
    store -> int -> typ -> store *)
let remembering store tmsym type_ =
  { store with instances = IntMap.add tmsym type_ store.instances }

(** store with tmsym's body marked as being checked.
    store -> int -> store *)
let checking_now store tmsym =
  { store with checking = IntSet.add tmsym store.checking }

(** store recording the type a `def name : type` line gave the definition
    sym. store -> int -> typ -> store *)
let with_signature store sym type_ =
  { store with signatures = IntMap.add sym type_ store.signatures }

(** store gathering into a different frame. store -> frame -> store *)
let with_frame store frame = { store with frame }

(** store whose frame has seen a `return` at info giving type_.
    store -> info -> typ -> store *)
let returning store info type_ =
  with_frame store
    { returns = store.frame.returns @ [ { given_info = info; given_type = type_ } ] }

(** store with what an inner check found out (environments, instances,
    solutions, and the result tables) merged in; frame and checking stay
    store's own. A solution is knowledge like the others: a metavariable
    is handed out once, so no two checks can disagree about one.
    store -> store -> store *)
let learned store inner =
  {
    store with
    environments = inner.environments;
    instances = inner.instances;
    fresh = inner.fresh;
    solutions = inner.solutions;
    groups = inner.groups;
    captured = StringSet.union store.captured inner.captured;
    tmap = inner.tmap;
    (* `qmap` is a result exactly as `tmap` is, so it comes back for the
       same reason: a call resolved while a deferred definition's body
       was being worked out is resolved once, and dropping it here would
       leave `elaborate.ml` with nothing to rewrite that call by. *)
    qmap = inner.qmap;
    (* A `+` whose operands the inner check left open is still to be
       decided, here or further out. *)
    pending_plus = inner.pending_plus;
    open_kinds = inner.open_kinds;
    kind_origins = inner.kind_origins;
    upcasts = inner.upcasts;
  }

(** store with what this call denotes recorded under its symbol. Like
    `record` it overwrites: a generalisable body is checked twice, and
    `verified`'s pass is the one that counts.
    store -> int -> resolution -> store *)
let record_resolution store sym answer =
  { store with qmap = IntMap.add sym answer store.qmap }

(* How deep a chain of implicits resolving implicits may go before it is
   called a mistake rather than a program. *)
let max_implicit_depth = 32

(** store with a node's type recorded, with every metavariable in it
    replaced by what it was solved to. Overwrites: a body checked twice
    -- once to work it out and once to verify -- reports the second
    answer. store -> int -> typ -> store *)
let record store sym type_ =
  { store with tmap = IntMap.add sym (zonk type_ store) store.tmap }

(* --- ground types, and the tables that name them --- *)

(** The ground types the operator and builtin tables name. *)
type kind = KInt | KFloat | KString | KChar | KBool | KList | KTuple | KData | KArray | KDynArray | KMutMap | KSlice

(** Whether a type is of this kind, deciding nothing.
    kind -> typ -> bool *)
let kind_matches kind type_ =
  match (kind, type_) with
  | KInt, TInt _
  | KFloat, TFloat _
  | KString, TString _
  | KChar, TChar _
  | KBool, TBool _
  | KList, TList _
  | KTuple, TTuple _ ->
      true
  | (KList | KString | KArray | KDynArray | KSlice), TCon (_, name, _, _) when is_kind_name name ->
      (* A store of elements its first call will settle: of this kind
         where it may still become one. *)
      List.exists
        (fun c ->
          match (c, kind) with
          | CList, KList | CString, KString | CArray, KArray | CDynArray, KDynArray | CSlice, KSlice -> true
          | _ -> false)
        (kind_allowed name)
  | KData, TCon (_, name, _, _) -> not (is_kind_name name)
  | KArray, TCon (_, name, _, _) -> name = array_name
  | KDynArray, TCon (_, name, _, _) -> name = dynarray_name
  | KMutMap, TCon (_, name, _, _) -> name = mutmap_name
  | KSlice, TCon (_, name, _, _) -> name = slice_name
  | _ -> false

(** The type a kind names. Only the atoms are ever built: KList and
    KTuple appear in the builtins' rules, which compare rather than
    construct. kind -> info -> typ *)
let kind_type kind info =
  match kind with
  | KInt -> t_int info
  | KFloat -> t_float info
  | KString -> t_string info
  | KChar -> t_char info
  | KBool -> t_bool info
  | KList -> t_list info (t_unknown info)
  | KTuple -> t_tuple info []
  | KData -> t_tuple info []
  | KArray -> t_array info (t_unknown info)
  | KDynArray -> t_dynarray info (t_unknown info)
  | KMutMap -> t_mutmap info (t_unknown info) (t_unknown info)
  | KSlice -> t_slice info (t_unknown info)

(** Whether type_ is one of kinds. A flexible variable counts as any of
    them, since no value of it arrives. typ -> [kind] -> bool *)
let every type_ kinds =
  match type_ with
  | TCon (_, name, _, _) when is_kind_name name ->
      (* Every kind it may still become has to be accepted, since the
         first call may choose any of them. *)
      let accepted c =
        List.exists
          (fun kind ->
            match (c, kind) with
            | CList, KList | CString, KString | CArray, KArray | CDynArray, KDynArray | CSlice, KSlice -> true
            | _ -> false)
          kinds
      in
      List.for_all accepted (kind_allowed name)
  | _ -> List.exists (fun kind -> kind_matches kind type_) kinds || is_meta type_

(* One row per operand type an operator accepts, paired with what it is
   then worth. PYKING.md, "Operators", is the table this implements. *)

(** The rows `+ - * /` share. Int comes first, and being first is what
    decides an operand nothing else has: see docs/type_inference.md,
    "Two numeric types, no type classes". [(kind, kind)] *)
let arithmetic = [ (KInt, KInt); (KFloat, KFloat) ]

(** The rows `< <= > >=` share. Both answer Bool, so an operand nothing
    has decided is left open rather than defaulted -- which is what `==`
    already does. [(kind, kind)] *)
let ordering = [ (KInt, KBool); (KFloat, KBool); (KChar, KBool) ]

(** The rows `==` and `!=` share. [(kind, kind)] *)
let equality =
  [ (KInt, KBool); (KFloat, KBool); (KString, KBool); (KChar, KBool); (KBool, KBool) ]

(** The rows of `and` and `or`, spelled as words, and of `xor`: logic
    on Bools and bitwise on Ints. Bool comes first, so two operands nothing has
    decided are Bools -- logic is what the words are written for most.
    [(kind, kind)] *)
let logic_words = [ (KBool, KBool); (KInt, KInt) ]

(** The rows of the bitwise operators. [(kind, kind)] *)
let bitwise = [ (KInt, KInt) ]

(** The rows of a binary operator in the EBinary node.
    binop -> [(kind, kind)] *)
let binop_rows op =
  match op with
  | BMod | BPow -> arithmetic
  | BNeq -> equality
  | BAnd Word | BOr Word | BXor -> logic_words
  | BAnd Symbol | BOr Symbol | BBoolXor -> [ (KBool, KBool) ]
  | BBitAnd _ | BBitOr _ | BShiftLeft | BShiftRight -> bitwise

(** An operator's spelling and its rows, or None for an expression that
    is not one. expr -> (string, [(kind, kind)]) option *)
let operator_of expr =
  match expr with
  | EAdd _ -> Some ("+", arithmetic @ [ (KString, KString) ])
  | EConcat _ -> Some ("+", [ (KString, KString) ])
  | ESub _ -> Some ("-", arithmetic)
  | EMul _ -> Some ("*", arithmetic)
  | EDiv _ -> Some ("/", arithmetic)
  | ELessThan _ -> Some ("<", ordering)
  | ELessThanEq _ -> Some ("<=", ordering)
  | EGreatThan _ -> Some (">", ordering)
  | EGreatThanEq _ -> Some (">=", ordering)
  | EEq _ -> Some ("==", equality)
  | EBinary (_, op, _, _, _) -> Some (binop_text op, binop_rows op)
  | _ -> None

(** The two operands of a binary operator application.
    expr -> (expr, expr) option *)
let binary_operands expr =
  match expr with
  | EAdd (_, left, right, _)
  | EConcat (_, left, right, _)
  | ESub (_, left, right, _)
  | EMul (_, left, right, _)
  | EDiv (_, left, right, _)
  | ELessThan (_, left, right, _)
  | ELessThanEq (_, left, right, _)
  | EGreatThan (_, left, right, _)
  | EGreatThanEq (_, left, right, _)
  | EEq (_, left, right, _)
  | EBinary (_, _, left, right, _) ->
      Some (left, right)
  | _ -> None

(* The operators that are easy to write for one another: `&` where
   `and` was meant on Bools, `&&` where `and` or `&` was meant on Ints.
   Each names the other when a mismatch is exactly the swap -- and only
   then, so `1 & 'a'`, which no operator would take, is not offered a
   suggestion. *)

(** The "did you mean" clause for an operator written where its
    look-alike belongs, or "" when there is nothing to suggest.
    expr -> typ -> typ -> string *)
let rec alternative expr left_type right_type =
  match expr with
  | (EEq _ | EBinary (_, BNeq, _, _, _))
    when kind_matches KArray left_type || kind_matches KArray right_type ->
      ". Arrays are compared with 'same(a, b)', which asks whether they \
       are one array, or with 'array.equal(a, b)' from lib/array, which \
       compares their elements"
  | (EAdd _ | ESub _)
    when (match (left_type, right_type) with
          | TCon (_, l, _, _), _ when l = ptr_name -> true
          | _, TCon (_, r, _, _) when r = ptr_name -> true
          | _ -> false) ->
      ". A pointer has no arithmetic: a run of an array's elements is a \
       view, 'view(a, i, j)', and an element's address is '&a[i]'"
  | (EEq _ | EBinary (_, BNeq, _, _, _))
    when kind_matches KMutMap left_type || kind_matches KMutMap right_type ->
      ". MutMaps are compared with 'same(a, b)', which asks whether they are \
       one MutMap"
  | (EEq _ | EBinary (_, BNeq, _, _, _))
    when kind_matches KDynArray left_type || kind_matches KDynArray right_type ->
      ". DynArrays are compared with 'same(a, b)', which asks whether they are \
       one DynArray, or with 'dynarray.equal(a, b)' from lib/dynarray, which compares \
       their elements"
  | (EEq _ | EBinary (_, BNeq, _, _, _)) when kind_matches KData left_type && kind_matches KData right_type ->
      ". A struct or a datatype's value is compared field by field, by a \
       function the program writes; 'same(a, b)' asks whether two var \
       structs are one"
  | _ -> alternative_scalar expr left_type right_type

and alternative_scalar expr left_type right_type =
  let mixed_numbers =
    (kind_matches KInt left_type && kind_matches KFloat right_type)
    || (kind_matches KFloat left_type && kind_matches KInt right_type)
  in
  if mixed_numbers then
    ". Pyking mixes no numbers on its own: `float(n)` makes an Int a Float, \
     and `int(x)` truncates a Float to an Int"
  else
    let on_bools text =
      if kind_matches KBool left_type && kind_matches KBool right_type then
        ". On Bools, write " ^ text
      else ""
    in
    let on_ints text =
      if kind_matches KInt left_type && kind_matches KInt right_type then
        ". On Ints, write " ^ text
      else ""
    in
    match expr with
    | EAdd _ ->
        if
          (kind_matches KString left_type && kind_matches KInt right_type)
          || (kind_matches KInt left_type && kind_matches KString right_type)
        then ". `+` joins two Strings and converts nothing: write string(n)"
        else if
          (kind_matches KString left_type && kind_matches KChar right_type)
          || (kind_matches KChar left_type && kind_matches KString right_type)
        then ". `+` joins two Strings, and a Char is not one: write string(c)"
        else ""
    | EBinary (_, BBitAnd Symbol, _, _, _) -> on_bools "'and' (or '&&')"
    | EBinary (_, BBitOr Symbol, _, _, _) -> on_bools "'or' (or '||')"
    | EBinary (_, BAnd Symbol, _, _, _) -> on_ints "'and' or '&'"
    | EBinary (_, BOr Symbol, _, _, _) -> on_ints "'or' or '|'"
    | _ -> ""

(** The Type_error for an operator applied to what it does not accept,
    naming what it does.
    expr -> string -> [(kind, kind)] -> typ -> typ -> store -> exn *)
let operator_error expr spelling rows left_type right_type store =
  let info = expr_info expr in
  let accepted =
    String.concat " or "
      (List.map
         (fun (operand, _) ->
           let name = printed (kind_type operand info) in
           Printf.sprintf "%s %s %s" name spelling name)
         rows)
  in
  let accepted =
    match expr with
    | EAdd _ | EConcat _ -> accepted ^ " or two lists of one type"
    | _ -> accepted
  in
  let together =
    displayed
      (t_tuple info [ zonk left_type store; zonk right_type store ])
      store
  in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (left_type, right_type)
  in
  Type_error
    ( info,
      Printf.sprintf "`%s` cannot be applied to %s and %s; it accepts %s%s"
        spelling (printed mine) (printed theirs) accepted
        (alternative expr (zonk left_type store) (zonk right_type store)) )

(* --- agreement --- *)

(** The one type two branches both have, and the store that makes it so,
    or (None, store) where nothing does.

    Two branches of one `if` yield one value, so they are the same type
    -- which `unify` decides, and which is also what settles a base case
    returning `[]` against a branch returning `[1]`: the empty list's
    element is a metavariable, and being one type with `Int` solves it. A
    branch that never falls through is written None and leaves the answer
    to the other one. typ option -> typ option -> store -> (typ option, store) *)
let agree first second store =
  match (first, second) with
  | None, _ -> (second, store)
  | _, None -> (first, store)
  | Some first, Some second -> (
      match unify first second store with
      | None -> (None, store)
      | Some answer -> (Some (zonk first answer), answer))

(** The store in which `actual` supplies what `expected` wants, or None.
    `unify` first -- anything still open is settled by the demand -- and
    `accepts` after it, for the one thing unification does not do: use a
    scheme at an instance of itself.
    typ -> typ option -> store -> store option *)
let satisfies expected actual store =
  match actual with
  (* The statement supplying this never falls through, so no value
     arrives and there is none to be wrong. *)
  | None -> Some store
  | Some actual -> (
      match unify expected actual store with
      | Some answer -> Some answer
      | None ->
          if accepts (zonk expected store) (zonk actual store) then Some store
          else None)

(** Raises Type_error if an if yields one of two different unannotated
    functions (see docs/type_inference.md). typ option -> typ option ->
    info -> () *)
let check_not_conflated then_type else_type info =
  let definition type_ =
    match type_ with
    | Some (TFunction (_, _, _, _, _, Some (SFunctionDef _ as node), _)) ->
        Some node
    | _ -> None
  in
  match (definition then_type, definition else_type) with
  | ( Some (SFunctionDef (_, my_name, _, _, _, my_sym, _, _, _)),
      Some (SFunctionDef (_, their_name, _, _, _, their_sym, _, _, _)) )
    when my_sym <> their_sym ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this 'if' yields one of two functions -- '%s' and '%s' -- and \
                neither says what its type is, so there is no telling which \
                one a later call would be checking. Annotate them, or call \
                them where they are chosen"
               my_name their_name ))
  | _ -> ()

(** The message for a loop body that does not end in the accumulator the
    next turn carries. typ -> typ -> store -> string *)
let carry_error acc_type actual store =
  let together = displayed (t_tuple builtin_info [ acc_type; actual ]) store in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (acc_type, actual)
  in
  Printf.sprintf "this loop carries %s, but its body ends in %s" (printed mine)
    (printed theirs)

(** The `if` with no `else` a loop body's end falls through, where that
    is why the body ends in no accumulator: the `if` and its condition,
    since that is what the message is about. [stmt] -> info option *)
let rec open_if stmts =
  match List.rev stmts with
  | SIf (info, cond, _, None, _) :: _ ->
      let c = expr_info cond in
      Some { info with row2 = c.row2; col2 = c.col2 }
  | SIf (_, _, then_body, Some else_body, _) :: _ -> (
      match open_if then_body with
      | Some info -> Some info
      | None -> open_if else_body)
  | SMatch (_, _, cases, _) :: _ ->
      List.find_map (fun (MatchCase (_, _, _, body, _)) -> open_if body) cases
  | _ -> None

(** The message for a loop body whose end an `if` with no `else` falls
    through: on that path nothing gives the next turn its accumulator.
    typ -> store -> string *)
let open_if_error acc_type store =
  Printf.sprintf
    "this loop carries %s, but its body can reach its end without a \
     'continue' or a 'break': this 'if' has no 'else', so when its \
     condition is false nothing says what the loop does next. Add an \
     'else' that continues or breaks, or a 'continue' or a 'break' after \
     the 'if'"
    (printed (displayed acc_type store))

(** The message for a `break`/`continue` whose value is not the
    accumulator the loop carries. string -> typ -> typ -> store -> string *)
let jump_error keyword acc_type actual store =
  let together = displayed (t_tuple builtin_info [ acc_type; actual ]) store in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (acc_type, actual)
  in
  Printf.sprintf "this loop carries %s, but this '%s' gives it %s"
    (printed mine) keyword (printed theirs)

(** Why a statement's branches had to agree, said after the error that
    they do not: its value is used, which a statement after it would
    have stopped. string -> string -> string *)
let value_used statement parts =
  Printf.sprintf
    "Its value is used -- it is bound, or it ends a function or a loop \
     body that carries a value -- so its %s must give one type. With a \
     statement after it, the %s would only be run, and its %s could \
     differ"
    parts statement parts

(* --- where a block is left --- *)

(** Whether one statement says what happens next on every path through
    it. stmt -> bool *)
let rec ends_here statement =
  match statement with
  | SContinue _ | SBreak _ | SReturn _ | SReturnStmt _ -> true
  | SIf (_, _, then_body, else_body, _) -> (
      match else_body with
      | None -> false
      | Some else_body ->
          ends_every_path then_body && ends_every_path else_body)
  | SMatch (_, _, cases, _) ->
      (* Every `match` matches every value: exhaustive.ml refuses one
         that does not. *)
      List.for_all
        (fun (MatchCase (_, _, _, body, _)) -> ends_every_path body)
        cases
  | _ -> false

(** Whether every path through a loop body says what happens next --
    `continue`, `break` or `return`, or a branching statement whose every
    branch does. An `if` with no `else` has a path that runs neither, so
    it does not. [stmt] -> bool *)
and ends_every_path stmts =
  match List.rev stmts with [] -> false | last :: _ -> ends_here last

(* --- the environment --- *)

(** env with name bound to type_. A fresh map, so shadowing works by
    construction. `implicit` marks a binding an implicit argument may be
    resolved to; every ordinary binding form leaves it alone.
    env -> string -> typ -> env *)
let bind ?(implicit = false) ?(var = false) env name type_ =
  SMap.add name { btype = type_; bimplicit = implicit; bvar = var } env

(** The message for a name not in scope, naming the name in scope or
    the keyword it is most likely a misspelling of, where one is close
    (Suggest.closest). A name the compiler made up, or an overloaded
    definition's qualified one, is never offered.
    env -> string -> string *)
let unbound_message env name =
  let names =
    SMap.fold
      (fun n _ out ->
        if Names.is_qualified n || Desugar_args.generated_name n then out
        else n :: out)
      env []
  in
  let keywords =
    List.filter
      (fun k -> not (List.mem k Lexer.reserved_words || SMap.mem k env))
      Lexer.keywords
  in
  match Suggest.closest name (names @ keywords) with
  | meant :: _ when List.mem meant keywords ->
      Printf.sprintf "unbound name '%s': did you mean the keyword '%s'?" name
        meant
  | meant :: _ -> Printf.sprintf "unbound name '%s': did you mean '%s'?" name meant
  | [] -> Printf.sprintf "unbound name '%s'" name

(** The type a name denotes, or None where it is not in scope.
    env -> string -> typ? *)
let type_of env name =
  match SMap.find_opt name env with
  | Some binding -> Some binding.btype
  | None -> None


(* --- datatypes --- *)

(** The part of a canonical datatype name after its module, which is
    what its own module calls it. string -> string *)
let base_name canonical =
  match String.rindex_opt canonical '.' with
  | Some at -> String.sub canonical (at + 1) (String.length canonical - at - 1)
  | None -> canonical

(** A written type with every datatype name in it replaced by the
    canonical one the checker's types use, refusing a name that is not a
    datatype in scope and one applied to the wrong number of types.
    Inside a datatype's own declaration `params` are the only type
    variables there may be. [string]? -> store -> typ -> typ *)
let rec resolved ?params store type_ =
  let go = resolved ?params store in
  match type_ with
  | TCon (info, spelled, args, sym) -> (
      match SMap.find_opt spelled store.types with
      | None ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "unknown type '%s': a type starting with an uppercase \
                    letter is a datatype, and none of that name is declared \
                    or imported here"
                   spelled ))
      | Some canonical ->
          let wanted =
            match SMap.find_opt canonical store.datatypes with
            | Some (Datatype (_, wanted, _, _)) -> List.length wanted
            | None when List.mem canonical [ array_name; dynarray_name; slice_name; ptr_name ] -> 1
            | None when canonical = mutmap_name -> 2
            | None -> (
                match SMap.find_opt canonical store.classes with
                | Some c -> List.length c.cl_params
                | None -> List.length args)
          in
          if List.length args <> wanted then
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "'%s' takes %d type parameter%s, but is given %d" spelled
                     wanted
                     (if wanted = 1 then "" else "s")
                     (List.length args) ));
          TCon (info, canonical, List.map go args, sym))
  | TVar (info, name, _, true) -> (
      match params with
      | Some (owner, names) when not (List.mem name names) ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'%s' is not a parameter of '%s': a field's type may name \
                    only the datatype's own type parameters, written \
                    'datatype %s(%s)'"
                   name owner owner
                   (String.concat ", " (names @ [ name ])) ))
      | _ -> type_)
  | TList (info, element, sym) -> TList (info, go element, sym)
  | TTuple (info, elements, sym) -> TTuple (info, List.map go elements, sym)
  | TFunction (info, ps, result, sym, tmsym, definition, implicits) ->
      TFunction
        (info, List.map go ps, go result, sym, tmsym, definition, map_implicits go implicits)
  | TForall (info, vars, body, sym) ->
      let params =
        match params with
        | Some (owner, names) -> Some (owner, names @ vars)
        | None -> None
      in
      TForall (info, vars, resolved ?params store body, sym)
  | _ -> type_

(** A written annotation with its datatype names resolved, where there
    is one. store -> typ? -> typ? *)
let resolved_option store annotation = Option.map (resolved store) annotation

(** store knowing the datatypes these statements declare and the ones
    their imports bring in: every name spelled as the source may spell
    it, every constructor, and each field's type. A datatype's own name
    is in scope throughout the module, so datatypes may name each other
    in any order. [stmt] -> store -> store *)
let declare_datatypes stmts store =
  let add_imported store (exported, local) (Datatype (canonical, _, constructors, _) as d) =
    let store = { store with datatypes = SMap.add canonical d store.datatypes } in
    let store =
      if base_name canonical = exported then
        { store with types = SMap.add local canonical store.types }
      else store
    in
    if List.mem_assoc exported constructors then
      { store with constructors = SMap.add local canonical store.constructors }
    else store
  in
  let store =
    List.fold_left
      (fun store statement ->
        match statement with
        | SImport (_, module_, alias, selected, fields, _) -> (
            match List.assoc_opt module_ store.modules with
            | None -> store
            | Some sigmap ->
                let entries =
                  List.filter_map
                    (fun (n, t, _) ->
                      match t with TData (_, d, _) -> Some (n, d) | _ -> None)
                    sigmap
                in
                if selected then
                  List.fold_left
                    (fun store (exported, local) ->
                      match List.assoc_opt exported entries with
                      | Some d -> add_imported store (exported, local) d
                      | None -> store)
                    store fields
                else
                  List.fold_left
                    (fun store (exported, d) ->
                      add_imported store (exported, alias ^ "." ^ exported) d)
                    store entries)
        | _ -> store)
      store stmts
  in
  let own =
    List.filter_map
      (function
        | SDatatype (info, name, params, constructors, sym, _, writable) ->
            Some (info, name, params, constructors, sym, writable)
        | _ -> None)
      stmts
  in
  (* The names first, so a field may name any datatype of the module. *)
  let store =
    List.fold_left
      (fun store (info, name, params, _, _, writable) ->
        if SMap.mem name store.types then
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "the datatype '%s' is already declared; a datatype is \
                    declared once"
                   name ));
        {
          store with
          types = SMap.add name name store.types;
          datatypes = SMap.add name (Datatype (name, params, [], writable)) store.datatypes;
        })
      store own
  in
  let store =
    List.fold_left
      (fun store (_, name, _, constructors, _, _) ->
        List.fold_left
          (fun store (Constructor (ci, cname, _, _)) ->
            (match SMap.find_opt cname store.constructors with
            | Some owner ->
                raise
                  (Type_error
                     ( ci,
                       Printf.sprintf
                         "'%s' is already a constructor of '%s'; a \
                          constructor belongs to one datatype"
                         cname (base_name owner) ))
            | None -> ());
            { store with constructors = SMap.add cname name store.constructors })
          store constructors)
      store own
  in
  List.fold_left
    (fun store (info, name, params, constructors, sym, writable) ->
      let store, typed =
        List.fold_left
          (fun (store, typed) (Constructor (_, cname, fields, csym)) ->
            let store, fields =
              List.fold_left
                (fun (store, fields) (Field (fi, label, type_, _, fsym)) ->
                  let t, store =
                    match (type_, label) with
                    | Some type_, _ -> (resolved ~params:(name, params) store type_, store)
                    | None, Some field ->
                        (* Its default decides it, where its def is
                           written (`check_stmt`). *)
                        let meta, store = fresh_meta fi store in
                        ( meta,
                          {
                            store with
                            field_defaults =
                              SMap.add
                                (Desugar_args.field_default_name cname field)
                                (meta, field) store.field_defaults;
                          } )
                    | None, None -> (t_unknown fi, store)
                  in
                  (record store fsym t, fields @ [ (label, t) ]))
                (store, []) fields
            in
            let store =
              record store csym
                (TCon (info, name, List.map (t_var info) params, 0))
            in
            (store, typed @ [ (cname, fields) ]))
          (store, []) constructors
      in
      let d = Datatype (name, params, typed, writable) in
      let store = { store with datatypes = SMap.add name d store.datatypes } in
      record store sym (TData (info, d, 0)))
    store own

(* --- classes and interfaces ---
   PYKING.md, "Classes and interfaces"; design/plan-objects.md. A class
   is a nominal type, `TCon (name, args)`, like a datatype's. What the
   checker knows of it is in `store.classes`, built from the
   declarations' annotations alone -- every method says its types -- so
   the table is complete before any body is checked. *)

(** The class or interface of this canonical name, where there is one.
    store -> string -> class_info? *)
let class_named store name = SMap.find_opt name store.classes

(** Whether a type is an object's: a class's or an interface's.
    store -> typ -> bool *)
let is_object_type store t =
  match prune t store with TCon (_, name, _, _) -> SMap.mem name store.classes | _ -> false

(** What a class's parameters are at these arguments.
    class_info -> [typ] -> [(string, typ)] *)
let class_mapping c args =
  if List.length c.cl_params = List.length args then List.combine c.cl_params args else []

(** A class's type at its own parameters, which are rigid: what `self` is
    in its methods. info -> class_info -> typ *)
let self_type info c = TCon (info, c.cl_name, List.map (t_var info) c.cl_params, 0)

(** The supertypes a class names in its header, at the arguments `args`
    gives its parameters: the parent first. store -> (string * [typ]) ->
    [(string * [typ])] *)
let direct_supers store (name, args) =
  match class_named store name with
  | None -> []
  | Some c ->
      let mapping = class_mapping c args in
      List.map
        (fun (n, ts) -> (n, List.map (fun t -> substitute t mapping) ts))
        (Option.to_list c.cl_parent @ c.cl_interfaces)

(** A class and its parents, nearest first, each at its arguments.
    store -> (string * [typ]) -> [(string * [typ])] *)
let class_chain store start =
  let rec go seen (name, args) =
    if List.mem_assoc name seen then List.rev seen
    else
      let seen = (name, args) :: seen in
      match class_named store name with
      | Some { cl_parent = Some _; _ } -> (
          match direct_supers store (name, args) with
          | parent :: _ -> go seen parent
          | [] -> List.rev seen)
      | _ -> List.rev seen
  in
  go [] start

(** Every supertype of a class or interface, itself first: its class
    chain, then every interface reached from any of them, nearest first.
    store -> (string * [typ]) -> [(string * [typ])] *)
let all_supers store start =
  let rec go seen queue =
    match queue with
    | [] -> List.rev seen
    | (n, a) :: rest ->
        if List.mem_assoc n seen then go seen rest
        else go ((n, a) :: seen) (rest @ direct_supers store (n, a))
  in
  let chain = class_chain store start in
  go [] chain

(** The arguments a supertype has as seen from (name, args), where it is
    one. store -> (string * [typ]) -> string -> [typ]? *)
let super_as store start target = List.assoc_opt target (all_supers store start)

(** A method's types with a class's parameters given.
    [(string, typ)] -> method_info -> method_info *)
let method_at mapping m =
  {
    m with
    md_params = List.map (fun (n, t, d) -> (n, substitute t mapping, d)) m.md_params;
    md_return = substitute m.md_return mapping;
  }

(** The method `name` a value of class or interface `start` has: the
    class whose declaration it is, and its types at `start`'s arguments.
    A body a class in the chain gives is found before an interface's
    default, which is found before a declaration without a body -- which
    is Java's order. store -> (string * [typ]) -> string ->
    (string * method_info)? *)
let lookup_method_in store supers name =
  let declared (n, args) =
    match class_named store n with
    | Some c -> (
        match List.find_opt (fun m -> m.md_name = name) c.cl_methods with
        | Some m -> Some (n, method_at (class_mapping c args) m)
        | None -> None)
    | None -> None
  in
  let with_body ca = match declared ca with Some (_, m) as found when not m.md_abstract -> found | _ -> None in
  match List.find_map with_body supers with
  | Some found -> Some found
  | None -> List.find_map declared supers

let lookup_method store start name =
  let chain = class_chain store start in
  match List.find_map (fun ca -> lookup_method_in store [ ca ] name |> Option.map (fun r -> (ca, r))) chain with
  | Some (_, (owner, m)) when not m.md_abstract -> Some (owner, m)
  | _ -> lookup_method_in store (all_supers store start) name

(** The field `name` of a class, from it or a class above it: the class
    that declares it, and the field at `start`'s arguments.
    store -> (string * [typ]) -> string -> (string * field_info)? *)
let lookup_field store start name =
  List.find_map
    (fun (n, args) ->
      match class_named store n with
      | Some c -> (
          match List.find_opt (fun f -> f.fd_name = name) c.cl_fields with
          | Some f -> Some (n, { f with fd_type = substitute f.fd_type (class_mapping c args) })
          | None -> None)
      | None -> None)
    (class_chain store start)

(** Every method a class or interface has, its own and inherited, by
    name, each where `lookup_method` finds it.
    store -> (string * [typ]) -> [(string, (string * method_info))] *)
let all_methods store start =
  let names =
    List.fold_left
      (fun names (n, _) ->
        match class_named store n with
        | Some c ->
            List.fold_left
              (fun names m -> if List.mem m.md_name names then names else names @ [ m.md_name ])
              names c.cl_methods
        | None -> names)
      [] (all_supers store start)
  in
  List.filter_map (fun n -> Option.map (fun found -> (n, found)) (lookup_method store start n)) names

(** The store in which `actual` stands where `wanted` is expected: one
    type, or -- for objects -- a class or interface `actual`'s class
    extends or implements, which is an upcast, recorded under the
    expression's symbol negated for elaborate.ml. None where neither.
    store -> int -> typ -> typ -> store? *)
let coerced store sym wanted actual =
  match unify wanted actual store with
  | Some answer -> Some answer
  | None -> (
      match (prune wanted store, prune actual store) with
      | TCon (info, w, wargs, _), TCon (_, a, aargs, _)
        when w <> a && SMap.mem w store.classes && SMap.mem a store.classes -> (
          match super_as store (a, aargs) w with
          | Some seen -> (
              match unify (TCon (info, w, wargs, 0)) (TCon (info, w, seen, 0)) store with
              | Some answer -> Some (record_resolution answer (-sym) (Upcast (TCon (info, w, wargs, 0))))
              | None -> None)
          | None -> None)
      | _ -> None)

(** The class a construction or a pattern names, where it names one:
    `[module.]Name`. store -> string? -> string -> class_info? *)
let object_class store module_ name =
  let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
  match SMap.find_opt spelled store.types with
  | Some canonical -> class_named store canonical
  | None -> None

(** Whether a type mentions an object anywhere, so that a value written
    where it is wanted has the type pushed into it -- each element of a
    list literal upcast on its own. store -> typ -> bool *)
let rec mentions_object store t =
  match prune t store with
  | TCon (_, name, args, _) -> SMap.mem name store.classes || List.exists (mentions_object store) args
  | TList (_, e, _) -> mentions_object store e
  | TTuple (_, es, _) -> List.exists (mentions_object store) es
  | _ -> false

(** Two method signatures agree: the same parameters, by name and type,
    and the same result. method_info -> method_info -> bool *)
let same_signature a b =
  List.length a.md_params = List.length b.md_params
  && List.for_all2 (fun (n1, t1, _) (n2, t2, _) -> n1 = n2 && printed t1 = printed t2) a.md_params b.md_params
  && printed a.md_return = printed b.md_return

(** A method's signature as a program writes it, for a message.
    method_info -> string *)
let signature_text m =
  Printf.sprintf "%s(%s)%s" m.md_name
    (String.concat ", " ("self" :: List.map (fun (n, t, _) -> n ^ ": " ^ printed t) m.md_params))
    (match m.md_return with TTuple (_, [], _) -> "" | t -> " -> " ^ printed t)

(** store knowing every class and interface these statements declare:
    their names first, so they may name each other in any order, then
    what each says, then the rules a declaration must keep -- every one
    checked here, at the class, before any body is.
    [stmt] -> store -> store *)
let declare_classes stmts store =
  let own = List.filter_map (function SClass (i, c, _) -> Some (i, c) | _ -> None) stmts in
  (* A class declared again -- a REPL entry redefining one -- replaces it. *)
  let store =
    List.fold_left
      (fun store (_, c) ->
        if SMap.mem c.c_name store.classes then
          { store with classes = SMap.remove c.c_name store.classes; types = SMap.remove c.c_name store.types }
        else store)
      store own
  in
  let store =
    List.fold_left
      (fun store (i, c) ->
        if SMap.mem c.c_name store.types then
          raise
            (Type_error
               ( i,
                 Printf.sprintf "'%s' is already declared: a class or a datatype of one name is declared once"
                   c.c_name ));
        if SMap.mem c.c_name store.constructors then
          raise (Type_error (i, Printf.sprintf "'%s' is already a constructor of '%s'" c.c_name
                                  (base_name (SMap.find c.c_name store.constructors))));
        { store with types = SMap.add c.c_name c.c_name store.types })
      store own
  in
  (* Placeholders, so a type naming any class resolves with its arity. *)
  let store =
    List.fold_left
      (fun store (i, c) ->
        {
          store with
          classes =
            SMap.add c.c_name
              {
                cl_name = c.c_name;
                cl_kind = c.c_kind;
                cl_params = c.c_params;
                cl_parent = None;
                cl_interfaces = [];
                cl_header = [];
                cl_fields = [];
                cl_methods = [];
                cl_info = i;
              }
              store.classes;
        })
      store own
  in
  let resolve c t = resolved ~params:(c.c_name, c.c_params) store t in
  let supertype c want (ClassRef (ri, module_, name, args, _, _)) =
    let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
    match SMap.find_opt spelled store.types with
    | Some canonical when SMap.mem canonical store.classes ->
        let target = SMap.find canonical store.classes in
        let interface = target.cl_kind = ClassInterface in
        if want = `Interface && not interface then
          raise
            (Type_error
               ( ri,
                 Printf.sprintf
                   "'%s' is a class, which a class 'extends'; 'implements' names interfaces"
                   spelled ));
        if want = `Class && interface then
          raise
            (Type_error
               ( ri,
                 Printf.sprintf
                   "'%s' is an interface, which a %s 'implements'; 'extends' names the one parent class"
                   spelled (match c.c_kind with ClassInterface -> "interface" | _ -> "class") ));
        let args = List.map (resolve c) args in
        if want <> `Class && List.length args <> List.length target.cl_params then
          raise
            (Type_error
               ( ri,
                 Printf.sprintf "'%s' takes %d type parameter%s, but is given %d" spelled
                   (List.length target.cl_params)
                   (if List.length target.cl_params = 1 then "" else "s")
                   (List.length args) ));
        (canonical, args)
    | _ ->
        raise
          (Type_error
             ( ri,
               Printf.sprintf "unknown %s '%s': none of that name is declared or imported here"
                 (if want = `Class then "class" else "interface") spelled ))
  in
  (* The header, the methods and the supertypes named, each class on its
     own; a parent's arguments are what its constructor's arguments say. *)
  let store =
    List.fold_left
      (fun store (_, c) ->
        let header = List.map (fun (MemberField (_, n, t, _, _, _, _)) -> (n, resolve c (Option.get t))) c.c_header in
        let interfaces =
          (* an interface's `extends` names interfaces, as a class's
             `implements` does *)
          List.map (supertype c `Interface) c.c_implements
        in
        let parent =
          match c.c_extends with
          | None -> None
          | Some (ClassRef (ri, _, _, _, ctor, _) as r) ->
              let canonical, _ = supertype c `Class r in
              let target = SMap.find canonical store.classes in
              (* The parent's type arguments: what each argument given to
                 its constructor says it is -- a header parameter, a
                 literal -- matched against what that constructor takes. *)
              let target_header =
                match List.find_opt (fun (_, d) -> d.c_name = canonical) own with
                | Some (_, d) ->
                    List.map
                      (fun (MemberField (_, n, t, _, _, _, _)) ->
                        (n, resolved ~params:(d.c_name, d.c_params) store (Option.get t)))
                      d.c_header
                | None -> target.cl_header
              in
              let metas, inner = fresh_metas (List.length target.cl_params) ri store in
              let mapping = class_mapping target metas in
              let known arg =
                match arg with
                | EVar (_, n, _) -> List.assoc_opt n header
                | EInt (ai, _, _) -> Some (t_int ai)
                | EFloat (ai, _, _) -> Some (t_float ai)
                | EString (ai, _, _) -> Some (t_string ai)
                | EBool (ai, _, _) -> Some (t_bool ai)
                | EChar (ai, _, _) -> Some (t_char ai)
                | _ -> None
              in
              let inner =
                if List.length ctor <> List.length target_header then inner
                else
                  List.fold_left2
                    (fun inner (_, arg) (_, wanted) ->
                      match known arg with
                      | Some t -> ( match unify (substitute wanted mapping) t inner with Some s -> s | None -> inner)
                      | None -> inner)
                    inner ctor target_header
              in
              let args = List.map (fun m -> zonk m inner) metas in
              if List.exists (fun a -> metas_in a inner <> []) args then
                raise
                  (Type_error
                     ( ri,
                       Printf.sprintf
                         "nothing here says what the type parameters of '%s' are: pass it a header \
                          parameter or a literal for each field that names one"
                         canonical ));
              Some (canonical, args)
        in
        let methods =
          List.map
            (fun (MethodDecl (mi, name, params, ret, body, override, private_, _)) ->
              {
                md_name = name;
                md_params = List.map (fun (Param (_, n, t, d, _)) -> (n, resolve c (Option.get t), d)) params;
                md_return = (match ret with Some t -> resolve c t | None -> unit_type mi);
                md_abstract = body = None;
                md_private = private_;
                md_override = override;
                md_info = mi;
              })
            c.c_methods
        in
        let placeholder = SMap.find c.c_name store.classes in
        {
          store with
          classes =
            SMap.add c.c_name
              { placeholder with cl_parent = parent; cl_interfaces = interfaces; cl_header = header; cl_methods = methods }
              store.classes;
        })
      store own
  in
  (* No class above itself. *)
  List.iter
    (fun (i, c) ->
      let rec climb seen name =
        List.iter
          (fun (n, _) ->
            if n = c.c_name then
              raise
                (Type_error
                   (i, Printf.sprintf "'%s' is above itself: a class or interface cannot extend what extends it" c.c_name));
            if not (List.mem n seen) then climb (n :: seen) n)
          (direct_supers store (name, List.map (t_var i) (match class_named store name with Some k -> k.cl_params | None -> [])))
      in
      climb [] c.c_name)
    own;
  (* Each class's fields, now that every parent's are known: the header's
     -- less a parameter that only passes an inherited field on -- then
     the body's. Parents first. *)
  let rec fields_of done_ (i, c) =
    if List.mem c.c_name done_ then (done_, ())
    else
      let info = SMap.find c.c_name store.classes in
      let done_ =
        match info.cl_parent with
        | Some (p, _) -> (
            match List.find_opt (fun (_, d) -> d.c_name = p) own with
            | Some parent -> fst (fields_of done_ parent)
            | None -> done_)
        | None -> done_
      in
      ignore i;
      (c.c_name :: done_, ())
  in
  let order = List.fold_left (fun done_ ic -> fst (fields_of done_ ic)) [] own |> List.rev in
  let store =
    List.fold_left
      (fun store name ->
        let i, c = List.find (fun (_, d) -> d.c_name = name) own in
        let info = SMap.find name store.classes in
        let self = (name, List.map (t_var i) info.cl_params) in
        let inherited n =
          match info.cl_parent with
          | Some p -> lookup_field store p n
          | None -> None
        in
        let field passed (MemberField (fi, n, t, _, var, private_, _)) =
          let t = resolve c (Option.get t) in
          match inherited n with
          | Some (owner, f) when passed && printed f.fd_type = printed t && not var && not private_ -> ignore owner; None
          | Some (owner, _) ->
              raise
                (Type_error
                   ( fi,
                     Printf.sprintf
                       "'%s' is already a field of '%s', which '%s' extends; a field is declared once, \
                        and a header parameter that only passes it on has its type"
                       n owner name ))
          | None -> Some { fd_name = n; fd_type = t; fd_var = var; fd_private = private_; fd_info = fi }
        in
        let fields = List.filter_map (field true) c.c_header @ List.filter_map (field false) c.c_fields in
        ignore self;
        { store with classes = SMap.add name { info with cl_fields = fields } store.classes })
      store order
  in
  (* The rules of each declaration. *)
  List.iter
    (fun (i, c) ->
      let info = SMap.find c.c_name store.classes in
      let self = (c.c_name, List.map (t_var i) info.cl_params) in
      let above = List.tl (all_supers store self) in
      let above_method name = lookup_method_in store above name in
      (* A field and a method never share a name, in a class or above it. *)
      List.iter
        (fun m ->
          match lookup_field store self m.md_name with
          | Some (owner, _) ->
              raise
                (Type_error
                   ( m.md_info,
                     Printf.sprintf "'%s' is a field of '%s'; a field and a method never share a name"
                       m.md_name owner ))
          | None -> ())
        info.cl_methods;
      List.iter
        (fun f ->
          match above_method f.fd_name with
          | Some (owner, _) ->
              raise
                (Type_error
                   ( f.fd_info,
                     Printf.sprintf "'%s' is a method of '%s'; a field and a method never share a name"
                       f.fd_name owner ))
          | None -> ())
        info.cl_fields;
      (* `override` exactly where something above has the method, with
         the same signature; defaults are written once, above. *)
      List.iter
        (fun m ->
          match above_method m.md_name with
          | Some (owner, theirs) ->
              if theirs.md_private then
                raise
                  (Type_error
                     ( m.md_info,
                       Printf.sprintf "'%s' is private to '%s', so nothing below it may have a method of that name"
                         m.md_name owner ));
              if not m.md_override then
                raise
                  (Type_error
                     ( m.md_info,
                       Printf.sprintf "'%s' is defined by '%s', which '%s' %s: write 'override def %s'"
                         m.md_name owner c.c_name
                         (match class_named store owner with
                         | Some { cl_kind = ClassInterface; _ } when c.c_kind <> ClassInterface -> "implements"
                         | _ -> "extends")
                         m.md_name ));
              if m.md_private then
                raise (Type_error (m.md_info, Printf.sprintf "an override of '%s' is public, as what it overrides is" m.md_name));
              if not (same_signature m theirs) then
                raise
                  (Type_error
                     ( m.md_info,
                       Printf.sprintf "'%s' overrides '%s' of '%s', so it is written '%s'"
                         m.md_name (signature_text theirs) owner (signature_text { theirs with md_name = m.md_name }) ));
              List.iter
                (fun (n, _, d) ->
                  if d <> None then
                    raise
                      (Type_error
                         ( m.md_info,
                           Printf.sprintf
                             "the default for '%s' is written where '%s' is first declared, in '%s', not in an override"
                             n m.md_name owner )))
                m.md_params
          | None ->
              if m.md_override then
                let known = List.map fst (List.concat_map (fun (n, _) ->
                  match class_named store n with Some k -> List.map (fun md -> (md.md_name, ())) k.cl_methods | None -> []) above) in
                raise
                  (Type_error
                     ( m.md_info,
                       Printf.sprintf "'%s' has no method '%s' to override%s" c.c_name m.md_name
                         (match Suggest.closest m.md_name known with
                         | meant :: _ -> Printf.sprintf "; did you mean '%s'?" meant
                         | [] -> "") )))
        info.cl_methods;
      (* `eq` and `show` mean what `==` and printing take them to. *)
      List.iter
        (fun m ->
          match m.md_name with
          | "eq" -> (
              match (m.md_params, m.md_return) with
              | [ (_, TCon (_, n, _, _), _) ], TBool _ when n = c.c_name || List.mem_assoc n above -> ()
              | _ ->
                  raise
                    (Type_error
                       (m.md_info, Printf.sprintf "'eq' is what '==' calls, so it is written 'def eq(self, other: %s) -> Bool'" c.c_name)))
          | "show" -> (
              match (m.md_params, m.md_return) with
              | [], TString _ -> ()
              | _ -> raise (Type_error (m.md_info, "'show' is what printing calls, so it is written 'def show(self) -> String'")))
          | _ -> ())
        info.cl_methods;
      (* A class that can be made gives every method a body; two defaults
         of one name from two interfaces are settled by an override. *)
      if c.c_kind = ClassPlain then
        List.iter
          (fun (_, (owner, m)) ->
            if m.md_abstract then
              raise
                (Type_error
                   ( i,
                     Printf.sprintf "class '%s' %s '%s' but does not define '%s'" c.c_name
                       (match class_named store owner with
                       | Some { cl_kind = ClassInterface; _ } -> "implements"
                       | _ -> "extends")
                       owner (signature_text m) )))
          (all_methods store self);
      if c.c_kind <> ClassInterface then
        List.iter
          (fun (name, _) ->
            let chain = class_chain store self in
            let in_chain = lookup_method_in store chain name in
            let defaults =
              List.filter_map
                (fun (n, args) ->
                  match class_named store n with
                  | Some ({ cl_kind = ClassInterface; _ } as k) -> (
                      match List.find_opt (fun md -> md.md_name = name && not md.md_abstract) k.cl_methods with
                      | Some _ -> ignore args; Some n
                      | None -> None)
                  | _ -> None)
                (all_supers store self)
            in
            match in_chain with
            | Some (_, m) when not m.md_abstract -> ()
            | _ -> (
                match defaults with
                | a :: b :: _ ->
                    raise
                      (Type_error
                         ( i,
                           Printf.sprintf
                             "'%s' has a default for '%s' from both '%s' and '%s': write 'override def %s' to say which runs"
                             c.c_name name a b name ))
                | _ -> ()))
          (all_methods store self))
    own;
  store

(** What a constructor builds, from how the source spells it: the
    canonical datatype, the constructor's field types and the type of
    the value it makes, with a fresh metavariable for each of the
    datatype's parameters. info -> String -> String -> store ->
    (string, [(String?, typ)], typ, store) *)
let constructor_use info spelled name store =
  match SMap.find_opt spelled store.constructors with
  | None ->
      (* `True` for `true` is the likely one: the Bools are keywords. *)
      let known = SMap.fold (fun c _ out -> c :: out) store.constructors [] in
      let meant =
        match Suggest.closest spelled (known @ [ "true"; "false" ]) with
        | ("true" | "false") as k :: _ ->
            Printf.sprintf ". Did you mean the keyword '%s'?" k
        | c :: _ -> Printf.sprintf ". Did you mean '%s'?" c
        | [] -> ""
      in
      raise
        (Analyses.Analysis_error
           ( info,
             Printf.sprintf
               "unknown constructor '%s': a name starting with an uppercase \
                letter is a constructor, and no datatype declared or imported \
                here has one of that name%s"
               spelled meant ))
  | Some canonical ->
      let (Datatype (_, params, constructors, _)) =
        SMap.find canonical store.datatypes
      in
      let fields = List.assoc name constructors in
      let metas, store = fresh_metas (List.length params) info store in
      let mapping = List.combine params metas in
      ( canonical,
        List.map (fun (label, t) -> (label, substitute t mapping)) fields,
        TCon (info, canonical, metas, 0),
        store )

(** How a field of a constructor is named in a message: by its name
    where it has one, by its position otherwise.
    String -> int -> String? -> String *)
let field_named constructor position label =
  match label with
  | Some n -> Printf.sprintf "the field '%s' of '%s'" n constructor
  | None -> Printf.sprintf "field %d of '%s'" (position + 1) constructor

(** The environment a program starts in: every name in
    Builtin.names, at its TBuiltin type. Its own function so
    src/repl.ml can reuse it when checking a session one entry at a
    time. () -> env *)
let builtin_env () =
  let env =
    List.fold_left
      (fun env name -> bind env name (t_builtin builtin_info name))
      SMap.empty Builtin.names
  in
  (* `array`, `array_init` and `dynarray` are overload sets of builtin
     definitions, resolved by their arguments as any `::` set is
     (PYKING.md, "Arrays", "DynArrays"); each set's members take different
     numbers of arguments, so a call is never ambiguous. *)
  let i = builtin_info in
  let a = t_var i "a" and s = t_var i "s" in
  List.fold_left
    (fun env (name, vars, params, result) ->
      bind env name (t_forall i vars (t_function i params result)))
    env
    [
      ("list::array", [ "a" ], [ t_list i a ], t_array i a);
      ("fill::array", [ "a" ], [ t_int i; a ], t_array i a);
      ("init::array_init", [ "a" ], [ t_int i; t_function i [ t_int i ] a ], t_array i a);
      ("unfold::array_init", [ "a"; "s" ], [ t_int i; s; t_function i [ s ] (t_tuple i [ a; s ]) ], t_array i a);
      ("empty::dynarray", [ "a" ], [], t_dynarray i a);
      ("list::dynarray", [ "a" ], [ t_list i a ], t_dynarray i a);
      ("empty::mutmap", [ "k"; "v" ], [], t_mutmap i (t_var i "k") (t_var i "v"));
      ("list::mutmap", [ "k"; "v" ], [ t_list i (t_tuple i [ t_var i "k"; t_var i "v" ]) ], t_mutmap i (t_var i "k") (t_var i "v"));
    ]

(** What a module exports, or a refusal saying it cannot be reached from
    here at all -- which is what a file checked on its own gets, since no
    module system ran to find it. string -> info -> store -> sigmap *)
let available module_ info store =
  match List.assoc_opt module_ store.modules with
  | Some sigmap -> sigmap
  | None ->
      raise
        (Analyses.Analysis_error
           ( info,
             Printf.sprintf
               "module '%s' cannot be imported here: an import needs the \
                whole program, and this is one file on its own"
               module_ ))

(** env extended with everything a module's imports bring into scope: a
    selected name under the name it is known by here, and a field of a
    plain import under `alias.field`, which is the spelling `EQualified`
    looks up. An import is a declaration of the module rather than a
    statement in its sequence -- like a `def`, all of them are in scope
    throughout it, which is what lets a definition written above an
    import still name what it brings in.
    [stmt] -> env -> store -> env *)
let import_env stmts env store =
  List.fold_left
    (fun env statement ->
      match statement with
      | SImport (info, module_, name, selected, fields, _) ->
          let sigmap = available module_ info store in
          List.fold_left
            (fun env (exported, local) ->
              let _, type_, implicit =
                List.find (fun (n, _, _) -> n = exported) sigmap
              in
              let bound =
                if selected then local else Printf.sprintf "%s.%s" name exported
              in
              match type_ with
              (* A datatype and its constructors are not values; the
                 store's own tables hold them (`declare_datatypes`). *)
              | TData _ -> env
              | _ ->
              (* A public implicit is found by an unqualified call as
                 well, and automatically -- an ordering a module defines
                 is usable in the file that imports it without being
                 named (PYKING.md, "Modules"). It is bound under the one
                 spelling either way, so a resolution always names the
                 module it came from. *)
              bind ~implicit env bound type_)
            env fields
      | _ -> env)
    env stmts

(** Why `module.name` names nothing: either no module is in scope under
    that name, or the one that is does not export it.
    string -> string -> env -> string *)
let unreachable_name module_ name env =
  let prefix = module_ ^ "." in
  let known =
    SMap.exists
      (fun bound _ ->
        String.length bound >= String.length prefix
        && String.sub bound 0 (String.length prefix) = prefix)
      env
  in
  if not known then
    Printf.sprintf
      "unbound name '%s.%s': no module is imported under the name '%s'" module_
      name module_
  else Printf.sprintf "module '%s' does not export '%s'" module_ name

(* --- what a definition says about itself --- *)

(** The type a `def name : type` line gave this definition, already
    quantified, or None where the source wrote none.
    stmt -> store -> typ option *)
let signature_of node store = IntMap.find_opt (stmt_sym node) store.signatures

(** Whether a function definition has its complete type annotated, either
    by a signature line of its own or by an annotation on every parameter
    and the return type. stmt -> store -> bool *)
let fully_annotated node store =
  match signature_of node store with
  | Some _ -> true
  | None -> (
      match node with
      | SFunctionDef (_, _, params, _, return_type, _, _, _, _) ->
          return_type <> None
          && List.for_all (fun (Param (_, _, t, _, _)) -> t <> None) params
      | _ -> false)

(** Refuses a definition that carries implicit parameters, or is itself
    implicit, without writing its whole type down. Resolving an implicit
    argument is a question about types, so there has to be a type to ask
    it of (PYKING.md, "Implicits"). stmt -> store -> () *)
let check_implicit_annotated node store =
  match node with
  | SFunctionDef (info, name, _, _, _, _, _, implicits, implicit)
    when (implicits <> [] || implicit) && not (fully_annotated node store) ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "'%s' is %s, so it needs its whole type written down: \
                annotate every parameter and the return type, or give it a \
                'def %s : ...' signature line"
               name
               (if implicit then "implicit" else "a function with an implicit parameter")
               name ))
  | _ -> ()

(** Refuses a module that exports a name whose type the source does not
    write down.

    A module says what it exports here, in the file that exports it,
    rather than leaving the module that imports it to find out. A `def`
    says its whole type on its own header or on a signature line of its
    own, and an `=` binding says it on its name; what the checker would
    have worked out on its own is not enough, because what crosses the
    boundary is what the source promised.
    [stmt] -> store -> () *)
let check_exports stmts store =
  let incomplete name how =
    Printf.sprintf
      "'%s' is public, and a public function or value needs a complete \
       annotated type signature: %s"
      name how
  in
  List.iter
    (fun statement ->
      match statement with
      | SFunctionDef (info, name, _, _, _, _, true, _, _)
        when not (fully_annotated statement store) ->
          raise
            (Type_error
               ( info,
                 incomplete name
                   (Printf.sprintf
                      "annotate every parameter and the return type, or give \
                       it a 'def %s : ...' signature line."
                      name) ))
      | SLet (info, TargetName (_, name, _), _, None, _, true, _)
      | SLetStmt (info, TargetName (_, name, _), _, None, _, true) ->
          raise
            (Type_error
               ( info,
                 incomplete name
                   (Printf.sprintf "write its type on its name, '%s: Int = \
                                    ...'."
                      name) ))
      | _ -> ())
    stmts

(** Refuses a public definition, binding or datatype whose type names
    one of this module's datatypes that is not public: another module
    could hold such a value but never name its type.
    [stmt] -> store -> () *)
let check_exported_datatypes stmts store =
  let public_types =
    List.filter_map
      (function SDatatype (_, name, _, _, _, true, _) -> Some name | _ -> None)
      stmts
  in
  let own =
    List.filter_map
      (function SDatatype (_, name, _, _, _, _, _) -> Some name | _ -> None)
      stmts
  in
  let rec hidden t =
    match t with
    | TCon (_, n, args, _) ->
        if List.mem n own && not (List.mem n public_types) then Some n
        else List.find_map hidden args
    | TList (_, e, _) -> hidden e
    | TTuple (_, es, _) -> List.find_map hidden es
    | TFunction (_, ps, r, _, _, _, ips) ->
        List.find_map hidden (ps @ implicit_types ips @ [ r ])
    | TForall (_, _, b, _) -> hidden b
    | TData (_, Datatype (_, _, constructors, _), _) ->
        List.find_map
          (fun (_, fields) -> List.find_map (fun (_, t) -> hidden t) fields)
          constructors
    | _ -> None
  in
  List.iter
    (fun statement ->
      let exported =
        match statement with
        | SFunctionDef (info, name, _, _, _, sym, true, _, _)
        | SLet (info, TargetName (_, name, _), _, _, sym, true, _)
        | SLetStmt (info, TargetName (_, name, _), _, _, sym, true)
        | SDatatype (info, name, _, _, sym, true, _) ->
            Option.map (fun t -> (info, name, t)) (IntMap.find_opt sym store.tmap)
        | _ -> None
      in
      match exported with
      | Some (info, name, t) -> (
          match hidden (zonk t store) with
          | Some datatype ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' is public, and its type names the datatype '%s', \
                        which is not: make '%s' public too, so that a module \
                        holding the value can name its type"
                       name datatype datatype ))
          | None -> ())
      | None -> ())
    stmts

(** node's type, from the signature line that named it or from the
    annotations on its own header, quantified over the type variables it
    leaves free. Raises Type_error if neither says the whole type.
    stmt -> store -> typ *)
let function_type node store =
  match signature_of node store with
  | Some written -> written
  | None -> (
      match node with
      | SFunctionDef (info, name, params, _, return_type, _, _, implicits, _) ->
          let unannotated =
            List.filter_map
              (function Param (_, n, None, _, _) -> Some n | _ -> None)
              params
          in
          if unannotated <> [] || return_type = None then
            let missing =
              String.concat ", "
                (List.map (Printf.sprintf "parameter '%s'") unannotated
                @ if return_type = None then [ "the return type" ] else [])
            in
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "'%s' can only be checked when every parameter and the \
                      return type is annotated; %s is not"
                     name missing ))
          else
            generalize
              (t_function
                 ~implicits:
                   (List.map
                      (fun (Param (_, n, t, _, _)) ->
                        IParam (n, resolved store (Option.get t)))
                      implicits)
                 info
                 (List.map
                    (fun (Param (_, _, t, _, _)) -> resolved store (Option.get t))
                    params)
                 (resolved store (Option.get return_type)))
      | _ -> unsupported (stmt_info node))

(** The type a def has: its annotated types, or TUnknown for the missing
    parts, in which case it carries its own definition so that a call can
    work it out. stmt -> store -> typ *)
let declared_type node store =
  if fully_annotated node store then function_type node store
  else
    match node with
    | SFunctionDef (info, _, params, _, return_type, sym, _, implicits, _) ->
        TFunction
          ( info,
            List.map
              (fun (Param (pinfo, _, t, _, _)) ->
                match t with Some t -> resolved store t | None -> t_unknown pinfo)
              params,
            (match return_type with
            | Some t -> resolved store t
            | None -> t_unknown info),
            0,
            sym,
            Some node,
            List.map
              (fun (Param (pinfo, pname, t, _, _)) ->
                IParam
                  ( pname,
                    match t with
                    | Some t -> resolved store t
                    | None -> t_unknown pinfo ))
              implicits )
    | _ -> unsupported (stmt_info node)

(** Pairs each `def name : type` line of a block with the definition of
    that name in the same block, and records the type it gives it.
    Refuses a signature that names no definition here, a second one for
    one definition, and one whose definition also annotates itself -- a
    `def` says its type in one place or the other, never both.
    [stmt] -> [(string, stmt)] -> store -> store *)
let declare_signatures stmts defined store =
  let _, store =
    List.fold_left
      (fun (seen, store) statement ->
        match statement with
        | SFunctionSig (info, name, written, _, _) -> (
            match List.assoc_opt name defined with
            | None ->
                raise
                  (Type_error
                     ( info,
                       Printf.sprintf
                         "there is no 'def %s' in this block for this \
                          signature to describe"
                         name ))
            | Some node ->
                if List.mem name seen then
                  raise
                    (Type_error
                       ( info,
                         Printf.sprintf
                           "'%s' already has a signature in this block" name ));
                let node_params, node_return =
                  match node with
                  | SFunctionDef (_, _, params, _, return_type, _, _, _, _) ->
                      (params, return_type)
                  | _ -> ([], None)
                in
                let annotated =
                  List.filter_map
                    (function Param (_, n, Some _, _, _) -> Some n | _ -> None)
                    node_params
                in
                if annotated <> [] || node_return <> None then
                  raise
                    (Type_error
                       ( stmt_info node,
                         Printf.sprintf
                           "'%s' has a signature of its own, so its \
                            definition writes no annotations; remove the ones \
                            on %s"
                           name
                           (if annotated <> [] then String.concat ", " annotated
                            else "its return type") ));
                let type_ = generalize (resolved store written) in
                let _, written_type = instantiated type_ in
                (match written_type with
                | TFunction (_, _, _, _, _, _, (IParam (implicit, _) :: _)) ->
                    (* An implicit parameter is written on the `def`
                       header, where the body can name it. A signature
                       line says a type and binds nothing, so one here
                       would name a parameter that does not exist
                       (docs/implicits.md). *)
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "'%s' cannot take the implicit parameter '%s' \
                              on a signature line: an implicit parameter is \
                              written on the 'def' itself, where its body \
                              can name it"
                             name implicit ))
                | TFunction (_, written_params, _, _, _, _, _) ->
                    if List.length written_params <> List.length node_params
                    then
                      raise
                        (Type_error
                           ( info,
                             Printf.sprintf
                               "this signature gives '%s' %d parameter%s, but \
                                its definition takes %d"
                               name (List.length written_params)
                               (if List.length written_params = 1 then ""
                                else "s")
                               (List.length node_params) ))
                | _ ->
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "the signature of '%s' is %s, which is not a \
                              function type"
                             name (printed type_) )));
                (seen @ [ name ], with_signature store (stmt_sym node) type_))
        | _ -> (seen, store))
      ([], store) stmts
  in
  store

(** env with every def of a block bound, and the store recording where
    each deferred one was written. Not recursive: a def inside a branch
    is declared when that branch's block is checked.
    [stmt] -> env -> store -> (env, store) *)
let declare_functions stmts env store =
  let defined = Analyses.block_functions stmts in
  let store = declare_signatures stmts defined store in
  let functions = List.map snd defined in
  let env =
    List.fold_left
      (fun env function_ ->
        match function_ with
        | SFunctionDef (_, name, _, _, _, _, _, _, implicit) ->
            bind ~implicit env name (declared_type function_ store)
        | _ -> env)
      env functions
  in
  let deferred =
    List.filter (fun f -> not (fully_annotated f store)) functions
  in
  let store =
    List.fold_left
      (fun store function_ ->
        let sym = stmt_sym function_ in
        (* Record this environment, so a body reached from a call is
           checked where it was written. And which definitions it is
           worked out *with*: the ones it may name, which is every `def`
           of its own block. See `infer_call`. *)
        let store = with_environment store sym env in
        { store with groups = IntMap.add sym deferred store.groups })
      store deferred
  in
  (env, store)

(* --- the arity and the argument types of a builtin call --- *)

(** Raises Type_error if a call does not pass as many arguments as the
    builtin takes. The bounds are Builtin's, so a variadic one has no
    upper bound and never refuses. string -> info -> int -> () *)
let check_builtin_arity name info given =
  match Builtin.lookup name with
  | None -> ()
  | Some builtin ->
      let low = builtin.Builtin.min_args and high = builtin.Builtin.max_args in
      if low <= given && match high with None -> true | Some h -> given <= h
      then ()
      else
        let expected =
          match high with
          | None -> Printf.sprintf "at least %d" low
          | Some h when h = low -> string_of_int low
          | Some h -> Printf.sprintf "%d to %d" low h
        in
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' takes %s argument%s, but %d %s given" name
                 expected
                 (if high = Some 1 then "" else "s")
                 given
                 (if given = 1 then "was" else "were") ))

(** The Type_error for a builtin argument of the wrong type.
    string -> expr -> typ -> string -> exn *)
let builtin_argument_error name argument actual accepted =
  Type_error
    ( expr_info argument,
      Printf.sprintf "'%s' cannot be applied to %s; it accepts %s" name
        (printed actual) accepted )

(** Every kind variable in type_, through the metavariables' solutions,
    and every one each links on to. typ -> store -> [string] *)
let kind_names_in type_ store =
  let rec chain found name =
    let found = if List.mem name found then found else name :: found in
    match SMap.find_opt name store.solutions with
    | Some (TCon (_, next, [], _)) when is_kind_name next && not (List.mem next found) -> chain found next
    | _ -> found
  in
  let rec walk found t =
    match t with
    | TVar (_, name, _, false) -> (
        match SMap.find_opt name store.solutions with Some answer -> walk found answer | None -> found)
    | TCon (_, name, args, _) when is_kind_name name -> List.fold_left walk (chain found name) args
    | TList (_, element, _) -> walk found element
    | TTuple (_, elements, _) | TCon (_, _, elements, _) -> List.fold_left walk found elements
    | TFunction (_, params, result, _, _, _, implicits) ->
        walk (List.fold_left walk found (params @ implicit_types implicits)) result
    | _ -> found
  in
  List.rev (walk [] type_)

(** Whether the kind variable `name` has been decided, rather than left
    open or linked on to one that is open. string -> store -> bool *)
let kind_decided name store =
  let rec last name =
    match SMap.find_opt name store.solutions with
    | Some (TCon (_, next, [], _)) when is_kind_name next -> last next
    | Some _ -> true
    | None -> false
  in
  last name

(** store with the call at `info` remembered as the one that decided
    the kind of `subject` -- "vec_add1's parameter v1" -- where one of
    `kinds`, the parameter's kind variables, is decided now. Keyed by
    the function's name and the argument's position, since the scheme
    reads a decided kind back as its type from then on, and a later call
    may no longer carry the definition that names its parameters.
    [string] -> info -> string -> string -> store -> store *)
let remember_kinds kinds info key subject store =
  if SMap.mem key store.kind_origins || not (List.exists (fun k -> kind_decided k store) kinds) then store
  else { store with kind_origins = SMap.add key (info, subject) store.kind_origins }

(** What a refused argument's message adds where its parameter's kind
    was decided by an earlier call and this argument is of another kind:
    who decided it, to what, and where -- `key` as `remember_kinds`
    keys it; or, where nothing has, which kinds the body allows.
    string -> string -> typ -> typ -> store -> string *)
let kind_note key subject actual expected store =
  match (SMap.find_opt key store.kind_origins, container_of (prune expected store)) with
  | Some (info, subject), Some kind when container_of (prune actual store) <> Some kind ->
      Printf.sprintf ": %s was fixed to %s by its first call, at line %d" subject (container_words kind) info.row1
  | _ -> (
      (* Still open, but the body allows fewer kinds than this one --
         it writes by index, or slices. *)
      match (kind_var_parts (prune expected store), container_of (prune actual store)) with
      | Some (name, _), Some kind when not (List.mem kind (kind_allowed name)) ->
          Printf.sprintf ": the body uses %s as %s, not as %s" subject (containers_words (kind_allowed name))
            (container_words kind)
      | _ -> "")

(** The Type_error for an argument that does not match the declared
    parameter type. The two are named together, so a variable standing in
    both reads as the same letter in both.
    int -> typ -> typ -> expr -> store -> exn *)
let argument_error ?(note = "") position actual expected arg store =
  let info = expr_info arg in
  let together =
    displayed (t_tuple info [ zonk actual store; zonk expected store ]) store
  in
  let mine, theirs =
    match together with
    | TTuple (_, [ mine; theirs ], _) -> (mine, theirs)
    | _ -> (actual, expected)
  in
  (* A list of objects where a list of their supertype is wanted. *)
  let note =
    match (prune actual store, prune expected store) with
    | TList (_, a, _), TList (_, w, _) when note = "" && is_object_type store a && is_object_type store w ->
        Printf.sprintf ": a [%s] is not a [%s], since lists do not take subtypes; annotate the list where it is made"
          (shown a store) (shown w store)
    | _ -> note
  in
  Type_error
    ( info,
      Printf.sprintf "argument %d has type %s, but %s was expected%s" position
        (printed_nested mine) (printed_nested theirs) note )

(** The single type every way out of a body gives, and the store that
    makes them one. Each is unified with the ones before it, so a base
    case returning `[]` settles against a branch returning `[Int]`; two
    that cannot be one type are refused at the later one. At least one is
    required. [given] -> string -> store -> (typ, store) *)
let one_type given name store =
  match given with
  | [] -> invalid_arg "one_type: nothing given"
  | first :: rest ->
      List.fold_left
        (fun (worth, store) later ->
          match agree (Some worth) (Some later.given_type) store with
          | Some both, store -> (both, store)
          | None, store ->
              raise
                (Type_error
                   ( later.given_info,
                     Printf.sprintf
                       "'%s' gives %s on one path, but %s on this one; a \
                        function has one return type"
                       name (shown worth store)
                       (shown later.given_type store) )))
        (first.given_type, store) rest

(** Every metavariable still open in the types an environment binds.
    These are the ones a definition written there may *not* generalise:
    they belong to something enclosing it, which has already been given
    them by its own caller. env -> store -> StringSet.t *)
let free_metas env store =
  (* A field whose type its default has not decided yet belongs to the
     whole module, as a name the environment binds does. *)
  let fields =
    SMap.fold
      (fun _ (type_, _) found ->
        List.fold_left
          (fun found meta -> StringSet.add meta found)
          found (metas_in type_ store))
      store.field_defaults StringSet.empty
  in
  SMap.fold
    (fun _ binding found ->
      List.fold_left
        (fun found meta -> StringSet.add meta found)
        found (metas_in binding.btype store))
    env fields

(** The store with every `+` whose operands were left open decided
    (`operator_result`): one now an Int, a Float, a String or a list
    stays what it is; one still open becomes an Int, the table's first
    row; and one that became anything else is refused here, where the
    `+` is. Run when the module is done; until then a definition does not
    generalise over such a type (`infer_definition`), since a type
    variable would have to add and join at once. store -> store *)
let settle_plus store =
  List.fold_left
    (fun store (operand, info) ->
      match zonk operand store with
      | TVar (_, _, _, false) as open_ -> (
          match unify (t_int info) open_ store with
          | Some store -> store
          | None -> store)
      | TInt _ | TFloat _ | TString _ | TList _ -> store
      | other ->
          let shown_ = printed (displayed other store) in
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "`+` cannot be applied to %s and %s; it accepts Int + Int or \
                    Float + Float or String + String or two lists of one type"
                   shown_ shown_ )))
    { store with pending_plus = [] }
    (List.rev store.pending_plus)

(** The store with every kind variable nothing decided decided: a list
    where it may be one, as an index with nothing else to go on always
    meant, and otherwise the first kind it allows -- an array, for a
    store only ever written. Run when the module is done. store -> store *)
let settle_kinds store =
  List.fold_left
    (fun store name ->
      let rec last name =
        match SMap.find_opt name store.solutions with
        | Some (TCon (_, next, [], _)) when is_kind_name next -> last next
        | Some _ -> None
        | None -> Some name
      in
      match last name with
      | None -> store
      | Some open_ -> (
          match kind_allowed open_ with
          | [] -> store
          | first :: _ as allowed ->
              let kind = if List.mem CList allowed then CList else first in
              let info = builtin_info in
              solving store open_ (container_type kind info (t_unknown info))))
    store (List.rev store.open_kinds)

(** The scheme a definition has: its worked-out type, with every
    metavariable the body left unsolved bound by one `all` at the top.

    Unsolved means the body never had to decide it, which is exactly what
    a type variable stands for -- so this is Hindley-Milner's
    generalisation step, and what it produces is the principal type.

    Except for `outer`, the metavariables the scope it was written in
    already holds. A `def` inside another `def` may not generalise the
    enclosing function's parameter: whoever called *that* chose it, and a
    scheme promising otherwise would be a promise the body cannot keep.
    This is Hindley-Milner's "not free in the environment" side
    condition, and it is the one place generalisation is unsound without
    a rule rather than merely imprecise.

    Only at the top: a metavariable is a type, never a scheme, so no
    `all` can appear inside one of these.
    stmt -> typ -> StringSet.t -> store -> typ *)
let generalise ?(avoid = StringSet.empty) node mono outer store =
  let settled = zonk mono store in
  let open_metas =
    List.filter
      (fun meta -> not (StringSet.mem meta outer))
      (metas_in settled store)
  in
  if open_metas = [] then settled
  else
    let taken = StringSet.union avoid (names_in settled) in
    let info = stmt_info node in
    let names, chosen =
      List.fold_left
        (fun (names, chosen) meta ->
          let name =
            next_name (List.length names)
              (List.fold_left (fun s n -> StringSet.add n s) taken names)
          in
          (names @ [ name ], chosen @ [ (meta, t_var info name) ]))
        ([], []) open_metas
    in
    t_forall info names (substitute settled chosen)

(** One `(?a, ?b, ...) -> ?r` per definition in the group, all of whose
    variables are fresh. These are what the group's names mean while its
    bodies are checked. [stmt] -> store -> ([typ], store) *)
let monotypes_for group store =
  List.fold_left
    (fun (monotypes, store) node ->
      match node with
      | SFunctionDef (info, _, params, _, return_type, _, _, _, _) ->
          (* A parameter the source annotated means what it says: a
             metavariable stands only where nothing was written. *)
          let params, store =
            List.fold_left
              (fun (types, store) param ->
                match param with
                | Param (_, _, Some written, _, _) ->
                    (types @ [ resolved store written ], store)
                | Param (at, _, None, _, _) ->
                    let metas, store = fresh_metas 1 at store in
                    (types @ metas, store))
              ([], store) params
          in
          let result, store =
            match return_type with
            | Some written -> (resolved store written, store)
            | None ->
                let metas, store = fresh_metas 1 info store in
                (match metas with [ meta ] -> (meta, store) | _ -> (t_unknown info, store))
          in
          (monotypes @ [ t_function info params result ], store)
      | _ -> (monotypes, store))
    ([], store) group

(** store in which the body of node supplies `wanted`. Raises Type_error
    where nothing makes it so -- which, since `wanted` is this
    inference's own metavariable, means the body's own ways out
    disagreed. store -> typ -> typ option -> stmt -> store *)
let required store wanted supplied node =
  match supplied with
  (* Nothing ever comes out of this body: every way through it is a
     `break`, a `continue`, or a loop that never ends. Whatever the
     caller wants of it is fine. *)
  | None -> store
  | Some supplied -> (
      match unify wanted supplied store with
      | Some answer -> answer
      | None ->
          let name =
            match node with
            | SFunctionDef (_, name, _, _, _, _, _, _, _) -> name
            | _ -> "?"
          in
          raise
            (Type_error
               ( stmt_info node,
                 Printf.sprintf
                   "'%s' has to return %s, but its body ends in a value of \
                    type %s"
                   name (shown wanted store) (shown supplied store) )))

(** Every name a body reads. Used to find which definitions of a block
    name each other, so only those are worked out as one.
    [stmt] -> StringSet.t *)
let names_used body =
  Walk.fold_stmts
    (fun names node ->
      match node with
      | Walk.NExpr (EVar (_, name, _)) -> StringSet.add name names
      | _ -> names)
    StringSet.empty body

(** The definitions worked out together with node: the ones in its block
    that it and they mutually depend on -- its strongly connected
    component in the block's call graph.

    Only those. A sibling node merely *calls* is worked out and
    generalised first, on demand, so it is polymorphic by the time this
    body uses it; grouping it in here instead would hold it to one type
    for the whole group, which is the difference between `let`-bound and
    lambda-bound in Hindley-Milner and the reason `id` may serve two
    types inside one caller. stmt -> store -> [stmt] *)
let inference_group node store =
  let sym = stmt_sym node in
  let block =
    match IntMap.find_opt sym store.groups with
    | Some group -> group
    | None -> [ node ]
  in
  let siblings =
    List.filter
      (fun other ->
        instance_of store (stmt_sym other) = None
        && not (IntSet.mem (stmt_sym other) store.checking))
      block
  in
  if not (List.exists (fun other -> stmt_sym other = sym) siblings) then [ node ]
  else
    let name_of other =
      match other with
      | SFunctionDef (_, name, _, _, _, _, _, _, _) -> name
      | _ -> ""
    in
    let body_of other =
      match other with
      | SFunctionDef (_, _, _, body, _, _, _, _, _) -> body
      | _ -> []
    in
    let calls =
      List.map
        (fun other ->
          let used = names_used (body_of other) in
          ( stmt_sym other,
            List.filter_map
              (fun sibling ->
                if StringSet.mem (name_of sibling) used then
                  Some (stmt_sym sibling)
                else None)
              siblings ))
        siblings
    in
    let reaches start =
      let rec go seen waiting =
        match waiting with
        | [] -> seen
        | one :: rest ->
            let next =
              match List.assoc_opt one calls with Some ns -> ns | None -> []
            in
            let fresh_ones =
              List.filter (fun n -> not (IntSet.mem n seen)) next
            in
            go
              (List.fold_left (fun s n -> IntSet.add n s) seen fresh_ones)
              (fresh_ones @ rest)
      in
      go IntSet.empty [ start ]
    in
    let forward = IntSet.add sym (reaches sym) in
    List.filter
      (fun other ->
        let theirs = stmt_sym other in
        IntSet.mem theirs forward
        && IntSet.mem sym (IntSet.add theirs (reaches theirs)))
      siblings

(** What a deferred function turned out to be, once something has worked
    it out. A definition is worked out once, so from the second call on
    it is an ordinary scheme, read back through whatever has since been
    solved.

    The type is pruned first, so a definition reached through a
    metavariable that has since been solved to it -- a function put in a
    list and taken out again -- is seen for what it is rather than for
    the variable it arrived in. typ -> store -> typ *)
let settled_type func_type store =
  let func_type = prune func_type store in
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _), _) -> (
      match instance_of store tmsym with
      | Some instance -> zonk instance store
      | None -> func_type)
  | _ -> func_type

(* --- reading a definition's parts ---
   The Python reaches these as dataclass attributes. A definition is
   always an SFunctionDef where these are used; the other cases are
   unreachable and answer with nothing. *)

let def_name node =
  match node with SFunctionDef (_, name, _, _, _, _, _, _, _) -> name | _ -> ""

(** The implicit parameters of a definition, or none for anything else.
    stmt -> [param] *)
let def_implicits node =
  match node with
  | SFunctionDef (_, _, _, _, _, _, _, implicits, _) -> implicits
  | _ -> []

let def_params node =
  match node with SFunctionDef (_, _, params, _, _, _, _, _, _) -> params | _ -> []

let def_body node =
  match node with SFunctionDef (_, _, _, body, _, _, _, _, _) -> body | _ -> []

let param_name (Param (_, name, _, _, _)) = name
let param_sym (Param (_, _, _, _, sym)) = sym

(** Checks a written annotation, if any, against its right-hand side's
    actual type, and answers the store that makes them one. An annotation
    is a *demand*, so a right-hand side still open is settled by it --
    `xs: [Int] = []` says what the empty list holds. The annotation is
    quantified first, since a written type is quantified wherever one is
    written. Raises Type_error at the annotation on a mismatch.
    typ option -> typ -> store -> store *)
let check_annotation annotation actual store =
  match annotation with
  | None -> store
  | Some annotation -> (
      let annotation = generalize (resolved store annotation) in
      match unify annotation (zonk actual store) store with
      | Some answer -> answer
      | None ->
          if accepts annotation (zonk actual store) then store
          else
            raise
              (Type_error
                 ( type_info annotation,
                   Printf.sprintf
                     "this binding is annotated %s, but its value has type %s"
                     (printed_nested annotation) (shown_nested actual store) )))

(** Checks a return's type against return_type, or -- while one is being
    worked out -- collects it into store's frame.
    typ option -> expected -> info -> store -> store *)
let check_return actual return_type info store =
  match actual with
  (* `return loop: continue` -- the statement never falls through, so no
     value is ever returned here. *)
  | None -> store
  | Some actual -> (
      match return_type with
      | Inferring -> returning store info actual
      | No_function -> store
      | Declared declared -> (
          match unify declared actual store with
          | Some answer -> answer
          | None ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "this function returns %s, but this 'return' gives %s"
                       (shown declared store) (shown actual store) ))))

(** The store in which what a pattern matches has the shape the pattern
    looks at. typ -> typ -> info -> store -> store *)
let pattern_shape wanted type_ info store =
  match unify wanted type_ store with
  | Some answer -> answer
  | None ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this pattern matches %s, but it is matched against %s"
               (printed wanted) (shown type_ store) ))

(** Why `==` cannot compare values of type t, or None where it can:
    structurally, part by part, every part a scalar or itself something
    `==` compares (PYKING.md, "Comparison operators"). A function has no
    equality; an array, a DynArray, a MutMap and a `var struct` have an identity
    instead, which `same` asks; a type variable may stand for any of
    those. A metavariable is left to what decides it. Answers the part
    that has none, as a reader names it, and what to say of it.
    store -> typ -> (string * string) option *)
let equality_problem store t =
  let same_hint = ": 'same(a, b)' asks whether two of those are one" in
  let rec go seen t =
    match prune t store with
    | TInt _ | TFloat _ | TString _ | TChar _ | TBool _ -> None
    | TTuple (_, parts, _) -> List.find_map (go seen) parts
    | TList (_, element, _) -> go seen element
    | TFunction _ | TBuiltin _ | TForall _ -> Some ("a function", "")
    | TCon (_, name, _, _) when name = array_name -> Some ("an array", same_hint)
    | TCon (_, name, _, _) when name = dynarray_name -> Some ("a DynArray", same_hint)
    | TCon (_, name, _, _) when name = mutmap_name -> Some ("a MutMap", same_hint)
    | TCon (_, name, _, _) when name = slice_name -> Some ("a view", same_hint)
    | TCon (_, name, _, _) when SMap.mem name store.classes ->
        Some
          ( Printf.sprintf "an object, a %s" (base_name name),
            ": compare the objects one at a time with '==', which calls their 'eq'" )
    | TCon (_, name, args, _) -> (
        match SMap.find_opt name store.datatypes with
        | Some (Datatype (_, _, _, true)) -> Some (Printf.sprintf "a var struct, %s" (base_name name), same_hint)
        | Some (Datatype (_, params, constructors, false)) ->
            if List.mem name seen then List.find_map (go seen) args
            else
              let mapping = if List.length params = List.length args then List.combine params args else [] in
              List.find_map
                (fun (_, fields) -> List.find_map (fun (_, ft) -> go (name :: seen) (substitute ft mapping)) fields)
                constructors
        | None -> None)
    | settled when is_meta settled -> None
    | TVar (_, name, _, _) ->
        Some
          ( Printf.sprintf "the type variable '%s'" name,
            ": it may stand for a function, or another type with no equality" )
    | _ -> None
  in
  go [] t

(** Why values of type t cannot be a MutMap's keys, or None where they can
    (FCR-F3): Int, Char, String, Bool and (), and tuples, lists and
    immutable datatypes of keys. A Float is not one -- NaN is equal to
    nothing, itself included -- nor is a function or anything with an
    identity. store -> typ -> string option *)
let key_problem store t =
  let rec go seen t =
    match prune t store with
    | TInt _ | TString _ | TChar _ | TBool _ -> None
    | TFloat _ -> Some "a Float, which NaN makes equal to nothing, not even itself"
    | TTuple (_, parts, _) -> List.find_map (go seen) parts
    | TList (_, element, _) -> go seen element
    | TCon (_, name, _, _) when name = ptr_name -> Some "a pointer, whose target changes"
    | TCon (_, name, _, _) when List.mem name [ array_name; dynarray_name; mutmap_name; slice_name ] ->
        Some (Printf.sprintf "%s, which changes" (if name = array_name then "an array" else "a " ^ name))
    | TCon (_, name, _, _) when SMap.mem name store.classes ->
        Some (Printf.sprintf "an object, a %s, which has an identity of its own" (base_name name))
    | TCon (_, name, args, _) -> (
        match SMap.find_opt name store.datatypes with
        | Some (Datatype (_, _, _, true)) -> Some (Printf.sprintf "a var struct, %s, which changes" (base_name name))
        | Some (Datatype (_, params, constructors, false)) ->
            if List.mem name seen then List.find_map (go seen) args
            else
              let mapping = if List.length params = List.length args then List.combine params args else [] in
              List.find_map
                (fun (_, fields) -> List.find_map (fun (_, ft) -> go (name :: seen) (substitute ft mapping)) fields)
                constructors
        | None -> None)
    | settled when is_meta settled -> None
    | TVar (_, name, _, _) -> Some (Printf.sprintf "the type variable '%s', which may be anything" name)
    | _ -> Some "a function"
  in
  go [] t

(** Raises Type_error where a MutMap's key type is settled enough to say it
    cannot be one. info -> typ -> store -> () *)
let demand_key info key store =
  match key_problem store key with
  | None -> ()
  | Some part ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "a MutMap's keys are compared and hashed, so a key is an Int, a \
                Char, a String, a Bool, or a tuple, list or datatype of \
                those; the key type here, %s, is or holds %s"
               (shown key store) part ))

(** What an operator is worth over two operands of type `common`, and the
    store that says so -- (None, store) where the operator does not
    accept it. expr -> typ -> [(kind, kind)] -> store -> (typ option, store) *)
let operator_result expr common rows store =
  let info = expr_info expr in
  match expr with
  | EConcat _ ->
      (* A join elaborate.ml built from a `+`: String + String is String
         and [a] + [a] is [a], so either way it is what both operands
         are. *)
      if
        (match common with TString _ | TList _ -> true | _ -> false)
        || is_meta common
      then (Some (zonk common store), store)
      else (None, store)
  | EAdd _ when (match common with TList _ -> true | _ -> false) ->
      (* Two lists of one type join into that type, which the table,
         holding only atoms, cannot state. *)
      (Some (zonk common store), store)
  | EAdd _ when is_meta common ->
      (* Two operands nothing has decided yet: `+` is worth what they
         are, whichever of its four rows that turns out to be, so the
         type is left open for a later use to decide -- a call passing
         Strings, most often. What is still open when the module is done
         is an Int (`settle_plus`). *)
      (Some common, { store with pending_plus = (common, info) :: store.pending_plus })
  | _ ->
      let results =
        List.fold_left
          (fun seen (_, result) ->
            if List.mem result seen then seen else seen @ [ result ])
          [] rows
      in
      if is_meta common then
        match (rows, results) with
        (* One row, so the operands have to be what it says. *)
        | [ (operand, result) ], _ -> (
            match unify (kind_type operand info) common store with
            | Some after -> (Some (kind_type result info), after)
            | None -> (None, store))
        (* Several rows agreeing on the result -- `==` -- so this is
           worth that whichever row it turns out to be, and nothing here
           has to decide which. *)
        | _, [ result ] -> (Some (kind_type result info), store)
        (* Several rows disagreeing about the result -- the arithmetic
           operators, once Float joined them. Nothing here has decided
           the operand, so the table's first row does: an unannotated
           `a + b` is Int arithmetic, and a Float one says so. *)
        | (operand, result) :: _, _ -> (
            match unify (kind_type operand info) common store with
            | Some after -> (Some (kind_type result info), after)
            | None -> (None, store))
        | [], _ -> (None, store)
      else
        match
          List.find_opt (fun (operand, _) -> kind_matches operand common) rows
        with
        | Some (_, result) -> (Some (kind_type result info), store)
        | None -> (None, store)

(* --- the checker itself --- *)

(** Checks a list of statements, either at the top level or as a block.
    `return_type` is what a `return` written in it is checked against and
    `acc_type` what the loop a `break`/`continue` belongs to carries;
    the answer is what the block supplies, which is None for a block that
    does not fall through. `discarded` says nothing uses what the block
    supplies -- its last statement is then run only for what it does, as
    every statement before the last always is.
    ?discarded:bool -> [stmt] -> env -> expected -> typ option -> store ->
    (typ option, store) *)
let rec check_stmts ?(discarded = false) stmts env return_type acc_type store =
  (* Bind every function definition of the block first, so that they may
     name each other and themselves. *)
  let env, store = declare_functions stmts env store in
  let start =
    Some
      (unit_type
         (match stmts with [] -> empty_info | first :: _ -> stmt_info first))
  in
  (* A statement extends the environment for the ones after it, so the
     environment is threaded through the sequence as well. *)
  let result, _, _, store, _ =
    List.fold_left
      (fun (result, left, env, store, rest) statement ->
        let rest = match rest with _ :: rest -> rest | [] -> [] in
        let before = env in
        (* A statement with another after it is run for what it does:
           what it is worth goes nowhere. *)
        let supplied, env, store =
          check_stmt ~discarded:(discarded || rest <> []) statement env
            return_type acc_type store
        in
        let store = if env == before then store else sharpened rest env store in
        if left then
          (* Everything from here on is unreachable: something above said
             what happens next on every path through it. It is still
             checked -- unreachable code is code -- but what the block is
             worth was settled where the block was left. *)
          (result, left, env, store, rest)
        else (supplied, ends_here statement, env, store, rest))
      (start, false, env, store, stmts) stmts
  in
  (result, store)

(** store with every unannotated `def` among `rest` recorded as written
    in `env`: what a body worked out before its `def` is reached sees
    the bindings above it. [stmt] -> env -> store -> store *)
and sharpened rest env store =
  List.fold_left
    (fun store statement ->
      match statement with
      | SFunctionDef _ when environment_of store (stmt_sym statement) <> None ->
          with_environment store (stmt_sym statement) env
      | _ -> store)
    store rest

(** Checks one statement. Answers what it supplies, the environment the
    statements after it should see, and the store. `discarded` says
    nothing uses what it supplies, so the branches of an `if` or the arms
    of a `match` need not agree on a type (PYKING.md, "Type checking").
    ?discarded:bool -> stmt -> env -> expected -> typ option -> store ->
    (typ option, env, store) *)
and check_stmt ?(discarded = false) statement env return_type acc_type store =
  match statement with
  | SLet (info, target, e, annotation, sym, _, implicit) ->
      (* The binding's symbol records what its right-hand side turned out
         to be; the binding *itself* is a statement, so it has unit
         type. An annotation naming an object is pushed into the value,
         which may then be an upcast. *)
      let expr_type_, store =
        match annotation with
        | Some written when mentions_object store (resolved store written) ->
            let wanted = resolved store written in
            let store = check_wanted e wanted "this binding's value" env store in
            (zonk wanted store, record store (expr_sym e) (zonk wanted store))
        | _ -> check_expr e env store
      in
      let store = check_annotation annotation expr_type_ store in
      let expr_type_ = zonk expr_type_ store in
      let store = record store sym expr_type_ in
      let env, store = check_target ~implicit target expr_type_ env store in
      (Some (unit_type info), env, store)
  | SLetStmt (info, target, inner, annotation, sym, _) ->
      (* `x = if c: ...` binds what the branch that runs yields, so the
         bound statement's own type is the binding's type -- and the
         branches having agreed on one is what the `SIf` case below has
         already established. `x = loop ...` binds the accumulator the
         loop stopped with, for the same reason. *)
      let bound_type, _, store =
        check_stmt inner env return_type acc_type store
      in
      let bound_type, store =
        match bound_type with
        | Some bound_type -> (bound_type, store)
        (* Nothing ever arrives here -- a `loop:` with no `break` is the
           only way to write it -- so the name stands for a value of no
           particular type. *)
        | None -> fresh_meta info store
      in
      let store = check_annotation annotation bound_type store in
      let bound_type = zonk bound_type store in
      let store = record store sym bound_type in
      let env, store = check_target target bound_type env store in
      (Some (unit_type info), env, store)
  | SImport (info, module_, _, _, _, _) ->
      (* What an import brings in was settled before the first statement
         was checked (see `import_env`), so there is nothing left to do
         here and nothing it is worth. Asking again is how a caller that
         checks statements one at a time -- the REPL -- is told there is
         no module system running. *)
      ignore (available module_ info store);
      (Some (unit_type info), env, store)
  | SVar (info, name, e, sym) ->
      (* A mutable variable's type is its value's, with no mark of
         mutability on it: a `var` Int is read as an ordinary Int and
         stands wherever one does. Whether this name may be bound here at
         all, and whether a `:=` may name it, is analyses.ml's rule
         rather than a type. *)
      let var_type, store = check_expr e env store in
      let var_type = zonk var_type store in
      let store = record store sym var_type in
      (Some (unit_type info), bind ~var:true env name var_type, store)
  | SMutateTuple _ -> after_desugar "typesystem"
  | SSetIndex (info, owner, index, value, sym) ->
      (* `a[i] := v` writes an element: `a` is an array -- a list or a
         String is never changed -- `i` an Int, and `v` the element type.
         They are checked in the order they run. *)
      let owner_type, store = check_expr owner env store in
      (* A compound write's array is a temporary with no span of its own
         (desugar_args.ml), so the statement is where it is reported. *)
      let owner_info =
        let o = expr_info owner in
        if o.row1 = o.row2 && o.col1 = o.col2 then info else o
      in
      (match prune owner_type store with
      | settled when mutmap_parts settled <> None ->
          (* `d[k] := v` puts an entry in a MutMap, or replaces the value of
             the one it has (PYKING.md, "MutMaps"). *)
          let key, wanted = Option.get (mutmap_parts settled) in
          let key_type, store = check_expr index env store in
          let store =
            match unify key key_type store with
            | Some store -> store
            | None ->
                raise
                  (Type_error
                     ( expr_info index,
                       Printf.sprintf "this MutMap's keys are %s, and this one is %s"
                         (shown key store) (shown key_type store) ))
          in
          demand_key (expr_info index) key store;
          let actual, store = check_expr value env store in
          let store =
            match satisfies wanted (Some actual) store with
            | Some store -> store
            | None ->
                raise
                  (Type_error
                     ( info,
                       Printf.sprintf "this MutMap's values are %s, but this '%s' gives %s"
                         (shown wanted store) (assignment_word statement) (shown actual store) ))
          in
          let store = record store sym (unit_type info) in
          (Some (unit_type info), env, store)
      | _ -> (
      let element, store =
        match prune owner_type store with
        | settled when store_element settled <> None -> (Option.get (store_element settled), store)
        | TList _ ->
            raise
              (Type_error
                 ( owner_info,
                   Printf.sprintf
                     "a list is never changed, so its element cannot be \
                      written with '%s'; an array's can: make one with \
                      'array(xs)'"
                     (assignment_word statement) ))
        | TString _ ->
            raise
              (Type_error
                 ( owner_info,
                   Printf.sprintf
                     "a String is never changed, so its characters cannot be \
                      written with '%s'"
                     (assignment_word statement) ))
        | settled when is_meta settled || kind_var_parts settled <> None -> (
            (* Nothing has said what is written: an array, a DynArray or
               a view, whichever its first call passes. *)
            match indexed_kind settled info writable_containers store with
            | Some (_, element, store) -> (element, store)
            | None ->
                raise
                  (Type_error
                     ( owner_info,
                       Printf.sprintf
                         "only an array's, a DynArray's or a view's element is written with '%s', \
                          and this value is read as %s elsewhere"
                         (assignment_word statement)
                         (containers_words (kind_allowed (fst (Option.get (kind_var_parts settled))))) )))
        | settled ->
            raise
              (Type_error
                 ( owner_info,
                   Printf.sprintf
                     "only an array's or a DynArray's element is written with '%s', \
                      and this value is %s"
                     (assignment_word statement) (shown settled store) ))
      in
      let what = if dynarray_element (prune owner_type store) <> None then "DynArray" else "array" in
      let index_type, store = check_expr index env store in
      let store =
        match unify (t_int info) index_type store with
        | Some store -> store
        | None ->
            raise
              (Type_error
                 ( expr_info index,
                   Printf.sprintf "%s index is an Int, and this one is %s"
                     (if what = "DynArray" then "a DynArray's" else "an array's")
                     (shown index_type store) ))
      in
      let actual, store = check_expr value env store in
      let store =
        match satisfies element (Some actual) store with
        | Some store -> store
        | None ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "this %s's elements are %s, but this '%s' gives %s"
                     what (shown element store) (assignment_word statement)
                     (shown actual store) ))
      in
      let store = record store sym (unit_type info) in
      (Some (unit_type info), env, store)))
  | SSetDeref (info, pointer, value, sym) ->
      (* `*p := v` writes what a pointer points at: `p` is a Ptr(T) and
         `v` a T, checked in the order they run. *)
      let pointer_type, store = check_expr pointer env store in
      let target, store =
        match prune pointer_type store with
        | settled when ptr_target settled <> None -> (Option.get (ptr_target settled), store)
        | settled when is_meta settled ->
            let target, store = fresh_meta info store in
            (target, Option.get (unify (t_ptr info target) settled store))
        | settled ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf "'*p %s' writes through a pointer, and this value is %s"
                     (assignment_word statement) (shown settled store) ))
      in
      let actual, store = check_expr value env store in
      let store =
        match satisfies target (Some actual) store with
        | Some store -> store
        | None ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf "this pointer points at %s, but this '%s' gives %s"
                     (shown target store) (assignment_word statement) (shown actual store) ))
      in
      let store = record store sym (unit_type info) in
      (Some (unit_type info), env, store)
  | SSetField (info, owner, field, value, sym) ->
      (* `p.x := v` writes a field: `p` is a `var struct` -- a plain
         struct or datatype never changes -- with a field `x`, and `v` is
         that field's type. They are checked in the order they run. *)
      let owner_type, store = check_expr owner env store in
      (* A compound write's owner is a temporary with no span of its own
         (desugar_args.ml), so the statement is where it is reported. *)
      let owner_info =
        let o = expr_info owner in
        if o.row1 = o.row2 && o.col1 = o.col2 then info else o
      in
      (match prune owner_type store with
      | TCon (_, canonical, args, _) when SMap.mem canonical store.classes -> (
          (* An object's field is written where it is declared `var`. *)
          match lookup_field store (canonical, args) field with
          | Some (owner_class, f) ->
              if f.fd_private && store.current_class <> Some owner_class then
                raise (Type_error (owner_info, Printf.sprintf "'%s' is private to '%s'" field (base_name owner_class)));
              if not f.fd_var then
                raise
                  (Type_error
                     ( owner_info,
                       Printf.sprintf
                         "the field '%s' of '%s' never changes, so it is not written with '%s'; declare it 'var %s'"
                         field (base_name owner_class) (assignment_word statement) field ));
              let store =
                check_wanted value f.fd_type
                  (Printf.sprintf "what '%s' writes to the field '%s'" (assignment_word statement) field)
                  env store
              in
              (Some (unit_type info), env, record store sym (unit_type info))
          | None -> ignore (object_member info canonical args field 0 store); (Some (unit_type info), env, store))
      | _ ->
      (match prune owner_type store with
      | TCon (_, canonical, _, _) when SMap.mem canonical store.datatypes -> (
          match SMap.find canonical store.datatypes with
          | Datatype (_, _, _, true) -> ()
          | Datatype (_, _, constructors, false) ->
              let built =
                match constructors with
                | [ (cname, _) ] -> Printf.sprintf "%s(%s = ..., ..old)" (base_name cname) field
                | _ -> "a new value"
              in
              raise
                (Type_error
                   ( owner_info,
                     Printf.sprintf
                       "a %s never changes, so its field '%s' cannot be \
                        written with '%s': build a new one, %s, or declare \
                        it 'var struct %s'"
                       (base_name canonical) field (assignment_word statement) built
                       (base_name canonical) )))
      | settled when is_meta settled ->
          raise
            (Type_error
               ( owner_info,
                 Printf.sprintf
                   "nothing here says what this value is, so there is no \
                    telling which field '%s' is written; annotate it"
                   field ))
      | settled ->
          raise
            (Type_error
               ( owner_info,
                 Printf.sprintf
                   "only a var struct's field is written with '%s', and this \
                    value is %s"
                   (assignment_word statement) (shown settled store) )));
      let wanted, store = field_type info owner_type field store in
      let actual, store = check_expr value env store in
      let store =
        match satisfies wanted (Some actual) store with
        | Some store -> store
        | None ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "the field '%s' holds %s, but this '%s' gives %s"
                     field (shown wanted store) (assignment_word statement)
                     (shown actual store) ))
      in
      let store = record store sym (unit_type info) in
      (Some (unit_type info), env, store))
  | SMutate (info, name, e, sym) -> (
      (* A mutation binds nothing and is worth nothing: the name keeps
         the type it was declared with, and the value written into it
         must fit that type. *)
      match type_of env name with
      | None ->
          raise
            (Analyses.Analysis_error (info, unbound_message env name))
      | Some declared -> (
          let actual, store = check_expr e env store in
          match satisfies declared (Some actual) store with
          | None ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf "'%s' is %s, but this '%s' gives %s" name
                       (shown declared store) (assignment_word statement)
                       (shown actual store) ))
          | Some store ->
              let store = record store sym declared in
              (Some (unit_type info), env, store)))
  | SExprStmt (_, e, _) ->
      (* An expression statement has its expression's type. That is what
         lets a block yield a value, and so what makes the two branches
         of an `if` comparable. *)
      let type_, store = check_expr e env store in
      (Some type_, env, store)
  | SIf (info, cond, then_body, else_body, _) -> (
      let cond_type, store = check_expr cond env store in
      let store =
        demand cond_type (t_bool (expr_info cond)) (expr_info cond)
          "the condition of an 'if'" store
      in
      let then_type, then_store =
        check_stmts ~discarded then_body env return_type acc_type store
      in
      match else_body with
      (* With no `else` there is a way through this statement that runs
         no branch at all, so the `if` supplies nothing whatever the one
         branch it has ends in. A body that needed that value is caught
         where the value was needed -- `check_function` -- rather than
         here. *)
      | None -> (Some (unit_type info), env, then_store)
      | Some else_body ->
          (* The `else` is checked against what the `then` *found out*,
             not against the store they both started from: only one of
             them runs, but both were checked, and what either worked out
             is true whichever way the program goes. *)
          let else_type, else_store =
            check_stmts ~discarded else_body env return_type acc_type
              then_store
          in
          if then_type = None && else_type = None then
            (* Neither way through this `if` falls out of it, so neither
               does the `if`. *)
            (None, env, else_store)
          else if
            discarded && fst (agree then_type else_type else_store) = None
          then
            (* Nothing uses what this `if` is worth -- a statement comes
               after it, or the block it ends is itself run for what it
               does -- so each branch is only run, and the two need not
               be one type. The `if` is then worth unit, as one with no
               `else` is. *)
            (Some (unit_type info), env, else_store)
          else
            (* A branch that cannot finish -- a loop with no `break` in
               it, or one ending in `break`/`continue` -- leaves the type
               of the `if` to the other one, which is what `agree` does
               with a None side. *)
            let both, else_store = agree then_type else_type else_store in
            if both = None then
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "the branches of this 'if' have different types: %s and \
                        %s. %s"
                       (shown (Option.get then_type) else_store)
                       (shown (Option.get else_type) else_store)
                       (value_used "'if'" "branches") ));
            check_not_conflated then_type else_type info;
            (both, env, else_store))
  | SReturn (info, e, _) ->
      (* A `return` supplies the function's value explicitly, so that
         value is what this statement supplies -- which is exactly what
         PYKING.md's tail-position table says of it, and what lets a
         branch that returns sit beside one that ends in an expression
         without either being a special case. *)
      if return_type = No_function then
        raise (Type_error (info, "'return' outside a function"));
      let actual, store = check_expr e env store in
      let store =
        match return_type with
        | Declared declared -> (
            match coerced store (expr_sym e) declared actual with Some answer -> answer | None -> store)
        | _ -> store
      in
      ( Some actual,
        env,
        check_return (Some actual) return_type (expr_info e) store )
  | SClass (info, c, _) -> (Some (unit_type info), env, check_class info c env store)
  | SReturnStmt (info, inner, _) ->
      (* `return if c: ...` -- the same rule, against whatever the branch
         that runs yields. *)
      if return_type = No_function then
        raise (Type_error (info, "'return' outside a function"));
      let actual, _, store = check_stmt inner env return_type acc_type store in
      (actual, env, check_return actual return_type info store)
  | SLoop (info, target, init, annotation, iterate, body, sym) ->
      (* The accumulator is what the initializer turned out to be, and
         the loop carries exactly that from turn to turn -- and is worth
         exactly that when it stops, however it stops. A loop with none
         written carries unit and is worth unit. *)
      let accumulator, body_env, store =
        match target with
        | None -> (unit_type info, env, store)
        | Some target ->
            let init =
              match init with Some init -> init | None -> unsupported info
            in
            let accumulator, store = check_expr init env store in
            let store = check_annotation annotation accumulator store in
            let accumulator = zonk accumulator store in
            let body_env, store = check_target target accumulator env store in
            (accumulator, body_env, store)
      in
      let store = record store sym accumulator in
      let turn_env, store = check_iteration iterate env body_env store in
      let supplied, store =
        check_turn ~discarded:(target = None) body turn_env return_type
          accumulator store
      in
      (* What the body ends in is what the next turn carries, so it is
         held to the accumulator's type -- unless the body always jumps,
         and then nothing arrives at the end of it to be held to
         anything. A loop carrying nothing asks nothing of its body:
         there is no next accumulator for it to give. An accumulator that
         starts as `[]` starts as `[?e]`, and what the body ends in is
         what solves it. *)
      let store =
        match (target, supplied) with
        | Some _, Some supplied_type_ ->
            let last = List.nth body (List.length body - 1) in
            let both, store = agree (Some accumulator) supplied store in
            if both = None then (
              match open_if body with
              | Some if_info ->
                  raise
                    (Type_error
                       (if_info, open_if_error (zonk accumulator store) store))
              | None ->
                  raise
                    (Type_error
                       ( stmt_info last,
                         carry_error (zonk accumulator store)
                           (zonk supplied_type_ store) store )));
            store
        | _ -> store
      in
      (Some (zonk accumulator store), env, store)
  | SBreak (info, value, _) ->
      (* A `break` ends the loop, which is then worth the accumulator
         this turn started with -- or, with a value written, that value,
         held to the accumulator's type. The statement supplies
         *nothing*: it never falls through, so no value arrives after
         it. That is None rather than a type, and it is what lets a
         branch that breaks sit beside one that ends in the next
         accumulator: `agree` keeps the other branch's answer. *)
      if acc_type = None then
        raise (Type_error (info, "'break' outside a loop"));
      (None, env, check_jump_value "break" value env acc_type store)
  | SContinue (info, value, _) ->
      (* `continue` starts the next turn with the accumulator unchanged,
         which is that type whatever it is -- or with the value written,
         which must be that type. Nothing arrives after it either, so it
         supplies nothing too. *)
      if acc_type = None then
        raise (Type_error (info, "'continue' outside a loop"));
      (None, env, check_jump_value "continue" value env acc_type store)
  | SMatch (info, subject, cases, sym) ->
      (* Every arm is a branch, and they must agree on one type the way
         an `if`'s two do -- one value leaves a `match` however many ways
         in there are. Each arm is checked in the environment its own
         pattern binds, and against what the arms before it worked
         out. *)
      let subject_type, store = check_expr subject env store in
      let yielded, seen, store =
        List.fold_left
          (fun (yielded, seen, store)
               (MatchCase (case_info, pattern, guard, body, _)) ->
            let inner, store = check_pattern pattern subject_type env store in
            (* A guard is asked once the pattern has matched, so it sees
               what the pattern binds. *)
            let store =
              match guard with
              | None -> store
              | Some g ->
                  let g_type, store = check_expr g inner store in
                  demand g_type (t_bool (expr_info g)) (expr_info g)
                    "the guard of a 'case'" store
            in
            let arm_type, store =
              check_stmts ~discarded body inner return_type acc_type store
            in
            if not seen then (arm_type, true, store)
            else if
              discarded && yielded <> None && arm_type <> None
              && fst (agree yielded arm_type store) = None
            then
              (* Nothing uses what this `match` is worth, so its arms
                 need not agree (as for `if` above): from here on it is
                 worth unit. *)
              (Some (unit_type case_info), seen, store)
            else if yielded = None || arm_type = None then
              (* An arm that never falls through leaves what the `match`
                 is worth to the arms that do. *)
              let yielded, store = agree yielded arm_type store in
              (yielded, seen, store)
            else
              let both, store = agree yielded arm_type store in
              if both = None then
                raise
                  (Type_error
                     ( case_info,
                       Printf.sprintf
                         "the arms of this 'match' have different types: %s \
                          and %s. %s"
                         (shown (Option.get yielded) store)
                         (shown (Option.get arm_type) store)
                         (value_used "'match'" "arms") ));
              check_not_conflated yielded arm_type case_info;
              (both, seen, store))
          (None, false, store) cases
      in
      if not seen then (* No arms at all. *)
        (Some (unit_type info), env, store)
      else if yielded = None then
        (* No arm falls through, so neither does the `match`. *)
        (None, env, store)
      else
        let store = record store sym (Option.get yielded) in
        (* Every `match` matches every value -- exhaustive.ml refuses one
           that does not -- so it supplies what its arms do. *)
        (yielded, env, store)
  | SDatatype (info, _, _, _, _, _, _) ->
      (* What a datatype declares was settled before the first statement
         was checked (`declare_datatypes`), since every datatype of the
         module is in scope throughout it. *)
      (Some (unit_type info), env, store)
  | SFunctionSig (info, _, _, _, _) ->
      (* The signature was paired with its definition before this block
         was checked (`declare_signatures`); on its own it says nothing
         and produces nothing. *)
      (Some (unit_type info), env, store)
  | SFunctionDef (info, name, _, _, _, sym, _, _, implicit) ->
      check_implicit_annotated statement store;
      if fully_annotated statement store then
        (* Checked against its annotations here; visible under its own
           name only to the statements that follow. *)
        let supplied, store = check_function statement env store in
        ( supplied,
          bind ~implicit env name (function_type statement store),
          store )
      else
        (* Not fully annotated: there is nothing to check yet, because
           what an unannotated parameter is depends on what is passed to
           it. All this statement does is fix *where* the function was
           written, since that is the scope its body belongs to however
           far away it is eventually called from. The name is already
           bound, by `declare_functions`, and the binding names the
           definition by symbol -- so recording the environment here is
           what every holder of that name sees. *)
        let store = with_environment store sym env in
        match SMap.find_opt name store.field_defaults with
        | None -> (Some (unit_type info), env, store)
        | Some (field_type, field) ->
            (Some (unit_type info), env, field_default info name field_type field env store)

(** The store in which the field whose default the def `name` holds has
    that default's type. Raises Type_error where the default does not
    decide a type of its own. info -> String -> typ -> String -> env ->
    store -> store *)
and field_default info name field_type field env store =
  let call = ECall (info, EVar (info, name, 0), [], 0) in
  let given, after = expr_type call env store in
  let after =
    { after with tmap = IntMap.remove 0 after.tmap; qmap = IntMap.remove 0 after.qmap }
  in
  let given = zonk given after in
  if metas_in given after <> [] then
    raise
      (Type_error
         ( info,
           Printf.sprintf
             "the default of the field '%s' does not decide its type (it is \
              %s); write the type: '%s: T = ...'"
             field (shown given after) field ));
  demand given field_type info
    (Printf.sprintf "the field '%s', used before its default is reached," field)
    after

(** store with the value a `break`/`continue` carries held to the
    accumulator of the loop it belongs to. Nothing to check without one.
    string -> expr option -> env -> typ option -> store -> store *)
and check_jump_value keyword value env acc_type store =
  match (value, acc_type) with
  | None, _ | _, None -> store
  | Some e, Some accumulator -> (
      let actual, store = check_expr e env store in
      match unify accumulator actual store with
      | Some store -> store
      | None ->
          raise
            (Type_error (expr_info e, jump_error keyword accumulator actual store)))

(** One pass over a loop body: what it supplies -- the accumulator the
    next turn carries -- and the store. A `return` written in the body
    leaves the enclosing *function*, so what it gives stays in the frame,
    exactly as one written outside the loop would.
    [stmt] -> env -> expected -> typ -> store -> (typ option, store) *)
and check_turn ?(discarded = false) body turn_env return_type accumulator store =
  check_stmts ~discarded body turn_env return_type (Some accumulator) store

(** The environment a loop's body runs in, once its iteration clause is
    checked. A `for` walks a list and binds its element over the body; a
    `while` is a Bool test, asked where the accumulator is in scope.
    loop_iter option -> env -> env -> store -> (env, store) *)
and check_iteration iterate env body_env store =
  match iterate with
  | Some (ForIn (info, name, sequence, _)) ->
      let sequence_type, store = check_expr sequence env store in
      let element, store =
        demand_sequence sequence_type info
          "a 'for' loop walks a list or a String, but this one" store
      in
      (bind body_env name element, store)
  | Some (WhileTest (info, condition, _)) ->
      let condition_type, store = check_expr condition body_env store in
      ( body_env,
        demand condition_type (t_bool info) info "the condition of a 'while'"
          store )
  | None -> (body_env, store)

(** env with every name in an assignment target bound to its part of
    type_, recording each part under the target's own symbol, and the
    store that makes the value the right shape.

    A destructuring target is a *demand* for a tuple of that many parts,
    so a value nothing has decided yet is settled by it -- which is what
    lets `n, s = pair` say what `pair` is inside a body being worked out.
    assign_target -> typ -> env -> store -> (env, store) *)
and check_target ?(implicit = false) target type_ env store =
  match target with
  | TargetName (_, name, sym) ->
      let store = record store sym type_ in
      (bind ~implicit env name type_, store)
  | TargetTuple (info, elements, sym) -> (
      let parts, store = fresh_metas (List.length elements) info store in
      match unify (t_tuple info parts) type_ store with
      | None ->
          (* A tuple `:=` binds its parts to `name__new` temporaries first
             (desugar_args), and is reported as what was written. *)
          let rec temporaries target =
            match target with
            | TargetName (_, name, _) -> String.ends_with ~suffix:"__new" name
            | TargetTuple (_, parts, _) -> List.for_all temporaries parts
          in
          raise
            (Type_error
               ( info,
                 if temporaries target then
                   Printf.sprintf
                     "this ':=' writes %d values, but its value has type %s"
                     (List.length elements) (shown type_ store)
                 else
                   Printf.sprintf
                     "this binding takes %d values apart, but its value has \
                      type %s"
                     (List.length elements) (shown type_ store) ))
      | Some store ->
          let store = record store sym (zonk type_ store) in
          List.fold_left2
            (fun (env, store) element part ->
              check_target element part env store)
            (env, store) elements parts)

(** The type of one expression, recorded in the store's table under its
    symbol. expr -> env -> store -> (typ, store) *)
and check_expr e env store =
  let type_, store = expr_type e env store in
  (type_, record store (expr_sym e) type_)

(** The rules: what each expression is worth, without recording it.
    expr -> env -> store -> (typ, store) *)
and expr_type e env store =
  match e with
  | EInt (info, _, _) -> (t_int info, store)
  | EFloat (info, _, _) -> (t_float info, store)
  | EString (info, _, _) -> (t_string info, store)
  | EChar (info, _, _) -> (t_char info, store)
  | EBool (info, _, _) -> (t_bool info, store)
  | ETuple (info, elements, _) ->
      (* A tuple of the element types, in order -- and `()`, with no
         elements, is the unit type, which is the same thing said of
         nothing. *)
      let types, store = check_each elements env store in
      (t_tuple info types, store)
  | EVar (info, name, _) -> (
      (* Two different questions, asked in order. Is the name in scope at
         all -- a question about *names*, answered the way analyses.ml
         answers it and reported the same way? And then: does this
         checker know a type for it? *)
      match type_of env name with
      | None -> (
          match candidates_for e env with
          | Some (_, candidates) ->
              (* Several `::` definitions and no plain one: the arguments
                 of a call are what say which is meant, and there are
                 none here (docs/overloading.md). *)
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' names %d definitions (%s), so it can be called \
                        but not used as a value; write the one that is meant"
                       name (List.length candidates)
                       (String.concat ", "
                          (List.map (fun (n, _) -> "'" ^ n ^ "'") candidates))
                   ))
          | None when name = "self" ->
              raise
                (Analyses.Analysis_error
                   (info, "'self' is the object a method is called on, so it is written only inside a class's method"))
          | None ->
              raise
                (Analyses.Analysis_error (info, unbound_message env name)))
      | Some (TBuiltin (_, builtin, _)) ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'%s' is a builtin operation: it can be called, but not \
                    used as a value"
                   builtin ))
      | Some type_ ->
          (* A name standing for a definition something has already
             worked out means the scheme it turned out to be, not the
             promise it was declared as. One nothing has worked out yet
             is worked out here: handing a definition somewhere is a
             demand on its type as surely as calling it is, and its body
             would otherwise never be checked at all. *)
          let store = work_out type_ store in
          (settled_type type_ store, store))
  | EQualified (info, module_, name, _) -> (
      (* A public name of an imported module. `import_env` put it in the
         environment under this very spelling, so the lookup is `EVar`'s
         -- and the type is the one the module's own check worked out,
         read out of its sigmap. *)
      let qualified = Printf.sprintf "%s.%s" module_ name in
      match type_of env qualified with
      | None ->
          raise
            (Analyses.Analysis_error
               (info, unreachable_name module_ name env))
      | Some type_ -> (settled_type type_ store, store))
  | EIf (info, cond, then_expr, else_expr, _) ->
      (* The `if` *expression*, whose `else` is mandatory -- so unlike
         the statement it always yields a value, and its branches must
         agree on what. *)
      let cond_type, store = check_expr cond env store in
      let store =
        demand cond_type (t_bool (expr_info cond)) (expr_info cond)
          "the condition of an 'if'" store
      in
      (* Both branches yield the value this expression is worth, so they
         are one type. *)
      let then_type, then_store = check_expr then_expr env store in
      let else_type, else_store = check_expr else_expr env then_store in
      let both, else_store =
        agree (Some then_type) (Some else_type) else_store
      in
      if both = None then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "the branches of this 'if' have different types: %s and %s"
                 (shown then_type else_store) (shown else_type else_store) ));
      check_not_conflated (Some then_type) (Some else_type) info;
      (Option.get both, else_store)
  | ENeg (info, operand, _) -> (
      (* Negation follows the arithmetic table: a Float negates to a
         Float, and an operand nothing has decided is an Int, which is
         the table's first row. *)
      let operand_type, store = check_expr operand env store in
      let settled = prune operand_type store in
      match
        if is_meta settled then unify (t_int info) settled store
        else if kind_matches KInt settled || kind_matches KFloat settled then
          Some store
        else None
      with
      | Some answer -> (zonk (prune operand_type answer) answer, answer)
      | None ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "`-` cannot be applied to %s; it negates an Int or a Float"
                   (shown operand_type store) )))
  | EList (info, elements, _) ->
      (* Every element is one of the same list, so they agree on one type
         -- the rule the branches of an `if` obey, for the same reason.
         An empty list has no element to say what it holds, and is worth
         `[a]` for a variable nothing has constrained: no element of it
         ever arrives, so it fits wherever any list is wanted. *)
      let types, store = check_each elements env store in
      (match types with
      | [] ->
          let element, store = fresh_meta info store in
          (t_list info element, store)
      | first :: rest ->
          let element, store =
            List.fold_left
              (fun (element, store) other ->
                let both, store = agree (Some element) (Some other) store in
                match both with
                | Some both -> (both, store)
                | None when is_object_type store element && is_object_type store other ->
                    (* Two classes: no common type is guessed. *)
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "the elements of this list are a %s and a %s, and Pyking does not guess a \
                              common type; annotate the list, as in 'xs: [Shape] = [...]', with the \
                              class or interface both are"
                             (shown element store) (shown other store) ))
                | None ->
                    raise
                      (Type_error
                         ( info,
                           Printf.sprintf
                             "the elements of this list have different types: \
                              %s and %s"
                             (shown element store) (shown other store) )))
              (first, store) rest
          in
          (t_list info element, store))
  | EListComp (info, element, clauses, _) ->
      let inner, store = check_clauses clauses env store in
      let element_type, store = check_expr element inner store in
      (t_list info element_type, store)
  | ELambda (info, params, body, _) -> check_lambda info params body env store
  | ELet (_, target, annotation, value, body, _) ->
      (* As an `=` binding: the value is checked where the `let` is
         written, and only the body sees what it binds. *)
      let value_type, store = check_expr value env store in
      let store = check_annotation annotation value_type store in
      let value_type = zonk value_type store in
      let inner, store = check_target target value_type env store in
      check_expr body inner store
  | EConstruct (info, module_, name, args, _) when object_class store module_ name <> None ->
      let c = Option.get (object_class store module_ name) in
      if c.cl_kind <> ClassPlain then
        raise
          (Type_error
             ( info,
               if c.cl_kind = ClassInterface then
                 Printf.sprintf "'%s' is an interface, which cannot be made; make a class that implements it" name
               else
                 Printf.sprintf "'%s' is an abstract class, which cannot be made; make a class that extends it" name ));
      let metas, store = fresh_metas (List.length c.cl_params) info store in
      let mapping = class_mapping c metas in
      let given = arg_exprs args in
      if List.length given <> List.length c.cl_header then
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' takes %d argument%s, but %d %s given" name (List.length c.cl_header)
                 (if List.length c.cl_header = 1 then "" else "s")
                 (List.length given)
                 (if List.length given = 1 then "was" else "were") ));
      let store =
        List.fold_left2
          (fun store arg (n, t) ->
            check_wanted arg (substitute t mapping) (Printf.sprintf "the field '%s' of '%s'" n name) env store)
          store given c.cl_header
      in
      (zonk (TCon (info, c.cl_name, metas, 0)) store, store)
  | EConstruct (info, module_, name, args, _) ->
      (* A constructor is applied to every one of its fields -- the sugar
         has filled in the defaults and put the named ones in place --
         and builds a value of its datatype at whatever the fields say
         the parameters are. *)
      let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
      let _, fields, result, store = constructor_use info spelled name store in
      (* Making a `var struct` is mutation's, wherever it is declared
         (FCR-A4); the parser refuses one this module declares, and this
         is where one another module declares is. *)
      (match prune result store with
      | TCon (_, canonical, _, _) when not store.mutation -> (
          match SMap.find_opt canonical store.datatypes with
          | Some (Datatype (_, _, _, true)) ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "'%s' makes a var struct, whose fields are written in \
                        place, which needs 'use mutation' at the top of this \
                        module"
                       spelled ))
          | _ -> ())
      | _ -> ());
      let given = arg_exprs args in
      if List.length given <> List.length fields then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "'%s' has %d field%s, but %d %s given%s" spelled
                 (List.length fields)
                 (if List.length fields = 1 then "" else "s")
                 (List.length given)
                 (if List.length given = 1 then "was" else "were")
                 (if given = [] then
                    "; a constructor is not a value, so one with fields is \
                     always applied to them"
                  else "") ));
      let store, _ =
        List.fold_left2
          (fun (store, position) argument (label, wanted) ->
            let actual, store = check_expr argument env store in
            let store =
              demand actual wanted (expr_info argument)
                (field_named spelled position label)
                store
            in
            (store, position + 1))
          (store, 0) given fields
      in
      (zonk result store, store)
  | EField (info, record, field, sym) -> (
      let record_type, store = check_expr record env store in
      match prune record_type store with
      | TCon (_, canonical, args, _) when SMap.mem canonical store.classes ->
          object_member info canonical args field sym store
      | _ -> field_type info record_type field store)
  | ESuper (info, _, name, args, sym) -> check_super info name args sym env store
  | EMethod (info, _, _, _, _) | EUpcast (info, _, _, _) -> unsupported info
  | ECall _ -> check_call e env store
  | EAdd _ | EConcat _ | ESub _ | EMul _ | EDiv _ | ELessThan _
  | ELessThanEq _ | EGreatThan _ | EGreatThanEq _ | EEq _ | EBinary _ ->
      check_binary e env store
  | EUnary (info, op, operand, _) -> (
      (* `not` is logic on a Bool and bitwise on an Int, and an operand
         nothing has decided is a Bool; `!` is a Bool's alone and `~` an
         Int's. *)
      let operand_type, store = check_expr operand env store in
      let settled = prune operand_type store in
      let accepts, default =
        match op with
        | UNot Word -> ([ KBool; KInt ], KBool)
        | UNot Symbol -> ([ KBool ], KBool)
        | UBitNot _ -> ([ KInt ], KInt)
      in
      match
        if is_meta settled then unify (kind_type default info) settled store
        else if List.exists (fun kind -> kind_matches kind settled) accepts then Some store
        else None
      with
      | Some answer -> (zonk (prune operand_type answer) answer, answer)
      | None ->
          let hint =
            match op with
            | UNot Symbol when kind_matches KInt settled -> ". On an Int, write 'not' or '~'"
            | UBitNot _ when kind_matches KBool settled -> ". On a Bool, write 'not' or '!'"
            | _ -> ""
          in
          raise
            (Type_error
               ( info,
                 Printf.sprintf "`%s` cannot be applied to %s; it takes %s%s"
                   (unop_text op) (shown operand_type store)
                   (String.concat " or "
                      (List.map (fun kind -> printed (kind_type kind info)) accepts))
                   hint )))
  | EAddr (info, place, _) -> (
      (* `&place`: a pointer to a place something may write -- a `var`,
         an array's or a view's element, a var struct's field, or what a
         pointer points at (PYKING.md, "Pointers"). *)
      let refuse what =
        raise
          (Type_error
             ( expr_info place,
               Printf.sprintf
                 "'&' takes the address of a place that can be written -- a \
                  'var', an array's element, a var struct's field, or '*p' -- \
                  and %s" what ))
      in
      match place with
      | EVar (_, name, _) -> (
          match SMap.find_opt name env with
          | Some { bvar = true; _ } ->
              let target, store = check_expr place env store in
              (t_ptr info (zonk target store), store)
          | Some _ ->
              refuse
                (Printf.sprintf
                   "'%s' is not a var, so nothing can write to it through a \
                    pointer: declare it 'var %s = ...'"
                   name name)
          | None -> ignore (check_expr place env store); refuse "")
      | EIndex (_, owner, _, _) -> (
          let owner_type, _ = check_expr owner env store in
          match prune owner_type store with
          | settled when array_element settled <> None || slice_element settled <> None ->
              let target, store = check_expr place env store in
              (t_ptr info (zonk target store), store)
          | settled when dynarray_element settled <> None ->
              refuse "a DynArray's element moves when the DynArray grows: take the address of an array's"
          | _ -> refuse "this element is of a value that never changes, or of a MutMap")
      | EField (_, owner, _, _) -> (
          let owner_type, _ = check_expr owner env store in
          match prune owner_type store with
          | TCon (_, name, _, _)
            when (match SMap.find_opt name store.datatypes with
                  | Some (Datatype (_, _, _, writable)) -> writable
                  | None -> false) ->
              let target, store = check_expr place env store in
              (t_ptr info (zonk target store), store)
          | _ -> refuse "this field is of a struct or datatype that never changes")
      | EDeref _ ->
          let target, store = check_expr place env store in
          (t_ptr info (zonk target store), store)
      | EQualified (_, alias, field, s) when SMap.mem alias env ->
          (* `&p.x`: a value's field, which the parser read as a module's
             name. *)
          check_expr (EAddr (info, EField (expr_info place, EVar (expr_info place, alias, 0), field, s), 0)) env store
      | _ -> refuse "this is a value, not a place: a call's result or a literal has nowhere to write")
  | EDeref (info, pointer, _) -> (
      (* `*p`: what the pointer points at, now. *)
      let pointer_type, store = check_expr pointer env store in
      match prune pointer_type store with
      | settled when ptr_target settled <> None -> (zonk (Option.get (ptr_target settled)) store, store)
      | settled when is_meta settled ->
          let target, store = fresh_meta info store in
          let store = Option.get (unify (t_ptr info target) settled store) in
          (target, store)
      | settled ->
          raise
            (Type_error
               ( expr_info pointer,
                 Printf.sprintf "'*' reads through a pointer, and this value is %s"
                   (shown settled store) )))
  | ESlice (info, seq, low, high, _) ->
      (* `s[i:j]` copies a run of a list, a String, an array, a DynArray or a
         view into a new value of its own kind -- a view's into an array
         -- and its bounds are Ints (PYKING.md, "Slices"). *)
      let seq_type, store = check_expr seq env store in
      let result, store =
        match prune seq_type store with
        | TString _ as t -> (t, store)
        | TList _ as t -> (zonk t store, store)
        | settled when array_element settled <> None || dynarray_element settled <> None -> (zonk settled store, store)
        | settled when slice_element settled <> None -> (t_array info (zonk (Option.get (slice_element settled)) store), store)
        | settled when (is_meta settled || kind_var_parts settled <> None)
                       && indexed_kind settled info [ CList; CArray; CDynArray; CString ] store <> None ->
            (* Nothing has said what is sliced: its first call will, and
               the slice is of the same kind. A view is not one of them,
               since its slice is an array rather than a view. *)
            let made, _, store = Option.get (indexed_kind settled info [ CList; CArray; CDynArray; CString ] store) in
            (made, store)
        | settled ->
            raise
              (Type_error
                 ( expr_info seq,
                   Printf.sprintf
                     "only a list, a String, an array, a DynArray or a view is sliced \
                      with '[i:j]', and this value is %s"
                     (shown settled store) ))
      in
      let store =
        List.fold_left
          (fun store bound ->
            let bound_type, store = check_expr bound env store in
            match unify (t_int info) bound_type store with
            | Some store -> store
            | None ->
                raise
                  (Type_error
                     ( expr_info bound,
                       Printf.sprintf "a slice's bounds are Ints, and this one is %s"
                         (shown bound_type store) )))
          store
          (Option.to_list low @ Option.to_list high)
      in
      (result, store)
  | EIndex (info, list, index, _) ->
      (* `xs[i]` reads element i of a list, so the list is `[a]` for some
         a, the index an Int, and the element is worth an `a`. A String
         is indexed too, and its element is a Char. A MutMap is indexed by
         its key, and its element is a value (PYKING.md, "MutMaps"). *)
      let list_type, store = check_expr list env store in
      match prune list_type store with
      | settled when mutmap_parts settled <> None ->
          let key, value = Option.get (mutmap_parts settled) in
          let key_type, store = check_expr index env store in
          let store =
            match unify key key_type store with
            | Some store -> store
            | None ->
                raise
                  (Type_error
                     ( expr_info index,
                       Printf.sprintf "this MutMap's keys are %s, and this one is %s"
                         (shown key store) (shown key_type store) ))
          in
          demand_key (expr_info index) key store;
          (zonk value store, store)
      | _ ->
      let indexed =
        if kind_var_parts (prune list_type store) <> None || is_meta (prune list_type store) then "a list's, an array's or a String"
        else if kind_matches KString (prune list_type store) then "a String"
        else if kind_matches KArray (prune list_type store) then "an array"
        else if kind_matches KDynArray (prune list_type store) then "a DynArray"
        else if kind_matches KSlice (prune list_type store) then "a view"
        else "a list"
      in
      let element, store =
        match prune list_type store with
        | TString _ -> (t_char info, store)
        | settled when store_element settled <> None -> (Option.get (store_element settled), store)
        | settled when (is_meta settled || kind_var_parts settled <> None)
                       && indexed_kind settled info all_containers store <> None ->
            (* Nothing has said what is indexed: its first call will, and
               until then it is any store of elements. *)
            let _, element, store = Option.get (indexed_kind settled info all_containers store) in
            (element, store)
        | _ -> (
            let element, store = fresh_meta info store in
            match unify (t_list info element) list_type store with
            | Some store -> (element, store)
            | None ->
                raise
                  (Type_error
                     ( expr_info list,
                       Printf.sprintf
                         "only a list, an array, a DynArray, a MutMap or a String is indexed \
                          with '[...]', and this value is %s"
                         (shown list_type store) )))
      in
      let index_type, store = check_expr index env store in
      let store =
        match unify (t_int info) index_type store with
        | Some store -> store
        | None ->
            raise
              (Type_error
                 ( expr_info index,
                   Printf.sprintf "%s's index is an Int, and this one is %s" indexed
                     (shown index_type store) ))
      in
      (zonk element store, store)

(** One lambda: the function type it is worth.

    A lambda is **lambda-bound and so monomorphic**, whatever it is
    bound to afterwards -- `def` is how a polymorphic function is
    written (PYKING.md, "Lambdas"). A parameter with no annotation is a
    metavariable the body and the uses settle between them; a type
    variable *written* in one is a metavariable too, and one shared by
    every parameter that names it, since there is nothing here to
    quantify it. The body is checked in the environment the lambda
    stands in, extended with the parameters -- what it captures is what
    is bound where it is written.
    info -> [param] -> expr -> env -> store -> (typ, store) *)
and check_lambda info params body env store =
  let written =
    List.filter_map
      (fun (Param (_, _, type_, _, _)) -> resolved_option store type_)
      params
  in
  let mapping, store =
    List.fold_left
      (fun (mapping, store) name ->
        if List.mem_assoc name mapping then (mapping, store)
        else
          let meta, store = fresh_meta info store in
          (mapping @ [ (name, meta) ], store))
      ([], store)
      (List.concat_map free_vars written)
  in
  let param_types, store =
    List.fold_left
      (fun (types, store) (Param (param_info, _, type_, _, _)) ->
        match resolved_option store type_ with
        | Some written -> (types @ [ substitute written mapping ], store)
        | None ->
            let meta, store = fresh_meta param_info store in
            (types @ [ meta ], store))
      ([], store) params
  in
  let store =
    List.fold_left2
      (fun store param type_ ->
        let _, store = check_param param type_ store in
        store)
      store params param_types
  in
  let body_env =
    List.fold_left2
      (fun body_env param type_ -> bind body_env (param_name param) type_)
      env params param_types
  in
  let result, store = check_expr body body_env store in
  (t_function info param_types result, store)

(** Checks every expression left to right (Pyking's evaluation order) and
    answers their types. [expr] -> env -> store -> ([typ], store) *)
and check_each exprs env store =
  match exprs with
  | [] -> ([], store)
  | first :: rest ->
      let type_, store = check_expr first env store in
      let types, store = check_each rest env store in
      (type_ :: types, store)

(** The type of a binary operator application, from the operator table.

    **Every operator Pyking has takes two operands of one type**, so they
    are unified first and the table is then asked about that one type.
    Doing it the other way round -- trying each row against each operand
    -- would pick the first row a still-open operand happened to fit, and
    pin two types that had said nothing to whichever row the table lists
    first. expr -> env -> store -> (typ, store) *)
and check_binary e env store =
  let ordering = match e with ELessThan _ | ELessThanEq _ | EGreatThan _ | EGreatThanEq _ -> true | _ -> false in
  let equality =
    match e with EEq (_, l, r, _) -> Some (true, l, r) | EBinary (_, BNeq, l, r, _) -> Some (false, l, r) | _ -> None
  in
  let object_answer =
    match (equality, binary_operands e) with
    | Some (positive, left, right), _ -> (
        let left_type, peeked = check_expr left env store in
        match prune left_type peeked with
        | TCon (_, canonical, args, _) when SMap.mem canonical peeked.classes -> (
            let word = if positive then "==" else "!=" in
            match lookup_method peeked (canonical, args) "eq" with
            | Some (_, m) ->
                let other = match m.md_params with [ (_, t, _) ] -> t | _ -> left_type in
                let store = check_wanted right other (Printf.sprintf "what '%s' compares a %s to" word (base_name canonical)) env peeked in
                Some (t_bool (expr_info e), record_resolution store (expr_sym e) (Object_eq positive))
            | None ->
                raise
                  (Type_error
                     ( expr_info e,
                       Printf.sprintf
                         "'%s' compares two %ss, but '%s' has no 'eq' method; define 'def eq(self, other: %s) -> Bool', \
                          or use 'same(a, b)' to ask whether they are one object"
                         word (base_name canonical) (base_name canonical) (base_name canonical) )))
        | _ -> None)
    | None, Some (left, _) when ordering -> (
        let left_type, peeked = check_expr left env store in
        match prune left_type peeked with
        | TCon (_, canonical, _, _) when SMap.mem canonical peeked.classes ->
            raise
              (Type_error
                 ( expr_info e,
                   Printf.sprintf "objects have no order, so a %s is not compared with '<'; compare what a method says of them"
                     (base_name canonical) ))
        | _ -> None)
    | _ -> None
  in
  match object_answer with
  | Some answer -> answer
  | None ->
  let spelling, rows =
    match operator_of e with Some pair -> pair | None -> unsupported (expr_info e)
  in
  let left, right =
    match binary_operands e with
    | Some pair -> pair
    | None -> unsupported (expr_info e)
  in
  let left_type, store = check_expr left env store in
  let right_type, store = check_expr right env store in
  let structured common =
    match common with
    | TList _ -> true
    | TTuple (_, parts, _) -> parts <> []
    | TCon (_, name, _, _) -> not (List.mem name [ array_name; dynarray_name; mutmap_name; slice_name ])
    | _ -> false
  in
  let answer =
    match unify left_type right_type store with
    | None -> None
    | Some together -> (
        let common = prune left_type together in
        match e with
        | (EEq _ | EBinary (_, BNeq, _, _, _)) when structured common -> (
            (* `==` on lists, tuples, structs and datatypes compares them
               part by part, where every part is something `==`
               compares (PYKING.md, "Comparison operators"). *)
            match (common, equality_problem together common) with
            | TCon (_, name, _, _), Some _
              when (match SMap.find_opt name together.datatypes with
                    | Some (Datatype (_, _, _, true)) -> true
                    | _ -> false) ->
                None
            | _, None -> Some (t_bool (expr_info e), together)
            | _, Some (part, hint) ->
                raise
                  (Type_error
                     ( expr_info e,
                       Printf.sprintf
                         "`%s` compares %s part by part, and this one holds %s, \
                          which `%s` does not compare%s"
                         spelling (shown common together) part spelling
                         hint )))
        | _ -> (
            match operator_result e common rows together with
            | Some type_, after -> Some (type_, after)
            | None, _ -> None))
  in
  match answer with
  | Some pair -> pair
  | None -> raise (operator_error e spelling rows left_type right_type store)

(** The store in which `arg` is a `wanted`: one type, or an object seen as
    one of its supertypes (an upcast). Where `wanted` holds an object, a
    list, tuple or `if` written here has it pushed into each part, so
    each element is upcast on its own. Raises Type_error naming `what`.
    expr -> typ -> string -> env -> store -> store *)
and check_wanted arg wanted what env store =
  match arg with
  | (EList (_, _ :: _, _) | ETuple (_, _ :: _, _) | EIf _) when mentions_object store wanted -> (
      match (arg, prune wanted store) with
      | EList (info, elements, sym), TList (_, element, _) ->
          let store = List.fold_left (fun store x -> check_wanted x element what env store) store elements in
          record store sym (t_list info element)
      | ETuple (info, elements, sym), TTuple (_, parts, _) when List.length parts = List.length elements ->
          let store = List.fold_left2 (fun store x w -> check_wanted x w what env store) store elements parts in
          record store sym (TTuple (info, parts, 0))
      | EIf (info, condition, then_, else_, sym), _ ->
          let c, store = check_expr condition env store in
          let store = demand c (t_bool info) (expr_info condition) "the condition of an 'if'" store in
          let store = check_wanted then_ wanted what env store in
          let store = check_wanted else_ wanted what env store in
          record store sym wanted
      | _ -> check_plain_wanted arg wanted what env store)
  | _ -> check_plain_wanted arg wanted what env store

and check_plain_wanted arg wanted what env store =
  let actual, store = check_expr arg env store in
  match coerced store (expr_sym arg) wanted actual with
  | Some answer -> answer
  | None ->
      let hint =
        match (prune wanted store, prune actual store) with
        | TList (_, w, _), TList (_, a, _) when is_object_type store w && is_object_type store a ->
            Printf.sprintf ": a [%s] is not a [%s], since lists do not take subtypes; annotate the list where it is made"
              (shown a store) (shown w store)
        | _ -> ""
      in
      raise
        (Type_error
           (expr_info arg, Printf.sprintf "%s must be %s, not %s%s" what (shown wanted store) (shown actual store) hint))

(** What reading `field` of an object gives: a field's value, or a
    method as a function, closed over the object. Private members are
    reached only from the methods of the class declaring them.
    info -> string -> [typ] -> string -> int -> store -> (typ, store) *)
and object_member info canonical args field sym store =
  let private_to owner = store.current_class <> Some owner in
  match lookup_field store (canonical, args) field with
  | Some (owner, f) ->
      if f.fd_private && private_to owner then
        raise (Type_error (info, Printf.sprintf "'%s' is private to '%s'" field (base_name owner)));
      (zonk f.fd_type store, store)
  | None -> (
      match lookup_method store (canonical, args) field with
      | Some (owner, m) ->
          if m.md_private && private_to owner then
            raise (Type_error (info, Printf.sprintf "'%s' is private to '%s'" field (base_name owner)));
          let store = record_resolution store sym (Method_value (List.length m.md_params)) in
          (t_function info (List.map (fun (_, t, _) -> t) m.md_params) m.md_return, store)
      | None ->
          let known =
            List.concat_map
              (fun (n, _) ->
                match class_named store n with
                | Some c -> List.map (fun f -> f.fd_name) c.cl_fields @ List.map (fun m -> m.md_name) c.cl_methods
                | None -> [])
              (all_supers store (canonical, args))
          in
          raise
            (Type_error
               ( info,
                 Printf.sprintf "'%s' has no field or method '%s'%s" (base_name canonical) field
                   (match Suggest.closest field known with
                   | meant :: _ -> Printf.sprintf "; did you mean '%s'?" meant
                   | [] -> "") )))

(** The store in which a method's arguments -- positional, then named,
    any left out having a default -- each fit their parameter.
    info -> string -> method_info -> [(String?, expr)] -> env -> store -> store *)
and check_method_arguments info shown m written env store =
  let params = m.md_params in
  let positional = List.filter (fun (n, _) -> n = None) written in
  let named = List.filter_map (fun (n, e) -> Option.map (fun n -> (n, e)) n) written in
  if List.length written > List.length params || List.length positional > List.length params then
    raise
      (Type_error
         ( info,
           Printf.sprintf "'%s' takes %d argument%s, but %d %s given" shown (List.length params)
             (if List.length params = 1 then "" else "s")
             (List.length written)
             (if List.length written = 1 then "was" else "were") ));
  List.iter
    (fun (n, e) ->
      match List.find_opt (fun (p, _, _) -> p = n) params with
      | None -> raise (Type_error (expr_info e, Printf.sprintf "'%s' has no parameter '%s'" shown n))
      | Some _ ->
          let at = let rec find k = function [] -> 0 | (p, _, _) :: rest -> if p = n then k else find (k + 1) rest in find 0 params in
          if at < List.length positional then
            raise (Type_error (expr_info e, Printf.sprintf "'%s' is already given by position %d" n (at + 1))))
    named;
  List.fold_left
    (fun (store, at) (p, t, default) ->
      let given =
        if at < List.length positional then Some (snd (List.nth positional at)) else List.assoc_opt p named
      in
      match given with
      | Some e -> (check_wanted e t (Printf.sprintf "the argument '%s' of '%s'" p shown) env store, at + 1)
      | None when default <> None -> (store, at + 1)
      | None ->
          raise (Type_error (info, Printf.sprintf "'%s' needs its argument '%s', which has no default" shown p)))
    (store, 0) params
  |> fst

(** A call of a method found on an object's class.
    expr -> (string * method_info) -> [(String?, expr)] -> env -> store -> (typ, store) *)
and check_method_call call (owner, m) written env store =
  let info = expr_info call in
  if m.md_private && store.current_class <> Some owner then
    raise (Type_error (info, Printf.sprintf "'%s' is private to '%s'" m.md_name (base_name owner)));
  let store = check_method_arguments info m.md_name m written env store in
  let store =
    record_resolution store (expr_sym call) (Method_call (owner, List.map (fun (n, _, d) -> (n, d)) m.md_params))
  in
  (zonk m.md_return store, store)

(** `super.name(args)`: the implementation the class inherited, from its
    parent's chain first, then a default of one of its interfaces.
    info -> string -> [(String?, expr)] -> int -> env -> store -> (typ, store) *)
and check_super info name written sym env store =
  match store.current_class with
  | None -> raise (Type_error (info, "'super' calls a method the class inherited, so it is written only inside a method"))
  | Some cname ->
      let c = Option.get (class_named store cname) in
      let self_args = List.map (t_var info) c.cl_params in
      let chain = match c.cl_parent with Some p -> class_chain store p | None -> [] in
      let in_chain =
        match lookup_method_in store chain name with Some (o, m) when not m.md_abstract -> Some (o, m) | _ -> None
      in
      let found =
        match in_chain with
        | Some found -> found
        | None -> (
            let defaults =
              List.filter_map
                (fun (n, args) ->
                  match class_named store n with
                  | Some ({ cl_kind = ClassInterface; _ } as k) -> (
                      match List.find_opt (fun m -> m.md_name = name && not m.md_abstract) k.cl_methods with
                      | Some m -> Some (n, method_at (class_mapping k args) m)
                      | None -> None)
                  | _ -> None)
                (List.tl (all_supers store (cname, self_args)))
            in
            match defaults with
            | [ one ] -> one
            | [] ->
                raise
                  (Type_error
                     (info, Printf.sprintf "nothing above '%s' gives '%s' a body for 'super' to call" (base_name cname) name))
            | (a, _) :: (b, _) :: _ ->
                raise
                  (Type_error
                     ( info,
                       Printf.sprintf "'super.%s' could mean the default of '%s' or of '%s'" name (base_name a) (base_name b) )))
      in
      let owner, m = found in
      let store = check_method_arguments info name m written env store in
      let store = record_resolution store sym (Super_owner (owner, List.map (fun (n, _, d) -> (n, d)) m.md_params)) in
      (zonk m.md_return store, store)

(** The type a class pattern matches, given the subject's type: the
    class at arguments that make it one with the subject, whichever of
    the two is above the other. info -> class_info -> [typ] -> typ ->
    store -> (typ, store) *)
and object_pattern_type info c written subject store =
  let args, store =
    if written <> [] then (written, store) else fresh_metas (List.length c.cl_params) info store
  in
  let mine = TCon (info, c.cl_name, args, 0) in
  let refuse () =
    raise
      (Type_error
         ( info,
           Printf.sprintf "this pattern matches %s, but it is matched against %s, which is never one"
             (shown mine store) (shown subject store) ))
  in
  match prune subject store with
  | TCon (_, sname, sargs, _) when SMap.mem sname store.classes -> (
      let joined =
        match super_as store (c.cl_name, args) sname with
        | Some seen -> unify (TCon (info, sname, seen, 0)) (TCon (info, sname, sargs, 0)) store
        | None -> (
            match super_as store (sname, sargs) c.cl_name with
            | Some seen -> unify mine (TCon (info, c.cl_name, seen, 0)) store
            | None -> None)
      in
      match joined with Some store -> (mine, store) | None -> refuse ())
  | settled when is_meta settled -> (
      match unify settled mine store with Some store -> (mine, store) | None -> refuse ())
  | _ -> refuse ()

(** The store in which a class's body checks: each body field's first
    value, the parent's arguments -- with the header's parameters in scope,
    as in a constructor -- and each method's body, with `self` and its
    parameters in scope and its result what it says.
    info -> class_decl -> env -> store -> store *)
and check_class info c env store =
  let ci = Option.get (class_named store c.c_name) in
  let self_t = self_type info ci in
  let header_env = List.fold_left (fun env (n, t) -> bind env n t) env ci.cl_header in
  let store =
    List.fold_left2
      (fun store (MemberField (_, _, _, _, _, _, fs)) (_, t) -> record store fs t)
      store c.c_header ci.cl_header
  in
  let store =
    List.fold_left
      (fun store (MemberField (_, n, _, v, _, _, fs)) ->
        let t = match List.find_opt (fun f -> f.fd_name = n) ci.cl_fields with Some f -> f.fd_type | None -> t_unknown info in
        let store = record store fs t in
        match v with
        | Some e -> check_wanted e t (Printf.sprintf "the first value of the field '%s'" n) header_env store
        | None -> store)
      store c.c_fields
  in
  let store =
    match (c.c_extends, ci.cl_parent) with
    | Some (ClassRef (ri, _, pname, _, args, rs)), Some (pcanon, pargs) ->
        let p = Option.get (class_named store pcanon) in
        let mapping = class_mapping p pargs in
        if List.length args <> List.length p.cl_header then
          raise
            (Type_error
               ( ri,
                 Printf.sprintf "'%s' takes %d argument%s, but %d %s given" pname (List.length p.cl_header)
                   (if List.length p.cl_header = 1 then "" else "s")
                   (List.length args)
                   (if List.length args = 1 then "was" else "were") ));
        let store =
          List.fold_left2
            (fun store (_, a) (n, t) ->
              check_wanted a (substitute t mapping) (Printf.sprintf "the field '%s' of '%s'" n pname) header_env store)
            store args p.cl_header
        in
        record store rs (TCon (ri, pcanon, pargs, 0))
    | _ -> store
  in
  let store =
    List.fold_left2
      (fun store (ClassRef (ri, _, _, _, _, rs)) (n, args) -> record store rs (TCon (ri, n, args, 0)))
      store c.c_implements ci.cl_interfaces
  in
  List.fold_left
    (fun store (MethodDecl (mi, name, params, _, body, _, _, ms)) ->
      let md = List.find (fun m -> m.md_name = name) ci.cl_methods in
      let store = record store ms (t_function mi (List.map (fun (_, t, _) -> t) md.md_params) md.md_return) in
      let store = List.fold_left2 (fun store (Param (_, _, _, _, ps)) (_, t, _) -> record store ps t) store params md.md_params in
      (* A default is a literal or the call of the def desugar_args made
         of it, checked here so a call that leaves it out can use it. *)
      let store =
        List.fold_left2
          (fun store (Param (_, pn, _, d, _)) (_, t, _) ->
            match d with
            | Some e -> check_wanted e t (Printf.sprintf "the default for '%s'" pn) env store
            | None -> store)
          store params md.md_params
      in
      match body with
      | None -> store
      | Some body ->
          let menv = bind env "self" self_t in
          let menv = List.fold_left2 (fun e (Param (_, n, _, _, _)) (_, t, _) -> bind e n t) menv params md.md_params in
          let unit_result = match md.md_return with TTuple (_, [], _) -> true | _ -> false in
          let inner = { (with_frame store { returns = [] }) with current_class = Some c.c_name } in
          let supplied, inner = check_stmts body menv (Declared md.md_return) None inner in
          let inner =
            if unit_result then inner
            else
              match supplied with
              | None -> inner
              | Some t -> (
                  let last_sym =
                    match List.rev body with SExprStmt (_, e, _) :: _ -> expr_sym e | _ -> 0
                  in
                  match coerced inner last_sym md.md_return t with
                  | Some answer -> answer
                  | None ->
                      raise
                        (Type_error
                           ( mi,
                             Printf.sprintf "the method '%s' has to return %s, but its body ends in a value of type %s"
                               name (shown md.md_return inner) (shown t inner) )))
          in
          learned store inner)
    store c.c_methods

(** Type-checks a function call. expr -> env -> store -> (typ, store) *)
and check_call call env store =
  let method_ =
    match call with
    | ECall (_, (EField (_, obj, name, _) as callee), written, _) -> (
        let obj_type, peeked = check_expr obj env store in
        match prune obj_type peeked with
        | TCon (_, canonical, oargs, _) when SMap.mem canonical peeked.classes -> (
            match lookup_method peeked (canonical, oargs) name with
            | Some found -> Some (check_method_call call found written env peeked)
            | None ->
                if List.exists (fun (n, _) -> n <> None) written then
                  raise
                    (Type_error
                       ( expr_info callee,
                         Printf.sprintf "'%s' has no method '%s', and only a method's arguments are named" canonical name ));
                None)
        | settled when is_meta settled && not (SMap.is_empty peeked.classes) ->
            (* `s.area()` where nothing says what `s` is. *)
            let subject = match obj with EVar (_, n, _) -> Printf.sprintf "'%s'" n | _ -> "this value" in
            raise
              (Type_error
                 ( expr_info callee,
                   Printf.sprintf
                     "nothing here says what class %s is, so there is no telling which method '%s' is meant; \
                      annotate it, as in 'def f(%s: Shape)'"
                     subject name (match obj with EVar (_, n, _) -> n | _ -> "x") ))
        | _ ->
            if List.exists (fun (n, _) -> n <> None) written then
              raise
                (Type_error
                   ( expr_info call,
                     "an argument is named only in a call of a 'def', a method or a constructor, which say \
                      what their parameters are called" ));
            None)
    | _ -> None
  in
  match method_ with
  | Some answer -> answer
  | None ->
  let func, args =
    match call with
    | ECall (_, func, args, _) -> (func, arg_exprs args)
    | _ -> unsupported (expr_info call)
  in
  let builtin =
    match func with
    | EVar (_, name, _) -> (
        match type_of env name with
        | Some (TBuiltin (_, builtin, _)) -> Some builtin
        | _ -> None)
    | _ -> None
  in
  match builtin with
  | Some builtin -> check_builtin_call builtin call env store
  | None -> (
      match func with
      | EVar (_, name, _)
        when List.exists (fun (_, members) -> List.mem name members) Builtin.overload_sets
             && type_of env name <> None ->
          (* A builtin set's member named outright (`fill::array(...)`)
             is resolved as a set of one, so what it reaches is recorded
             as an overloaded call's is. *)
          resolve_overload call name [ (name, Option.get (type_of env name)) ] args env store
      | _ ->
      match candidates_for func env with
      | Some (spelling, candidates) ->
          (* A name that is not bound but has `::` definitions in scope
             is an overloaded call: the arguments say which of them is
             meant (docs/overloading.md). *)
          resolve_overload call spelling candidates args env store
      | None -> (
          let func_type, store = check_expr func env store in
          match settled_type func_type store with
          | TFunction (_, _, _, _, _, Some (SFunctionDef _), _) as deferred ->
              (* Nothing has worked this definition out yet, so this call
                 is what makes it happen. Its body decides its type, and
                 this call is then checked against that like any other. *)
              infer_call deferred call env store
          | settled -> called_at ?about:(definition_named env func) settled call args env store))

(** The overload set a callee names, where it names one: the spelling
    the source wrote, and every `::` definition in scope whose base name
    is that one. A name that *is* bound means itself and nothing else --
    a plain `def` is not a member of any set (docs/overloading.md).
    expr -> env -> (string, [(string, typ)]) option *)
and candidates_for func env =
  let gather spelling fits =
    let found =
      SMap.fold
        (fun bound binding found ->
          if fits bound binding then found @ [ (bound, binding.btype) ]
          else found)
        env []
    in
    if found = [] then None else Some (spelling, found)
  in
  match func with
  | EVar (_, name, _) when not (SMap.mem name env) ->
      if Names.is_qualified name then
        (* `int::leq` written with no module in front, reaching one an
           import brought in: only a public *implicit* arrives that way
           (PYKING.md, "Modules"). *)
        gather name (fun bound binding ->
            binding.bimplicit && imported bound && Names.field bound = name)
      else
        gather name (fun bound binding ->
            let field = Names.field bound in
            Names.is_qualified field
            && Names.base field = name
            && ((not (imported bound)) || binding.bimplicit))
  | EQualified (_, module_, name, _)
    when (not (SMap.mem (module_ ^ "." ^ name) env))
         && not (Names.is_qualified name) ->
      let prefix = module_ ^ "." in
      gather (prefix ^ name) (fun bound _ ->
          imported bound
          && String.length bound > String.length prefix
          && String.sub bound 0 (String.length prefix) = prefix
          && Names.is_qualified (Names.field bound)
          && Names.base (Names.field bound) = name)
  | _ -> None

(** Whether this environment key names something reached through a
    module -- `alias.field` -- rather than one of this file's own.
    string -> Bool *)
and imported bound = String.contains bound '.'

(** One overloaded call. The arguments are checked **once**, and each
    candidate is then tried against the types they turned out to be, in
    a store of its own: the store is a value, so a trial that does not
    fit is discarded by not being kept. Exactly one candidate fitting
    resolves the call; none and several are both errors naming what was
    in scope (docs/overloading.md).
    expr -> string -> [(string, typ)] -> [expr] -> env -> store
    -> (typ, store) *)
and resolve_overload call spelling candidates args env store =
  let info = expr_info call in
  let given, store = check_each args env store in
  let fitting =
    List.filter_map
      (fun (name, scheme) ->
        let used, trial = instantiate scheme store in
        match prune used trial with
        | TFunction (_, params, result, _, _, _, implicits)
          when List.length params = List.length given -> (
            match unify_each given params trial with
            | None -> None
            | Some trial -> Some (name, result, implicits, trial))
        | _ -> None)
      candidates
  in
  match fitting with
  | [ (name, result, implicits, trial) ] ->
      let implicits = map_implicits (fun t -> prune t trial) implicits in
      let supplied, store = discharge info implicits env trial 0 in
      let store =
        record_resolution store (expr_sym call)
          (Call (Some (name, t_function info given (zonk result store)), supplied))
      in
      (result, store)
  | [] -> raise (no_candidate info spelling candidates given store)
  | several -> raise (several_candidates info spelling several given store)

(** The type of the field `field` of a value of type record_type: every
    constructor of its datatype has the field, at one type. Raises
    Type_error otherwise. info -> typ -> string -> store -> (typ, store) *)
and field_type info record_type field store =
  (* A field is read the same way whichever constructor built the
     value, so every constructor of the datatype has to have it, at
     one type. *)
  match prune record_type store with
  | TCon (_, canonical, args, _) -> (
      let (Datatype (_, params, constructors, _)) =
        SMap.find canonical store.datatypes
      in
      let mapping = List.combine params args in
      let found =
        List.map
          (fun (cname, fields) ->
            ( cname,
              Option.map
                (fun (_, t) -> substitute t mapping)
                (List.find_opt (fun (label, _) -> label = Some field) fields) ))
          constructors
      in
      match List.find_opt (fun (_, t) -> t = None) found with
      | Some (cname, _) ->
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "'%s' has no field '%s' in every constructor: '%s' has \
                    none, so a value built by it has nothing to read"
                   (base_name canonical) field cname ))
      | None -> (
          match List.map (fun (_, t) -> Option.get t) found with
          | [] ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf "'%s' has no constructors" canonical ))
          | first :: rest ->
              let store =
                List.fold_left
                  (fun store other ->
                    match unify first other store with
                    | Some store -> store
                    | None ->
                        raise
                          (Type_error
                             ( info,
                               Printf.sprintf
                                 "the field '%s' of '%s' has a different \
                                  type in different constructors (%s and \
                                  %s), so reading it has no one type"
                                 field (base_name canonical)
                                 (shown first store) (shown other store) )))
                  store rest
              in
              (zonk first store, store)))
  | settled when is_meta settled ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "nothing here says what datatype this value is, so there \
                is no telling which field '%s' is meant; annotate it"
               field ))
  | settled ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "'.%s' reads a field of a datatype, but this value is %s"
               field (shown settled store) ))

(** Why no definition of an overloaded name fits these arguments.
    info -> string -> [(string, typ)] -> [typ] -> store -> exn *)
and no_candidate info spelling candidates given store =
  Type_error
    ( info,
      Printf.sprintf
        "no definition of '%s' takes (%s); the ones in scope are %s"
        spelling
        (String.concat ", " (List.map (fun t -> shown t store) given))
        (String.concat ", "
           (List.map
              (fun (name, scheme) ->
                Printf.sprintf "'%s' of type %s" name (shown scheme store))
              candidates)) )

(** Why several definitions of an overloaded name fit. An argument type
    nothing has decided fits every candidate, and saying *that* is worth
    more than listing them (docs/overloading.md).
    info -> string -> [(string, typ, [implicit_param], store)] -> [typ]
    -> store -> exn *)
and several_candidates info spelling fitting given store =
  let named =
    String.concat " and "
      (List.map (fun (name, _, _, _) -> Printf.sprintf "'%s'" name) fitting)
  in
  let undecided =
    List.exists (fun type_ -> is_meta (prune type_ store)) given
  in
  Type_error
    ( info,
      if undecided then
        Printf.sprintf
          "nothing here decides which '%s' is meant: %s all take these \
           arguments, and the type of at least one of them is still open. \
           Annotate it, or take the definition as an implicit parameter"
          spelling named
      else
        Printf.sprintf
          "this call to '%s' is ambiguous: %s all take these arguments, so \
           write the one that is meant"
          spelling named )

(** The arguments one call's implicit parameters resolve to, in order.
    info -> [implicit_param] -> env -> store -> int
    -> ([argument], store) *)
and discharge info implicits env store depth =
  List.fold_left
    (fun (found, store) (IParam (name, wanted)) ->
      let one, store = resolve_implicit info name wanted env store depth in
      (found @ [ one ], store))
    ([], store) implicits

(** The one implicit binding in scope that fits this parameter, and the
    store in which it does.

    The search is by name and by type: every *implicit* binding whose
    base name is this one is tried, and its own implicit parameters --
    which it does not carry across -- become obligations discharged here,
    in the scope of the call (docs/implicits.md). A non-implicit binding
    is never considered, which is what keeps a value from being captured
    by accident.
    info -> string -> typ -> env -> store -> int -> (argument, store) *)
and resolve_implicit info name wanted env store depth =
  if depth > max_implicit_depth then
    raise
      (Type_error
         ( info,
           Printf.sprintf
             "resolving the implicit '%s' went %d deep and did not stop; \
              an implicit that needs one of its own kind cannot go round \
              for ever"
             name max_implicit_depth ));
  let wanted = zonk wanted store in
  let fitting =
    SMap.fold
      (fun bound binding found ->
        if binding.bimplicit && Names.base (Names.field bound) = name then
          let used, trial = instantiate binding.btype store in
          let stripped, obligations =
            match prune used trial with
            | TFunction (i, params, result, sym, tmsym, definition, implicits)
              when implicits <> [] ->
                ( TFunction (i, params, result, sym, tmsym, definition, []),
                  implicits )
            | other -> (other, [])
          in
          match unify stripped wanted trial with
          | None -> found
          | Some trial -> found @ [ (bound, obligations, trial) ]
        else found)
      env []
  in
  match fitting with
  | [ (bound, [], store) ] -> (Direct (bound, zonk wanted store), store)
  | [ (bound, obligations, store) ] ->
      (* The candidate takes implicit arguments of its own and is being
         passed where a plain function type is wanted, so what is passed
         is a lambda that supplies them -- the dictionary, built here
         and emitted by elaborate.ml. *)
      let obligations = map_implicits (fun t -> prune t store) obligations in
      let inner, store = discharge info obligations env store (depth + 1) in
      let wanted = zonk wanted store in
      (Wrapped (bound, wanted, arity wanted, inner), store)
  | [] -> raise (no_implicit info name wanted env store)
  | several ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "the implicit '%s' of type %s is ambiguous here: %s all fit"
               name (shown wanted store)
               (String.concat " and "
                  (List.map
                     (fun (bound, _, _) -> Printf.sprintf "'%s'" bound)
                     several)) ))

(** Why no implicit binding fits. Names a binding of the right name that
    is not implicit, since that is the mistake worth pointing at.
    info -> string -> typ -> env -> store -> exn *)
and no_implicit info name wanted env store =
  let shadowing =
    SMap.exists
      (fun bound binding ->
        (not binding.bimplicit) && Names.base (Names.field bound) = name)
      env
  in
  Type_error
    ( info,
      Printf.sprintf "no implicit '%s' of type %s is in scope here%s" name
        (shown wanted store)
        (if shadowing then
           Printf.sprintf
             "; there is a '%s', but it is not declared 'implicit', and only \
              an implicit definition may be resolved to"
             name
         else "") )

(** A call to a builtin -- print, string, len, range or a conversion --
    checked by its own rule since
    none of them has a TFunction type (PYKING.md, "Builtins").
    string -> expr -> env -> store -> (typ, store) *)
and check_builtin_call name call env store =
  let info, args = match call with
    | ECall (info, _, args, _) -> (info, arg_exprs args)
    | _ -> (expr_info call, [])
  in
  let types, store = check_each args env store in
  let types = List.map (fun t -> zonk t store) types in
  let given = List.length args in
  match (name, types) with
  | ("print" | "debug"), _ -> (unit_type info, store)
  | "string", [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KInt; KFloat; KString; KChar; KBool; KList; KTuple; KData ])
      then
        raise
          (builtin_argument_error name (List.hd args) value
             "Int, Float, String, Char, Bool, a list, a tuple or a datatype");
      (t_string info, store)
  | ("int" | "float" | "bool"), [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KInt; KFloat; KString; KChar; KBool ]) then
        raise
          (builtin_argument_error name (List.hd args) value
             "Int, Float, String, Char or Bool");
      ( (match name with
        | "int" -> t_int info
        | "float" -> t_float info
        | _ -> t_bool info),
        store )
  | "char", [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KInt; KString; KChar ]) then
        raise
          (builtin_argument_error name (List.hd args) value "Int, String or Char");
      (t_char info, store)
  | "len", [ value ] ->
      check_builtin_arity name info given;
      if not (every value [ KList; KString; KArray; KDynArray; KMutMap; KSlice ]) then
        raise
          (builtin_argument_error name (List.hd args) value
             "a list, an array, a DynArray, a MutMap, a view or a String");
      (t_int info, store)
  | ("remove" | "clear" | "discard" | "get" | "has" | "keys" | "values" | "items"), first :: _
    when mutmap_parts (prune first store) <> None
         || List.mem name [ "discard"; "get"; "has"; "keys"; "values"; "items" ] ->
      (* A MutMap's builtins (PYKING.md, "MutMaps"): the first argument is
         one, a key is its key type, a default its value type. One
         nothing has decided is a MutMap. *)
      check_builtin_arity name info given;
      let key, value, store =
        match mutmap_parts (prune first store) with
        | Some (key, value) -> (key, value, store)
        | None -> (
            let key, store = fresh_meta info store in
            let value, store = fresh_meta info store in
            match unify (t_mutmap info key value) first store with
            | Some store -> (key, value, store)
            | None -> raise (builtin_argument_error name (List.hd args) first "a MutMap"))
      in
      let expect store position wanted what =
        match unify wanted (List.nth types position) store with
        | Some store -> store
        | None -> raise (builtin_argument_error name (List.nth args position) (List.nth types position) what)
      in
      let store =
        if List.mem name [ "remove"; "discard"; "get"; "has" ] then (
          let store = expect store 1 key (Printf.sprintf "%s, the MutMap's key type" (shown key store)) in
          demand_key (expr_info (List.nth args 1)) key store;
          store)
        else store
      in
      let store =
        if name = "get" then expect store 2 value (Printf.sprintf "%s, the MutMap's value type" (shown value store))
        else store
      in
      ( (match name with
        | "remove" | "get" -> zonk value store
        | "has" -> t_bool info
        | "keys" -> t_list info (zonk key store)
        | "values" -> t_list info (zonk value store)
        | "items" -> t_list info (t_tuple info [ zonk key store; zonk value store ])
        | _ -> unit_type info),
        store )
  | "view", [ first; _; _ ] ->
      (* `view(a, i, j)`: elements i up to j of an array or of a view of
         one, shared with it (PYKING.md, "Slices"). *)
      check_builtin_arity name info given;
      let element, store = fresh_meta info store in
      let store =
        match prune first store with
        | settled when slice_element settled <> None ->
            Option.get (unify (t_slice info element) settled store)
        | _ -> (
            match unify (t_array info element) first store with
            | Some store -> store
            | None -> raise (builtin_argument_error name (List.hd args) first "an array or a view"))
      in
      let store =
        List.fold_left
          (fun store position ->
            match unify (t_int info) (List.nth types position) store with
            | Some store -> store
            | None -> raise (builtin_argument_error name (List.nth args position) (List.nth types position) "Int"))
          store [ 1; 2 ]
      in
      (t_slice info (zonk element store), store)
  | "copy_into", [ first; second ] ->
      (* `copy_into(dst, src)`: src's elements written over dst's first
         ones, as memmove copies -- right where the two overlap. Each is
         an array or a view, of one element type. *)
      check_builtin_arity name info given;
      let element, store = fresh_meta info store in
      let store =
        List.fold_left2
          (fun store argument actual ->
            match prune actual store with
            | settled when slice_element settled <> None -> (
                match unify (t_slice info element) settled store with
                | Some store -> store
                | None -> raise (builtin_argument_error name argument actual "an array or a view of one element type"))
            | _ -> (
                match unify (t_array info element) actual store with
                | Some store -> store
                | None -> raise (builtin_argument_error name argument actual "an array or a view of one element type")))
          store args [ first; second ]
      in
      (unit_type info, store)
  | ("push" | "pop" | "insert" | "remove" | "clear"), first :: rest ->
      (* A writer changes a DynArray (PYKING.md, "DynArrays"): its first argument
         is one, an index is an Int, and a value is the element type. One
         nothing has decided is a DynArray. *)
      check_builtin_arity name info given;
      let element, store = fresh_meta info store in
      let store =
        match unify (t_dynarray info element) first store with
        | Some store -> store
        | None -> raise (builtin_argument_error name (List.hd args) first "a DynArray")
      in
      let expect store position wanted what =
        match unify wanted (List.nth types position) store with
        | Some store -> store
        | None -> raise (builtin_argument_error name (List.nth args position) (List.nth types position) what)
      in
      let element_text store = Printf.sprintf "%s, the DynArray's element type" (shown element store) in
      let store =
        match (name, rest) with
        | "push", [ _ ] -> expect store 1 element (element_text store)
        | "insert", [ _; _ ] ->
            let store = expect store 1 (t_int info) "Int, an index" in
            expect store 2 element (element_text store)
        | "remove", [ _ ] -> expect store 1 (t_int info) "Int, an index"
        | _ -> store
      in
      ((match name with "pop" | "remove" -> zonk element store | _ -> unit_type info), store)
  | "same", [ first; second ] ->
      (* Whether two values are one: identity, which `==` does not ask
         (PYKING.md, "Arrays", "Mutable structs"). Both are arrays of one
         element type, or both one `var struct` -- the values that have
         an identity; one nothing has decided is an array. *)
      check_builtin_arity name info given;
      let wanted = "two arrays, DynArrays, MutMaps, views, var structs or objects, of one type" in
      let identity settled =
        match settled with
        | TCon (_, c, _, _) when List.mem c [ array_name; dynarray_name; mutmap_name; slice_name ] -> true
        | TCon (_, c, _, _) when SMap.mem c store.classes -> true
        | TCon (_, c, _, _) -> (
            match SMap.find_opt c store.datatypes with
            | Some (Datatype (_, _, _, writable)) -> writable
            | None -> false)
        | _ -> false
      in
      (* Two objects are compared where either's class is above the
         other's: a Shape may be the very Square it is asked about. *)
      let related =
        match (prune first store, prune second store) with
        | TCon (_, a, aargs, _), TCon (_, b, bargs, _) when SMap.mem a store.classes && SMap.mem b store.classes ->
            super_as store (a, aargs) b <> None || super_as store (b, bargs) a <> None
        | _ -> false
      in
      let store =
        match unify first second store with
        | Some store -> store
        | None when related -> store
        | None -> raise (builtin_argument_error name (List.nth args 1) second wanted)
      in
      let store =
        match prune first store with
        | settled when is_meta settled -> (
            let element, store = fresh_meta info store in
            match unify (t_array info element) settled store with
            | Some store -> store
            | None -> store)
        | settled when identity settled -> store
        | _ -> raise (builtin_argument_error name (List.hd args) first wanted)
      in
      (t_bool info, store)
  | "range", _ ->
      check_builtin_arity name info given;
      List.iter2
        (fun argument actual ->
          if not (every actual [ KInt ]) then
            raise (builtin_argument_error name argument actual "Int"))
        args types;
      (t_list info (t_int info), store)
  | _ ->
      (* A builtin with the wrong number of arguments reaches here for
         `string`, `len` and the conversions, whose cases ask for exactly
         one; the arity check says which and how many. *)
      check_builtin_arity name info given;
      unsupported info

(** One call to something of known type: the type it is worth, and the
    store in which the arguments fit its parameters.

    The scheme is *instantiated* first, so a polymorphic function is used
    at one of its instances and each call picks its own -- which is what
    lets one definition serve two callers at two types. Each argument is
    then unified with its parameter, left to right, so the first mistake
    is the one reported.
    typ -> expr -> [expr] -> env -> store -> (typ, store) *)
and called_at ?about scheme call args env store =
  let info = expr_info call in
  let used, store = instantiate scheme store in
  let used = prune used store in
  let used, store =
    if is_meta used then
      (* Calling something nothing has decided is what decides it: it is
         a function of this many arguments, and the arguments and the
         result say the rest. This is the one place a type is *built* by
         a demand rather than compared against one. *)
      let made, store = fresh_metas (List.length args + 1) info store in
      let rec split seen = function
        | [ last ] -> (List.rev seen, last)
        | one :: rest -> split (one :: seen) rest
        | [] -> ([], t_unknown info)
      in
      let params, result = split [] made in
      let built = t_function info params result in
      let store =
        match unify (prune scheme store) built store with
        | Some store -> store
        | None -> store
      in
      (built, store)
    else (used, store)
  in
  match used with
  | TFunction (_, params, result, _, _, _, implicits)
    when implicits <> []
         && List.length args = List.length params + List.length implicits ->
      (* Every implicit argument written out at the call: nothing is
         resolved and nothing is inserted, since they are already where
         they belong (PYKING.md, "Implicits"). *)
      (result, check_arguments ?about args (params @ implicit_types implicits) env store 1)
  | TFunction (_, params, result, _, _, _, implicits) ->
      if List.length args <> List.length params then
        raise
          (Type_error
             ( info,
               Printf.sprintf
                 "this function takes %d argument%s, but %d %s given"
                 (List.length params)
                 (if List.length params = 1 then "" else "s")
                 (List.length args)
                 (if List.length args = 1 then "was" else "were") ));
      let store = check_arguments ?about args params env store 1 in
      (* Whatever was called -- a definition, a parameter holding one,
         a binding -- its implicit parameters are resolved here, where
         the call is written. That is what lets a function carrying one
         be passed as a value and called somewhere else (PYKING.md,
         "Implicits"). *)
      if implicits = [] then (result, store)
      else
        let implicits = map_implicits (fun t -> prune t store) implicits in
        let supplied, store = discharge info implicits env store 0 in
        (result, record_resolution store (expr_sym call) (Call (None, supplied)))
  | _ ->
      raise
        (Type_error
           ( info,
             Printf.sprintf
               "this call applies something of type %s, which is not a \
                function"
               (shown used store) ))

(** Checks each argument against its parameter, left to right (so the
    first mistake is the one reported), and answers the store in which
    they fit. [expr] -> [typ] -> env -> store -> int -> store *)
and check_arguments ?about args declared env store position =
  match (args, declared) with
  | [], _ -> store
  | arg :: rest, expected :: rest_declared ->
      let store =
        match arg with
        | (EList (_, _ :: _, _) | ETuple (_, _ :: _, _) | EIf _) when mentions_object store expected ->
            check_wanted arg expected (Printf.sprintf "argument %d" position) env store
        | _ ->
            let actual, store = check_expr arg env store in
            fitted ?about expected actual arg position env store
      in
      check_arguments ?about rest rest_declared env store (position + 1)
  | _ :: _, [] -> store

(** The store in which one argument fits one parameter, or a Type_error
    naming both.

    An argument that is itself polymorphic is *instantiated* wherever the
    parameter is not written polymorphic: every instance of it exists, so
    it stands where one of them is wanted, and it is the instance that
    has to fit. Where the parameter *is* written `(all a. ...)` the
    argument has to be that scheme whole, which is first-class
    polymorphism and the one place the two are compared as schemes.
    typ -> typ -> expr -> int -> store -> store *)
and fitted ?about expected actual arg position env store =
  (* The kind variables the parameter holds, read before `prune` turns a
     decided one into its type: a call deciding one is remembered, and a
     call disagreeing with one is told which call decided it. *)
  let kinds = kind_names_in expected store in
  let settled = prune expected store in
  let store = work_out actual store in
  let actual = settled_type actual store in
  let actual, store =
    if is_forall settled then (actual, store) else instantiate actual store
  in
  let key, subject =
    match about with
    | Some (name, Some params) when position <= List.length params ->
        (Printf.sprintf "%s#%d" name position, Printf.sprintf "%s's parameter %s" name (List.nth params (position - 1)))
    | Some (name, _) -> (Printf.sprintf "%s#%d" name position, Printf.sprintf "%s's argument %d" name position)
    | None -> ("", "")
  in
  match unify settled actual store with
  | Some answer ->
      if kinds = [] || key = "" then answer else remember_kinds kinds (expr_info arg) key subject answer
  | None when coerced store (expr_sym arg) settled actual <> None -> Option.get (coerced store (expr_sym arg) settled actual)
  | None -> (
      match adapted arg actual settled env store with
      | Some answer -> answer
      | None ->
          raise
            (argument_error
               ~note:(if key = "" then "" else kind_note key subject actual settled store)
               position actual settled arg store))

(** The store in which an argument carrying implicit parameters fits a
    parameter that has none, by supplying them *here*.

    A function whose type says `implicit my` is called with `my`
    resolved where the call is written; handing it somewhere that wants
    an ordinary function is the same demand one step earlier, so the
    implicits are resolved at this position and what is passed is a
    lambda that supplies them -- the same adaptation
    `resolve_implicit` makes for an implicit argument
    (docs/implicits.md, "The dictionary"). None where this argument is
    not that case, and the caller then reports the mismatch it has.
    expr -> typ -> typ -> env -> store -> store? *)
and adapted arg actual wanted env store =
  match (prune actual store, prune wanted store) with
  | ( TFunction (info, params, result, sym, tmsym, definition, implicits),
      TFunction (_, wanted_params, _, _, _, _, []) )
    when implicits <> [] && List.length params = List.length wanted_params -> (
      (* More implicit parameters than are wanted: they are supplied
         here, and the lambda hands on everything it is given. *)
      let stripped =
        TFunction (info, params, result, sym, tmsym, definition, [])
      in
      match unify (prune wanted store) stripped store with
      | None -> None
      | Some store ->
          let implicits = map_implicits (fun t -> prune t store) implicits in
          let supplied, store =
            try discharge (expr_info arg) implicits env store 0
            with Type_error (where, message) ->
              raise (Type_error (where, resolved_here message arg))
          in
          let wanted = zonk (prune wanted store) store in
          Some
            (record_resolution store (expr_sym arg)
               (Adapted (wanted, arity wanted, supplied))))
  | ( TFunction (info, params, result, sym, tmsym, definition, []),
      TFunction (_, wanted_params, _, _, _, _, (_ :: _ as wanted_implicits)) )
    when List.length params = List.length wanted_params -> (
      (* Fewer: the value does not ask for what is offered, so the
         lambda takes the implicit arguments and hands on only the
         explicit ones. A function that needs less stands wherever one
         that needs more is wanted. *)
      let filled =
        TFunction (info, params, result, sym, tmsym, definition, wanted_implicits)
      in
      match unify (prune wanted store) filled store with
      | None -> None
      | Some store ->
          let wanted = zonk (prune wanted store) store in
          Some
            (record_resolution store (expr_sym arg)
               (Adapted (wanted, List.length wanted_params, []))))
  | _ -> None

(** Why an implicit an adapted argument needs could not be found, said
    where the mistake usually is: the parameter it is passed to has no
    implicit of its own, so the search happened here rather than
    wherever that parameter is called (docs/implicits.md).
    String -> expr -> String *)
and resolved_here message arg =
  let what =
    match arg with
    | EVar (_, name, _) -> Printf.sprintf "'%s'" name
    | EQualified (_, module_, field, _) ->
        Printf.sprintf "'%s.%s'" module_ field
    | _ -> "this argument"
  in
  Printf.sprintf
    "%s. %s takes it implicitly and the parameter it is passed to does \
     not, so it is resolved here rather than where that parameter is \
     called; write the implicit into that parameter's own type to have it \
     resolved there instead"
    message what

(** The store in which this definition has a scheme: `infer_call` without
    the call. What makes it happen is usually a call, but a definition
    handed somewhere a type is written down is worked out there instead --
    the body receiving it will not reach it again, so that is the only
    place the two can be compared for real. typ -> store -> store *)
and work_out func_type store =
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _), _)
    when instance_of store tmsym = None
         && not (IntSet.mem tmsym store.checking) ->
      let _, store = infer_definition func_type store in
      store
  | _ -> store

(** The name a call reaches a function by, and its parameters' names
    where the name is bound to a definition. None for a callee that is
    not a name. env -> expr -> (string * [string] option) option *)
and definition_named env func =
  match func with
  | EVar (_, name, _) -> (
      match type_of env name with
      | Some
        (TFunction (_, _, _, _, _, Some (SFunctionDef (_, _, params, _, _, _, _, _, _)), _)) ->
          Some (name, Some (List.map (fun (Param (_, p, _, _, _)) -> p) params))
      | _ -> Some (name, None))
  | _ -> None

(** The type this call is worth, working the definition out first.
    typ -> expr -> env -> store -> (typ, store) *)
and infer_call func_type call env store =
  let args =
    match call with ECall (_, _, args, _) -> arg_exprs args | _ -> []
  in
  let _, store = infer_definition func_type store in
  let func = match call with ECall (_, func, _, _) -> Some func | _ -> None in
  let about = Option.bind func (definition_named env) in
  called_at ?about (settled_type func_type store) call args env store

(** The scheme an unannotated function has, worked out from its body the
    first time something calls it and remembered afterward.

    The body decides it, not this call: every parameter goes in as a
    metavariable and the body's own demands are what solve them. So the
    answer is the definition's principal type, and this call is then
    checked against it like a call to anything else.
    typ -> store -> (typ, store) *)
and infer_definition func_type store =
  match func_type with
  | TFunction (_, _, _, _, tmsym, Some (SFunctionDef _ as node), _) ->
      (* The environment the function was *written* in -- not this
         call's. `declare_functions` always records it, and the `def`
         statement sharpens it to the position; the fallback is for a
         caller that somehow checked a call before the definition was
         declared, where the builtins are at least in scope. *)
      let body_env =
        match environment_of store tmsym with
        | Some written -> written
        | None -> builtin_env ()
      in
      (* Every `def` of the block this one is in is worked out together,
         because they may name each other: each is bound to a *monotype*
         while the group's bodies are checked, and generalised only once
         all of them are done. That is the whole of recursion here -- a
         recursive call is an ordinary call to a type already in scope --
         and it is the rule Hindley-Milner applies to a `let rec`
         group. *)
      let group = inference_group node store in
      let monotypes, inner = monotypes_for group store in
      let inner = with_frame inner { returns = [] } in
      let inner =
        List.fold_left
          (fun inner other -> checking_now inner (stmt_sym other))
          inner group
      in
      let inner =
        List.fold_left2
          (fun inner other mono ->
            (* In the scope *it* was written in, never the group's or the
               caller's: what a body captures is what was bound where it
               stands (PYKING.md, "Names and scoping"). *)
            let group_env =
              match environment_of store (stmt_sym other) with
              | Some written -> written
              | None -> body_env
            in
            let group_env =
              List.fold_left2
                (fun group_env sibling sibling_mono ->
                  bind group_env (def_name sibling) sibling_mono)
                group_env group monotypes
            in
            let mono_params =
              match mono with
              | TFunction (_, params, _, _, _, _, _) -> params
              | _ -> []
            in
            let group_env =
              List.fold_left2
                (fun group_env param type_ ->
                  bind group_env (param_name param) type_)
                group_env (def_params other) mono_params
            in
            let supplied, inner = body_result other group_env inner in
            let mono_result =
              match mono with
              | TFunction (_, _, result, _, _, _, _) -> result
              | _ -> mono
            in
            required inner mono_result supplied other)
          inner group monotypes
      in
      let store = learned store inner in
      (* A `+` the bodies left open is not generalised over: a type
         variable would have to add and join at once. Its operands stay
         one type, which the definition's first use decides -- a call
         passing Strings -- and what nothing decides is an Int once the
         module is done (`settle_plus`). *)
      let undecided =
        List.fold_left
          (fun found (operand, _) ->
            match zonk operand store with
            | TVar (_, name, _, false) -> StringSet.add name found
            | _ -> found)
          StringSet.empty store.pending_plus
      in
      (* Generalise the whole group and remember every scheme *before*
         verifying any of them: a body re-checked while a name it calls
         is still unworked would work that one out all over again, which
         for two functions that call each other never ends. *)
      let store, schemes =
        List.fold_left2
          (fun (store, schemes) other mono ->
            let outer =
              StringSet.union undecided
                (free_metas
                   (match environment_of store (stmt_sym other) with
                   | Some written -> written
                   | None -> body_env)
                   store)
            in
            (* What this definition may not generalise, remembered so the
               printed output does not claim it did. *)
            let store =
              {
                store with
                captured =
                  StringSet.union store.captured
                    (StringSet.inter outer
                       (List.fold_left
                          (fun s m -> StringSet.add m s)
                          StringSet.empty (metas_in mono store)));
              }
            in
            (* A def written inside this one that holds this one's
               variables has already named its own, and its type then
               names both. *)
            let own = metas_in (zonk mono store) store in
            let avoid =
              Walk.fold_stmts
                (fun found node ->
                  match node with
                  | Walk.NStmt (SFunctionDef (_, _, _, _, _, sym, _, _, _)) -> (
                      match IntMap.find_opt sym store.instances with
                      | Some (TForall (_, vars, body, _))
                        when List.exists (fun m -> List.mem m own) (metas_in body store) ->
                          List.fold_left (fun s v -> StringSet.add v s) found vars
                      | _ -> found)
                  | _ -> found)
                StringSet.empty (def_body other)
            in
            ( store,
              schemes @ [ (generalise ~avoid other (zonk mono store) outer store, outer) ] ))
          (store, []) group monotypes
      in
      let outers = List.map snd schemes in
      let schemes = List.map fst schemes in
      let store =
        List.fold_left2
          (fun store other scheme -> remembering store (stmt_sym other) scheme)
          store group schemes
      in
      let store =
        List.fold_left2
          (fun store ((other, scheme), outer) mono ->
            let settled, store = verifying other scheme mono store in
            (* A scheme the body holds to is what the body's own types
               mean: each variable it generalised is that variable from
               here on, so a type recorded inside the body -- a nested
               def's among them -- reads back in the scheme's own
               variables rather than as one nothing settled. *)
            let store =
              match settled with
              | TForall (_, names, _, _) when settled == scheme ->
                  let open_metas =
                    List.filter
                      (fun meta -> not (StringSet.mem meta outer))
                      (metas_in (zonk mono store) store)
                  in
                  if List.length open_metas <> List.length names then store
                  else
                    List.fold_left2
                      (fun store meta name ->
                        if SMap.mem meta store.solutions then store
                        else
                          (* One a definition inside could not generalise
                             is still written `?` where that definition's
                             own types are printed. *)
                          let marked = if StringSet.mem meta store.captured then -1 else 0 in
                          solving store meta (TVar (stmt_info other, name, marked, true)))
                      store open_metas names
              | _ -> store
            in
            let store = remembering store (stmt_sym other) settled in
            let store = record store (stmt_sym other) settled in
            match instantiated settled with
            | _, TFunction (_, params, _, _, _, _, _) ->
                List.fold_left2
                  (fun store param type_ ->
                    record store (param_sym param) type_)
                  store (def_params other) params
            | _ -> store)
          store
          (List.combine (List.combine group schemes) outers)
          monotypes
      in
      (settled_type func_type store, store)
  | _ -> (func_type, store)

(** What a function's body supplies: every `return` in it and the value it
    ends in, which have to be one type.
    stmt -> env -> store -> (typ option, store) *)
and body_result node env store =
  let started = with_frame store { returns = [] } in
  let supplied, ended = supplied_type node env Inferring started in
  let collected = ended.frame.returns in
  let collected =
    match supplied with
    | None -> collected
    (* The body's tail position supplies a value too, and it answers the
       same question a `return` does (PYKING.md, "Tail position"). *)
    | Some supplied ->
        let body = def_body node in
        let last = List.nth body (List.length body - 1) in
        collected
        @ [ { given_info = stmt_info last; given_type = supplied } ]
  in
  let restored = with_frame ended { returns = store.frame.returns } in
  if collected = [] then (None, restored)
  else
    let type_, store = one_type collected (def_name node) restored in
    (Some type_, store)

(** What a function body supplies: its last statement's value.
    stmt -> env -> expected -> store -> (typ option, store) *)
and supplied_type node env return_type store =
  (* A body is checked with no enclosing loop: a `break` may not cross a
     `def`, so one written here belongs to nothing. *)
  check_stmts (def_body node) env return_type None store

(** Whether a body really does have the scheme that was worked out for
    it, decided by checking it again with the variables **rigid** --
    which is the check an annotated polymorphic function gets, so what
    this accepts is exactly what the checker enforces. Answers the table
    that check filled, so the scheme is what the body's own nodes are
    reported as, or None where it does not hold.

    Unification is sound, so this should never refuse anything; it is
    kept because it costs one pass and it makes "a type this checker
    reports is one it enforces" true by construction rather than by
    argument (docs/type_inference.md, "Verification").
    stmt -> typ -> store -> typ IntMap.t option *)
and verified node scheme store =
  let _, written = instantiated scheme in
  match written with
  | TFunction (_, written_params, result, _, _, _, _)
    when List.length written_params = List.length (def_params node) -> (
      let env =
        match environment_of store (stmt_sym node) with
        | Some written_in -> written_in
        | None -> builtin_env ()
      in
      (* Its own name means the scheme while its body is checked, so a
         recursive call is an ordinary call to a polymorphic function. *)
      let env = bind env (def_name node) scheme in
      let env =
        List.fold_left2
          (fun env param type_ -> bind env (param_name param) type_)
          env (def_params node) written_params
      in
      (* The table this check fills is its own, and so is everything else
         it works out: only the table is kept. *)
      let probe_store = { store with tmap = IntMap.empty } in
      match
        try Some (supplied_type node env (Declared result) probe_store)
        with Type_error _ | Analyses.Analysis_error _ -> None
      with
      | None -> None
      | Some (supplied, after) ->
          if satisfies result supplied after = None then None
          else
            (* Read back through the check's own solutions: those are
               dropped with the rest of what it worked out, and a
               metavariable left in the table would later be read as one
               a different check solved under the same number. *)
            let probe =
              List.fold_left2
                (fun probe param type_ ->
                  IntMap.add (param_sym param) type_ probe)
                (IntMap.map (fun t -> zonk t after) after.tmap)
                (def_params node) written_params
            in
            Some (IntMap.add (stmt_sym node) scheme probe))
  | _ -> None

(** node's scheme, once checking its body against it has said so, or the
    scheme with its variables left as the metavariables they came from
    where the check does not hold.

    That fallback is not a failure but the one thing unification cannot
    express: a body whose demands are *ad-hoc* rather than parametric --
    `string(x)`, which accepts six types and no one type -- generalises to
    a promise it cannot keep, the re-check with `x` rigid says so, and
    the definition stays open for its first call to settle
    (docs/type_inference.md, "What is left of ad-hoc polymorphism").
    stmt -> typ -> typ -> store -> (typ, store) *)
and verifying node scheme mono store =
  match verified node scheme store with
  | None -> (zonk mono store, store)
  | Some probe ->
      (* A def nested in this body is only declared by the re-check, not
         worked out again: what the first check worked out stands. *)
      let rec unknown t =
        match t with
        | TUnknown _ -> true
        | TList (_, e, _) -> unknown e
        | TTuple (_, es, _) | TCon (_, _, es, _) -> List.exists unknown es
        | TFunction (_, ps, r, _, _, _, _) -> List.exists unknown ps || unknown r
        | TForall (_, _, b, _) -> unknown b
        | _ -> false
      in
      let merged =
        IntMap.union
          (fun _ probed first -> if unknown probed then Some first else Some probed)
          probe store.tmap
      in
      (scheme, { store with tmap = merged })

(** Checks a fully annotated def's body against its declared types.
    Always yields unit, whatever the function's own type is: a def is a
    statement. stmt -> env -> store -> (typ option, store) *)
and check_function node env store =
  let ftype = function_type node store in
  (* The body is checked at the *quantified* variables themselves, not at
     anything they might be instantiated to: a TVar is `same_type` only
     with itself, so a body that assumes `a` is an Int is refused here
     rather than at some call. That is the whole of skolemization. *)
  let _, written = instantiated ftype in
  let param_types, result_type, written_implicits =
    match written with
    | TFunction (_, params, result, _, _, _, implicits) ->
        (params, result, implicits)
    | _ -> ([], written, [])
  in
  let store =
    List.fold_left2
      (fun store param type_ ->
        let _, store = check_param param type_ store in
        store)
      store (def_params node) param_types
  in
  let store = record store (stmt_sym node) ftype in
  (* env already binds every def of this block (`declare_functions`); the
     parameters shadow over that, as analyses.ml binds them. *)
  let body_env =
    List.fold_left2
      (fun body_env param type_ -> bind body_env (param_name param) type_)
      env (def_params node) param_types
  in
  (* An implicit parameter is an implicit binding in the body, which is
     what lets a definition discharge its own recursive call's implicit
     against the one it was given (docs/implicits.md). *)
  let body_env, store =
    List.fold_left2
      (fun (body_env, store) param (IParam (_, type_)) ->
        let _, store = check_param param type_ store in
        (bind ~implicit:true body_env (param_name param) type_, store))
      (body_env, store) (def_implicits node) written_implicits
  in
  (* The body's last statement is in tail position; `check_stmt` already
     answers what it supplies, by return or by value (PYKING.md). *)
  let supplied, store =
    check_stmts (def_body node) body_env (Declared result_type) None store
  in
  (* A body ending in an object of a class below the declared result is
     an upcast there. *)
  let tail_upcast =
    match (supplied, List.rev (def_body node)) with
    | Some t, SExprStmt (_, e, _) :: _ -> coerced store (expr_sym e) result_type t
    | _ -> None
  in
  match (match tail_upcast with Some answer -> Some answer | None -> satisfies result_type supplied store) with
  | Some answer -> (Some (unit_type (stmt_info node)), answer)
  | None -> (
      match supplied with
      | Some supplied when is_unit supplied ->
          raise
            (Type_error
               ( stmt_info node,
                 Printf.sprintf
                   "'%s' returns %s, so its body must return on every path, \
                    or end in an expression of that type"
                   (def_name node) (shown result_type store) ))
      | _ ->
          let body = def_body node in
          let last = List.nth body (List.length body - 1) in
          raise
            (Type_error
               ( stmt_info last,
                 Printf.sprintf
                   "'%s' returns %s, but its body ends in a value of type %s"
                   (def_name node) (shown result_type store)
                   (shown (Option.get supplied) store) )))

(** A parameter's declared type, recorded under its symbol. The type is
    passed in rather than read off the node, since a `def` with a
    signature line writes no annotation on the parameter itself.
    param -> typ -> store -> (typ, store) *)
and check_param param type_ store = (type_, record store (param_sym param) type_)

(** The environment a comprehension's clauses leave for its element
    expression. Each `for` binds over the elements of its sequence and
    the ones after it see those bindings; each `if` is checked in
    whatever is in scope by then.
    [comp_clause] -> env -> store -> (env, store) *)
and check_clauses clauses env store =
  List.fold_left
    (fun (env, store) clause ->
      match clause with
      | CompFor (info, pattern, sequence, _) ->
          let sequence_type, store = check_expr sequence env store in
          let element, store =
            demand_sequence sequence_type info
              "a comprehension walks a list or a String, but this one" store
          in
          check_pattern pattern element env store
      | CompIf (info, condition, _) ->
          let condition_type, store = check_expr condition env store in
          (match condition_type with
          | TBool _ -> ()
          | _ ->
              raise
                (Type_error
                   ( info,
                     Printf.sprintf
                       "the condition of a comprehension must be Bool, not %s"
                       (printed condition_type) )));
          (env, store))
    (env, store) clauses

(** The environment a pattern binds and the store in which the value it
    matches has the shape it looks at. A pattern is a *demand*: what it
    takes apart, the subject has to be, which `unify` decides -- so a
    pattern is also how the type of something still open is settled.
    Raises Type_error for a pattern that could never match.
    pattern -> typ -> env -> store -> (env, store) *)
and check_pattern pattern type_ env store =
  match pattern with
  | PWildcard (_, sym) -> (env, record store sym type_)
  | PCapture (_, name, sym) -> (bind env name type_, record store sym type_)
  | PInt (info, _, sym) ->
      let store = pattern_shape (t_int info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PString (info, _, sym) ->
      let store = pattern_shape (t_string info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PChar (info, _, sym) ->
      let store = pattern_shape (t_char info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PBool (info, _, sym) ->
      let store = pattern_shape (t_bool info) type_ info store in
      (env, record store sym (zonk type_ store))
  | PTuple (info, elements, sym) ->
      let parts, store = fresh_metas (List.length elements) info store in
      let store = pattern_shape (t_tuple info parts) type_ info store in
      let store = record store sym (zonk type_ store) in
      List.fold_left2
        (fun (env, store) element part -> check_pattern element part env store)
        (env, store) elements parts
  | PText (info, _, name, _, sym) ->
      (* A string split around a fixed beginning and end. The middle is a
         String like the whole, so there is one type here and nothing to
         take apart. *)
      let store = pattern_shape (t_string info) type_ info store in
      let store = record store sym (zonk type_ store) in
      let env =
        match name with None -> env | Some name -> bind env name (t_string info)
      in
      (env, store)
  | PConstructor (info, module_, name, fields, _, sym) when object_class store module_ name <> None ->
      (* `case Square(side):` -- an object of that class or one below it,
         its header's fields matched as a struct's are. *)
      let c = Option.get (object_class store module_ name) in
      if c.cl_kind = ClassInterface then
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' is an interface, which has no fields to match: write 'case x: %s:'" name name ));
      let instance, store = object_pattern_type info c [] type_ store in
      if List.length fields <> List.length c.cl_header then
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' has %d field%s in its header, and this pattern matches %d" name
                 (List.length c.cl_header)
                 (if List.length c.cl_header = 1 then "" else "s")
                 (List.length fields) ));
      let mapping = match instance with TCon (_, _, args, _) -> class_mapping c args | _ -> [] in
      let store = record store sym (zonk instance store) in
      List.fold_left2
        (fun (env, store) one (_, t) -> check_pattern one (zonk (substitute t mapping) store) env store)
        (env, store) fields c.cl_header
  | PTyped (info, name, t, sym) -> (
      (* `case c: Circle:` -- an object of that class or interface. *)
      match t with
      | TCon (ti, spelled, written, _) -> (
          match SMap.find_opt spelled store.types with
          | Some canonical when SMap.mem canonical store.classes ->
              let c = SMap.find canonical store.classes in
              let written = List.map (resolved store) written in
              if written <> [] && List.length written <> List.length c.cl_params then
                raise
                  (Type_error
                     ( ti,
                       Printf.sprintf "'%s' takes %d type parameter%s, but is given %d" spelled
                         (List.length c.cl_params)
                         (if List.length c.cl_params = 1 then "" else "s")
                         (List.length written) ));
              let instance, store = object_pattern_type info c written type_ store in
              let instance = zonk instance store in
              (bind env name instance, record store sym instance)
          | _ ->
              raise
                (Type_error
                   (ti, Printf.sprintf "'case %s: %s' tests the class of an object, and '%s' is no class or interface" name spelled spelled)))
      | _ -> raise (Type_error (type_info t, "'case name: Type' tests the class of an object, so Type is a class or an interface")))
  | PConstructor (info, module_, name, fields, _, sym) ->
      let spelled = match module_ with Some m -> m ^ "." ^ name | None -> name in
      let _, wanted, result, store = constructor_use info spelled name store in
      let store =
        match unify result type_ store with
        | Some answer -> answer
        | None ->
            raise
              (Type_error
                 ( info,
                   Printf.sprintf
                     "this pattern matches %s, but it is matched against %s"
                     (shown result store) (shown type_ store) ))
      in
      if List.length fields <> List.length wanted then
        raise
          (Type_error
             ( info,
               Printf.sprintf "'%s' has %d field%s, and this pattern matches %d"
                 spelled (List.length wanted)
                 (if List.length wanted = 1 then "" else "s")
                 (List.length fields) ));
      let store = record store sym (zonk type_ store) in
      List.fold_left2
        (fun (env, store) one (_, field_type) ->
          check_pattern one (zonk field_type store) env store)
        (env, store) fields wanted
  | POr (info, alternatives, sym) -> (
      (* Every alternative matches the same value and binds the same
         names, at the same types: whichever of them matched, the arm
         after it sees one set of bindings. *)
      match alternatives with
      | [] -> unsupported info
      | first :: rest ->
          let first_env, store = check_pattern first type_ env store in
          let names = List.map fst (Analyses.pattern_bindings first) in
          let store =
            List.fold_left
              (fun store alternative ->
                let alternative_env, store =
                  check_pattern alternative type_ env store
                in
                List.fold_left
                  (fun store name ->
                    match (type_of first_env name, type_of alternative_env name) with
                    | Some mine, Some theirs -> (
                        match unify mine theirs store with
                        | Some store -> store
                        | None ->
                            raise
                              (Type_error
                                 ( pattern_info alternative,
                                   Printf.sprintf
                                     "'%s' is %s in one alternative of this \
                                      '|' and %s in another; every \
                                      alternative binds a name at one type"
                                     name (shown mine store) (shown theirs store)
                                 )))
                    | _ -> store)
                  store names)
              store rest
          in
          (first_env, record store sym (zonk type_ store)))
  | PAs (_, inner, name, sym) ->
      let env, store = check_pattern inner type_ env store in
      (bind env name type_, record store sym (zonk type_ store))
  | PList (info, prefix, rest, suffix, sym) ->
      let element, store = fresh_meta info store in
      let store = pattern_shape (t_list info element) type_ info store in
      let store = record store sym (zonk type_ store) in
      let env, store =
        List.fold_left
          (fun (env, store) one -> check_pattern one element env store)
          (env, store) (prefix @ suffix)
      in
      let env =
        match rest with
        (* The rest of a list is a list of the same elements. *)
        | Some (ListRest (_, Some name, _)) ->
            bind env name (zonk type_ store)
        | _ -> env
      in
      (env, store)

(* --- the program --- *)

(** What exhaustiveness knows of a type's shapes: a datatype's
    constructors, or for a class its own name -- a pattern on it takes its
    header's fields -- and for an interface its own, each open to the
    classes below it that a case names. store -> string -> datatype? *)
let exhaustive_datatype store canonical =
  match SMap.find_opt canonical store.datatypes with
  | Some d -> Some d
  | None -> (
      match class_named store canonical with
      | Some c ->
          let own = if c.cl_kind = ClassInterface then [] else List.map (fun (n, t) -> (Some n, t)) c.cl_header in
          Some (Datatype (canonical, c.cl_params, [ (canonical, own); (Exhaustive.open_marker, []) ], false))
      | None -> None)

(** Refuses a `match` in these statements that does not match every
    value, or that has a case no value can reach, in the words
    exhaustive.ml puts it. Run once the types are worked out, since what
    a pattern could match is a question about its type.
    [stmt] -> store -> () *)
let check_matches stmts store =
  let tmap = IntMap.map (fun type_ -> zonk type_ store) store.tmap in
  try
    Exhaustive.check (exhaustive_datatype store) tmap stmts
  with Exhaustive.Refused (info, message) -> raise (Type_error (info, message))

(** One resolution with every type in it read back through what has
    since been solved. resolution -> store -> resolution *)
let rec resolved_types answer store =
  match answer with
  | Call (target, supplied) ->
      Call
        ( (match target with
          | None -> None
          | Some (name, type_) -> Some (name, zonk type_ store)),
          List.map (fun one -> resolved_argument one store) supplied )
  | Adapted (type_, passed, supplied) ->
      Adapted
        ( zonk type_ store,
          passed,
          List.map (fun one -> resolved_argument one store) supplied )
  | Upcast type_ -> Upcast (zonk type_ store)
  | Method_call _ | Method_value _ | Super_owner _ | Object_eq _ -> answer

(** One resolved argument, read back the same way.
    argument -> store -> argument *)
and resolved_argument one store =
  match one with
  | Direct (name, type_) -> Direct (name, zonk type_ store)
  | Wrapped (name, type_, passed, inner) ->
      Wrapped
        ( name,
          zonk type_ store,
          passed,
          List.map (fun one -> resolved_argument one store) inner )

(** Refuses a binding whose type holds a mutable value of a type nothing
    decided -- an array of elements nothing decided (`a = array([])`,
    never written or read as anything), or a `var struct` of a parameter
    nothing decided (`c = Cell([])`): a mutable value has to be one type,
    and no later program text can say which once the module is checked
    (PYKING.md, "Arrays", "Mutable structs"). An immutable `xs = []` stays
    a list of anything. [stmt] -> store -> () *)
let check_open_arrays stmts store =
  let writable name =
    match SMap.find_opt name store.datatypes with
    | Some (Datatype (_, _, _, writable)) -> writable
    | None -> false
  in
  let rec open_array type_ =
    match type_ with
    | TCon (_, name, [ element ], _) when name = array_name || name = dynarray_name || name = slice_name ->
        metas_in element store <> [] || open_array element
    | TCon (_, name, args, _) when name = mutmap_name ->
        List.exists (fun arg -> metas_in arg store <> []) args || List.exists open_array args
    | TCon (_, name, args, _) when writable name ->
        List.exists (fun arg -> metas_in arg store <> []) args || List.exists open_array args
    | TCon (_, _, args, _) | TTuple (_, args, _) -> List.exists open_array args
    | TList (_, element, _) -> open_array element
    | _ -> false
  in
  (* A MutMap's key type, wherever one is in a binding's type, is one a
     key can be: what `d[k]` and `has` check at a use, this checks of a
     MutMap nothing used. *)
  let rec keys_fit info type_ =
    match type_ with
    | TCon (_, name, [ key; _ ], _) when name = mutmap_name -> demand_key info key store
    | TCon (_, _, args, _) | TTuple (_, args, _) -> List.iter (keys_fit info) args
    | TList (_, element, _) -> keys_fit info element
    | _ -> ()
  in
  let check name info sym =
    match IntMap.find_opt sym store.tmap with
    | Some type_ ->
        let type_ = zonk type_ store in
        keys_fit info type_;
        if open_array type_ then
          let shown =
            substitute type_ (List.map (fun meta -> (meta, t_unknown info)) (metas_in type_ store))
          in
          raise
            (Type_error
               ( info,
                 Printf.sprintf
                   "the type of '%s' is %s: nothing says what it holds. \
                    Use it, or annotate it ('%s: %s = ...')"
                   name (printed shown) name
                   (printed
                      (substitute type_
                         (List.map (fun meta -> (meta, t_var info "Int")) (metas_in type_ store)))) ))
    | None -> ()
  in
  let rec names target =
    match target with
    | TargetName (i, name, sym) -> check name i sym
    | TargetTuple (_, parts, _) -> List.iter names parts
  in
  Walk.fold_stmts
    (fun () node ->
      match node with
      | Walk.NStmt (SLet (_, target, _, _, _, _, _)) | Walk.NStmt (SLetStmt (_, target, _, _, _, _)) -> names target
      | Walk.NStmt (SVar (i, name, _, sym)) -> check name i sym
      | _ -> ())
    () stmts

(** Type-checks one module -- or a whole one-file program, which is the
    same thing. `sigmaps` pairs the name of every module this one imports
    with what that module exports and at what type, which is all of it
    this check can see (module.ml). Raises Type_error for the first thing
    that does not check out. Answers the types it worked out and, beside
    them, what every call it resolved denotes.
    [stmt] -> [(string, sigmap)] -> (typ IntMap.t, resolution IntMap.t) *)
let type_check ?(declared = []) ?(mutation = true) stmts sigmaps =
  let store = declare_datatypes stmts { (empty_store sigmaps) with mutation } in
  let store = declare_classes stmts store in
  (* A module's own declaration half is in scope here, unqualified and
     with no import: `foo.pyk` and `foo_external.pyk` are one module, so
     a name the target's source provides is a name of this module (see
     docs/modules.md, "A module in two halves"). It goes in before the
     imports, since it is the module's own. *)
  let start =
    List.fold_left (fun env (name, type_) -> bind env name type_)
      (builtin_env ()) declared
  in
  let _, store =
    (* A program's last statement is run for what it does, like every
       other: nothing receives what it is worth. *)
    check_stmts ~discarded:true stmts (import_env stmts start store)
      No_function None store
  in
  let store = settle_plus store in
  let store = settle_kinds store in
  check_open_arrays stmts store;
  check_exports stmts store;
  check_exported_datatypes stmts store;
  check_matches stmts store;
  (* Every type is read back once the whole module has been checked,
     because a metavariable open where it was recorded may have been
     solved by something written further down -- a definition worked out
     before the call that says what it holds, most often. What is still
     open then is open for good, and is shown as the variable it is. *)
  ( IntMap.map (fun type_ -> displayed (zonk type_ store) store) store.tmap,
    (* Every resolution is read back for the same reason: one recorded
       while a metavariable was open may have been decided by something
       written further down, and `elaborate.ml` fills `tmap` from these
       types rather than running the checker again (docs/implicits.md). *)
    IntMap.map (fun answer -> resolved_types answer store) store.qmap )
