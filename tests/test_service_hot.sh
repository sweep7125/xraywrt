#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
xray_test_bin 'hot apply preflight' || exit 0
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
export HOT_TEST_ROOT="$tmpdir" HOT_ROOT="$ROOT_DIR" XRAY_TEST_BIN XRAY_TEST_ASSETS
for scenario in hot rules_only add_only remove_only rmo_error ado_error rules_error override_error restart_error publish_error restore_error publish_restore_error domain_strategy default_order untagged duplicate \
 geodata_during_api geodata_during_override failed_fetch \
 changed_geodata same_config_geodata unknown_geodata new_geodata missing_geodata invalid_geodata invalid_config install; do
 ash -s "$scenario" <<'ASH'
set -eu
for m in constants helpers validate settings geodata xray-config lists dns config xray-api service; do . "$XRAYWRT_LIB_DIR/$m.sh"; done
scenario="$1"
dir="$HOT_TEST_ROOT/$scenario"
mkdir -p "$dir/tmp" "$dir/run" "$dir/share"
PKG_TMP_DIR="$dir/tmp" PKG_STATE_DIR="$dir/run" XRAY_SHARE_DIR="$dir/share"
RUNTIME_CONFIG="$dir/runtime.json" PROFILE_FILE="$dir/profile" XRAY_CONFIG="$dir/source.json"
XRAY_CONFIG_BACKUP="$dir/source.bak" SUPERVISOR_PID_FILE="$dir/run/supervisor.pid"
CONFIG_OK_FILE="$dir/run/config.ok" CONFIG_ERR_FILE="$dir/run/config.err" CONFIG_INVALID_FILE="$dir/run/config.invalid"
CONFIG_TESTED_FILE="$dir/run/config.tested" RUNTIME_LOCK_FILE="$dir/run/lock" GEODATA_TMP_DIR="$dir/tmp/geodata"
GEODATA_MANUAL_FILE="$dir/share/.manual" MEMINFO_FILE=/proc/meminfo
XRAY_BIN="$dir/core"
export HOT_DIR="$dir" HOT_FAIL='' HOT_MUTATE='' HOT_EXPECT_ASSET="$XRAY_SHARE_DIR"
cat >"$XRAY_BIN" <<'CORE'
#!/bin/sh
if [ "$1" != api ]; then
 echo test >>"$HOT_DIR/events"
 exec "$XRAY_TEST_BIN" "$@"
