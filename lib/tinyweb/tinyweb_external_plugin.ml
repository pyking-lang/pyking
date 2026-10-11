(* What joins tinyweb_external.ml to the interpreter, compiled into its
   plugin after it (src/plugin_host.ml). A compiled program runs
   `after_program` from `at_exit`; under the interpreter it runs when
   the program's top level has ended instead, where a runtime error in a
   callback is reported like any other, and the REPL serves the page
   while it waits for a line. The samples are in tinyweb_assets/ beside
   the library rather than beside `pyk`. This file is the one part of
   the implementation a compiled program does not need, which is why it
   is apart: it names Pyk_plugin, which only `pyk` has. *)

let () =
  Tinyweb_external.hosted := true;
  (match Pyk_plugin.directory "tinyweb" with
  | Some directory ->
      Tinyweb_external.assets :=
        Filename.concat directory "tinyweb_assets" :: !Tinyweb_external.assets
  | None -> ());
  Pyk_plugin.after_program Tinyweb_external.after_program;
  Pyk_plugin.on_idle
    (fun () -> List.map Obj.repr (Tinyweb_external.descriptors ()))
    Tinyweb_external.handle
