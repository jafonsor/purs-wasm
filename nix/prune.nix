# The gmp-free wasm GHC without what building purs-core does not use.
#
# A SEPARATE, cheap derivation: it copies the (cached) full install and deletes
# files, so changing the recipe never rebuilds GHC. The recipe is the one
# measured in .scratch/other-languages/research/12-ghc-wasm-compression.md of
# type-solution (aarch64-darwin: 4116 MB -> 663 MB, same purs-core.wasm):
#
#   drop    profiling (*_p.a, *_p-ghc*.so, *.p_hi, *.p_dyn_hi) and rts debug
#   drop    the ghc, ghc-toolchain, hpc packages (library, .so, .conf)
#   drop    haddock and the packages only it needs (haddock-api/-library, xhtml)
#   drop    html/doc/latex
#   dedupe  identical host binaries become relative symlinks
#   KEEP    Cabal, Cabal-syntax (cabal's solver needs them), ghc-heap,
#           ghc-platform (ghc-boot depends on them), every .so (Template
#           Haskell) and every .dyn_hi (the build uses `shared: True`).
#
# Research 12 measured only the Mac layout, so nothing here assumes where
# packages live: it finds them by name with `find`. It verifies itself:
# `ghc-pkg check` must report nothing broken, the kept packages must still be
# registered, and the output must not mention the full install's store path.
# nix/pruned-smoke.nix then compiles a Template Haskell program with it, and
# purs-core-wasm-from-pruned builds purs-core with it (same sha256 required).
#
# Wrappers: the full install's bin/wasm32-wasi-ghc* are Nix wrappers that
# hard-code the full install's store path. They are replaced by wrappers that
# find the real binary next to themselves, so a copy of this output (the
# release tarball) works anywhere the Nix store paths it still references
# exist: node, the npm packages and the wasi-sdk (lib/settings hard-codes it),
# plus the glibc the host binaries were linked with. See README.md.
{ pkgs, ghc }:

let
  inherit (pkgs) lib;
  inherit (ghc) wasi-sdk nodejs npm-deps;
  nodePath = "${npm-deps}/lib/node_modules/@haskell-wasm/ghc-wasm-npm-deps/node_modules";
in

