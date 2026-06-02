# Porting tmux 3.5 to Kandelo (wasm32-posix-kernel)

## 概述

将 tmux 3.5 移植到 Kandelo wasm32 平台。tmux 是一个终端复用器，依赖 ncurses 和 libevent。

```
依赖链: tmux → libevent → (无)
                → ncurses → (无)
```

### 项目背景

Kandelo 是一个 POSIX 兼容的 WebAssembly 多进程内核。C 程序编译为 wasm32 后，
在浏览器或 Node.js 中运行，通过 channel 机制与内核通信实现系统调用。

tmux 是第一个被移植的 TUI 程序，涉及：
- 静态链接 ncurses 以支持 terminfo 终端能力查询
- fork-instrument 实现多进程（client-server 架构）
- 通过 PTY（伪终端）实现终端 I/O

---

## 构建步骤

### 构建前准备

必须使用 Nix dev shell，不能直接用宿主系统工具链：

```bash
bash scripts/dev-shell.sh bash   # 进入 dev shell
```

在 dev shell 中，`wasm32posix-cc`、`wasm32posix-ar` 等交叉编译工具链已配置在 PATH 上。

### ncurses 为什么需要先构建

tmux 使用 ncurses 的 terminfo 功能来查询终端能力（如支持多少颜色、哪些转义序列等）。
关键函数有：

| 函数 | 作用 |
|------|------|
| `setupterm(term, fd, errret)` | 初始化终端，加载终端能力数据库 |
| `tigetstr(cap)` | 获取字符串型终端能力（如清屏序列） |
| `tigetnum(cap)` | 获取数值型终端能力（如列数） |
| `tigetflag(cap)` | 获取布尔型终端能力（如是否支持彩色） |

**ncurses 在 Kandelo 中的特殊配置**：
- `--disable-database`：禁用运行时 terminfo 文件查找（wasm 没有文件系统访问）
- `--with-fallbacks=xterm-256color,xterm,vt100,dumb`：将终端能力数据编译到 `libtinfow.a` 内部
- `--enable-widec`：宽字符支持（UTF-8）

tmux 的所有 terminfo 函数都通过 `libtinfow.a` 解析——`libncursesw.a` 对外暴露
这些函数符号但实际定义在 `libtinfow.a` 中。如果链接时只加 `-lncursesw` 不加
`-ltinfow`，链接器会把这些函数留为未解析的 `env.*` 导入，运行时抛出
`Unimplemented import: env.setupterm` 错误。

#### 构建 ncurses

```bash
# 方式一：直接运行构建脚本
bash scripts/dev-shell.sh bash packages/registry/ncurses/build-ncurses.sh

# 方式二：通过 dep resolver（会自动缓存到 ~/.cache/kandelo/）
cargo run -p xtask --target x86_64-unknown-linux-gnu -- \
    build-deps resolve ncurses --arch wasm32
```

构建产物：
- `libncursesw.a` (228 KB) — curses 函数（move、addstr 等）
- `libtinfow.a` (264 KB) — terminfo 函数（setupterm、tigetstr 等）+ 编译的 fallback 终端数据

安装位置：
- 直接运行：`packages/registry/ncurses/ncurses-install/`
- 通过 resolver：`~/.cache/kandelo/libs/ncurses-6.5-rev1-wasm32-*/`

### libevent 构建

tmux 使用 libevent 作为事件循环库（替代传统的 select/poll 循环）。

```bash
cargo run -p xtask --target x86_64-unknown-linux-gnu -- \
    build-deps resolve libevent --arch wasm32
```

libevent 的 configure 在交叉编译时会产生假阳性检测，已在构建脚本中通过
`export ac_cv_*=no` 解决：

| 假阳性 | 原因 | 修复 |
|--------|------|------|
| `mach_absolute_time` | macOS 特有函数 | `ac_cv_func_mach_absolute_time=no` |
| `port_create` | Solaris 特有 | `ac_cv_func_port_create=no` |
| `kqueue` | BSD 特有 | `ac_cv_func_kqueue=no` |

### tmux 构建

