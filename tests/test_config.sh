#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh dns.sh config.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"

FX="$ROOT_DIR/tests/fixtures/xray"
# src <jq filter>: a provider config derived from the single-node fixture.
src() { jq "${1:-.}" "$FX/src/single.json"; }
PKG_TMP_DIR="$tmpdir/tmp"
XRAY_DIR="$tmpdir/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_CONFIG_BACKUP="$XRAY_DIR/config.json.bak"
RUNTIME_CONFIG="$tmpdir/runtime.json"
SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
mkdir -p "$XRAY_DIR"
echo "$$" >"$SUPERVISOR_PID_FILE"
XRAY_BIN="$tmpdir/xray-bin"
# Fake `xray run -test -c <file>`: an outbound tagged BROKEN is rejected.
cat >"$XRAY_BIN" <<'C'
#!/bin/sh
if grep -q BROKEN "$4"; then echo "Failed to start: proxy 0: missing type"; exit 1; fi
exit 0
C
chmod +x "$XRAY_BIN"
src '.remarks = "A"' >"$XRAY_CONFIG"
core_up=0
service_running() { [ "$core_up" = 1 ]; }
service_ready() { [ "$core_up" = 1 ]; }
cron_update() { :; }
policy_apply() { :; }
restart_ok=1
xray_api_apply() { return 1; } # Restart rollback coverage; API success has a separate suite.
core_restart() { echo restart >>"$tmpdir/events"; [ "$restart_ok" = 1 ] && geodata_snapshot; }

runtime_config_fixture() {
 setup_runtime_paths "$tmpdir/runtime-$1"
 RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
}

# polish: runtime file
(
 set -e
 runtime_config_fixture file
 cp "$FX/out/single.proxy-first.json" "$RUNTIME_CONFIG"
 declare -F runtime_config_json >/dev/null || fail 'runtime_config_json helper missing (runtime file)'
 runtime_config_json >"$tmpdir/runtime-file.json"
 assert_eq false "$(jq -r .generated "$tmpdir/runtime-file.json")" 'runtime file is not a generated preview'
 jq -j .content "$tmpdir/runtime-file.json" >"$tmpdir/runtime-file.content"
 # Spec 15: secrets are shown as "***", everything else as is.
 secrets='["id","password","privateKey","publicKey","shortId","pass","user","secretKey","preSharedKey"]'
 jq -S --argjson k "$secrets" 'walk(if type == "object" then with_entries(if .key as $x | $k | index($x) then .value = "***" else . end) else . end)' \
  "$RUNTIME_CONFIG" >"$tmpdir/runtime-file.want"
 jq -S . "$tmpdir/runtime-file.content" >"$tmpdir/runtime-file.got"
 assert_true 'runtime file shown with hidden secrets' cmp -s "$tmpdir/runtime-file.want" "$tmpdir/runtime-file.got"
 id="$(jq -r '[.. | objects | .id? // empty] | first' "$RUNTIME_CONFIG")"
 [ -n "$id" ] || fail 'fixture has a user id'
 assert_false 'runtime view has no user id' grep -qF "$id" "$tmpdir/runtime-file.content"
 jq '.outbounds[0].settings = {"servers": [{"address": "x", "port": 1, "users": [{"user": "u", "pass": "p"}]}]} | .outbounds[0].streamSettings = {"realitySettings": {"publicKey": "k", "shortId": "s"}}' \
  "$RUNTIME_CONFIG" >"$tmpdir/r.json" && mv "$tmpdir/r.json" "$RUNTIME_CONFIG"
 runtime_config_json | jq -r .content | jq -e '.outbounds[0].settings.servers[0].users[0] == {user: "***", pass: "***"} and .outbounds[0].streamSettings.realitySettings == {publicKey: "***", shortId: "***"}' >/dev/null ||
  fail 'socks and reality secrets hidden'
)
pass 'runtime file'

