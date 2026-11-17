#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="${SCRIPT_DIR}/router"

# Safety contracts run without a VM; only the existing live checks are opt-in.
fail() { echo "not ok - $*" >&2; exit 1; }
for script in run-network.sh network-guest.sh; do
  [ -f "${ROUTER_DIR}/${script}" ] || fail "network fixture missing: ${script}"
done
host="${ROUTER_DIR}/run-network.sh"
guest="${ROUTER_DIR}/network-guest.sh"
grep -q 'ROUTER_HOST=127.0.0.1 ROUTER_SSH_FORCE_DOCKER=1' "$host" || fail 'network SSH must force loopback and Docker'
grep -q 'ROUTER_CONTAINER=xraywrt-openwrt-test' "$host" || fail 'network container must be fixed'
grep -q 'readlink /proc/1/exe' "$host" || fail 'QEMU identity must not depend on truncated ps output'
grep -q 'trap .*EXIT' "$host" || fail 'host must collect evidence on failure'
grep -q 'GUEST_TIMEOUT / 5' "$host" || fail 'host guest poll loop must be bounded'
grep -q 'WORK=/tmp/xraywrt-network-test' "$guest" || fail 'guest must own its temporary directory'
grep -q 'trap .*EXIT' "$guest" || fail 'guest must clean up on exit'
grep -q 'refuse existing' "$guest" || fail 'guest must refuse existing fixture objects'
for fixture_contract in \
  'ip -4 rule add priority 50 fwmark 0x220000/0xff0000 lookup 201' \
  'ip -4 rule del priority 50 fwmark 0x220000/0xff0000 lookup 201' \
  'ip -4 rule show | grep -Eq '\''(^50:| lookup (200|201)( |$))' \
  'ip -6 rule show | grep -Eq '\''(^50:| lookup (200|201)( |$))' \
  '[ "$priority" != 50 ]' \
  'ip -4 rule show | grep '\''^50:.*0x220000/0xff0000.*lookup 201'; do
  grep -qF "$fixture_contract" "$guest" || fail "priority collision fixture must use slot 50: $fixture_contract"
done
# /tmp/xraywrt/nft.applied holds only the SHA-256 of the applied ruleset: the syntax row must check the live table.
if grep -q 'nft -c -f /tmp/xraywrt/nft.applied' "$guest"; then fail 'nft syntax row must not parse the nft.applied hash as a ruleset'; fi
grep -qF 'nft list table inet xraywrt' "$guest" || fail 'nft syntax row must re-check the live inet xraywrt table'
grep -q 'save-config' "$guest" || fail 'guest must install and restore the config through the config API'
grep -q 'network.m22c.proto=static' "$guest" || fail 'netifd must retain the selected client fixture addresses'
# The A2 row alone may toggle this guest-only sysctl, with failure-safe restoration.
if grep -vE '^[[:space:]]*sysctl -w net\.ipv6\.conf\.all\.disable_ipv6=[01]$' "$guest" |
  grep -Eq '(killall|pkill|conntrack -F|flush ruleset|sysctl -w)'; then
  fail 'guest must not use broad process, conntrack or network mutations'
fi
for contract in 'sysctl -w net.ipv6.conf.all.disable_ipv6=1' 'sysctl -w net.ipv6.conf.all.disable_ipv6=0'; do
  grep -qF "$contract" "$guest" || fail "IPv6 disabled fixture must toggle and restore only the allowed sysctl: $contract"
done
for script in "$host" "$guest"; do
  grep -q "'local names'" "$script" || fail 'network matrix must include local names'
done
grep -q 'dhcp.m22host.name=m22host.lan' "$guest" || fail 'local names must use a fixture-owned dnsmasq host record'
grep -q 'check_local_names' "$guest" || fail 'local names must have a guest check'
bash -n "$host"
sh -n "$guest"
for script in "$host" "$guest"; do
  grep -q "'port forward and WAN service replies'" "$script" || fail 'network matrix must include port forward and WAN service replies'
