# Pyking built from source, as a function for nixpkgs' callPackage:
#
#   pkgs.callPackage ./tools/packaging/nix/default.nix { }
#
# flake.nix beside this file does that for every system. The build is the
# repository's own -- `make build` and `pyk plugins lib` -- and the tree
# installed is the one every package ships (packaging.py's `stage`), in
# libexec/pyking, with bin/pyk a wrapper that names this OCaml as
# $OCAMLOPT so a program's own external module compiles its plugin.
#
# The browser libraries the notebook and the playground load are fetched
# here by hash, since a build has no network. Their versions and file
# lists are tools/webrun/server.py's, and tests/test_packaging.py holds
# the two to each other.
{ lib
, stdenv
, fetchurl
, ocamlPackages
, python3
, makeWrapper
}:

let
  root = ../../..;

  ace = "1.43.4";
  katex = "0.16.22";
  monaco = "0.57.0";

  aceFiles = {
    "ace.js" = "sha256-GCjoJTZasXOZFJ2XJjzmugCJiaF8VuHU8DZEkbjvtIs=";
    "ext-searchbox.js" = "sha256-75wukoVRj6Xha29z0lxGTs4aVB7WOH2kRJv4ptkT6YI=";
    "mode-python.js" = "sha256-iOugfGH1Fo6+9UMj9uLTH34SnAWVTqaqWjsKBKKwOq0=";
    "mode-javascript.js" = "sha256-Efoa/DFlOm9I90K7t8tSzywW+aC1V8v54voObBl/fxQ=";
    "mode-c_cpp.js" = "sha256-IYi4zBAjHML8/Pfw/d56k5H7te1p67oKHnuBiUXN1uo=";
    "mode-java.js" = "sha256-XAEZ3xCZd3VzjpjaX2InjfiJFQcbqU4s9Q05feRANw8=";
    "mode-html.js" = "sha256-W8+m4QId7ODT5m7M3V1iK/nCaRfkLlU1g6UvIWqlzOE=";
    "mode-ocaml.js" = "sha256-jGhVACaLz6S2TogTnhpiZdmW99hNM8U4UShpw5xzgms=";
    "mode-sh.js" = "sha256-CBJSKkgWc30pqJtgHbf41gOtGAn9NM0lox8A07cxqlQ=";
    "mode-json.js" = "sha256-AQ/qtz/XXPze4wzccb3Mho5PkURlpZpxQcXuSYOor+w=";
    "theme-tomorrow.js" = "sha256-uU+w+r0N/jMNYWhnZUoU2pjO8mHh1o3EsBiTe2aiDQk=";
    "theme-tomorrow_night.js" = "sha256-dX+wF/D/em8rR/MKP/e9YhFSnezuvweQnUZHrhF1o4o=";
  };

  katexFiles = {
    "katex.min.js" = "sha256-6NiFUFlJ86X0q91d0NU2lr0Tca0m/79PMQ3Nd8jNrok=";
    "katex.min.css" = "sha256-GQlRJzV+1tKf4KY6awAMkTqJ9/GWO3Zd03Fel8mFLnU=";
    "fonts/KaTeX_AMS-Regular.woff2" = "sha256-DN04fJWQoan5eUVgAi27WWVKfYbxh6oMgUla1C06cwg=";
    "fonts/KaTeX_Caligraphic-Bold.woff2" = "sha256-3ncB5Czx9M8LdmwD+yeXcgfu4vT9XXb6ghiEBtpD6kw=";
    "fonts/KaTeX_Caligraphic-Regular.woff2" = "sha256-XVPnCtYHwjUhYt7J4JI/tU7Nr6zL9gTNjc99APrLmJs=";
    "fonts/KaTeX_Fraktur-Bold.woff2" = "sha256-dERO/Vk8AF4/RXO0RSRwTArwqTf+kRzKnpQGjQ0UDT8=";
    "fonts/KaTeX_Fraktur-Regular.woff2" = "sha256-UYFNJw0G/wJV26B5mZT6TYyE0R8JlR1HWV9Kux82Atw=";
    "fonts/KaTeX_Main-Bold.woff2" = "sha256-D2DRuJeTjskYyM4HMJJBG6+UOPZzlGVpP/GLD50gsCE=";
    "fonts/KaTeX_Main-BoldItalic.woff2" = "sha256-mc1Co8By2Rjy9EmEqAfPeqFuE1Rf0IdfwHxsZfmecVs=";
    "fonts/KaTeX_Main-Italic.woff2" = "sha256-l0ecpszpBqvJYeyslvql+couYbjnZw1HWCa83umnwmc=";
    "fonts/KaTeX_Main-Regular.woff2" = "sha256-wjQs2Lhp4BdSqTIdwXIT/EDU0Ex5aIwdQ/LPMWq9eGY=";
    "fonts/KaTeX_Math-BoldItalic.woff2" = "sha256-3Ec0TbtstbZVyEYNVh9N9fUBuQyAStPGzsZf4yI1GrE=";
    "fonts/KaTeX_Math-Italic.woff2" = "sha256-evWMXsjxMqLd3pAnxteBTezOTTuCKhEZKkKiDi6XMmQ=";
    "fonts/KaTeX_SansSerif-Bold.woff2" = "sha256-6ZrlEUS/EjLvzBv+Wt02JixoZrD6qyT6dXQOG5hXemI=";
    "fonts/KaTeX_SansSerif-Italic.woff2" = "sha256-ALJqyCXiCVBWOW4FU7isJtP4rRWMOCbii0xFs4XEcUo=";
    "fonts/KaTeX_SansSerif-Regular.woff2" = "sha256-aOjHPvQq/TzOxYvw+6MCzORIk45/wCCl4x+KlS7uE0I=";
    "fonts/KaTeX_Script-Regular.woff2" = "sha256-A21OlRSbaf+bzAzVV3Hv6yX/o5Ryk+aazXjVrDKMaEs=";
    "fonts/KaTeX_Size1-Regular.woff2" = "sha256-a0fEAWa22+IaXfyncYQT8hR/0jmb4bpgXYrTnO3yXf4=";
    "fonts/KaTeX_Size2-Regular.woff2" = "sha256-0ExUIZ+ersbU1P1C37KHhZdaR5TWsvxx5Wa5zW24Qt0=";
    "fonts/KaTeX_Size3-Regular.woff2" = "sha256-c9WRJxsWBJYMsQu5D+4CFnCvcpcBfg6YSAszLRH1GZU=";
    "fonts/KaTeX_Size4-Regular.woff2" = "sha256-pK99QURAocF5CCXPtwDPnPQ7DyxLBPDrxSMBGtmFPsA=";
    "fonts/KaTeX_Typewriter-Regular.woff2" = "sha256-cdUX1ngneHz6vfGGkUzDNY7aU543kxlB8rL9SiH2jAs=";
  };

  monacoTarball = fetchurl {
    url = "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${monaco}.tgz";
    hash = "sha256-PqFxL7rNMpDPR1EAfjpbV8wnl2dgeBLUw+V5JfsLBcI=";
  };

  # Each vendored file copied to tools/webrun/vendor/<directory>/<path>.
  copies = directory: base: files: lib.concatStrings (lib.mapAttrsToList (path: hash: ''
    install -D -m 644 ${fetchurl { url = "${base}/${path}"; inherit hash; }} tools/webrun/vendor/${directory}/${path}
  '') files);

  # What is not source: what a build in the checkout leaves behind.
  generated = [ "_build" "build" "share" "pyk" "website" "temp" ".git"
                "tools/webrun/vendor" "tools/packaging/build" "tools/site/build"
                "tools/site/node_modules" "tools/editors/vscode/node_modules" ];
