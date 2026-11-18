#!/usr/bin/env bash
# core_channel=pkgcore (spec 4.5): the xraywrt-core package from the latest
# separate core release, sha256 from the API digest (or SHA256SUMS-core without
# the API), apk add --allow-untrusted;
# normal and tight-flash path with the old .apk as rollback; refusals of
# core-check.

# shellcheck disable=SC2030,SC2031,SC2154 # subshell stubs; tmpdir and asset_* come from core_fixture.sh
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/core_fixture.sh"


# Fake .apk: "version=<v>", "size=<installed-size>", then the core binary.
make_apk() {
	{
		echo "version=$2"
		echo "size=$(wc -c <"$3" | tr -d ' ')"
		cat "$3"
	} >"$1"
}
# apk stub: one package (xraywrt-core) whose only file is $XRAY_BIN. Like
# apk, `add` refuses to overwrite a file no package owns.
export APK_TEST_DIR="$tmpdir" APK_TEST_BIN="$XRAY_BIN"
mkdir -p "$tmpdir/apk-bin"
cat >"$tmpdir/apk-bin/apk" <<'APK'
#!/bin/sh
d="$APK_TEST_DIR"
echo "apk $*" >>"$d/apk.log"
case "$1" in
extract)
	[ "$2" = --allow-untrusted ] && [ "$3" = --destination ] || exit 2
	mkdir -p "$4/opt/xraywrt/bin"
	tail -n +3 "$5" >"$4/opt/xraywrt/bin/xray"
	chmod 755 "$4/opt/xraywrt/bin/xray"
	;;
adbdump) printf 'info:\n  name: xraywrt-core\n  version: %s\n  installed-size: %s\n' "$(sed -n '1s/^version=//p' "$2")" "${APK_TEST_ISIZE:-$(sed -n '2s/^size=//p' "$2")}" ;;
add)
	[ "$2" = --allow-untrusted ] || exit 2
	v="$(sed -n '1s/^version=//p' "$3")"
	[ "${APK_ADD_FAIL:-}" != "$v" ] || { echo "ERROR: $3: No space left on device" >&2; exit 1; }
	[ "$(cat "$d/apk.installed" 2>/dev/null)" != "$v" ] || exit 0
	[ ! -e "$APK_TEST_BIN" ] || [ -f "$d/apk.installed" ] || { echo "ERROR: xraywrt-core-$v: trying to overwrite opt/xraywrt/bin/xray" >&2; exit 1; }
	tail -n +3 "$3" >"$APK_TEST_BIN" && chmod 755 "$APK_TEST_BIN"
	[ "${APK_ADD_MISMATCH:-}" != "$v" ] || sed -i "s/version)/version) echo Xray xcore-0.0.1; exit 0;; #/" "$APK_TEST_BIN"
	echo "$v" >"$d/apk.installed"
	;;
del) [ "${APK_DEL_FAIL:-0}" = 0 ] || exit 1; [ "$2" = xraywrt-core ] && rm -f "$APK_TEST_BIN" "$d/apk.installed" ;;
*) exit 2 ;;
esac
APK
chmod 755 "$tmpdir/apk-bin/apk"
# Spec 4.5: the pkgcore asset follows the package architecture DISTRIB_ARCH.
OPENWRT_RELEASE_FILE="$tmpdir/openwrt_release"
arch_is() { printf "DISTRIB_ARCH='%s'\n" "$1" >"$OPENWRT_RELEASE_FILE"; }
arch_is aarch64_cortex-a53
PATH="$tmpdir/apk-bin:$PATH"
pkg_installed_names() { [ ! -f "$tmpdir/apk.installed" ] || echo xraywrt-core; }
# The apk database (pkg.sh): the stub's one package and its version.
pkg_version() { [ "$1" != xraywrt-core ] || [ ! -f "$tmpdir/apk.installed" ] || cat "$tmpdir/apk.installed"; }

