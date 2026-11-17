#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
cleanup() {
 local rc=$?
 if [ "$rc" -ne 0 ]; then cat "$tmpdir/live/err" 2>/dev/null || :; fi
 rm -rf "$tmpdir"
}
trap cleanup EXIT
export RECOVERY_TEST_DIR="$tmpdir"
ash <<'ASH'
set -eu
for m in constants helpers validate service; do . "$XRAYWRT_LIB_DIR/$m.sh"; done
PKG_STATE_DIR="$RECOVERY_TEST_DIR"
SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
USER_STOP_FILE="$PKG_STATE_DIR/stopped"
DEGRADED_FILE="$PKG_STATE_DIR/degraded"
RUNNING_MARKER="$PKG_STATE_DIR/running"
LAST_ERROR_FILE="$PKG_STATE_DIR/error"
APPLY_WARNING_FILE="$PKG_STATE_DIR/apply-warning"
echo $$ >"$SUPERVISOR_PID_FILE"
echo dns >"$DEGRADED_FILE"
settings_load() { :; }
service_running() { return 0; }
runtime_refresh() { echo beta >"$PKG_STATE_DIR/runtime"; }
policy_reapply_ready() { grep -qx beta "$PKG_STATE_DIR/runtime"; touch "$RUNNING_MARKER"; }
service_recovery_reload $$
[ -f "$RUNNING_MARKER" ] && [ ! -e "$DEGRADED_FILE" ]
rm "$RUNNING_MARKER"
echo dns >"$DEGRADED_FILE"
runtime_refresh() { touch "$USER_STOP_FILE"; }
service_recovery_reload $$
[ ! -e "$RUNNING_MARKER" ] && [ -e "$DEGRADED_FILE" ]
rm "$USER_STOP_FILE"
runtime_refresh() { return 1; }
service_recovery_reload $$
[ -e "$RUNNING_MARKER" ] && [ ! -e "$DEGRADED_FILE" ]
[ "$(cat "$RUNNING_MARKER")" = "$$" ]
grep -q '\[E:recovery_inputs' "$APPLY_WARNING_FILE"
rm "$RUNNING_MARKER"
echo dns >"$DEGRADED_FILE"
runtime_refresh() { return 2; }
service_recovery_reload $$
[ -e "$RUNNING_MARKER" ] && [ ! -e "$DEGRADED_FILE" ]
rm "$RUNNING_MARKER"
# A stale recovery from an older supervisor cannot apply to a new instance.
echo 999999 >"$SUPERVISOR_PID_FILE"
service_recovery_reload $$
[ ! -e "$RUNNING_MARKER" ]
ASH
pass 'recovery validates current runtime, rejects candidates, and respects Stop and supervisor identity'

# Exercise the real external scheduler: only one worker, no inherited locks.
ash <<'ASH'
set -eu
for m in constants helpers validate service; do . "$XRAYWRT_LIB_DIR/$m.sh"; done
PKG_STATE_DIR="$RECOVERY_TEST_DIR"
XRAYWRT_CLI="$PKG_STATE_DIR/cli"
cat >"$XRAYWRT_CLI" <<'CLI'
#!/bin/ash
for fd in 6 8 9; do [ ! -e "/proc/$$/fd/$fd" ] || exit 1; done
printf '%s\n' "$*" >>"$RECOVERY_TEST_DIR/calls"
sleep 0.2
CLI
chmod +x "$XRAYWRT_CLI"
SUPERVISOR_CMD="$XRAYWRT_CLI run-service"
exec 6>>"$PKG_STATE_DIR/lock6"
exec 8>>"$PKG_STATE_DIR/lock8"
exec 9>>"$PKG_STATE_DIR/lock9"
recovery_pid=""
service_recovery_schedule
service_recovery_schedule
wait "$recovery_pid"
[ "$(wc -l <"$PKG_STATE_DIR/calls")" -eq 1 ]
grep -q '^recover-runtime ' "$PKG_STATE_DIR/calls"
ASH
pass 'external recovery coalesces and closes inherited descriptors'

