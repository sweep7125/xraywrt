#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh
assert_true 'Xray API module exists' test -f "$XRAYWRT_LIB_DIR/xray-api.sh"
load_modules xray-api.sh
export API_CALLS="$tmpdir/calls" API_FIXTURE="$ROOT_DIR/tests/fixtures/xray-api/bi-override.json" API_FAIL=0
XRAY_BIN="$tmpdir/xray"
cat >"$XRAY_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$API_CALLS"
[ "$API_FAIL" = 0 ] || { echo 'API unavailable' >&2; exit 1; }
[ "$2" != bi ] || cat "$API_FIXTURE"
STUB
chmod +x "$XRAY_BIN"
assert_eq "$(jq -c . "$API_FIXTURE")" "$(xray_api_bi main)" 'bi JSON normalized through JSON helper'
assert_eq 'api bi --server=unix:/var/run/xraywrt/api.sock --timeout=3 -json -- main' "$(tail -1 "$API_CALLS")" 'bi server timeout and JSON flag'
xray_api_bo main node-b
assert_eq 'api bo --server=unix:/var/run/xraywrt/api.sock --timeout=3 -b main -- node-b' "$(tail -1 "$API_CALLS")" 'bo pin syntax'
xray_api_bo main ''
assert_eq 'api bo --server=unix:/var/run/xraywrt/api.sock --timeout=3 -b main -r' "$(tail -1 "$API_CALLS")" 'bo remove syntax'
export API_FAIL=1
assert_false 'bi propagates API error' xray_api_bi main
assert_false 'bo propagates API error' xray_api_bo main node-b
export API_FAIL=0 API_FIXTURE="$tmpdir/bad"
printf 'not JSON\n' >"$API_FIXTURE"
assert_false 'bi rejects malformed JSON' xray_api_bi main
printf '[]\n' >"$API_FIXTURE"
assert_false 'bi rejects non-object JSON' xray_api_bi main
pass 'Xray bi/bo wrappers'

# B3: runtime selectors are prefixes; UI targets are actual outbound tags.
load_modules settings.sh
RUNTIME_CONFIG="$tmpdir/runtime.json"
cp "$ROOT_DIR/tests/fixtures/xray-api/config.json" "$RUNTIME_CONFIG"
service_running() { return 0; }
export API_FIXTURE="$ROOT_DIR/tests/fixtures/xray-api/bi-override.json"
# Faithful UCI show quoting, including spaces and apostrophes in tag names.
uci_entries=('backup=node-b')
uci() {
 [ "${1:-}" != -q ] || shift
 local op="$1" value="${2:-}" item
 case "$op" in
 show) printf '%s=' "$value"; for item in "${uci_entries[@]}"; do printf "'%s' " "${item//\'/\'\\\'\'}"; done; printf '\n' ;;
 revert) printf 'revert %s\n' "$value" >>"$tmpdir/uci.calls"; uci_entries=("${uci_saved[@]}") ;;
 del_list) local remaining=(); for item in "${uci_entries[@]}"; do [ "$item" = "${value#*=}" ] || remaining+=("$item"); done; uci_entries=("${remaining[@]}") ;;
 add_list) [ "${UCI_FAIL:-}" != add_list ] || return 1; uci_entries+=("${value#*=}") ;;
 commit) : ;;
 *) fail "unexpected uci: $op $value" ;;
 esac
}
jq '.routing.balancers[0].fallbackTag = "node-b" | del(.routing.balancers[1].fallbackTag)' "$RUNTIME_CONFIG" >"$tmpdir/fallback.json"
cp "$tmpdir/fallback.json" "$RUNTIME_CONFIG"
result="$(balancers_json)"
assert_eq node-b "$(jq -r '.balancers[0].fallback' <<<"$result")" 'configured fallback returned'
assert_eq null "$(jq -r '.balancers[1].fallback' <<<"$result")" 'absent fallback is null'
assert_eq 'main backup' "$(jq -r '[.balancers[].tag] | join(" ")' <<<"$result")" 'all runtime balancers listed'
assert_eq 'node-a node-b' "$(jq -r '.balancers[0].targets | join(" ")' <<<"$result")" 'selector expanded to candidate targets'
assert_eq node-b "$(jq -r '.balancers[0].override' <<<"$result")" 'current override from live API'
assert_eq '["node-a","node-b"]' "$(jq -c '.balancers[0].selected' <<<"$result")" 'API selection remains an array'
balancer_set main node-b >"$tmpdir/set.json"
assert_eq 'backup=node-b main=node-b' "${uci_entries[*]}" 'set preserves other overrides'
assert_eq true "$(jq -r .ok "$tmpdir/set.json")" 'set JSON result'
balancer_set main '' >"$tmpdir/set.json"
assert_eq 'backup=node-b' "${uci_entries[*]}" 'automatic removes persisted override'
for pair in 'missing node-a' 'main absent'; do
 read -r tag target <<<"$pair"
 before="$(wc -l <"$API_CALLS")"
 assert_false 'invalid override rejected' balancer_set "$tag" "$target"
 assert_eq "$before" "$(wc -l <"$API_CALLS")" 'invalid override never sent to API'
