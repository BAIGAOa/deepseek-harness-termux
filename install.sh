#!/data/data/com.termux/files/usr/bin/bash
# install.sh — DeepSeek Harness (@deepseek-ai/dsh) on Android/Termux
#
# Targets dsh 0.2.1-rc.2 (override with DSH_VERSION). Installs dsh + dsh-TUI,
# patches the few places where upstream assumes glibc/macOS/Linux desktop, and
# builds the two native addons (koffi, node-pty) against Termux's bionic libc.
#
# Usage:  bash install.sh
# Re-run: safe — it reinstalls the pinned packages, reapplies the patches, and
#         rebuilds the native addons from scratch.
set -euo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"
TUI_VERSION="${TUI_VERSION:-0.16.1}"
ANDROID_API="${ANDROID_API:-30}"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$REPO_DIR/patches/0.2.1-rc.2"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    [OK] %s\n' "$1"; }
warn() { printf '    [!] %s\n' "$1" >&2; }
fail() { printf '    [x] %s\n' "$1" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
[ -n "${PREFIX:-}" ] && [ -d "$PREFIX" ] || fail 'This installer is for Termux (PREFIX is not set).'
[ -f "$PATCH_DIR/01-koffi-android.patch" ] || fail "Patch set missing: $PATCH_DIR"

# Termux + glibc-runner: the glibc prefix often sits first on PATH, which makes
# `cc`/`gcc`/`ar` resolve to glibc-target tools. Native addons built that way
# cannot be loaded by Termux's bionic Node. Put $PREFIX/bin first and pin the
# compilers explicitly.
export PATH="$PREFIX/bin:$HOME/.local/bin:/system/bin:$PATH"
export CC=clang
export CXX=clang++
export CFLAGS="--target=aarch64-linux-android${ANDROID_API} -D__ANDROID_API__=${ANDROID_API}"
export CXXFLAGS="$CFLAGS"
# Older Node headers reference android_ndk_path without a default; harmless on
# current headers and kept for forward/backward compatibility.
export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path="

NODE_BIN="$PREFIX/bin/node"
NPM_BIN="$PREFIX/bin/npm"
[ -x "$NODE_BIN" ] || fail 'Node.js not found. Run: pkg install nodejs-lts'
[ -x "$NPM_BIN" ] || fail 'npm not found. Run: pkg install nodejs-lts'

NODE_VERSION="$("$NODE_BIN" -p 'process.versions.node')"
NODE_MAJOR="${NODE_VERSION%%.*}"
NODE_REST="${NODE_VERSION#*.}"
NODE_MINOR="${NODE_REST%%.*}"
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 19 ]; }; then
    fail "Node.js $NODE_VERSION is too old; dsh needs ^22.19 or >=24."
fi
ok "Node.js $NODE_VERSION"

# ── Step 1: system dependencies ──────────────────────────────────────────────
step '[1/9] Checking system dependencies'
SYSTEM_PKGS=(ndk-sysroot clang binutils make cmake pkg-config python patch git proot)
MISSING=()
for pkg in "${SYSTEM_PKGS[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "$pkg"
    else
        MISSING+=("$pkg")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    printf '    -> installing: %s\n' "${MISSING[*]}"
    pkg install -y "${MISSING[@]}"
fi
ok "clang: $(command -v clang)"
ok "cc:    $(command -v cc)"

# ── Step 2: install dsh + dsh-TUI ────────────────────────────────────────────
# --ignore-scripts: koffi and node-pty are patched first and then built below.
# Installing with scripts enabled would fail on the pristine koffi source.
step '[2/9] Installing @deepseek-ai/dsh and @deepseek-harness-tui/dsh-tui'
install_pkgs() {
    "$NPM_BIN" install -g \
        "@deepseek-ai/dsh@$DSH_VERSION" \
        "@deepseek-harness-tui/dsh-tui@$TUI_VERSION" \
        --ignore-scripts --no-audit --no-fund "$@"
}
if ! install_pkgs; then
    warn 'npm registry failed; retrying with npmmirror…'
    install_pkgs --registry=https://registry.npmmirror.com ||
        fail 'npm install failed on both registries.'
fi

DSH_DIR="$("$NPM_BIN" root -g)/@deepseek-ai/dsh"
[ -d "$DSH_DIR" ] || fail "dsh package directory not found: $DSH_DIR"
ok "dsh installed at $DSH_DIR"

