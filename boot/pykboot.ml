

open Printf
open Ast
open Lexer


let main =
  let len = in_channel_length stdin in
  let data = really_input_string stdin len in
  let lst = List.init len (String.get data) in
  lst |> lexing |> List.map pprint_token
        |> String.concat " | " |> printf "%s\n"
