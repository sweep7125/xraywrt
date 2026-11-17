#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backend="$tmpdir/backend"
cat >"$backend" <<'B'
#!/bin/sh
echo "backend $*"
B
chmod +x "$backend"
read_cli="$ROOT_DIR/rootfs/usr/bin/xraywrt-read"

assert_eq "backend status-json" "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" status-json)" "read command passes"
for bad in "select-proxy a b" "save-config /tmp/x" "read-config" "read-config /tmp/xraywrt-config.abc" "read-config /etc/hosts" "status-json extra" "core-update" "profile-json x" "lists-json x" "geodata-update --name x.dat" "geodata-update --file /tmp/x --name ../x.dat"; do
	# shellcheck disable=SC2086
	if XRAYWRT_BACKEND="$backend" sh "$read_cli" $bad >/dev/null 2>&1; then
		fail "read wrapper must reject: $bad"
	fi
done
pass "read wrapper rejects writes"

out="$(sh "$ROOT_DIR/rootfs/usr/bin/xraywrt" bogus 2>&1 || true)"
[[ "$out" == *"Usage: xraywrt"* ]] || fail "usage on unknown command: $out"
pass "cli usage"

assert_eq 'backend profile-json' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" profile-json)" "profile-json read wrapper"
# A14.1: the Overview profile list is a read; config-check runs the core (write ACL).
assert_eq 'backend profiles' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" profiles)" "profiles read wrapper"
assert_false 'read wrapper rejects profiles arguments' env XRAYWRT_BACKEND="$backend" sh "$read_cli" profiles x
# The subscription link is a credential: the read wrapper always asks for the masked form.
assert_eq 'backend subscription-json --mask' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" subscription-json)" 'read wrapper masks the subscription link'
assert_false 'read wrapper rejects subscription-json arguments' env XRAYWRT_BACKEND="$backend" sh "$read_cli" subscription-json x
assert_eq 'backend check-ip' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" check-ip)" 'check-ip read wrapper'
assert_false 'read wrapper rejects check-ip arguments' env XRAYWRT_BACKEND="$backend" sh "$read_cli" check-ip x
assert_false 'read wrapper rejects config-check' env XRAYWRT_BACKEND="$backend" sh "$read_cli" config-check
# Execute dispatch with the normal module bootstrap removed, not a duplicated case.
strip_xraywrt_cli_bootstrap >"$tmpdir/cli.sh"
export XRAYWRT_LIB_DIR
for n in 1 2 3 4; do printf '%s\n' "$n" >"$tmpdir/list$n"; done
# The real CLI argument boundary is exercised with a harmless apply stub.
sed -i '/^case "$cmd" in/i lists_apply() { local IFS=:; printf "lists:%s\\n" "$*"; }' "$tmpdir/cli.sh"
assert_eq "lists:$tmpdir/list1:$tmpdir/list2:$tmpdir/list3" "$(sh "$tmpdir/cli.sh" apply-lists "$tmpdir/list1" "$tmpdir/list2" "$tmpdir/list3")" "three list CLI args"
assert_false "two lists rejected" sh "$tmpdir/cli.sh" apply-lists a b >/dev/null 2>&1
assert_false "four lists rejected" sh "$tmpdir/cli.sh" apply-lists a b c d >/dev/null 2>&1
sed -i '/^case "$cmd" in/i subscription_update() { printf "update:%s\\n" "$1"; }' "$tmpdir/cli.sh"
assert_eq 'update:https://new.example/sub' "$(sh "$tmpdir/cli.sh" update-subscription https://new.example/sub)" 'update URL forwarded'
assert_false 'extra update args rejected' sh "$tmpdir/cli.sh" update-subscription a b >/dev/null 2>&1
pass 'optional subscription URL CLI boundary'

# polish: read wrapper
(
 set -e
 assert_eq 'backend runtime-config' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" runtime-config)" 'read wrapper allows runtime-config'
 assert_false 'read wrapper rejects runtime-config arguments' env XRAYWRT_BACKEND="$backend" sh "$read_cli" runtime-config x >/dev/null 2>&1
)
pass 'runtime-config read wrapper'

