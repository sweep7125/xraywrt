#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh dns.sh nft.sh route.sh
setup_runtime_paths "$tmpdir"
FX="$ROOT_DIR/tests/fixtures/xray"
src="$tmpdir/source.json"
out="$tmpdir/runtime.json"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"

# Spec 6.3/6.5: fakedns servers bring the direct listener (7895) and its
# rule; provider inbounds stay as they are.
(
 warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
 for mode in proxy-first direct-first; do
  UCI_MODE="$mode"
  jq '.inbounds = [{"tag": "lan-socks", "protocol": "socks", "port": 17891}]' "$FX/src/fakedns.json" >"$src"
  cp "$src" "$tmpdir/source-copy"
  : >"$tmpdir/warnings"
  xray_config_generate "$src" "$out"
  assert_true "$mode source untouched" cmp -s "$src" "$tmpdir/source-copy"
  assert_true "$mode fakedns domains in the profile" grep -qE '^fake-domains [1-9]' "$out.profile"
  assert_eq '7895 127.0.0.1' "$(jq -r '[.inbounds[] | select(.tag | startswith("xraywrt-") and test("direct")) | "\(.port) \(.listen)"] | join("|")' "$out")" "$mode one IPv4 loopback inbound: the fake pool is IPv4"
  assert_eq '["fakedns"]' "$(jq -c '.inbounds[] | select(.tag == "xraywrt-fakeip-direct") | .sniffing.destOverride' "$out")" "$mode direct inbound sniffs fake-IP only"
  assert_eq lan-socks "$(jq -r '.inbounds[0].tag' "$out")" "$mode provider inbound kept"
  assert_false "$mode no inbound warning" grep -q inbound "$tmpdir/warnings"
  assert_eq 3 "$(jq '[.routing.rules[].inboundTag == ["xraywrt-fakeip-direct"]] | index(true)' "$out")" "$mode direct rule follows the fake-IP block rule"
  assert_eq xraywrt-direct "$(jq -r '.routing.rules[3].outboundTag' "$out")" "$mode direct devices go direct"
  assert_eq '{"domain":["geosite:netflix"],"outboundTag":"proxy"}' "$(jq -c '.routing.rules[4]' "$out")" "$mode provider rules follow"
  cp "$FX/src/single.json" "$src"
  xray_config_generate "$src" "$out"
  assert_false "$mode no fakedns, no direct inbound" grep -q xraywrt-fakeip-direct "$out"
  assert_false "$mode no fakedns, no fake-IP domains" grep -qE '^fake-domains [1-9]' "$out.profile"
 done
)
pass 'fake-IP direct listener in the generated config'

settings_load
POLICY_MODE=proxy-first
DNS_MODE=fake-ip
DIRECT_LISTENER=1
DISABLE_QUIC=1
mkdir -p "$tmpdir/work"
printf 'aa:bb:cc:dd:ee:ff\n192.0.2.2\n2001:db8::2\n192.0.2.3;80,443\n2001:db8::3;443\n;8080\n' >"$DIRECT_SRC_LIST_FILE"
ip() { return 0; }
nft_render "$out" "$tmpdir/work"
for match in 'ether saddr @direct_src_mac' 'ip saddr @direct_src' 'ip6 saddr @direct_src6' 'ip saddr { 192.0.2.3 } meta l4proto { tcp, udp } th dport { 80,443 }' 'ip6 saddr { 2001:db8::3 } meta l4proto { tcp, udp } th dport { 443 }' 'meta nfproto ipv4 meta l4proto { tcp, udp } th dport { 8080 }'; do
 assert_file_contains "$out" "prerouting_policy $match goto direct_device_policy" "fake-IP device form: $match"
done
assert_file_contains "$out" 'add element inet xraywrt direct_src_mac { aa:bb:cc:dd:ee:ff }' 'fake-IP fills device sets'
expected="add rule inet xraywrt direct_device_policy meta nfproto ipv6 return
add rule inet xraywrt direct_device_policy ip daddr != $FAKEIP_RANGE return
add rule inet xraywrt direct_device_policy ip daddr $FAKEIP_RANGE udp dport 443 reject
add rule inet xraywrt direct_device_policy ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set meta mark | $NFT_INTERCEPT_MARK | $NFT_DIRECT_MARK accept"
assert_eq "$expected" "$(grep '^add rule inet xraywrt direct_device_policy ' "$out")" 'real destinations return, fake QUIC rejects before direct marking'
first="$(grep '^add rule inet xraywrt proxy_redirect ' "$out" | sed -n '2p')"
assert_eq "add rule inet xraywrt proxy_redirect meta mark & $NFT_DIRECT_MARK == $NFT_DIRECT_MARK meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$XRAY_DIRECT_TPROXY_PORT accept" "$first" 'dedicated TPROXY terminates before generic TPROXY'
assert_file_not_contains "$out" 'mangle_output meta mark & 0x04000000' 'router output does not select direct devices'
DISABLE_QUIC=0
nft_render "$out" "$tmpdir/work"
assert_file_not_contains "$out" 'udp dport 443 reject' 'fake direct QUIC allowed when disabled'
pass 'fake-IP direct devices nft policy'

DIRECT_LISTENER=0
nft_render "$out" "$tmpdir/work"
assert_file_not_contains "$out" direct_device_policy 'no fake-IP direct chain without listener'
assert_file_not_contains "$out" "127.0.0.1:$XRAY_DIRECT_TPROXY_PORT" 'no dedicated TPROXY without listener'
assert_file_not_contains "$out" 'prerouting_policy ether saddr @direct_src' 'fake-IP direct devices skipped without listener'
assert_file_not_contains "$out" 'add element inet xraywrt direct_src' 'no direct source sets populated without listener'
assert_file_contains "$out" "prerouting_policy meta l4proto { tcp, udp } meta mark set" 'fallback keeps generic fake-IP interception'
printf 'profile-schema 1\nfake-enabled 1\nmode proxy-first\nfake-domains 3\n' >"$PROFILE_FILE"
settings_load
assert_eq 'fake-ip:1' "$DNS_MODE:$DIRECT_LISTENER" 'settings loads the listener with fakedns domains'
printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\nfake-domains 0\n' >"$PROFILE_FILE"
settings_load
assert_eq 'redir-host:0' "$DNS_MODE:$DIRECT_LISTENER" 'settings resets the listener without fakedns domains'
pass 'fake-IP direct devices fallback without listener'
