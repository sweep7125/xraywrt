#!/usr/bin/env bash
# Lost DNS outbound: pure previews, accepted transactions, persistent per-subscription off.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh dns.sh xray-config.sh config.sh subscription.sh service.sh status.sh
FX="$ROOT_DIR/tests/fixtures/xray"

# Model UCI's committed versus staged state, including export/import for rollback.
uci() {
 local args=("$@")
 [ "${1:-}" != -q ] || shift
 case "$1" in
 export) cat "$FAKE_UCI_DB" ;;
 import) cat >"$FAKE_UCI_DB" ;;
 commit) [ "${FAIL_COMMIT:-0}" = 0 ] || return 1; cp "$FAKE_UCI_DB" "$tmpdir/committed" ;;
 revert) cp "$tmpdir/committed" "$FAKE_UCI_DB" ;;
 del_list)
  local key="${2%%=*}" item="${2#*=}" value word
  value="$(command uci -q get "$key" || :)"
  command uci -q delete "$key"
  for word in $value; do [ "$word" = "$item" ] || command uci -q add_list "$key=$word"; done
  ;;
 *) command uci "${args[@]}" ;;
 esac
}
xray_config_test() { [ "${REJECT:-0}" = 0 ]; }
service_running() { return 1; }
service_ready() { service_running; }
nft_active() { return 1; }
cron_update() { :; }
policy_apply() { :; }
core_version() { echo test; }

setup_safety() {
 fake_uci_reset
 setup_runtime_paths "$tmpdir/$1"
 XRAY_CONFIG_BACKUP="$XRAY_CONFIG.bak"
 RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
 SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
 DNS_AUTO_RESOLVFILE="$PKG_TMP_DIR/resolv.auto"
 printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
 XRAY_BIN=/bin/true
 lost='VPN 🇷🇺 |] = <lost> hasOwnProperty'
 jq --arg t "$lost" '.outbounds[0].tag = $t | .routing.rules = [] | .xraywrt = {"mode":"direct-first", "dns-forward-other-types":true} | .dns.servers = ["192.0.2.20"]' "$FX/src/single.json" >"$XRAY_CONFIG"
 jq '.outbounds[0].tag = "replacement"' "$XRAY_CONFIG" >"$PKG_TMP_DIR/candidate"
 uci_set dns_raw_via "$lost"
 uci_set dns_raw_upstream '192.0.2.54:5353'
 uci add_list xraywrt.settings.provider_override=disable_quic
 uci_commit
 settings_load
 xray_config_generate "$XRAY_CONFIG" "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 cp "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
 cp "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
 cp "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
}
assert_off() {
 assert_eq '' "$(jq -r '.inbounds[] | select(.tag == "xraywrt-dns-in") | .settings.rewriteAddress // ""' "$RUNTIME_CONFIG")" 'no raw DNS rewrite'
 assert_eq return "$(jq -r '.outbounds[] | select(.tag == "xraywrt-dns") | .settings.rules[-1].action' "$RUNTIME_CONFIG")" 'other query types get empty answer'
 assert_eq '["192.0.2.20"]' "$(jq -c '.dns.servers' "$RUNTIME_CONFIG")" 'primary DNS stays provider-owned'
 assert_eq "$lost" "$(uci_get dns_raw_lost)" 'exact lost tag persists'
 assert_eq '' "$(uci_get dns_raw_via)" 'no active outbound remains'
 assert_eq 0 "$(uci_get dns_forward_other_types)" 'explicit off persisted'
 assert_eq '192.0.2.54:5353' "$(uci_get dns_raw_upstream)" 'saved server preserved'
 case " $(uci_get provider_override) " in *' dns_forward_other_types '*) ;; *) fail 'provider cannot override forced off' ;; esac
 case " $(uci_get provider_override) " in *' disable_quic '*) ;; *) fail 'unrelated provider override preserved' ;; esac
 assert_file_contains "$PROFILE_FILE" '[E:dns_raw_lost]' 'persistent actionable status warning'
 assert_file_contains "$PROFILE_FILE" "dns-raw-lost $lost" 'profile retains exact lost-tag context'
}