repo_url=https://github.com/sweep7125/xraywrt-core/releases/download
legacy_url=https://github.com/sweep7125/xraywrt/releases/download
new_version=0.25.1-r1 old_version=0.23.0-r1 release_tag=v0.2.0
new_asset="xraywrt-core_${new_version}_aarch64_cortex-a53.apk"
old_asset="xraywrt-core_${old_version}_aarch64_cortex-a53.apk"
make_core "$tmpdir/pkgcore-core" pkgcore
make_core "$tmpdir/pkgcore-old-core" pkgcoreold
# 8 KiB larger old package: RAM for the new .apk is no RAM for the old one.
{
	head -n -1 "$tmpdir/pkgcore-old-core"
	head -c 8192 /dev/zero | tr '\0' '#'
	echo
	tail -n 1 "$tmpdir/pkgcore-old-core"
} >"$tmpdir/padded" && mv "$tmpdir/padded" "$tmpdir/pkgcore-old-core"
make_apk "$tmpdir/new.apk" "$new_version" "$tmpdir/pkgcore-core"
make_apk "$tmpdir/old.apk" "$old_version" "$tmpdir/pkgcore-old-core"
new_sha="$(sha256sum "$tmpdir/new.apk" | cut -d' ' -f1)"
new_size="$(wc -c <"$tmpdir/new.apk" | tr -d ' ')"
old_sha="$(sha256sum "$tmpdir/old.apk" | cut -d' ' -f1)"
old_size="$(wc -c <"$tmpdir/old.apk" | tr -d ' ')"
release_digest="sha256:$new_sha"
old_available=1
pkgcore_sums="$new_sha  xraywrt-core_0.25.1-r1_aarch64_generic.apk
$new_sha  $new_asset
$new_sha  xraywrt-core_0.25.1-r1_x86_64.apk
$new_sha  luci-app-xraywrt.apk"
# Body routes: NEW_DOWN=1 fails github.com for the new .apk; gh-proxy.com
# serves a bad body, ghproxy.net the real one.
http_fetch() {
	echo "$1" >>"$tmpdir/fetch.log"
	case "$1" in
	"https://gh-proxy.com/$repo_url/"*) echo bad >"$2" ;;
	"https://ghproxy.net/$repo_url/$release_tag/$new_asset") cat "$tmpdir/new.apk" >"$2" ;;
	"$repo_url/$release_tag/SHA256SUMS-core")
		[ -z "${SUMS_ERROR:-}" ] || { FETCH_ERROR="$SUMS_ERROR"; return 1; }
		printf '%s\n' "$pkgcore_sums" >"$2"
		;;
	https://api.github.com/repos/sweep7125/xraywrt-core/releases/latest)
		[ -z "${API_ERROR:-}" ] || { FETCH_ERROR="$API_ERROR"; return 1; }
		jq -nc --arg t "$release_tag" --arg d "$release_digest" --argjson s "$new_size" --arg n "$new_asset" --arg u "${NEW_URL:-$repo_url/$release_tag/$new_asset}" '{tag_name: $t, assets: [
			{name: "luci-app-xraywrt.apk", browser_download_url: "https://example.com/luci-app-xraywrt.apk", digest: "sha256:00", size: 1},
			{name: "xraywrt-core_0.25.1-r1_aarch64_generic.apk", browser_download_url: "https://example.com/generic.apk", digest: $d, size: $s},
			{name: $n, browser_download_url: $u, digest: (if $d == "" then null else $d end), size: $s},
			{name: "xraywrt-core_0.25.1-r1_x86_64.apk", browser_download_url: "https://example.com/x86_64.apk", digest: $d, size: $s}]}' >"$2"
		;;
	"$repo_url/$release_tag/$new_asset") [ "${NEW_DOWN:-0}" = 0 ] || { FETCH_ERROR=network; return 1; }; cat "$tmpdir/new.apk" >"$2" ;;
	"$legacy_url/v0.1.0/$old_asset"|"$repo_url/v0.1.0/$old_asset") [ "$old_available" = 1 ] || { FETCH_ERROR=http_404; return 1; }; cat "$tmpdir/old.apk" >"$2" ;;
	*) FETCH_ERROR=http_404; return 1 ;;
	esac
}
github_latest_tag() {
	echo "redirect $1" >>"$tmpdir/fetch.log"
	[ -n "${REDIRECT_TAG-$release_tag}" ] || return 1
	echo "${REDIRECT_TAG-$release_tag}"
}
# Service stubs (as the low-flash tests): start succeeds when the core on
# flash carries $ready_with.
running=0 ready_with=pkgcore
service_running() { [ "$running" = 1 ]; }
core_service_stop() {
	echo stop >>"$tmpdir/svc.log"
	running=0
}
core_service_start() {
	[ ! -f "$USER_STOP_FILE" ] || return 0
	local tag
	tag="$(tail -n 2 "$XRAY_BIN" 2>/dev/null | grep -o '^#[a-z]*$' | head -1)"
	printf 'start %s\n' "${tag#\#}" >>"$tmpdir/svc.log"
	[ "${tag#\#}" = "$ready_with" ] || return 1
	running=1
}
reset_logs() { rm -f "$tmpdir/apk.log" "$tmpdir/svc.log" "$tmpdir/fetch.log"; }
install_old_pkg() {
	printf 'MemAvailable:   200000 kB\n' >"$MEMINFO_FILE"
	rm -f "$XRAY_BIN" "$tmpdir/apk.installed" "$CORE_VERSION_CACHE"
	mkdir -p "${XRAY_BIN%/*}" "${CORE_JSON_FILE%/*}"
	apk add --allow-untrusted "$tmpdir/old.apk"
	jq -nc --arg a "$old_asset" --arg s "$old_sha" --argjson z "$old_size" --arg v "$old_version" \
		'{channel: "core", tag: "v0.1.0", asset: $a, sha256: $s, size: $z, version: $v, source: "package", installed_at: 1}' >"$CORE_JSON_FILE"
	cp "$CORE_JSON_FILE" "$tmpdir/old.json"
	running=1 ready_with=pkgcore free_kb=1000000 old_available=1
	reset_logs
}
assert_old_pkg_kept() {
	assert_eq "$old_version" "$(cat "$tmpdir/apk.installed" 2>/dev/null)" "$1: old package installed"
	assert_true "$1: old core on flash" cmp -s "$tmpdir/pkgcore-old-core" "$XRAY_BIN"
	assert_true "$1: core.json unchanged" cmp -s "$tmpdir/old.json" "$CORE_JSON_FILE"
	assert_false "$1: RAM stage removed" test -e "$CORE_TMP_DIR"
}

# Rollback origins are fixed: old records default to the legacy repository.
install_old_pkg
mkdir -p "$CORE_TMP_DIR"
core_pkg_old_fetch || fail "legacy rollback: $CORE_OLD_ERROR"
assert_file_contains "$tmpdir/fetch.log" "$legacy_url/v0.1.0/$old_asset" 'legacy rollback origin'
jq '.repo = "sweep7125/xraywrt-core"' "$CORE_JSON_FILE" >"$tmpdir/r" && mv "$tmpdir/r" "$CORE_JSON_FILE"
reset_logs
core_pkg_old_fetch || fail "current rollback: $CORE_OLD_ERROR"
assert_file_contains "$tmpdir/fetch.log" "$repo_url/v0.1.0/$old_asset" 'current rollback origin'
for invalid in '"evil/repo"' '""' 'null'; do
 jq --argjson repo "$invalid" '.repo = $repo' "$CORE_JSON_FILE" >"$tmpdir/r" && mv "$tmpdir/r" "$CORE_JSON_FILE"
 reset_logs
 if core_pkg_old_fetch; then fail "invalid rollback origin accepted: $invalid"; fi
 assert_false 'invalid origin never fetched' test -e "$tmpdir/fetch.log"
