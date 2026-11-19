#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
xray_test_bin 'v0.1.5 review regressions' || exit 0

src_json '{"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}]}'
for mode in direct-first proxy-first; do
 printf '%s\n' 'resolver.test;443 proxy' 'unqualified.test proxy' >"$tmpdir/rules.txt"
 gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\""
 assert_eq 0 "$rc" "$mode generation"
 jq -e '[.routing.rules[] | select((.ruleTag // "") | startswith("xraywrt-rule-")) | .inboundTag] == [["xraywrt-tproxy4","xraywrt-tproxy6"],null]' <<<"$out" >/dev/null || fail "$mode qualified site inbound scope"
done
pass 'qualified domains apply only to packet inbounds'

printf '%s\n' '1.2.3.4-1.2.3.9;443 direct' >"$tmpdir/rules.txt"
printf 'proxy\n' | xraywrt-json rules check "$tmpdir/rules.txt" >"$tmpdir/check"
grep -q 'bad_entry' "$tmpdir/check" || fail 'qualified IPv4 range rejected'
pass 'qualified mistyped IPv4 ranges rejected'

awk 'BEGIN { for (i = 0; i < 10001; i++) printf "10.%d.%d.%d;443;udp\n", int(i / 65536), int(i / 256) % 256, i % 256 }' >"$tmpdir/large"
printf '%s\n' 'https://list.test/large proxy' '10.0.0.1;443;udp direct' >"$tmpdir/rules.txt"
printf '{"https://list.test/large":"%s/large"}\n' "$tmpdir" >"$tmpdir/remote.json"
for mode in direct-first proxy-first; do
 gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/large\": \"$tmpdir/large\"}"
 assert_eq 0 "$rc" "$mode large generation"
 jq -e '[.routing.rules[] | select((.ruleTag // "") | startswith("xraywrt-rule-"))] | length == 0' <<<"$out" >/dev/null || fail "$mode oversized Xray run skipped"
 prof_has 'warn My rules: the rule "proxy" has more than 10000 addresses and is skipped'
 printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" >"$tmpdir/packet"
 assert_eq 'direct;ip;10.0.0.1;443;udp' "$(cat "$tmpdir/packet")" "$mode oversized nft run skipped, later direct retained"
