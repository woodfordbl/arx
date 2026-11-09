#!/bin/sh
# install.sh: installs the latest arx release (binary, commands, and the
# plugins and kits that come with it), then, on a terminal, sets it up.
#
#   sh install.sh [--prefix DIR] [--version vX.Y.Z] [--kit NAME] [--no-setup]
#
# The default prefix is ~/.local. --kit then runs `arx kit add NAME
# --default`, so every run uses that kit (coding, explorer or research).
# When stdout and /dev/tty are a terminal and CI is not set, it goes on into
# `arx setup --if-needed`, which reads its answers from /dev/tty, so this
# works under `curl ... | sh`; an arx that is set up already is left as it
# is. --no-setup stops after the install, for scripts.
#
# It downloads arx-<os>-<arch>.tar.gz and its .sha256 from the arx site,
# which serves the GitHub release (ARX_DOWNLOAD_URL replaces it), then runs
# the bundled arx-update to verify and install it. From a source checkout,
# `make install` does the same with your own build.
set -eu

site=${ARX_DOWNLOAD_URL:-https://arx-documentation.vercel.app}
site=${site%/}
prefix=$HOME/.local
version="" kit="" setup=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --kit) kit=$2; shift 2 ;;
    --no-setup) setup=0; shift ;;
    *) echo "usage: sh install.sh [--prefix DIR] [--version vX.Y.Z] [--kit NAME] [--no-setup]" >&2; exit 2 ;;
  esac
done

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed 's/aarch64/arm64/')
asset=arx-$os-$arch.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -n "$version" ] || version=$(curl -fsSL "$site/releases/latest")
[ -n "$version" ] || { echo "install.sh: no release found at $site" >&2; exit 1; }
echo "Downloading arx $version for $os-$arch..."
curl -fsSL -o "$tmp/$asset" "$site/releases/download/$version/$asset"
curl -fsSL -o "$tmp/$asset.sha256" "$site/releases/download/$version/$asset.sha256"
echo "$version" >"$tmp/latest"

# arx-update (inside the release) verifies the checksum and installs. Its
# own "Downloading" line would repeat ours, so it is dropped.
mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack"
out=$(ARX_UPDATE_DIR=$tmp ARX_BIN=/nonexistent \
  sh "$tmp/unpack/arx-$os-$arch/libexec/arx/arx-update" --prefix "$prefix") || {
  printf '%s\n' "$out"
  exit 1
}
printf '%s\n' "$out" | sed '/^Downloading /d'

# The kit asks no question: naming it with --kit is the yes.
if [ -n "$kit" ]; then
  "$prefix/bin/arx" kit add "$kit" --default --yes || {
    echo "install.sh: arx is installed, but the kit $kit is not; try \`arx kit add $kit --default\`" >&2
    exit 1
  }
fi

# On a terminal, go on into setup, with its answers from /dev/tty: under
# `curl | sh`, stdin is this script. The subshell matters: a failed
# redirection on a special built-in exits a POSIX shell. The install worked,
# so a cancelled setup still exits 0.
if [ "$setup" -eq 1 ] && [ -z "${CI:-}" ] && [ -t 1 ] && (exec </dev/tty) 2>/dev/null; then
  "$prefix/bin/arx" setup --if-needed </dev/tty ||
    echo "arx is installed. Run \`arx setup\` when you're ready."
  exit 0
fi

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Add $prefix/bin to your PATH, e.g. in ~/.zshrc: export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
echo "Next: arx setup"