```bash
# 直接运行构建脚本（会自动 resolve ncurses 和 libevent）
bash scripts/dev-shell.sh bash packages/registry/tmux/build-tmux.sh

# 部署到 local-binaries（供浏览器 demo 使用）
cp packages/registry/tmux/tmux-install/tmux.wasm local-binaries/programs/wasm32/tmux.wasm
```

#### 为什么需要 -ltinfow

构建脚本中两个地方需要 `-ltinfow`：

1. **configure LIBS**（行 60）— 用于链接测试，让 configure 正确检测 terminfo 函数
2. **make LIBS**（行 127）— 实际链接时拉入 `libtinfow.a`

如果不加，`wasm-objdump -x` 会看到：
```
 - func[1] sig=12 <env.setupterm> <- env.setupterm
 - func[2] sig=4 <env.tigetnum> <- env.tigetnum
 - func[3] sig=4 <env.tigetflag> <- env.tigetflag
 - func[4] sig=4 <env.tigetstr> <- env.tigetstr
```

加上后这些变为已解析符号（在 libtinfow.a 中标记为 `T`）。

#### configure 假阳性修复

tmux 的 configure 检测了很多 BSD/Linux 特有函数。在交叉编译模式下，
这些检测只编译不运行，所以会误判为可用。所有假阳性都已用 `ac_cv_*=no` 禁用：

| tmux configure 检测 | 误判原因 | 修复 |
|---|---|---|
| `HAVE_FDFORKPTY` | 需要 `-lutil` | `ac_cv_search_fdforkpty=no` |
| `HAVE_IMSG` | BSD imsg | `ac_cv_search_imsg_init=no` |
| `HAVE_CLOSEFROM` | BSD closefrom | `ac_cv_func_closefrom=no` |
| `HAVE_GETPEEREID` | BSD getpeereid | `ac_cv_func_getpeereid=no` |
| `HAVE_GETPROGNAME` | BSD getprogname | `ac_cv_func_getprogname=no` |
| `HAVE_VIS` | BSD vis | `ac_cv_func_vis/stavis/strvis/strnvis=no` |
| `HAVE_FREEZERO` | BSD freezero | `ac_cv_func_freezero=no` |
| `HAVE_NTOHLL` | BSD byte swap | `ac_cv_func_ntohll/htonll=no` |
| `HAVE_EXPLICIT_BZERO` | BSD explicit_bzero | `ac_cv_func_explicit_bzero=no` |
| `HAVE_FGETLN` | BSD fgetln | `ac_cv_func_fgetln=no` |
| `HAVE_KINFO_GETFILE` | BSD kinfo | `ac_cv_func_kinfo_getfile=no` |
| `HAVE_SETPROCTITLE` | BSD setproctitle | `ac_cv_func_setproctitle=no` |
| `HAVE_GETPEERUCRED` | Solaris | `ac_cv_func_getpeerucred=no` |
| `HAVE_PROC_PIDINFO` | macOS proc_info | `ac_cv_func_proc_pidinfo=no` |
| `HAVE_SYS_SIGNAME` | BSD sys_signame | `ac_cv_search_sys_signame=no` |
| `HAVE_LIBXNET` | Solaris xnet | `ac_cv_lib_xnet_socket=no` |

#### musl 缺失函数补丁

有些函数 musl libc 完全没有，tmux 的 compat 目录也没有提供实现，需要手动 stub：

**`getdtablecount()`** — OpenBSD 函数，返回当前进程打开的文件描述符数。
tmux 的 `compat/imsg.c` 中使用了它。musl 没有，tmux 也没有提供 compat 实现。

```c
int getdtablecount(void) { return 64; }
```

通过 `libstubs.a` 在链接时注入：
```bash
wasm32posix-cc -c -x c - -o "$BUILD_DIR/stubs.o" -DNDEBUG -O2 <<'EOF'
int getdtablecount(void) { return 64; }
EOF
wasm32posix-ar cr "$BUILD_DIR/libstubs.a" "$BUILD_DIR/stubs.o"
```

