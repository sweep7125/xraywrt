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
own_rules() { jq -c '[.routing.rules[] | select((.ruleTag // "") | startswith("xraywrt-rule-"))]' <<<"$out"; }
dns_servers() { jq -c .dns.servers <<<"$out"; }
core_test() {
	xray-test run -test -c "$tmpdir/out.json" >"$tmpdir/core.log" 2>&1 || fail "$1: core test: $(cat "$tmpdir/core.log")"
}
sniffing='"inbounds":[{"tag":"in","protocol":"socks","listen":"127.0.0.1","port":1081,"sniffing":{"enabled":true,"destOverride":["tls"]}}]'
src_json "{\"outbounds\":[$direct_ob,$proxy_ob,$second_ob],\"routing\":{\"balancers\":[{\"tag\":\"pool\",\"selector\":[\"proxy\",\"second\"]}]},$sniffing}"

# Interleaved blocks: a change of target starts a new rule and a new DNS entry, in line order.
for mode in direct-first proxy-first; do
	gen_rules "$mode" $'a.test direct\nb.test direct\nc.test proxy\nd.test pool\ne.test direct\n# comment\n\nf.test direct'
	assert_eq '[{"domain":["domain:a.test","domain:b.test"],"outboundTag":"xraywrt-direct","ruleTag":"xraywrt-rule-1"},{"domain":["domain:c.test"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2"},{"domain":["domain:d.test"],"balancerTag":"pool","ruleTag":"xraywrt-rule-3"},{"domain":["domain:e.test","domain:f.test"],"outboundTag":"xraywrt-direct","ruleTag":"xraywrt-rule-4"}]' "$(own_rules)" "$mode: runs become rules in line order"
	jq -e '[.routing.rules[] | .ruleTag // empty] == ["xraywrt-rule-1","xraywrt-rule-2","xraywrt-rule-3","xraywrt-rule-4"]' <<<"$out" >/dev/null || fail "$mode: own rules are before the provider's"
	core_test "$mode interleaved"
done
gen_rules direct-first $'a.test direct\nb.test direct\nc.test proxy\nd.test pool\ne.test direct'
assert_eq '[{"address":"192.0.2.53","domains":["domain:a.test","domain:b.test"],"skipFallback":true},{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"fakedns","domains":["domain:d.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"192.0.2.53","domains":["domain:e.test"],"skipFallback":true},"192.0.2.53"]' "$(dns_servers)" 'direct-first: one DNS server entry per run, in line order'
gen_rules proxy-first $'a.test direct\nc.test proxy'
assert_eq '[{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},"192.0.2.53"]' "$(dns_servers)" 'proxy-first: direct sites need no real-address DNS entry'
pass 'My rules: runs of sites'

# The target decides the rule; core makes none; the first line of a name wins.
gen_rules direct-first $'a.test core\nb.test core\nc.test proxy\na.test direct'
assert_eq '[{"domain":["domain:c.test"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-2"}]' "$(own_rules)" 'core: no routing rule, a repeated name keeps its first line'
assert_eq '[{"address":"fakedns","domains":["domain:a.test","domain:b.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},{"address":"fakedns","domains":["domain:c.test"],"skipFallback":true,"queryStrategy":"UseIPv4"},"192.0.2.53"]' "$(dns_servers)" 'core and a tag are fake-IP names'
prof_has 'fake-domains 3'
prof_lacks 'direct-domains 1'
pass 'My rules: core target'

# Addresses: a tag gets an ip rule (also from a list link), direct and core none.
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
	assert_eq '[{"ip":["1.2.3.0/24","2001:db8::/32","9.9.9.0/24","2001:db8:9::/48"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-1"},{"ip":["0.0.0.0/24"],"balancerTag":"pool","ruleTag":"xraywrt-rule-4"}]' "$(own_rules)" "$mode: address rules: typed and fetched entries of a tag run, none for direct and core"
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
assert_eq '[{"domain":["domain:a.test"],"outboundTag":"xraywrt-direct","ruleTag":"xraywrt-rule-1"}]' "$(own_rules)" 'only the lines with a target are used'
pass 'My rules: bad lines and missing targets'

# direct and core are reserved: a provider tag of that name is no target and never wins.
src_json "{\"outbounds\":[{\"tag\":\"direct\",\"protocol\":\"vless\",\"settings\":{\"vnext\":[{\"address\":\"10.0.0.9\",\"port\":443,\"users\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"encryption\":\"none\"}]}]}},{\"tag\":\"core\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"192.0.2.8\",\"port\":1}]}},$proxy_ob],\"routing\":{\"balancers\":[{\"tag\":\"core\",\"selector\":[\"proxy\"]}]},$sniffing}"
gen_rules direct-first $'example.com direct\nexample.org core\nexample.net proxy'
assert_eq '[{"domain":["domain:example.com"],"outboundTag":"xraywrt-direct","ruleTag":"xraywrt-rule-1"},{"domain":["domain:example.net"],"outboundTag":"proxy","ruleTag":"xraywrt-rule-3"}]' "$(own_rules)" 'a provider outbound tagged direct (vless) is not the target of direct; core is no tag either'
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