done
pass 'rollback origin allowlist and legacy default'

# Candidate rejection must precede package mutation, even with a stopped service.
export VERSION_LINE='Xray 26.11.1 xcore-0.25.1 (rust linux/aarch64)'
for state in 0 1; do
	install_old_pkg
	running="$state"
	printf '{"preserved":true}\n' >"$XRAY_CONFIG"
	cp "$XRAY_CONFIG" "$tmpdir/source-before.json"
	settings_require() { return 0; }
	xray_config_generate() { cp "$1" "$2"; }
	if REJECT=1 core_update 2>/dev/null; then fail 'package config rejection accepted'; fi
	assert_old_pkg_kept 'candidate rejection'
	assert_eq "$state" "$running" 'rejected conversion retains running state'
	assert_true 'source config unchanged' cmp -s "$XRAY_CONFIG" "$tmpdir/source-before.json"
	assert_false 'rejected candidate never installed/removed' grep -qE '^apk (add|del)' "$tmpdir/apk.log"
done
rm -f "$XRAY_CONFIG"
pass 'package candidate config validation before replacement'
install_old_pkg
old_available=0
if core_update 2>/dev/null; then fail 'normal update without prefetched rollback accepted'; fi
assert_old_pkg_kept 'normal unavailable rollback'
assert_false 'rollback refusal never changes service' test -e "$tmpdir/svc.log"
assert_false 'rollback refusal never mutates package' grep -qE '^apk (add|del)' "$tmpdir/apk.log"
pass 'normal update requires rollback before replacement'

install_old_pkg
if VERSION_LINE='Xray 26.11.1 xcore-0.23.0 (rust linux/aarch64)' core_update 2>/dev/null; then fail 'mislabeled package binary accepted'; fi
assert_old_pkg_kept 'mismatched XrayWRT core version'
pass 'package marker must match release package version'

# Release lookup: asset xraywrt-core_<version>_<DISTRIB_ARCH>.apk, API digest only.
core_pkg_resolve || fail "resolve: $CORE_ERROR"
assert_eq "$release_tag:$new_asset:$new_version:$new_sha:$new_size" "$CORE_TAG:$CORE_ASSET:$CORE_PKG_VERSION:$CORE_SHA256:$CORE_SIZE" 'release, asset, version, sha256, size'
assert_eq "$repo_url/$release_tag/$new_asset" "$CORE_URL" 'asset URL'
arch_is x86_64; core_pkg_resolve || fail "resolve x86_64: $CORE_ERROR"
assert_eq xraywrt-core_0.25.1-r1_x86_64.apk "$CORE_ASSET" 'asset of DISTRIB_ARCH'
arch_is aarch64_generic; core_pkg_resolve || fail "resolve aarch64_generic: $CORE_ERROR"
assert_eq xraywrt-core_0.25.1-r1_aarch64_generic.apk "$CORE_ASSET" 'each aarch64 package architecture has its own asset'
arch_is cortex-a53; if core_pkg_resolve; then fail 'asset of a longer architecture accepted'; fi
assert_eq "The core is not available for this router (cortex-a53); the current core is kept. [E:core_arch|cortex-a53]" "$CORE_ERROR" 'architecture matched whole, not as a suffix'
arch_is mipsel_24kc; if core_pkg_resolve; then fail 'missing arch asset accepted'; fi
assert_eq "The core is not available for this router (mipsel_24kc); the current core is kept. [E:core_arch|mipsel_24kc]" "$CORE_ERROR" 'no package for the arch'
arch_is aarch64_cortex-a53
if release_digest='' core_pkg_resolve; then fail 'package without digest accepted'; fi
assert_eq "release sweep7125/xraywrt-core@v0.2.0 publishes no sha256 for $new_asset [E:core_no_checksum|release sweep7125/xraywrt-core@v0.2.0 publishes no sha256 for $new_asset]" "$CORE_ERROR" 'digest required'
NEW_URL="http://example.com/$new_asset" core_pkg_resolve || fail "untrusted API URL should be ignored: $CORE_ERROR"
assert_eq "$repo_url/$release_tag/$new_asset" "$CORE_URL" 'canonical HTTPS asset URL'
if API_ERROR=http_401 core_pkg_resolve; then fail 'API failure accepted'; fi
assert_eq 'cannot read the latest release of sweep7125/xraywrt-core (GitHub API: http_401) [E:core_download|cannot read the latest release of sweep7125/xraywrt-core (GitHub API: http_401)]' "$CORE_ERROR" 'other API errors: no fallback'
if API_ERROR=http_404 core_pkg_resolve; then fail 'no release accepted'; fi
assert_eq 'release sweep7125/xraywrt-core has no releases (GitHub API: http_404)' "$CORE_ERROR" 'no releases'
pass 'pkgcore release lookup'

# API unavailable (spec 4.5): tag from the github.com redirect, sha256 from
# the release's SHA256SUMS-core on github.com, size unknown.
for err in network http_403 http_429 http_502; do
	rm -f "$tmpdir/fetch.log"
	API_ERROR="$err" core_pkg_resolve || fail "fallback on $err: $CORE_ERROR"
	assert_eq "$release_tag:$new_asset:$new_version:$new_sha:" "$CORE_TAG:$CORE_ASSET:$CORE_PKG_VERSION:$CORE_SHA256:$CORE_SIZE" "fallback on $err"
	assert_eq "$repo_url/$release_tag/$new_asset" "$CORE_URL" "fallback asset URL ($err)"