setup_safety previews
xray_config_generate "$PKG_TMP_DIR/candidate" "$PKG_TMP_DIR/probe" || fail 'valid candidate with lost DNS outbound should generate off'
assert_true 'candidate generation cannot mutate UCI' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
assert_file_contains "$PKG_TMP_DIR/probe.profile" "dns-raw-lost $lost" 'preview reports unavailable outbound'
# Catalog and installed-profile reads are nonmutating as well.
xraywrt-json dns-outbounds "$PKG_TMP_DIR/candidate" '' >/dev/null
profile_json >"$PKG_TMP_DIR/profile.json"
assert_true 'catalog/profile reads cannot mutate UCI' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
# config-check is a probe, even if the core accepts it.
probe="/tmp/xraywrt-config.safety.$$"
cp "$PKG_TMP_DIR/candidate" "$probe"
config_check_json "$probe" >"$PKG_TMP_DIR/check.json"
assert_true 'config-check cannot mutate UCI' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
assert_true 'config-check cannot replace source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
pass 'DNS safety previews and checks are pure'

for mode in direct-first proxy-first; do
 setup_safety "accepted-$mode"
 jq --arg m "$mode" '.xraywrt.mode = $m' "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/new"
 SUBSCRIPTION_INSTALLING=1 config_install "$PKG_TMP_DIR/new" >/dev/null
 assert_off
 cp "$XRAY_CONFIG" "$PKG_TMP_DIR/lost-source"
 # Reboot-equivalent: discard runtime/cache, reload committed UCI, regenerate.
 uci revert xraywrt
 rm -f "$RUNTIME_CONFIG" "$PROFILE_FILE"
 settings_load
 runtime_config_build "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 assert_off
 # Reappearance of exactly the old source tag cannot undo the latch.
 config_install "$PKG_TMP_DIR/source.before" >/dev/null
 assert_off
 # Explicit repair uses the original exact tag and a valid explicit server.
 uci_set dns_raw_via "$lost"
 uci_set dns_raw_lost ''
 uci_commit
 settings_load
 runtime_config_build "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 assert_eq "$lost" "$(jq -r '.outbounds[] | select(.tag == "xraywrt-dns") | .streamSettings.sockopt.dialerProxy' "$RUNTIME_CONFIG")" 'explicit repair restores exact selected route'
 assert_file_not_contains "$PROFILE_FILE" '[E:dns_raw_lost]' 'explicit repair resolves warning'
 pass "DNS safety accepted $mode config latches off until explicit repair"
done

for failure in corrupt rejected persistence publish; do
 setup_safety "$failure"
 case "$failure" in
 corrupt) printf '{broken' >"$PKG_TMP_DIR/candidate" ;;
 rejected) REJECT=1 ;;
 persistence) FAIL_COMMIT=1 ;;
 publish)
  mv() { [ "${3:-}" != "$RUNTIME_CONFIG" ] || [ "${2:-}" = "$RUNTIME_CONFIG.prev" ] || return 1; command mv "$@"; }
  ;;
 esac
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" "$failure must fail explicitly"
 REJECT=0 FAIL_COMMIT=0
 unset -f mv 2>/dev/null || :
 assert_true "$failure retains previous UCI" diff -q <(sort "$FAKE_UCI_DB") <(sort "$PKG_TMP_DIR/uci.before")
 assert_true "$failure retains previous source" cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
 assert_true "$failure retains previous runtime" cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 pass "DNS safety $failure candidate cannot mutate active selection"
done

setup_safety startup
cp "$PKG_TMP_DIR/candidate" "$XRAY_CONFIG"
settings_load
runtime_config_build "$RUNTIME_CONFIG"
cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
assert_off
# Persisted safety remains visible even if a cached profile predates the latch.
sed -i '/\[E:dns_raw_lost\]/d' "$PROFILE_FILE"
settings_load
assert_file_contains <(status_warnings) '[E:dns_raw_lost]' 'status exposes persisted safety independent of cached profile'
# Repeated unrelated applies preserve both latch and warning.
settings_load
runtime_refresh
assert_off
# The ordinary per-subscription copying path must carry the latch and warning context.
subscription_copy_settings settings s1 defaults || fail 'park safety settings'
uci -q set xraywrt.s2=subscription
subscription_copy_settings s2 settings defaults || fail 'restore new subscription defaults'
uci_commit
settings_load
assert_eq '' "$(uci_get dns_raw_lost)$(uci_get dns_raw_via)$(uci_get dns_raw_upstream)" 'new subscription does not inherit DNS safety state'
assert_false 'cached warning cannot leak to another subscription' grep -qF '[E:dns_raw_lost]' <(status_warnings)
subscription_copy_settings s1 settings defaults || fail 'restore safety settings'
uci_commit
settings_load
assert_eq "$lost" "$(uci_get dns_raw_lost)" 'switching back restores exact latch'
assert_eq '192.0.2.54:5353' "$(uci_get dns_raw_upstream)" 'switching back restores saved server'
pass 'DNS safety startup, unrelated apply and subscription isolation'

