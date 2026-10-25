# HeidiSQL AI Edition

*As of 2026-10-25, version 0.1.0 (in development).*

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

## Enabling the assistant for a session

The assistant is off for every session until you enable it. In the session manager, select a
session and open the **LLM Settings** tab:

- **Enable AI assistant for this session** turns it on for this connection only.
- **Provider** chooses one of the AI providers, or the default one. **Manage...** opens the
  provider settings.
- **Context notes** are sent with every request: write down what the schema does not say, such
  as units, status codes or conventions.

Sent to the provider with each request: table and column names, types, keys, comments,
approximate row counts, the notes, and the SQL or question being asked about. No table data. For
sensitive databases, use a local provider such as Ollama, so nothing leaves the computer.

**File > Export settings** includes these session settings (also the notes), but not the AI
providers. After importing on another computer, sessions whose provider does not exist there
show "(removed provider)" until you choose one.

## Generating SQL

**Query > AI assistant panel** shows the assistant on the right side of the main window.
**Query > Generate SQL with AI...** (Ctrl+Shift+G, also in the query editor's context menu) opens
it and puts the cursor into its prompt box.

1. Select a database (or one of its tables) in the tree. Without one, Generate SQL stays disabled,
   because the model needs the schema to write correct SQL.
2. Describe the query and press **Generate SQL** or Ctrl+Enter. The answer streams into the panel.
3. **Insert** puts the SQL at the cursor of the query editor, **Replace** replaces the editor's
   text, **Copy** copies it. Generated SQL is never executed; Ctrl+Z undoes Insert and Replace.
   When an answer has several SQL blocks, a list chooses which one to use.
4. SQL that changes data (DML) or the structure (DDL) gets a red warning.

Each query tab has its own conversation; follow-up questions include the last answers. **Clear**
starts over, closing the tab forgets it. Conversations are not saved. **Context sent...** shows
exactly what went to the provider with the last question. Only one question runs at a time;
**Cancel** stops it.

## Explaining, optimizing and fixing queries

The Query menu and the query editor's context menu also offer:

- **Explain query with AI**: a plain-language explanation of the selected SQL, or of the whole
  editor text when nothing is selected.
- **Optimize query with AI**: a faster version of the query with the same result, plus index
  suggestions as `CREATE INDEX` statements.
- **Fix error with AI**: when a query fails, the panel shows the error with a **Fix error**
  button. The failed statement and the server's message are sent, and the answer contains the
  corrected SQL. A later successful query in the same tab removes the offer.

Text typed into the prompt box before choosing one of these is sent along as a remark, e.g.
"focus on the joins". As with Generate SQL, nothing is executed.

Tables mentioned in the question or in the editor's SQL, the table selected in the tree, and
their foreign key neighbours are sent with their columns; other tables only by name, within the
provider's context size. While a query is running, only schema data that is already loaded is
sent.

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
