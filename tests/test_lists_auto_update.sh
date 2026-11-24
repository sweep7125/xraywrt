#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh xray-config.sh lists.sh service.sh
setup_runtime_paths "$tmpdir"
LIST_DIR="$tmpdir/lst"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
lists_ensure_files
settings_load() { :; }
subscription_due() { return 1; }
LISTS_INTERVAL=1

# Even the refresh stub must not run on a URL-free cron tick.
(
 lists_update_remote() { echo refresh >>"$tmpdir/unexpected"; echo unchanged; }
 lists_cache_gc() { echo gc >>"$tmpdir/unexpected"; }
 http_fetch() { echo fetch >>"$tmpdir/unexpected"; }
 auto_update
 assert_false 'idle auto-update never refreshes, fetches or runs GC' test -e "$tmpdir/unexpected"
 assert_false 'idle auto-update creates no cache directory' test -d "$POLICY_CACHE_DIR"
)
pass 'auto-update skips remote lists entirely without URLs'

# Count across command substitutions and pipelines, using the real refresh/GC.
eval "$(declare -f lists_urls | sed '1s/lists_urls/original_lists_urls/')"
lists_urls() { echo call >>"$tmpdir/url-calls"; original_lists_urls; }
http_fetch() { echo fetch >>"$tmpdir/fetches"; printf '9.9.9.9\n' >"$2"; }
with_lock() { "$@"; }
auto_update_policy() { echo apply >>"$tmpdir/applied"; }
printf 'https://one.example/list core\nhttps://one.example/list direct\n' >"$RULES_FILE"
printf 'https://two.example/list\n' >"$SRC_LIST_FILE"
mkdir -p "$POLICY_CACHE_DIR"
stale="$(lists_cache_file https://removed.example/list)"
printf '1.1.1.1\n' >"$stale"
auto_update
assert_eq 1 "$(wc -l <"$tmpdir/url-calls" | tr -d ' ')" 'auto-update computes URL set once, including GC'
assert_eq 2 "$(wc -l <"$tmpdir/fetches" | tr -d ' ')" 'each distinct configured URL fetched once'
assert_eq apply "$(cat "$tmpdir/applied")" 'changed cache applies policy'
assert_false 'GC uses the same URL set' test -e "$stale"
pass 'auto-update reuses one URL set for fetch and GC'

# Standalone refresh also computes once; explicit empty input must not recompute.
: >"$tmpdir/url-calls"
lists_update_remote 1 >/dev/null
assert_eq 1 "$(wc -l <"$tmpdir/url-calls" | tr -d ' ')" 'standalone refresh computes URL set once'
: >"$tmpdir/url-calls"
lists_update_remote 0 '' >/dev/null
assert_false 'explicit empty URL set is reused' test -s "$tmpdir/url-calls"
pass 'standalone refresh reuses its URL set'

: >"$tmpdir/url-calls"
LISTS_INTERVAL=0
auto_update
assert_false 'disabled list interval does not compute URLs' test -s "$tmpdir/url-calls"
pass 'disabled interval skips URL collection'

# Partial discovery must never be mistaken for the complete live URL set.
stale_guard="$(lists_cache_file https://guard.example/list)"
printf "1.1.1.1\n" >"$stale_guard"
(
 lists_source() { [ "$1" != src ] || return 1; printf '%s\n' 'https://partial.example/list'; }
 lists_rules_urls() { :; }
 if lists_update_remote 0 >/dev/null 2>&1; then fail 'partial URL discovery must fail'; fi
 assert_true 'failed discovery keeps existing cache' test -f "$stale_guard"
)
(
 lists_source() { printf '%s\n' 'https://partial.example/list'; }
 lists_rules_urls() { printf '%s\n' 'https://other.example/list'; return 1; }
 assert_false 'rules URL discovery failure reaches GC' lists_cache_gc >/dev/null 2>&1
 assert_true 'GC keeps cache after rules discovery failure' test -f "$stale_guard"
)
(
 profile_entries() { printf '%s\n' 'https://partial.example/list'; return 1; }
 assert_false 'profile failure reaches URL discovery' original_lists_urls >/dev/null 2>&1
 assert_false 'profile failure reaches standalone refresh' lists_update_remote 0 >/dev/null 2>&1
 assert_true 'profile failure keeps cache' test -f "$stale_guard"
)
(
 LISTS_INTERVAL=1
 lists_urls() { printf '%s\n' 'https://partial.example/list'; return 1; }
 lists_update_remote() { echo called >>"$tmpdir/unexpected-cron-refresh"; }
 assert_false 'cron reports URL discovery failure' auto_update >/dev/null 2>&1
 assert_false 'cron does not refresh after failed discovery' test -e "$tmpdir/unexpected-cron-refresh"
 assert_true 'cron keeps cache after failed discovery' test -f "$stale_guard"
)
(
 lists_source() { printf '%s\n' 'partial'; return 1; }
 assert_false 'resolve reports source failure' lists_resolve dst "$tmpdir/out4" "$tmpdir/out6" >/dev/null 2>&1
 assert_false 'resolve removes partial source' test -e "$PKG_TMP_DIR/list.dst.$$"
)
(
 lists_rule_targets() { printf '%s\n' core; return 1; }
 assert_false 'rule target failure reaches URL discovery' original_lists_urls >/dev/null 2>&1
 assert_true 'rule target failure keeps cache' test -f "$stale_guard"
)
(
 lists_source() { :; }
 lists_rules_urls() { :; }
 lists_update_remote 0 >/dev/null
 assert_false 'successful empty discovery cleans stale cache' test -f "$stale_guard"
)
pass 'URL discovery fails closed without preventing empty-source cleanup'
stale_guard2="$(lists_cache_file https://guard2.example/list)"
printf "1.1.1.1\n" >"$stale_guard2"
(
 XRAY_CONFIG="$tmpdir/config-present"
 : >"$XRAY_CONFIG"
 profile_ensure() { return 1; }
 http_fetch() { echo called >>"$tmpdir/unexpected-profile-fetch"; }
 assert_false 'profile failure reaches refresh' lists_update_remote 1 >/dev/null 2>&1
 assert_false 'profile failure prevents fetch' test -e "$tmpdir/unexpected-profile-fetch"
 assert_true 'profile failure preserves cache' test -f "$stale_guard2"
)
(
 XRAY_CONFIG="$tmpdir/config-present"
 profile_ensure() { echo ensure >>"$tmpdir/ensure-calls"; }
 profile_get() { echo direct-first; }
 lists_source() { echo "$POLICY_MODE" >>"$tmpdir/modes"; }
 lists_rules_urls() { :; }
 lists_update_remote 0 >/dev/null
 assert_eq 1 "$(wc -l <"$tmpdir/ensure-calls" | tr -d ' ')" 'profile ensured once before URL snapshot'
 assert_eq 'direct-first' "$(sort -u "$tmpdir/modes")" 'URL sources use ensured profile mode'
)
pass 'profile is checked before URL discovery'
printf "1.1.1.1\n" >"$stale_guard2"
(
 RULES_FILE="$tmpdir"
 assert_false 'rules read error reaches refresh' lists_update_remote 0 >/dev/null 2>&1
 assert_true 'rules read error preserves cache' test -f "$stale_guard2"
)
pass 'rules read error preserves cache'

