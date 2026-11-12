#!/usr/bin/env bash
#
# mayhem/test.sh — RUN OrioleDB's own pg_regress suite (the REGRESSCHECKS list in the Makefile)
# against the extension that mayhem/build.sh installed into mayhem/build-test/pg, normal flags.
# Each test's SQL output is diffed by pg_regress against test/expected, so the oracle asserts real
# query results; a neutered postgres/initdb/pg_regress prints no "ok N - name" lines and fails.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PG="$SRC/mayhem/build-test/pg"
if ! { [ -x "$PG/bin/postgres" ] && [ -f "$PG/lib/orioledb.so" ]; }; then
  echo "mayhem/build.sh did not build the test setup" >&2
  emit_ctrf "pg_regress" 0 1 0
  exit 1
fi

# the same test list upstream's `make regresscheck` runs
TESTS="$(sed -n '/^REGRESSCHECKS[[:space:]]*=/,/[^\\]$/p' Makefile | sed 's/^REGRESSCHECKS[[:space:]]*=//' | tr -d '\\' | tr -s '[:space:]' ' ')"
EXPECTED=$(echo $TESTS | wc -w)
if [ "$EXPECTED" -lt 40 ]; then
  echo "could not read REGRESSCHECKS from Makefile (got $EXPECTED)" >&2
  emit_ctrf "pg_regress" 0 1 0
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out"

timeout 1500 "$PG/lib/pgxs/src/test/regress/pg_regress" --no-locale \
  --inputdir=test --outputdir="$WORK/out" --bindir="$PG/bin" \
  --temp-instance="$WORK/tmp_check" --temp-config=test/orioledb_regression.conf \
  $TESTS 2>&1 | tee "$WORK/regress.log"

PASSED=$(grep -c -E '^ok [0-9]+ +- ' "$WORK/regress.log" || true)
FAILED=$(grep -c -E '^not ok [0-9]+ +- ' "$WORK/regress.log" || true)
# tests that never reported (crash, hang, neutered binaries) count as failures
MISSING=$(( EXPECTED - PASSED - FAILED ))
[ "$MISSING" -gt 0 ] && FAILED=$(( FAILED + MISSING ))
[ "$FAILED" -gt 0 ] && head -60 "$WORK/out/regression.diffs" 2>/dev/null
emit_ctrf "pg_regress" "$PASSED" "$FAILED" 0
