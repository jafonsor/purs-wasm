# Check that the pruned install still does what building purs-core needs,
# in about a minute instead of the 15 minutes of purs-core-wasm-from-pruned:
#
#   - Template Haskell runs (loads shared libraries through node and dyld.mjs)
#   - the Cabal library is there (cabal's solver needs it for purescript)
#   - ghc-heap and ghc-platform are there (ghc-boot depends on them)
#   - the package database is usable, and the compiler links a wasm module
#
# Research 12 found each of these broken by a wrong deletion (no .so: TH
# fails; no Cabal: the solver fails; no .dyn_hi: `shared: True` fails).
{ pkgs, ghc }:

pkgs.runCommand "pruned-smoke"
{
  nativeBuildInputs = [ ghc ghc.nodejs ];
} ''
  export HOME=$TMPDIR LANG=C.UTF-8 LC_ALL=C.UTF-8
  mkdir work && cd work
  cat > Main.hs <<'HS'
  {-# LANGUAGE TemplateHaskell #-}
  module Main (main) where

  import Distribution.Version (mkVersion, versionNumbers)
  import GHC.Exts.Heap (GenClosure)
  import GHC.Platform.ArchOS (ArchOS)
  import Language.Haskell.TH (litE, integerL)

  main :: IO ()
  main = do
    -- evaluated at compile time, by running code in the wasm interpreter
    print ($(litE (integerL (product [1 .. 20]))) :: Integer)
    print (versionNumbers (mkVersion [9, 14]))
  HS
  wasm32-wasi-ghc -package Cabal -package ghc-heap -package ghc-platform \
    Main.hs -o main.wasm
  test -s main.wasm
  mkdir $out
  cp main.wasm $out/
  wasm32-wasi-ghc-pkg list --simple-output > $out/packages.txt
''
