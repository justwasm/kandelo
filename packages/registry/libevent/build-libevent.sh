#!/usr/bin/env bash
#
# Build libevent 2.1.12 for wasm32-posix-kernel.
#
# Honors the dep-resolver build-script contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/libevent-src"

LIBEVENT_VERSION="${WASM_POSIX_DEP_VERSION:-${LIBEVENT_VERSION:-2.1.12}}"
INSTALL_DIR="${WASM_POSIX_DEP_OUT_DIR:-$SCRIPT_DIR/libevent-install}"
SOURCE_URL="${WASM_POSIX_DEP_SOURCE_URL:-https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}-stable/libevent-${LIBEVENT_VERSION}-stable.tar.gz}"
SOURCE_SHA256="${WASM_POSIX_DEP_SOURCE_SHA256:-92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb}"

if ! command -v wasm32posix-cc &>/dev/null; then
    echo "ERROR: wasm32posix-cc not found. Activate SDK first." >&2
    exit 1
fi

# --- Fetch + verify source ---
if [ ! -d "$SRC_DIR" ]; then
    echo "==> Downloading libevent $LIBEVENT_VERSION..."
    TARBALL="/tmp/libevent-${LIBEVENT_VERSION}-stable.tar.gz"
    curl --retry 10 --retry-delay 5 --retry-max-time 300 --retry-all-errors -fsSL "$SOURCE_URL" -o "$TARBALL"
    if [ -n "$SOURCE_SHA256" ]; then
        echo "==> Verifying source sha256..."
        echo "$SOURCE_SHA256  $TARBALL" | shasum -a 256 -c -
    fi
    mkdir -p "$SRC_DIR"
    tar xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1
    rm "$TARBALL"
fi

rm -rf "$INSTALL_DIR"
BUILD_DIR="$SCRIPT_DIR/libevent-wasm-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Configuring libevent for wasm32..."
(
    cd "$BUILD_DIR"

    # Stub runtime probes that autoconf can't cross-compile
    export ac_cv_func_malloc_0_nonnull=yes
    export ac_cv_func_realloc_0_nonnull=yes
    export ac_cv_func_sendfile=yes
    export ac_cv_func_splice=no
    export ac_cv_func_arc4random=no
    export ac_cv_func_arc4random_buf=no
    export ac_cv_func_arc4random_addrandom=no
    export ac_cv_func_pipe2=yes
    export ac_cv_func_accept4=yes
    export ac_cv_func_strtok_r=yes
    export ac_cv_func_strlcpy=yes
    export ac_cv_func_strlcat=yes
    export ac_cv_func_clock_gettime=yes
    export ac_cv_func_pthreads=yes
    export ac_cv_func_umask=yes
    export ac_cv_func_mach_absolute_time=no
    export ac_cv_func_mach_timebase_info=no
    export ac_cv_func_port_create=no
    export ac_cv_header_port_h=no
    export ac_cv_func_kqueue=no
    export ac_cv_header_sys_event_h=no
    export ac_cv_func_devpoll=no

    # Disable OpenSSL (not available in wasm)
    export ac_cv_header_openssl_ssl_h=no
    export ac_cv_header_openssl_evp_h=no
    export ac_cv_lib_ssl_SSL_new=no
    export ac_cv_lib_crypto_OPENSSL_init_crypto=no

    CC=wasm32posix-cc \
    CXX=wasm32posix-c++ \
    AR=wasm32posix-ar \
    RANLIB=wasm32posix-ranlib \
    NM=wasm32posix-nm \
    CFLAGS="-O2 -DNDEBUG -D_event_set_levyx=event_set_levyx" \
    LDFLAGS="" \
    "$SRC_DIR/configure" \
        --host=wasm32-unknown-none \
        --prefix="$INSTALL_DIR" \
        --disable-shared \
        --enable-static \
        --disable-openssl \
        --disable-samples \
        --disable-libevent-regress \
        --disable-tests \
        --disable-clock-gettime \
        --with-pic \
        2>&1 | tail -20
)

echo "==> Building libevent..."
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" -C "$BUILD_DIR" 2>&1 | tail -10

echo "==> Installing to $INSTALL_DIR..."
make -C "$BUILD_DIR" install 2>&1 | tail -10

if [ -f "$INSTALL_DIR/lib/libevent.a" ]; then
    echo "==> libevent build complete!"
    ls -lh "$INSTALL_DIR/lib/"libevent*.a
else
    echo "ERROR: libevent.a not found" >&2
    exit 1
fi
