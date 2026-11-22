#!/usr/bin/env bash
# xray-config.uc via `xraywrt-json gen`: source formats, profile selection,
# section ownership, provider keys, marks, inbounds, rules, server hosts,
# geodata and determinism (spec 5, 6, 10).

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"

# A unique case-insensitive BLOCK blackhole is reused for the stale FakeIP guard.
for tag in block BLOCK Block; do
 src_json "{\"outbounds\":[{\"tag\":\"proxy\",\"protocol\":\"vless\"},{\"tag\":\"$tag\",\"protocol\":\"blackhole\"}],\"dns\":{\"servers\":[{\"address\":\"fakedns\",\"domains\":[\"domain:a.test\"]}]}}"
 gen "$tmpdir/src.json"
 assert_eq 0 "$rc" "provider BLOCK generation: $errtxt"
 assert_eq "$tag" "$(jq -r '.routing.rules[2].outboundTag' <<<"$out")" 'FakeIP guard uses exact provider BLOCK tag'
 assert_eq 0 "$(jq '[.outbounds[] | select(.tag == "xraywrt-block")] | length' <<<"$out")" 'no redundant block outbound'
done
src_json '{"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"Block","protocol":"blackhole"}],"dns":{"servers":[{"address":"fakedns","domains":["domain:a.test"]}]},"routing":{"rules":[{"domain":["full:blocked.test"],"outboundTag":"xraywrt-block"}]}}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "provider legacy block reference generation: $errtxt"
assert_eq Block "$(jq -r '.routing.rules[2].outboundTag' <<<"$out")" 'guard uses provider block despite legacy reference'
jq -e '[.outbounds[] | select(.tag == "xraywrt-block" and .protocol == "blackhole")] | length == 1' <<<"$out" >/dev/null || fail 'legacy block reference retains blackhole'
for reference in '"routing":{"balancers":[{"tag":"pool","selector":["xraywrt-block"]}]}' '"routing":{"balancers":[{"tag":"pool","fallbackTag":"xraywrt-block"}]}' '"outbounds":[{"tag":"proxy","protocol":"vless","proxySettings":{"tag":"xraywrt-block"}},{"tag":"Block","protocol":"blackhole"}]' '"outbounds":[{"tag":"proxy","protocol":"vless","streamSettings":{"sockopt":{"dialerProxy":"xraywrt-block"}}},{"tag":"Block","protocol":"blackhole"}]'; do
 jq -n --argjson reference "{$reference}" '{outbounds:[{tag:"proxy",protocol:"vless"},{tag:"Block",protocol:"blackhole"}]} + $reference' >"$tmpdir/src.json"
 gen "$tmpdir/src.json"
 assert_eq 0 "$rc" "legacy reference generation: $errtxt"
 jq -e '[.outbounds[] | select(.tag == "xraywrt-block" and .protocol == "blackhole")] | length == 1' <<<"$out" >/dev/null || fail "legacy reference retains blackhole: $reference"
done
# Selectors match tag prefixes; tag references require exact equality.
for reference in '"routing":{"balancers":[{"tag":"pool","selector":["xraywrt-b"]}]}' '"observatory":{"subjectSelector":["xraywrt-b"]}' '"burstObservatory":{"subjectSelector":["xraywrt-b"]}'; do
 jq -n --argjson reference "{$reference}" '{outbounds:[{tag:"proxy",protocol:"vless"},{tag:"BlOcK",protocol:"blackhole"}]} + $reference' >"$tmpdir/src.json"
 gen "$tmpdir/src.json"
 assert_eq 0 "$rc" "prefix selector generation: $errtxt"
 jq -e '[.outbounds[] | select(.tag == "xraywrt-block" and .protocol == "blackhole")] | length == 1' <<<"$out" >/dev/null || fail "prefix selector retains legacy block: $reference"
done
for reference in '"routing":{"balancers":[{"tag":"pool","selector":["xraywrt-block-extra"]}]}' '"observatory":{"subjectSelector":["xraywrt-block-extra"]}' '"burstObservatory":{"subjectSelector":["xraywrt-block-extra"]}' '"routing":{"rules":[{"outboundTag":"xraywrt-b"}]}' '"routing":{"balancers":[{"tag":"pool","fallbackTag":"xraywrt-b"}]}' '"outbounds":[{"tag":"proxy","protocol":"vless","proxySettings":{"tag":"xraywrt-b"}},{"tag":"BlOcK","protocol":"blackhole"}]' '"outbounds":[{"tag":"proxy","protocol":"vless","streamSettings":{"sockopt":{"dialerProxy":"xraywrt-b"}}},{"tag":"BlOcK","protocol":"blackhole"}]'; do
 jq -n --argjson reference "{$reference}" '{outbounds:[{tag:"proxy",protocol:"vless"},{tag:"BlOcK",protocol:"blackhole"}]} + $reference' >"$tmpdir/src.json"
 gen "$tmpdir/src.json"
 assert_eq 0 "$rc" "nonmatching reference generation: $errtxt"
 assert_eq 0 "$(jq '[.outbounds[] | select(.tag == "xraywrt-block")] | length' <<<"$out")" "nonmatching reference does not retain legacy block: $reference"
done
for outbounds in '[{"tag":"block","protocol":"freedom"}]' '[{"tag":"BLOCK","protocol":"blackhole"},{"tag":"block","protocol":"blackhole"}]'; do
 src_json "{\"outbounds\":$outbounds,\"dns\":{\"servers\":[{\"address\":\"fakedns\",\"domains\":[\"domain:a.test\"]}]}}"
 gen "$tmpdir/src.json"
 assert_eq 0 "$rc" "incompatible BLOCK generation: $errtxt"
 assert_eq xraywrt-block "$(jq -r '.routing.rules[2].outboundTag' <<<"$out")" 'incompatible BLOCK falls back'
done
pass 'provider BLOCK reuse'

# UX 4.1a: default to proxy-first unless the provider or user specifies a mode.
mode_case() {
 src_json "$1"
 gen "$tmpdir/src.json" "${4:-.mode_override = false | .mode = \"direct-first\"}"
 assert_eq 0 "$rc" "mode generation: $errtxt"
 prof_has "mode $2"
 prof_has "mode-source $3"
}
mode_case '{"outbounds":[{"protocol":"vless","tag":"proxy"}]}' proxy-first auto
mode_case '{"outbounds":[{"protocol":"freedom","tag":"direct"}],"dns":{"servers":[{"address":"fakedns","domains":["domain:a.test"]}]}}' proxy-first auto
mode_case '{"outbounds":[{"protocol":"freedom","tag":"direct"}]}' proxy-first auto
for condition in '"network":"tcp,udp"' '"ip":["0.0.0.0/0","::/0"]' '"port":"0-65535"' '"port":"1-65535"' '"type":"field"'; do
 mode_case '{"outbounds":[{"protocol":"vless","tag":"proxy"},{"protocol":"freedom","tag":"direct"}],"xraywrt":{"proxy-ips":[]},"routing":{"rules":[{"domain":["a.test"],"outboundTag":"proxy"},{'"$condition"',"outboundTag":"direct"}]}}' proxy-first auto
