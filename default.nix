{}:
with import <nixpkgs> {};
let
  inherit (haskellPackages) blazeBuilder cabal cabalInstall_1_18_0_2 extensibleEffects snap websocketsSnap ;

in cabal.mkDerivation (self: {
  pname = "snaplet-socketio";
  version = "1.0.0";
  src = ./.;
  buildDepends = [ blazeBuilder extensibleEffects snap websocketsSnap ];
  buildTools = [ cabalInstall_1_18_0_2 nodejs ];
})