done
grep -q 'check_forward_replies' "$guest" || fail 'port forward row must have a guest check'
grep -q 'uci set firewall.m22dnat=redirect' "$guest" || fail 'port forward must use a fixture-owned fw4 redirect'
grep -q 'comment a1-reply' "$guest" || fail 'port forward row must count marked replies'
grep -q 'stop_reply_listeners' "$guest" || fail 'reply listeners must have tracked TERM/KILL teardown'
grep -q 'a1-ports-router.before' "$guest" || fail 'reply probes must refuse occupied ports'
udp_probe="$(sed -n '/^udp_echo()/,/^)/p' "$guest")"
for contract in 'cat /proc/net/nf_conntrack' 'a1-$label.conntrack-all' 'absent grep -q UNREPLIED'; do
  grep -qF "$contract" <<<"$udp_probe" || fail "UDP probe must check its conntrack before listener teardown: $contract"
done
for script in "$host" "$guest"; do
  grep -q "'IPv6 disabled'" "$script" || fail 'network matrix must include IPv6 disabled'
  grep -q "'policy rule precedence'" "$script" || fail 'network matrix must include policy rule precedence'
done
grep -q 'check_ipv6_disabled' "$guest" || fail 'IPv6 disabled row must have a guest check'
grep -q 'restore_ipv6' "$guest" || fail 'IPv6 sysctl and addresses must be restored even on failure'
grep -q 'check_rule_precedence' "$guest" || fail 'policy precedence row must have a guest check'
for contract in 'priority 105' 'priority 110' 'priority 2001' '0x3f00/0x3f00' 'PRIORITY=1000'; do
  grep -qF "$contract" "$guest" || fail "policy precedence fixture missing: $contract"
done
# B5: declared but never run by this static harness.
for script in "$host" "$guest"; do
 grep -q "'balancer overrides'" "$script" || fail 'network matrix must include balancer overrides'
done
for evidence in 'check_balancer_overrides' 'balancer-set main proxy' 'balancer-set main ""' 'balancers-$phase.json' 'for phase in pinned restarted'; do
 grep -qF "$evidence" "$guest" || fail "balancer row missing evidence: $evidence"
done
# C3: declarations and evidence contracts only; never launch the VM here.
for script in "$host" "$guest"; do
 for name in 'hot subscription TCP' 'routing strategy restart'; do
  grep -qF "'$name'" "$script" || fail "network matrix must include $name"
 done
done
for evidence in 'check_hot_subscription' 'check_routing_strategy_restart' 'hot-idle' \
 'hot-subscription.json' '.action == "hot_reloaded"' '.action == "restarted"' \
 'hot-tcp.before' 'hot-tcp.after' 'wait "$client"' 'hot-tcp.pid-before' 'strategy.pid-after'; do
 grep -qF "$evidence" "$guest" || fail "hot apply row missing evidence: $evidence"
done
# NETWORK_NODE_XRAY: the synthetic node (a server) may run a Go Xray while the router core is a
# client-only build (core refuses non-loopback inbounds); the default stays the router core.
grep -qF "VM \"cat > '\$WORK/node-xray' && chmod 755 '\$WORK/node-xray'\" <\"\$NETWORK_NODE_XRAY\"" "$host" || fail 'host must copy NETWORK_NODE_XRAY into the guest'
grep -qF 'NODE_XRAY="$WORK/node-xray"; [ -x "$NODE_XRAY" ] || NODE_XRAY=/opt/xraywrt/bin/xray' "$guest" || fail 'guest must default the node binary to the router core'
for contract in '"$NODE_XRAY" tls cert' 'ip netns exec m22-w "$NODE_XRAY" run -c'; do
  grep -qF "$contract" "$guest" || fail "synthetic node must use NODE_XRAY: $contract"
done
# The host requires exactly the rows the guest records and runs.
eval "$(sed -n '/^ROWS=(/,/)$/p' "$host")"
[ "${#ROWS[@]}" -ge 14 ] || fail 'host row list missing'
recorded="$(sed -n '/^for name in .nft syntax/,/; do$/p' "$guest")"
for name in "${ROWS[@]}"; do
  grep -qE "^row ('$name'|$name) " "$guest" || fail "guest does not run row: $name"
  grep -qF "$name" <<<"$recorded" || fail "guest does not record row: $name"
