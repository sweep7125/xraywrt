#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/.build/router"
DIST_DIR="${PROJECT_ROOT}/dist"
LOG_DIR="${BUILD_DIR}/logs"
mkdir -p "${LOG_DIR}"

MODE="${1:-baseline}"
WATCHDOG="${2:-}"

echo "=========================================================="
echo " XrayWRT Real OpenWrt 25.12.6 VM Smoke Test"
echo " Target: x86/64 QEMU TCG | Mode: ${MODE}"
echo "=========================================================="

# 1. Connectivity check
echo -n "[smoke] Testing SSH connectivity..."
if ! "${SCRIPT_DIR}/ssh.sh" true 2>/dev/null; then
  echo " FAILED"
  echo "Error: Cannot connect to OpenWrt VM via ${SCRIPT_DIR}/ssh.sh" >&2
  exit 1
fi
echo " OK"

# 2. Baseline proof
echo "[smoke] Gathering baseline proof..."
"${SCRIPT_DIR}/ssh.sh" "uname -a" | tee "${LOG_DIR}/baseline-uname.txt"
"${SCRIPT_DIR}/ssh.sh" "ubus call system board" | tee "${LOG_DIR}/baseline-board.json"
"${SCRIPT_DIR}/ssh.sh" "apk --version" | tee "${LOG_DIR}/baseline-apk.txt"
"${SCRIPT_DIR}/ssh.sh" "ip -o addr show" | tee "${LOG_DIR}/baseline-ip.txt"
"${SCRIPT_DIR}/ssh.sh" "ps | grep -E 'procd|dropbear' | grep -v grep" | tee "${LOG_DIR}/baseline-procs.txt" || true
"${SCRIPT_DIR}/ssh.sh" "nft list tables" | tee "${LOG_DIR}/baseline-nft.txt"

if [ "${MODE}" != "integration" ] && [ "${MODE}" != "--integration" ]; then
  echo "=========================================================="
  echo " Baseline Proof Complete (OK)"
  echo " Details saved in ${LOG_DIR}/"
  echo " Use './tests/router/run-smoke.sh --integration' for APK & service lifecycle"
  echo "=========================================================="
  exit 0
fi


# 3. Integration verification on XrayWRT core
echo "=========================================================="
echo " Running Integration Smoke Mode"
echo "=========================================================="

VM() { "${SCRIPT_DIR}/ssh.sh" "$@"; }
fail() { echo " FAILED: $*"; exit 10; }

VERSION="$(sed -n 's/^PKG_VERSION:=//p' "${PROJECT_ROOT}/Makefile")"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "${PROJECT_ROOT}/Makefile")"
APP_APK="${DIST_DIR}/luci-app-xraywrt-${VERSION}-r${RELEASE}.apk"
RU_APK="${DIST_DIR}/luci-i18n-xraywrt-ru-${VERSION}-r${RELEASE}.apk"
[ -f "${APP_APK}" ] && [ -f "${RU_APK}" ] || { echo "Error: ${VERSION} APKs not found in ${DIST_DIR}" >&2; exit 2; }

echo "[smoke] Installing ${VERSION} packages..."
# jq is a test tool only (status checks below), not a package dependency.
VM "command -v jq >/dev/null || { apk update >/dev/null && apk add jq >/dev/null; }" || fail "cannot install jq in the guest"
VM "cat > /tmp/mw-app.apk" <"${APP_APK}"
VM "cat > /tmp/mw-ru.apk" <"${RU_APK}"
VM "apk add --allow-untrusted /tmp/mw-app.apk /tmp/mw-ru.apk" | tee "${LOG_DIR}/apk-install.log"
VM "test -s /usr/lib/lua/luci/i18n/xraywrt.ru.lmo" || fail "Russian catalog missing"

# XRAY_TEST_CORE=installed: keep the core already in the guest (e.g. the
# xraywrt-core package, which core-update --file must not replace).
if [ "${XRAY_TEST_CORE:-}" = installed ]; then
  echo "[smoke] Using the installed core (XRAY_TEST_CORE=installed)..."
  VM "/usr/bin/xraywrt core-version-json" | tee "${LOG_DIR}/core-version.json" | grep -q '"installed":true' || fail "no installed core"
else
  CORE_APK="${DIST_DIR}/xraywrt-core_0.26.5-r2_x86_64.apk"
  [ -f "$CORE_APK" ] || fail "build the XrayWRT core 0.26.5-r2 x86_64 VM package first"
  echo "[smoke] Installing XrayWRT core 0.26.5-r2 VM package..."
  VM "cat > /tmp/core.apk" <"$CORE_APK"
  VM "apk add --allow-untrusted /tmp/core.apk" | tee "${LOG_DIR}/core-install.log"
  VM "/opt/xraywrt/bin/xray version | sed -n 1p" | grep -Eq ' [a-z]+-0\.26\.5 ' || fail "core is not XrayWRT core 0.26.5"

