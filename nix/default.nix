# Everything this repo builds, for one system.
#
# Everything is pinned: fetches are fixed-output (hashes), nothing reaches the
# network inside a build (the Nix sandbox enforces it on Linux).
#
#   ghc-wasm-native             the gmp-free wasm GHC 9.14 (flavour
#                               perf+native_bignum), built from the
#                               haskell-wasm/ghc fork at a pinned commit.
#                               Hours to build; cached on its own.
#   ghc-wasm-native-pruned      a copy of it without what purs-core does not
#                               use (research 12): about 1/6 of the size.
#   purs-core-wasm              purs-core.wasm: pinned upstream purescript
#                               v0.15.16 plus nix/purescript/purescript.patch,
#                               built with the FULL GHC. The release's wasm.
#   purs-core-wasm-from-pruned  the same build with the pruned GHC; must give
#                               the same bytes (check pruned-same-wasm).
#   release-assets              the files a GitHub Release carries.
#
# The GHC derivation reads no file of this repo except nix/ghc-wasm-native.nix
# itself (through the evaluator, not as a build input), so a change anywhere
# else (README, workflow, smoke test, release-assets) leaves its derivation
# path unchanged.
{ pkgs
, system
# Source tree of haskell-wasm/ghc-wasm-meta (flake input, pinned by flake.lock):
# gives the wasi-sdk fork, the Node packages Template Haskell needs, cabal.
, ghcWasmMeta
# { flakeRev, commitDate, nixpkgsRev, ghcWasmMetaRev } for BUILDINFO.json.
, provenance
}:

rec {
  ghc-wasm-native = import ./ghc-wasm-native.nix { inherit pkgs ghcWasmMeta; };
  inherit (ghc-wasm-native) wasi-sdk;

  ghc-wasm-native-pruned = import ./prune.nix { inherit pkgs; ghc = ghc-wasm-native; };

  purs-core-wasm = import ./purs-core.nix {
    inherit pkgs ghcWasmMeta;
    ghc = ghc-wasm-native;
  };

  purs-core-wasm-from-pruned = (import ./purs-core.nix {
    inherit pkgs ghcWasmMeta;
    ghc = ghc-wasm-native-pruned;
    # The pruned install's wrappers put node on PATH themselves; this is only
    # for the shebangs of lib/dyld.mjs (`env -S node ...`).
    extraNativeBuildInputs = [ ghc-wasm-native.nodejs ];
  }).overrideAttrs (_: { pname = "purs-core-wasm-from-pruned"; });

  pruned-smoke = import ./pruned-smoke.nix { inherit pkgs; ghc = ghc-wasm-native-pruned; };

  # Cheap: two files compared. The expensive part is building the second wasm.
  pruned-same-wasm = pkgs.runCommand "pruned-same-wasm" { } ''
    a=$(sha256sum ${purs-core-wasm}/purs-core.wasm | cut -d' ' -f1)
    b=$(sha256sum ${purs-core-wasm-from-pruned}/purs-core.wasm | cut -d' ' -f1)
    echo "full GHC:   $a"
    echo "pruned GHC: $b"
    [ "$a" = "$b" ] || { echo "pruning changed purs-core.wasm"; exit 1; }
    echo "$a" > $out
  '';

  release-assets = import ./release-assets.nix {
    inherit pkgs system provenance purs-core-wasm;
    ghc-pruned = ghc-wasm-native-pruned;
    ghc = ghc-wasm-native;
  };
}
