#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
export RELOAD_TEST_DIR="$tmpdir" RELOAD_FIXTURES="$ROOT_DIR/tests/fixtures/xray"

# Unchanged inputs must not rebuild the runtime config; each generator input
# must. Scenarios run in BusyBox ash, the shell of the router.
failed=0
for scenario in same source uc_file rules remote_list wan_dns dns_port fakeip tproxy direct_tproxy mark \
	mode log_level runtime_missing profile_missing no_key reuse restart_failure test_rejected \
	build_failed_test install_ok install_restore degraded_source degraded_rules degraded_rejected stopped; do
	if ash -s "$scenario" <<'ASH'
set -e
. "$XRAYWRT_LIB_DIR/constants.sh"
. "$XRAYWRT_LIB_DIR/helpers.sh"
xraywrt_load_modules
scenario="$1"
test_root="$RELOAD_TEST_DIR/$scenario"
mkdir -p "$test_root/lib"
cp "$XRAYWRT_LIB_DIR/xray-config.uc" "$test_root/lib/"
XRAYWRT_LIB_DIR_REAL="$XRAYWRT_LIB_DIR"
# Generator files come from a private copy so a scenario can edit them.
XRAYWRT_LIB_DIR="$test_root/lib"
PKG_TMP_DIR="$test_root/tmp"
PKG_STATE_DIR="$test_root/run"
PKG_PERSIST_DIR="$test_root/persist"
XRAY_BIN="$test_root/core"
XRAY_SHARE_DIR="$tmpdir/share"
mkdir -p "$XRAY_SHARE_DIR" && touch "$XRAY_SHARE_DIR/geoip.dat" "$XRAY_SHARE_DIR/geosite.dat"
printf '#!/bin/sh\nexit 0\n' >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
XRAY_CONFIG="$test_root/source.json"
XRAY_CONFIG_BACKUP="$test_root/source.json.bak"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
CONFIG_INVALID_FILE="$PKG_STATE_DIR/config.invalid"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
DEGRADED_FILE="$PKG_STATE_DIR/degraded"
RULES_FILE="$test_root/rules.txt"
POLICY_CACHE_DIR="$test_root/cache"
mkdir -p "$POLICY_CACHE_DIR"
printf 'https://list.example/a proxy\n' >"$RULES_FILE"
printf '1.1.1.0/24\n' >"$(lists_cache_file https://list.example/a)"
DNS_AUTO_RESOLVFILE="$test_root/resolv.auto"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"
echo "$$" >"$SUPERVISOR_PID_FILE"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
FX="$RELOAD_FIXTURES"
cp "$FX/src/single.json" "$XRAY_CONFIG"
uci set network.lan.ipaddr=192.168.8.1/24
inputs="$RUNTIME_CONFIG.inputs"

# The real generator with a counter; key computation is not a generation.
eval "$(sed -n '/^xray_config_generate() {/,/^}/p' "$XRAYWRT_LIB_DIR_REAL/xray-config.sh" |
	sed '1s/xray_config_generate/xray_config_generate_real/')"
xray_config_generate() {
	[ "${3:-}" = key ] || echo gen >>"$test_root/generations"
	xray_config_generate_real "$@"
}
settings_load() { :; }
cron_update() { :; }
service_ready() { return 0; }
service_running() { return 0; }
policy_apply() { echo apply >>"$test_root/events"; }
config_profile_apply() { echo profile_apply >>"$test_root/events"; }
xray_config_test() { echo test >>"$test_root/events"; [ ! -e "$test_root/reject" ]; }
# These existing rows exercise restart rollback; live API paths have their own suite.
xray_api_apply() { return 1; }
core_restart() { echo restart >>"$test_root/events"; [ ! -e "$test_root/restart_fail" ] || return 1; geodata_snapshot || :; }
count() { [ -f "$test_root/$1" ] && wc -l <"$test_root/$1" | tr -d ' ' || echo 0; }
require() { [ "$(count generations)" -eq "$1" ] || { echo "$scenario: expected $1 generations, got $(count generations)" >&2; exit 1; }; }

case "$scenario" in
build_failed_test | install_ok | install_restore) ;;
*)
	service_reload
	require 1
	[ -s "$inputs" ] || { echo 'successful reload stored no key' >&2; exit 1; }
	[ "$(wc -c <"$inputs" | tr -d ' ')" -eq 65 ] || { echo 'key is not one sha256 line' >&2; exit 1; }
	;;
esac

