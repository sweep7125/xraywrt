#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh dns.sh nft.sh route.sh core.sh service.sh pkg.sh status.sh
pkg_installed_names() { :; }
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
RUNTIME_CONFIG="$tmpdir/runtime.json"
LIST_DIR="$tmpdir/lst"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src"
lists_ensure_files
printf '1.1.1.1 core\n# c\n2001:db8::1 core\n' >"$RULES_FILE"
echo "mode: rule" >"$RUNTIME_CONFIG"
fake_uci_set dhcp.cfg01 dnsmasq
fake_uci_set dhcp.cfg01.server "'9.9.9.9' '/corp.lan/10.0.0.2'"
service_running() { true; }
service_enabled() { true; }
dns_probe() { true; }
nft_active() { true; }
route_active() { true; }
core_version() { echo v1.19.32; }

(
 export settings_uci_netbird_mark=bad settings_uci_subscription=evil
 status_json >"$tmpdir/poison-status.json" || fail 'status returns JSON with inherited snapshot variables'
 assert_false 'status with inherited snapshot variables creates no invalid marker' test -e "$CONFIG_INVALID_FILE"
 assert_eq "$NETBIRD_DEFAULT_MARK" "$NETBIRD_MARK" 'status ignores inherited NetBird mark'
 assert_eq '' "$SUBSCRIPTION_URL" 'status ignores inherited subscription URL'
)
pass 'status ignores inherited settings snapshot variables'

echo ok >"$HEALTH_FILE"
(
 assert_eq false "$(status_json | jq .observatory_signal)" 'no live observatory signal'
 touch "$PKG_STATE_DIR/observatory"
 assert_eq true "$(status_json | jq .observatory_signal)" 'live observatory signal is exposed'
 rm "$PKG_STATE_DIR/observatory"
)
json="$(status_json)"
assert_eq "true|true|true|null" "$(jq -r '"\(.running)|\(.dns_ok)|\(.policy_active)|\(.config_valid)"' <<<"$json")" "checklist flags"
assert_eq 'false|false|true' "$(jq -r '"\(.flags.dns_hijack)|\(.flags.disable_quic)|\(.flags.enabled)"' <<<"$json")" 'support summary allowlisted flags'
assert_eq '["9.9.9.9"]' "$(jq -c .custom_dns_servers <<<"$json")" "only global custom servers reported"
assert_eq 2 "$(jq .lists.dst <<<"$json")" "list count ignores comments"
assert_eq "v1.19.32" "$(jq -r .core <<<"$json")" "core version"
# UX task 9: count only effective provider overrides, plus the explicit mode choice.
(
 printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\nset disable_quic 0\n' >"$PROFILE_FILE"
 fake_uci_set xraywrt.settings.provider_override 'disable_quic bypass_ntp mode disable_quic'
 assert_eq 2 "$(status_json | jq .overrides)" 'provider overrides count excludes absent keys and duplicates'
 assert_eq 2 "$(profile_json | jq .overrides)" 'profile reports the same override count'
 fake_uci_set xraywrt.settings.provider_override bypass_ntp
 assert_eq 0 "$(status_json | jq .overrides)" 'router-only choices are not provider overrides'
 for reason in dns observatory; do
  printf '%s\n' "$reason" >"$DEGRADED_FILE"
  assert_eq "$reason" "$(status_json | jq -r .degraded_reason)" 'status reads degraded reason'
  assert_eq "$reason" "$(service_state_json | jq -r .degraded_reason)" 'live state reads degraded reason'
 done
 : >"$DEGRADED_FILE"
 assert_eq dns "$(status_json | jq -r .degraded_reason)" 'legacy empty marker means DNS failure'
 rm "$DEGRADED_FILE"
 assert_eq null "$(status_json | jq .degraded_reason)" 'no degraded reason without marker'
)
pass "status checklist"

(
 load_modules nft.sh
 nft() { printf '%s\n' "$*" >"$tmpdir/status-nft.calls"; }
 json="$(status_json)"
 assert_eq true "$(jq .policy_active <<<"$json")" 'status uses real nft active check'
 assert_eq '-t list table inet xraywrt' "$(cat "$tmpdir/status-nft.calls")" 'status nft check skips set elements'
)
pass 'status uses terse nft active check'

