{ haskellPackages ? (import <nixpkgs> {}).haskellPackages }:
let
  pkgs = import <nixpkgs> {};

  inherit (haskellPackages) async blazeBuilder cabal cabalInstall_1_18_0_2 extensibleEffects snap websocketsSnap pipes pipesConcurrency;

in cabal.mkDerivation (self: {
  pname = "snaplet-socketio";
  version = "1.0.0";
  src = ./.;
  buildDepends = [ async blazeBuilder extensibleEffects snap websocketsSnap pipes pipesConcurrency ];
  buildTools = [ cabalInstall_1_18_0_2 pkgs.nodejs ];
})