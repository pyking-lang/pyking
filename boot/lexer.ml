
open Printf
open Ast

(*
  Lexer for Pyking. What is still missing:
  - Escape handling of characters within strings
*)

let len = String.length

(* Returns longest string prefix matching predicate 'pred' *)
let string_until pred lst =
  let retv a xs = (List.rev a |> List.to_seq |> String.of_seq, xs) in
  let rec work acc = function
    | x::xs -> if pred x then work (x::acc) xs else retv acc (x::xs)
    | [] -> retv acc []
  in work [] lst

(* Predefined predicates *)
let is_digit x = x >= '0' && x <= '9'
let is_letter x = (x == '_') || (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z')
let is_digit_letter x = is_digit x || is_letter x
let skip xs = match xs with x::xs -> xs | _ -> failwith "Unexpected end"

(* Lexing a list of characters into a list of tokens *)
let lexing file lst =
  let fi r c l = Info(file, r, c, r, c + l) in
  let rec work acc r c = function
    (* Integer *)
    | x::xs when is_digit x ->
       let (y,ys) = string_until is_digit (x::xs) in
       work ((fi r c (len y), TokInt(int_of_string y))::acc) r (c + len y) ys
    (* Line comment *)
    | '#'::xs ->
       let (_,ys) = string_until (fun x -> x <> '\n') xs in
       work acc (r + 1) 0 ys
    (* String *)
    | ('\'' as s)::xs | ('"' as s)::xs ->
       let (str, ys) = string_until (fun x -> x <> s) xs in
       let l = 2 + len str in
       work ((fi r c l, TokString(str))::acc) r (c + l) (skip ys)
    (* Operators that are user defined in real pyking *)
    | '+'::xs -> work ((fi r c 1, TokAdd)::acc) r (c + 1) xs
    | '-'::xs -> work ((fi r c 1, TokSub)::acc) r (c + 1) xs
    | '*'::xs -> work ((fi r c 1, TokMul)::acc) r (c + 1) xs
    | '/'::xs -> work ((fi r c 1, TokDiv)::acc) r (c + 1) xs
    | '<'::'='::xs -> work ((fi r c 2, TokLessThanEq)::acc) r (c + 2) xs
    | '<'::xs -> work ((fi r c 1, TokLessThan)::acc) r (c + 1) xs
    | '>'::'='::xs -> work ((fi r c 2, TokGreatThanEq)::acc) r (c + 2) xs
    | '>'::xs -> work ((fi r c 1, TokGreatThan)::acc) r (c + 1) xs
    | '='::'='::xs -> work ((fi r c 2, TokEqEq)::acc) r (c + 2) xs
    (* Language lex items *)
    | ':'::xs -> work ((fi r c 1, TokColon)::acc) r (c + 1) xs
    | '='::xs -> work ((fi r c 1, TokEq)::acc) r (c + 1) xs
    | '('::xs -> work ((fi r c 1, TokLParen)::acc) r (c + 1) xs
    | ')'::xs -> work ((fi r c 1, TokRParen)::acc) r (c + 1) xs
    | '.'::xs -> work ((fi r c 1, TokDot)::acc) r (c + 1) xs
    | ','::xs -> work ((fi r c 1, TokComma)::acc) r (c + 1) xs
    | ' '::xs -> work acc r (c + 1) xs
    | '\n'::xs -> work acc (r + 1) 0 xs
    (* Keywords and identifiers *)
    | x::xs when is_letter x ->
       let (y,ys) = string_until is_digit_letter (x::xs) in
       let l = len y in
       (match y with
        | "def" -> work ((fi r c l, TokDef)::acc) r (c + l) ys
        | "return" -> work ((fi r c l, TokReturn)::acc) r (c + l) ys
        | x -> work ((fi r c l, TokIdent(x))::acc) r (c + l) ys)
    | [] -> List.rev acc
    | x::_ -> failwith (sprintf "Toking error: unknown character '%c'." x)
  in
  work [] 1 0 lst
