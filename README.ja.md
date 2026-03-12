# Ardour 9.2 for macOS arm64 with Nix

English version: [README.md](README.md)

このリポジトリには、macOS arm64 向けに Ardour 9.2 をビルドし、
インストールツリーを再配置可能な Nix ランタイムとして再パッケージし、
そのステージ済み出力から `Ardour9.app` バンドルを組み立てる Nix flake が
含まれています。

この flake は当初、nixpkgs ベースの素直なビルドとして始まりましたが、
公式の macOS バンドルとの比較を何度か行ううちに、Ardour の
パッケージングスクリプトが暗黙の外部入力に依存していることがわかりました。
現在のレシピでは、実行時の挙動と公式バンドルとの整合性に影響する箇所で、
そうした入力を明示しています。

## 想定用途

このリポジトリは、開発者向けに再現可能な依存解決および検証環境を提供する
ことを目的としています。完成済み成果物の配布を目的としたものではなく、
このリポジトリからビルドした成果物は再配布しないでください。(公式配布のペイウォールは嫌いなのですが、安易に配布することで作者に資金が入らないのもよくないと思っているのでこのようにしています。わかる人にはわかる状態にしておきたいということです。ライセンス上再配布が問題ないことと実際に再配布するかどうかは別問題なのです。)

## 現在の状態

- `nix build` は macOS arm64 で成功します。
- 生成される `result/bin/ardour9` は正常に起動します。
- 生成される `result/Ardour9.app` は `open` で開けます。
- これまで欠けていた LV2 core/spec バンドル、`Harrison.lv2`、
  `gmsynth.lv2`、同梱メディア、`harvid` 動画ツール、カーソルアイコン
  セット、GTK clearlooks エンジン、および `glib20.mo` /
  `gettext-runtime.mo` / `gettext-tools.mo` カタログが含まれています。

## リポジトリ構成

- `flake.nix`
  メインのビルドおよびパッケージングレシピ。
- `ardour-lv2-stack.nix`
  Ardour 固定版 LV2 スタック用のカスタムレシピ。
- `libwebsockets.nix`
  Ardour 固定版 `libwebsockets` 用のカスタムレシピ。
- `vamp.nix`
  Ardour 固定版 `vamp-plugin-sdk` 用のカスタムレシピ。
- `aubio.nix`
  以前の作業から維持しているカスタム aubio レシピ。
- `arm64-fix.patch`
  Ardour ソースツリーに適用するパッチ。

## flake の構成

この flake は 3 段階で Ardour をビルドします。

### 1. `ardour-base`

`ardour-base` は Ardour 自体をビルドする通常の
`stdenv.mkDerivation` です。

この段階では次を行います。

- サブモジュール付きで `Ardour/ardour` のタグ `9.2` を取得する。
- `arm64-fix.patch` を適用する。
- ビルドが Git メタデータに依存しないよう、静的な `revision.cc` を
  注入する。
- `wscript` を書き換え、バージョンとリビジョン日付の検出がビルド時に
  tarball や Git 状態を問い合わせないようにする。
- 次を実行する。
  - `python3 ./waf configure`
  - `python3 ./waf`
  - `python3 ./waf i18n`
  - `python3 ./waf install`

重要な詳細:

- `python3 ./waf i18n` は必須です。いくつかの翻訳カタログがビルド中に
  生成され、リポジトリにはあらかじめ含まれていないためです。
- `NIX_CFLAGS_COMPILE` には `pkg-config --cflags sratom-0` を追加します。
  そうしないと、Ardour の configure ロジックが Nix 環境内で必要な
  ヘッダーを安定して見つけられませんでした。
- `CFLAGS` と `CXXFLAGS` には `-DDISABLE_VISIBILITY` を追加します。
  このビルドでは macOS 上でこれが必要です。

### 2. `ardour-package`

`ardour-package` は、`ardour-base` のインストール済みツリーを
再パッケージする `stdenvNoCC.mkDerivation` です。

この段階では次を行います。

- `ardour-base` のインストールツリー全体を `$out` にコピーする。
- `lib/ardour9` 以下の Mach-O ファイルを走査する。
- `otool -L` を使って `/nix/store` にある実行時依存を見つける。
- それらの依存物を `lib/ardour9/bundled` にコピーする。
- Mach-O の install name を `@loader_path` 相対参照へ書き換える。
- Ardour のシェルラッパーを書き換え、元の store path を
  ハードコードする代わりに、インストール先パスから `_ardour_root` を
  計算するようにする。
