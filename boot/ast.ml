
open Printf

type row = int
type col = int
type info =
  | Info of string * row * col * row * col

(* Token types *)
type token =
  | TokInt of int
  | TokColon       (* ':' *)
  | TokEq          (* '=' *)
  | TokLParen      (* '(' *)
  | TokRParen      (* ')' *)
  | TokDef         (* 'def' *)
  | TokDot         (* '.' *)
  | TokIdent of string


let pprint_token = function
  | TokInt(x) -> sprintf "TokInt(%d)" x
  | TokColon -> "TokColon"
  | TokEq -> "TokEq"
  | TokLParen -> "TokLParen"
  | TokRParen -> "TokRParen"
  | TokDef -> "TokDef"
  | TokDot -> "TokDot"
  | TokIdent(s) -> sprintf "TokIdent('%s')" s
