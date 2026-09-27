(** Where this installation of pyk keeps what ships beside it: the
    standard library in lib/, the compiler as JavaScript in build/, and
    the web tools in tools/. Found from the running executable with
    every symbolic link resolved, so a `pyk` reached through a link --
    Homebrew's bin/pyk is one -- finds the directory it was installed
    in, not the directory of the link. See docs/build.md ("What a
    distribution needs").

    Functions:
      root () -- the directory holding the executable. *)

let root () =
  let executable = Module.absolute Sys.executable_name in
  let resolved = try Unix.realpath executable with Unix.Unix_error _ -> executable in
  Module.dirname resolved
