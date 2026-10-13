#!/bin/sh
# The whole verification matrix in one place, so CI and a local run cannot
# drift apart.  Exits non-zero if any step fails, but keeps going after the
# first failure: a broken cross-target should not hide a broken test.
#
#   ./scripts/ci.sh            # uses `zig` from PATH
#   ZIG=~/local/zig/zig ./scripts/ci.sh

set -eu

zig="${ZIG:-zig}"
failed=""

step() {
    name=$1
    shift
    printf '=== %s\n' "$name"
    if "$zig" "$@" >/tmp/zflac-ci.log 2>&1; then
        printf '    ok\n'
    else
        printf '    FAILED: zig %s\n' "$*"
        sed 's/^/    /' /tmp/zflac-ci.log | tail -25
        failed="$failed\n $name"
    fi
}

# Same reporting, but for a command that is not `zig`.
check() {
    name=$1
    shift
    printf '=== %s\n' "$name"
    if "$@" >/tmp/zflac-ci.log 2>&1; then
        printf '    ok\n'
    else
        printf '    FAILED: %s\n' "$*"
        sed 's/^/    /' /tmp/zflac-ci.log | tail -25
        failed="$failed\n $name"
    fi
}

# Targets that only have to compile; the bindings are exercised on the host.
cross_only="
x86_64-linux-gnu
aarch64-linux-gnu
aarch64-linux-musl
arm-linux-musleabi
riscv64-linux-musl
x86_64-windows-gnu
x86_64-macos-none
"

# Same architecture, statically linked musl: the test binary runs on a glibc
# host, so these get real tests rather than a compile check.  Other cross
# targets would need an emulator configured with -fqemu.
cross_test="
x86_64-linux-musl
"

step "format" fmt --check src tests examples build.zig
step "build" build

# Default Debug run writes libFLAC's debug output to stderr, which makes Zig's
# runner print a `failed command:` block even though the step exits 0
# (ziglang/zig#35202).  The quiet leg below is the one to read in CI logs.
step "test (debug)" build test
step "test (quiet libFLAC)" build -Dtest-flac-assertions=false test
step "test (no alloc hooks)" build -Dflac-alloc-hooks=false test
step "test (libFLAC asserts off)" build -Dflac-assertions=false test
step "test (no fseeko)" build -Dflac-fseeko=false test
step "test (ReleaseSafe)" build -Doptimize=safe test
step "test (ReleaseFast)" build -Doptimize=fast test

step "example" build example
step "quickstart" build quickstart
step "memstats" build memstats

# The converter, end to end: take the FLAC the example just wrote, decode it to
# a WAV, encode that back to FLAC, decode that again, and require the two WAVs
# to be byte-identical.  That covers both directions, all three callback
# interfaces, and the WAV header patch-up.
check "converter round trip" sh -c '
    ./zig-out/bin/convert roundtrip.flac /tmp/zflac-a.wav &&
    ./zig-out/bin/convert /tmp/zflac-a.wav /tmp/zflac-b.flac &&
    ./zig-out/bin/convert /tmp/zflac-b.flac /tmp/zflac-c.wav &&
    cmp /tmp/zflac-a.wav /tmp/zflac-c.wav
'
rm -f roundtrip.flac /tmp/zflac-a.wav /tmp/zflac-b.flac /tmp/zflac-c.wav

for t in $cross_only; do
    # A separate prefix: installing a cross build into ./zig-out would leave a
    # foreign binary where the host one was, and the next local run of
    # zig-out/bin/convert would fail with a shell syntax error.
    step "build $t" build -Dtarget=$t -Doptimize=small --prefix /tmp/zflac-ci-cross
    rm -rf /tmp/zflac-ci-cross
done

for t in $cross_test; do
    step "test $t" build -Dtarget=$t -Doptimize=small test
done

step "test musl (no fseeko)" build -Dtarget=x86_64-linux-musl -Dflac-fseeko=false test

if [ -n "$failed" ]; then
    printf '\n=== failed steps:%b\n' "$failed"
    exit 1
fi
printf '\n=== all steps passed\n'
