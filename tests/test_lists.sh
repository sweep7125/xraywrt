#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh xray-config.sh lists.sh service.sh
setup_runtime_paths "$tmpdir"


LIST_DIR="$tmpdir/lst"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
PKG_TMP_DIR="$tmpdir/tmp"
lists_ensure_files

# The provider's lists keep the full entry syntax (ports, comments): the generic
# checks of the classifier and the resolver run on them.
set_dst() { { echo 'has proxy-ips'; sed 's/^/proxy-ip /'; } >"$PROFILE_FILE"; }
printf '1.1.1.1 | 12\n' | set_dst
assert_eq '1.1.1.1|12' "$(lists_source dst)" "runtime keeps legacy pipe, making entry invalid"
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
[[ ! -s "$tmpdir/v4" && ! -s "$tmpdir/v6" ]] || fail "pipe entry must be invalid"
pass "lists runtime does not strip legacy suffix"

set_dst <<'L'
# comment
1.1.1.1
2001:db8::/32;443
;53
999.1.1.1
1.1.1.1
https://lists.example.com/a.txt;80
L
mkdir -p "$POLICY_CACHE_DIR"
printf '8.8.8.0/24\n2606:4700::1;8443\n' >"$(lists_cache_file https://lists.example.com/a.txt)"

stdout="$(lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null)"
assert_eq "" "$stdout" "resolve writes nothing to stdout (CLI output must stay JSON)"
assert_eq 3 "$(wc -l <"$tmpdir/v4" | tr -d ' ')" "v4 entries deduplicated"
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "remote entry inherits URL ports"
assert_file_contains "$tmpdir/v4" ";53" "port-only entry in v4"
assert_file_contains "$tmpdir/v6" "2001:db8::/32;443" "v6 entry"
assert_file_contains "$tmpdir/v6" "2606:4700::1;8443" "remote v6 keeps own ports"
assert_file_contains "$tmpdir/v6" ";53" "port-only entry in v6"
assert_file_not_contains "$tmpdir/v4" "999.1.1.1" "invalid entry skipped"
pass "mixed families resolved"

# Provider selectors retain transport and port conditions for both families.
printf '1.1.1.1;443;udp\n2001:db8::1;;tcp\n1.1.1.2;80-90;tcp\n1.1.1.3;443;sctp\n' | set_dst
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_eq $'1.1.1.1;443;udp\n1.1.1.2;80-90;tcp' "$(cat "$tmpdir/v4")" 'provider IPv4 transport selectors validated'
assert_eq '2001:db8::1;;tcp' "$(cat "$tmpdir/v6")" 'provider IPv6 all-port transport selector'
pass 'provider transport selectors'
assert_eq '1.1.1.1;443;udp' "$(printf '1.1.1.1;443;udp\n' | lists_classify 1 src)" 'device lists do not accept transport selectors'
printf 'https://lists.example.com/a.txt;80;udp\nhttps://lists.example.com/a.txt;;tcp\n' | set_dst
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_file_contains "$tmpdir/v4" '8.8.8.0/24;80;udp' 'remote address inherits UDP and ports'
assert_file_contains "$tmpdir/v6" '2606:4700::1;8443;udp' 'remote port override retains UDP'
assert_file_contains "$tmpdir/v6" '2606:4700::1;8443;tcp' 'same cache retains TCP selector'
pass 'remote transport inheritance'
(
 cache="$(lists_cache_file https://lists.example.com/a.txt)"
 cp "$cache" "$tmpdir/selector-cache-backup"
 printf '203.0.113.1;;tcp\n203.0.113.2;123;udp\n2001:db8::1;;tcp\n2001:db8::2;456;udp\n' >"$cache"
 printf 'https://lists.example.com/a.txt;;udp\n' | set_dst
 lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
 assert_eq '203.0.113.2;123;udp' "$(cat "$tmpdir/v4")" 'URL UDP excludes conflicting IPv4 TCP rows'
 assert_eq '2001:db8::2;456;udp' "$(cat "$tmpdir/v6")" 'URL UDP excludes conflicting IPv6 TCP rows'
 cp "$tmpdir/selector-cache-backup" "$cache"
)
pass 'URL transport constrains cached rows'
(
 mkdir -p "$tmpdir/inheritance-cache"
 POLICY_CACHE_DIR="$tmpdir/inheritance-cache"
 printf '203.0.113.2;;udp\n2001:db8::2;;udp\n' >"$(lists_cache_file https://lists.example.com/a.txt)"
 printf 'https://lists.example.com/a.txt;443;udp\n' | set_dst
 lists_resolve dst "$tmpdir/v4" "$tmpdir/v6"
 assert_eq '203.0.113.2;443;udp' "$(cat "$tmpdir/v4")" 'an explicit row protocol still inherits IPv4 URL ports'
 assert_eq '2001:db8::2;443;udp' "$(cat "$tmpdir/v6")" 'an explicit row protocol still inherits IPv6 URL ports'
)

