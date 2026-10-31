(** What may be written where the cursor is: the parts of completion the
    language server (lsp.ml) and the REPL (repl_session.ml) share. Each
    works the candidates out from what it knows; this says which word is
    being completed, which names are never offered, and what the
    candidates have in common. See docs/repl.md, "Completion".

    Functions:
      word_before line col -- the word ending at col, and its `m.`.
      qualifier line col -- the `m` of an `m.` before the cursor, dotted
        where a submodule is named, as in `m.sub.`.
      hidden name -- whether a pass made the name up.
      module_position line col -- whether a module's name is written
        there: after `import`, or right after `from`.
      library_modules -- the standard library's modules.
      matching prefix candidates -- the candidates starting with prefix.
      common_prefix names -- what every name starts with. *)

(** Whether c may be part of a name; `:` too, for `int::abs` and the
    REPL's meta-commands. char -> bool *)
let word_char c =
  match c with 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | ':' -> true | _ -> false

(** Where the word ending at i starts. string -> int -> int *)
let rec back line i = if i > 0 && word_char line.[i - 1] then back line (i - 1) else i

(** The word that ends at column `col` of `line`: where it starts, the
    text so far, and the module written before it with a `.`, if any.
    string -> int -> (int, string, string?) *)
let word_before line col =
  let col = max 0 (min col (String.length line)) in
  let start = back line col in
  let prefix = String.sub line start (col - start) in
  let module_ =
    if start > 0 && line.[start - 1] = '.' then
      let stop = start - 1 in
      let first = back line stop in
      if first < stop then Some (String.sub line first (stop - first)) else None
    else None
  in
  (start, prefix, module_)

(** The qualifier written before the cursor, as in `m.` or `m.pa`, if
    there is one, with the submodules in it: `m.sub.` is `m.sub`.
    string -> int -> string? *)
let qualifier line col =
  let start, _, module_ = word_before line col in
  match module_ with
  | None -> None
  | Some _ ->
      let rec chain stop =
        let first = back line stop in
        if first > 0 && line.[first - 1] = '.' && back line (first - 1) < first - 1 then chain (first - 1)
        else String.sub line first (start - 1 - first)
      in
      Some (chain (start - 1))

(** Whether a name was made up by a pass rather than written: a default
    argument's helper, an elaborated overload. string -> bool *)
let hidden name = Desugar_args.generated_name name || Elaborate.generated_name name

(** Whether s starts with prefix. string -> string -> bool *)
let starts_with prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

(** Whether the cursor is where a module's name is written: in the list
    after `import` (`import io, ma`), or the one word after `from`
    (`from ti`) -- not after `as`, nor after `from m import`, where the
    names written are the module's own. string -> int -> bool *)
let module_position line col =
  let before = String.sub line 0 (max 0 (min col (String.length line))) in
  let rec skip s i = if i < String.length s && (s.[i] = ' ' || s.[i] = '\t') then skip s (i + 1) else i in
  let text = let i = skip before 0 in String.sub before i (String.length before - i) in
  let after keyword =
    let k = String.length keyword in
    if String.length text > k && String.sub text 0 k = keyword && (text.[k] = ' ' || text.[k] = '\t') then
      let i = skip text k in
      Some (String.sub text i (String.length text - i))
    else None
  in
  let name s = String.for_all (fun c -> word_char c || c = '.') s in
  match after "import" with
  | Some rest -> List.for_all (fun part -> name (String.trim part)) (String.split_on_char ',' rest)
  | None -> ( match after "from" with Some rest -> name rest | None -> false)

(** The standard library's modules, read from lib/ when the compiler
    was built (src/dune). [string] *)
let library_modules = Library_modules.names

(** The candidates whose name starts with prefix, each once, in
    alphabetical order, leaving out hidden names.
    string -> [(string, string?)] -> [(string, string?)] *)
let matching prefix candidates =
  candidates
  |> List.filter (fun (name, _) -> starts_with prefix name && not (hidden name))
  |> List.sort_uniq (fun (a, _) (b, _) -> compare a b)
  |> List.fold_left
       (fun out (name, detail) ->
         match out with (n, _) :: _ when n = name -> out | _ -> (name, detail) :: out)
       []
  |> List.rev

(** The longest text every name starts with. [string] -> string *)
let common_prefix names =
  match names with
  | [] -> ""
  | first :: rest ->
      let rec shared n =
        if n < String.length first && List.for_all (fun s -> String.length s > n && s.[n] = first.[n]) rest
        then shared (n + 1)
        else n
      in
      String.sub first 0 (shared 0)
