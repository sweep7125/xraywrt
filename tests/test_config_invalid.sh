#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # subshell stubs
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh core.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"
XRAY_BIN="$tmpdir/core"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
cp "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$XRAY_CONFIG"
settings_load() { :; }
settings_ensure_generated() { :; }
service_recover() { :; }
runtime_dirs_init() { :; }
cron_update() { :; }
dns_guard() { :; }
xray_config_key() { return 1; }
xray_config_generate() { cp "$1" "$2"; }
for scenario in settings validation geodata missing_core nonexec_core lock layout config_rejected generate_io core_killed; do
 (
  rm -f "$CONFIG_INVALID_FILE" "$CONFIG_TESTED_FILE" "$CORE_VERSION_CACHE" "$CONFIG_ERR_FILE"
  mkdir -p "$PKG_STATE_DIR" && touch "$CONFIG_OK_FILE"
  printf '#!/bin/sh\n[ "$1" != version ] || { echo "Xray 1.2.3"; exit 0; }\nexit 0\n' >"$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  with_lock() { "$@"; }
  expected=no
  case "$scenario" in
  settings) settings_load() { settings_invalid lists_interval x; }; expected=yes ;;
  validation | geodata)
   printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$scenario rejected" >"$XRAY_BIN"
   expected=yes
   ;;
  core_killed) printf '#!/bin/sh\n[ "$1" != version ] || { echo "Xray 1.2.3"; exit 0; }\nkill -9 $$\n' >"$XRAY_BIN" ;;
  missing_core) rm "$XRAY_BIN" ;;
  nonexec_core) chmod -x "$XRAY_BIN" ;;
  lock) with_lock() { echo 'Error: runtime lock timed out' >&2; return 1; } ;;
  layout) runtime_dirs_init() { echo 'Error: layout failed' >&2; return 1; } ;;
  config_rejected) xray_config_generate() { return 2; }; expected=yes ;;
  generate_io) xray_config_generate() { return 1; } ;;
  esac
  if service_prepare_cmd 2>"$tmpdir/error"; then fail "$scenario must fail prepare"; fi
  if [ "$expected" = yes ]; then
   assert_true "$scenario blocks automatic restart" test -f "$CONFIG_INVALID_FILE"
  else
   assert_false "$scenario must not block automatic restart" test -e "$CONFIG_INVALID_FILE"
  fi
  if [ "$scenario" = core_killed ]; then
   # A killed check (OOM) is not a verdict on the config: the next hotplug retries.
   assert_file_contains "$tmpdir/error" '[E:config_test_oom]' 'killed check says memory, not rejection'
   assert_false 'killed check is not a rejection' grep -q config_rejected "$tmpdir/error"
   assert_false 'killed check clears the valid mark' test -e "$CONFIG_OK_FILE"
   assert_file_contains "$CONFIG_ERR_FILE" '[E:config_test_oom]' 'killed check is recorded for status'
  fi
  if [ "$scenario" = config_rejected ]; then
   # Diagnostics must say "has errors", not "not checked yet".
   assert_false 'parser rejection clears the valid mark' test -e "$CONFIG_OK_FILE"
   assert_true 'parser rejection records a failed check' test -f "$CONFIG_ERR_FILE"
  fi
 )
 pass "configuration invalid marker: $scenario"
done
(
 load_modules xray-config.sh lists.sh
 lists_profile_filter() { :; }
 dns_wan_servers() { echo 192.0.2.53; }
 rc=0
 xray_config_generate "$ROOT_DIR/tests/fixtures/xray/src/bad-notjson.txt" "$tmpdir/out.json" 2>/dev/null || rc=$?
 assert_eq 2 "$rc" 'generator rejection of the config returns 2'
 rc=0
 xray_config_generate "$tmpdir/missing.json" "$tmpdir/out.json" 2>/dev/null || rc=$?
 assert_eq 1 "$rc" 'unreadable source returns 1'
)
pass 'generator separates config rejection from other failures'
(
 load_modules xray-config.sh
 lists_profile_filter() { :; }
 XRAY_CONFIG="$tmpdir/hand.json"
 printf '{"outbounds":[{"tag":"direct","protocol":"freedom"}]}\n' >"$XRAY_CONFIG"
 xray_params_json() { jq '.wan_dns = []' "$ROOT_DIR/tests/fixtures/xray/params/default.json"; }
 dns_wan_servers() { :; }
 rc=0
 xray_config_generate "$XRAY_CONFIG" "$tmpdir/out.json" 2>/dev/null || rc=$?
 assert_eq 1 "$rc" 'no DNS server with an empty WAN DNS list is not a config rejection'
 dns_wan_servers() { echo 192.0.2.53; }
 xray_config_generate "$XRAY_CONFIG" "$tmpdir/out.json" 2>/dev/null || rc=$?
 assert_eq 2 "$rc" 'no DNS server with a WAN DNS list is a config rejection'
)
(
 rm -f "$CONFIG_INVALID_FILE"
 printf '#!/bin/sh\n[ "$1" != version ] || { echo "Xray 1.2.3"; exit 0; }\nexit 0\n' >"$XRAY_BIN"
 chmod +x "$XRAY_BIN"
 with_lock() { "$@"; }
 dns_wan_servers() { :; }
 xray_params_json() { jq '.wan_dns = []' "$ROOT_DIR/tests/fixtures/xray/params/default.json"; }
 lists_profile_filter() { :; }
 printf '{"outbounds":[{"tag":"direct","protocol":"freedom"}]}\n' >"$XRAY_CONFIG"
 unset -f xray_config_generate
 source "$XRAYWRT_LIB_DIR/xray-config.sh"
 service_prepare_cmd 2>/dev/null && fail 'empty WAN DNS fails the start'
 assert_false 'empty WAN DNS at boot does not block hotplug' test -e "$CONFIG_INVALID_FILE"
)
pass 'empty WAN DNS at boot is transient'
: >"$CONFIG_INVALID_FILE"
config_check_record ok
assert_false 'valid configuration clears invalid marker' test -e "$CONFIG_INVALID_FILE"
pass 'valid configuration clears invalid marker'
