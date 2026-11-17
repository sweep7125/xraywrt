#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh xray-config.sh xray-api.sh service.sh
setup_runtime_paths "$tmpdir"
RUNTIME_CONFIG="$tmpdir/runtime.json"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
export OBS_TEST_DIR="$tmpdir"
XRAY_BIN="$tmpdir/xray"
cat >"$XRAY_BIN" <<'SH'
#!/bin/sh
[ "$1" != run ] || exec sleep 30
printf '%s\n' "$*" >>"$OBS_TEST_DIR/api.calls"
for tag do :; done
[ ! -e "$OBS_TEST_DIR/$tag.error" ] || exit 1
cat "$OBS_TEST_DIR/$tag.json"
SH
chmod +x "$XRAY_BIN"
live='{"balancer":{"principleTarget":{"tag":["node"]}}}'
empty='{"balancer":{"principleTarget":{"tag":[""]}}}'
printf 'observe-balancer a\nobserve-balancer b\n' >"$PROFILE_FILE"
printf '%s\n' "$empty" | tee "$tmpdir/a.json" >"$tmpdir/b.json"
assert_true 'startup empty observations are not a failure' watchdog_observatory_ok
assert_false 'startup has no observatory signal' test -f "$OBSERVATORY_FILE"
printf '%s\n' "$live" >"$tmpdir/a.json"
assert_true 'one live balancer is enough' watchdog_observatory_ok
assert_true 'live observation arms the signal' test -f "$OBSERVATORY_FILE"
printf '%s\n' "$empty" >"$tmpdir/a.json"
assert_false 'all empty after a live observation is failure' watchdog_observatory_ok
printf '{"balancer":{"principleTarget":{"tag":[]}}}\n' >"$tmpdir/a.json"
assert_false 'empty array also means no target' watchdog_observatory_ok
printf '{"balancer":{"override":{},"principleTarget":{}}}\n' | tee "$tmpdir/a.json" >"$tmpdir/b.json"
assert_false 'core omits the empty tag list: no target' watchdog_observatory_ok
printf '%s\n' "$empty" >"$tmpdir/b.json"
touch "$tmpdir/b.error"
assert_true 'API failure is no data, not failure' watchdog_observatory_ok
rm "$tmpdir/b.error"
for bad in '{}' '{"balancer":{}}' '{"balancer":{"principleTarget":{"tag":"bad"}}}' '{"balancer":{"principleTarget":{"tag":[null]}}}' 'invalid'; do
 printf '%s\n' "$bad" >"$tmpdir/b.json"
 assert_true 'malformed or missing targets are no data' watchdog_observatory_ok
done
: >"$PROFILE_FILE"
: >"$tmpdir/api.calls"
assert_true 'no profile signal is healthy' watchdog_observatory_ok
assert_eq '' "$(cat "$tmpdir/api.calls")" 'no API calls without observed balancers'
assert_false 'no balancers clears signal' test -f "$OBSERVATORY_FILE"
pass 'observatory signal needs a live observation; API failures are neutral'

# One ucode start per balancer check: the core's answer is parsed once.
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "$1" >>"%s/json.calls"\nexec "%s/rootfs/usr/bin/xraywrt-json" "$@"\n' "$tmpdir" "$ROOT_DIR" >"$tmpdir/bin/xraywrt-json"
chmod +x "$tmpdir/bin/xraywrt-json"
printf 'observe-balancer a\nobserve-balancer b\n' >"$PROFILE_FILE"
printf '%s\n' "$live" | tee "$tmpdir/a.json" >"$tmpdir/b.json"
: >"$tmpdir/json.calls"
PATH="$tmpdir/bin:$PATH" watchdog_observatory_ok || fail 'live balancers are healthy'
assert_eq $'observatory-target\nobservatory-target' "$(cat "$tmpdir/json.calls")" 'one ucode start per balancer'
pass 'observatory check starts ucode once per balancer'

