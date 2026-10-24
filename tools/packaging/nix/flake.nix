# Pyking built from source with Nix, on Linux and macOS:
#
#   nix run 'github:pyking-lang/pyking/release-<version>?dir=tools/packaging/nix' -- hello.pyk
#
# The package is default.nix beside this file, called with this flake's
# nixpkgs (pinned by flake.lock).
{
  description = "Compiler and interpreter for Pyking, a small statically typed Python-like language";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (system: rec {
        pyking = nixpkgs.legacyPackages.${system}.callPackage ./default.nix { };
        default = pyking;
      });
    };
}
