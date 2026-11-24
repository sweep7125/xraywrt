#!/usr/bin/env bash
# xray-config.uc My rules (spec 11): one ordered list of sites and addresses, each
# with a target (direct, core or a tag). Adjacent lines of one target and kind make
# one DNS server entry and one routing rule; the first matching line wins.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
xray_test_bin 'My rules generation' || exit 0
export XRAY_LOCATION_ASSET="$XRAY_TEST_ASSETS"

proxy_ob='{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}'
second_ob='{"tag":"second","protocol":"socks","settings":{"servers":[{"address":"192.0.2.2","port":1080}]}}'
direct_ob='{"tag":"direct","protocol":"freedom"}'
# gen_rules <mode> <rules text> [extra jq filter]
gen_rules() {
	printf '%s\n' "$2" >"$tmpdir/rules.txt"
	gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$1\" | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {} ${3:+| $3}"
	assert_eq 0 "$rc" "$1: generate: $errtxt"
}
own_rules() { jq -c '[.routing.rules[] | select((.ruleTag // "") | startswith("xraywrt-rule-")) | select((.ruleTag | endswith("-service")) | not) | if .inboundTag == ["xraywrt-tproxy4","xraywrt-tproxy6"] and (.port == null and .network == null) then del(.inboundTag) else . end]' <<<"$out"; }
dns_servers() { jq -c .dns.servers <<<"$out"; }
core_test() {
	xray-test run -test -c "$tmpdir/out.json" >"$tmpdir/core.log" 2>&1 || fail "$1: core test: $(cat "$tmpdir/core.log")"
}
# Send both transports to the same original address and port on the real core.
selector_routes() (
	local core="" port=18948
	trap '[ -z "$core" ] || { kill "$core" 2>/dev/null || :; wait "$core" 2>/dev/null || :; }' EXIT
	jq --arg log "$tmpdir/access.log" --argjson port "$port" '
	 .routing.rules += [{ip:["198.20.22.2"],port:443,network:"tcp,udp",outboundTag:"second"}]
	 | (.outbounds[] | select(.protocol == "socks") | .settings.servers) = [{address:"127.0.0.1",port:1}]
	 | .inbounds = [{tag:"xraywrt-tproxy4",listen:"127.0.0.1",port:$port,protocol:"tunnel",settings:{address:"198.20.22.2",port:443,allowedNetwork:"tcp,udp"}}]
	 | .log = {access:$log,loglevel:"warning"}' <<<"$out" >"$tmpdir/selector-runtime.json"
	: >"$tmpdir/access.log"
	"$XRAY_TEST_BIN" run -c "$tmpdir/selector-runtime.json" >"$tmpdir/selector-core.log" 2>&1 &
	core=$!
	for _ in {1..100}; do
		grep -q 'started' "$tmpdir/selector-core.log" && break
		kill -0 "$core" 2>/dev/null || fail "selector core start: $(cat "$tmpdir/selector-core.log")"
		sleep .05
	done
	printf 'tcp\n' >/dev/tcp/127.0.0.1/$port
	printf 'udp\n' >/dev/udp/127.0.0.1/$port
	for _ in {1..100}; do
		if grep -Fq 'accepted tcp:198.20.22.2:443 [xraywrt-tproxy4 -> second]' "$tmpdir/access.log" &&
		   grep -Fq 'accepted udp:198.20.22.2:443 [xraywrt-tproxy4 -> proxy]' "$tmpdir/access.log"; then
			return 0
		fi
		sleep .05
	done
	fail "$1: expected provider TCP route and personal UDP route: $(cat "$tmpdir/access.log")"
)

sniffing='"inbounds":[{"tag":"in","protocol":"socks","listen":"127.0.0.1","port":1081,"sniffing":{"enabled":true,"destOverride":["tls"]}}]'
src_json "{\"outbounds\":[$direct_ob,$proxy_ob,$second_ob],\"routing\":{\"balancers\":[{\"tag\":\"pool\",\"selector\":[\"proxy\",\"second\"]}]},$sniffing}"

# The site run between address runs must split both consumers in the same order.
gen_rules direct-first $'198.51.100.1;80;udp proxy\nfirst.test proxy\n198.51.100.2;80;udp proxy\nsecond.test direct'
jq -e '[.[] | .ruleTag] == ["xraywrt-rule-1","xraywrt-rule-2","xraywrt-rule-3","xraywrt-rule-4"]' <<<"$(own_rules)" >/dev/null || fail 'interleaved address/site run boundaries'
printf '{}\n' >"$tmpdir/remote.json"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" "$tmpdir/out.json" >"$tmpdir/packet"
assert_eq $'proxy;ip;198.51.100.1;80;udp\nproxy;ip;198.51.100.2;80;udp' "$(cat "$tmpdir/packet")" 'packet address order across site run'
pass 'core and packet policies preserve interleaved run order'