printf 'https://lists.example.com/a.txt;80;invalid\n' | set_dst
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
[[ ! -s "$tmpdir/v4" && ! -s "$tmpdir/v6" ]] || fail 'invalid URL selector must not broaden cached entries'
printf 'https://lists.example.com/a.txt;80\n' | set_dst

http_fetch() {
	FETCH_ERROR=network
	return 1
}
LISTS_INTERVAL=0
assert_eq unchanged "$(lists_update_remote 0)" "cached list not due without interval"
if lists_update_remote 1 >/dev/null 2>&1; then
	fail "forced update with failing fetch must report failure"
fi
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_file_contains "$tmpdir/v4" "8.8.8.0/24;80" "cache used when fetch fails"
pass "remote cache used offline"

http_fetch() {
	printf '9.9.9.9\nnot-an-ip\n' >"$2"
}
assert_eq changed "$(lists_update_remote 1)" "fetched content changes cache"
assert_eq "9.9.9.9" "$(cat "$(lists_cache_file https://lists.example.com/a.txt)")" "cache keeps only valid entries"
assert_eq unchanged "$(lists_update_remote 1)" "same content is unchanged"
pass "remote update"

# An error page or empty body is not a list: the cache survives and the update fails.
cache="$(lists_cache_file https://lists.example.com/a.txt)"
for body in '' '<html>error</html>' '# only a comment'; do
	http_fetch() { printf '%s\n' "$body" >"$2"; }
	if lists_update_remote 1 >/dev/null 2>&1; then fail "empty remote list [$body] must count as a failure"; fi
	assert_eq "9.9.9.9" "$(cat "$cache")" "empty remote list [$body] keeps the cache"
done
pass "remote list without entries keeps the cache"

# Zero-padded numbers would reach nft as octal or hostnames: emit canonical decimals.
printf '010.000.000.001/032;00443\n::1/0128;0080-0090,0443\n;00080\n' | set_dst
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_eq "$(printf ';80\n10.0.0.1/32;443\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v4")" "v4 numbers normalized"
assert_eq "$(printf '::1/128;80-90,443\n;80\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v6")" "v6 prefix and ports normalized"
pass "list numbers normalized"

printf '10.0.0.1\n300.1.1.1\n2001:db8::1;443\n1:2:3:4:5:6::7\nfe80::1/64\n::ffff:1.2.3.4\n;80\nbad\n' | set_dst
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
assert_eq "$(printf ';80\n10.0.0.1\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v4")" "v4 classification"
assert_eq "$(printf '1:2:3:4:5:6::7\n2001:db8::1;443\n;80\nfe80::1/64\n' | LC_ALL=C sort)" "$(LC_ALL=C sort "$tmpdir/v6")" "v6 classification"
pass "bulk classification"

seq 1 20000 | awk '{ printf "10.%d.%d.0/24\n", int($1/256)%256, $1%256 }' | set_dst
start=$(date +%s)
lists_resolve dst "$tmpdir/v4" "$tmpdir/v6" 2>/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] || fail "20000 entries took ${elapsed}s (one fork per entry?)"
pass "large list resolves fast"

# The provider's lists are always used; My rules add to them: core and tag
# addresses join the list that goes to the core, direct ones the other list.
printf 'has proxy-ips\nproxy-ip 1.2.3.4\nhas direct-ips\nproxy-ip x\ndirect-ip 7.7.7.7\nrules-target proxy\n' >"$PROFILE_FILE"
printf '5.6.7.8 core\n9.9.9.0/24 proxy\n6.6.6.6 direct\n6.6.6.7 gone\nexample.org core\n' >"$RULES_FILE"
lists_resolve dst "$tmpdir/p4" "$tmpdir/p6"
assert_eq $'1.2.3.4\n5.6.7.8\n9.9.9.0/24' "$(cat "$tmpdir/p4")" 'provider list plus own core and tag addresses; no site, direct or unknown target'
POLICY_MODE=proxy-first
assert_eq $'7.7.7.7\n6.6.6.6' "$(lists_source direct)" 'proxy-first: provider direct list plus own direct addresses'
POLICY_MODE=direct-first
assert_eq 6.6.6.6 "$(lists_source direct)" 'direct-first: only own direct addresses bypass'
printf 'has proxy-ips\nproxy-ip 999.1.1.1\nproxy-ip https://p.example/l.txt\n' >"$PROFILE_FILE"
: >"$RULES_FILE"
warn() { echo "$*" >>"$tmpdir/warnings"; }
lists_resolve dst "$tmpdir/p4" "$tmpdir/p6"
assert_file_not_contains "$tmpdir/p4" 999.1.1.1 "invalid provider address dropped"
assert_file_contains "$tmpdir/warnings" 999.1.1.1 "invalid provider address warned"
assert_eq https://p.example/l.txt "$(lists_urls)" "provider URL fetched"
rm "$PROFILE_FILE"
printf '5.6.7.8 core\n' >"$RULES_FILE"
assert_eq 5.6.7.8 "$(lists_source dst)" "no provider uses own list"
assert_eq "$DIRECT_SRC_LIST_FILE" "$(lists_file direct_src)" "device kind"
assert_eq "$RULES_FILE" "$(lists_file rules)" "rules kind"
assert_false 'old dst kind is gone' lists_file dst
pass "provider lists and My rules"