done
assert_eq "https://api.github.com/repos/sweep7125/xraywrt-core/releases/latest
redirect sweep7125/xraywrt-core
$repo_url/$release_tag/SHA256SUMS-core" "$(cat "$tmpdir/fetch.log")" 'API, redirect, SHA256SUMS-core from github.com only'
export API_ERROR=http_403
arch_is x86_64; core_pkg_resolve || fail "fallback x86_64: $CORE_ERROR"
assert_eq xraywrt-core_0.25.1-r1_x86_64.apk "$CORE_ASSET" 'fallback: line of DISTRIB_ARCH'
arch_is aarch64_generic; core_pkg_resolve || fail "fallback aarch64_generic: $CORE_ERROR"
assert_eq xraywrt-core_0.25.1-r1_aarch64_generic.apk "$CORE_ASSET" 'fallback: own aarch64 line'
arch_is mipsel_24kc; if core_pkg_resolve; then fail 'fallback: missing arch accepted'; fi
assert_eq "The core is not available for this router (mipsel_24kc); the current core is kept. [E:core_arch|mipsel_24kc]" "$CORE_ERROR" 'fallback: no line for the arch'
arch_is 64; if core_pkg_resolve; then fail 'fallback: arch suffix of another arch accepted'; fi
arch_is aarch64_cortex-a53
if pkgcore_sums="$pkgcore_sums
$old_sha  $old_asset" core_pkg_resolve; then fail 'fallback: two lines accepted'; fi
assert_eq "release sweep7125/xraywrt-core@v0.2.0 lists more than one xraywrt-core_<version>_aarch64_cortex-a53.apk in SHA256SUMS-core" "$CORE_ERROR" 'fallback: one line only'
if pkgcore_sums="$new_sha  xraywrt-core_1/../x_aarch64_cortex-a53.apk" core_pkg_resolve; then fail 'fallback: bad version accepted'; fi
assert_eq 'release sweep7125/xraywrt-core@v0.2.0 has an invalid package version in xraywrt-core_1/../x_aarch64_cortex-a53.apk' "$CORE_ERROR" 'fallback: version checked'
if pkgcore_sums="nothex  $new_asset" core_pkg_resolve; then fail 'fallback: bad hash accepted'; fi
assert_eq "release sweep7125/xraywrt-core@v0.2.0 publishes no sha256 for $new_asset [E:core_no_checksum|release sweep7125/xraywrt-core@v0.2.0 publishes no sha256 for $new_asset]" "$CORE_ERROR" 'fallback: sha256 checked'
if SUMS_ERROR=http_404 core_pkg_resolve; then fail 'fallback without SHA256SUMS-core accepted'; fi
assert_eq 'release sweep7125/xraywrt-core@v0.2.0 has no SHA256SUMS-core (http_404); GitHub API unavailable (http_403): retry later' "$CORE_ERROR" 'fallback: no SHA256SUMS-core'
if REDIRECT_TAG='' core_pkg_resolve; then fail 'fallback without the redirect accepted'; fi
assert_eq 'cannot reach GitHub (API: http_403) [E:core_download|cannot reach GitHub (API: http_403)]' "$CORE_ERROR" 'fallback: GitHub unreachable'
if REDIRECT_TAG='v1/../x' core_pkg_resolve; then fail 'fallback: bad tag accepted'; fi
assert_eq 'release sweep7125/xraywrt-core has no valid release tag' "$CORE_ERROR" 'fallback: tag checked'
unset API_ERROR
pass 'pkgcore release lookup without the API'

# First install: no core, the package goes in, core.json describes it.
running=0
rm -f "$XRAY_BIN" "$CORE_JSON_FILE" "$tmpdir/apk.installed"
reset_logs
core_update || fail "first install: $CORE_ERROR"
assert_eq "1:1:0:$new_version" "$CORE_UPDATED:$CORE_VERIFIED:$CORE_RESTARTED:$CORE_VERSION" 'first install state'
assert_true 'package core installed' cmp -s "$tmpdir/pkgcore-core" "$XRAY_BIN"
assert_file_contains "$tmpdir/apk.log" "apk add --allow-untrusted $CORE_TMP_DIR/new.apk" 'apk add --allow-untrusted'
jq -e --arg a "$new_asset" --arg s "$new_sha" --argjson z "$new_size" --arg v "$new_version" \
	'(keys | sort) == ["asset","installed_at","repo","sha256","size","source","tag","version"] and .tag == "v0.2.0" and .asset == $a and .sha256 == $s and .size == $z and .version == $v and .source == "package" and .repo == "sweep7125/xraywrt-core"' \
	"$CORE_JSON_FILE" >/dev/null || fail "package core.json: $(cat "$CORE_JSON_FILE")"
assert_false 'stopped service: no service calls' test -e "$tmpdir/svc.log"
assert_false 'RAM stage removed' test -e "$CORE_TMP_DIR"
reset_logs
core_update || fail "up to date: $CORE_ERROR"
assert_eq "0:$new_version" "$CORE_UPDATED:$CORE_VERSION" 'same package version is a no-op'
assert_false 'up to date: no download' grep -q "$new_asset" "$tmpdir/fetch.log"
pass 'pkgcore first install and up to date'

# A package added by hand at the current version has no core.json: write it, so the next update has a rollback source.
rm -f "$CORE_JSON_FILE"
reset_logs
core_update || fail "up to date without core.json: $CORE_ERROR"
assert_eq "0:$new_version" "$CORE_UPDATED:$CORE_VERSION" 'up to date without core.json: still a no-op'
assert_false 'up to date without core.json: no download' grep -q "$new_asset" "$tmpdir/fetch.log"
assert_false 'up to date without core.json: apk untouched' grep -qE '^apk (add|del)' "$tmpdir/apk.log"
jq -e --arg a "$new_asset" --arg s "$new_sha" --argjson z "$new_size" --arg v "$new_version" \
	'(keys | sort) == ["asset","installed_at","repo","sha256","size","source","tag","version"] and .tag == "v0.2.0" and .asset == $a and .sha256 == $s and .size == $z and .version == $v and .source == "package" and .repo == "sweep7125/xraywrt-core"' \
	"$CORE_JSON_FILE" >/dev/null || fail "core.json written for the installed package: $(cat "$CORE_JSON_FILE" 2>&1)"
