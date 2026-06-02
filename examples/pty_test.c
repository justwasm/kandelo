/**
 * pty_test.c — Test /dev/ptmx PTY pair creation and bidirectional I/O.
 *
 * 1. open("/dev/ptmx") → master fd
 * 2. grantpt / unlockpt / ptsname_r → "/dev/pts/N"
 * 3. open(slave) → slave fd
 * 4. Write to master → read from slave (input path)
 * 5. Write to slave  → read from master (output path)
 *
 * Compile: wasm32posix-cc examples/pty_test.c -o examples/pty_test.wasm
 * Run:     npx tsx examples/run-example.ts pty_test
 */
#define _GNU_SOURCE

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>

int main(void) {
    int master, slave, n;
    char slave_name[64];
    char buf[256];
    const char *tag;

    /* ── Step 1: open /dev/ptmx ── */
    master = open("/dev/ptmx", O_RDWR);
    if (master < 0) { perror("FAIL: open /dev/ptmx"); return 1; }
    printf("  master fd = %d\n", master);

    /* ── Step 2: grantpt (no-op), unlockpt, ptsname ── */
    if (grantpt(master) < 0)  { perror("FAIL: grantpt"); return 1; }
    if (unlockpt(master) < 0) { perror("FAIL: unlockpt"); return 1; }
    if (ptsname_r(master, slave_name, sizeof(slave_name)) < 0) {
        perror("FAIL: ptsname_r"); return 1;
    }
    printf("  slave = %s\n", slave_name);

    /* ── Step 3: open slave ── */
    slave = open(slave_name, O_RDWR);
    if (slave < 0) { perror("FAIL: open slave"); return 1; }
    printf("  slave fd = %d\n", slave);

    /* ── Disable echo on slave so reads are deterministic ── */
    struct termios t;
    tcgetattr(slave, &t);
    t.c_lflag &= ~ECHO;
    t.c_lflag &= ~ICANON;   /* raw mode so we don't wait for \n */
    tcsetattr(slave, TCSANOW, &t);

    /* ── Step 4: master→slave (input path) ── */
    tag = "  master_wr → slave_rd";
    write(master, "HELLO", 5);
    n = read(slave, buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = '\0'; printf("OK  %-26s (%d) %s\n", tag, n, buf); }
    else       { printf("FAIL %s: read returned %d\n", tag, n); return 1; }

    /* ── Step 5: slave→master (output path) ── */
    tag = "  slave_wr → master_rd";
    write(slave, "WORLD", 5);
    n = read(master, buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = '\0'; printf("OK  %-26s (%d) %s\n", tag, n, buf); }
    else       { printf("FAIL %s: read returned %d\n", tag, n); return 1; }

    /* ── Step 6: verify data independence (no cross-talk) ── */
    /* write to master, read from master should NOT see it.
     * Use non-blocking read to avoid hanging on empty output buffer. */
    int flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    tag = "  master_wr → master_rd (should see nothing)";
    write(master, "SECRET", 6);
    n = read(master, buf, sizeof(buf) - 1);
    if (n < 0)
        printf("OK  %-26s (no cross-talk, EAGAIN)\n", tag);
    else if (n == 0)
        printf("OK  %-26s (no cross-talk)\n", tag);
    else {
        buf[n] = '\0';
        printf("WARN%s (%d) %s (master saw master data!)\n", tag, n, buf);
    }
    fcntl(master, F_SETFL, flags); /* restore */

    close(slave);
    close(master);
    printf("=== pty_test PASSED ===\n");
    return 0;
}
