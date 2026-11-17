#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"; rm -f /tmp/xraywrt-policy-list.test-provider-"$$".*' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh service.sh
FX="$ROOT_DIR/tests/fixtures/xray"
# download <jq filter>: the provider's next subscription body (fakedns.json based).
download() { jq "$1" "$FX/src/fakedns.json" >"$tmpdir/download"; }
PKG_TMP_DIR="$tmpdir/tmp"
PKG_STATE_DIR="$tmpdir/run"
XRAY_DIR="$tmpdir/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_CONFIG_BACKUP="$XRAY_CONFIG.bak"
RUNTIME_CONFIG="$tmpdir/runtime.json"
SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/lock"
NFT_APPLIED_FILE="$tmpdir/nft.applied"
SUBSCRIPTION_META_FILE="$tmpdir/subscription.json"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lists"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
POLICY_CACHE_DIR="$tmpdir/cache"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR" "$XRAY_DIR"
echo "$$" >"$SUPERVISOR_PID_FILE"
lists_ensure_files
XRAY_BIN="$tmpdir/core"
XRAY_SHARE_DIR="$tmpdir/share"
mkdir -p "$XRAY_SHARE_DIR" && touch "$XRAY_SHARE_DIR/geoip.dat" "$XRAY_SHARE_DIR/geosite.dat"
printf '#!/bin/sh\nexit 0\n' >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
set_active_subscription https://p.example/sub
fake_uci_set xraywrt.settings.bypass_subscription_dns 0
fake_uci_set xraywrt.settings.subscription_auto_update 1
service_running() { return 0; }
service_ready() { return 0; }
core_restart() { echo restart >>"$tmpdir/events"; }
nft_active() { return 0; }
nft() { echo "nft:$*" >>"$tmpdir/events"; }
policy_apply() { echo "policy:$POLICY_MODE" >>"$tmpdir/events"; nft_apply; }
dns_restart_dnsmasq() { echo dns-restart >>"$tmpdir/events"; }
http_fetch() {
 FETCH_HDR="$6"
 assert_eq "$PKG_TMP_DIR/subscription.$$.headers" "$FETCH_HDR" "subscription requests explicit headers"
 assert_eq 0 "${LOCK_DEPTH:-0}" "download outside lock"
 assert_false "download leaves runtime lock free" lock_busy
 cp "$tmpdir/download" "$2"
 printf 'HTTP/1.1 200 OK\r\n%s\r\n' "$headers" >"$FETCH_HDR"
}
headers='profile-update-interval: 12'
download .
# First download: metadata must be reloaded before cron is computed.
subscription_update >/dev/null
assert_file_contains "$CRON_FILE" '/usr/bin/xraywrt auto-update' "first provider header enables cron"
assert_eq 12 "$(settings_subscription_interval)" "first header effective"
subscription_json | jq -e '.auto_update and .effective_interval == 12 and (has("interval") | not)' >/dev/null || fail "new subscription JSON fields"
# C7: the Subscription page reads the backup flag here, not from status-json.
had_backup=0
[ ! -f "$XRAY_CONFIG_BACKUP" ] || { had_backup=1; mv "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.c7"; }
assert_eq false "$(subscription_json | jq -c '.config_backup')" "no backup in subscription JSON"
printf '{"outbounds":[]}\n' >"$XRAY_CONFIG_BACKUP"
assert_eq true "$(subscription_json | jq -c '.config_backup')" "backup in subscription JSON"
mv "$SUBSCRIPTION_META_FILE" "$SUBSCRIPTION_META_FILE.c7"
printf '{"config_backup":true}' >"$SUBSCRIPTION_META_FILE"
rm -f "$XRAY_CONFIG_BACKUP"
assert_eq false "$(subscription_json | jq -c '.config_backup')" "provider metadata cannot claim a backup"
mv "$SUBSCRIPTION_META_FILE.c7" "$SUBSCRIPTION_META_FILE"
[ "$had_backup" = 0 ] || mv "$tmpdir/backup.c7" "$XRAY_CONFIG_BACKUP"
pass 'subscription JSON config_backup'
: >"$tmpdir/events"
assert_eq direct-first "$(profile_get mode)" "provider mode from the xraywrt key"
# The provider switches mode and extends its fake-IP whitelist.
download '.xraywrt.mode = "proxy-first" | .dns.servers[0].domains += ["domain:example.net"]'
touch -d '25 hours ago' "$PKG_STATE_DIR/subscription.stamp"
auto_update >/dev/null
assert_eq proxy-first "$(profile_get mode)" "cron provider mode change derives new mode"
assert_file_contains "$tmpdir/events" 'policy:proxy-first' "cron reapplies policy"
assert_eq 1 "$(grep -c '^nft:-f ' "$tmpdir/events")" "cron mode flip reapplies nft once"
# Spec 9.3: a new runtime config restarts the running core (no hot reload).
assert_eq 1 "$(grep -c '^restart$' "$tmpdir/events")" "cron restarts the core once"
# New provider URL is fetched unlocked, then nft is applied under the lock.
download '.xraywrt."proxy-ips" = ["https://p.example/list.txt"]'
lists_update_remote() {
 assert_eq 0 "${LOCK_DEPTH:-0}" "remote list fetch outside lock"
 assert_false "remote list fetch leaves runtime lock free" lock_busy
 echo fetched >>"$tmpdir/events"
 echo changed
}
nft_apply() {
 assert_true "nft apply owns runtime lock" test "${LOCK_DEPTH:-0}" -gt 0
 assert_eq "$$" "$(cat "$RUNTIME_LOCK_FILE.owner")" "nft apply owner metadata"
 echo nft-ready >>"$tmpdir/events"
}
: >"$tmpdir/events"
subscription_update >/dev/null
assert_file_contains "$tmpdir/events" fetched "new provider list fetched"
assert_eq nft-ready "$(tail -n1 "$tmpdir/events")" "nft reapplied after list fetch"
# A broken extension is ignored by the real generator/install path.
download '.xraywrt = {"disable-quic": "maybe", "unknown": true, "direct-ips": ["1.2.3.4"]}'
subscription_update >/dev/null
cmp -s "$XRAY_CONFIG" "$tmpdir/download" || fail "broken extension still installs byte-identically"
assert_file_contains "$PROFILE_FILE" 'ignored disable-quic' "bad extension ignored"
# Without a period the subscription must not acquire a cron schedule.
headers=''
subscription_update >/dev/null
assert_file_not_contains "$CRON_FILE" '/usr/bin/xraywrt auto-update' "absent header removes schedule"
# Exercise actual three-file installation, retaining the user's last list.
printf '192.0.2.1 core\n' >"/tmp/xraywrt-policy-list.test-provider-$$.1"
for i in 2 3; do printf '192.0.2.%s\n' "$i" >"/tmp/xraywrt-policy-list.test-provider-$$.$i"; done
service_ready() { return 1; }
lists_apply /tmp/xraywrt-policy-list.test-provider-"$$".{1,2,3} >/dev/null
assert_eq 192.0.2.3 "$(cat "$DIRECT_SRC_LIST_FILE")" "last list installed"
assert_eq '192.0.2.1 core' "$(cat "$RULES_FILE")" "My rules installed"
# Reboot removes the tmpfs stamp, but persistent metadata retains an update time.
rm -f "$PKG_STATE_DIR/subscription.stamp"
touch -d '1 hour ago' "$SUBSCRIPTION_META_FILE"
meta_mtime="$(date -r "$SUBSCRIPTION_META_FILE" +%s)"
assert_eq "$meta_mtime" "$(subscription_json | jq -r '.last_update')" "json uses meta mtime"
SUBSCRIPTION_INTERVAL=24
assert_false "due uses meta: one hour old is not due" subscription_due
touch -d '25 hours ago' "$SUBSCRIPTION_META_FILE"
assert_true "due uses meta: 25 hours old is due" subscription_due
# A newer tmpfs stamp takes precedence over unchanged persistent metadata.
touch -d '1 hour ago' "$PKG_STATE_DIR/subscription.stamp"
stamp_mtime="$(date -r "$PKG_STATE_DIR/subscription.stamp" +%s)"
assert_eq "$stamp_mtime" "$(subscription_json | jq -r '.last_update')" "stamp wins"
assert_false "stamp wins for due" subscription_due
assert_eq "$PKG_STATE_DIR/subscription.stamp" "$(subscription_stamp_file)" "stamp path wins"
rm "$PKG_STATE_DIR/subscription.stamp"
assert_eq "$SUBSCRIPTION_META_FILE" "$(subscription_stamp_file)" "metadata path fallback"
rm "$SUBSCRIPTION_META_FILE"
assert_false "no stamp or metadata returns failure" subscription_stamp_file
assert_eq "" "$(subscription_stamp_file || true)" "no stamp or metadata prints nothing"
assert_eq null "$(subscription_json | jq -r '.last_update')" "no timestamp remains null"
assert_true "no timestamp is due" subscription_due
pass "subscription cron transitions, provider list refresh, broken extensions, four-list installation and reboot timestamps"