# Real ash supervisor + CLI dispatch + runtime_refresh/publish/core_restart.
# Only the core and router policy primitives are fixtures.
export RECOVERY_ROOT="$ROOT_DIR"
ash <<'ASH'
set -eu
root="$RECOVERY_TEST_DIR/live"
mkdir -p "$root"
export RECOVERY_LIVE="$root"
cat >"$root/setup" <<'SETUP'
PKG_TMP_DIR="$RECOVERY_LIVE/tmp"
PKG_STATE_DIR="$RECOVERY_LIVE/run"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"
set_paths() {
for entry in 'SERVICE_PID_FILE core.pid' 'SUPERVISOR_PID_FILE supervisor.pid' 'RESTART_RESULT_FILE restart' 'RUNNING_MARKER running' 'USER_STOP_FILE stopped' 'HEALTH_FILE health' 'DEGRADED_FILE degraded' 'LAST_ERROR_FILE error' 'RUNTIME_LOCK_FILE lock' 'OBSERVATORY_FILE observatory' 'CONFIG_OK_FILE config.ok' 'CONFIG_ERR_FILE config.err'; do
 set -- $entry; eval "$1=\"$PKG_STATE_DIR/$2\""
done
}
set_paths
XRAY_CONFIG="$RECOVERY_LIVE/source"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
XRAY_BIN="$RECOVERY_LIVE/core"
SUPERVISOR_CMD="$RECOVERY_LIVE/cli run-service"
WATCHDOG_INTERVAL=0.05
WATCHDOG_FAILS=1
CORE_READY_WAIT=5
settings_load() { :; }
cron_update() { :; }
service_running() { kill -0 "$(cat "$SERVICE_PID_FILE" 2>/dev/null)" 2>/dev/null; }
xray_config_key() { sha256sum "$XRAY_CONFIG" | cut -d' ' -f1; }
xray_config_generate() { cp "$1" "$2"; echo profile >"$2.profile"; }
xray_config_test() { :; }
geodata_snapshot() { :; }
geodata_unchanged() { [ ! -f "$RECOVERY_LIVE/allow-refresh" ]; }
balancer_overrides_apply() { :; }
watchdog_observatory_ok() { :; }
wait_for_ready() { :; }
dns_probe() { [ -f "$RECOVERY_LIVE/healthy" ]; }
policy_apply() { cat "$RUNTIME_CONFIG" >>"$RECOVERY_LIVE/applied"; }
policy_cleanup() { :; }
nft_fw4_input_cleanup() { :; }
SETUP
{
 echo '#!/bin/ash'
 echo 'for fd in 6 8 9; do [ ! -e "/proc/$$/fd/$fd" ] || touch "$RECOVERY_LIVE/leaked"; done'
 echo '. "$XRAYWRT_LIB_DIR/constants.sh"; . "$XRAYWRT_LIB_DIR/helpers.sh"; xraywrt_load_modules'
 echo '. "$RECOVERY_LIVE/setup"'
 sed -n '/^service_reload() {/,/^}/p' "$XRAYWRT_LIB_DIR/service.sh" | sed '1s/service_reload/service_reload_real/'
 echo 'service_reload() { service_reload_real; rc=$?; touch "$RECOVERY_LIVE/reload-done"; return "$rc"; }'
 sed '1,/^usage() {/d' "$RECOVERY_ROOT/rootfs/usr/bin/xraywrt" | sed '1i usage() {'
} >"$root/cli"
cat >"$root/core" <<'CORE'
#!/bin/ash
cat "$3" >>"$RECOVERY_LIVE/spawns"
exec sleep 30
CORE
chmod +x "$root/cli" "$root/core"
. "$root/setup"
echo alpha >"$XRAY_CONFIG"
cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
xray_config_key "$XRAY_CONFIG" >"$RUNTIME_CONFIG.inputs"
echo profile >"$PROFILE_FILE"
"$root/cli" run-service >"$root/out" 2>"$root/err" &
sup=$!
trap 'kill -TERM "$sup" 2>/dev/null; wait "$sup" 2>/dev/null || :' EXIT
await_file() { i=0; while [ ! -f "$1" ] && [ "$i" -lt 200 ]; do sleep 0.02; i=$((i+1)); done; [ -f "$1" ]; }
await_file "$DEGRADED_FILE"
await_file "$root/reload-done"
touch "$root/allow-refresh"
echo beta >"$XRAY_CONFIG"
"$root/cli" reload
[ "$(cat "$RUNTIME_CONFIG")" = beta ]
[ ! -e "$RUNNING_MARKER" ]
[ "$(sort -u "$root/applied")" = alpha ]
applied_before="$(wc -l <"$root/applied")"
# Recovery must validate even an input changed without a preceding reload.
echo gamma >"$XRAY_CONFIG"
touch "$root/healthy"
await_file "$RUNNING_MARKER"
[ "$(cat "$RUNTIME_CONFIG")" = gamma ]
[ "$(tail -n1 "$root/applied")" = gamma ]
[ ! -e "$root/leaked" ]
[ "$(wc -l <"$root/spawns")" -eq 3 ]
# A recovery already queued behind another reload must not undo explicit Stop.
exec 9>>"$RUNTIME_LOCK_FILE"
flock 9
rm "$RUNNING_MARKER"
echo dns >"$DEGRADED_FILE"
"$root/cli" recover-runtime "$sup" 9>&- &
worker=$!
sleep 0.1
touch "$USER_STOP_FILE"
flock -u 9
exec 9>&-
wait "$worker"
[ ! -e "$RUNNING_MARKER" ]
[ "$(wc -l <"$root/applied")" -eq "$((applied_before + 1))" ]
kill -TERM "$sup"
wait "$sup"
trap - EXIT
[ ! -e "$SERVICE_PID_FILE" ] && [ ! -e "$RUNNING_MARKER" ]
ASH
pass 'live degraded CLI reload and external recovery publish latest inputs without self-USR1 wait'

