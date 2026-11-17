#!/usr/bin/env bash
# CLI config-check must not recover a locked update that is awaiting application.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
writer='' checker=''
trap 'kill ${writer:-} ${checker:-} 2>/dev/null || :; rm -rf "$tmpdir"' EXIT
export GEODATA_LOCK_FIXTURE="$tmpdir"
cat >"$tmpdir/setup" <<'SETUP'
PKG_TMP_DIR="$GEODATA_LOCK_FIXTURE/tmp"
PKG_STATE_DIR="$GEODATA_LOCK_FIXTURE/run"
XRAY_SHARE_DIR="$GEODATA_LOCK_FIXTURE/share"
GEODATA_TMP_DIR="$PKG_TMP_DIR/geodata"
XRAY_CONFIG="$GEODATA_LOCK_FIXTURE/source.json"
RUNTIME_CONFIG="$PKG_TMP_DIR/runtime.json"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
XRAY_BIN="$GEODATA_LOCK_FIXTURE/core"
MEMINFO_FILE=/proc/meminfo
settings_load() { :; }
xray_config_generate() { printf '{}' >"$2"; : >"$2.profile"; }
core_version() { echo 1; }
SETUP
{
 echo '#!/bin/ash'
 echo '. "$XRAYWRT_LIB_DIR/constants.sh"; . "$XRAYWRT_LIB_DIR/helpers.sh"; xraywrt_load_modules'
 echo '. "$GEODATA_LOCK_FIXTURE/setup"'
 sed '1,/^usage() {/d' "$ROOT_DIR/rootfs/usr/bin/xraywrt" | sed '1i usage() {'
} >"$tmpdir/cli"
mkdir -p "$tmpdir/share" "$tmpdir/tmp/geodata/assets" "$tmpdir/run"
printf old >"$tmpdir/share/a.dat"
printf new >"$tmpdir/tmp/geodata/assets/a.dat"
printf '{}' >"$tmpdir/source.json"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/core"
chmod +x "$tmpdir/cli" "$tmpdir/core"
ash <<'ASH' >"$tmpdir/writer.out" 2>"$tmpdir/writer.err" &
. "$XRAYWRT_LIB_DIR/constants.sh"; . "$XRAYWRT_LIB_DIR/helpers.sh"; . "$XRAYWRT_LIB_DIR/validate.sh"; . "$XRAYWRT_LIB_DIR/geodata.sh"
. "$GEODATA_LOCK_FIXTURE/setup"
publish_wait() {
 GEODATA_FETCHED=' a.dat'
 geodata_publish || return 1
 touch "$GEODATA_LOCK_FIXTURE/ready"
 while [ ! -f "$GEODATA_LOCK_FIXTURE/release" ]; do sleep 0.02; done
 geodata_settle ok
}
with_lock publish_wait
ASH
writer=$!
for _ in {1..200}; do [ ! -e "$tmpdir/ready" ] || break; sleep 0.02; done
[ -f "$tmpdir/ready" ] || { cat "$tmpdir/writer.err"; fail 'locked update reached published stage'; }
"$tmpdir/cli" config-check >"$tmpdir/check.out" 2>"$tmpdir/check.err" &
checker=$!
sleep 0.3
assert_eq new "$(cat "$tmpdir/share/a.dat")" 'concurrent config-check cannot roll back active update'
assert_eq published "$(head -n1 "$tmpdir/share/.geodata-transaction")" 'concurrent checker cannot remove active journal'
kill -0 "$checker" 2>/dev/null || { cat "$tmpdir/check.out" "$tmpdir/check.err"; fail 'checker waits for update lock'; }
touch "$tmpdir/release"
wait "$writer"; writer=''
wait "$checker"; checker=''
assert_eq new "$(cat "$tmpdir/share/a.dat")" 'successful update remains published after check'
assert_eq true "$(jq -r .ok "$tmpdir/check.out")" 'check succeeds after update commits'
pass 'concurrent CLI config-check serializes journal recovery and publication'

# Lock contention must return a useful error before the synchronous RPC expires.
start_runtime_lock_holder "$tmpdir/run/runtime.flock" "$tmpdir/held"
holder=$LOCK_HOLDER_PID
writer=$holder
start=$(date +%s)
RUNTIME_LOCK_TIMEOUT=120 timeout 8 "$tmpdir/cli" config-check >"$tmpdir/busy.out" 2>"$tmpdir/busy.err" && busy_rc=0 || busy_rc=$?
elapsed=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
writer=''
assert_eq 1 "$busy_rc" 'config-check returns busy rather than RPC-like timeout'
assert_true 'config-check lock wait stays within five seconds plus scheduling' test "$elapsed" -le 6
assert_file_contains "$tmpdir/busy.err" '[E:runtime_busy|' 'bounded contention returns coded busy error'
assert_file_contains "$tmpdir/busy.err" 'Try again' 'busy error explains retry'
pass 'config-check bounds lock wait with a clear retry error'
