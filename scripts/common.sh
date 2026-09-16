#!/usr/bin/env bash
# Shared helpers for all build scripts.
set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

load_versions() {
  # shellcheck disable=SC1091
  source "$(repo_root)/VERSIONS"
  : "${MPV_VERSION:?MPV_VERSION missing in VERSIONS}"
  : "${FFMPEG_VERSION:?FFMPEG_VERSION missing in VERSIONS}"
  : "${FFMPEG_URL:?FFMPEG_URL missing in VERSIONS}"
}

# NOTE: log goes to stderr so stdout stays clean for command substitution.
log()  { echo "[obve-mpv] $*" >&2; }
fail() { echo "[obve-mpv][ERROR] $*" >&2; exit 1; }

# Portable SHA-256 (sha256sum on Linux, shasum on macOS).
sha256_file() {
  local file="${1:?file required}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file"
  else
    python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest() + '  ' + sys.argv[1])" "$file"
  fi
}

# Refuse nightly/snapshot ffmpeg sources.
assert_stable_ffmpeg() {
  local src="${1:?ffmpeg source (URL or version) required}"
  case "$src" in
    *master*|*snapshot*|*nightly*|*N-*|*-git*|*git-master*)
      fail "ffmpeg source '$src' looks like nightly/snapshot. Only stable tarballs allowed."
      ;;
  esac
  if [[ "$src" =~ ^https?:// ]]; then
    case "$src" in
      https://ffmpeg.org/releases/ffmpeg-[0-9]*.[0-9]*.tar.*) ;;
      *) fail "ffmpeg URL must be https://ffmpeg.org/releases/ffmpeg-X.Y.tar.*, got: $src" ;;
    esac
  fi
}

download_ffmpeg_stable() {
  local dest_dir="${1:?dest dir required}"
  load_versions
  assert_stable_ffmpeg "$FFMPEG_URL"
  assert_stable_ffmpeg "$FFMPEG_VERSION"
  mkdir -p "$dest_dir"
  local tarball="$dest_dir/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  if [[ ! -f "$tarball" ]]; then
    log "downloading stable ffmpeg $FFMPEG_VERSION"
    curl -fL "$FFMPEG_URL" -o "$tarball"
  else
    log "reusing cached $tarball"
  fi
  if [[ "${FFMPEG_SHA256:-SKIP}" != "SKIP" && -n "${FFMPEG_SHA256:-}" ]]; then
    local actual
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tarball" | awk '{print $1}')"
    else
      actual="$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$tarball")"
    fi
    [[ "$actual" == "$FFMPEG_SHA256" ]] || fail "checksum mismatch for $tarball"
    log "checksum OK ($tarball)"
  else
    log "WARNING: FFMPEG_SHA256=SKIP, checksum not verified. Fill VERSIONS."
  fi
  rm -rf "$dest_dir/ffmpeg-${FFMPEG_VERSION}"
  tar -xf "$tarball" -C "$dest_dir"
  echo "$dest_dir/ffmpeg-${FFMPEG_VERSION}"
}

# Fetch a pinned git ref deterministically (shallow).
git_fetch_pin() {
  local repo_url="${1:?repo url}" ref="${2:?sha/tag}" dest="${3:?dest dir}"
  if [[ ! -d "$dest/.git" ]]; then
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo_url" 2>/dev/null || true
  fi
  git -C "$dest" fetch -q --depth 1 origin "$ref"
  git -C "$dest" checkout -q FETCH_HEAD
  log "checked out $repo_url @ $ref"
}

# Download libass stable tarball (release asset, fallback: git archive of tag).
download_libass_stable() {
  local dest_dir="${1:?dest dir required}" version="${2:?version required}"
  mkdir -p "$dest_dir"
  local tarball="$dest_dir/libass-${version}.tar.gz"
  if [[ ! -f "$tarball" ]]; then
    if ! curl -fL "https://github.com/libass/libass/releases/download/${version}/libass-${version}.tar.gz" -o "$tarball"; then
      log "release asset missing, falling back to git archive of tag ${version}"
      curl -fL "https://github.com/libass/libass/archive/refs/tags/${version}.tar.gz" -o "$tarball"
    fi
  fi
  rm -rf "$dest_dir/libass-${version}"
  tar -xzf "$tarball" -C "$dest_dir"
  echo "$dest_dir/libass-${version}"
}
