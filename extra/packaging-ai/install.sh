#!/bin/sh
# Installs the heidisql-ai package of the latest HeidiSQL AI Edition release (ADR-010).
# Usage: curl -fsSL https://github.com/ggrace519/HeidiSQL/releases/latest/download/install.sh | sh
# Uses apt on Debian/Ubuntu and dnf on Fedora. Installs next to a stock HeidiSQL package.
set -eu

API_URL="${HEIDISQL_AI_RELEASE_API:-https://api.github.com/repos/ggrace519/HeidiSQL/releases/latest}"

fail() {
	echo "heidisql-ai install: $*" >&2
	exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required."
[ "$(uname -m)" = "x86_64" ] || fail "packages are built for x86_64 only. Use a release archive instead."

if command -v apt-get >/dev/null 2>&1; then
	pattern='_amd64\.deb'
	installer="apt-get install -y"
elif command -v dnf >/dev/null 2>&1; then
	pattern='\.x86_64\.rpm'
	installer="dnf install -y"
else
	fail "neither apt-get nor dnf found. Use a release archive instead."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
	command -v sudo >/dev/null 2>&1 || fail "run as root or install sudo."
	SUDO="sudo"
fi

url=$(curl -fsSL "$API_URL" | grep -o "\"browser_download_url\": *\"[^\"]*${pattern}\"" | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/') || true
[ -n "$url" ] || fail "the latest release has no package for this system."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
file="$tmpdir/${url##*/}"
echo "Downloading $url"
curl -fSL --progress-bar -o "$file" "$url"
chmod 644 "$file"
chmod 755 "$tmpdir"

echo "Installing ${file##*/}"
# shellcheck disable=SC2086
$SUDO $installer "$file"
echo "Installed. Start it with: heidisql-ai"
