{ inputs, targetSystem }:

let
  buildSystem = if targetSystem == "x86_64-windows" then "x86_64-linux" else targetSystem;
  pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
  inherit (pkgs) lib;
in rec {

  flake-compat = import inputs.flake-compat;

  prettyName = "Blockfrost Platform Desktop";

  ourVersion = "0.1.0";

  blockfrostPlatformOnly = true;

  # These are configs of ‘cardano-node’ for all networks we make available from the UI.
  # The patching of the official networks needs to happen to:
  #   • turn off ‘EnableP2P’ (and modify topology accordingly), because it doesn’t work on Windows,
  #   • and turn off ‘hadPrometheus’, because it makes cardano-node hang on Windows during graceful exit.
  networkConfigs = let
    selectedNetworks = [ "mainnet" "preprod" "preview" ];
  in pkgs.runCommand "network-configs" {
    nativeBuildInputs = [ pkgs.jq ];
  } (lib.concatMapStringsSep "\n" (network: ''
    mkdir -p $out/${network}
    cp -r ${inputs.cardano-js-sdk}/packages/cardano-services/config/network/${network}/. $out/${network}
  '') selectedNetworks);

  cardanoNodeFlake = (flake-compat { src = inputs.cardano-node; }).defaultNix;

  blockfrostPlatformFlake = (flake-compat { src = inputs.blockfrost-platform; }).defaultNix;

  ogmiosPatched = {
    outPath = toString (pkgs.runCommand "ogmios-patched" {} ''
      cp -r ${inputs.ogmios} $out
      chmod -R +w $out
      find $out -name cabal.project.freeze -delete -o -name package.yaml -delete
      grep -RF -- -external-libsodium-vrf $out | cut -d: -f1 | sort --uniq | xargs -n1 -- sed -r s/-external-libsodium-vrf//g -i
      cd $out
      patch -p1 -i ${./ogmios-6-5-0--missing-srp-hash.patch}
      patch -p1 -i ${./ogmios--on-windows.patch}
      patch -p1 -i ${./ogmios-6-9-0--fix-cabal-doctest.patch}
    '');
    inherit (inputs.ogmios.sourceInfo) rev shortRev lastModified lastModifiedDate;
  };

  inherit (cardanoNodeFlake.project.${buildSystem}.pkgs) haskell-nix;

  ogmiosProject = haskell-nix.project {
    compiler-nix-name = "ghc96";
    projectFileName = "cabal.project";
    inputMap = { "https://input-output-hk.github.io/cardano-haskell-packages" = cardanoNodeFlake.inputs.CHaP; };
    src = ogmiosPatched + "/server";
    modules = [
      ({ config, lib, pkgs, ... }: {
        packages.cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
        packages.cardano-crypto-class.components.library.pkgconfig = lib.mkForce [ ([ pkgs.libsodium-vrf pkgs.secp256k1 ]
          ++ (if pkgs ? libblst then [pkgs.libblst] else [])) ];
        packages.ogmios.components.library.preConfigure = "export GIT_SHA=${inputs.ogmios.rev}";
      })
      ({ lib, pkgs, ...}: {
        packages.entropy.package.buildType = lib.mkForce "Simple";
        packages.ouroboros-network-framework.doHaddock = false;
      })
    ];
  };

  ogmios = {
    x86_64-linux = ogmiosProject.projectCross.musl64.hsPkgs.ogmios.components.exes.ogmios;
    x86_64-windows = ogmiosProject.projectCross.mingwW64.hsPkgs.ogmios.components.exes.ogmios;
    x86_64-darwin = ogmiosProject.hsPkgs.ogmios.components.exes.ogmios;
    aarch64-darwin = ogmiosProject.hsPkgs.ogmios.components.exes.ogmios;
  }.${targetSystem};

  blockfrost-platform =
    blockfrostPlatformFlake.internal.${targetSystem}.bundle // {
      inherit (blockfrostPlatformFlake.internal.${targetSystem}.package) version;
    };

  cardano-node = {
    x86_64-linux = cardanoNodeFlake.hydraJobs.x86_64-linux.musl.cardano-node;
    x86_64-windows = cardanoNodeFlake.hydraJobs.x86_64-linux.windows.cardano-node;
    x86_64-darwin = cardanoNodeFlake.packages.x86_64-darwin.cardano-node;
    aarch64-darwin = cardanoNodeFlake.packages.aarch64-darwin.cardano-node;
  }.${targetSystem};

  cardano-submit-api = {
    x86_64-linux = cardanoNodeFlake.hydraJobs.x86_64-linux.musl.cardano-submit-api;
    x86_64-windows = cardanoNodeFlake.hydraJobs.x86_64-linux.windows.cardano-submit-api;
    x86_64-darwin = cardanoNodeFlake.packages.x86_64-darwin.cardano-submit-api;
    aarch64-darwin = cardanoNodeFlake.packages.aarch64-darwin.cardano-submit-api;
  }.${targetSystem};

  postgresPackage = {
    x86_64-linux = pkgs.postgresql_15_jit;
    x86_64-darwin = pkgs.postgresql_15_jit;
    aarch64-darwin = pkgs.postgresql_15_jit;
    x86_64-windows = let
      version = "15.4-1";
    in (pkgs.fetchurl {
      url = "https://get.enterprisedb.com/postgresql/postgresql-${version}-windows-x64.exe";
      hash = "sha256-Su4VKwJkeQ6HqCXTIZIK2c4AJHloqm72BZLs2JCnmN8=";
    }) // { inherit version; };
  }.${targetSystem};

  blockfrost-platform-desktop-exe-vendorHash = "sha256-3mz58RaOQvbZbTMCDwXTmIWUqMqpPlzy8222kvm9SOU=";

  go-constants = pkgs.writeTextDir "constants/constants.go" ''
    package constants

    const (
      BlockfrostPlatformDesktopVersion = ${__toJSON ourVersion}
      BlockfrostPlatformDesktopRevision = ${__toJSON (inputs.self.rev or "dirty")}
      CardanoNodeVersion = ${__toJSON cardanoNodeFlake.project.${buildSystem}.hsPkgs.cardano-node.identifier.version}
      CardanoNodeRevision = ${__toJSON inputs.cardano-node.rev}
      BlockfrostPlatformOnly = ${__toJSON blockfrostPlatformOnly}
      BlockfrostPlatformVersion = ${__toJSON blockfrost-platform.version}
      BlockfrostPlatformRevision = ${__toJSON inputs.blockfrost-platform.rev}
      OgmiosVersion = ${__toJSON ogmios.version}
      OgmiosRevision = ${__toJSON inputs.ogmios.rev}
      PostgresVersion = ${__toJSON postgresPackage.version}
      PostgresRevision = ${__toJSON postgresPackage.version}
      CardanoJsSdkVersion = ${__toJSON ((__fromJSON (__readFile (inputs.cardano-js-sdk + "/packages/cardano-services/package.json"))).version)}
      CardanoJsSdkRevision = ${__toJSON inputs.cardano-js-sdk.rev}
      CardanoJsSdkBuildInfo = ${__toJSON (let self = inputs.cardano-js-sdk; in builtins.toJSON {
        inherit (self) lastModified lastModifiedDate rev;
        shortRev = self.shortRev or "no rev";
        extra = {
          inherit (self) narHash;
          sourceInfo = self;
          path = self.outPath;
        };
      })}
      MithrilClientRevision = ${__toJSON inputs.mithril.sourceInfo.rev or "dirty"}
      MithrilClientVersion = ${__toJSON mithril-bin.version}
      MithrilGVKPreview = ${__toJSON mithrilGenesisVerificationKeys.preview}
      MithrilGVKPreprod = ${__toJSON mithrilGenesisVerificationKeys.preprod}
      MithrilGVKMainnet = ${__toJSON mithrilGenesisVerificationKeys.mainnet}
    )
  '';

  # Minimize rebuilds:
  coreSrc = builtins.path {
    path = inputs.self + "/core";
  };

  uiSrc = builtins.path {
    path = inputs.self + "/ui";
  };

  swagger-ui = let
    name = "swagger-ui";
    version = "5.2.0";
    src = pkgs.fetchFromGitHub {
      owner = "swagger-api"; repo = name;
      rev = "v${version}";
      hash = "sha256-gF2bUTr181MePC+FJN+BV2KQ7ZEW7sa4Mib7K0sgi4s=";
    };
  in pkgs.runCommand "${name}-${version}" {} ''
    cp -r ${src}/dist $out
    chmod -R +w $out
    sed -r 's|url:.*,|url: window.location.origin + "/openapi.json",|' -i $out/swagger-initializer.js
  '';

  # OpenAPI linter
  vacuum = pkgs.buildGoModule rec {
    pname = "vacuum";
    version = "0.2.6";
    src = pkgs.fetchFromGitHub {
      owner = "daveshanley"; repo = pname;
      rev = "v${version}";
      hash = "sha256-G0NzCqxu1rDrgnOrbDGuOv4Vq9lZJGeNyXzKRBvtf4o=";
    };
    vendorHash = "sha256-5aAnKf/pErRlugyk1/iJMaI4YtY/2Vs8GpB3y8tsjh4=";
    doCheck = false;  # some segfault in OAS 2.0 tests…
  };

  openApiJson = let
    src = builtins.path { path = coreSrc + "/openapi.json"; };
  in pkgs.runCommand "openapi.json" {
    buildInputs = [ pkgs.jq vacuum ];
  } ''
    vacuum lint --details ${src}

    jq --sort-keys\
      --arg title ${lib.escapeShellArg "${prettyName} API"} \
      '.info.title = $title' \
      ${src} >$out
  '';

  mithrilGenesisVerificationKeys = {
    preview = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/pre-release-preview/genesis.vkey");
    preprod = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-preprod/genesis.vkey");
    mainnet = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-mainnet/genesis.vkey");
  };

  # FIXME: build from source (Linux, and Darwins are available in their flake.nix, but Windows not)
  mithril-bin = let
    ver = (__fromJSON (__readFile (inputs.self + "/flake.lock"))).nodes.mithril.original.ref or "unknown-ref";
  in {
    x86_64-linux = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
    x86_64-windows = pkgs.fetchurl {
      name = "mithril-${ver}-windows-x64.tar.gz";
      url = "https://github.com/input-output-hk/mithril/releases/download/${ver}/mithril-${ver}-windows-x64.tar.gz";
      hash = "sha256-XS9tgSu1wOsLFz4COlXgO7WEGKgFw+/LJFY4tW7AwEs=";
    };
    x86_64-darwin = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
    aarch64-darwin = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
  }.${targetSystem} // { version = ver; };

  ui = rec {
    nodejs = pkgs.nodejs;

    yarn = pkgs.yarn.override { inherit nodejs; };

    yarn2nix = let
      src = builtins.path { path = pkgs.path + "/pkgs/development/tools/yarn2nix-moretea/yarn2nix"; };
    in
      import src {
        inherit pkgs nodejs yarn;
        allowAliases = true;
      };

    lockfiles = pkgs.lib.cleanSourceWith {
      src = uiSrc;
      name = "ui-lockfiles";
      filter = name: type: let b = baseNameOf (toString name); in (b == "package.json" || b == "yarn.lock");
    };

    favicons = pkgs.runCommand "favicons" {
      buildInputs = with pkgs; [ imagemagick ];
      original = builtins.path { path = uiSrc + "/favicon.svg"; };
    } ''
      mkdir -p $out
      convert -background none -size 32x32 $original $out/favicon-32x32.png
      convert -background none -size 16x16 $original $out/favicon-16x16.png
      convert $out/favicon-*.png $out/favicon.ico
    '';

    offlineCache = yarn2nix.importOfflineCache (yarn2nix.mkYarnNix {
      yarnLock = lockfiles + "/yarn.lock";
    });

    setupCacheAndGypDirs = ''
      # XXX: `HOME` (for various caches) cannot be under our source root:
      export HOME=$(realpath $NIX_BUILD_TOP/home)
      mkdir -p $HOME

      # Do not look up in the registry, but in the offline cache, cf. <https://classic.yarnpkg.com/en/docs/yarnrc>:
      echo '"--offline" true' >>$HOME/.yarnrc
      echo '"--frozen-lockfile" true' >>$HOME/.yarnrc
      yarn config set yarn-offline-mirror ${offlineCache}

      # Don’t try to download prebuilded packages (with prebuild-install):
      export npm_config_build_from_source=true
      ( echo 'buildFromSource=true' ; echo 'compile=true' ; ) >$HOME/.prebuild-installrc

      ${pkgs.lib.concatMapStringsSep "\n" (cacheDir: ''

        # Node.js headers for building native `*.node` extensions with node-gyp:
        # TODO: learn why installVersion=9 – where does it come from? see node-gyp
        mkdir -p ${cacheDir}/node-gyp/${nodejs.version}
        echo 9 > ${cacheDir}/node-gyp/${nodejs.version}/installVersion
        ln -sfn ${nodejs}/include ${cacheDir}/node-gyp/${nodejs.version}

      '') [
        "$HOME/.cache"          # Linux, Windows (cross-compiled)
        "$HOME/Library/Caches"  # Darwin
      ]}

      # These are sometimes useful:
      #
      # npm config set loglevel verbose
      # echo '"--verbose" true' >>$HOME/.yarnrc
      # export NODE_OPTIONS='--trace-warnings'
      # export DEBUG='*'
      # export DEBUG='node-gyp'
    '';
  };

}
