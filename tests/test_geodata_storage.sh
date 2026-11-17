#!/usr/bin/env bash
# Flash preparation must preserve old inodes, bound space and clean failed attempts.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh geodata.sh
setup_runtime_paths "$tmpdir"
MEMINFO_FILE=/proc/meminfo
head -c 1048576 /dev/zero >"$XRAY_SHARE_DIR/space.dat"
head -c 1500 /dev/zero >"$tmpdir/upload"
old_inode="$(stat -c %i "$XRAY_SHARE_DIR/space.dat")"
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" space.dat
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 2000 1000 1026 50%% /\n'; }
geodata_publish
assert_eq "$old_inode" "$(stat -c %i "$XRAY_SHARE_DIR/space.dat.old")" 'backup is original inode, not a flash copy'
assert_eq 1500 "$(wc -c <"$XRAY_SHARE_DIR/space.dat" | tr -d ' ')" 'new set fits without old-copy budget'
geodata_settle err
assert_eq "$old_inode" "$(stat -c %i "$XRAY_SHARE_DIR/space.dat")" 'rollback restores original inode without copying'
pass 'hard-linked backup and restore need space only for new bytes'

geodata_stage_begin
geodata_stage_file "$tmpdir/upload" space.dat
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\n/dev/x 2000 1000 1025 50%% /\n'; }
assert_false 'new bytes plus reserve still enforced' geodata_publish
assert_false 'space refusal writes no persistent preparation' test -e "$XRAY_SHARE_DIR/space.dat.new"
geodata_settle err
unset -f df
pass 'precise new-set space boundary'

for name in a b; do printf 'old-%s' "$name" >"$XRAY_SHARE_DIR/$name.dat"; done
geodata_stage_begin
geodata_stage_file "$tmpdir/upload" a.dat
geodata_stage_file "$tmpdir/upload" b.dat
(
 cp() { [ "$2" != "$XRAY_SHARE_DIR/b.dat.new" ] || return 1; command cp "$@"; }
 assert_false 'second flash copy fails before journal' geodata_publish
 geodata_settle err
 assert_false 'failed preparation removes first backup link' test -e "$XRAY_SHARE_DIR/a.dat.old"
 assert_false 'failed preparation removes first new file' test -e "$XRAY_SHARE_DIR/a.dat.new"
 assert_false 'failed preparation removes second backup link' test -e "$XRAY_SHARE_DIR/b.dat.old"
 assert_false 'failed preparation removes temporary journal' test -e "$XRAY_SHARE_DIR/.geodata-transaction.tmp"
 assert_eq old-a "$(cat "$XRAY_SHARE_DIR/a.dat")" 'failed preparation preserves active bytes'
)
pass 'pre-journal write failure cleans all flash preparation'
