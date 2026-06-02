# Kandelo 编译运行实验报告

**环境**: Ubuntu 24.04 LTS x86_64  + Nix 2.34
**日期**: 2026-06-02
**目标**: 使用 Nix dev shell 从源码编译并运行 Kandelo POSIX-on-WebAssembly 内核及 Browser Demo。

> **2026-06-02 更新**：此前无 Nix 纯手动安装工具链的方案已归档（见下方「无 Nix 环境安装」章节）。
> 当前推荐且 **唯一 CI 验证** 的路径是 `scripts/dev-shell.sh`（`nix develop --ignore-environment` 的封装）。

---

## 概述

Kandelo 是一个将 POSIX 系统调用映射到 WebAssembly 的多进程内核，由三层组成：
- **Kernel**（Rust → wasm64）：实现 170+ POSIX syscall
- **Host**（TypeScript）：Node.js / 浏览器运行时
- **Glue**（C）：每个用户程序内嵌的 `channel_syscall.c`，将 musl 的 `__syscall` 转为 SharedArrayBuffer channel 调用

---

Nix flake 管理所有构建依赖，无需手动安装。只需安装 Nix 后使用 `scripts/dev-shell.sh`：

```bash
# 进入 dev shell（自动将 LLVM 21、Rust、Node 24、SDK 等加入 PATH）
bash scripts/dev-shell.sh bash

# 或单条命令执行
bash scripts/dev-shell.sh <command>
```

Dev shell 封装了 `nix develop --ignore-environment` 并保留了 HOME、GH_TOKEN 等必要环境变量，
**不会**泄漏宿主系统上未声明的工具，保证与 CI 行为一致。

---

### 无 Nix 环境安装（归档）

如无法使用 Nix，需手动安装以下工具：

---

## 安装步骤

### 1. 安装 Rust toolchain（rustup）

```bash
# 下载并安装 rustup（不修改 shell profile）
python3 -c "import urllib.request; urllib.request.urlretrieve('https://sh.rustup.rs', '/tmp/rustup-init.sh')"
chmod +x /tmp/rustup-init.sh
RUSTUP_HOME=/home/exedev/.rustup CARGO_HOME=/home/exedev/.cargo \
  sh /tmp/rustup-init.sh -y --no-modify-path --default-toolchain none

export PATH="/home/exedev/.cargo/bin:$PATH"

# 安装项目锁定的 nightly 版本（含 rust-src + wasm32 target）
rustup toolchain install nightly-2026-04-27 \
  --component rust-src \
  --target wasm32-unknown-unknown
```

> `.cargo/config.toml` 默认 target 是 `wasm64-unknown-unknown`，该 target 没有预编译 stdlib，
> `build.sh` 通过 `-Z build-std=core,alloc` 从源码构建，因此 **不需要** 单独 `rustup target add wasm64`。

### 2. 安装 LLVM 21（预编译包）

```bash
# 从 GitHub Releases 下载 LLVM 21 Linux x64 二进制
python3 -c "import urllib.request; urllib.request.urlretrieve(
  'https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/LLVM-21.1.8-Linux-X64.tar.xz',
  '/home/exedev/llvm-21.tar.xz')"

mkdir -p /home/exedev/llvm-21
tar xf /home/exedev/llvm-21.tar.xz -C /home/exedev/llvm-21 --strip-components=1

export PATH="/home/exedev/llvm-21/bin:$PATH"
export LLVM_BIN="/home/exedev/llvm-21/bin"
export LLVM_PREFIX="/home/exedev/llvm-21"
export LLVM_VERSION=21
```

验证：
```
clang version 21.1.8
wasm-ld: LLD 21.1.8
```

### 3. 安装 Node.js 24

```bash
python3 -c "import urllib.request; urllib.request.urlretrieve(
  'https://nodejs.org/dist/latest-v24.x/node-v24.16.0-linux-x64.tar.xz',
  '/home/exedev/node-24.tar.xz')"

tar xf /home/exedev/node-24.tar.xz -C /home/exedev

export PATH="/home/exedev/node-v24.16.0-linux-x64/bin:$PATH"
```

> **重要**：必须 Node.js 24+。Node 22 的 V8 不默认开启 memory64（wasm64 大内存），会导致内核实例化失败。

### 4. 安装 wabt 和 binaryen（可选，测试用）

