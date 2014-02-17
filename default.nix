{ cabal, async, blazeBuilder, extensibleEffects, snap, websocketsSnap, pipes
, pipesConcurrency
}:
cabal.mkDerivation (self: {
  pname = "snaplet-socketio";
  version = "1.0.0";
  src = ./.;
  buildDepends = [ async blazeBuilder extensibleEffects snap websocketsSnap pipes pipesConcurrency ];
})