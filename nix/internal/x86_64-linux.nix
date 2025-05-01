{ inputs, targetSystem }:

assert targetSystem == "x86_64-linux";

let
  pkgs = inputs.nixpkgs.legacyPackages.${targetSystem};
  inherit (pkgs) lib;
in rec {
  common = import ./common.nix { inherit inputs targetSystem; };

  package = blockfrost-platform-desktop;

  installer = selfExtractingArchive;

  inherit (common) cardano-node ogmios cardano-submit-api blockfrost-platform;

  cardano-js-sdk = (common.flake-compat {
    src = inputs.cardano-js-sdk;
  }).defaultNix.${pkgs.system}.cardano-services.packages.cardano-services;

  # In v18.16, after `patchelf`, we’re getting:
  #   `Check failed: VerifyChecksum(blob)` in `v8::internal::Snapshot::VerifyChecksum`
  # Let’s disable the default snapshot verification for now:
  nodejs-no-snapshot = cardano-js-sdk.nodejs.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./nodejs--no-verify-snapshot-checksum.patch ];
  });

  webkit2gtk = pkgs.webkitgtk_4_1.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./webkitgtk--specify-paths-via-env.patch ];
  });

  webkit2Bundle = mkBundle {
    "jsc" = "${webkit2gtk}/libexec/webkit2gtk-4.1/jsc";
    "MiniBrowser" = "${webkit2gtk}/libexec/webkit2gtk-4.1/MiniBrowser";
    "WebKitNetworkProcess" = "${webkit2gtk}/libexec/webkit2gtk-4.1/WebKitNetworkProcess";
    "WebKitWebProcess" = "${webkit2gtk}/libexec/webkit2gtk-4.1/WebKitWebProcess";
  };

  blockfrost-platform-desktop-exe = pkgs.buildGoModule rec {
    name = "blockfrost-platform-desktop";
    src = common.coreSrc;
    vendorHash = common.blockfrost-platform-desktop-exe-vendorHash;
    nativeBuildInputs = with pkgs; [ pkg-config ];
    buildInputs = [ webkit2gtk ] ++ (with pkgs; [
      (libayatana-appindicator-gtk3.override {
        gtk3 = gtk3-x11;
        libayatana-indicator = libayatana-indicator.override { gtk3 = gtk3-x11; };
        libdbusmenu-gtk3 = libdbusmenu-gtk3.override { gtk3 = gtk3-x11; };
      })
      gtk3-x11
    ]);
    overrideModAttrs = oldAttrs: {
      buildInputs = (oldAttrs.buildInputs or []) ++ buildInputs;
    };
    preBuild = ''
      ln -sf ${common.go-constants}/constants ./
      ln -sf ${go-assets}/assets ./
      # go:embed forbids symlinks, so:
      cp -R ${ui.dist} ./web-ui
    '';
    meta.mainProgram = "blockfrost-platform-desktop";
  };

  go-assets = pkgs.runCommand "go-assets" {
    nativeBuildInputs = with pkgs; [ imagemagick go-bindata ];
  } ''
    magick -background none -size 44x44 ${builtins.path { path = common.coreSrc + "/cardano.svg"; }} cardano.png
    cp cardano.png tray-icon
    cp ${common.openApiJson} openapi.json
    mkdir -p $out/assets
    go-bindata -pkg assets -o $out/assets/assets.go tray-icon openapi.json
  '';

  nix-bundle-exe = import inputs.nix-bundle-exe;

  # XXX: this tweaks `nix-bundle-exe` a little by making sure that each package lands in a separate
  # directory, because otherwise we get conflicts in e.g libstdc++ versions:
  mkBundle = exes': let
    exes = lib.removeAttrs exes' ["extraInit"];
    extraInit = exes'.extraInit or "";
  in (nix-bundle-exe {
    inherit pkgs;
    bin_dir = "bin";
    exe_dir = "exe";
    lib_dir = "lib";
  } (pkgs.linkFarm "exes" (lib.mapAttrsToList (name: path: {
    name = "bin/" + name;
    inherit path;
  }) exes))).overrideAttrs (drv: {
    buildCommand = builtins.replaceStrings ["find '"] ["find -L '"] drv.buildCommand + ''
      for base in ${lib.escapeShellArgs (__attrNames exes)} ; do
        if ${with pkgs; lib.getExe file} "$out/bin/$base" | cut -d: -f2 | grep -i 'shell script' >/dev/null ; then
          # dynamic linking:
          ${with pkgs; lib.getExe patchelf} --set-rpath '$ORIGIN' $out/exe/"$base"
          mv $out/exe/"$base" $out/."$base"-wrapped
          mv $out/bin/"$base" $out/
          sed -r 's,"\$\(dirname (.*?)\)" ,\1 , ; s,lib/,,g ; s,exe/'"$base"',.'"$base"'-wrapped,' -i $out/"$base"
          ${lib.optionalString (extraInit != "") ''
            head -n 3 $out/"$base" >$out/"$base".new
            cat ${pkgs.writeText "extraInit" extraInit} >>$out/"$base".new
            tail -n +4 $out/"$base" >>$out/"$base".new
            mv $out/"$base".new $out/"$base"
            chmod +x $out/"$base"
          ''}
        else
          # static linking:
          mv "$out/bin/$base" $out/
        fi
      done
      rmdir $out/bin
      if [ -e $out/exe ] ; then rmdir $out/exe ; fi
      if [ -e $out/lib ] ; then mv $out/lib/* $out/ && rmdir $out/lib ; fi
    '';
  });

  postgresPackage = common.postgresPackage.overrideAttrs (drv: {
    # `--with-system-tzdata=` is non-relocatable, cf. <https://github.com/postgres/postgres/blob/REL_15_2/src/timezone/pgtz.c#L39-L43>
    configureFlags = lib.filter (flg: !(lib.hasPrefix "--with-system-tzdata=" flg)) drv.configureFlags;
  });

  # Slightly more complicated, we have to bundle ‘postgresPackage.lib’, and also make smart
  # use of ‘make_relative_path’ defined in <https://github.com/postgres/postgres/blob/REL_15_2/src/port/path.c#L635C1-L662C1>:
  postgresBundle = let
    pkglibdir = let
      unbundled = postgresPackage.lib;
      bin_dir = "bin";
      exe_dir = "exe";
      lib_dir = ".";
    in (nix-bundle-exe {
      inherit pkgs;
      inherit bin_dir exe_dir lib_dir;
    } unbundled).overrideAttrs (drv: {
      inherit bin_dir exe_dir lib_dir;
      buildCommand = ''
        mkdir -p $out/${lib_dir}
        eval "$(sed -r '/^(out|binary)=/d ; /^exe_interpreter=/,$d' \
                  <${inputs.nix-bundle-exe + "/bundle-linux.sh)"}"
        find -L ${unbundled} -type f -name '*.so' | while IFS= read -r elf ; do
          bundleLib "$elf"
        done
      '';
    });
    binBundle = (mkBundle {
      "postgres" = "${postgresPackage}/bin/postgres";
      "initdb"   = "${postgresPackage}/bin/.initdb-wrapped";
      "psql"     = "${postgresPackage}/bin/psql";
      "pg_dump"  = "${postgresPackage}/bin/pg_dump";
    }).overrideAttrs (drv: {
      buildCommand = drv.buildCommand + ''
        find $out -mindepth 1 -maxdepth 1 -type f -executable | xargs file | grep 'shell script' | cut -d: -f1 | while IFS= read -r wrapper ; do
          sed -r '/^exec/i export NIX_PGLIBDIR="$dir/../pkglibdir"' -i "$wrapper"
        done
      '';
    });
  in pkgs.runCommand "postgresBundle" {
    passthru = { inherit pkglibdir binBundle; };
  } ''
    mkdir -p $out/bin
    cp -r ${binBundle}/. $out/bin/

    ln -sfn ${pkglibdir} $out/pkglibdir
    ln -sfn ${postgresPackage}/share $out/share
  '';

  testPostgres = pkgs.writeShellScriptBin "test-postgres" ''
    set -euo pipefail

    export PGDATA=$HOME/.local/share/blockfrost-platform-desktop/test-postgres
    if [ -e "$PGDATA" ] ; then rm -r "$PGDATA" ; fi
    mkdir -p "$PGDATA"

    ${postgresBundle}/bin/initdb --username postgres --pwfile ${pkgs.writeText "pwfile" "dupa.888"}

    mv "$PGDATA"/postgresql.conf "$PGDATA"/postgresql.conf.original
    cat >"$PGDATA/postgresql.conf" <<EOF
  listen_addresses = 'localhost'
  port = 5432
  unix_socket_directories = '$HOME/.local/share/blockfrost-platform-desktop/test-postgres'
  max_connections = 100
  fsync = on
  logging_collector = off
  log_destination = 'stderr'
  log_statement = 'all'
  datestyle = 'iso'
  timezone = 'utc'
  #autovacuum = on
  EOF

    mv "$PGDATA"/pg_hba.conf "$PGDATA"/pg_hba.conf.original
    cat >"$PGDATA/pg_hba.conf" <<EOF
  # TYPE  DATABASE        USER            ADDRESS                 METHOD
  host    all             all             127.0.0.1/32            scram-sha-256
  host    all             all             ::1/128                 scram-sha-256
  EOF

    exec ${postgresBundle}/bin/postgres
  '';

  # $dir is $out/libexec/blockfrost-platform-desktop/
  # TODO: move WEBKIT_EXEC_PATH here, but then `nix run -L` doesn’t work: Couldn't open libGLESv2.so.2: /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-libGL-1.7.0/lib/libGLESv2.so.2: cannot open shared object file: No such file or directory
  extraBSInit = ''
    # Prevent a Gtk3 segfault, especially with WebKit2 this cannot be done from within the executable:
    export XKB_CONFIG_EXTRA_PATH="$(realpath "$dir/../../share/xkb")"
    # Prepend our libexec/xclip to PATH – for xclip on Linux, which is not installed on all distributions
    export PATH="$(realpath "$dir/../xclip"):$PATH"
    # WebKit2 data directories:
    export WEBKIT_DEFAULT_CACHE_DIR="$HOME"/.local/share/blockfrost-platform-desktop/webkit2gtk
    export WEBKIT_DEFAULT_DATA_DIR="$HOME"/.local/share/blockfrost-platform-desktop/webkit2gtk
  '';

  blockfrost-platform-desktop = pkgs.runCommand "blockfrost-platform-desktop" {
    meta.mainProgram = blockfrost-platform-desktop-exe.name;
  } ''
    mkdir -p $out/bin $out/libexec/blockfrost-platform-desktop
    cp ${blockfrost-platform-desktop-exe}/bin/blockfrost-platform-desktop $out/libexec/blockfrost-platform-desktop/.blockfrost-platform-desktop-wrapped
    cp ${pkgs.writeScript "blockfrost-platform-desktop-non-bundle" ''
      #!/bin/sh
      set -x
      set -eu
      dir="$(cd -- "$(dirname "$(realpath "$0")")" >/dev/null 2>&1 ; pwd -P)"
      ${extraBSInit}
      exec "$dir"/.blockfrost-platform-desktop-wrapped "$@"
    ''} $out/libexec/blockfrost-platform-desktop/blockfrost-platform-desktop
    ln -s $out/libexec/blockfrost-platform-desktop/* $out/bin/

    mkdir -p $out/{libexec,share}
    ln -s ${mkBundle { "cardano-node"   = lib.getExe cardano-node;
                       "cardano-submit-api" = lib.getExe cardano-submit-api;}} $out/libexec/cardano-node
    ln -s ${blockfrost-platform                                              } $out/libexec/blockfrost-platform
    ln -s ${mkBundle { "mithril-client" = lib.getExe mithril-client;        }} $out/libexec/mithril-client
    ln -s ${mkBundle { "clip"           = lib.getExe pkgs.xclip;            }} $out/libexec/xclip

    ${lib.optionalString (!common.blockfrostPlatformOnly) ''
      ln -s ${mkBundle { "ogmios"         = lib.getExe ogmios;                }} $out/libexec/ogmios
      ln -s ${mkBundle { "node"           = lib.getExe nodejs-no-snapshot;    }} $out/libexec/nodejs
      ln -s ${postgresBundle                                                   } $out/libexec/postgres

      ln -s ${cardano-js-sdk}/libexec/incl $out/share/cardano-js-sdk
    ''}

    ln -s ${pkgs.xkeyboard_config}/share/X11/xkb $out/share/xkb
    ln -s ${common.networkConfigs} $out/share/cardano-node-config
    ln -s ${common.swagger-ui} $out/share/swagger-ui
    ln -s ${ui.dist} $out/share/ui
  '';

  # XXX: this has no dependency on /nix/store on the target machine
  blockfrost-platform-desktop-bundle = let
    unbundled = blockfrost-platform-desktop;
  in pkgs.runCommand "blockfrost-platform-desktop-bundle" {} ''
    mkdir -p $out
    cp -r --dereference ${unbundled}/libexec $out/
    chmod -R +w $out/libexec
    cp -r --dereference ${webkit2Bundle} $out/libexec/webkit2
    rm -r $out/libexec/blockfrost-platform-desktop
    cp -r --dereference ${mkBundle {
      "blockfrost-platform-desktop" = (lib.getExe blockfrost-platform-desktop-exe);
      extraInit = ''
        ${extraBSInit}
        # Use the bundled WebKit2:
        export WEBKIT_EXEC_PATH="$(realpath "$dir/../webkit2")"
      '';
    }} $out/libexec/blockfrost-platform-desktop
    mkdir -p $out/bin
    ln -s ../libexec/blockfrost-platform-desktop/blockfrost-platform-desktop $out/bin/
    cp -r --dereference ${unbundled}/share $out/ || true  # FIXME: unsafe! broken node_modules symlinks
    chmod -R +w $out/share
    cp $(find ${desktopItem} -type f -name '*.desktop') $out/share/blockfrost-platform-desktop.desktop
    ${pkgs.imagemagick}/bin/magick -background none -size 1024x1024 \
      ${builtins.path { path = common.coreSrc + "/cardano.svg"; }} $out/share/icon_large.png
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "blockfrost-platform-desktop";
    exec = "INSERT_PATH_HERE";
    desktopName = common.prettyName;
    genericName = "Cardano Crypto-Currency Backend";
    comment = "Run Blockfrost Platform Desktop locally";
    categories = [ "Network" ];
    icon = "INSERT_ICON_PATH_HERE";
    startupWMClass = "blockfrost-platform-desktop";
  };

  # XXX: Be *super careful* changing this!!! You WILL DELETE user data if you make a mistake. Ping @michalrus
  selfExtractingArchive = let
    scriptTemplate = __replaceStrings [
      "@UGLY_NAME@"
      "@PRETTY_NAME@"
    ] [
      (lib.escapeShellArg "blockfrost-platform-desktop")
      (lib.escapeShellArg common.prettyName)
    ] (__readFile ./linux-self-extracting-archive.sh);
    script = __replaceStrings ["1010101010"] [(toString (1000000000 + __stringLength scriptTemplate))] scriptTemplate;
    revShort =
      if inputs.self ? shortRev
      then builtins.substring 0 9 inputs.self.rev
      else "dirty";
  in pkgs.runCommand "blockfrost-platform-desktop-installer" {
    inherit script;
    passAsFile = [ "script" ];
  } ''
    mkdir -p $out
    target=$out/blockfrost-platform-desktop-${common.ourVersion}-${revShort}-${targetSystem}.bin
    cat $scriptPath >$target
    echo 'Compressing (xz)...'
    tar -cJ -C ${blockfrost-platform-desktop-bundle} . >>$target
    chmod +x $target

    # Make it downloadable from Hydra:
    mkdir -p $out/nix-support
    echo "file binary-dist \"$target\"" >$out/nix-support/hydra-build-products
  '';

  swagger-ui-preview = let
    port = 12345;
  in pkgs.writeShellScriptBin "swagger-ui-preview" ''
    set -euo pipefail
    openapi=$(realpath -e core/openapi.json)
    cd $(mktemp -d)
    ln -s ${common.swagger-ui} ./swagger-ui
    ln -s "$openapi" ./openapi.json
    ( sleep 0.5 ; xdg-open http://127.0.0.1:${toString port}/swagger-ui/ ; ) &
    ${lib.getExe pkgs.python3} -m http.server ${toString port}
  '';

  mithril-client = lib.recursiveUpdate { meta.mainProgram = "mithril-client"; } common.mithril-bin;

  ui = rec {
    node_modules = pkgs.stdenv.mkDerivation {
      name = "ui-node_modules";
      src = common.ui.lockfiles;
      nativeBuildInputs = [ common.ui.yarn common.ui.nodejs ] ++ (with pkgs; [ python3 pkg-config jq ]);
      configurePhase = common.ui.setupCacheAndGypDirs;
      buildPhase = ''
        # Do not look up in the registry, but in the offline cache:
        ${common.ui.yarn2nix.fixup_yarn_lock}/bin/fixup_yarn_lock yarn.lock

        # Now, install from offlineCache to node_modules/, but do not
        # execute any scripts defined in the project package.json and
        # its dependencies we need to `patchShebangs` first, since even
        # ‘/usr/bin/env’ is not available in the build sandbox
        yarn install --ignore-scripts

        # Remove all prebuilt *.node files extracted from `.tgz`s
        find . -type f -name '*.node' -not -path '*/@swc*/*' -exec rm -vf {} ';'

        patchShebangs . >/dev/null  # a real lot of paths to patch, no need to litter logs

        # And now, with correct shebangs, run the install scripts (we have to do that
        # semi-manually, because another `yarn install` will overwrite those shebangs…):
        find node_modules -type f -name 'package.json' | sort | ( xargs grep -F '"install":' || true ; ) | cut -d: -f1 | while IFS= read -r dependency ; do
          # The grep pre-filter is not ideal:
          if [ "$(jq .scripts.install "$dependency")" != "null" ] ; then
            echo ' '
            echo "Running the install script for ‘$dependency’:"
            ( cd "$(dirname "$dependency")" ; yarn run install ; )
          fi
        done

        patchShebangs . >/dev/null  # a few new files will have appeared
      '';
      installPhase = ''
        mkdir $out
        cp -r node_modules $out/
      '';
      dontFixup = true; # TODO: just to shave some seconds, turn back on after everything works
    };

    dist = pkgs.stdenv.mkDerivation {
      name = "ui-dist";
      src = common.uiSrc;
      nativeBuildInputs = [ common.ui.yarn common.ui.nodejs ] ++ (with pkgs; [ python3 pkg-config jq ]);
      CI = "nix";
      NODE_ENV = "production";
      BUILDTYPE = "Release";
      configurePhase = common.ui.setupCacheAndGypDirs + ''
        cp -r ${node_modules}/. ./
        chmod -R +w .
      '';
      buildPhase = ''
        patchShebangs .
        yarn build
      '';
      installPhase = ''
        cp -r dist $out
        cp -r ${common.ui.favicons}/. $out/
      '';
      dontFixup = true;
    };
  };
}
