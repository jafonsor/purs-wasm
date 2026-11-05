{
  description = "The PureScript compiler for the browser: gmp-free wasm GHC and purs-core.wasm";

  inputs = {
    # The same nixpkgs (nixos-26.05) type-solution pins through nix-haskell.
    # Pinned by rev here and by hash in flake.lock (committed).
    nixpkgs.url = "github:NixOS/nixpkgs/6d65bfc1bcef2ef39a239d38e577e92a89fb0f07";

    # Upstream of the wasi-sdk fork, the npm packages Template Haskell needs
    # and cabal-install; only its pkgs/*.nix are used, so not a flake input.
    ghc-wasm-meta = {
      url = "github:haskell-wasm/ghc-wasm-meta/5b96779e3d356b3962b6e9c85a9db3a1fcc31ed1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, ghc-wasm-meta }:
    let
      lib = nixpkgs.lib;
      # x86_64-linux is the release target and the one that must be right; the
      # others are exposed because they cost nothing (not built in CI).
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      eachSystem = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      bundle = system: pkgs: import ./nix {
        inherit pkgs system;
        ghcWasmMeta = ghc-wasm-meta;
        # Provenance for BUILDINFO.json. lastModifiedDate is the commit's date
        # (the tagged commit in a release), never the build's.
        provenance = {
          flakeRev = self.rev or "dirty";
          commitDate = self.lastModifiedDate;
          nixpkgsRev = nixpkgs.rev;
          ghcWasmMetaRev = ghc-wasm-meta.rev;
        };
      };
    in
    {
      packages = eachSystem (system: pkgs:
        let b = bundle system pkgs; in {
          inherit (b)
            wasi-sdk
            ghc-wasm-native
            ghc-wasm-native-pruned
            purs-core-wasm
            purs-core-wasm-from-pruned
            release-assets;
          default = b.purs-core-wasm;
        });

      # `nix flake check` builds these; CI runs them explicitly after the
      # packages (they are the proof that the pruned install is good).
      checks = eachSystem (system: pkgs:
        let b = bundle system pkgs; in {
          inherit (b) pruned-smoke pruned-same-wasm;
        });

      devShells = eachSystem (system: pkgs: {
        # For working on the workflow and the smoke test.
        default = pkgs.mkShell {
          packages = [ pkgs.nodejs pkgs.actionlint pkgs.jq pkgs.xz ];
        };
      });
    };

  nixConfig = {
    extra-substituters = [ "https://cache.nixos.org" ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };
}
