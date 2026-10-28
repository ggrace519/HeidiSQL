# HeidiSQL Lazarus/FreePascal port

> **HeidiSQL AI Edition** — this fork adds an AI assistant for writing and understanding SQL.
> See [AI-EDITION.md](AI-EDITION.md) for what differs from stock HeidiSQL, how to install it, and how
> to use the assistant. Linux archives (and, after 0.1.0, `.deb`/`.rpm` packages) are on the [releases page](https://github.com/ggrace519/HeidiSQL/releases/latest).

[![Build Status](https://github.com/ggrace519/HeidiSQL/actions/workflows/lazarus.yaml/badge.svg?branch=lazarus)](https://github.com/ggrace519/HeidiSQL/actions/workflows/lazarus.yaml?query=branch%3Alazarus)
[![Latest Release](https://img.shields.io/github/v/release/ggrace519/HeidiSQL?label=latest%20release&logo=github)](https://github.com/ggrace519/HeidiSQL/releases/latest)
[![Linux release](https://img.shields.io/badge/release-Linux-yellow?logo=Linux)](https://github.com/ggrace519/HeidiSQL/releases/latest)
[![Windows from source](https://img.shields.io/badge/from%20source-Windows-blue?logo=Windows)](#building)
[![macOS from source](https://img.shields.io/badge/from%20source-macOS-black?logo=macOS)](#building)
[![License](https://img.shields.io/github/license/ggrace519/HeidiSQL?logo=github)](https://github.com/ggrace519/HeidiSQL/blob/lazarus/LICENSE)
[![Downloads](https://img.shields.io/github/downloads/ggrace519/HeidiSQL/total?logo=github)](https://github.com/ggrace519/HeidiSQL/releases)


This is the code base for compiling HeidiSQL on Linux and macOS. From v13 onwards, the Windows version
will be compiled from here.

Since February 2025 I am migrating the sources from the master branch, using Lazarus and FreePascal. I
left away some Windows-only stuff which won't ever work on other platforms, such as some Windows message
handlings, and ADO driver usage. Therefore, support for MS SQL is being redeveloped via FreeTDS
(formerly ADO), but is not yet fully mature.  

Ansgar

![HeidiSQL GTK2 running on Ubuntu Linux 22.04](https://www.heidisql.com/images/screenshots/linux_version_datagrid.png)

### Building
Install Lazarus 4.8 and FreePascal 3.2.2 (the versions used by the CI build). Then load the `.lpi` file in the root directory in the Lazarus IDE.
Alternatively, use `/usr/bin/lazbuild heidisql.lpi` on the command line.

### Patching Lazarus 4.8
Local fixes for Lazarus 4.8 live in `extra/lazarus-patches/4.8/`. The CI applies all of them to the
Lazarus installation before building, and local builds should do the same:

```bash
for p in extra/lazarus-patches/4.8/*.patch; do
  patch -d /path/to/lazarus -p1 --dry-run < "$p" && patch -d /path/to/lazarus -p1 < "$p"
done
```
On Windows, use `patch --binary -p1` instead: without `--binary`, GNU patch strips the CRs from
the patch and rewrites the entire target file with LF line endings.

Patches are stored with LF line endings in the repository, so they match the LF line endings of
the Linux Lazarus installation applied by the CI. With `core.autocrlf=true` the Windows checkout
has CRLF line endings, matching the CRLF Lazarus installation for local application.

Generate new patches as commits in a git baseline of the local Lazarus installation and export them
with `git diff`, then convert to CRLF with `unix2dos` before applying locally with `patch --binary`.

The Cocoa patches fix undersized fonts and icons in all VirtualTree controls on retina displays,
caused by the blit scaling changes in Lazarus 4.6+ (upstream issues #41313/#41299).

### Icons8 copyright
Icons added in January 2019 are copyright by [Icons8](https://icons8.com). Used with a special permission
from Icons8 given to Ansgar for this project only. Do not copy them for anything else other than building
HeidiSQL.

[![Lazarus logo.](https://www.heidisql.com/images/powered-by-lazarus.png)](https://www.lazarus-ide.org/)

