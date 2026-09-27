(** Where this installation of pyk keeps what ships beside it: the
    standard library in lib/, the compiler as JavaScript in build/, and
    the web tools in tools/. Found from the running executable with
    every symbolic link resolved, so a `pyk` reached through a link --
    Homebrew's bin/pyk is one -- finds the directory it was installed
    in, not the directory of the link. See docs/build.md ("What a
    distribution needs").

    Functions:
      root () -- the directory holding the executable. *)

(** The directory holding the running executable, after resolving every
    symbolic link on the way to it. () -> string *)
val root : unit -> string
