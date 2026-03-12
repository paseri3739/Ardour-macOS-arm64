# Ardour macOS arm64 Build / Packaging Context

## Goal

- Build Ardour 9.2 for macOS arm64 with Nix.
- Make the build output runnable outside the original Nix build sandbox.
- Compare against the official distributed app and close packaging gaps where practical.

## Current Status

- Local `nix build` succeeds.
- The generated `result/bin/ardour9` launches successfully on the host macOS environment.
- GUI launch, new session creation, and CoreAudio speaker output were confirmed on the host machine.
- On a clean macOS VM, both the custom build output and the official `Ardour9.app` crash when starting a new session.
- The current VM crash is not a dylib resolution failure. It is an OpenGL / NSOpenGL canvas crash.

## Repository / Output Structure

- Main recipe: [flake.nix](/Users/masato/Documents/Ardour-macOS-arm64/flake.nix)
- Related overrides:
  - [aubio.nix](/Users/masato/Documents/Ardour-macOS-arm64/aubio.nix)
  - [vamp.nix](/Users/masato/Documents/Ardour-macOS-arm64/vamp.nix)
- Patch:
  - [arm64-fix.patch](/Users/masato/Documents/Ardour-macOS-arm64/arm64-fix.patch)

## Major Changes Made

### 1. Split the build into two derivations

To avoid repeating the full C++ build when only post-install packaging fixups change:

- `packages.base`
  - Heavy `waf configure/build/install`
- `packages.default`
  - Copies `${ardour-base}` and applies packaging fixups

Effect:

- Fixup-only changes usually rebuild only the lightweight second derivation.

### 2. Fixed Mach-O references to build-directory paths

Original runtime failure:

- `dyld` tried to load libraries from `/nix/var/nix/builds/.../source/build/libs/...`

Fix:

- Post-install Darwin fixup rewrites build-tree references to installed output locations.
- `LC_ID_DYLIB` is normalized for internal dylibs.

Result:

- The original launch failure caused by build-directory paths was resolved.

### 3. Fixed shell wrapper scripts that hardcoded Nix store paths

Affected wrappers included:

- `result/bin/ardour9`
- `result/bin/ardour9-lua`
- `result/bin/ardour9-export`
- `result/bin/ardour9-new_session`
- `result/bin/ardour9-new_empty_session`
- `result/lib/ardour9/utils/ardour-util.sh`

Fix:

- Rewrote shebangs to `#!/bin/sh`
- Replaced absolute `${ardour-base}` paths with `$_ardour_root/...`
- Added wrapper prelude to compute root from script location

Result:

- `rg -n '/nix/store|/nix/var/nix' result/bin result/lib/ardour9/utils/ardour-util.sh`
  returned no hits after fixup.

### 4. Rewrote internal Mach-O dependencies to relative paths

Fix:

- Internal Ardour dylibs now use `@loader_path/...`
- Subdirectory references are rewritten relative to the current Mach-O location

Result:

- Internal Ardour libraries no longer depend on absolute `/nix/store/.../ardour-9.2/...` paths.

### 5. Bundled external dylibs and rewrote them to relative paths

Fix:

- External non-system `/nix/store/...` dylib dependencies are copied to:
  - `result/lib/ardour9/bundled`
- References are rewritten to `@loader_path/.../bundled/...`
- Bundled dylibs also get normalized `LC_ID_DYLIB`

Result:

- `find ... | otool -L | rg '/nix/store/'` no longer found Mach-O references inside the packaged Ardour tree.

## Official App Comparison

Compared local output against:

- `/Users/masato/Downloads/Ardour9.app`

Findings:

- Internal Ardour dylibs in `result/lib/ardour9` are broadly present.
- The official `.app` contains more bundled resources and auxiliary components.
- Important difference before bundling work:
  - The official `.app` bundled many external dylibs inside the app
  - The Nix output originally depended on `/nix/store/...`
- After bundling work:
  - The custom output became much closer to a self-contained package for dylib purposes

Not fully matched to the official app:

- Additional resources
- Some extra plugins and bundled content
- `.app` bundle layout itself

## Dependency / Recipe Work

Official dependency list referenced by user:

- https://nightly.ardour.org/list.php#build_deps

Changes made in response:

