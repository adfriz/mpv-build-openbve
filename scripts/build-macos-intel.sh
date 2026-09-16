#!/usr/bin/env bash
# Build libmpv.2.dylib (LGPL-only, slim decode-only) for macOS Intel x86_64.
# MUST run on macos-15-intel (or with arch -x86_64). ffmpeg from stable tarball.
# Brew is used ONLY for build tools + LGPL decode libs (never brew ffmpeg: GPL).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ROOT="$(repo_root)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/macos-intel}"
INSTALL_DIR="${INSTALL_DIR:-$ROOT/install/macos-intel}"
STAGING="${STAGING_DIR:-$ROOT/staging/macos-intel}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
export ARCHFLAGS="-arch x86_64"
export CFLAGS="${CFLAGS:-} -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export LDFLAGS="${LDFLAGS:-} -arch x86_64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

if [[ "$(uname -m)" != "x86_64" ]]; then
  fail "must build on Intel (x86_64). Current: $(uname -m). Use macos-15-intel runner."
fi

load_versions
assert_stable_ffmpeg "$FFMPEG_URL"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$STAGING"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

log "mpv=$MPV_VERSION ffmpeg=$FFMPEG_VERSION placebo=$LIBPLACEBO_VERSION target=$MACOSX_DEPLOYMENT_TARGET x86_64"

# --- libass: static, from stable tarball ---
if ! pkg-config --exists libass 2>/dev/null; then
  log "building libass $LIBASS_VERSION (static)"
  ASSRC="$(download_libass_stable "$BUILD_DIR/dl" "$LIBASS_VERSION")"
  cd "$ASSRC"
  ./configure --prefix="$INSTALL_DIR" --disable-shared --enable-static
  make -j"$JOBS"
  make install
fi

# --- dav1d: static, from stable tarball (deterministic, not floating brew) ---
log "building dav1d $DAV1D_VERSION (static)"
DAVSRC="$(download_dav1d_stable "$BUILD_DIR/dl" "$DAV1D_VERSION")"
cd "$DAVSRC"
meson setup build --prefix="$INSTALL_DIR" --default-library=static \
  --buildtype=release -Denable_tools=false -Denable_tests=false
meson compile -C build -j"$JOBS"
meson install -C build

# --- ffmpeg: stable tarball, decode-only, LGPL (same minimal set as Linux) ---
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
  --enable-libharfbuzz --enable-libdav1d --enable-libplacebo
  --enable-version3
)
printf '%s\n' "${FFMPEG_CONF[@]}" > "$STAGING/ffmpeg-configure.txt"
./configure "${FFMPEG_CONF[@]}"
make -j"$JOBS"
make install

# --- mpv: stable tag, LGPL lib-only ---
# libplacebo via pinned-tag subproject (deterministic, not floating brew).
cd "$ROOT"
MPV_SRC="$ROOT/build/mpv-src-macos"
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

# --- stage + bundle brew dylibs with @loader_path (bash3-safe: no assoc arrays) ---
mkdir -p "$STAGING/x64" "$STAGING/include/mpv"
cp "$MPV_SRC/include/mpv/client.h" "$STAGING/include/mpv/client.h"

MANIFEST="$(mktemp)"
cp -L "$BUILD_DIR/mpv/libmpv.2.dylib" "$STAGING/x64/libmpv.2.dylib"
echo "$STAGING/x64/libmpv.2.dylib" > "$MANIFEST"
CHANGED=1
while [[ "$CHANGED" == 1 ]]; do
  CHANGED=0
  DEPS="$(mktemp)"
  while IFS= read -r f; do otool -L "$f" | tail -n +2 | awk '{print $1}'; done < "$MANIFEST" | sort -u > "$DEPS"
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/*|@loader_path/*) continue ;;
    esac
    if [[ ! -e "$STAGING/x64/$(basename "$dep")" ]]; then
      cp -L "$dep" "$STAGING/x64/$(basename "$dep")"
      chmod +w "$STAGING/x64/$(basename "$dep")"
      echo "$STAGING/x64/$(basename "$dep")" >> "$MANIFEST"
      CHANGED=1
    fi
  done < "$DEPS"
  rm -f "$DEPS"
done
while IFS= read -r f; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f"
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/*|@loader_path/*) continue ;;
    esac
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done < "$MANIFEST"
rm -f "$MANIFEST"
install_name_tool -id "@rpath/libmpv.2.dylib" "$STAGING/x64/libmpv.2.dylib"
ln -sf libmpv.2.dylib "$STAGING/x64/libmpv.dylib"
otool -L "$STAGING/x64/libmpv.2.dylib" | tee "$STAGING/otool.txt"
lipo -info "$STAGING/x64/libmpv.2.dylib"
log "staged: $STAGING/x64 (+ bundled deps)"
