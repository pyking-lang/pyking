(* A canvas, two circles, two samples and buttons that play them, written
   in OCaml against tinyweb.ml. Build it with
     ocamlopt -I +unix unix.cmxa tinyweb.mli tinyweb.ml example.ml -o example
   then run ./example and open the address it prints. *)

let () =
  Tinyweb.web_init 0;
  let kick = Tinyweb.load_sample "kick1.wav" in
  let snare = Tinyweb.load_sample "snare1.wav" in
  let canvas = Tinyweb.canvas 400 200 in
  Tinyweb.draw_circle canvas 100 50 30 "#ff0000";
  Tinyweb.draw_circle canvas 100 50 20 "#000000";
  let presses = ref 0 in
  ignore (Tinyweb.make_button "Play kick" (fun () -> Tinyweb.play_sample kick 0.0 1.0 1.0));
  ignore
    (Tinyweb.make_button "Play snare" (fun () ->
         incr presses;
         Printf.printf "snare, press %d\n" !presses;
         Tinyweb.play_sample snare 0.0 0.5 1.0));
  ignore (Tinyweb.make_button "Does nothing" (fun () -> ()));
  print_endline "built the page"
