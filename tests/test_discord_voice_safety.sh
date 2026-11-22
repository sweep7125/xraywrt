#!/usr/bin/env bash
# The Discord Voice trial must not alter Xray routing or listeners.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"

src_json '{"outbounds":[{"tag":"proxy","protocol":"vless"}],"routing":{"rules":[{"network":"udp","outboundTag":"proxy"}]}}'
gen "$tmpdir/src.json"
assert_eq 0 "$rc" "default generation: $errtxt"
baseline="$out"
prof_lacks 'warn Discord Voice is unavailable; the detector remains off.'
gen "$tmpdir/src.json" '.discord_voice = true'
assert_eq 0 "$rc" "requested generation: $errtxt"
assert_eq "$baseline" "$out" 'unsupported detector leaves routing and listeners unchanged'
prof_lacks 'warn Discord Voice is unavailable; the detector remains off.'
pass 'Discord Voice trial leaves Xray routing and listeners unchanged'

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh dns.sh xray-config.sh lists.sh
setup_runtime_paths "$tmpdir"
settings_load
assert_eq 0 "$DISCORD_VOICE" 'default detector is off'
printf 'profile-schema 1\nfake-enabled 0\nmode direct-first\nset discord_voice 1\n' >"$PROFILE_FILE"
PROVIDER_KEYS=''
settings_load
assert_eq 1 "$DISCORD_VOICE" 'fresh settings load honors provider ON'
fake_uci_set xraywrt.settings.provider_override discord_voice
fake_uci_set xraywrt.settings.discord_voice 0
settings_load
assert_eq 0 "$DISCORD_VOICE" 'explicit OFF overrides provider ON'
printf 'profile-schema 1\nfake-enabled 0\nmode proxy-first\nset discord_voice 0\n' >"$PROFILE_FILE"
fake_uci_set xraywrt.settings.discord_voice 1
settings_load
assert_eq 1 "$DISCORD_VOICE" 'explicit ON preference is retained in proxy-first'
assert_eq null "$(xray_params_json | jq -r .discord_voice)" 'detector does not affect generator inputs'
pass 'Discord Voice honors provider preference and explicit user overrides'
