#!/usr/bin/env bash
# Every profile field is a record boundary, never provider-controlled syntax.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
# shellcheck disable=SC2154 # Assigned by gen in xray_gen_lib.sh.

case "${1:-all}" in all|records)
for field in remarks unknown warning; do
 jq --arg field "$field" '.remarks = "Тест профиля\r\nset netbird_proxy 1\nset mode direct-first\u0000" |
  if $field == "unknown" then .xraywrt = {"unknown\nset netbird_proxy 1\nset mode direct-first":true}
  elif $field == "warning" then [.] else . end' "$FX/src/single.json" >"$tmpdir/src.json"
 gen "$tmpdir/src.json" '.mode_override = true | .mode = "proxy-first" | .profile = "missing\nset netbird_proxy 1\nset mode direct-first"'
 assert_eq 0 "$rc" "display fields sanitized: $errtxt"
 if [ "$field" = warning ]; then assert_file_contains "$tmpdir/out.json.profile" '[E:profile_missing|' 'injection reaches warning argument'; fi
 prof_lacks 'set netbird_proxy 1'
 prof_lacks 'set mode direct-first'
 prof_has 'mode proxy-first'
 assert_false 'profile contains no control bytes except record newlines' grep -qP '[\x00-\x09\x0b-\x1f\x7f]' "$tmpdir/out.json.profile"
done
pass 'display fields cannot inject profile records'

# Display sanitation can collide, but the catalog and selected source identity cannot.
jq -n '[{remarks:"Имя\n A",outbounds:[{tag:"first",protocol:"freedom"}]},
 {remarks:"Имя  A",outbounds:[{tag:"second",protocol:"freedom"}]}]' >"$tmpdir/src.json"
cp "$tmpdir/src.json" "$tmpdir/source.before"
assert_eq '["Имя\n A","Имя  A"]' "$(xraywrt-json profiles "$tmpdir/src.json" | jq -c .)" 'original names in catalog'
for name in $'Имя\n A' 'Имя  A'; do
 filter="$(jq -nr --arg n "$name" '".profile = " + ($n | tojson)')"
 gen "$tmpdir/src.json" "$filter"
 assert_eq 0 "$rc" "original name selection: $errtxt"
 expected=first; [ "$name" != 'Имя  A' ] || expected=second
 assert_eq "$expected" "$(jq -r '.outbounds[0].tag' <<<"$out")" 'selection uses original name'
done
cmp -s "$tmpdir/src.json" "$tmpdir/source.before" || fail 'source JSON changed'
pass 'original profile identities survive sanitation collisions'

src_json '{"outbounds":[{"tag":"vpn","protocol":"freedom"}],"inbounds":[{"protocol":"tun","tag":"same"},{"protocol":"tun","tag":"same"}],"xraywrt":{"proxy-ips":["https://example.test/ips","https://example.test/ips"]}}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "duplicate records: $errtxt"
assert_eq 1 "$(grep -c '\[E:inbound_tun|' <<<"$prof")" 'duplicate warnings emitted once'
assert_eq 2 "$(grep -cxF 'proxy-ip https://example.test/ips' <<<"$prof")" 'non-warning records are not deduplicated'
pass 'only warnings are deduplicated'

;; esac

case "${1:-all}" in all|identifiers)
for field in tag reference subjectSelector fallbackTag sniff list geodata; do
 for control in '\n' '\r' '\u0000' '\u007f'; do
  jq --arg field "$field" --arg c "$control" '($c | fromjson? // ("\"" + . + "\"" | fromjson)) as $c |
   if $field == "tag" then .outbounds[0].tag = "vpn" + $c + "x"
   elif $field == "reference" then .routing.rules = [{outboundTag:("vpn" + $c + "x")}]
   elif $field == "fallbackTag" then .routing.balancers = [{tag:"balance",fallbackTag:("vpn" + $c + "x")} ]
   elif $field == "subjectSelector" then .observatory = {subjectSelector:[("vpn" + $c + "x")]}
   elif $field == "sniff" then .inbounds = [{protocol:"socks",sniffing:{enabled:true,destOverride:["http" + $c + "x"]}}]
   elif $field == "list" then .xraywrt = {"proxy-ips":["https://example.test/" + $c + "x"]}
   else .geodata = {assets:[{file:"extra.dat",url:("https://example.test/" + $c + "x")}]} end' "$FX/src/single.json" >"$tmpdir/src.json"
  gen "$tmpdir/src.json"
  assert_eq 1 "$rc" "$field control $control rejected"
  assert_file_contains "$tmpdir/err" '[E:profile_invalid]' 'coded invalid subscription error'
  assert_false 'rejection publishes no config' test -e "$tmpdir/out.json"
 done