done
export API_FAIL=1
assert_false 'failed override not persisted' balancer_set main node-a
assert_eq 'backup=node-b' "${uci_entries[*]}" 'API failure leaves UCI untouched'
export API_FAIL=0
uci_entries=('main=node-b' 'missing=node-a' 'backup=absent')
warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
balancer_overrides_apply
assert_file_contains "$tmpdir/warnings" missing 'missing balancer warned'
assert_file_contains "$tmpdir/warnings" absent 'missing target warned'
assert_eq 'main=node-b missing=node-a backup=absent' "${uci_entries[*]}" 'stale UCI uci_entries kept'
export API_FAIL=1
assert_true 'reapply API failure does not fail startup' balancer_overrides_apply
export API_FAIL=0
# The absent list is its empty default (no list item with an empty tag).
uci_entries=()
assert_eq '' "$(settings_balancer_overrides)" 'empty override default'
uci_entries=("Europe's best=node with space")
assert_eq "Europe's best=node with space" "$(settings_balancer_overrides)" 'UCI list quoting round trip'
uci_entries=()
jq '.routing.balancers = []' "$RUNTIME_CONFIG" >"$tmpdir/empty.json"
RUNTIME_CONFIG="$tmpdir/empty.json"
: >"$API_CALLS"
assert_eq '{"running":true,"balancers":[],"stale":[]}' "$(balancers_json)" 'no balancers empty state'
assert_false 'empty config needs no API calls' test -s "$API_CALLS"
pass 'balancer listing, persistence and safe readiness reapply'

# Spec 16 (owner decision 5a): a stopped core fails fast, before any API call.
RUNTIME_CONFIG="$tmpdir/runtime.json"
uci_entries=('main=node-b')
: >"$API_CALLS"
service_running() { return 1; }
assert_eq '{"running":false,"balancers":[],"stale":[]}' "$(balancers_json)" 'stopped core: running false, empty list'
assert_false 'stopped core: set fails' balancer_set main node-a 2>"$tmpdir/stopped.err"
assert_eq 'Error: Xray is not running [E:not_running]' "$(cat "$tmpdir/stopped.err")" 'stopped core message'
assert_false 'stopped core: no API call' test -s "$API_CALLS"
assert_eq 'main=node-b' "${uci_entries[*]}" 'stopped core: UCI unchanged'
service_running() { return 0; }
pass 'balancers need a running core'

cat >"$XRAY_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$API_CALLS"
for arg do last="$arg"; done
[ "$2" != bi ] || [ "$last" != "${API_FAIL_TAG:-}" ] || exit 1
[ "$2" != bi ] || cat "$API_FIXTURE"
[ "$2" != bo ] || echo 'bo noise'
STUB
# bo stdout never reaches the JSON result.
uci_entries=('backup=node-b')
assert_eq '{"ok":true}' "$(balancer_set main node-a | jq -c .)" 'set prints only its JSON'
# UCI failure: staged change reverted, previous live override (node-b) restored.
uci_entries=('backup=node-b') uci_saved=('backup=node-b')
: >"$API_CALLS"
: >"$tmpdir/uci.calls"
UCI_FAIL=add_list
assert_false 'UCI failure fails set' balancer_set main node-a 2>/dev/null
UCI_FAIL=''
assert_eq 'revert xraywrt.settings.balancer_override' "$(cat "$tmpdir/uci.calls")" 'staged UCI reverted'
assert_eq 'backup=node-b' "${uci_entries[*]}" 'UCI back to the saved list'
assert_eq 'api bo --server=unix:/var/run/xraywrt/api.sock --timeout=3 -b main -- node-b' "$(tail -1 "$API_CALLS")" 'previous core override restored'
# A balancer gone from the runtime: "" only drops the UCI entry.
uci_entries=('gone=node-a' 'backup=node-b')
: >"$API_CALLS"
balancer_set gone '' >/dev/null
assert_eq 'backup=node-b' "${uci_entries[*]}" 'absent balancer entry removed'
assert_false 'absent balancer removal needs no API' test -s "$API_CALLS"
pass 'set output, UCI rollback and stale removal'