# polish: preview leaves no scratch (production layout: the profile lives in PKG_TMP_DIR)
(
 set -e
 runtime_config_fixture preview
 # shellcheck disable=SC2030 # subshell-local on purpose
 PROFILE_FILE="$PKG_TMP_DIR/config.json.profile"
 src '.xraywrt = {"disable-quic": true, "proxy-ips": ["https://10.0.0.1/x"]}' >"$XRAY_CONFIG"
 before_scratch="$(ls -A "$PKG_TMP_DIR")"
 : >"$tmpdir/preview.log"
 logger() { echo "$*" >>"$tmpdir/preview.log"; }
 xray_config_test() { fail 'runtime preview must not test with the Xray core'; }
 declare -F runtime_config_json >/dev/null || fail 'runtime_config_json helper missing (preview)'
 runtime_config_json >"$tmpdir/runtime-preview.json"
 assert_eq true "$(jq -r .generated "$tmpdir/runtime-preview.json")" 'missing runtime produces generated preview'
 jq -j .content "$tmpdir/runtime-preview.json" >"$tmpdir/runtime-preview.content"
 assert_eq true "$(jq '[.inbounds[].tag] | index("xraywrt-tproxy4") != null' "$tmpdir/runtime-preview.content")" 'preview contains router inbounds'
 assert_eq false "$(jq 'has("xraywrt")' "$tmpdir/runtime-preview.content")" 'preview removes the provider key'
 after_scratch="$(ls -A "$PKG_TMP_DIR")"
 # The only allowed new entry is the provider profile built by settings_load.
 assert_eq "$(printf '%s\n%s' "$before_scratch" config.json.profile | grep -v '^$' | sort)" "$(printf '%s\n' "$after_scratch" | sort)" 'preview leaves only the profile'
 assert_false 'no runtime-preview scratch' compgen -G "$PKG_TMP_DIR/runtime-preview.*"
 assert_false 'no tmp files' compgen -G "$PKG_TMP_DIR/*.tmp.*"
 assert_false 'preview logs no warnings (each opening of the view)' test -s "$tmpdir/preview.log"
)
pass 'preview leaves no scratch'

# polish: no config
(
 set -e
 runtime_config_fixture missing
 declare -F runtime_config_json >/dev/null || fail 'runtime_config_json helper missing (no config)'
 missing_rc=0
 runtime_config_json >"$tmpdir/runtime-missing.out" 2>"$tmpdir/runtime-missing.err" || missing_rc=$?
 assert_eq 1 "$missing_rc" 'runtime-config without a config fails'
 assert_eq "Error: Xray config not found: $XRAY_CONFIG [E:config_missing|$XRAY_CONFIG]" "$(cat "$tmpdir/runtime-missing.err")" 'no config'
)
pass 'no config'

# polish: backup is a hard link; backup fallback
check_config_backup() {
  set -e
  local XRAY_DIR XRAY_CONFIG XRAY_CONFIG_BACKUP RUNTIME_CONFIG old_inode
  setup_runtime_paths "$tmpdir/backup-$backup_mode"
  XRAY_DIR="$tmpdir/backup-$backup_mode/xray"
  XRAY_CONFIG="$XRAY_DIR/config.json"
  XRAY_CONFIG_BACKUP="$XRAY_CONFIG.bak"
  RUNTIME_CONFIG="$PKG_TMP_DIR/runtime.json"
  mkdir -p "$XRAY_DIR"
  src '.remarks = "A"' >"$XRAY_CONFIG"
  src '.remarks = "B"' >"$PKG_TMP_DIR/candidate.json"
  old_inode="$(stat -c %i "$XRAY_CONFIG")"
  if [ "$backup_mode" = fallback ]; then ln() { return 1; }; fi
  config_install "$PKG_TMP_DIR/candidate.json" >/dev/null
  assert_eq A "$(jq -r .remarks "$XRAY_CONFIG_BACKUP")" "backup $backup_mode content"
  if [ "$backup_mode" = hardlink ]; then
   assert_eq "$old_inode" "$(stat -c %i "$XRAY_CONFIG_BACKUP")" 'backup is a hard link'
   [ "$old_inode" != "$(stat -c %i "$XRAY_CONFIG")" ] || fail 'new config must use another inode'
  fi
}
for backup_mode in hardlink fallback; do
 (check_config_backup)
 pass "backup $backup_mode"
done