done
[ "$(grep -c '^row ' "$guest")" = "${#ROWS[@]}" ] || fail 'guest runs rows the host does not require'
echo 'ok - network fixture static safety contracts (no VM)'

# Exercise host failure handling with a fake transport; no Docker daemon or VM.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/project/tests/router" "$tmpdir/bin" "$tmpdir/guest/logs"
cp "$host" "$tmpdir/project/tests/router/run-network.sh"
cp "$guest" "$tmpdir/project/tests/router/network-guest.sh"
printf 'FAIL\n' >"$tmpdir/guest/cleanup.status"
printf 'nft syntax\tNOT TESTED\tfixture transport failed\n' >"$tmpdir/guest/results.tsv"
cat >"$tmpdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmpdir/project/tests/router/ssh.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$ROUTER_HOST" "$ROUTER_SSH_FORCE_DOCKER" "$ROUTER_CONTAINER" >>"$NETWORK_FAKE_ENV"
case "$*" in
  *"tar -C"*) tar -C "$NETWORK_FAKE_GUEST" -cf - logs results.tsv cleanup.status ;;
  *"rm -rf"*) echo removed >"$NETWORK_FAKE_REMOVED" ;;
  *"sh '/tmp/xraywrt-network-test/network-guest.sh'"*) exit 1 ;;
  *"grep -c"*) exit 1 ;;
  *"cat >"*) cat >/dev/null ;;
  *) : ;;
esac
EOF
chmod +x "$tmpdir/bin/docker" "$tmpdir/project/tests/router/ssh.sh"
export NETWORK_FAKE_ENV="$tmpdir/environment" NETWORK_FAKE_GUEST="$tmpdir/guest" NETWORK_FAKE_REMOVED="$tmpdir/removed"
if PATH="$tmpdir/bin:$PATH" NETWORK_TIMEOUT=5 NETWORK_ROWS='fake-IP direct devices' ROUTER_HOST=example.invalid ROUTER_SSH_FORCE_DOCKER=0 ROUTER_CONTAINER=not-a-vm \
  bash "$tmpdir/project/tests/router/run-network.sh" >"$tmpdir/output" 2>&1; then
  fail 'unavailable network check must return 1'
fi
[ -s "$NETWORK_FAKE_ENV" ] || fail 'fake SSH transport not exercised'
if grep -vxF '127.0.0.1|1|xraywrt-openwrt-test' "$NETWORK_FAKE_ENV"; then
  fail 'caller overrides escaped fixed VM transport'
fi
[ ! -e "$NETWORK_FAKE_REMOVED" ] || fail 'failed restoration must preserve guest recovery snapshots'
grep -q '| nft syntax | NOT TESTED |' "$tmpdir/project/.build/verification-0110/network/REPORT.md" || fail 'failed transport must not claim synthetic PASS'
grep -q '| local names | NOT TESTED |' "$tmpdir/project/.build/verification-0110/network/REPORT.md" || fail 'failed transport must report local names as untested'
echo 'ok - network host pins transport, fails closed and retains failed-restore state'

