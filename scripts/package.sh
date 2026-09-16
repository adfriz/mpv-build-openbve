#!/usr/bin/env bash
# Package one platform staging dir into a separate release archive.
# Usage: package.sh <platform> <staging-dir> <dist-dir>
# Output: dist/libmpv-lgpl-<platform>.{zip,tar.gz} + per-file sha256
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

PLATFORM="${1:?platform required: windows|linux|macos-intel}"
STAGING="${2:?staging dir required}"
DIST="${3:?dist dir required}"
ROOT="$(repo_root)"
load_versions

[[ -f "$STAGING/runtime.json" ]] || fail "run verify-lgpl.sh before package.sh (runtime.json missing)"

mkdir -p "$DIST"
cp "$ROOT/NOTICE.md" "$STAGING/NOTICE.md" 2>/dev/null || echo "libmpv LGPL build for OpenBVE (see README)" > "$STAGING/NOTICE.md"
# Third-party license texts, fetched from pinned tags (fail = no release).
mkdir -p "$STAGING/LICENSES"
fetch_or_fail() {
  [[ -f "$2" ]] || curl -fL "$1" -o "$2" || fail "cannot fetch license text $1"
}
fetch_or_fail "https://raw.githubusercontent.com/mpv-player/mpv/${MPV_VERSION}/LICENSE.LGPL" "$STAGING/LICENSES/LICENSE.LGPL-mpv"
fetch_or_fail "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n${FFMPEG_VERSION}/COPYING.LGPLv2.1" "$STAGING/LICENSES/COPYING.LGPLv2.1-ffmpeg"
fetch_or_fail "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n${FFMPEG_VERSION}/COPYING.LGPLv3" "$STAGING/LICENSES/COPYING.LGPLv3-ffmpeg"
fetch_or_fail "https://raw.githubusercontent.com/libass/libass/${LIBASS_VERSION}/COPYING" "$STAGING/LICENSES/COPYING-libass"
cp "$ROOT/LICENSES/"* "$STAGING/LICENSES/" 2>/dev/null || true

# Audit trail inside every archive.
AUDIT="x64 include runtime.json NOTICE.md LICENSES ffmpeg-configure.txt"
[[ -f "$STAGING/mpv-configure.txt" ]] && AUDIT="$AUDIT mpv-configure.txt"
[[ -f "$STAGING/ldd.txt" ]] && AUDIT="$AUDIT ldd.txt"
[[ -f "$STAGING/otool.txt" ]] && AUDIT="$AUDIT otool.txt"
[[ -f "$STAGING/dlldeps.txt" ]] && AUDIT="$AUDIT dlldeps.txt"

case "$PLATFORM" in
  windows)
    OUT="$DIST/libmpv-lgpl-windows-x64.zip"
    # shellcheck disable=SC2086
    (cd "$STAGING" && zip -r "$OUT" $AUDIT)
    ;;
  linux)
    OUT="$DIST/libmpv-lgpl-linux-x64.tar.gz"
    # shellcheck disable=SC2086
    tar -czf "$OUT" -C "$STAGING" $AUDIT
    ;;
  macos-intel)
    OUT="$DIST/libmpv-lgpl-macos-intel.tar.gz"
    # shellcheck disable=SC2086
    tar -czf "$OUT" -C "$STAGING" $AUDIT
    ;;
  *) fail "unknown platform $PLATFORM" ;;
esac

(cd "$DIST" && sha256_file "$(basename "$OUT")" > "$(basename "$OUT").sha256")
log "packaged $OUT"
