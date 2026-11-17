#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules constants.sh helpers.sh

# "Removed" checks: grep must run and find nothing (exit 1); a bad path or
# option (exit 2) fails instead of passing silently.
absent() {
	local rc=0
	grep "$@" || rc=$?
	[ "$rc" -eq 1 ]
}

expected="validate.sh settings.sh geodata.sh xray-config.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh core.sh xray-api.sh service.sh pkg.sh status.sh migration.sh job.sh"
assert_eq "$expected" "$XRAYWRT_MODULES" "runtime module order"
assert_eq "$PKG_STATE_DIR/jobs" "$JOBS_DIR" 'jobs use volatile package state'
assert_false "kernel.sh removed" test -e "$XRAYWRT_LIB_DIR/kernel.sh"
assert_true "KERNEL_ constants removed" absent -rn KERNEL_ "$ROOT_DIR/rootfs"
# A2.1: no Mihomo web panel.
assert_true "dashboard removed" absent -rniE --exclude=migration.sh 'dashboard|zashboard|ui_url' "$ROOT_DIR/rootfs" "$ROOT_DIR/po" "$ROOT_DIR/tools" "$ROOT_DIR/README.md"
assert_false "dashboard test removed" test -e "$ROOT_DIR/tests/test_dashboard.sh"
# A2.2: no Mihomo proxy groups, server selection or latency tests; watchdog probe is DNS, not REST.
assert_true "proxy group API removed" absent -rnE 'proxies-json|select-proxy|group-delay|api_proxies_json|api_select|api_group_delay|api_dns_probe|uri_encode|API_DELAY_URL|Server selection' "$ROOT_DIR/rootfs" "$ROOT_DIR/po" "$ROOT_DIR/tools" "$ROOT_DIR/README.md"
# A2.3: no Go memory limit for the core.
assert_true "core memory limit removed" absent -rnE 'GOMEMLIMIT|memory_limit|memlimit' "$ROOT_DIR/rootfs" "$ROOT_DIR/tests"/test_*.sh --exclude=test_modules.sh
assert_false "core memory test removed" test -e "$ROOT_DIR/tests/test_core_memory.sh"
# A2.5: no controller secret and no LAN controller; only the private unix socket stays until A5.
assert_true "API secret removed" absent -rnE 'API_SECRET|api_secret|settings_secret_write|migrate_secret|XRAYWRT_SECRET|MIHOMO_API_PORT|controller secret' "$ROOT_DIR/rootfs" "$ROOT_DIR/po" "$ROOT_DIR/tests"/test_*.sh "$ROOT_DIR/tests/fixtures/settings" --exclude=test_modules.sh
# A2.4: no tmpfs links in the core directory and no persisted Mihomo cache.db.
assert_true "tmpfs layout removed" absent -rnE 'layout_|cache_db|CACHE_DB|cache\.db|RULESET_(TMPFS|LINK)|PROXY_PROVIDERS_|PROXIES_(TMPFS|LINK)|RULES_(TMPFS|LINK)' "$ROOT_DIR/rootfs" "$ROOT_DIR/tests"/test_*.sh --exclude=test_modules.sh
for module in $XRAYWRT_MODULES; do
 assert_true "$module exists" test -f "$XRAYWRT_LIB_DIR/$module"
done
for name in CORE_TMP_DIR CORE_RELEASE_JSON_MAX_BYTES CORE_ASSET_MAX_BYTES; do
 assert_true "$name defined" test -n "${!name}"
done
assert_true "ucode generator installed by package wildcard" grep -qF '$(CP) ./rootfs/usr/lib/xraywrt/* $(1)/usr/lib/xraywrt/' "$ROOT_DIR/Makefile"
assert_true "ucode generator exists" test -f "$XRAYWRT_LIB_DIR/xray-config.uc"
# Spec 9.4/6.1: Mihomo REST API and the awk/YAML generator are gone.
for module in mihomo-api.sh mihomo-config.sh mihomo-config.awk yaml-lex.awk; do
 assert_false "$module removed" test -e "$XRAYWRT_LIB_DIR/$module"
done
for module in core.sh subscription.sh lists.sh; do
 (
  load_modules "$module"
  case "$module" in
  core.sh) declare -F core_update >/dev/null ;;
  subscription.sh) declare -F subscription_update subscription_due >/dev/null ;;
  lists.sh) declare -F lists_install lists_apply lists_refresh >/dev/null ;;
  esac
 ) || fail "$module owns its interfaces"
done
pass "runtime modules and packaged generator"

load_modules config.sh
assert_false "dead runtime reload helper removed" declare -F config_runtime_reload