# An existing record is left alone.
printf '{"source":"package","tag":"keep"}\n' >"$CORE_JSON_FILE"
core_update || fail "up to date with core.json: $CORE_ERROR"
assert_eq '{"source":"package","tag":"keep"}' "$(cat "$CORE_JSON_FILE")" 'an existing core.json is not rewritten'
release_tag=v0.3.0
reset_logs
core_update || fail "same version after tag move: $CORE_ERROR"
assert_eq '{"source":"package","tag":"keep"}' "$(cat "$CORE_JSON_FILE")" 'tag move does not rewrite legacy record'
assert_false 'tag move does not reinstall' grep -qE '^apk (add|del)' "$tmpdir/apk.log"
assert_false 'tag move does not download package' grep -q "$new_asset" "$tmpdir/fetch.log"
release_tag=v0.2.0
pass 'same-version package without core.json gets its record'

# Real apk add at the same version is a no-op, even with a missing binary.
# The verified release asset also supplies rollback without old provenance.
rm -f "$XRAY_BIN" "$CORE_JSON_FILE"
running=1
reset_logs
core_update || fail "same-version repair: $CORE_ERROR"
assert_true 'same-version repair restores binary' cmp -s "$tmpdir/pkgcore-core" "$XRAY_BIN"
assert_eq "1:1:$new_version" "$CORE_UPDATED:$running:$(cat "$tmpdir/apk.installed")" 'repair reports success only with installed core'
assert_eq "apk del xraywrt-core
apk add --allow-untrusted $CORE_TMP_DIR/new.apk" "$(grep -E '^apk (add|del)' "$tmpdir/apk.log")" 'repair forces remove then add'
pass 'same-version package repair restores missing binary'

# Failed repair add: rollback re-adds the staged copy of the verified asset.
rm -f "$XRAY_BIN"
reset_logs
if APK_ADD_FAIL="$new_version" core_update 2>/dev/null; then fail 'failed repair accepted'; fi
assert_file_contains "$tmpdir/apk.log" "apk add --allow-untrusted $CORE_TMP_DIR/old.apk" 'repair rollback re-adds the staged package'
case "$CORE_ERROR" in *'[E:core_restore'*) ;; *) fail "repair rollback code: $CORE_ERROR" ;; esac
assert_eq 0 "$CORE_UPDATED" 'failed repair never reports success'
pass 'failed same-version repair uses the staged rollback'

install_old_pkg
running=0
if APK_ADD_MISMATCH="$new_version" core_update 2>/dev/null; then fail 'post-install version mismatch accepted'; fi
assert_old_pkg_kept 'post-install version mismatch'
assert_eq 0 "$running" 'post-install mismatch preserves stopped state'
assert_eq 0 "$CORE_UPDATED" 'post-install mismatch never reports update success'
pass 'post-install version mismatch rolls back'


# Normal path: apk add over the old package, restart, readiness.
install_old_pkg
core_update || fail "normal update: $CORE_ERROR"
assert_eq '1:1' "$CORE_UPDATED:$CORE_RESTARTED" 'normal path restarts the service itself'
assert_eq $'stop\nstart pkgcore' "$(cat "$tmpdir/svc.log")" 'restart waits for the new core'
assert_eq "apk add --allow-untrusted $CORE_TMP_DIR/new.apk" "$(grep -E '^apk (add|del)' "$tmpdir/apk.log")" 'normal path: apk add over the old package'
assert_file_contains "$tmpdir/apk.log" "apk adbdump $CORE_TMP_DIR/new.apk" 'installed-size from the package metadata'
assert_true 'normal path: old .apk prefetched' grep -q "$old_asset" "$tmpdir/fetch.log"
assert_eq "$new_version" "$(jq -r .version "$CORE_JSON_FILE")" 'core.json updated'
pass 'pkgcore normal path'

# Init distinguishes updater control from a user Stop; an updater start cannot clear Stop.
(
 eval "$(sed -n '/^start_service() {/,/^}/p; /^stop_service() {/,/^}/p' "$ROOT_DIR/rootfs/etc/init.d/xraywrt")"
 rm -f "$USER_STOP_FILE" "$SKIP_START_FILE"
 XRAYWRT_UPDATE_CONTROL=1 stop_service
 assert_false 'internal stop does not set user intent' test -e "$USER_STOP_FILE"
 stop_service
 assert_true 'user Stop sets intent' test -f "$USER_STOP_FILE"
 XRAYWRT_UPDATE_CONTROL=1 start_service
 assert_true 'internal start preserves user Stop' test -f "$USER_STOP_FILE"
 rm -f "$USER_STOP_FILE"
)
pass 'init distinguishes updater control from user Stop'

