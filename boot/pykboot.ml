

open Printf
open Ast
open Lexer


let main =
  if Array.length Sys.argv != 2 then (
    printf "Usage: pykboot <filename>\n";
    exit 1)
  else
    let filename = Array.get Sys.argv 1 in
    let ic = In_channel.open_text filename in
    let data = In_channel.input_all ic in
    In_channel.close ic;
    let len = String.length data in
    let lst = List.init len (String.get data) in
    lst
    |> lexing filename
    |> List.map (fun (fi,t) -> pprint_info fi ^ " " ^ pprint_token t)
    |> String.concat "\n"
    |> printf "%s\n"