setup_safety stopped-profile
jq -s '[.[0] + {remarks:"original"}, .[1] + {remarks:"chosen"}]' "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/array"
cp "$PKG_TMP_DIR/array" "$XRAY_CONFIG"
uci_set profile chosen
uci_commit
service_reload
assert_off
pass 'DNS safety selected-profile change persists even while stopped'

setup_safety unchanged-refresh
set_active_subscription https://provider.example/config s1
uci_commit
cp "$PKG_TMP_DIR/candidate" "$XRAY_CONFIG"
SUBSCRIPTION_INSTALLING=1 config_install "$XRAY_CONFIG" >/dev/null
assert_off
pass 'DNS safety unchanged accepted refresh reconciles an existing lost selection'

setup_safety restart-rejected
echo "$$" >"$SUPERVISOR_PID_FILE"
service_running() { return 0; }
xray_api_apply() { return 1; }
core_restart() {
 if grep -qF '[E:dns_raw_lost]' "$PROFILE_FILE"; then
  assert_eq "$lost" "$(uci_get dns_raw_lost)" 'off latch must commit before new runtime starts'
  return 1
 fi
 return 0
}
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
assert_eq 1 "$rc" 'rejected restart fails candidate'
assert_true 'rejected restart restores UCI' diff -q <(sort "$FAKE_UCI_DB") <(sort "$PKG_TMP_DIR/uci.before")
assert_true 'rejected restart restores source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
assert_true 'rejected restart restores runtime' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
pass 'DNS safety persists before restart and rolls back a rejected runtime'

(
 setup_safety concurrent-rollback
 echo "$$" >"$SUPERVISOR_PID_FILE"
 service_running() { return 0; }
 core_restart() {
  if grep -qF '[E:dns_raw_lost]' "$PROFILE_FILE"; then
   uci_set dns_raw_upstream '203.0.113.7:53'
   uci -q set xraywrt.s1.url=https://concurrent.example/
   uci -q add_list xraywrt.settings.provider_override=concurrent_setting
   uci_commit
   return 1
  fi
  return 0
 }
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'rejected concurrent restart fails candidate'
 assert_eq '203.0.113.7:53' "$(uci_get dns_raw_upstream)" 'concurrent DNS upstream survives rollback'
 assert_eq 'https://concurrent.example/' "$(uci -q get xraywrt.s1.url)" 'concurrent subscription change survives rollback'
 case " $(uci_get provider_override) " in *' concurrent_setting '*) ;; *) fail 'concurrent override survives rollback' ;; esac
 assert_eq "$lost" "$(uci_get dns_raw_via)" 'rollback restores selected outbound'
)
pass 'DNS safety rollback preserves concurrent unrelated commits'

(
 setup_safety quoted-rollback
 quoted='VPN 🇷🇺 '"'single'"' "double"'
 uci_set dns_raw_via "$quoted"
 uci_commit
 printf 'dns-raw-lost %s\n' "$quoted" >"$PKG_TMP_DIR/quoted.profile"
 dns_forward_safety_save "$PKG_TMP_DIR/quoted.profile" "$PKG_TMP_DIR/safety-uci"
 dns_forward_safety_restore "$PKG_TMP_DIR/safety-uci"
 assert_eq "$quoted" "$(uci_get dns_raw_via)" 'rollback preserves quoted Unicode outbound exactly'
)
pass 'DNS safety rollback preserves quoted Unicode tags'