# The service may become running during installation, requiring the outer fallback.
install_old_pkg
(
 eval "$(sed -n '/^start_service() {/,/^}/p; /^stop_service() {/,/^}/p' "$ROOT_DIR/rootfs/etc/init.d/xraywrt")"
 eval "real_$(declare -f pkg_install_file)"
 pkg_install_file() { real_pkg_install_file "$@" && : >"$tmpdir/fallback-running"; }
 service_running() { [ -f "$tmpdir/fallback-running" ]; }
 XRAYWRT_CLI=/bin/true
 procd_open_instance() { : >"$tmpdir/fallback-started"; }
 procd_set_param() { :; }
 procd_close_instance() { :; }
 function /etc/init.d/xraywrt {
  [ "$1" = restart ] || return 1
  XRAYWRT_UPDATE_CONTROL='' stop_service
  : >"$tmpdir/fallback-dispatched"
  stop_service
  start_service
 }
 rm -f "$USER_STOP_FILE" "$SKIP_START_FILE" "$tmpdir/fallback-running" "$tmpdir/fallback-started" "$tmpdir/fallback-dispatched"
 result="$(core_update_locked)" || fail 'fallback update failed'
 assert_true 'fallback restart was dispatched' test -f "$tmpdir/fallback-dispatched"
 assert_eq true "$(printf '%s' "$result" | jq -r .updated)" 'fallback update completed'
 assert_true 'fallback restart preserves user Stop' test -f "$USER_STOP_FILE"
 assert_false 'fallback restart does not submit a start after user Stop' test -f "$tmpdir/fallback-started"
)
rm -f "$USER_STOP_FILE"
pass 'fallback restart honors Stop before dispatch'
(
 eval "$(sed -n '/^start_service() {/,/^}/p' "$ROOT_DIR/rootfs/etc/init.d/xraywrt")"
 rm -f "$USER_STOP_FILE" "$SKIP_START_FILE"
 XRAYWRT_CLI="$tmpdir/prepare-stop"
 printf '#!/bin/sh\n: >"%s"\n' "$USER_STOP_FILE" >"$XRAYWRT_CLI"
 chmod +x "$XRAYWRT_CLI"
 procd_open_instance() { fail 'internal start continued after Stop during prepare'; }
 XRAYWRT_UPDATE_CONTROL=1 start_service
 assert_true 'Stop during prepare preserved' test -f "$USER_STOP_FILE"
 rm -f "$USER_STOP_FILE"
)
pass 'internal start honors Stop during prepare'

# Stop pressed while the package is installed: the update must not start the service again.
install_old_pkg
(
	eval "real_$(declare -f pkg_install_file)"
	pkg_install_file() { real_pkg_install_file "$@" && : >"$USER_STOP_FILE"; }
	core_update || fail "update with Stop during the install: $CORE_ERROR"
	assert_eq 1 "$CORE_UPDATED" 'update with Stop completes'
	assert_eq 0 "${CORE_RESTARTED:-0}" 'Stop during the install: no restart'
	assert_false 'Stop during the install: the service is not started' grep -q '^start' "$tmpdir/svc.log"
)
rm -f "$USER_STOP_FILE"
pass 'pkgcore update keeps the service stopped after Stop'

# Normal path, the new core does not start: apk del, old .apk by core.json, start.
install_old_pkg
ready_with=pkgcoreold
if core_update 2>/dev/null; then fail 'core that does not start accepted'; fi
assert_eq 'new core failed to start, previous core restored [E:core_restored|new core failed to start]' "$CORE_ERROR" 'normal rollback text'
assert_eq $'stop\nstart pkgcore\nstop\nstart pkgcoreold' "$(cat "$tmpdir/svc.log")" 'old core started again'
assert_file_contains "$tmpdir/fetch.log" "$legacy_url/v0.1.0/$old_asset" 'old .apk downloaded for the rollback'
assert_old_pkg_kept 'normal rollback'
install_old_pkg
ready_with=pkgcoreold
export APK_ADD_FAIL="$new_version"
if core_update 2>/dev/null; then fail 'failed apk add accepted'; fi
unset APK_ADD_FAIL
assert_eq "cannot install $new_asset: ERROR: $CORE_TMP_DIR/new.apk: No space left on device, previous core restored [E:core_restored|cannot install $new_asset: ERROR: $CORE_TMP_DIR/new.apk: No space left on device]" "$CORE_ERROR" 'apk add error text'
assert_eq 1 "$running" 'failed apk add restores running state'
assert_old_pkg_kept 'failed apk add'
pass 'pkgcore normal path rollback'

# Tight flash: installed-size + 4 MiB only fits once the old package is gone.
bin_size="$(wc -c <"$tmpdir/pkgcore-core" | tr -d ' ')"
old_bin="$(wc -c <"$tmpdir/pkgcore-old-core" | tr -d ' ')"
tight_kb=$(((bin_size + 4194304 - old_bin + 1023) / 1024))
[ $((tight_kb * 1024)) -lt $((bin_size + 4194304)) ] || fail 'fixture: tight flash must be below the normal path'
install_old_pkg
free_kb="$tight_kb"
(
 eval "real_$(declare -f pkg_install_file)"
 pkg_install_file() { real_pkg_install_file "$@" && : >"$USER_STOP_FILE"; }
 core_update || fail "tight update with Stop: $CORE_ERROR"
 assert_eq 0 "${CORE_RESTARTED:-0}" 'tight Stop during install: no restart'
 assert_false 'tight Stop during install: no start' grep -q '^start' "$tmpdir/svc.log"
)
rm -f "$USER_STOP_FILE"
pass 'tight update honors Stop during install'

install_old_pkg
free_kb="$tight_kb"
(
 eval "real_$(declare -f pkg_install_file)"
 pkg_install_file() {
  if [[ "$1" == */new.apk ]]; then : >"$USER_STOP_FILE"; return 1; fi
  real_pkg_install_file "$@"
 }
 if core_update 2>/dev/null; then fail 'tight failed install accepted'; fi
 assert_false 'tight rollback after Stop: no start' grep -q '^start' "$tmpdir/svc.log"
 assert_eq "$old_version" "$(cat "$tmpdir/apk.installed")" 'tight rollback restores old package after Stop'
)
rm -f "$USER_STOP_FILE"
pass 'tight rollback honors Stop during failed install'

