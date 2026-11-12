#!/usr/bin/env bash
#
# mayhem/build.sh — build OrioleDB's fuzz harness and its regression-test setup.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem, offline. The patched
# PostgreSQL that OrioleDB needs is already installed under /opt/toolchains/deps (Dockerfile), so this
# script only compiles OrioleDB itself, twice:
#   1) with NORMAL flags and IS_DEV=1 (what upstream's own tests use), installed into a private copy
#      of PostgreSQL at mayhem/build-test/pg — what mayhem/test.sh runs pg_regress against;
#   2) with $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link and without IS_DEV (the production
#      code path), archived and linked into the libFuzzer harness and its -standalone reproducer.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

PGSHA="$(sed -n 's/^17:[[:space:]]*//p' .pgtags)"
PGPREFIX="/opt/toolchains/deps/postgres-17-$PGSHA"
[ -x "$PGPREFIX/bin/pg_config" ] || { echo "patched PostgreSQL $PGSHA missing at $PGPREFIX (Dockerfile PG_SHA must match .pgtags)" >&2; exit 1; }

# `make clean` also removes the generated headers; the Makefile regenerates them.
omake() { make USE_PGXS=1 CC="$CC" ORIOLEDB_PATCHSET_VERSION="$PGSHA" -j"$MAYHEM_JOBS" "$@"; }

# 1) test build, normal flags
TESTROOT="$SRC/mayhem/build-test"
rm -rf "$TESTROOT"
mkdir -p "$TESTROOT/pg"
for d in bin lib share include; do cp -a "$PGPREFIX/$d" "$TESTROOT/pg/$d"; done
omake clean PG_CONFIG="$TESTROOT/pg/bin/pg_config" >/dev/null
omake all install IS_DEV=1 PG_CONFIG="$TESTROOT/pg/bin/pg_config" COPT="$COVERAGE_FLAGS"

# 2) sanitized fuzz build: clean the in-tree objects first so nothing from (1) is reused
omake clean PG_CONFIG="$PGPREFIX/bin/pg_config" >/dev/null
omake all PG_CONFIG="$PGPREFIX/bin/pg_config" \
      COPT="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

FUZZROOT="$SRC/mayhem/build-fuzz"
rm -rf "$FUZZROOT"
mkdir -p "$FUZZROOT"
find src -name '*.o' | sort | xargs ar rcs "$FUZZROOT/liborioledb.a"
omake clean PG_CONFIG="$PGPREFIX/bin/pg_config" >/dev/null

PGCFLAGS="-I$SRC/include -I$PGPREFIX/include/server -I$PGPREFIX/include/internal -D_GNU_SOURCE"
PGLIBS="$PGPREFIX/lib/libpgbackend.a $PGPREFIX/lib/libpgcommon_srv.a $PGPREFIX/lib/libpgport_srv.a"
SYSLIBS="-lzstd -lcurl -lssl -lcrypto -licui18n -licuuc -licudata -lz -lm -lpthread -ldl -lrt"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZROOT/lsan_off.o"
$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $PGCFLAGS \
    -c "$SRC/mayhem/fuzz_wal_container.c" -o "$FUZZROOT/fuzz_wal_container.o"

# 3) harness: fuzzer binary and run-once standalone reproducer
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$FUZZROOT/fuzz_wal_container.o" "$FUZZROOT/lsan_off.o" \
    "$FUZZROOT/liborioledb.a" $PGLIBS $SYSLIBS -o "$SRC/fuzz_wal_container"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" "$FUZZROOT/fuzz_wal_container.o" "$FUZZROOT/lsan_off.o" \
    "$FUZZROOT/liborioledb.a" $PGLIBS $SYSLIBS -o "$SRC/fuzz_wal_container-standalone"