# polish: filter keeps ips
(
 set -e
 filter_profile="$tmpdir/filter.profile"
 cat >"$filter_profile" <<'PROFILE'
proxy-ip 91.108.4.0/22
proxy-ip https://10.0.0.1/x.txt # rejected private host
proxy-ip https://p.example/x.txt;443
direct-ip http://p.example/y
PROFILE
 : >"$tmpdir/filter.warnings"
 warn() { echo "$*" >>"$tmpdir/filter.warnings"; }
 declare -F lists_profile_filter >/dev/null || fail 'lists_profile_filter helper missing'
 lists_profile_filter "$filter_profile"
 assert_eq $'proxy-ip 91.108.4.0/22\nproxy-ip https://p.example/x.txt;443' "$(cat "$filter_profile")" 'filter keeps ips and public https'
 assert_eq $'xraywrt: ignored list URL https://10.0.0.1/x.txt (only public https URLs)\nxraywrt: ignored list URL http://p.example/y (only public https URLs)' "$(cat "$tmpdir/filter.warnings")" 'exactly two filter warnings'
)
pass 'filter keeps ips'

# Provider URLs alone are restricted; own files retain the same URLs.
urls=(http://p.example/l.txt https://127.0.0.1/x https://10.1.2.3/x
 https://192.168.1.1/x https://169.254.1.1/x https://100.64.0.1/x
 'https://[::1]/x' 'https://[fd00::1]/x' 'https://[fe80::1]/x'
 https://localhost/x https://172.16.0.1/x 'https://[0:0:0:0:0:0:0:1]/x'
 https://127.1/x https://2130706433/x https://0x7f000001/x https://0x7f.0.0.1/x
 https://0177.0.0.1/x https://127.0.0.1./x
 ftp://p.example/l.txt 'https://%31%32%37.0.0.1/x'
 'https://[::ffff:7f00:1]/x' 'https://[0:0:0:0:0:ffff:808:808]/x'
 'https://[::808:808]/x')
for host in 0.1.2.3 10.0.0.1 100.64.0.1 100.127.255.255 127.0.0.1 \
 169.254.1.1 172.16.0.1 172.31.255.255 192.0.0.8 192.0.2.1 \
 192.88.99.1 192.168.1.1 198.18.0.1 198.19.255.255 198.51.100.1 \
 203.0.113.1 224.0.0.1 239.1.1.1 240.0.0.1 255.255.255.255 \
 '[::]' '[::1]' '[::ffff:10.0.0.1]' '[64:ff9b::102:304]' \
 '[fc00::1]' '[fd00::1]' '[fe80::1]' '[febf::1]' '[fec0::1]' '[feff::1]' '[ff02::1]'; do
 urls+=("https://$host/x")
done
for host in 1.1.1.1 100.63.255.255 100.128.0.1 172.32.0.1 192.0.1.1 \
 192.88.98.1 198.17.255.255 198.20.0.1 223.255.255.255 '[2606:4700::1111]'; do
 assert_true "public address URL allowed: $host" lists_provider_url_ok "https://$host/x"
done
for url in https://p.example/l.txt https://123.example/x https://8.8.8.8/x 'https://[2606:4700::1111]/x'; do
 assert_true "public https URL allowed: $url" lists_provider_url_ok "$url"
done
for url in "${urls[@]}"; do
 assert_false "provider URL rejected: $url" lists_provider_url_ok "$url"
done
assert_false 'fragment cannot spoof the URL host' lists_provider_url_ok 'https://127.0.0.1#@p.example/x'
printf 'has proxy-ips\nproxy-ip https://p.example/l.txt\n' >"$PROFILE_FILE"
printf 'proxy-ip %s\n' "${urls[@]}" >>"$PROFILE_FILE"
printf '%s core\n' "${urls[@]}" >"$RULES_FILE"
lists_profile_filter "$PROFILE_FILE"
assert_eq https://p.example/l.txt "$(lists_provider_entries dst)" 'provider URLs filtered'
for url in "${urls[@]}"; do
 assert_file_contains "$tmpdir/warnings" "xraywrt: ignored list URL $url (only public https URLs)" 'exact provider URL warning'
done
rm "$PROFILE_FILE"
assert_eq "$(printf '%s\n' "${urls[@]}" | grep -v '^ftp:')" "$(lists_source dst)" 'own URLs unrestricted; a link is http or https'
: >"$RULES_FILE"
pass 'provider url policy'