# One failing bi keeps the list; a time cap skips the rest.
jq '.routing.balancers[1].fallbackTag = "node-a" | .routing.balancers += [{tag:"a=b",selector:["node-a"],strategy:{type:"random"}}]' "$ROOT_DIR/tests/fixtures/xray-api/config.json" >"$RUNTIME_CONFIG"
uci_entries=('main=node-a' 'missing=node-a')
export API_FAIL_TAG=backup
result="$(balancers_json)"
API_FAIL_TAG=''
assert_eq true "$(jq -r .running <<<"$result")" 'running core listed'
assert_eq 'main backup a=b' "$(jq -r '[.balancers[].tag] | join(" ")' <<<"$result")" 'failing bi keeps every balancer'
assert_eq node-a "$(jq -r '.balancers[1].fallback' <<<"$result")" 'failed API retains configured fallback'
assert_eq 'api' "$(jq -r '.balancers[1].error' <<<"$result")" 'failed balancer marked'
assert_eq '[null,[]]' "$(jq -c '.balancers[1] | [.override, .selected]' <<<"$result")" 'failed balancer has no live state'
assert_eq null "$(jq -r '.balancers[0].error' <<<"$result")" 'other balancers unaffected'
assert_eq 'true false' "$(jq -r '[.balancers[0].settable, .balancers[2].settable] | join(" ")' <<<"$result")" 'tags with = are not settable'
assert_eq 'node-a true' "$(jq -r '.balancers[0] | [.saved, .stale] | join(" ")' <<<"$result")" 'saved override differing from the live one is stale'
assert_eq 'null false' "$(jq -r '.balancers[2] | [(.saved | tostring), .stale] | join(" ")' <<<"$result")" 'no saved override, not stale'
assert_eq '[{"tag":"missing","target":"node-a"}]' "$(jq -c .stale <<<"$result")" 'saved override of an absent balancer listed'
: >"$API_CALLS"
result="$(XRAY_API_LIST_TIMEOUT=0 balancers_json)"
assert_eq node-a "$(jq -r '.balancers[1].fallback' <<<"$result")" 'time cap retains configured fallback'
assert_eq 'timeout timeout timeout' "$(jq -r '[.balancers[].error] | join(" ")' <<<"$result")" 'time cap marks skipped balancers'
assert_false 'time cap skips bi calls' grep -q '^api bi ' "$API_CALLS"
pass 'balancer listing survives API errors and marks stale overrides'

# Strict reapply after a hot apply: an API failure is an error.
uci_entries=('main=node-a')
API_FAIL_TAG=''
cat >"$XRAY_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$API_CALLS"
exit 1
STUB
assert_true 'lenient reapply ignores API failure' balancer_overrides_apply
assert_false 'strict reapply fails on API error' balancer_overrides_apply 1
pass 'strict balancer override reapply'

# rmo reads any argument it can open as a JSON config (or stdin:/URL):
# tags never reach argv, only a temp file of tag-only outbounds.
cat >"$XRAY_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$API_CALLS"
for arg do last="$arg"; done
[ "$2" != rmo ] || cp "$last" "$API_CALLS.rmo"
[ "$2" != ado ] || cp "$last" "$API_CALLS.ado"
STUB
XRAY_SHARE_DIR="$tmpdir/share"
jq -n '{outbounds:[{tag:"direct",protocol:"freedom"},{tag:"/tmp/xraywrt/config.json",protocol:"freedom"},{tag:"stdin:",protocol:"freedom"},{tag:"keep",protocol:"freedom"}]}' >"$tmpdir/old.json"
jq '.outbounds |= map(select(.tag == "direct" or .tag == "keep")) | .outbounds[1].protocol = "blackhole"' "$tmpdir/old.json" >"$tmpdir/cand.json"
: >"$API_CALLS"
xray_api_apply "$tmpdir/old.json" "$tmpdir/cand.json"
assert_eq 1 "$(grep -c '^api rmo ' "$API_CALLS")" 'one rmo call for all removed tags'
assert_false 'removed tags never on argv' grep -qE 'config\.json|stdin:| keep$' "$API_CALLS"
assert_eq '{"outbounds":[{"tag":"/tmp/xraywrt/config.json"},{"tag":"stdin:"},{"tag":"keep"}]}' "$(jq -c . "$API_CALLS.rmo")" 'rmo file lists removed tags only'
assert_eq keep "$(jq -r '[.outbounds[].tag] | join(" ")' "$API_CALLS.ado")" 'changed outbound re-added'
grep -qE '^api rmo --server=unix:/var/run/xraywrt/api.sock --timeout=30 /' "$API_CALLS" || fail "rmo: $(cat "$API_CALLS")"
grep -qE '^api ado --server=unix:/var/run/xraywrt/api.sock --timeout=30 /' "$API_CALLS" || fail "ado: $(cat "$API_CALLS")"
grep -qx "api adrules --server=unix:/var/run/xraywrt/api.sock --timeout=30 $tmpdir/cand.json" "$API_CALLS" || fail "adrules: $(cat "$API_CALLS")"
assert_false 'temp delta files removed' test -e "$tmpdir/cand.json.outbounds" -o -e "$tmpdir/cand.json.removed"
: >"$API_CALLS"
jq '.outbounds += [{tag:"new",protocol:"freedom"}]' "$tmpdir/old.json" >"$tmpdir/add.json"
xray_api_apply "$tmpdir/old.json" "$tmpdir/add.json"
assert_false 'nothing removed, no rmo call' grep -q '^api rmo ' "$API_CALLS"
pass 'apply passes removed tags by file with the apply timeout'
