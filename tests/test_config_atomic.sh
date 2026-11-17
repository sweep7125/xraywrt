#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh dns.sh xray-config.sh config.sh subscription.sh service.sh

FX="$ROOT_DIR/tests/fixtures/xray"
setup_install() {
 setup_runtime_paths "$tmpdir/$1"
 XRAY_CONFIG_BACKUP="$XRAY_CONFIG.bak"
 RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
 SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
 DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
 printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
 echo "$$" >"$SUPERVISOR_PID_FILE"
 jq '.xraywrt = {"disable-quic": true}' "$FX/src/single.json" >"$XRAY_CONFIG"
 printf 'older backup\n' >"$XRAY_CONFIG_BACKUP"
 # A new runtime (one more rule) and a new provider setting.
 jq '.xraywrt = {"disable-quic": false} | .routing.rules += [{"port": "25", "outboundTag": "block"}]' "$FX/src/single.json" >"$PKG_TMP_DIR/candidate"
 settings_load
 xray_config_generate "$XRAY_CONFIG" "$RUNTIME_CONFIG"
 cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
 cp "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
 cp "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 cp "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
 : >"$PKG_TMP_DIR/events"
}
xray_config_test() { return 0; }
xray_api_apply() { return 1; }
service_running() { return 0; }
service_ready() { return 0; }
cron_update() { echo cron >>"$PKG_TMP_DIR/events"; }
policy_apply() { echo "policy $(profile_get "set disable_quic")" >>"$PKG_TMP_DIR/events"; }
# The new runtime does not start; the previous one does.
core_restart() {
 echo "restart $(profile_get "set disable_quic")" >>"$PKG_TMP_DIR/events"
 [ "$(profile_get "set disable_quic")" = 1 ]
}