# Expanded and zero-padded IPv6 literals take the same range checks in both awks.
for awk_impl in default busybox; do
 (
  if [ "$awk_impl" = busybox ]; then awk() { busybox awk "$@"; }; fi
  for host in 192.0.0.0 192.0.0.255 192.0.2.0 192.0.2.255 \
   192.88.99.0 192.88.99.255 198.18.0.0 198.19.255.255 224.0.0.0 \
   '[0064:ff9b:0:0:0:0:102:304]' '[64:ff9b:0:0::102:304]' \
   '[fc00:0:0:0:0:0:0:1]' '[fdff::1]' '[fe80:0:0:0:0:0:0:1]' \
   '[febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff]' '[fec0:0:0:0:0:0:0:1]' \
   '[feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]' '[ff00::]' '[ffff::1]'; do
   assert_false "$awk_impl rejects reserved literal $host" lists_provider_url_ok "https://$host/x"
  done
  for host in 192.0.3.0 192.88.100.0 198.51.99.255 198.51.101.0 \
   203.0.112.255 203.0.114.0 '[64:ff9b::1:0:0]' '[64:ff9b:1::1]' \
   '[64:ff9c::1]' '[fbff::1]' '[fe00::1]' '[fe7f::1]'; do
   assert_true "$awk_impl allows adjacent public literal $host" lists_provider_url_ok "https://$host/x"
  done
 )
done
pass 'provider URL range edges and expanded IPv6'

printf '# Кириллица "quoted" \\path\r\n1.2.3.4 core\r\n\r\n' >"$RULES_FILE"
printf '# Устройства\n10.0.0.1\n' >"$SRC_LIST_FILE"
rm "$DIRECT_SRC_LIST_FILE"
json="$(lists_json)"
for kind in rules src; do
 file="$(lists_file "$kind")"
 jq -e --arg k "$kind" --rawfile content "$file" '.[$k] == $content' <<<"$json" >/dev/null || fail "exact JSON file text: $kind"
 jq -j --arg k "$kind" '.[$k]' <<<"$json" >"$tmpdir/json-$kind.txt"
 assert_true "lists-json byte-exact quotes, backslash and CRLF: $kind" cmp -s "$file" "$tmpdir/json-$kind.txt"
done
assert_eq '' "$(jq -r .direct_src <<<"$json")" 'missing list JSON is empty'
assert_eq 'direct_src rules src' "$(jq -r 'keys | join(" ")' <<<"$json")" 'lists-json carries only My rules and the device lists'
lists_ensure_files
pass 'lists-json exact texts'

# Three simultaneous local-list payloads exercise rawfile assembly, not argv limits.
awk 'BEGIN { for (i=0;i<1048576;i++) print "1.2.3.4" }' >"$RULES_FILE"
for file in "$SRC_LIST_FILE" "$DIRECT_SRC_LIST_FILE"; do cp "$RULES_FILE" "$file"; done
lists_json >"$tmpdir/three-lists.actual.json"
jq -nc --rawfile rules "$RULES_FILE" --rawfile src "$SRC_LIST_FILE" --rawfile direct_src "$DIRECT_SRC_LIST_FILE" \
 '{rules:$rules,src:$src,direct_src:$direct_src}' >"$tmpdir/three-lists.expected.json"
assert_true 'three 8 MiB lists byte parity' cmp -s "$tmpdir/three-lists.expected.json" "$tmpdir/three-lists.actual.json"
pass 'lists-json three simultaneous 8 MiB lists'

# Exercise the fetch limit through the real http_fetch, stubbing transport only.
load_modules fetch.sh
curl() {
 local out='' headers=''
 while [ "$#" -gt 0 ]; do
  case "$1" in
  -o) out="$2"; shift ;;
  -D) headers="$2"; shift ;;
  esac
  shift
 done
 cp "$tmpdir/remote" "$out"
 printf 'HTTP/1.1 200 OK\n\n' >"$headers"
}
printf 'https://size.example/list core\n' >"$RULES_FILE"
: >"$SRC_LIST_FILE"; : >"$DIRECT_SRC_LIST_FILE"
# http_fetch is defined by fetch.sh, replacing the earlier local fake.
awk 'BEGIN { for (i=0;i<115200;i++) print "9.9.9.9" }' >"$tmpdir/remote"
assert_eq changed "$(lists_update_remote 1)" '900 KiB remote list accepted'
cache="$(lists_cache_file https://size.example/list)"
cp "$cache" "$tmpdir/cache.before"
awk 'BEGIN { for (i=0;i<144180;i++) print "8.8.8.8" }' >"$tmpdir/remote"
assert_false '1.1 MiB remote rejected' lists_update_remote 1 >/dev/null
assert_file_contains "$tmpdir/warnings" '(too_large)' 'too_large remote error'
cmp -s "$cache" "$tmpdir/cache.before" || fail 'oversized remote keeps cache'
pass 'remote size'