subscription_failed=false
for entry in 'http://p/x|true|http flagged' 'HTTP://p/x|true|case insensitive' 'https://p/x|false|https not flagged' '|false|empty url false'; do
 IFS='|' read -r url expected name <<<"$entry"
 if [ -n "$url" ]; then set_active_subscription "$url"; else fake_uci_reset; fi
 if (assert_eq "$expected" "$(status_json | jq .subscription_insecure)" "$name"); then
  pass "status subscription $name"
 else
  subscription_failed=true
 fi
done
[ "$subscription_failed" = false ] || fail 'status subscription security flags'

echo fail >"$HEALTH_FILE"
dns_probe() { fail "status must not probe DNS"; }
assert_eq false "$(status_json | jq .dns_ok)" "failed DNS probe reported"
pass "status dns failure"

logread() { for i in $(seq 1 1500); do echo "xraywrt: line $i"; done; echo "other: x"; }
assert_eq 1000 "$(logs_json 5000 | jq '.lines | length')" "logs clamped to 1000"
assert_eq 200 "$(logs_json abc | jq '.lines | length')" "invalid limit uses 200"
assert_eq "xraywrt: line 1500" "$(logs_json 1 | jq -r '.lines[0]')" "newest line kept"
pass "logs clamp"

# The watchdog's own DNS probe (every 15 s) is not shown; other Xray DNS lines stay.
logread() {
	echo "xray[1]: [Info] [7] handling DNS traffic to 127.0.0.1:$XRAY_DNS_PORT/udp"
	echo "xray[1]: [Info] [8] handling DNS traffic to 127.0.0.1:9999/udp"
	echo "xraywrt: started"
	echo "xray[1]: [Info] [9] handling DNS traffic to 127.0.0.1:$XRAY_DNS_PORT/udp"
}
assert_eq "xray[1]: [Info] [8] handling DNS traffic to 127.0.0.1:9999/udp,xraywrt: started" "$(logs_json 10 | jq -r '.lines | join(",")')" "logs hide the watchdog DNS probe"
assert_eq 4 "$(logs_json 10 full | jq '.lines | length')" 'detailed logs keep DNS messages'
pass "logs hide watchdog probe"

printf 'mode: rule\n' >"$XRAY_CONFIG"
service_running() { false; }
XRAY_BIN="$tmpdir/core"
printf '#!/bin/sh\ntouch "%s"\n' "$tmpdir/core.called" >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
json="$(status_json)"
assert_false "status never invokes core" test -e "$tmpdir/core.called"
touch "$CONFIG_OK_FILE"
assert_eq true "$(status_json | jq .config_valid)" "recorded success"
rm "$CONFIG_OK_FILE"
printf 'bad proxy type\n' >"$CONFIG_ERR_FILE"
assert_eq 'false:bad proxy type' "$(status_json | jq -r '"\(.config_valid):\(.config_error)"')" "recorded error"
touch -d '2000-01-01' "$CONFIG_ERR_FILE"
assert_eq null "$(status_json | jq .config_valid)" "new config invalidates result"
printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\ndns redir-host\nset disable_quic 0\nhas proxy-ips\nproxy-ip 1.2.3.4\n' >"$PROFILE_FILE"
fake_uci_set xraywrt.settings.provider_override disable_quic
profile_json | jq -e '.provider.disable_quic == "0" and .overrides == 1 and .targets == [] and .reserved == [] and .provider_lists == true' >/dev/null || fail "profile-json contract"
printf 'mode-source auto\nsniff tls\ndirect-domains 2\n' >>"$PROFILE_FILE"
profile_json | jq -e '.mode_source == "auto" and .sniff == "tls" and .direct_domains == 2' >/dev/null || fail 'profile mode source and direct domains'
status_json | jq -e '.sniff == "tls" and .direct_domains == 2' >/dev/null || fail 'status direct domains'
# The targets of My rules are what the generator recorded; reserved tags are named apart.
printf 'rules-target proxy\nrules-target pool\nrules-reserved direct\n' >>"$PROFILE_FILE"
profile_json | jq -e '.targets == ["proxy","pool"] and .reserved == ["direct"] and (has("lists") | not)' >/dev/null || fail 'profile targets and reserved tags'
cp "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$XRAY_CONFIG"
profile_json | jq -e '.dns_outbounds == ["proxy"]' >/dev/null || fail 'profile separates DNS outbounds from My rules balancers'
fake_uci_set xraywrt.settings.dns_raw_via proxy
profile_json | jq -e '.dns_outbounds == ["proxy"]' >/dev/null || fail 'catalog survives via with missing upstream'
rm -f "$PROFILE_FILE"
profile_json | jq -e '.dns_outbounds == ["proxy"]' >/dev/null || fail 'repair catalog does not need a successful cached profile'
jq -s '[.[0] + {remarks:"first"}, .[0] + {remarks:"chosen",outbounds:[{protocol:"socks",tag:"chosen tag"}]}]' "$XRAY_CONFIG" >"$tmpdir/array.json"
cp "$tmpdir/array.json" "$XRAY_CONFIG"
fake_uci_set xraywrt.settings.profile chosen
profile_json | jq -e '.dns_outbounds == ["chosen tag"]' >/dev/null || fail 'profile selection updates DNS catalog without cached profile refresh'
uci delete xraywrt.settings.profile
uci delete xraywrt.settings.dns_raw_via
pass "status check state, core not called and profile-json"

printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\ndns redir-host\nset block_client_ipv6 1\n' >"$PROFILE_FILE"
fake_uci_set xraywrt.settings.block_client_ipv6 0
fake_uci_set xraywrt.settings.provider_override block_client_ipv6
profile_json | jq -e '.provider.block_client_ipv6 == "1" and .overrides == 1' >/dev/null || fail "client IPv6 provider value and override"
for extra in '' 'ignored block-client-ipv6'; do
 printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\ndns redir-host\n%s\n' "$extra" >"$PROFILE_FILE"
 profile_json | jq -e '.provider | has("block_client_ipv6") | not' >/dev/null || fail "absent or invalid provider key not guessed"
done
uci delete xraywrt.settings.provider_override
uci delete xraywrt.settings.block_client_ipv6
pass "profile-json client IPv6 provider key"

printf '# Devices\naa:bb:cc:dd:ee:ff\n10.2.3.4\n' >"$SRC_LIST_FILE"
printf 'aa:bb:cc:dd:ee:ff\n' >"$DIRECT_SRC_LIST_FILE"
assert_eq '2:1' "$(status_json | jq -r '"\(.lists.src):\(.lists.direct_src)"')" 'status counts MAC and IP devices'
pass 'status MAC device counts'

XRAY_CONFIG_BACKUP="$tmpdir/config.json.bak"
assert_eq false "$(status_json | jq .config_backup)" 'no backup flag'
touch "$XRAY_CONFIG_BACKUP"
assert_eq true "$(status_json | jq .config_backup)" 'backup flag'
pass 'status backup flag'

# Home shows the NetBird flag only when NetBird is on the router.
(
 fake_uci_set xraywrt.settings.netbird_interface "nb-missing-$$"
 have_command() { false; }
 assert_eq false "$(status_json | jq .netbird)" 'no NetBird interface or program'
 have_command() { [ "$1" = netbird ]; }
 assert_eq true "$(status_json | jq .netbird)" 'netbird program in PATH'
 have_command() { false; }
 fake_uci_set xraywrt.settings.netbird_interface lo
 assert_eq true "$(status_json | jq .netbird)" 'NetBird interface exists'
)
pass 'status netbird flag'