(
 setup_safety snapshot-presence
 uci_set dns_raw_lost ''
 uci -q delete xraywrt.settings.dns_forward_other_types
 uci_commit
 printf 'dns-raw-lost %s\n' "$lost" >"$PKG_TMP_DIR/presence.profile"
 dns_forward_safety_save "$PKG_TMP_DIR/presence.profile" "$PKG_TMP_DIR/safety-uci"
 dns_forward_safety_restore "$PKG_TMP_DIR/safety-uci"
 assert_true 'explicit empty option remains present' uci -q get xraywrt.settings.dns_raw_lost
 assert_false 'absent option remains absent' uci -q get xraywrt.settings.dns_forward_other_types
)
pass 'DNS safety rollback preserves empty versus absent options'

(
 setup_safety snapshot-control
 printf 'dns-raw-lost %s\n' "$lost" >"$PKG_TMP_DIR/control.profile"
 eval "saved_$(declare -f uci)"
 uci() {
  if [ "$*" = '-q get xraywrt.settings.dns_raw_via' ]; then printf 'unsafe\n\n'; return 0; fi
  saved_uci "$@"
 }
 rc=0
 dns_forward_safety_save "$PKG_TMP_DIR/control.profile" "$PKG_TMP_DIR/safety-uci" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'unsafe trailing newline cannot be snapshotted silently'
 assert_true 'unsafe snapshot leaves UCI unchanged' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
 assert_false 'unsafe snapshot is discarded' test -e "$PKG_TMP_DIR/safety-uci"
)
pass 'DNS safety rejects nonrepresentable snapshot values'

(
 setup_safety subscription-refresh
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 SUBSCRIPTION_META_FILE="$PKG_PERSIST_DIR/subscription.json"
 service_running() { return 1; }
 set_active_subscription https://provider.example/config s1
 uci_commit
 http_fetch() { cp "$PKG_TMP_DIR/candidate" "$2"; printf 'HTTP/1.1 200 OK\r\nprofile-update-interval: 12\r\n\r\n' >"$6"; }
 subscription_update >/dev/null
 assert_off
 assert_eq s1 "$(uci_get subscription)" 'automatic refresh keeps active subscription'
 random_hex() { echo 00000002; }
 subscription_store "$PKG_TMP_DIR/source.before" '{}' https://provider.example/other >"$PKG_TMP_DIR/added"
 other="$(jq -r .id "$PKG_TMP_DIR/added")"
 assert_eq "$lost" "$(uci_get dns_raw_lost)" 'parking another subscription cannot change active safety state'
 subscription_switch "$other" >/dev/null
 settings_load
 assert_eq '' "$(uci_get dns_raw_lost)$(uci_get dns_raw_via)$(uci_get dns_raw_upstream)" 'real switch gives other subscription its own DNS settings'
 assert_false 'real switch isolates warning' grep -qF '[E:dns_raw_lost]' <(status_warnings)
 subscription_switch s1 >/dev/null
 settings_load
 assert_off
)
pass 'DNS safety automatic refresh and actual subscription switches preserve isolation'

(
 setup_safety subscription-copy-failure
 uci_set dns_raw_lost "$lost"
 eval "saved_$(declare -f uci)"
 uci() {
  case "$*" in *' set xraywrt.s1.dns_raw_lost='*) return 1 ;; esac
  saved_uci "$@"
 }
 rc=0
 subscription_copy_settings settings s1 defaults || rc=$?
 assert_eq 1 "$rc" 'a failed latch copy must abort the subscription transaction'
)
pass 'DNS safety subscription copying reports persistence failure'

(
 setup_safety failed-start
 cp "$PKG_TMP_DIR/candidate" "$XRAY_CONFIG"
 rm -f "$RUNTIME_CONFIG" "$PROFILE_FILE"
 settings_load
 FAIL_COMMIT=1
 rc=0
 runtime_config_build "$RUNTIME_CONFIG" >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'startup cannot accept an unpersisted safety decision'
 assert_false 'failed startup leaves no new runtime to start' test -f "$RUNTIME_CONFIG"
 assert_true 'failed startup retains committed UCI' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
 assert_file_contains "$PKG_TMP_DIR/error" '[E:dns_raw_persist]' 'failed startup reports persistence error'
)
pass 'DNS safety failed startup cannot run an unrecorded forced-off config'

