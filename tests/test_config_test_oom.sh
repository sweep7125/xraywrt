#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh xray-config.sh
setup_runtime_paths "$tmpdir"
XRAY_DIR="$tmpdir/xray"
XRAY_BIN="$tmpdir/core"
export CORE_OOM_LOG="$tmpdir/oom.log"
cat >"$XRAY_BIN" <<'CORE'
#!/bin/sh
[ "$1" != version ] || { echo 'Xray 1.2.3 (Xray, Penetrates Everything.)'; exit 0; }
CORE
chmod +x "$XRAY_BIN"
# Rewrite only this test copy; production has no environment-controlled proc path.
sed "s|/proc/self/oom_score_adj|$tmpdir/oom_score_adj|g" "$XRAYWRT_LIB_DIR/xray-config.sh" >"$tmpdir/config-test.sh"
source "$tmpdir/config-test.sh"
export CORE_OOM_FILE="$tmpdir/oom_score_adj"
printf '\ncat "$CORE_OOM_FILE" >"$CORE_OOM_LOG" 2>/dev/null || true\n' >>"$XRAY_BIN"
cp "$ROOT_DIR/tests/fixtures/xray/out/single.proxy-first.json" "$XRAY_CONFIG"
if ! xray_config_test "$XRAY_CONFIG" 2>"$tmpdir/test.err"; then
 fail "standalone config test: $(cat "$tmpdir/test.err")"
fi
assert_eq '' "$(cat "$tmpdir/test.err")" 'config test needs no service module and emits no lookup errors'
assert_eq 1000 "$(cat "$CORE_OOM_LOG")" 'checker increases OOM priority before core execution'
rm "$CORE_OOM_FILE"
mkdir "$CORE_OOM_FILE"
assert_true 'unwritable OOM score is nonfatal' xray_config_test "$XRAY_CONFIG"
pass 'config test works without service module and raises OOM score'

# The generator parses an up to 8 MiB source, so it is the first OOM victim too.
mkdir "$tmpdir/bin"
printf '#!/bin/sh\ncat "$CORE_OOM_FILE" >"$CORE_OOM_LOG" 2>/dev/null || true\nexec "%s/rootfs/usr/bin/xraywrt-json" "$@"\n' "$ROOT_DIR" >"$tmpdir/bin/xraywrt-json"
chmod +x "$tmpdir/bin/xraywrt-json"
rmdir "$CORE_OOM_FILE"
rm -f "$CORE_OOM_LOG"
lists_profile_filter() { :; }
xray_params_json() { cat "$ROOT_DIR/tests/fixtures/xray/params/default.json"; }
PATH="$tmpdir/bin:$PATH" xray_config_generate "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$tmpdir/generated.json" ||
 fail 'generation under the OOM stub'
assert_eq 1000 "$(cat "$CORE_OOM_LOG")" 'generator increases OOM priority before parsing'
pass 'generator raises OOM score'