done
for condition in '"inboundTag":["x"]' '"source":["10.0.0.0/8"]' '"user":["x"]' '"network":"tcp"' '"ip":["0.0.0.0/0"]' '"network":"tcp,udp","port":"0-65535"'; do
 mode_case '{"outbounds":[{"protocol":"vless","tag":"proxy"},{"protocol":"freedom","tag":"direct"}],"xraywrt":{"proxy-ips":[]},"routing":{"rules":[{'"$condition"',"outboundTag":"direct"}]}}' proxy-first auto
done
mode_case '{"outbounds":[{"protocol":"freedom","tag":"direct"}],"xraywrt":{"proxy-ips":[]},"routing":{"rules":[{"balancerTag":"pool"}]}}' proxy-first auto
mode_case '{"outbounds":[{"protocol":"freedom","streamSettings":{"sockopt":{"dialerProxy":"proxy"}}}],"xraywrt":{"proxy-ips":[]}}' proxy-first auto
mode_case '{"outbounds":[{"protocol":"freedom"}],"xraywrt":{"mode":"direct-first"}}' direct-first provider
mode_case '{"outbounds":[{"protocol":"freedom"}],"xraywrt":{"mode":"direct-first"}}' proxy-first user '.mode_override = true | .mode = "proxy-first"'
pass 'provider mode defaults'

# UX 4.2: own direct sites require provider HTTP/TLS/QUIC sniffing in proxy-first.
printf 'example.com direct\nexample.com direct # duplicate\nvpn.test core\n' >"$tmpdir/rules.txt"
rules_filter() { printf '.rules_file = "%s"' "$tmpdir/rules.txt"; }
direct_rules() { jq -c '[.routing.rules[] | select(.domain != null and .outboundTag == "xraywrt-direct")]' <<<"$out"; }
for mode in proxy-first direct-first; do
 gen "$FX/src/sniff-tproxy.json" '.mode_override = true | .mode = "'"$mode"'" | '"$(rules_filter)"
 assert_eq 0 "$rc" "direct sites generation: $errtxt"
 prof_has 'direct-domains 1'
 jq -e '.routing.rules[4] == {domain:["domain:example.com"],inboundTag:["xraywrt-tproxy4","xraywrt-tproxy6"],outboundTag:"direct",ruleTag:"xraywrt-rule-1"} and .routing.rules[5] == {domain:["domain:example.com"],outboundTag:"xraywrt-direct",ruleTag:"xraywrt-rule-1-service"}' <<<"$out" >/dev/null || fail 'direct site rule before provider rules'
 if [ "$mode" = direct-first ]; then
  jq -e '.dns.servers[0] == {address:"192.0.2.53",domains:["domain:example.com"],skipFallback:true,finalQuery:true}' <<<"$out" >/dev/null || fail 'real DNS precedes fakedns'
 else
  jq -e '.dns.servers | all(.[]; type != "object" or .address == "fakedns")' <<<"$out" >/dev/null || fail 'proxy-first leaves DNS unchanged'
 fi
 XRAY_LOCATION_ASSET=/usr/local/share/xray-test xray-test run -test -c "$tmpdir/out.json" >"$tmpdir/direct-core.log" 2>&1 || fail "direct sites core test: $(cat "$tmpdir/direct-core.log")"
done
jq '.dns.servers = [{address:"192.0.2.54",port:5353,domains:["domain:provider.test"],queryStrategy:"UseIPv4",skipFallback:false}]' "$FX/src/sniff-tproxy.json" >"$tmpdir/direct-dns.json"
gen "$tmpdir/direct-dns.json" '.mode_override = true | .mode = "direct-first" | '"$(rules_filter)"
assert_eq 0 "$rc" "direct DNS object generation: $errtxt"
jq -e '.dns.servers[0] == {address:"192.0.2.54",port:5353,domains:["domain:example.com"],queryStrategy:"UseIPv4",skipFallback:true,finalQuery:true}' <<<"$out" >/dev/null || fail 'direct DNS keeps resolver policy and replaces its domains'
jq '.dns.servers = [{address:"192.0.2.54",domains:["domain:provider.test"]},"192.0.2.55"]' "$FX/src/sniff-tproxy.json" >"$tmpdir/direct-dns.json"
gen "$tmpdir/direct-dns.json" '.mode_override = true | .mode = "direct-first" | '"$(rules_filter)"
jq -e '.dns.servers[0] == {address:"192.0.2.55",domains:["domain:example.com"],skipFallback:true,finalQuery:true}' <<<"$out" >/dev/null || fail 'direct DNS prefers a server without its own domains'
cp "$tmpdir/rules.txt" "$tmpdir/rules-before.txt"
for fixture in sniff-none sniff-disabled; do
 gen "$FX/src/$fixture.json" '.mode_override = true | .mode = "proxy-first" | '"$(rules_filter)"
 prof_has 'warn direct domains ignored: the provider config has no sniffing'
 prof_has 'direct-domains 0'
 assert_eq '[]' "$(direct_rules)" 'no direct rule without sniffing'
 cmp -s "$tmpdir/rules.txt" "$tmpdir/rules-before.txt" || fail 'ignored list preserved'
done
# Direct-first answers these names with real addresses: no recognition needed.
for fixture in sniff-none sniff-disabled; do
 gen "$FX/src/$fixture.json" '.mode_override = true | .mode = "direct-first" | '"$(rules_filter)"
 assert_eq 0 "$rc" "direct-first without sniffing: $errtxt"
 prof_lacks 'warn direct domains ignored: the provider config has no sniffing'
 prof_has 'direct-domains 1'
 jq -e '[.routing.rules[] | select(.domain != null and .outboundTag == "xraywrt-direct")] | length == 1' <<<"$out" >/dev/null || fail 'direct-first keeps the direct rule without sniffing'
 jq -e '.dns.servers[0].domains == ["domain:example.com"]' <<<"$out" >/dev/null || fail 'direct-first real DNS for direct sites without sniffing'
done
: >"$tmpdir/rules.txt"
gen "$FX/src/sniff-tproxy.json" "$(rules_filter)"
prof_lacks 'warn direct domains ignored: the provider config has no sniffing'
prof_has 'direct-domains 0'
assert_eq '[]' "$(direct_rules)" 'empty list has no rule'
awk 'BEGIN { for(i=0;i<10001;i++) print "host" i ".test direct" }' >"$tmpdir/rules.txt"
gen "$FX/src/sniff-tproxy.json" "$(rules_filter)"
prof_has 'direct-domains 10000'
prof_has 'warn My rules has more than 10000 sites, the rest is ignored'
pass 'own direct sites'

# A5.1 source formats (spec 5.1).
share='config: share links are not supported, use the Xray JSON subscription URL'
gen_fails "$FX/src/bad-share.txt" "$share"
gen_fails "$FX/src/bad-base64.txt" "$share"
gen_fails "$FX/src/bad-yaml.txt" 'config: Clash/Mihomo YAML is not supported'
gen_fails "$FX/src/bad-notjson.txt" 'config: not JSON'
gen_fails "$FX/src/bad-nooutbounds.txt" 'config: no outbounds'
gen_fails "$FX/src/bad-emptyoutbounds.txt" 'config: no outbounds'
src_json '"text"'
gen_fails "$tmpdir/src.json" 'config: no outbounds'
src_json '[]'
gen_fails "$tmpdir/src.json" 'config: no outbounds'
: >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: not JSON'
head -c 8388609 /dev/zero | tr '\0' ' ' >"$tmpdir/big.json"
gen_fails "$tmpdir/big.json" 'config: larger than 8 MiB'
printf '\357\273\277' | cat - "$FX/src/single.json" >"$tmpdir/bom.json"
gen "$tmpdir/bom.json"
assert_eq 0 "$rc" "BOM JSON: $errtxt"
gen "$FX/src/single.json"
assert_eq 0 "$rc" "single.json: $errtxt"
jq -e '.outbounds[0].tag == "proxy"' <<<"$out" >/dev/null || fail "runtime config: $out"
pass 'source formats'

