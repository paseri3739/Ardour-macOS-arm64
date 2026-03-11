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

        # for macos, we need to use the custom versions of aubio and vamp plugins
        aubio-custom = pkgs.callPackage ./aubio.nix { };
        vamp-custom = pkgs.callPackage ./vamp.nix { };

        libraries =
          with pkgs;
          [
            boost
            glib
            glibmm
            libsndfile
            curl
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
            lv2
            libxml2
            cppunit
            libwebsockets
            lrdf
            libsamplerate
            serd
            sord
            sratom
            lilv
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
          version = "9.2";

          src = pkgs.fetchFromGitHub {
            owner = "Ardour";
            repo = "ardour";
            rev = "9.2";
            fetchSubmodules = true;
            hash = "sha256-zbEfEuWdhlKtYE0gVB/N0dFrcmNoJqgEMuvQ0wdmRpM=";
          };

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
            printf '#include "ardour/revision.h"\nnamespace ARDOUR { const char* revision = "9.2"; }\n' > libs/ardour/revision.cc

            # バージョン取得ロジックの回避
            substituteInPlace wscript \
              --replace "rev, rev_date = fetch_tarball_revision_date()" "rev, rev_date = '9.2', '2026-03-10'" \
              --replace "rev, rev_date = fetch_git_revision_date()" "rev, rev_date = '9.2', '2026-03-10'"

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
          version = "9.2";

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
      in
      {
        packages.default = ardour-package;
        packages.base = ardour-base;

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
