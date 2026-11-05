# purs-core.wasm: the PureScript compiler's core, for a browser worker or any
# WASI host (test/smoke.mjs runs it under Node).
#
# Pinned upstream purescript v0.15.16 plus nix/purescript/purescript.patch
# (drops the cryptonite/memory hashing, monad-logger, ide/interactive/publish,
# adds the `purs-core` executable), built with the gmp-free wasm GHC.
# Entry point: nix/purescript/purs-core-Main.hs.
#
# Closed box: every Hackage package is a fixed-output fetch listed in
# purescript/hackage.json (name, version, sha256 of the tarball: the plan
# type-solution's ticket 14 build solved); cabal reads them from a local `file+noindex`
# repository and never touches the network.
{ pkgs, ghcWasmMeta, ghc
# Only for trying this derivation with another wasm GHC (a bindist that
# finds its wasm clang through PATH).
, extraNativeBuildInputs ? [ ]
}:

let
  inherit (pkgs) lib;

  purescript = pkgs.fetchFromGitHub {
    owner = "purescript";
    repo = "purescript";
    rev = "4c66c05a59a08b698ba5c34b48e8bf7744ecb9f6"; # tag v0.15.16
    hash = "sha256-a71w1M36PQ/cZxe1VZH0vamL7Hjxs7YQDhQD6hHdOLQ=";
  };

  # cborg 0.2.10.0 from git: the Hackage release does not build for wasm32
  # (merge of well-typed/cborg `palas-wasm-fix`, 2026-05-13).
  cborg = pkgs.fetchFromGitHub {
    owner = "well-typed";
    repo = "cborg";
    rev = "6ef2791ca41b397a3e36c868ad3e66a0d09f19b2";
    hash = "sha256-KWmRYTnYHqrPi4OLr83pqz59KB+nDWS19Pu8ZCjFzZc=";
  };

  # cheapskate 0.1.1.2 needs one import under GHC 9.14 (cheapskate.patch).
  cheapskate = pkgs.fetchurl {
    url = "https://hackage.haskell.org/package/cheapskate-0.1.1.2/cheapskate-0.1.1.2.tar.gz";
    hash = "sha256-7TdIl8OTkfz3YFUuZGje85/jbDGFcIyoMFZmDKOixp4=";
  };

  hackage = pkgs.linkFarm "purs-core-hackage" (map
    (p: {
      name = "${p.name}-${p.version}.tar.gz";
      path = pkgs.fetchurl {
        url = "https://hackage.haskell.org/package/${p.name}-${p.version}/${p.name}-${p.version}.tar.gz";
        sha256 = p.sha256;
      };
    })
    (builtins.fromJSON (builtins.readFile ./purescript/hackage.json)));

  # Files of this repo enter the build one by one, each as its own store
  # path (a plain ./path would be a path inside the whole flake source).
  file = name: path: builtins.path { inherit name path; };
  purescriptPatch = file "purescript.patch" ./purescript/purescript.patch;
  cheapskatePatch = file "cheapskate.patch" ./purescript/cheapskate.patch;
  pursCoreMain = file "purs-core-Main.hs" ./purescript/purs-core-Main.hs;

  cabal = pkgs.callPackage "${ghcWasmMeta}/pkgs/cabal.nix" { };

  cabalProject = pkgs.writeText "cabal.project" ''
    packages: purescript/purescript.cabal
              cheapskate
              cborg/cborg
    allow-newer: all
    constraints: purescript -release
    shared: True
    library-for-ghci: False
  '';

in

pkgs.stdenvNoCC.mkDerivation {
  pname = "purs-core-wasm";
  version = "0.15.16";

  dontUnpack = true;

  nativeBuildInputs = [
    ghc
    cabal
    pkgs.happy
    pkgs.alex
    pkgs.gnumake
    pkgs.patch
    pkgs.gnutar
    pkgs.gzip
  ] ++ extraNativeBuildInputs;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    # Sources have non-ASCII text (happy, hsc2hs, ghc read them as UTF-8).
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    export CABAL_DIR=$TMPDIR/cabal
    mkdir -p $CABAL_DIR
    # cabal writes an index cache into a noindex repository: copy it.
    cp -rL ${hackage} $TMPDIR/hackage
    chmod -R u+w $TMPDIR/hackage
    cat > $CABAL_DIR/config <<EOF
    repository purs-core-hackage
      url: file+noindex://$TMPDIR/hackage
    EOF

    mkdir work
    cd work
    cp -r ${purescript} purescript
    cp -r ${cborg} cborg
    chmod -R u+w purescript cborg
    tar xzf ${cheapskate}
    mv cheapskate-0.1.1.2 cheapskate

    patch -d purescript -p1 < ${purescriptPatch}
    patch -d cheapskate -p1 < ${cheapskatePatch}
    mkdir purescript/app-core
    cp ${pursCoreMain} purescript/app-core/Main.hs

    # The patch drops happy from build-tool-depends (cabal would build it for
    # wasm and could not run it): generate the parser with a native happy.
    happy -agc purescript/src/Language/PureScript/CST/Parser.y \
      -o purescript/src/Language/PureScript/CST/Parser.hs
    rm purescript/src/Language/PureScript/CST/Parser.y

    cp ${cabalProject} cabal.project
    cabal \
      --with-compiler=wasm32-wasi-ghc \
      --with-hc-pkg=wasm32-wasi-ghc-pkg \
      --with-hsc2hs=wasm32-wasi-hsc2hs \
      build exe:purs-core -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    wasm=$(find dist-newstyle -type f -path '*/x/purs-core/build/purs-core/purs-core.wasm')
    test -n "$wasm"
    cp "$wasm" $out/purs-core.wasm
    runHook postInstall
  '';

  dontFixup = true;

  meta.description = "PureScript 0.15.16 compiler core as a wasm32-wasi module";
}
