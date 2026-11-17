#!/usr/bin/env bash
# Failed staging/metadata/finalization always reports an actionable error.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
upload="/tmp/xraywrt-geodata-errors.$$"
uploaded="/tmp/xraywrt-geodata.errors$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload" "$uploaded"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh xray-config.sh
setup_runtime_paths "$tmpdir"
RUNTIME_CONFIG="$tmpdir/runtime.json"
MEMINFO_FILE=/proc/meminfo
settings_load() { :; }
service_running() { return 1; }
printf new >"$upload"
ln -s "$tmpdir/outside" "$GEODATA_MANUAL_FILE"
assert_false 'unsafe manual metadata fails' geodata_install_file "$upload" unused.dat >"$tmpdir/result" 2>"$tmpdir/error"
assert_file_contains "$tmpdir/error" '[E:geodata_write]' 'manual metadata error is not silent'
assert_false 'manual metadata failure releases candidate RAM' test -e "$GEODATA_TMP_DIR/assets"
assert_false 'manual metadata failure preserves active state' test -e "$XRAY_SHARE_DIR/unused.dat"
rm "$GEODATA_MANUAL_FILE"
pass 'manual metadata failure reports error and frees staging'

rm -f "$PKG_TMP_DIR/geodata-check.json.live-refs"
mkdir "$PKG_TMP_DIR/geodata-check.json.live-refs"
assert_false 'unwritable reference scratch fails' geodata_install_file "$upload" unused.dat >"$tmpdir/result" 2>"$tmpdir/error"
assert_file_contains "$tmpdir/error" '[E:geodata_write]' 'scratch failure is not silent'
assert_false 'scratch failure releases candidate RAM' test -e "$GEODATA_TMP_DIR/assets"
rmdir "$PKG_TMP_DIR/geodata-check.json.live-refs"
pass 'scratch failure reports error and frees staging'

printf old >"$XRAY_SHARE_DIR/unused.dat"
eval "$(declare -f geodata_journal_stage | sed '1s/geodata_journal_stage/real_journal_stage/')"
geodata_journal_stage() { [ "$1" != committed ] || return 1; real_journal_stage "$@"; }
assert_false 'commit-record failure is not success' geodata_install_file "$upload" unused.dat >"$tmpdir/result" 2>"$tmpdir/error"
assert_file_contains "$tmpdir/error" '[E:geodata_finalize]' 'finalization failure explains the recovery action'
assert_file_contains "$tmpdir/error" 'may restore the previous files' 'finalization failure warns that publication may be undone'
assert_eq published "$(head -n1 "$XRAY_SHARE_DIR/.geodata-transaction")" 'failed commit keeps recovery journal'
assert_eq old "$(cat "$XRAY_SHARE_DIR/unused.dat.old")" 'failed commit keeps distinct old bytes'
assert_eq new "$(cat "$XRAY_SHARE_DIR/unused.dat")" 'error does not pretend publication was rejected'
assert_false 'finalization failure releases candidate RAM' test -e "$GEODATA_TMP_DIR/assets"
geodata_journal_stage() { real_journal_stage "$@"; }
geodata_recover
assert_eq old "$(cat "$XRAY_SHARE_DIR/unused.dat")" 'retry can recover after finalization failure'
pass 'finalization failure warns of recovery and keeps recoverable backups'

# The /tmp upload (RAM) is removed after success and after failure.
printf good >"$uploaded"
geodata_install_file "$uploaded" removed.dat >"$tmpdir/result"
assert_false 'successful install removes the upload' test -e "$uploaded"
printf bad >"$uploaded"
assert_false 'unsafe name fails' geodata_install_file "$uploaded" ../bad.dat
assert_false 'failed install removes the upload' test -e "$uploaded"
printf keep >"$upload"
assert_false 'unsafe name fails for a foreign path' geodata_install_file "$upload" ../bad.dat
assert_true 'files outside /tmp/xraywrt-geodata.* are kept' test -e "$upload"
pass 'geodata upload is removed on every exit path'
