#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh geodata.sh nft.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
SERVICE_PID_FILE="$PKG_STATE_DIR/pid"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
XRAY_BIN="$tmpdir/core"
printf '#!/bin/sh\nexec sleep 30\n' >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
cp "$ROOT_DIR/tests/fixtures/xray/out/single.proxy-first.json" "$RUNTIME_CONFIG"
settings_load() { :; }
balancer_overrides_apply() { echo reapplied >>"$tmpdir/overrides.calls"; }
policy_cleanup() { :; }
stop_child() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
for scenario in readiness policy; do
 (
  wait_for_ready() { [ "$scenario" != readiness ]; }
  policy_reapply() { err 'nft transaction rejected'; return 1; }
  rc=0
  run_service 2>"$tmpdir/stderr" || rc=$?
  assert_eq 1 "$rc" "$scenario failure is reported"
  if [ "$scenario" = readiness ]; then
   expected='core did not become ready; router stays on direct routing'
  else
   expected='Failed to apply routing rules: nft transaction rejected [E:routing_apply|nft transaction rejected]'
   assert_file_not_contains "$tmpdir/stderr" 'core did not become ready' 'policy error is not a readiness error'
  fi
  assert_eq "$expected" "$(cat "$LAST_ERROR_FILE")" "$scenario failure has its own error"
  assert_file_contains "$tmpdir/stderr" "Error: $expected" "$scenario error passed to stderr"
  assert_false 'startup error temporary file removed' test -e "$LAST_ERROR_FILE.err.$$"
 )
 pass "startup error: $scenario"
done

(
 rm -f "$RUNNING_MARKER" "$tmpdir/overrides.calls"
 applied=0
 marker_at_unlock=no
 eval "$(declare -f lock_release | sed '1s/lock_release/real_lock_release/')"
 lock_release() {
  if [ "$applied" = 1 ]; then
   assert_eq 1 "$LOCK_DEPTH" 'startup policy owns runtime lock'
   [ ! -f "$RUNNING_MARKER" ] || marker_at_unlock=yes
   applied=2
  fi
  real_lock_release
 }
 wait_for_ready() { return 0; }
 policy_reapply() {
  assert_eq 1 "$LOCK_DEPTH" 'startup policy applied inside runtime lock'
  applied=1
 }
 WATCHDOG_INTERVAL=0.01
 dns_probe() {
  if [ ! -f "$tmpdir/requested-restart" ]; then
   touch "$tmpdir/requested-restart"
   restart=1
  else
   stop=1
  fi
  return 0
 }
 run_service
 assert_true 'core start records geodata content' geodata_unchanged
 assert_eq 2 "$(wc -l <"$tmpdir/overrides.calls" | tr -d ' ')" 'overrides applied after startup and in-process restart readiness'
 assert_eq 2 "$applied" 'startup readiness publication checked under lock'
 assert_eq yes "$marker_at_unlock" 'startup marker published before releasing policy lock'
)
pass 'startup marker and policy share runtime lock'

(
 source_init_xraywrt_lib
 setup_runtime_paths "$tmpdir/init"
 SKIP_START_FILE="$tmpdir/init/skip-start"
 XRAYWRT_CLI="$tmpdir/init/cli"
 export INIT_TEST_STATE="$PKG_STATE_DIR"
 cat >"$XRAYWRT_CLI" <<'CLI'
#!/bin/sh
for file in health degraded last_error config.invalid; do
 [ ! -e "$INIT_TEST_STATE/$file" ] || echo "$file" >>"$INIT_TEST_STATE/stale"
done
if [ -f "$INIT_TEST_STATE/reject" ]; then
 : >"$INIT_TEST_STATE/config.invalid"
 echo 'Xray rejected the configuration' >"$INIT_TEST_STATE/last_error"
 exit 1
fi
CLI
 chmod +x "$XRAYWRT_CLI"
 touch "$HEALTH_FILE" "$DEGRADED_FILE" "$LAST_ERROR_FILE" "$CONFIG_INVALID_FILE"
 procd_open_instance() { touch "$PKG_STATE_DIR/launched"; }
 procd_set_param() { :; }
 procd_close_instance() { :; }
 start_service
 assert_false 'start clears stale health/degraded/error before prepare' test -e "$PKG_STATE_DIR/stale"
 assert_false 'start clears health before supervisor launch' test -e "$HEALTH_FILE"
 assert_false 'start clears degraded before supervisor launch' test -e "$DEGRADED_FILE"
 assert_false 'start clears last error before supervisor launch' test -e "$LAST_ERROR_FILE"
 assert_false 'start clears config invalid marker before prepare' test -e "$CONFIG_INVALID_FILE"
 assert_true 'valid configuration launches supervisor' test -f "$PKG_STATE_DIR/launched"
 rm "$PKG_STATE_DIR/launched"
 touch "$PKG_STATE_DIR/reject"
 assert_false 'invalid configuration aborts start' start_service 2>"$tmpdir/prepare.err"
 assert_true 'prepare failure marks configuration invalid' test -f "$CONFIG_INVALID_FILE"
 assert_file_contains "$tmpdir/prepare.err" 'Xray rejected the configuration' 'prepare failure keeps error text'
 assert_false 'invalid configuration never launches supervisor' test -e "$PKG_STATE_DIR/launched"
 rm "$PKG_STATE_DIR/reject"
 printf '#!/bin/sh\necho transient >"$INIT_TEST_STATE/last_error"\nexit 1\n' >"$XRAYWRT_CLI"
 assert_false 'transient prepare failure aborts start' start_service 2>"$tmpdir/prepare.err"
 assert_false 'transient prepare failure does not block hotplug' test -e "$CONFIG_INVALID_FILE"
 printf '#!/bin/sh\nexit 0\n' >"$XRAYWRT_CLI"
 start_service
 assert_false 'manual start clears previous configuration failure' test -e "$CONFIG_INVALID_FILE"
 assert_true 'fixed configuration launches supervisor' test -f "$PKG_STATE_DIR/launched"
)
pass 'start removes stale state and marks only configuration failures'
(
 source_init_xraywrt_lib
 assert_eq /tmp/xraywrt.skip-start "$(busybox ash -c '. "$1"; printf "%s" "$SKIP_START_FILE"' _ "$XRAYWRT_LIB_DIR/constants.sh")" 'new skip-start constant'
 setup_runtime_paths "$tmpdir/skip"
 SKIP_START_FILE="$tmpdir/new.skip-start"
 XRAYWRT_CLI=/bin/false
 touch "$SKIP_START_FILE"
 assert_true 'recent skip marker suppresses prepare' start_service
 assert_false 'skip marker consumed' test -e "$SKIP_START_FILE"
 assert_false 'no legacy skip-start name' grep -rq LEGACY_SKIP_START_FILE "$XRAYWRT_LIB_DIR" "$ROOT_DIR/rootfs/etc/init.d"
)
pass 'skip-start marker supported'
