# obve-mpv-builds

LGPL-only `libmpv` dynamic libraries for the OpenBVE video-texture feature
(PR `leezer3/OpenBVE#1333`: local video file → mesh material via OpenGL FBO).

## Releases (one archive per platform)

| File | Contents |
|---|---|
| `libmpv-lgpl-windows-x64.zip` | `x64/libmpv-2.dll`, `x64/libmpv.dll.a`, `include/mpv/client.h` |
| `libmpv-lgpl-linux-x64.tar.gz` | `x64/libmpv.so.2` (+ `libmpv.so` symlink) + bundled non-system `.so` (`$ORIGIN` rpath) |
| `libmpv-lgpl-macos-intel.tar.gz` | `x64/libmpv.2.dylib` (+ `libmpv.dylib` symlink, x86_64 only) + bundled brew `.dylib` (`@loader_path`) |

Every archive also ships `runtime.json` (mpv/ffmpeg versions + SHA),
`ffmpeg-configure.txt` (exact configure flags, for LGPL auditing), `NOTICE.md`, `LICENSES/`.

Pinned versions: see `VERSIONS` (`mpv v0.41.0`, `ffmpeg 9.0.1` stable tarball,
`libass 0.17.5`, `libplacebo v7.360.1` built as a subproject).

Linking model: `ffmpeg + libass + libplacebo` are always **statically** linked
into `libmpv`; remaining distro libs (freetype/harfbuzz/dav1d/…) are **bundled**
in the `x64/` folder. No GPL dependency anywhere in the chain (enforced by
`verify-lgpl.sh`).

## Usage in OpenBVE

1. Place the lib next to the app (`BaseDirectory/x64/...`; on Windows next to `Tolk.dll`):
   `x64/libmpv-2.dll` (Windows), `x64/libmpv.so.2` (Linux), `x64/libmpv.2.dylib` (macOS).
2. Linux/macOS need a `dllmap` because of `DllImport("libmpv-2.dll")`:
   ```xml
   <dllmap os="linux" dll="libmpv-2.dll" target="libmpv.so.2"/>
   <dllmap os="osx" dll="libmpv-2.dll" target="libmpv.2.dylib"/>
   ```
3. Supported formats: local `.mp4/.mkv/.webm/.avi` only (`://` blocked). Test first
   with a small `720p 30fps ~10s` file.
4. `GetProcAddressOpenGL` in the PR is Windows-only for now; Linux
   (`glXGetProcAddress`) / macOS still need to be added on the OpenBVE side.

## LGPL-only: what is disabled

* mpv: `-Dgpl=false -Dcplayer=false`, no `dvdnav/rubberband/openal/jack/oss-audio/caca`,
  no `lua/javascript` (the PR uses `load-scripts=no`), no `libarchive/libbluray/uchardet`,
  no `lcms2/vulkan/spirv-cross/shaderc` (the render API used by the PR is OpenGL).
  Legacy `vo_x11/xv/vdpau` are off via `-Dgpl=false` — unused since `vo=libmpv`.
* ffmpeg: decode-only (`--disable-encoders/muxers/programs/doc`), minimal external libs
  (`libass/freetype/fribidi/fontconfig/harfbuzz/dav1d`); libplacebo is linked by
  mpv directly (pinned subproject), not via ffmpeg; everything else
  uses ffmpeg native decoders (h264/hevc/vp8/vp9/aac/mp3/opus/vorbis). **Without**
  `--enable-gpl/nonfree/libx264/libx265/librubberband/libdavs2/libdvdnav/libdvdread/
  libssh/libsrt/libzvbi/avisynth`.
* ffmpeg **must be a stable tarball** from `https://ffmpeg.org/releases/` (never
  master/nightly). Windows: the ffmpeg/mpv checkouts in the superbuild are pinned
  to stable tags (`n9.0.1`/`v0.41.0`). `verify-lgpl.sh` fails the build on any
  snapshot marker or GPL flag found in `ffmpeg-configure.txt` (the exact flags are
  stored in every archive).

## Local build / CI

```bash
bash scripts/build-linux.sh        # ubuntu-22.04
arch -x86_64 bash scripts/build-macos-intel.sh  # macos-15-intel
bash scripts/build-windows-lgpl.sh # cross-compile Windows DLL on ubuntu-22.04
bash scripts/verify-lgpl.sh linux staging/linux
python3 scripts/smoke-opengl.py staging/linux/x64/libmpv.so.2
bash scripts/package.sh linux staging/linux dist
```

CI: `.github/workflows/build.yml` (3 jobs + `release` with 3 separate ZIPs). Bump versions via `VERSIONS` + tag `v*`.

## License

Build scripts and docs in this repo: MIT (see `LICENSE`). Redistribution terms for the built libraries: see `NOTICE.md`.