expect=2
case "$scenario" in
same) expect=1 ;;
degraded_source | degraded_rules | degraded_rejected | stopped)
 service_ready() { return 1; }
 [ "$scenario" = stopped ] || touch "$DEGRADED_FILE"
 policy_apply() { echo 'premature policy' >&2; exit 1; }
 if [ "$scenario" = degraded_rules ]; then
  printf 'domain:beta.example core\n' >"$RULES_FILE"
 else
  sed -i 's/"port": 443/"port": 8443/' "$XRAY_CONFIG"
 fi
 case "$scenario" in
 stopped) service_running() { return 1; } ;;
 degraded_rejected) touch "$test_root/reject" ;;
 esac
 rc=0
 service_reload || rc=$?
 case "$scenario" in
 stopped) require 1 ;;
 degraded_rejected) [ "$rc" -eq 1 ]; require 2; grep -q '443' "$RUNTIME_CONFIG" ;;
 *) [ "$rc" -eq 0 ]; require 2
  if [ "$scenario" = degraded_rules ]; then grep -q beta.example "$RUNTIME_CONFIG"; else grep -q 8443 "$RUNTIME_CONFIG"; fi ;;
 esac
 exit 0
 ;;
source) sed -i 's/"port": 443/"port": 8443/' "$XRAY_CONFIG" ;;
uc_file) printf '\n// changed\n' >>"$XRAYWRT_LIB_DIR/xray-config.uc" ;;
rules) printf 'domain:example.org core\n' >"$RULES_FILE" ;;
# A fetched list that feeds a routing rule is a generator input.
remote_list) printf '2.2.2.0/24\n' >"$(lists_cache_file https://list.example/a)" ;;
wan_dns) printf 'nameserver 192.0.2.54\n' >"$DNS_AUTO_RESOLVFILE" ;;
dns_port) XRAY_DNS_PORT=7000 ;;
fakeip) FAKEIP_RANGE=198.20.0.0/15 ;;
tproxy) XRAY_TPROXY_PORT=7001 ;;
direct_tproxy) XRAY_DIRECT_TPROXY_PORT=7002 ;;
mark) XRAY_ROUTING_MARK=3 ;;
mode) UCI_MODE=direct-first ;;
log_level) UCI_CORE_LOG_LEVEL=error; LOG_LEVEL_OVERRIDE=1 ;;
runtime_missing) rm -f "$RUNTIME_CONFIG" ;;
profile_missing) rm -f "$PROFILE_FILE" ;;
no_key)
 # Fail only the generator library hash: URL cache names and generation still work.
 sha256sum() {
  [ "$#" -eq 0 ] || { command sha256sum "$@"; return; }
  data="$(cat; printf x)"; data="${data%x}"
  case "$data" in *'function group_rule_runs'*) return 1 ;; esac
  printf '%s' "$data" | command sha256sum "$@"
 }
 ;;
reuse)
 eval "$(sed -n '/^lists_rules_remote_pairs() {/,/^}/p' "$XRAYWRT_LIB_DIR_REAL/lists.sh" | sed '1s/lists_rules_remote_pairs/lists_rules_remote_pairs_real/')"
 eval "$(sed -n '/^xray_params_json() {/,/^}/p' "$XRAYWRT_LIB_DIR_REAL/xray-config.sh" | sed '1s/xray_params_json/xray_params_json_real/')"
 lists_rules_remote_pairs() { echo pairs >>"$test_root/captures"; lists_rules_remote_pairs_real; }
 xray_params_json() { echo params >>"$test_root/captures"; xray_params_json_real; }
 xray_config_generate() {
  if [ "${3:-}" = key ]; then
   printf '%s' "$4" >"$test_root/key.params"
  else
   echo gen >>"$test_root/generations"
   printf '%s' "$4" >"$test_root/gen.params"
  fi
  xray_config_generate_real "$@"
 }
 # Force generation, then ensure both paths consume exactly one snapshot.
 rm -f "$RUNTIME_CONFIG"
 ;;
restart_failure)
	# A core that does not restart rolls back: the key must not claim the rolled-back config.
	sed -i 's/"port": 443/"port": 8443/' "$XRAY_CONFIG"
	touch "$test_root/restart_fail"
	rc=0
	service_reload 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ] || { echo 'failed reload was not reported' >&2; exit 1; }
	[ ! -e "$inputs" ] || { echo 'rollback left a stale key' >&2; exit 1; }
	rm -f "$test_root/restart_fail"
	require 2
	service_reload
	require 3
	[ -s "$inputs" ]
	service_reload
	require 3
	exit 0
	;;