fi

echo "[smoke] Deploying minimal provider config (direct only, WAN DNS)..."
VM "cat > /opt/xraywrt/config.json" <<'EOF'
{
  "log": {"loglevel": "info"},
  "outbounds": [{"tag": "direct", "protocol": "freedom"}]
}
EOF

wait_ready() {
  local i
  for i in $(seq 1 45); do
    VM "/usr/bin/xraywrt status-json | jq -e '.running and .policy_active and .dns_ok' >/dev/null" && return 0
    sleep 2
  done
  return 1
}

echo -n "[smoke] start..."
VM "/etc/init.d/xraywrt enable; /etc/init.d/xraywrt start"
wait_ready || fail "service not ready"
echo " OK"

echo -n "[smoke] dnsmasq conf-dir redirect..."
VM "grep -qx 'server=127.0.0.1#7874' /tmp/dnsmasq.*.d/xraywrt.conf" || fail "conf file missing"
VM "uci show dhcp | grep -q 7874" && fail "UCI must not be modified"
echo " OK"

echo -n "[smoke] DNS answers through dnsmasq..."
VM "nslookup openwrt.org 127.0.0.1 | grep -q Address" || fail "no DNS answer"
echo " OK"

echo -n "[smoke] nft and policy routing (IPv4 + IPv6)..."
VM "nft list table inet xraywrt" >"${LOG_DIR}/nft-xraywrt.txt"
grep -q 'tproxy ip6 to \[::1\]:7894' "${LOG_DIR}/nft-xraywrt.txt" || fail "no IPv6 TPROXY"
VM "ip -4 rule | grep -q 0x8000000" || fail "no IPv4 rule"
VM "[ ! -e /proc/net/if_inet6 ] || ip -6 rule | grep -q 0x8000000" || fail "no IPv6 rule"
echo " OK"

echo "[smoke] reload..."
VM "/etc/init.d/xraywrt reload"
wait_ready || fail "not ready after reload"

echo -n "[smoke] stop is synchronous..."
VM "/etc/init.d/xraywrt stop"
VM "ls /tmp/dnsmasq.*.d/xraywrt.conf >/dev/null 2>&1" && fail "conf file left after stop"
VM "nft list table inet xraywrt >/dev/null 2>&1" && fail "nft table left after stop"
VM "ip rule | grep -q 0x8000000" && fail "ip rule left after stop"
echo " OK"

if [ "${WATCHDOG}" = "--watchdog" ]; then
  echo -n "[smoke] watchdog fail-open with frozen Xray..."
  VM "/etc/init.d/xraywrt start"
  wait_ready || fail "not ready before watchdog test"
  OLD_PID="$(VM 'cat /var/run/xraywrt/xray.pid' | tr -d '\r\n')"
  VM "kill -STOP ${OLD_PID}"
  opened=0
  for i in $(seq 1 30); do
    sleep 3
    if ! VM "ls /tmp/dnsmasq.*.d/xraywrt.conf >/dev/null 2>&1" &&
      VM "/usr/bin/xraywrt status-json | jq -e '.state == \"degraded\" and (.policy_active | not)' >/dev/null"; then
      opened=1
      break
    fi
  done
  [ "${opened}" = 1 ] || fail "DNS and policy did not fail open with frozen Xray after 90 s"
  # Spec 9.2: a hung core is not restarted; 3 good probes restore the policy.
  VM "kill -CONT ${OLD_PID}"
  wait_ready || fail "policy not restored after the core recovered"
  NEW_PID="$(VM 'cat /var/run/xraywrt/xray.pid' | tr -d '\r\n')"
  [ "${NEW_PID}" = "${OLD_PID}" ] || fail "Xray was restarted instead of recovering in place"
  echo " OK"
  echo -n "[smoke] crashed Xray is respawned..."
  VM "kill -KILL ${OLD_PID}"
  sleep 5
  wait_ready || fail "not ready after the core crash"
  NEW_PID="$(VM 'cat /var/run/xraywrt/xray.pid' | tr -d '\r\n')"
  [ "${NEW_PID}" != "${OLD_PID}" ] || fail "Xray was not respawned"
  VM "/etc/init.d/xraywrt stop"
  echo " OK"
fi

echo "=========================================================="
echo " All Integration Tests PASSED successfully!"
echo "=========================================================="
