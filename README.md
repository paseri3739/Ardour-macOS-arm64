# Ardour 9.2 for macOS arm64 with Nix

This repository contains a Nix flake that builds Ardour 9.2 on macOS arm64,
repackages the install tree into a relocatable Nix runtime, and then assembles
an `Ardour9.app` bundle from that staged output.

The flake started as a straightforward nixpkgs-based build, but several rounds
of comparison against the official macOS bundle showed that Ardour's packaging
scripts rely on implicit external inputs. The current recipe makes those inputs
explicit where they matter for runtime behavior and bundle parity.

## Current status

- `nix build` succeeds on macOS arm64.
- The resulting `result/bin/ardour9` launches successfully.
- The resulting `result/Ardour9.app` can be opened with `open`.
- The LV2 core/spec bundles, `Harrison.lv2`, bundled media, `harvid`
  video tools, and cursor icon sets that were previously missing are now
  included.

## Repository layout

- `flake.nix`
  Main build and packaging recipe.
- `ardour-lv2-stack.nix`
  Custom recipes for the Ardour-pinned LV2 stack.
- `libwebsockets.nix`
  Custom recipe for the Ardour-pinned `libwebsockets`.
- `vamp.nix`
  Custom recipe for the Ardour-pinned `vamp-plugin-sdk`.
- `aubio.nix`
  Custom aubio recipe kept from earlier work.
- `arm64-fix.patch`
  Patch applied to the Ardour source tree.

## How the flake is structured

The flake builds Ardour in three stages.

### 1. `ardour-base`

`ardour-base` is a normal `stdenv.mkDerivation` that builds Ardour itself.

It does the following:

- Fetches `Ardour/ardour` at tag `9.2` with submodules.
- Applies `arm64-fix.patch`.
- Injects a static `revision.cc` so the build does not depend on Git metadata.
- Rewrites `wscript` so version and revision date detection do not try to query
  tarball or Git state at build time.
- Runs:
  - `python3 ./waf configure`
  - `python3 ./waf`
  - `python3 ./waf i18n`
  - `python3 ./waf install`

Important details:

- `python3 ./waf i18n` is required because some translation catalogs are
  generated during the build and are not already present in the repo.
- `NIX_CFLAGS_COMPILE` is extended with `pkg-config --cflags sratom-0` because
  Ardour's configure logic was otherwise not reliably finding the required
  headers in the Nix environment.
- `CFLAGS` and `CXXFLAGS` add `-DDISABLE_VISIBILITY`, which is needed on macOS
  for this build.

### 2. `ardour-package`

`ardour-package` is a `stdenvNoCC.mkDerivation` that repackages the installed
  tree from `ardour-base`.

It does the following:

- Copies the full install tree from `ardour-base` into `$out`.
- Traverses Mach-O files under `lib/ardour9`.
- Uses `otool -L` to find `/nix/store` runtime dependencies.
- Copies those dependencies into `lib/ardour9/bundled`.
- Rewrites Mach-O install names to use `@loader_path`-relative references.
- Rewrites the Ardour shell wrappers so they compute `_ardour_root` from the
  installed path instead of hard-coding the original store path.
- Adds extra non-repo resources that the official bundle expects:
  - Ardour bundled media zip
  - LV2 spec/core TTL bundles
  - Harrison XT LV2 bundle
  - harvid video-tool bundle

This second stage exists because `waf install` alone does not produce a
standalone macOS bundle or a self-contained Nix-style runtime tree.

### 3. `ardour-app`

`ardour-app` is a second `stdenvNoCC.mkDerivation` that assembles a macOS app
bundle from `ardour-package`.

It does the following:

- Creates `Applications/Ardour9.app/Contents`.
- Flattens `lib/ardour9` into `Contents/lib` so the app layout is closer to the
  official macOS bundle.
- Copies `share/ardour9` and `etc/ardour9` into `Contents/Resources`.
- Adds macOS packaging assets from `tools/osx_packaging` in the Ardour source:
  - `Info.plist.in`
  - `InfoPlist.strings.in`
  - `Resources/fonts.conf`
  - `Ardour.icns`
  - `typeArdour.icns`
- Copies `gtk2_ardour/icons/cursor_square` and `gtk2_ardour/icons/cursor_z`
  into `Contents/Resources/icons`, matching upstream packaging behavior.
- Copies the Ardour GUI binary into `Contents/MacOS/Ardour9`.
- Rewrites the copied executable so its Mach-O references point at
  `@executable_path/../lib/...`, matching app-bundle layout.
- Creates top-level app helper executables in `Contents/lib` for:
  - `ardour9-export`
  - `ardour9-lua`
  - `ardour9-new_session`
  - `ardour9-new_empty_session`
- Creates `Contents/MacOS` shell wrappers for the helper tools, following the
  official bundle pattern.