(
 load_modules constants.sh helpers.sh validate.sh lists.sh dns.sh service.sh
 setup_runtime_paths "$tmpdir/callers"
 service_running() { return 0; }
 service_ready() { return 1; }
 settings_load() { :; }
 lists_install() { echo 1; }
 lists_update_remote() { :; }
 service_reload() { touch "$tmpdir/list-reloaded"; }
 nft_apply_if_ready() { fail 'degraded rules must use runtime reload'; }
 lists_apply /tmp/xraywrt-policy-list.changed - - >"$tmpdir/startup-result"
 assert_false 'startup lists cannot request restart' test -e "$tmpdir/list-reloaded"
 assert_eq starting "$(jq -r .pending_reason "$tmpdir/startup-result")" 'startup is not reported as degraded'
 dns_wan_servers() { echo 192.0.2.53; }
 route_ipv6_enabled() { return 1; }
 nft_connected_prefixes() { :; }
 nft_active() { return 0; }
 dns_apply() { fail 'degraded DNS refresh must not apply policy'; }
 route_setup() { fail 'degraded DNS refresh must not apply routes'; }
 nft_apply() { fail 'degraded DNS refresh must not apply nft'; }
 printf 'uses-wan-dns\n' >"$PROFILE_FILE"
 runtime_refresh() { fail 'startup WAN DNS cannot request restart'; }
 net_refresh
 touch "$DEGRADED_FILE"
 lists_apply /tmp/xraywrt-policy-list.changed - - >/dev/null
 assert_true 'degraded My rules call reload' test -e "$tmpdir/list-reloaded"
 # WAN DNS changes also refresh the live runtime, never policy while degraded.
 runtime_refresh() { touch "$tmpdir/dns-refreshed"; }

 net_refresh
 assert_true 'degraded WAN DNS refresh reaches runtime' test -e "$tmpdir/dns-refreshed"
)
pass 'degraded domain-list and WAN-DNS callers update runtime without policy'

(
 load_modules constants.sh helpers.sh validate.sh lists.sh service.sh
 setup_runtime_paths "$tmpdir/list-outcomes"
 lists_install() { echo 1; }
 settings_load() { :; }
 lists_update_remote() { echo changed; }
 service_ready() { return 1; }
 service_running() { return 1; }
 lists_apply - - - - >"$tmpdir/list-result"
 assert_eq saved "$(jq -r .apply_status "$tmpdir/list-result")" 'stopped lists are saved, not applied'
 service_running() { return 0; }
 touch "$DEGRADED_FILE"
 lists_apply - - - - >"$tmpdir/list-result"
 assert_eq degraded "$(jq -r .pending_reason "$tmpdir/list-result")" 'degraded list waiting is not an error'
 service_ready() { return 0; }
 nft_apply_if_ready() { return 1; }
 lists_apply - - - - >"$tmpdir/list-result"
 assert_eq partial "$(jq -r .apply_status "$tmpdir/list-result")" 'published lists report failed policy as partial'
 assert_true 'list partial persists warning' test -s "$APPLY_WARNING_FILE"
)
pass 'list outcomes distinguish waiting from failed application'

# Persistent policy failure must earn three new healthy probes before retry.
(
 load_modules constants.sh helpers.sh validate.sh service.sh
 setup_runtime_paths "$tmpdir/backoff"
 RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
 echo '{}' >"$RUNTIME_CONFIG"
 WATCHDOG_INTERVAL=0.001
 WATCHDOG_FAILS=1
 probe_count=0
 settings_load() { :; }
 wait_for_ready() { :; }
 core_spawn() { sleep 30 9>&- & pid=$!; }
 balancer_overrides_apply() { :; }
 policy_reapply_ready() { :; }
 policy_cleanup() { :; }
 nft_fw4_input_cleanup() { :; }
 with_lock() { "$@"; }
 lock_busy() { return 1; }
 lock_acquire() { :; }
 lock_release() { :; }
 watchdog_observatory_ok() { :; }
 dns_probe() {
  probe_count=$((probe_count + 1))
  [ "$probe_count" -ne 12 ] || { stop=1; return 1; }
  [ "$probe_count" -gt 1 ]
 }
 service_recovery_schedule() { echo "$probe_count" >>"$tmpdir/retries"; }
 run_service || fail 'backoff supervisor must stop normally'
 assert_eq $'4\n7\n10' "$(cat "$tmpdir/retries")" 'failed recovery waits three fresh healthy cycles before retry'
)
pass 'persistent policy failure backs off recovery validation'
