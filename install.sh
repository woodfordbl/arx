#!/bin/sh
# install.sh: installs the latest arx release (binary + commands).
#
#   sh install.sh [--prefix DIR] [--version vX.Y.Z]     (default prefix ~/.local)
#
# It downloads arx-<os>-<arch>.tar.gz and its .sha256 from the arx site,
# which serves the GitHub release (ARX_DOWNLOAD_URL replaces it), then runs
# the bundled arx-update to verify and install it. From a source checkout,
# `make install` does the same with your own build.
set -eu

site=${ARX_DOWNLOAD_URL:-https://arx-documentation.vercel.app}
site=${site%/}
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

[ -n "$version" ] || version=$(curl -fsSL "$site/releases/latest")
[ -n "$version" ] || { echo "install.sh: no release found at $site" >&2; exit 1; }
curl -fsSL -o "$tmp/$asset" "$site/releases/download/$version/$asset"
curl -fsSL -o "$tmp/$asset.sha256" "$site/releases/download/$version/$asset.sha256"
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
