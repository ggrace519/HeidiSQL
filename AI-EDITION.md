# HeidiSQL AI Edition

*As of 2026-10-06, version 0.1.0 (in development).*

This fork of the HeidiSQL Lazarus/FreePascal port adds an AI assistant that helps write and
understand SQL for the database you are connected to. It is developed on top of the upstream
`lazarus` branch and can be installed next to a stock HeidiSQL.

The assistant itself is still in development. This page covers how the fork differs from stock
HeidiSQL today.

## Differences from stock HeidiSQL

| Area | AI Edition | Stock HeidiSQL |
|---|---|---|
| Settings folder | `~/.config/heidisql-ai/` (Linux and macOS), `%LOCALAPPDATA%\heidisql-ai\` (Windows) | `~/.config/heidisql/`, `%LOCALAPPDATA%\heidisql\` |
| Window title and About box | "HeidiSQL AI Edition" | "HeidiSQL" |
| Update check | Releases of this fork on GitHub, tagged `ai-v<version>` | heidisql.com |
| Usage statistics | Never sent, option hidden | Optional, sent to heidisql.com |

The client name reported to database servers (`program_name` / `application_name`) stays
"HeidiSQL", and translations are shared with the upstream project.

### First start

When the AI Edition starts for the first time and finds a stock HeidiSQL's settings, it offers to
copy them: sessions, preferences, snippets, custom highlighters and query tab backups. Open tabs
stay with the stock HeidiSQL. Paths inside the settings that
pointed to the stock folder are rewritten to the AI Edition's folder. The stock settings are not
changed. The offer appears only once, also when declined. To bring settings over later, use
**File > Export settings** in stock HeidiSQL and **File > Import settings** in the AI Edition.

Portable mode (a `portable.lock` file next to the executable) keeps its settings next to the
executable as before, and is never offered a copy.

## AI providers

**Tools > Preferences > AI providers** lists the AI servers the assistant can use. Each provider
has a base URL (usually ending in `/v1`), a model and an API key source. **Test** connects and
fills the model list. The provider marked with ★ is the default.

| Server | Base URL | API key |
|---|---|---|
| Ollama (local) | `http://localhost:11434/v1` | None |
| LM Studio (local) | `http://localhost:1234/v1` | None |
| OpenRouter | `https://openrouter.ai/api/v1` | Keychain entry |
| OpenAI | `https://api.openai.com/v1` | Keychain entry |

API keys are never stored in HeidiSQL's settings or in `ai-providers.json`. A provider names
where the key is:

- **Keychain entry:** the system keychain. **Store key...** asks for the key and saves it: in the
  Secret Service (GNOME Keyring, KWallet, KeePassXC) on Linux, or the Credential Manager on
  Windows. On macOS, run the Terminal command that **Store key...** copies to the clipboard.
- **Environment variable:** read when a request starts. Programs started from a desktop menu may
  not see variables set in a shell profile.

HTTPS certificates and host names are verified against the system's trusted certificates. For a
server with a self-signed certificate, tick **Accept untrusted HTTPS certificates**, or add its
CA in **Extra CA file**. Providers are saved in `ai-providers.json` in the settings folder;
**File > Export settings** does not include them.

## Building

```sh
make build-gtk2      # or build-qt5, build-qt6
./out/gtk2/heidisql
```

Requires Lazarus 4.8 and FreePascal 3.2.2. Do not install the fork with `make deb-package` or
`make rpm-package` next to a stock HeidiSQL package: both packages install the same files.

## Versioning and releases

The AI Edition has its own version (`AIEDITIONVERSION` in `source/const.inc`), independent of
the upstream version shown in the window title. Releases are tagged `ai-v<version>`, for
example `ai-v0.1.0`.

See [CHANGELOG-AI.md](CHANGELOG-AI.md) for changes, and [DECISIONS.md](DECISIONS.md) for the
reasoning behind them.