install_old_pkg
free_kb="$tight_kb"
core_update || fail "tight update: $CORE_ERROR"
assert_eq '1:1' "$CORE_UPDATED:$CORE_RESTARTED" 'tight path restarts the service itself'
assert_eq "apk del xraywrt-core
apk add --allow-untrusted $CORE_TMP_DIR/new.apk" "$(grep -E '^apk (add|del)' "$tmpdir/apk.log")" 'del old, then add new'
assert_eq $'stop\nstart pkgcore' "$(cat "$tmpdir/svc.log")" 'stop before apk del'
assert_file_contains "$tmpdir/fetch.log" "$legacy_url/v0.1.0/$old_asset" 'old .apk fetched before removing the package'
assert_true 'tight path installed the new core' cmp -s "$tmpdir/pkgcore-core" "$XRAY_BIN"
assert_false 'RAM stage removed' test -e "$CORE_TMP_DIR"
install_old_pkg
free_kb="$tight_kb" ready_with=pkgcoreold
if core_update 2>/dev/null; then fail 'tight: core that does not start accepted'; fi
assert_eq 'new core failed to start, previous core restored [E:core_restored|new core failed to start]' "$CORE_ERROR" 'tight rollback text'
assert_eq "apk del xraywrt-core
apk add --allow-untrusted $CORE_TMP_DIR/new.apk
apk del xraywrt-core
apk add --allow-untrusted $CORE_TMP_DIR/old.apk" "$(grep -E '^apk (add|del)' "$tmpdir/apk.log")" 'tight rollback: del new, add old'
assert_old_pkg_kept 'tight rollback'
install_old_pkg
free_kb="$tight_kb" ready_with=nothing
if core_update 2>/dev/null; then fail 'tight: neither core starts accepted'; fi
assert_eq 'new core failed to start; previous core restored, but it did not start either [E:core_restore_unready|new core failed to start]' "$CORE_ERROR" 'neither starts'
pass 'pkgcore tight flash path'

install_old_pkg
free_kb="$tight_kb" ready_with=pkgcoreold
if APK_DEL_FAIL=1 core_update 2>/dev/null; then fail 'failed old-package removal accepted'; fi
assert_old_pkg_kept 'failed package removal'
assert_eq 1 "$running" 'failed package removal restores running state'
install_old_pkg
free_kb="$tight_kb" ready_with=nothing
if APK_DEL_FAIL=1 core_update 2>/dev/null; then fail 'failed package removal/restart accepted'; fi
assert_old_pkg_kept 'failed removal and restart'
assert_eq 'cannot remove the old xraywrt-core package; could not restart the current core [E:core_restart_failed|cannot remove the old xraywrt-core package]' "$CORE_ERROR" 'failed removal never claims restoration'
pass 'failed package removal restarts previous running core'

# Tight flash without the old .apk (or RAM for it): refuse unless --no-rollback.
install_old_pkg
free_kb="$tight_kb" old_available=0
if core_update 2>/dev/null; then fail 'tight without old .apk accepted'; fi
assert_eq "cannot download the installed package $old_asset for a rollback (http_404); --no-rollback installs without it" "$CORE_ERROR" 'old .apk unavailable'
assert_false 'refused: service untouched' test -e "$tmpdir/svc.log"
assert_old_pkg_kept 'old .apk unavailable'
install_old_pkg
free_kb="$tight_kb"
(
	printf 'MemAvailable:   %s kB\n' $(((new_size + 16777216) / 1024 + 2)) >"$MEMINFO_FILE"
	if core_update 2>/dev/null; then fail 'tight without RAM for the old .apk accepted'; fi
	[[ "$CORE_ERROR" == 'not enough RAM for the rollback copy '*'; --no-rollback installs without it' ]] || fail "old .apk RAM: $CORE_ERROR"
	assert_old_pkg_kept 'old .apk RAM'
)
install_old_pkg
rm -f "$CORE_JSON_FILE" "$tmpdir/old.json"
free_kb="$tight_kb"
if core_update 2>/dev/null; then fail 'tight without core.json accepted'; fi
assert_eq "core.json does not name the installed package for a rollback; --no-rollback installs without it" "$CORE_ERROR" 'no core.json'
install_old_pkg
free_kb="$tight_kb" ready_with=pkgcoreold old_available=0
if core_update --no-rollback 2>/dev/null; then fail 'no-rollback start failure must fail'; fi
assert_eq 'new core failed to start; no rollback copy (--no-rollback) [E:core_no_rollback|new core failed to start]' "$CORE_ERROR" 'no-rollback text'
assert_eq "1:$new_version" "$CORE_UPDATED:$(jq -r .version "$CORE_JSON_FILE")" 'no-rollback: new package stays and is recorded'
assert_false 'no-rollback: old .apk never fetched' grep -q "$old_asset" "$tmpdir/fetch.log"
install_old_pkg
free_kb=$((tight_kb - 64))
if core_update 2>/dev/null; then fail 'no flash accepted'; fi
assert_eq "not enough flash: need $(((bin_size + 4194304 + 1048575) / 1048576)) MiB, free $((free_kb / 1024)) MiB [E:core_flash|$(((bin_size + 4194304 + 1048575) / 1048576))|$((free_kb / 1024))]" "$CORE_ERROR" 'flash error uses installed-size'
assert_old_pkg_kept 'no flash'
install_old_pkg
(
	export APK_TEST_ISIZE=$((64 * 1048576))
	free_kb=60000
	if core_update 2>/dev/null; then fail 'installed-size above the flash accepted'; fi
	[[ "$CORE_ERROR" == 'not enough flash: need 68 MiB, '* ]] || fail "installed-size: $CORE_ERROR"
)
pass 'pkgcore tight flash refusals and --no-rollback'

