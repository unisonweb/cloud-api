{
  description = "Nix support for developing the cloud api";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: let
    ghc-version = "965";
    systemAttrs = flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [
            "nomad"
          ];
        overlays = [self.overlay];
      };
      ghc = pkgs.haskell.packages."ghc${ghc-version}";
      nativePackages =
        pkgs.lib.optionals pkgs.stdenv.isDarwin
        (with pkgs.darwin.apple_sdk.frameworks; [Cocoa]);

      cloud-api = pkgs.haskell.lib.buildStackProject {
        name = "cloud-api";
        buildInputs = [];
      };

      cloud-api-env = pkgs.mkShell {
        packages = let
          exports = self.packages."${system}";
        in
          with pkgs;
            [
              exports.stack
              exports.hls
              exports.ghc
              exports.ormolu
              dhall
              dhall-json
              glibcLocales
              gmp
              hpack
              openssl
              pkg-config
              postgresql
              redis
              miller
              zlib
            ]
            ++ nativePackages;
        # workaround for https://gitlab.haskell.org/ghc/ghc/-/issues/11042
        shellHook = ''
          export LD_LIBRARY_PATH=${pkgs.zlib}/lib:${pkgs.gmp}/lib:${pkgs.postgresql.lib}/lib:$LD_LIBRARY_PATH
        '';
      };
      dockerImage = pkgs.dockerTools.buildImage {
        name = "cloud-api";
        config = {
          Cmd = ["${cloud-api}/bin/cloud-exe"];
          src = ".";
        };
      };

      cloudTests = {env}:
        pkgs.writeShellApplication {
          name = "cloud-integration-tests-${env}";
          runtimeInputs = [pkgs.drone-cli];
          text = ''
            drone cron exec unisoncomputing/cloud-api integration-tests-${env}
          '';
        };
      cloudUser = {env}:
        pkgs.writeShellApplication {
          name = "cloud-user-${env}";
          runtimeEnv = {
            CLOUD_ENVIRONMENT = env;
          };
          runtimeInputs = [pkgs.nomad];
          text = builtins.readFile ./scripts/cloud-user.sh;
        };
    in {
      apps = {
        repl = flake-utils.lib.mkApp {
          drv = nixpkgs.legacyPackages."${system}".writeShellScriptBin "repl" ''
            confnix=$(mktemp)
            echo "builtins.getFlake (toString $(git rev-parse --show-toplevel))" >$confnix
            trap "rm $confnix" EXIT
            nix repl $confnix
          '';
        };

        integration-tests-staging = flake-utils.lib.mkApp {drv = cloudTests {env = "staging";};};
        integration-tests-prod = flake-utils.lib.mkApp {drv = cloudTests {env = "prod";};};

        cloud-user-staging = flake-utils.lib.mkApp {drv = cloudUser {env = "staging";};};
        cloud-user-prod = flake-utils.lib.mkApp {drv = cloudUser {env = "production";};};
      };

      pkgs = pkgs;

      devShells.default = cloud-api-env;

      formatter = pkgs.alejandra;

      packages = {
        cloud-api = cloud-api;
        hls = pkgs.unison-hls;
        hls-call-hierarchy-plugin = ghc.hls-call-hierarchy-plugin;
        ormolu = pkgs.ormolu;
        ghc = pkgs.haskell.compiler."ghc${ghc-version}";
        stack = pkgs.unison-stack;
        devShell = self.devShells."${system}".default;
        docker = dockerImage;
      };

      defaultPackage = self.packages."${system}".devShell;
    });
    topLevelAttrs = {
      overlay = final: prev: {
        unison-hls = final.haskell-language-server.override {
          haskellPackages = final.haskell.packages."ghc${ghc-version}";
          dynamic = true;
          supportedGhcVersions = [ghc-version];
        };
        unison-stack = prev.symlinkJoin {
          name = "stack";
          paths = [final.stack];
          buildInputs = [final.makeWrapper];
          postBuild = let
            flags = ["--no-nix" "--system-ghc" "--no-install-ghc"];
            add-flags = "--add-flags '${prev.lib.concatStringsSep " " flags}'";
          in ''
            wrapProgram "$out/bin/stack" ${add-flags}
          '';
        };
      };
    };
  in
    systemAttrs // topLevelAttrs;
}
