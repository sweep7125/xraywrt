#!/usr/bin/env bash
# Geodata (spec 10): fetch missing assets, refs, invalid files, prune,
# manual uploads, geodata-update.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh fetch.sh xray-config.sh
setup_runtime_paths "$tmpdir"
MEMINFO_FILE="$tmpdir/meminfo"
printf 'MemAvailable: 262144 kB\n' >"$MEMINFO_FILE"
srv="$tmpdir/srv"
mkdir -p "$srv"
printf 'site-v1\n' >"$srv/geosite.dat"
printf 'ip-v1\n' >"$srv/geoip.dat"
# Fake https: the url path names a file in $srv; FAIL_URL fails it.
http_fetch() {
	echo "$1 $3" >>"$tmpdir/fetch.log"
	echo "$4" >>"$tmpdir/fetch.mode"
	FETCH_ERROR=""
	if [ "${FAIL_URL:-}" = "$1" ] || [ ! -f "$srv/${1##*/}" ]; then
		FETCH_ERROR=network
		return 1
	fi
	cp "$srv/${1##*/}" "$2"
}
cfg="$tmpdir/run.json"
prof="$cfg.profile"
profile() { printf '%s\n' "$@" >"$prof"; }
share="$XRAY_SHARE_DIR"
rm -f "$share"/*.dat
ensure() {
	rm -f "$tmpdir/fetch.log"
	touch "$tmpdir/fetch.log"
	GEODATA_FETCHED=""
	geodata_ensure "$prof" "$@" 2>"$tmpdir/err" && rc=0 || rc=$?
}

# Names: [A-Za-z0-9._-]+.dat only.
for n in geosite.dat a-b_c.1.dat; do assert_true "$n valid" geodata_name_valid "$n"; done
for n in .dat x.txt ../x.dat a/b.dat 'a b.dat' ''; do assert_false "$n invalid" geodata_name_valid "$n"; done

profile 'geodata geosite.dat https://cdn.example.com/geosite.dat' 'geodata geoip.dat https://cdn.example.com/geoip.dat' \
	'geodata-ref geosite.dat'
ensure
assert_eq 0 "$rc" "fetch missing: $(cat "$tmpdir/err")"
assert_eq 'site-v1' "$(cat "$GEODATA_TMP_DIR/assets/geosite.dat")" 'geosite fetched under its name'
assert_eq 'ip-v1' "$(cat "$GEODATA_TMP_DIR/assets/geoip.dat")" 'unreferenced asset fetched too'
assert_eq ' geosite.dat geoip.dat' "$GEODATA_FETCHED" 'fetched list'
assert_eq "https://cdn.example.com/geosite.dat 67108864" "$(head -n 1 "$tmpdir/fetch.log")" '64 MiB limit'
geodata_publish && geodata_settle ok
assert_eq '' "$GEODATA_FETCHED" 'settled'
printf 'site-v2\n' >"$srv/geosite.dat"
ensure
assert_eq '' "$(cat "$tmpdir/fetch.log")" 'present files are not fetched again'
ensure 1
assert_eq 2 "$(wc -l <"$tmpdir/fetch.log" | tr -d ' ')" 'force fetches every asset'
assert_eq 'geodata' "$(sort -u "$tmpdir/fetch.mode")" 'geodata downloads use the bounded geodata mode'
assert_eq 'site-v1' "$(cat "$share/geosite.dat")" 'force leaves active copy unchanged until tested'
geodata_publish && geodata_settle ok
assert_eq 'site-v2' "$(cat "$share/geosite.dat")" 'forced copy kept'
assert_false 'old copy dropped' test -e "$share/geosite.dat.old"
pass 'fetch missing and force'

printf 'MemAvailable: 32768 kB\n' >"$MEMINFO_FILE"
rm -f "$share/geoip.dat"
ensure
assert_eq "https://cdn.example.com/geoip.dat $((16 * 1048576))" "$(cat "$tmpdir/fetch.log")" 'RAM caps the download'
geodata_publish && geodata_settle ok
printf 'MemAvailable: 262144 kB\n' >"$MEMINFO_FILE"
rm -f "$share/geoip.dat"
FAIL_URL=https://cdn.example.com/geoip.dat ensure
assert_eq 1 "$rc" 'failed download fails'
assert_eq 'geodata geoip.dat: download failed (network) [E:geodata_download|geoip.dat|network]' "$GEODATA_ERROR" 'download error'
assert_eq 1 "$GEODATA_TRANSIENT" 'download failure is transient'
assert_false 'nothing left behind' test -e "$share/geoip.dat"
profile 'geodata geoip.dat http://cdn.example.com/geoip.dat'
ensure
assert_eq 'geodata geoip.dat: url is not https' "$GEODATA_ERROR" 'https only'
profile 'geodata ../x.dat https://cdn.example.com/x.dat'
ensure
assert_eq 1 "$rc" 'unsafe name rejected'
profile 'geodata geoip.dat https://cdn.example.com/geoip.dat'
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 100 99 1024 99%% /\n'; }
ensure
assert_eq 0 "$rc" 'download stages without flash writes'
assert_false 'flash check rejects before publication' geodata_publish
assert_false 'no partial file' test -e "$share/geoip.dat.new"
geodata_settle err
unset -f df
profile 'geodata-ref geosite.dat' 'geodata-ref ext.dat'
ensure
assert_eq 1 "$rc" 'missing ref fails'
assert_eq 'config needs ext.dat, but geodata.assets does not provide it [E:geodata_missing|ext.dat]' "$GEODATA_ERROR" 'missing ref error'
assert_eq 0 "$GEODATA_TRANSIENT" 'missing ref is not transient'
assert_eq 1 "$rc" 'missing reference rejected'
rm -f "$share/geosite.dat"
profile 'geodata-ref geosite.dat'
ensure
assert_eq 'config needs geosite.dat, but geodata.assets does not provide it [E:geodata_missing|geosite.dat]' "$GEODATA_ERROR" 'removed ref file'
pass 'download checks and refs'

# A failed test rejects the entire staged set, not only the named file.
printf 'site-v1\n' >"$share/geosite.dat"
profile 'geodata geosite.dat https://cdn.example.com/geosite.dat' 'geodata geoip.dat https://cdn.example.com/geoip.dat'
ensure 1
geodata_settle err 'failed to load geosite.dat'
assert_eq 'site-v1' "$(cat "$share/geosite.dat")" 'old copy never replaced'
assert_false 'unrelated staged file not partially published' test -e "$share/geoip.dat"
pass 'invalid geodata rejects complete set'

# Prune: not in assets, not referenced, not manual.
rm -f "$share"/*
printf x | tee "$share/geosite.dat" "$share/geoip.dat" "$share/old.dat" "$share/mine.dat" "$share/ref.dat" >/dev/null
printf 'mine.dat\n' >"$GEODATA_MANUAL_FILE"
profile 'geodata geosite.dat https://cdn.example.com/geosite.dat' 'geodata-ref ref.dat' 'geodata-ref geosite.dat'
geodata_prune "$prof"
assert_eq '.manual geosite.dat mine.dat ref.dat' "$(cd "$share" && echo .[!.]* *)" 'prune'
pass 'prune'

# Manual upload boundaries (real core installation is in test_geodata_atomic).
printf 'manual\n' >/tmp/xraywrt-geo-test.$$
if geodata_install_file /tmp/xraywrt-geo-test.$$ ../x.dat 2>/dev/null; then fail 'bad name accepted'; fi
if geodata_install_file "$tmpdir/run.json.profile" x.dat 2>/dev/null; then fail 'file outside /tmp accepted'; fi
ln -sf /tmp/xraywrt-geo-test.$$ /tmp/xraywrt-geo-link.$$
if geodata_install_file /tmp/xraywrt-geo-link.$$ x.dat 2>/dev/null; then fail 'symlink accepted'; fi
rm -f /tmp/xraywrt-geo-test.$$ /tmp/xraywrt-geo-link.$$
pass 'manual upload trust boundaries'

# xray_config_test fetches first and settles by the core's answer.
XRAY_BIN="$tmpdir/xray"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
cat >"$XRAY_BIN" <<'EOF'
#!/bin/sh
[ "$1" != version ] || { echo 'Xray 1.0.0 (Xray)'; exit 0; }
if grep -q bad "$XRAY_LOCATION_ASSET/geosite.dat"; then echo 'failed to load geosite.dat'; exit 23; fi
EOF
chmod 755 "$XRAY_BIN"
echo '{}' >"$cfg"
rm -f "$share/geosite.dat"
profile 'geodata geosite.dat https://cdn.example.com/geosite.dat' 'geodata-ref geosite.dat'
printf 'bad\n' >"$srv/geosite.dat"
if xray_config_test "$cfg" 2>"$tmpdir/err"; then fail 'bad geodata passed'; fi
assert_file_contains "$tmpdir/err" 'failed to load geosite.dat' 'core error names the file'
assert_file_contains "$tmpdir/err" 'Xray rejected the configuration' 'rejection reported'
assert_false 'bad file removed' test -e "$share/geosite.dat"
printf 'good\n' >"$srv/geosite.dat"
xray_config_test "$cfg" 2>"$tmpdir/err" || fail "good geodata: $(cat "$tmpdir/err")"
assert_eq good "$(cat "$share/geosite.dat")" 'good file kept'
FAIL_URL=https://cdn.example.com/geosite.dat
rm -f "$share/geosite.dat"
if xray_config_test "$cfg" 2>/dev/null; then fail 'missing geodata passed'; fi
assert_eq 'geodata geosite.dat: download failed (network) [E:geodata_download|geosite.dat|network]' "$CONFIG_TEST_OUTPUT" 'download error recorded'
touch "$XRAY_BIN"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok" CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
rm -f "$CONFIG_INVALID_FILE"
config_check_record err
assert_false 'failed download does not block hotplug retries' test -e "$CONFIG_INVALID_FILE"
unset FAIL_URL
rm -f "$share/geoip.dat"
printf good >"$share/geosite.dat"
profile 'geodata geoip.dat https://cdn.example.com/geoip.dat' 'geodata-ref geosite.dat'
xray_config_test "$cfg"
assert_file_contains "$prof" '[E:geodata_unverified]' 'automatic unused download exposes an unverified profile warning'
pass 'config test fetches geodata'

# Hot apply may load new files, but this core caches previously loaded files.
# Snapshot content, not mtimes/size: atomic replacement can preserve both.
(
 RUNTIME_CONFIG="$tmpdir/live.json"
 XRAY_SHARE_DIR="$tmpdir/snapshot-share"
 mkdir -p "$XRAY_SHARE_DIR"
 assert_false 'unknown core geodata state requires restart' geodata_unchanged
 printf 'aaaa' >"$XRAY_SHARE_DIR/geosite.dat"
 geodata_snapshot
 assert_true 'unchanged core files permit hot apply' geodata_unchanged
 printf 'new category' >"$XRAY_SHARE_DIR/new.dat"
 assert_true 'new un-cached file permits hot apply' geodata_unchanged
 cp -p "$XRAY_SHARE_DIR/geosite.dat" "$tmpdir/stamp"
 printf 'bbbb' >"$XRAY_SHARE_DIR/geosite.dat"
 touch -r "$tmpdir/stamp" "$XRAY_SHARE_DIR/geosite.dat"
 assert_false 'same size and mtime changed bytes require restart' geodata_unchanged
 geodata_snapshot
 assert_true 'restart records the new bytes' geodata_unchanged
 rm "$XRAY_SHARE_DIR/geosite.dat"
 assert_false 'removed file requires restart' geodata_unchanged
 rm "$XRAY_SHARE_DIR/new.dat"
 geodata_snapshot
 assert_true 'empty share directory is known state' geodata_unchanged
)
pass 'geodata core-start content snapshot'

# Generated user assets use the same download, refresh, prune and bypass path.
source "$ROOT_DIR/tests/xray_gen_lib.sh"
load_modules dns.sh
src_json '{"outbounds":[{"protocol":"freedom"}]}'
gen "$tmpdir/src.json" '.geodata_asset = ["own.dat=https://own.example/geosite.dat"]'
assert_eq 0 "$rc" "user assets generated: $errtxt"
prof="$cfg.profile"
cp "$tmpdir/out.json.profile" "$prof"
rm -f "$share/own.dat"
ensure
assert_eq 0 "$rc" 'generated missing user file downloads'
assert_file_contains "$tmpdir/fetch.log" 'https://own.example/geosite.dat' 'user download URL'
geodata_publish && geodata_settle ok
geodata_prune "$prof"
assert_true 'prune retains user asset' test -f "$share/own.dat"
printf 'user-refresh\n' >"$srv/geosite.dat"
ensure 1
assert_eq user-refresh "$(cat "$GEODATA_TMP_DIR/assets/own.dat")" 'Update force stages user assets'
geodata_publish && geodata_settle ok
PROFILE_FILE="$prof" BYPASS_NTP=0 BYPASS_SUBSCRIPTION_DNS=0
assert_true 'user host receives DNS bypass' grep -qxF own.example <(dns_bypass_hosts)
profile 'mode proxy-first'
geodata_prune "$prof"
assert_false 'removed user asset pruned' test -f "$share/own.dat"
pass 'generated user assets download, refresh, prune and bypass'
