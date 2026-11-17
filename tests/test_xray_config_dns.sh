#!/usr/bin/env bash
# xray-config.uc DNS: internal DNS, no router bootstrap server, default resolver, loop
# guards (spec 7.3, 7.4), fake-IP (7.2) and the DNS outbound (7.5).

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"

# Activation is not a domain count: unrestricted FakeDNS is still active.
for server in '"fakedns"' '{"address":"fakedns"}' '{"address":"fakedns","domains":[]}'; do
 jq --argjson server "$server" '.dns.servers = [$server]' "$FX/src/single.json" >"$tmpdir/unrestricted.json"
 gen "$tmpdir/unrestricted.json"
 assert_eq 0 "$rc" "unrestricted FakeDNS: $errtxt"
 prof_has 'fake-domains 0'
 prof_has 'fake-enabled 1'
 jq -e '.fakedns == [{ipPool:"198.18.0.0/15",poolSize:65535}] and ([.inbounds[].tag] | index("xraywrt-fakeip-direct") != null)' <<<"$out" >/dev/null || fail 'IPv4 FakeDNS and direct listener active'
done
pass 'FakeDNS activation independent of domain count'

bootrule() { jq -c '.routing.rules[] | select(.inboundTag == ["xraywrt-dns-internal"]) | .ip' <<<"$out"; }

# No provider domains: My rules still get their own FakeDNS server.
gen "$FX/src/single.json" ".rules_file = \"$FX/lst/rules.txt\""
prof_has 'fake-domains 6'
prof_has 'provider-fake-domains 0'
pass 'own fake sites without provider domains'

# A5.9 internal DNS (spec 7.3, 7.4).
gen "$FX/src/single.json"
assert_eq 0 "$rc" "single.json: $errtxt"
assert_eq "{\"tag\":\"xraywrt-dns-internal\",\"servers\":[\"192.0.2.53\"]}" "$(jq -c .dns <<<"$out")" 'no provider DNS: WAN DNS'
prof_has 'uses-wan-dns'
prof_has 'warn no proxy DNS configured, using WAN DNS'
assert_eq '["127.0.0.1"]' "$(bootrule)" 'proxy-first: WAN DNS follow provider routing'
gen "$FX/src/single.json" '.mode_override = true | .mode = "direct-first" | .wan_dns = ["192.0.2.53", "2001:db8::53"]'
assert_eq "[\"192.0.2.53\",\"2001:db8::53\"]" "$(jq -c .dns.servers <<<"$out")" 'all WAN DNS'
assert_eq '["127.0.0.1","192.0.2.53","2001:db8::53"]' "$(bootrule)" 'direct-first: WAN DNS go direct'
prof_has 'uses-wan-dns'
prof_lacks 'warn no proxy DNS configured, using WAN DNS'
# The removed dns_upstream parameter changes nothing.
gen "$FX/src/single.json" '.mode_override = true | .mode = "direct-first" | .dns_upstream = ["tcp://192.0.2.10"]'
assert_eq '["192.0.2.53"]' "$(jq -c .dns.servers <<<"$out")" 'dns_upstream is not a parameter any more'
pass 'default resolver'

gen "$FX/src/full.json"
jq -e '.dns == {tag: "xraywrt-dns-internal", servers: ["https://dns.example.net/dns-query"],
	hosts: {"router.example.com": "192.168.1.1"}, queryStrategy: "UseIPv4"}' <<<"$out" >/dev/null || fail "provider DNS kept: $(jq -c .dns <<<"$out")"
