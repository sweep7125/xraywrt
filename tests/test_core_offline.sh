#!/usr/bin/env bash
# XrayWRT core API-unavailable resolver: hashes come only from trusted-origin sums.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh fetch.sh core.sh
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
openwrt_arch() { echo aarch64_generic; }
asset=xraywrt-core_0.25.1-r1_aarch64_generic.apk
sha="$(printf 'a%.0s' {1..64})"
sums_body="$sha  $asset"
tag=v0.2.0
http_fetch() {
	printf '%s\n' "$1" >>"$tmpdir/requests"
	case "$1" in
	https://api.github.com/*) FETCH_ERROR=http_403; return 1 ;;
	"https://github.com/sweep7125/xraywrt-core/releases/download/$tag/SHA256SUMS-core") printf '%s\n' "$sums_body" >"$2" ;;
	*) fail "unexpected fallback request $1" ;;
	esac
}
github_latest_tag() { assert_eq sweep7125/xraywrt-core "$1" "fallback repository"; printf '%s\n' "$tag"; }
core_pkg_resolve || fail "offline resolver: $CORE_ERROR"
assert_eq "$sha:$asset:" "$CORE_SHA256:$CORE_ASSET:$CORE_SIZE" 'sums identity, unknown compressed size'
assert_eq "https://github.com/sweep7125/xraywrt-core/releases/download/$tag/$asset" "$CORE_URL" 'package-only offline URL'
for sums_body in "bad $asset" "$sha  ../$asset" "$sha  xraywrt-core_1/../2_aarch64_generic.apk" "$sha  $asset
$sha  $asset"; do
	if core_pkg_resolve; then fail "malformed or ambiguous sums accepted: $sums_body"; fi
done
assert_false 'metadata never requested through proxies or obsolete digest files' grep -Eq 'gh-proxy|ghproxy|\.dgst' "$tmpdir/requests"
pass 'XrayWRT core offline sums reject malformed and ambiguous package identities'
