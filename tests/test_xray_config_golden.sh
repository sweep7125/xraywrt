#!/usr/bin/env bash
# Golden runtime configs and profiles for every valid source in both modes
# (spec 6); UPDATE_GOLDEN=1 rewrites them. Also determinism (A5.13).

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
golden="$FX/out"

for src in "$FX"/src/*.json; do
	name="$(basename "$src" .json)"
	for mode in proxy-first direct-first; do
		cat "$FX/lst/golden_rules.txt" >"$tmpdir/rules.txt"
		# Own direct sites come first, as the owner would type them.
		[ "$name" != direct-domains ] || cat "$FX/lst/direct_rules.txt" "$FX/lst/golden_rules.txt" >"$tmpdir/rules.txt"
		filter=".mode_override = true | .mode = \"$mode\" | .rules_file = \"$tmpdir/rules.txt\""
		gen "$src" "$filter"
		assert_eq 0 "$rc" "$name $mode: $errtxt"
		cp "$tmpdir/out.json" "$tmpdir/first.json"
		cp "$tmpdir/out.json.profile" "$tmpdir/first.profile"
		gen "$src" "$filter"
		cmp -s "$tmpdir/out.json" "$tmpdir/first.json" || fail "$name $mode: runtime differs between runs"
		cmp -s "$tmpdir/out.json.profile" "$tmpdir/first.profile" || fail "$name $mode: profile differs between runs"
		base="$golden/$name.$mode"
		if [ "${UPDATE_GOLDEN:-0}" = 1 ]; then
			mkdir -p "$golden"
			jq -S . "$tmpdir/out.json" >"$base.json"
			cp "$tmpdir/out.json.profile" "$base.profile"
			continue
		fi
		assert_eq "$(cat "$base.json")" "$(jq -S . "$tmpdir/out.json")" "$name $mode runtime"
		assert_eq "$(cat "$base.profile")" "$prof" "$name $mode profile"
	done
done
pass 'golden runtime configs'