# A5.2 profile selection (spec 5.1, 5.3).
arr="$FX/src/remnawave-array.json"
gen "$arr"
assert_eq 0 "$rc" "array: $errtxt"
jq -e '.outbounds[0].settings.vnext[0].address == "nl1.example.com"' <<<"$out" >/dev/null || fail 'empty profile: first element'
prof_has 'profile NL Amsterdam'
gen "$arr" '.profile = "DE Frankfurt"'
jq -e '.outbounds[0].settings.vnext[0].address == "de1.example.com"' <<<"$out" >/dev/null || fail 'profile by remarks'
prof_has 'profile DE Frankfurt'
prof_lacks 'profile NL Amsterdam'
gen "$arr" '.profile = "XX"'
assert_eq 0 "$rc" 'unknown profile still generates'
jq -e '.outbounds[0].settings.vnext[0].address == "nl1.example.com"' <<<"$out" >/dev/null || fail 'unknown profile: first element'
prof_has 'warn profile "XX" not found, using "NL Amsterdam"'
prof_has 'profile NL Amsterdam'
gen "$FX/src/single.json" '.profile = "Other"'
prof_has 'profile Node'
! grep -q '^warn profile' <<<"$prof" || fail 'object source: no profile warning'
src_json '[{"remarks": "a", "outbounds": [{"protocol": "freedom"}]}, {"remarks": "b"}]'
gen_fails "$tmpdir/src.json" 'config: no outbounds' '.profile = "b"'
src_json '[{"outbounds": [{"protocol": "freedom"}]}]'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "no remarks: $errtxt"
! grep -q '^profile ' <<<"$prof" || fail 'no remarks: no profile line'
# Provider-pinned profile: xraywrt.router-profile names the remarks to use. The
# provider repeats the key in every element, so the first non-empty string counts.
pin='"xraywrt":{"router-profile":"b"}'
src_json '[{"remarks":"a",'"$pin"',"outbounds":[{"protocol":"freedom","tag":"a"}]},{"remarks":"b",'"$pin"',"outbounds":[{"protocol":"freedom","tag":"b"}]},{"remarks":"c",'"$pin"',"outbounds":[{"protocol":"freedom","tag":"c"}]}]'
gen "$tmpdir/src.json" '.profile = "a"'
assert_eq 0 "$rc" "pinned profile: $errtxt"
jq -e '.outbounds[0].tag == "b"' <<<"$out" >/dev/null || fail 'the named profile beats the saved profile'
prof_has 'profile b'
prof_has 'profile-pinned 1'
! grep -q '^warn.*profile' <<<"$prof" || fail "pinned profile: no profile warning: $prof"
gen "$tmpdir/src.json" '.profile = "XX"'
! grep -q '^warn.*profile' <<<"$prof" || fail 'pinned profile: unknown saved profile is not a warning'
! grep -q '^ignored router-profile' <<<"$prof" || fail 'router-profile is accepted silently'
for value in '"nope"' 'true' '""' '7' 'null'; do
 src_json '[{"remarks":"a","xraywrt":{"router-profile":'"$value"'},"outbounds":[{"protocol":"freedom","tag":"a"}]},{"remarks":"b","outbounds":[{"protocol":"freedom","tag":"b"}]}]'
 gen "$tmpdir/src.json" '.profile = "b"'
 jq -e '.outbounds[0].tag == "b"' <<<"$out" >/dev/null || fail "router-profile $value does not pin"
 prof_lacks 'profile-pinned 1'
 ! grep -q '^ignored router-profile' <<<"$prof" || fail "router-profile $value is accepted silently"
done
src_json '[{"remarks":"a","xraywrt":{"router-profile":"nope"},"outbounds":[{"protocol":"freedom","tag":"a"}]}]'
gen "$tmpdir/src.json"
prof_has 'warn router-profile "nope" not found'
src_json '{"remarks":"a","xraywrt":{"router-profile":"x"},"outbounds":[{"protocol":"freedom","tag":"a"}]}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "object source: $errtxt"
prof_lacks 'profile-pinned 1'
! grep -q '^warn.*profile\|^ignored' <<<"$prof" || fail "object source ignores router-profile silently: $prof"
pass 'profile selection'

# A5.3 section ownership (spec 6.2).
gen "$FX/src/full.json"
assert_eq 0 "$rc" "full.json: $errtxt"
for k in geodata observatory burstObservatory policy transport vendorExtension routing.balancers routing.domainStrategy; do
	assert_eq "$(jq -S ".$k" "$FX/src/full.json")" "$(jq -S ".$k" <<<"$out")" "provider section $k kept"
done
jq -e '(has("remarks") or has("xraywrt") or has("stats") or has("metrics")) | not' <<<"$out" >/dev/null ||
	fail "router-removed sections: $out"
jq -e '.log == {loglevel: "debug", access: "none", dnsLog: false}' <<<"$out" >/dev/null || fail "log: $(jq -c .log <<<"$out")"
gen "$FX/src/full.json" '.log_level = "error" | .log_level_override = true'
jq -e '.log.loglevel == "error"' <<<"$out" >/dev/null || fail 'log level from params'
assert_eq "$(jq -c .inbounds "$FX/src/full.json")" "$(jq -c '.inbounds[:2]' <<<"$out")" 'provider inbounds kept as is, router inbounds follow'
! grep -q 'inbound' <<<"$prof" || fail "provider inbounds: no warning: $prof"
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"tag":"xraywrt-lan","port":1080,"protocol":"socks"}]}'
gen_fails "$tmpdir/src.json" 'config: tag "xraywrt-lan" uses reserved prefix xraywrt-'
for p in 7894 '"7895"' '"1000-7874"' '"80,10085"'; do
	src_json "{\"outbounds\":[{\"protocol\":\"freedom\"}],\"inbounds\":[{\"port\":$p,\"protocol\":\"socks\"}]}"
	gen_fails "$tmpdir/src.json" "config: inbound #1 port $(tr -d '"' <<<"$p") collides with a router port"
done
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"port":"7000-7873","protocol":"socks"},{"listen":"/run/x.sock","protocol":"socks"}]}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "inbound ports next to router ports: $errtxt"
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":"x"}'
gen_fails "$tmpdir/src.json" 'config: inbounds is not an array'
gen "$FX/src/full.json" '.log_level = "error" | .log_level_override = true'
jq -e '.fakedns != [{ipPool: "100.64.0.0/10", poolSize: 1000}]' <<<"$out" >/dev/null || fail 'provider fakedns kept'
prof_has 'warn fakedns section replaced'
gen "$FX/src/single.json"
! grep -v 'no proxy DNS' <<<"$prof" | grep -q '^warn' || fail "single.json: no warnings: $prof"
pass 'section ownership'