# Exercise the real UDP observation block without sockets or a privileged /proc.
# A concurrent conntrack dump can omit a live tuple on one read.
snapshot_block="$(sed -n '/^[[:space:]]*# Observe this tuple/,/^)/p' "$guest" | sed '1d;$d')"
[ -n "$snapshot_block" ] || fail 'UDP conntrack observation block missing'
mkdir -p "$tmpdir/udp/logs"
cat >"$tmpdir/udp-check.sh" <<'EOF'
set -eu
WORK="$UDP_TEST_WORK"
label=fixture ns=router port=8088 listen_port=8088
absent() { if "$@"; then exit 1; fi; }
sleep() { :; }
cat() {
  if [ "$1" != /proc/net/nf_conntrack ]; then command cat "$@"; return; fi
  count="$(command cat "$WORK/reads")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$WORK/reads"
  case "$UDP_TEST_KIND" in
    missing) return 0 ;;
    transient) [ "$count" -gt 1 ] || return 0 ;;
  esac
  reply=198.20.22.1 status=''
  [ "$UDP_TEST_KIND" != unreplied ] || status='[UNREPLIED] '
  [ "$UDP_TEST_KIND" != wrong-reply ] || reply=192.0.2.2
  printf 'ipv4 2 udp 17 59 src=198.20.22.2 dst=198.20.22.1 sport=43210 dport=8088 %ssrc=%s dst=198.20.22.2 sport=8088 dport=43210 mark=0\n' "$status" "$reply"
}
EOF
printf '%s\n' "$snapshot_block" >>"$tmpdir/udp-check.sh"
for kind in transient missing unreplied wrong-reply; do
  echo 0 >"$tmpdir/udp/reads"
  if UDP_TEST_WORK="$tmpdir/udp" UDP_TEST_KIND="$kind" sh "$tmpdir/udp-check.sh" >"$tmpdir/udp-$kind.log" 2>&1; then
    [ "$kind" = transient ] || fail "UDP conntrack must reject $kind evidence"
  else
    [ "$kind" != transient ] || fail 'UDP conntrack must retry a transiently omitted replied tuple'
  fi
  if [ "$kind" = transient ]; then
    [ "$(cat "$tmpdir/udp/reads")" = 2 ] || fail 'UDP observation must stop once a replied tuple is proven'
  else
    [ "$(cat "$tmpdir/udp/reads")" -le 5 ] || fail 'UDP observation retries must be bounded'
  fi
done
echo 'ok - UDP conntrack retries transient omissions but requires the replied tuple'

# Path evidence is core-agnostic: the WAN server, the node, nft and captures, never the router core's log text.
if grep -nE 'core_detour|dokodemo|taking detour|will use DNS in order|got answer:' "$guest"; then
  fail 'network rows must not assert on the router core log'