# New URLs seed auto-update once; provider log levels never overwrite UCI.
service_ready() { return 0; }
lists_update_remote() { echo unchanged; }
RUNNING_MARKER="$PKG_STATE_DIR/running"
touch "$RUNNING_MARKER"
for level in debug info warning error none invalid absent; do
 for hours in 1 12 8760 '' 0 8761 bad; do
  set_active_subscription https://old.example/sub
  fake_uci_set xraywrt.settings.core_log_level error
  fake_uci_set xraywrt.settings.subscription_auto_update 1
  headers="profile-update-interval: $hours"
  download "if \"$level\" == \"absent\" then del(.log) else .log.loglevel = \"$level\" end"
  subscription_update https://new.example/sub >/dev/null
  expected_level="$level"; case "$level" in invalid | absent) expected_level=error ;; esac
  expected_auto=0; case "$hours" in 1 | 12 | 8760) expected_auto=1 ;; esac
  assert_eq "$expected_auto" "$(uci_get subscription_auto_update)" "new URL auto default ($hours)"
  assert_eq error "$(uci_get core_log_level)" "import never writes UCI core_log_level ($level)"
  assert_eq "$expected_level" "$(jq -r .log.loglevel "$RUNTIME_CONFIG")" 'runtime uses provider log or UCI fallback'
  fake_uci_set xraywrt.settings.core_log_level none
  fake_uci_set xraywrt.settings.subscription_auto_update 0
  subscription_update https://new.example/sub >/dev/null
  assert_eq none "$(uci_get core_log_level)" 'same URL keeps user log level'
  assert_eq 0 "$(uci_get subscription_auto_update)" 'same URL keeps user auto choice off'
  fake_uci_set xraywrt.settings.subscription_auto_update 1
  subscription_update https://new.example/sub >/dev/null
  assert_eq 1 "$(uci_get subscription_auto_update)" 'same URL keeps user auto choice on'
 done