# UX 4.1b: client tun listeners are replaced by the router's TPROXY listeners.
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"tag":"tun-in","protocol":"tun","port":7894},{"tag":"socks-in","protocol":"socks","port":1080},{"protocol":"tun"}]}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "tun removal: $errtxt"
jq -e '[.inbounds[] | select(.protocol == "tun" or .tag == "tun-in")] == []' <<<"$out" >/dev/null || fail 'tun listeners removed'
assert_eq "$(jq -S '.inbounds[1]' "$tmpdir/src.json")" "$(jq -S '.inbounds[0]' <<<"$out")" 'socks listener kept unchanged'
prof_has 'warn inbound tun-in (tun) removed: the router uses TPROXY'
prof_has 'warn inbound #3 (tun) removed: the router uses TPROXY'
pass 'provider tun inbounds removed'

# A subscription must not open ports on the network or make the core write files
# as root; a hand-written config keeps what it says.
src_json '{"outbounds":[{"protocol":"freedom","streamSettings":{"security":"tls","tlsSettings":{"masterKeyLog":"/etc/config/network","serverName":"a.test"}}}],"inbounds":[{"tag":"open","protocol":"http","port":10809},{"tag":"lan","protocol":"socks","listen":"0.0.0.0","port":1080},{"tag":"v6","protocol":"socks","listen":"::","port":1081},{"tag":"lo","protocol":"socks","listen":"127.0.0.1","port":1082},{"tag":"lo6","protocol":"socks","listen":"::1","port":1083},{"tag":"sock","protocol":"socks","listen":"/run/x.sock"},{"tag":"abs","protocol":"socks","listen":"@x"},{"tag":"log","protocol":"socks","listen":"127.0.0.1","port":1084,"streamSettings":{"security":"tls","tlsSettings":{"masterKeyLog":"/tmp/k"}}}]}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "hand-written inbounds: $errtxt"
assert_eq "$(jq -S '.inbounds' "$tmpdir/src.json")" "$(jq -S '.inbounds[0:8]' <<<"$out")" 'hand-written inbounds unchanged'
assert_eq '"/etc/config/network"' "$(jq -c '.outbounds[0].streamSettings.tlsSettings.masterKeyLog' <<<"$out")" 'hand-written masterKeyLog kept'
gen "$tmpdir/src.json" '.from_subscription = true'
assert_eq 0 "$rc" "subscription inbounds: $errtxt"
assert_eq '["open:127.0.0.1","lan:127.0.0.1","v6:127.0.0.1","lo:127.0.0.1","lo6:::1","log:127.0.0.1"]' "$(jq -c '[.inbounds[0:6][] | .tag + ":" + .listen]' <<<"$out")" 'subscription inbounds listen on loopback only; unix sockets removed'
assert_eq 'null' "$(jq -c '[.. | .masterKeyLog? // empty] | first' <<<"$out")" 'masterKeyLog removed everywhere'
assert_eq 'a.test' "$(jq -r '.outbounds[0].streamSettings.tlsSettings.serverName' <<<"$out")" 'tls settings otherwise kept'
prof_has 'warn inbound open listens on 127.0.0.1 only: a subscription must not open ports on the network'
prof_has 'warn inbound sock removed: a subscription must not listen on a file'
prof_has 'warn inbound abs removed: a subscription must not listen on a file'
prof_has 'warn masterKeyLog removed: a subscription must not make Xray write files'
prof_lacks 'warn inbound lo listens on 127.0.0.1 only: a subscription must not open ports on the network'
prof_lacks 'warn inbound lo6 listens on 127.0.0.1 only: a subscription must not open ports on the network'
pass 'subscription inbounds and file keys are limited'

# 0.0.0.0 and :: on one port both become 127.0.0.1: the second would fail to bind.
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"tag":"a","protocol":"socks","listen":"0.0.0.0","port":1080},{"tag":"b","protocol":"socks","listen":"::","port":1080},{"tag":"c","protocol":"socks","port":1081},{"tag":"s","protocol":"socks","listen":"::","port":"1080"},{"tag":"t","protocol":"dokodemo-door","port":1082,"settings":{"network":"tcp"}},{"tag":"u","protocol":"dokodemo-door","port":1082,"settings":{"network":"udp"}},{"tag":"l","protocol":"socks","listen":"127.0.0.1","port":1083},{"tag":"l6","protocol":"socks","listen":"::1","port":1083}]}'
gen "$tmpdir/src.json" '.from_subscription = true'
assert_eq 0 "$rc" "duplicate inbounds: $errtxt"
assert_eq '["a","c","t","u","l","l6"]' "$(jq -c '[.inbounds[0:6][] | .tag]' <<<"$out")" 'second inbound on the same loopback port removed (also a text port); tcp/udp and 127.0.0.1/::1 pairs stay'
prof_has 'warn inbound b removed: its address and port are already used by another inbound'
pass 'forced loopback does not collide'

# UX 4.1: provider sniffing is copied whole; only fake-IP augments runtime.
sniff_warn='warn the provider config has no sniffing: domain rules see only IP addresses'
for fixture in sniff-tproxy sniff-disabled; do
	gen "$FX/src/$fixture.json"
	assert_eq 0 "$rc" "$fixture: $errtxt"
	assert_eq "$(jq -S '.inbounds[0].sniffing' "$FX/src/$fixture.json")" "$(jq -S '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing' <<<"$out")" "$fixture sniffing copied whole"
	assert_eq "$(jq -S '.inbounds[0]' "$FX/src/$fixture.json")" "$(jq -S '.inbounds[0]' <<<"$out")" 'provider inbound unchanged'
done
prof_has 'sniff 0'
prof_has "$sniff_warn"
gen "$FX/src/sniff-tproxy.json"
prof_has 'sniff tls'
prof_lacks "$sniff_warn"
printf 'example.com core\n' >"$tmpdir/sniff-fake.txt"
gen "$FX/src/sniff-tproxy.json" '.rules_file = "'"$tmpdir/sniff-fake.txt"'"'
prof_has 'sniff tls'
assert_eq "$(jq -S '.inbounds[0].sniffing | .destOverride = ["fakedns", "tls"]' "$FX/src/sniff-tproxy.json")" "$(jq -S '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing' <<<"$out")" 'fake-IP only prepends fakedns'
assert_eq "$(jq -S '.inbounds[0]' "$FX/src/sniff-tproxy.json")" "$(jq -S '.inbounds[0]' <<<"$out")" 'fake-IP does not mutate provider inbound'
for fake in false true; do
	filter='.'
	[ "$fake" = false ] || filter='.rules_file = "'"$tmpdir/sniff-fake.txt"'"'
	gen "$FX/src/sniff-none.json" "$filter"
	prof_has 'sniff 0'
	prof_has "$sniff_warn"
	if [ "$fake" = false ]; then
		jq -e '[.inbounds[] | select(.tag == "xraywrt-tproxy4" or .tag == "xraywrt-tproxy6") | has("sniffing") | not] | all' <<<"$out" >/dev/null || fail 'no provider sniffing: no runtime key'
		XRAY_LOCATION_ASSET=/usr/local/share/xray-test xray-test run -test -c "$tmpdir/out.json" >"$tmpdir/sniff-core.log" 2>&1 ||
			fail "no sniffing/no fake-IP core test: $(cat "$tmpdir/sniff-core.log")"
	else
		jq -e '[.inbounds[] | select(.tag == "xraywrt-tproxy4" or .tag == "xraywrt-tproxy6") | .sniffing == {enabled:true,destOverride:["fakedns"],routeOnly:true}] | all' <<<"$out" >/dev/null || fail 'fake-IP synthesizes only fakedns sniffing'
	fi
