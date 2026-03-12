{
  lib,
  stdenv,
  fetchurl,
  pkg-config,
  libsndfile,
  # install_name_tool を使用するために必要
  fixDarwinDylibNames,
}:

stdenv.mkDerivation rec {
  pname = "vamp-plugin-sdk";
  version = "2.9.0";

  src = fetchurl {
    url = "https://ardour.org/files/deps/vamp-plugin-sdk-${version}.tar.gz";
    hash = "sha256-typ474/4qSfcLtfmbs9MYtIyaKXXTQLaJb4rjQA0EJk=";
  };

  nativeBuildInputs = [ pkg-config ] ++ lib.optional stdenv.isDarwin fixDarwinDylibNames;
  buildInputs = [ libsndfile ];

  # build is susceptible to race conditions: https://github.com/vamp-plugins/vamp-plugin-sdk/issues/12
  enableParallelBuilding = false;

  # Darwin 環境での Makefile フラグの調整
  makeFlags = [
    "AR:=$(AR)"
    "RANLIB:=$(RANLIB)"
  ]
  ++ lib.optional (stdenv.buildPlatform != stdenv.hostPlatform) "-o test"
  ++ lib.optionals stdenv.isDarwin [
    "PLUGIN_EXT=.dylib"
    "VAMP_SDK_DYNAMIC_EXTENSION=.dylib"
    "VAMP_HOSTSDK_DYNAMIC_EXTENSION=.dylib"
    "LINK_SDK_DYNAMIC=-dynamiclib"
  ];

  # インストール後の後処理
  # .so として生成されてしまった場合の修正と、install_name の解決
  postInstall = lib.optionalString stdenv.isDarwin ''
    # もし .so が生成されていたら .dylib にリネームする
    for lib in $out/lib/*.so; do
      if [ -f "$lib" ]; then
        mv "$lib" "''${lib%.so}.dylib"
      fi
    done

    # 実行ファイルが参照する際の ID を絶対パスに設定する
    # これにより dyld が Nix store 内のライブラリを正しく発見できるようになります
    install_name_tool -id $out/lib/libvamp-sdk.dylib $out/lib/libvamp-sdk.dylib
    install_name_tool -id $out/lib/libvamp-hostsdk.dylib $out/lib/libvamp-hostsdk.dylib
  '';

  meta = {
    description = "Audio processing plugin system for plugins that extract descriptive information from audio data";
    homepage = "https://vamp-plugins.org/";
    license = lib.licenses.bsd3;
    maintainers = [ lib.maintainers.marcweber ];
    platforms = lib.platforms.unix;
  };
}