fi
[ "$2" = bo ] || [ "$XRAY_LOCATION_ASSET" = "$HOT_EXPECT_ASSET" ] || exit 1
echo "$2" >>"$HOT_DIR/events"
printf '%s\n' "$*" >>"$HOT_DIR/api"
for arg do last="$arg"; done
[ "$2" != ado ] || cp "$last" "$HOT_DIR/added.json"
[ "$2" != rmo ] || cp "$last" "$HOT_DIR/removed.json"
[ "$HOT_FAIL" != "$2" ] || exit 1
[ "$HOT_MUTATE" != "$2" ] || cp "$XRAY_TEST_ASSETS/geoip.dat" "$HOT_EXPECT_ASSET/geosite.dat"
CORE
chmod +x "$XRAY_BIN"
cp "$XRAY_TEST_ASSETS/geosite.dat" "$dir/share/geosite.dat"
jq '.outbounds += [{tag:"stable",protocol:"freedom"},{tag:"removed",protocol:"freedom"}]' "$HOT_ROOT/tests/fixtures/xray-api/config.json" >"$RUNTIME_CONFIG"
: >"$PROFILE_FILE"
echo $$ >"$SUPERVISOR_PID_FILE"
geodata_snapshot
jq '.outbounds |= (map(select(.tag != "removed")) | map(if .tag == "node-b" then .settings = {response:{type:"http"}} else . end) + [{tag:"added",protocol:"freedom"}])' "$RUNTIME_CONFIG" >"$XRAY_CONFIG"
: >"$XRAY_CONFIG.profile"
settings_load() { :; }
settings_balancer_overrides() { echo main=node-a; }
cron_update() { :; }
service_running() { return 0; }
service_ready() { return 0; }
policy_apply() { echo policy >>"$dir/events"; }
config_profile_apply() { :; }
core_version() { echo pinned; }
killall() { echo "$*" >>"$dir/hup"; }
core_restart() {
 echo restart >>"$dir/events"
 case "$scenario" in
  restart_error) cmp -s "$RUNTIME_CONFIG" "$dir/old.json" ;;
  restore_error | publish_restore_error) return 1 ;;
 esac
}
xray_config_key() { sha256sum "$1" | cut -d' ' -f1; }
xray_config_generate() { cp "$1" "$2"; cp "$1.profile" "$2.profile"; }
http_fetch() { cp "$XRAY_TEST_ASSETS/geosite.dat" "$2"; }
case "$scenario" in
 rules_only) jq '.routing.rules += [{domain:["full:other.test"],outboundTag:"node-a"}]' "$RUNTIME_CONFIG" >"$XRAY_CONFIG" ;;
 add_only) jq '.outbounds += [{tag:"added",protocol:"freedom"}]' "$RUNTIME_CONFIG" >"$XRAY_CONFIG" ;;
 remove_only) jq '.outbounds |= map(select(.tag != "removed"))' "$RUNTIME_CONFIG" >"$XRAY_CONFIG" ;;
 geodata_during_api) HOT_MUTATE=adrules ;;
 geodata_during_override) HOT_MUTATE=bo ;;
 rmo_error) HOT_FAIL=rmo ;;
 ado_error) HOT_FAIL=ado ;;
 rules_error | restart_error | restore_error) HOT_FAIL=adrules ;;
 override_error) HOT_FAIL=bo ;;
 publish_error | publish_restore_error)
  mv() { case "$*" in *config.candidate.json.profile*) return 1 ;; *) command mv "$@" ;; esac; }
  ;;
 domain_strategy) jq '.routing.domainStrategy = "IPIfNonMatch"' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG" ;;
 default_order) jq '.outbounds |= reverse' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG" ;;
 untagged) jq 'del(.outbounds[0].tag)' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG" ;;
 duplicate) jq '.outbounds += [.outbounds[0]]' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG" ;;
 changed_geodata | same_config_geodata)
  [ "$scenario" != same_config_geodata ] || cp "$RUNTIME_CONFIG" "$XRAY_CONFIG"
  # A valid but different same-name file not used by these rules.
  cp "$XRAY_TEST_ASSETS/geoip.dat" "$dir/share/geosite.dat"
  ;;
 unknown_geodata) rm "$RUNTIME_CONFIG.geodata" ;;
 new_geodata | missing_geodata | invalid_geodata | failed_fetch)
  jq '.routing.rules += [{domain:["ext:new.dat:private"],outboundTag:"node-a"}]' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG"
  echo 'geodata-ref new.dat' >"$XRAY_CONFIG.profile"
  case "$scenario" in
   new_geodata | failed_fetch) echo 'geodata new.dat https://example.test/new.dat' >>"$XRAY_CONFIG.profile" ;;
  esac
  [ "$scenario" != failed_fetch ] || http_fetch() { FETCH_ERROR=timeout; return 1; }
  [ "$scenario" != invalid_geodata ] || echo corrupt >"$dir/share/new.dat"
  ;;
 invalid_config) jq '.outbounds[0].protocol = "invalid"' "$XRAY_CONFIG" >"$dir/new"; mv "$dir/new" "$XRAY_CONFIG" ;;
