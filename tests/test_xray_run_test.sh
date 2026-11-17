#!/usr/bin/env bash
# Every golden runtime config passes `xray run -test` on the pinned Go Xray
# (spec 20); a geosite reference without assets fails in the core.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
command -v xray-test >/dev/null || fail 'xray-test missing from the test image'
assets=/usr/local/share/xray-test

for cfg in "$ROOT_DIR"/tests/fixtures/xray/out/*.json; do
	XRAY_LOCATION_ASSET="$assets" xray-test run -test -c "$cfg" >"$tmpdir/log" 2>&1 ||
		fail "$(basename "$cfg"): $(tail -3 "$tmpdir/log")"
done
pass 'golden configs pass run -test'

mkdir "$tmpdir/empty"
cfg="$ROOT_DIR/tests/fixtures/xray/out/fakedns.direct-first.json"
if XRAY_LOCATION_ASSET="$tmpdir/empty" xray-test run -test -c "$cfg" >"$tmpdir/log" 2>&1; then
	fail 'geosite without geosite.dat must fail'
fi
grep -q 'geosite.dat' "$tmpdir/log" || fail "missing geodata error: $(tail -3 "$tmpdir/log")"
pass 'missing geodata fails run -test'