`LIBS` 中添加 `-lstubs`。

**`ntohll` / `htonll`** — tmux 的 compat 目录已通过 `AC_LIBOBJ` 自动加入构建，无需手动提供。

#### fork 插桩

tmux 使用 `fork()` 创建 server 子进程。wasm 二进制需要经过 fork-instrument 处理，
添加保存/恢复 wasm 状态的代码（`wpk_fork_unwind_*` / `wpk_fork_rewind_*`）。

构建脚本已自动调用：
```bash
bash scripts/run-wasm-fork-instrument.sh tmux.wasm -o tmux.wasm
```

插桩后的二进制会导出 `wpk_fork_unwind_begin`、`wpk_fork_rewind_begin` 等 5 个符号。

---

## 启动 Dev Server

```bash
# 在项目根目录
cd apps/browser-demos

# 启动 Vite 开发服务器（需在 dev shell 中）
npx vite --host
```

Vite 启动后：
- `http://localhost:5173/pty-test.html` — 原始 PTY 测试页（带 bash shell）
- `http://localhost:5173/tmux-test.html` — 精简 tmux 测试页（最小 VFS）

注意：tmux-test.html 是独立 HTML，不会 HMR 热更新，修改后需 **Ctrl+Shift+R 硬刷新**。

---

## 当前状态

### 已解决

#### 1. ncurses 缺失

**现象**：加载 tmux.wasm 时报错 `Unimplemented import: env.setupterm`。

**根因**：ncurses 是整个构建链中缺失的一环。tmux 依赖 ncurses 的 terminfo 函数，
但 ncurses 从未为 wasm32 构建过。configure 的编译测试通过了（交叉编译下只编译
不链接），所以 tmux 认为自己有 ncurses 可用，但链接时 `libncursesw.a` 不存在，
所有 ncurses 函数都变为未解析的 `env.*` 导入。

**修复**：构建 ncurses（`bash scripts/dev-shell.sh bash packages/registry/ncurses/build-ncurses.sh`）。

#### 2. 缺少 -ltinfow

**现象**：即使 ncurses 已构建，`setupterm` 等函数仍然是 `env.*` 导入。

**根因**：ncurses 的架构中，terminfo 函数定义在 `libtinfow.a`（term library），
而不是 `libncursesw.a`（curses library）。`libncursesw.a` 中这些符号是 `U`
（undefined），依赖链接器从 `libtinfow.a` 中解析。tmux 的 `LIBS` 只传了
`-lncursesw`，没有 `-ltinfow`，所以链接器没有拉入这些函数。

**修复**：在 `build-tmux.sh` 的 configure LIBS 和 make LIBS 中都加上 `-ltinfow`。

```
-LIBS="-lncursesw -levent -levent_core -levent_extra"
+LIBS="-lncursesw -ltinfow -levent -levent_core -levent_extra"
```

验证方法：
```bash
wasm-objdump -x tmux.wasm | grep " env\.setupterm" && echo "still broken" || echo "fixed"
```

#### 3. Fork 返回 EEXIST

**现象**：tmux 调用 `fork()` 时抛出 `Fork failed: errno=17`（EEXIST）。

**根因**：`handleFork` 在分配 child PID 时，只检查了 JS 端的 `this.processes` Map，
没有检查 kernel 端的 process table。当一个 top-level 进程（通过 `kernel.spawn()` 创建）
退出时，`deactivateProcess()` 从 JS Map 中删除它，但 kernel 端的 process table
中的 zombie 条目不会被清除。下一个 fork 尝试重用这个 PID 时，kernel 报告 EEXIST。

具体场景：
1. `tmux -V` (pid=100) 启动 → 加入 JS Map 和 kernel table
2. `tmux -V` 退出 → `deactivateProcess(100)` 从 JS Map 删除
3. kernel table 中 pid 100 仍是 zombie（未 reap）
4. 真正的 tmux (pid=101) 调用 fork()
5. `handleFork` 检查 JS Map → pid 100 可用 → 使用 pid 100
6. `kernel_fork_process(101, 100)` → kernel 报告 EEXIST（pid 100 仍存在）