```bash
# wabt（提供 wat2wasm）
python3 -c "import urllib.request; urllib.request.urlretrieve(
  'https://github.com/WebAssembly/wabt/releases/download/1.0.41/wabt-1.0.41-linux-x64.tar.gz',
  '/home/exedev/wabt.tar.gz')"
mkdir -p /home/exedev/wabt && tar xf /home/exedev/wabt.tar.gz -C /home/exedev/wabt --strip-components=1

# binaryen（提供 wasm-opt）
python3 -c "import urllib.request; urllib.request.urlretrieve(
  'https://github.com/WebAssembly/binaryen/releases/download/version_130/binaryen-version_130-x86_64-linux.tar.gz',
  '/home/exedev/binaryen.tar.gz')"
mkdir -p /home/exedev/binaryen && tar xf /home/exedev/binaryen.tar.gz -C /home/exedev/binaryen --strip-components=1

export PATH="/home/exedev/wabt/bin:/home/exedev/binaryen/bin:$PATH"
```

---

## 编译步骤

### Nix dev shell 方式（推荐）

```bash
cd /home/exedev/kandelo

# 所有命令通过 dev-shell.sh 执行
bash scripts/dev-shell.sh bash scripts/build-musl.sh
bash scripts/dev-shell.sh bash build.sh
```

### 环境变量（无 Nix 时需手动设置）

```bash
export PATH="/home/exedev/kandelo/sdk/bin:\
/home/exedev/.cargo/bin:\
/home/exedev/llvm-21/bin:\
/home/exedev/node-v24.16.0-linux-x64/bin:\
/home/exedev/wabt/bin:\
/home/exedev/binaryen/bin:\
$PATH"
export LLVM_BIN="/home/exedev/llvm-21/bin"
export LLVM_PREFIX="/home/exedev/llvm-21"
export LLVM_VERSION=21
```

### Step 1：初始化 musl 子模块

```bash
cd /home/exedev/kandelo
git submodule update --init libc/musl
```

### Step 2：编译 musl wasm32 sysroot

```bash
bash scripts/build-musl.sh
```

输出：`sysroot/lib/libc.a`（约 1.4 MB）

构建过程：
1. 将 `libc/musl-overlay/` 的 wasm32posix 架构文件复制进 musl 源码树
2. 写入 `config.mak`（CC = clang --target=wasm32-unknown-unknown）
3. `make -j$(nproc)` 构建 libc.a + CRT 对象
4. `make install` 安装到 `sysroot/`
5. 额外编译 `__main_void`、`wasm_setjmp_rt`、`sigsetjmp_helpers` 并合入 libc.a

### Step 3：主构建（内核 + host + 用户程序）

```bash
bash build.sh
```

该脚本完成：
1. `cargo build --release -p kandelo -Z build-std=core,alloc`  
   → 产出 `target/wasm64-unknown-unknown/release/kandelo_kernel.wasm`  
   → 复制到 `local-binaries/kernel.wasm`（686 KB）
2. 编译 `wasm-fork-instrument` 宿主工具  
   → `tools/bin/wasm-fork-instrument`
3. 编译 `programs/*.c` 和 `examples/*.c`（C 和 C++ 测试用程序）
4. `cd host && npm install && npm run build`（tsup 打包 TypeScript host）
5. `bash scripts/build-rootfs.sh`（构建 `host/wasm/rootfs.vfs`，约 16 MB）

**注意**：Step 3 中 C++ 程序（如 `c_01_fork_in_try_no_throw.cpp`）需要 `wasm32posix-c++`，  
必须先将 `sdk/bin/` 加入 PATH，否则报 `command not found`。

### Step 4：一键安装 SDK（供后续 C 程序编译使用）

SDK 在 `sdk/bin/` 已有现成的 shell wrapper 脚本。Nix dev shell 已自动将 SDK 加入 PATH：

```bash
# 在 dev shell 内已自动生效
wasm32posix-cc --version

# 无 Nix 时需要手动 source
source /home/exedev/kandelo/sdk/activate.sh
```

或手动：`export PATH="/home/exedev/kandelo/sdk/bin:$PATH"`

