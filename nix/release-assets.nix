# The exact files a GitHub Release carries (and nothing else):
#
#   purs-core.wasm                           built with the full GHC
#   purs-core.wasm.sha256
#   ghc-wasm-native-<system>.tar.xz          the pruned install, xz -9e -T0
#   ghc-wasm-native-<system>.tar.xz.sha256
#   BUILDINFO.json                           versions, commits, sizes, date
#
# Nothing here reads the clock: the date is the date of the commit being built
# (flake `lastModifiedDate`), so a rebuild of the same tag gives the same
# files. CI adds the tag name to BUILDINFO.json afterwards (a tag is not known
# to a pure build); the checksums files do not cover BUILDINFO.json.
{ pkgs, system, provenance, purs-core-wasm, ghc, ghc-pruned }:

let
  tarball = "ghc-wasm-native-${system}.tar.xz";
  # 20261105150823 -> 2026-11-05T15:08:23Z
  d = provenance.commitDate;
  isoDate = "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
    + "T${builtins.substring 8 2 d}:${builtins.substring 10 2 d}:${builtins.substring 12 2 d}Z";
in

pkgs.runCommand "purs-wasm-release-assets"
{
  nativeBuildInputs = [ pkgs.gnutar pkgs.xz pkgs.jq pkgs.coreutils ];
  # xz -T0 with -9e wants about 3.4 GB; nothing to substitute for a few minutes.
  buildInfo = builtins.toJSON {
    schema = 1;
    inherit system;
    buildDate = isoDate; # the commit's date, not the clock's
    flakeRev = provenance.flakeRev;
    ghc = {
      version = ghc.version;
      commit = "8c11f10506b88beb05d9f98de1d7dcb3e449e259";
      source = "https://gitlab.haskell.org/haskell-wasm/ghc.git (branch ghc-9.14)";
      flavour = "perf+native_bignum (no gmp)";
    };
    purescript = {
      version = purs-core-wasm.version;
      commit = "4c66c05a59a08b698ba5c34b48e8bf7744ecb9f6";
      tag = "v${purs-core-wasm.version}";
    };
    nixpkgsRev = provenance.nixpkgsRev;
    ghcWasmMetaRev = provenance.ghcWasmMetaRev;
    wasiSdk = ghc.wasi-sdk.name;
    nodejs = ghc.nodejs.name;
  };
  passAsFile = [ "buildInfo" ];
} ''
  mkdir $out
  cd $out

  cp ${purs-core-wasm}/purs-core.wasm purs-core.wasm

  # Reproducible tar: sorted, no owners, no timestamps; writable once extracted.
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=u+w \
    -C ${ghc-pruned} -cf - . | xz -9e -T0 > ${tarball}

  sha256sum purs-core.wasm > purs-core.wasm.sha256
  sha256sum ${tarball} > ${tarball}.sha256

  jq --sort-keys \
    --argjson wasmBytes "$(stat -c %s purs-core.wasm)" \
    --argjson tarBytes "$(stat -c %s ${tarball})" \
    --argjson prunedInstalledBytes "$(du -sb ${ghc-pruned} | cut -f1)" \
    --argjson fullInstalledBytes "$(du -sb ${ghc} | cut -f1)" \
    --arg wasmSha "$(cut -d' ' -f1 purs-core.wasm.sha256)" \
    --arg tarSha "$(cut -d' ' -f1 ${tarball}.sha256)" \
    '. + {assets: {
        "purs-core.wasm": {bytes: $wasmBytes, sha256: $wasmSha},
        "${tarball}": {bytes: $tarBytes, sha256: $tarSha,
                       installedBytes: $prunedInstalledBytes, fullInstalledBytes: $fullInstalledBytes}}}' \
    $buildInfoPath > BUILDINFO.json
  ls -l
''
