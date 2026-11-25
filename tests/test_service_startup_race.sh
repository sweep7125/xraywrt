#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
export RECOVERY_TEST_DIR="$tmpdir" RECOVERY_ROOT="$ROOT_DIR" PROBE="${PROBE:-startup}"
cases=(startup early reject)
[ $# -eq 0 ] || cases=("$@")
for PROBE in "${cases[@]}"; do
export PROBE
ash <<'ASH'
set -eu
root="$RECOVERY_TEST_DIR/live"; mkdir -p "$root"; export RECOVERY_LIVE="$root"
cat >"$root/setup" <<'SETUP'
PKG_TMP_DIR="$RECOVERY_LIVE/tmp"; PKG_STATE_DIR="$RECOVERY_LIVE/run"; mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"
set_paths() {
for entry in 'SERVICE_PID_FILE core.pid' 'SUPERVISOR_PID_FILE supervisor.pid' 'RESTART_RESULT_FILE restart' 'RUNNING_MARKER running' 'USER_STOP_FILE stopped' 'HEALTH_FILE health' 'DEGRADED_FILE degraded' 'LAST_ERROR_FILE error' 'RUNTIME_LOCK_FILE lock' 'OBSERVATORY_FILE observatory' 'CONFIG_OK_FILE config.ok' 'CONFIG_ERR_FILE config.err' 'APPLY_WARNING_FILE warn'; do
 set -- $entry; eval "$1=\"$PKG_STATE_DIR/$2\""; done
}
set_paths
XRAY_CONFIG="$RECOVERY_LIVE/source"; RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"; PROFILE_FILE="$RUNTIME_CONFIG.profile"
XRAY_BIN="$RECOVERY_LIVE/core"; SUPERVISOR_CMD="$RECOVERY_LIVE/cli run-service"
RUNTIME_LOCK_TIMEOUT=15; WATCHDOG_INTERVAL=0.05; WATCHDOG_FAILS=1; CORE_READY_WAIT=3
core_version() { echo test; }
settings_load() { :; }; cron_update() { :; }
service_running() { local core_pid; core_pid="$(cat "$SERVICE_PID_FILE" 2>/dev/null)" || return 1; [ -n "$core_pid" ] && kill -0 "$core_pid" 2>/dev/null; }
xray_config_key() { if [ "$PROBE" = early ]; then uci_get core_log_level | sha256sum | cut -d' ' -f1; else sha256sum "$XRAY_CONFIG" | cut -d' ' -f1; fi; }
xray_config_generate() { echo gen >>"$RECOVERY_LIVE/generations"; if [ "$PROBE" = early ]; then uci_get core_log_level >"$2"; else cp "$1" "$2"; fi; echo profile >"$2.profile"; }
xray_config_test() { echo test >>"$RECOVERY_LIVE/tests"; ! grep -q bad "$1"; }
config_check_record() { :; }
geodata_snapshot() { :; }; geodata_unchanged() { [ "$PROBE" = reject ]; }; balancer_overrides_apply() { :; }
watchdog_observatory_ok() { :; }
wait_for_ready() { [ "$PROBE" = reject ] || sleep 2; :; }
dns_probe() { [ -f "$RECOVERY_LIVE/healthy" ]; }
policy_apply() { cat "$RUNTIME_CONFIG" >>"$RECOVERY_LIVE/applied"; }
policy_cleanup() { :; }; nft_fw4_input_cleanup() { :; }
SETUP
{ echo '#!/bin/ash'
 echo '. "$XRAYWRT_LIB_DIR/constants.sh"; . "$XRAYWRT_LIB_DIR/helpers.sh"; xraywrt_load_modules'
 echo '. "$RECOVERY_LIVE/setup"'
 if [ "$PROBE" = early ]; then
   sed -n '/^core_spawn() {/,/^}/p' "$XRAYWRT_LIB_DIR/service.sh" | sed '1s/core_spawn/core_spawn_real/'
   echo 'core_spawn() { touch "$RECOVERY_LIVE/before-pid"; while [ ! -f "$RECOVERY_LIVE/continue" ]; do sleep 0.02; done; core_spawn_real; }'
 fi
 sed '1,/^usage() {/d' "$RECOVERY_ROOT/rootfs/usr/bin/xraywrt" | sed '1i usage() {'
} >"$root/cli"
printf '#!/bin/ash\ncat "$3" >>"$RECOVERY_LIVE/spawns"\nexec sleep 30\n' >"$root/core"
chmod +x "$root/cli" "$root/core"
. "$root/setup"
echo alpha >"$XRAY_CONFIG"; cp "$XRAY_CONFIG" "$RUNTIME_CONFIG"
[ "$PROBE" != early ] || { uci set xraywrt.settings.core_log_level=alpha; uci commit xraywrt; }
if [ "$PROBE" = reject ]; then xray_config_key "$XRAY_CONFIG" >"$RUNTIME_CONFIG.inputs"; echo profile >"$PROFILE_FILE"; fi
[ "$PROBE" = reject ] || touch "$root/healthy"
"$root/cli" run-service >"$root/out" 2>"$root/err" &
sup=$!
trap 'touch "$root/continue"; kill -TERM "$sup" 2>/dev/null; wait "$sup" 2>/dev/null || :' EXIT
if [ "$PROBE" != reject ]; then
  if [ "$PROBE" = early ]; then
    i=0; while [ ! -f "$root/before-pid" ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
    [ -f "$root/before-pid" ] && [ ! -f "$SERVICE_PID_FILE" ]
  else
    sleep 0.5
    service_running && [ ! -f "$RUNNING_MARKER" ]
  fi
  if [ "$PROBE" = early ]; then uci set xraywrt.settings.core_log_level=beta; uci commit xraywrt; else echo beta >"$XRAY_CONFIG"; fi
  s=$(date +%s); rc=0; "$root/cli" reload 2>"$root/reload.err" || rc=$?
  echo "reload rc=$rc took=$(( $(date +%s) - s ))s runtime=$(cat "$RUNTIME_CONFIG")"
  [ "$rc" -eq 0 ] && [ "$(( $(date +%s) - s ))" -lt 2 ]
  [ "$(cat "$RUNTIME_CONFIG")" = alpha ]
  [ ! -s "$root/reload.err" ]
  if [ "$PROBE" = early ]; then
    touch "$root/continue"
  fi
  i=0; while [ ! -f "$RUNNING_MARKER" ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
  [ -f "$RUNNING_MARKER" ]
  # The deferred settings are applied once the core is ready.
  i=0; while [ "$(cat "$RUNTIME_CONFIG")" != beta ] && [ $i -lt 300 ]; do sleep 0.02; i=$((i+1)); done
  echo "spawns:"; cat "$root/spawns"; echo "applied:"; cat "$root/applied"; echo "runtime=$(cat "$RUNTIME_CONFIG")"
  [ "$(cat "$RUNTIME_CONFIG")" = beta ] || { echo "settings not applied after readiness" >&2; exit 1; }
  [ "$(head -n1 "$root/spawns")" = alpha ] && [ "$(head -n1 "$root/applied")" = alpha ]
  i=0; while [ "$(wc -l <"$root/spawns")" -lt 2 ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
  sleep 0.3
  [ "$(wc -l <"$root/spawns")" -eq 2 ] || { echo 'unexpected restart loop' >&2; exit 1; }
else
  i=0; while [ ! -f "$DEGRADED_FILE" ] && [ $i -lt 200 ]; do sleep 0.02; i=$((i+1)); done
  echo bad >"$XRAY_CONFIG"
  "$root/cli" reload 2>/dev/null || echo "reload rejected rc=$?"
  touch "$root/healthy"
  sleep 1
  [ -f "$RUNNING_MARKER" ] && [ ! -e "$DEGRADED_FILE" ]
  [ "$(cat "$RUNNING_MARKER")" = "$sup" ]
  [ "$(wc -l <"$root/tests")" -eq 2 ]
  [ "$(wc -l <"$root/generations")" -eq 2 ]
  grep -q '\[E:recovery_inputs' "$APPLY_WARNING_FILE"
  echo "rejected reload plus recovery: 2 config tests, policy restored on alpha"
  [ "$(tail -n1 "$root/applied")" = alpha ]
fi
ASH
pass "reviewer supervisor probe: $PROBE"
rm -rf "$tmpdir/live"
done