in
stdenv.mkDerivation {
  pname = "pyking";
  version = lib.fileContents (root + "/VERSION");

  src = lib.cleanSourceWith {
    src = root;
    filter = path: type:
      let relative = lib.removePrefix (toString root + "/") (toString path);
      in !(lib.elem relative generated)
         && !(lib.hasSuffix "~" relative)
         && baseNameOf relative != "__pycache__";
  };

  nativeBuildInputs = [
    ocamlPackages.ocaml
    ocamlPackages.findlib
    ocamlPackages.dune_3
    ocamlPackages.js_of_ocaml-compiler
    python3
    makeWrapper
  ];

  strictDeps = true;
  # The tree is installed as every package ships it: nbverify.py and the
  # help's scripts keep `#!/usr/bin/env python3`.
  dontPatchShebangs = true;

  postPatch = ''
    ${copies "ace" "https://cdn.jsdelivr.net/npm/ace-builds@${ace}/src-min-noconflict" aceFiles}
    ${copies "katex" "https://cdn.jsdelivr.net/npm/katex@${katex}/dist" katexFiles}
    mkdir -p tools/webrun/vendor/monaco
    tar -xzf ${monacoTarball} -C tools/webrun/vendor/monaco --strip-components=2 package/min/vs
    python3 -c 'import json; print(json.dumps({"version": "${monaco}", "from": "${monacoTarball.url}", "kept": "package/min/vs/"}, indent=2))' \
      > tools/webrun/vendor/monaco/monaco-editor-${monaco}.json
  '';

  buildPhase = ''
    runHook preBuild
    export DUNE_CACHE=disabled
    make build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    python3 tools/packaging/packaging.py stage --binary pyk --dest $out/libexec/pyking
    $out/libexec/pyking/pyk plugins $out/libexec/pyking/lib
    mkdir -p $out/bin
    makeWrapper $out/libexec/pyking/pyk $out/bin/pyk \
      --set-default OCAMLOPT ${ocamlPackages.ocaml}/bin/ocamlopt \
      --suffix PATH : ${lib.makeBinPath [ stdenv.cc ]}
    runHook postInstall
  '';

  meta = {
    description = "Compiler and interpreter for Pyking, a small statically typed Python-like language";
    homepage = "https://github.com/pyking-lang/pyking";
    license = lib.licenses.mit;
    mainProgram = "pyk";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