# polish: runtime-config usage
(
 set -e
 read_usage="$(sh "$read_cli" 2>&1 || true)"
 [[ "$read_usage" == *runtime-config* ]] || fail 'read wrapper usage lists runtime-config'
 backend_usage="$(sh "$tmpdir/cli.sh" 2>&1 || true)"
 [[ "$backend_usage" == *runtime-config* ]] || fail 'backend usage lists runtime-config'
)
pass 'runtime-config usage'

# polish: runtime-config backend dispatch
(
 set -e
 sed '/^case "$cmd" in/i runtime_config_json() { echo runtime-config-dispatched; }' "$tmpdir/cli.sh" >"$tmpdir/runtime-cli.sh"
 assert_eq runtime-config-dispatched "$(sh "$tmpdir/runtime-cli.sh" runtime-config)" 'runtime-config backend dispatch'
 assert_false 'runtime-config backend rejects arguments' sh "$tmpdir/runtime-cli.sh" runtime-config x >/dev/null 2>&1
)
pass 'runtime-config backend dispatch'

# Run real core_update_locked and dispatch, substituting only update/service edges.
strip_xraywrt_cli_bootstrap >"$tmpdir/core-cli.sh"
cat >"$tmpdir/init" <<'I'
#!/bin/sh
[ "$1" = restart ] || exit 99
sleep 0.1
echo restarted >"$RESTART_MARKER"
if [ "${RESTART_LOCK_CHECK:-0}" = 1 ]; then
 exec 7>>"$CORE_STATE_DIR/core.flock"
 flock -n 7 || { echo 'Error: core update lock still held at restart' >&2; exit 97; }
 echo released >"$CORE_STATE_DIR/restart.lock"
fi
[ -z "${RESTART_ERROR:-}" ] || printf '\nError: %s\n\n' "$RESTART_ERROR" >&2
exit "$RESTART_RC"
I
chmod +x "$tmpdir/init"
export INIT_STUB="$tmpdir/init" RESTART_MARKER="$tmpdir/restarted"
sed '/^cmd=/,$d' "$tmpdir/core-cli.sh" >"$tmpdir/core-prefix.sh"
export CORE_STATE_DIR="$tmpdir/core-state"
mkdir -p "$CORE_STATE_DIR"
cat >>"$tmpdir/core-prefix.sh" <<'STUBS'
PKG_STATE_DIR="$CORE_STATE_DIR"
eval "$(sed -n '/^core_update_locked()/,/^}/p' "$XRAYWRT_LIB_DIR/core.sh" | sed 's|/etc/init.d/xraywrt restart|"$INIT_STUB" restart|')"
core_version() { echo v1.19.30; }
core_update_json() { command printf '{"updated":%s,"version":"v1.19.32","error":null}\n' "$UPDATED"; return "$UPDATE_RC"; }
service_running() { [ "$RUNNING" = 1 ]; }
printf() {
 if [ "$1" = '%s\n' ] && [ "${EXPECT_RESTART:-0}" = 1 ] && [ ! -f "$RESTART_MARKER" ]; then
  echo 'printed before restart finished' >"$EARLY_PRINT"
 fi
 command printf "$@"
}
STUBS
sed -n '/^cmd=/,$p' "$tmpdir/core-cli.sh" >>"$tmpdir/core-prefix.sh"
mv "$tmpdir/core-prefix.sh" "$tmpdir/core-cli.sh"
export UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=0 EXPECT_RESTART=1 EARLY_PRINT="$tmpdir/early"
out="$(sh "$tmpdir/core-cli.sh" core-update)"
assert_false 'CLI prints only after foreground restart' test -e "$EARLY_PRINT"
assert_eq true "$(jq -r .restarted <<<"$out")" 'successful restart reported'
for scenario in stopped unchanged update_failure restart_failure; do
 rm -f "$RESTART_MARKER" "$EARLY_PRINT"
 export UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=0 EXPECT_RESTART=0
 case "$scenario" in
 stopped) export RUNNING=0 ;;
 unchanged) export UPDATED=false ;;
 update_failure) export UPDATE_RC=1 ;;
 restart_failure) export RESTART_RC=1 EXPECT_RESTART=1 ;;
 esac
 rc=0
 out="$(sh "$tmpdir/core-cli.sh" core-update 2>"$tmpdir/core.err")" || rc=$?
 assert_eq false "$(jq -r .restarted <<<"$out")" "$scenario not restarted"
 case "$scenario" in
 restart_failure)
  assert_eq 1 "$rc" 'restart failure status'
  assert_eq true "$(jq -r .updated <<<"$out")" 'updated kept on restart failure'
  assert_eq v1.19.32 "$(jq -r .version <<<"$out")" 'version kept on restart failure'
  assert_eq 'Xray core updated, but the service restart failed [E:core_restart_empty]' "$(jq -r .error <<<"$out")" 'clear restart error in JSON'
  assert_file_contains "$tmpdir/core.err" "Error: $(jq -r .error <<<"$out")" 'restart error in stderr'
  ;;
 update_failure) assert_eq 1 "$rc" 'update failure status' ;;
 *) assert_eq 0 "$rc" 'no-op status' ;;
 esac
 [ "$scenario" = restart_failure ] || assert_false 'no restart when unnecessary' test -e "$RESTART_MARKER"