# Without a readable profile, provider URLs are unknown: GC must fail open.
(
 setup_runtime_paths "$tmpdir/gc"
 POLICY_CACHE_DIR="$tmpdir/gc/cache"
 mkdir -p "$POLICY_CACHE_DIR"
 printf 'proxies: []\n' >"$XRAY_CONFIG"
 current="$(lists_cache_file https://provider.example/current)"
 removed="$(lists_cache_file https://provider.example/removed)"
 printf '1.1.1.1\n' >"$current"
 printf '9.9.9.9\n' >"$removed"
 cp "$current" "$tmpdir/gc/current.before"
 cp "$removed" "$tmpdir/gc/removed.before"
 profile_ensure() { return 1; }
 assert_false 'gc reports profile failure' lists_cache_gc
 assert_true 'gc skipped without profile: current cache untouched' cmp -s "$current" "$tmpdir/gc/current.before"
 assert_true 'gc skipped without profile: unused cache untouched' cmp -s "$removed" "$tmpdir/gc/removed.before"
 load_modules xray-config.sh
 printf 'profile-schema 1\nfake-enabled 0\nhas proxy-ips\nproxy-ip https://provider.example/current\n' >"$PROFILE_FILE"
 lists_cache_gc
 assert_true 'readable profile retains provider cache' cmp -s "$current" "$tmpdir/gc/current.before"
 assert_false 'readable profile permits unused cache cleanup' test -e "$removed"
)
pass 'gc skipped without profile'

# A failed URL hash must never delete caches or fetch to an empty path.
(
 setup_runtime_paths "$tmpdir/gc-hash"
 POLICY_CACHE_DIR="$tmpdir/gc-hash/cache"
 mkdir -p "$POLICY_CACHE_DIR"
 printf 'cached\n' >"$POLICY_CACHE_DIR/saved.txt"
 sha256sum() { return 1; }
 assert_false 'failed URL hash rejects GC' lists_cache_gc 'https://example.test/list'
 assert_true 'failed GC retains caches' test -f "$POLICY_CACHE_DIR/saved.txt"
 lists_cache_gc() { return 0; }
 http_fetch() { fail 'fetch called with no cache key'; }
 assert_false 'failed cache key rejects update' lists_update_remote 1 'https://example.test/list' >/dev/null 2>&1
 assert_true 'failed update retains caches' test -f "$POLICY_CACHE_DIR/saved.txt"
)
pass 'cache hash failure preserves lists and stops fetch'



printf 'https://current.example/a core\n' >"$RULES_FILE"
current="$(lists_cache_file https://current.example/a)"
removed="$(lists_cache_file https://removed.example/b)"
printf '1.1.1.1\n' >"$current"; cp "$current" "$removed"
LISTS_INTERVAL=0
lists_update_remote 0 >/dev/null
assert_true 'current cache kept' test -f "$current"
assert_false 'removed URL cache deleted' test -e "$removed"
for n in $(seq 1 33); do
 url="https://many.example/$n"
 printf '%s core\n' "$url"
 printf '1.1.1.1\n' >"$(lists_cache_file "$url")"
done >"$RULES_FILE"
lists_update_remote 0 >/dev/null
assert_true '33rd URL cache retained' test -f "$(lists_cache_file https://many.example/33)"
pass 'cache gc includes URLs beyond fetch cap'

# Apply only src; unchanged lists retain their timestamps and content.
with_lock() { "$@"; }
settings_load() { :; }
cron_update() { :; }
service_ready() { return 1; }
service_running() { return 1; }
upload="/tmp/xraywrt-policy-list.task8.$$"
printf '10.2.3.4\n' >"$upload"
printf '8.8.8.8 core\n' >"$RULES_FILE"
for kind in rules direct_src; do touch -d '2024-01-01 00:00:00' "$(lists_file "$kind")"; done
cp "$RULES_FILE" "$tmpdir/rules.before"
assert_eq '{"changed":true}' "$(lists_apply - "$upload" - | jq -c '{changed}')" 'partial apply updates src'
assert_eq 10.2.3.4 "$(cat "$SRC_LIST_FILE")" 'src replaced'
cmp -s "$RULES_FILE" "$tmpdir/rules.before" || fail 'rules kept'
for kind in rules direct_src; do
 assert_eq 1704067200 "$(stat -c %Y "$(lists_file "$kind")")" 'unchanged list mtime'
