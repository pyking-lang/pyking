
open Printf

type row = int
type col = int
type info =
  | Info of string * row * col * row * col

(* Token types *)
type token =
  | TokInt of int
  | TokString of string
  | TokAdd         (* '+' user defined *)
  | TokSub         (* '-' user defined *)
  | TokMul         (* '*' user defined *)
  | TokDiv         (* '/' user defined *)
  | TokLessThanEq  (* '<=' *)
  | TokLessThan    (* '<' *)
  | TokGreatThanEq (* '>=' *)
  | TokGreatThan   (* '>' *)
  | TokEqEq        (* '==' *)
  | TokColon       (* ':' *)
  | TokEq          (* '=' *)
  | TokLParen      (* '(' *)
  | TokRParen      (* ')' *)
  | TokDot         (* '.' *)
  | TokComma       (* ',' *)
  | TokDef         (* 'def' *)
  | TokReturn         (* 'return' *)
  | TokIdent of string


let pprint_token = function
  | TokInt(x) -> sprintf "TokInt(%d)" x
  | TokString(s) -> sprintf "TokString('%s')" s
  | TokAdd -> "TokAdd"
  | TokSub -> "TokSub"
  | TokMul -> "TokMul"
  | TokDiv -> "TokDiv"
  | TokLessThanEq -> "TokLessThanEq"
  | TokLessThan -> "TokLessThan"
  | TokGreatThanEq -> "TokGreatThanEq"
  | TokGreatThan -> "TokGreatThan"
  | TokEqEq -> "TokEqEq"
  | TokColon -> "TokColon"
  | TokEq -> "TokEq"
  | TokLParen -> "TokLParen"
  | TokRParen -> "TokRParen"
  | TokDot -> "TokDot"
  | TokComma -> "TokComma"
  | TokDef -> "TokDef"
  | TokReturn -> "TokReturn"
  | TokIdent(s) -> sprintf "TokIdent('%s')" s

let pprint_info = function
    Info(x, r1, c1, r2, c2) ->
    sprintf "'%s' %d:%d-%d:%d" x r1 c1 r2 c2