done
pass 'core CLI synchronous restart and result'

# polish: core update busy
(
 set -e
 start_runtime_lock_holder "$CORE_STATE_DIR/core.flock" "$tmpdir/core-holder.ready"
 core_holder=$LOCK_HOLDER_PID
 trap 'kill "$core_holder" 2>/dev/null; wait "$core_holder" 2>/dev/null || true' EXIT
 busy_rc=0
 busy_out="$(UPDATED=true UPDATE_RC=0 RUNNING=0 RESTART_RC=0 EXPECT_RESTART=0 sh "$tmpdir/core-cli.sh" core-update 2>"$tmpdir/core-busy.err")" || busy_rc=$?
 assert_eq 1 "$busy_rc" 'core update busy status'
 assert_eq 'Another core update is running [E:core_busy]' "$(jq -r .error <<<"$busy_out")" 'core update busy error'
 assert_eq false "$(jq -r .updated <<<"$busy_out")" 'busy update does not update'
 assert_eq false "$(jq -r .restarted <<<"$busy_out")" 'busy update does not restart'
 assert_file_contains "$tmpdir/core-busy.err" 'Error: Another core update is running' 'busy stderr'
)
pass 'core update busy'

# polish: restart error kept
(
 set -e
 restart_rc=0
 restart_out="$(UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=1 EXPECT_RESTART=0 RESTART_ERROR='Xray rejected the configuration' sh "$tmpdir/core-cli.sh" core-update 2>"$tmpdir/restart-detail.err")" || restart_rc=$?
 assert_eq 1 "$restart_rc" 'restart error status'
 assert_eq 'Xray core updated, but the service restart failed: Xray rejected the configuration [E:core_restart|Xray rejected the configuration]' "$(jq -r .error <<<"$restart_out")" 'restart error kept'
)
pass 'restart error kept'

# polish: lock released before restart
(
 set -e
 lock_out="$(UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=0 EXPECT_RESTART=0 RESTART_LOCK_CHECK=1 sh "$tmpdir/core-cli.sh" core-update)" || fail 'restart cannot take core lock'
 assert_eq true "$(jq -r .restarted <<<"$lock_out")" 'lock released before restart'
 assert_file_contains "$CORE_STATE_DIR/restart.lock" released 'init takes independent core lock'
)
pass 'lock released before restart'

