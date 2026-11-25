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
jq '.dns.servers = ["fakedns"] | .routing.domainStrategy = "IPIfNonMatch"' "$FX/src/single.json" >"$tmpdir/sniff-created.json"
gen "$tmpdir/sniff-created.json"
jq -e '[.inbounds[] | select(.tag | startswith("xraywrt-tproxy") or . == "xraywrt-fakeip-direct")] | (map(.tag) | sort) == ["xraywrt-fakeip-direct", "xraywrt-tproxy4", "xraywrt-tproxy6"] and all(.sniffing.routeOnly == true)' <<<"$out" >/dev/null || fail 'app-created FakeDNS sniffing is route-only'
jq -e '.routing.domainStrategy == "IPIfNonMatch"' <<<"$out" >/dev/null || fail 'routing domainStrategy remains provider-owned'
for value in true false absent; do
 jq --arg v "$value" '.inbounds = [{protocol:"socks", sniffing: ({enabled:true,destOverride:["tls"]} + if $v == "absent" then {} else {routeOnly: ($v == "true")} end)}]' "$tmpdir/sniff-created.json" >"$tmpdir/sniff-inherited.json"
 gen "$tmpdir/sniff-inherited.json"
 jq -e --arg v "$value" '[.inbounds[] | select(.tag == "xraywrt-tproxy4") | .sniffing] | length == 1 and (.[0] | type == "object" and (if $v == "absent" then (has("routeOnly") | not) else .routeOnly == ($v == "true") end))' <<<"$out" >/dev/null || fail "inherited routeOnly $value preserved"
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
prof_has 'warn no proxy DNS configured, using WAN DNS directly'
assert_eq '["127.0.0.1","192.0.2.53"]' "$(bootrule)" 'proxy-first: WAN DNS go direct'
gen "$FX/src/single.json" '.mode_override = true | .mode = "direct-first" | .wan_dns = ["192.0.2.53", "2001:db8::53"]'
assert_eq "[\"192.0.2.53\",\"2001:db8::53\"]" "$(jq -c .dns.servers <<<"$out")" 'all WAN DNS'
assert_eq '["127.0.0.1","192.0.2.53","2001:db8::53"]' "$(bootrule)" 'direct-first: WAN DNS go direct'
prof_has 'uses-wan-dns'
prof_lacks 'warn no proxy DNS configured, using WAN DNS directly'
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
	jq -e '[.routing.rules[] | select(.outboundTag == "block")] | length == 1' <<<"$out" >/dev/null || fail "$mode: fake range rule"
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
for mode in proxy-first direct-first; do
 gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\""
 assert_eq '[{"action":"resolve"}]' "$(dnsob | jq -c .settings.rules)" "$mode default resolves other types"
 assert_eq '{"allowedNetwork":"tcp,udp"}' "$(dnsin)" 'no raw rewrite'
 gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\" | .dns_forward_other_types = 0"
 assert_eq "[$aaaa]" "$(dnsob | jq -c .settings.rules)" "$mode forwarding off"
 gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\" | .block_https_svcb = 1"
 assert_eq '[{"qType":"65,64","action":"return"},{"action":"resolve"}]' "$(dnsob | jq -c .settings.rules)" "$mode HTTPS block"
done
jq '.xraywrt = {"dns-forward-other-types": false, "block-https-svcb": true}' "$FX/src/single.json" >"$tmpdir/provider.json"
gen "$tmpdir/provider.json"
assert_eq "[$aaaa]" "$(dnsob | jq -c '.settings.rules')" 'provider disables forwarding'
gen "$tmpdir/provider.json" '.dns_forward_override = true | .dns_forward_other_types = 1'
assert_eq '[{"qType":"65,64","action":"return"},{"action":"resolve"}]' "$(dnsob | jq -c .settings.rules)" 'user enables forwarding; provider blocks HTTPS'
gen "$tmpdir/provider.json" '.dns_forward_override = true | .dns_forward_other_types = 1 | .block_https_svcb_override = true | .block_https_svcb = 0'
assert_eq '[{"action":"resolve"}]' "$(dnsob | jq -c .settings.rules)" 'user allows HTTPS'
for fallback in true false; do
 jq --argjson fallback "$fallback" '.dns.disableFallbackIfMatch = $fallback' "$tmpdir/fake.json" >"$tmpdir/fake-fallback.json"
 gen "$tmpdir/fake-fallback.json"
 assert_eq "$fallback" "$(jq -r .dns.disableFallbackIfMatch <<<"$out")" 'provider FakeDNS fallback policy preserved'
 assert_eq '[{"action":"resolve"}]' "$(dnsob | jq -c .settings.rules)" 'FakeDNS server selection is owned by the core'
done
gen "$FX/src/single.json" '.dns_raw_via = "missing" | .dns_raw_upstream = "bad"'
assert_eq '{"action":"resolve"}' "$(dnsob | jq -c '.settings.rules[-1]')" 'legacy raw settings ignored'
pass 'DNS resolve rules and provider overrides'

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
# The injected WAN resolver must precede a provider's generic port 53 rule.
for mode in proxy-first direct-first; do
 src_json '{"outbounds":[{"tag":"proxy","protocol":"freedom"},{"tag":"dns-out","protocol":"dns"}],"routing":{"rules":[{"port":53,"network":"tcp,udp","outboundTag":"dns-out"}]},"dns":{"servers":["fakedns"],"disableCache":true}}'
 gen "$tmpdir/src.json" '.mode_override = true | .mode = "'"$mode"'" | .wan_dns = ["192.0.2.53","2001:db8::53"]'
 assert_eq 0 "$rc" "WAN fallback $mode: $errtxt"
 jq -e '.dns.servers == [{address:"fakedns",queryStrategy:"UseIPv4"},"192.0.2.53","2001:db8::53"] and .dns.disableCache == true and .routing.rules[1] == {inboundTag:["xraywrt-dns-internal"],ip:["127.0.0.1","192.0.2.53","2001:db8::53"],port:53,outboundTag:"xraywrt-direct"} and .routing.rules[-1] == {port:53,network:"tcp,udp",outboundTag:"dns-out"}' <<<"$out" >/dev/null || fail "WAN fallback precedes provider DNS: $mode"
 jq '.dns.servers = ["192.0.2.54"]' "$tmpdir/src.json" > "$tmpdir/control.json"
 gen "$tmpdir/control.json" '.mode_override = true | .mode = "'"$mode"'"'
 jq -e '.dns.servers == ["192.0.2.54"] and .routing.rules[1].ip == ["127.0.0.1"] and .routing.rules[-1].outboundTag == "dns-out"' <<<"$out" >/dev/null || fail "provider DNS remains routed by provider: $mode"
done
pass 'WAN fallback and provider DNS port 53 precedence'