fi
evidence_helpers="$(for fn in peer_is dns_asked foreign_syns; do sed -n "/^$fn() /,/^}/p" "$guest"; done)"
[ "$(grep -c '^[a-z_]*() ' <<<"$evidence_helpers")" = 3 ] || fail 'path evidence helpers missing'
ev() { sh -euc "$evidence_helpers"'
"$@"' ev "$@"; }
mkdir -p "$tmpdir/ev"
printf 'xraywrt-network-fixture\npeer=198.20.22.1\n' >"$tmpdir/ev/router4"
printf 'xraywrt-network-fixture\npeer=::ffff:198.20.22.1\n' >"$tmpdir/ev/mapped"
printf 'xraywrt-network-fixture\npeer=192.0.2.2\n' >"$tmpdir/ev/client"
printf 'xraywrt-network-fixture\n' >"$tmpdir/ev/none"
printf 'peer=198.20.22.1\npeer=198.20.22.1\n' >"$tmpdir/ev/twice"
ev peer_is "$tmpdir/ev/router4" 2001:db8:ffff::1 198.20.22.1 || fail 'peer_is must accept a listed peer'
ev peer_is "$tmpdir/ev/mapped" 198.20.22.1 || fail 'peer_is must strip the IPv4-mapped prefix'
for bad in client none twice; do
  if ev peer_is "$tmpdir/ev/$bad" 198.20.22.1; then fail "peer_is must refuse $bad"; fi
done
if ev peer_is "$tmpdir/ev/router4" 198.20.22.10 198.20.22; then fail 'peer_is must compare whole addresses'; fi
cat >"$tmpdir/ev/lo.decoded" <<'EOF'
12:00:00.000001 IP 127.0.0.1.40001 > 127.0.0.1.53: 4660+ A? node22.example.net. (36)
12:00:00.000002 IP 127.0.0.1.53 > 127.0.0.1.40001: 4660 1/0/0 A 198.20.22.2 (52)
12:00:00.000003 IP6 ::1.40002 > ::1.53: 4661+ [1au] AAAA? node22.example.net. (47)
12:00:00.000004 IP 127.0.0.1.40003 > 127.0.0.1.7874: 4662+ A? node22.example.net. (36)
12:00:00.000005 IP 127.0.0.1.40004 > 127.0.0.1.53: 4663+ A? xnode22.example.net. (37)
12:00:00.000006 IP 127.0.0.1.40005 > 127.0.0.1.53: 4664+ A? node22.example.net.lan. (40)
EOF
[ "$(ev dns_asked "$tmpdir/ev/lo.decoded" 53 A node22.example.net)" = 1 ] || fail 'dns_asked must count only exact A queries to port 53'
[ "$(ev dns_asked "$tmpdir/ev/lo.decoded" 53 AAAA node22.example.net)" = 1 ] || fail 'dns_asked must count EDNS AAAA queries'
[ "$(ev dns_asked "$tmpdir/ev/lo.decoded" 7874 A node22.example.net)" = 1 ] || fail 'dns_asked must count queries to the DNS inbound'
[ "$(ev dns_asked "$tmpdir/ev/lo.decoded" 7874 AAAA node22.example.net)" = 0 ] || fail 'dns_asked must print 0 when absent'
cat >"$tmpdir/ev/syn.decoded" <<'EOF'
12:00:00.000001 m22c  In  IP 192.0.2.2.40001 > 198.18.0.9.8080: Flags [S], seq 1, win 64240, length 0
12:00:00.000002 m22c  Out IP 198.18.0.9.8080 > 192.0.2.2.40001: Flags [S.], seq 2, ack 2, win 65483, length 0
12:00:00.000003 IP 192.0.2.22.40002 > 198.20.22.2.8080: Flags [S], seq 3, win 64240, length 0
EOF
[ "$(ev foreign_syns "$tmpdir/ev/syn.decoded" 192.0.2.2)" = '12:00:00.000003 IP 192.0.2.22.40002 > 198.20.22.2.8080: Flags [S], seq 3, win 64240, length 0' ] ||
  fail 'foreign_syns must report only SYNs from other sources'
printf '12:00:00.000004 m22w  Out IP6 2001:db8:ffff::1.40003 > 2001:db8:ffff::2.1080: Flags [S], seq 4, length 0\n' >>"$tmpdir/ev/syn.decoded"
[ "$(ev foreign_syns "$tmpdir/ev/syn.decoded" 192.0.2.2 | grep -c .)" = 2 ] || fail 'foreign_syns must report IPv6 SYNs'
echo 'ok - core-agnostic path evidence helpers (WAN peer, loopback DNS queries, foreign SYNs)'

grep -q -- '-e "VM_MEM=${VM_MEM:-512}"' "${ROUTER_DIR}/start.sh" || fail 'start.sh must pass VM_MEM (default 512) to the VM container'
grep -q -- '-m "${VM_MEM:-512}M"' "${ROUTER_DIR}/entrypoint.sh" || fail 'entrypoint.sh must size guest RAM from VM_MEM (default 512)'
echo 'ok - VM memory override defaults to 512 MiB'

# ROUTER_OPENWRT picks the guest release; 25.12 stays the default.
release_lib="${ROUTER_DIR}/release.sh"
[ -f "$release_lib" ] || fail 'tests/router/release.sh missing'
# shellcheck disable=SC2030,SC2031
release_values() { # release_values <ROUTER_OPENWRT value or empty>
  ( ROUTER_OPENWRT="$1"; [ -n "$1" ] || unset ROUTER_OPENWRT
    # shellcheck source=router/release.sh
    . "$release_lib" && router_select_release
    printf '%s|%s|%s|%s|%s\n' "$OPENWRT_VERSION" "$KERNEL_NAME" "$ROOTFS_NAME" "$DEFAULT_IMAGE_NAME" "$BASE_URL" )
}
[ "$(release_values '')" = '25.12.6|openwrt-25.12.6-x86-64-generic-kernel.bin|openwrt-25.12.6-x86-64-generic-ext4-rootfs.img.gz|xraywrt-openwrt-test:latest|https://downloads.openwrt.org/releases/25.12.6/targets/x86/64' ] ||
  fail "default guest must stay 25.12.6: $(release_values '')"
[ "$(release_values 25.12)" = "$(release_values '')" ] || fail '25.12 must equal the default'
if release_values 24.10 >/dev/null 2>&1; then fail 'unsupported ROUTER_OPENWRT=24.10 must be refused'; fi
if release_values 23.05 >/dev/null 2>&1; then fail 'unknown ROUTER_OPENWRT must be refused'; fi
grep -q 'router_select_release' "${ROUTER_DIR}/start.sh" || fail 'start.sh must select the release through release.sh'
grep -q -- '-e "ROUTER_KERNEL=${KERNEL_NAME}"' "${ROUTER_DIR}/start.sh" || fail 'start.sh must pass the kernel name to the VM container'
grep -q -- '-e "ROUTER_ROOTFS=${ROOTFS_NAME}"' "${ROUTER_DIR}/start.sh" || fail 'start.sh must pass the rootfs name to the VM container'
grep -q 'ROUTER_KERNEL:-openwrt-25.12.6' "${ROUTER_DIR}/entrypoint.sh" || fail 'entrypoint.sh must take the kernel name from ROUTER_KERNEL'
grep -q 'ROUTER_ROOTFS:-openwrt-25.12.6' "${ROUTER_DIR}/entrypoint.sh" || fail 'entrypoint.sh must take the rootfs name from ROUTER_ROOTFS'
echo 'ok - guest release selection (25.12 only)'

# Exercise smoke package selection without running the transport or a VM.
smoke_selection="$(sed -n '/^VERSION=/,/^echo "\[smoke\] Installing/p' "${ROUTER_DIR}/run-smoke.sh")"
[ -n "$smoke_selection" ] || fail 'smoke package selection block missing'
mkdir -p "$tmpdir/smoke/dist"
printf 'PKG_VERSION:=0.11.0\nPKG_RELEASE:=7\n' >"$tmpdir/smoke/Makefile"
touch "$tmpdir/smoke/dist/luci-app-xraywrt-0.11.0-r7.apk" "$tmpdir/smoke/dist/luci-i18n-xraywrt-ru-0.11.0-r7.apk"
if ! PROJECT_ROOT="$tmpdir/smoke" DIST_DIR="$tmpdir/smoke/dist" bash -eu -c "$smoke_selection" >"$tmpdir/smoke-selected" 2>&1; then
  cat "$tmpdir/smoke-selected" >&2
  fail 'run-smoke.sh must select the Makefile package revision, not hardcode r1'
fi
echo 'ok - smoke selects the current Makefile package revision (no VM)'
rm "$tmpdir/smoke/dist/luci-i18n-xraywrt-ru-0.11.0-r7.apk"
if PROJECT_ROOT="$tmpdir/smoke" DIST_DIR="$tmpdir/smoke/dist" bash -eu -c "$smoke_selection" >"$tmpdir/smoke-missing" 2>&1; then
  fail 'smoke must refuse a missing current-revision translation package'
fi
echo 'ok - smoke refuses an incomplete current-revision package pair (no VM)'

# Router smoke must exercise the production core; Go is synthetic-node-only.
if grep -q 'Installing Go Xray' "${ROUTER_DIR}/run-smoke.sh"; then fail 'smoke must not install Go as the router core'; fi
grep -q 'xraywrt-core_0.26.2-r1_x86_64.apk' "${ROUTER_DIR}/run-smoke.sh" || fail 'smoke default must install the exact XrayWRT core VM artifact'
echo 'ok - smoke defaults to XrayWRT core 0.26.2 (no VM)'

# XRAY_TEST_CORE=installed keeps the guest's core (e.g. the xraywrt-core package) instead of Go Xray.
smoke_core="$(sed -n '/^if \[ "\${XRAY_TEST_CORE:-}" = installed \]; then$/,/^fi$/p' "${ROUTER_DIR}/run-smoke.sh")"
[ -n "$smoke_core" ] || fail 'smoke core selection block missing'
smoke_core_run() { # smoke_core_run <core-version-json reply>
  XRAY_TEST_CORE=installed SMOKE_FAKE_REPLY="$1" SMOKE_FAKE_LOG="$tmpdir/smoke-core.log" LOG_DIR="$tmpdir" BUILD_DIR="$tmpdir/nobuild" bash -eu -c '
    VM() { echo "$*" >>"$SMOKE_FAKE_LOG"; case "$*" in *core-version-json*) echo "$SMOKE_FAKE_REPLY" ;; esac; }
    fail() { echo "FAILED: $*"; exit 10; }
    curl() { echo curl >>"$SMOKE_FAKE_LOG"; }
    '"$smoke_core"
}
: >"$tmpdir/smoke-core.log"
smoke_core_run '{"version":"26.10.28-1202","installed":true}' >/dev/null 2>&1 || fail 'smoke must accept an installed core with XRAY_TEST_CORE=installed'
if grep -qE 'core-update|curl' "$tmpdir/smoke-core.log"; then fail 'XRAY_TEST_CORE=installed must not replace the installed core'; fi
if smoke_core_run '{"version":"","installed":false}' >/dev/null 2>&1; then
  fail 'XRAY_TEST_CORE=installed must refuse a guest without a core'
