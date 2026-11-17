#!/usr/bin/env bash
# testlib xray_test_bin: real-core path, explicit skip or required failure.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

printf '#!/bin/sh\necho Xray\n' >"$tmpdir/xray"
chmod 755 "$tmpdir/xray"
XRAY_TEST_BIN="$tmpdir/xray" xray_test_bin 'probe' >"$tmpdir/out" || fail 'present binary must not skip'
assert_eq '' "$(cat "$tmpdir/out")" 'present binary prints nothing'
(XRAY_TEST_BIN="$tmpdir/xray" && xray_test_bin probe && [ "$XRAY_TEST_BIN" = "$tmpdir/xray" ]) || fail 'XRAY_TEST_BIN kept'

if XRAY_TEST_BIN="$tmpdir/missing" XRAY_TEST_REQUIRED='' xray_test_bin 'real core suite' >"$tmpdir/out"; then
	fail 'missing binary must skip'
fi
assert_eq "skip - real core suite (xray test binary $tmpdir/missing missing; set XRAY_TEST_REQUIRED=1 to fail)" "$(cat "$tmpdir/out")" 'explicit skip message'

if (XRAY_TEST_BIN="$tmpdir/missing" XRAY_TEST_REQUIRED=1 xray_test_bin 'real core suite') 2>"$tmpdir/err"; then
	fail 'missing binary with XRAY_TEST_REQUIRED=1 must fail'
fi
assert_file_contains "$tmpdir/err" "FAIL: real core suite: xray test binary $tmpdir/missing missing" 'required failure message'
assert_eq /usr/local/share/xray-test "$XRAY_TEST_ASSETS" 'default geodata dir'
pass 'xray_test_bin'
