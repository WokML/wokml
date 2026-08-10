{
  description = "wok toolchains: pinned GCC, Clang and GHC for CI and local work";

  # Pinned to a COMMIT, not a branch. A branch ref resolves to whatever is
  # current at the moment CI runs, which is precisely the drift this file
  # exists to remove. Bump it deliberately, in its own commit.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f13ff45afd1bb73e640eaa08a7066dbed07e3238";

  outputs = { self, nixpkgs }:
    let
      # The three build targets: Linux on both architectures, plus the Apple
      # Silicon machine the language is actually developed on.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      lib = nixpkgs.lib;
    in
    {
      devShells = lib.genAttrs systems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        base = [ pkgs.gnumake ];
      in
      {
        # Two C shells rather than one holding both compilers: each toolchain
        # installs its own `cc`/`ld` wrapper, so with both on PATH which
        # compiler actually ran becomes a coin toss -- and this whole exercise
        # is about knowing which compiler ran.
        #
        # Naming note: nixpkgs ships these as plain `gcc` and `clang`, NOT the
        # apt-style `gcc-15` / `clang-19`. The VERSION is pinned by the shell
        # you enter, not by the binary name.
        #
        # THE FLOORS BELOW ARE MEASURED, not guessed -- CI run 31368093939
        # rejected the version under each:
        #
        #   GCC 15, not 14. GCC 14 accepts every C23 feature this code uses,
        #   but still reports __STDC_VERSION__ == 202000L, and
        #   include/wok_base.h refuses anything below 202311L. So 14 fails on
        #   the project's own guard rather than on a missing feature.
        #
        #   Clang 19, not 18. Clang 18 has no `constexpr` in C -- "unknown
        #   type name 'constexpr'" -- which is exactly the feature flagged in
        #   advance as the one deciding the floor (wok_token.c:120,124).
        clang = (pkgs.mkShell.override { stdenv = pkgs.llvmPackages_19.stdenv; }) {
          packages = base;
        };

        # GHC 9.10.3 exactly, matching the developer machine. Named explicitly
        # because nixpkgs' default `ghc` attribute is 9.8.4.
        #
        # Nix pins the COMPILER here, not the Haskell packages: tasty and the
        # rest still come from Hackage via cabal, which is why
        # cabal.project.freeze and its index-state stay load-bearing.
        haskell = pkgs.mkShell {
          packages = base ++ [
            pkgs.haskell.compiler.ghc9103
            pkgs.cabal-install
            pkgs.pkg-config
          ];
        };

        # Publishing the coverage site. Node 24 explicitly, rather than
        # whatever the runner ships -- the runner's default is what drags
        # node20 into a build that has no other reason to care.
        #
        # netlify-cli comes from nixpkgs rather than `npx netlify-cli`, so the
        # deploy is pinned by the same rev as every compiler here instead of
        # resolving against npm at deploy time. Caveat worth knowing: the
        # nixpkgs package brings its own node runtime for the CLI itself, so
        # nodejs_24 here governs the shell, not necessarily the CLI's own
        # interpreter.
        deploy = pkgs.mkShell {
          # jq is not incidental: the deploy asserts which project it is about
          # to publish to, and that assertion reads Netlify's API response.
          packages = [ pkgs.nodejs_24 pkgs.netlify-cli pkgs.jq ];
        };
      }
      # GCC on Linux only. nixpkgs can build GCC for Darwin, but it is largely
      # uncached there and would turn a two-minute job into a compiler build --
      # for a compiler nobody ships this code with. macOS is Apple's clang in
      # practice, so that is what the Darwin leg tests.
      //
      lib.optionalAttrs nixpkgs.legacyPackages.${system}.stdenv.hostPlatform.isLinux {
        gcc = (nixpkgs.legacyPackages.${system}.mkShell.override {
          stdenv = nixpkgs.legacyPackages.${system}.gcc15Stdenv;
        }) {
          # lcov lives here because coverage is a GCC-only job: its gcov must
          # be the gcov of the compiler that built the objects, and being in
          # this shell is what guarantees that. python3 renders the same
          # tracefile as JSON for readers that are not browsers.
          packages = base ++ [
            nixpkgs.legacyPackages.${system}.lcov
            nixpkgs.legacyPackages.${system}.python3
            nixpkgs.legacyPackages.${system}.git
          ];
        };
      });
    };
}