# A channel or file core is not owned by the package: removed before apk add,
# a RAM copy is the rollback.
replace_channel_core() {
	rm -f "$tmpdir/apk.installed"
	install_old
	jq -nc '{channel: "Jolymmiles/Xray-core", tag: "v26.11.1-1424", source: "channel"}' >"$CORE_JSON_FILE"
	running=1 ready_with=pkgcore free_kb=1000000
	reset_logs
}
replace_channel_core
core_update || fail "replace channel core: $CORE_ERROR"
assert_true 'package core replaced the channel core' cmp -s "$tmpdir/pkgcore-core" "$XRAY_BIN"
assert_eq package "$(jq -r .source "$CORE_JSON_FILE")" 'core.json: package'
replace_channel_core
ready_with=old
if core_update 2>/dev/null; then fail 'replace: core that does not start accepted'; fi
assert_eq 'new core failed to start, previous core restored [E:core_restored|new core failed to start]' "$CORE_ERROR" 'channel core restored'
assert_true 'channel core back from RAM' cmp -s "$tmpdir/old" "$XRAY_BIN"
assert_false 'package removed again' test -e "$tmpdir/apk.installed"
assert_eq Jolymmiles/Xray-core "$(jq -r .channel "$CORE_JSON_FILE")" 'core.json still the channel'
assert_eq $'stop\nstart pkgcore\nstop\nstart old' "$(cat "$tmpdir/svc.log")" 'old channel core started'
pass 'pkgcore replaces a channel core'

# Old UCI cannot redirect the package update.
install_old_pkg
running=0
if core_update --file "$tmpdir/local" 2>/dev/null; then fail 'core file install accepted'; fi
assert_old_pkg_kept 'file install refused'
fake_uci_set xraywrt.settings.core_channel XTLS/Xray-core
core_update || fail "legacy UCI package update: $CORE_ERROR"
assert_eq "$new_version" "$(cat "$tmpdir/apk.installed")" 'legacy UCI cannot select alternate core'
pass 'no file install; legacy UCI cannot select a core'

# core-check (spec 4.4): package missing or another version = update.
check() {
	rm -f "$CORE_VERSION_CACHE"
	result="$(core_check_json)" && rc=0 || rc=$?
}
install_old_pkg
check
assert_eq 0 "$rc" 'pkgcore check succeeds'
jq -e --arg v "$old_version" --arg n "$new_version" '.installed == {tag: "v0.1.0", source: "package", version: $v} and .latest.tag == "v0.2.0" and .latest.version == $n and .update_available == true and has("channel_changed") == false and .error == null' <<<"$result" >/dev/null ||
	fail "older package: $result"
core_update >/dev/null 2>&1 || fail "update for check: $CORE_ERROR"
check
jq -e '.update_available == false and .installed.version == .latest.version' <<<"$result" >/dev/null || fail "same version: $result"
mv "$XRAY_BIN" "$tmpdir/package-core.off"
check
jq -e '.update_available == true and .xray_version == null' <<<"$result" >/dev/null || fail "missing package binary: $result"
mv "$tmpdir/package-core.off" "$XRAY_BIN"

apk del xraywrt-core
check
jq -e '.update_available == true and .installed.version == null' <<<"$result" >/dev/null || fail "package missing: $result"
replace_channel_core
check
jq -e '.update_available == true and has("channel_changed") == false' <<<"$result" >/dev/null || fail "channel core: $result"
API_ERROR=http_401 check
assert_eq 1 "$rc" 'pkgcore check failure'
jq -e '.update_available == false and .error == "cannot read the latest release of sweep7125/xraywrt-core (GitHub API: http_401) [E:core_download|cannot read the latest release of sweep7125/xraywrt-core (GitHub API: http_401)]"' <<<"$result" >/dev/null || fail "check error: $result"
install_old_pkg
fake_uci_set xraywrt.settings.core_channel XTLS/Xray-core
check
assert_eq 0 "$rc" 'legacy UCI does not affect package check'
jq -e '.update_available == true and .error == null' <<<"$result" >/dev/null || fail "legacy check: $result"
fake_uci_set xraywrt.settings.core_channel pkgcore
pass 'package core-check'

# Spec 4.1/4.5: the .apk body over github.com, then each proxy, verified;
# the hash never comes through a proxy.
rm -f "$XRAY_BIN" "$CORE_JSON_FILE" "$tmpdir/apk.installed"
reset_logs
API_ERROR=http_403 NEW_DOWN=1 core_update || fail "update over a proxy: $CORE_ERROR"
assert_eq "$new_version" "$(cat "$tmpdir/apk.installed")" 'verified proxy body installed'
assert_eq "$repo_url/$release_tag/$new_asset
https://gh-proxy.com/$repo_url/$release_tag/$new_asset
https://ghproxy.net/$repo_url/$release_tag/$new_asset" "$(grep -F "$new_asset" "$tmpdir/fetch.log" | grep -v SHA256SUMS)" 'github.com, bad gh-proxy.com body, then ghproxy.net'
assert_false 'SHA256SUMS-core never via a proxy' grep -qE '(gh-proxy\.com|ghproxy\.net)/.*SHA256SUMS' "$tmpdir/fetch.log"
assert_eq "$new_sha" "$(jq -r .sha256 "$CORE_JSON_FILE")" 'core.json sha256 from SHA256SUMS-core'
pass 'pkgcore .apk over GitHub proxies'

# Rollback .apk: github.com, then proxies; the bad proxy body is rejected.
install_old_pkg
printf 'MemAvailable:   200000 kB\n' >"$MEMINFO_FILE"
free_kb="$tight_kb" old_available=0
if core_update 2>/dev/null; then fail 'tight without any old .apk route accepted'; fi
assert_eq "$legacy_url/v0.1.0/$old_asset
https://gh-proxy.com/$legacy_url/v0.1.0/$old_asset
https://ghproxy.net/$legacy_url/v0.1.0/$old_asset" "$(grep -F "$old_asset" "$tmpdir/fetch.log")" 'old .apk: every route tried'
assert_eq "cannot download the installed package $old_asset for a rollback (http_404); --no-rollback installs without it" "$CORE_ERROR" 'error of the github.com route'
assert_old_pkg_kept 'old .apk routes'
pass 'rollback .apk over GitHub proxies'
