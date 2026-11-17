#!/usr/bin/env bash
# Candidate validation, set rollback and durable interrupted-publication recovery.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
xray_test_bin 'atomic geodata' || exit 0
tmpdir="$(TMPDIR=/root make_temp_dir)"
upload="/tmp/xraywrt-geodata-atomic.$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh fetch.sh xray-config.sh
case "$XRAY_SHARE_DIR/" in /tmp/* | /var/*) fail 'production geodata must be persistent' ;; esac
setup_runtime_paths "$tmpdir"
RUNTIME_CONFIG="$tmpdir/runtime.json"
XRAY_BIN="$XRAY_TEST_BIN"
MEMINFO_FILE="$tmpdir/meminfo"
printf 'MemAvailable: 262144 kB\n' >"$MEMINFO_FILE"
settings_load() { :; }
profile_ensure() { :; }
service_running() { [ "${RUNNING:-0}" = 1 ]; }
core_restart() { echo restart >>"$tmpdir/restarts"; [ "${RESTART_FAIL:-0}" = 0 ]; }
xray_config_generate() { cp "$1" "$2"; cp "$PROFILE_FILE" "$2.profile"; }
cat >"$XRAY_CONFIG" <<'EOF'
{"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"}]}}
EOF
cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
printf 'geodata-ref geosite.dat\n' >"$PROFILE_FILE"
cp "$PROFILE_FILE" "$RUNTIME_CONFIG.profile"
cp "$XRAY_TEST_ASSETS/geosite.dat" "$XRAY_SHARE_DIR/geosite.dat"
old="$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")"
printf broken >"$upload"
assert_false 'corrupt referenced manual upload rejected by real core' geodata_install_file "$upload" geosite.dat
assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'rejection preserves original bytes'
assert_false 'rejection leaves manual metadata unchanged' test -e "$GEODATA_MANUAL_FILE"
pass 'real core rejects the candidate, not the active valid file'

cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
geodata_install_file "$upload" geosite.dat
assert_file_contains "$GEODATA_MANUAL_FILE" geosite.dat 'validated upload marked manual'
assert_false 'stopped upload does not start core' test -e "$tmpdir/restarts"
assert_false 'committed upload cleans journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
pass 'valid first/manual install while stopped'

(
 for path in "$XRAY_CONFIG" "$RUNTIME_CONFIG" "$PROFILE_FILE"; do mv "$path" "$path.saved"; done
 geodata_install_file "$upload" first.dat >"$tmpdir/result"
 assert_file_contains "$tmpdir/result" geodata_unverified 'upload before first subscription is explicitly unverified'
 for path in "$XRAY_CONFIG" "$RUNTIME_CONFIG" "$PROFILE_FILE"; do mv "$path.saved" "$path"; done
)
pass 'first upload without a subscription is preserved'

# Existing unused files follow the explicitly approved warning path too.
printf unused >"$upload"
geodata_install_file "$upload" unused.dat >"$tmpdir/result"
assert_file_contains "$tmpdir/result" geodata_unverified 'new unused file is explicitly unverified'
printf replaced >"$upload"
geodata_install_file "$upload" unused.dat >"$tmpdir/result"
assert_eq replaced "$(cat "$XRAY_SHARE_DIR/unused.dat")" 'unused replacement saved'
assert_file_contains "$tmpdir/result" geodata_unverified 'unused replacement is explicitly unverified'
assert_false 'unused files do not restart' test -e "$tmpdir/restarts"
pass 'unused files warn, never claim validation'

# A running config remains relevant when pending settings no longer use the file.
printf '{"outbounds":[{"protocol":"freedom"}]}' >"$XRAY_CONFIG"
printf 'mode proxy-first\n' >"$PROFILE_FILE"
printf broken >"$upload"
RUNNING=1
assert_false 'running config references still require validation' geodata_install_file "$upload" geosite.dat
assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'running asset preserved'
pass 'both saved and running configurations checked'
printf 'mode proxy-first\n' >"$RUNTIME_CONFIG.profile"
assert_false 'stale runtime profile cannot bypass actual running-config validation' geodata_install_file "$upload" geosite.dat
assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'actual runtime protects candidate independently of profile cache'
printf 'geodata-ref geosite.dat\n' >"$RUNTIME_CONFIG.profile"
pass 'runtime reference detection does not trust a saved-profile cache'


cp "$XRAY_TEST_ASSETS/geosite.dat" "$upload"
printf old-live >"$XRAY_SHARE_DIR/geosite.dat"
RUNNING=1 RESTART_FAIL=1
assert_false 'failed apply reports failure' geodata_install_file "$upload" geosite.dat
assert_eq "$(printf old-live | sha256sum)" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'restart failure restores distinct old asset'
assert_eq 2 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'old runtime restart attempted'
RUNNING=0 RESTART_FAIL=0
pass 'restart and rollback failure are not success'

RUNNING=1
printf old-degraded >"$XRAY_SHARE_DIR/geosite.dat"
touch "$DEGRADED_FILE"
printf tested >"$CONFIG_TESTED_FILE"
geodata_install_file "$upload" geosite.dat >/dev/null
assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'degraded apply replaces distinct old bytes'
assert_true 'degraded update leaves watchdog recovery pending' test -f "$DEGRADED_FILE"
assert_false 'asset change invalidates successful config test cache' test -e "$CONFIG_TESTED_FILE"
assert_eq 3 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'degraded live core rereads validated asset'
RUNNING=0
touch "$USER_STOP_FILE"
geodata_install_file "$upload" geosite.dat >/dev/null
assert_eq 3 "$(wc -l <"$tmpdir/restarts" | tr -d ' ')" 'explicit Stop is not undone by update'
pass 'degraded update preserves recovery gate and explicit Stop'

# Downloads are a tmpfs set until tested. A failed member publishes nothing.
http_fetch() { if [[ "$1" == *bad* ]]; then FETCH_ERROR=network; return 1; fi; cp "$upload" "$2"; }
printf 'geodata a.dat https://example/a\ngeodata b.dat https://example/bad\n' >"$PROFILE_FILE"
printf old-a >"$XRAY_SHARE_DIR/a.dat"
printf old-b >"$XRAY_SHARE_DIR/b.dat"
assert_false 'one failed download rejects set' geodata_update --force
assert_eq old-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'first member unchanged'
assert_eq old-b "$(cat "$XRAY_SHARE_DIR/b.dat")" 'second member unchanged'
pass 'multi-file download failure preserves complete old set'

(
 cp "$RUNTIME_CONFIG" "$XRAY_CONFIG"
 jq '.routing.rules[0].domain += ["ext:other.dat:cn"]' "$XRAY_CONFIG" >"$tmpdir/two.json"
 cp "$tmpdir/two.json" "$XRAY_CONFIG"
 printf 'geodata geosite.dat https://example/site\ngeodata other.dat https://example/corrupt\ngeodata-ref geosite.dat\ngeodata-ref other.dat\n' >"$PROFILE_FILE"
 cp "$XRAY_TEST_ASSETS/geosite.dat" "$XRAY_SHARE_DIR/other.dat"
 other_old="$(sha256sum <"$XRAY_SHARE_DIR/other.dat")"
 http_fetch() { if [[ "$1" == *corrupt ]]; then printf broken >"$2"; else cp "$XRAY_TEST_ASSETS/geosite.dat" "$2"; fi; }
 assert_false 'corrupt member rejects entire downloaded candidate set' geodata_update --force
 assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geosite.dat")" 'first real candidate preserves original SHA'
 assert_eq "$other_old" "$(sha256sum <"$XRAY_SHARE_DIR/other.dat")" 'corrupt member preserves original SHA'
)
pass 'real core rejects entire multi-file candidate set'
# The subshell changed fixture files, so return to the unused update fixture.
printf '{"outbounds":[{"protocol":"freedom"}]}' >"$XRAY_CONFIG"
printf 'geodata a.dat https://example/a\ngeodata b.dat https://example/b\n' >"$PROFILE_FILE"
(
 fail_swap=1
 http_fetch() { printf new >"$2"; }
 mv() {
  if [[ "${*: -1}" == "$XRAY_SHARE_DIR/b.dat" && "$fail_swap" = 1 ]]; then fail_swap=0; return 1; fi
  command mv "$@"
 }
 assert_false 'failed second rename reports failure and restores set' geodata_update --force
 assert_eq old-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'failed publish restores first member'
 assert_eq old-b "$(cat "$XRAY_SHARE_DIR/b.dat")" 'failed publish restores second member'
 assert_false 'successful rollback settles journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
)
pass 'publication failure rolls back the entire set'

# Simulate process exit after the first rename; recover in a fresh ash process.
printf new-a >"$upload"
geodata_stage_begin
geodata_stage_file "$upload" a.dat
geodata_stage_file "$upload" b.dat
(
 mv() {
  command mv "$@" || return
  if [[ "${*: -1}" == "$XRAY_SHARE_DIR/a.dat" ]]; then exit 77; fi
 }
 geodata_publish
) && crash=0 || crash=$?
for path in "$XRAY_SHARE_DIR/.geodata-transaction" "$XRAY_SHARE_DIR/a.dat.old" "$XRAY_SHARE_DIR/b.dat.new"; do
 case "$path" in /tmp/* | /var/*) fail 'journal and flash staging must survive reboot' ;; esac
 assert_eq "$(stat -c %d "$XRAY_SHARE_DIR")" "$(stat -c %d "$path")" 'journal/backup share destination filesystem'
done
assert_eq 77 "$crash" 'interrupted between replacements'
assert_eq new-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'first replacement happened'
assert_eq old-b "$(cat "$XRAY_SHARE_DIR/b.dat")" 'second replacement did not happen'
XRAY_SHARE_DIR="$XRAY_SHARE_DIR" ash -c '. "$XRAYWRT_LIB_DIR/helpers.sh"; . "$XRAYWRT_LIB_DIR/geodata.sh"; geodata_recover'
assert_eq old-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'reboot recovery restores first member'
assert_eq old-b "$(cat "$XRAY_SHARE_DIR/b.dat")" 'reboot recovery restores complete old set'
assert_false 'recovery removes journal only after success' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
pass 'interrupted atomic rename recovers entire old set across processes'

geodata_stage_begin
geodata_stage_file "$upload" a.dat
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 100 99 1 99%% /\n'; }
assert_false 'insufficient flash rejected before backup or write' geodata_publish
assert_eq old-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'ENOSPC keeps old bytes'
assert_false 'ENOSPC creates no journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
unset -f df
ln -s "$tmpdir/outside" "$XRAY_SHARE_DIR/evil.dat"
assert_false 'target symlink rejected' geodata_stage_file "$upload" evil.dat
assert_false 'traversal rejected' geodata_stage_file "$upload" ../evil.dat
printf 'MemAvailable: 16384 kB\n' >"$MEMINFO_FILE"
assert_false 'RAM reserve enforced before copying upload' geodata_stage_file "$upload" ram.dat
printf 'MemAvailable: 262144 kB\n' >"$MEMINFO_FILE"
GEODATA_MAX_BYTES=1
assert_false 'size limit enforced for local uploads' geodata_stage_file "$upload" huge.dat
pass 'space, path, symlink and size trust boundaries'

# The ref walker misses negated geoip (and sniffing exclusions): a core installed
# means every upload is tested with the candidate, used or not.
printf '#!/bin/sh\necho x >>"%s"\nexec "%s" "$@"\n' "$tmpdir/core-count" "$XRAY_TEST_BIN" >"$tmpdir/counting-core"
chmod +x "$tmpdir/counting-core"
(
 XRAY_BIN="$tmpdir/counting-core"
 GEODATA_MAX_BYTES=67108864
 printf '{"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","ip":["!geoip:cn"],"outboundTag":"direct"}]}}\n' >"$XRAY_CONFIG"
 cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
 : >"$PROFILE_FILE"
 cp "$XRAY_TEST_ASSETS/geoip.dat" "$XRAY_SHARE_DIR/geoip.dat"
 old="$(sha256sum <"$XRAY_SHARE_DIR/geoip.dat")"
 printf broken >"$upload"
 RUNNING=1
 assert_false 'corrupt file referenced only via !geoip: is rejected' geodata_install_file "$upload" geoip.dat
 assert_eq "$old" "$(sha256sum <"$XRAY_SHARE_DIR/geoip.dat")" 'rejection keeps the original geoip.dat'
 assert_eq 1 "$(wc -l <"$tmpdir/core-count" | tr -d ' ')" 'candidate equal to the runtime config is tested once'
 cp "$XRAY_TEST_ASSETS/geoip.dat" "$upload"
 geodata_install_file "$upload" geoip.dat >/dev/null
 assert_eq 2 "$(wc -l <"$tmpdir/core-count" | tr -d ' ')" 'valid upload is tested once too'
 assert_false 'no check files left in RAM' compgen -G "$PKG_TMP_DIR/geodata-check*"
)
pass 'upload referenced only through negated geoip is tested by the core'
