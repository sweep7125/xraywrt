#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh fetch.sh subscription.sh
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
PKG_PERSIST_DIR="$tmpdir/etc"
PKG_STATE_DIR="$tmpdir/run"
SUBSCRIPTION_META_FILE="$tmpdir/etc/subscription.json"
mkdir -p "$PKG_STATE_DIR"

subscription_set_fixture() {
 fake_uci_reset
 set_active_subscription https://same.example/sub
 fake_uci_set xraywrt.settings.subscription_auto_update 1
 : >"$tmpdir/set.calls"
 uci() {
  case " $* " in *' commit '*) echo commit >>"$tmpdir/set.calls" ;; *' set '*) echo set >>"$tmpdir/set.calls" ;; esac
  command uci "$@"
 }
 cron_update() { echo cron >>"$tmpdir/set.calls"; }
 dns_apply() { echo dns >>"$tmpdir/set.calls"; }
}

# polish: set unchanged skips commit
(
 set -e
 subscription_set_fixture
 subscription_set https://same.example/sub 1 || fail 'unchanged setter must succeed'
 assert_eq '' "$(cat "$tmpdir/set.calls")" 'set unchanged skips commit, writes, cron and DNS'
)
pass 'set unchanged skips commit'

# A changed flag commits once; another link is refused (use add/delete-subscription).
(
 set -e
 subscription_set_fixture
 subscription_set https://same.example/sub 0 || fail 'changed setter must succeed'
 assert_eq 1 "$(grep -c '^commit$' "$tmpdir/set.calls")" 'changed flag commits once'
 assert_false 'another link refused' subscription_set https://changed.example/sub 0 2>/dev/null
)
fake_uci_reset
pass 'changed flag commits once'

# curl stub: logs args, writes $CURL_BODY to -o and $CURL_HEADERS to -D.
cat >"$tmpdir/bin/curl" <<'C'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
out="" hdr=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift ;;
	-D) hdr="$2"; shift ;;
	esac
	shift
done
printf '%b' "${CURL_HEADERS:-HTTP/1.1 200 OK\r\n}" >"$hdr"
printf '%s' "${CURL_BODY:-}" >"$out"
printf '%s' "${CURL_STDERR:-}" >&2
exit "${CURL_EXIT:-0}"
C
chmod +x "$tmpdir/bin/curl"
export CURL_LOG="$tmpdir/curl.log"
mkdir -p "$PKG_PERSIST_DIR"
echo 0123456789abcdef >"$PKG_PERSIST_DIR/hwid"

: >"$CURL_LOG"
CURL_BODY=data http_fetch http://example.com/s "$tmpdir/o" 100 10 1 || fail "http fetch"
assert_file_not_contains "$CURL_LOG" "x-hwid" "no device headers over http"
pass "no hwid on http"

: >"$CURL_LOG"
CURL_BODY=data http_fetch https://example.com/s "$tmpdir/o" 100 10 1 || fail "https fetch"
assert_file_contains "$CURL_LOG" "x-hwid: 0123456789abcdef" "stored hwid sent over https"
assert_file_contains "$CURL_LOG" "--proto-redir =https" "redirects limited to https"
assert_file_contains "$CURL_LOG" "--max-filesize 100" "size limit passed to curl"
assert_file_contains "$CURL_LOG" "Accept: application/json" "subscription asks for Xray JSON"
pass "hwid on https"

# Geodata files (up to 64 MB) get a stall limit and a total limit of 30 minutes with no curl retry (the caller tries every route); core packages have no total limit.
: >"$CURL_LOG"
CURL_BODY=data http_fetch https://example.com/g.dat "$tmpdir/o" 100 geodata 0 || fail "geodata fetch"
assert_file_contains "$CURL_LOG" '--speed-limit 2048 --speed-time 60 --max-time 1800' 'geodata fetch is bounded in total time'
: >"$CURL_LOG"
CURL_BODY=data http_fetch https://example.com/c.apk "$tmpdir/o" 100 core 0 || fail "core fetch"
assert_file_not_contains "$CURL_LOG" '--max-time' 'core package fetch keeps no total limit'
pass 'geodata fetch has a total time limit'