done
printf '%s\n' 'https://list.test/large proxy' >"$tmpdir/rules.txt"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" >"$tmpdir/packet"
assert_true 'oversized-only policy disables legacy fallback' test -s "$tmpdir/packet"
pass 'oversized named run skipped by both renderers'
printf '%s\n' 'https://list.test/large proxy' 'https://list.test/large direct' >"$tmpdir/rules.txt"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" >"$tmpdir/packet"
grep -q '^direct;ip;10.0.0.1;443;udp$' "$tmpdir/packet" || fail 'skipped URL must not claim later direct URL'
pass 'oversized URL does not claim later direct URL'
printf '%s\n' '203.0.113.7;8443;udp core' '203.0.113.7 proxy' >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\""
jq -e '[.routing.rules[] | select(.outboundTag == "proxy" and (.ip // [] | index("203.0.113.7")) and (.inboundTag // [] | index("xraywrt-dns-internal")))] | length > 0' <<<"$out" >/dev/null || fail 'bare route retained for internal DNS after packet shadow'
pass 'bare route retained for internal DNS after packet shadow'
src_json '{"inbounds":[{"tag":"provider","protocol":"socks","port":1081,"sniffing":{"enabled":true,"destOverride":["http","tls"]}}],"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}]}'
printf '%s\n' '203.0.113.8;443;tcp proxy' '203.0.113.9;443;udp proxy' >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\""
jq -e '[.routing.rules[] | select(.outboundTag == "proxy") | .ip[]?] | (index("203.0.113.8") == null and index("203.0.113.9") != null)' <<<"$out" >/dev/null || fail 'sniff-overridden named TCP skipped, safe UDP retained'
prof_has 'warn My rules: qualified named address selectors incompatible with sniffing are skipped'
pass 'sniff-overridden named TCP skipped, safe UDP retained'
# Uppercase overrides and partially filtered cached URLs must leave fallback tuples eligible.
src_json '{"inbounds":[{"tag":"provider","protocol":"socks","port":1081,"sniffing":{"enabled":true,"destOverride":["TLS"]}}],"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}]}'
printf '%s\n' '203.0.113.10;443;tcp' '203.0.113.11;443;udp' >"$tmpdir/mixed"
printf '%s\n' 'https://list.test/mixed proxy' 'https://list.test/mixed direct' >"$tmpdir/rules.txt"
printf '{"https://list.test/mixed":"%s/mixed"}\n' "$tmpdir" >"$tmpdir/remote.json"
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/mixed\": \"$tmpdir/mixed\"}"
jq -e '[.routing.rules[] | select(.outboundTag == "proxy") | .ip[]?] | index("203.0.113.10") == null and index("203.0.113.11") != null' <<<"$out" >/dev/null || fail 'uppercase TLS filters only TCP'
grep -qx 'rules-sniff-skipped-target proxy' <<<"$prof" || fail 'profile identifies affected target'
XRAY_LOCATION_ASSET="$XRAY_TEST_ASSETS" "$XRAY_TEST_BIN" run -test -c "$tmpdir/out.json" >"$tmpdir/core.log" 2>&1 || fail "uppercase TLS real core: $(cat "$tmpdir/core.log")"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" "$tmpdir/out.json" >"$tmpdir/packet"
grep -q '^direct;ip;203.0.113.10;443;tcp$' "$tmpdir/packet" || fail 'filtered URL tuple permits direct fallback'
pass 'uppercase sniffing and partial URL fallback'
printf '%s\n' '203.0.113.12 proxy' '203.0.113.12 direct' 'https://list.test/large proxy' >"$tmpdir/rules.txt"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" >"$tmpdir/packet"
# Use the large cache for the unrelated capped run.
printf '{"https://list.test/large":"%s/large"}\n' "$tmpdir" >"$tmpdir/remote.json"
printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" >"$tmpdir/packet"
grep -q '^direct;ip;203.0.113.12;;$' "$tmpdir/packet" || fail 'legacy duplicate direct precedence after cap'
pass 'legacy duplicate precedence after cap'
src_json '{"dns":{"tag":"provider-dns","servers":[{"address":"192.0.2.53","tag":"resolver-dedicated"}]},"inbounds":[{"tag":"provider-listener","protocol":"socks","port":1081}],"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}]}'
printf '%s\n' '203.0.113.7;8443;udp core' '203.0.113.7 proxy' >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".rules_file = \"$tmpdir/rules.txt\""
jq -e '[.routing.rules[] | select(.outboundTag == "proxy" and (.ip // [] | index("203.0.113.7"))) | .inboundTag[]?] | (index("resolver-dedicated") != null and index("xraywrt-dns-internal") != null and index("provider-listener") != null)' <<<"$out" >/dev/null || fail 'carved bare route keeps resolver, internal and provider tags'
pass 'carved bare route keeps explicit resolver tags'

# Sniff-incompatible rows do not consume the named-run limit.
src_json '{"inbounds":[{"tag":"provider","protocol":"socks","port":1081,"sniffing":{"enabled":true,"destOverride":["TLS"]}}],"outbounds":[{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}]}'
awk 'BEGIN { for (i = 0; i < 10000; i++) printf "10.%d.%d.%d;443;tcp\n", int(i / 65536), int(i / 256) % 256, i % 256; print "203.0.113.200;443;udp" }' >"$tmpdir/mixed-limit"
printf '%s\n' 'https://list.test/mixed-limit proxy' >"$tmpdir/rules.txt"
printf '{"https://list.test/mixed-limit":"%s/mixed-limit"}\n' "$tmpdir" >"$tmpdir/remote.json"
for mode in direct-first proxy-first; do
 gen "$tmpdir/src.json" ".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {\"https://list.test/mixed-limit\": \"$tmpdir/mixed-limit\"}"
 assert_eq 0 "$rc" "$mode mixed limit generation"
 jq -e '[.routing.rules[] | select(.outboundTag == "proxy") | .ip[]?] | index("203.0.113.200") != null' <<<"$out" >/dev/null || fail "$mode safe UDP survives incompatible rows at limit"
 prof_has 'warn My rules: qualified named address selectors incompatible with sniffing are skipped'
 printf 'proxy\n' | xraywrt-json rules packet-addresses "$tmpdir/rules.txt" "$tmpdir/remote.json" "$tmpdir/out.json" >"$tmpdir/packet"
 grep -qx 'proxy;ip;203.0.113.200;443;udp' "$tmpdir/packet" || fail "$mode packet safe UDP survives incompatible rows at limit"
