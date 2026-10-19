(** The compiler's targets: every one the driver offers, which family it
    belongs to, what its output file is called, and the unversioned
    alias that names its family's default.

    A target is named once, in this module. Nothing else in the compiler
    writes a target name into a list of its own -- the backends read
    their own versions back out of here, and so do pyk.ml, module.ml and
    execution.ml. See docs/targets.md.

    The table itself is private: a caller asks what a name means
    (`resolve`), what a target belongs to (`family_of`) and what it
    produces (`extension`) rather than reading rows.

    Data structures:
      family -- which backend a target belongs to.

    Functions:
      all -- every target, in the order the usage message lists them.
      default -- the target `pyk compile` uses when none is given.
      aliases -- each unversioned name and the version it means.
      resolve name -- the canonical target a name means, if any.
      family_of target -- the family a canonical target belongs to.
      members family -- a family's targets, oldest version first.
      extension target -- what the primary output file is called.
      version target -- the version a target's name says.
      es_edition target -- the ECMAScript edition a JavaScript target
        emits. *)

(** Which backend compiles a target, and so which targets share an
    emission. *)
type family = Python | Node | Web | Iweb | C | Java | Ocaml | Pyking

(** Every target, in the order the usage message lists them.
    [string] *)
val all : string list

(** What `pyk compile` picks when `--target` says nothing. string *)
val default : string

(** Each unversioned name and the version it means: a family's default.
    [(string, string)] *)
val aliases : (string * string) list

(** The canonical target a name means -- itself if it is already one, or
    what an alias points at. None for a name that is neither.
    string -> string option *)
val resolve : string -> string option

(** The family a canonical target belongs to. Raises Invalid_argument
    for a name that is not one. string -> family *)
val family_of : string -> family

(** A family's targets, oldest version first, so the last is the latest.
    family -> [string] *)
val members : family -> string list

(** What a target's primary output file is called. Raises
    Invalid_argument for a name that is not a target. string -> string *)
val extension : string -> string

(** What a target's name says after its family's: its version, "" for
    one without. Raises Invalid_argument for a name that is not a
    target. string -> string *)
val version : string -> string

(** The ECMAScript edition a JavaScript target emits: 2020 or 2024.
    string -> int *)
val es_edition : string -> int