# Qualified sites route only recognized traffic and never change DNS selection.
for mode in direct-first proxy-first; do
 gen_rules "$mode" $'overlap.example;443;udp direct\noverlap.example;443;tcp proxy\nother.example;;udp pool'
 jq -e '[.routing.rules[] | select((.ruleTag // "") | startswith("xraywrt-rule-")) | {domain,port,network,outboundTag,balancerTag}] == [
  {domain:["domain:overlap.example"],port:"443",network:"udp",outboundTag:"direct",balancerTag:null},
  {domain:["domain:overlap.example"],port:"443",network:"tcp",outboundTag:"proxy",balancerTag:null},
  {domain:["domain:other.example"],port:null,network:"udp",outboundTag:null,balancerTag:"pool"}]' <<<"$out" >/dev/null || fail "$mode: qualified site tuples: $(own_rules)"
 assert_eq '["192.0.2.53"]' "$(dns_servers)" "$mode: qualified sites do not add DNS entries"
 core_test "$mode qualified sites"
done
gen_rules direct-first $'example.com;443;udp proxy\nexample.com direct'
jq -e '[.[] | {domain,port,network,outboundTag}] == [{domain:["domain:example.com"],port:"443",network:"udp",outboundTag:"proxy"},{domain:["domain:example.com"],port:null,network:null,outboundTag:"direct"}]' <<<"$(own_rules)" >/dev/null || fail 'qualified route precedes unqualified route'
gen_rules direct-first $'example.com direct\nexample.com;443;udp proxy'
jq -e '[.[] | .outboundTag] == ["direct","proxy"]' <<<"$(own_rules)" >/dev/null || fail 'unqualified route precedes qualified route'
gen_rules direct-first $'domain:example.com core\ndomain:example.com;443;udp proxy\nfull:api.example.com;443;udp proxy'
jq -e '[.[] | .domain] == [["full:api.example.com"]]' <<<"$(own_rules)" >/dev/null || fail 'legacy core shadows its same matcher but not overlapping different matchers'
gen_rules direct-first 'regexp:^foo;bar$ proxy'
assert_eq '[{"domain":["regexp:^foo;bar$"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-1"}]' "$(own_rules)" 'regexp semicolon remains literal legacy syntax'
pass 'My rules: qualified sites use native tuple routing without DNS changes'

# Interleaved blocks: a change of target starts a new rule and a new DNS entry, in line order.
for mode in direct-first proxy-first; do
	gen_rules "$mode" $'a.test direct\nb.test direct\nc.test proxy\nd.test pool\ne.test direct\n# comment\n\nf.test direct'
	assert_eq '[{"domain":["domain:a.test","domain:b.test"],"outboundTag":"direct","ruleTag":"xraywrt-rule-1"},{"domain":["domain:c.test"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2"},{"domain":["domain:d.test"],"balancerTag":"pool","ruleTag":"xraywrt-rule-3"},{"domain":["domain:e.test","domain:f.test"],"outboundTag":"direct","ruleTag":"xraywrt-rule-4"}]' "$(own_rules)" "$mode: runs become rules in line order"
	jq -e '[.routing.rules[] | .ruleTag // empty | select(endswith("-service") | not)] == ["xraywrt-rule-1","xraywrt-rule-2","xraywrt-rule-3","xraywrt-rule-4"]' <<<"$out" >/dev/null || fail "$mode: own rules are before the provider's"
	core_test "$mode interleaved"
done
gen_rules direct-first $'a.test direct\nb.test direct\nc.test proxy\nd.test pool\ne.test direct'
assert_eq '[{"address":"192.0.2.53","domains":["domain:a.test","domain:b.test"],"skipFallback":true,"finalQuery":true},{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"fakedns","domains":["domain:d.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"192.0.2.53","domains":["domain:e.test"],"skipFallback":true,"finalQuery":true},"192.0.2.53"]' "$(dns_servers)" 'direct-first: one DNS server entry per run, in line order'
gen_rules proxy-first $'a.test direct\nc.test proxy'
assert_eq '[{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},"192.0.2.53"]' "$(dns_servers)" 'proxy-first: direct sites need no real-address DNS entry'
pass 'My rules: runs of sites'