# Device identity is opt-in even over HTTPS.
: >"$CURL_LOG"
CURL_BODY=data http_fetch https://example.com/s "$tmpdir/o" 100 10 0 || fail "https without device headers"
assert_file_not_contains "$CURL_LOG" "x-hwid" "no device headers when disabled"
assert_file_not_contains "$CURL_LOG" "Accept:" "Accept header only for subscriptions"
assert_eq 1 "$(wc -l <"$CURL_LOG" | tr -d ' ')" "one curl per fetch"
pass 'device headers https only'

# Omitted headers are owned by http_fetch on both success and failure.
for curl_exit in 0 7 22 63; do
 rm -f "$PKG_TMP_DIR"/fetch.headers.*
 if CURL_EXIT="$curl_exit" CURL_BODY=data http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then
  assert_eq 0 "$curl_exit" 'only successful curl succeeds'
 else
  assert_false 'curl failure reported' test "$curl_exit" = 0
 fi
 assert_eq '' "$FETCH_HDR" 'no retained header path without file'
 assert_eq '' "$(find "$PKG_TMP_DIR" -name 'fetch.headers.*')" 'temporary headers removed'
done
pass 'headers removed without file'

for curl_exit in 0 7; do
 headers_file="$PKG_TMP_DIR/kept headers"
 if CURL_EXIT="$curl_exit" CURL_BODY=data http_fetch https://example.com/s "$tmpdir/o" 100 10 0 "$headers_file"; then
  assert_eq 0 "$curl_exit" 'explicit headers success'
 else
  assert_eq 7 "$curl_exit" 'explicit headers failure'
 fi
 assert_eq "$headers_file" "$FETCH_HDR" 'explicit header path retained'
 assert_file_contains "$headers_file" 'HTTP/1.1 200 OK' 'explicit headers kept'
 rm -f "$headers_file"
done
pass 'headers kept with file'

if CURL_BODY="$(printf 'x%.0s' {1..101})" http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then
	fail "oversize body must fail"
fi
assert_eq too_large "$FETCH_ERROR" "oversize error kind"
[[ ! -e "$tmpdir/o" ]] || fail "partial output removed"
if CURL_EXIT=63 http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then fail "curl 63 must fail"; fi
assert_eq too_large "$FETCH_ERROR" "curl max-filesize exit"
if CURL_EXIT=22 CURL_HEADERS='HTTP/1.1 403 Forbidden\r\n' http_fetch https://example.com/s "$tmpdir/o" 100 10 0; then fail "403 must fail"; fi
assert_eq http_403 "$FETCH_ERROR" "http error kind"
if CURL_STDERR='curl: private diagnostic' CURL_EXIT=7 http_fetch https://example.com/s "$tmpdir/o" 100 10 0 2>"$tmpdir/curl.err"; then fail "network failure must fail"; fi
assert_eq '' "$(cat "$tmpdir/curl.err")" 'curl stderr suppressed'
pass "fetch errors"

assert_eq "Личная 🚀" "$(subscription_decode_metadata_value 'base64:0JvQuNGH0L3QsNGPIPCfmoA=')" "UTF-8 decoded"
assert_eq "abc" "$(subscription_decode_metadata_value 'base64:YWJj')" "unpadded quartet"
assert_eq "plain text" "$(subscription_decode_metadata_value 'plain text')" "plain text kept"
assert_eq "" "$(subscription_decode_metadata_value 'base64:YWJj====')" "malformed padding dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64:YQBi')" "NUL byte dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64://4=')" "non-UTF-8 dropped"
assert_eq "" "$(subscription_decode_metadata_value 'base64:???')" "invalid chars dropped"
pass "base64 metadata"

CURL_HEADERS='HTTP/1.1 302 Found\r\nprofile-title: old\r\n\r\nHTTP/1.1 200 OK\r\nProfile-Title: base64:0JvQuNGH0L3QsNGPIPCfmoA=\r\nsubscription-userinfo: upload=1; download=2; expire=1700000000\r\nprofile-update-interval: 12\r\n' \
	CURL_BODY=x http_fetch https://example.com/s "$tmpdir/o" 100 10 0 "$PKG_TMP_DIR/metadata.headers"
