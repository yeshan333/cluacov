#!/usr/bin/env bash
#
# LSan integration canary.
#
# Compiles a tiny C program with `-fsanitize=address` whose only job is
# to malloc(64) and never free, then runs it and asserts that LSan
# reports the leak. Used by the `mise run asan:54 / asan:55` tasks as a
# positive control: if this canary FAILS, leak detection is silently
# broken and the cluacov suite running clean afterwards proves nothing.
#
# Exits 0 on success, prints the canary's stderr and exits non-zero on
# failure.
#
# Usage:
#   spec/asan_lsan_canary.sh

set -eu

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

src="$work_dir/canary.c"
bin="$work_dir/canary"

cat > "$src" <<'CANARY_C'
/* Allocates 64 bytes and never frees them. The `volatile` prevents the
 * optimizer from eliding the allocation entirely. */
#include <stdlib.h>
int main(void) {
    volatile void *p = malloc(64);
    (void)p;
    return 0;
}
CANARY_C

if ! gcc -fsanitize=address -O0 -g "$src" -o "$bin" 2>"$work_dir/build.log"; then
    echo "asan canary: failed to build canary binary" >&2
    cat "$work_dir/build.log" >&2
    exit 1
fi

# Run with a clean ASAN_OPTIONS so we get the default LSan output. We
# explicitly do NOT inherit LD_PRELOAD: the canary binary already has
# libasan linked in.
canary_out=$(LD_PRELOAD= ASAN_OPTIONS="detect_leaks=1" "$bin" 2>&1 || true)

if echo "$canary_out" | grep -q "LeakSanitizer: detected memory leaks" \
   && echo "$canary_out" | grep -q "Direct leak of 64 byte"; then
    echo "==> LSan canary: OK (LSan detected the 64-byte canary leak)"
    exit 0
fi

echo "==> LSan canary: FAILED — LSan did not report the deliberate leak." >&2
echo "Canary output was:" >&2
echo "$canary_out" >&2
echo >&2
echo "This means leak detection is NOT functional in this environment." >&2
echo "A clean cluacov run afterwards would not actually prove anything." >&2
exit 1
