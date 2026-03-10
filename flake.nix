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
            # 実際のハッシュ値に書き換えてください（前回成功していればそのままで構いません）
            hash = "sha256-zbEfEuWdhlKtYE0gVB/N0dFrcmNoJqgEMuvQ0wdmRpM="; # 例：適宜修正
          };

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

          # バージョン取得ロジックの無効化とリビジョンファイルの生成
          postPatch = ''
            # wscriptのバージョン取得関数を上書きしてIndexErrorを回避
            substituteInPlace wscript \
              --replace "rev, rev_date = fetch_tarball_revision_date()" "rev, rev_date = '9.2', '2026-03-10'" \
              --replace "rev, rev_date = fetch_git_revision_date()" "rev, rev_date = '9.2', '2026-03-10'"

            # リビジョンファイルの作成
            mkdir -p libs/ardour
            printf '#include "ardour/revision.h"\nnamespace ARDOUR { const char* revision = "9.2"; }\n' > libs/ardour/revision.cc

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

            python3 ./waf install

            # macOS用パッケージング
            pushd tools/osx_packaging
            patchShebangs osx_build

            # 注: osx_buildが内部でシステムのXcodeツールに依存している場合、
            # サンドボックス内で実行するために環境変数の調整が必要になることがあります
            ./osx_build
            popd

            # 成果物の配置
            mkdir -p $out/Applications
            if [ -d "tools/osx_packaging/Ardour/Ardour9.app" ]; then
              cp -r tools/osx_packaging/Ardour/Ardour9.app $out/Applications/
            else
              echo "Error: Ardour9.app not found. Content of tools/osx_packaging/Ardour:"
              ls -la tools/osx_packaging/Ardour || true
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