# dsh plugin delegates to pnpm; the TUI bootstrap needs it.
if ! command -v pnpm >/dev/null 2>&1; then
    warn 'pnpm not found; installing it'
    "$NPM_BIN" install -g pnpm --no-audit --no-fund ||
        fail 'Could not install pnpm.'
fi
ok "pnpm: $(pnpm --version)"

# ── Step 3: apply Android patches ────────────────────────────────────────────
step '[3/9] Applying Android/Termux patches'
apply_patch() {
    local pkgdir="$1" patchfile="$2"
    local name; name="$(basename "$patchfile")"
    if [ ! -d "$pkgdir" ]; then
        fail "required package missing for $name: $pkgdir"
    fi
    if (cd "$pkgdir" && patch -p1 --dry-run --reverse < "$patchfile" >/dev/null 2>&1); then
        ok "$name (already applied)"
        return 0
    fi
    if (cd "$pkgdir" && patch -p1 --dry-run --forward < "$patchfile" >/dev/null 2>&1); then
        (cd "$pkgdir" && patch -p1 --forward < "$patchfile" >/dev/null)
        ok "$name"
        return 0
    fi
    warn "$name does not apply (upstream version drift?)"
    fail "cannot continue without patch: $name"
}

NM="$DSH_DIR/node_modules"
apply_patch "$NM/koffi"                                          "$PATCH_DIR/01-koffi-android.patch"
apply_patch "$NM/node-addon-require-builtin"                     "$PATCH_DIR/02-require-builtin-js-fallback.patch"
apply_patch "$NM/@deepseek-ai/node-addon-system"                  "$PATCH_DIR/03-node-addon-system-flock-koffi.patch"
apply_patch "$NM/@deepseek-ai/dsh-terminal-bash"                  "$PATCH_DIR/04-terminal-bash-termux-shell.patch"
apply_patch "$NM/@deepseek-ai/dsh-session-persistence-jsonl"      "$PATCH_DIR/05-session-persistence-link-rename.patch"
apply_patch "$NM/@deepseek-ai/dsh-subprocess-local"               "$PATCH_DIR/06-subprocess-local-android-index.patch"
apply_patch "$NM/@deepseek-ai/dsh-subprocess-local"               "$PATCH_DIR/06b-subprocess-local-android-runner.patch"
apply_patch "$NM/@deepseek-ai/dsh-sandbox-local"                  "$PATCH_DIR/07-sandbox-local-proot-runner.patch"

# ── Step 4: build koffi ──────────────────────────────────────────────────────
step '[4/9] Building koffi for Android'
KOFFI_DIR="$NM/koffi"
if command find "$KOFFI_DIR/build/koffi" -name koffi.node -type f 2>/dev/null | grep -q .; then
    ok 'koffi.node already built'
else
    (cd "$KOFFI_DIR" && rm -rf build/koffi/android_arm64 &&
        npm_config_nodedir="$PREFIX" "$NODE_BIN" ./cnoke.cjs -P . -D src/koffi --prebuild --release) ||
        fail 'koffi build failed (see output above)'
    ok 'koffi.node built'
fi

# ── Step 5: build node-pty ───────────────────────────────────────────────────
step '[5/9] Building node-pty for Android'
PTY_DIR="$NM/node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    ok 'pty.node already built'
else
    NODE_GYP="$PREFIX/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
    [ -f "$NODE_GYP" ] || fail "node-gyp not found at $NODE_GYP"
    (cd "$PTY_DIR" && rm -rf build &&
        "$NODE_BIN" "$NODE_GYP" rebuild --nodedir="$PREFIX") ||
        fail 'node-pty build failed (see output above)'
    ok 'pty.node built'
fi

# ── Step 6: remaining lifecycle scripts ──────────────────────────────────────
step '[6/9] Running remaining package lifecycle scripts'
if [ -f "$NM/@deepseek-ai/dsh-subprocess-local/scripts/ensure-spawn-helper.mjs" ]; then
    (cd "$NM/@deepseek-ai/dsh-subprocess-local" && "$NODE_BIN" scripts/ensure-spawn-helper.mjs) ||
        warn 'ensure-spawn-helper failed (non-fatal)'
    ok 'node-pty spawn helper checked'
