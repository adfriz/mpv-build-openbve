#!/usr/bin/env bash
# LGPL + stable-source gate. Fails the job on any violation.
# Usage: verify-lgpl.sh <platform: windows|linux|macos-intel> <staging-dir>
#
# Evidence model: build scripts must save their exact ffmpeg configure
# flags to $STAGING/ffmpeg-configure.txt. We scan THAT file — never source
# trees (mpv's own CI scripts/docs contain --enable-gpl strings and .git
# objects would false-positive).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

PLATFORM="${1:?platform required: windows|linux|macos-intel}"
STAGING="${2:?staging dir required}"
ROOT="$(repo_root)"

load_versions
assert_stable_ffmpeg "$FFMPEG_URL"
assert_stable_ffmpeg "$FFMPEG_VERSION"

fail_check() { echo "[verify][FAIL] $*" >&2; exit 1; }
pass() { echo "[verify][OK] $*"; }

# 1. Expected lib exists
case "$PLATFORM" in
  windows) LIB="$STAGING/x64/libmpv-2.dll" ;;
  linux) LIB="$STAGING/x64/libmpv.so.2" ;;
  macos-intel) LIB="$STAGING/x64/libmpv.2.dylib" ;;
  *) fail_check "unknown platform $PLATFORM" ;;
esac
[[ -f "$LIB" ]] || fail_check "missing $LIB"
[[ -f "$STAGING/include/mpv/client.h" ]] || fail_check "missing client.h"
pass "artifacts present ($PLATFORM)"

# 2. Configure evidence must exist and be GPL-free
CONF="$STAGING/ffmpeg-configure.txt"
[[ -f "$CONF" ]] || fail_check "missing $CONF (build script must save ffmpeg flags)"
FORBIDDEN="--enable-gpl|--enable-nonfree|--enable-libx264|--enable-libx265|--enable-librubberband|--enable-libdavs2|--enable-libdvdnav|--enable-libdvdread|--enable-libssh|--enable-libsrt|--enable-libzvbi|--enable-avisynth"
# NOTE: patterns start with '-', so '--' is mandatory. Without it grep errors
# out (exit 2) and the LGPL gate would spuriously PASS. Never drop the '--'.
if grep -Eq -- "$FORBIDDEN" "$CONF"; then
  grep -Eoh -- "$FORBIDDEN" "$CONF" | sort -u >&2 || true
  fail_check "forbidden GPL ffmpeg flag in $CONF"
fi
pass "ffmpeg flags LGPL-clean"

# 3. Pinned versions must appear in evidence (no silent master drift)
case "$PLATFORM" in
  windows)
    grep -q "GIT_TAG n${FFMPEG_VERSION}" "$CONF" || fail_check "ffmpeg not pinned to n$FFMPEG_VERSION"
    [[ -f "$STAGING/mpv-configure.txt" ]] || fail_check "missing mpv-configure.txt"
    grep -q "GIT_TAG ${MPV_VERSION}" "$STAGING/mpv-configure.txt" || fail_check "mpv not pinned to $MPV_VERSION"
    grep -q "\-Dgpl=false" "$STAGING/mpv-configure.txt" || fail_check "mpv LGPL flag missing"
    ;;
  linux|macos-intel)
    # mpv: the checked-out source must sit exactly on the pinned tag
    # (the old check grepped VERSIONS for its own content and could never
    # match, failing every run).
    found_mpv=false
    for src in "$ROOT/build"/mpv-src*; do
      [[ -d "$src/.git" ]] || continue
      found_mpv=true
      tag="$(git -C "$src" describe --tags --exact-match 2>/dev/null || git -C "$src" rev-parse --short HEAD)"
      [[ "$tag" == "$MPV_VERSION" ]] || fail_check "mpv source at '$tag', expected tag $MPV_VERSION ($src)"
    done
    $found_mpv || fail_check "no mpv source checkout found under $ROOT/build"
    # ffmpeg: the extracted stable tarball dir must carry the pinned version.
    [[ -n "$(find "$ROOT/build" -maxdepth 3 -type d -name "ffmpeg-$FFMPEG_VERSION" 2>/dev/null | head -1)" ]] \
      || fail_check "ffmpeg source dir for $FFMPEG_VERSION not found (drift?)"
    ;;
