#!/usr/bin/env bash
# `xraywrt profiles` and `xraywrt config-check` (spec 5.3, 15) on the
# pinned Go Xray.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh dns.sh lists.sh xray-config.sh core.sh service.sh config.sh
setup_runtime_paths "$tmpdir"
FX="$ROOT_DIR/tests/fixtures/xray"
command -v xray-test >/dev/null || fail 'xray-test missing from the test image'
XRAY_BIN="$(command -v xray-test)"
XRAY_SHARE_DIR=/usr/local/share/xray-test
DNS_AUTO_RESOLVFILE="$tmpdir/resolv"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
mkdir -p "${XRAY_CONFIG%/*}"

assert_eq '[]' "$(config_profiles_json)" 'no config: no profiles'
cp "$FX/src/single.json" "$XRAY_CONFIG"
assert_eq '[]' "$(config_profiles_json)" 'object source: no profiles'
cp "$FX/src/remnawave-array.json" "$XRAY_CONFIG"
jq -e 'type == "array" and length >= 2 and all(type == "string")' <<<"$(config_profiles_json)" >/dev/null ||
	fail "array profiles: $(config_profiles_json)"
assert_eq "$(jq -c '[.[].remarks]' "$FX/src/remnawave-array.json")" "$(config_profiles_json)" 'remarks in order'
jq 'map(.xraywrt["router-profile"] = "DE Frankfurt")' "$FX/src/remnawave-array.json" >"$XRAY_CONFIG"
assert_eq '[]' "$(config_profiles_json)" 'pinned profile: no server list'
jq 'map(.xraywrt["router-profile"] = "nope")' "$FX/src/remnawave-array.json" >"$XRAY_CONFIG"
assert_eq "$(jq -c '[.[].remarks]' "$FX/src/remnawave-array.json")" "$(config_profiles_json)" 'unknown router-profile: the user chooses'
pass 'profiles'

cp "$FX/src/single.json" "$XRAY_CONFIG"
out="$(config_check_json)" || fail "valid config: $out"
jq -e ".ok == true and .error == null" <<<"$out" >/dev/null || fail "valid config: $out"
assert_false 'check publishes nothing' test -e "$RUNTIME_CONFIG"
printf 'proxies:\n  - name: x\n' >/tmp/xraywrt-config.check$$
if out="$(config_check_json /tmp/xraywrt-config.check$$)"; then fail 'YAML must fail'; fi
assert_eq 'config: Clash/Mihomo YAML is not supported [E:config_yaml]' "$(jq -r .error <<<"$out")" 'generator error reported'
jq '.outbounds[0].settings.vnext[0].port = "x"' "$FX/src/single.json" >/tmp/xraywrt-config.check$$
if out="$(config_check_json /tmp/xraywrt-config.check$$)"; then fail 'core must reject'; fi
assert_eq 'Xray rejected the configuration [E:config_rejected]' "$(jq -r .error <<<"$out")" 'core rejection reported'
jq -e '.ok == false and (.output | length > 0)' <<<"$out" >/dev/null || fail "core output kept: $out"
# A14.4: a LuCI Validate upload is RAM in /tmp; the check removes it like save-config.
assert_false 'checked upload removed' test -e /tmp/xraywrt-config.check$$
assert_true 'installed config kept' test -f "$XRAY_CONFIG"
rm -f /tmp/xraywrt-config.check$$
if config_check_json "$tmpdir/other.json" 2>/dev/null; then fail 'other paths refused'; fi
pass 'config-check'