done
jq '.inbounds = [.inbounds[1]]' "$FX/src/sniff-tproxy.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
prof_has 'sniff http'
assert_eq "$(jq -S '.inbounds[0].sniffing' "$tmpdir/src.json")" "$(jq -S '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing' <<<"$out")" 'socks sniffing fallback'
jq '.inbounds |= reverse | .inbounds[1].protocol = "dokodemo-door" | .inbounds[1].streamSettings.sockopt.tproxy = "redirect"' "$FX/src/sniff-tproxy.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
prof_has 'sniff tls'
assert_eq "$(jq -S '.inbounds[1].sniffing' "$tmpdir/src.json")" "$(jq -S '.inbounds[] | select(.tag == "xraywrt-tproxy6").sniffing' <<<"$out")" 'redirect beats earlier socks'
jq '.inbounds[0].sniffing.destOverride = ["tls", "fakedns"]' "$FX/src/sniff-tproxy.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json" '.rules_file = "'"$tmpdir/sniff-fake.txt"'"'
assert_eq '["tls","fakedns"]' "$(jq -c '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing.destOverride' <<<"$out")" 'existing fakedns is not duplicated or reordered'
gen "$FX/src/sniff-disabled.json" '.rules_file = "'"$tmpdir/sniff-fake.txt"'"'
prof_has 'sniff 0'
assert_eq '{"enabled":true,"destOverride":["fakedns"],"routeOnly":true}' "$(jq -c '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing' <<<"$out")" 'fake-IP replaces disabled sniffing'
# An enabled block anywhere beats a disabled transparent listener.
jq '.inbounds[0].sniffing.enabled = false' "$FX/src/sniff-tproxy.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
prof_has 'sniff http'
assert_eq "$(jq -S '.inbounds[1].sniffing' "$tmpdir/src.json")" "$(jq -S '.inbounds[] | select(.tag == "xraywrt-tproxy4").sniffing' <<<"$out")" 'enabled sniffing beats disabled transparent'
pass 'provider sniffing'

# A5.4 provider key xraywrt (spec 5.2): same keys as x-mihowrt plus mode.
xr() {
	jq --argjson x "$1" '. + {xraywrt: $x}' "$FX/src/single.json" >"$tmpdir/src.json"
	gen "$tmpdir/src.json"
	assert_eq 0 "$rc" "xraywrt $1: $errtxt"
	jq -e 'has("xraywrt") | not' <<<"$out" >/dev/null || fail 'xraywrt key reaches the core'
	actual="$(grep -Ev '^(profile-schema |fake-enabled |profile |server-host |fake-domains |provider-fake-domains |set core_log_level |geodata|uses-wan-dns|warn no proxy DNS|sniff |mode |mode-source |direct-domains |rules-target |rules-reserved )' <<<"$prof" || :)"
}
xr '{"mode": "direct-first", "disable-quic": true, "dns-hijack": false, "bypass-ntp": "yes", "bypass-subscription-dns": 0, "block-client-ipv6": "off", "dns-forward-other-types": true, "lists-interval": 12}'
assert_eq 'set mode direct-first
set disable_quic 1
set dns_hijack 0
set bypass_ntp 1
set bypass_subscription_dns 0
set block_client_ipv6 0
set dns_forward_other_types 1
set lists_interval 12' "$actual" 'provider settings'
xr '{"discord-voice": true}'
assert_eq 'set discord_voice 1' "$actual" 'provider Discord Voice boolean'
xr '{"discord-voice": "maybe"}'
assert_eq 'ignored discord-voice' "$actual" 'invalid Discord Voice boolean'
xr '{"mode": "proxy-first", "lists-interval": "024"}'
assert_eq 'set mode proxy-first
set lists_interval 24' "$actual" 'string interval'
xr '{"proxy-ips": ["https://a.example/ips.txt", " https://b.example/x # note ", "#c", 5], "direct-ips": []}'
assert_eq 'ignored proxy-ips
has direct-ips' "$actual" 'non-string list item ignores the key'
xr '{"proxy-ips": ["https://a.example/ips.txt", " https://b.example/x # note ", "#c", ""], "direct-ips": null}'
assert_eq 'has proxy-ips
proxy-ip https://a.example/ips.txt
proxy-ip https://b.example/x
has direct-ips' "$actual" 'provider lists'
xr '{"mode": "fake-ip", "disable-quic": "maybe", "lists-interval": 8761, "lists-interval2": 1, "proxy-ips": "https://x", "direct-ips": {}, "dns-hijack": null, "bypass-ntp": 2}'
assert_eq 'ignored mode
ignored disable-quic
ignored lists-interval
ignored lists-interval2
ignored proxy-ips
ignored direct-ips
ignored dns-hijack
ignored bypass-ntp' "$actual" 'invalid values'
xr '"direct-first"'
assert_eq 'ignored xraywrt' "$actual" 'non-object key'
xr '{"lists-interval": 1.5}'
assert_eq 'ignored lists-interval' "$actual" 'fractional interval'
# One decimal elsewhere must not turn integers into decimal wrappers.
xr '{"lists-interval": 12, "frac": 1.5}'
assert_eq 'set lists_interval 12
ignored frac' "$actual" 'integer next to a decimal'
gen "$FX/src/single.json" '.extra = 1.5'
assert_eq '[{"qType":"1,28","action":"hijack"},{"action":"return"}]' "$(jq -c '.outbounds[] | select(.tag == "xraywrt-dns") | .settings.rules' <<<"$out")" 'integer params stay integers next to a decimal'
jq --argjson x '{"mode": "direct-first"}' '.[1].xraywrt = $x' "$FX/src/remnawave-array.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json" '.profile = "DE Frankfurt"'
prof_has 'set mode direct-first'
prof_has 'mode direct-first'
gen "$tmpdir/src.json" '.profile = "DE Frankfurt" | .mode_override = true'
prof_has 'mode proxy-first'
gen "$tmpdir/src.json"
prof_lacks 'set mode direct-first'
prof_has 'mode proxy-first'
pass 'provider key xraywrt'

# A5.5 marks and service outbounds (spec 6.2, 6.4).
jq '.outbounds += [
	{"tag": "chain", "protocol": "vless", "settings": {}, "streamSettings": {"network": "ws", "sockopt": {"mark": 255, "dialerProxy": "proxy"}}},
	{"protocol": "freedom", "streamSettings": {"sockopt": {"mark": 2, "tcpFastOpen": true}}},
	{"tag": "nostream", "protocol": "socks", "streamSettings": null}
]' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "marks: $errtxt"
assert_eq 'proxy direct block chain - nostream xraywrt-direct xraywrt-dns' \
	"$(jq -r '[.outbounds[] | .tag // "-"] | join(" ")' <<<"$out")" 'outbound order'
jq -e '[.outbounds[] | select(.protocol != "blackhole") | .streamSettings.sockopt.mark == 2] | all' <<<"$out" >/dev/null ||
	fail "every outbound gets mark 2: $(jq -c '[.outbounds[].streamSettings]' <<<"$out")"
jq -e '.outbounds[0].streamSettings | .network == "tcp" and .security == "reality" and .realitySettings.shortId == "6ba85179e30d4fc2"' <<<"$out" >/dev/null ||
	fail 'existing streamSettings kept'
