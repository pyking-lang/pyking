(** The examples `pyk example` lists and saves and the playground offers,
    read from src/examples.toml: each a test program, the name it is
    saved as, and one line saying what it does. See docs/pyk.md
    ("Examples").

    Data structures:
      example -- one entry of the list.

    Functions:
      read text -- the entries of examples.toml.
      find name examples -- the entry saved as name.
      listing examples -- the list as a table, one example per line. *)

type example = {
  source : string;  (** the program's path from the tree's root *)
  name : string;  (** the file it is saved as *)
  description : string;  (** one line *)
}

(** Where the list is, from the tree's root. *)
val file : string

(** The entries of examples.toml: each `[[examples]]` table's `source`,
    `name` and `description`. An entry missing one is left out.
    string -> [example] *)
val read : string -> example list

(** The example saved as name, if there is one. string -> [example] ->
    example? *)
val find : string -> example list -> example option

(** The list as a table under the headings "File name" and
    "Description", ruled off with dashes, one example per line.
    [example] -> string *)
val listing : example list -> string