meta="$(subscription_metadata_from_headers)"
assert_eq "Личная 🚀" "$(jq -r .profile_title <<<"$meta")" "title from last redirect block"
assert_eq "null" "$(jq -r .total <<<"$meta")" "missing total stays null (unlimited)"
assert_eq "3|1700000000|12" "$(jq -r '"\(.upload + .download)|\(.expire)|\(.header_interval)"' <<<"$meta")" "userinfo fields"
rm -f "$FETCH_HDR"
pass "subscription metadata"

# E7: freeze subscription metadata fixtures (redirect chain, CRLF, base64 title, empty fields, missing userinfo, spaces/odd order)
fixture_header_test() {
	local hdr="$1" expected="$2" name="$3"
	local f="$tmpdir/fixture.headers"
	printf '%b' "$hdr" >"$f"
	FETCH_HDR="$f"
	assert_eq "$expected" "$(subscription_metadata_from_headers)" "$name"
	# Production shell: BusyBox ash with BusyBox awk.
	assert_eq "$expected" "$(FETCH_HDR="$f" PATH="$tmpdir/bb:$PATH" L="$ROOT_DIR/rootfs/usr/lib/xraywrt" \
		ash -c '. "$L/constants.sh"; . "$L/helpers.sh"; . "$L/subscription.sh"; subscription_metadata_from_headers')" "$name (ash, BusyBox awk)"
	rm -f "$f"
}
mkdir -p "$tmpdir/bb"
ln -sf "$(command -v busybox)" "$tmpdir/bb/awk"

fixture_header_test \
	'HTTP/1.1 302 Found\r\nLocation: /next\r\nProfile-Title: Old Title\r\nsubscription-userinfo: upload=999\r\n\r\nHTTP/1.1 200 OK\r\nProfile-Title: New Title\r\nsubscription-userinfo: upload=100; download=200\r\n' \
	'{"profile_title":"New Title","announce":"","support_url":"","web_page_url":"","header_interval":null,"upload":100,"download":200,"total":null,"expire":null}' \
	"E7 fixture: redirect chain (two header blocks)"

fixture_header_test \
	'HTTP/1.1 200 OK\r\nprofile-title: CRLF Title\r\nsupport-url: https://help.example\r\nprofile-web-page-url: https://web.example\r\nprofile-update-interval: 24\r\nsubscription-userinfo: upload=10; download=20; total=30; expire=40\r\n' \
	'{"profile_title":"CRLF Title","announce":"","support_url":"https://help.example","web_page_url":"https://web.example","header_interval":24,"upload":10,"download":20,"total":30,"expire":40}' \
	"E7 fixture: CRLF"

fixture_header_test \
	'HTTP/1.1 200 OK\r\nProfile-Title: base64:0JvQuNGH0L3QsNGPIPCfmoA=\r\nannounce: base64:SGVsbG8gV29ybGQ=\r\n' \
	'{"profile_title":"Личная 🚀","announce":"Hello World","support_url":"","web_page_url":"","header_interval":null,"upload":null,"download":null,"total":null,"expire":null}' \
	"E7 fixture: base64 title and announce"

fixture_header_test \
	'HTTP/1.1 200 OK\r\nProfile-Title: \r\nprofile-update-interval: \r\nsubscription-userinfo: upload=; download=; total=; expire=\r\n' \
	'{"profile_title":"","announce":"","support_url":"","web_page_url":"","header_interval":null,"upload":null,"download":null,"total":null,"expire":null}' \
	"E7 fixture: empty fields"

fixture_header_test \
	'HTTP/1.1 200 OK\r\nProfile-Title: Just Title\r\n' \
	'{"profile_title":"Just Title","announce":"","support_url":"","web_page_url":"","header_interval":null,"upload":null,"download":null,"total":null,"expire":null}' \
	"E7 fixture: missing userinfo"

