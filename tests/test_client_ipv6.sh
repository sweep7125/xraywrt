#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh dns.sh
setup_runtime_paths "$tmpdir"
fake_uci_set network.lan.ipaddr 192.168.8.1/24
out="$tmpdir/out.json"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"

# Count UCI commits; the fake uci treats commit as a no-op.
uci() {
	[ "${1:-}" != commit ] || echo x >>"$tmpdir/commits"
	command uci "$@"
}

# cfg [jq filter]: a provider config from the single-node fixture.
cfg() {
	jq "${1:-.}" "$ROOT_DIR/tests/fixtures/xray/src/single.json"
}

# load_with [jq filter]: write the config and reload settings from a fresh profile.
load_with() {
	cfg "${1:-.}" >"$XRAY_CONFIG"
	rm -f "$PROFILE_FILE"
	settings_load
}

load_with
assert_eq 0 "$BLOCK_CLIENT_IPV6" "default off"
pass "default off"

for v in true '"yes"' '"on"' 1 '"TRUE"' '" on "'; do
	cfg ".xraywrt = {\"block-client-ipv6\": $v}" >"$XRAY_CONFIG"
	cp "$XRAY_CONFIG" "$tmpdir/src.copy"
	xray_config_generate "$XRAY_CONFIG" "$out"
	assert_file_contains "$out.profile" 'set block_client_ipv6 1' "provider $v on"
	assert_eq false "$(jq 'has("xraywrt")' "$out")" "provider key stripped"
	cmp -s "$XRAY_CONFIG" "$tmpdir/src.copy" || fail "source config changed"
done
for v in false '"no"' '"off"' 0; do
	cfg ".xraywrt = {\"block-client-ipv6\": $v}" >"$XRAY_CONFIG"
	xray_config_generate "$XRAY_CONFIG" "$out"
	assert_file_contains "$out.profile" 'set block_client_ipv6 0' "provider $v off"
done
pass "provider boolean forms"

fake_uci_set xraywrt.settings.block_client_ipv6 1
load_with '.xraywrt = {"block-client-ipv6": "maybe"}'
assert_file_contains "$PROFILE_FILE" 'ignored block-client-ipv6' "invalid value ignored"
assert_file_not_contains "$PROFILE_FILE" 'set block_client_ipv6' "invalid value not applied"
assert_eq 1 "$BLOCK_CLIENT_IPV6" "invalid keeps UCI"
load_with
assert_eq 1 "$BLOCK_CLIENT_IPV6" "missing keeps UCI"
pass "invalid falls back"

for pair in 'true 0 1 0' 'false 1 0 1'; do
	read -r -a args <<<"$pair"
	set -- "${args[@]}"
	uci delete xraywrt.settings.provider_override
	fake_uci_set xraywrt.settings.block_client_ipv6 "$2"
	filter=".xraywrt = {\"block-client-ipv6\": $1}"
	load_with "$filter"
	assert_eq "$3" "$BLOCK_CLIENT_IPV6" "provider $1 wins over UCI $2"
	fake_uci_set xraywrt.settings.provider_override block_client_ipv6
	load_with "$filter"
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override keeps own $2"
	load_with
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override after key drop"
	load_with "$filter"
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override after key re-add"
done
pass "provider and own"

# The provider's own IPv6 DNS choice (dns.queryStrategy) is independent of the flag.
uci delete xraywrt.settings.provider_override
for flag in true false; do
	for strategy in UseIP UseIPv4 ''; do
		filter=".dns.servers = [\"https://dns.example.com/dns-query\"] | .xraywrt = {\"block-client-ipv6\": $flag}"
		[ -z "$strategy" ] || filter="$filter | .dns.queryStrategy = \"$strategy\""
		fake_uci_set xraywrt.settings.block_client_ipv6 0
		load_with "$filter"
		expected=0; [ "$flag" = false ] || expected=1
		assert_eq "$expected" "$BLOCK_CLIENT_IPV6" "flag $flag independent of queryStrategy '$strategy'"
		xray_config_generate "$XRAY_CONFIG" "$out"
		assert_eq "${strategy:-null}" "$(jq -r .dns.queryStrategy "$out")" "provider queryStrategy preserved: $strategy"
	done
done
for strategy in UseIP UseIPv6; do
	fake_uci_set xraywrt.settings.block_client_ipv6 0
	load_with ".dns.queryStrategy = \"$strategy\""
	assert_eq 0 "$BLOCK_CLIENT_IPV6" "no implicit activation from $strategy"
done
pass "independent core keys"

fake_uci_reset
fake_uci_set network.lan.ipaddr 192.168.8.1/24
rm -f "$tmpdir/commits"
cp "$FAKE_UCI_DB" "$tmpdir/uci.before"
load_with '.xraywrt = {"block-client-ipv6": "on"}'
assert_eq 1 "$BLOCK_CLIENT_IPV6" "provider on"
cmp -s "$FAKE_UCI_DB" "$tmpdir/uci.before" || fail "provider value persisted into UCI"
assert_false "no UCI commit" test -e "$tmpdir/commits"
pass "no persistence"