assert_eq 'backend lists-json' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" lists-json)" 'lists-json read wrapper'
sed -i '/^case "$cmd" in/i lists_json() { echo lists-json; }' "$tmpdir/cli.sh"
assert_eq lists-json "$(sh "$tmpdir/cli.sh" lists-json)" 'lists-json CLI dispatch'
assert_false 'lists-json backend extra args rejected' sh "$tmpdir/cli.sh" lists-json x >/dev/null 2>&1
assert_eq 'lists:-:/tmp/xraywrt-policy-list.a:-' "$(sh "$tmpdir/cli.sh" apply-lists - /tmp/xraywrt-policy-list.a -)" 'CLI forwards unchanged sentinels'
pass 'lists-json and partial apply CLI boundary'

assert_eq 'backend job-status' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" job-status)" 'active job read wrapper'
assert_eq 'backend job-status 123-456' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" job-status 123-456)" 'specific job read wrapper'
for bad in 'job-start update-lists' 'job-run 1-2 update-lists' 'job-status ../x' 'job-status 1-2 x' 'job-status 1-x'; do
 # shellcheck disable=SC2086
 assert_false "read wrapper rejects $bad" env XRAYWRT_BACKEND="$backend" sh "$read_cli" $bad >/dev/null 2>&1
done
sed -i '/^case "$cmd" in/i job_start() { printf "job-start:%s\\n" "$*"; }; job_status() { printf "job-status:%s\\n" "$*"; }; job_run() { printf "job-run:%s\\n" "$*"; }' "$tmpdir/cli.sh"
assert_eq 'job-start:update-lists' "$(sh "$tmpdir/cli.sh" job-start update-lists)" 'job-start CLI dispatch'
assert_eq 'job-status:1-2' "$(sh "$tmpdir/cli.sh" job-status 1-2)" 'job-status CLI dispatch'
assert_eq 'job-run:1-2 service stop' "$(sh "$tmpdir/cli.sh" job-run 1-2 service stop)" 'internal job-run CLI dispatch'
pass 'job CLI boundary'

# Exercise real config locking and CLI dispatch with harmless config operations.
strip_xraywrt_cli_bootstrap >"$tmpdir/config-cli.sh"
sed '/^cmd=/,$d' "$tmpdir/config-cli.sh" >"$tmpdir/config-prefix.sh"
cat >>"$tmpdir/config-prefix.sh" <<'STUBS'
. "$XRAYWRT_LIB_DIR/config.sh"
settings_load() { echo settings >>"$CONFIG_ORDER"; }
with_lock() { echo lock >>"$CONFIG_ORDER"; "$@"; }
config_save() { printf 'save:%s\n' "$1" >>"$CONFIG_ORDER"; return "${CONFIG_RC:-0}"; }
config_restore() { echo restore >>"$CONFIG_ORDER"; return "${CONFIG_RC:-0}"; }
STUBS
sed -n '/^cmd=/,$p' "$tmpdir/config-cli.sh" >>"$tmpdir/config-prefix.sh"
mv "$tmpdir/config-prefix.sh" "$tmpdir/config-cli.sh"
export CONFIG_ORDER="$tmpdir/config-order"
: >"$CONFIG_ORDER"
sh "$tmpdir/config-cli.sh" restore-config
# No API wait any more (spec 9.4): config operations go straight to the lock.
assert_eq $'lock\nrestore' "$(cat "$CONFIG_ORDER")" 'cli restore runs under the lock'
pass 'cli restore runs under the lock'
: >"$CONFIG_ORDER"
sh "$tmpdir/config-cli.sh" save-config /tmp/xraywrt-config.test
assert_eq $'lock\nsave:/tmp/xraywrt-config.test' "$(cat "$CONFIG_ORDER")" 'cli save runs under the lock'
for op in save-config restore-config; do
 rc=0
 CONFIG_RC=7 sh "$tmpdir/config-cli.sh" "$op" /tmp/xraywrt-config.test || rc=$?
 assert_eq 7 "$rc" "$op returns locked operation status"
done
pass 'config CLI lock and return status'

