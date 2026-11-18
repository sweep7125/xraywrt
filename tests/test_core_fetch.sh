#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh fetch.sh core.sh
openwrt_arch() { echo aarch64_generic; }
assert_eq /tmp/xraywrt/core-update "$CORE_TMP_DIR" 'core stage lives in RAM (spec 4.3)'
assert_eq 67108864 "$CORE_ASSET_MAX_BYTES" 'asset size limit'
assert_eq /proc/meminfo "$MEMINFO_FILE" 'RAM is read from /proc/meminfo'
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
MEMINFO_FILE="$tmpdir/meminfo"
meminfo() { printf 'MemTotal:         245000 kB\nMemFree:           90000 kB\nMemAvailable:   %8s kB\n' "$1" >"$MEMINFO_FILE"; }
warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
log() { printf '%s\n' "$*" >>"$tmpdir/log"; }

{ printf '#!/bin/sh\necho "Xray 26.11.1 (Xray, Penetrates Everything.)"\n'; printf '#%.0s' $(seq 2000); echo; } >"$tmpdir/asset"
asset_size="$(wc -c <"$tmpdir/asset" | tr -d ' ')"
asset_sha="$(sha256sum "$tmpdir/asset" | cut -d' ' -f1)"
jq -nc --arg s "$asset_size" --arg d "sha256:$asset_sha" \
	'{tag_name: "v0.2.0", assets: [{name: "xraywrt-core_0.25.1-r1_aarch64_generic.apk", browser_download_url: "https://example.com/xraywrt-core_0.25.1-r1_aarch64_generic.apk", size: ($s | tonumber), digest: $d}]}' >"$tmpdir/release.json"
serve="$tmpdir/asset"
api_down=0

# curl stub behind the real http_fetch.
curl() {
	local out='' headers='' url='' max=''
	printf '%s\n' "$*" >>"$tmpdir/curl.log"
	while [ "$#" -gt 0 ]; do
		case "$1" in -o) out="$2"; shift ;; -D) headers="$2"; shift ;; --max-filesize) max="$2"; shift ;; esac
		url="$1"
		shift
	done
	printf 'HTTP/1.1 200 OK\r\n' >"$headers"
	case "$url" in
	*api.github.com*) [ "$api_down" = 0 ] || return 7; cp "$tmpdir/release.json" "$out" ;;
	*SHA256SUMS-core) printf '%s  xraywrt-core_0.25.1-r1_aarch64_generic.apk\n' "$asset_sha" >"$out" ;;
	*)
		# route_mode "<host>:ok|down|bad ...": github = the URL without a proxy.
		case " ${route_mode:-} " in
		*" $(url_host "$url" | sed 's/^github.com$/github/'):down "*) return 7 ;;
		*" $(url_host "$url" | sed 's/^github.com$/github/'):bad "*) cp "$tmpdir/bad" "$out"; return 0 ;;
		esac
		[ "$(wc -c <"$serve" | tr -d ' ')" -le "$max" ] || return 63
		cp "$serve" "$out"
		;;
	esac
}
github_latest_tag() { echo v0.2.0; }

fetch_asset() {
	: >"$tmpdir/curl.log"
	rm -rf "$CORE_TMP_DIR"
	core_pkg_resolve || fail "resolve: $CORE_ERROR"
	core_asset_fetch
}

# Verified download into the RAM stage; curl timeouts for metadata and asset.
for api_down in 0 1; do
	meminfo 200000
	fetch_asset || fail "asset fetch (api_down=$api_down): $CORE_ERROR"
	assert_true "asset in CORE_TMP_DIR (api_down=$api_down)" cmp -s "$tmpdir/asset" "$CORE_TMP_DIR/xray"
	api_args="$(grep api.github.com "$tmpdir/curl.log")"
	[[ "$api_args" == *'--max-time 30'* ]] || fail 'release metadata keeps fixed timeout'
	asset_args="$(grep -E 'xraywrt-core_0.25.1-r1_aarch64_generic.apk$' "$tmpdir/curl.log")"
	[[ "$asset_args" == *'--speed-limit 2048 --speed-time 60 --retry 2'* ]] || fail "core asset uses stall timeout and retry: $asset_args"
	[[ "$asset_args" != *'--max-time'* ]] || fail 'core asset has no fixed total timeout'
	pass "verified asset download (api_down=$api_down)"