src '.outbounds[0].tag = "BROKEN"' >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "invalid config must be rejected"; fi
assert_eq A "$(jq -r .remarks "$XRAY_CONFIG")" "source unchanged"
assert_file_contains "$tmpdir/err" "missing type" "Xray error passed to the user"
assert_file_contains "$tmpdir/err" "Xray rejected the configuration" "core rejection reported"
cp "$FX/src/bad-notjson.txt" "$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "non-JSON config must be rejected"; fi
assert_eq 'Error: config: not JSON [E:config_json]' "$(cat "$tmpdir/err")" "format error from the generator (spec 5.1)"
assert_eq A "$(jq -r .remarks "$XRAY_CONFIG")" "source unchanged after a format error"
pass "save rejects invalid"

src '.remarks = "B"' >"$tmpdir/cand"
assert_eq 'saved' "$(config_install "$tmpdir/cand" | xraywrt-json get action)" "saved while stopped"
assert_eq B "$(jq -r .remarks "$XRAY_CONFIG")" "installed"
assert_eq A "$(jq -r .remarks "$XRAY_CONFIG_BACKUP")" "backup kept"
pass "save while stopped"

core_up=1
: >"$tmpdir/events"
src '.remarks = "C" | .routing.rules += [{"port": "25", "outboundTag": "block"}]' >"$tmpdir/cand"
assert_eq 'restarted' "$(config_install "$tmpdir/cand" | xraywrt-json get action)" "core restarted while running"
assert_eq restart "$(cat "$tmpdir/events")" "one core restart"
assert_eq '25' "$(jq -r '.routing.rules[-1].port' "$RUNTIME_CONFIG")" "new runtime published"
pass "restart while running"

# A supervisor still starting: refuse at once instead of two restart waits.
service_ready() { return 1; }
: >"$tmpdir/events"
src '.remarks = "S"' >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "publish while starting must be refused"; fi
assert_file_contains "$tmpdir/err" "E:runtime_busy" "starting supervisor: busy"
assert_eq C "$(jq -r .remarks "$XRAY_CONFIG")" "source unchanged while starting"
assert_eq '' "$(cat "$tmpdir/events")" "no restart requested while starting"
service_ready() { [ "$core_up" = 1 ]; }
pass "publish while starting is busy"

restart_ok=0
cp "$RUNTIME_CONFIG" "$tmpdir/runtime.before"
src '.remarks = "D" | .routing.rules += [{"port": "26", "outboundTag": "block"}]' >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "failed restart must fail"; fi
assert_eq C "$(jq -r .remarks "$XRAY_CONFIG")" "previous config restored"
assert_true "previous runtime restored" cmp -s "$tmpdir/runtime.before" "$RUNTIME_CONFIG"
assert_file_contains "$tmpdir/err" 'new config failed to start, previous restored' "rollback error (spec 9.3)"
assert_false "no runtime .prev left" test -e "$RUNTIME_CONFIG.prev"
assert_false "failed restore after API work drops the geodata snapshot" test -e "$RUNTIME_CONFIG.geodata"
geodata_snapshot # the next core_spawn records it again
restart_ok=1
pass "apply rollback"

assert_false "path outside tmp" config_temp_path_allowed /etc/hosts
assert_false "nested path" config_temp_path_allowed /tmp/xraywrt-config.x/y
link="/tmp/xraywrt-config.testlink.$$"
ln -s /etc/hosts "$link"
assert_false "symlink" config_temp_path_allowed "$link"
rm -f "$link"
assert_eq C "$(config_read_json | jq -r .content | jq -r .remarks)" "read config"
pass "config paths"