done
pass 'sniff filtering precedes unique run cap'

# Count reads directly: dedupe identical selectors only within each run.
cat >"$tmpdir/read-count.uc" <<'UCODE'
let gen = loadfile(getenv('XRAYWRT_LIB_DIR') + '/xray-config.uc')();
let reads = 0;
let text = 'https://list.test/a proxy\nhttps://list.test/a proxy\nhttps://list.test/a;443;udp proxy\nhttps://list.test/a direct\n';
let rows = gen.rule_packet_addresses(text, ['proxy'], {'https://list.test/a': 'cache'}, (path) => { reads++; return '203.0.113.1\n'; }, null);
print(reads, '\n');
UCODE
assert_eq 3 "$(ucode "$tmpdir/read-count.uc")" 'identical URL selectors read once per run, distinct selectors and later runs read again'
pass 'URL selector reads deduplicated per run'

printf '%s\n' 'recognized.example direct' >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".mode_override = true | .mode = \"proxy-first\" | .rules_file = \"$tmpdir/rules.txt\""
assert_eq 0 "$rc" 'uppercase sniff direct site generation'
prof_has 'sniff tls'
prof_lacks 'warn direct domains ignored: the provider config has no sniffing'
jq -e '[.routing.rules[] | select(.outboundTag == "xraywrt-direct") | .domain[]?] | index("domain:recognized.example") != null' <<<"$out" >/dev/null || fail 'uppercase TLS recognizes bare direct site'
jq -e '[.inbounds[] | select(.tag == "provider") | .sniffing.destOverride] == [["TLS"]]' <<<"$out" >/dev/null || fail 'provider sniffing is unchanged'
pass 'uppercase sniff profile recognizes direct sites without mutating provider'

# Exactly 10,000 distinct admissible tuples remain valid; 10,001 stop expansion.
cat >"$tmpdir/cap-boundary.uc" <<'UCODE'
let gen = loadfile(getenv('XRAYWRT_LIB_DIR') + '/xray-config.uc')();
let entries = [];
for (let i = 0; i < 10001; i++) push(entries, sprintf('10.%d.%d.%d;443;udp', int(i / 65536), int(i / 256) % 256, i % 256));
let reads = 0;
let remote = {'https://list.test/a': 'a', 'https://list.test/b': 'b'};
let text = 'https://list.test/a proxy\nhttps://list.test/b proxy\n';
let exact = gen.rule_packet_addresses(text, ['proxy'], remote, (p) => { reads++; return p == 'a' ? join('\n', slice(entries, 0, 10000)) : entries[0]; }, null);
if (length(exact) != 10000 || reads != 2) die('exact cap or duplicate handling failed\n');
reads = 0;
let over = gen.rule_packet_addresses(text, ['proxy'], remote, (p) => { reads++; return join('\n', entries); }, null);
if (reads != 1 || length(filter(over, (row) => row[0] == 'proxy'))) die('cap did not stop before next URL\n');
print('ok\n');
UCODE
assert_eq ok "$(ucode "$tmpdir/cap-boundary.uc")" 'unique cap boundary and early stop'
pass 'unique cap boundary and early stop'