- Generates `Info.plist` from Ardour's upstream template and sets:
  - `CFBundleExecutable = Ardour9`
  - `CFBundleIdentifier = org.ardour.Ardour9`
  - `LSEnvironment` with `PATH`, `DYLIB_FALLBACK_LIBRARY_PATH`, and
    `ARDOUR_BUNDLED=true`

This third stage exists because the working Nix runtime tree is not yet an app
bundle, and the main GUI executable must be copied into `Contents/MacOS` with
its load commands rewritten for Finder-style launch.

## Dependency selection

The current flake uses a mixed strategy.

### Dependencies kept from nixpkgs

The following are still taken from nixpkgs because there was no evidence that
Ardour-specific patched variants were required for successful build and launch:

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

This was not chosen arbitrarily. The official dependency documentation and
`patch-info` were checked, and the remaining nixpkgs versions do not currently
show a blocker that would explain build or launch failure on macOS arm64.

### Dependencies pinned to Ardour-provided sources

The following are intentionally overridden because bundle comparisons and the
official packaging scripts showed that nixpkgs versions caused meaningful
runtime or layout drift:

- `lv2`
- `serd`
- `sord`
- `sratom`
- `lilv`
- `libwebsockets`
- `vamp-plugin-sdk`

#### Why the LV2 stack is custom

This was the most important divergence.

The official Ardour build stack does not use the same LV2 stack as current
nixpkgs. Ardour ships its own tarballs for:

- `lv2`
- `serd`
- `sord`
- `sratom`
- `lilv`

The custom recipe in `ardour-lv2-stack.nix` builds those exact sources with
their historical Waf build system. This matters because the difference is not
just cosmetic.

Example:

- nixpkgs `lv2` provided `schemas.lv2/dcterms.ttl`
- the official Ardour stack provides `schemas.lv2/dct.ttl` and `dcs.ttl`

The official macOS bundle contained `dct.ttl` and `dcs.ttl`, so using current
nixpkgs `lv2` left the bundle structurally different. The custom LV2 stack
removes that mismatch.

#### Why `libwebsockets` is custom

Current nixpkgs provided a newer soname than the official bundle. The Ardour
stack expects the older `4.3.0-14` branch, which installs `libwebsockets.19`.

The Ardour tarball is old enough to require:

- `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`

with current CMake. That compatibility flag is baked into `libwebsockets.nix`.

#### Why `vamp` is custom

The official bundle and the current Ardour dependency documentation do not line
up cleanly with current nixpkgs naming. The flake therefore uses the
Ardour-hosted `vamp-plugin-sdk` tarball instead of the GitHub release.

There is still a remaining naming mismatch versus the specific official
`Ardour9.app` used for comparison:

- current flake output bundles:
  - `libvamp-sdk-dynamic.2.9.0.dylib`
  - `libvamp-hostsdk.3.9.0.dylib`
- comparison bundle uses:
  - `libvamp-sdk.2.dylib`
  - `libvamp-hostsdk.2.dylib`

This is a known remaining difference. It does not currently block launch.

## Implicit dependencies made explicit

The most important outcome of the investigation was that Ardour's official
packaging is not repo-only. The flake now codifies the most relevant implicit
dependencies.

### 1. LV2 spec/core bundles

Evidence in the official packaging script:

- `tools/osx_packaging/osx_build` copies `build/libs/LV2`
- then it additionally copies `*.ttl` from `$GTKSTACK_ROOT/lib/lv2/*.lv2`

This means the official bundle expects external LV2 spec bundles that are not
produced by Ardour itself.

In the flake, this is reproduced by:

- building the Ardour-pinned `lv2` package
- copying its `lib/lv2/*.lv2/*.ttl` into the staged runtime tree
- carrying those bundles into `Contents/lib/LV2` during app assembly

Without this step, the output was missing `schemas.lv2` and other core LV2
metadata that the official bundle contained.

### 2. Bundled media

This was the other major hidden input.

Evidence in the official packaging script:

- first it copies `share/media` from the Ardour source tree
- later it downloads `http://stuff.ardour.org/loops/ArdourBundledMedia.zip`
- then it extracts that zip into the same media directory

The repo itself only contains:

- `.daw-meta.xml`
- `click.mid`
- `click-120bpm.flac`

The huge `MIDI Beats`, `MIDI Chords`, and `MIDI Progressions` trees come from
that external zip, not from the repository.

The flake now pins:

- `http://stuff.ardour.org/loops/ArdourBundledMedia.zip`
- hash: `sha256-oA3gBnHNwymyyjXCpcQVCvPWWIFH+dyi496nUqouI0w=`

and extracts it during `ardour-package`.

This makes the media dependency explicit and reproducible.

### 3. Harrison LV2 bundle

This is another packaging-time dependency, not something built from the Ardour
repo.

Evidence in the official packaging script:

- `tools/osx_packaging/osx_build` enables `WITH_HARRISON_LV2`
- then it downloads `harrison_lv2s-n.<platform>.zip`
- then it extracts that zip into `Contents/lib/LV2`