# core-update CLI (spec 4.3): options pass unchanged through the real lock wrapper.
sed '/^case "$cmd" in/i core_update_json() { for a; do command printf "[%s]" "$a"; done >"$CORE_STATE_DIR/file-args"; echo '\''{"updated":false,"version":"1.2.3","error":null}'\''; }' "$tmpdir/core-cli.sh" >"$tmpdir/offline-cli.sh"
forwarded() {
 : >"$CORE_STATE_DIR/file-args"
 EXPECT_RESTART=0 sh "$tmpdir/offline-cli.sh" core-update "$@" >/dev/null || fail "core-update $* rejected"
 cat "$CORE_STATE_DIR/file-args"
}
assert_eq '' "$(forwarded)" 'no options: XrayWRT core package'
assert_false 'removed channel option rejected' sh "$tmpdir/offline-cli.sh" core-update --channel Jolymmiles/Xray-core >/dev/null 2>&1
assert_eq '[--no-rollback]' "$(forwarded --no-rollback)" 'no-rollback forwarded'
assert_false 'removed channel with no-rollback rejected' sh "$tmpdir/offline-cli.sh" core-update --channel a/b --no-rollback >/dev/null 2>&1
for args in '--file /tmp/xray' '--file' '--channel' '--unknown path' '--no-rollback --file /tmp/xray' 'path' '--no-rollback --no-rollback' '--channel a/b --channel c/d'; do
 # shellcheck disable=SC2086
 assert_false "invalid core arguments rejected: $args" sh "$tmpdir/offline-cli.sh" core-update $args >/dev/null 2>&1
done
assert_false 'empty channel rejected' sh "$tmpdir/offline-cli.sh" core-update --channel '' >/dev/null 2>&1
acl="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-xraywrt.json"
assert_eq 'null' "$(jq -c '."luci-app-xraywrt".write.file["/tmp/xraywrt-core.*"] // null' "$acl")" 'no ACL to upload a core file'
pass 'core-update CLI options'

# core-check: real dispatch, no arguments, not in the read wrapper (network + core.flock).
sed '/^case "$cmd" in/i core_check_locked() { echo "check:$*"; }' "$tmpdir/core-cli.sh" >"$tmpdir/check-cli.sh"
assert_eq 'check:' "$(sh "$tmpdir/check-cli.sh" core-check)" 'core-check dispatch'
assert_false 'core-check rejects arguments' sh "$tmpdir/check-cli.sh" core-check x >/dev/null 2>&1
assert_false 'read wrapper rejects core-check' env XRAYWRT_BACKEND="$backend" sh "$read_cli" core-check >/dev/null 2>&1
usage="$(sh "$tmpdir/cli.sh" 2>&1 || true)"
[[ "$usage" == *'core-update [--no-rollback]'* && "$usage" == *core-check* ]] || fail "usage lists core commands: $usage"
pass 'core-check CLI'

# B3: read-only list, state-changing override under the existing runtime lock.
assert_eq 'backend balancers' "$(XRAYWRT_BACKEND="$backend" sh "$read_cli" balancers)" 'balancers read wrapper'
assert_false 'read wrapper denies balancer-set' env XRAYWRT_BACKEND="$backend" sh "$read_cli" balancer-set main node-a
sed '/^case "$cmd" in/i balancers_json() { echo listed; }; balancer_set() { printf "set:%s:%s\\n" "$1" "$2"; }; with_lock() { printf "locked:"; "$@"; }' "$tmpdir/cli.sh" >"$tmpdir/balancer-cli.sh"
assert_eq listed "$(sh "$tmpdir/balancer-cli.sh" balancers)" 'balancers dispatch'
assert_eq 'locked:set:main:' "$(sh "$tmpdir/balancer-cli.sh" balancer-set main '')" 'empty target preserved under lock'
assert_false 'set needs target argument' sh "$tmpdir/balancer-cli.sh" balancer-set main
assert_false 'list has no arguments' sh "$tmpdir/balancer-cli.sh" balancers extra
pass 'balancer CLI boundary'

sh "$tmpdir/offline-cli.sh" core-update --channel a/b >"$tmpdir/channel.out" 2>&1 && fail 'removed channel accepted'
assert_file_not_contains "$ROOT_DIR/rootfs/usr/lib/xraywrt/core.sh" 'alternate channels' 'no dead channel branch'