done
assert_eq '{"changed":false}' "$(lists_apply - - - | jq -c '{changed}')" 'all unchanged'
# My rules ride lists-json and the first apply-lists argument; a change regenerates the running core.
printf 'example.org core\n' >"$upload"
assert_eq '{"changed":true}' "$(lists_apply "$upload" - - | jq -c '{changed}')" 'rules applied'
assert_eq 'example.org core' "$(cat "$RULES_FILE")" 'rules installed as is'
assert_eq 'example.org core' "$(lists_json | jq -j .rules)" 'lists-json carries My rules'
assert_eq 10.2.3.4 "$(cat "$SRC_LIST_FILE")" 'device lists untouched by rules'
(
 service_ready() { return 0; }
 lists_update_remote() { :; }
 nft_apply_if_ready() { echo nft >>"$tmpdir/fake-reload.log"; }
 service_reload() { echo reload >>"$tmpdir/fake-reload.log"; }
 printf 'example.com direct\n' >"$upload"
 lists_apply "$upload" - - >/dev/null
 printf 'example.com direct\n' >"$upload"
 lists_apply "$upload" - - >/dev/null
 lists_apply - "$tmpdir/none" - >/dev/null 2>&1 || :
)
assert_eq $'reload\nnft' "$(cat "$tmpdir/fake-reload.log")" 'a changed My rules regenerates the running core; an unchanged one only the firewall'
awk 'BEGIN { for (i=0;i<70000;i++) print "example.com core" }' >"$upload"
assert_false 'oversize rules rejected' lists_apply "$upload" - - 2>"$tmpdir/rules.err"
assert_file_contains "$tmpdir/rules.err" 'List rules is larger than 1 MiB.' 'rules size error'
awk 'BEGIN { for (i=0;i<144180;i++) print "8.8.8.8" }' >"$upload"
assert_false 'oversize own list rejected' lists_apply - "$upload" - 2>"$tmpdir/own.err"
assert_file_contains "$tmpdir/own.err" 'List src is larger than 1 MiB.' 'exact own size error'
assert_eq 10.2.3.4 "$(cat "$SRC_LIST_FILE")" 'oversize upload keeps installed list'
victim="$(mktemp /tmp/somefile.XXXXXX)"
assert_false 'apply-lists rejects foreign path' lists_apply "$victim" - - 2>/dev/null
assert_true 'rejected path is not deleted' test -f "$victim"
rm -f "$victim"
pass 'partial apply and own size'

# My rules are checked before anything is installed: the error names the line and the targets.
printf 'profile-schema 1\nfake-enabled 0\nrules-target proxy\nrules-target pool\n' >"$PROFILE_FILE"
printf 'old.example core\n' >"$RULES_FILE"
rules_check() {
 printf '%s' "$1" >"$upload"
 assert_false "rules rejected: $2" lists_apply "$upload" - - >"$tmpdir/rules.out" 2>"$tmpdir/rules.err"
 assert_file_contains "$tmpdir/rules.err" "$3" "rules error: $2"
 assert_eq 'old.example core' "$(cat "$RULES_FILE")" "rules kept after: $2"
}
rules_check $'a.example;443;sctp proxy\n' 'invalid domain protocol' '[E:rules_bad_entry|1|a.example;443;sctp proxy]'
rules_check $'a.example;443;udp core\n' 'qualified domain core' '[E:rules_qualified_domain_core|1|a.example;443;udp core]'
rules_check $'a.example direct\nb.example\n' 'no target' '[E:rules_no_target|2|b.example|direct, core, proxy, pool]'
rules_check $'a.example gone\n' 'unknown target' '[E:rules_unknown_target|1|a.example gone|gone|direct, core, proxy, pool]'
rules_check $'a.example direct\n\n1.2.3.4;443-80 direct\n' 'inverted port range' '[E:rules_bad_entry|3|1.2.3.4;443-80 direct]'
rules_check $'a.example proxy extra\n' 'extra word' '[E:rules_bad_entry|1|a.example proxy extra]'
rules_check $'bad host direct\n' 'bad site' '[E:rules_bad_entry|1|bad host direct]'
rules_check $'aa:bb:cc:dd:ee:ff core\n' 'a MAC is not an address of My rules' '[E:rules_bad_entry|1|aa:bb:cc:dd:ee:ff core]'
rules_check $'https://youtube.com direct\n' 'a site address is not a list link' '[E:rules_bad_entry|1|https://youtube.com direct]'
rules_check $'https://youtube.com/ direct\n' 'a link without a path is not a list link' '[E:rules_bad_entry|1|https://youtube.com/ direct]'
rules_check $'1.2.3.4-1.2.3.9 direct\n' 'an address range is not a site' '[E:rules_bad_entry|1|1.2.3.4-1.2.3.9 direct]'
# The targets are read from a profile built with the saved settings, so they load first.
(
 settings_load() { echo load >>"$tmpdir/order"; }
 profile_ensure() { echo ensure >>"$tmpdir/order"; return 0; }
 : >"$tmpdir/order"
 printf 'a.example direct\n' >"$upload"
 lists_apply "$upload" - - >/dev/null
 assert_eq $'load\nensure' "$(head -n 2 "$tmpdir/order")" 'settings load before the profile is built'
)
# direct and core are reserved: they stay valid even when the configuration has a tag of that name.
printf 'profile-schema 1\nfake-enabled 0\nrules-target proxy\nrules-reserved direct\n' >"$PROFILE_FILE"
printf '# comment\nexample.com direct\nexample.org core\nexample.net proxy # trailing\n1.2.3.0/24 direct\n2001:db8::/32 core\nhttps://list.example/a.txt proxy\n' >"$upload"
assert_eq '{"changed":true}' "$(lists_apply "$upload" - - | jq -c '{changed}')" 'valid rules accepted'
{ for i in $(seq 1 10001); do echo "h$i.example core"; done; } >"$upload"
assert_false 'too many sites rejected' lists_apply "$upload" - - 2>"$tmpdir/rules.err"
assert_file_contains "$tmpdir/rules.err" '[E:rules_too_many|10000]' 'site limit error'
rm -f "$PROFILE_FILE"
pass 'My rules are validated on save'

