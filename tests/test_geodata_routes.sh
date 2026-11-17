#!/usr/bin/env bash
# Geodata fallback routes (spec 10): the url, then its jsDelivr or raw twin,
# then each GitHub proxy; a warning for every route that is not the url.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh fetch.sh geodata.sh
setup_runtime_paths "$tmpdir"
MEMINFO_FILE="$tmpdir/meminfo"
printf 'MemAvailable: 262144 kB\n' >"$MEMINFO_FILE"
warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }

routes() { geodata_routes "$1" | tr '\n' ' '; }
raw=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/geosite.dat
cdn=https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat
assert_eq "$raw $cdn https://gh-proxy.com/$raw https://ghproxy.net/$raw " "$(routes "$raw")" 'raw: url, jsDelivr, proxies'
assert_eq https://cdn.jsdelivr.net/gh/o/r@main/sub/dir/x.dat "$(geodata_routes https://raw.githubusercontent.com/o/r/main/sub/dir/x.dat | sed -n 2p)" 'path with directories kept'
heads=https://raw.githubusercontent.com/o/r/refs/heads/main/data/geoip.dat
assert_eq "$heads https://cdn.jsdelivr.net/gh/o/r@main/data/geoip.dat https://gh-proxy.com/$heads https://ghproxy.net/$heads " "$(routes "$heads")" 'raw refs/heads/<b>'
blob=https://github.com/o/r/raw/main/geoip.dat
assert_eq "$blob https://cdn.jsdelivr.net/gh/o/r@main/geoip.dat https://gh-proxy.com/$blob https://ghproxy.net/$blob " "$(routes "$blob")" 'github.com raw'
blob=https://github.com/o/r/raw/refs/heads/dev/geoip.dat
assert_eq "$blob https://cdn.jsdelivr.net/gh/o/r@dev/geoip.dat https://gh-proxy.com/$blob https://ghproxy.net/$blob " "$(routes "$blob")" 'github.com raw refs/heads/<b>'
rel=https://github.com/o/r/releases/download/v1/geoip.dat
assert_eq "$rel https://gh-proxy.com/$rel https://ghproxy.net/$rel " "$(routes "$rel")" 'release asset: no jsDelivr'
rel=https://github.com/o/r/releases/latest/download/geoip.dat
assert_eq "$rel https://gh-proxy.com/$rel https://ghproxy.net/$rel " "$(routes "$rel")" 'latest release asset: no jsDelivr'
assert_eq "$cdn $raw https://gh-proxy.com/$raw https://ghproxy.net/$raw " "$(routes "$cdn")" 'jsDelivr: url, raw, proxies before raw'
nref=https://cdn.jsdelivr.net/gh/o/r/geoip.dat
assert_eq "$nref https://raw.githubusercontent.com/o/r/HEAD/geoip.dat https://gh-proxy.com/https://raw.githubusercontent.com/o/r/HEAD/geoip.dat https://ghproxy.net/https://raw.githubusercontent.com/o/r/HEAD/geoip.dat " "$(routes "$nref")" 'jsDelivr without @ref: HEAD'
for url in https://cdn.example.com/geosite.dat https://github.com/o/r/blob/main/geoip.dat https://raw.githubusercontent.com/o/r https://example.com/https://github.com/o/r/raw/main/x.dat; do
	assert_eq "$url " "$(routes "$url")" "other url: original only ($url)"
done
pass 'geodata routes'

# Fetch: every route until one works; each non-original route warns.
prof="$tmpdir/run.json.profile"
printf 'geodata geosite.dat %s\n' "$raw" >"$prof"
# Fake https: DOWN lists the hosts that fail.
http_fetch() {
	echo "$1" >>"$tmpdir/fetch.log"
	case " $DOWN " in *" $(url_host "$1") "*) FETCH_ERROR=network; return 1 ;; esac
	printf 'site from %s\n' "$(url_host "$1")" >"$2"
}
ensure() {
	rm -f "$tmpdir/fetch.log" "$tmpdir/warnings" "$XRAY_SHARE_DIR/geosite.dat"
	touch "$tmpdir/fetch.log" "$tmpdir/warnings"
	geodata_ensure "$prof" 2>"$tmpdir/err" && rc=0 || rc=$?
	geo_error="$GEODATA_ERROR"
	[ "$rc" != 0 ] || geodata_publish
	geodata_settle ok
}
DOWN=''
ensure
assert_eq 0 "$rc" 'original route works'
assert_eq "$raw" "$(cat "$tmpdir/fetch.log")" 'only the original url'
assert_eq '' "$(cat "$tmpdir/warnings")" 'no warning for the original url'
DOWN='raw.githubusercontent.com cdn.jsdelivr.net'
ensure
assert_eq 0 "$rc" "proxy fallback: $(cat "$tmpdir/err")"
assert_eq 'site from gh-proxy.com' "$(cat "$XRAY_SHARE_DIR/geosite.dat")" 'file from the first working route'
assert_eq "$raw
$cdn
https://gh-proxy.com/$raw" "$(cat "$tmpdir/fetch.log")" 'routes in order until one works'
assert_eq 'geodata geosite.dat: raw.githubusercontent.com unavailable, using cdn.jsdelivr.net
geodata geosite.dat: raw.githubusercontent.com unavailable, using gh-proxy.com' "$(cat "$tmpdir/warnings")" 'each non-original route warns'
DOWN='raw.githubusercontent.com cdn.jsdelivr.net gh-proxy.com ghproxy.net'
ensure
assert_eq 1 "$rc" 'all routes down fails'
assert_eq 'geodata geosite.dat: download failed (network) [E:geodata_download|geosite.dat|network]' "$geo_error" 'error of the original url'
assert_eq 1 "$GEODATA_TRANSIENT" 'all routes down is transient'
assert_eq 4 "$(wc -l <"$tmpdir/fetch.log" | tr -d ' ')" 'every route tried'
printf 'geodata geosite.dat https://cdn.example.com/geosite.dat\n' >"$prof"
DOWN='cdn.example.com'
ensure
assert_eq 'https://cdn.example.com/geosite.dat' "$(cat "$tmpdir/fetch.log")" 'other hosts: no fallback'
pass 'geodata fetch fallback'