! grep -q 'uses-wan-dns' <<<"$prof" || fail 'provider DNS: no WAN DNS'
provboot='{"address":"127.0.0.1","port":53,"domains":["full:node.example.com"],"skipFallback":true}'
jq --argjson b "$provboot" '.dns.servers = [$b, "https://dns.example.net/dns-query"]' "$FX/src/full.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq "[$provboot,\"https://dns.example.net/dns-query\"]" "$(jq -c .dns.servers <<<"$out")" 'provider bootstrap server kept, none added'
jq '.dns = {"tag": "prov", "servers": [{"address": "fakedns", "queryStrategy": "UseIPv4"}, {"address": "192.0.2.20", "port": 853, "domains": ["geosite:x"]}], "disableCache": true}
	| .routing.rules += [{"inboundTag": ["prov", "other"], "outboundTag": "direct"}, {"inboundTag": ["other"], "outboundTag": "block"}]' \
	"$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq "{\"tag\":\"xraywrt-dns-internal\",\"servers\":[{\"address\":\"fakedns\",\"queryStrategy\":\"UseIPv4\"},{\"address\":\"192.0.2.20\",\"port\":853,\"domains\":[\"geosite:x\"]}],\"disableCache\":true}" \
	"$(jq -c .dns <<<"$out")" 'provider tag replaced'
assert_eq '[["xraywrt-dns-internal","other"],["other"]]' "$(jq -c '[.routing.rules[-2:][].inboundTag]' <<<"$out")" 'old DNS tag renamed in rules'
prof_has 'warn dns tag "prov" renamed to xraywrt-dns-internal'
prof_lacks 'uses-wan-dns'
# Direct forwarding before WAN DNS arrives at boot: off now, rebuilt by net_refresh later.
gen "$tmpdir/src.json" '.mode_override = true | .mode = "direct-first" | .dns_forward_other_types = "1" | .wan_dns = []'
assert_eq 0 "$rc" "direct forwarding without WAN DNS: $errtxt"
assert_eq '{"action":"return"}' "$(jq -c '.outbounds[] | select(.tag == "xraywrt-dns") | .settings.rules[-1]' <<<"$out")" 'no WAN DNS yet: other types return'
prof_has 'uses-wan-dns'
jq '.dns = {"servers": ["fakedns"]}' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq '"192.0.2.53"' "$(jq -c '.dns.servers[-1]' <<<"$out")" 'only fakedns servers: default resolver appended'
prof_has 'uses-wan-dns'
src_json '{"outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "203.0.113.5", "port": 443, "users": []}]}}]}'
gen "$tmpdir/src.json"
assert_eq '["192.0.2.53"]' "$(jq -c .dns.servers <<<"$out")" 'no server hosts: WAN DNS only'
pass 'provider DNS'

loop() {
	jq --argjson s "$1" '.dns = {"servers": [$s]}' "$FX/src/single.json" >"$tmpdir/src.json"
	gen_fails "$tmpdir/src.json" "config: DNS server \"$2\" loops back to dnsmasq or Xray; restrict it with domains"
}
loop '"localhost"' localhost
loop '"127.0.0.1"' 127.0.0.1
loop '"udp://127.0.0.1:53"' udp://127.0.0.1:53
loop '"tcp://127.0.0.1:7874"' tcp://127.0.0.1:7874
loop '{"address": "127.0.0.1", "port": 7874}' 127.0.0.1:7874
loop '{"address": "localhost", "domains": []}' localhost
loop '"::1"' ::1
loop '{"address": "tcp+local://[::1]:53"}' 'tcp+local://[::1]:53'
jq '.dns = {"servers": [{"address": "127.0.0.1", "port": 53, "domains": ["domain:lan"]}, "127.0.0.1:5353", "https://127.0.0.1/dns-query"]}' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "restricted or other-port loopback: $errtxt"
gen_fails "$FX/src/single.json" 'config: no DNS server: add dns.servers to the configuration' '.wan_dns = []'
jq '.dns = "x"' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: dns is not an object'
jq '.dns = {"servers": "x"}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: dns.servers is not an array'
pass 'DNS loop guards'

# A5.10 fake-IP (spec 7.2), both modes.
fd="$FX/lst/rules.txt"
own='{"address":"fakedns","domains":["geosite:youtube","domain:example.com","full:api.example.org","regexp:^cdn[0-9]+\\.example\\.net$","keyword:tracker","ext:extra.dat:video"],"skipFallback":true,"queryStrategy":"UseIPv4"}'
provfake='{"address":"fakedns","domains":["geosite:netflix"],"queryStrategy":"UseIPv6"}'
jq --argjson f "$provfake" '.dns = {"servers": [$f, "fakedns", "https://dns.example.net/dns-query"]}' "$FX/src/single.json" >"$tmpdir/fake.json"
for mode in proxy-first direct-first; do
	gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\""
	jq -e 'has("fakedns") | not' <<<"$out" >/dev/null || fail "$mode: no fakedns section without servers"
	prof_has 'fake-domains 0'
	gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$fd\""
	assert_eq "[$own,\"192.0.2.53\"]" "$(jq -c .dns.servers <<<"$out")" "$mode: own lines first"
	jq -e '.fakedns == [{ipPool: "198.18.0.0/15", poolSize: 65535}]' <<<"$out" >/dev/null || fail "$mode: router fakedns pool"
	jq -e '.inbounds[0].sniffing.destOverride[0] == "fakedns"' <<<"$out" >/dev/null || fail "$mode: sniffing fakedns"
	jq -e '[.routing.rules[] | select(.outboundTag == "xraywrt-block")] | length == 1' <<<"$out" >/dev/null || fail "$mode: fake range rule"
	jq -e '[.routing.rules[] | select(.ruleTag != null)] == []' <<<"$out" >/dev/null || fail "$mode: core lines make no routing rule"
	prof_has 'fake-domains 6'
	prof_has 'warn My rules: line 9 "foo:bar core" ignored'
	prof_has 'warn My rules: line 10 "bad host core" ignored'
	prof_has 'warn My rules: line 11 "ext:nodat core" ignored'
	prof_has 'warn My rules: line 12 "domain: core" ignored'
	# The provider's own fake-IP servers are always used, after ours.
	gen "$tmpdir/fake.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$fd\""
	assert_eq "[$own,$provfake,{\"address\":\"fakedns\",\"queryStrategy\":\"UseIPv4\"},\"https://dns.example.net/dns-query\"]" \
		"$(jq -c .dns.servers <<<"$out")" "$mode: provider servers kept"
	prof_has 'fake-domains 7'
	prof_has 'provider-fake-domains 1'
	gen "$tmpdir/fake.json" ".mode_override = true | .mode = \"$mode\""
	assert_eq "[$provfake,{\"address\":\"fakedns\",\"queryStrategy\":\"UseIPv4\"},\"https://dns.example.net/dns-query\"]" \
		"$(jq -c .dns.servers <<<"$out")" "$mode: no rules"
	prof_has 'fake-domains 1'
done
gen "$FX/src/single.json" ".rules_file = \"$tmpdir/missing.txt\""
assert_eq 0 "$rc" "missing rules file: $errtxt"
prof_has 'fake-domains 0'
seq 1 10005 | sed 's/^/d/; s/$/.example.com core/' >"$tmpdir/many.txt"
gen "$FX/src/single.json" ".rules_file = \"$tmpdir/many.txt\""
prof_has 'fake-domains 10000'
prof_has 'warn My rules has more than 10000 sites, the rest is ignored'
pass 'fake-IP'

# A5.11 DNS outbound rules (spec 7.5).
dnsob() { jq -c '.outbounds[] | select(.tag == "xraywrt-dns")' <<<"$out"; }
aaaa='{"qType":"1,28","action":"hijack"}'
dnsin() { jq -c '.inbounds[] | select(.tag == "xraywrt-dns-in") | .settings' <<<"$out"; }
fwd='.mode_override = true | .mode = "direct-first" | .dns_forward_other_types = 1'
gen "$FX/src/single.json"
assert_eq "{\"tag\":\"xraywrt-dns\",\"protocol\":\"dns\",\"streamSettings\":{\"sockopt\":{\"mark\":2}},\"settings\":{\"rules\":[$aaaa,{\"action\":\"return\"}]}}" "$(dnsob)" 'defaults: other types empty'
assert_eq '{"allowedNetwork":"tcp,udp"}' "$(dnsin)" 'defaults: no rewrite'
gen "$FX/src/single.json" '.rules_file = "'"$fd"'"'
assert_eq "[$aaaa,{\"action\":\"return\"}]" "$(dnsob | jq -c .settings.rules)" 'not forwarding: no whitelist rule'
gen "$FX/src/single.json" '.dns_forward_other_types = 1'
assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'proxy-first ignores dns_forward_other_types'
gen "$FX/src/single.json" "$fwd"' | .rules_file = "'"$fd"'"'
assert_eq "[$aaaa,{\"domain\":$(jq -c .domains <<<"$own"),\"action\":\"return\"},{\"action\":\"direct\"}]" "$(dnsob | jq -c .settings.rules)" 'direct-first forward: whitelist empty, rest raw'
assert_eq '{"allowedNetwork":"tcp,udp","rewriteAddress":"192.0.2.53","rewritePort":53}' "$(dnsin)" 'forward: rewrite to WAN DNS'
dnsob | jq -e '.streamSettings.sockopt | has("dialerProxy") | not' >/dev/null || fail 'forward: no dialerProxy'
gen "$tmpdir/fake.json" "$fwd"
assert_eq '{"domain":["geosite:netflix"],"action":"return"}' "$(dnsob | jq -c .settings.rules[1])" 'provider whitelist'
assert_eq '{"qType":"65,64","action":"return"}' "$(dnsob | jq -c .settings.rules[2])" 'bare fakedns server: HTTPS records stay empty'
jq '.dns.servers = ["https://dns.example.org/dns-query"]' "$FX/src/single.json" >"$tmpdir/own-dns.json"
gen "$tmpdir/own-dns.json" "$fwd"' | .wan_dns = []'
assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'no raw address: empty'
assert_eq '{"allowedNetwork":"tcp,udp"}' "$(dnsin)" 'no raw address: no rewrite'
# Provider key dns-forward-other-types applies in the same pass; provider_override keeps UCI.
jq '.xraywrt = {"dns-forward-other-types": true}' "$FX/src/single.json" >"$tmpdir/pfwd.json"
gen "$tmpdir/pfwd.json" '.mode_override = true | .mode = "direct-first"'
assert_eq '{"action":"direct"}' "$(dnsob | jq -c .settings.rules[-1])" 'provider forward key applies'
gen "$tmpdir/pfwd.json" '.mode_override = true | .mode = "direct-first" | .dns_forward_override = true'
assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'provider_override keeps UCI 0'
jq '.xraywrt = {"dns-forward-other-types": false}' "$FX/src/single.json" >"$tmpdir/pfwd0.json"
gen "$tmpdir/pfwd0.json" "$fwd"
assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'provider false beats UCI 1'
gen "$FX/src/full.json"
prof_lacks 'uses-wan-dns'
gen "$FX/src/full.json" "$fwd"
prof_has 'uses-wan-dns'
gen "$FX/src/full.json" "$fwd"' | .dns_raw_upstream = "[2001:db8::53]:5353"'
assert_eq '{"allowedNetwork":"tcp,udp","rewriteAddress":"2001:db8::53","rewritePort":5353}' "$(dnsin)" 'raw upstream'
prof_lacks 'uses-wan-dns'
tag="$(jq -r '.outbounds[0].tag' "$FX/src/single.json")"
gen "$FX/src/single.json" ".dns_raw_via = \"$tag\" | .dns_raw_upstream = \"192.0.2.54\""
assert_eq "{\"mark\":2,\"dialerProxy\":\"$tag\"}" "$(dnsob | jq -c .streamSettings.sockopt)" 'raw_via dialerProxy'
assert_eq '{"action":"direct"}' "$(dnsob | jq -c .settings.rules[-1])" 'raw_via forwards in proxy-first'
assert_eq '{"allowedNetwork":"tcp,udp","rewriteAddress":"192.0.2.54","rewritePort":53}' "$(dnsin)" 'raw_via: explicit rewrite'
gen "$FX/src/single.json" '.dns_raw_via = "nope" | .dns_raw_upstream = "192.0.2.54"'
assert_eq 0 "$rc" "missing DNS outbound forces off: $errtxt"
prof_has 'dns-raw-lost nope'
assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'missing outbound cannot fall back to another route'
pass 'DNS outbound rules'

# Via never falls back to WAN, even for manually saved settings.
for wan in '["192.0.2.53"]' '[]'; do
 gen_fails "$tmpdir/own-dns.json" 'config: dns_raw_upstream is required with dns_raw_via; set an explicit DNS server IP address and optional port' ".dns_raw_via = \"$tag\" | .wan_dns = $wan"
done
for value in 'dns.example' '999.2.3.4' '192.0.2.53:0' '192.0.2.53:65536' '[2001:::53]:53' '192.0.2.0/24' '192.000.2.53' '01.2.3.4' '192.000.2.53:5353' '01.2.3.4:5353' '::ffff:192.000.2.53' '::ffff:01.2.3.4' '[::ffff:192.000.2.53]:5353' '[::ffff:01.2.3.4]:5353'; do
 gen_fails "$FX/src/single.json" 'config: dns_raw_upstream must be an IP address with an optional port (1-65535)' ".dns_raw_via = \"$tag\" | .dns_raw_upstream = \"$value\""
done
for value in '192.0.2.54' '192.0.2.54:5353' '2001:db8::53' '[2001:db8::53]:5353' '::ffff:192.0.2.53' '[::ffff:192.0.2.53]:5353'; do
 gen "$FX/src/full.json" ".dns_raw_via = \"$tag\" | .dns_raw_upstream = \"$value\""
 assert_eq 0 "$rc" "explicit via address: $errtxt"
 prof_lacks 'uses-wan-dns'
done
pass 'VPN raw DNS requires an explicit valid IP'

# An inactive saved server is retained, but never creates an invalid rebinding exemption.
for source in "$FX/src/full.json" "$tmpdir/pfwd0.json"; do
 for mode in proxy-first direct-first; do
  gen "$source" ".mode_override = true | .mode = \"$mode\" | .dns_raw_upstream = \"192.0.2.53:0\" | .dns_raw_via = \"\" | .dns_forward_other_types = 0"
  assert_eq 0 "$rc" "$mode off/provider-off with saved invalid upstream: $errtxt"
  assert_eq '{"allowedNetwork":"tcp,udp"}' "$(dnsin)" 'inactive upstream creates no DNS rewrite'
  assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'inactive forwarding keeps empty answers'
  jq -e '[.outbounds[] | select(.protocol == "freedom") | .settings.finalRules[]? | select(.action == "allow" and has("ip"))] == []' <<<"$out" >/dev/null || fail 'invalid inactive upstream must not create a rebinding exemption'
  assert_eq '192.0.2.53:0' "$(jq -r .dns_raw_upstream "$tmpdir/params.json")" 'inactive saved server is preserved'
 done
done
for source in "$FX/src/full.json" "$tmpdir/pfwd.json"; do
 gen_fails "$source" 'config: dns_raw_upstream must be an IP address with an optional port (1-65535)' '.mode_override = true | .mode = "direct-first" | .dns_forward_other_types = 1 | .dns_raw_upstream = "192.0.2.53:0"'
done
pass 'inactive invalid DNS server does not block off/provider-off generation'


# Catalog uses selected original outbounds, not generated handlers or balancers.
jq '.outbounds += [{tag:"plain",protocol:"freedom"},{tag:"blocked",protocol:"blackhole"},{tag:"resolver",protocol:"dns"},{tag:"loop",protocol:"loopback"},{tag:"VPN 🇷🇺 = primary",protocol:"freedom",streamSettings:{sockopt:{dialerProxy:"proxy"}}},{protocol:"socks"}] | .routing.balancers = [{tag:"pool",selector:["proxy"]}]' "$FX/src/single.json" >"$tmpdir/catalog.json"
assert_eq '["proxy","VPN 🇷🇺 = primary"]' "$(xraywrt-json dns-outbounds "$tmpdir/catalog.json" '')" 'safe DNS outbound catalog'
jq -s '[.[0] + {remarks:"first"}, .[0] + {remarks:"chosen",outbounds:[{protocol:"socks",tag:"chosen tag"}]}]' "$tmpdir/catalog.json" >"$tmpdir/catalog-array.json"
assert_eq '["chosen tag"]' "$(xraywrt-json dns-outbounds "$tmpdir/catalog-array.json" chosen)" 'selected original profile'
jq '.[0].xraywrt = {"router-profile":"chosen"}' "$tmpdir/catalog-array.json" >"$tmpdir/catalog-pinned.json"
assert_eq '["chosen tag"]' "$(xraywrt-json dns-outbounds "$tmpdir/catalog-pinned.json" first)" 'provider pin beats selection'
for tag in plain blocked resolver loop pool xraywrt-direct; do
 gen "$tmpdir/catalog.json" ".dns_raw_via = \"$tag\" | .dns_raw_upstream = \"192.0.2.54\""
 assert_eq 0 "$rc" "unsuitable DNS outbound forces off: $errtxt"
 prof_has "dns-raw-lost $tag"
 assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'unsuitable outbound cannot forward'
done
for source in "$tmpdir/catalog-array.json" "$tmpdir/catalog-pinned.json"; do
 gen "$source" '.profile = "chosen" | .dns_raw_via = "proxy" | .dns_raw_upstream = "192.0.2.54"'
 assert_eq 0 "$rc" "selected original profile forces off: $errtxt"
 prof_has 'dns-raw-lost proxy'
 assert_eq '{"action":"return"}' "$(dnsob | jq -c .settings.rules[-1])" 'selected profile cannot borrow another profile outbound'
done
gen "$tmpdir/catalog.json" '.dns_raw_via = "VPN 🇷🇺 = primary" | .dns_raw_upstream = "192.0.2.54"'
assert_eq 0 "$rc" "chained freedom outbound: $errtxt"
assert_eq 'VPN 🇷🇺 = primary' "$(dnsob | jq -r .streamSettings.sockopt.dialerProxy)" 'explicit chain preserved'
pass 'DNS outbound catalog and generator agree'


# Settings and old cache readers use activation, never the count.
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh dns.sh xray-config.sh
setup_runtime_paths "$tmpdir/runtime"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
cp "$tmpdir/unrestricted.json" "$XRAY_CONFIG"
printf 'profile-schema 1\nmode proxy-first\nfake-domains 0\n' >"$PROFILE_FILE"
settings_load
assert_eq 1 "$(profile_get fake-enabled)" 'missing activation flag rebuilds cache'
assert_eq 'fake-ip:1' "$DNS_MODE:$DIRECT_LISTENER" 'zero-count active FakeDNS enables runtime policy'
jq 'del(.dns)' "$XRAY_CONFIG" >"$tmpdir/nodns.json" && cp "$tmpdir/nodns.json" "$XRAY_CONFIG"
rm -f "$PROFILE_FILE"
settings_load
assert_eq 'redir-host:0' "$DNS_MODE:$DIRECT_LISTENER" 'removing last FakeDNS disables runtime policy'
pass 'settings rebuild old cache and consume activation flag'
