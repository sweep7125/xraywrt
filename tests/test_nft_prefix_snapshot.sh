#!/usr/bin/env bash
set -e
source "$(dirname "$0")/testlib.sh"
set +u
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/rootfs/usr/lib/xraywrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/xraywrt/nft.sh"
PKG_TMP_DIR="$tmpdir/tmp"; mkdir -p "$PKG_TMP_DIR"
NFT_APPLIED_FILE="$tmpdir/applied"; NET_FP_FILE="$tmpdir/net"
USER_STOP_FILE="$tmpdir/stopped"; RULES_FILE="$tmpdir/rules"
RUNTIME_CONFIG="$tmpdir/runtime"; PROFILE_FILE="$tmpdir/profile"
SRC_LIST_FILE="$tmpdir/src"; DIRECT_SRC_LIST_FILE="$tmpdir/direct"
POLICY_CACHE_DIR="$tmpdir/cache"; mkdir -p "$POLICY_CACHE_DIR"
settings_require() { :; }; route_ipv6_enabled() { return 0; }
ip() { printf '%s\n' "$*" >>"$tmpdir/ip"; case "$*" in *'table main') echo '192.0.2.0/24 dev br-lan' ;; esac; }
nft_line() { printf '%s\n' "$*" >>"$tmpdir/lines"; }
nft_render() { nft_render_base; : >"$1"; }
ensure_dir() { mkdir -p "$1"; }; nft_active() { return 1; }
nft() { :; }; nft_discord_readiness_save() { :; }; nft_bypass_restore() { :; }; nft_fw4_input_apply() { :; }
atomic_write() { printf '%s\n' "$2" >"$1"; }
nft_apply
[ "$(wc -l <"$tmpdir/ip" | tr -d ' ')" = 4 ] || { echo 'expected four ip queries' >&2; exit 1; }
grep -q 'localv4 { 192.0.2.0/24 }' "$tmpdir/lines"
pass 'nft apply shares one prefix snapshot between hash and render'