SDK 工具列表：
- `wasm32posix-cc` / `wasm32posix-c++` — C/C++ 编译器（clang wrapper）
- `wasm32posix-ar` / `wasm32posix-ranlib` — 静态库工具
- `wasm32posix-nm` / `wasm32posix-strip` — 符号/裁剪工具
- `wasm32posix-configure` — autoconf 跨编译辅助

---

## 运行验证

### 编译并运行 hello world

```bash
wasm32posix-cc examples/hello.c -o examples/hello.wasm
npx tsx examples/run-example.ts hello
```

输出：
```
Hello from musl on kandelo!
```

---

## 测试结果

### Kernel 单元测试（864 项）

```bash
cargo test -p kandelo --target x86_64-unknown-linux-gnu --lib
```

```
test result: ok. 864 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.09s
```

> **注意**：文档中写的 `--target aarch64-apple-darwin` 是 macOS 专用写法（用宿主 target 运行 no_std 测试）。
> Linux x86_64 上应改用 `--target x86_64-unknown-linux-gnu`。

### Vitest 集成测试（跳过）

vitest global-setup 在启动时会：
1. 调用 `wat2wasm` 汇编测试 fixture
2. 安装 Playwright chromium（browser-kernel 测试需要）

由于 Playwright 需要下载浏览器二进制（约 300MB+），耗时过长，本次跳过。  
若需运行：
```bash
cd host && npx vitest run
```

---

## 关键坑点与解决方法

| 问题 | 原因 | 解决方法 |
|------|------|----------|
| `wasm32posix-c++: command not found` | `sdk/bin` 未加入 PATH | `export PATH="sdk/bin:$PATH"` 或 `source sdk/activate.sh` |
| `npm link` 的 SDK wrapper 找不到 ts 文件 | 安装后绝对路径指向 node bin 目录而非 repo | 改用 `sdk/bin/` 直接在 PATH 中（worktree-local 方式）|
| `rustup target add wasm64-unknown-unknown` 报错 | wasm64 没有预编译 stdlib | 不需要添加；build.sh 用 `-Z build-std` 从源码构建 |
| Cargo tests 默认 target 是 wasm64 | `.cargo/config.toml` 写死了 `target = "wasm64-unknown-unknown"` | `cargo test` 时显式指定 `--target x86_64-unknown-linux-gnu` |
| `sysctl -n hw.ncpu` 在 Linux 返回空 | build-musl.sh 里用了 macOS 的 CPU 数获取命令 | 脚本有 `|| echo 4` 兜底，自动退回 4 核并行，无影响 |
| LLVM 找不到 | `scripts/build-musl.sh` 默认读 `/opt/homebrew/opt/llvm/bin` | 设置 `LLVM_BIN` 环境变量覆盖 |
| `zip: command not found` | `build-vim-zip.sh` 需要宿主 `zip` 命令 | Nix dev shell 自带 `zip`；无 Nix 时手动安装：`apt install zip` 或下载预编译二进制 |
| `cache_key_sha mismatch` 警告 | 本地 recipe 与发布存档的 cache key 不符 | 若回退源码构建也失败，需排查缺失的宿主工具（如 `zip`）；否则可用 `--allow-stale` 忽略 |
| GitHub Pages 404 `/pages/kandelo/` | `index.html` 重定向使用 `window.location.origin`（绝对路径），忽略了 VITE_BASE | 改为 `new URL("pages/kandelo/", window.location.href)`（相对路径解析）|

---

## 产出文件

| 文件 | 大小 | 说明 |
|------|------|------|
| `local-binaries/kernel.wasm` | 686 KB | wasm64 内核，`binary-resolver.ts` 优先读取此处 |
| `host/dist/` | — | TypeScript host 打包产物（CJS + ESM）|
| `host/wasm/rootfs.vfs` | 16 MB | 根文件系统 VFS 镜像（zstd 压缩）|
| `tools/bin/wasm-fork-instrument` | 1.9 MB | fork 重写工具（宿主原生二进制）|
| `sysroot/lib/libc.a` | 1.4 MB | musl wasm32 静态库 |
| `out/wasm32/` | — | 用户程序 .wasm（hello, fork test 等）|

---

## 完整一键环境脚本

将以下内容保存为 `setup-env.sh`，每次打开终端 `source` 即可：

