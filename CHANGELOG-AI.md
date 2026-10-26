# HeidiSQL AI Edition changelog

Changes of the AI Edition fork. Upstream HeidiSQL changes are listed in [CHANGELOG.md](CHANGELOG.md).

## [Unreleased]

### Docs
- README badges now show this fork's build, release, license and downloads instead of upstream's, and
  AI-EDITION.md explains how to install the Linux release archives.

## [0.1.0] - 2026-10-26

First release of the AI Edition.

### Added
- **AI assistant panel** with **Generate SQL**: describe a query in your own words and the
  assistant writes SQL for the selected database, using its tables, columns and keys. The answer
  streams into a panel on the right; Insert, Replace or Copy put the SQL into the query editor
  without running it. Data- and structure-changing SQL is marked. Each query tab keeps its own
  conversation, and "Context sent" shows exactly what went to the provider.
- **Explain, Optimize and Fix error** with AI, in the Query menu and the editor's context menu:
  explain the selected SQL in plain language, get a faster version with index suggestions, or,
  after a query fails, get corrected SQL for the failed statement. Nothing is executed.
- **LLM Settings** tab in the session manager: enable the AI assistant per session (off by
  default), choose its provider, and write notes about the database that the model cannot see in
  the schema (e.g. units, soft deletes). The tab states exactly what is sent to the provider.
  Settings follow the session when it is renamed or cloned. If a session's provider is removed,
  the tab says so instead of silently switching to another provider.
- **AI providers** in Preferences: define the AI servers the assistant can use (local Ollama, LM
  Studio, vLLM, OpenRouter, OpenAI or any OpenAI-compatible server), test the connection, which
  lists the server's models, and store API keys in the system keychain (Secret Service on Linux,
  Credential Manager on Windows; on macOS a Terminal command is offered). Keys are never written to
  HeidiSQL's settings. HTTPS certificates are verified; self-signed servers can be allowed per
  provider, and an extra CA file can be added. A new installation starts with a "Local Ollama"
  provider.
- The AI Edition keeps its settings in its own folder (`heidisql-ai`), so it can run next to a
  stock HeidiSQL without the two overwriting each other's sessions, tabs and backups.
- On first start, the AI Edition offers to copy sessions, preferences, snippets, highlighters and
  query tab backups from a stock HeidiSQL on the same computer. The stock settings are left
  unchanged.
- Window titles and the About box show "HeidiSQL AI Edition". The About box shows the AI Edition
  version and the HeidiSQL version it is based on.

### Changed
- Based on upstream HeidiSQL 12.22 (Lazarus branch): Firebird/InterBase support, a role manager
  for PostgreSQL, a login manager for MS SQL Server, a Windows installer build and macOS fixes. See
  [CHANGELOG.md](CHANGELOG.md).
- The update check looks for AI Edition releases on GitHub (tags `ai-v<version>`) instead of
  stock HeidiSQL releases on heidisql.com.
- Usage statistics are no longer sent to the upstream heidisql.com service, and the option is
  hidden in Preferences.

### Fixed
- The update check reported "Updates available" and showed the release dialog without comparing
  versions. It now offers a release only when it is newer than the running version.
- Long status messages in the update check dialog ran underneath the Cancel button instead of
  wrapping.
- README listed Lazarus 4.4 as the build requirement while CI builds with Lazarus 4.8.

### Infrastructure
- CI builds pushes and pull requests to the new `develop` branch.
- Unit tests with fpcunit (`make test`), run by CI on Ubuntu.