fixture_header_test \
	'HTTP/1.1 200 OK\r\nsubscription-userinfo:   expire=99999 ;  total=50000 ;  download=3000 ; upload=1000  \r\n' \
	'{"profile_title":"","announce":"","support_url":"","web_page_url":"","header_interval":null,"upload":1000,"download":3000,"total":50000,"expire":99999}' \
	"E7 fixture: userinfo with spaces and odd order"

# E7: one awk pass in subscription.sh, no fetch_header
assert_eq 1 "$(sed -n '/subscription_metadata_from_headers() {/,/^}/p' "$ROOT_DIR/rootfs/usr/lib/xraywrt/subscription.sh" | grep -c 'awk ')" "single awk pass in subscription_metadata_from_headers"
assert_false "no fetch_header calls in subscription.sh" grep -q 'fetch_header' "$ROOT_DIR/rootfs/usr/lib/xraywrt/subscription.sh"
pass "frozen subscription header fixtures and one awk pass"

printf '%s\n' "$meta" >"$SUBSCRIPTION_META_FILE"
assert_eq 12 "$(settings_subscription_interval)" "auto interval from provider header"
fake_uci_set xraywrt.settings.subscription_auto_update 0
assert_eq 0 "$(settings_subscription_interval)" "explicit 0 disables"
pass "auto interval"

# E: concurrent downloads use their own temp files.
grep -q 'fetch.headers.\$\$' "$XRAYWRT_LIB_DIR/fetch.sh" || fail "header dump must be per process"
grep -q 'subscription.\$\$.json' "$XRAYWRT_LIB_DIR/subscription.sh" || fail "subscription candidate must be per process"
pass "per-process temp files"