- Rejected the temporary `libiconv` shim approach after user requested a root-cause fix instead.
- Switched `curl` in the dependency set to `curlMinimal`.
- Attempted to override `libwebsockets` with a custom curl input, but nixpkgs `libwebsockets` did not accept a `curl` argument, so that override was removed.
- Current state keeps:
  - `curl-custom = pkgs.curlMinimal`
  - `libraries` uses `curl-custom`
  - `libwebsockets` remains the nixpkgs package as-is

## Runtime Findings

### Host machine

Confirmed working:

- GUI launch
- New session creation
- CoreAudio speaker output

This indicates:

- The current packaging fixes resolved the original hardcoded-path launch problem.
- The build is operational on the target host environment.

### Clean VM

Observed behavior:

- GUI launches
- Crash occurs when starting a new session

This reproduces with:

- Custom packaged output
- Official distributed `Ardour9.app`

Conclusion:

- The VM failure is not specific to the Nix packaging work.

## Crash Logs Reviewed

### Custom output in VM

- [log.txt](/Users/masato/Downloads/log.txt)

Key facts:

- `EXC_BAD_ACCESS (SIGBUS)` / `KERN_PROTECTION_FAILURE`
- Crash on main thread
- Stack includes:
  - `_platform_memmove`
  - `-[NSSoftwareSurface frontBuffer]`
  - `-[NSCGLSurface flushRect:]`
  - `NSCGLSurfaceFlush`
  - `glFlush_Exec`
  - `-[ArdourCanvasOpenGLView drawRect:]`
  - `ARDOUR_UI::gui_idle_handler()`
  - `EngineControl::start_stop_button_clicked()`

### Official app in VM

- [log2.txt](/Users/masato/Downloads/log2.txt)

Key facts:

- `EXC_BAD_ACCESS (SIGSEGV)` / `KERN_INVALID_ADDRESS`
- Same essential draw path:
  - `_platform_memmove`
  - `-[NSSoftwareSurface frontBuffer]`
  - `-[NSCGLSurface flushRect:]`
  - `NSCGLSurfaceFlush`
  - `glFlush_Exec`
  - `-[ArdourCanvasOpenGLView drawRect:]`

Conclusion:

- Different signal details, same underlying crash family.
- The issue is tied to the VM OpenGL / NSOpenGL canvas path.

## UI Configuration Attempt

To try to avoid the OpenGL path by default on Darwin, the post-install fixup now injects these options into:

- [result/etc/ardour9/default_ui_config](/Users/masato/Documents/Ardour-macOS-arm64/result/etc/ardour9/default_ui_config)

Injected options:

- `nsgl-view-mode = 0`
- `cairo-image-surface = true`

This was motivated by strings found in the Ardour binary:

- `Render Canvas on openGL texture (requires restart)`
- `Use intermediate image-surface to render canvas (requires restart)`
- Config keys:
  - `nsgl-view-mode`
  - `cairo-image-surface`
  - `buggy-gradients`

Observed result:

- Even with these defaults present in `default_ui_config`, the VM still crashes in `ArdourCanvasOpenGLView`.

Current interpretation:

- Either these defaults are not the decisive switch for disabling the NSOpenGL canvas path
- Or user-specific UI config overrides them at runtime
- Or Ardour still instantiates the OpenGL-backed canvas path on this VM even with these settings

## What Is Considered Resolved

- Build succeeds reproducibly through Nix
- Original `dyld` failure from build-tree library paths is fixed
- Wrapper scripts no longer hardcode Nix store paths
- Internal Mach-O dependencies are relative
- External dylibs are bundled and referenced relatively
- Host runtime is functional

## What Is Not Resolved

- VM crash during new session creation
- Exact runtime switch needed to fully disable the crashing OpenGL canvas path in the VM
- Whether VM-specific user config or Quartz/OpenGL behavior is overriding the intended safe defaults

## Recommended Next Steps

1. Verify whether the VM is loading a user UI config that overrides `default_ui_config`.
2. Identify the exact Ardour preference or runtime path that controls creation of `ArdourCanvasOpenGLView`.
3. If possible, force a non-OpenGL canvas path in the package defaults or via environment/config.
4. If not possible, document the VM limitation explicitly, since the official `.app` reproduces the same failure.