grep -q "option block_client_ipv6 '0'" "$ROOT_DIR/rootfs/etc/config/xraywrt" || fail "shipped default"
pass "shipped default off"

# Client boundary: real list resolution, custom interfaces and every supported
# profile. Exact entry-chain assertions pin the path before list/NTP/QUIC rules.
(
 load_modules nft.sh route.sh
 fake_uci_reset
 settings_load
 LIST_DIR="$tmpdir/boundary-lists"
 RULES_FILE="$LIST_DIR/rules.txt"
 SRC_LIST_FILE="$LIST_DIR/src.txt"
 DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src.txt"
 POLICY_CACHE_DIR="$tmpdir/boundary-cache"
 lists_ensure_files
 # Entries with ports exist only in the provider's lists.
 printf 'profile-schema 1\nhas proxy-ips\nproxy-ip 2606:4700::/32\nproxy-ip 2606:4700::1111;443\nproxy-ip ;53\nhas direct-ips\ndirect-ip 2606:4700::/32\ndirect-ip 2606:4700::1111;443\ndirect-ip ;53\n' >"$PROFILE_FILE"
 printf '2001:db8::10\naa:bb:cc:dd:ee:ff\n;443\n' >"$SRC_LIST_FILE"
 cp "$SRC_LIST_FILE" "$DIRECT_SRC_LIST_FILE"
 SOURCE_INTERFACES='br-guest wt9'
 NETBIRD_INTERFACE=wt9
 BYPASS_NTP=1
 DISABLE_QUIC=1
 DNS_HIJACK=1
 ip() {
  case "$*" in
   '-6 route show table main') echo '2001:db8:1::/64 dev br-guest' ;;
  esac
  return 0
 }
 work="$tmpdir/boundary-work"
 mkdir -p "$work"
 rules="$tmpdir/boundary.nft"
 chain_rules() { grep -F "add rule inet xraywrt $1 " "$rules"; }
 for profile in direct-first:fake-ip proxy-first:fake-ip proxy-first:redir-host; do
  POLICY_MODE="${profile%:*}"
  DNS_MODE="${profile#*:}"
  unset BLOCK_CLIENT_IPV6
  nft_render "$rules" "$work"
  cp "$rules" "$tmpdir/boundary-off.nft"
  BLOCK_CLIENT_IPV6=0
  nft_render "$rules" "$work"
  assert_true "$profile absent equals off" cmp -s "$rules" "$tmpdir/boundary-off.nft"
  assert_file_not_contains "$rules" client_ipv6_egress "$profile off has no boundary chain"
  assert_file_not_contains "$rules" 'iifname @source_ifaces meta nfproto ipv6 return' "$profile off has no client IPv6 guards"
  assert_file_not_contains "$rules" 'reject with' "$profile off has no new rejects"
  expected='add rule inet xraywrt dns_hijack iifname "wt9" return
add rule inet xraywrt dns_hijack fib daddr type local return
add rule inet xraywrt dns_hijack iifname @source_ifaces ip daddr != @localv4 meta l4proto { tcp, udp } th dport 53 redirect to :53
add rule inet xraywrt dns_hijack iifname @source_ifaces ip6 daddr != @localv6 meta l4proto { tcp, udp } th dport 53 redirect to :53'
  assert_eq "$expected" "$(chain_rules dns_hijack)" "$profile off protects router DNS before both redirects"
  assert_file_contains "$rules" 'tproxy ip6 to [::1]:7894' "$profile off keeps IPv6 TPROXY"
  BLOCK_CLIENT_IPV6=1
  nft_render "$rules" "$work"
  if [ "$POLICY_MODE" = proxy-first ]; then
   assert_true "$profile flag on equals off" cmp -s "$rules" "$tmpdir/boundary-off.nft"
   continue
  fi
  assert_file_contains "$rules" 'add chain inet xraywrt client_ipv6_egress { type filter hook forward priority -1; policy accept; }' "$profile forward rejection"
  expected='add rule inet xraywrt client_ipv6_egress ct direction reply return
add rule inet xraywrt client_ipv6_egress iifname "wt9" return
add rule inet xraywrt client_ipv6_egress meta nfproto != ipv6 return
add rule inet xraywrt client_ipv6_egress iifname != @source_ifaces return
add rule inet xraywrt client_ipv6_egress fib daddr type local return
add rule inet xraywrt client_ipv6_egress ip6 daddr @localv6 return
add rule inet xraywrt client_ipv6_egress meta nfproto ipv6 meta l4proto tcp counter reject with tcp reset
add rule inet xraywrt client_ipv6_egress meta nfproto ipv6 counter reject with icmpv6 type admin-prohibited'
  assert_eq "$expected" "$(chain_rules client_ipv6_egress)" "$profile scoped rejection order; local returns, no accept/established/list loophole"
  expected='add rule inet xraywrt mangle_prerouting iifname "wt9" return