# Subscription download bypasses Xray only while it runs.
load_modules lists.sh nft.sh route.sh
nft_log="$tmpdir/nft.log"
: >"$nft_log"
nft() { echo "nft $*" >>"$nft_log"; }
nft_active() { true; }
nslookup() { printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nName:\tsub.example.com\nAddress: 203.0.113.7\n\nName:\tsub.example.com\nAddress: 2001:db8::7\n'; }
with_lock() { "$@"; }
config_install() { echo "fetch-order" >>"$nft_log"; echo '{"action":"saved"}'; }
cron_update() { :; }
lists_urls() { :; }
http_fetch() { echo "download" >>"$nft_log"; mkdir -p "$(dirname "$2")"; cp "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$2"; }
settings_load() { SUBSCRIPTION_URL=https://sub.example.com/s; BYPASS_SUBSCRIPTION_DNS=1; }
subscription_update >/dev/null
assert_eq "nft add element inet xraywrt bypass_dst { 203.0.113.7 timeout 2m }
nft add element inet xraywrt bypass_dst6 { 2001:db8::7 timeout 2m }
download
nft delete element inet xraywrt bypass_dst { 203.0.113.7 }
nft delete element inet xraywrt bypass_dst6 { 2001:db8::7 }
fetch-order" "$(cat "$nft_log")" "bypass added before download and removed right after"
: >"$nft_log"
settings_load() { SUBSCRIPTION_URL=https://sub.example.com/s; BYPASS_SUBSCRIPTION_DNS=0; }
subscription_update >/dev/null
assert_eq $'download\nfetch-order' "$(cat "$nft_log")" "no bypass when the toggle is off"
pass "temporary subscription bypass"

(
 settings_load() { SUBSCRIPTION_URL=https://sub.example.com/s; BYPASS_SUBSCRIPTION_DNS=1; }
 nslookup() { printf 'Name: sub.example.com\nAddress: 198.18.0.5\n'; }
 : >"$nft_log"
 subscription_update >/dev/null
 assert_file_not_contains "$nft_log" 'bypass_dst' 'fake-IP must never enter the temporary bypass'
 assert_eq '' "$(subscription_host_addresses 198.18.0.5)" 'literal fake-IP is filtered too'
 assert_eq '' "$(subscription_host_addresses 198.19.0.5)" 'upper half of the /15 fake-IP pool filtered'
 assert_eq 198.20.0.5 "$(subscription_host_addresses 198.20.0.5)" 'address outside FAKEIP_RANGE retained'
)
pass 'subscription fake-IP answers excluded from bypass'

(
 load_modules dns.sh
 settings_load() { SUBSCRIPTION_URL="$(active_subscription_url)"; BYPASS_SUBSCRIPTION_DNS=1; }
 settings_require() { :; }
 dns_confdirs() { echo "$tmpdir/dnsmasq"; }
 dns_restart_dnsmasq() { :; }
 DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
 printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
 set_active_subscription https://old.example/sub
 touch "$RUNNING_MARKER"
 for outcome in success download_failure empty install_failure; do
  http_fetch() {
   assert_file_contains "$tmpdir/dnsmasq/$DNS_CONF_NAME" 'server=/new.example/192.0.2.53' 'new host DNS bypass installed before fetch'
   case "$outcome" in
   download_failure) FETCH_ERROR=network; return 1 ;;
   empty) : >"$2" ;;
   *) echo '{"outbounds":[]}' >"$2" ;;
   esac
  }
  config_install() { [ "$outcome" != install_failure ] || return 1; echo '{"action":"saved"}'; }
  if [ "$outcome" = success ]; then
   subscription_update https://new.example/sub >/dev/null
   set_active_subscription https://old.example/sub
  else
   assert_false "$outcome fails" subscription_update https://new.example/sub >/dev/null 2>"$tmpdir/dns-failure.err"
   assert_file_contains "$tmpdir/dnsmasq/$DNS_CONF_NAME" 'server=/old.example/192.0.2.53' 'failed replacement restores saved host DNS bypass'
   assert_file_not_contains "$tmpdir/dnsmasq/$DNS_CONF_NAME" 'server=/new.example/' 'failed host DNS bypass removed'
  fi
 done
 # Stop may finish while the fetch is in progress or before the lock is acquired.
 for stop_at in fetch lock; do
  touch "$RUNNING_MARKER"
  with_lock() {
   if [ "$stop_at" = lock ]; then
    rm -f "$RUNNING_MARKER"
    dns_cleanup
   fi
   "$@"
  }
  http_fetch() {
   if [ "$stop_at" = fetch ]; then
    rm -f "$RUNNING_MARKER"
    dns_cleanup
   fi
   if [ -e "$tmpdir/dnsmasq/$DNS_CONF_NAME" ]; then
    touch "$tmpdir/dns-rewritten"
   fi
   FETCH_ERROR=network
   return 1
  }
  assert_false "failed fetch after stop at $stop_at" subscription_update https://new.example/sub >/dev/null 2>"$tmpdir/dns-stop.err"
  assert_false 'stopped service has no DNS config before failed fetch returns' test -e "$tmpdir/dns-rewritten"
  assert_false 'failed fetch must not recreate DNS config after stop' test -e "$tmpdir/dnsmasq/$DNS_CONF_NAME"
 done
 rm -f "$RUNNING_MARKER"
)
pass 'replacement host DNS prepared before fetch and restored only while running'


# A broken metadata file must not break the subscription page.
: >"$SUBSCRIPTION_META_FILE"
subscription_json | jq -e '.url != null' >/dev/null || fail "empty metadata file must be ignored"
echo '{oops' >"$SUBSCRIPTION_META_FILE"
subscription_json | jq -e '.url != null' >/dev/null || fail "invalid metadata file must be ignored"
pass "subscription json tolerates broken metadata"

payload="$(printf 'x%.0s' {1..12000} | busybox base64 | tr -d '\n')"
assert_eq 12000 "$(subscription_decode_metadata_value "base64:$payload" | wc -c | tr -d ' ')" "large valid metadata decoded"
assert_eq '' "$(subscription_decode_metadata_value "base64:${payload}AAAAA$(printf 'A%.0s' {1..400})")" "over limit metadata dropped"
assert_eq '' "$(subscription_decode_metadata_value base64:@@@)" "malformed metadata dropped"
assert_eq Hello "$(subscription_decode_metadata_value Hello)" "plain metadata"
# Set-subscription now accepts only the auto-update boolean.
set_active_subscription https://sub.example/x
for auto in 1 0; do
 subscription_set https://sub.example/x "$auto"
 assert_eq "$auto" "$(uci_get subscription_auto_update)" "auto-update stored"
done
assert_false "numeric interval rejected" subscription_set https://sub.example/x 5 2>"$tmpdir/set.err"
assert_file_contains "$tmpdir/set.err" 'Auto-update must be 0 or 1' "auto-update validation message"
pass "metadata limits and on/off setter"

# A replacement URL is committed only after installation succeeds.
settings_load() { SUBSCRIPTION_URL="$(active_subscription_url)"; BYPASS_SUBSCRIPTION_DNS=0; }
set_active_subscription https://old.example/sub
http_fetch() { printf '%s\n' "$1" >"$tmpdir/request-url"; printf '{"outbounds":[]}\n' >"$2"; }
config_install() { assert_eq https://old.example/sub "$(active_subscription_url)" 'old URL until install'; echo '{"action":"saved"}'; }
subscription_update https://new.example/sub >/dev/null
assert_eq https://new.example/sub "$(active_subscription_url)" 'successful URL saved'
assert_eq https://new.example/sub "$(cat "$tmpdir/request-url")" 'new URL downloaded'
config_install() { return 1; }
assert_false 'install failure rejects' subscription_update https://broken.example/sub >/dev/null 2>&1
assert_eq https://new.example/sub "$(active_subscription_url)" 'install failure keeps old URL'
http_fetch() { FETCH_ERROR=network; return 1; }
assert_false 'download failure rejects' subscription_update https://offline.example/sub >/dev/null 2>&1
assert_eq https://new.example/sub "$(active_subscription_url)" 'download failure keeps old URL'
assert_false 'invalid URL rejects' subscription_update javascript:evil >/dev/null 2>&1
assert_eq https://new.example/sub "$(active_subscription_url)" 'invalid URL keeps old URL'
pass 'replacement subscription URL transaction'

# Each subscription exit owns and removes its response headers.
for outcome in download_failure empty install_failure success; do
 http_fetch() {
  FETCH_HDR="$6"
  assert_eq "$PKG_TMP_DIR/subscription.$$.headers" "$FETCH_HDR" "subscription requests explicit headers"
  printf 'HTTP/1.1 200 OK\r\nProfile-Title: kept\r\n' >"$FETCH_HDR"
  case "$outcome" in
  download_failure) FETCH_ERROR=network; return 1 ;;
  empty) : >"$2" ;;
  install_failure | success) printf '{"outbounds":[]}\n' >"$2" ;;
  esac
 }
 config_install() { [ "$outcome" != install_failure ] || return 1; echo '{"action":"saved"}'; }
 rm -f "$PKG_TMP_DIR"/subscription.*.headers
 if [ "$outcome" = success ]; then
  subscription_update >/dev/null
  assert_eq kept "$(jq -r .profile_title "$SUBSCRIPTION_META_FILE")" 'headers parsed before cleanup'
 else
  assert_false "$outcome rejected" subscription_update >/dev/null 2>&1
 fi
 assert_eq "" "$(find "$PKG_TMP_DIR" -name 'subscription.*.headers')" "no header files left after subscription $outcome"