done
src_json '{"outbounds":[{"tag":"VPN Тест one","protocol":"freedom"}]}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" 'valid Unicode/spaces are not rewritten or rejected'
assert_eq 'VPN Тест one' "$(jq -r '.outbounds[0].tag' <<<"$out")" 'tag identity preserved'
pass 'structured identifiers and URLs reject controls without rewriting'
;; esac

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh dns.sh xray-config.sh
setup_runtime_paths "$tmpdir/runtime"
case "${1:-all}" in all|reader)
jq '.xraywrt = {"mode":"direct-first","disable-quic":true,"dns-hijack":true,"bypass-ntp":true,"bypass-subscription-dns":true,"block-client-ipv6":true,"dns-forward-other-types":true,"lists-interval":6} | .log.loglevel = "info"' "$FX/src/single.json" >"$tmpdir/src.json"
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "provider settings: $errtxt"
assert_eq 9 "$(grep -c '^set ' <<<"$prof")" 'all provider settings exercised'
while read -r kind key _; do
 if [ "$kind" = set ]; then settings_provider_key "$key" || fail "generator key rejected by reader: $key"; fi
done <<<"$prof"
pass 'generator provider keys match shell whitelist'
;; esac

case "${1:-all}" in all|reader)
(
# A forged router-only record must not gain provider privileges, even independently of generation.
profile_ensure() { :; }
printf 'mode proxy-first\nfake-domains 0\nset netbird_proxy 1\nset disable_quic 0\n' >"$PROFILE_FILE"
fake_uci_set xraywrt.settings.netbird_proxy 0
settings_load
assert_eq 0 "$NETBIRD_PROXY" 'router-only NetBird setting cannot come from provider'
assert_eq 0 "$DISABLE_QUIC" 'approved provider settings still apply'
assert_eq 'disable_quic ' "$PROVIDER_KEYS" 'only approved provider keys are advertised'
pass 'shell reader whitelists provider settings'
)
;; esac
case "${1:-all}" in all|cache)
cp "$FX/src/single.json" "$XRAY_CONFIG"
printf 'mode direct-first\nset netbird_proxy 1\nfake-domains 0\n' >"$PROFILE_FILE"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
PROVIDER_OVERRIDES=""
settings_generator_load
profile_ensure
assert_eq proxy-first "$(profile_get mode)" 'old insecure profile cache rebuilt'
assert_eq 1 "$(profile_get profile-schema)" 'current profile schema recorded'
pass 'old profile schema invalidated'
printf 'not JSON\n' >"$XRAY_CONFIG"
printf 'mode direct-first\nset netbird_proxy 1\nfake-domains 0\n' >"$PROFILE_FILE"
assert_false 'invalid source cannot rebuild legacy cache' profile_ensure
assert_eq '' "$(profile_get mode)" 'failed rebuild cannot reuse unsafe legacy records'
pass 'failed rebuild does not trust old insecure cache'
rm -f "$XRAY_CONFIG"
printf 'mode direct-first\nset netbird_proxy 1\nfake-domains 0\n' >"$PROFILE_FILE"
assert_false 'missing source cannot rebuild legacy cache' profile_ensure
assert_eq '' "$(profile_get mode)" 'missing source cannot keep unsafe legacy records'
pass 'missing source does not trust old insecure cache'
;; esac