**修复**：在 `host/src/kernel-worker.ts` 的 `handleFork` 中增加 EEXIST 重试循环：

```typescript
for (let attempt = 0; attempt < 10_000; attempt++) {
  // 跳过 JS Map 中已注册的 PID
  while (this.processes.has(this.nextChildPid)) { this.nextChildPid++; }
  const candidatePid = this.nextChildPid++;
  const forkResult = kernelForkProcess(parentPid, candidatePid);
  if (forkResult >= 0) { childPid = candidatePid; break; }
  if (forkResult !== -17) { /* 真正的错误 */ return; }
  // EEXIST：kernel 还有 zombie，继续试下一个 PID
}
```

### 未解决

`tmux new-session -d -s test` 调用后超时（8s 无响应）。

#### 已排除的可能性

| 原因 | 排查结果 |
|------|----------|
| `env.*` 未实现导入 | ✅ 二进制已无残留 env 函数导入 |
| ncurses `setupterm` 失败 | ✅ 已正确链接，`-V` 正常输出 |
| `setsid` 未实现 | ✅ 已实现（`SYS_SETSID=92`） |
| `poll`/`ppoll` 未实现 | ✅ 已实现（libevent 可用） |
| Unix domain socket | ✅ `AF_UNIX` socket/bind/listen/connect 全链路已实现 |
| fork 挂起 | ✅ EEXIST 已修复，fork 不再报错 |
| `execve` 不支持 | ✅ channel 路径已验证（`exec.test.ts`） |
| VFS 缺少 shell | ✅ bash 已写入 `/bin/bash` 并创建了 symlinks |

#### 当前观察

- `tmux -V` ✅ 正常："tmux 3.5"
- `tmux list-sessions` ✅ 正常："no server running on /tmp/tmux-1000/default"（退出码 1）
- `tmux list-keys` ❌ 超时（需要 fork 启动 server）
- `tmux -D` ❌ 无输出（前台 server，理论上应保持运行，不退出）
- `tmux new-session -d -s test` ❌ 超时（需要 fork 启动 server → 创建 session → 退出）

`list-keys` 和 `new-session -d` 的共性是都需要 fork 来启动 server 进程。

#### 假设

1. **fork child crash**：fork-instrument 的 rewind 恢复后，child 进程立即 crash。
   由于 child 在独立 worker 中，crash 不会被 parent 直接感知——parent 在等 socket
   出现，永远不会等到。

2. **libevent event loop 未启动**：child 中 libevent 的 `event_base_dispatch()`
   可能未能正确初始化（例如没有 fd 注册到 event base）。

3. **Unix socket 路径问题**：child 创建 socket 时需要创建 `/tmp/tmux-1000/` 目录。
   如果 `mkdir()` 或 `bind()` 静默失败，socket 文件不存在，parent 永远连不上。

4. **fork child 的 channel 通信中断**：fork 后 child 的 channel 偏移量或
   memory buffer 不正确，导致 syscall 无法正常返回。

#### 验证方法

**A. 分两步启动**：
```
Step 1: kernel.spawn(tmuxBytes, ["tmux", "-D"], ...)   # 前台 server
Step 2: kernel.spawn(tmuxBytes, ["tmux", "list-sessions"], ...)  # 连接 server
```
如果 Step 1 server 能启动（`tmux -D` 不需 fork），Step 2 应能正常连接并输出。
如果 Step 2 也超时，说明问题不在 fork，而在 server 初始化或 socket 通信本身。

**B. worker-main.ts 加日志**：在 fork rewind 路径（行 1020-1033）添加 `console.error`，
确认 child 是否成功执行到 `sendForkSyscall` 之后的恢复点。

**C. 最小 fork 测试**：写一个只调用 `fork()` + `exit()` 的 C 程序，编译为 wasm，
通过 `kernel.spawn()` 运行。如果也卡住，说明 fork-instrument 本身有问题。

**D. 检查 kernel 日志**：在 `browser-kernel-worker-entry.ts` 的
`installProcessWorkerListeners` 回调中添加日志，捕获 child worker 的任何
初始化失败或 wasm trap。