```bash
#!/bin/bash
REPO="/home/exedev/kandelo"
TOOLS="/home/exedev"

export PATH="\
$REPO/sdk/bin:\
$TOOLS/.cargo/bin:\
$TOOLS/llvm-21/bin:\
$TOOLS/node-v24.16.0-linux-x64/bin:\
$TOOLS/wabt/bin:\
$TOOLS/binaryen/bin:\
$PATH"

export LLVM_BIN="$TOOLS/llvm-21/bin"
export LLVM_PREFIX="$TOOLS/llvm-21"
export LLVM_VERSION=21
```

---

---

## Browser Demo 启动

### 一键启动（推荐）

```bash
bash scripts/dev-shell.sh bash run.sh browser
```

`run.sh browser` 自动完成：npm install → fetch-binaries → prepare-browser → npx vite --port 5198。

### 工作流分析（`.github/workflows/browser-demos-pages.yml`）

CI 的 `prepare-browser` 步骤等价于：
1. `scripts/fetch-binaries.sh --allow-stale` — 从 GitHub Releases `binaries-abi-v<N>` 拉取所有预构建 wasm 包
2. `run.sh prepare-browser` — 对未能从 index 获取的包调用本地源码构建（VFS 镜像等）
3. `apps/browser-demos && npm run build` / `npx vite` — 打包或启动 dev server

### 分步本地启动步骤

#### 前提：安装 Nix 后一步到位

```bash
# 全部通过 dev-shell.sh 执行，无需手动设置 PATH
cd /home/exedev/kandelo
```

#### Step 1：安装 browser-demos npm 依赖

```bash
bash scripts/dev-shell.sh npm install
```

#### Step 2：拉取预构建 wasm 二进制

`binaries-abi-v13` release 提供了 65 个包（bash, nginx, php, mariadb, wordpress, vim, git 等）。
cpython, erlang, perl, ruby, redis, texlive 目前**不在**该 index 中，需跳过（否则会触发数小时的源码构建）：

```bash
WASM_POSIX_FETCH_SKIP_PKGS="cpython erlang erlang-vfs perl perl-vfs python-vfs redis ruby texlive node-compat npm pcre2-source sqlite-cli" \
  bash scripts/dev-shell.sh bash scripts/fetch-binaries.sh --allow-stale
```

输出：`fetch-binaries: resolved=65 total=65 skipped=12`（65/65 全部成功）

#### Step 3：构建 browser demo 资产（VFS 镜像等）

```bash
WASM_POSIX_FETCH_SKIP_PKGS="cpython erlang erlang-vfs perl perl-vfs python-vfs redis ruby texlive node-compat npm pcre2-source sqlite-cli" \
  bash scripts/dev-shell.sh bash run.sh prepare-browser --allow-stale
```

输出：所有 `[OK]`，无失败。

此步骤构建 nginx-vfs、nginx-php-vfs、mariadb-vfs、wordpress-vfs、lamp-vfs 等 VFS 镜像，
并将 wasm 文件放到 `apps/browser-demos/public/`。

#### Step 4：启动 Vite dev server

```bash
bash scripts/dev-shell.sh npx vite --host 0.0.0.0 --port 5173
```

浏览器访问：**http://<server-ip>:5173/**

---

### 无 Nix 原生工具链方式（归档）

```bash
export PATH="/home/exedev/kandelo/sdk/bin:/home/exedev/.cargo/bin:/home/exedev/llvm-21/bin:\
/home/exedev/node-v24.16.0-linux-x64/bin:/home/exedev/wabt/bin:/home/exedev/binaryen/bin:$PATH"
export LLVM_BIN="/home/exedev/llvm-21/bin"

WASM_POSIX_FETCH_SKIP_PKGS="cpython erlang erlang-vfs perl perl-vfs python-vfs redis ruby texlive node-compat npm pcre2-source sqlite-cli" \
  bash scripts/fetch-binaries.sh --allow-stale

WASM_POSIX_FETCH_SKIP_PKGS="..." \
  bash run.sh prepare-browser --allow-stale

cd apps/browser-demos
npx vite --host 0.0.0.0 --port 5173
```

### 验证结果

```
VITE v6.4.1  ready in 148 ms
  ➜  Local:   http://localhost:5173/
  ➜  Network: http://10.42.0.42:5173/
```

