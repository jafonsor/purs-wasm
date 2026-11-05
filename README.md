# purs-wasm

The PureScript compiler (v0.15.16, plus a small patch) compiled to WebAssembly so it can run in a
browser, and the GHC that builds it. Everything is built from pinned sources by Nix, entirely in
GitHub Actions, and published as a GitHub Release.

In plain words: the compiler itself is a `.wasm` file. Building it needs a special GHC (the Haskell
compiler) that targets WebAssembly and does not use the GPL-licensed `gmp` library. That GHC takes
hours to build, so this repo builds it once, shrinks it, and releases both, so nobody else has to.

## What each release asset is

| File | What it is |
|---|---|
| `purs-core.wasm` | The compiler core (`purs-core`): reads `.purs` files, writes JavaScript. About 23 MB, about 2.3 MB with brotli. Runs under any WASI host (Node, browser with a WASI shim). Usage: `purs-core <output dir> <file.purs>...` |
| `purs-core.wasm.sha256` | Its checksum, `sha256sum` format. |
| `ghc-wasm-native-x86_64-linux.tar.xz` | The pruned wasm GHC install (about 85 MB; about 650 MB unpacked), for rebuilding `purs-core.wasm` without the multi-hour GHC build. See the limits below. |
| `ghc-wasm-native-x86_64-linux.tar.xz.sha256` | Its checksum. |
| `BUILDINFO.json` | Versions and commits of GHC, PureScript, nixpkgs, ghc-wasm-meta; sizes and checksums; build date (the date of the tagged commit, not the clock); the tag and workflow run. |

The wasm is built with the **full** GHC. The pruned GHC is also checked to give the identical wasm
(same sha256) in every run (`purs-core-wasm-from-pruned`, check `pruned-same-wasm`).

## The wasm is not reproducible across GHC builds

The same sources give different `purs-core.wasm` bytes with different GHC builds. type-solution
measured 23,625,988 bytes (macOS build of GHC), 23,585,103 bytes (Docker build on Linux) and
23,516,000 bytes (a third install). The same GHC install gives the same wasm every time (full and
pruned installs gave the same sha256 on the Mac). So **the release is the source of truth**: consumers
pin the sha256 of a release asset, they do not rebuild and compare.

## For a consumer (type-solution): fetch the wasm

```nix
purs-core-wasm = pkgs.fetchurl {
  url = "https://github.com/jafonsor/purs-wasm/releases/download/v0.15.16-1/purs-core.wasm";
  hash = "sha256-...";   # sha256 of the asset, as SRI: nix hash convert --hash-algo sha256 --to sri <hex>
};
```

Get the hash from `purs-core.wasm.sha256` (hex) or from `BUILDINFO.json`. Without Nix:

```sh
curl -fLO https://github.com/jafonsor/purs-wasm/releases/download/v0.15.16-1/purs-core.wasm
echo "<hex>  purs-core.wasm" | sha256sum -c
node test/smoke.mjs purs-core.wasm      # from this repo: compiles a module, checks the JavaScript
```

## For a developer: the pruned GHC

```sh
mkdir ghc && curl -fL https://github.com/jafonsor/purs-wasm/releases/download/v0.15.16-1/ghc-wasm-native-x86_64-linux.tar.xz | tar -C ghc -xJ
export PATH=$PWD/ghc/bin:$PATH
wasm32-wasi-ghc --version
```

**Honest limits of this tarball** (it is a copy of a Nix build output, not a portable distribution):

- `lib/settings` hard-codes the store path of the wasi-sdk (the haskell-wasm fork of it: its `wasm-ld`
  carries a patch GHC needs for Template Haskell). GHC has no variable for this. The wasi-sdk therefore
  has to exist at that exact `/nix/store/...-wasi-sdk` path: on a machine with Nix,
  `nix build github:jafonsor/purs-wasm#wasi-sdk` (same flake.lock) puts it there. Anywhere else, run
  `bin/ghc-wasm-native-set-wasi-sdk /path/to/the/fork` once; this rewrites the path in `lib/settings`
  (untested outside Nix).
- The wrappers in `bin/` also point at `node` and at the npm packages Template Haskell needs, by store
  path. `NODE_PATH` and the node on `PATH` can be overridden by setting them first.
- The host programs (`ghc`, `ghc-pkg`, `hsc2hs`) are ELF files linked against a Nix glibc: on a
  Linux without that store path they will not start. They need the same store paths too.

So the tarball helps people who have Nix (or can copy the store paths) and want to skip building GHC.
Making it truly portable (patchelf, bundling the wasi-sdk) is not done. Nix users should prefer
`nix build github:jafonsor/purs-wasm#ghc-wasm-native-pruned` (fetched from the binary cache if you have it,
otherwise built).

## What the pruning does

`nix/prune.nix` copies the full install and removes what building purs-core does not use, following
type-solution's measurement (research 12, 4116 MB to 663 MB on macOS):

- drops profiling libraries (`*_p.a`, `*_p-ghc*.so`, `*.p_hi`, `*.p_dyn_hi`) and the debug RTS
- drops the `ghc`, `ghc-toolchain`, `hpc` packages and `haddock` with `haddock-api`, `haddock-library`,
  `xhtml`; drops `html`/`doc`/`latex`
