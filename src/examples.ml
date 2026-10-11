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
let file = "src/examples.toml"

(** The text between a value's first and last double quote, or None.
    string -> string? *)
let quoted value =
  match (String.index_opt value '"', String.rindex_opt value '"') with
  | Some first, Some last when last > first -> Some (String.sub value (first + 1) (last - first - 1))
  | _ -> None

(** The entries of examples.toml: each `[[examples]]` table's `source`,
    `name` and `description`. An entry missing one is left out.
    string -> [example] *)
let read text =
  let finish table acc =
    match table with
    | Some (Some source, Some name, Some description) -> { source; name; description } :: acc
    | _ -> acc
  in
  let rec go lines table acc =
    match lines with
    | [] -> List.rev (finish table acc)
    | line :: rest -> (
        let line = String.trim line in
        if line = "[[examples]]" then go rest (Some (None, None, None)) (finish table acc)
        else
          match (table, String.index_opt line '=') with
          | Some (source, name, description), Some i when line.[0] <> '#' -> (
              let value = quoted (String.sub line (i + 1) (String.length line - i - 1)) in
              match String.trim (String.sub line 0 i) with
              | "source" -> go rest (Some (value, name, description)) acc
              | "name" -> go rest (Some (source, value, description)) acc
              | "description" -> go rest (Some (source, name, value)) acc
              | _ -> go rest table acc)
          | _ -> go rest table acc)
  in
  go (String.split_on_char '\n' text) None []

(** The example saved as name, if there is one. string -> [example] ->
    example? *)
let find name examples = List.find_opt (fun e -> e.name = name) examples

(** The list as a table under the headings "File name" and
    "Description", ruled off with dashes, one example per line.
    [example] -> string *)
let listing examples =
  let widest heading field = List.fold_left (fun w e -> max w (String.length (field e))) (String.length heading) examples in
  let names = widest "File name" (fun e -> e.name) in
  let descriptions = widest "Description" (fun e -> e.description) in
  let row name description = Printf.sprintf "%s%s%s\n" name (String.make (names + 2 - String.length name) ' ') description in
  String.concat ""
    (row "File name" "Description"
    :: row (String.make names '-') (String.make descriptions '-')
    :: List.map (fun e -> row e.name e.description) examples)