# Model the provider's tagged DoH, including an overlapping FakeDNS domain.
resolver='{"address":"https://dns.example/dns-query","port":443,"tag":"dns-direct","expectedIPs":["192.0.2.0/24"],"unexpectedIPs":["192.0.2.66"],"queryStrategy":"UseIPv4"}'
fake='{"address":"fakedns","domains":["domain:overlap.example"],"skipFallback":true,"queryStrategy":"UseIPv4"}'
src_json "{\"outbounds\":[$direct_ob,$proxy_ob],\"dns\":{\"servers\":[$fake,$resolver]},\"routing\":{\"rules\":[{\"inboundTag\":[\"dns-direct\"],\"outboundTag\":\"direct\"},{\"network\":\"tcp,udp\",\"outboundTag\":\"proxy\"}]},$sniffing}"
for mode in direct-first proxy-first; do
 gen_rules "$mode" $'overlap.example;443;udp direct\noverlap.example;443;tcp proxy'
 jq -e --argjson resolver "$resolver" --argjson fake "$fake" '.dns.servers == [$fake, $resolver]' <<<"$out" >/dev/null || fail "$mode: qualified overlap preserves provider DNS"
 core_test "$mode qualified FakeDNS overlap"
done
gen_rules direct-first 'overlap.example direct'
jq -e --argjson resolver "$resolver" --argjson fake "$fake" '
 .dns.servers == [($resolver + {domains:["domain:overlap.example"],skipFallback:true,finalQuery:true}), $fake, $resolver]
 and any(.routing.rules[]; .inboundTag == ["dns-direct"] and .outboundTag == "direct")
' <<<"$out" >/dev/null || fail 'direct-first preserves tagged resolver policy and ends DNS selection after the match'
core_test 'tagged direct DoH'
gen_rules proxy-first 'overlap.example direct'
jq -e --argjson resolver "$resolver" --argjson fake "$fake" '.dns.servers == [$fake, $resolver]' <<<"$out" >/dev/null || fail 'proxy-first DNS stays unchanged'
pass 'My rules: direct DNS keeps provider policy without FakeDNS fallback'

# A resolver sharing the provider DNS tag must follow the rewritten route.
src_json "{\"outbounds\":[$direct_ob,$proxy_ob],\"dns\":{\"tag\":\"dns-direct\",\"servers\":[$fake,$resolver]},\"routing\":{\"rules\":[{\"inboundTag\":[\"dns-direct\"],\"outboundTag\":\"direct\"},{\"network\":\"tcp,udp\",\"outboundTag\":\"proxy\"}]},$sniffing}"
gen_rules direct-first 'overlap.example direct'
jq -e --argjson resolver "$resolver" --argjson fake "$fake" '
 .dns.servers == [($resolver + {tag:"xraywrt-dns-internal",domains:["domain:overlap.example"],skipFallback:true,finalQuery:true}), $fake, $resolver]
 and any(.routing.rules[]; .inboundTag == ["xraywrt-dns-internal"] and .outboundTag == "direct")
' <<<"$out" >/dev/null || fail 'shared resolver tag follows rewritten DNS route without changing provider records'
core_test 'shared DNS tag'
gen_rules proxy-first 'overlap.example direct'
jq -e --argjson resolver "$resolver" --argjson fake "$fake" '.dns.servers == [$fake, $resolver]' <<<"$out" >/dev/null || fail 'proxy-first preserves shared-tag provider records'
pass 'My rules: shared DNS tag follows rewritten route'

# Restore the common source for the remaining tests.
# Selector mechanics use non-overriding sniffing; overriding behavior has separate tests.
sniffing='"inbounds":[{"tag":"in","protocol":"socks","listen":"127.0.0.1","port":1081,"sniffing":{"enabled":true,"destOverride":["tls"],"routeOnly":true}}]'
src_json "{\"outbounds\":[$direct_ob,$proxy_ob,$second_ob],\"routing\":{\"balancers\":[{\"tag\":\"pool\",\"selector\":[\"proxy\",\"second\"]}]},$sniffing}"

# The target decides the rule; core makes none; the first line of a name wins.
gen_rules direct-first $'a.test core\nb.test core\nc.test proxy\na.test direct'
assert_eq '[{"domain":["domain:c.test"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2"}]' "$(own_rules)" 'core: no routing rule, a repeated name keeps its first line'
assert_eq '[{"address":"fakedns","domains":["domain:a.test","domain:b.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},"192.0.2.53"]' "$(dns_servers)" 'core and a tag are fake-IP names'
prof_has 'fake-domains 3'
prof_lacks 'direct-domains 1'
pass 'My rules: core target'

