# deepseek-harness-termux

**在 Android / Termux 上运行完整的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`）—— 核心功能全部可用。**

[English](README.md) | 简体中文

---

`deepseek-harness-termux` 是一个社区维护的兼容层，将官方 [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) 智能体框架移植到基于 [Termux](https://termux.com/) 的 Android 环境。官方 npm 包面向 glibc 系 Linux 发行版构建，依赖的原生模块在 Android 的 Bionic libc 上要么编译失败、要么行为异常。本项目直接修改关键源码来适配 Android，而不是禁用相关插件。

**当前目标版本：`dsh 0.2.1-rc.2` + `@deepseek-harness-tui/dsh-tui 0.16.1`。**

[`patches/0.2.1-rc.2/`](patches/0.2.1-rc.2/) 下的补丁均由干净的官方 npm tarball 通过 `diff -u` 生成，精确、可复现。旧的 0.1.0-rc.6 安装脚本保留为 `install-0.1.0-rc.6.sh`。

## 功能状态

| 组件 | 状态 | 说明 |
|---|---|---|
| `dsh web` | ✅ 正常 | 服务运行于 `http://127.0.0.1:3080` |
| `dsh headless` | ✅ 已验证 | 已做端到端测试（bash 工具 + 会话持久化） |
| `dsh-tui`（`dst`） | ✅ 正常 | 全屏终端界面；安装脚本会自动初始化 profile |
| `dsh plugin` | ✅ 正常 | 插件管理（转发给 pnpm） |
| HMR（热重载） | ✅ 正常 | `dsh` 包装脚本以 `--expose-internals` 启动 Node |
| 子进程 (Subprocess) | ✅ 正常 | `node-pty` 已针对 Termux bionic 工具链（API 30）重新编译 |
| Bash 沙箱 | ⚠️ 部分 | `bubblewrap` 被 Android sepolicy 拦截；新增 `proot` 运行器。proot 无法强制只读路径，因此报告为 `partial` |
| 权限系统 (Permission) | ✅ 正常 | 随 `node-pty` 一并恢复 |
| 会话锁 | ✅ 已修复 | Android 没有预编译包，改由 `koffi` 调用 libc `flock(2)` |
| 会话持久化 | ✅ 已修复 | Android sepolicy 下 `link(2)` 回退为 `rename(2)` |
| Bash 终端 (PTY) | ✅ 已修复 | 默认 shell 从 `$PREFIX/bin/bash` 解析 |
| TUI / Web UI | ✅ 正常 | 两个 profile 均可启动；dsh-tui 首次运行向导可录入 API key |

## 系统要求

