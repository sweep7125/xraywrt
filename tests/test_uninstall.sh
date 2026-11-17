#!/usr/bin/env bash
# uninstall_cleanup (spec 12): remove the core, geodata, core.json and caches;
# keep config.json, lists and UCI; never touch MihoWRT files.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh fetch.sh lists.sh subscription.sh service.sh pkg.sh core.sh
pkg_installed_names() { :; }
setup_runtime_paths "$tmpdir"
XRAY_BIN="$tmpdir/opt/xraywrt/bin/xray"
XRAY_CONFIG="$tmpdir/opt/xraywrt/config.json"
CORE_JSON_FILE="$PKG_PERSIST_DIR/core.json"
service_recover() { echo recover >>"$tmpdir/calls"; }
policy_cleanup() { echo cleanup >>"$tmpdir/calls"; }
nft_fw4_input_cleanup() { echo fw4-include >>"$tmpdir/calls"; }
cron_sync() { echo "cron $*" >>"$tmpdir/calls"; }

mkdir -p "${XRAY_BIN%/*}" "$XRAY_SHARE_DIR" "$PKG_PERSIST_DIR" "$LIST_DIR" "$POLICY_CACHE_DIR" "$PKG_TMP_DIR" "$PKG_STATE_DIR" \
	"$tmpdir/opt/clash/bin" "$tmpdir/etc/config"
for f in "$XRAY_BIN" "$XRAY_BIN.new" "$XRAY_BIN.old" "$XRAY_SHARE_DIR/geosite.dat" "$CORE_JSON_FILE" "$PKG_PERSIST_DIR/subscription.json" \
	"$POLICY_CACHE_DIR/x" "$PKG_TMP_DIR/config.json" "$XRAY_CONFIG" "$RULES_FILE" "$tmpdir/etc/config/xraywrt" \
	"$tmpdir/opt/clash/bin/clash" "$tmpdir/opt/clash/config.yaml" "$tmpdir/etc/config/mihowrt"; do
	echo x >"$f"
done
mkdir -p "$XRAY_SUBS_DIR/s1/share"
echo x >"$XRAY_SUBS_DIR/s1/share/geosite.dat"
echo x >"$XRAY_SUBS_DIR/s1/config.json"
echo 's1 s2 parked' >"$XRAY_SUBS_DIR/.switch"
uninstall_cleanup || fail 'uninstall_cleanup'
assert_false 'parked rule databases removed' test -e "$XRAY_SUBS_DIR/s1/share"
assert_true 'parked config kept with its UCI section' test -f "$XRAY_SUBS_DIR/s1/config.json"
assert_false 'a switch journal is not replayed after a reinstall' test -e "$XRAY_SUBS_DIR/.switch"
assert_eq $'recover\ncleanup\nfw4-include\ncron '"$CRON_MARKER"' 0 ' "$(cat "$tmpdir/calls")" 'service stopped, policy, fw4 include and cron removed'
for f in "$XRAY_BIN" "$XRAY_BIN.new" "$XRAY_BIN.old" "$XRAY_SHARE_DIR" "$CORE_JSON_FILE" "$PKG_PERSIST_DIR/subscription.json" \
	"$POLICY_CACHE_DIR" "$PKG_TMP_DIR" "$PKG_STATE_DIR"; do
	assert_false "removed: $f" test -e "$f"
done
for f in "$XRAY_CONFIG" "$RULES_FILE" "$tmpdir/etc/config/xraywrt" "$tmpdir/opt/clash/bin/clash" "$tmpdir/opt/clash/config.yaml" \
	"$tmpdir/etc/config/mihowrt"; do
	assert_true "kept: $f" test -f "$f"
done
pass 'uninstall cleanup'

# Spec 12: the binary of the xraywrt-core package is removed by that package.
pkg_installed_names() { printf '%s\n' luci-app-xraywrt xraywrt-core; }
mkdir -p "${XRAY_BIN%/*}" "$PKG_PERSIST_DIR"
echo core >"$XRAY_BIN"
echo x >"$CORE_JSON_FILE"
uninstall_cleanup || fail 'uninstall_cleanup with the core package'
assert_eq core "$(cat "$XRAY_BIN")" 'package core kept'
assert_false 'core.json removed' test -e "$CORE_JSON_FILE"
pass 'uninstall keeps the xraywrt-core binary'