done
# Selected array element supplies the default, not the first element.
subscription_option_set "$(uci_get subscription)" profile chosen
jq -s '[.[0] + {remarks:"first",log:{loglevel:"debug"}}, .[0] + {remarks:"chosen",log:{loglevel:"info"}}]' "$FX/src/fakedns.json" >"$tmpdir/download"
subscription_update https://array.example/sub >/dev/null
assert_eq none "$(uci_get core_log_level)" 'selected profile never writes UCI log'
assert_eq info "$(jq -r .log.loglevel "$RUNTIME_CONFIG")" 'selected profile supplies effective log level'
subscription_option_set "$(uci_get subscription)" profile ''
# Run the real Connect body with only its init executable redirected.
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/init"; chmod +x "$tmpdir/init"
sed "s|/etc/init.d/xraywrt|$tmpdir/init|g" "$XRAYWRT_LIB_DIR/subscription.sh" >"$tmpdir/subscription-connect.sh"
source "$tmpdir/subscription-connect.sh"
for hours in '' 12; do
 headers="profile-update-interval: $hours"
 fake_uci_reset
 download 'del(.log)'
 subscription_connect https://connect.example/sub >/dev/null
 expected_auto=0; [ "$hours" != 12 ] || expected_auto=1
 assert_eq "$expected_auto" "$(uci_get subscription_auto_update)" 'Connect preserves first import auto default'
done
pass 'new URL auto defaults and Connect, provider log levels preserve UCI'
