#!/usr/bin/env bash
# core-check JSON (spec 4.4); no core auto-update.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh fetch.sh lists.sh subscription.sh service.sh pkg.sh core.sh
pkg_installed_names() { :; }
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
CORE_JSON_FILE="$tmpdir/etc/core.json"
LAST_ERROR_FILE="$PKG_STATE_DIR/last_error"
XRAY_BIN="$tmpdir/opt/bin/xray"
mkdir -p "${XRAY_BIN%/*}" "${CORE_JSON_FILE%/*}" "$PKG_STATE_DIR"
printf '#!/bin/sh\necho "Xray 26.11.1-1424 (Xray, Penetrates Everything.)"\n' >"$XRAY_BIN"
chmod 755 "$XRAY_BIN"
core_arch() { echo arm64-v8a; }
latest=v26.11.2
core_pkg_resolve() {
	echo core >>"$tmpdir/resolve.log"
	mkdir -p "$CORE_TMP_DIR"
	CORE_TAG="$latest" CORE_PKG_VERSION="0.25.1-r1" CORE_ERROR="" CORE_SIZE="${RESOLVE_SIZE:-}"
	[ -z "${RESOLVE_ERROR:-}" ] || {
		CORE_ERROR="$RESOLVE_ERROR"
		return 1
	}
}
record() { jq -nc --arg c "$1" --arg t "$2" --arg s "$3" '{channel: $c, tag: $t, source: $s}' >"$CORE_JSON_FILE"; }
check() {
	rm -f "$CORE_VERSION_CACHE"
	result="$(core_check_json)" && rc=0 || rc=$?
}

fake_uci_set xraywrt.settings.core_channel Jolymmiles/Xray-core
record Jolymmiles/Xray-core v26.11.1-1424 channel
check
assert_eq 0 "$rc" 'check succeeds'
jq -e '.installed == {tag: "v26.11.1-1424", source: "channel", version: null} and .latest == {tag: "v26.11.2", size: null, version: "0.25.1-r1"} and .update_available == true and has("channel_changed") == false and .error == null' <<<"$result" >/dev/null || fail "legacy migration check: $result"
assert_eq core "$(cat "$tmpdir/resolve.log")" 'only XrayWRT core release queried'
assert_false 'check removes RAM stage' test -e "$CORE_TMP_DIR"
record '' '' file
check
jq -e '.installed.source == "file" and .update_available == true' <<<"$result" >/dev/null || fail "file check: $result"
rm -f "$CORE_JSON_FILE" "$XRAY_BIN"
check
jq -e '.installed.source == null and .xray_version == null and .update_available == true' <<<"$result" >/dev/null || fail "missing core: $result"
RESOLVE_ERROR='cannot reach GitHub (API: network)' check
assert_eq 1 "$rc" 'resolve failure fails check'
jq -e '.update_available == false and .error == "cannot reach GitHub (API: network)"' <<<"$result" >/dev/null || fail "failure check: $result"
RESOLVE_SIZE=31457280 check
jq -e '.latest.size == 31457280' <<<"$result" >/dev/null || fail "published size: $result"
pass 'Core-only check JSON and failures'

# Spec 4.4: no core auto-update; the hourly tick and cron never touch the core.
assert_false 'no core auto-update function' declare -F core_auto_update
assert_false 'no core auto-update due check' declare -F core_auto_update_due
assert_false 'auto_update has no core step' grep -q core_ <<<"$(declare -f auto_update)"
cron_sync() { echo "$2" >"$tmpdir/cron"; }
settings_require() { :; }
lists_urls() { :; }
SUBSCRIPTION_INTERVAL=0 SUBSCRIPTION_URL="" LISTS_INTERVAL=24 CRON_MINUTE=17
cron_update
assert_eq 0 "$(cat "$tmpdir/cron")" 'no due work: no cron'
assert_false 'no core check stamp constant' grep -rq 'CORE_CHECK_STAMP\|core-check.stamp' "$ROOT_DIR/rootfs"
pass 'no core auto-update'