The repo's `wscript` files do not build `Harrison.lv2`. They only build the
Ardour-native LV2 bundles such as `a-comp.lv2` and `a-eq.lv2`.

In the flake, this is reproduced by pinning and extracting the Harrison bundle
for `aarch64-darwin`.

### 4. harvid video tools

This is also a packaging-time dependency, not something built by Ardour's own
build graph.

Evidence in the official packaging script:

- `tools/osx_packaging/osx_build` enables `WITH_HARVID`
- it reads `harvid_version.txt`
- it downloads `harvid-macOS-arm64-<version>.tgz`
- it extracts that archive into the app root, producing:
  - `Contents/MacOS/harvid`
  - `Contents/MacOS/ffmpeg_harvid`
  - `Contents/MacOS/ffprobe_harvid`
  - `Contents/lib/harvid/*`

The Ardour source tree references `harvid` at runtime for video timeline
support, but it does not build those binaries itself.

In the flake, this is reproduced by pinning the matching `harvid` archive,
staging it in `ardour-package`, and carrying it into `Ardour9.app`.

### 5. Cursor icon sets

This one is not an external download, but it is still a packaging-time implicit
dependency.

Evidence in the official packaging script:

- `tools/osx_packaging/osx_build` copies `../../gtk2_ardour/icons/cursor_*`
  into `Contents/Resources/icons`

The important detail is that `waf install` does not install the full cursor set.
In `gtk2_ardour/wscript`, the cursor PNG install is commented out and only the
`icons/cursor_square/hotspots` file is installed.

At runtime, Ardour's cursor loader expects the cursor-set subdirectories to be
present and reads the hotspot metadata from inside them. This means
`cursor_square` and `cursor_z` are real runtime resources, not cosmetic extras.

In the flake, this is reproduced by copying those directories directly from the
Ardour source tree into `Contents/Resources/icons` during `ardour-app`.

## Why some official differences remain

The current output is much closer to the official bundle than the initial
nixpkgs-only build, but it is not identical.

Remaining known differences:

- no code signing or notarization
- `vamp` naming still differs from the comparison bundle
- extra GTK/Gettext locale catalogs such as `gettext-runtime.mo`,
  `gettext-tools.mo`, `glib20.mo`, and some `gtkmm2ext9.mo` files are still
  missing
- the app uses a partially officialized layout:
  - `Contents/lib` is flattened like the official bundle
  - but some packaging details such as `bundled/` and extra helper remnants are
    still carried over from the staged runtime tree

These were intentionally deferred because they are less critical than:

- building successfully
- launching successfully
- fixing the missing LV2 metadata
- fixing the missing bundled media

## Trial-and-error history summarized

The current flake is the result of several failed or incomplete approaches.

### Initial approach

The original idea was to build Ardour only against nixpkgs dependencies and rely
on `waf install`.

This was insufficient because:

- the result was not self-contained
- many runtime dependencies still pointed at `/nix/store`
- bundle layout diverged strongly from the official macOS package

### First packaging pass

A second step was added to:

- crawl Mach-O dependencies
- copy store libraries into `bundled`
- rewrite install names

This made the output runnable, but did not solve missing resource trees.

### LV2 investigation

Comparison against the official app showed missing LV2 schema files. This led to
inspection of `tools/osx_packaging/osx_build`, which revealed that the official
bundle copied LV2 TTL files from an external stack rather than the repo.

That in turn led to:

- identifying the LV2 stack version mismatch
- replacing nixpkgs LV2-related dependencies with Ardour-hosted sources

### Media investigation

Comparison against the official app also showed an enormous media difference.
That led to the discovery that:

- the repo has only the click files
- the real content is pulled from `ArdourBundledMedia.zip`

This is now also encoded in the flake.

## Usage

### Build

```bash
nix build
```

This builds the app bundle by default.

If you want the intermediate staged runtime tree instead:

```bash
nix build .#tree
```

### Development shell

```bash
nix develop
```

## Result layout

Important parts of the result are:

- `result/Ardour9.app`
  Convenience symlink to the app bundle inside the Nix output.
- `result/Ardour9.app/Contents/MacOS/Ardour9`
  Main GUI executable.
- `result/Ardour9.app/Contents/lib`
  Main libraries, scanners, plugins, helper executables, and bundled dylibs.
- `result/Ardour9.app/Contents/lib/LV2`
  Ardour LV2 plugins plus the external LV2 spec/core TTL bundles.
- `result/Ardour9.app/Contents/Resources`
  Ardour data/config resources plus macOS packaging assets.
- `result/Ardour9.app/Contents/Resources/media`
  Repo media plus `ArdourBundledMedia.zip` content.

## If you want to go further

The next likely steps are:

- decide whether to normalize `vamp` dylib names to match the official bundle
- add the remaining locale assets that are still only present in the official
  bundle
- decide whether to flatten the remaining `bundled/` and helper layout
  differences inside `Contents/lib`
- add signing/notarization outside of the Nix build if release-grade macOS
  distribution is required
