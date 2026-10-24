# deepseek-harness-termux

**Run the full [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) on Android / Termux — no features disabled.**

English | [简体中文](README.zh-CN.md)

---

`deepseek-harness-termux` is a community-maintained compatibility layer that ports the official `@deepseek-ai/dsh` [agent harness](https://github.com/deepseek-ai/deepseek-harness) to Android environments running [Termux](https://termux.com/). The official npm package is built for glibc-based Linux distributions and depends on native modules that fail to compile or misbehave on Android's Bionic libc. Instead of disabling plugins that depend on those modules, this repository patches the source code so the harness works on Termux.

**Current target: `dsh 0.2.1-rc.2` + `@deepseek-harness-tui/dsh-tui 0.16.1`.**

All patches under [`patches/0.2.1-rc.2/`](patches/0.2.1-rc.2/) were generated against the pristine upstream npm tarballs with `diff -u`, so they are exact and reproducible. The previous 0.1.0-rc.6 installer is kept as `install-0.1.0-rc.6.sh`.

## Feature Status

Every plugin is enabled and working in the Termux build:

| Component | Status | Notes |
|---|---|---|
| `dsh web` | ✅ Working | Server runs on `http://127.0.0.1:3080` |
| `dsh headless` | ✅ Verified | End-to-end run tested (bash tool + session persistence) |
| `dsh-tui` (`dst`) | ✅ Working | Full-screen TUI; profile bootstrapped by the installer |
| `dsh plugin` | ✅ Working | Plugin management (forwards to pnpm) |
| HMR (Hot Reload) | ✅ Working | `dsh` wrapper launches Node with `--expose-internals` |
| Subprocess | ✅ Working | `node-pty` rebuilt against Termux's bionic toolchain (API 30) |
| Bash Sandbox | ⚠️ Partial | `bubblewrap` is blocked by Android sepolicy; a `proot` runner is added. proot cannot enforce read-only paths, so enforcement is reported as `partial` |
| Permission System | ✅ Working | Restored with `node-pty` |
| Session locking | ✅ Fixed | `flock` via `koffi` → libc (no Android prebuilt exists) |
| Session Persistence | ✅ Fixed | `link(2)` → `rename(2)` fallback for Android sepolicy |
| Bash Terminal (PTY) | ✅ Fixed | Default shell resolved from `$PREFIX/bin/bash` |
| TUI/Web UI | ✅ Working | Both profiles boot; `dsh-tui` first-run wizard covers the API key |

## Prerequisites

- **Android 12+** recommended (older versions may work but are untested)
- **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (the Play Store version is unsupported and outdated)
- **Node.js ^22.19 or >= 24**, **npm**, and the build toolchain for native modules:
  ```bash
  pkg update && pkg install git nodejs-lts ndk-sysroot clang binutils make cmake pkg-config python proot
  ```
- **Internet connection** for downloading packages

## Installation

```bash
# Clone this repository
git clone https://github.com/BAIGAOa/deepseek-harness-termux.git
cd deepseek-harness-termux

# Run the automated installer
bash install.sh
```

Re-running the installer is safe: it reinstalls the pinned packages, reapplies the patches, and rebuilds the native addons. Patch sets are version-specific; `DSH_VERSION` / `TUI_VERSION` can override the target only when a matching patch set is present.

### How the installer works

1. **Installs** `@deepseek-ai/dsh@0.2.1-rc.2` and `@deepseek-harness-tui/dsh-tui@0.16.1` globally with `--ignore-scripts` (so pristine `koffi` never tries to build).
2. **Forces the bionic toolchain.** If `glibc-runner` is installed, `$PREFIX/glibc/bin` is usually first on `PATH`, making `cc`/`gcc` produce glibc-linked addons that Termux's Node cannot load. The installer prepends `$PREFIX/bin` and pins `CC=clang`, `CXX=clang++`, `--target=aarch64-linux-android30`.
3. **Applies the Android source patches** under [`patches/0.2.1-rc.2/`](patches/0.2.1-rc.2/).
4. **Builds `koffi`** from the patched source (no `spawn.h`, no `/bin/sh`, no `statx`, Android `flock`).
5. **Builds `node-pty`** against the Termux NDK with `-D__ANDROID_API__=30`.
6. **Runs the remaining lifecycle scripts** (`ensure-spawn-helper`, `protobufjs`).
7. **Installs a `dsh` wrapper** that launches Node with `--expose-internals` (required by the profile resolver, and rejected by `NODE_OPTIONS`).
8. **Bootstraps the `dsh-tui` profile** through `dsh plugin add`, then patches its host-entry child to start with `--expose-internals` (otherwise the TUI prints `cannot host this launch` and falls back to a separate process).
9. **Runs smoke tests** for `koffi`, `node-pty`, the CLI version, and profile composition.

## Usage

### Start

```bash
dsh web              # Web UI → http://127.0.0.1:3080
dsh-tui              # Full-screen terminal UI (alias: dst)
dsh headless "…"     # One-shot task, print the answer, exit
```

Set your key once (the TUI's first-run wizard can also store it):

```bash
export DEEPSEEK_API_KEY="sk-…"
```

### Sandbox modes

The deployment default is `workspace-write`. On Android it is enforced through
`proot` (the only user-space option: `bwrap` needs namespaces blocked by
sepolicy). proot cannot make paths read-only, so its enforcement is reported as
`partial`.

```bash
export DSH_PERMISSION_MODE=danger-full-access   # unconfined
export DSH_PERMISSION_MODE=workspace-write      # proot wrapper (default)
export DSH_PERMISSION_MODE=read-only            # proot wrapper, writes not enforced
```

### Why the wrapper

The `dsh` command installed by this script is a tiny shell wrapper, not the
upstream npm shim:

```sh
exec "$PREFIX/bin/node" --expose-internals "$DSH_DIR/lib/bin.js" "$@"
```

`--expose-internals` is mandatory: the profile resolver and HMR require
`node:internal/modules/*`, and Node rejects that flag in `NODE_OPTIONS`.

## Patches

| Patch | Package | What it fixes |
|---|---|---|
| [`01-koffi-android.patch`](patches/0.2.1-rc.2/01-koffi-android.patch) | `koffi` 3.1.1 | Bionic has no `<spawn.h>` (declare the libc subset), no `/bin/sh`/`/bin/env` (resolve `$PREFIX`/`/system/bin`), no `statx()` (use `fstatat`), so it compiles on Android |
| [`02-require-builtin-js-fallback.patch`](patches/0.2.1-rc.2/02-require-builtin-js-fallback.patch) | `node-addon-require-builtin` 0.1.9 | No Android prebuilt exists; fall back to `require('node:internal/…')` under `--expose-internals` |
| [`03-node-addon-system-flock-koffi.patch`](patches/0.2.1-rc.2/03-node-addon-system-flock-koffi.patch) | `@deepseek-ai/node-addon-system` 0.1.2 | No Android prebuilt and glibc binaries cannot load; call libc `flock(2)` through `koffi` |
| [`04-terminal-bash-termux-shell.patch`](patches/0.2.1-rc.2/04-terminal-bash-termux-shell.patch) | `dsh-terminal-bash` | Resolves a real shell (`$PREFIX/bin/bash`) instead of `/bin/bash` |
| [`05-session-persistence-link-rename.patch`](patches/0.2.1-rc.2/05-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | Falls back to atomic `rename(2)` when Android sepolicy blocks `link(2)` with `EACCES/EPERM` |
| [`06-subprocess-local-android-index.patch`](patches/0.2.1-rc.2/06-subprocess-local-android-index.patch) | `dsh-subprocess-local` | Treats `android` like `linux` for process liveness |
| [`06b-subprocess-local-android-runner.patch`](patches/0.2.1-rc.2/06b-subprocess-local-android-runner.patch) | `dsh-subprocess-local` | Builds the Linux `/proc` process inspector on `android` instead of throwing |
| [`07-sandbox-local-proot-runner.patch`](patches/0.2.1-rc.2/07-sandbox-local-proot-runner.patch) | `dsh-sandbox-local` | Adds an `android` runner chain using `proot` (partial enforcement) |

## Compatibility Notes

- **Platform detection**: `process.platform` is `"android"` on Termux, so upstream `platform === "linux"` branches are extended to `platform === "linux" || platform === "android"`.
- **Bash sandbox**: `bubblewrap` requires `user_namespaces` and specific `/proc` access that Android sepolicy denies. The patched sandbox provider adds a `proot` runner for `android`. proot is ptrace-based and cannot enforce read-only binds, so the provider reports `partial` enforcement — this is honest about the weaker guarantee, not full confinement.
- **glibc-runner**: a Termux install with `glibc-runner` puts `/data/data/com.termux/files/usr/glibc/bin` first on `PATH`; `cc`/`gcc`/`uname` then resolve to glibc tools. Native addons built with them cannot load into bionic Node. The installer prepends `$PREFIX/bin` and sets `CC=clang`/`CXX=clang++`; if you build manually, do the same.
- **`link(2)`**: Android sepolicy returns `EACCES` for `link(2)` in app data (tested on Android 12/f2fs), so session publication falls back to `rename(2)`.
- **`flock(2)`**: there is no Android prebuilt for `@deepseek-ai/node-addon-system`; the patch routes it through `koffi` → `libc.so`.
- **Upgrades**: `npm install -g` and `dsh-tui update` replace the patched files (and the `dsh` wrapper). Re-run `bash install.sh` after either.

## Project Structure

```
deepseek-harness-termux/
├── README.md                     # This file (English)
├── README.zh-CN.md               # 简体中文 README
├── LICENSE                       # MIT License
├── install.sh                    # Automated installer (0.2.1-rc.2)
├── install-0.1.0-rc.6.sh         # Previous installer, kept for reference
├── patches/
│   ├── 0.2.1-rc.2/               # Patches for the current target
│   │   ├── 01-koffi-android.patch
│   │   ├── 02-require-builtin-js-fallback.patch
│   │   ├── 03-node-addon-system-flock-koffi.patch
│   │   ├── 04-terminal-bash-termux-shell.patch
│   │   ├── 05-session-persistence-link-rename.patch
│   │   ├── 06-subprocess-local-android-index.patch
│   │   ├── 06b-subprocess-local-android-runner.patch
│   │   └── 07-sandbox-local-proot-runner.patch
│   └── *.patch                   # Legacy 0.1.0-rc.6 patches
└── ...
```

## Acknowledgements

- **[DeepSeek AI](https://github.com/deepseek-ai)** for the excellent [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) agent framework.
- **[dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI)** for the full-screen terminal UI.
- **Termux Community** for the Android terminal environment.
- **koffi** and **node-pty** maintainers.
- **[Vengisk](https://github.com/Vengisk)** for the original [deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) project.

## License

MIT — same as the original [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). See [LICENSE](LICENSE).

---

*Maintained by [BAIGAOa](https://github.com/BAIGAOa). Based on the original project by [Vengisk](https://github.com/Vengisk) — not an official DeepSeek product.*