# Home fetches balancers only when opened; the status says whether there is anything to show.
(
 cp "$RUNTIME_CONFIG" "$tmpdir/runtime.keep"
 service_running() { true; }
 printf '{"routing":{"balancers":[{"tag":"b","selector":["a"]}]},"outbounds":[{"tag":"a"}]}\n' >"$RUNTIME_CONFIG"
 assert_eq true "$(status_json | jq .has_balancers)" 'configured balancers are reported'
 service_running() { false; }
 assert_eq false "$(status_json | jq .has_balancers)" 'a stopped core has no balancers block'
 service_running() { true; }
 printf '{"routing":{},"outbounds":[]}\n' >"$RUNTIME_CONFIG"
 assert_eq false "$(status_json | jq .has_balancers)" 'no balancers, no saved override'
 fake_uci_set xraywrt.settings.balancer_override "'gone=node-a'"
 assert_eq true "$(status_json | jq .has_balancers)" 'a stale saved override still surfaces the block'
 uci delete xraywrt.settings.balancer_override
 cp "$tmpdir/runtime.keep" "$RUNTIME_CONFIG"
)
pass 'status balancers flag'

# Diagnostics needs the stored flag next to the mode to say whether it has any effect.
assert_eq false "$(status_json | jq .block_client_ipv6)" 'client IPv6 flag off by default'
fake_uci_set xraywrt.settings.block_client_ipv6 1
assert_eq true "$(status_json | jq .block_client_ipv6)" 'client IPv6 flag reported'
uci delete xraywrt.settings.block_client_ipv6
pass 'status client IPv6 flag'

# Every state-table row, including precedence when multiple files exist.
service_running() { true; }
touch "$DEGRADED_FILE" "$RUNNING_MARKER" "$USER_STOP_FILE" "$LAST_ERROR_FILE"
assert_eq degraded "$(service_state)" 'alive degraded wins'
rm "$DEGRADED_FILE"
assert_eq running "$(service_state)" 'alive running marker'
rm "$RUNNING_MARKER"
assert_eq starting "$(service_state)" 'alive without marker'
service_running() { false; }
assert_eq stopped "$(service_state)" 'user stop wins over error'
rm "$USER_STOP_FILE"
assert_eq failed "$(service_state)" 'dead with error'
rm "$LAST_ERROR_FILE"
assert_eq stopped "$(service_state)" 'dead without error'
pass 'service state table'

# Exercise real core_version and service_enabled; only the full status may load settings.
load_modules core.sh status.sh
printf '#!/bin/sh\necho called >>"%s"\necho "Xray 1.19.32 (Xray, Penetrates Everything.)"\n' "$tmpdir/core.calls" >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
touch -d '2000-01-01' "$XRAY_BIN"
printf '%s\n%s\n' v1.19.32 "$(ls -lic --full-time "$XRAY_BIN")" >"$CORE_VERSION_CACHE"
curl() { echo called >>"$tmpdir/curl.calls"; return 1; }
dns_probe() { curl; }
echo 'failure "quoted"' >"$LAST_ERROR_FILE"
for health in ok fail missing; do
 case "$health" in ok) expected=true ;; fail) expected=false ;; missing) expected=null ;; esac
 if [ "$health" = missing ]; then rm -f "$HEALTH_FILE"; else echo "$health" >"$HEALTH_FILE"; fi
 (
  settings_load() { fail 'cheap status must not load settings'; }
  uci() { fail 'cheap status must not call uci'; }
  json="$(service_state_json)"
  assert_eq "$expected" "$(jq .dns_ok <<<"$json")" 'cheap health snapshot'
  jq -e '.running == false and (.enabled | type) == "boolean" and .state == "failed" and .last_error == "failure \"quoted\"" and (keys | length) == 7 and .degraded_reason == null' <<<"$json" >/dev/null || fail 'cheap JSON contract'
 )
 json="$(status_json)"
 assert_eq "$expected" "$(jq .dns_ok <<<"$json")" 'full status health snapshot'
 assert_eq failed "$(jq -r .state <<<"$json")" 'full status state'
 assert_eq 'failure "quoted"' "$(jq -r .last_error <<<"$json")" 'full status error'
done
assert_false 'status does not call API' test -e "$tmpdir/curl.calls"
assert_false 'fresh cache avoids core invocation' test -e "$tmpdir/core.calls"
touch -d '2001-01-01' "$CORE_VERSION_CACHE"
touch "$XRAY_BIN"
json="$(status_json)"
json="$(status_json)"
assert_eq 1 "$(wc -l <"$tmpdir/core.calls" | tr -d ' ')" 'new binary queried exactly once'
assert_eq 1.19.32 "$(sed -n 1p "$CORE_VERSION_CACHE")" 'cache refreshed'
pass 'cheap status uses health files and cached core version'

