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

                python3 <<'PY'
import os
import shutil
import subprocess
from collections import deque

ardour_lib = os.environ["ardourLib"]
bundled_dir = os.environ["bundledLibDir"]
out_root = os.environ["out"]


def is_macho(path: str) -> bool:
    try:
        out = subprocess.check_output(["file", "-b", path], text=True)
    except subprocess.CalledProcessError:
        return False
    return "Mach-O" in out


def macho_deps(path: str) -> list[str]:
    out = subprocess.check_output(["otool", "-L", path], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        deps.append(line.split(" ", 1)[0])
    return deps


def should_bundle(dep: str) -> bool:
    return (
        dep.startswith("/nix/store/")
        and not dep.startswith(out_root + "/")
        and not dep.startswith("/System/Library/")
        and not dep.startswith("/usr/lib/")
    )


queue = deque()
seen = set()

for root, _, files in os.walk(ardour_lib):
    for name in files:
        path = os.path.join(root, name)
        if is_macho(path):
            queue.append(path)

while queue:
    path = queue.popleft()
    if path in seen:
        continue
    seen.add(path)
    if not is_macho(path):
        continue

    for dep in macho_deps(path):
        if not should_bundle(dep):
            continue

        target = os.path.join(bundled_dir, os.path.basename(dep))
        if not os.path.exists(target):
            shutil.copy2(dep, target)
            os.chmod(target, os.stat(target).st_mode | 0o200)
            queue.append(target)
PY

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
            resourcesDir="$appRoot/Resources"
            libDir="$appRoot/lib"
            macosDir="$appRoot/MacOS"
            lv2Dir="$libDir/LV2"

            mkdir -p "$resourcesDir" "$libDir" "$macosDir" "$lv2Dir"

            cp -a ${ardour-package}/lib/ardour9/. "$libDir/"
            chmod -R u+w "$libDir"

            while IFS= read -r -d "" entry; do
              cp -a "$entry" "$resourcesDir/"
            done < <(find ${ardour-package}/share/ardour9 -mindepth 1 -maxdepth 1 -print0)

            while IFS= read -r -d "" entry; do
              cp -a "$entry" "$resourcesDir/"
            done < <(find ${ardour-package}/etc/ardour9 -mindepth 1 -maxdepth 1 -print0)
            chmod -R u+w "$resourcesDir"

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

            export resourcesDir libDir macosDir

            python3 <<'PY'
import os
import subprocess
from pathlib import Path


def macho_deps(path: Path) -> list[str]:
    out = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if line:
            deps.append(line.split(" ", 1)[0])
    return deps


def patch_executable(path: Path) -> None:
    for dep in macho_deps(path):
        if dep.startswith("@loader_path/../"):
            new_dep = "@executable_path/../lib/" + dep[len("@loader_path/../") :]
        elif dep.startswith("@loader_path/"):
            new_dep = "@executable_path/../lib/" + dep[len("@loader_path/") :]
        else:
            continue
        subprocess.check_call(["install_name_tool", "-change", dep, new_dep, str(path)])


lib_dir = Path(os.environ["libDir"])
macos_dir = Path(os.environ["macosDir"])

main_executable = macos_dir / "${bundleName}"
main_executable.write_bytes((lib_dir / "ardour-${releaseVersion}").read_bytes())
main_executable.chmod(0o755)
patch_executable(main_executable)

for name in ("ardour9-export", "ardour9-new_session", "ardour9-new_empty_session"):
    target = lib_dir / name
    target.write_bytes((lib_dir / "utils" / name).read_bytes())
    target.chmod(0o755)
    patch_executable(target)

lua_target = lib_dir / "ardour9-lua"
lua_target.write_bytes((lib_dir / "luasession").read_bytes())
lua_target.chmod(0o755)
patch_executable(lua_target)
PY

            cat > "$macosDir/ardour9-export" <<'EOF'
#!/bin/sh

BIN_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUNDLE_DIR=$(dirname "$BIN_DIR")

export ARDOUR_DATA_PATH="$BUNDLE_DIR/Resources"
export ARDOUR_CONFIG_PATH="$BUNDLE_DIR/Resources"
export ARDOUR_DLL_PATH="$BUNDLE_DIR/lib"
export VAMP_PATH="$BUNDLE_DIR/lib/vamp''${VAMP_PATH:+:$VAMP_PATH}"

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