fi
if [ -f "$NM/protobufjs/scripts/postinstall.js" ]; then
    (cd "$NM/protobufjs" && "$NODE_BIN" scripts/postinstall) ||
        warn 'protobufjs postinstall failed (non-fatal)'
    ok 'protobufjs postinstall'
fi

# ── Step 7: fix CLI shims and install the dsh wrapper ────────────────────────
step '[7/9] Installing Termux CLI wrappers'
for f in "$PREFIX/bin/dsh-tui" "$PREFIX/bin/dst"; do
    [ -e "$f" ] || continue
    command -v termux-fix-shebang >/dev/null 2>&1 && termux-fix-shebang "$f" || true
done
# dsh must run with --expose-internals: the profile resolver and HMR reach into
# Node internals, and NODE_OPTIONS rejects this flag.
rm -f "$PREFIX/bin/dsh"
cat > "$PREFIX/bin/dsh" <<EOF
#!$PREFIX/bin/sh
# Generated by deepseek-harness-termux/install.sh
exec "$NODE_BIN" --expose-internals "$DSH_DIR/lib/bin.js" "\$@"
EOF
chmod +x "$PREFIX/bin/dsh"
ok "$PREFIX/bin/dsh"

# ── Step 8: bootstrap the dsh-TUI profile ────────────────────────────────────
step '[8/9] Preparing the dsh-tui profile'
TUI_PROFILE="$HOME/.dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui"
if [ -d "$TUI_PROFILE" ]; then
    ok 'dsh-tui profile already installed'
else
    "$PREFIX/bin/dsh" plugin --profile dsh-tui add \
        "@deepseek-harness-tui/dsh-tui@$TUI_VERSION" ||
        warn 'dsh-tui profile bootstrap failed; the launcher will retry on first run'
    [ -d "$TUI_PROFILE" ] && ok 'dsh-tui profile installed'
fi
# dsh-tui starts its host-entry child with a bare `node`; on Android that child
# needs --expose-internals to reach Node internals (otherwise the TUI prints
# "cannot host this launch" and falls back to a separate dsh process).
TUI_BIN="$TUI_PROFILE/bin/dsh-tui.js"
if [ -f "$TUI_BIN" ]; then
    if grep -qF 'spawn(process.execPath, ["--expose-internals", entry, ...appArgs]' "$TUI_BIN"; then
        ok 'dsh-tui host-entry spawn already patched'
    elif grep -qF 'spawn(process.execPath, [entry, ...appArgs]' "$TUI_BIN"; then
        sed -i 's/spawn(process\.execPath, \[entry, \.\.\.appArgs\]/spawn(process.execPath, ["--expose-internals", entry, ...appArgs]/' "$TUI_BIN"
        ok 'dsh-tui host-entry spawn patched'
    else
        warn 'dsh-tui host-entry spawn pattern not found; TUI may fall back to a separate process'
    fi
fi

# ── Step 9: smoke tests ──────────────────────────────────────────────────────
step '[9/9] Smoke tests'
"$NODE_BIN" -e "require('$NM/koffi'); console.log('    koffi: OK')" ||
    fail 'koffi failed to load'
"$NODE_BIN" -e "require('$NM/node-pty'); console.log('    node-pty: OK')" ||
    fail 'node-pty failed to load'
"$PREFIX/bin/dsh" --version >/dev/null || fail 'dsh --version failed'
ok "dsh $("$PREFIX/bin/dsh" --version)"
"$PREFIX/bin/dsh" --profile web --dump-config >/dev/null || fail 'dsh web profile failed to compose'
ok 'web profile composes'

printf '\n==> Installation complete\n\n'
cat <<'EOF'
Start:
  dsh web          # Web UI on http://127.0.0.1:3080 (opens the browser)
  dsh-tui          # Full-screen terminal UI (alias: dst)
  dsh headless "…" # One-shot task

Credentials:
  export DEEPSEEK_API_KEY="sk-…"     # https://platform.deepseek.com
  (dsh-tui's first-run wizard can also store it.)

Sandbox:
  Default mode is workspace-write, enforced through proot (partial: proot
  cannot make paths read-only). Set DSH_PERMISSION_MODE=danger-full-access to
  run unconfined, or read-only/workspace-write to keep the proot wrapper.

Note:
  npm upgrades and `dsh-tui update` overwrite the patches. Re-run
  `bash install.sh` afterwards.
EOF