# A failed discovery cannot justify deleting an existing hourly schedule.
(
 settings_require() { :; }
 cron_sync() { printf '%s\n' "$2" >"$tmpdir/cron-enabled"; }
 SUBSCRIPTION_INTERVAL=0 SUBSCRIPTION_URL='' LISTS_INTERVAL=1 CRON_MINUTE=17
 printf 'existing\n' >"$tmpdir/cron-enabled"
 lists_urls() { printf '%s\n' 'https://partial.example/list'; return 1; }
 assert_false 'cron schedule reports discovery failure' cron_update
 assert_eq existing "$(cat "$tmpdir/cron-enabled")" 'failed discovery leaves cron untouched'
 lists_urls() { :; }
 cron_update
 assert_eq 0 "$(cat "$tmpdir/cron-enabled")" 'empty list schedule is disabled'
 lists_urls() { echo called >"$tmpdir/unexpected-cron-discovery"; return 1; }
 SUBSCRIPTION_INTERVAL=1 SUBSCRIPTION_URL='https://subscription.example/'
 cron_update
 assert_eq 1 "$(cat "$tmpdir/cron-enabled")" 'subscription alone enables cron'
 assert_false 'subscription schedule needs no list discovery' test -e "$tmpdir/unexpected-cron-discovery"
 SUBSCRIPTION_INTERVAL=0 LISTS_INTERVAL=0
 cron_update
 assert_eq 0 "$(cat "$tmpdir/cron-enabled")" 'disabled intervals disable cron'
 assert_false 'disabled lists need no discovery' test -e "$tmpdir/unexpected-cron-discovery"
)
pass 'cron schedule preserves existing entry on discovery failure'

(
 source "$XRAYWRT_LIB_DIR/subscription.sh"
 settings_load() { :; }
 cron_update() { :; }
 lists_urls() { echo call >>"$tmpdir/settled-urls"; printf '%s\n' 'https://one.example/list'; }
 lists_update_remote() { printf '%s\n' "$2" >"$tmpdir/settled-snapshot"; echo changed; }
 with_lock() { echo apply >>"$tmpdir/settled-applied"; }
 result="$(subscription_settled applied)"
 assert_eq applied "$result" 'subscription preserves result'
 assert_eq 1 "$(wc -l <"$tmpdir/settled-urls" | tr -d ' ')" 'subscription discovers URLs once'
 assert_eq 'https://one.example/list' "$(cat "$tmpdir/settled-snapshot")" 'subscription passes discovered snapshot'
 assert_eq apply "$(cat "$tmpdir/settled-applied")" 'changed lists applied'
 lists_update_remote() { echo changed; return 1; }
 : >"$tmpdir/settled-applied"
 result="$(subscription_settled applied)"
 assert_eq applied "$result" 'partial refresh retains subscription result'
 assert_eq apply "$(cat "$tmpdir/settled-applied")" 'partially changed lists still applied'
 lists_urls() { :; }
 lists_update_remote() { echo called >"$tmpdir/unexpected-settled-refresh"; }
 subscription_settled applied >/dev/null
 assert_false 'empty subscription URLs skip refresh' test -e "$tmpdir/unexpected-settled-refresh"
 lists_urls() { echo 'https://partial.example/list'; return 1; }
 subscription_settled applied >/dev/null
 assert_false 'failed subscription discovery skips refresh' test -e "$tmpdir/unexpected-settled-refresh"
)
pass 'subscription reuses discovered URL snapshot'
