(** "Did you mean": the name a misspelled one was most likely meant to
    be, out of the names that were there to be meant. One rule for every
    message that offers one -- the parser's for a misspelled keyword,
    the checker's for an unbound name, the language server's quick fix
    -- so they never disagree about what is close.

    Functions:
      distance a b -- the edits that make a into b.
      near name -- how many edits a name may be from what it meant.
      closest name candidates -- the candidates near name, closest
        first. *)

(** The edits that make a into b: a character inserted, removed or
    changed, or two neighbours swapped (`retrun` is one from `return`).
    string -> string -> int *)
let distance a b =
  let m = String.length a and n = String.length b in
  let d = Array.make_matrix (m + 1) (n + 1) 0 in
  for i = 0 to m do d.(i).(0) <- i done;
  for j = 0 to n do d.(0).(j) <- j done;
  for i = 1 to m do
    for j = 1 to n do
      let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
      let best =
        min (min (d.(i - 1).(j) + 1) (d.(i).(j - 1) + 1)) (d.(i - 1).(j - 1) + cost)
      in
      let best =
        if i > 1 && j > 1 && a.[i - 1] = b.[j - 2] && a.[i - 2] = b.[j - 1] then
          min best (d.(i - 2).(j - 2) + 1)
        else best
      in
      d.(i).(j) <- best
    done
  done;
  d.(m).(n)

(** How many edits a name may be from the one it was meant to be: none
    in a one-letter name, where any letter is one edit from any other,
    one in a short name, where two would make anything look like
    anything, and a little more the longer the name is. string -> int *)
let near name =
  let length = String.length name in
  if length <= 1 then 0 else if length <= 3 then 1 else 2 + (length / 8)

(** The candidates near name, closest first, and alphabetical among
    equally close ones; name itself is not one. Case is not an edit:
    `Print` is as close to `print` as a name gets.
    string -> [string] -> [string] *)
let closest name candidates =
  let lower = String.lowercase_ascii name in
  candidates
  |> List.sort_uniq compare
  |> List.filter_map (fun candidate ->
         if candidate = name then None
         else
           let d =
             if String.lowercase_ascii candidate = lower then 0
             else distance name candidate
           in
           if d <= near name then Some (d, candidate) else None)
  |> List.sort compare |> List.map snd