core_up=1
service_running() { [ "$core_up" = 1 ]; }
service_ready() { [ "$core_up" = 1 ]; }
policy_apply() { echo policy >>"$tmpdir/events"; }
cron_update() { echo cron >>"$tmpdir/events"; }
dns_restart_dnsmasq() { echo dns-restart >>"$tmpdir/events"; }
src '.xraywrt = {"disable-quic": true}' >"$XRAY_CONFIG"
xray_config_generate "$XRAY_CONFIG" "$RUNTIME_CONFIG"
# shellcheck disable=SC2031 # set only inside the preview subshell
cp "$RUNTIME_CONFIG.profile" "$PROFILE_FILE"
cp "$XRAY_CONFIG" "$tmpdir/cand"
touch -d '2000-01-01' "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP"
: >"$tmpdir/events"
assert_eq 'unchanged' "$(config_install "$tmpdir/cand" | xraywrt-json get action)" "unchanged action"
assert_eq 946684800 "$(stat -c %Y "$XRAY_CONFIG")" "unchanged preserves source mtime"
assert_eq 946684800 "$(stat -c %Y "$XRAY_CONFIG_BACKUP")" "unchanged preserves backup mtime"
assert_eq '' "$(cat "$tmpdir/events")" "unchanged no restart"
src '.xraywrt = {"disable-quic": false}' >"$tmpdir/cand"
assert_eq 'saved' "$(config_install "$tmpdir/cand" | xraywrt-json get action)" "provider-key-only change keeps the core"
assert_eq $'cron\npolicy' "$(cat "$tmpdir/events")" "provider-key-only change applies profile without restart"
# A provider mode flip changes the runtime (WAN DNS go direct in direct-first).
src '.xraywrt = {"mode": "direct-first"}' >"$tmpdir/cand"
: >"$tmpdir/events"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'restart\ncron\npolicy' "$(cat "$tmpdir/events")" "mode flip restarts the core and applies policy without DNS restart"
assert_eq direct-first "$(profile_get mode)" "provider key flips mode"
# fakedns servers switch fake-IP on: the dnsmasq cache is flushed exactly once.
src '.xraywrt = {"mode": "direct-first"} | .dns.servers = [{"address": "fakedns"}, "https://dns.example.com/dns-query"]' >"$tmpdir/cand"
: >"$tmpdir/events"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'restart\ncron\npolicy\ndns-restart' "$(cat "$tmpdir/events")" "DNS mode flushes cache exactly once"
assert_eq 0 "$(profile_get fake-domains)" "fakedns domains counted in the profile"
: >"$tmpdir/events"
jq '.log = {"loglevel": "info"}' "$tmpdir/cand" >"$tmpdir/cand.next" && mv "$tmpdir/cand.next" "$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'restart\ncron\npolicy' "$(cat "$tmpdir/events")" "provider log level change applied with one restart"
: >"$tmpdir/events"
jq '.routing.rules += [{"port": "27", "outboundTag": "block"}]' "$tmpdir/cand" >"$tmpdir/cand.next" && mv "$tmpdir/cand.next" "$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq restart "$(cat "$tmpdir/events")" "same profile no policy or DNS restart"
: >"$tmpdir/events"
src '.xraywrt = {"mode": "direct-first"}' >"$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null
assert_eq $'restart\ncron\npolicy\ndns-restart' "$(cat "$tmpdir/events")" 'removing last FakeDNS flushes cache exactly once'
assert_eq 0 "$(profile_get fake-enabled)" 'removing last FakeDNS clears activation'
src '.outbounds[0].tag = "BROKEN"' >"$XRAY_CONFIG"
assert_false "prepare failure" runtime_config_build "$RUNTIME_CONFIG"
assert_file_contains "$CONFIG_ERR_FILE" 'missing type' "prepare records error"
src >"$XRAY_CONFIG"
runtime_config_build "$RUNTIME_CONFIG"
assert_true "prepare records success" test -f "$CONFIG_OK_FILE"
assert_false "prepare clears error" test -f "$CONFIG_ERR_FILE"
pass "no-op install, restart/profile/DNS transitions and prepare check records"

# Exercise the real save-config dispatch, including its upload path guard.
load_modules subscription.sh
sed '/^LIB=/,/xraywrt_load_modules.*exit 1/d' "$ROOT_DIR/rootfs/usr/bin/xraywrt" >"$tmpdir/cli.sh"
config_cli() { ( set -- "$@"; source "$tmpdir/cli.sh"; ); }
upload="/tmp/xraywrt-config.safety.$$"
trap 'rm -rf "$tmpdir"; rm -f "$upload"' EXIT
for candidate in '' $'\n  \n' $'# only\n# comments\n'; do
 printf '%s' "$candidate" >"$upload"
 cp "$XRAY_CONFIG" "$tmpdir/source.before"
 cp "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.before"
 : >"$tmpdir/events"
 rc=0
 config_cli save-config "$upload" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 assert_eq 1 "$rc" 'empty config rejected'
 case "$candidate" in
 '#'*) assert_eq 'Error: config: not JSON [E:config_json]' "$(cat "$tmpdir/err")" 'comments are not JSON' ;;
 *) assert_eq 'Error: The config is empty: nothing was changed. [E:config_empty]' "$(cat "$tmpdir/err")" 'empty config message' ;;
 esac
 assert_true 'empty preserves installed config' cmp -s "$XRAY_CONFIG" "$tmpdir/source.before"
 assert_true 'empty preserves backup' cmp -s "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.before"
 assert_eq '' "$(cat "$tmpdir/events")" 'empty does not restart'
