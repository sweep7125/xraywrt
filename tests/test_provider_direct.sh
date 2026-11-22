#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
printf 'example.com direct\n' >"$tmpdir/rules.txt"
filter='.mode_override = true | .mode = "direct-first" | .rules_file = "'"$tmpdir"'/rules.txt"'
for strategy in ForceIP ForceIPv4 ForceIPv6; do
 src_json '{"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"DiReCt","protocol":"freedom","streamSettings":{"sockopt":{"domainStrategy":"'"$strategy"'"}}}],"dns":{"servers":[{"address":"fakedns","domains":["domain:a.test"]}]}}'
 gen "$tmpdir/src.json" "$filter"
 assert_eq 0 "$rc" "generation: $errtxt"
 assert_eq DiReCt "$(jq -r '.routing.rules[] | select(.inboundTag == ["xraywrt-fakeip-direct"]) | .outboundTag' <<<"$out")" 'fakeip uses provider'
 assert_eq DiReCt "$(jq -r '.routing.rules[] | select(.ruleTag == "xraywrt-rule-1") | .outboundTag' <<<"$out")" 'personal rule uses provider'
 assert_eq xraywrt-direct "$(jq -r '.routing.rules[] | select(.inboundTag == ["xraywrt-dns-internal"] and .port == 53) | .outboundTag' <<<"$out")" 'bootstrap retains fallback'
done
pass 'provider DIRECT reuse'
# Target strategy overrides legacy freedom, which overrides socket strategy.
for row in \
 '{"targetStrategy":"ForceIPv4","settings":{"domainStrategy":"UseIP"},"streamSettings":{"sockopt":{"domainStrategy":"AsIs"}}}|DiReCt' \
 '{"targetStrategy":"UseIP","settings":{"domainStrategy":"ForceIP"},"streamSettings":{"sockopt":{"domainStrategy":"ForceIP"}}}|DiReCt' \
 '{"settings":{"domainStrategy":"ForceIP"},"streamSettings":{"sockopt":{"domainStrategy":"AsIs"}}}|DiReCt' \
 '{"settings":{"domainStrategy":"UseIP"},"streamSettings":{"sockopt":{"domainStrategy":"ForceIP"}}}|DiReCt' \
 '{"streamSettings":{"sockopt":{"domainStrategy":"UseIPv4"}}}|DiReCt' \
 '{}|DiReCt' \
 '{"targetStrategy":"ForceIP","proxySettings":{"tag":"proxy"}}|DiReCt' \
 '{"targetStrategy":"ForceIP","streamSettings":{"sockopt":{"dialerProxy":"proxy"}}}|DiReCt'; do
 config=${row%|*}; expected=${row##*|}
 jq -n --argjson extra "$config" '{outbounds:[{tag:"proxy",protocol:"vless"},({tag:"DiReCt",protocol:"freedom"} + $extra)],dns:{servers:[{address:"fakedns",domains:["domain:a.test"]}]}}' >"$tmpdir/src.json"
 gen "$tmpdir/src.json" "$filter"
 assert_eq 0 "$rc" "precedence generation: $errtxt"
 assert_eq "$expected" "$(jq -r '.routing.rules[] | select(.inboundTag == ["xraywrt-fakeip-direct"]) | .outboundTag' <<<"$out")" "effective strategy: $config"
done
src_json '{"outbounds":[{"tag":"direct","protocol":"freedom","targetStrategy":"ForceIP"},{"tag":"DIRECT","protocol":"freedom","targetStrategy":"ForceIP"}],"dns":{"servers":[{"address":"fakedns","domains":["domain:a.test"]}]}}'
gen "$tmpdir/src.json" "$filter"
assert_eq xraywrt-direct "$(jq -r '.routing.rules[] | select(.inboundTag == ["xraywrt-fakeip-direct"]) | .outboundTag' <<<"$out")" 'ambiguous tags retain fallback'
pass 'provider DIRECT precedence and exclusions'
src_json '{"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"DIRECT","protocol":"freedom","targetStrategy":"ForceIP","settings":{"redirect":"198.51.100.5:443","custom":"kept"},"streamSettings":{"sockopt":{"happyEyeballs":{"tryDelayMs":250}}}}],"routing":{"balancers":[{"tag":"pool","selector":["xraywrt-d"]}]},"dns":{"servers":[{"address":"fakedns","domains":["domain:a.test"]}]}}'
gen "$tmpdir/src.json" "$filter"
assert_eq 0 "$rc" "provider options generation: $errtxt"
jq -e '.outbounds[] | select(.tag == "DIRECT") | .targetStrategy == "ForceIP" and .settings.redirect == "198.51.100.5:443" and .settings.custom == "kept" and .streamSettings.sockopt.happyEyeballs.tryDelayMs == 250 and .streamSettings.sockopt.mark == 2' <<<"$out" >/dev/null || fail 'provider options preserved'
jq -e '[.outbounds[] | select(.tag == "xraywrt-direct")] | length == 1 and .[0].streamSettings.sockopt == {domainStrategy:"ForceIP",mark:2}' <<<"$out" >/dev/null || fail 'legacy prefix and bootstrap retain unmodified fallback'
pass 'provider options and legacy selector'
# The tag, not protocol or chaining, selects the provider outbound.
src_json '{"outbounds":[{"tag":"proxy","protocol":"vless"},{"tag":"DIRECT","protocol":"socks","proxySettings":{"tag":"proxy"}}],"dns":{"servers":["fakedns"]}}'
gen "$tmpdir/src.json" "$filter"
assert_eq 0 "$rc" "chained DIRECT generation: $errtxt"
jq -e '[.routing.rules[] | select(.ruleTag == "xraywrt-rule-1" or .ruleTag == "xraywrt-rule-1-service")] == [{domain:["domain:example.com"],inboundTag:["xraywrt-tproxy4","xraywrt-tproxy6"],outboundTag:"DIRECT",ruleTag:"xraywrt-rule-1"},{domain:["domain:example.com"],outboundTag:"xraywrt-direct",ruleTag:"xraywrt-rule-1-service"}]' <<<"$out" >/dev/null || fail 'client and service rules retain first-match order'
pass 'chained provider DIRECT and service route'
