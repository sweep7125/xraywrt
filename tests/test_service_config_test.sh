#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh xray-config.sh core.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.json"
XRAY_SHARE_DIR="$tmpdir/share"
mkdir -p "$XRAY_SHARE_DIR"
XRAY_BIN="$tmpdir/core"
export TEST_CORE_DIR="$tmpdir"
cat >"$XRAY_BIN" <<'CORE'
#!/bin/sh
if [ "$1" = version ]; then cat "$TEST_CORE_DIR/version"; exit 0; fi
echo test >>"$TEST_CORE_DIR/calls"
[ ! -f "$TEST_CORE_DIR/reject" ] || { echo 'invalid config' >&2; exit 1; }
CORE
chmod +x "$XRAY_BIN"
printf 'Xray 1.2.3 (Xray, Penetrates Everything.)\n' >"$tmpdir/version"
printf '{"remarks":"A"}\n' >"$XRAY_CONFIG"
xray_config_generate() { cp "$1" "$2"; printf 'profile\n' >"$2.profile"; }
xray_config_key() { return 1; }
settings_load() { :; }
cron_update() { :; }
service_ready() { return 0; }
policy_apply() { :; }
assert_stamp() {
 local hash share
 hash="$(sha256sum "$1" | cut -d' ' -f1)"
 # shellcheck disable=SC2012 # the same listing xray_config_test_key hashes
 share="$(ls -ln "$XRAY_SHARE_DIR" | sha256sum | cut -d' ' -f1)"
 assert_true 'successful config test writes stamp' test -f "$CONFIG_TESTED_FILE"
 assert_eq "$hash $2 $share" "$(cat "$CONFIG_TESTED_FILE")" 'stamp identifies config bytes, tested core and geodata'
}
run_case() (
 case "$1" in
 miss)
  # File arguments only: the geodata listing is hashed from stdin.
  sha256sum() { [ $# -eq 0 ] || echo hash >>"$tmpdir/hashes"; command sha256sum "$@"; }
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/hashes" | tr -d ' ')" 'start stamp miss hashes runtime config only once'
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'start stamp miss tests core'
  assert_stamp "$RUNTIME_CONFIG" 1.2.3
  ;;
 hit)
  runtime_config_build "$RUNTIME_CONFIG"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'start stamp hit skips duplicate core test'
  assert_stamp "$RUNTIME_CONFIG" 1.2.3
  ;;
 config)
  runtime_config_build "$RUNTIME_CONFIG"
  printf '{"remarks":"B"}\n' >"$XRAY_CONFIG"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 2 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'config change retests core'
  assert_stamp "$RUNTIME_CONFIG" 1.2.3
  ;;
 core)
  runtime_config_build "$RUNTIME_CONFIG"
  printf 'Xray 1.2.4 (Xray, Penetrates Everything.)\n' >"$tmpdir/version"
  rm -f "$CORE_VERSION_CACHE"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 2 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'core version change retests config'
  assert_stamp "$RUNTIME_CONFIG" 1.2.4
  ;;
 geodata)
  xray_config_generate() { cp "$1" "$2"; printf 'geodata-ref geosite.dat\n' >"$2.profile"; }
  printf 'v1\n' >"$XRAY_SHARE_DIR/geosite.dat"
  printf 'x\n' >"$XRAY_SHARE_DIR/unused.dat"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_false 'start prunes unused geodata before the stamp' test -e "$XRAY_SHARE_DIR/unused.dat"
  printf 'v2-longer\n' >"$XRAY_SHARE_DIR/geosite.dat"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 2 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'geodata change retests config'
  assert_stamp "$RUNTIME_CONFIG" 1.2.3
  ;;
 candidate)
  xray_config_test "$XRAY_CONFIG" "$XRAY_BIN"
  assert_stamp "$XRAY_CONFIG" 1.2.3
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'successful explicit-binary test seeds start stamp'
  ;;
 failed)
  touch "$tmpdir/reject"
  assert_false 'rejected config fails' xray_config_test "$XRAY_CONFIG" 2>/dev/null
  assert_false 'failed first test does not stamp' test -e "$CONFIG_TESTED_FILE"
  rm "$tmpdir/reject"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_stamp "$RUNTIME_CONFIG" 1.2.3
  cp "$CONFIG_TESTED_FILE" "$tmpdir/stamp.before"
  touch "$tmpdir/reject"
  printf '{"remarks":"B"}\n' >"$XRAY_CONFIG"
  assert_false 'changed rejected config fails start' runtime_config_build "$RUNTIME_CONFIG" 2>/dev/null
  assert_true 'failed test preserves previous stamp' cmp -s "$tmpdir/stamp.before" "$CONFIG_TESTED_FILE"
  ;;
 reload)
  runtime_config_build "$RUNTIME_CONFIG"
  printf '{"remarks":"B"}\n' >"$XRAY_CONFIG"
  xray_config_test "$XRAY_CONFIG"
  assert_stamp "$XRAY_CONFIG" 1.2.3
  service_reload
  assert_eq 3 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'changed reload tests even with matching stamp'
  ;;
 esac
)
cases=(miss hit config core geodata candidate failed reload)
[ $# -eq 0 ] || cases=("$@")
for scenario in "${cases[@]}"; do
 rm -f "$tmpdir/calls" "$tmpdir/hashes" "$tmpdir/reject" "$CONFIG_TESTED_FILE" "$CORE_VERSION_CACHE" "$XRAY_SHARE_DIR"/*
 printf 'Xray 1.2.3 (Xray, Penetrates Everything.)\n' >"$tmpdir/version"
 printf '{"remarks":"A"}\n' >"$XRAY_CONFIG"
 run_case "$scenario"
 pass "config test stamp: $scenario"
done