- **Android 12+** 推荐（更早版本可能可运行，但未经测试）
- **Termux** — 请从 [F-Droid](https://f-droid.org/en/packages/com.termux/) 安装（Play Store 版本不受支持且已过时）
- **Node.js ^22.19 或 >= 24**、**npm**、以及原生模块构建工具链：
  ```bash
  pkg update && pkg install git nodejs-lts ndk-sysroot clang binutils make cmake pkg-config python proot
  ```
- **网络连接** — 用于下载依赖包

## 安装

```bash
# 克隆本仓库
git clone https://github.com/BAIGAOa/deepseek-harness-termux.git
cd deepseek-harness-termux

# 运行自动化安装脚本
bash install.sh
```

重复执行是安全的：脚本会重新安装固定版本的包、重新应用补丁、重新编译原生模块。补丁与版本绑定；只有存在对应补丁集时，才应通过 `DSH_VERSION` / `TUI_VERSION` 覆盖目标版本。

### 安装脚本做了什么

1. 以 `--ignore-scripts` 全局安装 `@deepseek-ai/dsh@0.2.1-rc.2` 和 `@deepseek-harness-tui/dsh-tui@0.16.1`（避免未打补丁的 `koffi` 直接编译失败）。
2. **强制使用 bionic 工具链**：如果装了 `glibc-runner`，`$PREFIX/glibc/bin` 往往排在 `PATH` 最前，`cc`/`gcc` 会产出 glibc 链接的 `.node`，Termux 的 Node 无法加载。脚本把 `$PREFIX/bin` 提前，并固定 `CC=clang`、`CXX=clang++`、`--target=aarch64-linux-android30`。
3. 应用 [`patches/0.2.1-rc.2/`](patches/0.2.1-rc.2/) 下的全部补丁。
4. 从补丁后的源码编译 `koffi`（补上 `<spawn.h>` 子集、`/bin/sh`、`statx`、`flock`）。
5. 用 Termux NDK 编译 `node-pty`（`-D__ANDROID_API__=30`）。
6. 运行剩余生命周期脚本（`ensure-spawn-helper`、`protobufjs`）。
7. 安装 `dsh` 包装脚本，以 `--expose-internals` 启动 Node（profile 解析器和 HMR 需要，且 `NODE_OPTIONS` 不允许该参数）。
8. 通过 `dsh plugin add` 初始化 `dsh-tui` profile，并修补其 host-entry 子进程，使其带 `--expose-internals` 启动（否则 TUI 会提示 `cannot host this launch` 并退回独立进程模式）。
9. 冒烟测试：`koffi`、`node-pty`、CLI 版本、profile 组合。

## 使用方法

```bash
dsh web              # Web UI → http://127.0.0.1:3080
dsh-tui              # 全屏终端界面（别名：dst）
dsh headless "…"     # 单次任务，输出结果后退出
```

配置 API Key（也可以让 dsh-tui 首次运行向导写入）：

```bash
export DEEPSEEK_API_KEY="sk-…"
```

### 沙箱模式

默认模式为 `workspace-write`。在 Android 上通过 `proot` 执行（`bwrap` 所需的 namespace 被 sepolicy 禁止）。proot 无法强制只读，因此其执行强度报告为 `partial`。

```bash
export DSH_PERMISSION_MODE=danger-full-access   # 不限制
export DSH_PERMISSION_MODE=workspace-write      # proot 包装（默认）
export DSH_PERMISSION_MODE=read-only            # proot 包装，但不强制只读
```

### 为什么需要包装脚本

本脚本安装的 `dsh` 命令不是上游 npm shim，而是一个很小的 shell 包装：

```sh
exec "$PREFIX/bin/node" --expose-internals "$DSH_DIR/lib/bin.js" "$@"
```

`--expose-internals` 是必需的：profile 解析器和 HMR 需要 `node:internal/modules/*`，而 Node 不允许通过 `NODE_OPTIONS` 传入该参数。

## 源码补丁

| 补丁 | 目标包 | 修复内容 |
|---|---|---|
| [`01-koffi-android.patch`](patches/0.2.1-rc.2/01-koffi-android.patch) | `koffi` 3.1.1 | Bionic 没有 `<spawn.h>`（声明所需子集）、没有 `/bin/sh`/`/bin/env`（解析到 `$PREFIX`/`/system/bin`）、没有 `statx()`（改用 `fstatat`） |
| [`02-require-builtin-js-fallback.patch`](patches/0.2.1-rc.2/02-require-builtin-js-fallback.patch) | `node-addon-require-builtin` 0.1.9 | Android 无预编译包；在 `--expose-internals` 下退回 `require('node:internal/…')` |
| [`03-node-addon-system-flock-koffi.patch`](patches/0.2.1-rc.2/03-node-addon-system-flock-koffi.patch) | `@deepseek-ai/node-addon-system` 0.1.2 | 无 Android 预编译包且 glibc 二进制无法加载；通过 `koffi` 调用 libc `flock(2)` |
| [`04-terminal-bash-termux-shell.patch`](patches/0.2.1-rc.2/04-terminal-bash-termux-shell.patch) | `dsh-terminal-bash` | 解析真实 shell（`$PREFIX/bin/bash`），而不是 `/bin/bash` |
| [`05-session-persistence-link-rename.patch`](patches/0.2.1-rc.2/05-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | Android sepolicy 拒绝 `link(2)`（`EACCES/EPERM`）时回退为原子 `rename(2)` |
| [`06-subprocess-local-android-index.patch`](patches/0.2.1-rc.2/06-subprocess-local-android-index.patch) | `dsh-subprocess-local` | 进程存活判断将 `android` 视同 `linux` |
| [`06b-subprocess-local-android-runner.patch`](patches/0.2.1-rc.2/06b-subprocess-local-android-runner.patch) | `dsh-subprocess-local` | 在 `android` 上构建 Linux `/proc` 进程检查器，而不是直接抛错 |
| [`07-sandbox-local-proot-runner.patch`](patches/0.2.1-rc.2/07-sandbox-local-proot-runner.patch) | `dsh-sandbox-local` | 为 `android` 增加 `proot` 运行器链（部分强制） |

## 兼容性说明

- **平台判定**：Termux 上 `process.platform` 为 `"android"`，上游 `platform === "linux"` 分支统一扩展为 `platform === "linux" || platform === "android"`。
- **Bash 沙箱**：`bubblewrap` 需要 `user_namespaces` 及特定 `/proc` 访问权限，Android sepolicy 会拒绝。补丁后的 sandbox provider 为 `android` 增加了 `proot` 运行器；proot 基于 ptrace，无法实现只读绑定，所以如实报告为 `partial`，而不是宣称完整隔离。
- **glibc-runner**：装有 `glibc-runner` 的 Termux 会把 `glibc/bin` 放在 `PATH` 最前，`cc`/`gcc`/`uname` 都会指向 glibc 工具。用它编译出的原生模块无法被 bionic Node 加载。安装脚本会提前 `$PREFIX/bin` 并固定 `CC=clang`/`CXX=clang++`；手动编译时也请这样做。
- **`link(2)`**：Android sepolicy 对应用数据目录中的硬链接返回 `EACCES`（已在 Android 12/f2fs 上验证），因此会话发布回退为 `rename(2)`。
- **`flock(2)`**：`@deepseek-ai/node-addon-system` 没有 Android 预编译包，补丁改为 `koffi` → `libc.so`。
- **升级**：`npm install -g` 与 `dsh-tui update` 会覆盖补丁文件和 `dsh` 包装脚本。升级后请重新运行 `bash install.sh`。

## 项目结构

```
deepseek-harness-termux/
├── README.md                     # 英文说明
├── README.zh-CN.md               # 本文件
├── LICENSE                       # MIT 许可证
├── install.sh                    # 自动化安装脚本（0.2.1-rc.2）
├── install-0.1.0-rc.6.sh         # 旧版安装脚本（保留参考）
├── patches/
│   ├── 0.2.1-rc.2/               # 当前目标的补丁
│   │   ├── 01-koffi-android.patch
│   │   ├── 02-require-builtin-js-fallback.patch
│   │   ├── 03-node-addon-system-flock-koffi.patch
│   │   ├── 04-terminal-bash-termux-shell.patch
│   │   ├── 05-session-persistence-link-rename.patch
│   │   ├── 06-subprocess-local-android-index.patch
│   │   ├── 06b-subprocess-local-android-runner.patch
│   │   └── 07-sandbox-local-proot-runner.patch
│   └── *.patch                   # 0.1.0-rc.6 旧补丁
└── ...
```

## 致谢

- **[DeepSeek AI](https://github.com/deepseek-ai)** — 优秀的 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 智能体框架。
- **[dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI)** — 全屏终端界面。
- **Termux 社区** — Android 终端环境。
- **koffi**、**node-pty** 的维护者。
- **[Vengisk](https://github.com/Vengisk)** — 原始 [deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) 项目。

## 许可证

MIT — 与官方 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 相同。参见 [LICENSE](LICENSE)。

---

*由 [BAIGAOa](https://github.com/BAIGAOa) 维护，基于 [Vengisk](https://github.com/Vengisk) 的原始项目 — 非 DeepSeek 官方产品。*