# Qualified addresses and cached rows form the same tuples as packet policy.
cat >"$tmpdir/selectors.txt" <<'EOF'
198.20.22.2;;udp
2001:db8::2;8443;udp
198.20.22.3;;tcp
EOF
printf '%s\n' '198.20.22.2;443;tcp core' 'https://list.test/selectors;0443;udp proxy' '198.20.22.2;443 second' '2001:DB8::1/064;080-090;tcp pool' '198.20.22.2;8443;;udp second' >"$tmpdir/rules.txt"
assert_eq 'https://list.test/selectors' "$(xraywrt-json rules urls "$tmpdir/rules.txt")" 'cache keyed by bare URL'
assert_eq $'198.20.22.2;443;tcp\nhttps://list.test/selectors;443;udp\n198.20.22.2;443\n2001:db8::1/64;80-90;tcp' "$(printf 'proxy\nsecond\npool\n' | xraywrt-json rules entries "$tmpdir/rules.txt" proxy)" 'canonical selectors and invalid entries excluded'
for mode in direct-first proxy-first; do
 gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/selectors\": \"$tmpdir/selectors.txt\"}"
 assert_eq 0 "$rc" "$mode: $errtxt"
 jq -e 'all(.[]; .inboundTag == ["xraywrt-tproxy4","xraywrt-tproxy6"]) and [.[] | del(.ruleTag,.inboundTag)] == [
  {ip:["198.20.22.2"],port:"443",network:"udp",outboundTag:"proxy"},
  {ip:["2001:db8::2"],port:"8443",network:"udp",outboundTag:"proxy"},
  {ip:["198.20.22.2"],port:"443",network:"udp",outboundTag:"second"},
  {ip:["2001:db8::1/64"],port:"80-90",network:"tcp",balancerTag:"pool"}
 ]' <<<"$(own_rules)" >/dev/null || fail "$mode: qualified URL inheritance and core shadows: $(own_rules)"
 core_test "$mode selectors"
 selector_routes "$mode"
done
pass 'My rules: canonical address tuples and ordered core shadows'
for mode in direct-first proxy-first; do
 gen_rules "$mode" $'2001:db8::1;81;tcp core\n2001:db8::/127;80-82;tcp proxy\n198.51.100.1 direct\n198.51.100.1;;udp second\n198.51.100.2 core\n198.51.100.2;;udp second'
 assert_eq '[{"ip":["2001:db8::"],"port":"80-82","network":"tcp","inboundTag":["xraywrt-tproxy4","xraywrt-tproxy6"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2"},{"ip":["2001:db8::1"],"port":"80,82","network":"tcp","inboundTag":["xraywrt-tproxy4","xraywrt-tproxy6"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2-2"}]' "$(own_rules)" "$mode: only intersecting IPv6 ports and plain IPv4 shadows are removed"
 core_test "$mode CIDR and port shadows"
 gen_rules "$mode" $'198.51.100.2;443;udp core\n198.51.100.2 second'
 jq -e '[.[] | select(.inboundTag == ["xraywrt-tproxy4","xraywrt-tproxy6"]) | {port,network}] == [{port:null,network:"tcp"},{port:"0-442,444-65535",network:"udp"}] and any(.[]; .ip == ["198.51.100.2"] and (.inboundTag | index("xraywrt-dns-internal")))' <<<"$(own_rules)" >/dev/null || fail "$mode: TCP and all other UDP ports remain eligible"
 core_test "$mode all-port shadow"
done


# A tag gets IP rules for plain and scoped rows; direct and core need no outbound.
cat >"$tmpdir/cache.txt" <<'EOF'
9.9.9.0/24
2001:db8:9::/48
8.8.8.8;443
;53
aa:bb:cc:dd:ee:ff
not-an-address
10.0.0.0/33
EOF
printf '%s\n' $'1.2.3.0/24 proxy\n2001:DB8::/32 proxy\nhttps://list.test/a.txt proxy\n5.6.7.0/24 direct\n6.6.6.6 core\n0.0.0.0/24 pool\nhttps://list.test/b.txt direct' >"$tmpdir/rules.txt"
for mode in direct-first proxy-first; do
	gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/a.txt\": \"$tmpdir/cache.txt\", \"https://list.test/b.txt\": \"$tmpdir/missing.txt\"}"
	assert_eq 0 "$rc" "$mode: $errtxt"
	assert_eq '[{"ip":["1.2.3.0/24","2001:db8::/32","9.9.9.0/24","2001:db8:9::/48"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-1"},{"ip":["8.8.8.8"],"port":"443","inboundTag":["xraywrt-tproxy4","xraywrt-tproxy6"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-1-2"},{"ip":["0.0.0.0/0","::/0"],"port":"53","inboundTag":["xraywrt-tproxy4","xraywrt-tproxy6"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-1-3"},{"ip":["0.0.0.0/24"],"balancerTag":"pool","ruleTag":"xraywrt-rule-4"}]' "$(own_rules)" "$mode: address rules: typed and fetched entries of a tag run, none for direct and core"
	core_test "$mode addresses"