# Real supervisor: startup empties, live, three failures, three recovery cycles.
for scenario in observatory dns; do
 (
  printf 'observe-balancer a\n' >"$PROFILE_FILE"
  printf '%s\n' "$live" >"$tmpdir/a.json"
  touch "$OBSERVATORY_FILE" # A previous core run must not arm this one.
  printf '{}\n' >"$RUNTIME_CONFIG"
  WATCHDOG_INTERVAL=0.01
  WATCHDOG_FAILS=3
  WATCHDOG_OBSERVE_TICKS=1
  count=0
  settings_load() { :; }
  balancer_overrides_apply() { :; }
  wait_for_ready() { :; }
  service_recovery_schedule() { policy_reapply_ready && rm -f "$DEGRADED_FILE"; }
  policy_reapply_ready() { echo apply >>"$tmpdir/$scenario.events"; }
  policy_cleanup() {
   [ ! -f "$DEGRADED_FILE" ] || printf '%s\n' "$(cat "$DEGRADED_FILE")" >>"$tmpdir/$scenario.events"
  }
  nft_fw4_input_cleanup() { :; }
  dns_probe() {
   count=$((count + 1))
   case "$count" in
    1) assert_false 'new core forgets previous live observation' test -f "$OBSERVATORY_FILE" ;;
    4) assert_eq apply "$(cat "$tmpdir/$scenario.events")" 'startup empties do not degrade' ;;
    8) assert_eq "$scenario" "$(cat "$DEGRADED_FILE")" 'three bad cycles publish scenario before cleanup' ;;
    10) assert_true 'two good cycles do not recover' test -f "$DEGRADED_FILE" ;;
    11) assert_false 'three good cycles restore policy' test -f "$DEGRADED_FILE"; stop=1 ;;
   esac
   if [ "$count" -le 3 ] || { [ "$scenario" = observatory ] && [ "$count" -ge 5 ] && [ "$count" -le 7 ]; }; then
    printf '%s\n' "$empty" >"$tmpdir/a.json"
   else
    printf '%s\n' "$live" >"$tmpdir/a.json"
   fi
   [ "$scenario" != dns ] || [ "$count" -lt 5 ] || [ "$count" -gt 7 ]
  }
  run_service || fail 'supervisor must stop normally'
  assert_eq "$(printf 'apply\n%s\napply' "$scenario")" "$(cat "$tmpdir/$scenario.events")" 'degrade and recover once'
  assert_false 'stop clears observatory signal' test -f "$OBSERVATORY_FILE"
 )
done
pass 'watchdog observes provider checks and DNS, degrades and restores in three cycles'

# A healthy observatory is read every 4th tick; a failing one every tick until it is healthy again.
(
 printf 'observe-balancer a\n' >"$PROFILE_FILE"
 printf '%s\n' "$live" >"$tmpdir/a.json"
 rm -f "$OBSERVATORY_FILE" "$DEGRADED_FILE" "$tmpdir/ticks.log"
 : >"$tmpdir/api.calls"
 printf '{}\n' >"$RUNTIME_CONFIG"
 WATCHDOG_INTERVAL=0.01
 WATCHDOG_FAILS=3
 WATCHDOG_OBSERVE_TICKS=4
 count=0
 settings_load() { :; }
 balancer_overrides_apply() { :; }
 wait_for_ready() { :; }
 service_recovery_schedule() { policy_reapply_ready && rm -f "$DEGRADED_FILE"; }
 policy_reapply_ready() { :; }
 policy_cleanup() { :; }
 nft_fw4_input_cleanup() { :; }
 dns_probe() {
  count=$((count + 1))
  wc -l <"$tmpdir/api.calls" | tr -d ' ' >>"$tmpdir/ticks.log"
  case "$count" in 5 | 6 | 7) printf '%s\n' "$empty" >"$tmpdir/a.json" ;; *) printf '%s\n' "$live" >"$tmpdir/a.json" ;; esac
  [ "$count" -lt 11 ] || stop=1
 }
 run_service || fail 'supervisor must stop normally'
 assert_eq '0 1 1 1 1 2 3 4 5 6 7' "$(tr '\n' ' ' <"$tmpdir/ticks.log" | sed 's/ $//')" 'API calls before each tick: every 4th while healthy, every tick after a failure and while degraded'
 assert_eq 8 "$(wc -l <"$tmpdir/api.calls" | tr -d ' ')" 'observatory reads in 11 ticks'
)
pass 'watchdog reads a healthy observatory every 4th tick, a failing one every tick'

source "$ROOT_DIR/tests/xray_gen_lib.sh"
for section in observatory burstObservatory; do
 src_json '{"outbounds":[{"tag":"direct","protocol":"freedom"}],"'"$section"'":{},"routing":{"balancers":[{"tag":"ping","strategy":{"type":"leastPing"}},{"tag":"load","strategy":{"type":"leastLoad"}},{"tag":"random","strategy":{"type":"random"}},{"tag":"round","strategy":{"type":"roundRobin"}}]}}'
 gen "$tmpdir/src.json"
 # shellcheck disable=SC2154 # gen sets rc and errtxt.
 assert_eq 0 "$rc" "generate observation profile: $errtxt"
 prof_has 'observe-balancer ping'
 prof_has 'observe-balancer load'
 prof_lacks 'observe-balancer random'
 prof_lacks 'observe-balancer round'
done
src_json '{"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"balancers":[{"tag":"ping","strategy":{"type":"leastPing"}}]}}'
gen "$tmpdir/src.json"
prof_lacks 'observe-balancer ping'
pass 'generator profiles only provider-observed leastPing and leastLoad balancers'

# Balancer tags cross the line-oriented profile boundary.
src_json '{"outbounds":[{"protocol":"freedom"}],"observatory":{},"routing":{"balancers":[{"tag":"bad\nmode direct-first","strategy":{"type":"leastPing"}}]}}'
gen "$tmpdir/src.json"
# shellcheck disable=SC2154 # gen sets prof.
assert_false 'control characters cannot inject observation profile lines' grep -q '^observe-balancer ' <<<"$prof"
pass 'observation profile skips unsafe balancer tags'
