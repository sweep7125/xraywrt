#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh fetch.sh pkg.sh core.sh
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
CORE_JSON_FILE="$tmpdir/core.json"
XRAY_BIN="$tmpdir/xray"
for channel in core Jolymmiles/Xray-core XTLS/Xray-core arbitrary/repo; do
 assert_false "removed --channel $channel rejected at CLI/job boundary" core_args_valid --channel "$channel"
done
pass 'removed core channel flag rejected'
core_release_resolve() { CORE_ERROR='alternate production resolver called'; return 1; }
for channel in Jolymmiles/Xray-core XTLS/Xray-core arbitrary/repo; do
 fake_uci_set xraywrt.settings.core_channel "$channel"
 called=0
 core_pkg_update() { called=$((called + 1)); }
 core_update || fail "legacy channel must not prevent XrayWRT core update: $CORE_ERROR"
 assert_eq 1 "$called" 'legacy UCI cannot select a production core'
 assert_eq "$channel" "$(uci_get core_channel)" 'uncompleted migration retains old UCI'
done
pass 'legacy core channel cannot select an alternate core'
unset -f core_release_resolve
for helper in core_arch core_release_resolve_direct core_unzip_ensure core_zip_extract; do
 assert_false "obsolete production helper $helper removed" declare -F "$helper"
done
pass 'alternate binary and zip downloaders removed'
for file in rootfs/usr/bin/xraywrt rootfs/usr/lib/xraywrt/job.sh install.sh; do
 assert_file_not_contains "$ROOT_DIR/$file" --channel "$file does not advertise removed flags"
done
for file in rootfs/www/luci-static/resources/view/xraywrt/advanced.js rootfs/www/luci-static/resources/xraywrt/api.js; do
 assert_file_not_contains "$ROOT_DIR/$file" XTLS/Xray-core "$file has no alternate core choice or suggestion"
done
pass 'production interfaces do not advertise alternate cores'
json="$(xraywrt-json build status --arg core '')"
assert_eq false "$(jq 'has("core_channel")' <<<"$json")" 'status does not expose selectable core channels'
json="$(xraywrt-json build core-check)"
assert_eq false "$(jq 'has("channel_changed") or (.installed | has("channel"))' <<<"$json")" 'core-check has no channel selection schema'
pass 'production JSON schemas have no channel selectors'
assert_file_not_contains "$ROOT_DIR/rootfs/www/luci-static/resources/view/xraywrt/updates.js" 'mw-core-file' 'Updates page has no core file upload'
assert_file_not_contains "$ROOT_DIR/rootfs/usr/lib/xraywrt/core.sh" 'core_file_allowed' 'backend has no core file install'
pass 'no core file install'