(
 # Relocate only the fixed init paths, keeping the real enabled-check logic.
 eval "$(declare -f service_enabled | sed "s|/etc/|$tmpdir/etc/|g")"
 mkdir -p "$tmpdir/etc/rc.d" "$tmpdir/etc/init.d"
 printf '#!/bin/sh\ntouch "%s"\n' "$tmpdir/init.called" >"$tmpdir/etc/init.d/xraywrt"
 chmod +x "$tmpdir/etc/init.d/xraywrt"
 assert_false 'no start link means disabled' service_enabled
 ln -s ../init.d/xraywrt "$tmpdir/etc/rc.d/S21xraywrt"
 assert_true 'start link means enabled' service_enabled
 assert_false 'enabled never invokes init' test -e "$tmpdir/init.called"
)
assert_eq service-state-json "$(XRAYWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/xraywrt-read" service-state-json)" 'read wrapper exposes cheap status'
assert_false 'cheap read command rejects arguments' env XRAYWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/xraywrt-read" service-state-json extra
pass 'cheap enabled flag and read wrapper'

# PID state is sampled once, even if the process changes between checks.
(
 service_running() { echo checked >>"$tmpdir/pid-checks"; true; }
 printf 'first line\nsecond \\ line\n' >"$LAST_ERROR_FILE"
 json="$(service_state_json)"
 assert_eq 1 "$(wc -l <"$tmpdir/pid-checks" | tr -d ' ')" 'cheap status checks PID once'
 assert_eq 'first line
second \ line' "$(jq -r .last_error <<<"$json")" 'multiline error preserved literally'
)
pass 'service-state-json single PID snapshot and literal errors'

printf 'ok\nunexpected\n' >"$HEALTH_FILE"
assert_eq null "$(health_json)" 'malformed health snapshot stays unknown'
printf 'ok\n\n' >"$HEALTH_FILE"
assert_eq true "$(health_json)" 'health trailing newlines retain previous meaning'
pass 'health file exact snapshot semantics'

(
 assert_eq '[]' "$(status_json | jq -c '[keys[] | select(startswith("dashboard"))]')" 'status has no dashboard fields'
 assert_eq '[]' "$(profile_json | jq -c '[keys[] | select(startswith("dashboard"))]')" 'profile has no dashboard fields'
)
pass 'status and profile have no dashboard'
awk 'BEGIN { printf "%0200000d\n", 1 }' >"$LAST_ERROR_FILE"
json="$(status_json)"
assert_true 'huge snapshot gives bounded JSON error' test "$(jq -rj .last_error <<<"$json" | wc -c)" -le 4096
last_error_record "$LAST_ERROR_FILE"
assert_true 'recorded start error bounded' test "$(wc -c <"$LAST_ERROR_FILE")" -le 4096
CONFIG_TEST_OUTPUT="$(awk 'BEGIN { for (i=0;i<25;i++) printf "%010000d\n", i }')"
config_check_record err
assert_true 'recorded config error bounded' test "$(wc -c <"$CONFIG_ERR_FILE")" -le 4096
assert_true 'config error lines bounded' test "$(awk 'length > n { n=length } END { print n }' "$CONFIG_ERR_FILE")" -le 1000
pass 'huge status and recorded errors stay bounded'

(
 awk() { touch "$tmpdir/error-awk-called"; command awk "$@"; }
 : >"$tmpdir/empty-error"
 assert_eq '' "$(error_text "$tmpdir/empty-error")" 'empty diagnostic snapshot'
 assert_eq '' "$(error_text "$tmpdir/missing-error" 2>/dev/null)" 'missing diagnostic snapshot'
 assert_false 'empty error snapshots never fork awk' test -e "$tmpdir/error-awk-called"
)
pass 'empty error snapshots stay fork-free'

