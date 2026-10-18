(** The C code-generation backend, serving c89, c99 and c23. Like
    target_ocaml.ml it infers no types of its own: every type it writes
    is read out of the checker's tmap. C has no garbage collector, so
    this backend compiles what needs none: a polymorphic function once
    per type it is used at, a tuple as a struct passed by value, a
    datatype that does not hold itself as a tagged union, a nested def as
    a function of its own taking what it captures, and a function value
    as a function pointer and an environment on the stack -- one that
    could outlive that stack frame is refused, and so is a list. C also
    leaves the order of an operator's operands and a call's arguments
    unspecified, so operands that can print are pinned down with
    temporaries. See docs/target_c.md.

    Data structures:
      Unsupported -- a construct this backend cannot compile.
      cexpr / cstmt -- the C AST: an expression is its text and its
        precedence.
      binding / scope -- what a Pyking name stands for in C.
      state -- what the translation of one module accumulates.
      cprogram -- a translated module.

    Functions:
      translate_program stmts tmap context standard -- one module.
      pprint_c_program program standard source -- the translation unit.
      pprint_c_header program standard source -- the header a module the
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

(* Why a list is refused: every one is a heap allocation, and nothing
   would free it. *)
let heap_reason = "a list, which needs a heap: C has no garbage collector to free one"

(* --- C expressions: text and precedence --- *)

type cexpr = { text : string; prec : int; local_env : bool }
(* local_env: a function value whose environment is in this function's
   own stack frame, which must not outlive it *)

let p_comma = 0
let p_assign = 2
let p_cond = 3
let p_or = 4
let p_and = 5
let p_eq = 9
let p_rel = 10
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
let rec code own info t =
  (* With no better place to point at, a refusal points at where the
     checker made the type. *)
  let info = if info.file = "<c>" then type_info t else info in
  match t with
  | TInt _ -> "i"
  | TFloat _ -> "f"
  | TBool _ -> "b"
  | TString _ -> "s"
  | TTuple (_, [], _) -> "u"
  | TTuple (_, es, _) -> "T" ^ String.concat "" (List.map (code own info) es) ^ "_"
  | TCon (_, c, args, _) ->
      (* A datatype is named by its module wherever it is used, so every
         file of the program spells its struct the same. *)
      let c = if String.contains c '.' then c else own ^ "." ^ c in
      "D" ^ ident_of c ^ "_" ^ String.concat "" (List.map (code own info) args) ^ "_"
  | TFunction (_, ps, r, _, _, _, imps) ->
      "F" ^ String.concat "" (List.map (code own info) (ps @ List.map (fun (IParam (_, t)) -> t) imps)) ^ "_" ^ code own info r ^ "_"
  | TList _ -> unsupported info heap_reason
  | TForall _ ->
      unsupported info
        "a polymorphic parameter, which C cannot compile once per type: the \
         one function is handed every type it is used at"
  | TVar _ | TUnknown _ | _ ->
      unsupported info "a value whose type nothing in the program settles, which C has to know"

(* --- what a translation reads --- *)

type ctx = {
  tmap : typ IntMap.t;
  standard : string;
  context : Module.context;
  own : string;
  datatypes : datatype SMap.t;
  modules : (string * string) list; (* alias -> module *)
  printing : Analyses.effects;
  sigma : (string * typ) list; (* the type variables of the instance being written *)
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

(** A helper added to the file once. state -> string -> string -> state *)
let need_helper st name text =
  if List.mem_assoc name st.helpers then st else { st with helpers = st.helpers @ [ (name, text) ] }

(* --- the shared helpers --- *)

let concat_helper =
  "static const char *pyk_concat(const char *a, const char *b)\n{\n    size_t la = strlen(a);\n    size_t lb = strlen(b);\n    char *result = malloc(la + lb + 1);\n    memcpy(result, a, la);\n    memcpy(result + la, b, lb + 1);\n    return result;\n}"

let slice_helper =
  "static const char *pyk_slice(const char *s, size_t from, size_t drop)\n{\n    size_t n = strlen(s) - from - drop;\n    char *out = malloc(n + 1);\n    memcpy(out, s + from, n);\n    out[n] = '\\0';\n    return out;\n}"

let ends_helper =
  "static int pyk_ends_with(const char *s, const char *suffix)\n{\n    size_t ls = strlen(s);\n    size_t lt = strlen(suffix);\n    return ls >= lt && strcmp(s + ls - lt, suffix) == 0;\n}"

let int_str_helper =
  "static const char *pyk_int_str(int n)\n{\n    char *out = malloc(24);\n    sprintf(out, \"%d\", n);\n    return out;\n}"

let quote_helper =
  "static const char *pyk_quote(const char *s)\n{\n    char *out = malloc(strlen(s) * 2 + 3);\n    size_t k = 0;\n    out[k++] = '\\'';\n    for (; *s != '\\0'; s++) {\n        switch (*s) {\n        case '\\\\': out[k++] = '\\\\'; out[k++] = '\\\\'; break;\n        case '\\'': out[k++] = '\\\\'; out[k++] = '\\''; break;\n        case '\\n': out[k++] = '\\\\'; out[k++] = 'n'; break;\n        case '\\t': out[k++] = '\\\\'; out[k++] = 't'; break;\n        case '\\r': out[k++] = '\\\\'; out[k++] = 'r'; break;\n        default: out[k++] = *s;\n        }\n    }\n    out[k++] = '\\'';\n    out[k] = '\\0';\n    return out;\n}"

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
      "    char *out = malloc(64);";
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
let need_float st = need_helper st "pyk_float_str" float_helper

(** The typedef a host's callback parameter is written through:
    `pyk_fn_ii_v` for `(Int, Int) -> ()`. ctx -> typ -> string *)
let host_callback_type _ctx t =
  match t with
  | TFunction (_, ps, r, _, _, _, _) ->
      let letter t = match t with TInt _ -> "i" | TFloat _ -> "f" | TBool _ -> "b" | TString _ -> "s" | _ -> "v" in
      "pyk_fn_" ^ String.concat "" (List.map letter ps) ^ "_" ^ letter r
  | _ -> "void"

(* --- the types a file declares --- *)

(** The datatype a canonical name denotes, its parameters bound to args.
    ctx -> info -> string -> [typ] -> (datatype, [(string, typ)]) *)
let datatype_of ctx info canonical args =
  match SMap.find_opt canonical ctx.datatypes with
  | Some (Datatype (_, params, _) as d) ->
      (d, if List.length params = List.length args then List.combine params args else [])
  | None -> unsupported info (Printf.sprintf "the datatype %s is not one this module can see" canonical)

(** A constructor's fields at an instance: each field's C name and type.
    ctx -> info -> typ -> string -> [(string, typ)] *)
let ctor_fields ctx info t name =
  match t with
  | TCon (_, canonical, args, _) -> (
      let Datatype (_, _, ctors), bound = datatype_of ctx info canonical args in
      match List.assoc_opt name ctors with
      | Some fields -> List.mapi (fun i (_, ft) -> (Printf.sprintf "f%d" i, substitute bound ft)) fields
      | None -> unsupported info (Printf.sprintf "no constructor %s" name))
  | _ -> unsupported info "a constructor of a value that is not a datatype"

(** A constructor's tag: its position in its datatype. ctx -> info -> typ
    -> string -> int *)
let ctor_tag ctx info t name =
  match t with
  | TCon (_, canonical, args, _) ->
      let Datatype (_, _, ctors), _ = datatype_of ctx info canonical args in
      let rec go i = function [] -> 0 | (c, _) :: rest -> if c = name then i else go (i + 1) rest in
      go 0 ctors
  | _ -> 0

(** Whether a datatype instance holds itself, directly or through another
    datatype or a tuple: the one a tagged union by value cannot be.
    ctx -> info -> typ -> bool *)
let holds_itself ctx info t =
  let rec reaches seen t target =
    match t with
    | TCon (_, c, args, _) ->
        let key = c ^ "/" ^ code ctx.own info t in
        if key = target then true
        else if List.mem key seen then false
        else
          let Datatype (_, _, ctors), bound = datatype_of ctx info c args in
          List.exists
            (fun (_, fields) -> List.exists (fun (_, ft) -> reaches (key :: seen) (substitute bound ft) target) fields)
            ctors
    | TTuple (_, es, _) -> List.exists (fun e -> reaches seen e target) es
    | _ -> false
  in
  match t with
  | TCon (_, c, args, _) ->
      let key = c ^ "/" ^ code ctx.own info t in
      let Datatype (_, _, ctors), bound = datatype_of ctx info c args in
      List.exists
        (fun (_, fields) -> List.exists (fun (_, ft) -> reaches [] (substitute bound ft) key) fields)
        ctors
  | _ -> false

(** A Pyking type as C writes it, every compound type it names declared
    once in the file. ctx -> state -> info -> typ -> (string, state) *)
let rec ctype ctx st info t =
  let t = substitute ctx.sigma t in
  let info = if info.file = "<c>" then type_info t else info in
  match t with
  | TInt _ -> ("int", st)
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
  | TCon (_, canonical, args, _) ->
      let name = "pyk_d_" ^ code ctx.own info t in
      if List.mem_assoc name st.types then (name, st)
      else (
        if holds_itself ctx info t then
          unsupported info
            (Printf.sprintf
               "the datatype %s, which holds a value of itself: that needs a \
                heap, and C has no garbage collector to free one"
               (pprint_type default_config t));
        let Datatype (_, _, ctors), bound = datatype_of ctx info canonical args in
        let arms, st =
          List.fold_left
            (fun (out, st) (cname, fields) ->
              let fs, st =
                List.fold_left
                  (fun (out, st) (i, (_, ft)) ->
                    let ct, st = ctype ctx st info (substitute bound ft) in
                    (out @ [ (ct, Printf.sprintf "f%d" i) ], st))
                  ([], st)
                  (List.mapi (fun i f -> (i, f)) fields)
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
        let decl =
          Printf.sprintf "typedef struct %s {\n    int tag;\n    union {\n%s\n    } u;\n} %s;" name
            (String.concat "\n" members) name
        in
        let st = { st with types = st.types @ [ (name, decl) ] } in
        let st =
          List.fold_left
            (fun st (tag, (cname, fs)) ->
              let maker_name = Printf.sprintf "pyk_mk_%s_%s" (code ctx.own info t) cname in
              let maker =
                Printf.sprintf "static %s %s(%s)\n{\n    %s v;\n    v.tag = %d;\n%s\n    return v;\n}" name maker_name
                  (if fs = [] then "void" else String.concat ", " (List.map (fun (ct, n) -> declaration ct n) fs))
                  name tag
                  (String.concat "\n" (List.map (fun (_, n) -> Printf.sprintf "    v.u.%s.%s = %s;" (c_ident cname) n n) fs))
              in
              need_helper st maker_name maker)
            st
            (List.mapi (fun i a -> (i, a)) arms)
        in
        (name, st))
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
  | TList _ -> unsupported info heap_reason
  | t -> ignore (code ctx.own info t); ("int", st)

(** A declaration of name at the C type text. string -> string -> string *)
and declaration ct name =
  if String.length ct > 0 && ct.[String.length ct - 1] = '*' then ct ^ name else ct ^ " " ^ name

(** The function that writes a value of type t as it appears inside a
    larger one (a String quoted), declared once in the file.
    ctx -> state -> info -> typ -> (string -> string, state) *)
let rec shower ctx st info t =
  let t = substitute ctx.sigma t in
  match t with
  | TInt _ -> ((fun v -> Printf.sprintf "pyk_int_str(%s)" v), need_helper st "pyk_int_str" int_str_helper)
  | TFloat _ -> ((fun v -> Printf.sprintf "pyk_float_str(%s)" v), need_float st)
  | TBool _ -> ((fun v -> Printf.sprintf "(%s ? \"true\" : \"false\")" v), st)
  | TString _ -> ((fun v -> Printf.sprintf "pyk_quote(%s)" v), need_helper st "pyk_quote" quote_helper)
  | TTuple (_, [], _) -> ((fun _ -> "\"()\""), st)
  | TFunction _ -> ((fun _ -> "\"<function>\""), st)
  | TTuple (_, es, _) ->
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then ((fun v -> Printf.sprintf "%s(%s)" name v), st)
      else
        let parts, st =
          List.fold_left
            (fun (out, st) (i, e) ->
              let show, st = shower ctx st info e in
              (out @ [ show (Printf.sprintf "v.a%d" i) ], st))
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
        let text = Printf.sprintf "static const char *%s(%s v)\n{\n%s\n}" name ct body in
        ((fun v -> Printf.sprintf "%s(%s)" name v), need_helper st name text)
  | TCon (_, canonical, args, _) ->
      let name = "pyk_show_" ^ code ctx.own info t in
      let ct, st = ctype ctx st info t in
      if List.mem_assoc name st.helpers then ((fun v -> Printf.sprintf "%s(%s)" name v), st)
      else
        let Datatype (_, _, ctors), bound = datatype_of ctx info canonical args in
        let arms, st =
          List.fold_left
            (fun (out, st) (tag, (cname, fields)) ->
              let parts, st =
                List.fold_left
                  (fun (out, st) (i, (_, ft)) ->
                    let show, st = shower ctx st info (substitute bound ft) in
                    (out @ [ show (Printf.sprintf "v.u.%s.f%d" (c_ident cname) i) ], st))
                  ([], st)
                  (List.mapi (fun i f -> (i, f)) fields)
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
        let st = need_concat st in
        let text =
          Printf.sprintf "static const char *%s(%s v)\n{\n    const char *out;\n    switch (v.tag) {\n%s\n    }\n    return \"\";\n}" name ct
            (String.concat "\n" arms)
        in
        ((fun v -> Printf.sprintf "%s(%s)" name v), need_helper st name text)
  | t ->
      ignore (code ctx.own info t);
      ((fun v -> v), st)

(** What print writes for v, a value of type t: its text.
    ctx -> state -> info -> typ -> cexpr -> (string, state) *)
let printed ctx st info t (v : cexpr) =
  match substitute ctx.sigma t with
  | TString _ -> (v.text, st)
  | t ->
      let show, st = shower ctx st info t in
      (show v.text, st)

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
        | EBool (i, _, _) | EEq (i, _, _, _) | ELessThan (i, _, _, _) | ELessThanEq (i, _, _, _)
        | EGreatThan (i, _, _, _) | EGreatThanEq (i, _, _, _) ->
            TBool (i, 0)
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

(** The tests a pattern makes of the subject s, of type t, and the names
    it binds, each to a place in s. ctx -> state -> pattern -> cexpr ->
    typ -> ([cexpr], [(string, cexpr, typ)], state) *)
let rec pattern ctx st p (s : cexpr) (t : typ) =
  let info = pattern_info p in
  match p with
  | PWildcard _ -> ([], [], st)
  | PCapture (_, name, _) -> ([], [ (name, s, t) ], st)
  | PInt (_, v, _) -> ([ binary p_eq "==" s (if v < 0 then mk p_unary (string_of_int v) else atom (string_of_int v)) ], [], st)
  | PBool (_, v, _) -> ([ (if v then s else mk p_unary ("!" ^ at p_unary s)) ], [], st)
  | PString (_, v, _) -> ([ binary p_eq "==" (atom (Printf.sprintf "strcmp(%s, %s)" s.text (quote v))) (atom "0") ], [], st)
  | PTuple (_, ps, _) ->
      let types = match t with TTuple (_, ts, _) -> ts | _ -> List.map (fun _ -> t) ps in
      parts ctx st ps (List.mapi (fun i _ -> atom (Printf.sprintf "%s.a%d" (at p_atom s) i)) ps) types
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
  | PConstructor (_, _, name, fields, _, _) ->
      let tag = ctor_tag ctx info t name in
      let declared = ctor_fields ctx info t name in
      let test = binary p_eq "==" (atom (at p_atom s ^ ".tag")) (atom (string_of_int tag)) in
      let places = List.map (fun (f, _) -> atom (Printf.sprintf "%s.u.%s.%s" (at p_atom s) (c_ident name) f)) declared in
      let conds, binds, st = parts ctx st fields places (List.map snd declared) in
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
  if List.length effectful < 2 then (values, [], st)
  else
    let earlier = List.filteri (fun i _ -> i < List.length effectful - 1) effectful in
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
  | EBool (_, b, _) -> (atom (if b then true_text ctx else false_text ctx), { st with uses_bool = st.uses_bool || ctx.standard <> "c89" })
  | ETuple (_, [], _) -> (unit_value, st)
  | ETuple (_, es, _) ->
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let values, steps, st = in_order ctx st scope es in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a tuple");
      (sequenced steps (atom (Printf.sprintf "pyk_mk_%s(%s)" (code ctx.own info t) (String.concat ", " (List.map (fun v -> v.text) values)))), st)
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
  | EConcat (_, l, r, _) ->
      let pieces, steps, st = in_order ctx st scope [ l; r ] in
      let st = need_concat st in
      (sequenced steps (atom (Printf.sprintf "pyk_concat(%s, %s)" (List.nth pieces 0).text (List.nth pieces 1).text)), st)
  | EEq (_, l, r, _) -> (
      let pieces, steps, st = in_order ctx st scope [ l; r ] in
      let a = List.nth pieces 0 and b = List.nth pieces 1 in
      match type_of ctx scope l with
      | TString _ -> (sequenced steps (binary p_eq "==" (atom (Printf.sprintf "strcmp(%s, %s)" a.text b.text)) (atom "0")), st)
      | _ -> (sequenced steps (binary p_eq "==" a b), st))
  | ELessThan (_, l, r, _) -> arithmetic ctx st scope p_rel "<" l r
  | ELessThanEq (_, l, r, _) -> arithmetic ctx st scope p_rel "<=" l r
  | EGreatThan (_, l, r, _) -> arithmetic ctx st scope p_rel ">" l r
  | EGreatThanEq (_, l, r, _) -> arithmetic ctx st scope p_rel ">=" l r
  | ECall (_, EVar (_, name, callee), args, _)
    when Builtin.crosses_host name && not (IntMap.mem callee ctx.tmap) ->
      let line, st = print_call ctx st scope name (arg_exprs args) in
      (atom (Printf.sprintf "(%s, 0)" line), st)
  | ECall (_, EVar (_, name, _), args, _) when List.mem name Builtin.pure_names && not (SMap.mem name scope.names) ->
      builtin ctx st scope e name (arg_exprs args)
  | ECall (_, func, args, _) -> call ctx st scope e func (arg_exprs args)
  | EConstruct (_, _, name, args, _) ->
      let t = type_of ctx scope e in
      let _, st = ctype ctx st info t in
      let values, steps, st = in_order ctx st scope (arg_exprs args) in
      if List.exists (fun v -> v.local_env) values then unsupported info (escaping "a datatype");
      ( sequenced steps
          (atom (Printf.sprintf "pyk_mk_%s_%s(%s)" (code ctx.own info t) name (String.concat ", " (List.map (fun v -> v.text) values)))),
        st )
  | EField (_, record, name, _) ->
      let rt = type_of ctx scope record in
      let v, st = expr ctx st scope record in
      let accessor, st = field_accessor ctx st info rt name in
      (atom (Printf.sprintf "%s(%s)" accessor v.text), st)
  | ELambda (_, params, body, _) -> lambda ctx st scope e params body
  | ELet (_, bindings, body, _) ->
      (* Each value into a temporary, by the comma operator, in order;
         the body then reads the temporaries. *)
      let steps, inner, st =
        List.fold_left
          (fun (steps, inner, st) (name, value) ->
            let v, st = expr ctx st scope value in
            let t = type_of ctx scope value in
            let ct, st = ctype ctx st info t in
            let temp, st = fresh_temp st ct in
            ( steps @ [ Printf.sprintf "%s = %s" temp (at p_assign v) ],
              bind_value inner name { value = atom temp; kind = BLocal; btype = t; cname_ = temp },
              st ))
          ([], scope, st) bindings
      in
      let result, st = expr ctx st inner body in
      (sequenced steps result, st)

and escaping what =
  Printf.sprintf
    "%s holding a function that captures values: the values are on the stack \
     of the function that made it, and C has no garbage collector to keep \
     them once it returns"
    what

and arithmetic ctx st scope prec op l r =
  let pieces, steps, st = in_order ctx st scope [ l; r ] in
  (sequenced steps (binary prec op (List.nth pieces 0) (List.nth pieces 1)), st)

(** A field every constructor of a datatype has, read through a function
    of its own. ctx -> state -> info -> typ -> string -> (string, state) *)
and field_accessor ctx st info t name =
  match t with
  | TCon (_, canonical, args, _) ->
      let Datatype (_, _, ctors), bound = datatype_of ctx info canonical args in
      let ct, st = ctype ctx st info t in
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
              Printf.sprintf "    case %d: return v.u.%s.f%d;" tag (c_ident cname) index)
            ctors
        in
        (* The last constructor's field is what `default` answers, so the
           function returns on every path. *)
        let last =
          match List.rev ctors with
          | (cname, fields) :: _ ->
              let rec go i = function [] -> 0 | (l, _) :: rest -> if l = Some name then i else go (i + 1) rest in
              Printf.sprintf "v.u.%s.f%d" (c_ident cname) (go 0 fields)
          | [] -> "0"
        in
        let text =
          Printf.sprintf "static %s(%s v)\n{\n    switch (v.tag) {\n%s\n    }\n    return %s;\n}" (declaration ft fname) ct
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
        let sigma = template.t_sigma @ sigma in
        let name = f.cname ^ "_m" ^ String.concat "" (List.map (fun (_, t) -> code ctx.own info t) sigma) in
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
  if f.lifted && not captures_nothing then
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
  | "range", _ ->
      unsupported info
        "`range` outside a `for` loop's header, where it is a list, which \
         needs a heap: C has no garbage collector to free one"
  | "len", [ v ] -> (
      match arg_type 0 with
      | TString _ -> wrap (atom (Printf.sprintf "(int)strlen(%s)" v.text))
      | _ -> unsupported info heap_reason)
  | "string", [ v ] -> (
      match arg_type 0 with
      | TString _ -> wrap v
      | t ->
          let show, st = shower ctx st info t in
          (sequenced steps (atom (show v.text)), st))
  | "int", [ v ] -> (
      match arg_type 0 with
      | TInt _ -> wrap v
      | TFloat _ -> (sequenced steps (atom (Printf.sprintf "pyk_truncate(%s)" v.text)), need_helper st "pyk_truncate" truncate_helper)
      | TBool _ -> wrap (mk p_cond (Printf.sprintf "%s ? 1 : 0" (at (p_cond + 1) v)))
      | TString _ -> (sequenced steps (atom (Printf.sprintf "pyk_int_of_string(%s)" v.text)), need_helper st "pyk_int_of_string" int_of_string_helper)
      | _ -> unsupported info "`int` of this type")
  | "float", [ v ] -> (
      match arg_type 0 with
      | TFloat _ -> wrap v
      | TInt _ -> wrap (mk p_unary (Printf.sprintf "(double)%s" (at p_unary v)))
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
      | _ -> unsupported info "`bool` of this type")
  | _ -> unsupported info (Printf.sprintf "the builtin `%s` with these arguments" name)

(** A print or debug call, as the C call writing the line.
    ctx -> state -> scope -> string -> [expr] -> (string, state) *)
and print_call ctx st scope name args =
  let values, steps, st = in_order ctx st scope args in
  let pieces, st =
    List.fold_left2
      (fun (out, st) a v ->
        let t = type_of ctx scope a in
        match t with
        | TInt _ -> (out @ [ ("%d", v.text) ], st)
        | TString _ -> (out @ [ ("%s", v.text) ], st)
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
      if StringSet.mem name scope.cells then
        let cell, st = fresh st (name ^ "_cell") in
        ( pre @ [ CDecl (ct, cell, Some v.text); CDecl (ct ^ (if ct.[String.length ct - 1] = '*' then "*" else " *"), cname, Some ("&" ^ cell)) ],
          bind_value scope name { value = atom cname; kind = BCell; btype = t; cname_ = cname },
          st )
      else (pre @ [ CDecl (ct, cname, Some v.text) ], bind_value scope name { value = atom cname; kind = BLocal; btype = t; cname_ = cname }, st)
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
  | SBreak _ -> ([ CBreak ], scope, st)
  | SContinue _ -> ([ CContinue ], scope, st)
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
  | SFunctionSig _ | SImport _ | SDatatype _ -> ([], scope, st)

(** Whether the function being written answers nothing. state -> bool *)
and is_void st = StringSet.mem "pyk$void" st.taken

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
      let inner = { scope with loops = []; family = name; cells = StringSet.union scope.cells (captured_vars body) } in
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
  let scope = { scope with cells = StringSet.union scope.cells (captured_vars body) } in
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
  | TInt _ -> "int"
  | TFloat _ -> "double"
  | TBool _ -> bool_type ctx
  | TString _ -> "const char *"
  | TTuple (_, [], _) -> "void"
  | TFunction (_, ps, r, _, _, _, _) ->
      ignore (List.map (host_type ctx info) (r :: ps));
      host_callback_type ctx t
  (* A tuple of what crosses crosses too, as the struct this backend
     writes it as: a C implementation declares the same one. *)
  | TTuple (_, es, _) when List.for_all (fun e -> match e with TInt _ | TFloat _ | TBool _ | TString _ -> true | _ -> false) es ->
      "pyk_t_" ^ code ctx.own info t
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
let expand_captures table text =
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

(** One module of a program as a cprogram. [stmt] -> typ IntMap.t ->
    Module.context -> string -> cprogram *)
let translate_program ?(requested = []) stmts tmap (context : Module.context) standard =
  let own = context.context_name in
  let own_datatypes =
    List.filter_map
      (function
        | SDatatype (_, _, _, _, sym, _) -> (match IntMap.find_opt sym tmap with Some (TData (_, d, _)) -> Some d | _ -> None)
        | _ -> None)
      stmts
  in
  let datatypes =
    List.fold_left
      (fun map (_, sigmap) ->
        List.fold_left
          (fun map (_, t, _) -> match t with TData (_, (Datatype (c, _, _) as d), _) -> SMap.add c d map | _ -> map)
          map sigmap)
      SMap.empty context.sigmaps
  in
  let datatypes = List.fold_left (fun map (Datatype (c, _, _) as d) -> SMap.add c d map) datatypes own_datatypes in
  let modules = List.filter_map (function SImport (_, m, alias, false, _, _) -> Some (alias, m) | _ -> None) stmts in
  let ctx = { tmap; standard; context; own; datatypes; modules; printing = Analyses.effects stmts; sigma = [] } in
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
  let scope = { scope with cells = StringSet.empty } in
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
        | SLet (_, TargetName (_, name, _), (EVar (_, other, _) as e), _, _, false, _)
          when (match SMap.find_opt other scope.names with
               | Some { kind = BFn f; _ } -> f.generic && type_vars (type_of ctx scope e) <> []
               | _ -> false) ->
            (* Another name for a polymorphic function is that function:
               there is no one C function a value of it could hold. *)
            (funcs, body, statics, bind_value scope name (SMap.find other scope.names), st)
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
            let st = { st with taken = StringSet.add ("static$" ^ cname) st.taken } in
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
    @ (if contains "malloc" || contains "strtod" || contains "atoi" || contains "NULL" then [ "stdlib.h" ] else [])
    @ (if contains "strlen" || contains "strcmp" || contains "memcpy" || contains "strcpy" || contains "strchr" || contains "strncmp" then [ "string.h" ] else [])
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
let pprint_c_header (program : cprogram) standard source =
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
  expand_captures program.capture_table text

(** The whole translation unit. cprogram -> string -> string -> string *)
let pprint_c_program (program : cprogram) standard source =
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
      if program.main then [ ""; "int main(void)"; "{"; block standard 1 program.main_body; ""; "    return 0;"; "}"; "" ]
      else [ ""; Printf.sprintf "void %s(void)" (init_name program.program_name); "{"; block standard 1 program.main_body; "}"; "" ])
  in
  let body = expand_captures program.capture_table body in
  let found = headers program standard body in
  String.concat "\n"
    ([
       comment (Printf.sprintf "Generated from %s by the Pyking compiler. Do not edit." source) standard;
       comment
         (if program.main && not program.separate then Printf.sprintf "Target: %s. Compile with:  cc -std=%s <this file>" standard standard
          else Printf.sprintf "Target: %s. One translation unit of the program; compile it with the others." standard)
         standard;
     ]
    @ (if found = [] then [] else "" :: found)
    @ if contains_text "double" body then "" :: no_contraction standard else [])
  ^ "\n" ^ body