- 公式バンドルが想定している、リポジトリ外の追加リソースを加える。
  - Ardour 同梱メディア zip
  - LV2 spec/core TTL バンドル
  - Harrison XT LV2 バンドル
  - x42 General MIDI synth LV2 バンドル
  - harvid video-tool バンドル

この第 2 段階が必要なのは、`waf install` だけではスタンドアロンの
macOS バンドルや、自己完結した Nix 風ランタイムツリーにならないためです。

### 3. `ardour-app`

`ardour-app` は、`ardour-package` から macOS アプリバンドルを組み立てる
もう 1 つの `stdenvNoCC.mkDerivation` です。

この段階では次を行います。

- `Applications/Ardour9.app/Contents` を作成する。
- `lib/ardour9` を `Contents/lib` に平坦化し、アプリのレイアウトを
  公式 macOS バンドルに近づける。
- ステージ済みの `bundled/`、`appleutility/`、`vamp/` サブツリーを
  `Contents/lib` に畳み込み、Mach-O 参照を書き換えて最終レイアウトを
  公式バンドルにより近づける。
- `share/ardour9` と `etc/ardour9` を `Contents/Resources` にコピーする。
- `Contents/Resources` 内で locale ツリーを再構築し、Ardour が生成した
  カタログと、公式バンドルが使っている追加の `glib` / `gettext`
  カタログをアプリに含められるようにする。
- Ardour ソースの `tools/osx_packaging` から macOS パッケージング資産を
  追加する。
  - `Info.plist.in`
  - `InfoPlist.strings.in`
  - `Resources/fonts.conf`
  - `Ardour.icns`
  - `typeArdour.icns`
- `gtk2_ardour/icons/cursor_square` と `gtk2_ardour/icons/cursor_z` を
  `Contents/Resources/icons` にコピーし、upstream のパッケージング挙動に
  合わせる。
- Ardour ビルド済み clearlooks エンジンから
  `Contents/lib/gtkengines/engines/libclearlooks.so` を作成し、アプリ
  レイアウト向けに Mach-O 参照を書き換える。
- Ardour の GUI バイナリを `Contents/MacOS/Ardour9` にコピーする。
- コピーした実行ファイルを書き換え、その Mach-O 参照が
  `@executable_path/../lib/...` を指すようにして、app bundle レイアウトに
  合わせる。
- `Contents/lib` にトップレベルのアプリ補助実行ファイルを作成する。
  - `ardour9-export`
  - `ardour9-lua`
  - `ardour9-new_session`
  - `ardour9-new_empty_session`
- 補助ツール用に `Contents/MacOS` のシェルラッパーを作成し、公式バンドル
  のパターンに合わせる。
- Ardour 上流テンプレートから `Info.plist` を生成し、次を設定する。
  - `CFBundleExecutable = Ardour9`
  - `CFBundleIdentifier = org.ardour.Ardour9`
  - `LSEnvironment` に `PATH`、
    `DYLIB_FALLBACK_LIBRARY_PATH`、`ARDOUR_BUNDLED=true`

この第 3 段階が必要なのは、動作する Nix ランタイムツリーがまだアプリ
バンドルではなく、メイン GUI 実行ファイルを `Contents/MacOS` にコピーし、
Finder から起動できるよう load command を書き換える必要があるためです。

## 依存関係の選定

現在の flake は混合戦略を採っています。

### nixpkgs のまま使う依存関係

以下は、Ardour 固有のパッチ版がビルド成功や起動成功に必須だという証拠が
なかったため、引き続き nixpkgs から取得しています。

- `boost`
- `glib`
- `glibmm`
- `libsndfile`
- `libarchive`
- `liblo`
- `taglib`
- `rubberband`
- `jack2`
- `fftwFloat`
- `libpng`
- `pango`
- `cairomm`
- `pangomm`
- `libxml2`
- `cppunit`
- `lrdf`
- `libsamplerate`
- `libogg`
- `flac`
- `fontconfig`
- `freetype`
- `readline`

これは恣意的に選んだものではありません。公式の依存関係ドキュメントと
`patch-info` を確認したうえで、残した nixpkgs 版には現在のところ
macOS arm64 でのビルド失敗や起動失敗を説明する明確な阻害要因が
見当たりませんでした。

### Ardour 提供ソースに固定した依存関係

以下は、バンドル比較と公式パッケージングスクリプトの調査により、
nixpkgs 版だと実行時挙動やレイアウトに意味のあるずれが生じると
わかったため、意図的に上書きしています。