---

## 测试页说明

### pty-test.html

原有 bash PTY 测试页。流程：
1. 加载 shell VFS image（含 `/tmp`、`/home/user`、bash 等）
2. 下载 tmux.wasm 并写入 VFS 的 `/usr/bin/tmux`
3. 写入 `.tmux.conf` 配置文件
4. 通过 `kernel.spawn()` 启动 bash（带 PTY）
5. 用户可在 bash 中输入 `tmux` 命令

bash 进程通过 PTY 交互，键盘输入 → xterm.js → `kernel.ptyWrite()` → PTY master →
kernel line discipline → PTY slave → bash stdin。输出路径相反。

### tmux-test.html

精简版测试页（加载更快）。不使用 shell VFS image，而是：
1. 用 `MemoryFileSystem.create()` 创建空白 VFS
2. 手动创建 `/tmp`、`/home`、`/usr/bin`、`/bin` 目录
3. 下载 tmux.wasm 和 bash.wasm 并写入 VFS
4. 通过 `kernel.spawn()` 依次运行 tmux 各子命令

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `packages/registry/libevent/package.toml` | libevent 配方 |
| `packages/registry/libevent/build-libevent.sh` | libevent 构建脚本 |
| `packages/registry/ncurses/package.toml` | ncurses 配方 |
| `packages/registry/ncurses/build-ncurses.sh` | ncurses 构建脚本（交叉编译 + fallback 终端） |
| `packages/registry/tmux/package.toml` | tmux 配方 |
| `packages/registry/tmux/build-tmux.sh` | tmux 构建脚本 |
| `local-binaries/programs/wasm32/tmux.wasm` | 构建产物（2.3 MB，fork-instrumented） |
| `apps/browser-demos/pty-test.html` | PTY 交互测试页（bash + tmux） |
| `apps/browser-demos/tmux-test.html` | tmux 精简测试页 |
| `host/src/kernel-worker.ts` | `handleFork` EEXIST 重试修复（行 5462-5492） |
| `docs/tmux-porting.md` | 本文档 |

## 调试技巧

### 检查 wasm 导入

```bash
# 列出所有 env 导入
wasm-objdump -x tmux.wasm | grep " env\." | sed 's/.*<env\.\(.*\)>.*/\1/' | sort -u

# 正常情况应该只有 __channel_base(global) 和 memory
# 如果有函数导入（如 setupterm、tigetstr），说明链接有问题

# 列出所有 kernel 导入
wasm-objdump -x tmux.wasm | grep "kernel\."
```

### 查看 configure 缓存

```bash
# 检查 config.log 中的检测结果
grep "ac_cv_" packages/registry/tmux/tmux-wasm-build/config.log
```

### 查看链接命令

```bash
# 从构建日志中提取最后链接命令
grep "wasm32posix-cc.*-o tmux" packages/registry/tmux/tmux-build.log | head -1 | tr ' ' '\n' | grep -E "^-l|-L"
```

### 查看 libtinfow.a 中的符号

```bash
wasm32posix-nm ~/.cache/kandelo/libs/ncurses-6.5-rev1-wasm32-*/lib/libtinfow.a | grep " T "
# 应看到 T setupterm, T tigetstr, T tigetnum, T tigetflag, T _nc_fallback
```

### 强制完全重建

```bash
rm -rf packages/registry/tmux/{tmux-src,tmux-wasm-build,tmux-install}
rm -rf packages/registry/ncurses/{ncurses-src,ncurses-wasm-build,ncurses-install,ncurses-host-build,terminfo}
bash packages/registry/ncurses/build-ncurses.sh
bash packages/registry/tmux/build-tmux.sh
cp packages/registry/tmux/tmux-install/tmux.wasm local-binaries/programs/wasm32/tmux.wasm
```

### 浏览器控制台调试

打开 F12 Console，过滤 `[kernel-worker]` 可看到进程错误消息。
worker crash、fork 失败、未实现的 syscall 等都会打印到控制台。