add rule inet xraywrt mangle_prerouting iifname @source_ifaces jump prerouting_policy'
  assert_eq "$expected" "$(chain_rules mangle_prerouting)" "$profile no IPv6 skip before policy"
  expected='add rule inet xraywrt proxy_redirect iifname "wt9" return
add rule inet xraywrt proxy_redirect meta mark & 0x08000000 == 0x08000000 meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:7894
add rule inet xraywrt proxy_redirect meta mark & 0x08000000 == 0x08000000 meta nfproto ipv6 meta l4proto { tcp, udp } tproxy ip6 to [::1]:7894'
  assert_eq "$expected" "$(chain_rules proxy_redirect)" "$profile selected IPv6 reaches TPROXY"
  expected='add rule inet xraywrt dns_hijack iifname "wt9" return
add rule inet xraywrt dns_hijack fib daddr type local return
add rule inet xraywrt dns_hijack iifname @source_ifaces ip daddr != @localv4 meta l4proto { tcp, udp } th dport 53 redirect to :53
add rule inet xraywrt dns_hijack iifname @source_ifaces ip6 daddr != @localv6 meta l4proto { tcp, udp } th dport 53 redirect to :53'
  assert_eq "$expected" "$(chain_rules dns_hijack)" "$profile IPv6 DNS redirect independent of flag"
  for iface in br-guest wt9; do
   assert_file_contains "$rules" "source_ifaces { \"$iface\" }" "$profile custom source interface"
  done
  assert_file_contains "$rules" 'localv6 { 2001:db8:1::/64 }' "$profile existing connected-local discovery"
  for expression in 'ip6 daddr' 'meta nfproto ipv6 meta l4proto { tcp, udp } th dport { 53 }'; do
   assert_file_contains "$rules" "prerouting_policy $expression" "$profile populated destination/port-only list rules remain behind guard"
  done
  if [ "$POLICY_MODE" = direct-first ] || [ "$DNS_MODE" = redir-host ]; then
   assert_file_contains "$rules" 'prerouting_policy ip6 saddr' "$profile source list behind guard"
   assert_file_contains "$rules" 'prerouting_policy ether saddr' "$profile MAC list behind guard"
  fi
  assert_file_contains "$rules" 'prerouting_policy meta nfproto ipv6 udp dport 123 return' "$profile NTP remains behind entry guard"
  assert_file_not_contains "$rules" 'ct state established,related' "$profile no flow-state bypass"
  for pattern in '^add rule inet xraywrt mangle_output ' ' (ip |meta nfproto ipv4)'; do
   assert_eq "$(grep -E "$pattern" "$tmpdir/boundary-off.nft")" "$(grep -E "$pattern" "$rules")" "$profile router output and IPv4 expressions unchanged"
  done
  assert_file_contains "$rules" 'mangle_output meta mark & 0x000000ff == 2 return' "$profile Xray routing-mark exemption unchanged"
  BLOCK_CLIENT_IPV6=0
  nft_render "$rules" "$work"
  assert_true "$profile disable removes all boundary rules" cmp -s "$rules" "$tmpdir/boundary-off.nft"
  pass "$profile client IPv6 boundary"
 done

 # NetBird router-output selection remains identical in both settings.
 for NETBIRD_PROXY in 0 1; do
  for BLOCK_CLIENT_IPV6 in 0 1; do
   nft_render "$rules" "$work"
   chain_rules mangle_output >"$tmpdir/output-$BLOCK_CLIENT_IPV6"
  done
  assert_true "NetBird output unchanged ($NETBIRD_PROXY)" cmp -s "$tmpdir/output-0" "$tmpdir/output-1"
 done
 # The flag never suppresses the existing IPv6 policy route.
 route_families() { printf '4\n6\n'; }
 route_state_read() { ROUTE_TABLE=100; ROUTE_PRIORITY=50; }
 route_rule_present() { return 1; }
 ROUTE_STATE_FILE="$tmpdir/boundary-route.state"
 ip() { printf '%s\n' "$*" >>"$tmpdir/route-$BLOCK_CLIENT_IPV6"; }
 for BLOCK_CLIENT_IPV6 in 0 1; do route_setup; done
 assert_true 'policy routing unchanged' cmp -s "$tmpdir/route-0" "$tmpdir/route-1"
 assert_file_contains "$tmpdir/route-1" '-6 route replace local default dev lo table 100' 'IPv6 local route retained'
 pass 'router output and IPv6 routes unchanged'
)