jq -e '.outbounds[3].streamSettings == {network: "ws", sockopt: {mark: 2, dialerProxy: "proxy"}}' <<<"$out" >/dev/null || fail 'chain sockopt kept'
jq -e '.outbounds[4].streamSettings.sockopt.tcpFastOpen == true' <<<"$out" >/dev/null || fail 'sockopt keys kept'
prof_has 'warn outbound "chain" mark 255 replaced with 2'
assert_eq 1 "$(grep -c '^warn outbound' <<<"$prof")" 'one mark warning'
jq -e '.outbounds[-2:] | (.[0] | del(.settings)) == {tag: "xraywrt-direct", protocol: "freedom", streamSettings: {sockopt: {mark: 2, domainStrategy: "ForceIP"}}} and
	.[1].protocol == "dns" and .[1].streamSettings.sockopt.mark == 2' <<<"$out" >/dev/null ||
	fail "service outbounds: $(jq -c '.outbounds[-3:]' <<<"$out")"
# Provider options remain on the provider outbound, not the fallback.
he='{"tryDelayMs":250,"prioritizeIPv6":true}'
jq --argjson he "$he" '.outbounds[1].streamSettings = {sockopt: {happyEyeballs: $he, domainStrategy: "UseIPv4"}}' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq '{"domainStrategy":"ForceIP","mark":2}' \
	"$(jq -c '.outbounds[] | select(.tag == "xraywrt-direct") | .streamSettings.sockopt' <<<"$out")" 'fallback does not copy happyEyeballs'
jq -e --argjson he "$he" '.outbounds[1].streamSettings.sockopt == {happyEyeballs: $he, domainStrategy: "UseIPv4", mark: 2}' <<<"$out" >/dev/null || fail 'provider direct unchanged'
jq --argjson he "$he" '.outbounds[1] |= (.tag = "direct-2" | .streamSettings = {sockopt: {happyEyeballs: $he}}) | .outbounds[2] = {tag: "direct", protocol: "vless", streamSettings: {sockopt: {happyEyeballs: $he}}}' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq '{"domainStrategy":"ForceIP","mark":2}' "$(jq -c '.outbounds[] | select(.tag == "xraywrt-direct") | .streamSettings.sockopt' <<<"$out")" 'no freedom "direct", no happyEyeballs'
pass 'direct happyEyeballs'
# Spec 6.4: finalRules against DNS rebinding on every directly dialing freedom.
nets='["10.0.0.0/8","fc00::/7"]'
fr() { jq -nc --argjson n "$nets" --argjson a "$1" '[{action: "allow", port: "53"}] + $a + [{action: "block", ip: $n}]'; }
fin() { jq -c --arg t "$1" '.outbounds[] | select(.tag == $t) | .settings.finalRules' <<<"$out"; }
jq '.outbounds += [{"tag": "own", "protocol": "freedom", "settings": {"finalRules": [{"action": "block", "port": "25"}]}},
	{"tag": "via", "protocol": "freedom", "streamSettings": {"sockopt": {"dialerProxy": "proxy"}}}]' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json" ".local_nets = $nets"
assert_eq "$(fr '[]')" "$(fin xraywrt-direct)" 'router direct finalRules'
assert_eq "$(fr '[]')" "$(fin direct)" 'provider freedom finalRules'
assert_eq "$(fr '[]' | jq -c '. + [{action: "block", port: "25"}]')" "$(fin own)" 'provider finalRules follow the router rules'
assert_eq null "$(fin via)" 'dialerProxy freedom: no finalRules'
gen "$tmpdir/src.json" ".local_nets = $nets | .dns_raw_upstream = \"[2001:db8::53]:5353\""
assert_eq 0 "$rc" "dns_raw_upstream: $errtxt"
assert_eq "$(fr '[{"action": "allow", "ip": ["2001:db8::53"]}]')" "$(fin xraywrt-direct)" 'dns_raw_upstream IP allowed'
gen_fails "$FX/src/single.json" 'config: local_nets is empty' '.local_nets = []'
jq '.outbounds[1].settings = {finalRules: "x"}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: outbound "direct" finalRules is not an array'
pass 'freedom finalRules'
gen "$FX/src/single.json" '.mark = 7'
jq -e '.outbounds[0].streamSettings.sockopt.mark == 7 and .outbounds[-1].streamSettings.sockopt.mark == 7' <<<"$out" >/dev/null || fail 'mark from params'
reserved() { gen_fails "$tmpdir/src.json" "config: tag \"$1\" uses reserved prefix xraywrt-"; }
gen_fails "$FX/src/bad-reserved.txt" 'config: tag "xraywrt-x" uses reserved prefix xraywrt-'
jq '.routing.balancers = [{"tag": "xraywrt-auto", "selector": ["proxy"]}]' "$FX/src/single.json" >"$tmpdir/src.json"
reserved xraywrt-auto
jq '.routing.rules[0].ruleTag = "xraywrt-r"' "$FX/src/single.json" >"$tmpdir/src.json"
reserved xraywrt-r
jq '.reverse = {"portals": [{"tag": "xraywrt-p", "domain": "r.example.com"}]}' "$FX/src/single.json" >"$tmpdir/src.json"
reserved xraywrt-p
jq '.dns = {"servers": [{"address": "192.0.2.9", "tag": "xraywrt-x"}]}' "$FX/src/single.json" >"$tmpdir/src.json"
reserved xraywrt-x
jq '.outbounds = [{"protocol": "freedom"}, {"tag": 5, "protocol": "freedom"}]' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "non-string tag goes to run -test: $errtxt"
jq '.outbounds = ["x"]' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: outbound #1 is not an object'
pass 'marks and service outbounds'

# A5.6 router inbounds (spec 6.3), the same in both modes.
tp() {
	jq -nc --arg t "$1" --arg l "$2" --argjson p "$3" --argjson d "$4" '{tag: $t, protocol: "tunnel", listen: $l, port: $p,
		settings: {allowedNetwork: "tcp,udp", followRedirect: true}, streamSettings: {sockopt: {tproxy: "tproxy"}}} + if $d == null then {} else {sniffing: {enabled: true, destOverride: $d, routeOnly: true}} end'
}
dnsin='{"tag":"xraywrt-dns-in","protocol":"tunnel","listen":"127.0.0.1","port":7874,"settings":{"allowedNetwork":"tcp,udp"}}'
for mode in proxy-first direct-first; do
	gen "$FX/src/single.json" ".mode_override = true | .mode = \"$mode\""
	expected="$(jq -sc . <<<"$(tp xraywrt-tproxy4 127.0.0.1 7894 'null')$(tp xraywrt-tproxy6 ::1 7894 'null')$dnsin")"
	assert_eq "$expected" "$(jq -c .inbounds <<<"$out")" "$mode inbounds without fakedns"
	jq '.dns = {"servers": [{"address": "fakedns", "domains": ["geosite:youtube"]}, "https://dns.example.net/dns-query"]}' "$FX/src/single.json" >"$tmpdir/src.json"
	gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\""
	fk='["fakedns"]'
	expected="$(jq -sc . <<<"$(tp xraywrt-tproxy4 127.0.0.1 7894 "$fk")$(tp xraywrt-tproxy6 ::1 7894 "$fk")$(tp xraywrt-fakeip-direct 127.0.0.1 7895 '["fakedns"]')$dnsin")"
	assert_eq "$expected" "$(jq -c .inbounds <<<"$out")" "$mode inbounds with fakedns"
