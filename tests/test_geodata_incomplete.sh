#!/usr/bin/env bash
# Manual recovery can build a missing multi-file set one upload at a time.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
xray_test_bin 'incomplete geodata repair' || exit 0
tmpdir="$(make_temp_dir)"
upload="/tmp/xraywrt-geodata-incomplete.$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh xray-config.sh
setup_runtime_paths "$tmpdir"
RUNTIME_CONFIG="$tmpdir/runtime.json"
XRAY_BIN="$tmpdir/core"
printf '#!/bin/sh\necho test >>"%s"\nexec "%s" "$@"\n' "$tmpdir/core-tests" "$XRAY_TEST_BIN" >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
MEMINFO_FILE=/proc/meminfo
settings_load() { :; }
service_running() { return 0; }
core_restart() { echo restart >>"$tmpdir/restarts"; }
xray_config_generate() { cp "$1" "$2"; cp "$PROFILE_FILE" "$2.profile"; }
cat >"$XRAY_CONFIG" <<'EOF'
{"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"},{"type":"field","ip":["geoip:cn"],"outboundTag":"direct"}]}}
EOF
cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
printf 'geodata-ref geosite.dat\ngeodata-ref geoip.dat\n' >"$PROFILE_FILE"
rm "$XRAY_SHARE_DIR/geosite.dat" "$XRAY_SHARE_DIR/geoip.dat"
cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result"
assert_true 'first upload saved despite other missing file' cmp -s "$upload" "$XRAY_SHARE_DIR/geosite.dat"
assert_file_contains "$tmpdir/result" geodata_incomplete 'incomplete upload returns warning'
assert_file_contains "$tmpdir/result" geosite.dat 'warning names saved file'
assert_file_contains "$tmpdir/result" geoip.dat 'warning names still-missing file'
assert_false 'incomplete set does not invoke the core test' test -e "$tmpdir/core-tests"
assert_false 'incomplete set cannot restart a running core' test -e "$tmpdir/restarts"
assert_false 'incomplete publication commits journal normally' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
assert_file_contains "$GEODATA_MANUAL_FILE" geosite.dat 'incomplete upload retains manual metadata'
pass 'first missing asset is saved with actionable warning and no restart'

# A bad first asset cannot slip through the real check on the completing upload.
printf bad-first >"$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result"
assert_file_contains "$tmpdir/result" geodata_incomplete 'corrupt incomplete upload remains explicitly unverified'
assert_false 'still-incomplete replacement does not invoke the core' test -e "$tmpdir/core-tests"
cp "$XRAY_TEST_ASSETS/geoip.dat" "$upload"
assert_false 'completing upload checks the whole set, including corrupt first member' geodata_install_file "$upload" geoip.dat
assert_eq bad-first "$(cat "$XRAY_SHARE_DIR/geosite.dat")" 'rejected completion preserves original first bytes'
assert_false 'rejected completion does not publish second member' test -e "$XRAY_SHARE_DIR/geoip.dat"
assert_false 'rejected completion never restarts' test -e "$tmpdir/restarts"
assert_file_not_contains "$GEODATA_MANUAL_FILE" geoip.dat 'rejected completion preserves manual metadata'
pass 'completing upload rejects a corrupt previously saved member'

cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result"
assert_false 'repair still-incomplete set does not restart' test -e "$tmpdir/restarts"
cp "$XRAY_TEST_ASSETS/geoip.dat" "$upload"
geodata_install_file "$upload" geoip.dat >"$tmpdir/result"
assert_eq '[]' "$(jq -c .warnings "$tmpdir/result")" 'complete validated set has no missing-file warning'
assert_true 'completing valid asset published' cmp -s "$upload" "$XRAY_SHARE_DIR/geoip.dat"
assert_eq 1 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'complete validated set applies once'
assert_eq 2 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'rejected completion tested once; valid completion tests once: pending equals runtime'
pass 'upload completing the set gets real core test and normal apply'

# Pending settings must not let a wrong upload name corrupt complete live assets.
jq '.routing.rules[0].domain += ["ext:extra.dat:cn"]' "$XRAY_CONFIG" >"$tmpdir/pending.json"
cp "$tmpdir/pending.json" "$XRAY_CONFIG"
printf 'geodata-ref geosite.dat\ngeodata-ref geoip.dat\ngeodata-ref extra.dat\n' >"$PROFILE_FILE"
old_site="$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")"
printf corrupt-live-geosite >"$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result" 2>"$tmpdir/error" && upload_rc=0 || upload_rc=$?
assert_eq 1 "$upload_rc" 'pending missing extra cannot bypass complete live config test'
assert_file_contains "$tmpdir/error" '[E:geodata_check]' 'live core rejection is reported'
assert_eq "$old_site" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'live rejection preserves valid old asset'
assert_eq 1 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'rejected wrong-name upload never restarts'
assert_eq 3 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'only complete live config is tested'
pass 'incomplete pending settings cannot bypass live validation'

cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result"
assert_file_contains "$tmpdir/result" extra.dat 'valid live update retains pending-missing warning'
assert_eq 2 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'validated complete live config can reread updated file'
assert_eq 4 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'pending-incomplete update tests live only'
pass 'pending missing file does not suppress validated live application'

# Conversely, complete pending settings still reject a corrupt upload when live refs are incomplete.
cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
jq 'del(.routing.rules[0].domain[1])' "$XRAY_CONFIG" >"$tmpdir/complete.json"
cp "$tmpdir/complete.json" "$XRAY_CONFIG"
printf 'geodata-ref geosite.dat\ngeodata-ref geoip.dat\n' >"$PROFILE_FILE"
printf corrupt-pending-geosite >"$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result" 2>"$tmpdir/error" && upload_rc=0 || upload_rc=$?
assert_eq 1 "$upload_rc" 'incomplete live refs cannot bypass complete pending test'
assert_eq "$old_site" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'pending rejection preserves old asset'
assert_eq 5 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'only complete pending config is tested'
cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
geodata_install_file "$upload" geosite.dat >"$tmpdir/result"
assert_file_contains "$tmpdir/result" extra.dat 'incomplete live refs return missing-file warning'
assert_eq 6 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'complete pending test still runs on successful upload'
assert_eq 2 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'incomplete live config cannot restart'
pass 'pending and live completeness gates are independent'

printf unused-garbage >"$upload"
geodata_install_file "$upload" unused.dat >"$tmpdir/result"
assert_file_contains "$tmpdir/result" geodata_unverified 'genuinely unused upload keeps unverified warning'
assert_eq unused-garbage "$(cat "$XRAY_SHARE_DIR/unused.dat")" 'genuinely unused file is saved'
assert_eq 7 "$(wc -l <"$tmpdir/core-tests" | tr -d ' ')" 'unused upload is core-tested with the candidate only: the live config misses extra.dat'
assert_eq 2 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'genuinely unused upload does not restart'
pass 'genuinely unused file still saves without restart'