HTTP 200 响应确认。Demo 支持的功能（来自 `BROWSER_DEPS`）：
- **shell** — dash + bash + coreutils + grep + sed
- **nginx** — 静态文件服务 + FastCGI
- **php / php-fpm** — PHP 8.4
- **mariadb** (wasm32 + wasm64) — SQL 数据库
- **wordpress** — 完整 CMS (nginx + php-fpm + SQLite 或 MariaDB)
- **vim** — 终端编辑器（含 runtime zip）
- **git** — 版本控制
- **nethack** — 经典 roguelike
- **fbdoom** — DOOM via /dev/fb0
- **nano** — 文本编辑器
- **spidermonkey-node** — JS 运行时
- **bc, less, m4, make, tar, curl, wget, gzip, bzip2, xz, zstd** 等

跳过的 demo（需单独长时间源码构建）：cpython, erlang, perl, ruby, redis, texlive

### 所需 HTTP Headers（SharedArrayBuffer）

`vite.config.ts` 已自动注入：
```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

---

## Browser Demo 问题修复记录

启动后通过外部 IP 访问时遇到多个问题。

### 问题一：gallery.json 缺失 + CORS

**现象**：`Failed to fetch gallery.json: CORS blocked`。  
**根因**：`gallery.json` 来自第三方 repo `brandonpayton/kandelo-software`，**不在**当前 repo 的 release 中。

**修复**：
1. 清空 `DEFAULT_SOFTWARE_MANIFEST_URLS`（`live-setup.ts:72`），不再尝试远程 gallery。  
   所有 gallery 条目改为使用本地内置 demo（`liveGalleryItems()`），它们使用 Vite 的 `@binaries/` 别名正确解析本地 VFS 文件路径。
2. 保留 `fetchTextWithDevProxy` 中 `isDevServer` 的 `import.meta.hot` 检测（对外部 IP 访问 dev server 也启用 `/cors-proxy`），但当前不再需要代理 GitHub。

---

### 问题二：外部 IP 访问时底部导航栏有 redirect 提示但没变化

**修复**：`vite.config.ts` 添加 `allowedHosts: true`。

---

### 问题三：`cache_key_sha mismatch` + 缺少 `zip` → 包回退到旧存档 → kernel 卡 boot

**现象**：
```
[ 0.250000] info kandelo: instantiating kernel...
```
之后 dmesg 不再更新，terminal 显示 Kandelo Linux logo + `status: booting` + `Waiting for the kernel to reach 'running'`。
浏览器 console 无错误日志。

**根因**（双重失败）：
1. `cache_key_sha mismatch`：本地 recipe（`package.toml` / `build.toml`）的 cache key 与已发布存档不符。
   解析器尝试下载存档但 SHA 验证失败 → 标记为 stale → 回退到源码编译。
2. 源码编译因**宿主环境缺少 `zip` 命令**（`build-vim-zip.sh: line 68: zip: command not found`）失败（exit 127）。
   → `shell`、`node-vfs` 两个包标记为 `WARN ... failed to resolve`。
3. 但解析器缓存中**仍有旧存档**（来自之前的 `fetch-binaries`）。`--allow-stale` 容忍了失败。
4. 旧存档与当前代码不兼容 → `kernel.init()` 内部初始化进程（init/WASM 实例化）挂起。

**修复**：
- 安装 `zip`（从 Debian 获取预编译二进制 `zip_3.0-12_amd64`）
- 通过 Nix dev shell 重新构建 shell 和 node-vfs（`cargo xtask build-deps resolve shell --arch wasm32`）
- Nix dev shell 原生提供 `zip`，不会遇到此问题

**经验**：在无 Nix 环境下，`scripts/fetch-binaries.sh --allow-stale` 的 `cache_key_sha mismatch`
警告不可忽略——旧存档可能不兼容。需确保所有回退源码构建的依赖（如 `zip`）都已安装。

---

### 问题四：`index.html` 绝对路径重定向 → GitHub Pages 404

**现象**：
访问 `https://automattic.github.io/kandelo/` 时自动跳转到 `https://automattic.github.io/pages/kandelo/` 导致 404。