fi
echo 'ok - smoke keeps the installed core with XRAY_TEST_CORE=installed (no VM)'

# DNS cleanup removes the redirect before nft/routes: wait for the full degraded snapshot.
smoke_watchdog="$(sed -n '/echo -n "\[smoke\] watchdog fail-open/,/echo -n "\[smoke\] crashed/{ /echo -n "\[smoke\] crashed/d; p; }' "${ROUTER_DIR}/run-smoke.sh")"
[ -n "$smoke_watchdog" ] || fail 'smoke watchdog block missing'
echo 0 >"$tmpdir/watchdog-reads"
SMOKE_WATCHDOG_READS="$tmpdir/watchdog-reads" bash -eu -c '
  VM() {
    case "$*" in
      *"ls /tmp/dnsmasq"*) return 1 ;;
      *"jq -e"*)
        count=$(cat "$SMOKE_WATCHDOG_READS"); count=$((count + 1))
        echo "$count" >"$SMOKE_WATCHDOG_READS"
        [ "$count" -ge 2 ]; return $? ;;
      *"cat /var/run/xraywrt/xray.pid"*) echo 42 ;;
    esac
    return 0
  }
  sleep() { :; }
  wait_ready() { :; }
  fail() { echo "FAILED: $*"; exit 10; }
  '"$smoke_watchdog" >"$tmpdir/watchdog.log" 2>&1 || {
    cat "$tmpdir/watchdog.log" >&2
    fail 'smoke must retry until policy cleanup reaches the full degraded snapshot'
  }