# Both successful and failed list URLs release their response headers.
lists_urls() {
 case "$outcome" in
 success) echo https://ok.example/list ;;
 failure) echo https://fail.example/list ;;
 mixed) printf '%s\n' https://ok.example/list https://fail.example/list ;;
 esac
}
http_fetch() {
 FETCH_HDR=""
 case "$1" in
 *fail.example*) FETCH_ERROR=network; return 1 ;;
 *) echo 9.9.9.9 >"$2" ;;
 esac
}
for outcome in success failure mixed; do
 if [ "$outcome" = success ]; then
  lists_update_remote 1 >/dev/null
 else
  assert_false "$outcome list update reports failure" lists_update_remote 1 >/dev/null 2>&1
 fi
 assert_eq "" "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" "no header files left after $outcome list fetches"
done
pass 'list response headers cleaned'

assert_eq 'mac aa:bb:cc:dd:ee:ff' "$(printf 'AA:BB:CC:DD:EE:FF\n' | lists_classify)" 'classify mac lower-case'
for entry in aa-bb-cc-dd-ee-ff aa:bb:cc:dd:ee 'aa:bb:cc:dd:ee:ff;443' 'aa:bb:cc:dd:ee:ff;' 'aa:bb:cc:dd:ee:ff/48'; do
 assert_eq "$entry" "$(printf '%s\n' "$entry" | lists_classify 1)" "invalid MAC: $entry"
done
# Exercise the classifier with the actual BusyBox awk as well as the default awk.
( awk() { busybox awk "$@"; }; assert_eq 'mac aa:bb:cc:dd:ee:ff' "$(printf 'AA:BB:CC:DD:EE:FF\n' | lists_classify)" 'BusyBox classifies MAC' )
pass 'classify mac'
for kind in src direct_src; do
 printf 'AA:BB:CC:DD:EE:FF # Device\n10.2.3.4\n' >"$upload"
 args=(- - -)
 if [ "$kind" = src ]; then args[1]="$upload"; else args[2]="$upload"; fi
 assert_eq '{"changed":true}' "$(lists_apply "${args[@]}" | jq -c '{changed}')" 'MAC accepted in device list'
 assert_file_contains "$(lists_file "$kind")" 'aa:bb:cc:dd:ee:ff # Device' 'MAC stored lower-case, comment retained'
 lists_resolve "$kind" "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
 assert_eq aa:bb:cc:dd:ee:ff "$(cat "$tmpdir/mac")" 'MAC resolved separately'
 assert_eq 10.2.3.4 "$(cat "$tmpdir/m4")" 'MAC not in IPv4 output'
done
printf 'AA:BB:CC:DD:EE:FF\n' >"$(lists_cache_file https://mac.example/list)"
for kind in src direct_src; do
 printf 'https://mac.example/list\naa:bb:cc:dd:ee:ff\n' >"$(lists_file "$kind")"
 lists_resolve "$kind" "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
 assert_eq aa:bb:cc:dd:ee:ff "$(cat "$tmpdir/mac")" 'remote and own MACs deduplicated'
done
for kind in dst direct; do
 printf 'https://mac.example/list core\n' >"$RULES_FILE"
 [ "$kind" = dst ] || printf 'https://mac.example/list direct\n' >"$RULES_FILE"
 lists_resolve "$kind" "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
 assert_eq '' "$(cat "$tmpdir/mac")" 'address lists exclude remote MACs'
done
printf 'has proxy-ips\nproxy-ip aa:bb:cc:dd:ee:ff\n' >"$PROFILE_FILE"
: >"$RULES_FILE"
lists_resolve dst "$tmpdir/m4" "$tmpdir/m6" "$tmpdir/mac"
assert_eq '' "$(cat "$tmpdir/mac")" 'provider destination MAC excluded'
pass 'mac only in device lists'

(
 upload="/tmp/xraywrt-policy-list.huge.$$"
 trap 'rm -f "$upload"' EXIT
 awk 'BEGIN { for (i=0;i<30;i++) printf "%0300d\n", i }' >"$upload"
 assert_false 'invalid examples rejected' lists_install - "$upload" - 2>"$tmpdir/examples.err"
 assert_true 'invalid examples bounded' test "$(wc -c <"$tmpdir/examples.err")" -le 4096
 assert_file_contains "$tmpdir/examples.err" '(30 total)' 'invalid total retained'
)
pass 'invalid list examples bounded with total'