done
# Too many addresses for one rule skip that rule with a warning: the config stays valid
# (a start after a reboot must not fail on a grown remote list); other rules are kept.
{ echo '7.7.7.7 second'; for i in $(seq 0 100); do for j in $(seq 0 99); do printf '10.%d.%d.0/24 proxy\n' "$i" "$j"; done; done; } >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {}"
assert_eq 0 "$rc" "a rule with more than 10000 addresses is skipped, not refused: $errtxt"
assert_eq '[{"ip":["7.7.7.7"],"outboundTag":"second","ruleTag":"xraywrt-rule-1"}]' "$(own_rules)" 'the other rules are kept'
prof_has 'warn My rules: the rule "proxy" has more than 10000 addresses and is skipped'
grep -qF '[E:rules_too_large|proxy|10000]' <<<"$prof" || fail "coded warning: $prof"
core_test 'too many addresses'
# A big fetched list is cut at the limit without a quadratic scan (the check runs at every start).
awk 'BEGIN { for (i = 0; i < 70000; i++) printf "10.%d.%d.%d\n", int(i / 65536), int(i / 256) % 256, i % 256 }' >"$tmpdir/big.txt"
printf '%s\n' 'https://list.test/big.txt proxy' >"$tmpdir/rules.txt"
started=$SECONDS
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/big.txt\": \"$tmpdir/big.txt\"}"
assert_eq 0 "$rc" "a big fetched list is skipped: $errtxt"
assert_eq '[]' "$(own_rules)" 'no rule from a list over the limit'
[ $((SECONDS - started)) -lt 20 ] || fail "a 70000-line list took $((SECONDS - started)) s"
pass 'My rules: addresses'

# Bad lines are skipped with a warning; a target that is gone is named and skipped.
gen_rules direct-first $'a.test direct\nb.test gone\n1.2.3.4\nnot a rule at all\nc.test proxy extra\nd.test gone\ne.test other\n1.2.3.0/33 core\nf.test core'
prof_has 'warn My rules: line 3 "1.2.3.4" ignored'
prof_has 'warn My rules: line 4 "not a rule at all" ignored'
prof_has 'warn My rules: line 5 "c.test proxy extra" ignored'
prof_has 'warn My rules: line 8 "1.2.3.0/33 core" ignored'
prof_has 'warn My rules: the targets gone, other are not in the configuration, their lines are skipped'
assert_eq '[{"domain":["domain:a.test"],"outboundTag":"direct","ruleTag":"xraywrt-rule-1"}]' "$(own_rules)" 'only the lines with a target are used'
pass 'My rules: bad lines and missing targets'

# direct and core are reserved: a provider tag of that name is no target and never wins.
src_json "{\"outbounds\":[{\"tag\":\"direct\",\"protocol\":\"vless\",\"settings\":{\"vnext\":[{\"address\":\"10.0.0.9\",\"port\":443,\"users\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"encryption\":\"none\"}]}]}},{\"tag\":\"core\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"192.0.2.8\",\"port\":1}]}},$proxy_ob],\"routing\":{\"balancers\":[{\"tag\":\"core\",\"selector\":[\"proxy\"]}]},$sniffing}"
gen_rules direct-first $'example.com direct\nexample.org core\nexample.net proxy'
assert_eq '[{"domain":["domain:example.com"],"outboundTag":"direct","ruleTag":"xraywrt-rule-1"},{"domain":["domain:example.net"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-3"}]' "$(own_rules)" 'provider outbound tagged direct is used; core is no tag'
prof_has 'rules-target proxy'
prof_lacks 'rules-target direct'
prof_lacks 'rules-target core'
prof_has 'rules-reserved direct'
prof_has 'rules-reserved core'
core_test 'reserved tags'
src_json "{\"outbounds\":[$direct_ob,$proxy_ob]}"
gen_rules direct-first 'example.com direct'
prof_lacks 'rules-reserved direct'
pass 'My rules: reserved targets'