done
api_down=0

# sha256 mismatch: refuse and drop the download.
printf '#!/bin/sh\necho "Xray 6.6.6 (evil)"\n' >"$tmpdir/evil"
serve="$tmpdir/evil"
jq --arg s "$(wc -c <"$tmpdir/evil" | tr -d ' ')" '.assets[0].size = ($s | tonumber)' "$tmpdir/release.json" >"$tmpdir/r" && mv "$tmpdir/r" "$tmpdir/release.json"
if fetch_asset; then fail 'sha256 mismatch must fail'; fi
assert_eq 'sha256 mismatch [E:core_damaged]' "$CORE_ERROR" 'sha256 mismatch error'
assert_false 'mismatching download removed' test -e "$CORE_TMP_DIR/xray"
serve="$tmpdir/asset"
if fetch_asset; then fail 'size mismatch must fail'; fi
assert_eq 'downloaded size does not match release [E:core_damaged]' "$CORE_ERROR" 'size mismatch error'
assert_false 'size mismatch removes download' test -e "$CORE_TMP_DIR/xray"
pass 'sha256 and size are checked'

# Published size above the limit: refuse before downloading.
jq --arg s "$asset_size" '.assets[0].size = 67108865' "$tmpdir/release.json" >"$tmpdir/r" && mv "$tmpdir/r" "$tmpdir/release.json"
if fetch_asset; then fail 'oversized asset must fail'; fi
assert_eq 'asset xraywrt-core_0.25.1-r1_aarch64_generic.apk is too large (67108865 bytes, limit 67108864)' "$CORE_ERROR" 'size limit error'
assert_false 'oversized asset is not downloaded' grep -q 'xraywrt-core_0.25.1-r1_aarch64_generic.apk' "$tmpdir/curl.log"
jq --arg s "$asset_size" '.assets[0].size = ($s | tonumber)' "$tmpdir/release.json" >"$tmpdir/r" && mv "$tmpdir/r" "$tmpdir/release.json"
pass 'asset size limit'

# MemAvailable >= size + 16 MiB before downloading.
need_kb=$(((asset_size + 16777216 + 1023) / 1024))
meminfo "$((need_kb - 1))"
if fetch_asset; then fail 'low RAM must fail'; fi
assert_eq "not enough RAM: need 17 MiB, available $(((need_kb - 1) / 1024)) MiB [E:core_ram|17|$(((need_kb - 1) / 1024))]" "$CORE_ERROR" 'RAM error'
assert_false 'low RAM: nothing downloaded' grep -q 'xraywrt-core_0.25.1-r1_aarch64_generic.apk' "$tmpdir/curl.log"
meminfo "$need_kb"
fetch_asset || fail "exact RAM budget: $CORE_ERROR"
assert_file_contains "$tmpdir/curl.log" "--max-filesize $asset_size " 'published size: download capped to that size'
pass 'RAM check uses MemAvailable'

# Fallback (no published size): the download is capped to the RAM budget.
api_down=1
meminfo $((16384 + 1))
if fetch_asset; then fail 'unknown size above RAM budget must fail'; fi
assert_eq 'not enough RAM for xraywrt-core_0.25.1-r1_aarch64_generic.apk' "$CORE_ERROR" 'capped download error'
assert_file_contains "$tmpdir/curl.log" '--max-filesize 1024 ' 'unknown size: limit = MemAvailable - 16 MiB'
meminfo 200000
fetch_asset || fail "fallback with RAM: $CORE_ERROR"
assert_file_contains "$tmpdir/curl.log" "--max-filesize $CORE_ASSET_MAX_BYTES " 'unknown size: limit capped at 64 MiB'
rm -f "$MEMINFO_FILE"
if fetch_asset; then fail 'unreadable meminfo must fail'; fi
assert_eq 'cannot check free RAM' "$CORE_ERROR" 'meminfo error'
pass 'RAM budget without published size'