test_rejected)
	# A rejected candidate leaves the live config and its key; the old inputs still skip.
	sed -i 's/"port": 443/"port": 8443/' "$XRAY_CONFIG"
	touch "$test_root/reject"
	rc=0
	service_reload 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ]
	require 2
	service_reload 2>/dev/null || :
	require 3
	exit 0
	;;
build_failed_test)
	# Start path: runtime_config_build stores the key only after the core test passed.
	touch "$test_root/reject"
	rc=0
	runtime_config_build "$RUNTIME_CONFIG" 2>/dev/null || rc=$?
	[ "$rc" -eq 1 ]
	[ ! -e "$inputs" ] || { echo 'rejected config kept a key' >&2; exit 1; }
	rm "$test_root/reject"
	runtime_config_build "$RUNTIME_CONFIG"
	geodata_snapshot # Model the subsequent core spawn.
	[ -s "$inputs" ] || { echo 'start stored no key' >&2; exit 1; }
	: >"$test_root/events"
	service_reload
	require 2
	[ "$(cat "$test_root/events")" = apply ] || { echo 'reload after start was not policy-only' >&2; exit 1; }
	exit 0
	;;
install_ok | install_restore)
	XRAY_CONFIG_BACKUP="$test_root/backup"
	service_reload
	[ -s "$inputs" ] || { echo 'reload stored no key' >&2; exit 1; }
	sed 's/"port": 443/"port": 8443/' "$XRAY_CONFIG" >"$test_root/upload.json"
	[ "$scenario" = install_ok ] || touch "$test_root/restart_fail"
	rc=0
	config_install "$test_root/upload.json" >/dev/null 2>&1 || rc=$?
	if [ "$scenario" = install_restore ]; then
		[ "$rc" -eq 1 ]
		[ ! -e "$inputs" ] || { echo 'restore left a stale key' >&2; exit 1; }
		cmp -s "$XRAY_CONFIG" "$FX/src/single.json" || { echo 'restore did not bring back the config' >&2; exit 1; }
		rm "$test_root/restart_fail"
		service_reload
		[ "$(count generations)" -eq 3 ] || { echo 'restored config was not regenerated' >&2; exit 1; }
	else
		[ "$rc" -eq 0 ]
		[ -s "$inputs" ] || { echo 'install stored no key' >&2; exit 1; }
		service_reload
		[ "$(count generations)" -eq 2 ] || { echo 'reload after install regenerated' >&2; exit 1; }
	fi
	exit 0
	;;
esac

: >"$test_root/events"
rc=0
service_reload || rc=$?
[ "$rc" -eq 0 ]
require "$expect"
if [ "$scenario" = reuse ]; then
 [ "$(cat "$test_root/captures")" = "$(printf 'pairs\nparams')" ] || { echo 'inputs captured more than once' >&2; exit 1; }
 cmp -s "$test_root/key.params" "$test_root/gen.params" || { echo 'key and generator used different params' >&2; exit 1; }
fi
if [ "$scenario" = no_key ]; then
 [ ! -e "$inputs" ] || { echo 'failed key was stored' >&2; exit 1; }
fi
if [ "$scenario" = same ]; then
	[ "$(cat "$test_root/events")" = apply ] || { echo 'unchanged reload did more than apply policy' >&2; exit 1; }
else
	# Identical output needs only the policy apply; changed output is tested and restarted first.
	[ "$(tail -n 1 "$test_root/events")" = apply ] || { echo "$scenario did not apply policy" >&2; exit 1; }
fi
ASH
	then pass "service reload generation skip: $scenario"; else failed=1; fi
done

# Every router parameter the generator reads must come from xray_params_json,
# whose output is part of the generation key.
uc_params="$(grep -oE 'params\.[a-z_]+' "$ROOT_DIR/rootfs/usr/lib/xraywrt/xray-config.uc" | sed 's/^params\.//' | sort -u)"
sh_params="$(sed -n '/^xray_params_json() {/,/^}/p' "$ROOT_DIR/rootfs/usr/lib/xraywrt/xray-config.sh" | grep -oE -- '--arg(json)? [a-z_]+' | awk '{ print $2 }' | sort -u)"
if [ -n "$uc_params" ] && [ "$uc_params" = "$sh_params" ]; then pass 'generator key covers every generator parameter'; else
	echo "FAIL: generator parameters differ: uc=[$uc_params] sh=[$sh_params]" >&2
	failed=1
fi
exit "$failed"