pkgs.runCommand "ghc-wasm-native-pruned-${ghc.version}"
{
  nativeBuildInputs = [ pkgs.findutils pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.patchelf ];
  # Cheap, but copying 3.4 GB: not worth substituting from anywhere else.
  allowSubstitutes = false;
  inherit (ghc) version;
  passthru = { inherit (ghc) wasi-sdk nodejs npm-deps; full = ghc; };
  meta.description = "ghc-wasm-native without profiling, ghc/hpc/haddock packages and duplicate binaries";
} ''
  set -eu
  cp -a ${ghc} $out
  chmod -R u+w $out
  cd $out
  size() { du -sm --apparent-size . | cut -f1; }
  echo "full install: $(size) MB"

  # cp -a keeps symlinks as they were: absolute ones into the full install
  # must point into this output instead.
  find . -type l -lname '${ghc}/*' | while read -r l; do
    t=$(readlink "$l")
    ln -sfn "$out/''${t#${ghc}/}" "$l"
  done

  # ---- host binaries: the linker put the full install's lib directory into
  # their RPATH (stdenv's self-rpath; dontFixup keeps it). Point it at this
  # output instead, or the closure would drag in the whole 3.4 GB install.
  # Done first, so binaries that only differed in it can be deduplicated.
  { grep -rlF '${ghc}' . || true; } | while read -r f; do
    if rp=$(patchelf --print-rpath "$f" 2>/dev/null) && [[ "$rp" == *'${ghc}'* ]]; then
      echo "rpath fix: $f: $rp"
      patchelf --set-rpath "''${rp//'${ghc}'/$out}" "$f"
    fi
  done

  # ---- documentation
  rm -rf share/doc share/man doc
  find lib -maxdepth 4 -type d \( -name html -o -name latex -o -name doc \) -prune -exec rm -rf {} +

  # ---- profiling and rts debug variants
  find . \( -name '*_p.a' -o -name '*_p-ghc*.so' -o -name '*.p_hi' -o -name '*.p_dyn_hi' \
            -o -name '*_debug*.a' -o -name '*_debug*.so' \) -delete

  # ---- the ghc library, ghc-toolchain, hpc, haddock and what only it needs
  dbs=$(find . -type d -name package.conf.d)
  test -n "$dbs" || { echo "no package.conf.d in the install"; exit 1; }
  drop='^(ghc|ghc-toolchain|hpc|haddock-api|haddock-library|xhtml)-[0-9]'
  for db in $dbs; do
    for conf in $(ls $db | grep -E "$drop" | grep '\.conf$' || true); do
      id=''${conf%.conf}
      name=$(echo "$id" | sed -E 's/-[0-9][0-9.]*(-[A-Za-z0-9]+)?$//')
      echo "dropping package $id"
      rm -f "$db/$conf"
      # library directories (ghc-9.14.1.xxx[-hash]) and libHS<name>-* files
      find lib \( -type d -name "$name-[0-9]*" -o -name "libHS$name-[0-9]*" \) -prune -exec rm -rf {} +
    done
  done
  rm -f bin/*haddock* bin/.*haddock*
  # a re-registered database needs a writable, fresh cache
  bin/wasm32-wasi-ghc-pkg recache
  broken=$(bin/wasm32-wasi-ghc-pkg check --simple-output 2>&1 || true)
  if [ -n "$broken" ]; then echo "broken packages after pruning: $broken"; exit 1; fi
  bin/wasm32-wasi-ghc-pkg list --simple-output > $TMPDIR/pkgs.txt
  cat $TMPDIR/pkgs.txt
  for keep in Cabal Cabal-syntax ghc-heap ghc-platform ghc-boot ghc-internal base template-haskell; do
    grep -qE "(^| )$keep-[0-9]" $TMPDIR/pkgs.txt || { echo "pruning lost $keep"; exit 1; }
  done
  for gone in ghc hpc haddock-api xhtml; do
    if grep -qE "(^| )$gone-[0-9]" $TMPDIR/pkgs.txt; then echo "$gone still registered"; exit 1; fi
  done

  # ---- wrappers: the real binaries are bin/.NAME-wrapped (wrapProgram)
  for real in bin/.*-wrapped; do
    [ -e "$real" ] || [ -L "$real" ] || continue
    n=''${real#bin/.}; n=''${n%-wrapped}
    rm -f bin/$n
    cat > bin/$n <<'WRAP'
  #!@shell@
  dir=$(dirname "$(readlink -f "$0")")
  export PATH="@node@/bin''${PATH:+:$PATH}"
  export NODE_PATH="''${NODE_PATH:-@nodePath@}"
  exec -a "$0" "$dir/.@name@-wrapped" "$@"
  WRAP
    sed -i \
      -e "s|@shell@|${pkgs.runtimeShell}|" \
      -e "s|@node@|${nodejs}|" \
      -e "s|@nodePath@|${nodePath}|" \
      -e "s|@name@|$n|" bin/$n
    chmod +x bin/$n
  done

  # ---- dedupe identical host binaries into relative symlinks
  declare -A seen
  for f in $(find bin -maxdepth 1 -type f -size +100k | sort -r); do
    h=$(sha256sum "$f" | cut -d' ' -f1)
    if [ -n "''${seen[$h]:-}" ]; then
      echo "dedupe $f -> $(basename "''${seen[$h]}")"
      rm "$f"; ln -s "$(basename "''${seen[$h]}")" "$f"
    else
      seen[$h]=$f
    fi
  done

  # ---- helper for a different wasi-sdk location (README: limitations)
  cat > bin/ghc-wasm-native-set-wasi-sdk <<'HELP'
  #!@shell@
  # usage: ghc-wasm-native-set-wasi-sdk /path/to/haskell-wasm/wasi-sdk
  # Rewrites the wasi-sdk path lib/settings hard-codes. Needs the haskell-wasm
  # fork of wasi-sdk (a plain one lacks the wasm-ld patch).
  set -eu
  dir=$(dirname "$(readlink -f "$0")")
  for s in $(find "$dir/.." -name settings -path '*lib*' -type f); do
    sed -i "s|@wasiSdk@|$1|g" "$s"
  done
  HELP
  sed -i -e "s|@shell@|${pkgs.runtimeShell}|" -e "s|@wasiSdk@|${wasi-sdk}|g" bin/ghc-wasm-native-set-wasi-sdk
  chmod +x bin/ghc-wasm-native-set-wasi-sdk

  # ---- the output must be independent of the full install
  leaks=$(grep -rlF '${ghc}' . || true)
  if [ -n "$leaks" ]; then
    echo "files that still name the full install (${ghc}):"
    for f in $leaks; do
      echo "== $f"
      echo "   rpath: $(patchelf --print-rpath "$f" 2>&1 | head -c 300)"
      echo "   store paths in it:"
      grep -a -o '/nix/store/[a-z0-9]\{32\}-[A-Za-z0-9._+-]*' "$f" | sort | uniq -c | sort -rn | head -8
    done
    exit 1
  fi
  dangling=$(find . -xtype l)
  if [ -n "$dangling" ]; then echo "dangling symlinks: $dangling"; exit 1; fi

  echo "pruned install: $(size) MB"
''
