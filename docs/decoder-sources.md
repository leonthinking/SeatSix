# SeatSix decoder sources and notices

The full SeatSix macOS download includes the universal media libraries from IINA's `iina-1.5.0-release` build. The original `iina-deps-fat.zip` SHA-256 is `d6b3bb920f14780ec9c9df22e323e2bf72a5ca2b198473c67bf37581f0a60b6e`. Its source manifest, build options, architecture settings and patch history are available at the exact build commit. [IINA build recipes](https://github.com/iina/deps-buildscripts/tree/f86d54276547df6d14104583ea604af67433f1e1)

Download **SeatSix-0.1.0-decoder-sources.tar.gz** (for version 0.1.0) beside the DMG on the same GitHub Release. It contains the original source archives, commit snapshots for JPEG XL and libplacebo and their submodules, and the five patch files applied to mpv and Rubber Band. `decoder-sources.lock.json` identifies individual versions, source URLs and SHA-256 checksums. Individual source files retain their copyright notices and license terms. The application's `Contents/Resources/ThirdPartyNotices` folder contains copies of the upstream license documents and attributions.

SeatSix uses libmpv and FFmpeg with GPL components enabled. The source to SeatSix itself, including the app packaging scripts, is provided in the GitHub Release's source code download for the same tag. This software is based in part on the work of the Independent JPEG Group. This product includes software developed by the FreeType Project. [FFmpeg build options](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/buildscripts/build-ffmpeg.sh) · [mpv build options](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/buildscripts/build-mpv.sh)

## Rebuild the libraries

On macOS, use Xcode command line tools, Python 3.12 or later, Meson, Ninja, CMake, NASM, autoconf, automake, GNU libtool and pkg-config. Start in a new directory containing the source asset. The restoration command verifies the downloads and patches, then populates the upstream build's local source cache with the package archives and submodule trees.

```sh
version=0.1.0
tar -xzf "SeatSix-${version}-decoder-sources.tar.gz"
git clone https://github.com/iina/deps-buildscripts.git recipes
git -C recipes checkout --detach f86d54276547df6d14104583ea604af67433f1e1
python3 decoder-sources/decoder-sources.py --restore-to recipes/sources
cd recipes
GIT_CEILING_DIRECTORIES="$PWD/sources" bash build.sh all
bash fix-install-names.sh all
bash lipo.sh
```

The build writes universal libraries under `recipes/output/fat/`. `build.sh` applies the supplied patches and the package-specific configure adjustments for libbs2b and libvorbis before compilation. For libbs2b the recipe removes the obsolete `dist-lzma` option, the sndfile probe and the command-line programs, then regenerates configure with `autoreconf --force --verbose --install`. For libvorbis it removes `-force_cpusubtype_ALL` from the generated Makefiles. [libbs2b build steps](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/buildscripts/build-libbs2b.sh) · [libvorbis build steps](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/buildscripts/build-libvorbis.sh)

The pinned upstream workflow documents its separate native arm64 and Intel builds. [IINA build workflow](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/.github/workflows/build.yml)

## Prepare the release asset

From the SeatSix checkout, run `python3 scripts/decoder-sources.py build/decoder-sources`. The command publishes the archive and notices together into a new directory. You can reuse the same destination when every file still matches. Choose a new destination for changed inputs or an existing directory containing other files. Set `SEATSIX_DECODER_SOURCE_CACHE` or pass `--cache DIRECTORY` to reuse a verified download cache. Package the generated `ThirdPartyNotices` alongside the libraries and publish the generated `decoder-sources.tar.gz` with the matching DMG.
