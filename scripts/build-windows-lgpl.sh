#!/usr/bin/env bash
# Build libmpv-2.dll (LGPL-only) by cross-compiling on Ubuntu.
#
# Upstream layout (2026): zhongfly/mpv-winbuild holds scripts+patches,
# the cmake superbuild is shinchiro/mpv-winbuild-cmake (cloned as subdir),
# and our vendored cmake/patches/compile-lgpl-libmpv.patch is applied to it
# with `git am --3way` — exactly like upstream's own LGPL CI job.
#
# mpv + ffmpeg inside the superbuild default to git master, so both are
# pinned to STABLE tags (GIT_TAG injection) before cmake configure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ROOT="$(repo_root)"
WORK="$ROOT/build/winbuild"
ENGINE="$WORK/engine"
PATCHSRC="$WORK/upstream-patches"
BUILDD="$WORK/build64"
STAGING="${STAGING_DIR:-$ROOT/staging/windows}"
JOBS="${JOBS:-$(nproc)}"
COMPILER="${COMPILER:-gcc}"

load_versions
assert_stable_ffmpeg "$FFMPEG_VERSION"

FFMPEG_GIT_TAG="n${FFMPEG_VERSION}"
MPV_GIT_TAG="${MPV_VERSION}"

mkdir -p "$WORK" "$STAGING"

# 1. Pin upstream patch source (compat patches for the engine).
git_fetch_pin "$WINBUILD_SCRIPTS_REPO" "$WINBUILD_SCRIPTS_REF" "$PATCHSRC"
# 2. Pin cmake engine.
git_fetch_pin "$WINBUILD_ENGINE_REPO" "$WINBUILD_ENGINE_REF" "$ENGINE"

cd "$ENGINE"
git reset -q --hard HEAD
git clean -qdff -e build64 -e src_packages -e install_rustup -e clang_root || true

# 3. Engine compat patches, then our LGPL patch (same file as upstream root).
for p in "$PATCHSRC"/patch/*.patch; do
  git am --3way "$p" || { git am --abort; fail "cannot apply $p"; }
done
git am --3way "$ROOT/cmake/patches/compile-lgpl-libmpv.patch" \
  || { git am --abort; fail "LGPL patch does not apply to engine $WINBUILD_ENGINE_REF"; }
log "patches applied"

# 4. Pin mpv + ffmpeg to stable tags (engine defaults to master).
python3 - "$ENGINE/packages/ffmpeg.cmake" "$FFMPEG_GIT_TAG" <<'EOF'
import re, sys
path, tag = sys.argv[1], sys.argv[2]
s = open(path).read()
if re.search(r'(?m)^\s*GIT_TAG\b', s):
    s = re.sub(r'(?m)^\s*GIT_TAG.*$', f'    GIT_TAG {tag}', s)
else:
    s = s.replace('GIT_REPOSITORY', f'GIT_TAG {tag}\n    GIT_REPOSITORY', 1)
open(path, 'w').write(s)
EOF
python3 - "$ENGINE/packages/mpv.cmake" "$MPV_GIT_TAG" <<'EOF'
import re, sys
path, tag = sys.argv[1], sys.argv[2]
s = open(path).read()
if re.search(r'(?m)^\s*GIT_TAG\b', s):
    s = re.sub(r'(?m)^\s*GIT_TAG.*$', f'    GIT_TAG {tag}', s)
else:
    s = s.replace('GIT_REPOSITORY', f'GIT_TAG {tag}\n    GIT_REPOSITORY', 1)
open(path, 'w').write(s)
EOF
grep -H "^ *GIT_TAG" "$ENGINE"/packages/{ffmpeg,mpv}.cmake
# Save configure evidence for verify-lgpl.sh.
cp "$ENGINE/packages/ffmpeg.cmake" "$STAGING/ffmpeg-configure.txt"
cp "$ENGINE/packages/mpv.cmake" "$STAGING/mpv-configure.txt"

# 5. Configure (mirrors upstream build.sh gcc path, minus packaging).
cmake -Wno-dev \
  -DTARGET_ARCH=x86_64-w64-mingw32 \
  -DCOMPILER_TOOLCHAIN="$COMPILER" \
  -DSINGLE_SOURCE_LOCATION="$WORK/src_packages" \
  -DRUSTUP_LOCATION="$WORK/install_rustup" \
  -G Ninja -S "$ENGINE" -B "$BUILDD"

ninja -C "$BUILDD" download || true
if [[ "$COMPILER" == "gcc" ]] && [[ ! -f "$BUILDD/install/bin/cross-gcc" ]]; then
  ninja -C "$BUILDD" gcc && rm -rf "$BUILDD/toolchain"
elif [[ "$COMPILER" == "clang" ]] && [[ ! "$(ls -A "$WORK/clang_root/bin/clang" 2>/dev/null)" ]]; then
  ninja -C "$BUILDD" llvm && ninja -C "$BUILDD" llvm-clang
fi
if ninja -C "$BUILDD" -t targets all 2>/dev/null | grep -q "rustup: phony"; then
  if [[ ! "$(ls -A "$WORK/install_rustup/.cargo/bin" 2>/dev/null)" ]]; then
    ninja -C "$BUILDD" rustup-fullclean
    ninja -C "$BUILDD" rustup
  fi
fi
ninja -C "$BUILDD" update
ninja -C "$BUILDD" mpv -j"$JOBS"

# 6. Collect LGPL dev package (renamed by patch to mpv-dev-lgpl-*).
DEV_DIR="$(ls -d "$BUILDD"/mpv-dev-lgpl-* 2>/dev/null | head -1)"
[[ -n "${DEV_DIR:-}" ]] || fail "mpv-dev-lgpl-* not found after build"
log "dev package: $DEV_DIR"

mkdir -p "$STAGING/x64" "$STAGING/include/mpv"
cp "$DEV_DIR/libmpv-2.dll" "$STAGING/x64/libmpv-2.dll"
cp "$DEV_DIR/libmpv.dll.a" "$STAGING/x64/libmpv.dll.a"
cp "$DEV_DIR/include/mpv/client.h" "$STAGING/include/mpv/client.h"
if command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
  x86_64-w64-mingw32-objdump -p "$STAGING/x64/libmpv-2.dll" | grep -i "DLL Name" > "$STAGING/dlldeps.txt" || true
elif command -v objdump >/dev/null 2>&1; then
  objdump -p "$STAGING/x64/libmpv-2.dll" | grep -i "DLL Name" > "$STAGING/dlldeps.txt" || true
fi
log "staged: $STAGING/x64/libmpv-2.dll"
