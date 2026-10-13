{
  description = "Nix support for developing the cloud api";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {self, ...}: let
    ghc-version = "967";
    systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      inherit systems;

      perSystem = {
        lib,
        pkgs,
        system,
        self',
        ...
      }: let
        ghc = pkgs.haskell.packages."ghc${ghc-version}";
        nativePackages =
          lib.optionals pkgs.stdenv.hostPlatform.isDarwin
          (with pkgs.darwin.apple_sdk.frameworks; [Cocoa]);

        cloud-api = pkgs.haskell.lib.buildStackProject {
          name = "cloud-api";
          buildInputs = [];
        };

        cloud-api-env = pkgs.mkShell {
          packages =
            [
              self'.packages.stack
              self'.packages.hls
              self'.packages.ghc
              self'.packages.ormolu
              pkgs.dhall
              pkgs.dhall-json
              pkgs.glibcLocales
              pkgs.gmp
              pkgs.hpack
              pkgs.nixd
              pkgs.openssl
              pkgs.pkg-config
              pkgs.postgresql
              pkgs.redis
              pkgs.miller
              pkgs.zlib
            ]
            ++ nativePackages;
          # workaround for https://gitlab.haskell.org/ghc/ghc/-/issues/11042
          shellHook = let
            libraryPath = lib.makeLibraryPath [pkgs.zlib pkgs.gmp pkgs.postgresql.lib];
          in ''
            export LD_LIBRARY_PATH=${libraryPath}:$LD_LIBRARY_PATH
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
        mkApp = drv: {
          type = "app";
          program = pkgs.lib.getExe drv;
        };
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [
              "nomad"
            ];
          overlays = [self.overlay];
        };

        apps = {
          repl = mkApp (pkgs.writeShellScriptBin "repl" ''
            confnix=$(mktemp)
            echo "builtins.getFlake (toString $(git rev-parse --show-toplevel))" >$confnix
            trap "rm $confnix" EXIT
            nix repl $confnix
          '');

          integration-tests-staging = mkApp (cloudTests {env = "staging";});
          integration-tests-prod = mkApp (cloudTests {env = "prod";});

          cloud-user-staging = mkApp (cloudUser {env = "staging";});
          cloud-user-prod = mkApp (cloudUser {env = "production";});
        };

        devShells.default = cloud-api-env;

        formatter = pkgs.alejandra;

        packages = {
          cloud-api = cloud-api;
          hls = pkgs.unison-hls;
          hls-call-hierarchy-plugin = ghc.hls-call-hierarchy-plugin;
          ormolu = pkgs.ormolu;
          ghc = pkgs.haskell.compiler."ghc${ghc-version}";
          stack = pkgs.unison-stack;
          devShell = cloud-api-env;
          docker = dockerImage;
        };
      };

      flake = {
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
    };
}
