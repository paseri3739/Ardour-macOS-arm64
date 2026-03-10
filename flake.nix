{
  description = "Ardour 9.2 dependencies and build environment";

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

          # 作成したパッチファイルを適用
          patches = [
            ./arm64-fix.patch
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
            python311
            perl
            gettext
            itstool
            makeWrapper
          ];

          buildInputs = libraries;

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

            # 1. ビルド済みファイルのインストール
            python3 ./waf install

            # 2. tools/osx_packaging/osx_build の実行
            pushd tools/osx_packaging
            patchShebangs osx_build
            ./osx_build
            popd

            # 3. 成果物 Ardour9.app の配置
            mkdir -p $out/Applications
            if [ -d "tools/osx_packaging/Ardour/Ardour9.app" ]; then
              cp -r tools/osx_packaging/Ardour/Ardour9.app $out/Applications/
            else
              echo "Error: Resulting Ardour9.app not found in expected path."
              exit 1
            fi

            runHook postInstall
          '';
        };
      in
      {
        packages.default = ardour-package;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            pkg-config
            python311
          ];
          buildInputs = libraries;
          shellHook = ''
            export NIX_CFLAGS_COMPILE="$(pkg-config --cflags sratom-0) $NIX_CFLAGS_COMPILE"
          '';
        };
      }
    );
}