done
pass 'subscription response headers cleaned on every exit'

# CLI and job processes may download together, but publish config/metadata as a pair.
(
 concurrent="$tmpdir/concurrent"
 mkdir -p "$concurrent/tmp" "$concurrent/run" "$concurrent/etc"
 cat >"$concurrent/update.sh" <<'SH'
#!/bin/ash
set -eu
root="$1"; identity="$2"
for module in constants helpers validate xray-config subscription; do
 . "$XRAYWRT_LIB_DIR/$module.sh"
done
PKG_TMP_DIR="$root/tmp"
PKG_STATE_DIR="$root/run"
SUBSCRIPTION_META_FILE="$root/etc/subscription.json"
RUNTIME_LOCK_FILE="$root/run/runtime.flock"
settings_load() { SUBSCRIPTION_URL=https://same.example/sub; BYPASS_SUBSCRIPTION_DNS=0; }
uci_get() { echo https://same.example/sub; }
http_fetch() { printf '{"remarks":"%s","outbounds":[]}\n' "$identity" >"$2"; }
subscription_metadata_from_headers() { printf '{"profile_title":"%s"}\n' "$identity"; }
config_install() {
 cp "$1" "$root/config.json"
 echo "install $identity" >>"$root/events"
 sleep 0.2
 echo '{"action":"saved"}'
}
atomic_copy() {
 echo "metadata $identity depth=${LOCK_DEPTH:-0} stage=${1##*/}" >>"$root/events"
 cp "$1" "$2"
}
lists_urls() { :; }
cron_update() { :; }
subscription_update >"$root/result.$identity"
SH
 ash "$concurrent/update.sh" "$concurrent" cli &
 cli_pid=$!
 ash "$concurrent/update.sh" "$concurrent" job &
 job_pid=$!
 wait "$cli_pid" || fail 'CLI subscription update succeeds'
 wait "$job_pid" || fail 'job subscription update succeeds'
 assert_eq 2 "$(grep -c 'depth=1 stage=subscription\.[0-9]*\.json$' "$concurrent/events" || true)" 'both metadata publications use per-PID staging under runtime lock'
 awk '
 /^install / { if (pending) exit 1; pending = $2; next }
 /^metadata / { if ($2 != pending) exit 1; pending = "" }
 END { if (pending) exit 1 }
 ' "$concurrent/events" || fail 'install and metadata publication cannot interleave'
 installed="$(jq -r .remarks "$concurrent/config.json")"
 assert_eq "$installed" "$(jq -r .profile_title "$concurrent/etc/subscription.json")" 'final config and metadata belong to the same update'
 assert_eq '' "$(find "$concurrent/tmp" -name 'subscription.*.json')" 'metadata staging cleaned'
)
pass 'concurrent CLI and job subscription publication serialized'

# Never expose provider credentials while files are being filled or published.
(
 umask 022
 settings_load() { SUBSCRIPTION_URL=https://same.example/sub; BYPASS_SUBSCRIPTION_DNS=0; }
 subscription_metadata_from_headers() { echo '{"profile_title":"private"}'; }
 http_fetch() {
  assert_eq 600 "$(stat -c %a "$2")" 'subscription candidate private before fetch'
  assert_eq 600 "$(stat -c %a "$6")" 'subscription headers private before fetch'
  printf '{"outbounds":[]}\n' >"$2"
  FETCH_HDR="$6"
 }
 config_install() { assert_eq 600 "$(stat -c %a "$1")" 'downloaded subscription mode'; echo '{"action":"saved"}'; }
 atomic_copy() {
  assert_eq 600 "$(stat -c %a "$1")" 'staged metadata mode'
  command cp "$1" "$2"
 }
 subscription_update >/dev/null
 assert_eq 0022 "$(umask)" 'subscription update does not change caller umask'
)
pass 'subscription candidates, headers and metadata created mode 600'

# A short metadata write must never replace the previous complete JSON.
(
 printf '{"profile_title":"previous"}\n' >"$SUBSCRIPTION_META_FILE"
 config_install() { echo '{"action":"saved"}'; }
 printf() {
  if [ "${2:-}" = '{"profile_title":"replacement"}' ]; then
   builtin printf '{"profile_title":'
   return 1
  fi
  # Forward printf's format unchanged in this fault stub.
  # shellcheck disable=SC2059
  builtin printf "$@"
 }
 subscription_install "$XRAY_CONFIG" '{"profile_title":"replacement"}' '' >/dev/null 2>"$tmpdir/metadata-write.err" || fail 'metadata write failure must not reject the installed config'
 assert_eq '{"profile_title":"previous"}' "$(cat "$SUBSCRIPTION_META_FILE")" 'failed staged metadata write keeps previous JSON'
 assert_false 'failed metadata staging removed' test -e "$PKG_TMP_DIR/subscription.$$.json"
)
pass 'short subscription metadata writes are not published'

# Only the usage counters differ: flash is not rewritten, the page shows the new counters.
(
 config_install() { echo '{"action":"saved"}'; }
 eval "$(declare -f atomic_copy | sed '1s/atomic_copy/real_atomic_copy/')"
 atomic_copy() { echo write >>"$tmpdir/meta-writes"; real_atomic_copy "$@"; }
 usage_meta() { printf '{"profile_title":"t","announce":"","support_url":"","web_page_url":"","header_interval":12,"upload":%s,"download":%s,"total":50,"expire":9}' "$1" "$2"; }
 rm -f "$SUBSCRIPTION_META_FILE" "$tmpdir/meta-writes"
 subscription_install "$XRAY_CONFIG" "$(usage_meta 1 2)" '' >/dev/null
 subscription_install "$XRAY_CONFIG" "$(usage_meta 5 7)" '' >/dev/null
 assert_eq 1 "$(wc -l <"$tmpdir/meta-writes" | tr -d ' ')" 'counter-only change does not rewrite flash metadata'
 assert_eq 1 "$(jq -r .upload "$SUBSCRIPTION_META_FILE")" 'flash keeps the last written counters as the reboot fallback'
 assert_eq '5:7' "$(subscription_json | jq -r '"\(.upload):\(.download)"')" 'page shows the fresh counters'
 subscription_install "$XRAY_CONFIG" "$(usage_meta 5 7 | sed 's/"total":50/"total":60/')" '' >/dev/null
 assert_eq 2 "$(wc -l <"$tmpdir/meta-writes" | tr -d ' ')" 'other metadata change is written'
 assert_eq 60 "$(jq -r .total "$SUBSCRIPTION_META_FILE")" 'changed metadata reaches flash'
)
pass 'usage counters stay in tmpfs'

# Failure creating the second staging file also cleans the first one.
(
 settings_load() { SUBSCRIPTION_URL=https://same.example/sub; BYPASS_SUBSCRIPTION_DNS=0; }
 ln -s "$tmpdir/missing-parent/headers" "$PKG_TMP_DIR/subscription.$$.headers"
 http_fetch() { fail 'staging failure must not start a download'; }
 assert_false 'staging failure rejects update' subscription_update >/dev/null 2>"$tmpdir/staging.err"
 assert_false 'candidate removed after header staging fails' test -e "$PKG_TMP_DIR/subscription.$$.json"
 assert_false 'failed header staging path removed' test -L "$PKG_TMP_DIR/subscription.$$.headers"
)
pass 'subscription staging failure cleans partial files'

# check-ip: the router's own address through the stubbed curl.
(
 . "$XRAYWRT_LIB_DIR/fetch.sh"
: >"$CURL_LOG"
assert_eq '{"ip":"203.0.113.7","country":"NL"}' "$(CURL_BODY='{"ip":"203.0.113.7","country":"NL","city":"x"}' check_ip_json | jq -c .)" 'check-ip prints ip and country'
assert_file_contains "$CURL_LOG" 'https://ipinfo.io/json' 'check-ip asks ipinfo.io'
assert_file_contains "$CURL_LOG" '--max-time 10' 'check-ip has a 10 s limit'
for bad in '{"ip":"203.0.113.7"}' 'not json' '{"ip":"<x>","country":"NL"}'; do
 out="$(CURL_BODY="$bad" check_ip_json 2>&1)" && fail "check-ip accepted: $bad"
 case "$out" in *'[E:check_ip]'*) ;; *) fail "check-ip code for $bad: $out" ;; esac
done
out="$(CURL_EXIT=7 check_ip_json 2>&1)" && fail 'check-ip accepted a network error'
case "$out" in *'[E:check_ip]'*) ;; *) fail "check-ip network code: $out" ;; esac
assert_eq '' "$(find "$PKG_TMP_DIR" -name 'check-ip.*')" 'check-ip leaves no temporary file'
)
pass 'check-ip'