(
 setup_safety rollback-commit-failure
 echo "$$" >"$SUPERVISOR_PID_FILE"
 service_running() { return 0; }
 core_restart() {
  if grep -qF '[E:dns_raw_lost]' "$PROFILE_FILE"; then FAIL_COMMIT=1; return 1; fi
  return 0
 }
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'rollback commit failure cannot report acceptance'
 assert_file_contains "$PKG_TMP_DIR/error" '[E:dns_raw_persist]' 'rollback persistence failure is surfaced'
 assert_eq "$lost" "$(uci_get dns_raw_lost)" 'failed rollback retains committed off latch'
 assert_eq '' "$(uci_get dns_raw_via)" 'failed rollback cannot leave staged enabling values'
 FAIL_COMMIT=0
 settings_load
 runtime_config_build "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 assert_off
)
pass 'DNS safety rollback persistence failure retains off and reports error'

(
 setup_safety missing-profile
 rc=0
 dns_forward_safety_save "$PKG_TMP_DIR/missing.profile" "$PKG_TMP_DIR/safety-uci" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'unreadable safety metadata cannot be treated as no lost outbound'
 assert_true 'unreadable safety metadata leaves UCI unchanged' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
)
pass 'DNS safety requires readable generated metadata before acceptance'

(
 setup_safety supervisor-existing-file
 cp "$PKG_TMP_DIR/candidate" "$XRAY_CONFIG"
 settings_load
 # A prior preview/failed build left bytes, but never accepted a persistent latch.
 xray_config_generate "$XRAY_CONFIG" "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 FAIL_COMMIT=1
 with_lock() { "$@"; }
 policy_cleanup() { :; }
 core_spawn() { touch "$PKG_TMP_DIR/spawned"; pid=1; }
 wait_for_ready() { return 1; }
 stop_child() { :; }
 pgrep() { return 1; }
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 rc=0
 (run_service) >"$PKG_TMP_DIR/out" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_false 'supervisor cannot start an unaccepted forced-off file via existing-file shortcut' test -f "$PKG_TMP_DIR/spawned"
 assert_eq 1 "$rc" 'supervisor reports failed safety persistence'
 assert_false 'supervisor removes unaccepted runtime after failed latch' test -f "$RUNTIME_CONFIG"
 assert_eq '' "$(uci_get dns_raw_lost)" 'failed supervisor start cannot mutate committed selection'
)
pass 'DNS safety supervisor existing-file shortcut cannot bypass durable acceptance'

(
 setup_safety consecutive-rejections
 echo "$$" >"$SUPERVISOR_PID_FILE"
 service_running() { return 0; }
 xray_api_apply() { return 1; }
 core_restart() {
  if grep -qF '[E:dns_raw_lost]' "$PROFILE_FILE"; then FAIL_COMMIT=1; return 1; fi
  return 0
 }
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >/dev/null 2>"$PKG_TMP_DIR/first.error" || rc=$?
 assert_eq 1 "$rc" 'first rejected restart reports rollback persistence failure'
 assert_eq "$lost" "$(uci_get dns_raw_lost)" 'first rejection retains committed latch'
 assert_true 'failed rollback leaves an earlier transaction snapshot' test -f "$PKG_TMP_DIR/runtime.candidate.json.dns-uci"
 FAIL_COMMIT=0
 uci_set core_log_level debug
 uci_commit
 settings_load
 jq '.routing.rules += [{port:"25",outboundTag:"block"}]' "$XRAY_CONFIG" >"$PKG_TMP_DIR/second"
 core_restart() { return 0; }
 mv() { [ "${3:-}" != "$RUNTIME_CONFIG" ] || [ "${2:-}" = "$RUNTIME_CONFIG.prev" ] || return 1; command mv "$@"; }
 rc=0
 config_install "$PKG_TMP_DIR/second" >/dev/null 2>"$PKG_TMP_DIR/second.error" || rc=$?
 unset -f mv
 assert_eq 1 "$rc" 'second publication rejection remains an error'
 assert_eq "$lost" "$(uci_get dns_raw_lost)" 'second rejection cannot restore an earlier enabling snapshot'
 assert_eq '' "$(uci_get dns_raw_via)" 'second rejection cannot restore an earlier outbound'
 assert_eq debug "$(uci_get core_log_level)" 'second rejection preserves later unrelated UCI changes'
 settings_load
 service_running() { return 1; }
 config_install "$PKG_TMP_DIR/second" >/dev/null
 assert_off
 assert_eq debug "$(uci_get core_log_level)" 'next accepted change remains off without undoing later settings'
)
pass 'DNS safety consecutive rejections cannot reuse an earlier UCI snapshot'

