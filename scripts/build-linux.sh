#!/usr/bin/env bash
# Build libmpv.so.2 (LGPL-only, slim decode-only) on Ubuntu 22.04.
# ffmpeg + libass + libplacebo are statically linked in;
# remaining distro libs are BUNDLED next to the .so with $ORIGIN rpath.
# ffmpeg comes from a stable tarball only (never master).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ROOT="$(repo_root)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/linux}"
INSTALL_DIR="${INSTALL_DIR:-$ROOT/install/linux}"
STAGING="${STAGING_DIR:-$ROOT/staging/linux}"
JOBS="${JOBS:-$(nproc)}"

load_versions
assert_stable_ffmpeg "$FFMPEG_URL"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$STAGING"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/share/pkgconfig:${PKG_CONFIG_PATH:-}"

log "mpv=$MPV_VERSION ffmpeg=$FFMPEG_VERSION libass=$LIBASS_VERSION placebo=$LIBPLACEBO_VERSION"

# --- libass: static, from stable tarball (distro .so would leak a dep) ---
if ! pkg-config --exists libass 2>/dev/null; then
  log "building libass $LIBASS_VERSION (static)"
  ASSRC="$(download_libass_stable "$BUILD_DIR/dl" "$LIBASS_VERSION")"
  cd "$ASSRC"
  ./configure --prefix="$INSTALL_DIR" --disable-shared --enable-static
  make -j"$JOBS"
  make install
fi

# --- dav1d: static, from stable tarball (distro 0.9.x < ffmpeg 9 minimum) ---
log "building dav1d $DAV1D_VERSION (static)"
DAVSRC="$(download_dav1d_stable "$BUILD_DIR/dl" "$DAV1D_VERSION")"
cd "$DAVSRC"
meson setup build --prefix="$INSTALL_DIR" --default-library=static \
  --buildtype=release -Denable_tools=false -Denable_tests=false
meson compile -C build -j"$JOBS"
meson install -C build

# --- ffmpeg: stable tarball, decode-only, LGPL ---
# Minimal external set: everything else is decoded by ffmpeg natively
# (h264/hevc/vp8/vp9/aac/mp3/opus/vorbis all have native decoders).
FFSRC="$(download_ffmpeg_stable "$BUILD_DIR/dl")"
cd "$FFSRC"
FFMPEG_CONF=(
  --prefix="$INSTALL_DIR"
  --pkg-config-flags=--static
  --disable-programs --disable-doc
  --disable-encoders --disable-muxers
  --disable-debug
  --enable-runtime-cpudetect
  --enable-libass --enable-libfreetype --enable-libfribidi --enable-libfontconfig
  --enable-libharfbuzz --enable-libdav1d
  --enable-version3
  # NOTE: no --enable-libplacebo on purpose: libplacebo is linked by mpv
  # directly (pinned-tag meson subproject). ffmpeg's own libplacebo support
  # is only the vf_libplacebo filter, unused by this decode path.
  # NOTE: intentionally NO --enable-gpl --enable-nonfree --enable-libx264
  # --enable-libx265 --enable-librubberband --enable-libdavs2
  # --enable-libdvdnav --enable-libdvdread --enable-libssh --enable-libsrt
  # --enable-libzvbi --enable-avisynth, and no encoder-only libs (lame/svtav1).
)
printf '%s\n' "${FFMPEG_CONF[@]}" > "$STAGING/ffmpeg-configure.txt"
./configure "${FFMPEG_CONF[@]}"
make -j"$JOBS"
make install

# --- mpv: stable tag, LGPL lib-only ---
# NOTE: Ubuntu 22.04 libplacebo-dev (v4.x) is too old for mpv 0.41
# (needs >= 6.338.2), so libplacebo is built as a meson subproject
# from its stable tag. mpv already forces it static (default_options).
cd "$ROOT"
MPV_SRC="$ROOT/build/mpv-src"
if [[ ! -d "$MPV_SRC/.git" ]]; then
  git clone --depth 1 --branch "$MPV_VERSION" https://github.com/mpv-player/mpv.git "$MPV_SRC"
else
  git -C "$MPV_SRC" fetch -q --depth 1 origin "refs/tags/$MPV_VERSION:refs/tags/$MPV_VERSION" || true
  git -C "$MPV_SRC" checkout -q "$MPV_VERSION"
fi
if [[ ! -d "$MPV_SRC/subprojects/libplacebo" ]]; then
  git clone --depth 1 --branch "$LIBPLACEBO_VERSION" https://github.com/haasn/libplacebo.git "$MPV_SRC/subprojects/libplacebo"
fi

# meson option names verified against mpv v0.41.0 meson.options.
# (-Dgl=auto on purpose: enabled when GL headers exist, missing header
#  fails later at the explicit detection check in verify-lgpl.sh.)
rm -rf "$BUILD_DIR/mpv"
meson setup "$BUILD_DIR/mpv" "$MPV_SRC" \
  -Dgpl=false -Dcplayer=false -Dlibmpv=true -Ddefault_library=shared \
  --prefer-static -Dbuildtype=release \
  -Dvulkan=disabled -Dspirv-cross=disabled -Dshaderc=disabled \
  -Ddvdnav=disabled -Drubberband=disabled -Dopenal=disabled \
  -Djack=disabled -Doss-audio=disabled -Dcaca=disabled \
  -Dpdf-build=disabled -Dtests=disabled \
  -Dlua=disabled -Djavascript=disabled \
  -Dlibarchive=disabled -Dlibbluray=disabled -Duchardet=disabled \
  -Dlcms2=disabled -Dgl=auto \
  --force-fallback-for=libplacebo \
  --prefix="$INSTALL_DIR"
meson compile -C "$BUILD_DIR/mpv" -j"$JOBS"

# --- stage + bundle non-system deps with $ORIGIN rpath (bash3-safe) ---
mkdir -p "$STAGING/x64" "$STAGING/include/mpv"
cp -L "$BUILD_DIR/mpv/libmpv.so.2" "$STAGING/x64/libmpv.so.2"
ln -sf libmpv.so.2 "$STAGING/x64/libmpv.so"
cp "$MPV_SRC/include/mpv/client.h" "$STAGING/include/mpv/client.h"

MANIFEST="$(mktemp)"
echo "$STAGING/x64/libmpv.so.2" > "$MANIFEST"
CHANGED=1
while [[ "$CHANGED" == 1 ]]; do
  CHANGED=0
  DEPS="$(mktemp)"
  while IFS= read -r f; do ldd "$f" 2>/dev/null | grep -oE '/[^ ]+'; done < "$MANIFEST" | sort -u > "$DEPS"
  while IFS= read -r dep; do
    case "$(basename "$dep")" in
      ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*) continue ;;
    esac
    if [[ ! -e "$STAGING/x64/$(basename "$dep")" ]]; then
      cp -L "$dep" "$STAGING/x64/" || log "WARNING: cannot bundle $dep"
      echo "$STAGING/x64/$(basename "$dep")" >> "$MANIFEST"
      CHANGED=1
    fi
  done < "$DEPS"
  rm -f "$DEPS"
done
rm -f "$MANIFEST"
patchelf --set-rpath '$ORIGIN' "$STAGING/x64/libmpv.so.2"
ldd "$STAGING/x64/libmpv.so.2" | tee "$STAGING/ldd.txt"
log "staged: $STAGING/x64 (+ bundled deps)"