[ "$(cat "$tmpdir/watchdog-reads")" -ge 2 ] || fail 'smoke must observe completed policy cleanup'
echo 'ok - smoke waits for degraded state and policy cleanup after DNS redirect removal (no VM)'

# Boots a QEMU OpenWrt VM via Docker; keep it out of the default unit suite.
if [ "${XRAYWRT_ROUTER_TESTS:-0}" != "1" ]; then
  echo "1..0 # SKIP set XRAYWRT_ROUTER_TESTS=1 to run the OpenWrt VM harness"
  exit 0
fi

echo "1..2"

# Test 1: Router test harness start / status check
if ! "${ROUTER_DIR}/status.sh" >/dev/null 2>&1; then
  echo "# Starting router test harness..."
  "${ROUTER_DIR}/start.sh" >/dev/null
fi

if "${ROUTER_DIR}/status.sh" >/dev/null 2>&1; then
  echo "ok 1 - openwrt router vm running and ssh reachable"
else
  echo "not ok 1 - openwrt router vm not reachable"
  exit 1
fi

# Test 2: Baseline smoke proof
if "${ROUTER_DIR}/run-smoke.sh" baseline >/dev/null 2>&1; then
  echo "ok 2 - openwrt baseline kernel/ubus/apk/procd proof passed"
else
  echo "not ok 2 - openwrt baseline proof failed"
  exit 1
fi