- replaces identical host binaries by symlinks
- keeps `Cabal`, `Cabal-syntax` (cabal's solver needs them), `ghc-heap`, `ghc-platform`, every `.so`
  (Template Haskell) and every `.dyn_hi` (the build uses `shared: True`)

That was measured on aarch64-darwin only, so the derivation checks itself on Linux: `ghc-pkg check` must
report nothing broken, the kept packages must still be registered, and the output must not mention the
full install's store path. Then `checks.<system>.pruned-smoke` compiles and links a Template Haskell
program (which also imports Cabal, ghc-heap, ghc-platform) with it in about a minute, and
`purs-core-wasm-from-pruned` rebuilds purs-core with it and `pruned-same-wasm` demands the same sha256.
All three run in CI before anything is released.

## Flake attributes

`packages.x86_64-linux` is the release target and the one that matters. `aarch64-linux`,
`aarch64-darwin` and `x86_64-darwin` evaluate but are not built in CI (macOS was only exercised with the
hand-made install from type-solution ticket 14).

| Attribute | |
|---|---|
| `ghc-wasm-native` | The full gmp-free wasm GHC 9.14 (`perf+native_bignum`), from source at a pinned commit. Hours. |
| `ghc-wasm-native-pruned` | The pruned copy, minutes. |
| `purs-core-wasm` | `purs-core.wasm` with the full GHC. About 15 min on top of GHC. |
| `purs-core-wasm-from-pruned` | The same with the pruned GHC. |
| `release-assets` | The five release files in one directory. |
| `wasi-sdk` | The wasi-sdk fork the GHC is configured with. |
| `checks.<system>.pruned-smoke`, `pruned-same-wasm` | Verification of the pruned install. |

Everything is pinned: `flake.lock` (committed) fixes nixpkgs (nixos-26.05, the same revision as
type-solution) and `ghc-wasm-meta`; every other fetch (GHC source, purescript, cborg, 118 Hackage
tarballs, cheapskate) is hash-pinned in `nix/`. Nothing reaches the network inside a build.

## Cut a release

1. Commit; the workflow `Build` must have passed on `main` (run it from the Actions tab,
   "Run workflow").
2. Tag and push: `git tag v0.15.16-1 && git push origin v0.15.16-1`. The tag name is free as long
   as it starts with `v`; convention here is the PureScript version plus a build counter.
3. The workflow builds, runs the smoke test under Node, and creates the GitHub Release with the five
   files. Re-pushing the same tag (after deleting and re-creating it) replaces the files.

A manual run (`workflow_dispatch`) does everything except the release; the files are in the run's
artifact `release-assets`.

### Time and limits

- Cold GHC: expect 1.5 to 3 h on a 4-core runner (type-solution measured 2 h 54 min under emulation on a
  Mac). Then about 15 min each for the two purs-core builds, a few minutes for pruning and xz. The job
  limit is 6 h. If a cold run could exceed it, run the workflow by hand with "Only build GHC": it stops
  after `ghc-wasm-native`, and a second run fetches it from the cache.
- Disk: the runner has about 14 GB free; the step "Free disk space" removes about 30 GB of preinstalled
  software. The GHC build tree is large; if the build still runs out of disk, the next step is
  moving `/nix` to `/mnt`.
- Cache: `magic-nix-cache` stores what is built in the GitHub Actions cache, limited to 10 GB per
  repository with least-recently-used eviction. The compressed GHC alone is about 1 GB, but everything
  else (wasi-sdk 373 MB, node, cabal, the pruned copy) adds up; the step summary shows whether the GHC
  was BUILT or FETCHED. A tag build is only able to read the cache of its own tag ref and of the
  default branch, so run the workflow on `main` first to warm it.

## Build locally

With Nix (flakes enabled) on x86_64-linux:

```sh
nix build .#purs-core-wasm            # hours the first time (GHC), then minutes
nix build .#release-assets && ls result/
```

Elsewhere, an x86_64-linux container reproduces what CI does (this is how type-solution's ticket 27 was
built on a Mac; with Rosetta emulation the GHC took 2 h 54 min):

```sh
docker run --rm --platform linux/amd64 --privileged --cpus=4 --memory=16g \
  -v "$PWD":/src -w /src \
  nixos/nix:2.35.4@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0 \
  sh -c 'echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf &&
         git config --global --add safe.directory /src &&
         nix build --accept-flake-config -L .#purs-core-wasm && cp -L result/purs-core.wasm .'
```

(`--privileged` for the Nix sandbox.)

The smoke test needs only Node 20 or later: `node test/smoke.mjs path/to/purs-core.wasm`.

## Layout

- `flake.nix`, `flake.lock`: pinned inputs and outputs.
- `nix/ghc-wasm-native.nix`: the GHC. `nix/prune.nix`, `nix/pruned-smoke.nix`: the pruned install and
  its check. `nix/purs-core.nix` with `nix/purescript/`: the compiler (`purescript.patch`,
  `cheapskate.patch`, `hackage.json`, `purs-core-Main.hs`). `nix/release-assets.nix`: the release files.
- `.github/workflows/build.yml`, `scripts/plan.sh`, `test/smoke.mjs`.

## Licensing

This repository's own license is not chosen yet.

What the assets contain, each under its own license:

- GHC and its libraries (`base`, `containers`, ...): BSD-3-Clause. This GHC is built with the native
  bignum backend, so the wasm and the pruned install contain no `gmp` (LGPL/GPL); that is the reason
  for building GHC at all.
- PureScript: BSD-3-Clause (patched, `nix/purescript/purescript.patch`).
- `cborg` (BSD-3-Clause) from a pinned git commit, `cheapskate` (BSD-3-Clause, patched), and the other
  Hackage packages in `nix/purescript/hackage.json`, each under the license on Hackage.
- The wasi-sdk fork (Apache-2.0 with LLVM exceptions; `wasi-libc` is under its own permissive licenses) is
  used to build, and its libc is linked into the wasm; the pruned GHC tarball does not contain it.
- The release does not include the license texts of the Hackage packages linked into the wasm: a
  redistributor should add them (TODO).
