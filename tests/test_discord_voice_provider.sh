#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
. "$root/rootfs/usr/lib/xraywrt/settings.sh"
. "$root/rootfs/usr/lib/xraywrt/status.sh"
PROFILE_FILE="$tmp/profile"
NFT_APPLIED_FILE="$tmp/nft.applied"
profile_get() { [ "$1" != 'set discord_voice' ] || printf 1; }
settings_uci_get() { printf '%s' "${2:-}"; }
code_message() { printf '%s' "$2"; }
nft_active() { return 0; }
PROVIDER_KEYS=discord_voice PROVIDER_OVERRIDES=
[ "$(settings_bool discord_voice 0)" = 1 ] || { echo 'provider value ignored'; exit 1; }
PROVIDER_OVERRIDES=discord_voice
[ "$(settings_bool discord_voice 0)" = 0 ] || { echo 'override ignored'; exit 1; }
DISCORD_VOICE=1 POLICY_MODE=direct-first
[ "$(status_warnings)" != '' ] || { echo 'unapplied detector did not warn'; exit 1; }
echo 1 >"$NFT_APPLIED_FILE.discord_voice"
[ "$(status_warnings)" = '' ] || { echo 'applied detector warned'; exit 1; }
POLICY_MODE=proxy-first
rm "$NFT_APPLIED_FILE.discord_voice"
[ "$(status_warnings)" = '' ] || { echo 'proxy-first warned'; exit 1; }
echo 'ok - Discord Voice provider and applied readiness'
. "$root/rootfs/usr/lib/xraywrt/nft.sh"
PKG_TMP_DIR="$tmp" NET_FP_FILE="$tmp/net.fp" USER_STOP_FILE="$tmp/stopped"
NFT_TABLE_NAME=xraywrt ROUTE_PROC_ROOT="$tmp/proc"
mkdir -p "$ROUTE_PROC_ROOT/sys/net/netfilter"
settings_require() { :; }
ensure_dir() { mkdir -p "$1"; }
atomic_write() { printf '%s\n' "$2" >"$1"; }
nft_input_hash() { printf '%s' "${DISCORD_VOICE}-${POLICY_MODE}-${DISCORD_ACCOUNTING}"; }
nft_render() { printf '%s\n' "${DISCORD_VOICE}-${POLICY_MODE}-${DISCORD_ACCOUNTING}" >"$1"; }
nft_active() { [ -f "$tmp/table" ]; }
nft() {
 case "$1" in
 -f) [ ! -f "$tmp/fail" ] || return 1; touch "$tmp/table" ;;
 delete) [ ! -f "$tmp/fail-delete" ] || return 1; rm -f "$tmp/table" ;;
 esac
}
nft_fw4_input_apply() { :; }
nft_bypass_restore() { :; }
err_code() { :; }
DISCORD_VOICE=1 POLICY_MODE=direct-first
echo 1 >"$ROUTE_PROC_ROOT/sys/net/netfilter/nf_conntrack_acct"
nft_apply
[ "$(cat "$NFT_APPLIED_FILE.discord_voice")" = 1 ] || { echo 'ready apply not recorded'; exit 1; }
echo 0 >"$ROUTE_PROC_ROOT/sys/net/netfilter/nf_conntrack_acct"
touch "$tmp/fail"
if nft_apply; then echo 'failed transaction accepted'; exit 1; fi
[ "$(cat "$NFT_APPLIED_FILE.discord_voice")" = 1 ] || { echo 'failed apply lost readiness'; exit 1; }
touch "$tmp/fail-delete"
nft_cleanup
[ "$(cat "$NFT_APPLIED_FILE.discord_voice")" = 1 ] || { echo 'failed Stop lost readiness'; exit 1; }
rm "$tmp/fail" "$tmp/fail-delete"
nft_apply
[ "$(cat "$NFT_APPLIED_FILE.discord_voice")" = 0 ] || { echo 'skipped detector marked ready'; exit 1; }
nft_cleanup
[ ! -e "$NFT_APPLIED_FILE.discord_voice" ] || { echo 'successful Stop retained readiness'; exit 1; }
echo 'ok - Discord Voice applied readiness transaction and Stop'
