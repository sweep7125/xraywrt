#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules constants.sh helpers.sh validate.sh xray-config.sh lists.sh nft.sh job.sh service.sh

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
setup_runtime_paths "$tmpdir"
lists_ensure_files
mkdir -p "$POLICY_CACHE_DIR" "$PKG_TMP_DIR"
settings_load() { :; }
service_ready() { return 0; }
service_running() { return 0; }
with_lock() { "$@"; }
nft_apply() { printf 'apply\n' >>"$tmpdir/applied"; }
http_fetch() {
 case "$mode:$1" in
 all-fail:* | mixed:*fail.example*) FETCH_ERROR=network; return 1 ;;
 esac
 printf '9.9.9.9\n' >"$2"
}

printf '%s core\n' https://ok.example/list https://fail.example/list >"$RULES_FILE"
ok_cache="$(lists_cache_file https://ok.example/list)"
fail_cache="$(lists_cache_file https://fail.example/list)"
for mode in mixed all-fail unchanged; do
 printf '9.9.9.9\n' >"$ok_cache"
 [ "$mode" = unchanged ] || printf '1.1.1.1\n' >"$ok_cache"
 printf '9.9.9.9\n' >"$fail_cache"
 [ "$mode" = unchanged ] || printf '8.8.8.8\n' >"$fail_cache"
 : >"$tmpdir/applied"
 rc=0
 lists_refresh >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 case "$mode" in
 mixed)
  assert_eq 0 "$rc" 'accepted partial refresh returns compatible success'
  assert_eq partial "$(jq -r .apply_status "$tmpdir/out")" 'mixed refresh is partial, not ordinary success'
  assert_eq apply "$(cat "$tmpdir/applied")" 'partial refresh applies changed cache'
  assert_eq 9.9.9.9 "$(cat "$ok_cache")" 'successful URL cache updated'
  assert_eq 8.8.8.8 "$(cat "$fail_cache")" 'failed URL cache preserved'
  assert_eq 'Error: Failed to update 1 of 2 remote lists: Remote list fetch failed: fail.example (network) [E:lists_update|1|2|Remote list fetch failed: fail.example (network)]' "$(cat "$tmpdir/err")" 'partial refresh reports count and first error'
  ;;
 all-fail)
  assert_eq 1 "$rc" 'all failed refresh returns failure'
  assert_eq '' "$(cat "$tmpdir/applied")" 'all failed refresh does not apply'
  assert_eq 1.1.1.1 "$(cat "$ok_cache")" 'first failed cache preserved'
  assert_eq 8.8.8.8 "$(cat "$fail_cache")" 'second failed cache preserved'
  assert_eq 'Error: Failed to update 2 of 2 remote lists: Remote list fetch failed: ok.example (network) [E:lists_update|2|2|Remote list fetch failed: ok.example (network)]' "$(cat "$tmpdir/err")" 'all failed refresh reports first error'
  ;;
 unchanged)
  assert_eq 0 "$rc" 'unchanged successful refresh returns success'
  assert_eq false "$(jq -r .changed "$tmpdir/out")" 'unchanged successful refresh JSON'
  assert_eq '' "$(cat "$tmpdir/applied")" 'unchanged refresh does not apply'
  assert_eq '' "$(cat "$tmpdir/err")" 'unchanged refresh has no error'
  ;;
 esac
 pass "lists_refresh $mode"
done

# A changed core list can shadow a later tag even when that tag has no URL.
test_shadow_refresh() {
 local mode=unchanged PROFILE_FILE="$tmpdir/shadow.profile" RULES_FILE="$tmpdir/shadow.rules" POLICY_CACHE_DIR="$tmpdir/shadow-cache"
 mkdir -p "$POLICY_CACHE_DIR"
 printf 'rules-target proxy\n' >"$PROFILE_FILE"
 printf 'https://ok.example/list;443;udp core\n9.9.9.9 proxy\n' >"$RULES_FILE"
 printf '1.1.1.1\n' >"$(lists_cache_file https://ok.example/list)"
 (
  service_reload() { printf 'reload\n' >>"$tmpdir/applied"; }
  : >"$tmpdir/applied"
  lists_refresh >"$tmpdir/out" 2>"$tmpdir/err"
  assert_eq reload "$(cat "$tmpdir/applied")" 'refresh rebuilds a tag shadowed by a changed core URL'
 )
}
test_shadow_refresh
pass 'changed address shadow cache rebuilds the core routing config'

# The prescribed successful retry clears only its own warning, even if unchanged.
mode=unchanged
printf 'Fetch failed [E:apply_lists]\n' >"$APPLY_WARNING_FILE"
lists_refresh >/dev/null
assert_false 'successful remote-list retry clears fetch warning' test -e "$APPLY_WARNING_FILE"
printf 'Routing failed [E:apply_partial]\n' >"$APPLY_WARNING_FILE"
lists_refresh >/dev/null
assert_true 'remote-list retry retains unrelated routing warning' test -s "$APPLY_WARNING_FILE"
(
 lists_install() { echo 0; }
 cron_update() { :; }
 printf 'Fetch failed [E:apply_lists]\n' >"$APPLY_WARNING_FILE"
 lists_apply - - - - >/dev/null
 assert_false 'successful list apply clears fetch warning' test -e "$APPLY_WARNING_FILE"
)
pass 'successful list retry clears only its own warning'

# Routing failure must win when a partial fetch also fails.
(
 mode=mixed
 printf '1.1.1.1\n' >"$ok_cache"
 nft_apply() { return 1; }
 lists_refresh >"$tmpdir/routing-partial" 2>/dev/null
 assert_file_contains "$APPLY_WARNING_FILE" '[E:apply_partial]' 'routing failure is not hidden by failed fetch'
 mode=unchanged
 lists_refresh >/dev/null
 assert_file_contains "$APPLY_WARNING_FILE" '[E:apply_partial]' 'unchanged successful fetch does not erase unapplied routing'
)
pass 'mixed fetch and routing failures retain the routing warning'

# A publication error is a failed URL too, and leaves the old cache intact.
(
 mode=unchanged
 printf '1.1.1.1\n' >"$ok_cache"
 atomic_copy() { return 1; }
 assert_false 'cache write failure fails refresh' lists_refresh >"$tmpdir/out" 2>"$tmpdir/err"
 assert_eq 1.1.1.1 "$(cat "$ok_cache")" 'cache write failure preserves old cache'
 assert_eq 'Error: Failed to update 1 of 2 remote lists: Remote list cache write failed: ok.example [E:lists_update|1|2|Remote list cache write failed: ok.example]' "$(cat "$tmpdir/err")" 'cache write failure counted'
)
pass 'lists_refresh cache write failure'

# Run the real job dispatcher and finalizer around the real failed refresh.
mode=all-fail
JOBS_DIR="$tmpdir/jobs"
job_dir_prepare
id=1-4242
jq -nc --arg id "$id" '{id:$id,op:"update-lists",state:"running",started:1,finished:null,result:null,error:null}' >"$JOBS_DIR/$id.json"
ln -s "$id" "$JOBS_DIR/active"
job_run "$id" update-lists
assert_eq error "$(jq -r .state "$JOBS_DIR/$id.json")" 'failed refresh finishes job with error'
assert_eq 'Failed to update 2 of 2 remote lists: Remote list fetch failed: ok.example (network) [E:lists_update|2|2|Remote list fetch failed: ok.example (network)]' "$(jq -r .error "$JOBS_DIR/$id.json")" 'job exposes refresh failure'
assert_false 'failed refresh releases job slot' test -L "$JOBS_DIR/active"
pass 'lists_refresh failure reaches job status'
