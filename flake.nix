{
  description = "Ardour dependencies and build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        ardourVersion = "9.2";
        releaseVersion = "9.2.0";
        bundleName = "Ardour9";
        ardourSource = pkgs.fetchFromGitHub {
          owner = "Ardour";
          repo = "ardour";
          rev = ardourVersion;
          fetchSubmodules = true;
          hash = "sha256-zbEfEuWdhlKtYE0gVB/N0dFrcmNoJqgEMuvQ0wdmRpM=";
        };

        # for macos, we need to use the custom versions of aubio and vamp plugins
        aubio-custom = pkgs.callPackage ./aubio.nix { };
        ardourLv2Stack = pkgs.callPackage ./ardour-lv2-stack.nix { };
        ardourBundledMedia = pkgs.fetchurl {
          url = "http://stuff.ardour.org/loops/ArdourBundledMedia.zip";
          hash = "sha256-oA3gBnHNwymyyjXCpcQVCvPWWIFH+dyi496nUqouI0w=";
        };
        harrisonLv2Bundle =
          if system == "aarch64-darwin" then
            pkgs.fetchurl {
              url = "https://builder.harrisonconsoles.com/pub/dsp/harrison_lv2s-n.macarm64.zip";
              hash = "sha256-06L1IOXyBZsNXKV2300FG6BTSYa6DKZr3QjgxzUH1sI=";
            }
          else
            null;
        harvidBundle =
          if system == "aarch64-darwin" then
            pkgs.fetchurl {
              url = "http://ardour.org/files/video-tools/harvid-macOS-arm64-v0.9.1.tgz";
              hash = "sha256-QpcPSAy9C47cbNRePJ+V4X3xnrR5RoBoyNaSoc20nQM=";
            }
          else
            null;
        gmsynthBundle =
          if system == "aarch64-darwin" then
            pkgs.fetchurl {
              url = "https://x42-plugins.com/x42/mac/x42-gmsynth-lv2-macOS-v0.6.4.zip";
              hash = "sha256-vgS2QKrTu+eJpeGGV/3bTohmhBInANFr0wN45AkxMRo=";
            }
          else
            null;
        libwebsocketsCustom = pkgs.callPackage ./libwebsockets.nix { };
        vamp-custom = pkgs.callPackage ./vamp.nix { };
        curl-custom = pkgs.curlMinimal;

        libraries =
          with pkgs;
          [
            boost
            glib
            glibmm
            libsndfile
            curl-custom
            libarchive
            liblo
            taglib
            vamp-custom
            rubberband
            libusb1
            jack2
            fftwFloat
            libpng
            pango
            cairomm
            pangomm
            ardourLv2Stack.lv2
            libxml2
            cppunit
            libwebsocketsCustom
            lrdf
            libsamplerate
            ardourLv2Stack.serd
            ardourLv2Stack.sord
            ardourLv2Stack.sratom
            ardourLv2Stack.lilv
            libogg
            flac
            fontconfig
            freetype
            aubio-custom
            readline # for Lua Commandline Tool
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.apple-sdk
          ];

        ardour-base = pkgs.stdenv.mkDerivation {
          pname = "ardour";
          version = ardourVersion;

          src = ardourSource;

          patches = [
            ./arm64-fix.patch
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
            perl
            python311
          ];

          buildInputs = libraries;

          # macOS needs these flags to disable symbol visibility
          CFLAGS = "-DDISABLE_VISIBILITY";
          CXXFLAGS = "-DDISABLE_VISIBILITY";

          postPatch = ''
            # リビジョン情報の静的生成
            mkdir -p libs/ardour
            printf '#include "ardour/revision.h"\nnamespace ARDOUR { const char* revision = "${ardourVersion}"; }\n' > libs/ardour/revision.cc

            # バージョン取得ロジックの回避
            substituteInPlace wscript \
              --replace "rev, rev_date = fetch_tarball_revision_date()" "rev, rev_date = '${ardourVersion}', '2026-03-10'" \
              --replace "rev, rev_date = fetch_git_revision_date()" "rev, rev_date = '${ardourVersion}', '2026-03-10'"

            chmod +x waf
          '';

          preConfigure = ''
            export NIX_CFLAGS_COMPILE="$(pkg-config --cflags sratom-0) $NIX_CFLAGS_COMPILE"
          '';

          configurePhase = ''
            runHook preConfigure
            python3 ./waf configure \
              --prefix=$out \
              --arm64 \
              --strict \
              --ptformat \
              --libjack=weak \
              --optimize \
              --keepflags
              runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            python3 ./waf
            python3 ./waf i18n
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Wafによる標準的なインストールを実行
            # これにより $out/bin, $out/lib, $out/share 配下に成果物が配置されます
            python3 ./waf install

            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
              if [ -f build/libs/clearlooks-newer/libclearlooks.dylib ]; then
                mkdir -p "$out/lib/ardour9/gtkengines/engines"
                cp build/libs/clearlooks-newer/libclearlooks.dylib \
                  "$out/lib/ardour9/gtkengines/libclearlooks.dylib"
                ln -sf ../libclearlooks.dylib \
                  "$out/lib/ardour9/gtkengines/engines/libclearlooks.so"
              fi
            ''}
            runHook postInstall
          '';
        };

        ardour-package = pkgs.stdenvNoCC.mkDerivation {
          pname = "ardour";
          version = ardourVersion;

          dontUnpack = true;
          dontPatchShebangs = true;
          nativeBuildInputs =
            pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.cctools
            ]
            ++ [
              pkgs.python311
              pkgs.unzip
            ];

          installPhase = ''
            runHook preInstall

            cp -a ${ardour-base}/. "$out/"
            chmod -R u+w "$out"

            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
              ardourLib="$out/lib/ardour9"
              baseRoot="${ardour-base}"
              buildPrefix="/source/build/libs/"
              bundledLibDir="$ardourLib/bundled"

              if [ -d "$ardourLib" ]; then
                mkdir -p "$bundledLibDir"
                export ardourLib bundledLibDir out

                python3 ${./scripts/copy-tree-macho-deps.py}

                while IFS= read -r -d "" macho; do
                  if ! file -b "$macho" | grep -q "Mach-O"; then
                    continue
                  fi

                  machoDir="$(dirname "$macho")"

                  case "$macho" in
                    *.dylib)
                      install_name_tool -id "@loader_path/$(basename "$macho")" "$macho"
                      ;;
                  esac

                  while IFS= read -r dep; do
                    target=""

                    case "$dep" in
                      "$baseRoot"/*)
                        target="$out/''${dep#"$baseRoot"/}"
                        ;;
                      "$out"/*)
                        target="$dep"
                        ;;
                      /nix/store/*)
                        depBase="$(basename "$dep")"
                        if [ -f "$bundledLibDir/$depBase" ]; then
                          target="$bundledLibDir/$depBase"
                        fi
                        ;;
                      *"$buildPrefix"*)
                        depBase="$(basename "$dep")"
                        target="$(find -L "$ardourLib" -name "$depBase" | head -n 1)"
                        ;;
                    esac

                    if [ -n "$target" ]; then
                      relTarget="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$target" "$machoDir")"
                      install_name_tool -change "$dep" "@loader_path/$relTarget" "$macho"
                    elif [ "''${dep#"$baseRoot"/}" != "$dep" ] || [ "''${dep#"$buildPrefix"}" != "$dep" ]; then
                      echo "warning: no installed Mach-O match for $dep in $macho" >&2
                    fi
                  done < <(otool -L "$macho" | tail -n +2 | awk '{print $1}')
                done < <(find "$ardourLib" -type f \( -perm -111 -o -name "*.dylib" \) -print0)
              fi
            ''}

            if [ -d "$out/share/ardour9/media" ]; then
              unzip -oq ${ardourBundledMedia} -d "$out/share/ardour9/media"
            fi

            if [ -d "$out/lib/ardour9/LV2" ]; then
              while IFS= read -r -d "" ttl; do
                bundleName="$(basename "$(dirname "$ttl")")"
                installDir="$out/lib/ardour9/LV2/$bundleName"
                mkdir -p "$installDir"
                cp "$ttl" "$installDir/"
              done < <(find ${ardourLv2Stack.lv2}/lib/lv2 -mindepth 2 -maxdepth 2 -type f -name "*.ttl" -print0)
            fi

            ${pkgs.lib.optionalString (harrisonLv2Bundle != null) ''
              if [ -d "$out/lib/ardour9/LV2" ]; then
                unzip -oq ${harrisonLv2Bundle} -d "$out/lib/ardour9/LV2"
              fi
            ''}

            ${pkgs.lib.optionalString (gmsynthBundle != null) ''
              if [ -d "$out/lib/ardour9/LV2" ]; then
                unzip -oq ${gmsynthBundle} -d "$out/lib/ardour9/LV2"
              fi
            ''}

            ${pkgs.lib.optionalString (harvidBundle != null) ''
              tmpHarvid="$TMPDIR/harvid"
              mkdir -p "$tmpHarvid"
              tar -xzf ${harvidBundle} -C "$tmpHarvid"

              if [ -d "$tmpHarvid/lib/harvid" ]; then
                mkdir -p "$out/lib/ardour9/harvid"
                cp -a "$tmpHarvid/lib/harvid/." "$out/lib/ardour9/harvid/"
                chmod -R u+w "$out/lib/ardour9/harvid"
              fi

              if [ -d "$tmpHarvid/MacOS" ]; then
                mkdir -p "$out/lib/ardour9/video-tools"
                cp -a "$tmpHarvid/MacOS/." "$out/lib/ardour9/video-tools/"
                chmod -R u+w "$out/lib/ardour9/video-tools"
              fi
            ''}

            for script in \
              "$out/bin/ardour9" \
              "$out/bin/ardour9-lua" \
              "$out/bin/ardour9-export" \
              "$out/bin/ardour9-new_session" \
              "$out/bin/ardour9-new_empty_session" \
              "$out/lib/ardour9/utils/ardour-util.sh"
            do
              [ -f "$script" ] || continue

              substituteInPlace "$script" \
                --replace "${ardour-base}/share/ardour9" '$_ardour_root/share/ardour9' \
                --replace "${ardour-base}/etc/ardour9" '$_ardour_root/etc/ardour9' \
                --replace "${ardour-base}/lib/ardour9/vamp" '$_ardour_root/lib/ardour9/vamp' \
                --replace "${ardour-base}/lib/ardour9/utils/" '$_ardour_root/lib/ardour9/utils/' \
                --replace "${ardour-base}/lib/ardour9/luasession" '$_ardour_root/lib/ardour9/luasession' \
                --replace "${ardour-base}/lib/ardour9/ardour-9.2.0" '$_ardour_root/lib/ardour9/ardour-9.2.0' \
                --replace "${ardour-base}/lib/ardour9" '$_ardour_root/lib/ardour9'
            done

            for script in \
              "$out/bin/ardour9" \
              "$out/bin/ardour9-lua" \
              "$out/bin/ardour9-export" \
              "$out/bin/ardour9-new_session" \
              "$out/bin/ardour9-new_empty_session"
            do
              [ -f "$script" ] || continue

              tmp="$TMPDIR/$(basename "$script").wrapped"
              {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' '_script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"'
                printf '%s\n' '_ardour_root="$(CDPATH= cd -- "$_script_dir/.." && pwd)"'
                printf '%s\n' 'export PATH=$_ardour_root/lib/ardour9/video-tools''${PATH:+:$PATH}'
                sed '1d' "$script"
              } > "$tmp"
              mv "$tmp" "$script"
              chmod +x "$script"
            done

            if [ -f "$out/lib/ardour9/utils/ardour-util.sh" ]; then
              tmp="$TMPDIR/ardour-util.sh.wrapped"
              {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' '_script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"'
                printf '%s\n' '_ardour_root="$(CDPATH= cd -- "$_script_dir/../../.." && pwd)"'
                printf '%s\n' 'export PATH=$_ardour_root/lib/ardour9/video-tools''${PATH:+:$PATH}'
                sed '1d' "$out/lib/ardour9/utils/ardour-util.sh"
              } > "$tmp"
              mv "$tmp" "$out/lib/ardour9/utils/ardour-util.sh"
              chmod +x "$out/lib/ardour9/utils/ardour-util.sh"
            fi

            runHook postInstall
          '';
        };

        ardour-app = pkgs.stdenvNoCC.mkDerivation {
          pname = "ardour-app";
          version = ardourVersion;

          dontUnpack = true;
          dontPatchShebangs = true;
          nativeBuildInputs =
            pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.cctools
            ]
            ++ [
              pkgs.python311
            ];

          installPhase = ''
            runHook preInstall

            if [ "${if pkgs.stdenv.isDarwin then "1" else "0"}" != 1 ]; then
              mkdir -p "$out"
              cp -a ${ardour-package}/. "$out/"
              runHook postInstall
              exit 0
            fi

            appDir="$out/${bundleName}.app"
            appRoot="$appDir/Contents"
            finalResourcesDir="$appRoot/Resources"
            resourcesDir="$(mktemp -d)"
            libDir="$appRoot/lib"
            macosDir="$appRoot/MacOS"
            lv2Dir="$libDir/LV2"

            mkdir -p "$resourcesDir" "$libDir" "$macosDir" "$lv2Dir"

            cp -a ${ardour-package}/lib/ardour9/. "$libDir/"
            chmod -R u+w "$libDir"

            if [ -f "$libDir/gtkengines/libclearlooks.dylib" ]; then
              mkdir -p "$libDir/gtkengines/engines"
              rm -f "$libDir/gtkengines/engines/libclearlooks.so"
              cp "$libDir/gtkengines/libclearlooks.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              chmod u+w "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -id "@loader_path/libclearlooks.so" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../libytk.dylib" "@loader_path/../../libytk.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../libydk.dylib" "@loader_path/../../libydk.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../libztk.dylib" "@loader_path/../../libztk.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../libydk-pixbuf.dylib" "@loader_path/../../libydk-pixbuf.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libcairo.2.dylib" "@loader_path/../../bundled/libcairo.2.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libpango-1.0.0.dylib" "@loader_path/../../bundled/libpango-1.0.0.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libgobject-2.0.0.dylib" "@loader_path/../../bundled/libgobject-2.0.0.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libglib-2.0.0.dylib" "@loader_path/../../bundled/libglib-2.0.0.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libharfbuzz.0.dylib" "@loader_path/../../bundled/libharfbuzz.0.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              install_name_tool -change "@loader_path/../bundled/libintl.8.dylib" "@loader_path/../../bundled/libintl.8.dylib" "$libDir/gtkengines/engines/libclearlooks.so"
              rm -f "$libDir/gtkengines/libclearlooks.dylib"
            fi

            rm -rf "$libDir/engines"

            if [ -d "$libDir/video-tools" ]; then
              cp -a "$libDir/video-tools/." "$macosDir/"
              chmod -R u+w "$macosDir"
              rm -rf "$libDir/video-tools"
            fi

            while IFS= read -r -d "" entry; do
              if [ "$(basename "$entry")" = "locale" ]; then
                continue
              fi
              cp -R "$entry" "$resourcesDir/"
            done < <(find ${ardour-package}/share/ardour9 -mindepth 1 -maxdepth 1 -print0)

            while IFS= read -r -d "" entry; do
              cp -R "$entry" "$resourcesDir/"
            done < <(find ${ardour-package}/etc/ardour9 -mindepth 1 -maxdepth 1 -print0)
            chmod -R u+w "$resourcesDir"

            if [ -d ${ardour-package}/share/ardour9/locale ]; then
              while IFS= read -r -d "" moFile; do
                relPath="''${moFile#${ardour-package}/share/ardour9/locale/}"
                mkdir -p "$resourcesDir/locale/$(dirname "''${relPath}")"
                install -m 0644 "$moFile" "$resourcesDir/locale/''${relPath}"
              done < <(find ${ardour-package}/share/ardour9/locale -type f -print0)
            fi

            if [ -d "$resourcesDir/locale" ]; then
              glibLocaleRoot="${pkgs.glib.out}/share/locale"
              gettextLocaleRoot="${pkgs.gettext}/share/locale"

              while IFS= read -r -d "" lcDir; do
                lang="$(basename "$(dirname "$lcDir")")"

                if ! find "$lcDir" -maxdepth 1 -type f ! -name 'libytk9.mo' | grep -q .; then
                  continue
                fi

                sourceLang="$lang"
                if [ ! -d "$glibLocaleRoot/$sourceLang" ] && [ ! -d "$gettextLocaleRoot/$sourceLang" ]; then
                  fallbackLang="$(printf '%s\n' "$lang" | sed 's/_[A-Z][A-Z]$//')"
                  if [ "$fallbackLang" != "$lang" ] && { [ -d "$glibLocaleRoot/$fallbackLang" ] || [ -d "$gettextLocaleRoot/$fallbackLang" ]; }; then
                    sourceLang="$fallbackLang"
                  fi
                fi

                targetLocaleDir="$resourcesDir/locale/$sourceLang/LC_MESSAGES"
                mkdir -p "$targetLocaleDir"
                chmod u+w "$resourcesDir/locale" "$resourcesDir/locale/$sourceLang" "$targetLocaleDir" || true

                for mo in gettext-runtime.mo gettext-tools.mo; do
                  if [ -f "$gettextLocaleRoot/$sourceLang/LC_MESSAGES/$mo" ]; then
                    install -m 0644 "$gettextLocaleRoot/$sourceLang/LC_MESSAGES/$mo" "$targetLocaleDir/$mo"
                  fi
                done

                if [ -f "$glibLocaleRoot/$sourceLang/LC_MESSAGES/glib20.mo" ]; then
                  install -m 0644 "$glibLocaleRoot/$sourceLang/LC_MESSAGES/glib20.mo" "$targetLocaleDir/glib20.mo"
                fi
              done < <(find "$resourcesDir/locale" -mindepth 2 -maxdepth 2 -type d -name LC_MESSAGES -print0)
            fi

            mkdir -p "$resourcesDir/icons"
            cp -a ${ardourSource}/gtk2_ardour/icons/cursor_square "$resourcesDir/icons/"
            cp -a ${ardourSource}/gtk2_ardour/icons/cursor_z "$resourcesDir/icons/"

            cp ${ardourSource}/tools/osx_packaging/Resources/fonts.conf "$resourcesDir/fonts.conf"
            cp ${ardourSource}/tools/osx_packaging/Ardour.icns "$resourcesDir/appIcon.icns"
            cp ${ardourSource}/tools/osx_packaging/typeArdour.icns "$resourcesDir/typeArdour.icns"
            ln -s typeArdour.icns "$resourcesDir/typeIcon.icns"

            if [ -d ${pkgs.lrdf}/share/ladspa/rdf ]; then
              mkdir -p "$resourcesDir/rdf"
              cp -a ${pkgs.lrdf}/share/ladspa/rdf/. "$resourcesDir/rdf/"
            else
              mkdir -p "$resourcesDir/rdf"
              touch "$resourcesDir/rdf/.stub"
            fi

            export appRoot resourcesDir libDir macosDir

            export releaseVersion='${releaseVersion}'
            export bundleName='${bundleName}'
            python3 ${./scripts/patch-app-executables.py}

            if [ -d "$libDir/bundled" ]; then
              cp -a "$libDir/bundled/." "$libDir/"
            fi

            if [ -d "$libDir/appleutility" ]; then
              cp -a "$libDir/appleutility/." "$libDir/"
            fi

            if [ -d "$libDir/vamp" ]; then
              cp -a "$libDir/vamp/." "$libDir/"
            fi

            rm -rf \
              "$libDir/bundled" \
              "$libDir/appleutility" \
              "$libDir/vamp" \
              "$libDir/utils" \
              "$libDir/engines"

            rm -f \
              "$libDir/ardour-${releaseVersion}" \
              "$libDir/hardour-${releaseVersion}" \
              "$libDir/luasession"

            python3 ${./scripts/normalize-app-macho-refs.py}

            cat > "$macosDir/ardour9-export" <<'EOF'
#!/bin/sh

BIN_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLE_DIR=$(dirname "$BIN_DIR")

export ARDOUR_DATA_PATH="$BUNDLE_DIR/Resources"
export ARDOUR_CONFIG_PATH="$BUNDLE_DIR/Resources"
export ARDOUR_DLL_PATH="$BUNDLE_DIR/lib"
export VAMP_PATH="$BUNDLE_DIR/lib''${VAMP_PATH:+:$VAMP_PATH}"
export PATH="$BUNDLE_DIR/MacOS''${PATH:+:$PATH}"

SELF=$(basename "$0")
exec "$BUNDLE_DIR/lib/$SELF" "$@"
EOF

            cp "$macosDir/ardour9-export" "$macosDir/ardour9-lua"
            cp "$macosDir/ardour9-export" "$macosDir/ardour9-new_session"
            cp "$macosDir/ardour9-export" "$macosDir/ardour9-new_empty_session"
            chmod +x \
              "$macosDir/ardour9-export" \
              "$macosDir/ardour9-lua" \
              "$macosDir/ardour9-new_session" \
              "$macosDir/ardour9-new_empty_session"

            env='<key>LSEnvironment</key><dict><key>PATH</key><string>/usr/local/bin:/opt/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>DYLIB_FALLBACK_LIBRARY_PATH</key><string>/usr/local/lib:/opt/lib</string><key>ARDOUR_BUNDLED</key><string>true</string></dict>'
            infoString='${releaseVersion} built with Nix on ${system}'
            sed \
              -e "s?@ENV@?$env?g" \
              -e "s?@VERSION@?${releaseVersion}?g" \
              -e "s?@INFOSTRING@?$infoString?g" \
              -e "s?@IDBASE@?org.ardour?g" \
              -e "s?@IDSUFFIX@?${bundleName}?g" \
              -e "s?@BUNDLENAME@?${bundleName}?g" \
              -e "s?@EXECUTABLE@?${bundleName}?g" \
              ${ardourSource}/tools/osx_packaging/Info.plist.in > "$appRoot/Info.plist"

            sed \
              -e "s?@APPNAME@?${bundleName}?g" \
              -e "s?@VERSION@?${releaseVersion}?g" \
              ${ardourSource}/tools/osx_packaging/InfoPlist.strings.in > "$resourcesDir/InfoPlist.strings"

            mkdir -p "$finalResourcesDir"
            cp -R "$resourcesDir/." "$finalResourcesDir/"

            runHook postInstall
          '';
        };

        export-app = pkgs.writeShellApplication {
          name = "export-ardour-app";
          text = ''
            set -eu

            dest="''${1:-./dist/${bundleName}.app}"
            mkdir -p "$(dirname "$dest")"
            rm -rf "$dest"
            cp -R ${ardour-app}/${bundleName}.app "$dest"
            chmod -R u+w "$dest"
            find "$dest" -exec touch -h {} +

            printf 'exported %s\n' "$dest"
          '';
        };
      in
      {
        packages.default = ardour-app;
        packages.app = ardour-app;
        packages.tree = ardour-package;
        packages.base = ardour-base;
        packages.export-app = export-app;

        apps.export-app = {
          type = "app";
          program = "${export-app}/bin/export-ardour-app";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            pkg-config
            perl
            python311
          ];
          buildInputs = libraries;
          # This is needed for the build system to find sratom's headers and libraries
          shellHook = ''
            export NIX_CFLAGS_COMPILE="$(pkg-config --cflags sratom-0) $NIX_CFLAGS_COMPILE"
          '';
        };
      }
    );
}
