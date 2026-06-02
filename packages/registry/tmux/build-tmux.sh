#!/usr/bin/env bash
#
# Build tmux 3.5 for wasm32-posix-kernel.
#
# Depends on ncurses and libevent (resolved via cargo xtask build-deps).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SRC_DIR="$SCRIPT_DIR/tmux-src"
HOST_TARGET="$(rustc -vV | awk '/^host/ {print $2}')"

TMUX_VERSION="${WASM_POSIX_DEP_VERSION:-${TMUX_VERSION:-3.5}}"
INSTALL_DIR="${WASM_POSIX_DEP_OUT_DIR:-$SCRIPT_DIR/tmux-install}"
SOURCE_URL="${WASM_POSIX_DEP_SOURCE_URL:-https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz}"
SOURCE_SHA256="${WASM_POSIX_DEP_SOURCE_SHA256:-2fe01942e7e7d93f524a22f2c883822c06bc258a4d61dba4b407353d7081950f}"

if ! command -v wasm32posix-cc &>/dev/null; then
    echo "ERROR: wasm32posix-cc not found. Activate SDK first." >&2
    exit 1
fi

# --- Resolve dependencies via resolver ---
echo "==> Resolving ncurses..."
NCURSES_DIR="$(cd "$REPO_ROOT" && cargo run -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps resolve ncurses --arch wasm32 2>/dev/null)"
if [ -z "$NCURSES_DIR" ] || [ ! -f "$NCURSES_DIR/lib/libncursesw.a" ]; then
    echo "ERROR: ncurses resolution failed" >&2; exit 1
fi
echo "  ncurses: $NCURSES_DIR"

echo "==> Resolving libevent..."
LIBEVENT_DIR="$(cd "$REPO_ROOT" && cargo run -p xtask --target "$HOST_TARGET" --quiet -- \
    build-deps resolve libevent --arch wasm32 2>/dev/null)"
if [ -z "$LIBEVENT_DIR" ] || [ ! -f "$LIBEVENT_DIR/lib/libevent.a" ]; then
    echo "ERROR: libevent resolution failed" >&2; exit 1
fi
echo "  libevent: $LIBEVENT_DIR"

# --- Fetch + verify source ---
if [ ! -d "$SRC_DIR" ]; then
    echo "==> Downloading tmux $TMUX_VERSION..."
    TARBALL="/tmp/tmux-${TMUX_VERSION}.tar.gz"
    curl --retry 10 --retry-delay 5 --retry-max-time 300 --retry-all-errors -fsSL "$SOURCE_URL" -o "$TARBALL"
    if [ -n "$SOURCE_SHA256" ]; then
        echo "==> Verifying source sha256..."
        echo "$SOURCE_SHA256  $TARBALL" | shasum -a 256 -c -
    fi
    mkdir -p "$SRC_DIR"
    tar xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1
    rm "$TARBALL"
fi

BUILD_DIR="$SCRIPT_DIR/tmux-wasm-build"
rm -rf "$BUILD_DIR" "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

CPPFLAGS="-I$NCURSES_DIR/include/ncursesw -I$NCURSES_DIR/include -I$LIBEVENT_DIR/include -I$SRC_DIR/compat"
LDFLAGS="-L$NCURSES_DIR/lib -L$LIBEVENT_DIR/lib"
LIBS="-lncursesw -ltinfow -levent -levent_core -levent_extra"

echo "==> Configuring tmux for wasm32..."

