{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-24.05-darwin";

    flake-compat.url = "github:input-output-hk/flake-compat";
    flake-compat.flake = false;

    cardano-node.url = "github:IntersectMBO/cardano-node/10.1.4";
    cardano-node.flake = false; # prevent lockfile explosion

    cardano-js-sdk.url = "github:input-output-hk/cardano-js-sdk/@cardano-sdk/cardano-services@0.35.10";
    cardano-js-sdk.flake = false; # we patch it & to prevent lockfile explosion

    blockfrost-platform = {
      url = "github:blockfrost/blockfrost-platform/pull/296/head"; # fetch `/addresses/{addr}/utxos` from the ledger state
      flake = false; # to prevent lockfile explosion
    };

    ogmios = {
      url = "https://github.com/CardanoSolutions/ogmios.git";
      ref = "refs/tags/v6.11.2";
      type = "git";
      submodules = true;
      flake = false;
    };

    mithril.url = "github:input-output-hk/mithril/2450.0";

    nix-bundle-exe.url = "github:3noch/nix-bundle-exe";
    nix-bundle-exe.flake = false;

    # FIXME: ‘nsis’ can’t cross-compile with the regular Nixpkgs (above)
    nixpkgs-nsis.url = "github:input-output-hk/nixpkgs/be445a9074f139d63e704fa82610d25456562c3d";
    nixpkgs-nsis.flake = false; # too old

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: let
    supportedSystem = ["x86_64-linux" "x86_64-darwin" "aarch64-darwin"];
    inherit (inputs.nixpkgs) lib;
  in {
    packages = lib.genAttrs supportedSystem (buildSystem:
      import ./nix/packages.nix { inherit inputs buildSystem; }
    );

    internal = import ./nix/internal.nix { inherit inputs; };

    devShells = lib.genAttrs supportedSystem (buildSystem:
      import ./nix/devshells.nix { inherit inputs buildSystem; }
    );

    hydraJobs = {
      installer = {
        x86_64-linux   = inputs.self.packages.x86_64-linux.installer;
        x86_64-darwin  = inputs.self.packages.x86_64-darwin.installer;
        aarch64-darwin  = inputs.self.packages.aarch64-darwin.installer;
        x86_64-windows = inputs.self.packages.x86_64-linux.installer-x86_64-windows;
      };

      inherit (inputs.self) devShells;

      required = inputs.nixpkgs.legacyPackages.x86_64-linux.releaseTools.aggregate {
        name = "github-required";
        meta.description = "All jobs required to pass CI";
        constituents =
          __attrValues inputs.self.hydraJobs.installer ++
          map (a: a.default) (__attrValues inputs.self.hydraJobs.devShells);
      };
    };
  };

}
