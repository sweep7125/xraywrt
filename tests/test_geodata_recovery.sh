#!/usr/bin/env bash
# Persistent journal failure handling and both core-start entry paths.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(TMPDIR=/root make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh xray-config.sh subscription.sh service.sh
setup_runtime_paths "$tmpdir"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
RUNTIME_CONFIG="$tmpdir/runtime.json"
printf '{}' >"$RUNTIME_CONFIG"
printf old >"$XRAY_SHARE_DIR/a.dat"
printf old-manual >"$GEODATA_MANUAL_FILE"
printf new >"$tmpdir/upload"
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_stage_file "$tmpdir/upload" new.dat
printf new-manual >"$GEODATA_TMP_DIR/assets/.manual"
GEODATA_FETCHED="$GEODATA_FETCHED .manual"
geodata_publish
(
 cp() {
  [ "$1" != "$GEODATA_MANUAL_FILE.old" ] || return 1
  command cp "$@"
 }
 ln() {
  [ "$2" != "$GEODATA_MANUAL_FILE.old" ] || return 1
  command ln "$@"
 }
 assert_false 'restore failure is not success' geodata_recover
 assert_eq published "$(head -n1 "$XRAY_SHARE_DIR/.geodata-transaction")" 'interrupted recovery must remain uncommitted'
 assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'first old member restored before second restoration fails'
 assert_eq new-manual "$(cat "$GEODATA_MANUAL_FILE")" 'second member still has distinct new bytes'
 assert_true 'restore failure retains full journal' test -f "$XRAY_SHARE_DIR/.geodata-transaction"
 assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat.old")" 'restore failure retains last backup'
 assert_eq old-manual "$(cat "$GEODATA_MANUAL_FILE.old")" 'manual backup retained'
)
geodata_recover
assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'second recovery keeps first old member'
assert_eq old-manual "$(cat "$GEODATA_MANUAL_FILE")" 'second recovery restores remaining old member'
assert_false 'second recovery removes first-install member' test -e "$XRAY_SHARE_DIR/new.dat"
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_stage_file "$tmpdir/upload" new.dat
printf new-manual >"$GEODATA_TMP_DIR/assets/.manual"
GEODATA_FETCHED="$GEODATA_FETCHED .manual"
geodata_publish
# An invalid row must not cause an earlier valid row to be restored/deleted.
printf 'prepare\na.dat 1\n../outside 0\n' >"$XRAY_SHARE_DIR/.geodata-transaction"
assert_false 'traversal in journal rejected as whole' geodata_recover
assert_eq new "$(cat "$XRAY_SHARE_DIR/a.dat")" 'invalid journal does not touch assets'
printf 'published\na.dat 1\nnew.dat 0\n.manual 1\n' >"$XRAY_SHARE_DIR/.geodata-transaction"
geodata_recover
assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'old asset restored'
assert_eq old-manual "$(cat "$GEODATA_MANUAL_FILE")" 'manual metadata restored as set'
assert_false 'first-install file removed on recovery' test -e "$XRAY_SHARE_DIR/new.dat"
pass 'rollback failure, validated journal, first install and manual metadata recovery'

# procd may respawn without init prepare; it must recover under the lock too.
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_publish
(
 eval "$(declare -f lock_acquire | sed '1s/lock_acquire/real_lock_acquire/')"
 lock_acquire() { echo lock >>"$tmpdir/respawn-lock"; real_lock_acquire; }
 settings_load() { return 1; }
 assert_false 'test stops before core start' run_service
 assert_true 'respawn recovery acquires runtime lock' test -s "$tmpdir/respawn-lock"
 assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'respawn recovers before loading/starting core'
 assert_false 'respawn recovery settled journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
)
geodata_recover
pass 'procd respawn recovers under runtime lock before core start'

# The actual init Start -> prepare path must recover before prune/config test.
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_publish
(
 source_init_xraywrt_lib
 setup_runtime_paths "$tmpdir"
 RUNTIME_CONFIG="$tmpdir/runtime.json"
 RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
 XRAY_BIN="$tmpdir/core"
 printf '#!/bin/sh\nexit 0\n' >"$XRAY_BIN"
 chmod +x "$XRAY_BIN"
 XRAYWRT_CLI=boot_cli
 SKIP_START_FILE="$tmpdir/skip-start"
 settings_ensure_generated() { :; }
 settings_load() { :; }
 service_recover() { :; }
 runtime_dirs_init() { :; }
 dns_guard() { :; }
 cron_update() { :; }
 xray_config_key() { return 1; }
 xray_config_generate() { printf '{}' >"$2"; printf 'geodata-ref a.dat\n' >"$2.profile"; }
 geodata_prune() {
  assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'init prepare recovers before pruning'
  assert_false 'init prepare settled journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction"
 }
 xray_config_test_key() { return 1; }
 xray_config_test() { assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'init tests restored assets'; }
 config_check_record() { :; }
 boot_cli() { assert_eq prepare "$1" 'init calls prepare'; with_lock service_prepare 2>"$tmpdir/boot-error" || { cat "$tmpdir/boot-error"; return 1; }; }
 procd_open_instance() { assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'init launches only restored set'; }
 procd_set_param() { :; }
 procd_close_instance() { :; }
 start_service
)
pass 'init boot path recovers before prune, config test and procd launch'

# A directory at the target must not turn mv into a move-inside operation.
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_publish
rm "$XRAY_SHARE_DIR/a.dat"
mkdir "$XRAY_SHARE_DIR/a.dat"
assert_false 'directory target blocks recovery without consuming backup' geodata_recover
assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat.old")" 'directory target retains original backup'
rmdir "$XRAY_SHARE_DIR/a.dat"
geodata_recover
assert_eq old "$(cat "$XRAY_SHARE_DIR/a.dat")" 'recovery succeeds once unsafe target is removed'
pass 'nonregular recovery target cannot consume the only backup'

(
 rm -f "$tmpdir/runtime.json"
 settings_load() { :; }
 runtime_config_build() { assert_eq 1 "$LOCK_DEPTH" 'missing-runtime respawn build is locked'; touch "$tmpdir/build-locked"; return 1; }
 assert_false 'stop test before core spawn' run_service
 assert_true 'missing runtime build reached under lock' test -f "$tmpdir/build-locked"
)
pass 'procd missing-runtime build owns runtime lock'