(
 setup_safety snapshot-ownership
 snapshot="$PKG_TMP_DIR/old.dns-uci"
 uci -q export xraywrt >"$snapshot"
 dns_forward_safety_save "$PROFILE_FILE" "$snapshot"
 assert_false 'no-loss early return invalidates the previous snapshot' test -e "$snapshot"
 mkdir "$snapshot"
 rc=0
 dns_forward_safety_save "$PROFILE_FILE" "$snapshot" 2>"$PKG_TMP_DIR/error" || rc=$?
 assert_eq 1 "$rc" 'failure to invalidate a snapshot aborts before the no-loss return'
 assert_file_contains "$PKG_TMP_DIR/error" '[E:dns_raw_persist]' 'snapshot invalidation failure is actionable'
 assert_true 'invalidation failure leaves current UCI untouched' cmp -s "$FAKE_UCI_DB" "$PKG_TMP_DIR/uci.before"
)
pass 'DNS safety snapshot ownership is checked even when no new latch is needed'

(
 setup_safety supervisor-lock-wait
 set_active_subscription https://provider.example/a sa
 uci_commit
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 LOCK_DEPTH=0
 holder=''
 trap '[ -z "$holder" ] || { kill "$holder" 2>/dev/null || :; wait "$holder" 2>/dev/null || :; }' EXIT
 # Hold the real production lock until the supervisor has loaded subscription A.
 (
  lock_acquire
  touch "$PKG_TMP_DIR/holder.ready"
  for ((i=0;i<200;i++)); do [ ! -f "$PKG_TMP_DIR/loaded.ready" ] || break; sleep 0.02; done
  [ -f "$PKG_TMP_DIR/loaded.ready" ] || exit 3
  cp "$PKG_TMP_DIR/candidate" "$XRAY_CONFIG"
  set_active_subscription https://provider.example/b sb
  uci_set dns_raw_via replacement
  uci_set dns_raw_lost ''
  uci_set dns_raw_upstream '198.51.100.54:5354'
  uci_commit
  settings_load
  runtime_config_build "$RUNTIME_CONFIG"
  cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
  assert_eq replacement "$(uci_get dns_raw_via)" 'subscription B has a valid accepted route before lock release'
  lock_release
 ) &
 holder=$!
 for ((i=0;i<200;i++)); do [ ! -f "$PKG_TMP_DIR/holder.ready" ] || break; sleep 0.02; done
 [ -f "$PKG_TMP_DIR/holder.ready" ] || fail 'lock holder did not become ready'
 eval "before_wait_$(declare -f settings_load)"
 settings_load() { before_wait_settings_load; touch "$PKG_TMP_DIR/loaded.ready"; }
 policy_cleanup() { :; }
 core_spawn() { pid=1; }
 wait_for_ready() { return 1; }
 stop_child() { :; }
 pgrep() { return 1; }
 rc=0
 (run_service) >/dev/null 2>"$PKG_TMP_DIR/run.error" || rc=$?
 wait "$holder" || fail 'accepted subscription change under lock failed'
 holder=''
 assert_eq 1 "$rc" 'fixture ends at its stubbed readiness failure'
 assert_eq sb "$(uci_get subscription)" 'subscription B remains active after supervisor lock wait'
 assert_eq '' "$(uci_get dns_raw_lost)" 'supervisor lock wait cannot persist subscription A loss into B'
 assert_eq replacement "$(uci_get dns_raw_via)" 'supervisor keeps B selected outbound'
 assert_eq '198.51.100.54:5354' "$(uci_get dns_raw_upstream)" 'supervisor keeps B saved DNS server'
 assert_eq replacement "$(jq -r '.outbounds[] | select(.tag == "xraywrt-dns") | .streamSettings.sockopt.dialerProxy' "$RUNTIME_CONFIG")" 'runtime uses B route after lock acquisition'
 assert_eq '198.51.100.54' "$(jq -r '.inbounds[] | select(.tag == "xraywrt-dns-in") | .settings.rewriteAddress' "$RUNTIME_CONFIG")" 'runtime uses B DNS server, not stale A parameters'
 assert_file_not_contains "$PROFILE_FILE" '[E:dns_raw_lost]' 'B does not inherit A warning'
)
pass 'DNS safety supervisor reloads subscription settings after the real runtime lock wait'