# The real JSON consumer replaces a trailing byte fragment rather than emitting invalid UTF-8.
printf '%0999dЖ' 0 >"$LAST_ERROR_FILE"
assert_eq 1000 "$(error_text "$LAST_ERROR_FILE" | tr -d '\n' | wc -c)" 'diagnostic cut lands inside Cyrillic character'
json="$(status_json)"
printf '%s\n' "$json" >"$tmpdir/utf8-status.json"
node - "$tmpdir/utf8-status.json" <<'NODE'
const fs = require('fs');
const text = new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(process.argv[2]));
const data = JSON.parse(text);
if (!data.last_error.startsWith('0'.repeat(999))) throw new Error('diagnostic prefix lost');
NODE
pass 'byte-cut UTF-8 diagnostic survives real status JSON consumer'

(
 DISCORD_VOICE=1 POLICY_MODE=direct-first
 NFT_APPLIED_FILE="$tmpdir/discord-applied"
 mkdir -p "$ROUTE_PROC_ROOT/sys/net/netfilter"
 echo 1 >"$ROUTE_PROC_ROOT/sys/net/netfilter/nf_conntrack_acct"
 status_warnings >"$tmpdir/discord-warning"
 assert_file_contains "$tmpdir/discord-warning" 'Discord Voice inactive' 'unapplied detector warns even when accounting is on'
 echo 1 >"$NFT_APPLIED_FILE.discord_voice"
 echo 0 >"$ROUTE_PROC_ROOT/sys/net/netfilter/nf_conntrack_acct"
 status_warnings >"$tmpdir/discord-warning"
 assert_file_not_contains "$tmpdir/discord-warning" 'Discord Voice inactive' 'installed detector remains ready after accounting changes'
 POLICY_MODE=proxy-first
 rm -f "$NFT_APPLIED_FILE.discord_voice"
 status_warnings >"$tmpdir/discord-warning"
 assert_file_not_contains "$tmpdir/discord-warning" 'Discord Voice inactive' 'proxy-first has no detector warning'
)
pass 'Discord Voice prerequisite warning'

