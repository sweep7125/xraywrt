#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
base="$ROOT_DIR/tests/fixtures/xray/out/single.proxy-first.json"
check_diff() {
 local expected="$1" filter="$2"
 jq "$filter" "$base" >"$tmpdir/new.json"
 assert_eq "$expected" "$(xraywrt-json diff "$base" "$tmpdir/new.json")" "$filter"
}
# adrules leaves the live router's domain strategy unchanged (pinned Go probe).
check_diff restart '.routing.domainStrategy = "IPIfNonMatch"'
check_diff restart '.routing.domainMatcher = "linear"'
check_diff restart '.routing.vendorExtension = true'
check_diff restart 'del(.routing.domainStrategy)'
check_diff hot '.outbounds[0].settings.vnext[0].port = 8443'
check_diff hot '.routing.rules += [{domain:["full:other.example"],outboundTag:"direct"}]'
check_diff hot '.routing.balancers = [{tag:"auto",selector:["proxy"],strategy:{type:"random"}}]'
check_diff hot '.outbounds += [{tag:"new",protocol:"freedom"}] | .routing.rules = []'
for section in dns inbounds api log fakedns observatory burstObservatory policy transport reverse geodata; do
 check_diff restart ".$section = {}"
done
check_diff restart '.outbounds[0].settings.vnext[0].port = 8443 | .dns.queryStrategy = "UseIPv4"'
check_diff restart '.vendorExtension = {value:1}'
check_diff restart '.vendorExtension = null'
check_diff restart '.routing.vendorExtension = null'
check_diff restart '.outbounds |= reverse'
check_diff restart 'del(.outbounds[0].tag)'
check_diff restart '.outbounds += [.outbounds[0]]'
check_diff restart '.outbounds[0].tag = "line\nbreak"'
check_diff hot '.'
# A renamed non-default handler is removed and re-added by tag with its rule.
check_diff hot '.outbounds[1].tag = "direct2" | .routing.rules[-1].outboundTag = "direct2"'
# Balancers sort candidate tags (outbound.Manager.Select), so order beyond the default is not semantic.
check_diff hot '.outbounds |= [.[0]] + (.[1:] | reverse)'
check_diff restart '.stats = {}'
# AddOutbound makes the first added handler the default after rmo dropped it.
jq '.outbounds[0].settings.vnext[0].port = 8443 | .outbounds += [{tag:"new",protocol:"freedom"}]' "$base" >"$tmpdir/new.json"
assert_eq hot "$(xraywrt-json diff "$base" "$tmpdir/new.json")" 'changed default plus a new handler'
xraywrt-json outbound-delta "$base" "$tmpdir/new.json" "$tmpdir/added.json" "$tmpdir/removed.json"
assert_eq 'proxy new' "$(jq -r '[.outbounds[].tag] | join(" ")' "$tmpdir/added.json")" 'default handler is added first'
assert_eq '{"outbounds":[{"tag":"proxy"}]}' "$(jq -c . "$tmpdir/removed.json")" 'changed default removed by tag'
# Object key order is not a semantic config change.
jq 'to_entries | reverse | from_entries' "$base" >"$tmpdir/reordered.json"
assert_eq hot "$(xraywrt-json diff "$base" "$tmpdir/reordered.json")" 'object key order ignored'
printf 'bad JSON\n' >"$tmpdir/bad.json"
assert_false 'bad runtime config cannot be hot-applied' xraywrt-json diff "$base" "$tmpdir/bad.json"
pass 'runtime section diff'