**根因**：
`apps/browser-demos/index.html` 第 8 行使用了从 `window.location.origin` 解析的绝对路径：
```js
const target = new URL("/pages/kandelo/", window.location.origin);
```
在 GitHub Pages 上被部署到 `https://automattic.github.io/kandelo/`（`VITE_BASE=/kandelo/`），
正确的目标路径应为 `https://automattic.github.io/kandelo/pages/kandelo/`。
但 `window.location.origin` 给出 `https://automattic.github.io`，
结果 `new URL("/pages/kandelo/", origin)` → `https://automattic.github.io/pages/kandelo/`（缺少 `/kandelo` 前缀）。

**修复**：
将 `window.location.origin` 改为 `window.location.href`，使 `new URL` 使用相对路径解析：
```js
const target = new URL("pages/kandelo/", window.location.href);
```
同时修复同文件第 15 行的 `<a href="...">` 链接。

**效果**：
- Dev 模式（`localhost:5173/`）→ `localhost:5173/pages/kandelo/` ✅
- GitHub Pages（`automattic.github.io/kandelo/`）→ `automattic.github.io/kandelo/pages/kandelo/` ✅

---

### 最终修改文件清单（相对 repo root）

| 文件 | 改动 |
|---|---|
| `apps/browser-demos/pages/kandelo/kernel-host/live-setup.ts` | ① `DEFAULT_SOFTWARE_MANIFEST_URLS = []`；② `isDevHost` → `isDevServer`（2 处）；③ `manifestBase` 修复 base URL 解析 |
| `apps/browser-demos/vite.config.ts` | `allowedHosts: true` |
| `apps/browser-demos/index.html` | `new URL("/pages/kandelo/", origin)` → `new URL("pages/kandelo/", href)`；链接相对路径化 |
| `apps/browser-demos/public/service-worker.js` | **回滚**（最终方案不需要 CORS proxy） |
| `apps/browser-demos/public/gallery.json` | **删除**（不再需要） |
| `apps/browser-demos/public/index.toml` | **删除**（不再需要） |

### 本地可用的内置 Demo

不需要任何远程 gallery manifest，`liveGalleryItems()` 从 Vite 的 `@binaries/` 别名直接解析本地 VFS 文件：

- **Shell** — dash + bash + coreutils + grep + sed + vim + git + nethack
- **Node.js** (SpiderMonkey) — Node.js 兼容运行时
- **nginx** — 静态文件服务
- **nginx + PHP-FPM** — FastCGI
- **WordPress (SQLite)** — nginx + PHP-FPM + SQLite
- **LAMP + WordPress** — nginx + PHP-FPM + MariaDB + WordPress
- **DOOM** — /dev/fb0 帧缓冲上的 DOOM

> 原 gallery 中的 Python、Erlang、Perl、Ruby、Redis 等需源码构建，本地未安装 prebuilt 时自动跳过。

---

## Consumer npm 包方式验证

README 中描述的 `npm install wasm-posix-host wasm-posix-sdk` **当前不可用**。

### 验证结果

| 步骤 | 状态 | 说明 |
|---|---|---|
| `npm install wasm-posix-host` | ❌ 404 | 未发布到 npmjs.org 或 GitHub Packages |
| `npm pack` 本地打包 + 本地安装 | ⚠️ 部分可用 | host 包 OK，SDK 包不可用 |
| SDK `wasm32posix-cc --version` | ❌ 失败 | `node --experimental-strip-types` 不允许对 `node_modules/` 下的 `.ts` 文件做 type stripping |

### 根因

SDK 工具链是 TypeScript 源码（`sdk/src/bin/cc.ts`），通过 `node --experimental-strip-types` 直接执行。这在 `npm link`（symlink）时 work，但在 `node_modules/` 下被 Node.js 明确禁止（`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`）。

### 消费者路径

要让 consumer approach 可用，需要：
1. 将包发布到 npm registry
2. 给 SDK 增加编译步骤（`tsc` / `tsup`），将 `.ts` 编译为 `.js`，`bin` 指向编译产物而非源码

目前可行的唯一路径是本报告记录的**源码编译方式**。

---

## 参考

- `AGENTS.md` — 项目架构与命令速查
- `CLAUDE.md` — 测试要求与构建注意事项
- `flake.nix` — Nix 环境中的完整工具依赖清单（等价的手动安装参照本报告）
- `scripts/build-musl.sh` — musl 构建细节
- `docs/architecture.md` — 三层架构详解
- `.github/workflows/browser-demos-pages.yml` — CI deploy 流程参考