done
gen "$FX/src/single.json" '.ipv6 = false'
assert_eq 'xraywrt-tproxy4 xraywrt-dns-in' "$(jq -r '[.inbounds[].tag] | join(" ")' <<<"$out")" 'no ::1 listener without IPv6'
src_json '{"outbounds": [{"protocol": "freedom"}], "dns": {"servers": ["fakedns"]}}'
gen "$tmpdir/src.json"
jq -e '[.inbounds[].tag] | index("xraywrt-fakeip-direct") != null' <<<"$out" >/dev/null || fail 'string fakedns server'
gen "$FX/src/single.json" '.ports = {tproxy: 17894, direct: 17895, dns: 17874, api: 11085}'
assert_eq '17894 17894 17874' "$(jq -r '[.inbounds[].port] | join(" ")' <<<"$out")" 'ports from params'
assert_eq '127.0.0.1:11085' "$(jq -r .api.listen <<<"$out")" 'API port from params'
for port in tproxy direct dns; do
	gen_fails "$FX/src/single.json" 'config: API port 7874 collides with a router port' ".ports.$port = 7874 | .ports.api = 7874"
done
pass 'router inbounds'

# A5.7 service routing rules before the provider's (spec 6.5).
dnsrule='{"inboundTag":["xraywrt-dns-in"],"outboundTag":"xraywrt-dns"}'
boot='{"inboundTag":["xraywrt-dns-internal"],"ip":["127.0.0.1","192.0.2.53"],"port":53,"outboundTag":"xraywrt-direct"}'
gen "$FX/src/single.json"
assert_eq "[$dnsrule,$boot,{\"ip\":[\"geoip:private\"],\"outboundTag\":\"direct\"}]" "$(jq -c .routing.rules <<<"$out")" 'rules without fakedns'
jq -e '.routing.domainStrategy == "AsIs"' <<<"$out" >/dev/null || fail 'routing keys kept'
jq '.dns = {"servers": ["fakedns"]} | del(.routing)' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json" '.fakeip_range = "198.18.0.0/16"'
assert_eq "[$dnsrule,$boot,{\"ip\":[\"198.18.0.0/16\"],\"outboundTag\":\"block\"},{\"inboundTag\":[\"xraywrt-fakeip-direct\"],\"outboundTag\":\"direct\"}]" \
	"$(jq -c .routing.rules <<<"$out")" 'rules with fakedns, no provider routing'
jq '.routing = {"rules": "x"}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: routing.rules is not an array'
jq '.routing = "x"' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: routing is not an object'
pass 'service routing rules'

# A5.8 proxy server hosts for the dnsmasq bypass and bootstrap (spec 7.4).
gen "$FX/servers-hosts.json"
assert_eq 0 "$rc" "servers.json: $errtxt"
assert_eq 'server-host vless.example.com
server-host flat.example.com
server-host vmess.example.com
server-host trojan.example.com
server-host ss.example.com
server-host socks.example.com
server-host http.example.com
server-host hy.example.com
server-host wg.example.com' "$(grep '^server-host' <<<"$prof")" 'server hosts'
pass 'server hosts'

# A5.12 geodata (spec 10).
geo='{"cron":"0 4 * * *","outbound":"proxy-1","assets":[{"url":"https://geo.example.com/geosite.dat","file":"geosite.dat"},{"url":"https://geo.example.com/a/geoip.dat","file":"geoip.dat"}]}'
jq --argjson g "$geo" '.geodata = $g | .routing.rules += [{"domain": ["geosite:cn", "ext:extra.dat:ads"], "outboundTag": "direct"}, {"source": ["geoip:ru"], "outboundTag": "direct"}]
	| .dns = {"servers": [{"address": "192.0.2.20", "domains": ["geosite:google"], "expectedIPs": ["geoip:us"]}]}' "$FX/src/single.json" >"$tmpdir/src.json"
printf 'ext:own.dat:x core\n' >"$tmpdir/fd.txt"
gen "$tmpdir/src.json" '.rules_file = "'"$tmpdir/fd.txt"'"'
assert_eq 0 "$rc" "geodata: $errtxt"
assert_eq "$geo" "$(jq -c .geodata <<<"$out")" 'geodata section kept'
assert_eq 'geodata geosite.dat https://geo.example.com/geosite.dat
geodata geoip.dat https://geo.example.com/a/geoip.dat
geodata-ref extra.dat
geodata-ref geoip.dat
geodata-ref geosite.dat
geodata-ref own.dat' "$(grep '^geodata' <<<"$prof")" 'geodata profile lines'
gen "$FX/src/single.json"
assert_eq 'geodata-ref geoip.dat' "$(grep '^geodata' <<<"$prof")" 'no assets, one ref'
bad() {
	jq --argjson a "$1" '.geodata = {"assets": [$a]}' "$FX/src/single.json" >"$tmpdir/src.json"
	gen_fails "$tmpdir/src.json" "$2"
}
bad '{"url":"https://x.example/a.dat","file":"../a.dat"}' 'config: geodata file "../a.dat" is invalid'
bad '{"url":"https://x.example/a.dat","file":"a.txt"}' 'config: geodata file "a.txt" is invalid'
bad '{"url":"https://x.example/a.dat"}' 'config: geodata file "" is invalid'
bad '{"url":"http://x.example/a.dat","file":"a.dat"}' 'config: geodata url "http://x.example/a.dat" is not https'
bad '{"url":"https://x.example/a b.dat","file":"a.dat"}' 'config: geodata url "https://x.example/a b.dat" is not https'
jq '.geodata = {"assets": "x"}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: geodata.assets is not an array'
jq '.routing = {"rules": [{"domain": ["ext:a/b.dat:x"], "outboundTag": "direct"}]}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: geodata file "a/b.dat" is invalid'
pass 'geodata'

# A null entry in a provider array is the core's to reject, not a generator TypeError.
jq '.observatory = {} | .routing.balancers = [null]' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "null balancer: $errtxt"
jq '.geodata = {"assets": [null]}' "$FX/src/single.json" >"$tmpdir/src.json"
gen_fails "$tmpdir/src.json" 'config: geodata file "" is invalid' '.geodata_asset = ["own.dat=https://own.example/a.dat"]'
pass 'null provider array entries'

# B1: router API cannot be replaced by a provider listener or API service.
src_json '{"outbounds":[{"tag":"direct","protocol":"freedom"}],"inbounds":[{"tag":"other","port":10086,"protocol":"http"}],"api":{"tag":"evil","services":["LoggerService"]}}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "provider API ownership: $errtxt"
jq -e '.api == {tag:"xraywrt-api", listen:"127.0.0.1:10085", services:["HandlerService","RoutingService","StatsService"]}' <<<"$out" >/dev/null || fail 'router API listens itself'
assert_eq '[]' "$(jq -c '[.inbounds[] | select(.port == 10085 or .tag == "xraywrt-api")]' <<<"$out")" 'no API inbound: provider routing cannot reach it'
assert_eq '[]' "$(jq -c '[.routing.rules[] | select(.outboundTag == "xraywrt-api" or (.inboundTag // [] | index("xraywrt-api")))]' <<<"$out")" 'no API routing rule'
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"tag":"xraywrt-api","listen":"0.0.0.0","port":10086,"protocol":"socks"}]}'
gen_fails "$tmpdir/src.json" 'config: tag "xraywrt-api" uses reserved prefix xraywrt-'
src_json '{"outbounds":[{"protocol":"freedom"}],"inbounds":[{"tag":"other","port":10085,"protocol":"http"}]}'
gen_fails "$tmpdir/src.json" 'config: inbound "other" port 10085 collides with a router port'
src_json '{"outbounds":[{"tag":"xraywrt-api","protocol":"freedom"}]}'
gen_fails "$tmpdir/src.json" 'config: tag "xraywrt-api" uses reserved prefix xraywrt-'
pass 'router API ownership'

