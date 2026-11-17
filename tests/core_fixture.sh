# shellcheck shell=bash
# Shared setup of the core_update tests: Xray stub, release fixture, flash/RAM stubs.
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh fetch.sh pkg.sh core.sh
# No xraywrt-core package unless a test installs one.
pkg_installed_names() { :; }
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/core-update"
CORE_JSON_FILE="$tmpdir/etc/core.json"
XRAY_BIN="$tmpdir/opt/bin/xray"
MEMINFO_FILE="$tmpdir/meminfo"
printf 'MemAvailable:   200000 kB\n' >"$MEMINFO_FILE"
core_arch() { echo arm64-v8a; }
free_kb=1000000
core_free_kb() { echo "$free_kb"; }
export CORE_TEST_LOG="$tmpdir/core.log"

# Xray stub: `version` prints $VERSION_LINE; `run -test -c F` logs F's
# content and fails when REJECT=1. Padding makes it a few KiB.
make_core() {
	cat >"$1" <<'CORE'
#!/bin/sh
case "$1" in
version) printf '%s\nA unified platform for anti-censorship.\n' "${VERSION_LINE:-Xray 26.11.1-1424 (Xray, Penetrates Everything.)}"; exit "${VERSION_RC:-0}" ;;
run)
	[ "$2" = -test ] && [ "$3" = -c ] || exit 2
	cat "$4" >>"$CORE_TEST_LOG"
	[ "${REJECT:-0}" = 1 ] && { echo 'Failed to start: main: failed to load config files: [x] > bad'; exit 23; }
	echo 'Configuration OK.'
	;;
*) exit 2 ;;
esac
CORE
	printf '#%s\n' "$2" >>"$1"
	chmod 644 "$1"
}
make_core "$tmpdir/asset" release
asset_sha="$(sha256sum "$tmpdir/asset" | cut -d' ' -f1)"
asset_size="$(wc -c <"$tmpdir/asset" | tr -d ' ')"
release_tag=v26.11.1-1424
http_fetch() {
	echo "$1" >>"$tmpdir/fetch.log"
	case "$1" in
	*api.github.com*)
		jq -nc --arg t "$release_tag" --arg d "sha256:$asset_sha" --arg s "$asset_size" \
			'{tag_name: $t, assets: [{name: "Xray-linux-arm64-v8a", browser_download_url: "https://example.com/Xray-linux-arm64-v8a", digest: $d, size: ($s | tonumber)}]}' >"$2"
		;;
	https://example.com/Xray-linux-arm64-v8a) cat "$tmpdir/asset" >"$2" ;;
	*) FETCH_ERROR=http_404; return 1 ;;
	esac
}
install_old() {
	mkdir -p "${XRAY_BIN%/*}"
	make_core "$XRAY_BIN" old
	chmod 755 "$XRAY_BIN"
	cp "$XRAY_BIN" "$tmpdir/old"
	rm -f "$CORE_VERSION_CACHE" "$CORE_JSON_FILE" "$CORE_TEST_LOG" "$tmpdir/fetch.log"
}
assert_old_kept() {
	assert_true "$1: old core byte-identical" cmp -s "$XRAY_BIN" "$tmpdir/old"
	assert_false "$1: no core.json" test -e "$CORE_JSON_FILE"
	assert_false "$1: no candidate left on flash" test -e "$XRAY_BIN.new"
	assert_false "$1: RAM stage removed" test -e "$CORE_TMP_DIR"
	assert_eq 0 "$CORE_UPDATED" "$1: not updated"
}
