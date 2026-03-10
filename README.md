# Ardour for macOS (arm64)

This repository provides a Nix flake to build Ardour 9.2 for macOS on arm64 processors.

## Requirements

*   [Nix](https://nixos.org/download.html)

## Usage

### Building

To build Ardour, run the following command in the root of this repository:

```bash
nix build
```

The resulting application bundle (`Ardour9.app`) will be in the `result/Applications/` directory.

### Development Shell

To enter a development shell with all the necessary dependencies, run:

```bash
nix develop
```

## Dependencies

This flake pulls in all the necessary dependencies to build Ardour, including:

*   aubio
*   boost
*   cairomm
*   cppunit
*   curl
*   fftwFloat
*   flac
*   fontconfig
*   freetype
*   glib
*   glibmm
*   jack2
*   libarchive
*   liblo
*   libogg
*   libpng
*   libsamplerate
*   libsndfile
*   libusb1
*   libwebsockets
*   libxml2
*   lilv
*   lrdf
*   lv2
*   pango
*   pangomm
*   rubberband
*   serd
*   sord
*   sratom
*   taglib
*   vamp-plugin-sdk

## Patch

The `arm64-fix.patch` file modifies the build script to avoid using SSE instructions on arm64, which are specific to x86 processors.