# Spec 4.1: the body comes from github.com, then each GITHUB_PROXIES route;
# every attempt is checked against the sha256; tag and hash never via a proxy.
meminfo 200000
gh_url=https://github.com/sweep7125/xraywrt-core/releases/download/v0.2.0/xraywrt-core_0.25.1-r1_aarch64_generic.apk
jq --arg u "$gh_url" '.assets[0].browser_download_url = $u' "$tmpdir/release.json" >"$tmpdir/r" && mv "$tmpdir/r" "$tmpdir/release.json"
sed 's/Xray 26/Xray 66/' "$tmpdir/asset" >"$tmpdir/bad"
assert_eq "gh-proxy.com ghproxy.net" "$GITHUB_PROXIES" 'GitHub proxies (spec 4.1)'
assert_eq "https://example.com/a" "$(github_routes https://example.com/a)" 'no proxy routes for other hosts'
routes() { grep -oE '(https://(gh-proxy\.com|ghproxy\.net)/)?https://github\.com/[^ ]*xraywrt-core_0.25.1-r1_aarch64_generic.apk$' "$tmpdir/curl.log" | tr '\n' ' '; }
all_routes="$gh_url https://gh-proxy.com/$gh_url https://ghproxy.net/$gh_url "
for api_down in 0 1; do
	: >"$tmpdir/log"
	: >"$tmpdir/warnings"
	route_mode="github:down gh-proxy.com:bad ghproxy.net:ok"
	fetch_asset || fail "proxy fallback (api_down=$api_down): $CORE_ERROR"
	assert_true "verified body via the last proxy (api_down=$api_down)" cmp -s "$tmpdir/asset" "$CORE_TMP_DIR/xray"
	assert_eq "$all_routes" "$(routes)" "github.com, then each proxy in order (api_down=$api_down)"
	assert_file_contains "$tmpdir/log" 'Core update: xraywrt-core_0.25.1-r1_aarch64_generic.apk from ghproxy.net' 'working route logged'
	assert_file_contains "$tmpdir/warnings" 'Core update: xraywrt-core_0.25.1-r1_aarch64_generic.apk from gh-proxy.com: sha256' 'bad proxy body rejected'
	assert_false "tag and hash never via a proxy (api_down=$api_down)" grep -qE '(gh-proxy\.com|ghproxy\.net)/.*(api\.github\.com|SHA256SUMS-core)' "$tmpdir/curl.log"
done
api_down=0
route_mode="github:ok gh-proxy.com:ok ghproxy.net:ok"
fetch_asset || fail "github route: $CORE_ERROR"
assert_eq "$gh_url " "$(routes)" 'github.com works: no proxy request'
route_mode="github:down gh-proxy.com:down ghproxy.net:down"
if fetch_asset; then fail 'all routes down must fail'; fi
assert_eq 'download failed (network) [E:core_download|download failed (network)]' "$CORE_ERROR" 'error of the github.com route'
route_mode="github:bad gh-proxy.com:bad ghproxy.net:bad"
if fetch_asset; then fail 'bad bodies on every route must fail'; fi
assert_eq 'sha256 mismatch [E:core_damaged]' "$CORE_ERROR" 'every bad body rejected'
assert_eq "$all_routes" "$(routes)" 'every route tried'
assert_false 'rejected body removed' test -e "$CORE_TMP_DIR/xray"
pass 'body routes: github.com, then proxies, each verified'