for level in debug info warning error none invalid absent; do
 src_json "{\"outbounds\":[{\"protocol\":\"freedom\"}],\"log\":{\"loglevel\":\"$level\"}}"
 [ "$level" != absent ] || src_json '{"outbounds":[{"protocol":"freedom"}]}'
 gen "$tmpdir/src.json" '.log_level = "error"'
 case "$level" in
 invalid | absent)
  ! grep -q '^set core_log_level ' <<<"$prof" || fail 'invalid/absent log level exported'
  expected=error ;;
 *) prof_has "set core_log_level $level"; expected="$level" ;;
 esac
 assert_eq "$expected" "$(jq -r .log.loglevel <<<"$out")" 'effective provider log level'
 gen "$tmpdir/src.json" '.log_level = "none" | .log_level_override = true'
 assert_eq none "$(jq -r .log.loglevel <<<"$out")" 'UCI override log level'
done
pass 'provider core_log_level profile metadata and effective generation'

# User assets share the provider's geodata/profile path.
gen "$FX/src/single.json" '.geodata_asset = ["own.dat=https://own.example/a.dat?x=y"]'
assert_eq 0 "$rc" "user geodata: $errtxt"
jq -e '.geodata == {cron:"0 5 * * *", assets:[{file:"own.dat",url:"https://own.example/a.dat?x=y"}]}' <<<"$out" >/dev/null || fail 'user geodata section and default cron'
prof_has 'geodata own.dat https://own.example/a.dat?x=y'
xray_test_bin "user geodata" || exit 0
cp /usr/local/share/xray-test/*.dat "$tmpdir/"
cp "$tmpdir/geoip.dat" "$tmpdir/own.dat"
XRAY_LOCATION_ASSET="$tmpdir" "$XRAY_TEST_BIN" run -test -c "$tmpdir/out.json" >"$tmpdir/core-test.log" 2>&1 || fail "user geodata core test: $(cat "$tmpdir/core-test.log")"
gen "$FX/src/full.json" '.geodata_asset = ["own.dat=https://own.example/a.dat", "geosite.dat=https://own.example/site.dat"] | .geodata_cron = "15 6 * * 1-5"'
assert_eq 0 "$rc" "merged geodata: $errtxt"
assert_eq "$(jq -r '.geodata.cron' "$FX/src/full.json")" "$(jq -r '.geodata.cron' <<<"$out")" 'subscription cron wins'
prof_has 'warn geodata geosite.dat: the subscription already has a file with this name, rename yours'
prof_has 'geodata own.dat https://own.example/a.dat'
jq 'del(.geodata.cron)' "$FX/src/full.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json" '.geodata_asset = ["own.dat=https://own.example/a.dat"] | .geodata_cron = "15 6 * * 1-5"'
assert_eq '15 6 * * 1-5' "$(jq -r '.geodata.cron' <<<"$out")" 'user schedule covers all assets without subscription cron'
for entry in 'bad' '../a.dat=https://x/a' '.dat=https://x/a' 'a.txt=https://x/a' 'a.dat=http://x/a' 'a.dat=https://x/a b' 'a.dat=https://' $'a.dat=https://x/a\tbad' $'a.dat=https://x/a\001bad'; do
 gen "$FX/src/single.json" ".geodata_asset = [$(jq -n --arg v "$entry" '$v')]"
 assert_eq 0 "$rc" 'invalid user entry does not reject config'
 jq -e 'has("geodata") | not' <<<"$out" >/dev/null || fail "invalid asset accepted: $entry"
 grep -q '^warn geodata ' <<<"$prof" || fail 'invalid user entry warning'
done
gen "$FX/src/single.json" '.geodata_asset = ["a.dat=https://x/a", "a.dat=https://x/b"] | .geodata_cron = "61 * * * *"'
assert_eq 1 "$(jq '.geodata.assets | length' <<<"$out")" 'duplicate user name skipped'
assert_eq '0 5 * * *' "$(jq -r '.geodata.cron' <<<"$out")" 'bad cron falls back'
prof_has 'warn geodata cron: invalid schedule, using 0 5 * * *'
for cron in '*/10 0-23/2 1,15 * 0-6' '0 5 * * *'; do
 gen "$FX/src/single.json" ".geodata_asset = [\"a.dat=https://x/a\"] | .geodata_cron = \"$cron\""
 assert_eq "$cron" "$(jq -r '.geodata.cron' <<<"$out")" 'numeric cron supported'
done
for cron in '0 24 * * *' '0 5 0 * *' '0 5 * 13 *' '0 5 * * 7' '*/0 * * * *' '*/99999999999999999999999999999999 * * * *' '5-2 * * * *' '0 5 * *' '0 5 * * * extra'; do
 gen "$FX/src/single.json" ".geodata_asset = [\"a.dat=https://x/a\"] | .geodata_cron = \"$cron\""
 prof_has 'warn geodata cron: invalid schedule, using 0 5 * * *'
done
pass 'user geodata merges, validates, schedules and passes core test'

# The subscription's own geodata schedule: valid and at most daily, or the router's schedule applies.
provider_cron() { jq --arg c "$1" '.geodata.cron = $c' "$FX/src/full.json" >"$tmpdir/src.json"; gen "$tmpdir/src.json" "${2:-.}"; }
for cron in '0 4 * * *' '30 3 * * 1-5'; do
 provider_cron "$cron"
 assert_eq 0 "$rc" "provider cron $cron: $errtxt"
 assert_eq "$cron" "$(jq -r '.geodata.cron' <<<"$out")" "provider cron $cron kept"
 prof_lacks "warn geodata cron \"$cron\" from the subscription is invalid or more frequent than daily, using 0 5 * * *"
done
for cron in '* * * * *' '*/5 * * * *' '0 */2 * * *' '0 0,12 * * *' '15,45 3 * * *' '0-30 4 * * *' '61 * * * *' 'daily' '0 5 * *'; do
 provider_cron "$cron" '.geodata_cron = "15 6 * * 1-5"'
 assert_eq 0 "$rc" "provider cron $cron does not reject the config: $errtxt"
 assert_eq '15 6 * * 1-5' "$(jq -r '.geodata.cron' <<<"$out")" "provider cron $cron replaced by the router schedule"
 prof_has "warn geodata cron \"$cron\" from the subscription is invalid or more frequent than daily, using 15 6 * * 1-5"
done
provider_cron '* * * * *'
assert_eq '0 5 * * *' "$(jq -r '.geodata.cron' <<<"$out")" 'router default schedule replaces a too frequent one'
jq '.geodata.cron = 5' "$FX/src/full.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq '0 5 * * *' "$(jq -r '.geodata.cron' <<<"$out")" 'non-string provider cron replaced'
pass 'provider geodata cron is validated and at most daily'
