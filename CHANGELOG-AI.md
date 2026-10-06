# HeidiSQL AI Edition changelog

Changes of the AI Edition fork. Upstream HeidiSQL changes are listed in [CHANGELOG.md](CHANGELOG.md).

## [Unreleased]

### Added
- The AI Edition keeps its settings in its own folder (`heidisql-ai`), so it can run next to a
  stock HeidiSQL without the two overwriting each other's sessions, tabs and backups.
- On first start, the AI Edition offers to copy sessions, preferences, snippets and highlighters
  from a stock HeidiSQL on the same computer. The stock settings are left unchanged.
- Window titles and the About box show "HeidiSQL AI Edition".

### Changed
- The update check looks for AI Edition releases on GitHub (tags `ai-v<version>`) instead of
  stock HeidiSQL releases on heidisql.com.
- Usage statistics are no longer sent to the upstream heidisql.com service, and the option is
  hidden in Preferences.

### Fixed
- The update check reported "Updates available" and showed the release dialog without comparing
  versions. It now offers a release only when it is newer than the running version.
- README listed Lazarus 4.4 as the build requirement while CI builds with Lazarus 4.8.

### Infrastructure
- CI builds pushes and pull requests to the new `develop` branch.
