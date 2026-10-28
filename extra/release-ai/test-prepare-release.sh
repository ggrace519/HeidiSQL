#!/bin/sh
# Tests for prepare-release.sh. Run: sh extra/release-ai/test-prepare-release.sh
set -u

script="$(cd "$(dirname "$0")" && pwd)/prepare-release.sh"
failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# setup <version> <unreleased body>: a minimal repository in $work/repo
setup() {
	rm -rf "$work/repo"
	mkdir -p "$work/repo/source"
	printf "const\n  AIEDITIONVERSION = '%s';\n" "$1" > "$work/repo/source/const.inc"
	printf '# Changelog\n\n## [Unreleased]\n%b\n## [0.1.0] - 2026-10-26\n\n### Added\n- First.\n' "$2" \
		> "$work/repo/CHANGELOG-AI.md"
}

check() {
	if [ "$2" = "$3" ]; then
		echo "ok   - $1"
	else
		echo "FAIL - $1"
		echo "       expected: $(printf '%s' "$2" | tr '\n' '|')"
		echo "       actual:   $(printf '%s' "$3" | tr '\n' '|')"
		failures=$((failures + 1))
	fi
}

setup 0.1.0 '\n'
out=$(sh "$script" "$work/repo" 2026-11-01)
check "empty [Unreleased]: prints nothing" "" "$out"
check "empty [Unreleased]: version unchanged" "  AIEDITIONVERSION = '0.1.0';" "$(sed -n 2p "$work/repo/source/const.inc")"

setup 0.1.0 '\n### Added\n\n### Docs\n'
check "headings without entries: prints nothing" "" "$(sh "$script" "$work/repo" 2026-11-01)"

setup 0.1.0 '\n### Added\n- Packages.\n\n### Docs\n- Readme.\n'
out=$(sh "$script" "$work/repo" 2026-11-01)
check "Added: minor bump" "0.2.0" "$out"
check "Added: const.inc updated" "  AIEDITIONVERSION = '0.2.0';" "$(sed -n 2p "$work/repo/source/const.inc")"
check "Added: changelog sections" "$(printf '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-11-01\n\n### Added\n- Packages.\n\n### Docs\n- Readme.\n\n## [0.1.0] - 2026-10-26\n\n### Added\n- First.')" "$(cat "$work/repo/CHANGELOG-AI.md")"

setup 0.2.3 '\n### Changed\n- Thing.\n'
check "Changed: minor bump, patch reset" "0.3.0" "$(sh "$script" "$work/repo" 2026-11-01)"

setup 0.2.3 '\n### Fixed\n- Bug.\n\n### Docs\n- Readme.\n'
check "Fixed and Docs only: patch bump" "0.2.4" "$(sh "$script" "$work/repo" 2026-11-01)"

setup 1.9.0 '\n### Added\n- Feature.\n'
check "minor goes past 9" "1.10.0" "$(sh "$script" "$work/repo" 2026-11-01)"

setup 0.1.0 '\n### Added\n- Packages.\n'
sh "$script" "$work/repo" 2026-11-01 >/dev/null
check "second run: nothing left to release" "" "$(sh "$script" "$work/repo" 2026-11-02)"

setup 0.1.0 '\n### Added\n- Packages.\n'
printf '\n## [0.2.0] - 2026-10-30\n' >> "$work/repo/CHANGELOG-AI.md"
sh "$script" "$work/repo" 2026-11-01 >/dev/null 2>&1
check "existing section for the next version: fails" "1" "$?"

setup 0.1.0 '\n### Added\n- Packages.\n'
sed -i 's/## \[Unreleased\]/## Unreleased/' "$work/repo/CHANGELOG-AI.md"
sh "$script" "$work/repo" 2026-11-01 >/dev/null 2>&1
check "missing [Unreleased] heading: fails" "1" "$?"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