esac
[ "$scenario" != same_config_geodata ] || runtime_config_key_store "$(xray_config_key "$XRAY_CONFIG")"
cp "$RUNTIME_CONFIG" "$dir/old.json"
cp "$PROFILE_FILE" "$dir/old.profile"
: >"$dir/events"
rc=0
if [ "$scenario" = install ]; then
 cp "$XRAY_CONFIG" "$dir/upload.json"; cp "$XRAY_CONFIG.profile" "$dir/upload.json.profile"
 cp "$RUNTIME_CONFIG" "$XRAY_CONFIG"
 with_lock config_install "$dir/upload.json" >"$dir/result" || rc=$?
 grep -q '"action":"hot_reloaded"' "$dir/result" || { cat "$dir/result"; exit 1; }
else
 with_lock service_reload || rc=$?
fi
case "$scenario" in
 missing_geodata | invalid_geodata | invalid_config | duplicate | failed_fetch)
  [ "$rc" = 1 ]
  [ ! -e "$dir/hup" ]
  cmp "$RUNTIME_CONFIG" "$dir/old.json"
  cmp "$PROFILE_FILE" "$dir/old.profile"
  [ ! -f "$dir/api" ]
  ! grep -q restart "$dir/events"
  ;;
 restart_error | publish_error | restore_error | publish_restore_error)
  [ "$rc" = 1 ]
  cmp "$RUNTIME_CONFIG" "$dir/old.json"
  cmp "$PROFILE_FILE" "$dir/old.profile"
  grep -q restart "$dir/events"
  # Unknown core state after partial API work: no snapshot forces restart.
  case "$scenario" in
   restore_error | publish_restore_error) [ ! -e "$RUNTIME_CONFIG.geodata" ] ;;
   *) [ -f "$RUNTIME_CONFIG.geodata" ] ;;
  esac
  ;;
 *)
  [ "$rc" = 0 ]
  # A published config flushes the dnsmasq cache exactly once.
  [ "$(cat "$dir/hup")" = '-HUP dnsmasq' ]
  if [ "$scenario" != install ]; then cmp "$RUNTIME_CONFIG" "$XRAY_CONFIG"; fi
  case "$scenario" in
   hot | new_geodata | install | rules_only | add_only | remove_only)
    [ "${RUNTIME_HOT_RELOADED:-0}" = 1 ] || { echo "$scenario: expected hot apply, got $(cat "$dir/events")" >&2; exit 1; }
    ! grep -q restart "$dir/events"
    case "$scenario" in
     rules_only) [ "$(tr '\n' ' ' <"$dir/events")" = 'test adrules bo policy ' ] ;;
     add_only) [ "$(tr '\n' ' ' <"$dir/events")" = 'test ado adrules bo policy ' ] ;;
     remove_only) [ "$(tr '\n' ' ' <"$dir/events")" = 'test rmo adrules bo policy ' ] ;;
     *)
    [ "$(jq -c . "$dir/removed.json")" = '{"outbounds":[{"tag":"node-b"},{"tag":"removed"}]}' ]
    grep -q '^api rmo --server=unix:/var/run/xraywrt/api.sock --timeout=30 ' "$dir/api"
    [ "$(jq -r '[.outbounds[].tag] | join(" ")' "$dir/added.json")" = 'node-b added' ]
    [ "$(grep -E '^(test|rmo|ado|adrules|bo)$' "$dir/events" | tr '\n' ' ')" = 'test rmo ado adrules bo ' ]
     ;;
    esac
    geodata_unchanged
    if [ "$scenario" = new_geodata ]; then
     echo changed >"$dir/share/new.dat"
     ! geodata_unchanged
    fi
    ;;
   *)
    [ "${RUNTIME_HOT_RELOADED:-0}" = 0 ]
    [ "$(grep -c '^restart$' "$dir/events")" = 1 ]
    ;;
  esac
  ;;
esac
[ ! -e "$dir/tmp/config.candidate.json" ]
[ ! -e "$dir/tmp/config.candidate.json.profile" ]
ASH
 pass "hot apply: $scenario"
done
