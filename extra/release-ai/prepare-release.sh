#!/bin/sh
# Prepares the next AI Edition release (ADR-011): picks the next version from the
# CHANGELOG-AI.md [Unreleased] section, sets AIEDITIONVERSION in source/const.inc and turns
# [Unreleased] into a "[<version>] - <date>" section below a new, empty [Unreleased].
# Prints the new version, or nothing when [Unreleased] has no "- " entries (then nothing changes).
# Needs GNU sed (sed -i, \n in replacements), as on the ubuntu-latest runners.
# Minor bump when the section has "### Added" or "### Changed", patch bump otherwise.
# Usage: prepare-release.sh [repository root] [date, default today in UTC]
set -eu

root="${1:-.}"
date="${2:-$(date -u +%Y-%m-%d)}"
changelog="$root/CHANGELOG-AI.md"
constinc="$root/source/const.inc"

fail() {
	echo "prepare-release: $*" >&2
	exit 1
}

[ -f "$changelog" ] || fail "$changelog not found"
[ -f "$constinc" ] || fail "$constinc not found"

grep -qx '## \[Unreleased\]' "$changelog" || fail "no '## [Unreleased]' heading in $changelog"
unreleased=$(awk '
	$0 == "## [Unreleased]" { found = 1; next }
	found && /^## \[/ { exit }
	found { print }
' "$changelog")
printf '%s\n' "$unreleased" | grep -q '^- ' || exit 0

current=$(sed -n "s/^ *AIEDITIONVERSION = '\([0-9]*\.[0-9]*\.[0-9]*\)';.*/\1/p" "$constinc")
[ -n "$current" ] || fail "no AIEDITIONVERSION = 'X.Y.Z' in $constinc"

major=${current%%.*}
rest=${current#*.}
minor=${rest%%.*}
patch=${rest#*.}
if printf '%s\n' "$unreleased" | grep -Eq '^### (Added|Changed)$'; then
	next="$major.$((minor + 1)).0"
else
	next="$major.$minor.$((patch + 1))"
fi

grep -q "^## \[$next\]" "$changelog" && fail "$changelog already has a section for $next"

sed -i "s/^\( *AIEDITIONVERSION = '\)$current'/\1$next'/" "$constinc"
sed -i "s/^## \[Unreleased\]\$/## [Unreleased]\n\n## [$next] - $date/" "$changelog"
echo "$next"
