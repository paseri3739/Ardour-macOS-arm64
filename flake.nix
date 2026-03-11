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

        ardour-package = pkgs.stdenv.mkDerivation {
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

            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
              ardourLib="$out/lib/ardour9"
              buildPrefix="/source/build/libs/"

              if [ -d "$ardourLib" ]; then
                while IFS= read -r -d "" macho; do
                  if ! file -b "$macho" | grep -q "Mach-O"; then
                    continue
                  fi

                  case "$macho" in
                    *.dylib)
                      install_name_tool -id "$macho" "$macho"
                      ;;
                  esac

                  while IFS= read -r dep; do
                    case "$dep" in
                      *"$buildPrefix"*)
                        depBase="$(basename "$dep")"
                        target="$(find -L "$ardourLib" -name "$depBase" | head -n 1)"
                        if [ -n "$target" ]; then
                          install_name_tool -change "$dep" "$target" "$macho"
                        else
                          echo "warning: no installed Mach-O match for $dep in $macho" >&2
                        fi
                        ;;
                    esac
                  done < <(otool -L "$macho" | tail -n +2 | awk '{print $1}')
                done < <(find "$ardourLib" -type f \( -perm -111 -o -name "*.dylib" \) -print0)
              fi
            ''}

            runHook postInstall
          '';
        };
      in
      {
        packages.default = ardour-package;

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
