#!/usr/bin/env bash
# core version and core_candidate_test (spec 4.3): the candidate's `version`
# and `run -test` on the generated runtime config, or a base config.

# shellcheck disable=SC2030,SC2031,SC2154 # subshell stubs; tmpdir and asset_* come from core_fixture.sh
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/core_fixture.sh"
service_running() { return 1; }
assert_eq /etc/xraywrt/core.json "$(. "$ROOT_DIR/rootfs/usr/lib/xraywrt/constants.sh"; echo "$CORE_JSON_FILE")" 'core source record lives in /etc/xraywrt (spec 4.1)'

# Candidate version: exit 0 and a first line "Xray <version> ...".
make_core "$tmpdir/cand" c
chmod 755 "$tmpdir/cand"
assert_eq 26.11.1-1424 "$(core_version "$tmpdir/cand")" 'version from first line of `xray version`'
for bad in 'Mihomo Meta v1.19.30 linux' 'Xray' 'xray 1.0' 'Xray ../x'; do
	if VERSION_LINE="$bad" core_version "$tmpdir/cand" >/dev/null; then fail "non-Xray version accepted: $bad"; fi
done
if VERSION_RC=1 core_version "$tmpdir/cand" >/dev/null; then fail 'failing `version` accepted'; fi
install_old
assert_eq 26.11.1-1424 "$(core_version)" 'installed core version'
assert_eq 26.11.1-1424 "$(sed -n 1p "$CORE_VERSION_CACHE")" 'installed version cached'
VERSION_LINE='Xray 1.0.0' core_version "$tmpdir/cand" >/dev/null
assert_eq 26.11.1-1424 "$(sed -n 1p "$CORE_VERSION_CACHE")" 'candidate does not touch the installed cache'
# apk replaces the core keeping the packaged (older) mtime: the cache must not survive it.
printf '#!/bin/sh\necho "Xray 26.10.28-1202 (xcore)"\n' >"$XRAY_BIN.pkg"
chmod 755 "$XRAY_BIN.pkg"
touch -d '2026-10-17 21:45:38' "$XRAY_BIN.pkg"
mv -f "$XRAY_BIN.pkg" "$XRAY_BIN"
assert_eq 26.10.28-1202 "$(core_version)" 'cache dropped when apk replaces the core with an older mtime'
pass 'core version'


# Without config.json the candidate tests a router-only base config.
export VERSION_LINE='Xray 26.11.1-1424 xcore-0.25.1 (rust linux/aarch64)'
ensure_dir "$CORE_TMP_DIR"
install_old
chmod 755 "$tmpdir/asset"
core_candidate_test "$tmpdir/asset" || fail "base config test: $CORE_ERROR"
jq -e '.inbounds[0].protocol == "tunnel" and .outbounds[0].protocol == "freedom"' "$CORE_TEST_LOG" >/dev/null || fail 'base config not tested'
pass 'candidate base-config test'

# Spec 4.3 step 4: with config.json the candidate tests the runtime config
# generated from it (router inbounds, provider outbounds), not the base one.
install_old
load_modules xray-config.sh dns.sh lists.sh
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
jq '.outbounds[0].tag = "provider-probe"' "$ROOT_DIR/tests/fixtures/xray/src/single.json" >"$XRAY_CONFIG"
: >"$XRAY_SHARE_DIR/geoip.dat"
core_candidate_test "$tmpdir/asset" || fail "generated config test: $CORE_ERROR"
jq -e '(.outbounds | map(.tag) | index("provider-probe")) == 0 and (.inbounds | map(.tag) | index("xraywrt-tproxy4")) != null' "$CORE_TEST_LOG" >/dev/null ||
	fail "candidate not tested on the generated runtime config: $(cat "$CORE_TEST_LOG")"
# A config.json the generator rejects refuses the update.
echo '{"outbounds": []}' >"$XRAY_CONFIG"
if core_candidate_test "$tmpdir/asset" 2>/dev/null; then fail 'candidate accepted with a rejected config.json'; fi
assert_eq 'cannot generate the runtime config: config: no outbounds [E:config_outbounds]' "$CORE_ERROR" 'generation failure text'
rm -f "$XRAY_CONFIG"
pass 'candidate tests the generated runtime config'

# Geodata the saved config needs but share/ lacks (reinstall after an uninstall)
# must not block the core install: the base config is tested instead.
install_old
cp "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$XRAY_CONFIG"
rm -f "$XRAY_SHARE_DIR/geoip.dat"
core_candidate_test "$tmpdir/asset" || fail "test without geodata: $CORE_ERROR"
jq -e '(.inbounds | map(.tag) | index("xraywrt-tproxy4")) == null and .outbounds[0].tag == null' "$CORE_TEST_LOG" >/dev/null ||
	fail "candidate not tested on the base config: $(cat "$CORE_TEST_LOG")"
rm -f "$XRAY_CONFIG"
pass 'missing geodata tests the base config'

# A rejecting core is reported with its last line.
if REJECT=1 core_candidate_test "$tmpdir/asset" 2>/dev/null; then fail 'rejected config accepted'; fi
assert_eq 'new core rejects the current config: Failed to start: main: failed to load config files: [x/ > bad [E:core_config|Failed to start: main: failed to load config files: [x/ > bad]' "$CORE_ERROR" 'run -test failure text'
pass 'candidate rejection text'
