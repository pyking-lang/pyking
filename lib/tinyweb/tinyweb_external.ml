(* The OCaml implementation of the names declared in
   tinyweb_external.pyk, which is how the interpreter runs a tinyweb
   program in a terminal: headless. Nothing is drawn and nothing is
   played. Where $PYKING_PAGE_LOG names a file, each command the
   program sends the page is written there as one line, and where
   $PYKING_PAGE_EVENTS names a file, the events it lists are delivered
   once the program's top level has ended -- which is how a tinyweb
   program is tested. The lines are the ones tinyweb_external_node.js
   and the browser implementation write; see docs/libraries.md,
   "Testing a page". *)

let log_file = Sys.getenv_opt "PYKING_PAGE_LOG"

let write line =
  match log_file with
  | None -> ()
  | Some path ->
      let channel =
        Stdlib.open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path
      in
      Stdlib.output_string channel (line ^ "\n");
      Stdlib.close_out channel

let quote text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | c -> Buffer.add_char buffer c)
    text;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let seconds x = Printf.sprintf "%.3f" x
let command words = write (String.concat " " words)
let last = ref 0
let fresh () = incr last; !last
let clock = ref 0.0

let buttons : (int * (unit -> unit)) list ref = ref []
let sliders : (int * (int -> unit)) list ref = ref []
let frames : (float -> unit) list ref = ref []
let mice : (int * (int -> int -> unit)) list ref = ref []
let keys : (string -> unit) list ref = ref []

let canvas width height =
  let id = fresh () in
  command [ "canvas"; string_of_int id; string_of_int width; string_of_int height ];
  id

let fill_canvas c color = command [ "clear"; string_of_int c; color ]

let draw_circle c x y radius color =
  command [ "circle"; string_of_int c; string_of_int x; string_of_int y; string_of_int radius; color ]

let draw_rect c x y width height color =
  command
    [ "rect"; string_of_int c; string_of_int x; string_of_int y; string_of_int width;
      string_of_int height; color ]

let draw_line c x1 y1 x2 y2 color width =
  command
    [ "line"; string_of_int c; string_of_int x1; string_of_int y1; string_of_int x2;
      string_of_int y2; color; string_of_int width ]

let draw_text c x y words color size =
  command
    [ "text"; string_of_int c; string_of_int x; string_of_int y; color; string_of_int size;
      quote words ]

let make_button title on_click =
  let id = fresh () in
  command [ "button"; string_of_int id; quote title ];
  buttons := !buttons @ [ (id, on_click) ];
  id

let label text =
  let id = fresh () in
  command [ "label"; string_of_int id; quote text ];
  id

let set_label id text = command [ "set_label"; string_of_int id; quote text ]

let make_slider low high value on_change =
  let id = fresh () in
  command
    [ "slider"; string_of_int id; string_of_int low; string_of_int high; string_of_int value ];
  sliders := !sliders @ [ (id, on_change) ];
  id

let load_sample name =
  let id = fresh () in
  command [ "load"; string_of_int id; quote name ];
  id

let play_sample sample at volume rate =
  command [ "play"; string_of_int sample; seconds at; seconds volume; seconds rate ]

let time () = !clock

let on_frame draw =
  command [ "on_frame" ];
  frames := !frames @ [ draw ]

let on_mouse c click =
  command [ "on_mouse"; string_of_int c ];
  mice := !mice @ [ (c, click) ]

let on_key pressed =
  command [ "on_key" ];
  keys := !keys @ [ pressed ]

(* One event from the events file: its line, as the page would send it. *)
let deliver line =
  let words = List.filter (fun w -> w <> "") (String.split_on_char ' ' line) in
  let each table id f = List.iter (fun (key, g) -> if key = id then f g) table in
  match words with
  | [] -> ()
  | _ when String.length line > 4 && String.sub line 0 4 = "key " ->
      write ("> " ^ line);
      List.iter (fun f -> f (String.sub line 4 (String.length line - 4))) !keys
  | _ -> (
      write ("> " ^ line);
      match words with
      | [ "click"; id ] -> each !buttons (int_of_string id) (fun f -> f ())
      | [ "slide"; id; value ] ->
          each !sliders (int_of_string id) (fun f -> f (int_of_string value))
      | [ "frame"; t ] ->
          clock := float_of_string t;
          List.iter (fun f -> f !clock) !frames
      | [ "mouse"; c; x; y ] ->
          each !mice (int_of_string c) (fun f -> f (int_of_string x) (int_of_string y))
      | _ -> write ("! unknown event: " ^ line))

let () =
  match Sys.getenv_opt "PYKING_PAGE_EVENTS" with
  | Some path when Sys.file_exists path ->
      Pyk_plugin.after_program (fun () ->
          let channel = Stdlib.open_in path in
          let rec lines acc =
            match Stdlib.input_line channel with
            | line -> lines (line :: acc)
            | exception End_of_file -> List.rev acc
          in
          let all = lines [] in
          Stdlib.close_in channel;
          List.iter deliver all)
  | _ -> ()
