(** The C code-generation backend, serving two kinds of target. Plain C
    -- c89, c99, c23 -- is clean C for teaching: it allocates with
    malloc and never frees, checks no index, and refuses what needs a
    heap that is freed (a list, a datatype holding itself, a function
    value that could outlive the stack frame holding its environment),
    each refusal saying c23-gc compiles it. c23-gc is c23 with the
    Boehm-Demers-Weiser collector (bdwgc): it allocates from the
    collector, checks every index and array size, and compiles those
    too -- a list as a pointer to typed cons cells, a datatype holding
    itself as a pointer to a collected struct, and a closure's
    environment on the collected heap. Neither compiles a polymorphic
    parameter.

    Like target_ocaml.ml it infers no types of its own: every type it
    writes is read out of the checker's tmap. It compiles a polymorphic
    function once per type it is used at, a tuple as a struct passed by
    value, a datatype that does not hold itself as a tagged union, a
    nested def as a function of its own taking what it captures, a
    function value as a function pointer and an environment, and an
    array as a struct of its length and a pointer to its elements,
    passed by value. C also leaves the order of an operator's operands
    and a call's arguments unspecified, so operands that can print are
    pinned down with temporaries. See docs/target_c.md and
    docs/target_c_internals.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      cexpr / cstmt -- the C AST: an expression is its text and its
        precedence.
      binding / scope -- what a Pyking name stands for in C.
      state -- what the translation of one module accumulates.
      cprogram -- a translated module.

    Functions:
      translate_program stmts tmap context target -- one module.
      pprint_c_program program target source -- the translation unit.
      pprint_c_header program target source -- the header a module the
        program imports is included through. *)

open Lexer
open Syntax

(* What a module the program imports declares itself in, beside its own
   translation unit. *)
let header_extension = ".h"

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of info * string