export ac_cv_func_strlcpy=yes
export ac_cv_func_strlcat=yes
export ac_cv_func_forkpty=yes
export ac_cv_func_openpty=yes
export ac_cv_search_fdforkpty=no
export ac_cv_search_imsg_init=no
export ac_cv_func_login_tty=yes
export ac_cv_func_utimensat=yes
export ac_cv_func_closefrom=no
export ac_cv_func_explicit_bzero=no
export ac_cv_func_freezero=no
export ac_cv_func_fgetln=no
export ac_cv_func_kinfo_getfile=no
export ac_cv_func_getpeereid=no
export ac_cv_func_getpeerucred=no
export ac_cv_func_setproctitle=no
export ac_cv_lib_xnet_socket=no
export ac_cv_func_proc_pidinfo=no
export ac_cv_func_proc_pidfdinfo=no
export ac_cv_func_ntohll=no
export ac_cv_func_htonll=no
export ac_cv_func_vis=no
export ac_cv_func_stravis=no
export ac_cv_func_strvis=no
export ac_cv_func_strnvis=no
export ac_cv_header_vis_h=no
export ac_cv_func_getprogname=no
export ac_cv_search_sys_signame=no
export ac_cv_header_utempter_h=no
export ac_cv_func_utempter_add_record=no
export ac_cv_func_utempter_remove_record=no
export ac_cv_func_utempter_set_write_entry=no
export gl_cv_func_getcwd_null=yes

(
    cd "$BUILD_DIR"
    CC=wasm32posix-cc \
    AR=wasm32posix-ar \
    RANLIB=wasm32posix-ranlib \
    NM=wasm32posix-nm \
    CFLAGS="-O2 -DHAVE_FORKPTY -DHAVE_OPENPTY" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="$LDFLAGS" \
    LIBS="$LIBS" \
    "$SRC_DIR/configure" \
        --host=wasm32-unknown-none \
        --prefix="$INSTALL_DIR" \
        --disable-utempter \
        2>&1 | tail -20
)

echo "==> Building tmux..."
# getdtablecount is not in musl — needed by compat/imsg when enabled
wasm32posix-cc -c -x c - -o "$BUILD_DIR/stubs.o" -DNDEBUG -O2 <<'EOF'
int getdtablecount(void) { return 64; }
EOF
wasm32posix-ar cr "$BUILD_DIR/libstubs.a" "$BUILD_DIR/stubs.o"
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    -C "$BUILD_DIR" \
    CFLAGS="-O2 -Wno-implicit-function-declaration" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="-L$BUILD_DIR" \
    LIBS="-lstubs -L$NCURSES_DIR/lib -L$LIBEVENT_DIR/lib -lncursesw -ltinfow -lm -levent -levent_core -levent_extra" \
    2>&1 | tail -10

# Check if the binary was produced
TMUX_BINARY=""
for candidate in "$BUILD_DIR/tmux" "$BUILD_DIR/tmux.wasm"; do
    if [ -f "$candidate" ]; then
        TMUX_BINARY="$candidate"
        break
    fi
done

if [ -z "$TMUX_BINARY" ]; then
    # Maybe it's named tmux but we need to strip it
    if [ -f "$BUILD_DIR/tmux" ]; then
        TMUX_BINARY="$BUILD_DIR/tmux"
    else
        echo "ERROR: tmux binary not found in $BUILD_DIR" >&2
        ls -la "$BUILD_DIR"/tmux* 2>/dev/null || true
        exit 1
    fi
fi

# Rename to .wasm and run fork-instrument
mkdir -p "$INSTALL_DIR"
cp "$TMUX_BINARY" "$INSTALL_DIR/tmux.wasm"
echo "==> tmux binary: $INSTALL_DIR/tmux.wasm"

# Apply fork instrumentation (tmux uses fork for sessions)
if [ -f "$REPO_ROOT/tools/bin/wasm-fork-instrument" ] || command -v wasm-fork-instrument &>/dev/null; then
    echo "==> Running fork instrumentation..."
    bash "$REPO_ROOT/scripts/run-wasm-fork-instrument.sh" "$INSTALL_DIR/tmux.wasm" -o "$INSTALL_DIR/tmux.wasm" 2>&1 | tail -5 || true
    echo "==> Fork instrumentation applied"
fi

ls -lh "$INSTALL_DIR/tmux.wasm"
echo "==> tmux build complete!"