esac
pass "stable pins verified"

# 4. GL backend must have been detected (PR needs OPENGL render API).
# Meson prints "Run-time dependency gl found: YES" in meson-log.txt.
if [[ "$PLATFORM" != "windows" ]]; then
  MLOG="$(find "$ROOT/build" -path "*meson-logs/meson-log.txt" 2>/dev/null | head -1)"
  if [[ -n "${MLOG:-}" ]]; then
    grep -Eq "Run-time dependency gl found: YES" "$MLOG" || fail_check "GL backend not detected (OPENGL render API at risk). See $MLOG"
    grep -Eq "Run-time dependency libplacebo found: YES" "$MLOG" || fail_check "libplacebo not found. See $MLOG"
    pass "GL + libplacebo detected by meson"
  else
    echo "[verify][WARN] meson-log.txt not found, skipping detection check" >&2
  fi
fi

# 5. Linked-deps sanity on the STAGED lib (+ bundling depth checks)
case "$PLATFORM" in
  linux)
    ldd "$LIB" | tee "$STAGING/ldd.txt"
    grep -qiE "libx264|libx265|rubberband|dvdnav" "$STAGING/ldd.txt" && fail_check "GPL lib linked (ldd)"
    grep -q "not found" "$STAGING/ldd.txt" && fail_check "unresolved deps (ldd)"
    # Every resolved dep must be system-core or bundled in x64/.
    while IFS= read -r line; do
      dep="$(echo "$line" | grep -oE '/[^ ]+' || true)"
      [[ -z "$dep" ]] && continue
      case "$(basename "$dep")" in
        ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*) continue ;;
      esac
      [[ -f "$STAGING/x64/$(basename "$dep")" ]] || fail_check "dep not bundled: $dep"
    done < "$STAGING/ldd.txt"
    pass "ldd clean, all non-system deps bundled"
    ;;
  macos-intel)
    otool -L "$LIB" | tee "$STAGING/otool.txt"
    grep -qiE "libx264|libx265|rubberband|dvdnav" "$STAGING/otool.txt" && fail_check "GPL lib linked (otool)"
    if grep -Eq "/opt/homebrew/|/usr/local/" "$STAGING/otool.txt"; then
      fail_check "absolute brew path leaked (bundling incomplete)"
    fi
    [[ "$(lipo -info "$LIB")" == *"x86_64"* ]] || fail_check "not x86_64: $(lipo -info "$LIB")"
    [[ "$(lipo -info "$LIB")" == *"arm64"* ]] && fail_check "must be Intel-only, found arm64 slice"
    pass "otool/lipo clean (x86_64 only, no brew paths)"
    ;;
  windows)
    if [[ -f "$STAGING/dlldeps.txt" ]]; then
      grep -qiE "libx264|libx265|rubberband" "$STAGING/dlldeps.txt" && fail_check "GPL dll dependency found"
      pass "dll deps clean"
    else
      echo "[verify][WARN] dlldeps.txt missing, skipped" >&2
    fi
    ;;
esac

# 6. runtime.json for audit
LIBPLACEBO_VER="$LIBPLACEBO_VERSION"
if [[ "$PLATFORM" == "macos-intel" ]]; then
  # macOS uses brew libplacebo (floating); record the actual version.
  LIBPLACEBO_VER="brew-$(pkg-config --modversion libplacebo 2>/dev/null || echo unknown)"
fi
cat > "$STAGING/runtime.json" <<EOF
{
  "platform": "$PLATFORM",
  "mpv": "$MPV_VERSION",
  "ffmpeg": "$FFMPEG_VERSION-stable",
  "ffmpeg_url": "$FFMPEG_URL",
  "ffmpeg_sha256": "${FFMPEG_SHA256:-SKIP}",
  "libass": "$LIBASS_VERSION",
  "libplacebo": "$LIBPLACEBO_VER",
  "gpl": false,
  "license_mpv": "LGPL-2.1+",
  "license_ffmpeg": "LGPL (v3 if --enable-version3)",
  "client_h": "ISC",
  "git_sha": "${GITHUB_SHA:-local}",
  "arch": "x86_64"
}
EOF
pass "wrote runtime.json"