- `lv2`
- `serd`
- `sord`
- `sratom`
- `lilv`
- `libwebsockets`
- `vamp-plugin-sdk`

#### LV2 スタックをカスタムにしている理由

ここが最も重要な差分でした。

Ardour の公式ビルドスタックは、現行 nixpkgs と同じ LV2 スタックを
使っていません。Ardour は次の独自 tarball を配布しています。

- `lv2`
- `serd`
- `sord`
- `sratom`
- `lilv`

`ardour-lv2-stack.nix` のカスタムレシピは、それらの正確なソースを
歴史的な Waf ビルドシステムでビルドします。これは見た目だけの差では
ありません。

例:

- nixpkgs の `lv2` は `schemas.lv2/dcterms.ttl` を提供していた
- 公式 Ardour スタックは `schemas.lv2/dct.ttl` と `dcs.ttl` を提供する

公式 macOS バンドルには `dct.ttl` と `dcs.ttl` が含まれていたため、
現行 nixpkgs の `lv2` を使うとバンドル構造が異なったままになります。
カスタム LV2 スタックはこの不一致を解消します。

#### `libwebsockets` をカスタムにしている理由

現行 nixpkgs は、公式バンドルより新しい soname を提供していました。
Ardour スタックは、`libwebsockets.19` をインストールする古い
`4.3.0-14` 系を想定しています。

Ardour の tarball は古く、現行 CMake では次が必要です。

- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`

この互換フラグは `libwebsockets.nix` に組み込んであります。

#### `vamp` をカスタムにしている理由

公式バンドルと現行 Ardour 依存関係ドキュメントは、現行 nixpkgs の
命名ときれいに一致しません。そのためこの flake では、GitHub release
ではなく Ardour がホストしている `vamp-plugin-sdk` tarball を使います。

比較対象にした特定の公式 `Ardour9.app` と比べると、まだ次の命名差が
残っています。

- 現在の flake 出力が同梱するもの:
  - `libvamp-sdk-dynamic.2.9.0.dylib`
  - `libvamp-hostsdk.3.9.0.dylib`
- 比較対象バンドルが使うもの:
  - `libvamp-sdk.2.dylib`
  - `libvamp-hostsdk.2.dylib`

これは既知の残差分です。現時点では起動の妨げにはなっていません。

## 暗黙依存を明示化したもの

今回の調査で最も重要だった成果は、Ardour の公式パッケージングが
リポジトリ単体では完結していないとわかったことです。この flake では、
特に重要な暗黙依存をコード化しています。

### 1. LV2 spec/core バンドル

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は `build/libs/LV2` をコピーする
- その後さらに `$GTKSTACK_ROOT/lib/lv2/*.lv2` から `*.ttl` をコピーする

つまり公式バンドルは、Ardour 自身が生成しない外部 LV2 spec バンドルを
前提にしています。

この flake では、次で再現しています。

- Ardour 固定版 `lv2` パッケージをビルドする
- その `lib/lv2/*.lv2/*.ttl` をステージ済みランタイムツリーへコピーする
- アプリ組み立て時にそれらのバンドルを `Contents/lib/LV2` へ持ち込む

この手順がないと、出力には `schemas.lv2` など、公式バンドルに入っていた
コア LV2 メタデータが欠けていました。

### 2. 同梱メディア

これはもう 1 つの大きな隠れた入力でした。

公式パッケージングスクリプトでの根拠:

- まず Ardour ソースツリーから `share/media` をコピーする
- 後で `http://stuff.ardour.org/loops/ArdourBundledMedia.zip` を取得する
- その zip を同じ media ディレクトリへ展開する

リポジトリ自体には、次しか含まれていません。

- `.daw-meta.xml`
- `click.mid`
- `click-120bpm.flac`

巨大な `MIDI Beats`、`MIDI Chords`、`MIDI Progressions` ツリーは、
リポジトリ由来ではなく外部 zip 由来です。

現在の flake では次を固定しています。

- `http://stuff.ardour.org/loops/ArdourBundledMedia.zip`
- hash: `sha256-oA3gBnHNwymyyjXCpcQVCvPWWIFH+dyi496nUqouI0w=`

そして `ardour-package` 中で展開しています。

これにより、このメディア依存が明示的かつ再現可能になります。

### 3. Harrison LV2 バンドル

これも Ardour リポジトリからビルドされるものではなく、
パッケージング時依存です。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は `WITH_HARRISON_LV2` を有効にする
- その後 `harrison_lv2s-n.<platform>.zip` をダウンロードする
- それを `Contents/lib/LV2` に展開する

リポジトリの `wscript` は `Harrison.lv2` をビルドしません。ビルドするのは
`a-comp.lv2` や `a-eq.lv2` のような Ardour ネイティブの LV2 バンドルです。

この flake では、`aarch64-darwin` 向け Harrison バンドルを固定して
展開することで再現しています。

### 4. harvid 動画ツール

これも Ardour 自身のビルドグラフではなく、パッケージング時依存です。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は `WITH_HARVID` を有効にする
- `harvid_version.txt` を読む
- `harvid-macOS-arm64-<version>.tgz` をダウンロードする
- そのアーカイブをアプリルートに展開し、次を生成する
  - `Contents/MacOS/harvid`
  - `Contents/MacOS/ffmpeg_harvid`
  - `Contents/MacOS/ffprobe_harvid`
  - `Contents/lib/harvid/*`

Ardour ソースツリーは実行時に動画タイムライン対応のため `harvid` を
参照しますが、これらのバイナリ自体はビルドしません。

この flake では、対応する `harvid` アーカイブを固定し、
`ardour-package` でステージして `Ardour9.app` に持ち込むことで
再現しています。

### 5. カーソルアイコンセット

これは外部ダウンロードではありませんが、やはりパッケージング時の
暗黙依存です。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は `../../gtk2_ardour/icons/cursor_*` を
  `Contents/Resources/icons` にコピーする

重要なのは、`waf install` だけではカーソルセット全体がインストール
されないことです。`gtk2_ardour/wscript` ではカーソル PNG の install が
コメントアウトされており、インストールされるのは
`icons/cursor_square/hotspots` だけです。

実行時、Ardour のカーソルローダーはカーソルセットのサブディレクトリが
存在することを前提とし、その中の hotspot メタデータを読みます。つまり
`cursor_square` と `cursor_z` は見た目だけの追加ではなく、
実際の実行時リソースです。

この flake では、`ardour-app` 中でこれらのディレクトリを Ardour
ソースツリーから直接 `Contents/Resources/icons` へコピーすることで
再現しています。

### 6. `gmsynth.lv2`

これも外部のパッケージング依存です。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は `WITH_GMSYNTH` を有効にする
- その後 `x42-gmsynth-lv2-macOS-<version>.zip` をダウンロードする
- そのバンドルを `Contents/lib/LV2` に展開する

Ardour リポジトリはこのプラグインを General MIDI 用フォールバック
シンセとして参照していますが、`gmsynth.lv2` 自体はビルドしません。

この flake では、x42 の macOS 用 LV2 アーカイブを固定し、
`ardour-package` 中で展開することで再現しています。

### 7. Clearlooks GTK エンジン

これは外部ダウンロードではありませんが、`waf install` だけでは正しく
再現されません。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` は
  `build/libs/clearlooks-newer/libclearlooks.dylib` をコピーする
- それを `Contents/lib/gtkengines/engines/libclearlooks.so` として
  インストールする

Ardour ソースツリーには `libs/clearlooks-newer` が含まれており、
ビルドでエンジン自体は生成されますが、アプリ内の GTK ランタイム期待に
合わせるにはバンドル固有の配置が必要です。

この flake では、`ardour-base` 中でビルドツリーから生成済みエンジンを
取り出し、その後 `ardour-app` 中で最終アプリレイアウト向けに Mach-O
パスを書き換えたうえで
`Contents/lib/gtkengines/engines/libclearlooks.so` を構成しています。

### 8. GTK/Gettext の locale カタログ

これは一部がパッケージング時の暗黙依存であり、一部がスタック版数差です。

公式パッケージングスクリプトでの根拠:

- `tools/osx_packaging/osx_build` はまず、リポジトリ/ビルドツリーから
  Ardour 自身の `.mo` ファイルをコピーする
- その後さらに `$GTKSTACK_ROOT/share/locale` から locale ディレクトリを
  コピーする

実際の公式アプリには、たとえば次の追加カタログが入っています。

- `glib20.mo`
- `gettext-runtime.mo`
- `gettext-tools.mo`

これらのカタログは Ardour リポジトリ自体には由来しません。
パッケージング時に使われた外部 GTK/Gettext スタック由来です。

この flake では、`ardour-app` 中で nixpkgs の `glib` と `gettext` から
対応するカタログを追加することで再現しています。これは意図的に
`gtkmm2ext3.mo` を `gtkmm2ext9.mo` へ改名していません。

その改名は upstream のパッケージングスクリプトにはありますが、
ソースツリーとビルド済み `libgtkmm2ext.dylib` はどちらも依然として
`gtkmm2ext3` 翻訳ドメインを使っているため、現時点では実行時必須要件とは
みなしていません。

## 公式との差分で残っているもの

現在の出力は、当初の nixpkgs のみのビルドより公式バンドルにかなり
近づいていますが、完全一致ではありません。

既知の残差分:

- コード署名や notarization はない
- `vamp` の命名は比較対象バンドルとまだ異なる
- 追加した `glib20.mo` / `gettext-runtime.mo` / `gettext-tools.mo`
  カタログは現行 nixpkgs の `glib` と `gettext` 由来なので、
  比較対象バンドル内の古いカタログとは内容が異なる
- `gtkmm2ext3.mo` は、公式パッケージングスクリプトのように
  `gtkmm2ext9.mo` へ改名せず、ビルド時のドメイン名のまま保持している
- アプリのレイアウトは公式バンドルにかなり近づいたが、一部のライブラリ名
  やバージョンは比較対象バンドルとまだ異なる

これらを後回しにしたのは、次の方が優先度が高かったためです。

- ビルドを成功させること
- 起動を成功させること
- 欠けていた LV2 メタデータを補うこと
- 欠けていた同梱メディアを補うこと
- 欠けていた同梱プラグインと GTK エンジンを補うこと

## 試行錯誤の経緯まとめ

現在の flake は、いくつかの失敗または不十分だったアプローチを経て
できあがっています。

### 初期アプローチ

当初は、Ardour を nixpkgs の依存だけでビルドし、`waf install` に頼る
という考えでした。

これは不十分でした。理由は次のとおりです。

- 結果が自己完結していなかった
- 多くの実行時依存がまだ `/nix/store` を指していた
- バンドルレイアウトが公式 macOS パッケージと大きく異なっていた

### 最初のパッケージング段階

次に 2 段階目を追加して、以下を行いました。

- Mach-O 依存を走査する
- store のライブラリを `bundled` にコピーする
- install name を書き換える

これで出力は実行可能になりましたが、欠けているリソースツリーまでは
解決しませんでした。

### LV2 の調査

公式アプリとの比較で LV2 スキーマファイルの欠落が見つかり、
`tools/osx_packaging/osx_build` を調べた結果、公式バンドルが
リポジトリではなく外部スタックから LV2 TTL ファイルをコピーしていると
わかりました。

そこから次につながりました。

- LV2 スタックの版数不一致を特定する
- LV2 関連依存を nixpkgs 版から Ardour ホスト版ソースへ置き換える

### メディアの調査

公式アプリとの比較でメディア差分も非常に大きいことがわかりました。
そこから次が判明しました。

- リポジトリには click ファイルしかない
- 実際のコンテンツは `ArdourBundledMedia.zip` から取得される

これは現在、flake にも組み込まれています。

## 使い方

### ビルド

```bash
nix build
```

デフォルトではアプリバンドルをビルドします。

中間生成物であるステージ済みランタイムツリーが必要なら、代わりに次を
使ってください。

```bash
nix build .#tree
```

### 開発シェル

```bash
nix develop
```

## 出力結果のレイアウト

結果の重要な部分は次のとおりです。

- `result/Ardour9.app`
  Nix 出力内のアプリバンドルへの便宜的なシンボリックリンク。
- `result/Ardour9.app/Contents/MacOS/Ardour9`
  メイン GUI 実行ファイル。
- `result/Ardour9.app/Contents/lib`
  メインライブラリ、スキャナ、プラグイン、補助実行ファイル、同梱 dylib。
- `result/Ardour9.app/Contents/lib/LV2`
  Ardour の LV2 プラグインと、外部の LV2 spec/core TTL バンドル。
- `result/Ardour9.app/Contents/Resources`
  Ardour のデータ/設定リソースと macOS パッケージング資産。
- `result/Ardour9.app/Contents/Resources/media`
  リポジトリ由来メディアと `ArdourBundledMedia.zip` の内容。

## さらに進めるなら

次にやる可能性が高いものは以下です。

- `vamp` の dylib 名を公式バンドルに合わせて正規化するか決める
- さらに多くのライブラリ名と soname を比較対象バンドルに合わせて
  正規化するか決める
- リリース品質の macOS 配布が必要なら、Nix ビルドの外側で
  署名/notarization を追加する
