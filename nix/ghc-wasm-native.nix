# The gmp-free wasm GHC 9.14, built from source.
#
# Recipe: type-solution's ticket 14 (ghc-native-build.sh and
# ghc-native-install.sh), packaged by its ticket 27. Source: the `ghc-9.14`
# branch of haskell-wasm/ghc, pinned to a commit. Flavour `perf+native_bignum`, no
# `--with-intree-gmp`, so the compiler and what it builds link no gmp.
#
# The only inputs are fixed-output fetches and pinned nixpkgs/ghc-wasm-meta
# packages. Nothing here may mention a repo path outside this file, or the
# derivation would change when unrelated files do.
#
# `ghcWasmMeta` is the ghc-wasm-meta flake input (flake = false) as a source
# tree. The `passthru` below is what prune.nix and release-assets.nix use.
{ pkgs, ghcWasmMeta }:

let
  inherit (pkgs) lib stdenv;

  rev = "8c11f10506b88beb05d9f98de1d7dcb3e449e259";
  version = "9.14.1.20261012"; # the VERSION file at that commit

  src = pkgs.fetchgit {
    url = "https://gitlab.haskell.org/haskell-wasm/ghc.git";
    inherit rev;
    fetchSubmodules = true;
    hash = "sha256-0bo6rC3JdJ1uF0J1I3UkynqBpanvB+yeD8jeau8R0OU=";
  };

  # The wasi-sdk fork (clang, wasm-ld with the haskell-wasm patch, libffi-wasm).
  wasi-sdk = pkgs.callPackage "${ghcWasmMeta}/pkgs/wasi-sdk.nix" { };
  nodejs = pkgs.nodejs_latest;
  npm-deps = pkgs.callPackage "${ghcWasmMeta}/pkgs/npm-deps.nix" { inherit nodejs; };

  # Stage 0: the GHC that nixpkgs bootstraps its own GHC 9.14 with, and the
  # hadrian build system built from this very source tree (as nixpkgs does).
  bootPkgs = pkgs.haskell.packages.ghc9103;
  hadrian = import "${pkgs.path}/pkgs/development/tools/haskell/hadrian/make-hadrian.nix"
    { inherit bootPkgs lib; }
    { ghcSrc = src; ghcVersion = "9.14.1"; };

  buildPlatform = stdenv.buildPlatform.config;
in

stdenv.mkDerivation {
  pname = "ghc-wasm-native";
  inherit version src;

  nativeBuildInputs = [
    hadrian
    bootPkgs.alex
    bootPkgs.happy
    pkgs.autoconf
    pkgs.automake
    pkgs.m4
    pkgs.perl
    pkgs.python3
    pkgs.makeWrapper
    # The bindist's configure writes node into the shebangs of lib/dyld.mjs and
    # lib/post-link.mjs (`env -S node ...`); without node on PATH it writes
    # nothing, and Template Haskell fails with "env: unrecognized option".
    nodejs
  ];
  # Stage 0's ghc is not declared here (its setup hook would add its lib
  # directory to the linker flags); configure is told where it is via $GHC.
  # Stage 0 builds terminfo, so it needs ncurses.
  buildInputs = [ pkgs.ncurses ];
  strictDeps = true;

  postPatch = ''
    patchShebangs .
    # GHC's source tree is a git checkout minus .git: boot generates configure.
    # configure derives the snapshot version from these when there is no
    # .git (else from today's date, which would make the build depend on the
    # day it runs): the commit's date and id.
    echo 20261012 > VERSION_DATE
    echo ${rev} > GIT_COMMIT_ID
    ./boot
  '';

  # What the build (and the bindist install) needs to know about the wasm
  # toolchain: the same values ghc-wasm-meta's wasi-sdk setup hook exports.
  # Not taken from the hook itself, which also points CC at wasm clang for
  # the stage-0 build.
  preConfigure = ''
    export HOME=$TMPDIR
    # hsc2hs and haddock read UTF-8 sources: a plain C locale fails with
    # "cannot encode character".
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    SDK=${wasi-sdk}
    export AR=$SDK/bin/llvm-ar CC=$SDK/bin/wasm32-wasi-clang CC_FOR_BUILD=cc \
      CXX=$SDK/bin/wasm32-wasi-clang++ LD=$SDK/bin/wasm-ld NM=$SDK/bin/llvm-nm \
      OBJCOPY=$SDK/bin/llvm-objcopy OBJDUMP=$SDK/bin/llvm-objdump \
      RANLIB=$SDK/bin/llvm-ranlib SIZE=$SDK/bin/llvm-size \
      STRINGS=$SDK/bin/llvm-strings STRIP=$SDK/bin/llvm-strip
    export CONF_CC_OPTS_STAGE2="-Wno-error=int-conversion -O3 -mcpu=lime1 -mreference-types -msimd128"
    export CONF_CXX_OPTS_STAGE2="-fno-exceptions -Wno-error=int-conversion -O3 -mcpu=lime1 -mreference-types -msimd128"
    export CONF_GCC_LINKER_OPTS_STAGE2="-Wl,--error-limit=0,--keep-section=ghc_wasm_jsffi,--keep-section=target_features,--stack-first,--strip-debug "
    unset CONFIGURE_ARGS
    export GHC=${bootPkgs.ghc}/bin/ghc
  '';

  # configure by hand: the generic one would add --prefix and --build/--host
  # for the wasm target.
  dontUseCcConfigure = true;
  configurePhase = ''
    runHook preConfigure
    ./configure --target=wasm32-wasi --with-system-libffi
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    hadrian -j$NIX_BUILD_CORES --flavour=perf+native_bignum --docs=none binary-dist-dir
    runHook postBuild
  '';

  # Install the bindist: its configure writes lib/settings from CONF_*_STAGE2,
  # and the link flags also need -fuse-ld=<wasi-sdk>/bin/wasm-ld (without it
  # clang picks a plain LLVM wasm-ld that lacks the haskell-wasm patch
  # splitting __wasm_apply_data_relocs; Template Haskell then fails to load
  # big shared libraries).
  installPhase = ''
    runHook preInstall
    export CONF_GCC_LINKER_OPTS_STAGE2="-fuse-ld=$SDK/bin/wasm-ld $CONF_GCC_LINKER_OPTS_STAGE2"
    cd _build/bindist/ghc-${version}-wasm32-wasi || { ls _build/bindist; exit 1; }
    ./configure --prefix=$out --build=${buildPlatform} --host=${buildPlatform} --target=wasm32-wasi
    make install RelocatableBuild=YES
    cd ../../..
    runHook postInstall
  '';

  # Template Haskell runs through node, with its npm packages.
  postInstall = ''
    wrapProgram $out/bin/wasm32-wasi-ghc \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --set-default NODE_PATH ${npm-deps}/lib/node_modules/@haskell-wasm/ghc-wasm-npm-deps/node_modules
    wrapProgram $out/bin/wasm32-wasi-ghc-${version} \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --set-default NODE_PATH ${npm-deps}/lib/node_modules/@haskell-wasm/ghc-wasm-npm-deps/node_modules
    grep -q -- '-fuse-ld=${wasi-sdk}/bin/wasm-ld' $out/lib/settings
  '';

  dontFixup = true;
  enableParallelBuilding = true;

  passthru = { inherit wasi-sdk nodejs npm-deps src hadrian; };

  meta.description = "GHC ${version} wasm32-wasi cross compiler, native (gmp-free) bignum";
}
