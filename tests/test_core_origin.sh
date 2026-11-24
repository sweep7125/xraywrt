#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 0 ]; then
 bash "$0" api
 exec bash "$0" repo
fi
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh fetch.sh core.sh
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
CORE_JSON_FILE="$tmpdir/core.json"
MEMINFO_FILE="$tmpdir/meminfo"
printf 'MemAvailable: 200000 kB\n' >"$MEMINFO_FILE"
openwrt_arch() { echo aarch64_cortex-a53; }
sha="$(printf 'a%.0s' {1..64})"
asset=xraywrt-core_0.26.2-r1_aarch64_cortex-a53.apk
http_fetch() {
 printf '%s\n' "$1" >>"$tmpdir/requests"
 case "$1" in
 https://api.github.com/repos/sweep7125/xraywrt-core/releases/latest)
  jq -nc --arg a "$asset" --arg s "sha256:$sha" --arg u "${asset_url:-https://example.invalid/core.apk}" '{tag_name:"v0.26.2",assets:[{name:$a,browser_download_url:$u,digest:$s,size:123}]}' >"$2" ;;
 *) FETCH_ERROR=network; return 1 ;;
 esac
}
case "${1:-}" in
api)
 for asset_url in https://example.invalid/core.apk http://example.invalid/core.apk $'https://example.invalid/\tspoof'; do
  core_pkg_resolve || fail "canonical API resolution: $CORE_ERROR"
  assert_eq "https://github.com/sweep7125/xraywrt-core/releases/download/v0.26.2/$asset" "$CORE_URL" 'API asset URL is canonical'
  assert_eq "$sha:123" "$CORE_SHA256:$CORE_SIZE" 'API digest and size preserved'
 done
 ;;
repo)
 pkg_version() { echo 0.26.2-r1; }
 printf '{}\n' >"$CORE_JSON_FILE"
 assert_eq sweep7125/xraywrt "$(xraywrt-json core-repo "$CORE_JSON_FILE")" 'missing repo defaults to legacy'
 for repo in sweep7125/xraywrt sweep7125/xraywrt-core; do
  jq -nc --arg repo "$repo" '{repo:$repo}' >"$CORE_JSON_FILE"
  assert_eq "$repo" "$(xraywrt-json core-repo "$CORE_JSON_FILE")" 'explicit known repo retained'
 done
 failures=0
 for invalid in '"sweep7125/xraywrt-core\n"' '"sweep7125/xraywrt-core\u0000"' '"sweep7125/xraywrt\r"' '"sweep7125/xraywrt-core\t"' 'null' 'false' '123' '[]' '{}' '""' '"other/repo"'; do
  jq -nc --arg a "$asset" --arg s "$sha" --argjson r "$invalid" '{source:"package",tag:"v0.26.2",version:"0.26.2-r1",asset:$a,sha256:$s,size:123,repo:$r}' >"$CORE_JSON_FILE"
  rm -f "$tmpdir/requests"
  if core_pkg_old_fetch || [ -e "$tmpdir/requests" ]; then
   printf 'FAIL: invalid rollback repo reached fetch or succeeded: %s\n' "$invalid" >&2
   failures=$((failures + 1))
  fi
 done
 [ "$failures" = 0 ] || exit 1
 ;;
*) fail 'expected api or repo' ;;
esac
pass "core origin $1"