done
pass 'empty config rejected'

src >"$upload"
truncate -s 8388609 "$upload"
rc=0
config_cli save-config "$upload" >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'oversize rejected'
assert_eq 'Error: The config is larger than 8 MiB. [E:config_large]' "$(cat "$tmpdir/err")" 'oversize message'
assert_true 'oversize preserves installed config' cmp -s "$XRAY_CONFIG" "$tmpdir/source.before"
assert_true 'oversize preserves backup' cmp -s "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.before"
assert_eq '' "$(cat "$tmpdir/events")" 'oversize does not restart'
pass 'oversize rejected'

for body in '{}' ' x' $'\n\t{"outbounds": []}'; do
 printf '%s\n' "$body" >"$tmpdir/keys"
 assert_true 'non-blank content recognized' config_has_keys "$tmpdir/keys"
done
printf ' \n\t\n' >"$tmpdir/keys"
assert_false 'blank content is empty' config_has_keys "$tmpdir/keys"
pass 'config_has_keys contract'

service_running() { return 0; }
service_ready() { return 0; }
src '.remarks = "A"' >"$XRAY_CONFIG"
src '.remarks = "B" | .routing.rules += [{"port": "28", "outboundTag": "block"}]' >"$XRAY_CONFIG_BACKUP"
: >"$tmpdir/events"
assert_eq 'restarted' "$(config_cli restore-config | xraywrt-json get action)" 'restore action'
assert_eq B "$(jq -r .remarks "$XRAY_CONFIG")" 'restore installs B'
assert_eq A "$(jq -r .remarks "$XRAY_CONFIG_BACKUP")" 'restore backs up A'
assert_file_contains "$tmpdir/events" restart 'restore restarts the core'
config_cli restore-config >/dev/null
assert_eq A "$(jq -r .remarks "$XRAY_CONFIG")" 'second restore installs A'
assert_eq B "$(jq -r .remarks "$XRAY_CONFIG_BACKUP")" 'second restore backs up B'
rm "$XRAY_CONFIG_BACKUP"
rc=0
config_cli restore-config 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'missing backup rejected'
assert_eq 'Error: There is no previous configuration. [E:config_no_previous]' "$(cat "$tmpdir/err")" 'missing backup message'
pass 'restore swaps'

src '.outbounds[0].tag = "BROKEN"' >"$XRAY_CONFIG_BACKUP"
cp "$XRAY_CONFIG" "$tmpdir/source.before"
cp "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.before"
: >"$tmpdir/events"
rc=0
config_cli restore-config >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
assert_eq 1 "$rc" 'broken backup rejected'
assert_true 'broken backup preserves installed config' cmp -s "$XRAY_CONFIG" "$tmpdir/source.before"
assert_true 'broken backup stays unchanged' cmp -s "$XRAY_CONFIG_BACKUP" "$tmpdir/backup.before"
assert_eq '' "$(find "$PKG_TMP_DIR" -name 'restore.*' -print)" 'broken restore removes temporary file'
assert_eq '' "$(cat "$tmpdir/events")" 'broken restore does not restart'
pass 'broken backup restore is safe'

for candidate in $'\357\273\277{"outbounds": [{"protocol": "freedom"}]}\n' $'{"outbounds": [{"protocol": "blackhole"}]}\r\n'; do
 printf '%s' "$candidate" >"$upload"
 (
  awk() { busybox awk "$@"; }
  assert_true 'BusyBox awk accepts BOM or CRLF config' config_has_keys "$upload"
 )
 assert_true 'save-config accepts BOM or CRLF JSON' config_cli save-config "$upload"
done
pass 'BOM and CRLF JSON accepted'