(
 first="/tmp/xraywrt-policy-list.first.$$"
 second="/tmp/xraywrt-policy-list.second.$$"
 trap 'rm -f "$first" "$second"' EXIT
 printf '1.2.3.4 core\n' >"$first"; printf '5.6.7.8\n' >"$second"
 cp "$RULES_FILE" "$tmpdir/first.before"
 cp() { [ "$1" != "$second" ] || { printf partial >"$2"; return 1; }; command cp "$@"; }
 assert_false 'second staging copy fails install' lists_install "$first" "$second" - >"$tmpdir/install.out"
 assert_true 'first list not published before second staged' cmp -s "$RULES_FILE" "$tmpdir/first.before"
 assert_eq '' "$(find "$LIST_DIR" -name '*.new.*')" 'all staged lists cleaned'
)
pass 'list staging failure preserves published lists'

(
 upload="/tmp/xraywrt-policy-list.utf8.$$"
 trap 'rm -f "$upload"' EXIT
 printf '%089dЖ\n' 0 >"$upload"
 assert_false 'Cyrillic invalid entry rejected' lists_install - "$upload" - 2>"$tmpdir/utf8-list.err"
 xraywrt-json build object --arg error "$(cat "$tmpdir/utf8-list.err")" >"$tmpdir/utf8-list.json"
 node - "$tmpdir/utf8-list.json" <<'NODE'
const fs = require('fs');
const text = new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(process.argv[2]));
const data = JSON.parse(text);
if (!data.error.includes('0'.repeat(89)) || !data.error.includes('(1 total)'))
 throw new Error('invalid list diagnostic lost');
NODE
)
pass 'byte-cut UTF-8 list example survives real JSON consumer'

(
 uploads=()
 trap 'rm -f "${uploads[@]}"' EXIT
 n=0
 for kind in rules src direct_src; do
  n=$((n + 1))
  uploads+=("/tmp/xraywrt-policy-list.rename-$kind.$$")
  if [ "$kind" = rules ]; then printf '192.0.2.%s core\n' "$n" >"${uploads[n-1]}"; else printf '192.0.2.%s\n' "$n" >"${uploads[n-1]}"; fi
  printf '198.51.100.%s\n' "$n" >"$(lists_file "$kind")"
 done
 mv() {
  [ "$3" != "$SRC_LIST_FILE" ] || return 1
  command mv "$@"
 }
 rc=0
 lists_install "${uploads[@]}" >"$tmpdir/rename.out" || rc=$?
 assert_eq 1 "$rc" 'second list rename failure returns 1'
 assert_true 'first list published before rename failure' cmp -s "${uploads[0]}" "$RULES_FILE"
 assert_eq 198.51.100.2 "$(cat "$SRC_LIST_FILE")" 'failed second rename preserves previous list'
 assert_eq '' "$(find "$tmpdir" -name '*.new.*')" 'rename failure removes remaining stages'
 unset -f mv
 assert_eq 1 "$(lists_install "${uploads[@]}")" 'following refresh publishes remaining changes'
 n=0
 for kind in rules src direct_src; do
  assert_true "following refresh heals $kind" cmp -s "${uploads[n]}" "$(lists_file "$kind")"
  n=$((n + 1))
 done
 assert_eq '' "$(find "$tmpdir" -name '*.new.*')" 'successful retry leaves no stages'
)
pass 'list rename failure cleans stages and following refresh self-heals'

# An interrupted publisher leaves stages for any kind, including omitted uploads.
for kind in rules src direct_src; do
 printf 'orphaned\n' >"$(lists_file "$kind").new.12345"
done
assert_eq '{"changed":false}' "$(lists_apply - - - | jq -c '{changed}')" 'refresh without edits sweeps orphaned stages'
for kind in rules src direct_src; do
 assert_false "interrupted $kind stage removed" test -e "$(lists_file "$kind").new.12345"
done
pass 'interrupted list publication stages swept'

# Fetched lists: only a list that feeds a routing rule (tag target) rebuilds the config.
(
 service_reload() { echo reload >>"$tmpdir/policy.log"; }
 nft_apply_if_ready() { echo nft >>"$tmpdir/policy.log"; }
 printf 'profile-schema 1\nrules-target proxy\n' >"$PROFILE_FILE"
 for body in 'https://a.example/l core' 'https://a.example/l direct' 'https://a.example/l proxy' 'https://a.example/l gone'; do
  printf '%s\n' "$body" >"$RULES_FILE"
  lists_policy_apply
 done
 assert_eq $'nft\nnft\nreload\nnft' "$(cat "$tmpdir/policy.log")" 'only a link with a tag target rebuilds the config'
)
pass 'changed remote lists rebuild the config only for tag targets'
