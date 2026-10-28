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
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required (coreutils)."
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

release=$(curl -fsSL "$API_URL") || fail "could not read the release from $API_URL"
asset_url() {
	printf '%s\n' "$release" | grep -o "\"browser_download_url\": *\"[^\"]*$1\"" | head -n 1 | sed 's/.*"\(http[^"]*\)"$/\1/'
}
url=$(asset_url "$pattern")
[ -n "$url" ] || fail "the latest release has no package for this system."
sums_url=$(asset_url '/SHA256SUMS')
[ -n "$sums_url" ] || fail "the release has no SHA256SUMS, so the package cannot be verified."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
file="$tmpdir/${url##*/}"
echo "Downloading $url"
curl -fSL --progress-bar -o "$file" "$url"
curl -fsSL -o "$tmpdir/SHA256SUMS" "$sums_url"
expected=$(awk -v f="${url##*/}" '$2 == f || $2 == "*" f { print $1 }' "$tmpdir/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS has no entry for ${url##*/}."
actual=$(sha256sum "$file" | cut -d ' ' -f 1)
[ "$expected" = "$actual" ] || fail "checksum mismatch for ${url##*/}: the download is damaged or incomplete. Nothing was installed."
echo "Checksum verified"
chmod 644 "$file"
chmod 755 "$tmpdir"

echo "Installing ${file##*/}"
# shellcheck disable=SC2086
$SUDO $installer "$file"
echo "Installed. Start it with: heidisql-ai"
