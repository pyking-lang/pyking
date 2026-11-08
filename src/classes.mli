(** What a backend needs to know of a module's classes and interfaces
    (PYKING.md, "Classes and interfaces"), read from their declarations
    once the checker has accepted them. *)

open Syntax

module SMap : Map.S with type key = string

(** One field, its own class's: a header field that only passes an
    inherited one on is not one of these. *)
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
  parent_args : (string option * expr) list;
  parent_sym : int; (* the checker recorded the parent, at its type arguments, there *)
  interfaces : (string * int) list;
  header : (string * int) list; (* what the constructor takes, in order, with symbols *)
  own_header : string list; (* the header's fields that are this class's own *)
  fields : field list; (* this class's own fields *)
  methods : meth list;
  decl : class_decl;
  info : Lexer.info;
}

type table = cls SMap.t

(** The classes and interfaces these statements declare. *)
val table : stmt list -> table

(** The class or interface of this name. *)
val find : table -> string -> cls option

(** Every supertype, itself first: the class chain, then each interface
    reached from it, nearest first. *)
val supers : table -> string -> string list

(** Every field an object of the class has, its parents' first. *)
val all_fields : table -> string -> field list

(** The class declaring a field reached on this class. *)
val field_owner : table -> string -> string -> string option

(** That field. *)
val field_of : table -> string -> string -> field option

(** The method of this name a class or interface declares itself. *)
val own_method : table -> string -> string -> meth option

(** The class or interface whose body runs for a method on an object of
    this class: the class chain first, then interfaces' defaults. *)
val resolve : table -> string -> string -> string option

(** Where a method is first declared, at the class or above it. *)
val declaring : table -> string -> string -> string option

(** Whether a class declares or inherits a method of this name. *)
val has_method : table -> string -> string -> bool

(** Every method a value of the class has, by name. *)
val method_names : table -> string -> string list

(** Whether another class or interface of the program builds on this one. *)
val extended : table -> string -> bool

(** Every interface an object of the class is, nearest first. *)
val interfaces : table -> string -> string list

(** Every class and interface these statements declare, each after what
    it names and otherwise in the order written. *)
val ordered : table -> stmt list -> string list
