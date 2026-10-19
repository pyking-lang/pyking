(** The compiler's targets: every one the driver offers, which family it
    belongs to, what its output file is called, and the unversioned
    alias that names its family's default.

    A target is named once, here. Nothing else in the compiler writes a
    target name into a list of its own -- the backends read their own
    versions back out of this module, and so do pyk.ml, module.ml,
    execution.ml and the test harness. See docs/targets.md.

    A *version* says the oldest host the output is guaranteed to run on.
    Two versions of one family may emit identical text: the version sets
    the header comment and the command `--run` uses, and lets a backend
    refuse what an older host cannot do. What a version counts depends on
    the family: the host's release for Python, Node, Java and OCaml, the
    ECMAScript edition for the browser pages, the standard for C.

    Data structures:
      family -- which backend a target belongs to.

    Functions:
      all -- every target, in the order the usage message lists them.
      default -- the target `pyk compile` uses when none is given.
      aliases -- each unversioned name and the version it means.
      version target -- the version a target's name says.
      es_edition target -- the ECMAScript edition a JavaScript target
        emits.
      resolve name -- the canonical target a name means, if any.
      family_of target -- the family a canonical target belongs to.
      members family -- a family's targets, oldest version first.
      extension target -- what the primary output file is called.
      family_name family -- the unversioned name of a family. *)

(** Which backend compiles a target, and so which targets share an
    emission. *)
type family =
  | Python
  | Node
  | Web
  | Iweb
  | C
  | Java
  | Ocaml
  | Pyking

(* Every target, in the order `pyk --help` lists them: the families a
   program is most likely to want first, and `pyking` -- which compiles
   Pyking to Pyking rather than to a host -- last. *)
let table =
  [
    ("python12", Python, ".py");
    ("python14", Python, ".py");
    ("node22", Node, ".js");
    ("node24", Node, ".js");
    ("web2020", Web, ".html");
    ("web2024", Web, ".html");
    ("iweb2020", Iweb, ".html");
    ("iweb2024", Iweb, ".html");
    ("c89", C, ".c");
    ("c99", C, ".c");
    ("c23", C, ".c");
    ("java8", Java, ".java");
    ("java17", Java, ".java");
    ("java21", Java, ".java");
    ("ocaml4.14", Ocaml, ".ml");
    ("ocaml5.5", Ocaml, ".ml");
    ("pyking", Pyking, ".pyk");
  ]

(* The version each unversioned name means: the oldest a program is
   likely to meet, rather than the newest, except where an old one costs
   the output something (C89, Java 8). *)
let defaults =
  [
    (Python, "python12");
    (Node, "node22");
    (Web, "web2020");
    (Iweb, "iweb2020");
    (C, "c99");
    (Java, "java21");
    (Ocaml, "ocaml4.14");
  ]

(** Every target, in the order the usage message lists them.
    [string] *)
let all = List.map (fun (name, _, _) -> name) table

(** The unversioned name of a family. family -> string *)
let family_name f =
  match f with
  | Python -> "python"
  | Node -> "node"
  | Web -> "web"
  | Iweb -> "iweb"
  | C -> "c"
  | Java -> "java"
  | Ocaml -> "ocaml"
  | Pyking -> "pyking"

(** The family a canonical target belongs to. string -> family *)
let family_of target =
  match List.find_opt (fun (name, _, _) -> name = target) table with
  | Some (_, f, _) -> f
  | None -> invalid_arg ("no such target: " ^ target)

(** A family's targets, in the order `all` lists them -- oldest version
    first, so the last is the latest. family -> [string] *)
let members f =
  List.filter_map (fun (name, g, _) -> if g = f then Some name else None) table

(* The families that take a version. `pyking` is not one of them: it
   compiles Pyking to Pyking, so there is no host whose version could
   matter. *)
let versioned = [ Python; Node; Web; Iweb; C; Java; Ocaml ]

(** Each unversioned name and the version it means: a family's
    default. [(string, string)] *)
let aliases = List.map (fun f -> (family_name f, List.assoc f defaults)) versioned

(** The canonical target a name means -- itself if it is already one, or
    what an alias points at. None for a name that is neither.
    string -> string option *)
let resolve name =
  if List.mem name all then Some name else List.assoc_opt name aliases

(* What `pyk compile` picks when `--target` says nothing. Python
   because it is the one backend that compiles the whole language. *)
let default = List.assoc Python defaults

(** What a target's name says after its family's: its version, "" for
    one without. string -> string *)
let version target =
  let f = family_name (family_of target) in
  String.sub target (String.length f) (String.length target - String.length f)

(** The ECMAScript edition a JavaScript target emits: 2020 for node22,
    web2020 and iweb2020, 2024 for the rest. string -> int *)
let es_edition target =
  match target with "node22" | "web2020" | "iweb2020" -> 2020 | _ -> 2024

(** What a target's primary output file is called. string -> string *)
let extension target =
  match List.find_opt (fun (name, _, _) -> name = target) table with
  | Some (_, _, ext) -> ext
  | None -> invalid_arg ("no such target: " ^ target)