# Spec 9.3 step 4: the previous runtime, profile and config.json come back.
setup_install rollback
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'core start failure fails install'
assert_eq 'Error: new config failed to start, previous restored' "$(cat "$tmpdir/err")" 'rollback error'
assert_eq '' "$(cat "$tmpdir/out")" 'failed install emits no success action'
assert_true 'previous config restored' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
assert_true 'previous runtime restored' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
assert_true 'previous profile restored' cmp -s "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
assert_eq 'older backup' "$(cat "$XRAY_CONFIG_BACKUP")" 'failed install keeps older backup'
assert_eq $'restart 0\nrestart 1' "$(cat "$PKG_TMP_DIR/events")" 'rollback restarts the previous runtime without new policy'
assert_eq '' "$(find "$PKG_TMP_DIR" "${XRAY_CONFIG%/*}" -name '*.prev' -o -name '*.previous.*' -o -name '*.candidate*')" 'rollback leaves no staging files'
pass 'config_install rolls back a runtime that does not start without rotating backup'

core_restart() { echo restart >>"$PKG_TMP_DIR/events"; }
: >"$PKG_TMP_DIR/events"
assert_eq 'restarted' "$(config_install "$PKG_TMP_DIR/candidate" | xraywrt-json get action)" 'same candidate retries after failure'
assert_eq $'restart\ncron\npolicy 0' "$(cat "$PKG_TMP_DIR/events")" 'retry restarts the core and applies the new policy'
assert_true 'successful retry rotates backup' cmp -s "$XRAY_CONFIG_BACKUP" "$PKG_TMP_DIR/source.before"
assert_false 'successful retry drops the previous runtime' test -e "$RUNTIME_CONFIG.prev"
pass 'config_install retries the same bytes after rollback'

# A first link that returns the bytes already installed by hand still rebuilds the runtime.
(
 service_reload() { echo reload >>"$PKG_TMP_DIR/events"; }
 : >"$PKG_TMP_DIR/events"
 rm -f "$APPLY_WARNING_FILE"
 assert_eq unchanged "$(config_install "$XRAY_CONFIG" | xraywrt-json get action)" 'same bytes by hand: nothing to do'
 assert_eq '' "$(cat "$PKG_TMP_DIR/events")" 'no reload for the same bytes'
 uci_get() { :; }
 assert_eq unchanged "$(SUBSCRIPTION_INSTALLING=1 config_install "$XRAY_CONFIG" | xraywrt-json get action)" 'same bytes from a first link'
 assert_eq reload "$(cat "$PKG_TMP_DIR/events")" 'a first link reloads the service'
 # An ordinary (cron) update of a saved subscription must never restart anything.
 uci_get() { [ "$1" != subscription ] || echo s1; }
 : >"$PKG_TMP_DIR/events"
 assert_eq unchanged "$(SUBSCRIPTION_INSTALLING=1 config_install "$XRAY_CONFIG" | xraywrt-json get action)" 'same bytes from a saved subscription'
 assert_eq '' "$(cat "$PKG_TMP_DIR/events")" 'an unchanged update of a saved subscription does not reload'
)
pass 'a first link over the same bytes rebuilds the runtime'

# A policy failure after a live restart is reported, not rolled back: the
# core already runs the new config.
setup_install policy-failure
policy_apply() { err 'new policy failed'; return 1; }
rc=0
config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 0 "$rc" 'policy failure keeps the started config'
assert_eq partial "$(jq -r .apply_status "$tmpdir/out")" 'policy failure is not ordinary success'
assert_file_contains "$tmpdir/err" 'new policy failed' 'policy error reported'
assert_true 'new config kept' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate"
assert_true 'backup rotated' cmp -s "$XRAY_CONFIG_BACKUP" "$PKG_TMP_DIR/source.before"
policy_apply() { echo "policy $(profile_get "set disable_quic")" >>"$PKG_TMP_DIR/events"; }
pass 'config_install reports a policy failure after a started config'

for failed_file in profile runtime; do
 (
  setup_install "publish-$failed_file-failure"
  case "$failed_file" in
  profile) publish_dst="$PROFILE_FILE" ;;
  runtime) publish_dst="$RUNTIME_CONFIG" ;;
  esac
  mv() {
   if [ "${3:-}" = "$publish_dst" ] && [ "${2:-}" != "$publish_dst.prev" ]; then
    return 1
   fi
   command mv "$@"
  }
  rc=0
  config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
  assert_eq 1 "$rc" "failed $failed_file publish fails install"
  assert_eq 'Error: Cannot publish the runtime config' "$(cat "$tmpdir/err")" "failed $failed_file publish message"
  assert_true "failed $failed_file publish restores config" cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
  assert_true "failed $failed_file publish restores runtime" cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
  assert_true "failed $failed_file publish restores profile" cmp -s "$PROFILE_FILE" "$PKG_TMP_DIR/profile.before"
  assert_eq 'older backup' "$(cat "$XRAY_CONFIG_BACKUP")" "failed $failed_file publish keeps older backup"
  assert_eq '' "$(cat "$PKG_TMP_DIR/events")" "failed $failed_file publish does not restart"
 )
 pass "config_install restores everything after a failed $failed_file publish"
done

(
 setup_install write-failure
 mv() {
  [ "${3:-}" != "$XRAY_CONFIG" ] || return 1
  command mv "$@"
 }
 rc=0
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 assert_eq 1 "$rc" 'failed config write fails install'
 assert_eq "Error: Cannot write $XRAY_CONFIG" "$(cat "$tmpdir/err")" 'config write message'
 assert_true 'failed write keeps config' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
 assert_true 'failed write keeps runtime' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 assert_eq '' "$(find "$PKG_TMP_DIR" "${XRAY_CONFIG%/*}" -name '*.tmp' -o -name '*.previous.*' -o -name '*.candidate*' -o -name 'profile.old')" 'failed write leaves no staging files'
)
pass 'config_install failed config write changes nothing'

(
 setup_install profile-only
 geodata_snapshot
 jq '.xraywrt = {"disable-quic": false}' "$FX/src/single.json" >"$PKG_TMP_DIR/candidate"
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/out"
 assert_eq saved "$(jq -r .action "$tmpdir/out")" 'profile-only change keeps the core'
 assert_true 'profile-only change keeps runtime' cmp -s "$RUNTIME_CONFIG" "$PKG_TMP_DIR/runtime.before"
 assert_eq 0 "$(profile_get "set disable_quic")" 'profile-only change publishes the profile'
 assert_eq $'cron\npolicy 0' "$(cat "$PKG_TMP_DIR/events")" 'profile-only change applies policy without restart'
)
pass 'config_install profile-only change skips the Xray restart'

setup_install subscription
SUBSCRIPTION_META_FILE="$PKG_PERSIST_DIR/subscription.json"
printf '{"profile_title":"old"}\n' >"$SUBSCRIPTION_META_FILE"
SUBSCRIPTION_URL=https://provider.example/config
http_fetch() { cp "$PKG_TMP_DIR/candidate" "$2"; : >"$6"; }
subscription_metadata_from_headers() { echo '{"profile_title":"new"}'; }
with_lock() { "$@"; }
core_restart() { return 1; }
rc=0
subscription_update https://new.example/config >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'subscription propagates a failed start'
assert_true 'failed subscription keeps config' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/source.before"
assert_eq '{"profile_title":"old"}' "$(cat "$SUBSCRIPTION_META_FILE")" 'failed subscription keeps metadata'
assert_eq '' "$(active_subscription_url)" 'failed subscription does not save new URL'
assert_false 'failed subscription does not advance update stamp' test -f "$PKG_STATE_DIR/subscription.stamp"
pass 'subscription_update leaves metadata URL and stamp unchanged after a failed start'

# Unsafe provider identifiers fail before publication, without touching live state.
setup_install unsafe-identifier
jq '.outbounds[0].tag = "vpn\nset netbird_proxy 1"' "$PKG_TMP_DIR/candidate" >"$PKG_TMP_DIR/unsafe"
cp "$XRAY_CONFIG_BACKUP" "$PKG_TMP_DIR/backup.before"
rc=0
config_install "$PKG_TMP_DIR/unsafe" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'invalid identifier fails install'
assert_file_contains "$tmpdir/err" '[E:profile_invalid]' 'invalid identifier gives coded error'
for pair in "$XRAY_CONFIG:source" "$RUNTIME_CONFIG:runtime" "$PROFILE_FILE:profile" "$XRAY_CONFIG_BACKUP:backup"; do
 assert_true 'rejection preserves previous connection files' cmp -s "${pair%:*}" "$PKG_TMP_DIR/${pair##*:}.before"
done
assert_eq '' "$(cat "$PKG_TMP_DIR/events")" 'invalid identifier never restarts service or policy'
pass 'config_install rejects unsafe identifiers and keeps previous connection'

# Real config_install -> job_execute -> job_run result, not a mocked job payload.
(
 load_modules job.sh
 setup_install partial-job
 JOBS_DIR="$PKG_STATE_DIR/jobs"
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 mkdir -p "$JOBS_DIR"
 id=100-200
 xraywrt-json build job --arg id "$id" --arg op save-config --argjson started 100 >"$JOBS_DIR/$id.json"
 ln -s "$id" "$JOBS_DIR/active"
 upload="/tmp/xraywrt-config.partial.$$"
 trap 'rm -f "$upload"' EXIT
 cp "$PKG_TMP_DIR/candidate" "$upload"
 core_restart() { :; }
 policy_apply() { err 'forced policy failure'; return 1; }
 job_run "$id" save-config "$upload"
 assert_eq ok "$(jq -r .state "$JOBS_DIR/$id.json")" 'accepted config keeps compatible terminal ok'
 assert_eq partial "$(jq -r .result.apply_status "$JOBS_DIR/$id.json")" 'real config job exposes partial apply'
 assert_eq restarted "$(jq -r .result.action "$JOBS_DIR/$id.json")" 'partial retains actual runtime action'
 assert_true 'partial carries next-step warnings' jq -e '.result.warnings | length > 0' "$JOBS_DIR/$id.json"
 assert_true 'partial warning persisted' test -s "$APPLY_WARNING_FILE"
 assert_true 'partial retains accepted source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate"
 policy_apply() { :; }
 service_reload
 assert_false 'successful retry clears apply warning' test -e "$APPLY_WARNING_FILE"
)
pass 'real config job returns partial after publication and successful retry clears warning'

for pending in stopped degraded; do
 (
  setup_install "saved-$pending"
  service_ready() { return 1; }
  service_running() { [ "$pending" = degraded ]; }
  [ "$pending" != degraded ] || touch "$DEGRADED_FILE"
  core_restart() { :; }
  policy_apply() { fail 'waiting config must not apply policy'; }
  config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/waiting"
  assert_eq saved "$(jq -r .apply_status "$tmpdir/waiting")" 'waiting config is saved, not partial or applied'
  assert_eq "$pending" "$(jq -r .pending_reason "$tmpdir/waiting")" 'saved reason identifies waiting state'
  assert_eq 0 "$(jq '.warnings | length' "$tmpdir/waiting")" 'normal waiting is not an error'
 )
done
pass 'stopped and degraded accepted configs report saved with distinct pending reasons'

(
 setup_install unchanged-profile-retry
 geodata_snapshot
 # New source bytes with the same provider profile must still retry failed routing.
 echo 'previous routing failure' >"$APPLY_WARNING_FILE"
 jq '.routing.rules += [{"port":"25","outboundTag":"block"}]' "$XRAY_CONFIG" >"$PKG_TMP_DIR/candidate"
 core_restart() { :; }
 policy_apply() { echo retried >"$PKG_TMP_DIR/retried"; }
 config_install "$PKG_TMP_DIR/candidate" >/dev/null
 assert_true 'unchanged profile retries previously failed routing' test -e "$PKG_TMP_DIR/retried"
)
pass 'new source with unchanged profile cannot clear a warning without retrying routing'

(
 setup_install failed-backup
 core_restart() { :; }
 mv() {
  [ "${3:-}" != "$XRAY_CONFIG_BACKUP" ] || return 1
  command mv "$@"
 }
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/backup-result"
 assert_eq partial "$(jq -r .apply_status "$tmpdir/backup-result")" 'failed backup after publication is partial'
 assert_true 'failed backup retains accepted source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate"
)
pass 'failed backup after accepted publication is partial, not rejection'

(
 setup_install profile-only-publish-failure
 geodata_snapshot
 jq '.xraywrt = {"disable-quic":false}' "$FX/src/single.json" >"$PKG_TMP_DIR/candidate"
 mv() {
  [ "${3:-}" != "$PROFILE_FILE" ] || return 1
  command mv "$@"
 }
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/profile-result"
 assert_eq partial "$(jq -r .apply_status "$tmpdir/profile-result")" 'profile publish failure after source acceptance is partial'
 assert_true 'profile publish failure retains accepted source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate"
 assert_false 'failed publication cannot cache current input key' test -e "$RUNTIME_CONFIG.inputs"
)
pass 'profile-only publication failure cannot report ordinary success'

(
 setup_install subscription-policy-partial
 SUBSCRIPTION_META_FILE="$PKG_PERSIST_DIR/subscription.json"
 SUBSCRIPTION_URL=https://provider.example/config
 core_restart() { :; }
 http_fetch() { cp "$PKG_TMP_DIR/candidate" "$2"; : >"$6"; }
 subscription_metadata_from_headers() { echo '{}'; }
 lists_urls() { echo https://lists.example/list; }
 lists_update_remote() { echo changed; }
 nft_active() { return 0; }
 nft_apply_if_ready() { return 1; }
 subscription_update https://provider.example/config >"$tmpdir/subscription-result" || fail 'subscription update failed before producing result'
 assert_eq partial "$(jq -r .apply_status "$tmpdir/subscription-result")" 'subscription post-install policy failure remains partial'
 assert_true 'subscription partial retains accepted source' cmp -s "$XRAY_CONFIG" "$PKG_TMP_DIR/candidate"
)
pass 'subscription cannot hide a post-publication remote-list policy failure'

(
 setup_install dns-flush-partial
 sed -i 's/^fake-enabled 0$/fake-enabled 1/' "$PROFILE_FILE"
 core_restart() { :; }
 dns_restart_dnsmasq() { return 1; }
 config_install "$PKG_TMP_DIR/candidate" >"$tmpdir/dns-result"
 assert_eq partial "$(jq -r .apply_status "$tmpdir/dns-result")" 'required DNS flush failure is partial'
)
pass 'DNS-mode flush failure cannot report fully applied settings'
