#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh core.sh
OPENWRT_RELEASE_FILE="$tmpdir/openwrt_release"

# Package architecture is kept exactly, never mapped to a Go release suffix.
for arch in aarch64_cortex-a53 aarch64_generic aarch64_cortex-a72 aarch64_cortex-a76 x86_64 mipsel_24kc; do
	printf "DISTRIB_ARCH='%s'\n" "$arch" >"$OPENWRT_RELEASE_FILE"
	assert_eq "$arch" "$(openwrt_arch)" "exact package architecture $arch"
done
assert_false 'no alternate core architecture mapper' declare -F core_arch
rm -f "$OPENWRT_RELEASE_FILE"
assert_eq '' "$(openwrt_arch)" 'missing architecture does not invent a fallback'
# Actual missing-architecture release refusal is exercised in test_core_pkg.sh.
pass 'exact package architecture without alternate-core fallback'
