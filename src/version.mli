(** The compiler's version, read from the VERSION file at the root of the
    repository when the executable is built (see src/dune). `pyk
    --version` prints it, and the packages in tools/packaging/ are named
    by it. See docs/build.md ("Packaging").

    Functions:
      version -- the version, as VERSION writes it. *)

(** The version, as VERSION writes it, e.g. "0.1.0". string *)
val version : string
