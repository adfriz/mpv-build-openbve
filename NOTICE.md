# NOTICE — libmpv LGPL builds for OpenBVE

Built for the OpenBVE video-texture feature (local file decode to mesh
material, PR `leezer3/OpenBVE#1333`).

Per-build authoritative data lives in `runtime.json` (exact versions + SHAs)
and `ffmpeg-configure.txt` (exact configure flags) inside each release archive.
The table below reflects the pins in `VERSIONS` at release time.

## License summary

* `libmpv` core (`-Dgpl=false`): **LGPL-2.1-or-later**.
* `ffmpeg` (no `--enable-gpl` / `--enable-nonfree`): **LGPL**
  (v3 because `--enable-version3` is kept, same as the zhongfly reference;
  linking LGPL-2.1+ libmpv against an LGPLv3 ffmpeg is permitted).
* `include/mpv/client.h`: **ISC** (independent of `-Dgpl`).
* This is not legal advice. Audit `runtime.json`, `ffmpeg-configure.txt`
  and the CI logs before redistributing.

## Dependency list

| Component | Version (pinned) | License | Linkage |
|---|---|---|---|
| mpv (`-Dgpl=false -Dcplayer=false -Dlibmpv=true`) | `v0.41.0` (stable tag) | LGPL-2.1+ | the library itself |
| ffmpeg (decode-only, stable tarball) | `9.0.1` (`ffmpeg-9.0.1.tar.xz`) | LGPL (v3, see above) | static |
| libass (subtitles) | `0.17.5` (stable tarball) | ISC | static |
| libplacebo (GPU rendering / hwaccel mapping, linked by mpv directly) | `v7.360.1` (stable tag, meson subproject on Linux/macOS; superbuild on Windows) | LGPL-2.1+ | static |
| dav1d (AV1 decoder) | `1.5.4` (stable tarball) | BSD-2-Clause | static |
| freetype (font rasterizer, via libass) | distro/brew | FTL / GPL-2+ with font exception | bundled |
| harfbuzz (text shaping, via libass) | distro/brew | MIT | bundled |
| fribidi (bidi text, via libass) | distro/brew | LGPL-2.1+ | bundled |
| fontconfig (font discovery, via libass) | distro/brew | MIT | bundled |
| transitive support libs (expat, libpng, zlib, brotli, …) | distro/brew | MIT / BSD / zlib | bundled as needed |
| compiler runtime (libstdc++, libgcc) | toolchain | GPL-3.0 **with GCC Runtime Library Exception** (redistributable) | bundled (Linux) / static (Windows) |
| `mpv/client.h` header | same as mpv | ISC | header only |

Linux: non-system deps are bundled in `x64/` with `$ORIGIN` rpath
(`ldd.txt` in the archive proves it).
macOS (Intel only): brew deps are bundled in `x64/` with `@loader_path`
references (`otool.txt` in the archive proves no absolute brew path remains).
Windows: single self-contained `libmpv-2.dll` + `libmpv.dll.a` import lib
(`dlldeps.txt` in the archive lists its DLL dependencies).

## Explicitly excluded (GPL / non-free)

`libx264`, `libx265`, `libxvid`, `librubberband`, `libdavs2`, `libdvdnav`,
`libdvdread`, `libdvdcss`, `libssh`, `libsrt`, `libzvbi`, `avisynth`,
`--enable-gpl`, `--enable-nonfree`, all encoders/muxers/programs
(`--disable-encoders --disable-muxers --disable-programs`).
mpv-side: `dvdnav`, `rubberband`, `openal`, `jack`, `oss-audio`, `caca`,
`lua`, `javascript`, `libarchive`, `libbluray`, `uchardet`, `lcms2`, `vulkan`,
`spirv-cross`, `shaderc`, the `mpv` CLI (`-Dcplayer=false`).

## Sources

* mpv: https://github.com/mpv-player/mpv
* ffmpeg: https://ffmpeg.org/releases/ (stable tarballs only, never master)
* libass: https://github.com/libass/libass
* libplacebo: https://github.com/haasn/libplacebo
* Windows cross-build: https://github.com/zhongfly/mpv-winbuild scripts +
  https://github.com/shinchiro/mpv-winbuild-cmake engine, both SHA-pinned
  (see `VERSIONS`), plus vendored `cmake/patches/compile-lgpl-libmpv.patch`.