(** Raises Unsupported at info with message. info -> string -> 'a *)
let unsupported info message = raise (Unsupported (info, message))

module SMap = Map.Make (String)

let no_info = { file = "<c>"; row1 = 1; col1 = 0; row2 = 1; col2 = 0 }

(* Why plain C refuses a list: its cells are made and dropped as the
   program goes, which needs a heap that frees them. c23-gc has one. *)
let heap_reason =
  "a list, which needs a heap that is freed: plain C has none, and c23-gc \
   compiles it"

(** The element type a list's C type is written for: one nothing in the
    program settles -- `[]` printed, say -- holds no element, so unit
    serves. typ -> typ *)
let list_element e = match e with TVar _ | TUnknown _ -> TTuple (no_info, [], 0) | e -> e

(* The name of the type `Array(T)` (typesystem.ml's `t_array`), which
   is a TCon like a datatype's but compiled as a pointer of its own. *)
let array_name = "Array"

(* The name of the type `DynArray(T)` (typesystem.ml's `t_dynarray`), a TCon too,
   compiled as a pointer to a struct of its own. *)
let dynarray_name = "DynArray"

(** A DynArray type's element. typ -> typ option *)
let dynarray_element t = match t with TCon (_, c, [ e ], _) when c = dynarray_name -> Some e | _ -> None

(* `Slice(T)`, a view of a run of an array's elements: a pointer to
   `pyk_w_<code>`, the array's elements, where the run starts and how
   long it is. *)
let slice_name = "Slice"

(** A view type's element. typ -> typ option *)
let slice_element t = match t with TCon (_, c, [ e ], _) when c = slice_name -> Some e | _ -> None

(* `MutMap(K, V)`: a pointer to `pyk_m_<code>`, its entries in the order
   their keys came. *)
let mutmap_name = "MutMap"

(** A MutMap type's key and value types. typ -> (typ * typ) option *)
let mutmap_parts t = match t with TCon (_, c, [ k; v ], _) when c = mutmap_name -> Some (k, v) | _ -> None

(* `Ptr(T)`: C's own `T *`, pointing at a variable, an element or a
   field. *)
let ptr_name = "Ptr"

(** A pointer type's target. typ -> typ option *)
let ptr_target t = match t with TCon (_, c, [ e ], _) when c = ptr_name -> Some e | _ -> None

(** Whether a TCon's name is a store's -- an array's, a DynArray's, a view's,
    a MutMap's or a pointer's -- rather than a datatype's. string -> bool *)
let is_store c = c = array_name || c = dynarray_name || c = slice_name || c = mutmap_name || c = ptr_name

(** An array's, a DynArray's or a view's element type. typ -> typ option *)
let store_element t = match t with TCon (_, c, [ e ], _) when is_store c && c <> ptr_name -> Some e | _ -> None

(** The C standard a target writes, and whether it links the collector:
    `c23-gc` is c23 with bdwgc; c89, c99 and c23 are plain C, which
    allocates with malloc, never frees and checks no index.
    string -> (string, bool) *)
let standard_of target =
  let n = String.length target in
  if n > 3 && String.sub target (n - 3) 3 = "-gc" then (String.sub target 0 (n - 3), true) else (target, false)

(* The helpers below allocate through a marker, \001M:atomic:\001 (or
   M:scanned:, M:resize:), which `expand_captures` replaces once the
   target is known: bdwgc's allocator on c23-gc, malloc's on plain C.
   Atomic memory holds no pointer, so the collector never scans it. *)

(* --- C expressions: text and precedence --- *)

type cexpr = { text : string; prec : int; local_env : bool }
(* local_env: a function value whose environment is in this function's
   own stack frame, which must not outlive it *)

let p_comma = 0
let p_assign = 2
let p_cond = 3
let p_or = 4
let p_and = 5
let p_bit_or = 6
let p_xor = 7
let p_bit_and = 8
let p_eq = 9
let p_rel = 10
let p_shift = 11
let p_add = 12
let p_mul = 13
let p_unary = 14
let p_atom = 16

let mk ?(local_env = false) prec text = { text; prec; local_env }
let atom ?(local_env = false) text = mk ~local_env p_atom text
let at prec e = if e.prec < prec then "(" ^ e.text ^ ")" else e.text
let binary prec op l r = mk prec (at prec l ^ " " ^ op ^ " " ^ at (prec + 1) r)

let conjunction conds =
  match conds with
  | [] -> atom "1"
  | first :: rest -> List.fold_left (fun acc c -> binary p_and "&&" acc c) first rest

let unit_value = atom "0"

(* --- C statements --- *)

type cstmt =
  | CDecl of string * string * string option (* type, name, initializer *)
  | CLine of string (* one simple statement, with its `;` *)
  | CIf of string * cstmt list * cstmt list option
  | CWhile of string * cstmt list
  | CFor of string * cstmt list (* `init; test; step` *)
  | CBlock of cstmt list
  | CReturn of string option
  | CBreak
  | CContinue
  | CGoto of string
  | CLabel of string

(** Whether a `break` in stmts leaves the statement holding them.
    [cstmt] -> bool *)
let rec breaks stmts =
  List.exists
    (fun s ->
      match s with
      | CBreak -> true
      | CIf (_, t, e) -> breaks t || (match e with Some e -> breaks e | None -> false)
      | CBlock b -> breaks b
      | _ -> false)
    stmts

(** Whether s can finish and go on to what follows it. cstmt -> bool *)
let rec completes s =
  match s with
  | CWhile ("1", body) -> breaks body
  | CIf (_, t, Some e) -> block_completes t || block_completes e
  | CBlock b -> block_completes b
  | CReturn _ | CBreak | CContinue | CGoto _ -> false
  | _ -> true

and block_completes stmts = List.for_all completes stmts

(* --- names --- *)

(* What the headers a translation unit may include declare at file scope,
   which a function or a top-level binding of the same name would be
   declared over. *)
let library_names =
  String.split_on_char ' '
    "remove rename tmpfile tmpnam fclose fflush fopen freopen setbuf setvbuf \
     fscanf scanf sscanf vfprintf vprintf vsprintf fgetc fgets fputc fputs \
     getc getchar gets putc putchar puts ungetc fread fwrite fgetpos fseek \
     fsetpos ftell rewind clearerr feof ferror perror snprintf vsnprintf \
     vscanf vfscanf vsscanf fpos_t FILE stdin stdout EOF BUFSIZ getline \
     getdelim fileno popen pclose dprintf fdopen ctermid FILENAME_MAX \
     FOPEN_MAX L_tmpnam SEEK_CUR SEEK_END SEEK_SET TMP_MAX NULL atof atoi \
     atol atoll strtof strtold strtol strtoll strtoul strtoull rand srand \
     calloc free realloc abort atexit exit _Exit getenv system bsearch qsort \
     abs labs llabs div ldiv lldiv div_t ldiv_t lldiv_t mblen mbtowc wctomb \
     mbstowcs wcstombs aligned_alloc at_quick_exit quick_exit random srandom \
     setenv unsetenv putenv mkstemp realpath posix_memalign drand48 erand48 \
     lrand48 mrand48 srand48 EXIT_FAILURE EXIT_SUCCESS MB_CUR_MAX RAND_MAX \
     memcpy memmove strcpy strncpy strcat strncat memcmp strcoll strncmp \
     strxfrm memchr strchr strcspn strpbrk strrchr strspn strstr strtok \
     memset strerror strdup strndup index rindex bzero bcopy bcmp strcasecmp \
     strncasecmp stpcpy strsep strlcpy strlcat memccpy acos asin atan atan2 \
     cos sin tan cosh sinh tanh exp frexp ldexp log log10 modf pow sqrt ceil \
     fabs floor fmod acosh asinh atanh exp2 expm1 ilogb log1p log2 logb \
     scalbn scalbln cbrt hypot erf erfc lgamma tgamma trunc round lround \
     llround nearbyint rint lrint llrint remainder remquo copysign nan \
     nextafter nexttoward fdim fmax fmin fma j0 j1 jn y0 y1 yn gamma \
     signgam isnan isinf isfinite signbit fpclassify HUGE_VAL INFINITY NAN \
     DBL_MAX DBL_MIN DBL_EPSILON DBL_DIG DBL_MANT_DIG FLT_MAX FLT_MIN \
     FLT_EPSILON FLT_DIG FLT_RADIX FLT_ROUNDS LDBL_MAX LDBL_MIN"

(* Legal Pyking identifiers that are reserved in C: every standard's
   keywords, main, and what the C library declares. *)
let reserved =
  StringSet.of_list
    (String.split_on_char ' '
       "auto break case char const continue default do double else enum \
        extern float for goto if inline int long register restrict return \
        short signed sizeof static struct switch typedef union unsigned void \
        volatile while alignas alignof bool constexpr false nullptr \
        static_assert thread_local true typeof typeof_unqual _Alignas _Alignof \
        _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert \
        _Thread_local _BitInt _Decimal32 _Decimal64 _Decimal128 main printf \
        fprintf stderr strcmp strlen malloc size_t sprintf strtod"
    @ library_names)

(** name as a legal C identifier no library declares. string -> string *)
let c_ident name =
  if StringSet.mem name reserved || (String.length name >= 4 && String.sub name 0 4 = "pyk_") then name ^ "_"
  else name

(** A public name of a module, as every translation unit spells it:
    `<module>_<name>`. string -> string -> string *)
let module_name module_ name = Printf.sprintf "%s_%s" module_ name

(** The function that runs a module's own top level. string -> string *)
let init_name name = module_name name "init"

(* --- types --- *)

(** A polymorphic type's every variable. typ -> [string] *)
let rec type_vars type_ =
  match type_ with
  | TVar (_, v, _, _) -> [ v ]
  | TList (_, e, _) -> type_vars e
  | TTuple (_, es, _) | TCon (_, _, es, _) -> List.concat_map type_vars es
  | TFunction (_, ps, r, _, _, _, _) -> List.concat_map type_vars ps @ type_vars r
  | TForall (_, _, b, _) -> type_vars b
  | _ -> []

(** t with each variable `bound` names replaced. [(string, typ)] -> typ
    -> typ *)
let rec substitute bound t =
  match t with
  | TVar (_, v, _, _) -> ( match List.assoc_opt v bound with Some t -> t | None -> t)
  | TList (i, e, s) -> TList (i, substitute bound e, s)
  | TTuple (i, es, s) -> TTuple (i, List.map (substitute bound) es, s)
  | TCon (i, c, es, s) -> TCon (i, c, List.map (substitute bound) es, s)
  | TFunction (i, ps, r, a, b, c, d) ->
      TFunction (i, List.map (substitute bound) ps, substitute bound r, a, b, c, d)
  | TForall (i, vs, body, s) ->
      TForall (i, vs, substitute (List.filter (fun (v, _) -> not (List.mem v vs)) bound) body, s)
  | t -> t

(** What each variable of a declared type stands for, read off a type of
    the same shape. [(string, typ)] -> typ -> typ -> [(string, typ)] *)
let rec matching bound declared actual =
  match (declared, actual) with
  | TVar (_, v, _, _), t when not (List.mem_assoc v bound) -> (
      match t with TVar (_, w, _, _) when w = v -> bound | TUnknown _ -> bound | t -> (v, t) :: bound)
  | TList (_, a, _), TList (_, b, _) -> matching bound a b
  | (TTuple (_, xs, _), TTuple (_, ys, _) | TCon (_, _, xs, _), TCon (_, _, ys, _))
    when List.length xs = List.length ys ->
      List.fold_left2 matching bound xs ys
  | TFunction (_, ps, r, _, _, _, _), TFunction (_, qs, q, _, _, _, _)
    when List.length ps = List.length qs ->
      List.fold_left2 matching (matching bound r q) ps qs
  | _ -> bound

(** A def's function type: its own type variables, its parameters (the
    implicit ones made ordinary) and its result. typ -> ([string], [typ], typ) *)
let function_parts t =
  let vars, t = match t with TForall (_, vs, body, _) -> (vs, body) | t -> ([], t) in
  match Typesystem.without_implicits t with
  | TFunction (_, ps, r, _, _, _, _) -> (vars, ps, r)
  | _ -> (vars, [], t)

let is_unit t = match t with TTuple (_, [], _) -> true | _ -> false

(** A canonical datatype name as part of a C identifier. string -> string *)
let ident_of canonical = String.map (fun c -> if c = '.' then '_' else c) canonical

(** A type's code: what names the C type a compound type is declared as,
    and every instance of a polymorphic function. Raises Unsupported for
    a type C cannot be given. info -> typ -> string *)
(* The classes and interfaces of the module being written, by name: what
   `code` asks, which is given nothing else. Every object, whatever its
   class, is a `pyk_obj *` (docs/target_c.md, "Classes"). *)
let object_types : (string, unit) Hashtbl.t = Hashtbl.create 8

let rec code own info t =
  (* With no better place to point at, a refusal points at where the
     checker made the type. *)
  let info = if info.file = "<c>" then type_info t else info in
  match t with
  | TInt _ -> "i"
  | TChar _ -> "c"
  | TFloat _ -> "f"
  | TBool _ -> "b"
  | TString _ -> "s"
  | TTuple (_, [], _) -> "u"
  | TTuple (_, es, _) -> "T" ^ String.concat "" (List.map (code own info) es) ^ "_"
  | TCon (_, c, [ e ], _) when c = array_name -> "A" ^ code own info e ^ "_"
  | TCon (_, c, [ e ], _) when c = dynarray_name -> "V" ^ code own info e ^ "_"
  | TCon (_, c, [ e ], _) when c = slice_name -> "W" ^ code own info e ^ "_"
  | TCon (_, c, [ e ], _) when c = ptr_name -> "P" ^ code own info e ^ "_"
  | TCon (_, c, [ k; v ], _) when c = mutmap_name -> "M" ^ code own info k ^ code own info v ^ "_"
  | TCon (_, c, _, _) when Hashtbl.mem object_types c -> "O_"
  | TCon (_, c, args, _) ->
      (* A datatype is named by its module wherever it is used, so every
         file of the program spells its struct the same. *)
      let c = if String.contains c '.' then c else own ^ "." ^ c in
      "D" ^ ident_of c ^ "_" ^ String.concat "" (List.map (code own info) args) ^ "_"
  | TFunction (_, ps, r, _, _, _, imps) ->
      "F" ^ String.concat "" (List.map (code own info) (ps @ List.map (fun (IParam (_, t)) -> t) imps)) ^ "_" ^ code own info r ^ "_"
  | TList (_, e, _) -> "L" ^ code own info (list_element e) ^ "_"
  | TForall _ ->
      unsupported info
        "a polymorphic parameter (`all a. ...`), which one C function would \
         have to serve at every type: C compiles a polymorphic function once \
         per type"
  | TVar _ | TUnknown _ | _ ->
      unsupported info "a value whose type nothing in the program settles, which C has to know"

(* --- which calls can change something ---
   Beside which calls can print (Analyses.effects), the order C leaves
   open matters where a call changes what another operand reads: a
   `var` outside the function, a var struct's field, an element, a DynArray.
   A def changes something where its body writes one of those, or calls
   a def that does, a builtin that writes (`push`, ...), or another
   module; a call through a function value, which nothing here can see
   into, changes something wherever anything in the program might.
   Conservative, as the printing walk is: too much costs a temporary. *)

(** Whether a node, a lambda's body left out, writes or calls what
    writes, by what is known: changing the defs found so far, unknown
    what a call through a value is assumed to do. [StringSet.t] -> bool
    -> StringSet.t -> Walk.node -> bool *)
let writes defs changing unknown own node =
  let rec go node =
    match node with
    | Walk.NExpr (ELambda _) | Walk.NStmt (SFunctionDef _) -> false
    | Walk.NStmt (SMutate (_, name, _, _)) when not (StringSet.mem name own) -> true
    | Walk.NStmt (SSetField _ | SSetIndex _ | SSetDeref _) -> true
    | Walk.NExpr (ECall (_, EVar (_, name, _), _, _)) when List.mem name Builtin.writers && not (StringSet.mem name defs) -> true
    | Walk.NExpr (ECall (_, EVar (_, name, _), _, _) as e) when StringSet.mem name defs ->
        StringSet.mem name changing || List.exists go (List.tl (Walk.children (Walk.NExpr e)))
    | Walk.NExpr (ECall (_, EVar (_, name, _), _, _) as e) when List.mem name Builtin.names ->
        List.exists go (List.tl (Walk.children (Walk.NExpr e)))
    | Walk.NExpr (ECall (_, EQualified _, _, _)) -> true
    | Walk.NExpr (ECall _) when unknown -> true
    | node -> List.exists go (Walk.children node)
  in
  go node

(** A module's defs, those whose call can change something, and whether
    a call through a function value can. [stmt] -> (StringSet.t,
    StringSet.t, bool) *)
let changes stmts =
  let defs =
    Walk.fold_stmts
      (fun found node -> match node with Walk.NStmt (SFunctionDef (_, n, _, b, _, _, _, _, _)) -> (n, b) :: found | _ -> found)
      [] stmts
  in
  let names = StringSet.of_list (List.map fst defs) in
  (* A def's own `var`s it may write freely. *)
  let own body =
    Walk.fold_stmts (fun found node -> match node with Walk.NStmt (SVar (_, n, _, _)) -> StringSet.add n found | _ -> found) StringSet.empty body
  in
  (* Anything anywhere, a lambda's body or a def's, that writes. *)
  let anything =
    Walk.fold_stmts
      (fun found node ->
        found
        ||
        match node with
        | Walk.NStmt (SMutate _ | SSetField _ | SSetIndex _ | SSetDeref _) -> true
        | Walk.NExpr (ECall (_, EVar (_, name, _), _, _)) -> List.mem name Builtin.writers
        | Walk.NExpr (ECall (_, EQualified _, _, _)) -> true
        | _ -> false)
      false stmts
  in
  let rec settle changing =
    let next =
      List.fold_left
        (fun changing (name, body) ->
          if StringSet.mem name changing then changing
          else if List.exists (writes names changing anything (own body)) (List.map (fun s -> Walk.NStmt s) body) then StringSet.add name changing
          else changing)
        changing defs
    in
    if StringSet.equal next changing then changing else settle next
  in
  (names, settle StringSet.empty, anything)

(* --- what a translation reads --- *)

type ctx = {
  tmap : typ IntMap.t;
  standard : string; (* c89, c99 or c23: the standard written *)
  gc : bool; (* c23-gc: allocated from bdwgc, every index checked *)
  context : Module.context;
  own : string;
  datatypes : datatype SMap.t;
  modules : (string * string) list; (* alias -> module *)
  printing : Analyses.effects;
  changing : StringSet.t * StringSet.t * bool;
      (* this module's defs, those whose call can change a value, and
         whether a call nobody can see into can *)
  sigma : (string * typ) list; (* the type variables of the instance being written *)
  classes : Classes.table; (* the module's classes and interfaces *)
  slots : string list; (* every method name of them: an object's table has a slot for each *)
}

(** The C spelling of a Bool's type. ctx -> string *)
let bool_type ctx = if ctx.standard = "c89" then "int" else "bool"

let true_text ctx = if ctx.standard = "c89" then "1" else "true"
let false_text ctx = if ctx.standard = "c89" then "0" else "false"

(* --- what a Pyking name stands for --- *)

type fn = {
  cname : string; (* the C function, or the template it is instantiated from *)
  generic : bool; (* compiled once per instance *)
  lifted : bool; (* a nested def or a lambda: takes its captures first *)
  void : bool;
  ftype : typ;
  host : bool; (* the host's: a callback crosses as a plain function pointer *)
}

type kind =
  | BLocal (* a local, a parameter or a static: its value is its name *)
  | BCell (* a `var` a closure captures: a pointer to the cell *)
  | BFn of fn

type binding = { value : cexpr; kind : kind; btype : typ; cname_ : string }

type scope = {
  names : binding SMap.t;
  loops : (string * typ) list list; (* each loop's slots, innermost last *)
  cells : StringSet.t;
  block : stmt list;
  family : string; (* the function the lifted ones are written in *)
}

(* A lifted function's captures, finished once the module is done: its
   own, and those of every lifted function it reaches but did not write. *)
type capture = { direct : (string * string) list; reaches : string list; inside : string }

type cfunc = {
  f_name : string;
  f_public : bool;
  f_result : string;
  f_params : (string * string) list; (* type, name *)
  f_captures : bool;
  f_body : cstmt list;
}

(* A polymorphic def, compiled once per instance a call asks for. *)
type template = {
  t_def : stmt;
  t_scope : scope;
  t_sigma : (string * typ) list;
  t_lifted : bool;
  t_public : bool;
}

type state = {
  taken : StringSet.t; (* C names in use in this file *)
  counter : int;
  temps : (string * string) list; (* the function's evaluation-order temporaries *)
  pre : cstmt list; (* statements an expression needs run first *)
  funcs : cfunc list;
  captures : (string * capture) list;
  types : (string * string) list; (* C type name, its declaration *)
  helpers : (string * string) list; (* helper name, its definition *)
  wrappers : (string * string) list;
  templates : (string * template) list;
  instances : StringSet.t;
  pending : (string * string * (string * typ) list) list; (* instance, template, sigma *)
  includes_math : bool;
  uses_bool : bool;
  building : StringSet.t; (* the show helpers being written, which a
                             recursive datatype's reach again *)
  helper_protos : (string * string) list; (* helpers called before
                                               they are written *)
  (* Instances of another module's polymorphic functions this file
     calls, which that module compiles, and their prototypes here. *)
  requests : (string * (string * typ) list) list;
  protos : (string * string) list;
}

(** A name nothing in this file has taken, from base. state -> string ->
    (string, state) *)
let fresh st base =
  let base = c_ident base in
  let rec go candidate n =
    if StringSet.mem candidate st.taken then go (Printf.sprintf "%s%d" base n) (n + 1) else candidate
  in
  let name = go base 2 in
  (name, { st with taken = StringSet.add name st.taken })

(** A generated name: pyk_<prefix><n>. state -> string -> (string, state) *)
let temp st prefix =
  let name = Printf.sprintf "pyk_%s%d" prefix (st.counter + 1) in
  (name, { st with counter = st.counter + 1; taken = StringSet.add name st.taken })

let bind_value scope name b = { scope with names = SMap.add name b scope.names }

(** The binding of a name, or a refusal naming it. scope -> info ->
    string -> binding *)
let lookup scope info name =
  match SMap.find_opt name scope.names with
  | Some b -> b
  | None -> unsupported info (Printf.sprintf "'%s' is not a value this backend can compile" name)

(** The structs every object and class descriptor is, and the test a
    class pattern makes, ahead of their first use. state -> state *)
let rec need_objects st =
  if List.mem_assoc "pyk_obj" st.types then st
  else
    let st =
      {
        st with
        types =
          st.types
          @ [
              ( "pyk_obj",
                String.concat "\n"
                  [
                    "typedef struct pyk_class pyk_class;";
                    "typedef struct pyk_obj {";
                    "    const pyk_class *cls;";
                    "} pyk_obj;";
                    "struct pyk_class {";
                    "    const char *name;";
                    "    const pyk_class *parent;";
                    "    const pyk_class *const *ifaces;";
                    "    void (*const *vt)(void);";
                    "    const char *(*show)(pyk_obj *);";
                    "};";
                  ] );
            ];
      }
    in
    let st =
      need_helper st "pyk_is_a"
        (String.concat "\n"
           [
             "static int pyk_is_a(const pyk_class *c, const pyk_class *target)";
             "{";
             "    for (; c != NULL; c = c->parent) {";
             "        const pyk_class *const *i;";
             "        if (c == target) return 1;";
             "        for (i = c->ifaces; i != NULL && *i != NULL; i++) {";
             "            if (pyk_is_a(*i, target)) return 1;";
             "        }";
             "    }";
             "    return 0;";
             "}";
           ])
    in
    need_helper st "pyk_obj_show" "static const char *pyk_obj_show(pyk_obj *o)\n{\n    return o->cls->show(o);\n}"

(** A helper added to the file once. state -> string -> string -> state *)
and need_helper st name text =
  if List.mem_assoc name st.helpers then st else { st with helpers = st.helpers @ [ (name, text) ] }

(* --- the shared helpers --- *)

let concat_helper =
  "static const char *pyk_concat(const char *a, const char *b)\n{\n    size_t la = strlen(a);\n    size_t lb = strlen(b);\n    char *result = \001M:atomic:\001(la + lb + 1);\n    memcpy(result, a, la);\n    memcpy(result + la, b, lb + 1);\n    return result;\n}"

let slice_helper =
  "static const char *pyk_slice(const char *s, size_t from, size_t drop)\n{\n    size_t n = strlen(s) - from - drop;\n    char *out = \001M:atomic:\001(n + 1);\n    memcpy(out, s + from, n);\n    out[n] = '\\0';\n    return out;\n}"

let ends_helper =
  "static int pyk_ends_with(const char *s, const char *suffix)\n{\n    size_t ls = strlen(s);\n    size_t lt = strlen(suffix);\n    return ls >= lt && strcmp(s + ls - lt, suffix) == 0;\n}"

let int_str_helper =
  "static const char *pyk_int_str(int n)\n{\n    char *out = \001M:atomic:\001(24);\n    sprintf(out, \"%d\", n);\n    return out;\n}"

let quote_helper =
  "static const char *pyk_quote(const char *s)\n{\n    char *out = \001M:atomic:\001(strlen(s) * 2 + 3);\n    size_t k = 0;\n    out[k++] = '\"';\n    for (; *s != '\\0'; s++) {\n        switch (*s) {\n        case '\\\\': out[k++] = '\\\\'; out[k++] = '\\\\'; break;\n        case '\"': out[k++] = '\\\\'; out[k++] = '\"'; break;\n        case '\\n': out[k++] = '\\\\'; out[k++] = 'n'; break;\n        case '\\t': out[k++] = '\\\\'; out[k++] = 't'; break;\n        case '\\r': out[k++] = '\\\\'; out[k++] = 'r'; break;\n        default: out[k++] = *s;\n        }\n    }\n    out[k++] = '\"';\n    out[k] = '\\0';\n    return out;\n}"

(* --- characters ---
   A Char is an int holding its code point; a String is UTF-8, walked a
   code point at a time by pyk_utf8_step, which answers NULL at the end. *)

let utf8_step_helper =
  String.concat "\n"
    [
      "static const char *pyk_utf8_step(const char *p, int *c)";
      "{";
      "    const unsigned char *s = (const unsigned char *)p;";
      "    int n, k, v;";
      "    if (*s == 0) {";
      "        return NULL;";
      "    }";
      "    if (*s < 0x80) {";
      "        *c = *s;";
      "        return p + 1;";
      "    }";
      "    if (*s >= 0xF8 || *s < 0xC0) {";
      "        *c = 0xFFFD;";
      "        return p + 1;";
      "    }";
      "    n = *s >= 0xF0 ? 3 : *s >= 0xE0 ? 2 : 1;";
      "    v = *s & (0x3F >> n);";
      "    for (k = 1; k <= n; k++) {";
      "        if ((s[k] & 0xC0) != 0x80) {";
      "            *c = 0xFFFD;";
      "            return p + 1;";
      "        }";
      "        v = (v << 6) | (s[k] & 0x3F);";
      "    }";
      "    *c = v;";
      "    return p + 1 + n;";
      "}";
    ]

let utf8_length_helper =
  "static int pyk_utf8_length(const char *s)\n{\n    int c, n = 0;\n    while ((s = pyk_utf8_step(s, &c)) != NULL) {\n        n++;\n    }\n    return n;\n}"

let char_at_helper =
  String.concat "\n"
    [
      "static int pyk_char_at(const char *s, int i)";
      "{";
      "    const char *p = s;";
      "    int c = 0, k = 0, n;";
      "    if (i >= 0) {";
      "        while ((p = pyk_utf8_step(p, &c)) != NULL) {";
      "            if (k == i) {";
      "                return c;";
      "            }";
      "            k++;";
      "        }";
      "    }";
      "    n = pyk_utf8_length(s);";
      "    fprintf(stderr, \"error: the index %d is outside a String of %d character%s\\n\", i, n, n == 1 ? \"\" : \"s\");";
      "    exit(1);";
      "    return 0;";
      "}";
    ]

let utf8_helper =
  String.concat "\n"
    [
      "static const char *pyk_utf8(int c)";
      "{";
      "    char *out = \001M:atomic:\001(5);";
      "    if (c < 0x80) {";
      "        out[0] = (char)c;";
      "        out[1] = '\\0';";
      "    } else if (c < 0x800) {";
      "        out[0] = (char)(0xC0 | (c >> 6));";
      "        out[1] = (char)(0x80 | (c & 0x3F));";
      "        out[2] = '\\0';";
      "    } else if (c < 0x10000) {";
      "        out[0] = (char)(0xE0 | (c >> 12));";
      "        out[1] = (char)(0x80 | ((c >> 6) & 0x3F));";
      "        out[2] = (char)(0x80 | (c & 0x3F));";
      "        out[3] = '\\0';";
      "    } else {";
      "        out[0] = (char)(0xF0 | (c >> 18));";
      "        out[1] = (char)(0x80 | ((c >> 12) & 0x3F));";
      "        out[2] = (char)(0x80 | ((c >> 6) & 0x3F));";
      "        out[3] = (char)(0x80 | (c & 0x3F));";
      "        out[4] = '\\0';";
      "    }";
      "    return out;";
      "}";
    ]

let quote_char_helper =
  String.concat "\n"
    [
      "static const char *pyk_quote_char(int c)";
      "{";
      "    switch (c) {";
      "    case '\\'': return \"'\\\\''\";";
      "    case '\\\\': return \"'\\\\\\\\'\";";
      "    case '\\n': return \"'\\\\n'\";";
      "    case '\\t': return \"'\\\\t'\";";
      "    case '\\r': return \"'\\\\r'\";";
      "    case 0: return \"'\\\\0'\";";
      "    }";
      "    return pyk_concat(pyk_concat(\"'\", pyk_utf8(c)), \"'\");";
      "}";
    ]

let char_of_int_helper =
  "static int pyk_char_of_int(int n)\n{\n    return n >= 0 && n <= 0x10FFFF && !(n >= 0xD800 && n <= 0xDFFF) ? n : 0;\n}"

let char_of_string_helper =
  "static int pyk_char_of_string(const char *s)\n{\n    int c = 0;\n    return pyk_utf8_step(s, &c) != NULL ? c : 0;\n}"

(* Each character helper, those it calls added before it. *)
let rec need_char st name =
  let deps, text =
    match name with
    | "pyk_utf8_step" -> ([], utf8_step_helper)
    | "pyk_utf8_length" -> ([ "pyk_utf8_step" ], utf8_length_helper)
    | "pyk_char_at" -> ([ "pyk_utf8_step"; "pyk_utf8_length" ], char_at_helper)
    | "pyk_utf8" -> ([], utf8_helper)
    | "pyk_quote_char" -> ([ "pyk_concat"; "pyk_utf8" ], quote_char_helper)
    | "pyk_char_of_int" -> ([], char_of_int_helper)
    | "pyk_char_of_string" -> ([ "pyk_utf8_step" ], char_of_string_helper)
    | "pyk_concat" -> ([], concat_helper)
    | _ -> invalid_arg name
  in
  need_helper (List.fold_left need_char st deps) name text

let truncate_helper =
  "static int pyk_truncate(double x)\n{\n    if (x != x || x <= -2147483649.0 || x >= 2147483648.0) {\n        return 0;\n    }\n    return (int)x;\n}"

let int_of_string_helper =
  String.concat "\n"
    [
      "static int pyk_int_of_string(const char *s)";
      "{";
      "    const char *p = s;";
      "    double value = 0.0;";
      "    int negative = 0;";
      "    if (*p == '-' || *p == '+') {";
      "        negative = *p == '-';";
      "        p++;";
      "    }";
      "    if (*p == '\\0') {";
      "        return 0;";
      "    }";
      "    for (; *p != '\\0'; p++) {";
      "        if (*p < '0' || *p > '9') {";
      "            return 0;";
      "        }";
      "        value = value * 10.0 + (*p - '0');";
      "        if (value > 2147483648.0) {";
      "            return 0;";
      "        }";
      "    }";
      "    if (negative) {";
      "        value = -value;";
      "    }";
      "    if (value > 2147483647.0) {";
      "        return 0;";
      "    }";
      "    return (int)value;";
      "}";
    ]

let float_of_string_helper =
  String.concat "\n"
    [
      "static double pyk_float_of_string(const char *s)";
      "{";
      "    const char *p = s;";
      "    if (strcmp(s, \"inf\") == 0 || strcmp(s, \"+inf\") == 0) {";
      "        return HUGE_VAL;";
      "    }";
      "    if (strcmp(s, \"-inf\") == 0) {";
      "        return -HUGE_VAL;";
      "    }";
      "    if (strcmp(s, \"nan\") == 0) {";
      "        return HUGE_VAL - HUGE_VAL;";
      "    }";
      "    if (*p == '-' || *p == '+') {";
      "        p++;";
      "    }";
      "    if (*p < '0' || *p > '9') {";
      "        return HUGE_VAL - HUGE_VAL;";
      "    }";
      "    while (*p >= '0' && *p <= '9') {";
      "        p++;";
      "    }";
      "    if (*p == '.') {";
      "        p++;";
      "        if (*p < '0' || *p > '9') {";
      "            return HUGE_VAL - HUGE_VAL;";
      "        }";
      "        while (*p >= '0' && *p <= '9') {";
      "            p++;";
      "        }";
      "    }";
      "    if (*p == 'e' || *p == 'E') {";
      "        p++;";
      "        if (*p == '-' || *p == '+') {";
      "            p++;";
      "        }";
      "        if (*p < '0' || *p > '9') {";
      "            return HUGE_VAL - HUGE_VAL;";
      "        }";
      "        while (*p >= '0' && *p <= '9') {";
      "            p++;";
      "        }";
      "    }";
      "    if (*p != '\\0') {";
      "        return HUGE_VAL - HUGE_VAL;";
      "    }";
      "    return strtod(s, NULL);";
      "}";
    ]

let float_helper =
  String.concat "\n"
    [
      "static const char *pyk_float_str(double x)";
      "{";
      "    char buf[64];";
      "    char digits[32];";
      "    char *out = \001M:atomic:\001(64);";
      "    double a;";
      "    int negative, p, at, i, n, decpt, k;";
      "    const char *e;";
      "    if (x != x) { strcpy(out, \"nan\"); return out; }";
      "    if (x > DBL_MAX) { strcpy(out, \"inf\"); return out; }";
      "    if (x < -DBL_MAX) { strcpy(out, \"-inf\"); return out; }";
      "    negative = x < 0.0 || (x == 0.0 && 1.0 / x < 0.0);";
      "    a = negative ? -x : x;";
      "    if (a == 0.0) { strcpy(out, negative ? \"-0.0\" : \"0.0\"); return out; }";
      "    for (p = 0; p < 16; p++) {";
      "        sprintf(buf, \"%.*e\", p, a);";
      "        if (strtod(buf, NULL) == a) break;";
      "    }";
      "    if (p == 16) sprintf(buf, \"%.*e\", 16, a);";
      "    e = strchr(buf, 'e');";
      "    at = (int)(e - buf);";
      "    n = 0;";
      "    for (i = 0; i < at; i++) if (buf[i] != '.') digits[n++] = buf[i];";
      "    while (n > 1 && digits[n - 1] == '0') n--;";
      "    digits[n] = '\\0';";
      "    decpt = atoi(e + 1) + 1;";
      "    k = 0;";
      "    if (negative) out[k++] = '-';";
      "    if (decpt <= -4 || decpt > 16) {";
      "        out[k++] = digits[0];";
      "        if (n > 1) { out[k++] = '.'; strcpy(out + k, digits + 1); k += n - 1; }";
      "        sprintf(out + k, \"e%d\", decpt - 1);";
      "        return out;";
      "    }";
      "    if (decpt <= 0) {";
      "        out[k++] = '0';";
      "        out[k++] = '.';";
      "        for (i = 0; i < -decpt; i++) out[k++] = '0';";
      "        strcpy(out + k, digits);";
      "        return out;";
      "    }";
      "    if (decpt >= n) {";
      "        strcpy(out + k, digits);";
      "        k += n;";
      "        for (i = 0; i < decpt - n; i++) out[k++] = '0';";
      "        strcpy(out + k, \".0\");";
      "        return out;";
      "    }";
      "    for (i = 0; i < decpt; i++) out[k++] = digits[i];";
      "    out[k++] = '.';";
      "    strcpy(out + k, digits + decpt);";
      "    return out;";
      "}";
    ]

let need_concat st = need_helper st "pyk_concat" concat_helper

(* C leaves `>>` of a negative number to the compiler; Pyking's keeps
   the sign. *)
let shift_right_helper =
  "static int pyk_shr(int a, int n)\n{\n    return a < 0 ? ~(~a >> n) : a >> n;\n}"

(* An Int raised to an Int at least 0, by repeated squaring. *)
let power_helper =
  "static int pyk_ipow(int base, int exponent)\n{\n    int result = 1;\n    while (exponent > 0) {\n        if (exponent % 2 == 1)\n            result = result * base;\n        base = base * base;\n        exponent = exponent / 2;\n    }\n    return result;\n}"
let need_float st = need_helper st "pyk_float_str" float_helper

(** The typedef a host's callback parameter is written through:
    `pyk_fn_ii_v` for `(Int, Int) -> ()`. ctx -> typ -> string *)
let host_callback_type _ctx t =
  match t with
  | TFunction (_, ps, r, _, _, _, _) ->
      let letter t = match t with TInt _ -> "i" | TChar _ -> "c" | TFloat _ -> "f" | TBool _ -> "b" | TString _ -> "s" | _ -> "v" in
      "pyk_fn_" ^ String.concat "" (List.map letter ps) ^ "_" ^ letter r
  | _ -> "void"

(* --- the types a file declares --- *)

(** The datatype a canonical name denotes, its parameters bound to args.
    ctx -> info -> string -> [typ] -> (datatype, [(string, typ)]) *)
let datatype_of ctx info canonical args =
  match SMap.find_opt canonical ctx.datatypes with
  | Some (Datatype (_, params, _, _) as d) ->
      (d, if List.length params = List.length args then List.combine params args else [])
  | None -> unsupported info (Printf.sprintf "the datatype %s is not one this module can see" canonical)

(** The C member names of one constructor's fields: in a datatype of one
    constructor, a named field by its own name, and otherwise `f<i>`.
    bool -> [(String?, typ)] -> [string] *)
let member_names sole fields =
  let plain = List.mapi (fun i _ -> Printf.sprintf "f%d" i) fields in
  if not sole then plain
  else
    let named =
      List.mapi
        (fun i (label, _) ->
          match label with Some l -> c_ident l | None -> Printf.sprintf "f%d" i)
        fields
    in
    if List.length (List.sort_uniq compare named) = List.length named then named
    else plain

(** Where a member of a constructor lives in its datatype's value: the
    member itself in a struct of one constructor, under the union in a
    tagged union. bool -> string -> string -> string *)
let member_path sole cname member =
  if sole then member else Printf.sprintf "u.%s.%s" (c_ident cname) member

(** A constructor's fields at an instance: each field's path in the value
    and its type. ctx -> info -> typ -> string -> [(string, typ)] *)
let ctor_fields ctx info t name =
  match t with
  | TCon (_, canonical, args, _) -> (
      let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
      let sole = List.length ctors = 1 in
      match List.assoc_opt name ctors with
      | Some fields ->
          List.map2
            (fun member (_, ft) -> (member_path sole name member, substitute bound ft))
            (member_names sole fields) fields
      | None -> unsupported info (Printf.sprintf "no constructor %s" name))
  | _ -> unsupported info "a constructor of a value that is not a datatype"

(** The named fields of a datatype of one constructor, each with its
    path in the value; nothing for any other type. ctx -> info -> typ ->
    [(string, string)] *)
let sole_fields ctx info t =
  match t with
  | TCon (_, canonical, args, _) -> (
      let Datatype (_, _, ctors, _), _ = datatype_of ctx info canonical args in
      match ctors with
      | [ (_, fields) ] ->
          List.concat
            (List.map2
               (fun member (label, _) ->
                 match label with Some l -> [ (l, member) ] | None -> [])
               (member_names true fields) fields)
      | _ -> [])
  | _ -> []

(** Whether a type is a datatype of one constructor, which C writes as a
    plain struct. ctx -> info -> typ -> bool *)
let sole_constructor ctx info t =
  match t with
  | TCon (_, canonical, args, _) ->
      let Datatype (_, _, ctors, _), _ = datatype_of ctx info canonical args in
      List.length ctors = 1
  | _ -> false

(** A constructor's tag: its position in its datatype. ctx -> info -> typ
    -> string -> int *)
let ctor_tag ctx info t name =
  match t with
  | TCon (_, canonical, args, _) ->
      let Datatype (_, _, ctors, _), _ = datatype_of ctx info canonical args in
      let rec go i = function [] -> 0 | (c, _) :: rest -> if c = name then i else go (i + 1) rest in
      go 0 ctors
  | _ -> 0

(** Whether t is a `var struct`'s type: one whose value is a pointer to
    a struct written in place, on every C target. ctx -> typ -> bool *)
let var_struct ctx t =
  match t with
  | TCon (_, c, _, _) when Classes.find ctx.classes c <> None -> true
  | TCon (_, c, _, _) when not (is_store c) -> (
      match SMap.find_opt c ctx.datatypes with Some (Datatype (_, _, _, writable)) -> writable | None -> false)
  | _ -> false

(** Whether a datatype instance holds itself, directly or through another
    datatype, a tuple or a list: the one a tagged union by value cannot
    be. An array, a DynArray or a var struct on the way holds a pointer
    already, which ends the search. ctx -> info -> typ -> bool *)
let holds_itself ctx info t =
  let rec reaches seen t target =
    match t with
    | TCon (_, c, _, _) when is_store c -> false
    | TCon _ when var_struct ctx t -> false
    | TList (_, e, _) -> reaches seen e target
    | TCon (_, c, args, _) ->
        let key = c ^ "/" ^ code ctx.own info t in
        if key = target then true
        else if List.mem key seen then false
        else
          let Datatype (_, _, ctors, _), bound = datatype_of ctx info c args in
          List.exists
            (fun (_, fields) -> List.exists (fun (_, ft) -> reaches (key :: seen) (substitute bound ft) target) fields)
            ctors
    | TTuple (_, es, _) -> List.exists (fun e -> reaches seen e target) es
    | _ -> false
  in
  match t with
  | TCon (_, c, _, _) when is_store c || var_struct ctx t -> false
  | TCon (_, c, args, _) ->
      let key = c ^ "/" ^ code ctx.own info t in
      let Datatype (_, _, ctors, _), bound = datatype_of ctx info c args in
      List.exists
        (fun (_, fields) -> List.exists (fun (_, ft) -> reaches [] (substitute bound ft) key) fields)
        ctors
  | _ -> false

(** Whether a value of datatype t is a pointer to its struct: a var
    struct on every C target, and a datatype holding itself on c23-gc
    (plain C refuses one). ctx -> typ -> bool *)
let boxed ctx t =
  var_struct ctx t
  || ctx.gc
     && match t with TCon (_, c, _, _) when not (is_store c) -> holds_itself ctx no_info t | _ -> false

(** How a member of a datatype's value is reached: `->` through the
    pointer a var struct or a datatype holding itself is, `.` otherwise.
    ctx -> typ -> string *)
let member_of ctx t = if boxed ctx t then "->" else "."

(** The types a value of type t holds directly. ctx -> typ -> [typ] *)
let type_children ctx t =
  match t with
  | TTuple (_, es, _) -> es
  | TList (_, e, _) -> [ list_element e ]
  | TCon (_, c, [ e ], _) when is_store c -> [ e ]
  | TCon (_, c, [ k; v ], _) when c = mutmap_name -> [ k; v ]
  | TCon (_, c, args, _) -> (
      match SMap.find_opt c ctx.datatypes with
      | Some (Datatype (_, params, ctors, _)) ->
          let bound = if List.length params = List.length args then List.combine params args else [] in
          List.concat_map (fun (_, fields) -> List.map (fun (_, ft) -> substitute bound ft) fields) ctors
      | None -> [])
  | _ -> []

(** A type's code, where it has one. ctx -> typ -> string option *)
let code_opt ctx t = try Some (code ctx.own no_info t) with Unsupported _ -> None

(** Whether t, or a type a value of it holds however deep, is one wanted
    says. ctx -> (typ -> bool) -> typ -> bool *)
let reaches_type ctx wanted t =
  let rec go seen t =
    wanted t
    ||
    match code_opt ctx t with
    | Some k when List.mem k seen -> false
    | key -> List.exists (go (match key with Some k -> k :: seen | None -> seen)) (type_children ctx t)
  in
  go [] t

(* --- arrays ---
   An array is a struct of its length and a pointer to its elements,
   `pyk_a_<code>` per element type, passed by value: the elements are
   shared, and the length never changes. On c23-gc the elements come
   from the collector -- GC_MALLOC_ATOMIC where they hold no pointer, so
   it never scans them -- the size is checked before allocating and
   every index before it is used. Plain C mallocs them, never frees
   them and checks nothing: `a.items[i]` is all an index is. *)

(** Whether a value of type t holds a pointer the collector must see.
    ctx -> [string] -> typ -> bool *)
let rec holds_pointers ctx seen t =
  match substitute ctx.sigma t with
  | TInt _ | TChar _ | TFloat _ | TBool _ -> false
  | TTuple (_, es, _) -> List.exists (holds_pointers ctx seen) es
  | TCon (_, c, _, _) when is_store c && c <> array_name -> true
  | TCon (_, c, _, _) as t when c <> array_name && boxed ctx t -> true
  | TCon (_, c, args, _) when c <> array_name -> (
      if List.mem c seen then false
      else
        match SMap.find_opt c ctx.datatypes with
        | Some (Datatype (_, params, ctors, _)) ->
            let bound = if List.length params = List.length args then List.combine params args else [] in
            List.exists
              (fun (_, fields) -> List.exists (fun (_, ft) -> holds_pointers ctx (c :: seen) (substitute bound ft)) fields)
              ctors
        | None -> true)
  | _ -> true

(** A pointer to values of the C type ct. string -> string *)
let pointer_to ct = if String.length ct > 0 && ct.[String.length ct - 1] = '*' then ct ^ "*" else ct ^ " *"

(* The elements of a new array of n, each size bytes: n checked first,
   never negative and never more bytes than a size_t counts. *)
let array_items_helper =
  String.concat "\n"
    [
      "static void *pyk_array_items(int n, size_t size, int atomic)";
      "{";
      "    void *items;";
      "    if (n < 0) {";
      "        fprintf(stderr, \"error: an array's size is never negative, and this one is %d\\n\", n);";
      "        exit(1);";
      "    }";
      "    if ((size_t)n > ((size_t)-1) / size) {";
      "        items = NULL;";
      "    } else if (n == 0) {";
      "        items = GC_MALLOC_ATOMIC(1);";
      "    } else if (atomic) {";
      "        items = GC_MALLOC_ATOMIC((size_t)n * size);";
      "    } else {";
      "        items = GC_MALLOC((size_t)n * size);";
      "    }";
      "    if (items == NULL) {";
      "        fprintf(stderr, \"error: an array of %d elements is more than this machine can hold\\n\", n);";
      "        exit(1);";
      "    }";
      "    return items;";
      "}";
    ]

(* What reading or writing a[i] checks first. *)
let check_index_helper =
  String.concat "\n"
    [
      "static void pyk_check_index(int i, int n)";
      "{";
      "    if (i < 0 || i >= n) {";
      "        fprintf(stderr, \"error: the index %d is outside an array of %d element%s\\n\", i, n, n == 1 ? \"\" : \"s\");";
      "        exit(1);";
      "    }";
      "}";
    ]

(** A Pyking type as C writes it, every compound type it names declared
    once in the file. ctx -> state -> info -> typ -> (string, state) *)
let rec ctype ctx st info t =
  let t = substitute ctx.sigma t in
  let info = if info.file = "<c>" then type_info t else info in
  match t with
  | TCon (_, c, args, _) when Classes.find ctx.classes c <> None ->
      if args <> [] then
        unsupported info
          (Printf.sprintf "the generic class '%s', which C would need one struct and table of per type it is made at" c);
      ("pyk_obj *", need_objects st)
  | TInt _ | TChar _ -> ("int", st)
  | TFloat _ -> ("double", st)
  | TBool _ -> (bool_type ctx, { st with uses_bool = true })
  | TString _ -> ("const char *", st)
  | TTuple (_, [], _) -> ("int", st)
  | TTuple (_, es, _) ->
      let name = "pyk_t_" ^ code ctx.own info t in
      if List.mem_assoc name st.types then (name, st)
      else
        let fields, st =
          List.fold_left
            (fun (out, st) (i, e) ->
              let ct, st = ctype ctx st info e in
              (out @ [ (ct, Printf.sprintf "a%d" i) ], st))
            ([], st)
            (List.mapi (fun i e -> (i, e)) es)
        in
        let decl =
          Printf.sprintf "typedef struct %s {\n%s\n} %s;" name
            (String.concat "\n" (List.map (fun (ct, n) -> "    " ^ declaration ct n ^ ";") fields))
            name
        in
        let maker =
          Printf.sprintf "static %s pyk_mk_%s(%s)\n{\n    %s v;\n%s\n    return v;\n}" name (code ctx.own info t)
            (String.concat ", " (List.map (fun (ct, n) -> declaration ct n) fields))
            name
            (String.concat "\n" (List.map (fun (_, n) -> Printf.sprintf "    v.%s = %s;" n n) fields))
        in
        let st = { st with types = st.types @ [ (name, decl) ] } in
        (name, need_helper st ("pyk_mk_" ^ code ctx.own info t) maker)
  | TCon (_, c, [ elem ], _) when c = array_name ->
      (* The array's struct, and pyk_new_<code>(n), which makes one of n
         elements: zeroed and checked on c23-gc (the collector clears what
         it hands out), plain malloc on plain C. *)
      let acode = code ctx.own info t in
      let name = "pyk_a_" ^ acode in
      if List.mem_assoc name st.types then (name, st)
      else
        let ect, st = ctype ctx st info elem in
        let decl =
          Printf.sprintf "typedef struct %s {\n    int len;\n    %s;\n} %s;" name (declaration (pointer_to ect) "items") name
        in
        let st = { st with types = st.types @ [ (name, decl) ] } in
        let items, st =
          if ctx.gc then
            ( Printf.sprintf "pyk_array_items(n, sizeof(%s), %d)" ect (if holds_pointers ctx [] elem then 0 else 1),
              need_helper st "pyk_array_items" array_items_helper )
          else (Printf.sprintf "malloc(n * sizeof(%s))" ect, st)
        in
        let maker =
          String.concat "\n"
            [
              Printf.sprintf "static %s pyk_new_%s(int n)" name acode;
              "{";
              Printf.sprintf "    %s a;" name;
              "    a.len = n;";
              Printf.sprintf "    a.items = %s;" items;
              "    return a;";
              "}";
            ]
        in
        (name, need_helper st ("pyk_new_" ^ acode) maker)
  | TCon (_, c, [ elem ], _) when c = dynarray_name ->
      (* A DynArray is a pointer to its struct, shared by every name holding
         it: its length, its capacity and its elements, which
         pyk_grow_<code> doubles when they are full -- realloc on plain
         C, the collector's on c23-gc. pyk_new_<code>(n) makes one of n
         elements, for its maker to write. *)
      let vcode = code ctx.own info t in
      let name = "pyk_v_" ^ vcode in
      let shown = name ^ " *" in
      if List.mem_assoc name st.types then (shown, st)
      else
        let ect, st = ctype ctx st info elem in
        if List.mem_assoc name st.types then (shown, st)
        else
          let decl =
            Printf.sprintf "typedef struct %s {\n    int len;\n    int cap;\n    %s;\n} %s;" name
              (declaration (pointer_to ect) "items") name
          in
          let st = { st with types = st.types @ [ (name, decl) ] } in
          let kind = if holds_pointers ctx [] elem then "scanned" else "atomic" in
          let maker =
            String.concat "\n"
              [
                Printf.sprintf "static %s(int n)" (declaration shown ("pyk_new_" ^ vcode));
                "{";
                Printf.sprintf "    %s = \001M:scanned:\001(sizeof *v);" (declaration shown "v");
                "    v->len = n;";
                "    v->cap = n > 4 ? n : 4;";
                Printf.sprintf "    v->items = \001M:%s:\001(v->cap * sizeof *v->items);" kind;
                "    return v;";
                "}";
              ]
          in
          (shown, need_helper st ("pyk_new_" ^ vcode) maker)
  | TCon (_, c, [ target ], _) when c = ptr_name ->
      (* A pointer is C's own. *)
      let tct, st = ctype ctx st info target in
      (pointer_to tct, st)
  | TCon (_, c, [ elem ], _) when c = slice_name ->
      (* A view is a pointer to its struct -- so two views are `same` only
         where they are one -- holding the array's elements, where its
         run starts and its length. `view` makes it (`view_helper`). *)
      let wcode = code ctx.own info t in
      let name = "pyk_w_" ^ wcode in
      let shown = name ^ " *" in
      if List.mem_assoc name st.types then (shown, st)
      else
        let ect, st = ctype ctx st info elem in
        if List.mem_assoc name st.types then (shown, st)
        else
          let decl =
            Printf.sprintf "typedef struct %s {\n    int len;\n    int start;\n    %s;\n} %s;" name
              (declaration (pointer_to ect) "items") name
          in
          (shown, { st with types = st.types @ [ (name, decl) ] })
  | TCon (_, c, [ key; value ], _) when c = mutmap_name ->
      (* A MutMap is a pointer to its struct: its keys and values side by
         side, in the order the keys came. On c23-gc, `slots` is a hash
         index into them (-1 for an empty slot) and `version` counts the
         keys put in and taken out, which a `for` watches; plain C finds
         a key by looking at each in turn. *)
      let mcode = code ctx.own info t in
      let name = "pyk_m_" ^ mcode in
      let shown = name ^ " *" in
      if List.mem_assoc name st.types then (shown, st)
      else
        let kct, st = ctype ctx st info key in
        let vct, st = ctype ctx st info value in
        if List.mem_assoc name st.types then (shown, st)
        else
          let decl =
            String.concat "\n"
              ([ Printf.sprintf "typedef struct %s {" name; "    int len;"; "    int cap;" ]
              @ (if ctx.gc then [ "    int version;"; "    int nslots;"; "    int *slots;" ] else [])
              @ [
                  Printf.sprintf "    %s;" (declaration (pointer_to kct) "keys");
                  Printf.sprintf "    %s;" (declaration (pointer_to vct) "values");
                  Printf.sprintf "} %s;" name;
                ])
          in
          let st = { st with types = st.types @ [ (name, decl) ] } in
          let kind t = if holds_pointers ctx [] t then "scanned" else "atomic" in
          let maker =
            String.concat "\n"
              ([
                 Printf.sprintf "static %s(void)" (declaration shown ("pyk_new_" ^ mcode));
                 "{";
                 Printf.sprintf "    %s = \001M:scanned:\001(sizeof *d);" (declaration shown "d");
               ]
              @ (if ctx.gc then [ "    int i;" ] else [])
              @ [
                  "    d->len = 0;";
                  "    d->cap = 4;";
                  Printf.sprintf "    d->keys = \001M:%s:\001(d->cap * sizeof *d->keys);" (kind key);
                  Printf.sprintf "    d->values = \001M:%s:\001(d->cap * sizeof *d->values);" (kind value);
                ]
              @ (if ctx.gc then
                   [
                     "    d->version = 0;";
                     "    d->nslots = 8;";
                     "    d->slots = GC_MALLOC_ATOMIC(d->nslots * sizeof *d->slots);";
                     "    for (i = 0; i < d->nslots; i++) {";
                     "        d->slots[i] = -1;";
                     "    }";
                   ]
                 else [])
              @ [ "    return d;"; "}" ])
          in
          (shown, need_helper st ("pyk_new_" ^ mcode) maker)
  | TCon (_, canonical, args, _) ->
      let name = "pyk_d_" ^ code ctx.own info t in
      let is_boxed = boxed ctx t in
      (* A datatype holding itself is a pointer to its struct, declared
         ahead so that its fields -- and the list cells holding it --
         can name it before it is complete. *)
      let shown = if is_boxed then name ^ " *" else name in
      (* One that reaches itself through a pointer -- an array's
         elements, a DynArray, a var struct -- is declared ahead too, so the
         store can name it while its fields are worked out. *)
      let ahead =
        is_boxed
        ||
        match code_opt ctx t with
        | Some k -> List.exists (reaches_type ctx (fun u -> code_opt ctx u = Some k)) (type_children ctx t)
        | None -> false
      in
      if List.mem_assoc name st.types || (ahead && List.mem_assoc (name ^ "_fwd") st.types) then (shown, st)
      else (
        if (not ctx.gc) && holds_itself ctx info t then
          unsupported info
            (Printf.sprintf
               "the datatype %s, which holds a value of itself: a value of it \
                is a pointer into a heap that is freed, which plain C has \
                not, and c23-gc compiles it"
               (pprint_type default_config t));
        let st =
          if ahead then { st with types = st.types @ [ (name ^ "_fwd", Printf.sprintf "typedef struct %s %s;" name name) ] }
          else st
        in
        let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
        let sole = List.length ctors = 1 in
        let arms, st =
          List.fold_left
            (fun (out, st) (cname, fields) ->
              let fs, st =
                List.fold_left2
                  (fun (out, st) member (_, ft) ->
                    let ct, st = ctype ctx st info (substitute bound ft) in
                    (out @ [ (ct, member) ], st))
                  ([], st) (member_names sole fields) fields
              in
              (out @ [ (cname, fs) ], st))
            ([], st) ctors
        in
        let members =
          List.filter_map
            (fun (cname, fs) ->
              if fs = [] then None
              else
                Some
                  (Printf.sprintf "        struct {\n%s\n        } %s;"
                     (String.concat "\n" (List.map (fun (ct, n) -> "            " ^ declaration ct n ^ ";") fs))
                     (c_ident cname)))
            arms
        in
        let members = if members = [] then [ "        int unused;" ] else members in
        (* Declared ahead already, a datatype holding itself is completed
           here, by its tag alone. *)
        let opening, closing = if ahead then (Printf.sprintf "struct %s {" name, "};") else (Printf.sprintf "typedef struct %s {" name, Printf.sprintf "} %s;" name) in
        let decl =
          match arms with
          | [ (_, fs) ] ->
              (* One constructor: a plain struct, its fields its members. *)
              Printf.sprintf "%s\n%s\n%s" opening
                (if fs = [] then "    int unused;"
                 else String.concat "\n" (List.map (fun (ct, n) -> "    " ^ declaration ct n ^ ";") fs))
                closing
          | _ ->
              Printf.sprintf "%s\n    int tag;\n    union {\n%s\n    } u;\n%s" opening
                (String.concat "\n" members) closing
        in
        let st = { st with types = st.types @ [ (name, decl) ] } in
        let sel = if is_boxed then "->" else "." in
        let st =
          List.fold_left
            (fun st (tag, (cname, fs)) ->
              let maker_name = Printf.sprintf "pyk_mk_%s_%s" (code ctx.own info t) cname in
              let maker =
                let assignments =
                  (if sole then if fs = [] then [ Printf.sprintf "v%sunused = 0;" sel ] else []
                   else [ Printf.sprintf "v%stag = %d;" sel tag ])
                  @ List.map (fun (_, n) -> Printf.sprintf "v%s%s = %s;" sel (member_path sole cname n) n) fs
                in
                (* A var struct, or one that holds itself, is made on the
                   heap: malloc on plain C; on c23-gc the collector's,
                   atomic where no field holds a pointer. *)
                let made =
                  if is_boxed then
                    let atomic =
                      not
                        (List.exists
                           (fun (_, fields) -> List.exists (fun (_, ft) -> holds_pointers ctx [] (substitute bound ft)) fields)
                           ctors)
                    in
                    Printf.sprintf "%s = \001M:%s:\001(sizeof *v);" (declaration shown "v") (if atomic then "atomic" else "scanned")
                  else Printf.sprintf "%s v;" name
                in
                Printf.sprintf "static %s(%s)\n{\n    %s\n%s\n    return v;\n}" (declaration shown maker_name)
                  (if fs = [] then "void" else String.concat ", " (List.map (fun (ct, n) -> declaration ct n) fs))
                  made
                  (String.concat "\n" (List.map (fun a -> "    " ^ a) assignments))
              in
              need_helper st maker_name maker)
            st
            (List.mapi (fun i a -> (i, a)) arms)
        in
        (shown, st))
  | TFunction (_, _, _, _, _, _, _) ->
      let _, ps, r = function_parts t in
      let name = "pyk_c_" ^ code ctx.own info t in
      if List.mem_assoc name st.types then (name, st)
      else
        let pts, st =
          List.fold_left
            (fun (out, st) p ->
              let ct, st = ctype ctx st info p in
              (out @ [ ct ], st))
            ([], st) ps
        in
        let rt, st = if is_unit r then ("void", st) else ctype ctx st info r in
        (* The function and its environment -- and, where it captures
           nothing, the plain function, which is what a host is handed. *)
        let plain_params = match pts with [] -> "void" | pts -> String.concat ", " pts in
        let decl =
          Printf.sprintf "typedef struct %s {\n    %s;\n    void *env;\n    %s;\n} %s;" name
            (Printf.sprintf "%s (*fn)(%s)" rt (String.concat ", " ("void *" :: pts)))
            (Printf.sprintf "%s (*plain)(%s)" rt plain_params)
            name
        in
        let maker =
          Printf.sprintf
            "static %s pyk_mk_%s(%s (*fn)(%s), void *env, %s (*plain)(%s))\n{\n    %s v;\n    v.fn = fn;\n    v.env = env;\n    v.plain = plain;\n    return v;\n}"
            name (code ctx.own info t) rt (String.concat ", " ("void *" :: pts)) rt plain_params name
        in
        let st = { st with types = st.types @ [ (name, decl) ] } in
        (name, need_helper st ("pyk_mk_" ^ code ctx.own info t) maker)
  | TList (_, elem, _) when ctx.gc ->
      (* A list is a pointer to its first cell, NULL for `[]`: one cell
         type per element type, each cell from the collector. *)
      let lcode = code ctx.own info t in
      let name = "pyk_l_" ^ lcode in
      let shown = name ^ " *" in
      if List.mem_assoc name st.types then (shown, st)
      else
        let ect, st = ctype ctx st info (list_element elem) in
        (* The element may hold this very list: then it is declared by now. *)
        if List.mem_assoc name st.types then (shown, st)
        else
          let decl =
            Printf.sprintf "typedef struct %s {\n    %s;\n    struct %s *tail;\n} %s;" name (declaration ect "head")
              name name
          in
          let st = { st with types = st.types @ [ (name, decl) ] } in
          let maker =
            String.concat "\n"
              [
                Printf.sprintf "static %s(%s, %s)" (declaration shown ("pyk_cons_" ^ lcode)) (declaration ect "head")
                  (declaration shown "tail");
                "{";
                Printf.sprintf "    %s = GC_MALLOC(sizeof *cell);" (declaration shown "cell");
                "    cell->head = head;";
                "    cell->tail = tail;";
                "    return cell;";
                "}";
              ]
          in
          (shown, need_helper st ("pyk_cons_" ^ lcode) maker)
  | TList _ -> unsupported info heap_reason
  | t -> ignore (code ctx.own info t); ("int", st)

(** A declaration of name at the C type text. string -> string -> string *)
and declaration ct name =
  if String.length ct > 0 && ct.[String.length ct - 1] = '*' then ct ^ name else ct ^ " " ^ name

(* --- printing a value ---
   A value is written by a function per compound type, pyk_show_<code>.
   An array, a DynArray or a var struct may hold itself; printing one that is
   already being printed further out writes `...` instead, so each
   printer that can meet one takes the path from the value printed
   first, `up`, a list of pyk_path cells on the C stack. Only a store
   whose own elements or fields can reach its type guards itself, and
   only a type that can reach one takes the path: every other printer is
   as it always was. *)

(* A cell of the path is a store's identity -- `at`, with no `alike` --
   or, for a datatype value, which C copies and so has no identity of
   its own, the value's address and the function that says whether two
   such values are one: the same constructor holding the same stores. *)
let path_type =
  String.concat "\n"
    [
      "typedef struct pyk_path {";
      "    const void *at;";
      "    int (*alike)(const void *, const void *);";
      "    const struct pyk_path *up;";
      "} pyk_path;";
    ]

let on_path_helper =
  String.concat "\n"
    [
      "static int pyk_on_path(const pyk_path *path, const void *at, int (*alike)(const void *, const void *))";
      "{";
      "    for (; path != NULL; path = path->up) {";
      "        if (path->alike == alike && (alike == NULL ? path->at == at : alike(path->at, at))) {";
      "            return 1;";
      "        }";
      "    }";
      "    return 0;";
      "}";
    ]

(** Whether a value of type t can be printed inside itself: a store -- an
    array, a DynArray, a view, a MutMap, a pointer or a var struct -- whose
    elements or fields reach its own type, or a datatype that reaches
    itself through one. ctx -> typ -> bool *)
let cyclic ctx t =
  let is_mutable u = (match u with TCon (_, c, _, _) when is_store c -> true | _ -> false) || var_struct ctx u in
  let datatype = match t with TCon (_, c, _, _) when not (is_store c) -> type_children ctx t <> [] | _ -> false in
  (is_mutable t || (datatype && List.exists (reaches_type ctx is_mutable) (type_children ctx t)))
  &&
  match code_opt ctx t with
  | Some k -> List.exists (reaches_type ctx (fun u -> code_opt ctx u = Some k)) (type_children ctx t)
  | None -> false

(** Whether two values of type t, as texts, are one for the path: the
    same scalar, the same store, the same parts. ctx -> state -> info ->
    typ -> string -> string -> (string, state) *)
let rec shallow ctx st info t a b =
  match t with
  | TTuple (_, [], _) -> ("1", st)
  | TTuple (_, es, _) ->
      List.fold_left
        (fun (out, st) (i, e) ->
          let p, st = shallow ctx st info e (Printf.sprintf "%s.a%d" a i) (Printf.sprintf "%s.a%d" b i) in
          ((if out = "1" then p else out ^ " && " ^ p), st))
        ("1", st)
        (List.mapi (fun i e -> (i, e)) es)
  | TCon (_, c, _, _) when c = array_name -> (Printf.sprintf "%s.items == %s.items" a b, st)
  | TFunction _ -> (Printf.sprintf "%s.fn == %s.fn && %s.env == %s.env" a b a b, st)
  | TCon (_, c, _, _) when (not (is_store c)) && not (boxed ctx t) ->
      let alike, st = alike_helper ctx st info t in
      (Printf.sprintf "%s(&%s, &%s)" alike a b, st)
  | _ -> (Printf.sprintf "%s == %s" a b, st)

(** pyk_alike_<code> for a datatype copied by value: the same
    constructor, its fields the same. ctx -> state -> info -> typ ->
    (string, state) *)
and alike_helper ctx st info t =
  let name = "pyk_alike_" ^ code ctx.own info t in
  let ct, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    match t with
    | TCon (_, canonical, args, _) ->
        let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
        let sole = List.length ctors = 1 in
        let arms, st =
          List.fold_left
            (fun (out, st) (cname, fields) ->
              let parts, st =
                List.fold_left2
                  (fun (out, st) member (_, ft) ->
                    let path = member_path sole cname member in
                    let p, st = shallow ctx st info (substitute bound ft) ("x->" ^ path) ("y->" ^ path) in
                    (out @ [ p ], st))
                  ([], st) (member_names sole fields) fields
              in
              (out @ [ (match parts with [] -> "1" | ps -> String.concat " && " ps) ], st))
            ([], st) ctors
        in
        let body =
          match arms with
          | [ one ] -> [ Printf.sprintf "    return %s;" one ]
          | _ ->
              [ "    if (x->tag != y->tag) {"; "        return 0;"; "    }"; "    switch (x->tag) {" ]
              @ List.mapi (fun i p -> Printf.sprintf "    case %d: return %s;" i p) arms
              @ [ "    }"; "    return 1;" ]
        in
        let text =
          String.concat "\n"
            ([
               Printf.sprintf "static int %s(const void *a, const void *b)" name;
               "{";
               Printf.sprintf "    const %s = a;" (declaration (pointer_to ct) "x");
               Printf.sprintf "    const %s = b;" (declaration (pointer_to ct) "y");
             ]
            @ body @ [ "}" ])
        in
        (name, need_helper st name text)
    | _ -> (name, st)

(** Whether printing a value of type t can meet such a store, and so
    takes the path. ctx -> typ -> bool *)
let needs_path ctx t = reaches_type ctx (cyclic ctx) t

(** The path type and its search, declared once. state -> state *)
let need_path st =
  let st = if List.mem_assoc "pyk_path" st.types then st else { st with types = st.types @ [ ("pyk_path", path_type) ] } in
  need_helper st "pyk_on_path" on_path_helper

(** The function that writes a value of type t as it appears inside a
    larger one (a String quoted), declared once in the file: given the
    value's text and the path's. ctx -> state -> info -> typ ->
    (string -> string -> string, state) *)
let rec shower_at ctx st info t =
  let t = substitute ctx.sigma t in
  (* A printer's call, its signature, and -- for a store that guards
     itself -- the lines that write `...` for it and push it on the path,
     with the path its parts are handed. *)
  let paths = needs_path ctx t in
  let call name = if paths then fun v path -> Printf.sprintf "%s(%s, %s)" name v path else fun v _ -> Printf.sprintf "%s(%s)" name v in
  let params ct = if paths then declaration ct "v" ^ ", const pyk_path *up" else declaration ct "v" in
  let st = if paths then need_path st else st in
  let guard ?(alike = "NULL") id =
    if cyclic ctx t then
      ( [ "    pyk_path here;" ],
        [
          Printf.sprintf "    if (pyk_on_path(up, %s, %s)) {" id alike;
          "        return \"...\";";
          "    }";
          Printf.sprintf "    here.at = %s;" id;
          Printf.sprintf "    here.alike = %s;" alike;
          "    here.up = up;";
        ],
        "&here" )
    else ([], [], "up")
  in
  match t with
  | TCon (_, c, _, _) when Classes.find ctx.classes c <> None ->
      (* An object prints as its class says: `show`, or its header. *)
      ((fun v _ -> Printf.sprintf "pyk_obj_show(%s)" v), need_objects st)
  | TInt _ -> ((fun v _ -> Printf.sprintf "pyk_int_str(%s)" v), need_helper st "pyk_int_str" int_str_helper)
  | TFloat _ -> ((fun v _ -> Printf.sprintf "pyk_float_str(%s)" v), need_float st)
  | TBool _ -> ((fun v _ -> Printf.sprintf "(%s ? \"true\" : \"false\")" v), st)
  | TString _ -> ((fun v _ -> Printf.sprintf "pyk_quote(%s)" v), need_helper st "pyk_quote" quote_helper)
  | TChar _ -> ((fun v _ -> Printf.sprintf "pyk_quote_char(%s)" v), need_char st "pyk_quote_char")
  | TTuple (_, [], _) ->
      (* `()`, the value it is written for still worked out. *)
      let plain v = String.for_all (fun c -> c = '_' || c = '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) v in
      let shown v _ =
        let n = String.length v in
        if plain v then "\"()\""
        else if n > 5 && v.[0] = '(' && String.sub v (n - 4) 4 = ", 0)" then
          (* A call answering unit, `(f(x), 0)`: the call, then `()`. *)
          Printf.sprintf "(%s, \"()\")" (String.sub v 1 (n - 5))
        else Printf.sprintf "((void)(%s), \"()\")" v
      in
      (shown, st)
  | TFunction _ -> ((fun _ _ -> "\"<function>\""), st)
  | TTuple (_, es, _) ->
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let parts, st =
          List.fold_left
            (fun (out, st) (i, e) ->
              let show, st = shower_at ctx st info e in
              (out @ [ show (Printf.sprintf "v.a%d" i) "up" ], st))
            ([], st)
            (List.mapi (fun i e -> (i, e)) es)
        in
        let st = need_concat st in
        let body =
          String.concat "\n"
            ([ "    const char *out = \"(\";" ]
            @ List.mapi
                (fun i p ->
                  (if i > 0 then "    out = pyk_concat(out, \", \");\n" else "")
                  ^ Printf.sprintf "    out = pyk_concat(out, %s);" p)
                parts
            @ [ Printf.sprintf "    return pyk_concat(out, \"%s\");" (if List.length es = 1 then ",)" else ")") ])
        in
        let text = Printf.sprintf "static const char *%s(%s)\n{\n%s\n}" name (params ct) body in
        (call name, need_helper st name text)
  | TCon (_, c, [ elem ], _) when is_store c && c <> ptr_name ->
      (* Written as what makes one, `array([1, 2])` or `dynarray([1, 2])`, its
         elements as they are inside a list. *)
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let show, st = shower_at ctx st info elem in
        let st = need_concat st in
        let sel, opening = if c = dynarray_name then ("->", "dynarray([") else if c = slice_name then ("->", "view([") else (".", "array([") in
        (* A view counts on the path as the array it is a run of. *)
        let decls, checks, inner = guard (if c = array_name then "v.items" else if c = slice_name then "v->items" else "v") in
        let item = if c = slice_name then "v->items[v->start + i]" else Printf.sprintf "v%sitems[i]" sel in
        let text =
          String.concat "\n"
            ([ Printf.sprintf "static const char *%s(%s)" name (params ct); "{"; Printf.sprintf "    const char *out = \"%s\";" opening; "    int i;" ]
            @ decls @ checks
            @ [
                Printf.sprintf "    for (i = 0; i < v%slen; i++) {" sel;
                "        if (i > 0) {";
                "            out = pyk_concat(out, \", \");";
                "        }";
                Printf.sprintf "        out = pyk_concat(out, %s);" (show item inner);
                "    }";
                "    return pyk_concat(out, \"])\");";
                "}";
              ])
        in
        (call name, need_helper st name text)
  | TCon (_, c, [ target ], _) when c = ptr_name ->
      (* `Ptr(12)`: what it points at now, as inside a value. *)
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let decls, checks, inner = guard "v" in
        let show, st = shower_at ctx st info target in
        let st = need_concat st in
        let text =
          String.concat "\n"
            ([ Printf.sprintf "static const char *%s(%s)" name (params ct); "{" ]
            @ decls @ checks
            @ [ Printf.sprintf "    return pyk_concat(pyk_concat(\"Ptr(\", %s), \")\");" (show "*v" inner); "}" ])
        in
        (call name, need_helper st name text)
  | TCon (_, c, [ key; value ], _) when c = mutmap_name ->
      (* `mutmap([("ada", 37), ("bo", 6)])`: its entries as pairs, in order. *)
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let decls, checks, inner = guard "v" in
        let show_key, st = shower_at ctx st info key in
        let show_value, st = shower_at ctx st info value in
        let st = need_concat st in
        let text =
          String.concat "\n"
            ([ Printf.sprintf "static const char *%s(%s)" name (params ct); "{"; "    const char *out = \"mutmap([\";"; "    int i;" ]
            @ decls @ checks
            @ [
                "    for (i = 0; i < v->len; i++) {";
                "        if (i > 0) {";
                "            out = pyk_concat(out, \", \");";
                "        }";
                Printf.sprintf "        out = pyk_concat(pyk_concat(out, \"(\"), %s);" (show_key "v->keys[i]" inner);
                Printf.sprintf "        out = pyk_concat(pyk_concat(out, \", \"), %s);" (show_value "v->values[i]" inner);
                "        out = pyk_concat(out, \")\");";
                "    }";
                "    return pyk_concat(out, \"])\");";
                "}";
              ])
        in
        (call name, need_helper st name text)
  | TList (_, elem, _) ->
      (* `[1, 2]`, each element as it is written inside a value. *)
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let show, st = shower_at ctx st info (list_element elem) in
        let st = need_concat st in
        let text =
          String.concat "\n"
            [
              Printf.sprintf "static const char *%s(%s)" name (params ct);
              "{";
              "    const char *out = \"[\";";
              "    for (; v != NULL; v = v->tail) {";
              Printf.sprintf "        out = pyk_concat(out, %s);" (show "v->head" "up");
              "        if (v->tail != NULL) {";
              "            out = pyk_concat(out, \", \");";
              "        }";
              "    }";
              "    return pyk_concat(out, \"]\");";
              "}";
            ]
        in
        (call name, need_helper st name text)
  | TCon _ when StringSet.mem ("pyk_show_" ^ code ctx.own info t) st.building ->
      (* A datatype reached again while its own printer is being written:
         that printer is called before it is written, so it is declared
         ahead. *)
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      let proto = Printf.sprintf "static const char *%s(%s);" name (params ct) in
      let st = if List.mem_assoc name st.helper_protos then st else { st with helper_protos = st.helper_protos @ [ (name, proto) ] } in
      (call name, st)
  | TCon (_, canonical, args, _) ->
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then (call name, st)
      else
        let st = { st with building = StringSet.add name st.building } in
        let sel = member_of ctx t in
        (* A datatype copied by value is told by what it holds. *)
        let (decls, checks, inner), st =
          if boxed ctx t || not (cyclic ctx t) then (guard "v", st)
          else
            let alike, st = alike_helper ctx st info t in
            (guard ~alike "&v", st)
        in
        let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
        let sole = List.length ctors = 1 in
        let arms, st =
          List.fold_left
            (fun (out, st) (tag, (cname, fields)) ->
              let parts, st =
                List.fold_left2
                  (fun (out, st) member (_, ft) ->
                    let show, st = shower_at ctx st info (substitute bound ft) in
                    (out @ [ show ("v" ^ sel ^ member_path sole cname member) inner ], st))
                  ([], st) (member_names sole fields) fields
              in
              let arm =
                if parts = [] then Printf.sprintf "    case %d: return \"%s\";" tag cname
                else
                  String.concat "\n"
                    ([ Printf.sprintf "    case %d:" tag; Printf.sprintf "        out = \"%s(\";" cname ]
                    @ List.mapi
                        (fun i p ->
                          (if i > 0 then "        out = pyk_concat(out, \", \");\n" else "")
                          ^ Printf.sprintf "        out = pyk_concat(out, %s);" p)
                        parts
                    @ [ "        return pyk_concat(out, \")\");" ])
              in
              (out @ [ arm ], st))
            ([], st)
            (List.mapi (fun i c -> (i, c)) ctors)
        in
        let st = match ctors with [ (_, []) ] -> st | _ -> need_concat st in
        let st = { st with building = StringSet.remove name st.building } in
        let param = params ct in
        let unused = if paths then "    (void)v;\n    (void)up;" else "    (void)v;" in
        let text =
          match (ctors, arms) with
          | [ (cname, []) ], _ ->
              Printf.sprintf "static const char *%s(%s)\n{\n%s\n    return \"%s\";\n}" name param unused cname
          | [ _ ], [ arm ] ->
              (* One constructor: its arm is the whole function, a level
                 less indented and without the `case`. *)
              let lines = List.tl (String.split_on_char '\n' arm) in
              let lines =
                List.map
                  (fun l -> if String.length l >= 4 && String.sub l 0 4 = "    " then String.sub l 4 (String.length l - 4) else l)
                  lines
              in
              Printf.sprintf "static const char *%s(%s)\n{\n    const char *out;\n%s\n}" name param
                (String.concat "\n" (decls @ checks @ lines))
          | _ ->
              Printf.sprintf "static const char *%s(%s)\n{\n    const char *out;\n%s    switch (v%stag) {\n%s\n    }\n    return \"\";\n}" name param
                (String.concat "" (List.map (fun l -> l ^ "\n") (decls @ checks)))
                sel
                (String.concat "\n" arms)
        in
        (call name, need_helper st name text)
  | t ->
      ignore (code ctx.own info t);
      ((fun v _ -> v), st)

(** The function that writes a value of type t as it appears inside a
    larger one, printed on its own: the path starts empty.
    ctx -> state -> info -> typ -> (string -> string, state) *)
let shower ctx st info t =
  let show, st = shower_at ctx st info t in
  ((fun v -> show v "NULL"), st)

(* --- structural equality and hashing ---
   `==` on a list, a tuple, a struct or a datatype compares part by part
   (a Float by IEEE's rule, as C's `==` does), through a function written
   once per type, pyk_eq_<code>, answering 1 or 0. A MutMap's keys are
   compared by the same functions, and on c23-gc hashed by
   pyk_hash_<code>, which agree with them. *)

let hash_string_helper =
  String.concat "\n"
    [
      "static unsigned pyk_hash_string(const char *s)";
      "{";
      "    unsigned h = 2166136261u;";
      "    for (; *s != '\\0'; s++) {";
      "        h = (h ^ (unsigned char)*s) * 16777619u;";
      "    }";
      "    return h;";
      "}";
    ]

(** The function deciding whether two values of type t are equal, as an
    expression of their two texts. kind is "eq" or "hash"; for "hash" the
    function ignores its second text and answers an unsigned. ctx ->
    state -> info -> string -> typ -> (string -> string -> string, state) *)
let rec structural ctx st info kind t =
  let t = substitute ctx.sigma t in
  let eq = kind = "eq" in
  let name = Printf.sprintf "pyk_%s_%s" kind (code ctx.own info t) in
  let call = if eq then fun a b -> Printf.sprintf "%s(%s, %s)" name a b else fun a _ -> Printf.sprintf "%s(%s)" name a in
  let signature ct =
    if eq then Printf.sprintf "static int %s(%s, %s)" name (declaration ct "a") (declaration ct "b")
    else Printf.sprintf "static unsigned %s(%s)" name (declaration ct "a")
  in
  (* Each part, combined: `&&` for equality, `h * 31 +` for a hash. *)
  let combine parts =
    if eq then match parts with [] -> "1" | parts -> String.concat " && " parts
    else List.fold_left (fun h p -> Printf.sprintf "%s * 31u + %s" h p) "17u" parts
  in
  let part st pt pa pb =
    let f, st = structural ctx st info kind pt in
    (f pa pb, st)
  in
  match t with
  | TTuple (_, [], _) -> ((fun _ _ -> if eq then "1" else "0u"), st)
  | TInt _ | TChar _ | TBool _ | TFloat _ ->
      ((fun a b -> if eq then Printf.sprintf "%s == %s" a b else Printf.sprintf "(unsigned)%s" a), st)
  | TCon (_, c, _, _) when c = ptr_name && eq -> ((fun a b -> Printf.sprintf "%s == %s" a b), st)
  | TCon (_, c, _, _) when Classes.find ctx.classes c <> None ->
      (* an object is equal only to itself *)
      ((fun a b -> if eq then Printf.sprintf "%s == %s" a b else Printf.sprintf "(unsigned)(size_t)%s" a), st)
  | TString _ ->
      if eq then ((fun a b -> Printf.sprintf "strcmp(%s, %s) == 0" a b), st)
      else ((fun a _ -> Printf.sprintf "pyk_hash_string(%s)" a), need_helper st "pyk_hash_string" hash_string_helper)
  | _ when List.mem_assoc name st.helpers -> (call, st)
  | _ when StringSet.mem name st.building ->
      (* Reached again while it is being written: declared ahead. *)
      let ct, st = ctype ctx st info t in
      let st =
        if List.mem_assoc name st.helper_protos then st
        else { st with helper_protos = st.helper_protos @ [ (name, signature ct ^ ";") ] }
      in
      (call, st)
  | TTuple (_, es, _) ->
      let ct, st = ctype ctx st info t in
      let st = { st with building = StringSet.add name st.building } in
      let parts, st =
        List.fold_left
          (fun (out, st) (i, e) ->
            let p, st = part st e (Printf.sprintf "a.a%d" i) (Printf.sprintf "b.a%d" i) in
            (out @ [ p ], st))
          ([], st)
          (List.mapi (fun i e -> (i, e)) es)
      in
      let st = { st with building = StringSet.remove name st.building } in
      (call, need_helper st name (String.concat "\n" [ signature ct; "{"; Printf.sprintf "    return %s;" (combine parts); "}" ]))
  | TList (_, elem, _) ->
      let ct, st = ctype ctx st info t in
      let st = { st with building = StringSet.add name st.building } in
      let p, st = part st (list_element elem) "a->head" "b->head" in
      let st = { st with building = StringSet.remove name st.building } in
      let lines =
        if eq then
          [
            signature ct; "{"; "    for (; a != NULL && b != NULL; a = a->tail, b = b->tail) {";
            Printf.sprintf "        if (!(%s)) {" p; "            return 0;"; "        }"; "    }";
            "    return a == NULL && b == NULL;"; "}";
          ]
        else
          [ signature ct; "{"; "    unsigned h = 17u;"; "    for (; a != NULL; a = a->tail) {"; Printf.sprintf "        h = h * 31u + %s;" p;
            "    }"; "    return h;"; "}" ]
      in
      (call, need_helper st name (String.concat "\n" lines))
  | TCon (_, canonical, args, _) when not (is_store canonical) ->
      let ct, st = ctype ctx st info t in
      let st = { st with building = StringSet.add name st.building } in
      let sel = member_of ctx t in
      let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
      let sole = List.length ctors = 1 in
      let arms, st =
        List.fold_left
          (fun (out, st) (cname, fields) ->
            let parts, st =
              List.fold_left2
                (fun (out, st) member (_, ft) ->
                  let path = member_path sole cname member in
                  let p, st = part st (substitute bound ft) ("a" ^ sel ^ path) ("b" ^ sel ^ path) in
                  (out @ [ p ], st))
                ([], st) (member_names sole fields) fields
            in
            (out @ [ parts ], st))
          ([], st) ctors
      in
      let st = { st with building = StringSet.remove name st.building } in
      let body =
        match arms with
        | [ parts ] ->
            (if parts = [] then [ (if eq then "    (void)a;\n    (void)b;" else "    (void)a;") ] else [])
            @ [ Printf.sprintf "    return %s;" (combine parts) ]
        | _ ->
            (if eq then [ Printf.sprintf "    if (a%stag != b%stag) {" sel sel; "        return 0;"; "    }" ] else [])
            @ [ Printf.sprintf "    switch (a%stag) {" sel ]
            @ List.mapi
                (fun i parts ->
                  let parts = if eq then parts else Printf.sprintf "%du" i :: parts in
                  Printf.sprintf "    case %d: return %s;" i (combine parts))
                arms
            @ [ "    }"; (if eq then "    return 1;" else "    return 0u;") ]
      in
      (call, need_helper st name (String.concat "\n" ([ signature ct; "{" ] @ body @ [ "}" ])))
  | t -> unsupported info (Printf.sprintf "`==` on a value of type %s" (pprint_type default_config t))

(** What print writes for v, a value of type t: its text.
    ctx -> state -> info -> typ -> cexpr -> (string, state) *)
let printed ctx st info t (v : cexpr) =
  match substitute ctx.sigma t with
  | TString _ -> (v.text, st)
  | TChar _ -> (Printf.sprintf "pyk_utf8(%s)" v.text, need_char st "pyk_utf8")
  | t ->
      let show, st = shower ctx st info t in
      (show v.text, st)

(* --- lists ---
   On c23-gc a list is a pointer to its first cell, NULL for `[]`; a
   cell (`pyk_l_<code>`) holds an element and the rest of the list, and
   comes from the collector. Lists are never changed, so a list shares
   its cells with every list built onto it. Each helper below is written
   once per element type, named by the list's code: pyk_length_Li_. *)

(* What reading xs[i] outside the list stops the program with. *)
let list_index_helper =
  String.concat "\n"
    [
      "static void pyk_list_index(int i, int n)";
      "{";
      "    fprintf(stderr, \"error: the index %d is outside a list of %d element%s\\n\", i, n, n == 1 ? \"\" : \"s\");";
      "    exit(1);";
      "}";
    ]

(* What `range` with a step of 0 stops the program with. *)
let range_helper =
  String.concat "\n"
    [
      "static pyk_l_Li_ *pyk_range(int start, int stop, int step)";
      "{";
      "    pyk_l_Li_ *result = NULL;";
      "    pyk_l_Li_ **end = &result;";
      "    int n;";
      "    if (step == 0) {";
      "        fprintf(stderr, \"error: 'range' step must not be zero\\n\");";
      "        exit(1);";
      "    }";
      "    for (n = start; step > 0 ? n < stop : n > stop; n += step) {";
      "        *end = pyk_cons_Li_(n, NULL);";
      "        end = &(*end)->tail;";
      "    }";
      "    return result;";
      "}";
    ]

(** A helper over lists of type t -- `length`, `nth`, `take`, `drop`,
    `append` or `array` -- written once in the file: its name.
    ctx -> state -> info -> typ -> string -> (string, state) *)
let rec list_helper ctx st info t kind =
  let t = substitute ctx.sigma t in
  let lcode = code ctx.own info t in
  let name = Printf.sprintf "pyk_%s_%s" (if kind = "array" then "array_of" else kind) lcode in
  let lt, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    let elem = match t with TList (_, e, _) -> list_element e | _ -> TTuple (no_info, [], 0) in
    let ect, st = ctype ctx st info elem in
    let fn result params = Printf.sprintf "static %s(%s)" (declaration result name) (String.concat ", " params) in
    let lines, st =
      match kind with
      | "length" ->
          ( [ fn "int" [ declaration lt "xs" ]; "{"; "    int n = 0;"; "    for (; xs != NULL; xs = xs->tail) {"; "        n++;"; "    }";
              "    return n;"; "}" ],
            st )
      | "nth" ->
          let length, st = list_helper ctx st info t "length" in
          ( [
              fn ect [ declaration lt "xs"; "int i" ];
              "{";
              Printf.sprintf "    %s = xs;" (declaration lt "p");
              "    int k;";
              "    for (k = 0; k < i && p != NULL; k++) {";
              "        p = p->tail;";
              "    }";
              "    if (i < 0 || p == NULL) {";
              Printf.sprintf "        pyk_list_index(i, %s(xs));" length;
              "    }";
              "    return p->head;";
              "}";
            ],
            need_helper st "pyk_list_index" list_index_helper )
      | "take" ->
          ( [
              fn lt [ declaration lt "xs"; "int n" ];
              "{";
              Printf.sprintf "    %s = NULL;" (declaration lt "result");
              Printf.sprintf "    %s = &result;" (declaration (pointer_to lt) "end");
              "    for (; n > 0 && xs != NULL; n--, xs = xs->tail) {";
              Printf.sprintf "        *end = pyk_cons_%s(xs->head, NULL);" lcode;
              "        end = &(*end)->tail;";
              "    }";
              "    return result;";
              "}";
            ],
            st )
      | "drop" ->
          ( [ fn lt [ declaration lt "xs"; "int n" ]; "{"; "    for (; n > 0 && xs != NULL; n--) {"; "        xs = xs->tail;"; "    }";
              "    return xs;"; "}" ],
            st )
      | "append" ->
          (* a's elements in cells of their own, the last one's tail b:
             b itself is shared, never copied. *)
          ( [
              fn lt [ declaration lt "a"; declaration lt "b" ];
              "{";
              Printf.sprintf "    %s = b;" (declaration lt "result");
              Printf.sprintf "    %s = &result;" (declaration (pointer_to lt) "end");
              "    for (; a != NULL; a = a->tail) {";
              Printf.sprintf "        *end = pyk_cons_%s(a->head, b);" lcode;
              "        end = &(*end)->tail;";
              "    }";
              "    return result;";
              "}";
            ],
            st )
      | _ ->
          (* An array of the list's elements, in order. *)
          let at = TCon (no_info, array_name, [ elem ], 0) in
          let act, st = ctype ctx st info at in
          let length, st = list_helper ctx st info t "length" in
          ( [
              fn act [ declaration lt "xs" ];
              "{";
              Printf.sprintf "    %s = pyk_new_%s(%s(xs));" (declaration act "a") (code ctx.own info at) length;
              "    int i;";
              "    for (i = 0; xs != NULL; xs = xs->tail, i++) {";
              "        a.items[i] = xs->head;";
              "    }";
              "    return a;";
              "}";
            ],
            st )
    in
    (name, need_helper st name (String.concat "\n" lines))

(* --- DynArrays ---
   A DynArray is a pointer to `pyk_v_<code>`, its length, its capacity and
   its elements. Plain C checks nothing: popping an empty DynArray or an index
   outside it is undefined, as in C. c23-gc checks each, with the
   messages every target writes, and clears a slot an element leaves so
   the collector does not keep what it held. *)

let dynarray_index_helper =
  String.concat "\n"
    [
      "static void pyk_check_dynarray_index(int i, int n)";
      "{";
      "    if (i < 0 || i >= n) {";
      "        fprintf(stderr, \"error: the index %d is outside a DynArray of %d element%s\\n\", i, n, n == 1 ? \"\" : \"s\");";
      "        exit(1);";
      "    }";
      "}";
    ]

(** A helper over DynArrays of type t -- `push`, `pop`, `insert`, `remove`,
    `clear`, `at` (a checked read) or `of_list` -- written once in the
    file: its name. ctx -> state -> info -> typ -> string -> (string,
    state) *)
let dynarray_helper ctx st info t kind =
  let t = substitute ctx.sigma t in
  let vcode = code ctx.own info t in
  let name = Printf.sprintf "pyk_%s_%s" kind vcode in
  let vt, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    let elem = Option.value (dynarray_element t) ~default:(TTuple (no_info, [], 0)) in
    let ect, st = ctype ctx st info elem in
    let fn result params = Printf.sprintf "static %s(%s)" (declaration result name) (String.concat ", " params) in
    let grow = "pyk_grow_" ^ vcode in
    (* What push and insert make room with: the elements doubled when
       they are full. *)
    let need_grow st =
      need_helper st grow
        (String.concat "\n"
           [
             Printf.sprintf "static void %s(%s)" grow (declaration vt "v");
             "{";
             "    if (v->len == v->cap) {";
             "        v->cap *= 2;";
             "        v->items = \001M:resize:\001(v->items, v->cap * sizeof *v->items);";
             "    }";
             "}";
           ])
    in
    (* On c23-gc, a slot an element leaves is cleared where it can hold a
       pointer. *)
    let clears = ctx.gc && holds_pointers ctx [] elem in
    let check_index st = if ctx.gc then ([ "    pyk_check_dynarray_index(i, v->len);" ], need_helper st "pyk_check_dynarray_index" dynarray_index_helper) else ([], st) in
    let lines, st =
      match kind with
      | "push" ->
          ([ fn "void" [ declaration vt "v"; declaration ect "x" ]; "{"; Printf.sprintf "    %s(v);" grow; "    v->items[v->len++] = x;"; "}" ], need_grow st)
      | "pop" ->
          ( [ fn ect [ declaration vt "v" ]; "{"; Printf.sprintf "    %s;" (declaration ect "x") ]
            @ (if ctx.gc then
                 [ "    if (v->len == 0) {"; "        fprintf(stderr, \"error: pop from an empty DynArray\\n\");"; "        exit(1);"; "    }" ]
               else [])
            @ [ "    x = v->items[--v->len];" ]
            @ (if clears then [ "    memset(&v->items[v->len], 0, sizeof *v->items);" ] else [])
            @ [ "    return x;"; "}" ],
            st )
      | "insert" ->
          ( [ fn "void" [ declaration vt "v"; "int i"; declaration ect "x" ]; "{"; "    int k;" ]
            @ (if ctx.gc then
                 [
                   "    if (i < 0 || i > v->len) {";
                   "        fprintf(stderr, \"error: insert's index %d is outside 0 to %d, the DynArray's length\\n\", i, v->len);";
                   "        exit(1);";
                   "    }";
                 ]
               else [])
            @ [ Printf.sprintf "    %s(v);" grow; "    for (k = v->len; k > i; k--) {"; "        v->items[k] = v->items[k - 1];"; "    }";
                "    v->items[i] = x;"; "    v->len++;"; "}" ],
            need_grow st )
      | "remove" ->
          let checks, st = check_index st in
          ( [ fn ect [ declaration vt "v"; "int i" ]; "{"; Printf.sprintf "    %s;" (declaration ect "x"); "    int k;" ]
            @ checks
            @ [ "    x = v->items[i];"; "    for (k = i + 1; k < v->len; k++) {"; "        v->items[k - 1] = v->items[k];"; "    }"; "    v->len--;" ]
            @ (if clears then [ "    memset(&v->items[v->len], 0, sizeof *v->items);" ] else [])
            @ [ "    return x;"; "}" ],
            st )
      | "clear" ->
          ( [ fn "void" [ declaration vt "v" ]; "{" ]
            @ (if clears then [ "    memset(v->items, 0, v->len * sizeof *v->items);" ] else [])
            @ [ "    v->len = 0;"; "}" ],
            st )
      | "at" ->
          let checks, st = check_index st in
          ([ fn ect [ declaration vt "v"; "int i" ]; "{" ] @ checks @ [ "    return v->items[i];"; "}" ], st)
      | _ ->
          (* A DynArray of a list's elements, in order. *)
          let lt = TList (no_info, elem, 0) in
          let lct, st = ctype ctx st info lt in
          let length, st = list_helper ctx st info lt "length" in
          ( [
              fn vt [ declaration lct "xs" ];
              "{";
              Printf.sprintf "    %s = pyk_new_%s(%s(xs));" (declaration vt "v") vcode length;
              "    int i;";
              "    for (i = 0; xs != NULL; xs = xs->tail, i++) {";
              "        v->items[i] = xs->head;";
              "    }";
              "    return v;";
              "}";
            ],
            st )
    in
    (name, need_helper st name (String.concat "\n" lines))

(* --- MutMaps ---
   A MutMap is a pointer to `pyk_m_<code>`: `len` entries, their keys and
   values side by side in the order the keys came; a key's entry keeps
   its place when its value is replaced, and removing one moves the later
   ones down. pyk_find_<code> answers a key's position, or -1. On c23-gc
   it looks the key up in `slots`, a hash index of the positions, which
   is rebuilt when it fills or an entry moves, and `version` counts the
   keys put in and taken out; a missing key and a MutMap changed under a
   `for` stop the program. Plain C looks at each key in turn and checks
   nothing: a missing key is undefined there. *)

let mutmap_walk_helper =
  String.concat "\n"
    [
      "static void pyk_mutmap_walk(int now, int then)";
      "{";
      "    if (now != then) {";
      "        fprintf(stderr, \"error: the MutMap changed while a for loop was reading it\\n\");";
      "        exit(1);";
      "    }";
      "}";
    ]

(** A helper over MutMaps of type t -- `find`, `index` and `slot` (c23-gc),
    `put`, `at`, `remove`, `discard`, `get`, `has`, `keys`, `values`,
    `items`, `clear` or `of_list` -- written once in the file: its name.
    ctx -> state -> info -> typ -> string -> (string, state) *)
let rec mutmap_helper ctx st info t kind =
  let t = substitute ctx.sigma t in
  let mcode = code ctx.own info t in
  let name = Printf.sprintf "pyk_%s_%s" kind mcode in
  let dt, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    let key, value = Option.value (mutmap_parts t) ~default:(TTuple (no_info, [], 0), TTuple (no_info, [], 0)) in
    let kct, st = ctype ctx st info key in
    let vct, st = ctype ctx st info value in
    let fn result params = Printf.sprintf "static %s(%s)" (declaration result name) (String.concat ", " params) in
    let d = declaration dt "d" in
    let helper st kind = mutmap_helper ctx st info t kind in
    let eq, st = structural ctx st info "eq" key in
    (* On c23-gc, an entry's memory left behind is cleared where it can
       hold a pointer, so the collector does not keep what it held. *)
    let clears what elem = if ctx.gc && holds_pointers ctx [] elem then [ Printf.sprintf "    memset(&d->%s[d->len], 0, sizeof *d->%s);" what what ] else [] in
    let missing st suffix =
      if ctx.gc then
        let show, st = shower ctx st info key in
        ( [
            "    if (i < 0) {";
            Printf.sprintf "        fprintf(stderr, \"error: the MutMap has no key %%s%s\\n\", %s);" suffix (show "k");
            "        exit(1);";
            "    }";
          ],
          st )
      else ([], st)
    in
    let list_of st elem pick =
      let lt = TList (no_info, elem, 0) in
      let lct, st = ctype ctx st info lt in
      let lcode = code ctx.own info lt in
      ( [
          fn lct [ d ];
          "{";
          Printf.sprintf "    %s = NULL;" (declaration lct "result");
          Printf.sprintf "    %s = &result;" (declaration (pointer_to lct) "end");
          "    int i;";
          "    for (i = 0; i < d->len; i++) {";
          Printf.sprintf "        *end = pyk_cons_%s(%s, NULL);" lcode pick;
          "        end = &(*end)->tail;";
          "    }";
          "    return result;";
          "}";
        ],
        st )
    in
    let lines, st =
      match kind with
      | "find" when ctx.gc ->
          let hash, st = structural ctx st info "hash" key in
          ( [
              fn "int" [ d; declaration kct "k" ];
              "{";
              "    unsigned mask = (unsigned)d->nslots - 1u;";
              Printf.sprintf "    unsigned h = (%s * 2654435761u) & mask;" (hash "k" "");
              "    for (; d->slots[h] != -1; h = (h + 1u) & mask) {";
              Printf.sprintf "        if (%s) {" (eq "d->keys[d->slots[h]]" "k");
              "            return d->slots[h];";
              "        }";
              "    }";
              "    return -1;";
              "}";
            ],
            st )
      | "find" ->
          ( [
              fn "int" [ d; declaration kct "k" ];
              "{";
              "    int i;";
              "    for (i = 0; i < d->len; i++) {";
              Printf.sprintf "        if (%s) {" (eq "d->keys[i]" "k");
              "            return i;";
              "        }";
              "    }";
              "    return -1;";
              "}";
            ],
            st )
      | "slot" ->
          (* Entry i put in the hash index. *)
          let hash, st = structural ctx st info "hash" key in
          ( [
              fn "void" [ d; "int i" ];
              "{";
              "    unsigned mask = (unsigned)d->nslots - 1u;";
              Printf.sprintf "    unsigned h = (%s * 2654435761u) & mask;" (hash "d->keys[i]" "");
              "    while (d->slots[h] != -1) {";
              "        h = (h + 1u) & mask;";
              "    }";
              "    d->slots[h] = i;";
              "}";
            ],
            st )
      | "index" ->
          (* The hash index made again, at least twice as big as the
             entries, so a slot is always free. *)
          let slot, st = helper st "slot" in
          ( [
              fn "void" [ d ];
              "{";
              "    int i;";
              "    while (d->nslots < 2 * d->len + 2) {";
              "        d->nslots *= 2;";
              "    }";
              "    d->slots = GC_MALLOC_ATOMIC(d->nslots * sizeof *d->slots);";
              "    for (i = 0; i < d->nslots; i++) {";
              "        d->slots[i] = -1;";
              "    }";
              "    for (i = 0; i < d->len; i++) {";
              Printf.sprintf "        %s(d, i);" slot;
              "    }";
              "}";
            ],
            st )
      | "put" ->
          let find, st = helper st "find" in
          let grown, st =
            if ctx.gc then
              let index, st = helper st "index" in
              let slot, st = helper st "slot" in
              ( [
                  "    d->version++;";
                  "    if (2 * d->len + 2 > d->nslots) {";
                  Printf.sprintf "        %s(d);" index;
                  "    } else {";
                  Printf.sprintf "        %s(d, d->len - 1);" slot;
                  "    }";
                ],
                st )
            else ([], st)
          in
          ( [
              fn "void" [ d; declaration kct "k"; declaration vct "v" ];
              "{";
              Printf.sprintf "    int i = %s(d, k);" find;
              "    if (i >= 0) {";
              "        d->values[i] = v;";
              "        return;";
              "    }";
              "    if (d->len == d->cap) {";
              "        d->cap *= 2;";
              "        d->keys = \001M:resize:\001(d->keys, d->cap * sizeof *d->keys);";
              "        d->values = \001M:resize:\001(d->values, d->cap * sizeof *d->values);";
              "    }";
              "    d->keys[d->len] = k;";
              "    d->values[d->len] = v;";
              "    d->len++;";
            ]
            @ grown @ [ "}" ],
            st )
      | "at" ->
          let find, st = helper st "find" in
          let checks, st = missing st "" in
          ([ fn vct [ d; declaration kct "k" ]; "{"; Printf.sprintf "    int i = %s(d, k);" find ] @ checks @ [ "    return d->values[i];"; "}" ], st)
      | "take" ->
          (* Entry i taken out, the later ones moved down. *)
          let rest, st =
            if ctx.gc then
              let index, st = helper st "index" in
              ([ "    d->version++;"; Printf.sprintf "    %s(d);" index ], st)
            else ([], st)
          in
          ( [
              fn "void" [ d; "int i" ];
              "{";
              "    for (; i + 1 < d->len; i++) {";
              "        d->keys[i] = d->keys[i + 1];";
              "        d->values[i] = d->values[i + 1];";
              "    }";
              "    d->len--;";
            ]
            @ clears "keys" key @ clears "values" value @ rest @ [ "}" ],
            st )
      | "remove" ->
          let find, st = helper st "find" in
          let take, st = helper st "take" in
          let checks, st = missing st " to remove" in
          ( [ fn vct [ d; declaration kct "k" ]; "{"; Printf.sprintf "    int i = %s(d, k);" find; Printf.sprintf "    %s;" (declaration vct "v") ]
            @ checks
            @ [ "    v = d->values[i];"; Printf.sprintf "    %s(d, i);" take; "    return v;"; "}" ],
            st )
      | "discard" ->
          let find, st = helper st "find" in
          let take, st = helper st "take" in
          ( [ fn "void" [ d; declaration kct "k" ]; "{"; Printf.sprintf "    int i = %s(d, k);" find; "    if (i >= 0) {";
              Printf.sprintf "        %s(d, i);" take; "    }"; "}" ],
            st )
      | "get" ->
          let find, st = helper st "find" in
          ( [ fn vct [ d; declaration kct "k"; declaration vct "otherwise" ]; "{"; Printf.sprintf "    int i = %s(d, k);" find;
              "    return i >= 0 ? d->values[i] : otherwise;"; "}" ],
            st )
      | "has" ->
          let find, st = helper st "find" in
          ([ fn "int" [ d; declaration kct "k" ]; "{"; Printf.sprintf "    return %s(d, k) >= 0;" find; "}" ], st)
      | "keys" -> list_of st key "d->keys[i]"
      | "values" -> list_of st value "d->values[i]"
      | "items" ->
          let pair = TTuple (no_info, [ key; value ], 0) in
          let _, st = ctype ctx st info pair in
          list_of st pair (Printf.sprintf "pyk_mk_%s(d->keys[i], d->values[i])" (code ctx.own info pair))
      | "clear" ->
          let rest =
            if ctx.gc then
              [ "    int i;" ]
              @ (if holds_pointers ctx [] key then [ "    memset(d->keys, 0, d->len * sizeof *d->keys);" ] else [])
              @ (if holds_pointers ctx [] value then [ "    memset(d->values, 0, d->len * sizeof *d->values);" ] else [])
              @ [ "    d->version++;"; "    for (i = 0; i < d->nslots; i++) {"; "        d->slots[i] = -1;"; "    }" ]
            else []
          in
          ([ fn "void" [ d ]; "{" ] @ rest @ [ "    d->len = 0;"; "}" ], st)
      | _ ->
          (* A MutMap of a list of pairs: a key written twice keeps its first
             place and its last value. *)
          let pair = TTuple (no_info, [ key; value ], 0) in
          let lt = TList (no_info, pair, 0) in
          let lct, st = ctype ctx st info lt in
          let put, st = helper st "put" in
          ( [
              fn dt [ declaration lct "pairs" ];
              "{";
              Printf.sprintf "    %s = pyk_new_%s();" (declaration dt "d") mcode;
              "    for (; pairs != NULL; pairs = pairs->tail) {";
              Printf.sprintf "        %s(d, pairs->head.a0, pairs->head.a1);" put;
              "    }";
              "    return d;";
              "}";
            ],
            st )
    in
    (name, need_helper st name (String.concat "\n" lines))

(** How a `for` walks an array, a DynArray, a view or a MutMap t held in held,
    by the index idx: the element's type, the declarations it needs
    (version, a MutMap's version when the walk began, on c23-gc), the
    loop's test and the element read. A MutMap's walk is its keys, and on
    c23-gc checks at every advance that no key came or went.
    ctx -> state -> typ -> string -> string -> string -> (typ, [cstmt],
    string, string, state) *)
let walk_of ctx st t held idx version =
  match (mutmap_parts t, slice_element t, dynarray_element t, store_element t) with
  | Some (key, _), _, _, _ ->
      if ctx.gc then
        ( key,
          [ CDecl ("int", version, Some (held ^ "->version")) ],
          Printf.sprintf "pyk_mutmap_walk(%s->version, %s), %s < %s->len" held version idx held,
          Printf.sprintf "%s->keys[%s]" held idx,
          need_helper st "pyk_mutmap_walk" mutmap_walk_helper )
      else (key, [], Printf.sprintf "%s < %s->len" idx held, Printf.sprintf "%s->keys[%s]" held idx, st)
  | _, Some e, _, _ -> (e, [], Printf.sprintf "%s < %s->len" idx held, Printf.sprintf "%s->items[%s->start + %s]" held held idx, st)
  | _, _, Some e, _ -> (e, [], Printf.sprintf "%s < %s->len" idx held, Printf.sprintf "%s->items[%s]" held idx, st)
  | _, _, _, Some e -> (e, [], Printf.sprintf "%s < %s.len" idx held, Printf.sprintf "%s.items[%s]" held idx, st)
  | _ -> (t, [], "0", "0", st)

(* --- slices and views ---
   `s[i:j]` copies a run of a list, a String, an array, a DynArray or a view
   into a new value of its own kind (a view's into an array), through
   pyk_slice_<code>. A view is a pointer to `pyk_w_<code>`, sharing its
   array's elements: element k is `items[start + k]`. c23-gc checks
   every bound with the messages every target writes; plain C checks
   none. *)

(** The plural every bounds message ends with. *)
let plural = "n == 1 ? \"\" : \"s\""

(** A helper over slices and views -- `slice` of a sequence of type t,
    `view` of an array or a view t, `at` of a view t -- written once:
    its name. ctx -> state -> info -> typ -> string -> (string, state) *)
let run_helper ctx st info t kind =
  let t = substitute ctx.sigma t in
  let tcode = code ctx.own info t in
  let name = Printf.sprintf "pyk_%s_%s" kind tcode in
  let ct, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    let fn result params = Printf.sprintf "static %s(%s)" (declaration result name) (String.concat ", " params) in
    (* What the bounds of a slice or a view of n elements are checked
       against, on c23-gc. *)
    let bounds what lo hi =
      if ctx.gc then
        [
          Printf.sprintf "    if (%s < 0 || %s > %s || %s > n) {" lo lo hi hi;
          Printf.sprintf "        fprintf(stderr, \"error: %s %%d:%%d is outside %s of %%d element%%s\\n\", %s, %s, n, %s);"
            (if kind = "view" then "the view" else "the slice") what lo hi plural;
          "        exit(1);";
          "    }";
        ]
      else []
    in
    let lines, st =
      match (kind, t) with
      | "view", _ ->
          let elem = Option.value (store_element t) ~default:(TTuple (no_info, [], 0)) in
          let wt, st = ctype ctx st info (TCon (no_info, slice_name, [ elem ], 0)) in
          let is_view = slice_element t <> None in
          ( [ fn wt [ declaration ct "a"; "int i"; "int j" ]; "{"; Printf.sprintf "    int n = a%slen;" (if is_view then "->" else ".");
              Printf.sprintf "    %s = \001M:scanned:\001(sizeof *w);" (declaration wt "w") ]
            @ bounds (if is_view then "a view" else "an array") "i" "j"
            @ (if is_view then [ "    w->items = a->items;"; "    w->start = a->start + i;" ] else [ "    w->items = a.items;"; "    w->start = i;" ])
            @ [ "    w->len = j - i;"; "    return w;"; "}" ],
            st )
      | "place", _ when slice_element t = None ->
          (* An array's element's address, the index checked (c23-gc). *)
          let elem = Option.value (store_element t) ~default:(TTuple (no_info, [], 0)) in
          let ect, st = ctype ctx st info elem in
          let st = need_helper st "pyk_check_index" check_index_helper in
          ([ fn (pointer_to ect) [ declaration ct "a"; "int i" ]; "{"; "    pyk_check_index(i, a.len);"; "    return &a.items[i];"; "}" ], st)
      | "place", _ ->
          (* A view's element's address: its array's, checked on c23-gc. *)
          let elem = Option.value (slice_element t) ~default:(TTuple (no_info, [], 0)) in
          let ect, st = ctype ctx st info elem in
          let checks =
            if ctx.gc then
              [
                "    if (k < 0 || k >= w->len) {";
                "        fprintf(stderr, \"error: the index %d is outside a view of %d element%s\\n\", k, w->len, w->len == 1 ? \"\" : \"s\");";
                "        exit(1);";
                "    }";
              ]
            else []
          in
          ([ fn (pointer_to ect) [ declaration ct "w"; "int k" ]; "{" ] @ checks @ [ "    return &w->items[w->start + k];"; "}" ], st)
      | "at", _ ->
          let elem = Option.value (slice_element t) ~default:(TTuple (no_info, [], 0)) in
          let ect, st = ctype ctx st info elem in
          let checks =
            if ctx.gc then
              [
                "    if (k < 0 || k >= w->len) {";
                "        fprintf(stderr, \"error: the index %d is outside a view of %d element%s\\n\", k, w->len, w->len == 1 ? \"\" : \"s\");";
                "        exit(1);";
                "    }";
              ]
            else []
          in
          ([ fn ect [ declaration ct "w"; "int k" ]; "{" ] @ checks @ [ "    return w->items[w->start + k];"; "}" ], st)
      | _, TString _ ->
          (* By code point: the bytes from the lo-th to the hi-th. *)
          let st = need_char st "pyk_utf8_length" in
          ( [ fn "const char *" [ "const char *s"; "int lo"; "int hi" ]; "{"; "    int n = pyk_utf8_length(s);";
              "    const char *from = s;"; "    const char *to;"; "    char *out;"; "    int c, k;" ]
            @ bounds "a String" "lo" "hi"
            @ [
                "    for (k = 0; k < lo; k++) {";
                "        from = pyk_utf8_step(from, &c);";
                "    }";
                "    to = from;";
                "    for (; k < hi; k++) {";
                "        to = pyk_utf8_step(to, &c);";
                "    }";
                "    out = \001M:atomic:\001((size_t)(to - from) + 1);";
                "    memcpy(out, from, (size_t)(to - from));";
                "    out[to - from] = '\\0';";
                "    return out;";
                "}";
              ],
            st )
      | _, TList _ ->
          let length, st = list_helper ctx st info t "length" in
          let drop, st = list_helper ctx st info t "drop" in
          let take, st = list_helper ctx st info t "take" in
          ( [ fn ct [ declaration ct "xs"; "int lo"; "int hi" ]; "{"; Printf.sprintf "    int n = %s(xs);" length ]
            @ bounds "a list" "lo" "hi"
            @ [ Printf.sprintf "    return %s(%s(xs, lo), hi - lo);" take drop; "}" ],
            st )
      | _ ->
          (* An array, a DynArray or a view: a new array (a new DynArray of a DynArray)
             of the run's elements. *)
          let elem = Option.value (store_element t) ~default:(TTuple (no_info, [], 0)) in
          let is_dynarray = dynarray_element t <> None and is_view = slice_element t <> None in
          let made = if is_dynarray then t else TCon (no_info, array_name, [ elem ], 0) in
          let mt, st = ctype ctx st info made in
          let mcode = code ctx.own info made in
          let what, first = if is_dynarray then ("a DynArray", "a->items") else if is_view then ("a view", "a->items + a->start") else ("an array", "a.items") in
          let sel = if is_dynarray || is_view then "->" else "." in
          ( [ fn mt [ declaration ct "a"; "int lo"; "int hi" ]; "{"; Printf.sprintf "    int n = a%slen;" sel; Printf.sprintf "    %s;" (declaration mt "out"); "    int k;" ]
            @ bounds what "lo" "hi"
            @ [
                Printf.sprintf "    out = pyk_new_%s(hi - lo);" mcode;
                "    for (k = lo; k < hi; k++) {";
                Printf.sprintf "        out%sitems[k - lo] = (%s)[k];" (if is_dynarray then "->" else ".") first;
                "    }";
                "    return out;";
                "}";
              ],
            st )
    in
    (name, need_helper st name (String.concat "\n" lines))

(** copy_into's helper for elements of type elem: src's n elements over
    dst's first ones, overlapping or not. ctx -> state -> info -> typ ->
    (string, state) *)
let copy_helper ctx st info elem =
  let name = "pyk_copy_" ^ code ctx.own info elem in
  let ect, st = ctype ctx st info elem in
  let checks =
    if ctx.gc then
      [
        "    if (n > room) {";
        "        fprintf(stderr, \"error: copy_into copies %d element%s into %d\\n\", n, n == 1 ? \"\" : \"s\", room);";
        "        exit(1);";
        "    }";
      ]
    else []
  in
  ( name,
    need_helper st name
      (String.concat "\n"
         ([ Printf.sprintf "static void %s(%s, int room, %s, int n)" name (declaration (pointer_to ect) "dst") (declaration (pointer_to ect) "src"); "{" ]
         @ checks
         @ [ "    memmove(dst, src, n * sizeof *dst);"; "}" ])) )

(* --- types of expressions --- *)

(** The type the checker worked out for e, at the instance being written.
    ctx -> scope -> expr -> typ *)
let rec type_of ctx scope e =
  let t =
    match IntMap.find_opt (expr_sym e) ctx.tmap with
    | Some t -> t
    | None -> (
        match e with
        | EInt (i, _, _) -> TInt (i, 0)
        | EFloat (i, _, _) -> TFloat (i, 0)
        | EString (i, _, _) -> TString (i, 0)
        | EChar (i, _, _) -> TChar (i, 0)
        | EBool (i, _, _) | EEq (i, _, _, _) | ELessThan (i, _, _, _) | ELessThanEq (i, _, _, _)
        | EGreatThan (i, _, _, _) | EGreatThanEq (i, _, _, _)
        | EBinary (i, (BNeq | BAnd _ | BOr _ | BBoolXor), _, _, _) | EUnary (i, UNot _, _, _) ->
            TBool (i, 0)
        | EBinary (_, _, l, _, _) | EUnary (_, _, l, _) -> (
            match IntMap.find_opt (expr_sym l) ctx.tmap with Some t -> t | None -> TInt (no_info, 0))
        | EVar (i, name, _) -> (match SMap.find_opt name scope.names with Some b -> b.btype | None -> TUnknown (i, 0))
        | EAdd (_, l, _, _) | ESub (_, l, _, _) | EMul (_, l, _, _) | EDiv (_, l, _, _) | ENeg (_, l, _)
        | EConcat (_, l, _, _) -> (
            match IntMap.find_opt (expr_sym l) ctx.tmap with Some t -> t | None -> TInt (no_info, 0))
        | ETuple (i, es, _) -> TTuple (i, List.map (type_of ctx scope) es, 0)
        | EIf (_, _, a, _, _) -> type_of ctx scope a
        | ECall (i, f, _, _) -> (
            match type_of ctx scope f with
            | TFunction (_, _, r, _, _, _, _) | TForall (_, _, TFunction (_, _, r, _, _, _, _), _) -> r
            | _ -> TUnknown (i, 0))
        | e -> TUnknown (expr_info e, 0))
  in
  substitute ctx.sigma t

(* --- free names, for what a nested def captures --- *)

(** Every name read or written anywhere in stmts. [stmt] -> StringSet.t *)
let mentioned stmts =
  Walk.fold_stmts
    (fun found node ->
      match node with
      | Walk.NExpr (EVar (_, n, _)) -> StringSet.add n found
      | Walk.NStmt (SMutate (_, n, _, _)) -> StringSet.add n found
      | _ -> found)
    StringSet.empty stmts

(** The `var`s of a body a closure written in it mentions: those live in
    a cell its owner keeps and every closure points to. [stmt] -> StringSet.t *)
let captured_vars body =
  let vars =
    Walk.fold_stmts
      (fun found node -> match node with Walk.NStmt (SVar (_, n, _, _)) -> StringSet.add n found | _ -> found)
      StringSet.empty body
  in
  if StringSet.is_empty vars then vars
  else
    let inner =
      Walk.fold_stmts
        (fun found node ->
          match node with
          | Walk.NStmt (SFunctionDef (_, _, _, b, _, _, _, _, _)) -> StringSet.union found (mentioned b)
          | Walk.NExpr (ELambda (_, _, b, _)) -> StringSet.union found (mentioned [ SExprStmt (no_info, b, 0) ])
          | _ -> found)
        StringSet.empty body
    in
    StringSet.inter vars inner

(** The `var`s of a body whose address `&` takes: on c23-gc each lives
    in a collected cell, as a captured one does, so the address may
    outlive the function. [stmt] -> StringSet.t *)
let address_taken body =
  Walk.fold_stmts
    (fun found node -> match node with Walk.NExpr (EAddr (_, EVar (_, n, _), _)) -> StringSet.add n found | _ -> found)
    StringSet.empty body

(** The cells of a body: the `var`s a closure written in it captures,
    and on c23-gc those whose address is taken. bool -> [stmt] ->
    StringSet.t *)
let cells_of gc body =
  let captured = captured_vars body in
  if not gc then captured
  else
    let vars =
      Walk.fold_stmts
        (fun found node -> match node with Walk.NStmt (SVar (_, n, _, _)) -> StringSet.add n found | _ -> found)
        StringSet.empty body
    in
    StringSet.union captured (StringSet.inter vars (address_taken body))

(** On plain C, refuses the address of a local `var` of body that could
    outlive the function: it may be handed to a call, read through,
    compared or kept in a local, and nothing else -- not answered, not
    stored in a value, a field, an element or another variable. A local
    holding such an address is held to the same. statics are the top
    level's own `var`s, whose address may go anywhere. ?StringSet.t ->
    [stmt] -> unit *)
let check_local_addresses ?(statics = StringSet.empty) body =
  (* The function's own `var`s, a nested def's left to it. *)
  let rec own_vars stmts =
    List.concat_map
      (fun s ->
        match s with
        | SFunctionDef _ -> []
        | SVar (_, n, _, _) -> [ n ]
        | s -> List.concat_map (function Walk.NStmt s -> own_vars [ s ] | node -> nested_vars node) (Walk.children (Walk.NStmt s)))
      stmts
  and nested_vars node =
    match node with
    | Walk.NStmt s -> own_vars [ s ]
    | Walk.NExpr (ELambda _) -> []
    | node -> List.concat_map nested_vars (Walk.children node)
  in
  let locals = StringSet.diff (StringSet.of_list (own_vars body)) statics in
  if not (StringSet.is_empty locals) then begin
    let tainted = ref StringSet.empty in
    let names_local e =
      match e with
      | EAddr (_, EVar (_, n, _), _) -> StringSet.mem n locals
      | EVar (_, n, _) -> StringSet.mem n !tainted
      | _ -> false
    in
    (* Which nodes may hold such an address: a call's arguments, what is
       read through or compared, a local's value. *)
    let children node =
      let all ok = List.map (fun c -> (c, ok)) (Walk.children node) in
      match node with
      | Walk.NExpr (ECall (_, f, args, _)) -> (Walk.NExpr f, false) :: List.map (fun (_, a) -> (Walk.NExpr a, true)) args
      | Walk.NExpr (EDeref _ | EAddr _ | EEq _ | EBinary (_, BNeq, _, _, _)) -> all true
      | Walk.NStmt (SLet (_, TargetName (_, n, _), e, _, _, _, _)) | Walk.NStmt (SVar (_, n, e, _)) ->
          if names_local e then tainted := StringSet.add n !tainted;
          all true
      | Walk.NStmt (SMutate (_, n, e, _)) ->
          if names_local e && StringSet.mem n locals then tainted := StringSet.add n !tainted;
          all (StringSet.mem n locals)
      | Walk.NStmt (SSetDeref (_, p, v, _)) -> [ (Walk.NExpr p, true); (Walk.NExpr v, false) ]
      | Walk.NStmt (SFunctionDef _) | Walk.NExpr (ELambda _) -> []
      | _ -> all false
    in
    let rec go (node, ok) =
      (match node with
      | Walk.NExpr e when (not ok) && names_local e ->
          let name = match e with EAddr (_, EVar (_, n, _), _) | EVar (_, n, _) -> n | _ -> "" in
          unsupported (expr_info e)
            (Printf.sprintf
               "the address of the local `%s`, which could outlive the function it is in: plain C keeps \
                `%s` on that function's stack, and c23-gc, which moves it to the collected heap, \
                compiles it"
               name name)
      | _ -> ());
      List.iter go (children node)
    in
    (* Twice: a local is known to hold an address before it is read. *)
    List.iter (fun s -> go (Walk.NStmt s, true)) body;
    List.iter (fun s -> go (Walk.NStmt s, true)) body
  end

(** Whether a def is dead: nothing in its block reaches it but defs that
    are dead themselves. The checker works out a def's types the first
    time something calls it, so it never reached one of these, and
    nothing needs one. stmt -> [stmt] -> bool *)
let unreferenced def block =
  let names_in stmts =
    Walk.fold_stmts
      (fun found node -> match node with Walk.NExpr (EVar (_, n, _)) -> StringSet.add n found | _ -> found)
      StringSet.empty stmts
  in
  let defs =
    List.filter_map
      (fun s -> match s with SFunctionDef (_, n, _, _, _, _, false, _, _) -> Some (n, s) | _ -> None)
      block
  in
  let roots =
    List.fold_left
      (fun found s ->
        match s with
        | SFunctionDef (_, _, _, _, _, _, false, _, _) -> found
        | s -> StringSet.union found (names_in [ s ]))
      StringSet.empty block
  in
  let rec grow live =
    let more =
      List.fold_left
        (fun live (n, s) -> if StringSet.mem n live then StringSet.union live (names_in [ s ]) else live)
        live defs
    in
    if StringSet.equal more live then live else grow more
  in
  match def with
  | SFunctionDef (_, name, _, _, _, _, false, _, _) -> not (StringSet.mem name (grow roots))
  | _ -> false

(* --- capture markers ---
   What a lifted function captures is known once the module is done, so
   each place that names its captures writes a marker that
   `expand_captures` replaces: \001A:f:k\001 its arguments (k: whether
   more follow), \001P:f:k\001 its parameters, \001E:f\001 its
   environment's members, \001S:f:e\001 the assignments that fill the
   environment e, \001U:f:k\001 the arguments read back out of one. *)

let marker kind name more = Printf.sprintf "\001%s:%s:%s\001" kind name more

(* --- patterns --- *)

(** What a class's struct, descriptor, constructor and the rest are
    called in C: `pyk_<kind>_<module>_<Class>`. ctx -> string -> string ->
    string *)
let class_symbol ctx kind cls = Printf.sprintf "pyk_%s_%s_%s" kind (ident_of ctx.own) cls

(** A field of an object, read through the struct of the class declaring
    it: a parent's fields come first in every struct below it.
    ctx -> string -> string -> string -> string *)
let object_field ctx cls name v =
  let owner = Option.value (Classes.field_owner ctx.classes cls name) ~default:cls in
  Printf.sprintf "((%s *) %s)->%s" (class_symbol ctx "o" owner) v (c_ident name)

(** The slot a method name has in every object's table. ctx -> string -> int *)
let method_slot ctx name =
  let rec find k = function [] -> 0 | x :: more -> if x = name then k else find (k + 1) more in
  find 0 ctx.slots

(** A method's parameters and result, as the class or interface first
    declaring it says. ctx -> string -> string -> ([typ], typ) *)
let method_signature ctx cls name =
  match Classes.declaring ctx.classes cls name with
  | Some owner -> (
      match Classes.own_method ctx.classes owner name with
      | Some m -> (
          match IntMap.find_opt m.Classes.m_sym ctx.tmap with
          | Some (TFunction (_, ps, r, _, _, _, _)) -> (ps, r)
          | _ -> ([], TTuple (no_info, [], 0)))
      | None -> ([], TTuple (no_info, [], 0)))
  | None -> ([], TTuple (no_info, [], 0))

(** The tests a pattern makes of the subject s, of type t, and the names
    it binds, each to a place in s. ctx -> state -> pattern -> cexpr ->
    typ -> ([cexpr], [(string, cexpr, typ)], state) *)
let rec pattern ctx st p (s : cexpr) (t : typ) =
  let info = pattern_info p in
  match p with
  | PWildcard _ -> ([], [], st)
  | PCapture (_, name, _) -> ([], [ (name, s, t) ], st)
  | PInt (_, v, _) -> ([ binary p_eq "==" s (if v < 0 then mk p_unary (string_of_int v) else atom (string_of_int v)) ], [], st)
  | PChar (_, v, _) -> ([ binary p_eq "==" s (atom (string_of_int v)) ], [], st)
  | PBool (_, v, _) -> ([ (if v then s else mk p_unary ("!" ^ at p_unary s)) ], [], st)
  | PString (_, v, _) -> ([ binary p_eq "==" (atom (Printf.sprintf "strcmp(%s, %s)" s.text (quote v))) (atom "0") ], [], st)
  | PTuple (_, ps, _) ->
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> t) ps in
      parts ctx st ps (List.mapi (fun i _ -> atom (Printf.sprintf "%s.a%d" (at p_atom s) i)) ps) types
  | PList (_, prefix, rest, suffix, _) when ctx.gc -> (
      (* The cells the pattern needs tested present first, then its
         elements, each read where it sits: `s->tail->head`. *)
      let elem = match t with TList (_, e, _) -> list_element e | _ -> TTuple (no_info, [], 0) in
      let rec tails base n = if n = 0 then base else tails (atom (at p_atom base ^ "->tail")) (n - 1) in
      let head_at base i = atom (at p_atom (tails base i) ^ "->head") in
      let present base n = List.init n (fun i -> binary p_eq "!=" (tails base i) (atom "NULL")) in
      let k = List.length prefix and m = List.length suffix in
      let elems n = List.init n (fun _ -> elem) in
      match rest with
      | None ->
          let conds, binds, st = parts ctx st prefix (List.init k (head_at s)) (elems k) in
          (present s k @ [ binary p_eq "==" (tails s k) (atom "NULL") ] @ conds, binds, st)
      | Some (ListRest (_, name, _)) when m = 0 ->
          let conds, binds, st = parts ctx st prefix (List.init k (head_at s)) (elems k) in
          let named = match name with Some n -> [ (n, tails s k, t) ] | None -> [] in
          (present s k @ conds, binds @ named, st)
      | Some (ListRest (_, name, _)) ->
          (* Elements after the rest are counted back from the end. *)
          let length, st = list_helper ctx st info t "length" in
          let size = Printf.sprintf "%s(%s)" length s.text in
          let drop, st = list_helper ctx st info t "drop" in
          let back = atom (Printf.sprintf "%s(%s, %s - %d)" drop s.text size m) in
          let conds, binds, st =
            parts ctx st (prefix @ suffix) (List.init k (head_at s) @ List.init m (head_at back)) (elems (k + m))
          in
          let named, st =
            match name with
            | None -> ([], st)
            | Some n ->
                let take, st = list_helper ctx st info t "take" in
                ([ (n, atom (Printf.sprintf "%s(%s, %s - %d)" take (tails s k).text size (k + m)), t) ], st)
          in
          (binary p_rel ">=" (atom size) (atom (string_of_int (k + m))) :: conds, binds @ named, st))
  | PList _ -> unsupported info heap_reason
  | PText (_, prefix, name, suffix, _) ->
      let st = if suffix <> "" then need_helper st "pyk_ends_with" ends_helper else st in
      let conds =
        (if prefix = "" then []
         else [ binary p_eq "==" (atom (Printf.sprintf "strncmp(%s, %s, %d)" s.text (quote prefix) (String.length prefix))) (atom "0") ])
        @ (if suffix = "" then [] else [ atom (Printf.sprintf "pyk_ends_with(%s, %s)" s.text (quote suffix)) ])
        @
        if prefix <> "" && suffix <> "" then
          [ binary p_rel ">=" (atom (Printf.sprintf "strlen(%s)" s.text)) (atom (string_of_int (String.length prefix + String.length suffix))) ]
        else []
      in
      let binds, st =
        match name with
        | None -> ([], st)
        | Some name ->
            ( [ (name, atom (Printf.sprintf "pyk_slice(%s, %d, %d)" s.text (String.length prefix) (String.length suffix)), t) ],
              need_helper st "pyk_slice" slice_helper )
      in
      (conds, binds, st)
  | PConstructor (_, None, name, fields, _, _) when Classes.find ctx.classes name <> None ->
      (* An object of that class or one below it, its header's fields
         read through the struct of the class declaring each. *)
      let k = Option.get (Classes.find ctx.classes name) in
      let test = atom (Printf.sprintf "pyk_is_a(%s->cls, &%s)" (at p_atom s) (class_symbol ctx "class" name)) in
      let places = List.map (fun (h, _) -> atom (object_field ctx name h s.text)) k.Classes.header in
      let types = List.map (fun (_, hs) -> Option.value (IntMap.find_opt hs ctx.tmap) ~default:(TUnknown (info, 0))) k.Classes.header in
      let conds, binds, st = parts ctx st fields places types in
      (test :: conds, binds, st)
  | PTyped (_, bound, target, _) ->
      let cls = match target with TCon (_, c, _, _) -> c | _ -> "" in
      let test = atom (Printf.sprintf "pyk_is_a(%s->cls, &%s)" (at p_atom s) (class_symbol ctx "class" cls)) in
      ([ test ], [ (bound, s, target) ], st)
  | PConstructor (_, _, name, fields, _, _) ->
      let tag = ctor_tag ctx info t name in
      let declared = ctor_fields ctx info t name in
      let sel = member_of ctx t in
      let places = List.map (fun (path, _) -> atom (Printf.sprintf "%s%s%s" (at p_atom s) sel path)) declared in
      let conds, binds, st = parts ctx st fields places (List.map snd declared) in
      if sole_constructor ctx info t then (conds, binds, st)
      else
        let test = binary p_eq "==" (atom (at p_atom s ^ sel ^ "tag")) (atom (string_of_int tag)) in
        (test :: conds, binds, st)
  | PAs (_, inner, name, _) ->
      let conds, binds, st = pattern ctx st inner s t in
      (conds, binds @ [ (name, s, t) ], st)
  | POr (_, alternatives, _) ->
      let names = match alternatives with first :: _ -> List.map fst (Analyses.pattern_bindings first) | [] -> [] in
      let each, st =
        List.fold_left
          (fun (out, st) alt ->
            let conds, binds, st = pattern ctx st alt s t in
            (out @ [ (conds, binds) ], st))
          ([], st) alternatives
      in
      let cond =
        if List.exists (fun (c, _) -> c = []) each then []
        else
          match List.map (fun (c, _) -> conjunction c) each with
          | first :: rest -> [ List.fold_left (fun acc c -> binary p_or "||" acc c) first rest ]
          | [] -> []
      in
      let binds =
        List.map
          (fun name ->
            let value_in binds = List.find_map (fun (n, v, ty) -> if n = name then Some (v, ty) else None) binds in
            let rec chosen = function
              | [] -> (unit_value, t)
              | [ (_, binds) ] | ([], binds) :: _ -> Option.value (value_in binds) ~default:(unit_value, t)
              | (conds, binds) :: rest ->
                  let v, ty = Option.value (value_in binds) ~default:(unit_value, t) in
                  let other, _ = chosen rest in
                  (mk p_cond (Printf.sprintf "%s ? %s : %s" (at (p_cond + 1) (conjunction conds)) (at p_cond v) (at p_cond other)), ty)
            in
            let v, ty = chosen each in
            (name, v, ty))
          names
      in
      (cond, binds, st)

and parts ctx st ps places types =
  let rec go ps places types conds binds st =
    match (ps, places, types) with
    | p :: ps, place :: places, ty :: types ->
        let c, b, st = pattern ctx st p place ty in
        go ps places types (conds @ c) (binds @ b) st
    | _ -> (conds, binds, st)
  in
  go ps places types [] [] st

(** A C string literal. string -> string *)
and quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | '?' -> Buffer.add_string b "\\?"
      | c when Char.code c < 32 -> Buffer.add_string b (Printf.sprintf "\\%03o" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(** A Float literal. bool -> float -> cexpr * bool (whether it needs
    <math.h>) *)
let float_literal v =
  if v <> v then (atom "(HUGE_VAL - HUGE_VAL)", true)
  else if v = infinity then (atom "HUGE_VAL", true)
  else if v = neg_infinity then (mk p_unary "-HUGE_VAL", true)
  else
    let text = Builtin.float_text v in
    let text = if String.contains text '.' || String.contains text 'e' then text else text ^ ".0" in
    ((if v < 0.0 then mk p_unary text else atom text), false)

(* --- expressions --- *)

(** A temporary of type ct, declared at the top of the function.
    state -> string -> (string, state) *)
let fresh_temp st ct =
  let name, st = temp st "t" in
  (name, { st with temps = st.temps @ [ (ct, name) ] })

(** The pieces of an operation, translated left to right, each that can
    print -- but the last -- put in a temporary first, so that C, which
    fixes no order between them, cannot reorder what is printed. Answers
    the pieces and the assignments to run before them.
    ctx -> state -> scope -> [expr] -> ([cexpr], [string], state) *)
let rec in_order ?(expected = []) ctx st scope es =
  let values, st =
    List.fold_left
      (fun (out, st) (i, e) ->
        (* A polymorphic function handed where one type is wanted is the
           instance at that type. *)
        let v, st =
          match (List.nth_opt expected i, e) with
          | Some (Some at), EVar (_, name, _) -> (
              match SMap.find_opt name scope.names with
              | Some { kind = BFn f; _ } when f.generic -> function_value ~at ctx st scope e f
              | _ -> expr ctx st scope e)
          | Some (Some at), EQualified (_, alias, field, _) -> (
              match qualified_fn ctx alias field with
              | Some f when f.generic -> function_value ~at ctx st scope e f
              | _ -> expr ctx st scope e)
          | _ -> expr ctx st scope e
        in
        (out @ [ v ], st))
      ([], st)
      (List.mapi (fun i e -> (i, e)) es)
  in
  let effectful = List.concat (List.mapi (fun i e -> if Analyses.may_print ctx.printing e then [ i ] else []) es) in
  let printing = List.filteri (fun i _ -> i < List.length effectful - 1) effectful in
  (* A piece whose value a call could change -- a `var`, a field of a
     var struct, an element, or a call itself -- is worked out before a
     later piece that calls something, and a piece that calls something
     before a later one such a call could change. *)
  let calls = List.map (has_call ctx scope) es in
  let unstable = List.map (fun e -> not (stable ctx st scope e)) es in
  let changing =
    List.concat
      (List.mapi
         (fun i _ ->
           let later l = List.exists Fun.id (List.filteri (fun j _ -> j > i) l) in
           if (List.nth unstable i && later calls) || (List.nth calls i && later unstable) then [ i ] else [])
         es)
  in
  let earlier = List.sort_uniq compare (printing @ changing) in
  if earlier = [] then (values, [], st)
  else
    let steps, replaced, st =
      List.fold_left
        (fun (steps, replaced, st) index ->
          let v = List.nth values index in
          let ct, st = ctype ctx st no_info (type_of ctx scope (List.nth es index)) in
          let name, st = fresh_temp st ct in
          (steps @ [ Printf.sprintf "%s = %s" name (at p_assign v) ], replaced @ [ (index, name) ], st))
        ([], [], st) earlier
    in
    ( List.mapi (fun i v -> match List.assoc_opt i replaced with Some name -> atom name | None -> v) values,
      steps,
      st )

(** Whether nothing a call could do changes e's value: e reads no
    `var` a call can write (a captured one, or one of the top level), no
    field of a var struct, no element and no DynArray's length, and calls
    nothing but a builtin that only reads. ctx -> state -> scope -> expr
    -> bool *)
and stable ctx st scope e =
  let reads name =
    List.mem name Builtin.pure_names && (not (List.mem name Builtin.writers)) && not (SMap.mem name scope.names)
  in
  let store t = match t with TCon (_, c, _, _) -> is_store c | _ -> false in
  not
    (Walk.fold_stmts
       (fun found node ->
         found
         ||
         match node with
         | Walk.NExpr (ECall (_, EVar (_, "len", _), [ (_, a) ], _)) when reads "len" -> dynarray_element (type_of ctx scope a) <> None
         | Walk.NExpr (ECall (_, EVar (_, name, _), _, _)) -> not (reads name)
         | Walk.NExpr (ECall _) -> true
         | Walk.NExpr (EVar (_, name, _)) -> (
             match SMap.find_opt name scope.names with
             | Some { kind = BCell; _ } -> true
             | Some { kind = BLocal; cname_; _ } -> StringSet.mem ("var$" ^ cname_) st.taken
             | _ -> false)
         | Walk.NExpr (EQualified (_, alias, field, _)) -> qualified_fn ctx alias field = None
         | Walk.NExpr (EField (_, record, _, _)) -> var_struct ctx (type_of ctx scope record)
         | Walk.NExpr (EIndex (_, owner, _, _)) -> store (type_of ctx scope owner)
         | Walk.NExpr (EDeref _) -> true
         | _ -> false)
       false
       [ SExprStmt (no_info, e, 0) ])

(** result with the steps run first, by the comma operator: the one
    construct that fixes an order inside a C expression.
    [string] -> cexpr -> cexpr *)
and sequenced steps result =
  if steps = [] then result else atom ~local_env:result.local_env ("(" ^ String.concat ", " (steps @ [ at (p_comma + 1) result ]) ^ ")")

(** Translates one expression. ctx -> state -> scope -> expr -> (cexpr, state) *)
and expr ctx st scope e =
  let info = expr_info e in
  match e with
  | EInt (_, v, _) -> ((if v < 0 then mk p_unary (string_of_int v) else atom (string_of_int v)), st)
  | EFloat (_, v, _) ->
      let lit, math = float_literal v in
      (lit, if math then { st with includes_math = true } else st)
  | EString (_, s, _) -> (atom (quote s), st)
  | EChar (_, c, _) -> (atom (string_of_int c), st)
  | EBool (_, b, _) -> (atom (if b then true_text ctx else false_text ctx), { st with uses_bool = st.uses_bool || ctx.standard <> "c89" })
  | ETuple (_, [], _) -> (unit_value, st)
  | ETuple (_, es, _) ->
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let values, steps, st = in_order ctx st scope es in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a tuple");
      (sequenced steps (atom (Printf.sprintf "pyk_mk_%s(%s)" (code ctx.own info t) (String.concat ", " (List.map (fun v -> v.text) values)))), st)
  | EList (_, items, _) when ctx.gc ->
      (* Its cells built from the last one in, each element worked out
         left to right first. *)
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let lcode = code ctx.own info t in
      let values, steps, st = in_order ctx st scope items in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a list");
      let text = List.fold_right (fun v rest -> Printf.sprintf "pyk_cons_%s(%s, %s)" lcode v.text rest) values "NULL" in
      (sequenced steps (atom text), st)
  | EListComp _ when ctx.gc ->
      (* A function of its own, which builds the list with loops and
         takes what the comprehension reads from around it. *)
      let t = type_of ctx scope e in
      let name, st = fresh st (scope.family ^ "_list") in
      let ft = TFunction (info, [], t, 0, 0, None, []) in
      let def = SFunctionDef (info, name, [], [ SExprStmt (info, e, 0) ], None, expr_sym e, false, [], false) in
      let st = lift_with ctx st scope def name ft in
      (atom (Printf.sprintf "%s(%s)" name (marker "A" name "0")), st)
  | EList _ | EListComp _ -> unsupported info heap_reason
  | EVar (_, name, _) -> variable ctx st scope e name
  | EQualified (_, alias, field, _) -> (
      match qualified_fn ctx alias field with
      | Some f -> function_value ctx st scope e f
      | None ->
          let module_ = Option.value (List.assoc_opt alias ctx.modules) ~default:alias in
          (atom (module_name module_ field), st))
  | EIf (_, c, a, b, _) ->
      let c, st = expr ctx st scope c in
      let a, st = expr ctx st scope a in
      let b, st = expr ctx st scope b in
      ( mk ~local_env:(a.local_env || b.local_env) p_cond
          (Printf.sprintf "%s ? %s : %s" (at (p_cond + 1) c) (at p_cond a) (at p_cond b)),
        st )
  | ENeg (_, operand, _) ->
      let v, st = expr ctx st scope operand in
      let text = at p_unary v in
      (mk p_unary ("-" ^ if String.length text > 0 && text.[0] = '-' then "(" ^ text ^ ")" else text), st)
  | EAdd (_, l, r, _) -> arithmetic ctx st scope p_add "+" l r
  | ESub (_, l, r, _) -> arithmetic ctx st scope p_add "-" l r
  | EMul (_, l, r, _) -> arithmetic ctx st scope p_mul "*" l r
  | EDiv (_, l, r, _) -> arithmetic ctx st scope p_mul "/" l r
  | EConcat (_, l, r, _) when (match type_of ctx scope e with TList _ -> true | _ -> false) ->
      if not ctx.gc then unsupported info heap_reason;
      let pieces, steps, st = in_order ctx st scope [ l; r ] in
      let append, st = list_helper ctx st info (type_of ctx scope e) "append" in
      (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" append (List.nth pieces 0).text (List.nth pieces 1).text)), st)
  | EConcat (_, l, r, _) ->
      let pieces, steps, st = in_order ctx st scope [ l; r ] in
      let st = need_concat st in
      (sequenced steps (atom (Printf.sprintf "pyk_concat(%s, %s)" (List.nth pieces 0).text (List.nth pieces 1).text)), st)
  | EEq (_, l, r, _) -> (
      let pieces, steps, st = in_order ctx st scope [ l; r ] in
      let a = List.nth pieces 0 and b = List.nth pieces 1 in
      match type_of ctx scope l with
      | TString _ -> (sequenced steps (binary p_eq "==" (atom (Printf.sprintf "strcmp(%s, %s)" a.text b.text)) (atom "0")), st)
      | TInt _ | TChar _ | TBool _ | TFloat _ | TTuple (_, [], _) -> (sequenced steps (binary p_eq "==" a b), st)
      | t when ptr_target t <> None -> (sequenced steps (binary p_eq "==" a b), st)
      | t ->
          (* A list, a tuple, a struct or a datatype: part by part. *)
          let eq, st = structural ctx st info "eq" t in
          (sequenced steps (atom (eq a.text b.text)), st))
  | EBinary (_, op, l, r, _) -> (
      let float = match type_of ctx scope l with TFloat _ -> true | _ -> false in
      let call name st =
        let pieces, steps, st = in_order ctx st scope [ l; r ] in
        ( sequenced steps
            (atom (Printf.sprintf "%s(%s, %s)" name (List.nth pieces 0).text (List.nth pieces 1).text)),
          st )
      in
      match op with
      | BAnd _ | BOr _ ->
          (* Each operand is one C expression with its own steps inside
             it, so `&&` and `||` decide whether the right one runs, as
             Pyking's do. *)
          let a, st = expr ctx st scope l in
          let b, st = expr ctx st scope r in
          let prec, spelling = match op with BAnd _ -> (p_and, "&&") | _ -> (p_or, "||") in
          (mk ~local_env:false prec (at prec a ^ " " ^ spelling ^ " " ^ at (prec + 1) b), st)
      | BNeq -> (
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let a = List.nth pieces 0 and b = List.nth pieces 1 in
          match type_of ctx scope l with
          | TString _ -> (sequenced steps (binary p_eq "!=" (atom (Printf.sprintf "strcmp(%s, %s)" a.text b.text)) (atom "0")), st)
          | TInt _ | TChar _ | TBool _ | TFloat _ | TTuple (_, [], _) -> (sequenced steps (binary p_eq "!=" a b), st)
          | t when ptr_target t <> None -> (sequenced steps (binary p_eq "!=" a b), st)
          | t ->
              let eq, st = structural ctx st info "eq" t in
              (sequenced steps (mk p_unary ("!" ^ eq a.text b.text)), st))
      | BMod when float -> call "fmod" { st with includes_math = true }
      | BMod -> arithmetic ctx st scope p_mul "%" l r
      | BPow when float -> call "pow" { st with includes_math = true }
      | BPow -> call "pyk_ipow" (need_helper st "pyk_ipow" power_helper)
      | BBitAnd _ -> arithmetic ctx st scope p_bit_and "&" l r
      | BBitOr _ -> arithmetic ctx st scope p_bit_or "|" l r
      | BXor -> arithmetic ctx st scope p_xor "^" l r
      | BBoolXor -> arithmetic ctx st scope p_eq "!=" l r
      | BShiftLeft -> arithmetic ctx st scope p_shift "<<" l r
      | BShiftRight -> call "pyk_shr" (need_helper st "pyk_shr" shift_right_helper))
  | EUnary (_, op, operand, _) ->
      let v, st = expr ctx st scope operand in
      let spelling = match op with UNot _ -> "!" | UBitNot _ -> "~" in
      (mk p_unary (spelling ^ at p_unary v), st)
  | EDeref (_, pointer, _) ->
      let v, st = expr ctx st scope pointer in
      (mk p_unary ("*" ^ at p_unary v), st)
  | EAddr (_, EDeref (_, pointer, _), _) -> expr ctx st scope pointer
  | EAddr (_, EVar (_, name, _), _) -> (
      (* A `var`: C's `&x`; one in a cell -- captured, or on c23-gc one
         whose address is taken -- is its cell's pointer already. *)
      match SMap.find_opt name scope.names with
      | Some { kind = BCell; value; _ } -> (value, st)
      | Some { value; _ } -> (mk p_unary ("&" ^ at p_unary value), st)
      | None -> unsupported info (Printf.sprintf "'%s' is not a value this backend can compile" name))
  | EAddr (_, EField (_, owner, field, _), _) ->
      (* A var struct's field: `&p->x`. *)
      let owner_t = type_of ctx scope owner in
      let path =
        match List.assoc_opt field (sole_fields ctx info owner_t) with
        | Some path -> path
        | None -> unsupported info "the address of a field of what is not a var struct"
      in
      let v, st = expr ctx st scope owner in
      (mk p_unary (Printf.sprintf "&%s->%s" (at p_atom v) path), st)
  | EAddr (_, EIndex (_, owner, index, _), _) ->
      (* An element: `&a.items[i]` on plain C; on c23-gc the index is
         checked first, by pyk_place_<code>. A view's is its array's. *)
      let owner_t = type_of ctx scope owner in
      let pieces, steps, st = in_order ctx st scope [ owner; index ] in
      let o = List.nth pieces 0 and i = List.nth pieces 1 in
      if ctx.gc || slice_element owner_t <> None then
        let helper, st = run_helper ctx st info owner_t "place" in
        (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" helper o.text i.text)), st)
      else (sequenced steps (mk p_unary (Printf.sprintf "&%s.items[%s]" (at p_atom o) i.text)), st)
  | EAddr (info, _, _) -> unsupported info "the address of what is not a variable, an element or a field"
  | ESlice (_, sequence, low, high, _) ->
      (* The sequence, then the bounds, worked out in order; a bound left
         out is 0 or the length, read off the sequence held in a name. *)
      let seq_t = type_of ctx scope sequence in
      (match seq_t with TList _ when not ctx.gc -> unsupported info heap_reason | _ -> ());
      let given = List.filter_map Fun.id [ low; high ] in
      let values, steps, st = in_order ctx st scope (sequence :: given) in
      let sv = List.hd values in
      let named = String.for_all (fun c -> c = '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) sv.text in
      let sv, steps, st =
        if high <> None || named then (sv, steps, st)
        else
          let ct, st = ctype ctx st info seq_t in
          let held, st = fresh_temp st ct in
          (atom held, steps @ [ Printf.sprintf "%s = %s" held (at p_assign sv) ], st)
      in
      let rest = List.tl values in
      let lo, rest = match low with Some _ -> ((List.hd rest).text, List.tl rest) | None -> ("0", rest) in
      let hi, st =
        match (high, rest) with
        | Some _, h :: _ -> (h.text, st)
        | _ -> (
            match seq_t with
            | TString _ -> (Printf.sprintf "pyk_utf8_length(%s)" sv.text, need_char st "pyk_utf8_length")
            | TList _ ->
                let length, st = list_helper ctx st info seq_t "length" in
                (Printf.sprintf "%s(%s)" length sv.text, st)
            | t when Typesystem.array_element t <> None -> (sv.text ^ ".len", st)
            | _ -> (sv.text ^ "->len", st))
      in
      let helper, st = run_helper ctx st info seq_t "slice" in
      (sequenced steps (atom (Printf.sprintf "%s(%s, %s, %s)" helper sv.text lo hi)), st)
  | EIndex (_, l, r, _) -> (
      match type_of ctx scope l with
      | TString _ ->
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          ( sequenced steps (atom (Printf.sprintf "pyk_char_at(%s, %s)" (List.nth pieces 0).text (List.nth pieces 1).text)),
            need_char st "pyk_char_at" )
      | array_t when Typesystem.array_element array_t <> None ->
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let a = List.nth pieces 0 and i = List.nth pieces 1 in
          if ctx.gc then
            let getter, st = array_getter ctx st info array_t in
            (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" getter a.text i.text)), st)
          else (sequenced steps (atom (Printf.sprintf "%s.items[%s]" (at p_atom a) i.text)), st)
      | mutmap_t when mutmap_parts mutmap_t <> None ->
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let at, st = mutmap_helper ctx st info mutmap_t "at" in
          (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" at (List.nth pieces 0).text (List.nth pieces 1).text)), st)
      | view_t when slice_element view_t <> None ->
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let at, st = run_helper ctx st info view_t "at" in
          (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" at (List.nth pieces 0).text (List.nth pieces 1).text)), st)
      | dynarray_t when dynarray_element dynarray_t <> None ->
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let a = List.nth pieces 0 and i = List.nth pieces 1 in
          if ctx.gc then
            let getter, st = dynarray_helper ctx st info dynarray_t "at" in
            (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" getter a.text i.text)), st)
          else (sequenced steps (atom (Printf.sprintf "%s->items[%s]" (at p_atom a) i.text)), st)
      | TList _ as list_t when ctx.gc ->
          (* Checked, as an array's index is. *)
          let pieces, steps, st = in_order ctx st scope [ l; r ] in
          let nth, st = list_helper ctx st info list_t "nth" in
          (sequenced steps (atom (Printf.sprintf "%s(%s, %s)" nth (List.nth pieces 0).text (List.nth pieces 1).text)), st)
      | _ -> unsupported info heap_reason)
  | ELessThan (_, l, r, _) -> arithmetic ctx st scope p_rel "<" l r
  | ELessThanEq (_, l, r, _) -> arithmetic ctx st scope p_rel "<=" l r
  | EGreatThan (_, l, r, _) -> arithmetic ctx st scope p_rel ">" l r
  | EGreatThanEq (_, l, r, _) -> arithmetic ctx st scope p_rel ">=" l r
  | ECall (_, EVar (_, name, callee), args, _)
    when Builtin.crosses_host name && not (IntMap.mem callee ctx.tmap) ->
      let line, st = print_call ctx st scope name (arg_exprs args) in
      (atom (Printf.sprintf "(%s, 0)" line), st)
  | ECall (_, EVar (_, "len", _), [ (_, EList (_, items, _)) ], _) when not (SMap.mem "len" scope.names) ->
      (* The length of a list literal is how many elements it writes:
         each is worked out, left to right, and no list is made. *)
      let steps, st =
        List.fold_left
          (fun (out, st) item ->
            match item with
            | EInt _ | EFloat _ | EString _ | EChar _ | EBool _ | EVar _ -> (out, st)
            | _ ->
                let v, st = expr ctx st scope item in
                (out @ [ "(void)" ^ at p_unary v ], st))
          ([], st) items
      in
      (sequenced steps (atom (string_of_int (List.length items))), st)
  | ECall (_, EVar (_, name, _), args, _) when List.mem name Builtin.member_names && not (SMap.mem name scope.names) ->
      make_array ctx st scope e name (arg_exprs args)
  | ECall (_, EVar (_, name, _), args, _) when List.mem name Builtin.pure_names && not (SMap.mem name scope.names) ->
      builtin ctx st scope e name (arg_exprs args)
  | ECall (_, func, args, _) -> call ctx st scope e func (arg_exprs args)
  | EConstruct (_, None, name, args, _) when Classes.find ctx.classes name <> None ->
      (* An object, by its class's constructor. *)
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let values, steps, st = in_order ctx st scope (arg_exprs args) in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "an object");
      (sequenced steps (atom (Printf.sprintf "%s(%s)" (class_symbol ctx "new" name) (String.concat ", " (List.map (fun v -> v.text) values)))), st)
  | EMethod (_, obj, name, args, _) -> (
      (* Through the object's own class's table: the object held once,
         handed to the slot's function cast to the method's signature. *)
      let cls = match type_of ctx scope obj with TCon (_, c, _, _) -> c | _ -> "" in
      let pieces, steps, st = in_order ctx st scope (obj :: arg_exprs args) in
      let o = List.hd pieces in
      let ps, r = method_signature ctx cls name in
      let rt, st = if is_unit r then ("void", st) else ctype ctx st info r in
      let cps, st =
        List.fold_left (fun (out, st) p -> let ct, st = ctype ctx st info p in (out @ [ ct ], st)) ([], st) ps
      in
      let held, st = fresh_temp st "pyk_obj *" in
      let slot = method_slot ctx name in
      let fn = Printf.sprintf "((%s (*)(%s)) %s->cls->vt[%d])" rt (String.concat ", " ("pyk_obj *" :: cps)) held slot in
      let text =
        Printf.sprintf "(%s = %s, %s(%s))" held (at p_assign o) fn (String.concat ", " (held :: List.map (fun v -> v.text) (List.tl pieces)))
      in
      let text = if is_unit r then Printf.sprintf "(%s, 0)" text else text in
      match steps with _ -> (sequenced steps (atom text), st))
  | ESuper (_, owner, name, args, _) ->
      (* The body the checker chose, called directly on self. *)
      let values, steps, st = in_order ctx st scope (arg_exprs args) in
      let self = match SMap.find_opt "self" scope.names with Some b -> b.value.text | None -> "self" in
      let _, r = method_signature ctx owner name in
      let text = Printf.sprintf "%s(%s)" (class_symbol ctx ("m_" ^ name) owner) (String.concat ", " (self :: List.map (fun v -> v.text) values)) in
      (sequenced steps (atom (if is_unit r then Printf.sprintf "(%s, 0)" text else text)), st)
  | EUpcast (_, inner, _, _) -> expr ctx st scope inner
  | EField (_, record, name, _) when (match type_of ctx scope record with TCon (_, c, _, _) -> Classes.find ctx.classes c <> None | _ -> false) ->
      let cls = match type_of ctx scope record with TCon (_, c, _, _) -> c | _ -> "" in
      let v, st = expr ctx st scope record in
      (atom (object_field ctx cls name v.text), st)
  | EConstruct (_, _, name, args, _) ->
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let values, steps, st = in_order ctx st scope (arg_exprs args) in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a datatype");
      ( sequenced steps
          (atom (Printf.sprintf "pyk_mk_%s_%s(%s)" (code ctx.own info t) name (String.concat ", " (List.map (fun v -> v.text) values)))),
        st )
  | EField (_, record, name, _) -> (
      let rt = type_of ctx scope record in
      let v, st = expr ctx st scope record in
      match List.assoc_opt name (sole_fields ctx info rt) with
      | Some path -> (atom (Printf.sprintf "%s%s%s" (at p_atom v) (member_of ctx rt) path), st)
      | None ->
          let accessor, st = field_accessor ctx st info rt name in
          (atom (Printf.sprintf "%s(%s)" accessor v.text), st))
  | ELambda (_, params, body, _) -> lambda ctx st scope e params body
  | ELet (_, target, _, value, body, _) ->
      (* The value into a temporary by the comma operator -- a tuple's
         parts each into one of their own -- and the body then reads
         them. *)
      let v, st = expr ctx st scope value in
      let rec bound st scope target text local_env t =
        let ct, st = ctype ctx st info t in
        let temp, st = fresh_temp st ct in
        let step = Printf.sprintf "%s = %s" temp text in
        match target with
        | TargetName (_, name, _) ->
            ( [ step ],
              bind_value scope name
                { value = atom ~local_env temp; kind = BLocal; btype = t; cname_ = temp },
              st )
        | TargetTuple (_, targets, _) ->
            let types =
              match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> TUnknown (no_info, 0)) targets
            in
            List.fold_left
              (fun (steps, scope, st) (i, (target, ty)) ->
                let more, scope, st =
                  bound st scope target (Printf.sprintf "%s.a%d" temp i) local_env ty
                in
                (steps @ more, scope, st))
              ([ step ], scope, st)
              (List.mapi (fun i x -> (i, x)) (List.combine targets types))
      in
      let steps, inner, st =
        bound st scope target (at p_assign v) v.local_env (type_of ctx scope value)
      in
      let result, st = expr ctx st inner body in
      (sequenced steps result, st)

and escaping what =
  Printf.sprintf
    "%s holding a function that captures values: plain C keeps them on the \
     stack of the function that made it, which it would outlive, and has no \
     heap that is freed to move them to; c23-gc compiles it"
    what

and arithmetic ctx st scope prec op l r =
  let pieces, steps, st = in_order ctx st scope [ l; r ] in
  (sequenced steps (binary prec op (List.nth pieces 0) (List.nth pieces 1)), st)

(** The function reading a[i] of an array of type t on c23-gc, the index
    checked first: pyk_at_<code>. ctx -> state -> info -> typ -> (string, state) *)
and array_getter ctx st info t =
  let acode = code ctx.own info t in
  let name = "pyk_at_" ^ acode in
  let ct, st = ctype ctx st info t in
  if List.mem_assoc name st.helpers then (name, st)
  else
    let elem = Option.get (Typesystem.array_element t) in
    let ect, st = ctype ctx st info elem in
    let st = need_helper st "pyk_check_index" check_index_helper in
    let text =
      String.concat "\n"
        [
          Printf.sprintf "static %s(%s, int i)" (declaration ect name) (declaration ct "a");
          "{";
          "    pyk_check_index(i, a.len);";
          "    return a.items[i];";
          "}";
        ]
    in
    (name, need_helper st name text)

(** A call making an array, `list__array` and the other three the
    elaborator names: its arguments worked out left to right, and the
    size checked before anything is called or allocated. `list__array`
    is compiled only from a list literal, its elements written straight
    into the new array: there are no lists to make one from.
    ctx -> state -> scope -> expr -> string -> [expr] -> (cexpr, state) *)
and make_array ctx st scope e name args =
  let info = expr_info e in
  let t = type_of ctx scope e in
  match (dynarray_element t, name, args) with
  | _, "empty__mutmap", [] ->
      let _, st = ctype ctx st info t in
      (atom (Printf.sprintf "pyk_new_%s()" (code ctx.own info t)), st)
  | _, "list__mutmap", [ EList (_, items, _) ] ->
      (* Each pair put in turn, its key and value worked out left to
         right first; a pair that is not written out is held whole. *)
      let dt, st = ctype ctx st info t in
      let mcode = code ctx.own info t in
      let put, st = mutmap_helper ctx st info t "put" in
      let pieces = List.concat_map (fun item -> match item with ETuple (_, [ k; v ], _) -> [ k; v ] | e -> [ e ]) items in
      let values, steps, st = in_order ctx st scope pieces in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a MutMap");
      let held, st = fresh_temp st dt in
      let rec puts items values st =
        match (items, values) with
        | ETuple (_, [ _; _ ], _) :: items, k :: v :: values ->
            let rest, st = puts items values st in
            (Printf.sprintf "%s(%s, %s, %s)" put held k.text v.text :: rest, st)
        | item :: items, pair :: values ->
            let pt, st = ctype ctx st info (type_of ctx scope item) in
            let p, st = fresh_temp st pt in
            let rest, st = puts items values st in
            (Printf.sprintf "%s = %s" p (at p_assign pair) :: Printf.sprintf "%s(%s, %s.a0, %s.a1)" put held p p :: rest, st)
        | _ -> ([], st)
      in
      let made, st = puts items values st in
      (sequenced steps (atom ("(" ^ String.concat ", " ((Printf.sprintf "%s = pyk_new_%s()" held mcode :: made) @ [ held ]) ^ ")")), st)
  | _, "list__mutmap", [ xs ] when ctx.gc ->
      let v, st = expr ctx st scope xs in
      let helper, st = mutmap_helper ctx st info t "of_list" in
      (atom (Printf.sprintf "%s(%s)" helper v.text), st)
  | _, "list__mutmap", _ -> unsupported info heap_reason
  | Some _, "empty__dynarray", [] ->
      let _, st = ctype ctx st info t in
      (atom (Printf.sprintf "pyk_new_%s(0)" (code ctx.own info t)), st)
  | Some _, "list__dynarray", [ EList (_, items, _) ] ->
      (* Made as long as the literal, each element written straight in,
         left to right: no list is made. *)
      let vt, st = ctype ctx st info t in
      let values, st =
        List.fold_left (fun (out, st) item -> let v, st = expr ctx st scope item in (out @ [ v ], st)) ([], st) items
      in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a DynArray");
      let held, st = fresh_temp st vt in
      let steps =
        Printf.sprintf "%s = pyk_new_%s(%d)" held (code ctx.own info t) (List.length items)
        :: List.mapi (fun i v -> Printf.sprintf "%s->items[%d] = %s" held i (at p_assign v)) values
      in
      (atom ("(" ^ String.concat ", " (steps @ [ held ]) ^ ")"), st)
  | Some _, "list__dynarray", [ xs ] when ctx.gc ->
      let v, st = expr ctx st scope xs in
      let helper, st = dynarray_helper ctx st info t "of_list" in
      (atom (Printf.sprintf "%s(%s)" helper v.text), st)
  | Some _, _, _ -> unsupported info heap_reason
  | None, _, _ -> make_store ctx st scope e name args

(** A call making an array. ctx -> state -> scope -> expr -> string ->
    [expr] -> (cexpr, state) *)
and make_store ctx st scope e name args =
  let info = expr_info e in
  let t = type_of ctx scope e in
  let elem =
    match Typesystem.array_element t with
    | Some elem -> elem
    | None -> unsupported info "an array whose element type nothing in the program settles, which C has to know"
  in
  let act, st = ctype ctx st info t in
  let acode = code ctx.own info t in
  let ect, st = ctype ctx st info elem in
  let fn_type ps r = TFunction (info, ps, r, 0, 0, None, []) in
  (* A helper of the file, written once: its name, its parameters and the
     statements between making the array and answering it. *)
  let helper st hname params loop_decls loop_body =
    let text =
      String.concat "\n"
        ([
           Printf.sprintf "static %s(%s)" (declaration act hname) (String.concat ", " params);
           "{";
           Printf.sprintf "    %s = pyk_new_%s(n);" (declaration act "a") acode;
         ]
        @ List.map (fun d -> "    " ^ d) loop_decls
        @ [ "    int i;"; "    for (i = 0; i < n; i++) {" ]
        @ List.map (fun l -> "        " ^ l) loop_body
        @ [ "    }"; "    return a;"; "}" ])
    in
    need_helper st hname text
  in
  let call_text hname values steps = sequenced steps (atom (Printf.sprintf "%s(%s)" hname (String.concat ", " (List.map (fun v -> v.text) values)))) in
  match (name, args) with
  | "list__array", [ EList (_, items, _) ] ->
      (* The new array, and then each element written into it in turn:
         the comma operator runs them left to right. *)
      let values, st =
        List.fold_left
          (fun (out, st) item ->
            let v, st = expr ctx st scope item in
            (out @ [ v ], st))
          ([], st) items
      in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "an array");
      let held, st = fresh_temp st act in
      let steps =
        Printf.sprintf "%s = pyk_new_%s(%d)" held acode (List.length items)
        :: List.mapi (fun i v -> Printf.sprintf "%s.items[%d] = %s" held i (at p_assign v)) values
      in
      (atom ("(" ^ String.concat ", " (steps @ [ held ]) ^ ")"), st)
  | "list__array", [ xs ] when ctx.gc ->
      let v, st = expr ctx st scope xs in
      let helper, st = list_helper ctx st info (type_of ctx scope xs) "array" in
      (atom (Printf.sprintf "%s(%s)" helper v.text), st)
  | "list__array", _ -> unsupported info heap_reason
  | "fill__array", [ n; v ] ->
      let values, steps, st = in_order ctx st scope [ n; v ] in
      if (List.nth values 1).local_env then unsupported info (escaping "an array");
      let hname = "pyk_fill_" ^ acode in
      let st = helper st hname [ "int n"; declaration ect "v" ] [] [ "a.items[i] = v;" ] in
      (call_text hname values steps, st)
  | "init__array_init", [ n; f ] ->
      let ft = fn_type [ TInt (info, 0) ] elem in
      let values, steps, st = in_order ~expected:[ None; Some ft ] ctx st scope [ n; f ] in
      let fct, st = ctype ctx st info ft in
      let hname = "pyk_init_" ^ code ctx.own info ft in
      let body = if is_unit elem then [ "f.fn(f.env, i);"; "a.items[i] = 0;" ] else [ "a.items[i] = f.fn(f.env, i);" ] in
      let st = helper st hname [ "int n"; declaration fct "f" ] [] body in
      (call_text hname values steps, st)
  | "unfold__array_init", [ n; seed; f ] ->
      let seed_t = type_of ctx scope seed in
      let pair = TTuple (info, [ elem; seed_t ], 0) in
      let ft = fn_type [ seed_t ] pair in
      let values, steps, st = in_order ~expected:[ None; None; Some ft ] ctx st scope [ n; seed; f ] in
      let sct, st = ctype ctx st info seed_t in
      let pct, st = ctype ctx st info pair in
      let fct, st = ctype ctx st info ft in
      let hname = "pyk_unfold_" ^ code ctx.own info ft in
      let st =
        helper st hname
          [ "int n"; declaration sct "s"; declaration fct "f" ]
          [ declaration pct "r" ^ ";" ]
          [ "r = f.fn(f.env, s);"; "a.items[i] = r.a0;"; "s = r.a1;" ]
      in
      (call_text hname values steps, st)
  | _ -> unsupported info (Printf.sprintf "the builtin `%s` with these arguments" name)

(** A field every constructor of a datatype has, read through a function
    of its own. ctx -> state -> info -> typ -> string -> (string, state) *)
and field_accessor ctx st info t name =
  match t with
  | TCon (_, canonical, args, _) ->
      let Datatype (_, _, ctors, _), bound = datatype_of ctx info canonical args in
      let ct, st = ctype ctx st info t in
      let sel = member_of ctx t in
      let fname = Printf.sprintf "pyk_get_%s_%s" (code ctx.own info t) name in
      if List.mem_assoc fname st.helpers then (fname, st)
      else
        let field_t =
          List.find_map
            (fun (_, fields) -> List.find_map (fun (l, ft) -> if l = Some name then Some (substitute bound ft) else None) fields)
            ctors
        in
        let ft, st = ctype ctx st info (Option.value field_t ~default:(TInt (info, 0))) in
        let arms =
          List.mapi
            (fun tag (cname, fields) ->
              let index =
                let rec go i = function [] -> 0 | (l, _) :: rest -> if l = Some name then i else go (i + 1) rest in
                go 0 fields
              in
              Printf.sprintf "    case %d: return v%su.%s.f%d;" tag sel (c_ident cname) index)
            ctors
        in
        (* The last constructor's field is what `default` answers, so the
           function returns on every path. *)
        let last =
          match List.rev ctors with
          | (cname, fields) :: _ ->
              let rec go i = function [] -> 0 | (l, _) :: rest -> if l = Some name then i else go (i + 1) rest in
              Printf.sprintf "v%su.%s.f%d" sel (c_ident cname) (go 0 fields)
          | [] -> "0"
        in
        let text =
          Printf.sprintf "static %s(%s)\n{\n    switch (v%stag) {\n%s\n    }\n    return %s;\n}" (declaration ft fname) (declaration ct "v") sel
            (String.concat "\n" (List.filteri (fun i _ -> i < List.length arms - 1) arms))
            last
        in
        (fname, need_helper st fname text)
  | _ -> unsupported info "a field of a value that is not a datatype"

(** A name read as a value. ctx -> state -> scope -> expr -> string ->
    (cexpr, state) *)
and variable ctx st scope e name =
  let info = expr_info e in
  let b = lookup scope info name in
  match b.kind with
  | BFn f -> function_value ctx st scope e f
  | BCell -> (mk p_unary ("*" ^ b.value.text), st)
  | _ -> (b.value, st)

(** The function `alias.field` names, where it is one. ctx -> string ->
    string -> fn? *)
and qualified_fn ctx alias field =
  let module_ = Option.value (List.assoc_opt alias ctx.modules) ~default:alias in
  let sigmap = Option.value (List.assoc_opt module_ ctx.context.sigmaps) ~default:[] in
  match List.find_map (fun (n, t, _) -> if n = field then Some t else None) sigmap with
  | Some ((TFunction _ | TForall (_, _, TFunction _, _)) as t) ->
      let vars, _, r = function_parts t in
      let declared = Option.value (List.assoc_opt module_ ctx.context.external_fields) ~default:[] in
      Some
        {
          cname = module_name module_ field;
          generic = vars <> [];
          lifted = false;
          void = is_unit r;
          ftype = t;
          host = List.mem module_ ctx.context.externals || List.mem field declared;
        }
  | _ -> None

(** The C function a call to f reaches at this instance -- for a
    polymorphic one, the instance its arguments and result ask for, which
    is added to what the file compiles.
    ctx -> state -> scope -> info -> fn -> typ -> [typ] -> (string, state) *)
and instance ctx st info f result args =
  if not f.generic then (f.cname, st)
  else
    let vars, ps, r = function_parts f.ftype in
    let bound = matching [] r result in
    let bound = List.fold_left2 (fun b p a -> matching b p a) bound ps (if List.length args = List.length ps then args else ps) in
    let sigma = List.map (fun v -> (v, Option.value (List.assoc_opt v bound) ~default:(TTuple (info, [], 0)))) vars in
    match List.assoc_opt f.cname st.templates with
    | None when not f.lifted ->
        (* Another module's: that module compiles the instance, which is
           asked of it, and this file declares it. *)
        let name = f.cname ^ "_m" ^ String.concat "" (List.map (fun (_, t) -> code ctx.own info t) sigma) in
        if List.mem_assoc name st.protos then (name, st)
        else
          let ps = List.map (substitute sigma) ps and r = substitute sigma r in
          let pts, st = List.fold_left (fun (out, st) p -> let ct, st = ctype ctx st info p in (out @ [ ct ], st)) ([], st) ps in
          let rt, st = if is_unit r then ("void", st) else ctype ctx st info r in
          let proto =
            Printf.sprintf "%s(%s);" (declaration rt name) (match pts with [] -> "void" | pts -> String.concat ", " pts)
          in
          (name, { st with requests = st.requests @ [ (f.cname, sigma) ]; protos = st.protos @ [ (name, proto) ] })
    | None ->
        unsupported info
          (Printf.sprintf
             "the polymorphic function %s of another module: C compiles a \
              polymorphic function once per type, where it is written"
             f.cname)
    | Some template ->
        let name =
          f.cname ^ "_m" ^ String.concat "" (List.map (fun (_, t) -> code ctx.own info t) (template.t_sigma @ sigma))
        in
        (* The def's own variables first: a nested def's may be spelled
           like those of the def it is written in. *)
        let sigma = sigma @ template.t_sigma in
        if StringSet.mem name st.instances then (name, st)
        else (name, { st with instances = StringSet.add name st.instances; pending = st.pending @ [ (name, f.cname, sigma) ] })

(** A def used as a value: its closure, an environment beside it on the
    stack where it captures anything. ctx -> state -> scope -> expr -> fn
    -> (cexpr, state) *)
and function_value ?at ctx st scope e f =
  let info = expr_info e in
  let t = match at with Some t -> substitute ctx.sigma t | None -> type_of ctx scope e in
  let t = match t with TFunction _ -> t | _ -> substitute ctx.sigma f.ftype in
  if type_vars (match t with TForall (_, _, b, _) -> b | t -> t) <> [] then
    unsupported info
      "a polymorphic function as a value: C compiles a polymorphic function \
       once per type, and a value of every type has no one function to be";
  let _, ps, r = function_parts t in
  let target, st = instance ctx st info f r ps in
  let _, st = ctype ctx st info t in
  let wrapper = "pyk_w_" ^ target in
  let pts, st =
    List.fold_left (fun (out, st) p -> let ct, st = ctype ctx st info p in (out @ [ ct ], st)) ([], st) ps
  in
  let rt, st = if is_unit r then ("void", st) else ctype ctx st info r in
  let params = List.mapi (fun i ct -> (ct, Printf.sprintf "p%d" (i + 1))) pts in
  let args = String.concat ", " (List.map snd params) in
  let captures_nothing =
    match List.assoc_opt target st.captures with Some { direct = []; reaches = []; _ } -> true | _ -> false
  in
  let call =
    if f.lifted && not captures_nothing then
      Printf.sprintf "%s(%s%s)" target (marker "U" target (if params = [] then "0" else "1")) args
    else if f.lifted then Printf.sprintf "%s(%s%s)" target (marker "A" target (if params = [] then "0" else "1")) args
    else Printf.sprintf "%s(%s)" target args
  in
  let st =
    if List.mem_assoc wrapper st.wrappers then st
    else
      let body =
        (if f.lifted && not captures_nothing then Printf.sprintf "    struct pyk_env_%s *e = env;\n" target else "    (void)env;\n")
        ^ if is_unit r then Printf.sprintf "    %s;" call else Printf.sprintf "    return %s;" call
      in
      let text =
        Printf.sprintf "static %s(%s)\n{\n%s\n}" (declaration rt wrapper)
          (String.concat ", " ("void *env" :: List.map (fun (ct, n) -> declaration ct n) params))
          body
      in
      let env_type =
        if f.lifted && not captures_nothing then
          Printf.sprintf "struct pyk_env_%s {\n    int pyk_unused;\n%s\n};\n" target (marker "E" target "0")
        else ""
      in
      { st with wrappers = st.wrappers @ [ (wrapper, env_type ^ text) ] }
  in
  let captures_nothing =
    match List.assoc_opt target st.captures with Some { direct = []; reaches = []; _ } -> true | _ -> false
  in
  if f.lifted && (not captures_nothing) && ctx.gc then
    (* On c23-gc the environment is on the collected heap, made and
       filled where the value is: it may outlive this function. *)
    let ct = Printf.sprintf "struct pyk_env_%s *" target in
    let env, st = temp st "env" in
    let st = { st with temps = st.temps @ [ (ct, env) ] } in
    ( atom
        (Printf.sprintf "(%s = GC_MALLOC(sizeof *%s), %spyk_mk_%s(%s, %s, NULL))" env env (marker "C" target env)
           (code ctx.own info t) wrapper env),
      st )
  else if f.lifted && not captures_nothing then
    let env, st = temp st "env" in
    let st =
      { st with pre = st.pre @ [ CDecl (Printf.sprintf "struct pyk_env_%s" target, env, None); CLine (marker "S" target env) ] }
    in
    (atom ~local_env:true (Printf.sprintf "pyk_mk_%s(%s, &%s, NULL)" (code ctx.own info t) wrapper env), st)
  else (atom (Printf.sprintf "pyk_mk_%s(%s, NULL, %s)" (code ctx.own info t) wrapper target), st)

(** A call. ctx -> state -> scope -> expr -> expr -> [expr] -> (cexpr, state) *)
and call ctx st scope e func args =
  let info = expr_info e in
  let f =
    match func with
    | EVar (_, name, _) -> ( match SMap.find_opt name scope.names with Some { kind = BFn f; _ } -> Some f | _ -> None)
    | EQualified (_, alias, field, _) -> qualified_fn ctx alias field
    | _ -> None
  in
  let result = type_of ctx scope e in
  match f with
  | Some f ->
      let _, ps, r = function_parts f.ftype in
      let arg_types = List.map (type_of ctx scope) args in
      (* The parameters at this call, for an argument that is itself a
         polymorphic function. *)
      (* A polymorphic function handed as an argument says nothing of its
         own type here; what the other arguments and the result settle
         says what it is wanted at, and that instance then settles the
         rest. *)
      let generic_fn a =
        match a with
        | EVar (_, name, _) -> (match SMap.find_opt name scope.names with Some { kind = BFn f; _ } when f.generic -> Some f | _ -> None)
        | EQualified (_, alias, field, _) -> (match qualified_fn ctx alias field with Some f when f.generic -> Some f | _ -> None)
        | _ -> None
      in
      let bound = matching [] r result in
      let bound =
        if List.length ps = List.length arg_types then
          List.fold_left2
            (fun b (p, a) at -> if generic_fn a <> None then b else matching b p at)
            bound (List.combine ps args) arg_types
        else bound
      in
      let rec settle bound rounds =
        if rounds = 0 || List.length ps <> List.length args then bound
        else
          let next =
            List.fold_left2
              (fun b p a ->
                match generic_fn a with
                | None -> b
                | Some g -> (
                    let wanted = substitute b p in
                    match wanted with
                    | TFunction (_, wps, _, _, _, _, _) ->
                        let _, gps, gr = function_parts g.ftype in
                        if List.length gps <> List.length wps then b
                        else
                          let gb = List.fold_left2 (fun gb gp wp -> if type_vars wp = [] then matching gb gp wp else gb) [] gps wps in
                          let instance_t = substitute gb (TFunction (no_info, gps, gr, 0, 0, None, [])) in
                          matching b p instance_t
                    | _ -> b))
              bound ps args
          in
          if List.length next = List.length bound then bound else settle next (rounds - 1)
      in
      let bound = settle bound 4 in
      let expected = List.map (fun p -> Some (substitute bound p)) ps in
      let target, st = instance ctx st info f result (List.map (substitute bound) ps) in
      let values, steps, st =
        if f.host then host_arguments ctx st scope info ps args else in_order ~expected ctx st scope args
      in
      let texts = List.map (fun v -> v.text) values in
      let text =
        if f.lifted then Printf.sprintf "%s(%s%s)" target (marker "A" target (if texts = [] then "0" else "1")) (String.concat ", " texts)
        else Printf.sprintf "%s(%s)" target (String.concat ", " texts)
      in
      let call = if f.void then Printf.sprintf "(%s, 0)" text else text in
      (sequenced steps (atom call), st)
  | None ->
      let pieces, steps, st = in_order ctx st scope (func :: args) in
      let fv = List.hd pieces in
      let ft = type_of ctx scope func in
      let _, _, r = function_parts ft in
      let is_name =
        String.length fv.text > 0
        && String.for_all (fun c -> c = '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) fv.text
      in
      (* A closure held anywhere but in a name is held in a temporary, so
         it is worked out once. *)
      let call, st =
        let args = List.map (fun v -> v.text) (List.tl pieces) in
        if is_name then (Printf.sprintf "%s.fn(%s)" fv.text (String.concat ", " ((fv.text ^ ".env") :: args)), st)
        else
          let ct, st = ctype ctx st info ft in
          let held, st = fresh_temp st ct in
          (Printf.sprintf "(%s = %s, %s.fn(%s))" held (at p_assign fv) held (String.concat ", " ((held ^ ".env") :: args)), st)
      in
      let call = if is_unit r then Printf.sprintf "(%s, 0)" call else call in
      (sequenced steps (atom call), st)

(** The arguments of a call to the host: a callback is a plain pointer to
    one of the program's own top-level functions, since a C
    implementation is handed what the old interface hands it.
    ctx -> state -> scope -> info -> [typ] -> [expr] -> ([cexpr], [string], state) *)
and host_arguments ctx st scope info ps args =
  (* A lambda handed to the host is lifted to a function of its own, and
     handed over as that function, which it may be only where it
     captures nothing. *)
  let st, args_lifted =
    List.fold_left
      (fun (st, out) (i, a) ->
        match (List.nth_opt ps i, a) with
        | Some (TFunction _), ELambda (li, params, body, sym) ->
            let name, st = temp st "lambda" in
            let t = type_of ctx scope a in
            let def = SFunctionDef (li, name, params, [ SExprStmt (li, body, 0) ], None, sym, false, [], false) in
            let st = lift_with ctx st scope def name t in
            (match List.assoc_opt name st.captures with
            | Some { direct = []; reaches = []; _ } -> ()
            | _ ->
                unsupported li
                  "a lambda handed to a module implemented in C that captures \
                   values: C hands the host a plain function pointer, which \
                   carries nothing");
            (st, out @ [ Some name ])
        | _ -> (st, out @ [ None ]))
      (st, [])
      (List.mapi (fun i a -> (i, a)) args)
  in
  let plain = List.map2 (fun a l -> match l with Some _ -> ETuple (expr_info a, [], 0) | None -> a) args args_lifted in
  let values, steps, st = in_order ctx st scope plain in
  let values = List.map2 (fun v l -> match l with Some name -> atom name | None -> v) values args_lifted in
  let values =
    List.mapi
      (fun i v ->
        match (List.nth_opt ps i, List.nth args i) with
        | Some (TFunction _), EVar (_, name, _) -> (
            match SMap.find_opt name scope.names with
            | Some { kind = BFn { cname; lifted = false; generic = false; _ }; _ } -> atom cname
            | _ -> atom (Printf.sprintf "pyk_plain_%s(%s)" (code ctx.own info (Option.get (List.nth_opt ps i))) v.text))
        | Some (TFunction _), ELambda _ -> v
        | Some (TFunction _ as pt), _ -> atom (Printf.sprintf "pyk_plain_%s(%s)" (code ctx.own info pt) v.text)
        | _ -> v)
      values
  in
  (* A function value is handed over as its plain function, which only
     one that captures nothing has. *)
  let st =
    List.fold_left
      (fun st p ->
        match p with
        | TFunction _ as pt ->
            let ct, st = ctype ctx st info pt in
            let helper = "pyk_plain_" ^ code ctx.own info pt in
            need_helper st helper
              (Printf.sprintf
                 "static %s %s(%s c)\n{\n    if (c.plain == NULL) {\n        fprintf(stderr, \"a function that captures values cannot be handed to a module implemented in C\\n\");\n        exit(1);\n    }\n    return c.plain;\n}"
                 (host_callback_type ctx pt) helper ct)
        | _ -> st)
      st ps
  in
  (values, steps, st)

(** A builtin's call. ctx -> state -> scope -> expr -> string -> [expr] ->
    (cexpr, state) *)
and builtin ctx st scope e name args =
  let info = expr_info e in
  let values, steps, st = in_order ctx st scope args in
  let arg_type i = type_of ctx scope (List.nth args i) in
  let wrap v = (sequenced steps v, st) in
  match (name, values) with
  | "range", bounds when ctx.gc ->
      (* A list of the Ints counted, made as it is asked for. *)
      let _, st = ctype ctx st info (TList (info, TInt (info, 0), 0)) in
      let st = need_helper st "pyk_range" range_helper in
      let start, stop, step =
        match bounds with
        | [ stop ] -> ("0", stop.text, "1")
        | [ start; stop ] -> (start.text, stop.text, "1")
        | [ start; stop; step ] -> (start.text, stop.text, step.text)
        | _ -> unsupported info "`range` takes one, two or three arguments"
      in
      (sequenced steps (atom (Printf.sprintf "pyk_range(%s, %s, %s)" start stop step)), st)
  | "range", _ ->
      unsupported info
        "`range` outside a `for` loop's header, where it is a list, which \
         needs a heap that is freed: plain C has none, and c23-gc compiles it"
  | "len", [ v ] -> (
      match arg_type 0 with
      | TString _ -> (sequenced steps (atom (Printf.sprintf "pyk_utf8_length(%s)" v.text)), need_char st "pyk_utf8_length")
      | t when Typesystem.array_element t <> None -> wrap (atom (at p_atom v ^ ".len"))
      | t when dynarray_element t <> None || slice_element t <> None || mutmap_parts t <> None -> wrap (atom (at p_atom v ^ "->len"))
      | TList _ as t when ctx.gc ->
          let length, st = list_helper ctx st info t "length" in
          (sequenced steps (atom (Printf.sprintf "%s(%s)" length v.text)), st)
      | _ -> unsupported info heap_reason)
  | ("remove" | "discard" | "get" | "has" | "keys" | "values" | "items" | "clear"), (_ :: _ as vs)
    when mutmap_parts (arg_type 0) <> None ->
      (* A MutMap's: `keys`, `values` and `items` make lists, which plain C
         refuses. *)
      if (not ctx.gc) && List.mem name [ "keys"; "values"; "items" ] then unsupported info heap_reason;
      let helper, st = mutmap_helper ctx st info (arg_type 0) name in
      let called = Printf.sprintf "%s(%s)" helper (String.concat ", " (List.map (fun v -> v.text) vs)) in
      (sequenced steps (atom (if List.mem name [ "discard"; "clear" ] then Printf.sprintf "(%s, 0)" called else called)), st)
  | "view", [ a; i; j ] ->
      let helper, st = run_helper ctx st info (arg_type 0) "view" in
      (sequenced steps (atom (Printf.sprintf "%s(%s, %s, %s)" helper a.text i.text j.text)), st)
  | "copy_into", [ dst; src ] ->
      (* Each side is its elements and how many: an array's `items` and
         `len`, a view's from where its run starts. *)
      let elem = Option.value (store_element (arg_type 0)) ~default:(TTuple (no_info, [], 0)) in
      let helper, st = copy_helper ctx st info elem in
      let held i (v : cexpr) (steps, st) =
        let t = arg_type i in
        let name, steps, st =
          if String.for_all (fun c -> c = '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) v.text then (v.text, steps, st)
          else
            let ct, st = ctype ctx st info t in
            let name, st = fresh_temp st ct in
            (name, steps @ [ Printf.sprintf "%s = %s" name (at p_assign v) ], st)
        in
        let run = if slice_element t <> None then Printf.sprintf "%s->items + %s->start, %s->len" name name name else Printf.sprintf "%s.items, %s.len" name name in
        (run, (steps, st))
      in
      let d, acc = held 0 dst (steps, st) in
      let s_, (steps, st) = held 1 src acc in
      (sequenced steps (atom (Printf.sprintf "(%s(%s, %s), 0)" helper d s_)), st)
  | "same", [ a; b ] when Typesystem.array_element (arg_type 0) <> None ->
      (* One array is one block of elements: never empty, even for no
         elements, so two arrays never share one. *)
      wrap (binary p_eq "==" (atom (at p_atom a ^ ".items")) (atom (at p_atom b ^ ".items")))
  | "same", [ a; b ] ->
      (* A DynArray or a var struct is a pointer: one is one pointer. *)
      wrap (binary p_eq "==" a b)
  | ("push" | "insert" | "clear"), (_ :: _ as vs) when dynarray_element (arg_type 0) <> None ->
      let helper, st = dynarray_helper ctx st info (arg_type 0) name in
      (sequenced steps (atom (Printf.sprintf "(%s(%s), 0)" helper (String.concat ", " (List.map (fun v -> v.text) vs)))), st)
  | ("pop" | "remove"), (_ :: _ as vs) when dynarray_element (arg_type 0) <> None ->
      let helper, st = dynarray_helper ctx st info (arg_type 0) name in
      (sequenced steps (atom (Printf.sprintf "%s(%s)" helper (String.concat ", " (List.map (fun v -> v.text) vs)))), st)
  | "string", [ v ] -> (
      match arg_type 0 with
      | TString _ -> wrap v
      | TChar _ -> (sequenced steps (atom (Printf.sprintf "pyk_utf8(%s)" v.text)), need_char st "pyk_utf8")
      | t ->
          let show, st = shower ctx st info t in
          (sequenced steps (atom (show v.text)), st))
  | "int", [ v ] -> (
      match arg_type 0 with
      | TInt _ | TChar _ -> wrap v
      | TFloat _ -> (sequenced steps (atom (Printf.sprintf "pyk_truncate(%s)" v.text)), need_helper st "pyk_truncate" truncate_helper)
      | TBool _ -> wrap (mk p_cond (Printf.sprintf "%s ? 1 : 0" (at (p_cond + 1) v)))
      | TString _ -> (sequenced steps (atom (Printf.sprintf "pyk_int_of_string(%s)" v.text)), need_helper st "pyk_int_of_string" int_of_string_helper)
      | _ -> unsupported info "`int` of this type")
  | "float", [ v ] -> (
      match arg_type 0 with
      | TFloat _ -> wrap v
      | TInt _ | TChar _ -> wrap (mk p_unary (Printf.sprintf "(double)%s" (at p_unary v)))
      | TBool _ -> wrap (mk p_cond (Printf.sprintf "%s ? 1.0 : 0.0" (at (p_cond + 1) v)))
      | TString _ ->
          ( sequenced steps (atom (Printf.sprintf "pyk_float_of_string(%s)" v.text)),
            { (need_helper st "pyk_float_of_string" float_of_string_helper) with includes_math = true } )
      | _ -> unsupported info "`float` of this type")
  | "bool", [ v ] -> (
      match arg_type 0 with
      | TBool _ -> wrap v
      | TInt _ -> wrap (binary p_eq "==" v (atom "1"))
      | TFloat _ -> wrap (binary p_eq "==" v (atom "1.0"))
      | TString _ -> wrap (binary p_eq "==" (atom (Printf.sprintf "strcmp(%s, \"true\")" v.text)) (atom "0"))
      | TChar _ -> wrap (binary p_eq "!=" v (atom "0"))
      | _ -> unsupported info "`bool` of this type")
  | "char", [ v ] -> (
      match arg_type 0 with
      | TChar _ -> wrap v
      | TInt _ -> (sequenced steps (atom (Printf.sprintf "pyk_char_of_int(%s)" v.text)), need_char st "pyk_char_of_int")
      | TString _ -> (sequenced steps (atom (Printf.sprintf "pyk_char_of_string(%s)" v.text)), need_char st "pyk_char_of_string")
      | _ -> unsupported info "`char` of this type")
  | _ -> unsupported info (Printf.sprintf "the builtin `%s` with these arguments" name)

(** A print or debug call, as the C call writing the line.
    ctx -> state -> scope -> string -> [expr] -> (string, state) *)
and print_call ctx st scope name args =
  let values, steps, st = in_order ctx st scope args in
  (* Every argument is worked out before any is written: where a later
     one calls something that could change an earlier one -- an array, a
     DynArray or a var struct, or what holds one -- each is put in a
     temporary first, in order. *)
  let changeable a =
    reaches_type ctx (fun u -> (match u with TCon (_, c, _, _) when is_store c -> true | _ -> false) || var_struct ctx u) (type_of ctx scope a)
  in
  let rec exposed = function [] -> false | a :: rest -> (changeable a && List.exists (has_call ctx scope) rest) || exposed rest in
  let values, steps, st =
    if not (exposed args) then (values, steps, st)
    else
      List.fold_left2
        (fun (out, steps, st) a v ->
          (* One in_order pinned already is worked out in its turn. *)
          let pinned =
            String.length v.text > 5 && String.sub v.text 0 5 = "pyk_t"
            && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub v.text 5 (String.length v.text - 5))
          in
          if pinned then (out @ [ v ], steps, st)
          else
            let ct, st = ctype ctx st no_info (type_of ctx scope a) in
            let held, st = fresh_temp st ct in
            (out @ [ atom held ], steps @ [ Printf.sprintf "%s = %s" held (at p_assign v) ], st))
        ([], steps, st) args values
  in
  let pieces, st =
    List.fold_left2
      (fun (out, st) a v ->
        let t = type_of ctx scope a in
        match t with
        | TInt _ -> (out @ [ ("%d", v.text) ], st)
        | TString _ -> (out @ [ ("%s", v.text) ], st)
        | TChar _ -> (out @ [ ("%s", Printf.sprintf "pyk_utf8(%s)" v.text) ], need_char st "pyk_utf8")
        | _ ->
            let text, st = printed ctx st (expr_info a) t v in
            (out @ [ ("%s", text) ], st))
      ([], st) args values
  in
  let format = String.concat " " (List.map fst pieces) in
  let call =
    if Builtin.is_debug name then
      Printf.sprintf "fprintf(stderr, \"%s\\n\"%s)" format (String.concat "" (List.map (fun (_, v) -> ", " ^ v) pieces))
    else Printf.sprintf "printf(\"%s\\n\"%s)" format (String.concat "" (List.map (fun (_, v) -> ", " ^ v) pieces))
  in
  ((if steps = [] then call else "(" ^ String.concat ", " (steps @ [ call ]) ^ ")"), st)

(** `(x, y) => e`: a function of its own, as a closure.
    ctx -> state -> scope -> expr -> [param] -> expr -> (cexpr, state) *)
and lambda ctx st scope e params body =
  let info = expr_info e in
  let name, st = temp st "lambda" in
  let t = type_of ctx scope e in
  let def = SFunctionDef (info, name, params, [ SExprStmt (info, body, 0) ], None, expr_sym e, false, [], false) in
  let f = { cname = name; generic = false; lifted = true; void = (let _, _, r = function_parts t in is_unit r); ftype = t; host = false } in
  let inner = bind_value scope name { value = atom name; kind = BFn f; btype = t; cname_ = name } in
  let st = lift_with ctx st inner def name t in
  function_value ctx st inner (EVar (info, name, expr_sym e)) f

(** A list comprehension as statements on c23-gc, building its list into
    dest, which holds `[]` already: a loop per `for`, an `if` per
    condition, and each element put at the end, where `pyk_endN` points.
    ctx -> state -> scope -> expr -> string -> ([cstmt], state) *)
and comprehension ctx st scope e dest =
  match e with
  | EListComp (info, element, clauses, _) ->
      let t = type_of ctx scope e in
      let lt, st = ctype ctx st info t in
      let lcode = code ctx.own info t in
      let end_, st = temp st "end" in
      let rec go st scope clauses =
        match clauses with
        | [] ->
            let v, st = expr ctx st scope element in
            let pre, st = flush st in
            ( pre
              @ [
                  CLine (Printf.sprintf "*%s = pyk_cons_%s(%s, NULL);" end_ lcode v.text);
                  CLine (Printf.sprintf "%s = &(*%s)->tail;" end_ end_);
                ],
              st )
        | CompIf (_, c, _) :: rest ->
            let cv, st = expr ctx st scope c in
            let pre, st = flush st in
            let body, st = go st scope rest in
            (pre @ [ CIf (cv.text, body, None) ], st)
        | CompFor (ci, p, sequence, _) :: rest -> each ctx st scope ci p sequence (fun st scope -> go st scope rest)
      in
      let body, st = go st scope clauses in
      (CDecl (pointer_to lt, end_, Some ("&" ^ dest)) :: body, st)
  | _ -> unsupported (expr_info e) "a comprehension"

(** A loop over sequence -- a `range`, a String, an array or a list --
    with p matched against each element and body run where it matches,
    as a comprehension's `for` does. ctx -> state -> scope -> info ->
    pattern -> expr -> (state -> scope -> ([cstmt], state)) -> ([cstmt],
    state) *)
and each ctx st scope info p sequence body =
  (* The element is named for the pattern where the pattern is a name. *)
  let base = match p with PCapture (_, n, _) -> n | _ -> "item" in
  let cname, st = fresh st base in
  let matched st elem_t =
    match p with
    | PCapture (_, n, _) ->
        body st (bind_value scope n { value = atom cname; kind = BLocal; btype = elem_t; cname_ = cname })
    | _ ->
        let conds, binds, st = pattern ctx st p (atom cname) elem_t in
        let decls, inner, st = bind_all ctx st scope binds in
        let inner_stmts, st = body st inner in
        if conds = [] then (decls @ inner_stmts, st) else ([ CIf ((conjunction conds).text, decls @ inner_stmts, None) ], st)
  in
  match sequence with
  | ECall (_, EVar (_, "range", _), args, _) when not (SMap.mem "range" scope.names) ->
      let bounds, steps, st = in_order ctx st scope (arg_exprs args) in
      let pre, st = flush st in
      let start, stop, step =
        match bounds with
        | [ stop ] -> (atom "0", stop, atom "1")
        | [ start; stop ] -> (start, stop, atom "1")
        | [ start; stop; step ] -> (start, stop, step)
        | _ -> unsupported info "`range` takes one, two or three arguments"
      in
      let stop_name, st = fresh st (base ^ "_stop") in
      let step_name, st = fresh st (base ^ "_step") in
      let inner, st = matched st (TInt (info, 0)) in
      let header =
        Printf.sprintf "%s = %s; %s > 0 ? %s < %s : %s > %s; %s += %s" cname (sequenced steps start).text step_name cname
          stop_name cname stop_name cname step_name
      in
      ( pre
        @ [ CDecl ("int", stop_name, Some stop.text); CDecl ("int", step_name, Some step.text); CDecl ("int", cname, None);
            CFor (header, inner) ],
        st )
  | _ -> (
      let seq_t = type_of ctx scope sequence in
      let v, st = expr ctx st scope sequence in
      let pre, st = flush st in
      match seq_t with
      | TString _ ->
          let pos, st = fresh st (base ^ "_at") in
          let st = need_char st "pyk_utf8_step" in
          let inner, st = matched st (TChar (info, 0)) in
          ( pre
            @ [ CDecl ("const char *", pos, None); CDecl ("int", cname, None);
                CFor (Printf.sprintf "%s = %s; (%s = pyk_utf8_step(%s, &%s)) != NULL; " pos (at p_assign v) pos pos cname, inner) ],
            st )
      | TList (_, elem, _) ->
          let elem = list_element elem in
          let lt, st = ctype ctx st info seq_t in
          let ect, st = ctype ctx st info elem in
          let cell, st = fresh st (base ^ "_at") in
          let inner, st = matched st elem in
          ( pre
            @ [ CDecl (lt, cell, None); CDecl (ect, cname, None);
                CFor (Printf.sprintf "%s = %s; %s != NULL; %s = %s->tail" cell (at p_assign v) cell cell cell,
                      CLine (Printf.sprintf "%s = %s->head;" cname cell) :: inner) ],
            st )
      | at_t when store_element at_t <> None || mutmap_parts at_t <> None ->
          let act, st = ctype ctx st info at_t in
          let held, st = fresh st (base ^ (if mutmap_parts at_t <> None then "_mutmap" else "_array")) in
          let idx, st = fresh st (base ^ "_at") in
          let version, st = if mutmap_parts at_t <> None then fresh st (base ^ "_version") else ("", st) in
          let elem, decls, test, item, st = walk_of ctx st at_t held idx version in
          let ect, st = ctype ctx st info elem in
          let inner, st = matched st elem in
          ( pre
            @ [ CDecl (act, held, Some v.text) ] @ decls @ [ CDecl ("int", idx, None); CDecl (ect, cname, None);
                CFor (Printf.sprintf "%s = 0; %s; %s++" idx test idx,
                      CLine (Printf.sprintf "%s = %s;" cname item) :: inner) ],
            st )
      | _ -> unsupported info "a comprehension over what is not a list, a String or an array")

(* --- statements --- *)

(* What becomes of the value a block ends in. *)
and finished ctx st scope fin t (v : cexpr) =
  match fin with
  | `Return ->
      if v.local_env then
        unsupported no_info (escaping "a function answering a value");
      ([ CReturn (Some v.text) ], st)
  | `Void | `Discard -> ([ CLine (v.text ^ ";") ], st)
  | `Assign name -> ([ CLine (Printf.sprintf "%s = %s;" name v.text) ], st)
  | `Turn slots -> (
      match slots with
      | [] -> ([ CLine (v.text ^ ";") ], st)
      | [ (name, _) ] -> ([ CLine (Printf.sprintf "%s = %s;" name v.text) ], st)
      | slots ->
          let ct, st = ctype ctx st no_info t in
          let held, st = fresh_temp st ct in
          ignore scope;
          ( CLine (Printf.sprintf "%s = %s;" held v.text)
            :: List.mapi (fun i (name, _) -> CLine (Printf.sprintf "%s = %s.a%d;" name held i)) slots,
            st ))

(** The statements a `break x`/`continue x` puts x into the innermost
    loop's slots with, as the end of a turn would. Nothing for a bare
    one. ctx -> state -> scope -> expr option -> ([cstmt], state) *)
and jump_value ctx st scope value =
  match (value, List.rev scope.loops) with
  | Some e, slots :: _ ->
      let t =
        match type_of ctx scope e with
        | TUnknown _ when List.length slots > 1 ->
            TTuple (no_info, List.map snd slots, 0)
        | t -> t
      in
      let v, st = expr ctx st scope e in
      let pre, st = flush st in
      let given, st = finished ctx st scope (`Turn slots) t v in
      (pre @ given, st)
  | _ -> ([], st)

(** Statements an expression needed run first, in front of what it was
    used in. state -> ([cstmt], state) *)
and flush st = (st.pre, { st with pre = [] })

(** The statements of a block, each `def` in it declared first.
    ctx -> state -> scope -> [stmt] -> ([cstmt], scope, state) *)
and stmts ctx st scope statements =
  let scope = { scope with block = statements } in
  let scope, st = declare_defs ctx st scope statements in
  List.fold_left
    (fun (out, scope, st) s ->
      let translated, scope, st = stmt ctx st scope s in
      (out @ translated, scope, st))
    ([], scope, st) statements

(** A block whose last statement's value is finished by fin.
    ctx -> state -> scope -> finish -> [stmt] -> ([cstmt], state) *)
and tail_block ctx st scope fin statements =
  match statements with
  | [] -> finished ctx st scope fin (TTuple (no_info, [], 0)) unit_value
  | _ ->
      let scope = { scope with block = statements } in
      let scope, st = declare_defs ctx st scope statements in
      let count = List.length statements in
      let front = List.filteri (fun i _ -> i < count - 1) statements in
      let out, scope, st =
        List.fold_left
          (fun (out, scope, st) s ->
            let translated, scope, st = stmt ctx st scope s in
            (out @ translated, scope, st))
          ([], scope, st) front
      in
      let last, st = tail ctx st scope fin (List.nth statements (count - 1)) in
      (out @ last, st)

(** An expression evaluated as a statement. ctx -> state -> scope -> expr
    -> ([cstmt], state) *)
and effect_of ctx st scope e =
  match e with
  | ETuple (_, [], _) -> ([], st)
  | ECall (_, EVar (_, name, callee), args, _) when Builtin.crosses_host name && not (IntMap.mem callee ctx.tmap) ->
      let line, st = print_call ctx st scope name (arg_exprs args) in
      let pre, st = flush st in
      (pre @ [ CLine (line ^ ";") ], st)
  | e ->
      let v, st = expr ctx st scope e in
      let pre, st = flush st in
      let text =
        let prefix = "(" and suffix = ", 0)" in
        let n = String.length v.text in
        if n > 5 && String.sub v.text 0 1 = prefix && String.sub v.text (n - 4) 4 = suffix then String.sub v.text 1 (n - 5)
        else v.text
      in
      let is_call = String.length text > 0 && text.[String.length text - 1] = ')' && v.prec >= p_atom in
      (pre @ [ CLine ((if is_call then text else "(void)(" ^ text ^ ")") ^ ";") ], st)

(** The last statement of a block, its value finished by fin.
    ctx -> state -> scope -> finish -> stmt -> ([cstmt], state) *)
and tail ctx st scope fin s =
  match s with
  | SExprStmt (_, (EListComp _ as e), _) when ctx.gc && (match fin with `Return | `Assign _ -> true | _ -> false) -> (
      (* Built in place: the loops are statements of their own. *)
      match fin with
      | `Assign name ->
          let body, st = comprehension ctx st scope e name in
          (CLine (Printf.sprintf "%s = NULL;" name) :: body, st)
      | _ ->
          let lt, st = ctype ctx st no_info (type_of ctx scope e) in
          let held, st = temp st "list" in
          let body, st = comprehension ctx st scope e held in
          ((CDecl (lt, held, Some "NULL") :: body) @ [ CReturn (Some held) ], st))
  | SExprStmt (_, e, _) -> (
      let t = type_of ctx scope e in
      match fin with
      | `Void | `Discard | `Turn [] -> effect_of ctx st scope e
      | _ when is_unit t ->
          let s1, st = effect_of ctx st scope e in
          let s2, st = finished ctx st scope fin t unit_value in
          (s1 @ s2, st)
      | _ ->
          let v, st = expr ctx st scope e in
          let pre, st = flush st in
          let fin_stmts, st = finished ctx st scope fin t v in
          (pre @ fin_stmts, st))
  | SIf (_, c, then_body, else_body, _) -> (
      let cond, st = expr ctx st scope c in
      let pre, st = flush st in
      match else_body with
      | Some else_body ->
          let t_stmts, st = tail_block ctx st scope fin then_body in
          let e_stmts, st = tail_block ctx st scope fin else_body in
          (pre @ [ CIf (cond.text, t_stmts, Some e_stmts) ], st)
      | None ->
          let plain, _, st = stmts ctx st scope then_body in
          let after, st =
            match fin with
            | `Void | `Discard | `Turn [] -> ([], st)
            | _ -> finished ctx st scope fin (TTuple (no_info, [], 0)) unit_value
          in
          (pre @ (CIf (cond.text, plain, None) :: after), st))
  | SMatch (_, subject, cases, _) -> match_stmt ctx st scope subject cases fin
  | SLoop _ -> (
      let loop_stmts, value, t, st = loop ctx st scope s in
      match (value, fin) with
      | _, (`Void | `Discard) -> (loop_stmts, st)
      | _ when not (block_completes loop_stmts) -> (loop_stmts, st)
      | Some v, _ ->
          let rest, st = finished ctx st scope fin t v in
          (loop_stmts @ rest, st)
      | None, _ ->
          let rest, st = finished ctx st scope fin (TTuple (no_info, [], 0)) unit_value in
          (loop_stmts @ rest, st))
  | SReturn _ | SReturnStmt _ | SBreak _ | SContinue _ ->
      let translated, _, st = stmt ctx st scope s in
      (translated, st)
  | s -> (
      let translated, _, st = stmt ctx st scope s in
      match fin with
      | `Return | `Assign _ | `Turn (_ :: _) ->
          let after, st = finished ctx st scope fin (TTuple (no_info, [], 0)) unit_value in
          (translated @ after, st)
      | _ -> (translated, st))

(** Translates one statement. ctx -> state -> scope -> stmt ->
    ([cstmt], scope, state) *)
and stmt ctx st scope s =
  match s with
  | SLet (_, TargetName (_, name, _), (EListComp _ as e), _, _, _, _) when ctx.gc ->
      (* Built in place, by loops of its own. *)
      let t = type_of ctx scope e in
      let ct, st = ctype ctx st no_info t in
      let cname, st = fresh st name in
      let body, st = comprehension ctx st scope e cname in
      ( CDecl (ct, cname, Some "NULL") :: body,
        bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname },
        st )
  | SLet (_, target, e, _, _, _, _) ->
      let v, st = expr ctx st scope e in
      let pre, st = flush st in
      let t = type_of ctx scope e in
      let decls, scope, st = destructure ctx st scope target v t in
      (pre @ decls, scope, st)
  | SLetStmt (_, target, inner, _, _, _) -> (
      let t =
        match IntMap.find_opt (stmt_sym s) ctx.tmap with
        | Some t -> substitute ctx.sigma t
        | None -> target_type ctx scope target
      in
      match inner with
      | SLoop _ ->
          let loop_stmts, value, lt, st = loop ctx st scope inner in
          let decls, scope, st =
            destructure ctx st scope target (Option.value value ~default:unit_value) (match t with TUnknown _ -> lt | t -> t)
          in
          (loop_stmts @ decls, scope, st)
      | _ ->
          let t = match t with TUnknown _ -> target_type ctx scope target | t -> t in
          let ct, st = ctype ctx st no_info t in
          let held, st = temp st "v" in
          let body, st = tail ctx st scope (`Assign held) inner in
          let decls, scope, st = destructure ctx st scope target (atom held) t in
          ((CDecl (ct, held, None) :: body) @ decls, scope, st))
  | SVar (_, name, e, _) ->
      let v, st = expr ctx st scope e in
      let pre, st = flush st in
      let t = type_of ctx scope e in
      let ct, st = ctype ctx st no_info t in
      let cname, st = fresh st name in
      if StringSet.mem name scope.cells && ctx.gc then
        (* On c23-gc the cell is on the collected heap: a closure holding
           it may outlive this function. *)
        let alloc = if holds_pointers ctx [] t then "GC_MALLOC" else "GC_MALLOC_ATOMIC" in
        ( pre
          @ [ CDecl (pointer_to ct, cname, Some (Printf.sprintf "%s(sizeof *%s)" alloc cname));
              CLine (Printf.sprintf "*%s = %s;" cname v.text) ],
          bind_value scope name { value = atom cname; kind = BCell; btype = t; cname_ = cname },
          st )
      else if StringSet.mem name scope.cells then
        let cell, st = fresh st (name ^ "_cell") in
        ( pre @ [ CDecl (ct, cell, Some v.text); CDecl (ct ^ (if ct.[String.length ct - 1] = '*' then "*" else " *"), cname, Some ("&" ^ cell)) ],
          bind_value scope name { value = atom cname; kind = BCell; btype = t; cname_ = cname },
          st )
      else (pre @ [ CDecl (ct, cname, Some v.text) ], bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname }, st)
  | SMutateTuple _ -> after_desugar "target_c"
  | SSetDeref (info, pointer, value, _) ->
      (* *p := v: `*p = v;`, the pointer worked out first -- held in a
         temporary only where the value could change what it names. *)
      let pt = type_of ctx scope pointer in
      let pv, st = expr ctx st scope pointer in
      let ppre, st = flush st in
      let plain_local =
        match pointer with
        | EVar (_, name, _) -> (
            match SMap.find_opt name scope.names with
            | Some { kind = BLocal; cname_; value; _ } -> cname_ <> "" && cname_ = value.text && not (is_static st cname_)
            | _ -> false)
        | _ -> false
      in
      let held, decls, st =
        if plain_local || not (has_call ctx scope pointer || has_call ctx scope value) then (pv, [], st)
        else
          let ct, st = ctype ctx st info pt in
          let held, st = temp st "ptr" in
          (atom held, [ CDecl (ct, held, Some pv.text) ], st)
      in
      let vv, st = expr ctx st scope value in
      if vv.local_env then unsupported info (escaping "a variable");
      let vpre, st = flush st in
      (ppre @ decls @ vpre @ [ CLine (Printf.sprintf "*%s = %s;" (at p_unary held) (at p_assign vv)) ], scope, st)
  | SSetField (info, owner, field, value, _) ->
      (* owner.field := value: `p->x = v;`. The owner is worked out
         first, so where the value could change what it names -- a call
         in the value, and an owner that is not a local of its own -- it
         is put in a temporary first. *)
      let owner_t = type_of ctx scope owner in
      (match owner_t with
      | TCon (_, cls, _, _) when Classes.find ctx.classes cls <> None ->
          (* An object's field: the owner held first, then the value. *)
          let ov, st = expr ctx st scope owner in
          let opre, st = flush st in
          let held, st = temp st "owner" in
          let vv, st = expr ctx st scope value in
          let vpre, st = flush st in
          ( opre @ [ CDecl ("pyk_obj *", held, Some ov.text) ] @ vpre @ [ CLine (Printf.sprintf "%s = %s;" (object_field ctx cls field held) vv.text) ],
            scope,
            st )
      | _ ->
      let path =
        match List.assoc_opt field (sole_fields ctx info owner_t) with
        | Some path -> path
        | None -> unsupported info "a field written in place of what is not a var struct"
      in
      let ov, st = expr ctx st scope owner in
      let opre, st = flush st in
      let plain_local =
        match owner with
        | EVar (_, name, _) -> (
            match SMap.find_opt name scope.names with
            | Some { kind = BLocal; cname_; value; _ } -> cname_ <> "" && cname_ = value.text && not (is_static st cname_)
            | _ -> false)
        | _ -> false
      in
      let held, decls, st =
        if plain_local || not (has_call ctx scope owner || has_call ctx scope value) then (ov, [], st)
        else
          let ct, st = ctype ctx st info owner_t in
          let held, st = temp st "owner" in
          (atom held, [ CDecl (ct, held, Some ov.text) ], st)
      in
      let vv, st = expr ctx st scope value in
      if vv.local_env then unsupported info (escaping "a var struct");
      let vpre, st = flush st in
      (opre @ decls @ vpre @ [ CLine (Printf.sprintf "%s->%s = %s;" (at p_atom held) path (at p_assign vv)) ], scope, st))
  | SSetIndex (info, owner, key, value, _) when mutmap_parts (type_of ctx scope owner) <> None ->
      (* d[k] := v: the MutMap, the key and the value in order, then the
         entry put -- at the end, or over the key's own value. *)
      let values, steps, st = in_order ctx st scope [ owner; key; value ] in
      let pre, st = flush st in
      if (List.nth values 2).local_env then unsupported info (escaping "a MutMap");
      let put, st = mutmap_helper ctx st info (type_of ctx scope owner) "put" in
      ( pre
        @ List.map (fun step -> CLine (step ^ ";")) steps
        @ [ CLine (Printf.sprintf "%s(%s);" put (String.concat ", " (List.map (fun v -> v.text) values))) ],
        scope,
        st )
  | SSetIndex (info, owner, index, value, _) when slice_element (type_of ctx scope owner) <> None ->
      (* w[k] := v: the view and the index each held, the index checked
         on c23-gc, then the value worked out and written into the run. *)
      let owner_t = type_of ctx scope owner in
      let wt, st = ctype ctx st info owner_t in
      let ov, st = expr ctx st scope owner in
      let opre, st = flush st in
      let held, st = temp st "view" in
      let iv, st = expr ctx st scope index in
      let ipre, st = flush st in
      let idx, st = temp st "idx" in
      let vv, st = expr ctx st scope value in
      if vv.local_env then unsupported info (escaping "an array");
      let vpre, st = flush st in
      let checks, st =
        if ctx.gc then
          let at, st = run_helper ctx st info owner_t "at" in
          ([ CLine (Printf.sprintf "(void)%s(%s, %s);" at held idx) ], st)
        else ([], st)
      in
      ( opre
        @ [ CDecl (wt, held, Some ov.text) ]
        @ ipre
        @ [ CDecl ("int", idx, Some iv.text) ]
        @ checks @ vpre
        @ [ CLine (Printf.sprintf "%s->items[%s->start + %s] = %s;" held held idx (at p_assign vv)) ],
        scope,
        st )
  | SSetIndex (info, owner, index, value, _) when not ctx.gc ->
      (* Plain C: owner.items[index] = value (owner->items for a DynArray),
         nothing checked; operands that can print are pinned in order
         first. *)
      let owner_t = type_of ctx scope owner in
      if Typesystem.array_element owner_t = None && dynarray_element owner_t = None then
        unsupported info "an element write into what is not an array or a DynArray";
      let sel = if dynarray_element owner_t <> None then "->" else "." in
      let values, steps, st = in_order ctx st scope [ owner; index; value ] in
      let pre, st = flush st in
      let o = List.nth values 0 and i = List.nth values 1 and v = List.nth values 2 in
      if v.local_env then unsupported info (escaping "an array");
      ( pre
        @ List.map (fun step -> CLine (step ^ ";")) steps
        @ [ CLine (Printf.sprintf "%s%sitems[%s] = %s;" (at p_atom o) sel i.text (at p_assign v)) ],
        scope,
        st )
  | SSetIndex (info, owner, index, value, _) when dynarray_element (type_of ctx scope owner) <> None ->
      (* owner[index] := value on c23-gc, for a DynArray: the DynArray and the
         index each into a temporary, the index checked, the value worked
         out, and the index checked again before the write -- the value
         may have shrunk the DynArray. *)
      let owner_t = type_of ctx scope owner in
      let elem = Option.get (dynarray_element owner_t) in
      let vt, st = ctype ctx st info owner_t in
      let ect, st = ctype ctx st info elem in
      let ov, st = expr ctx st scope owner in
      let opre, st = flush st in
      let held, st = temp st "dynarray" in
      let iv, st = expr ctx st scope index in
      let ipre, st = flush st in
      let idx, st = temp st "idx" in
      let vv, st = expr ctx st scope value in
      if vv.local_env then unsupported info (escaping "a DynArray");
      let vpre, st = flush st in
      let worked, st = temp st "value" in
      let st = need_helper st "pyk_check_dynarray_index" dynarray_index_helper in
      let check = CLine (Printf.sprintf "pyk_check_dynarray_index(%s, %s->len);" idx held) in
      ( opre
        @ [ CDecl (vt, held, Some ov.text) ]
        @ ipre
        @ [ CDecl ("int", idx, Some iv.text); check ]
        @ vpre
        @ [ CDecl (ect, worked, Some vv.text); check; CLine (Printf.sprintf "%s->items[%s] = %s;" held idx worked) ],
        scope,
        st )
  | SSetIndex (info, owner, index, value, _) ->
      (* owner[index] := value on c23-gc: the array and the index each
         into a temporary, the index checked, and only then the value
         worked out and written -- into the array the temporary holds,
         whatever the value did to the name it came from. *)
      let owner_t = type_of ctx scope owner in
      if Typesystem.array_element owner_t = None then unsupported info "an element write into what is not an array";
      let act, st = ctype ctx st info owner_t in
      let ov, st = expr ctx st scope owner in
      let opre, st = flush st in
      let held, st = temp st "arr" in
      let iv, st = expr ctx st scope index in
      let ipre, st = flush st in
      let idx, st = temp st "idx" in
      let vv, st = expr ctx st scope value in
      if vv.local_env then unsupported info (escaping "an array");
      let vpre, st = flush st in
      let st = need_helper st "pyk_check_index" check_index_helper in
      ( opre
        @ [ CDecl (act, held, Some ov.text) ]
        @ ipre
        @ [ CDecl ("int", idx, Some iv.text); CLine (Printf.sprintf "pyk_check_index(%s, %s.len);" idx held) ]
        @ vpre
        @ [ CLine (Printf.sprintf "%s.items[%s] = %s;" held idx vv.text) ],
        scope,
        st )
  | SMutate (info, name, e, _) ->
      let v, st = expr ctx st scope e in
      let pre, st = flush st in
      let b = lookup scope info name in
      let place = match b.kind with BCell -> "*" ^ b.value.text | _ -> b.value.text in
      (pre @ [ CLine (Printf.sprintf "%s = %s;" place v.text) ], scope, st)
  | SReturn (_, e, _) ->
      let t = type_of ctx scope e in
      if is_unit t && is_void st then
        let s, st = effect_of ctx st scope e in
        (s @ [ CReturn None ], scope, st)
      else
        let v, st = expr ctx st scope e in
        let pre, st = flush st in
        let r, st = finished ctx st scope `Return t v in
        (pre @ r, scope, st)
  | SReturnStmt (_, inner, _) ->
      let fin = if is_void st then `Void else `Return in
      let body, st = tail ctx st scope fin inner in
      ((if fin = `Void then body @ [ CReturn None ] else body), scope, st)
  | SExprStmt (_, e, _) ->
      let s, st = effect_of ctx st scope e in
      (s, scope, st)
  | SLoop _ ->
      let loop_stmts, _, _, st = loop ctx st scope s in
      (loop_stmts, scope, st)
  | SBreak (_, value, _) ->
      (* The loop is worth what its slots hold, so a value written is put
         there first. *)
      let given, st = jump_value ctx st scope value in
      (given @ [ CBreak ], scope, st)
  | SContinue (_, value, _) ->
      (* The next turn starts from those same slots. *)
      let given, st = jump_value ctx st scope value in
      (given @ [ CContinue ], scope, st)
  | SIf (_, c, then_body, else_body, _) ->
      let cond, st = expr ctx st scope c in
      let pre, st = flush st in
      let t_stmts, _, st = stmts ctx st scope then_body in
      let e_stmts, st =
        match else_body with
        | None -> (None, st)
        | Some b ->
            let e_stmts, _, st = stmts ctx st scope b in
            (Some e_stmts, st)
      in
      (pre @ [ CIf (cond.text, t_stmts, e_stmts) ], scope, st)
  | SMatch (_, subject, cases, _) ->
      let out, st = match_stmt ctx st scope subject cases `Discard in
      (out, scope, st)
  | SFunctionDef _ ->
      let st = lift ctx st scope s in
      ([], scope, st)
  | SFunctionSig _ | SImport _ | SDatatype _ | SClass _ -> ([], scope, st)

(** Whether e calls something that can change a value while it is worked
    out (`changes`): a builtin that only reads (`len`, `same`, ...) and a
    def that only computes cannot. ctx -> scope -> expr -> bool *)
and has_call ctx scope e =
  let defs, changing, unknown = ctx.changing in
  let rec go node =
    match node with
    | Walk.NExpr (ELambda _) -> false
    | Walk.NExpr (ECall (_, EVar (_, name, _), _, _) as c) -> (
        let args = List.exists go (List.tl (Walk.children (Walk.NExpr c))) in
        args
        ||
        match SMap.find_opt name scope.names with
        | Some { kind = BFn { host = false; _ }; _ } when StringSet.mem name defs -> StringSet.mem name changing
        | Some { kind = BFn _; _ } -> true
        | Some _ -> unknown
        | None -> if List.mem name Builtin.names then List.mem name Builtin.writers else StringSet.mem name changing || unknown)
    | Walk.NExpr (ECall (_, EQualified _, _, _)) -> true
    | Walk.NExpr (ECall _) -> unknown
    | node -> List.exists go (Walk.children node)
  in
  go (Walk.NExpr e)

(** Whether the function being written answers nothing. state -> bool *)
and is_void st = StringSet.mem "pyk$void" st.taken

(** Whether a value of type t is a list whose element type nothing
    settles: one that is `[]` wherever it is read, at whatever type.
    typ -> bool *)
and empty_list t = match t with TList (_, e, _) -> type_vars e <> [] | _ -> false

(** A name bound to such a list: NULL, which is `[]` at every list
    type, the value it was given still worked out where it can do
    anything. scope -> string -> cexpr -> typ -> ([cstmt], scope) *)
and empty_binding scope name (v : cexpr) t =
  ( (if v.text = "NULL" then [] else [ CLine (Printf.sprintf "(void)(%s);" v.text) ]),
    bind_value scope name { value = atom "NULL"; kind = BLocal; btype = t; cname_ = "" } )

(** The type an assignment target binds. ctx -> scope -> assign_target
    -> typ *)
and target_type ctx scope target =
  match target with
  | TargetName (i, _, sym) -> (
      match IntMap.find_opt sym ctx.tmap with Some t -> substitute ctx.sigma t | None -> TUnknown (i, 0))
  | TargetTuple (i, ts, _) -> TTuple (i, List.map (target_type ctx scope) ts, 0)

(** A target bound to v, a value of type t. ctx -> state -> scope ->
    assign_target -> cexpr -> typ -> ([cstmt], scope, state) *)
and destructure ctx st scope target (v : cexpr) t =
  match target with
  | TargetName (_, name, _) when ctx.gc && empty_list t ->
      let worked, scope = empty_binding scope name v t in
      (worked, scope, st)
  | TargetName (_, name, _) ->
      let ct, st = ctype ctx st no_info t in
      let cname, st = fresh st name in
      ( [ CDecl (ct, cname, Some v.text) ],
        bind_value scope name { value = atom ~local_env:v.local_env cname; kind = BLocal; btype = t; cname_ = cname },
        st )
  | TargetTuple (_, targets, _) ->
      let ct, st = ctype ctx st no_info t in
      let held, st = temp st "t" in
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> TUnknown (no_info, 0)) targets in
      List.fold_left
        (fun (out, scope, st) (i, (target, ty)) ->
          let s, scope, st = destructure ctx st scope target (atom (Printf.sprintf "%s.a%d" held i)) ty in
          (out @ s, scope, st))
        ([ CDecl (ct, held, Some v.text) ], scope, st)
        (List.mapi (fun i x -> (i, x)) (List.combine targets types))

(** The pattern's bindings as locals. ctx -> state -> scope -> [(string,
    cexpr, typ)] -> ([cstmt], scope, state) *)
and bind_all ctx st scope binds =
  List.fold_left
    (fun (out, scope, st) (name, v, t) ->
      let ct, st = ctype ctx st no_info t in
      let cname, st = fresh st name in
      (out @ [ CDecl (ct, cname, Some v.text) ], bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname }, st))
    ([], scope, st) binds

(** A `match` as an if/else chain over the subject, held in a name of its
    own; where a case has a guard, a chain of ifs that a matched case
    leaves by `goto`. ctx -> state -> scope -> expr -> [match_case] ->
    finish -> ([cstmt], state) *)
and match_stmt ctx st scope subject cases fin =
  let v, st = expr ctx st scope subject in
  let pre, st = flush st in
  let t = type_of ctx scope subject in
  let ct, st = ctype ctx st no_info t in
  let held, st = temp st "s" in
  let hold = CDecl (ct, held, Some v.text) in
  let s = atom held in
  let count = List.length cases in
  let guarded = List.exists (fun c -> case_guard c <> None) cases in
  let arm st (MatchCase (_, p, guard, body, _)) =
    let conds, binds, st = pattern ctx st p s t in
    let decls, inner, st = bind_all ctx st scope binds in
    let body, st = tail_block ctx st inner fin body in
    (conds, decls, guard, inner, body, st)
  in
  if not guarded then
    let arms, st =
      List.fold_left
        (fun (out, st) c ->
          let conds, decls, _, _, body, st = arm st c in
          (out @ [ (conds, [ CBlock (decls @ body) ]) ], st))
        ([], st) cases
    in
    let chain =
      List.fold_right
        (fun (i, (conds, body)) chain ->
          match (i = count - 1, chain) with
          | true, _ -> Some body
          | false, None -> Some [ CIf ((conjunction conds).text, body, None) ]
          | false, Some rest -> Some [ CIf ((conjunction conds).text, body, Some rest) ])
        (List.mapi (fun i a -> (i, a)) arms)
        None
    in
    (pre @ (hold :: Option.value chain ~default:[]), st)
  else
    let label, st = temp st "matched" in
    let arms, st =
      List.fold_left
        (fun (out, st) (i, c) ->
          let conds, decls, guard, inner, body, st = arm st c in
          let leave = body @ [ CGoto label ] in
          let guarded, st =
            match guard with
            | None -> (decls @ leave, st)
            | Some g ->
                let gv, st = expr ctx st inner g in
                let gpre, st = flush st in
                (decls @ gpre @ [ CIf (gv.text, leave, None) ], st)
          in
          let one =
            if i = count - 1 && guard = None then CBlock guarded
            else CIf ((conjunction conds).text, [ CBlock guarded ], None)
          in
          (out @ [ one ], st))
        ([], st)
        (List.mapi (fun i c -> (i, c)) cases)
    in
    (pre @ (hold :: arms) @ [ CLabel label ], st)

(** A loop: its statements, the expression holding its value afterwards
    and that value's type. ctx -> state -> scope -> stmt -> ([cstmt],
    cexpr?, typ, state) *)
and loop ctx st scope s =
  match s with
  | SLoop (info, target, init, _, iterate, body, _) ->
      let slot_names = match target with Some t -> target_names t | None -> [] in
      let acc_t =
        match (target, init) with
        | Some target, Some init -> (
            match type_of ctx scope init with TUnknown _ -> target_type ctx scope target | t -> t)
        | _ -> TTuple (info, [], 0)
      in
      let slot_types =
        match (slot_names, acc_t) with
        | [ _ ], t -> [ t ]
        | names, TTuple (_, ts, _) when List.length ts = List.length names -> ts
        | names, _ -> List.map (fun _ -> TUnknown (info, 0)) names
      in
      let init_values, st =
        match (init, slot_names) with
        | Some (ETuple (_, es, _)), names when List.length es = List.length names && List.length names > 1 ->
            let vs, steps, st = in_order ctx st scope es in
            (List.mapi (fun i v -> if i = 0 then sequenced steps v else v) vs, st)
        | Some e, [ _ ] ->
            let v, st = expr ctx st scope e in
            ([ v ], st)
        | Some e, names ->
            let v, st = expr ctx st scope e in
            let ct, st = ctype ctx st info acc_t in
            let held, st = fresh_temp st ct in
            (List.mapi (fun i _ -> if i = 0 then atom (Printf.sprintf "(%s = %s, %s.a0)" held v.text held) else atom (Printf.sprintf "%s.a%d" held i)) names, st)
        | None, _ -> ([], st)
      in
      let pre, st = flush st in
      let slots, setup, inner, st =
        List.fold_left
          (fun (slots, setup, inner, st) ((name, ty), v) ->
            let ct, st = ctype ctx st info ty in
            let cname, st = fresh st name in
            ( slots @ [ (cname, ty) ],
              setup @ [ CDecl (ct, cname, Some v.text) ],
              bind_value inner name { value = atom cname; kind = BLocal; btype = ty; cname_ = cname },
              st ))
          ([], [], { scope with loops = scope.loops }, st)
          (List.combine (List.combine slot_names slot_types) init_values)
      in
      let inner = { inner with loops = scope.loops @ [ slots ] } in
      let value =
        match slots with
        | [] -> None
        | [ (cname, _) ] -> Some (atom cname)
        | slots -> Some (atom (Printf.sprintf "pyk_mk_%s(%s)" (code ctx.own info acc_t) (String.concat ", " (List.map fst slots))))
      in
      let fin = `Turn slots in
      (match iterate with
      | Some (ForIn (iter_info, element, ECall (_, EVar (_, "range", _), args, _), _)) when not (SMap.mem "range" scope.names) ->
          (* A count, which is all `for x in range(...)` asks of its list. *)
          let bounds, steps, st = in_order ctx st scope (arg_exprs args) in
          let start, stop, step =
            match bounds with
            | [ stop ] -> (atom "0", stop, atom "1")
            | [ start; stop ] -> (start, stop, atom "1")
            | [ start; stop; step ] -> (start, stop, step)
            | _ -> unsupported iter_info "`range` takes one, two or three arguments"
          in
          let cname, st = fresh st element in
          let stop_name, st = fresh st (element ^ "_stop") in
          let step_name, st = fresh st (element ^ "_step") in
          let inner = bind_value inner element { value = atom cname; kind = BLocal; btype = TInt (iter_info, 0); cname_ = cname } in
          let body_stmts, st = tail_block ctx st inner fin body in
          let header =
            Printf.sprintf "%s = %s; %s > 0 ? %s < %s : %s > %s; %s += %s" cname
              (sequenced steps start).text step_name cname stop_name cname stop_name cname step_name
          in
          ( pre @ setup
            @ [ CDecl ("int", stop_name, Some stop.text); CDecl ("int", step_name, Some step.text); CDecl ("int", cname, None);
                CFor (header, body_stmts) ],
            value, acc_t, st )
      | Some (ForIn (iter_info, element, sequence, _))
        when (match type_of ctx scope sequence with TString _ -> true | _ -> false) ->
          (* A String's Chars, decoded from its UTF-8 bytes as the loop
             walks them: no list, so no heap. *)
          let v, st = expr ctx st scope sequence in
          let spre, st = flush st in
          let cname, st = fresh st element in
          let pos_name, st = fresh st (element ^ "_at") in
          let st = need_char st "pyk_utf8_step" in
          let inner = bind_value inner element { value = atom cname; kind = BLocal; btype = TChar (iter_info, 0); cname_ = cname } in
          let body_stmts, st = tail_block ctx st inner fin body in
          let header = Printf.sprintf "%s = %s; (%s = pyk_utf8_step(%s, &%s)) != NULL; " pos_name (at p_assign v) pos_name pos_name cname in
          ( pre @ setup
            @ [ CDecl ("const char *", pos_name, None); CDecl ("int", cname, None) ]
            @ spre @ [ CFor (header, body_stmts) ],
            value, acc_t, st )
      | Some (ForIn (iter_info, element, sequence, _))
        when (let t = type_of ctx scope sequence in store_element t <> None || mutmap_parts t <> None) ->
          (* An array's elements by index, each read as its turn is
             reached, so a write ahead of the loop is seen; a DynArray's and a
             view's while the index is below the length at that turn; a
             MutMap's keys, which on c23-gc no key may come or go under. *)
          let at = type_of ctx scope sequence in
          let v, st = expr ctx st scope sequence in
          let spre, st = flush st in
          let act, st = ctype ctx st iter_info at in
          let held, st = fresh st (element ^ (if mutmap_parts at <> None then "_mutmap" else "_array")) in
          let idx, st = fresh st (element ^ "_at") in
          let version, st = if mutmap_parts at <> None then fresh st (element ^ "_version") else ("", st) in
          let elem, decls, test, item, st = walk_of ctx st at held idx version in
          let ect, st = ctype ctx st iter_info elem in
          let cname, st = fresh st element in
          let inner = bind_value inner element { value = atom cname; kind = BLocal; btype = elem; cname_ = cname } in
          let body_stmts, st = tail_block ctx st inner fin body in
          let header = Printf.sprintf "%s = 0; %s; %s++" idx test idx in
          ( pre @ setup @ spre
            @ [ CDecl (act, held, Some v.text) ] @ decls @ [ CDecl ("int", idx, None); CDecl (ect, cname, None);
                CFor (header, CLine (Printf.sprintf "%s = %s;" cname item) :: body_stmts) ],
            value, acc_t, st )
      | Some (ForIn (iter_info, element, sequence, _))
        when ctx.gc && (match type_of ctx scope sequence with TList _ -> true | _ -> false) ->
          (* A list's cells in turn: `x_at` the cell, `x` its element. *)
          let lt = type_of ctx scope sequence in
          let elem = match lt with TList (_, e, _) -> list_element e | t -> t in
          let v, st = expr ctx st scope sequence in
          let spre, st = flush st in
          let lct, st = ctype ctx st iter_info lt in
          let ect, st = ctype ctx st iter_info elem in
          let cell, st = fresh st (element ^ "_at") in
          let cname, st = fresh st element in
          let inner = bind_value inner element { value = atom cname; kind = BLocal; btype = elem; cname_ = cname } in
          let body_stmts, st = tail_block ctx st inner fin body in
          let header = Printf.sprintf "%s = %s; %s != NULL; %s = %s->tail" cell (at p_assign v) cell cell cell in
          ( pre @ setup @ spre
            @ [ CDecl (lct, cell, None); CDecl (ect, cname, None);
                CFor (header, CLine (Printf.sprintf "%s = %s->head;" cname cell) :: body_stmts) ],
            value, acc_t, st )
      | Some (ForIn (iter_info, _, _, _)) -> unsupported iter_info ("a `for` loop over " ^ heap_reason)
      | Some (WhileTest (_, condition, _)) ->
          let c, st = expr ctx st inner condition in
          let cpre, st = flush st in
          let body_stmts, st = tail_block ctx st inner fin body in
          if cpre = [] then (pre @ setup @ [ CWhile (c.text, body_stmts) ], value, acc_t, st)
          else (pre @ setup @ [ CWhile ("1", cpre @ [ CIf ("!(" ^ c.text ^ ")", [ CBreak ], None) ] @ body_stmts) ], value, acc_t, st)
      | None ->
          let body_stmts, st = tail_block ctx st inner fin body in
          (pre @ setup @ [ CWhile ("1", body_stmts) ], value, acc_t, st))
  | _ -> ([], None, TTuple (no_info, [], 0), st)

and target_names target =
  match target with TargetName (_, n, _) -> [ n ] | TargetTuple (_, ts, _) -> List.concat_map target_names ts

(** Every def of a block bound before any statement of it is translated:
    a def is visible throughout its block. ctx -> state -> scope ->
    [stmt] -> (scope, state) *)
and declare_defs ctx st scope statements =
  List.fold_left
    (fun (scope, st) s ->
      match s with
      | SFunctionDef (_, name, _, _, _, sym, _, _, _) ->
          let t = Option.value (IntMap.find_opt sym ctx.tmap) ~default:(TUnknown (no_info, 0)) in
          let vars, _, r = function_parts t in
          let cname, st = fresh st (scope.family ^ "_" ^ name) in
          ( bind_value scope name
              {
                value = atom cname;
                kind = BFn { cname; generic = vars <> []; lifted = true; void = is_unit r; ftype = t; host = false };
                btype = t;
                cname_ = cname;
              },
            st )
      | _ -> (scope, st))
    (scope, st) statements

(** A nested def as a function of its own, taking what it captures first:
    compiled here, or -- for a polymorphic one -- once per instance a call
    asks for. ctx -> state -> scope -> stmt -> state *)
and lift ctx st scope s =
  match s with
  | SFunctionDef (_, name, _, _, _, _, _, _, _) -> (
      match SMap.find_opt name scope.names with
      | Some { kind = BFn _; _ } when unreferenced s scope.block -> st
      | Some { kind = BFn f; _ } when f.generic ->
          {
            st with
            templates =
              st.templates @ [ (f.cname, { t_def = s; t_scope = scope; t_sigma = ctx.sigma; t_lifted = true; t_public = false }) ];
          }
      | Some { kind = BFn f; _ } -> lift_with ctx st scope s f.cname f.ftype
      | _ -> st)
  | _ -> st

(** A nested def or a lambda compiled as the function name.
    ctx -> state -> scope -> stmt -> string -> typ -> state *)
and lift_with ctx st scope s name t =
  match s with
  | SFunctionDef (_, _, params, body, _, _, _, _, _) ->
      let free = mentioned body in
      let direct, reaches, st =
        StringSet.fold
          (fun n (direct, reaches, st) ->
            match SMap.find_opt n scope.names with
            | Some { kind = BCell; cname_; btype; _ } when cname_ <> "" ->
                let ct, st = ctype ctx st no_info btype in
                (direct @ [ (cname_, ct ^ (if ct.[String.length ct - 1] = '*' then "*" else " *")) ], reaches, st)
            | Some { kind = BLocal; cname_; btype; value; _ } when cname_ <> "" && cname_ = value.text && not (is_static st cname_) ->
                let ct, st = ctype ctx st no_info btype in
                (direct @ [ (cname_, ct) ], reaches, st)
            | Some { kind = BFn { lifted = true; cname; _ }; _ } when cname <> name -> (direct, reaches @ [ cname ], st)
            | _ -> (direct, reaches, st))
          free ([], [], st)
      in
      let st = { st with captures = st.captures @ [ (name, { direct; reaches; inside = scope.family }) ] } in
      let inner = { scope with loops = []; family = name; cells = StringSet.union scope.cells (cells_of ctx.gc body) } in
      let f, st = function_of ctx st inner name params body t false true in
      { st with funcs = st.funcs @ [ f ] }
  | _ -> st

and is_static st name = StringSet.mem ("static$" ^ name) st.taken

(** One function: its parameters bound, its body finished by returning,
    its evaluation-order temporaries declared at its top.
    ctx -> state -> scope -> string -> [param] -> [stmt] -> typ -> bool
    -> bool -> (cfunc, state) *)
and function_of ctx st scope cname params body t public lifted =
  let _, ps, r = function_parts (substitute ctx.sigma t) in
  let ps = if List.length ps = List.length params then ps else List.map (fun _ -> TUnknown (no_info, 0)) params in
  let saved_temps = st.temps and saved_pre = st.pre in
  let saved_void = StringSet.mem "pyk$void" st.taken in
  let st = { st with temps = []; pre = [] } in
  let void = is_unit r in
  let st = if void then { st with taken = StringSet.add "pyk$void" st.taken } else { st with taken = StringSet.remove "pyk$void" st.taken } in
  let scope = { scope with cells = StringSet.union scope.cells (cells_of ctx.gc body) } in
  if not ctx.gc then check_local_addresses body;
  let cparams, scope, st =
    List.fold_left2
      (fun (out, scope, st) (Param (_, n, _, _, _)) pt ->
        let ct, st = ctype ctx st no_info pt in
        let pname, st = fresh st n in
        (out @ [ (ct, pname) ], bind_value scope n { value = atom pname; kind = BLocal; btype = pt; cname_ = pname }, st))
      ([], scope, st) params ps
  in
  let fin = if void then `Void else `Return in
  let body_stmts, st = tail_block ctx st scope fin body in
  let rt, st = if void then ("void", st) else ctype ctx st no_info r in
  let temps = List.map (fun (ct, n) -> CDecl (ct, n, None)) st.temps in
  let taken = StringSet.remove "pyk$void" st.taken in
  let st = { st with temps = saved_temps; pre = saved_pre; taken = (if saved_void then StringSet.add "pyk$void" taken else taken) } in
  ( { f_name = cname; f_public = public; f_result = rt; f_params = List.map (fun (ct, n) -> (ct, n)) cparams; f_captures = lifted; f_body = temps @ body_stmts },
    st )

(* --- a module --- *)

type cprogram = {
  program_name : string;
  main : bool;
  separate : bool;
  starts : string list;
  includes : string list;
  externs : string list; (* declarations of what the host implements *)
  statics : (bool * string * string) list; (* public, type, name *)
  funcs : cfunc list;
  main_body : cstmt list;
  types : (string * string) list;
  helpers : (string * string) list;
  helper_protos_ : string list; (* helpers called before they are written *)
  hands_argv : bool; (* c23-gc's main hands `sys` the program's argv *)
  wrappers : (string * string) list;
  capture_table : (string * capture) list;
  includes_math : bool;
  uses_bool : bool;
  public_types : string list;
  requests_ : (string * (string * typ) list) list;
  protos_ : string list;
}

(** The C type a declared host type is carried as at the boundary, where
    a function is a plain pointer: `pyk_fn_ii_v` for `(Int, Int) -> ()`.
    ctx -> info -> typ -> string *)
let rec host_type ctx info t =
  match t with
  | TInt _ | TChar _ -> "int"
  | TFloat _ -> "double"
  | TBool _ -> bool_type ctx
  | TString _ -> "const char *"
  | TTuple (_, [], _) -> "void"
  | TFunction (_, ps, r, _, _, _, _) ->
      ignore (List.map (host_type ctx info) (r :: ps));
      host_callback_type ctx t
  (* A tuple of what crosses crosses too, as the struct this backend
     writes it as: a C implementation declares the same one. *)
  | TTuple (_, es, _) when List.for_all (fun e -> match e with TInt _ | TChar _ | TFloat _ | TBool _ | TString _ -> true | _ -> false) es ->
      "pyk_t_" ^ code ctx.own info t
  (* On c23-gc a list of what crosses crosses too, as its first cell: the
     implementation builds the cells, declared as the program declares
     them, from the collector. *)
  | TList (_, e, _) when ctx.gc ->
      ignore (host_type ctx info e);
      "pyk_l_" ^ code ctx.own info t ^ " *"
  | _ ->
      unsupported info
        (Printf.sprintf "a type this target has no C type for at the host's boundary: %s" (pprint_type default_config t))

(** The typedef a host callback type is written through, guarded so a
    header and the file including it may both carry it.
    ctx -> typ -> string *)
let host_typedef ctx t =
  match t with
  | TFunction (_, ps, r, _, _, _, _) ->
      let name = host_type ctx no_info t in
      let guard = String.uppercase_ascii name in
      Printf.sprintf "#ifndef %s\n#define %s\ntypedef %s (*%s)(%s);\n#endif" guard guard (host_type ctx no_info r) name
        (match ps with [] -> "void" | ps -> String.concat ", " (List.map (host_type ctx no_info) ps))
  | _ -> ""

(** One declaration of a name the host implements -- none where C has no
    type for it: nothing the program reaches calls it, or the call is
    refused where it is translated. ctx -> info -> string -> typ -> [string] *)
let rec host_declaration ctx info cname t =
  try host_declaration_of ctx info cname t with Unsupported _ -> []

and host_declaration_of ctx info cname t =
  match t with
  | TFunction (_, ps, r, _, _, _, _) ->
      let typedefs = List.filter_map (fun p -> match p with TFunction _ -> Some (host_typedef ctx p) | _ -> None) ps in
      typedefs
      @ [
          Printf.sprintf "%s(%s);" (declaration (host_type ctx info r) cname)
            (match ps with [] -> "void" | ps -> String.concat ", " (List.map (host_type ctx info) ps));
        ]
  | t -> [ Printf.sprintf "extern %s;" (declaration (host_type ctx info t) cname) ]

(** What each lifted function captures, its own and those of every
    lifted function it reaches but did not write. [(string, capture)] ->
    string -> [(string, string)] *)
let closure table name =
  let rec go seen name =
    if List.mem name seen then []
    else
      match List.assoc_opt name table with
      | None -> []
      | Some c ->
          c.direct
          @ List.concat_map
              (fun r -> match List.assoc_opt r table with Some rc when rc.inside = name -> [] | _ -> go (name :: seen) r)
              c.reaches
  in
  List.sort_uniq (fun (a, _) (b, _) -> compare a b) (go [] name)

(** text with every capture marker replaced. [(string, capture)] ->
    string -> string *)
let expand_captures ~gc table text =
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let rec go i =
    if i >= n then ()
    else if text.[i] = '\001' then (
      let j = String.index_from text (i + 1) '\001' in
      let fields = String.split_on_char ':' (String.sub text (i + 1) (j - i - 1)) in
      (match fields with
      | [ kind; name; extra ] ->
          let names = closure table name in
          let more = extra = "1" in
          let joined pieces =
            Buffer.add_string b (String.concat ", " pieces);
            if pieces <> [] && more then Buffer.add_string b ", "
          in
          (match kind with
          | "A" -> joined (List.map fst names)
          | "P" -> joined (List.map (fun (n, t) -> declaration t n) names)
          | "U" -> joined (List.map (fun (n, _) -> "e->" ^ n) names)
          | "E" -> Buffer.add_string b (String.concat "\n" (List.map (fun (n, t) -> "    " ^ declaration t n ^ ";") names))
          | "S" -> Buffer.add_string b (String.concat " " (List.map (fun (n, _) -> Printf.sprintf "%s.%s = %s;" extra n n) names))
          | "C" -> Buffer.add_string b (String.concat "" (List.map (fun (n, _) -> Printf.sprintf "%s->%s = %s, " extra n n) names))
          | "M" ->
              (* An allocator (alloc_atomic and the others): bdwgc's on
                 c23-gc, malloc's on plain C. *)
              Buffer.add_string b
                (match (name, gc) with
                | "atomic", true -> "GC_MALLOC_ATOMIC"
                | "scanned", true -> "GC_MALLOC"
                | "resize", true -> "GC_REALLOC"
                | "resize", false -> "realloc"
                | _ -> "malloc")
          | _ -> ())
      | _ -> ());
      go (j + 1))
    else (
      Buffer.add_char b text.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(** A top-level binding: a file-scope variable per name, assigned where
    the binding is. ctx -> state -> scope -> statics -> assign_target ->
    cexpr -> typ -> bool -> ([cstmt], statics, scope, state) *)
let rec static_bindings ctx st scope statics target (v : cexpr) t public =
  if v.local_env then unsupported no_info (escaping "a top-level binding");
  let t = match t with TForall (_, _, body, _) -> body | t -> t in
  match target with
  | TargetName (_, name, _) when ctx.gc && empty_list t && not (public && not ctx.context.main) ->
      let worked, scope = empty_binding scope name v t in
      (worked, statics, scope, st)
  | TargetName (i, name, _) ->
      if type_vars t <> [] then
        unsupported i "a top-level value whose type has variables, which C cannot make concrete";
      let ct, st = ctype ctx st no_info t in
      let cname, st =
        if public && not ctx.context.main then (module_name ctx.own name, st) else fresh st name
      in
      let st = { st with taken = StringSet.add ("static$" ^ cname) (StringSet.add cname st.taken) } in
      ( [ CLine (Printf.sprintf "%s = %s;" cname v.text) ],
        statics @ [ (public && not ctx.context.main, ct, cname) ],
        bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname },
        st )
  | TargetTuple (_, targets, _) ->
      let ct, st = ctype ctx st no_info t in
      let held, st = temp st "t" in
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> TUnknown (no_info, 0)) targets in
      List.fold_left
        (fun (out, statics, scope, st) (i, (target, ty)) ->
          let s, statics, scope, st = static_bindings ctx st scope statics target (atom (Printf.sprintf "%s.a%d" held i)) ty public in
          (out @ s, statics, scope, st))
        ([ CDecl (ct, held, Some v.text) ], statics, scope, st)
        (List.mapi (fun i x -> (i, x)) (List.combine targets types))

(** A class or interface in C: the struct of its objects -- the class
    descriptor's pointer, then every field, its parents' first -- each
    method body a function taking the object first, and for a class the
    function setting up its fields (the parent's part first) and the one
    building an object; then, as a wrapper written after every function
    is declared, its table of methods (one slot per method name the
    module has), the interfaces it is, what it prints as and its
    descriptor (docs/target_c.md, "Classes").
    ctx -> state -> scope -> info -> class_decl -> ([cfunc], state) *)
let class_functions ctx st scope info c =
  let table = ctx.classes in
  let k = Option.get (Classes.find table c.c_name) in
  if c.c_params <> [] then
    unsupported info
      (Printf.sprintf "the generic class '%s', which C would need one struct and table of per type it is made at" c.c_name);
  let st = need_objects st in
  let type_at sym = Option.value (IntMap.find_opt sym ctx.tmap) ~default:(TUnknown (info, 0)) in
  let self_t = TCon (info, c.c_name, [], 0) in
  let sym name = class_symbol ctx name c.c_name in
  let interface = c.c_kind = ClassInterface in
  (* the struct *)
  let fields = Classes.all_fields table c.c_name in
  let st =
    if interface then st
    else
      let members, st =
        List.fold_left
          (fun (out, st) f ->
            let ct, st = ctype ctx st info (type_at f.Classes.f_sym) in
            (out @ [ "    " ^ declaration ct (c_ident f.Classes.f_name) ^ ";" ], st))
          ([], st) fields
      in
      let name = sym "o" in
      {
        st with
        types =
          st.types
          @ [ (name, Printf.sprintf "typedef struct %s {\n    const pyk_class *cls;\n%s\n} %s;" name (String.concat "\n" members) name) ];
      }
  in
  (* each method body *)
  let methods, st =
    List.fold_left
      (fun (out, st) (MethodDecl (mi, name, params, _, body, _, _, ms)) ->
        match body with
        | None -> (out, st)
        | Some body ->
            let ps, r = match type_at ms with TFunction (_, ps, r, _, _, _, _) -> (ps, r) | _ -> ([], TTuple (mi, [], 0)) in
            let t = TFunction (mi, self_t :: ps, r, 0, 0, None, []) in
            let fn, st =
              function_of ctx st { scope with family = sym ("m_" ^ name) } (sym ("m_" ^ name))
                (Param (mi, "self", None, None, 0) :: List.map (fun (Param (pi, pn, pt, _, psym)) -> Param (pi, pn, pt, None, psym)) params)
                body t false false
            in
            (out @ [ fn ], st))
      ([], st) c.c_methods
  in
  if interface then
    let ifaces = List.map (fun (n, _) -> "&" ^ class_symbol ctx "class" n) k.Classes.interfaces in
    let text =
      String.concat "\n"
        [
          Printf.sprintf "static const pyk_class *const %s[] = { %s };" (sym "if") (String.concat ", " (ifaces @ [ "NULL" ]));
          Printf.sprintf "const pyk_class %s = { %s, NULL, %s, NULL, NULL };" (sym "class") (quote c.c_name) (sym "if");
        ]
    in
    let ahead =
      String.concat "\n"
        (List.map (fun n -> Printf.sprintf "extern const pyk_class %s;" (class_symbol ctx "class" n)) (List.map fst (Classes.SMap.bindings table)))
    in
    let wrappers = if List.mem_assoc "pyk_classes_ahead" st.wrappers then st.wrappers else ("pyk_classes_ahead", ahead) :: st.wrappers in
    (methods, { st with wrappers = wrappers @ [ (sym "class", text) ] })
  else
    (* setting up the fields, the parent's first *)
    let header_ct, st =
      List.fold_left
        (fun (out, st) (n, hs) ->
          let ct, st = ctype ctx st info (type_at hs) in
          (out @ [ (n, ct, type_at hs) ], st))
        ([], st) k.Classes.header
    in
    let saved_temps = st.temps and saved_pre = st.pre in
    let st = { st with temps = []; pre = [] } in
    let cparams, iscope, st =
      List.fold_left
        (fun (out, iscope, st) (n, ct, t) ->
          let cn, st = fresh st n in
          (out @ [ (ct, cn) ], bind_value iscope n { value = atom cn; kind = BLocal; btype = t; cname_ = cn }, st))
        ([], scope, st) header_ct
    in
    let self_name = "self" in
    let parent_lines, st =
      match k.Classes.parent with
      | None -> ([], st)
      | Some p ->
          let values, steps, st = in_order ctx st iscope (arg_exprs k.Classes.parent_args) in
          let pre, st = flush st in
          let call = sequenced steps (atom (Printf.sprintf "%s(%s)" (class_symbol ctx "init" p) (String.concat ", " (self_name :: List.map (fun v -> v.text) values)))) in
          (pre @ [ CLine (call.text ^ ";") ], st)
    in
    let own_lines =
      List.map
        (fun n ->
          let cn = (SMap.find n iscope.names).value.text in
          CLine (Printf.sprintf "%s = %s;" (object_field ctx c.c_name n self_name) cn))
        k.Classes.own_header
    in
    let body_lines, st =
      List.fold_left
        (fun (out, st) (MemberField (_, n, _, v, _, _, _)) ->
          match v with
          | None -> (out, st)
          | Some e ->
              let vv, st = expr ctx st iscope e in
              let pre, st = flush st in
              (out @ pre @ [ CLine (Printf.sprintf "%s = %s;" (object_field ctx c.c_name n self_name) vv.text) ], st))
        ([], st) c.c_fields
    in
    let temps = List.map (fun (ct, n) -> CDecl (ct, n, None)) st.temps in
    let st = { st with temps = saved_temps; pre = saved_pre } in
    let init =
      {
        f_name = sym "init";
        f_public = false;
        f_result = "void";
        f_params = ("pyk_obj *", self_name) :: cparams;
        f_captures = false;
        f_body = temps @ parent_lines @ own_lines @ body_lines;
      }
    in
    let made =
      if c.c_kind = ClassAbstract then []
      else
        [
          {
            f_name = sym "new";
            f_public = false;
            f_result = "pyk_obj *";
            f_params = cparams;
            f_captures = false;
            f_body =
              [
                CDecl (sym "o" ^ " *", "made", Some (Printf.sprintf "%s(sizeof *made)" (marker "M" "scanned" "")));
                CLine (Printf.sprintf "made->cls = &%s;" (sym "class"));
                CLine (Printf.sprintf "%s(%s);" (sym "init") (String.concat ", " ("(pyk_obj *) made" :: List.map snd cparams)));
                CReturn (Some "(pyk_obj *) made");
              ];
          };
        ]
    in
    (* the table, what it prints as, and the descriptor *)
    let slot_fn m =
      match Classes.resolve table c.c_name m with
      | Some owner when Classes.has_method table c.c_name m -> Printf.sprintf "(void (*)(void)) %s" (class_symbol ctx ("m_" ^ m) owner)
      | _ -> "NULL"
    in
    let slots = if ctx.slots = [] then [ "NULL" ] else List.map slot_fn ctx.slots in
    let ifaces = List.map (fun (n, _) -> "&" ^ class_symbol ctx "class" n) k.Classes.interfaces in
    let show_body, st =
      if Classes.resolve table c.c_name "show" <> None && Classes.has_method table c.c_name "show" then
        (Printf.sprintf "    return %s(o);" (class_symbol ctx "m_show" (Option.get (Classes.resolve table c.c_name "show"))), st)
      else
        match k.Classes.header with
        | [] -> (Printf.sprintf "    return %s;" (quote c.c_name), st)
        | header ->
            let st = need_concat st in
            let parts, st =
              List.fold_left
                (fun (out, st) (h, hs) ->
                  let show, st = shower ctx st info (type_at hs) in
                  (out @ [ show (object_field ctx c.c_name h "o") ], st))
                ([], st) header
            in
            let joined =
              List.fold_left
                (fun so_far part -> Printf.sprintf "pyk_concat(pyk_concat(%s, \", \"), %s)" so_far part)
                (List.hd parts) (List.tl parts)
            in
            (Printf.sprintf "    return pyk_concat(pyk_concat(%s, %s), \")\");" (quote (c.c_name ^ "(")) joined, st)
    in
    let text =
      String.concat "\n"
        [
          Printf.sprintf "static const char *%s(pyk_obj *o);" (sym "show");
          Printf.sprintf "static void (*const %s[])(void) = { %s };" (sym "vt") (String.concat ", " slots);
          Printf.sprintf "static const pyk_class *const %s[] = { %s };" (sym "if") (String.concat ", " (ifaces @ [ "NULL" ]));
          Printf.sprintf "const pyk_class %s = { %s, %s, %s, %s, %s };" (sym "class") (quote c.c_name)
            (match k.Classes.parent with Some p -> "&" ^ class_symbol ctx "class" p | None -> "NULL")
            (sym "if") (sym "vt") (sym "show");
          Printf.sprintf "static const char *%s(pyk_obj *o)\n{\n%s\n}" (sym "show") show_body;
        ]
    in
    (* every descriptor is declared ahead, so one may name another *)
    let ahead =
      String.concat "\n"
        (List.map (fun n -> Printf.sprintf "extern const pyk_class %s;" (class_symbol ctx "class" n)) (List.map fst (Classes.SMap.bindings table)))
    in
    let wrappers = if List.mem_assoc "pyk_classes_ahead" st.wrappers then st.wrappers else ("pyk_classes_ahead", ahead) :: st.wrappers in
    (methods @ (init :: made), { st with wrappers = wrappers @ [ (sym "class", text) ] })

(** One module of a program as a cprogram. [stmt] -> typ IntMap.t ->
    Module.context -> string -> cprogram *)
let translate_program ?(requested = []) stmts tmap (context : Module.context) target =
  Hashtbl.reset object_types;
  List.iter (function SClass (_, c, _) -> Hashtbl.replace object_types c.c_name () | _ -> ()) stmts;
  let standard, gc = standard_of target in
  let own = context.context_name in
  let own_datatypes =
    List.filter_map
      (function
        | SDatatype (_, _, _, _, sym, _, _) -> (match IntMap.find_opt sym tmap with Some (TData (_, d, _)) -> Some d | _ -> None)
        | _ -> None)
      stmts
  in
  let datatypes =
    List.fold_left
      (fun map (_, sigmap) ->
        List.fold_left
          (fun map (_, t, _) -> match t with TData (_, (Datatype (c, _, _, _) as d), _) -> SMap.add c d map | _ -> map)
          map sigmap)
      SMap.empty context.sigmaps
  in
  let datatypes = List.fold_left (fun map (Datatype (c, _, _, _) as d) -> SMap.add c d map) datatypes own_datatypes in
  let modules = List.filter_map (function SImport (_, m, alias, false, _, _) -> Some (alias, m) | _ -> None) stmts in
  let ctx =
    {
      tmap;
      standard;
      gc;
      context;
      own;
      datatypes;
      modules;
      printing = Analyses.effects stmts;
      changing = changes stmts;
      sigma = [];
      classes = Classes.table stmts;
      slots =
        (let table = Classes.table stmts in
         List.fold_left
           (fun names c -> List.fold_left (fun names m -> if List.mem m names then names else names @ [ m ]) names (Classes.method_names table c))
           [] (Classes.ordered table stmts));
    }
  in
  let st =
    {
      taken = StringSet.empty;
      counter = 0;
      temps = [];
      pre = [];
      funcs = [];
      captures = [];
      types = [];
      helpers = [];
      wrappers = [];
      templates = [];
      instances = StringSet.empty;
      pending = [];
      includes_math = false;
      uses_bool = false;
      building = StringSet.empty;
      helper_protos = [];
      requests = [];
      protos = [];
    }
  in
  let scope = { names = SMap.empty; loops = []; cells = StringSet.empty; block = stmts; family = "main" } in
  let public_names = List.map fst (Module.public_names stmts) in
  let c_of name = if (not context.main) && List.mem name public_names then module_name own name else c_ident name in
  (* What the host provides: this module's own declarations, and every
     name an import takes from a module's declaration half. *)
  let host_fn module_ field t =
    let vars, _, r = function_parts t in
    BFn { cname = module_name module_ field; generic = vars <> []; lifted = false; void = is_unit r; ftype = t; host = true }
  in
  let scope, externs =
    List.fold_left
      (fun (scope, externs) (field, t) ->
        let cname = module_name own field in
        match t with
        | TFunction _ | TForall (_, _, TFunction _, _) ->
            (bind_value scope field { value = atom cname; kind = host_fn own field t; btype = t; cname_ = "" }, externs @ host_declaration ctx no_info cname t)
        | t -> (bind_value scope field { value = atom cname; kind = BLocal; btype = t; cname_ = "" }, externs @ host_declaration ctx no_info cname t))
      (scope, []) context.own_declared
  in
  let scope, externs =
    List.fold_left
      (fun (scope, externs) s ->
        match s with
        | SImport (info, module_, _, selected, fields, _) ->
            let sigmap = Option.value (List.assoc_opt module_ context.sigmaps) ~default:[] in
            let declared = Option.value (List.assoc_opt module_ context.external_fields) ~default:[] in
            List.fold_left
              (fun (scope, externs) (exported, local) ->
                let cname = module_name module_ exported in
                let from_host = List.mem module_ context.externals || List.mem exported declared in
                let externs =
                  match List.find_map (fun (n, t, _) -> if n = exported then Some t else None) sigmap with
                  | Some t when from_host && not (List.exists (fun e -> e = cname) externs) ->
                      (match t with TData _ -> externs | t -> externs @ host_declaration ctx info cname t)
                  | _ -> externs
                in
                if not selected then (scope, externs)
                else
                  match List.find_map (fun (n, t, _) -> if n = exported then Some t else None) sigmap with
                  | Some ((TFunction _ | TForall (_, _, TFunction _, _)) as t) ->
                      let vars, _, r = function_parts t in
                      ( bind_value scope local
                          {
                            value = atom cname;
                            kind = BFn { cname; generic = vars <> []; lifted = false; void = is_unit r; ftype = t; host = from_host };
                            btype = t;
                            cname_ = "";
                          },
                        externs )
                  | Some (TData _) | None -> (scope, externs)
                  | Some t -> (bind_value scope local { value = atom cname; kind = BLocal; btype = t; cname_ = "" }, externs))
              (scope, externs) fields
        | _ -> (scope, externs))
      (scope, externs) stmts
  in
  (* A tuple crossing to the host is the struct the file declares for it. *)
  let st =
    let host_types =
      List.map snd context.own_declared
      @ List.concat_map
          (fun (m, sigmap) ->
            let declared = Option.value (List.assoc_opt m context.external_fields) ~default:[] in
            List.filter_map
              (fun (n, t, _) -> if List.mem m context.externals || List.mem n declared then Some t else None)
              sigmap)
          context.sigmaps
    in
    let rec tuples t =
      match t with
      | TTuple (_, (_ :: _ as es), _) -> [ t ] @ List.concat_map tuples es
      | TList (_, e, _) when gc -> tuples e @ [ t ]
      | TFunction (_, ps, r, _, _, _, _) -> List.concat_map tuples (r :: ps)
      | _ -> []
    in
    List.fold_left
      (fun st t -> try snd (ctype ctx st no_info t) with Unsupported _ -> st)
      st
      (List.concat_map tuples host_types)
  in
  (* Every top-level def is a function, bound before anything is
     translated; a polymorphic one is a template its calls instantiate. *)
  let scope, st =
    List.fold_left
      (fun (scope, st) s ->
        match s with
        | SFunctionDef (_, name, _, _, _, sym, _, _, _) ->
            let t = Option.value (IntMap.find_opt sym tmap) ~default:(TUnknown (no_info, 0)) in
            let vars, _, r = function_parts t in
            let cname = c_of name in
            ( bind_value scope name
                { value = atom cname; kind = BFn { cname; generic = vars <> []; lifted = false; void = is_unit r; ftype = t; host = false }; btype = t; cname_ = cname },
              { st with taken = StringSet.add cname st.taken } )
        | _ -> (scope, st))
      (scope, st) stmts
  in
  (* A top-level `var` is a static, which needs no cell; one declared in
     a block of the top level -- a loop's body, say -- is a local of
     main, a new one each time it is declared, and lives in a cell where
     a closure captures it or, on c23-gc, its address is taken. *)
  let scope =
    let rec block_vars stmts =
      List.concat_map
        (fun s ->
          match s with
          | SFunctionDef _ -> []
          | SVar (_, n, _, _) -> [ n ]
          | s -> List.concat_map nested (Walk.children (Walk.NStmt s)))
        stmts
    and nested node =
      match node with
      | Walk.NStmt s -> block_vars [ s ]
      | Walk.NExpr (ELambda _) -> []
      | node -> List.concat_map nested (Walk.children node)
    in
    let in_blocks =
      List.concat_map (fun s -> match s with SVar _ | SFunctionDef _ -> [] | s -> block_vars [ s ]) stmts
    in
    if not gc then
      check_local_addresses
        ~statics:(StringSet.of_list (List.filter_map (function SVar (_, n, _, _) -> Some n | _ -> None) stmts))
        stmts;
    { scope with cells = StringSet.inter (StringSet.of_list in_blocks) (cells_of gc stmts) }
  in
  let funcs, body, statics, scope, st =
    List.fold_left
      (fun (funcs, body, statics, scope, st) s ->
        match s with
        | SFunctionDef _ when unreferenced s stmts -> (funcs, body, statics, scope, st)
        | SFunctionDef (_, name, params, fbody, _, sym, public, _, _) -> (
            let t = Option.value (IntMap.find_opt sym tmap) ~default:(TUnknown (no_info, 0)) in
            match SMap.find_opt name scope.names with
            | Some { kind = BFn f; _ } when f.generic ->
                ( funcs,
                  body,
                  statics,
                  scope,
                  { st with templates = st.templates @ [ (f.cname, { t_def = s; t_scope = scope; t_sigma = []; t_lifted = false; t_public = public && not context.main }) ] } )
            | Some { kind = BFn f; _ } ->
                let fscope = { scope with family = f.cname } in
                let saved = st.taken in
                let fn, st = function_of ctx st fscope f.cname params fbody t (public && not context.main) false in
                (* A function's locals are its own: the next one may reuse
                   their names. What it made at file scope stays taken. *)
                let made =
                  List.fold_left (fun set f -> StringSet.add f.f_name set) StringSet.empty st.funcs
                  |> fun set -> List.fold_left (fun set (n, _) -> StringSet.add n set) set st.templates
                in
                (funcs @ [ fn ], body, statics, scope, { st with taken = StringSet.union saved made })
            | _ -> (funcs, body, statics, scope, st))
        | SImport _ | SFunctionSig _ | SDatatype _ -> (funcs, body, statics, scope, st)
        | SClass (info, c, _) ->
            let saved = st.taken in
            let made, st = class_functions ctx st scope info c in
            let made_names = List.fold_left (fun set f -> StringSet.add f.f_name set) StringSet.empty (st.funcs @ made) in
            (funcs @ made, body, statics, scope, { st with taken = StringSet.union saved made_names })
        | SLet (_, TargetName (_, name, _), (EVar (_, other, _) as e), _, _, false, _)
          when (match SMap.find_opt other scope.names with
               | Some { kind = BFn f; _ } -> f.generic && type_vars (type_of ctx scope e) <> []
               | _ -> false) ->
            (* Another name for a polymorphic function is that function:
               there is no one C function a value of it could hold. *)
            (funcs, body, statics, bind_value scope name (SMap.find other scope.names), st)
        | SLet (_, (TargetName (_, name, _) as target), (EListComp _ as e), _, _, public, _) when gc ->
            let t = type_of ctx scope e in
            let assigns, statics, scope, st = static_bindings ctx st scope statics target (atom "NULL") t public in
            let cname = (SMap.find name scope.names).value.text in
            let built, st = comprehension ctx st scope e cname in
            (funcs, body @ assigns @ built, statics, scope, st)
        | SLet (_, target, e, _, _, public, _) ->
            let v, st = expr ctx st scope e in
            let pre, st = flush st in
            let t = type_of ctx scope e in
            let assigns, statics, scope, st = static_bindings ctx st scope statics target v t public in
            (funcs, body @ pre @ assigns, statics, scope, st)
        | SVar (_, name, e, _) ->
            let v, st = expr ctx st scope e in
            let pre, st = flush st in
            let t = type_of ctx scope e in
            let ct, st = ctype ctx st no_info t in
            let cname, st = fresh st name in
            (* A top-level `var`: a call can write it. *)
            let st = { st with taken = StringSet.add ("var$" ^ cname) (StringSet.add ("static$" ^ cname) st.taken) } in
            ( funcs,
              body @ pre @ [ CLine (Printf.sprintf "%s = %s;" cname v.text) ],
              statics @ [ (false, ct, cname) ],
              bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname },
              st )
        | SLetStmt (_, target, inner, _, _, public) -> (
            let t = match IntMap.find_opt (stmt_sym s) tmap with Some t -> t | None -> target_type ctx scope target in
            match inner with
            | SLoop _ ->
                let loop_stmts, value, lt, st = loop ctx st scope inner in
                let t = match t with TUnknown _ -> lt | t -> t in
                let assigns, statics, scope, st = static_bindings ctx st scope statics target (Option.value value ~default:unit_value) t public in
                (funcs, body @ loop_stmts @ assigns, statics, scope, st)
            | _ ->
                let ct, st = ctype ctx st no_info t in
                let held, st = temp st "v" in
                let inner_stmts, st = tail ctx st scope (`Assign held) inner in
                let assigns, statics, scope, st = static_bindings ctx st scope statics target (atom held) t public in
                (funcs, body @ [ CDecl (ct, held, None) ] @ inner_stmts @ assigns, statics, scope, st))
        | s ->
            let out, scope, st = stmt ctx st scope s in
            (funcs, body @ out, statics, scope, st))
      ([], [], [], scope, st) stmts
  in
  (* The instances calls asked for, each compiled at its types; one may
     ask for more. *)
  let rec drain st =
    match st.pending with
    | [] -> st
    | (name, template, sigma) :: rest -> (
        let st = { st with pending = rest } in
        match List.assoc_opt template st.templates with
        | None -> drain st
        | Some tpl -> (
            match tpl.t_def with
            | SFunctionDef (_, _, params, fbody, _, sym, _, _, _) ->
                let t = Option.value (IntMap.find_opt sym tmap) ~default:(TUnknown (no_info, 0)) in
                let ictx = { ctx with sigma } in
                let st =
                  if tpl.t_lifted then lift_with ictx st { tpl.t_scope with family = name } tpl.t_def name t
                  else
                    let fn, st = function_of ictx st { tpl.t_scope with family = name } name params fbody t tpl.t_public false in
                    { st with funcs = st.funcs @ [ fn ] }
                in
                drain st
            | _ -> drain st))
  in
  let st = { st with funcs = st.funcs @ funcs } in
  (* What the modules importing this one asked of its polymorphic
     functions. *)
  let st =
    List.fold_left
      (fun st (template, sigma) ->
        if not (List.mem_assoc template st.templates) then st
        else
          let name = template ^ "_m" ^ String.concat "" (List.map (fun (_, t) -> code ctx.own no_info t) sigma) in
          if StringSet.mem name st.instances then st
          else { st with instances = StringSet.add name st.instances; pending = st.pending @ [ (name, template, sigma) ] })
      st requested
  in
  let st = drain st in
  let temps = List.map (fun (ct, n) -> CDecl (ct, n, None)) st.temps in
  let includes =
    List.fold_left
      (fun names s ->
        match s with
        | SImport (_, name, _, _, _, _) when (not (List.mem name names)) && not (List.mem name context.externals) -> names @ [ name ]
        | _ -> names)
      (if context.main then context.starts else [])
      stmts
  in
  let starts = List.map (fun name -> CLine (Printf.sprintf "%s();" (init_name name))) context.starts in
  ignore scope;
  let public_types =
    List.filter_map
      (fun f -> if f.f_public then Some (String.concat " " (f.f_result :: List.map fst f.f_params)) else None)
      st.funcs
    @ List.filter_map (fun (public, t, _) -> if public then Some t else None) statics
  in
  {
    program_name = own;
    main = context.main;
    separate = context.separate;
    starts = context.starts;
    includes;
    externs;
    statics;
    funcs = st.funcs;
    main_body = temps @ starts @ body;
    types = st.types;
    helpers = st.helpers;
    helper_protos_ = List.map snd st.helper_protos;
    hands_argv = gc && context.main && List.mem_assoc "sys" context.sigmaps;
    wrappers = st.wrappers;
    capture_table = st.captures;
    includes_math = st.includes_math;
    uses_bool = st.uses_bool;
    public_types;
    requests_ = st.requests;
    protos_ = List.map snd st.protos;
  }

(** Every module of a program as a cprogram, each compiling the instances
    of its polymorphic functions the others call -- asked again until no
    module asks for one more. [([stmt], typ IntMap.t, Module.context)] ->
    string -> [cprogram] *)
let translate_all units standard =
  let rec go requested rounds =
    let programs =
      List.map (fun (stmts, tmap, context) -> translate_program ~requested stmts tmap context standard) units
    in
    let asked =
      List.fold_left
        (fun out p -> List.fold_left (fun out r -> if List.mem r out then out else out @ [ r ]) out p.requests_)
        requested programs
    in
    if List.length asked = List.length requested || rounds > 20 then programs else go asked (rounds + 1)
  in
  go [] 0

(* --- the printer --- *)

(** A comment in the standard's own style. string -> string -> string *)
let comment text standard = if standard = "c89" then Printf.sprintf "/* %s */" text else Printf.sprintf "// %s" text

(** s as C source, indented to level; under c89 a block's declarations
    come first. string -> int -> cstmt -> string *)
let rec pprint_stmt standard level s =
  let pad = String.make (4 * level) ' ' in
  match s with
  | CDecl (ct, name, None) -> pad ^ declaration ct name ^ ";"
  | CDecl (ct, name, Some init) -> Printf.sprintf "%s%s = %s;" pad (declaration ct name) init
  | CLine l -> pad ^ l
  | CIf (c, t, e) ->
      let rec ladder text e =
        match e with
        | None -> text ^ "\n" ^ pad ^ "}"
        | Some [ CIf (c2, t2, e2) ] -> ladder (text ^ "\n" ^ pad ^ "} else if (" ^ c2 ^ ") {\n" ^ block standard (level + 1) t2) e2
        | Some body -> text ^ "\n" ^ pad ^ "} else {\n" ^ block standard (level + 1) body ^ "\n" ^ pad ^ "}"
      in
      ladder (pad ^ "if (" ^ c ^ ") {\n" ^ block standard (level + 1) t) e
  | CWhile (c, body) -> Printf.sprintf "%swhile (%s) {\n%s\n%s}" pad c (block standard (level + 1) body) pad
  | CFor (h, body) -> Printf.sprintf "%sfor (%s) {\n%s\n%s}" pad h (block standard (level + 1) body) pad
  | CBlock body -> Printf.sprintf "%s{\n%s\n%s}" pad (block standard (level + 1) body) pad
  | CReturn None -> pad ^ "return;"
  | CReturn (Some v) -> pad ^ "return " ^ v ^ ";"
  | CBreak -> pad ^ "break;"
  | CContinue -> pad ^ "continue;"
  | CGoto l -> pad ^ "goto " ^ l ^ ";"
  | CLabel l -> String.make (4 * max 0 (level - 1)) ' ' ^ l ^ ":;"

(** A block's statements; under c89 every declaration moves to its top,
    its initializer left where it was as an assignment.
    string -> int -> [cstmt] -> string *)
and block standard level stmts =
  let pad = String.make (4 * level) ' ' in
  if standard <> "c89" then String.concat "\n" (List.map (pprint_stmt standard level) stmts)
  else
    let decls = List.filter_map (function CDecl (ct, n, _) -> Some (pad ^ declaration ct n ^ ";") | _ -> None) stmts in
    let rest =
      List.filter_map
        (function
          | CDecl (_, _, None) -> None
          | CDecl (_, n, Some init) -> Some (Printf.sprintf "%s%s = %s;" pad n init)
          | s -> Some (pprint_stmt standard level s))
        stmts
    in
    String.concat "\n" (if decls = [] then rest else decls @ (if rest = [] then [] else "" :: rest))

(** A function's declarator. cfunc -> string *)
let signature f =
  let params = List.map (fun (ct, n) -> declaration ct n) f.f_params in
  let params =
    if f.f_captures then marker "P" f.f_name (if params = [] then "0" else "1") ^ String.concat ", " params
    else match params with [] -> "void" | ps -> String.concat ", " ps
  in
  Printf.sprintf "%s(%s)" (declaration f.f_result f.f_name) params

(** Whether `s` occurs in `text`. string -> string -> bool *)
let contains_text s text =
  let n = String.length s and m = String.length text in
  let rec go i = i + n <= m && (String.sub text i n = s || go (i + 1)) in
  go 0

(** The lines that stop the C compiler fusing a multiply and an add into
    one rounding, which every other host rounds twice. string -> [string] *)
let no_contraction standard =
  [
    comment "Every multiply and add rounded on its own, as on every other target." standard;
    "#if defined(__clang__)";
    "#pragma STDC FP_CONTRACT OFF";
    "#elif defined(__GNUC__)";
    "#pragma GCC optimize (\"fp-contract=off\")";
    "#endif";
  ]

(** The #include lines a file needs, from what it writes.
    cprogram -> string -> string -> [string] *)
let headers (program : cprogram) standard text =
  let contains s =
    let n = String.length s and m = String.length text in
    let rec go i = i + n <= m && (String.sub text i n = s || go (i + 1)) in
    go 0
  in
  List.map (Printf.sprintf "#include <%s>")
    ((if standard = "c99" && (contains "bool" || contains "true" || contains "false") then [ "stdbool.h" ] else [])
    @ (if contains "printf" || contains "sprintf" then [ "stdio.h" ] else [])
    @ (if contains "malloc" || contains "strtod" || contains "atoi" || contains "NULL" || contains "exit(" then [ "stdlib.h" ] else [])
    @ (if contains "GC_" then [ "gc.h" ] else [])
    @ (if contains "strlen" || contains "strcmp" || contains "memcpy" || contains "memset" || contains "memmove" || contains "strcpy" || contains "strchr" || contains "strncmp" then [ "string.h" ] else [])
    @ (if contains "DBL_MAX" then [ "float.h" ] else [])
    @ if program.includes_math || contains "HUGE_VAL" then [ "math.h" ] else [])

let guard_of name = Printf.sprintf "PYK_%s_H" (String.uppercase_ascii name)

(** A type's declaration, guarded so two files of one program may both
    carry it. string -> string -> string *)
let guarded name decl =
  let guard = "PYK_TYPE_" ^ String.uppercase_ascii name in
  Printf.sprintf "#ifndef %s\n#define %s\n%s\n#endif" guard guard decl

(** The header a module the program imports is included through.
    cprogram -> string -> string -> string *)
let pprint_c_header (program : cprogram) target source =
  let standard, gc = standard_of target in
  let guard = guard_of program.program_name in
  let types = program.types in
  let text =
    String.concat "\n"
      ([
         comment (Printf.sprintf "Generated from %s by the Pyking compiler. Do not edit." source) standard;
         comment (Printf.sprintf "What the module '%s' exports." program.program_name) standard;
         "";
         Printf.sprintf "#ifndef %s" guard;
         Printf.sprintf "#define %s" guard;
       ]
      @ (if standard = "c99" then [ ""; "#include <stdbool.h>" ] else [])
      @ List.concat_map (fun (name, decl) -> [ ""; guarded name decl ]) types
      @ (let exported = List.filter_map (fun (public, ct, n) -> if public then Some (Printf.sprintf "extern %s;" (declaration ct n)) else None) program.statics in
         if exported = [] then [] else "" :: exported)
      @ (let protos = List.filter_map (fun f -> if f.f_public then Some (signature f ^ ";") else None) program.funcs in
         if protos = [] then [] else "" :: protos)
      @ [
          "";
          comment "Runs the module's own top level; the program calls it once, before any module that imports this one." standard;
          Printf.sprintf "void %s(void);" (init_name program.program_name);
          "";
          Printf.sprintf "#endif  %s" (comment guard standard);
          "";
        ])
  in
  expand_captures ~gc program.capture_table text

(** The whole translation unit. cprogram -> string -> string -> string *)
let pprint_c_program (program : cprogram) target source =
  let standard, gc = standard_of target in
  let visibility f = if f.f_public || not program.separate then (if f.f_captures then "static " else "") else "static " in
  let body =
    String.concat "\n"
      ((let included = List.map (Printf.sprintf "#include \"%s.h\"") program.includes in
        let included = if program.main then included else Printf.sprintf "#include \"%s.h\"" program.program_name :: included in
        if included = [] then [] else "" :: included)
      @ List.concat_map (fun (name, decl) -> [ ""; guarded name decl ]) program.types
      @ (if program.externs = [] then []
         else "" :: comment "What the external modules this one imports implement." standard :: program.externs)
      @ (if program.protos_ = [] then []
         else "" :: comment "The instances of other modules' polymorphic functions this one calls." standard :: program.protos_)
      @ (if program.helper_protos_ = [] then [] else "" :: program.helper_protos_)
      @ List.concat_map (fun (_, h) -> [ ""; h ]) program.helpers
      @ (let statics = List.map (fun (public, ct, n) -> Printf.sprintf "%s%s;" (if public then "" else "static ") (declaration ct n)) program.statics in
         if statics = [] then [] else "" :: statics)
      @ (if program.funcs = [] then []
         else
           ""
           :: comment "Declared ahead of their definitions: a Pyking function may be called before it is written." standard
           :: List.map (fun f -> visibility f ^ signature f ^ ";") program.funcs)
      @ List.concat_map (fun (_, w) -> [ ""; w ]) program.wrappers
      @ List.concat_map
          (fun f -> [ ""; visibility f ^ signature f; "{"; block standard 1 f.f_body; "}" ])
          program.funcs
      @
      if program.main && gc then
        (* The collector is started before anything can allocate; the
           program's own top level is a block of its own after it, since
           C89 wants a block's declarations before its statements. *)
        (if program.hands_argv then
           (* `sys.args` and the rest read the program's own arguments,
              which only main is handed. *)
           [ ""; "void pyk_sys_start(int argc, char **argv);"; ""; "int main(int argc, char **argv)"; "{"; "    GC_INIT();";
             "    pyk_sys_start(argc, argv);" ]
         else [ ""; "int main(void)"; "{"; "    GC_INIT();" ])
        @ [ "    {"; block standard 2 program.main_body; "    }"; ""; "    return 0;"; "}"; "" ]
      else if program.main then
        [ ""; "int main(void)"; "{"; block standard 1 program.main_body; ""; "    return 0;"; "}"; "" ]
      else [ ""; Printf.sprintf "void %s(void)" (init_name program.program_name); "{"; block standard 1 program.main_body; "}"; "" ])
  in
  let body = expand_captures ~gc program.capture_table body in
  let found = headers program standard body in
  String.concat "\n"
    ([
       comment (Printf.sprintf "Generated from %s by the Pyking compiler. Do not edit." source) standard;
       comment
         (if program.main && not program.separate then
            Printf.sprintf "Target: %s. Compile with:  cc -std=%s <this file>%s -lm" target standard
              (if gc then " -lgc" else "")
          else Printf.sprintf "Target: %s. One translation unit of the program; compile it with the others." target)
         standard;
     ]
    @ (if found = [] then [] else "" :: found)
    @ if contains_text "double" body then "" :: no_contraction standard else [])
  ^ "\n" ^ body
