#!/bin/sh
# install.sh: installs the latest arx release (binary + commands).
#
#   sh install.sh [--prefix DIR] [--version vX.Y.Z]     (default prefix ~/.local)
#
# It downloads arx-<os>-<arch>.tar.gz and its .sha256 from GitHub releases
# (through gh while the repo is private), then runs the bundled arx-update to
# verify and install it. From a source checkout, `make install` does the same
# with your own build.
set -eu

repo=${ARX_REPO:-woodfordbl/arx}
prefix=$HOME/.local
version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    *) echo "usage: sh install.sh [--prefix DIR] [--version vX.Y.Z]" >&2; exit 2 ;;
  esac
done

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed 's/aarch64/arm64/')
asset=arx-$os-$arch.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  [ -n "$version" ] || version=$(gh release view --repo "$repo" --json tagName -q .tagName)
  gh release download "$version" --repo "$repo" --pattern "$asset*" --dir "$tmp"
else
  base=https://github.com/$repo/releases
  if [ -z "$version" ]; then
    version=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
      sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
  fi
  curl -fsSL -o "$tmp/$asset" "$base/download/$version/$asset"
  curl -fsSL -o "$tmp/$asset.sha256" "$base/download/$version/$asset.sha256"
fi
echo "$version" >"$tmp/latest"

# arx-update (inside the release) verifies the checksum and installs.
mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack"
ARX_UPDATE_DIR=$tmp ARX_BIN=/nonexistent \
  sh "$tmp/unpack/arx-$os-$arch/libexec/arx/arx-update" --prefix "$prefix"

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Add $prefix/bin to your PATH, e.g. in ~/.zshrc: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
echo "Next: arx setup"