# A12.1: profile, core source, warnings, fake-IP domains and geodata (spec 15).
CORE_JSON_FILE="$tmpdir/core.json"
printf '{"channel":"Jolymmiles/Xray-core","tag":"v26.11.1-1424","source":"channel"}\n' >"$CORE_JSON_FILE"
fake_uci_set xraywrt.settings.profile 'Fast'
mkdir -p "$XRAY_SHARE_DIR"
rm -f "$XRAY_SHARE_DIR"/*
printf 'abc' >"$XRAY_SHARE_DIR/geosite.dat"
touch -d '@1700000000' "$XRAY_SHARE_DIR/geosite.dat"
printf '%s\n' 'profile-schema 1' 'mode direct-first' 'profile Main' 'warn profile "Fast" not found, using "Main"' 'ignored foo' \
	'fake-domains 0' 'fake-enabled 0' 'geodata geosite.dat https://cdn.example.com/geosite.dat' 'geodata geoip.dat https://cdn.example.com/geoip.dat' \
	'geodata-ref geosite.dat' 'geodata-ref ext.dat' >"$PROFILE_FILE"
json="$(status_json)"
jq -e '.profile == {name: "Fast", selected: "Main", pinned: false}' <<<"$json" >/dev/null || fail "profile: $(jq -c .profile <<<"$json")"
jq -e '.core_source == {channel: "Jolymmiles/Xray-core", tag: "v26.11.1-1424", source: "channel", version: null}' <<<"$json" >/dev/null ||
	fail "core source: $(jq -c .core_source <<<"$json")"
assert_eq '["profile \"Fast\" not found, using \"Main\"","ignored invalid or unknown setting '"'"'foo'"'"' [E:setting_ignored|foo]","direct-first has no fake-IP domains: only proxy IP lists are intercepted [E:direct_no_domains]"]' \
	"$(jq -c .warnings <<<"$json")" 'profile warnings'
assert_eq 0 "$(jq .fake_domains <<<"$json")" 'fake-IP domains'
assert_eq '[{"file":"ext.dat","asset":false,"referenced":true,"present":false,"size":null,"mtime":null},{"file":"geoip.dat","asset":true,"referenced":false,"present":false,"size":null,"mtime":null},{"file":"geosite.dat","asset":true,"referenced":true,"present":true,"size":3,"mtime":1700000000}]' \
	"$(jq -c .geodata <<<"$json")" 'geodata'
printf '%s\n' 'profile-schema 1' 'mode direct-first' 'fake-domains 2' 'fake-enabled 1' 'profile Main' 'profile-pinned 1' >"$PROFILE_FILE"
status_json | jq -e '.profile.pinned == true and .profile.selected == "Main"' >/dev/null || fail 'pinned profile in status'
printf '%s\n' 'profile-schema 1' 'mode direct-first' 'fake-domains 2' 'fake-enabled 1' >"$PROFILE_FILE"
json="$(status_json)"
jq -e '.warnings == [] and .fake_domains == 2 and .geodata == [] and .profile == {name: "Fast", selected: null, pinned: false}' <<<"$json" >/dev/null || fail "plain profile: $json"
printf '%s\n' 'profile-schema 1' 'mode direct-first' 'fake-domains 0' 'fake-enabled 1' >"$PROFILE_FILE"
json="$(status_json)"
jq -e '.fake_enabled == true and .fake_domains == 0 and .warnings == []' <<<"$json" >/dev/null || fail 'active zero-count FakeDNS has no inactive warning'
jq -e '.fake_enabled == true' <<<"$(profile_json)" >/dev/null || fail 'profile exposes activation boolean'
printf '%s\n' 'profile-schema 1' 'mode direct-first' 'fake-domains 0' 'fake-enabled 0' >"$PROFILE_FILE"
jq -e '.fake_enabled == false' <<<"$(status_json)" >/dev/null || fail 'status exposes inactive boolean'
jq -e '.fake_enabled == false' <<<"$(profile_json)" >/dev/null || fail 'profile exposes inactive boolean'
rm -f "$CORE_JSON_FILE" "$PROFILE_FILE"
uci delete xraywrt.settings.profile
json="$(status_json)"
jq -e '.core_source == {channel: null, tag: null, source: null, version: null} and .fake_domains == null and .profile == {name: null, selected: null, pinned: false}' <<<"$json" >/dev/null ||
	fail "no core.json or profile: $json"
# Production status no longer exposes source selection; old UCI is inert.
jq -e 'has("core_channel") | not' <<<"$json" >/dev/null || fail 'channel selector schema remains'
fake_uci_set xraywrt.settings.core_channel 'XTLS/Xray-core'
jq -e 'has("core_channel") | not' <<<"$(status_json)" >/dev/null || fail 'legacy UCI restored channel selector'
pkg_installed_names() { printf '%s\n' luci-app-xraywrt xraywrt-core; }
# A package installed by hand (apk add, no core.json) is still the core package source.
pkg_version() { [ "$1" = xraywrt-core ] && echo 0.23.0-r1; }
jq -e '.core_source == {source: "package", channel: "core", tag: null, version: "0.23.0-r1"}' <<<"$(status_json)" >/dev/null || fail "hand-installed package source: $(status_json | jq -c .core_source)"
jq -nc '{channel: "XTLS/Xray-core", tag: "v26.1.1", source: "channel"}' >"$CORE_JSON_FILE"
jq -e '.core_source.source == "package" and .core_source.version == "0.23.0-r1"' <<<"$(status_json)" >/dev/null || fail "package over a stale channel core.json: $(status_json | jq -c .core_source)"
unset -f pkg_version
# Spec 15: the Core page shows "<version> (package)".
jq -nc '{channel: "core", tag: "v0.2.0", version: "26.11.1-r1", source: "package"}' >"$CORE_JSON_FILE"
jq -e '.core_source == {source: "package", channel: "core", tag: "v0.2.0", version: "26.11.1-r1"}' <<<"$(status_json)" >/dev/null || fail "package source: $(status_json | jq -c .core_source)"
rm -f "$CORE_JSON_FILE"
unset -f pkg_installed_names
uci delete xraywrt.settings.core_channel
pass 'status profile, core source, warnings and geodata'

pkg_installed_names() { :; }
printf 'Accepted settings need routing retry.\n' >"$APPLY_WARNING_FILE"
for endpoint in status_json service_state_json; do
 "$endpoint" >"$tmpdir/apply-warning.json" || fail "$endpoint failed"
 assert_eq 'Accepted settings need routing retry.' "$(jq -r .apply_warning "$tmpdir/apply-warning.json")" "$endpoint exposes persisted application warning"
done
rm "$APPLY_WARNING_FILE"
pass 'full and cheap status expose application warning independently of process state'

(
 printf 'profile-schema 1\nfake-enabled 0\nmode direct-first\nhas proxy-ips\nhas direct-ips\nproxy-ip 192.0.2.1\nproxy-ip https://secret.example/token\nproxy-ip invalidSECRET\ndirect-ip 2001:db8::/32\ndirect-ip https://other.example/password\n' >"$PROFILE_FILE"
 printf "direct-ip 192.0.2.2;%s\n" "$(printf '443,%.0s' $(seq 1 120))443" >>"$PROFILE_FILE"
 for n in $(seq 1 55); do printf 'proxy-ip 198.51.100.%s\n' "$n" >>"$PROFILE_FILE"; done
 profile_ensure() { :; }
 json="$(profile_json)"
 assert_eq '192.0.2.1' "$(jq -r '.provider_sources.vpn.addresses[0]' <<<"$json")" 'provider VPN literal'
 assert_eq '2001:db8::/32' "$(jq -r '.provider_sources.direct.addresses[0]' <<<"$json")" 'provider direct literal'
 assert_eq '50:true:1:1' "$(jq -r '"\(.provider_sources.vpn.addresses | length):\(.provider_sources.vpn.truncated):\(.provider_sources.vpn.links):\(.provider_sources.direct.links)"' <<<"$json")" 'preview bounded and links counted separately'
 assert_eq '1:true' "$(jq -r '"\(.provider_sources.direct.addresses | length):\(.provider_sources.direct.truncated)"' <<<"$json")" 'oversized literal omitted with truncation indicator'
 assert_false 'provider preview does not expose links or invalid values' grep -Eq 'secret|password|invalidSECRET' <<<"$json"
)
pass 'profile provider list preview is bounded and private'

(
 printf 'profile-schema 1\nfake-enabled 0\nhas proxy-ips\n' >"$PROFILE_FILE"
 printf 'proxy-ip 192.0.2.1;%s\nproxy-ip https://secret.example/token\n' "$(printf '443,%.0s' $(seq 1 120))443" >>"$PROFILE_FILE"
 for n in $(seq 1 150); do printf 'proxy-ip 198.51.100.%s\n' "$((n % 254 + 1))" >>"$PROFILE_FILE"; done
 lists_classify() { cat >"$tmpdir/preview-classify-input"; }
 output="$(provider_list_preview dst)"
 assert_true 'preview caps classification input count' test "$(wc -l <"$tmpdir/preview-classify-input")" -le 100
 assert_true 'preview filters long literals before classification' test "$(awk 'length > n { n=length } END { print n+0 }' "$tmpdir/preview-classify-input")" -le 256
 assert_true 'preview counts links and signals truncation' bash -c '[[ "$1" == *"links 1"* && "$1" == *"truncated 1"* ]]' _ "$output"
)
pass 'provider preview bounds normalization work'

(
 printf 'profile-schema 1\nfake-enabled 0\nhas proxy-ips\nproxy-ip 192.0.2.1\n' >"$PROFILE_FILE"
 printf '{}' >"$XRAY_CONFIG"
 touch -d '2000-01-01' "$PROFILE_FILE"
 xray_config_generate() { return 1; }
 json="$(profile_json)"
 assert_eq null "$(jq -c .provider_sources <<<"$json")" 'failed stale profile rebuild makes preview unavailable'
 assert_false 'stale address not exposed by preview' grep -q '192.0.2.1' <<<"$json"
 rm "$XRAY_CONFIG"
 json="$(profile_json)"
 assert_eq null "$(jq -c .provider_sources <<<"$json")" 'missing source config makes preview unavailable'
)
pass 'profile preview rejects stale or missing source after failed rebuild'
