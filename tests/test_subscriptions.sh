#!/usr/bin/env bash
# Several saved subscriptions, one active: migration, add, switch, delete, per-subscription
# settings and lists, the geodata budget and the repair of an interrupted switch.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh service.sh migration.sh job.sh
setup_runtime_paths "$tmpdir"
FX="$ROOT_DIR/tests/fixtures/xray"
XRAY_CONFIG_BACKUP="$XRAY_CONFIG.bak"
RUNTIME_CONFIG="$tmpdir/runtime.json"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/lock"
SUBSCRIPTION_META_FILE="$tmpdir/subscription.json"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lists"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
POLICY_CACHE_DIR="$tmpdir/cache"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
NFT_APPLIED_FILE="$tmpdir/nft.applied"
XRAY_BIN="$tmpdir/core"
MEMINFO_FILE=/proc/meminfo
bodies="$tmpdir/bodies" fetches="$tmpdir/fetches" events="$tmpdir/events"
mkdir -p "$bodies" "$LIST_DIR"
: >"$fetches"
: >"$events"
rm -f "$XRAY_SHARE_DIR"/*.dat
lists_ensure_files
# The fake core accepts every config unless $tmpdir/core.fail exists.
printf '#!/bin/sh\n[ ! -e "%s/core.fail" ] || { echo rejected >&2; exit 1; }\nexit 0\n' "$tmpdir" >"$XRAY_BIN"
chmod +x "$XRAY_BIN"
printf '#!/bin/sh\necho "init $*" >>"%s"\n' "$events" >"$tmpdir/init"
chmod +x "$tmpdir/init"
sed "s|/etc/init.d/xraywrt|$tmpdir/init|g" "$XRAYWRT_LIB_DIR/subscription.sh" >"$tmpdir/subscription-init.sh"
source "$tmpdir/subscription-init.sh"
random_hex() { printf '%08x' "$(($(wc -l <"$tmpdir/ids") + 1))"; echo >>"$tmpdir/ids"; }
: >"$tmpdir/ids"
service_running() { return 1; }
service_ready() { return 1; }
nft_active() { return 1; }
cron_update() { echo cron >>"$events"; }
dns_apply() { :; }
lists_update_remote() { echo unchanged; }

# mkbody <tag> <log level>: a subscription whose geodata URLs and config bytes are its own.
mkbody() {
	jq --arg t "$1" --arg l "$2" '.log.loglevel = $l | .geodata.assets |= map(.url |= sub("geo.example.com/"; "geo.example.com/" + $t + "/"))' \
		"$FX/src/fakedns.json" >"$bodies/$1"
}
http_fetch() {
	local tag=""

	echo "$1" >>"$fetches"
	case "$1" in
	https://geo.example.com/*)
		[ -z "${GEO_FAIL:-}" ] || { FETCH_ERROR=network; return 1; }
		printf '%s' "$1" >"$2"
		;;
	https://p.example/*)
		tag="${1##*/}"
		[ -z "${SUB_FAIL:-}" ] && [ -f "$bodies/$tag" ] || { FETCH_ERROR=http_404; return 1; }
		cp "$bodies/$tag" "$2"
		FETCH_HDR="$6"
		printf 'HTTP/1.1 200 OK\r\nprofile-title: Title %s\r\nprofile-update-interval: 12\r\nsubscription-userinfo: upload=1; download=2; total=100; expire=0\r\n' "$tag" >"$6"
		;;
	*)
		FETCH_ERROR=network
		return 1
		;;
	esac
}
fetched() { grep -c -- "$1" "$fetches" || true; }
id_of() { subscription_id_of_url "https://p.example/$1"; }
share_has() { assert_eq "https://geo.example.com/$2/$1" "$(cat "$XRAY_SHARE_DIR/$1")" "share/$1 is from $2"; }
mkbody a debug
mkbody b info
mkbody c error
mkbody d warning
mkbody e none

# --- migration: the saved link and server become the first, active subscription
fake_uci_set xraywrt.settings.subscription_url https://p.example/a
fake_uci_set xraywrt.settings.profile Fast
settings_ensure_generated() { :; }
migrate
a="$(subscription_id_of_url https://p.example/a)"
assert_eq "$a" "$(uci_get subscription)" 'migrated subscription is active'
assert_eq Fast "$(subscription_option "$a" profile)" 'the server choice moved into the subscription'
assert_eq '' "$(uci_get subscription_url)$(uci_get profile)" 'old options removed'
assert_eq 1 "$(subscription_ids | wc -l | tr -d ' ')" 'one subscription'
before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" 'migration is idempotent'
assert_false 'migration restarts nothing and downloads nothing' test -s "$fetches" -o -s "$events"
pass 'migration makes the saved link the first subscription'
fake_uci_reset

# --- add: the first subscription is a normal Connect
# The link is saved only after the install: the generator must already see a provider's config.
eval "orig_$(declare -f xray_params_json)"
xray_params_json() { orig_xray_params_json | tee -a "$tmpdir/params"; }
out="$(subscription_add https://p.example/a)"
a="$(id_of a)"
[ -s "$tmpdir/params" ] || fail 'first connect generated no config'
assert_eq true "$(jq -s 'all(.from_subscription)' "$tmpdir/params")" 'first connect is generated as a subscription config'
assert_eq "$a" "$(uci_get subscription)" 'first subscription is active'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'first subscription installed'
share_has geosite.dat a
assert_eq $'init enable\ninit restart' "$(grep '^init' "$events")" 'first subscription enables and starts the service'
pass 'add first subscription behaves like Connect'

# --- add a second one: saved inactive, the running config is untouched
: >"$events"
out="$(subscription_add https://p.example/b)"
b="$(id_of b)"
assert_eq "$b" "$(printf '%s' "$out" | jq -r .id)" 'add reports the new id'
assert_eq added "$(printf '%s' "$out" | jq -r .action)" 'add reports the action'
assert_eq "$a" "$(uci_get subscription)" 'second subscription stays inactive'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'running config untouched'
share_has geosite.dat a
cmp -s "$XRAY_SUBS_DIR/$b/config.json" "$bodies/b" || fail 'second config stored'
assert_eq '' "$(cat "$events")" 'nothing restarted or reloaded'
json="$(subscription_json)"
assert_eq 2 "$(jq '.subscriptions | length' <<<"$json")" 'both listed'
assert_eq 'Title b' "$(jq -r --arg id "$b" '.subscriptions[] | select(.id == $id) | .name' <<<"$json")" 'name is the provider title'
assert_eq "$a" "$(jq -r '.subscriptions[] | select(.active) | .id' <<<"$json")" 'active row marked'
assert_eq 100 "$(jq -r --arg id "$b" '.subscriptions[] | select(.id == $id) | .meta.total' <<<"$json")" 'inactive row has its traffic'
pass 'add second subscription is saved inactive'

# The read role gets the host only: the link is the credential.
masked="$(subscription_json --mask)"
assert_eq 'https://p.example/…' "$(jq -r .url <<<"$masked")" 'read role sees the host only'
assert_eq 'https://p.example/a' "$(jq -r .url <<<"$json")" 'write role sees the link'
assert_false 'no saved link in the masked JSON' grep -q 'p.example/[ab]' <<<"$masked"
assert_eq 2 "$(jq '.subscriptions | length' <<<"$masked")" 'every subscription is still listed'
assert_eq '[]' "$(jq -c '[.subscriptions[] | keys[] | select(test("url"))]' <<<"$json")" 'a listed subscription carries no link'
assert_eq 'https://p.example/…' "$(subscription_url_masked 'https://user:pw@p.example:8443/sub?token=S')" 'userinfo, port, path and query are dropped'
assert_eq 'http://[2001:db8::1]/…' "$(subscription_url_masked 'http://[2001:db8::1]/sub')" 'IPv6 host keeps its brackets'
assert_eq '' "$(subscription_url_masked '')" 'no link stays empty'
assert_false 'unknown option rejected' subscription_json --other
pass 'subscription-json masks the link for the read role'

# --- a link that exists is not added twice; a bad link creates nothing
n="$(fetched p.example)"
out="$(subscription_add https://p.example/b)"
assert_eq exists "$(printf '%s' "$out" | jq -r .action)" 'duplicate says so'
assert_eq "$n" "$(fetched p.example)" 'duplicate downloads nothing'
out="$(subscription_add https://p.example/a)"
assert_eq exists "$(printf '%s' "$out" | jq -r .action)" 'the active link counts too'
for bad in https://p.example/typo ftp://x; do
	assert_false "bad link $bad" subscription_add "$bad" 2>/dev/null
done
cp "$FX/src/bad-share.txt" "$bodies/share"
assert_false 'share links are refused' subscription_add https://p.example/share 2>"$tmpdir/err"
assert_file_contains "$tmpdir/err" 'config_share' 'same error code as Update'
assert_eq 2 "$(subscription_ids | wc -l | tr -d ' ')" 'no entry was created'
assert_eq 1 "$(find "$XRAY_SUBS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 'no directory was created'
pass 'duplicate and bad links'

# --- own rule databases, own settings and lists of A
printf 'OWN' >"$XRAY_SHARE_DIR/own.dat"
printf 'LINK' >"$XRAY_SHARE_DIR/link.dat"
printf 'own.dat\n' >"$GEODATA_MANUAL_FILE"
fake_uci_set xraywrt.settings.geodata_asset 'link.dat=https://own.example/link.dat'
uci_set mode direct-first
uci_set dns_hijack 0
uci add_list xraywrt.settings.provider_override=mode
uci add_list xraywrt.settings.balancer_override=main=node-a
printf '192.0.2.1 core\nexample.org direct\n' >"$RULES_FILE"
subscription_option_set "$a" profile P1

# --- switch A -> B: B has no geodata yet, so it is downloaded; A's goes to its directory
: >"$fetches"
out="$(subscription_use "$b")"
assert_eq switched "$(printf '%s' "$out" | jq -r .action)" 'switch result'
assert_eq "$b" "$(uci_get subscription)" 'B is active'
cmp -s "$XRAY_CONFIG" "$bodies/b" || fail 'B installed'
assert_eq 0 "$(fetched 'p.example')" 'switch downloads no subscription'
share_has geosite.dat b
share_has geoip.dat b
assert_eq "https://geo.example.com/a/geosite.dat" "$(cat "$XRAY_SUBS_DIR/$a/share/geosite.dat")" "A's geodata is parked"
cmp -s "$XRAY_SUBS_DIR/$a/config.json" "$bodies/a" || fail 'A config parked'
assert_false 'the active one has no parked copy' test -e "$XRAY_SUBS_DIR/$b"
assert_false 'no journal left' test -e "$XRAY_SUBS_DIR/.switch"
assert_eq 'Title b' "$(jq -r '.profile_title' "$SUBSCRIPTION_META_FILE")" "B's metadata is live"
assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases stay in place'
assert_eq 'proxy-first:1' "$(uci_get mode):$(uci_get dns_hijack)" 'a new subscription starts with default settings'
assert_eq '' "$(uci_get provider_override)$(uci_get balancer_override)" 'no overrides for B'
assert_eq '' "$(cat "$RULES_FILE")" 'empty My rules for B'
assert_eq 'direct-first:0:mode:main=node-a' "$(subscription_option "$a" mode):$(subscription_option "$a" dns_hijack):$(subscription_option "$a" provider_override):$(subscription_option "$a" balancer_override)" "A's settings are kept in its section"
assert_eq $'192.0.2.1 core\nexample.org direct' "$(cat "$XRAY_SUBS_DIR/$a/lists/rules.txt")" "A's My rules are kept"
assert_eq unchanged "$(subscription_use "$b" | jq -r .action)" 'switching to the active subscription changes nothing'
pass 'switch moves geodata, settings and lists both ways'

# --- switch back B -> A: everything is stored, nothing is fetched
: >"$fetches"
printf '10.0.0.1 core\n' >"$RULES_FILE"
subscription_use "$a" >/dev/null
assert_eq '' "$(cat "$fetches")" 'switching back fetches nothing'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'A installed again'
share_has geosite.dat a
share_has geoip.dat a
assert_eq "https://geo.example.com/b/geosite.dat" "$(cat "$XRAY_SUBS_DIR/$b/share/geosite.dat")" "B's same-named file is parked, not mixed up"
assert_eq 'direct-first:0:mode:main=node-a:P1' "$(uci_get mode):$(uci_get dns_hijack):$(uci_get provider_override):$(uci_get balancer_override):$PROFILE_NAME" "A's settings, lists and server are back"
assert_eq $'192.0.2.1 core\nexample.org direct' "$(cat "$RULES_FILE")" "A's My rules are back"
assert_eq '10.0.0.1 core' "$(cat "$XRAY_SUBS_DIR/$b/lists/rules.txt")" "B's list edits were kept"
assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases survive both switches'
assert_eq 'Title a' "$(jq -r '.profile_title' "$SUBSCRIPTION_META_FILE")" "A's metadata is live"
pass 'switch back installs the stored config without any fetch'

# --- per-subscription server
settings_load
assert_eq P1 "$PROFILE_NAME" 'active subscription supplies the server'
subscription_use "$b" >/dev/null
settings_load
assert_eq '' "$PROFILE_NAME" 'another subscription has its own server'
subscription_option_set "$b" profile P2
settings_load
assert_eq P2 "$PROFILE_NAME" 'server of the new active subscription'
subscription_use "$a" >/dev/null
settings_load
assert_eq P1 "$PROFILE_NAME" 'server restored with the subscription'
pass 'selected server is per subscription'

# --- a rejected config restores everything
printf '203.0.113.9 core\n' >"$RULES_FILE"
subscription_add https://p.example/c >/dev/null
c="$(id_of c)"
touch "$tmpdir/core.fail"
assert_false 'a failing run -test fails the switch' subscription_use "$c" 2>"$tmpdir/err"
rm -f "$tmpdir/core.fail"
assert_eq "$a" "$(uci_get subscription)" 'active id restored'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'config restored'
share_has geosite.dat a
assert_eq 'direct-first:mode:203.0.113.9 core' "$(uci_get mode):$(uci_get provider_override):$(cat "$RULES_FILE")" 'settings and lists restored'
assert_false 'no journal left' test -e "$XRAY_SUBS_DIR/.switch"
assert_false 'the active one has no parked copy' test -e "$XRAY_SUBS_DIR/$a"
assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases survive a failed switch'
cmp -s "$XRAY_SUBS_DIR/$c/config.json" "$bodies/c" || fail 'the rejected subscription is kept'
assert_eq "$b" "$(id_of b)" 'other subscriptions untouched'
assert_eq "https://geo.example.com/b/geosite.dat" "$(cat "$XRAY_SUBS_DIR/$b/share/geosite.dat")" "B's parked geodata untouched"
pass 'a failed switch restores files, settings and the active id'

# --- an interrupted switch is repaired
interrupt() { # <back|forward>: a switch to B whose install is killed (forward: after it wrote the config)
	local how="$1"
	{
		(
			outer="$BASHPID"
			config_install() {
				[ "$how" != forward ] || cp "$1" "$XRAY_CONFIG"
				kill -9 "$outer"
			}
			subscription_switch "$b" >/dev/null 2>&1
		) || true
	} 2>/dev/null
}
interrupt back
assert_true 'the journal survives the crash' test -f "$XRAY_SUBS_DIR/.switch"
assert_eq "$b" "$(uci_get subscription)" 'crash left the other id committed'
subscription_recover
assert_eq "$a" "$(uci_get subscription)" 'recovery restores the active id'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'config unchanged'
share_has geosite.dat a
assert_eq 'direct-first:203.0.113.9 core' "$(uci_get mode):$(cat "$RULES_FILE")" 'recovery restores settings and lists'
assert_false 'journal gone' test -e "$XRAY_SUBS_DIR/.switch"
interrupt forward
subscription_recover
assert_eq "$b" "$(uci_get subscription)" 'a config that was installed finishes the switch'
cmp -s "$XRAY_CONFIG" "$bodies/b" || fail 'new config kept'
share_has geosite.dat b
assert_false 'parked copy and journal gone' test -e "$XRAY_SUBS_DIR/.switch" -o -e "$XRAY_SUBS_DIR/$b"
assert_eq 'Title b' "$(jq -r '.profile_title' "$SUBSCRIPTION_META_FILE")" 'metadata of the new subscription'
subscription_use "$a" >/dev/null
pass 'an interrupted switch is finished or undone'

# --- stale on switch
subscription_option_set "$b" updated "$(($(date +%s) - 30 * 3600))"
: >"$fetches"
out="$(subscription_use "$b")"
assert_eq 1 "$(fetched https://p.example/b)" 'a stale subscription is updated once on switch'
subscription_use "$a" >/dev/null
: >"$fetches"
subscription_use "$b" >/dev/null
assert_eq 0 "$(fetched https://p.example/b)" 'a fresh one is not updated'
subscription_use "$a" >/dev/null
subscription_option_set "$b" updated "$(($(date +%s) - 30 * 3600))"
: >"$fetches"
out="$(SUB_FAIL=1 subscription_use "$b")"
assert_eq partial "$(printf '%s' "$out" | jq -r .apply_status)" 'a failed update is a warning'
assert_eq 'switched' "$(printf '%s' "$out" | jq -r .action)" 'the switch itself succeeded'
assert_file_contains <(printf '%s' "$out") subscription_stale 'warning names the stale update'
assert_eq "$b" "$(uci_get subscription)" 'the stored subscription stays active'
cmp -s "$XRAY_CONFIG" "$bodies/b" || fail 'stored config keeps running'
subscription_use "$a" >/dev/null
subscription_option_set "$b" updated "$(($(date +%s) - 30 * 3600))"
uci_set subscription_auto_update 0
: >"$fetches"
subscription_use "$b" >/dev/null
assert_eq 0 "$(fetched https://p.example/b)" 'no update with auto-update off'
uci_set subscription_auto_update 1
subscription_use "$a" >/dev/null
pass 'stale subscription is updated on switch only when due'

# --- delete
subscription_add https://p.example/d >/dev/null
d="$(id_of d)"
assert_eq "https://geo.example.com/b/geosite.dat" "$(cat "$XRAY_SUBS_DIR/$b/share/geosite.dat")" 'B keeps its geodata'
with_lock subscription_delete "$d" >/dev/null
assert_false 'section removed' test -n "$(subscription_option "$d" url)"
assert_false 'directory removed' test -e "$XRAY_SUBS_DIR/$d"
assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases survive a delete'
assert_false 'the active one cannot be deleted while others exist' with_lock subscription_delete "$a" 2>"$tmpdir/err"
assert_file_contains "$tmpdir/err" subscription_active 'switch first'
assert_eq "$a" "$(uci_get subscription)" 'still active'
with_lock subscription_delete "$b" >/dev/null
with_lock subscription_delete "$c" >/dev/null
assert_eq 1 "$(subscription_ids | wc -l | tr -d ' ')" 'one left'
with_lock subscription_delete "$a" >/dev/null
assert_eq '' "$(uci_get subscription)$(subscription_ids)" 'the last one can go'
cmp -s "$XRAY_CONFIG" "$bodies/a" || fail 'the config stays as a hand-written one'
assert_eq 'direct-first:P1' "$(uci_get mode):$(uci_get profile)" 'settings and server stay'
assert_eq '203.0.113.9 core' "$(cat "$RULES_FILE")" 'lists stay'
assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases survive the last delete'
assert_false 'metadata of the deleted subscription is gone' test -e "$SUBSCRIPTION_META_FILE"
settings_load
assert_eq '' "$SUBSCRIPTION_URL" 'no subscription link'
assert_eq P1 "$PROFILE_NAME" 'hand-written config keeps the server choice'
pass 'delete inactive, refused for the active one, delete the last'

# --- ids reach paths only when valid
subscription_add https://p.example/a >/dev/null
a="$(id_of a)"
subscription_add https://p.example/b >/dev/null
b="$(id_of b)"
mkdir -p "$tmpdir/victim"
for bad in '' ../victim 'A1' 'a/b' 'a b' "$(printf 'x%.0s' {1..33})" '.' '-s'; do
	assert_false "use rejects '$bad'" subscription_use "$bad" 2>/dev/null
	assert_false "delete rejects '$bad'" subscription_delete "$bad" 2>/dev/null
	assert_false "job use rejects '$bad'" job_validate use-subscription "$bad" 2>/dev/null
	assert_false "job delete rejects '$bad'" job_validate delete-subscription "$bad" 2>/dev/null
done
assert_true 'job accepts a real id' job_validate use-subscription "$b"
assert_true 'job accepts add-subscription' job_validate add-subscription https://p.example/z
assert_false 'job add needs a link' job_validate add-subscription ftp://x 2>/dev/null
assert_true 'victim untouched' test -d "$tmpdir/victim"
pass 'ids are validated before they reach a path'

# --- geodata budget: the active one and the two most recently used keep their files
(
	# A clock that moves on at every call, also inside command substitutions.
	command date +%s >"$tmpdir/clock"
	date() {
		if [ "$*" = +%s ]; then
			echo "$(($(cat "$tmpdir/clock") + 1))" >"$tmpdir/clock.new" && mv "$tmpdir/clock.new" "$tmpdir/clock"
			cat "$tmpdir/clock"
		else
			command date "$@"
		fi
	}
	subscription_add https://p.example/c >/dev/null
	subscription_add https://p.example/d >/dev/null
	subscription_add https://p.example/e >/dev/null
	c="$(id_of c)" d="$(id_of d)" e="$(id_of e)"
	subscription_use "$b" >/dev/null
	subscription_use "$c" >/dev/null
	subscription_use "$d" >/dev/null
	subscription_use "$e" >/dev/null
	parked() { find "$XRAY_SUBS_DIR/$1/share" -name '*.dat' | wc -l | tr -d ' '; }
	assert_eq '2:2' "$(parked "$d"):$(parked "$c")" 'the two latest keep their geodata'
	assert_eq '0:0' "$(parked "$b"):$(parked "$a")" 'older ones lose their geodata'
	for id in "$a" "$b"; do
		assert_true "config of $id kept" test -f "$XRAY_SUBS_DIR/$id/config.json"
		assert_true "metadata of $id kept" test -f "$XRAY_SUBS_DIR/$id/subscription.json"
		assert_true "lists of $id kept" test -d "$XRAY_SUBS_DIR/$id/lists"
	done
	assert_eq 'direct-first:mode' "$(subscription_option "$a" mode):$(subscription_option "$a" provider_override)" "A's settings kept"
	assert_eq 'OWN:LINK' "$(cat "$XRAY_SHARE_DIR/own.dat"):$(cat "$XRAY_SHARE_DIR/link.dat")" 'own rule databases are never evicted'
	: >"$fetches"
	subscription_use "$a" >/dev/null
	assert_eq 2 "$(fetched https://geo.example.com/a/)" 'switching back downloads the files again'
	share_has geosite.dat a
	assert_eq "$a" "$(uci_get subscription)" 'A is active'
	assert_eq '2:2' "$(parked "$e"):$(parked "$d")" 'the latest keep theirs'
	assert_eq '0' "$(parked "$c")" 'the next oldest is evicted'
	# Offline: the switch to an evicted subscription fails and restores the active one.
	GEO_FAIL=1 subscription_use "$c" >/dev/null 2>&1 && fail 'offline switch to an evicted subscription must fail'
	assert_eq "$a" "$(uci_get subscription)" 'the active one is restored'
	share_has geosite.dat a
)
pass 'geodata is kept for the active and the two most recently used subscriptions'

# --- R20 review: an interrupted switch is decided by the committed active id
# The fake uci stages nothing. With UCI_STAGING=1 a commit is remembered and
# `uci revert` returns to it, which is what a power loss does to /tmp/.uci.
uci() {
	local args=("$@")

	[ "${args[0]:-}" != -q ] || args=("${args[@]:1}")
	case "${args[0]:-}" in
	commit) command uci "$@"; [ "${UCI_STAGING:-}" != 1 ] || cp "$FAKE_UCI_DB" "$tmpdir/uci.committed" ;;
	revert) [ "${UCI_STAGING:-}" != 1 ] || cp "$tmpdir/uci.committed" "$FAKE_UCI_DB" ;;
	*) command uci "$@" ;;
	esac
}
# Two subscriptions with their settings, lists and geodata, A active; everything committed.
fresh_pair() {
	local id="" pair="" opt="" f=""

	for id in $(subscription_ids); do command uci -q delete "xraywrt.$id"; done
	command uci -q delete xraywrt.settings.subscription
	for pair in $SUBSCRIPTION_SETTINGS; do command uci -q delete "xraywrt.settings.${pair%%:*}"; done
	for opt in $SUBSCRIPTION_SETTING_LISTS geodata_asset; do command uci -q delete "xraywrt.settings.$opt"; done
	rm -rf "$XRAY_SUBS_DIR" "$XRAY_CONFIG" "$XRAY_CONFIG_BACKUP" "$SUBSCRIPTION_META_FILE" "$PKG_STATE_DIR/subscription.stamp" "$GEODATA_MANUAL_FILE"
	rm -f "$XRAY_SHARE_DIR"/*.dat "$APPLY_WARNING_FILE" "$tmpdir/warns"
	for f in "$LIST_DIR"/*; do : >"$f"; done
	: >"$events"
	UCI_STAGING=0
	subscription_add https://p.example/a >/dev/null
	subscription_add https://p.example/b >/dev/null
	a="$(id_of a)" b="$(id_of b)"
	uci_set mode direct-first
	uci_set dns_hijack 0
	command uci add_list xraywrt.settings.provider_override=mode
	printf '192.0.2.1 core\n' >"$RULES_FILE"
	uci_commit
	UCI_STAGING=1
	uci_commit
	: >"$events"
}
# crash_switch <id> <point>: subscription_switch kills itself at <point>.
crash_switch() {
	local id="$1" point="$2"

	{
		(
			outer="$BASHPID"
			case "$point" in
			park) subscription_park_lists() { kill -9 "$outer"; } ;;
			precommit) uci_set() { [ "$1" != subscription ] || kill -9 "$outer"; uci -q set "$PKG_CONFIG.settings.$1=$2"; } ;;
			install) config_install() { kill -9 "$outer"; } ;;
			esac
			subscription_switch "$id" >/dev/null 2>&1
		) || true
	} 2>/dev/null
}
warn() { echo "$*" >>"$tmpdir/warns"; }

# H1: a switch killed before the commit leaves A's settings alone, with or without a power loss.
for loss in kill power; do
	fresh_pair
	crash_switch "$b" precommit
	assert_true "$loss: the journal survives the crash" test -f "$XRAY_SUBS_DIR/.switch"
	assert_eq parked "$(cut -d' ' -f3 "$XRAY_SUBS_DIR/.switch")" "$loss: the crash came after the copy of A"
	assert_eq 'proxy-first:1' "$(uci_get mode):$(uci_get dns_hijack)" "$loss: the staged defaults of B are in place"
	[ "$loss" != power ] || uci revert xraywrt
	subscription_recover
	assert_eq "$a" "$(uci_get subscription)" "$loss: A stays active"
	assert_eq 'direct-first:0:mode' "$(uci_get mode):$(uci_get dns_hijack):$(uci_get provider_override)" "$loss: A's settings survive"
	assert_eq '192.0.2.1 core' "$(cat "$RULES_FILE")" "$loss: A's own list survives"
	share_has geosite.dat a
	cmp -s "$XRAY_CONFIG" "$bodies/a" || fail "$loss: A's config unchanged"
	assert_false "$loss: journal and parked copy gone" test -e "$XRAY_SUBS_DIR/.switch" -o -e "$XRAY_SUBS_DIR/$a"
	assert_true "$loss: B is still saved" test -f "$XRAY_SUBS_DIR/$b/config.json"
	subscription_use "$b" >/dev/null || fail "$loss: B can be used afterwards"
	assert_eq "$b" "$(uci_get subscription)" "$loss: the next switch works"
done
pass 'a switch interrupted before the commit keeps the active subscription intact'

# H2: two links with the same config bytes: only the committed active id tells a finished switch.
fresh_pair
cp "$bodies/a" "$bodies/twin"
subscription_add https://p.example/twin >/dev/null
twin="$(id_of twin)"
crash_switch "$twin" park
assert_true 'the journal survives the crash' test -f "$XRAY_SUBS_DIR/.switch"
subscription_recover
assert_eq "$a" "$(uci_get subscription)" 'the identical config does not finish an unfinished switch'
assert_true 'the target stays saved' test -f "$XRAY_SUBS_DIR/$twin/config.json"
assert_eq 'Title a' "$(jq -r .profile_title "$SUBSCRIPTION_META_FILE")" "A's metadata is not replaced"
assert_false 'journal gone' test -e "$XRAY_SUBS_DIR/.switch"
subscription_use "$twin" >/dev/null || fail 'the target can still be used'
assert_eq "$twin" "$(uci_get subscription)" 'use works afterwards'
subscription_use "$a" >/dev/null
crash_switch "$twin" install
assert_eq "$twin" "$(uci_get subscription)" 'the commit happened before the crash'
subscription_recover
assert_eq "$twin" "$(uci_get subscription)" 'a committed switch with the same config is finished'
assert_false 'journal and parked copy gone' test -e "$XRAY_SUBS_DIR/.switch" -o -e "$XRAY_SUBS_DIR/$twin"
assert_eq 'Title twin' "$(jq -r .profile_title "$SUBSCRIPTION_META_FILE")" 'metadata of the new subscription'
pass 'identical configs do not hide an unfinished switch'

# H3: the running service uses the new settings and lists, also when the config bytes are identical.
fresh_pair
cp "$bodies/a" "$bodies/twin"
subscription_add https://p.example/twin >/dev/null
twin="$(id_of twin)"
(
	service_ready() { return 0; }
	runtime_refresh() { echo refresh >>"$events"; }
	policy_apply() { echo policy >>"$events"; }
	out="$(subscription_use "$twin")"
	assert_eq switched "$(jq -r .action <<<"$out")" 'identical config: switched'
	assert_eq $'refresh\npolicy' "$(grep -E '^(refresh|policy)$' "$events")" 'identical config: runtime and policy are applied from the new settings'
	assert_eq applied "$(jq -r .apply_status <<<"$out")" 'identical config: applied'
	: >"$events"
	out="$(subscription_use "$b")"
	assert_eq $'refresh\npolicy' "$(grep -E '^(refresh|policy)$' "$events" | tail -n 2)" 'different config: reloaded as well'
	policy_apply() { return 1; }
	out="$(subscription_use "$a")"
	assert_eq switched "$(jq -r .action <<<"$out")" 'a failed policy: the files did switch'
	assert_eq partial "$(jq -r .apply_status <<<"$out")" 'a failed policy is reported as partial, not applied'
	assert_file_contains <(printf '%s' "$out") apply_partial 'the warning says routing was not applied'
)
pass 'a switch applies the new settings and lists to the running service'

# M1: a failing repair never blocks the start nor Add and Delete.
fresh_pair
cp "$bodies/a" "$bodies/twin"
subscription_add https://p.example/twin >/dev/null
twin="$(id_of twin)"
subscription_add https://p.example/c >/dev/null
c="$(id_of c)"
crash_switch "$twin" install
(
	eval "$(declare -f atomic_copy | sed '1s/atomic_copy/real_atomic_copy/')"
	atomic_copy() { [ "$2" != "$SUBSCRIPTION_META_FILE" ] || return 1; real_atomic_copy "$@"; }
	subscription_recover || fail 'finish goes on without the metadata copy'
	assert_false 'finish removes the journal anyway' test -e "$XRAY_SUBS_DIR/.switch"
	assert_file_contains "$tmpdir/warns" 'Cannot' 'the failed copy is a warning'
)
fresh_pair
subscription_add https://p.example/c >/dev/null
c="$(id_of c)"
crash_switch "$b" install
(
	# The repair keeps failing (a full flash: the commit of the active id does not go through).
	subscription_switch_abort() { return 1; }
	assert_false 'a failing abort reports it' subscription_recover
	assert_true 'the journal stays for the next try' test -f "$XRAY_SUBS_DIR/.switch"
	# What a start does: nothing here may stop it.
	xray_config_key() { return 1; }
	xray_config_generate() { cp "$1" "$2" && printf 'profile-schema 1\n' >"$2.profile"; }
	xray_config_test_key() { echo key; }
	xray_config_test() { return 0; }
	config_check_record() { :; }
	runtime_config_key_store() { :; }
	geodata_prune() { :; }
	geodata_recover() { :; }
	runtime_config_build "$tmpdir/rt.json" || fail 'the start goes on with a failing repair'
	assert_false 'the parked copy the repair needs is not deleted' with_lock subscription_delete "$a"
	assert_true 'it is still there' test -d "$XRAY_SUBS_DIR/$a"
	with_lock subscription_delete "$c" >/dev/null || fail 'delete goes on with a failing repair'
	assert_false 'the deleted subscription is gone' test -d "$XRAY_SUBS_DIR/$c"
	subscription_add https://p.example/e >/dev/null || fail 'add goes on with a failing repair'
	assert_true 'the new subscription is saved' test -n "$(id_of e)"
)
pass 'a failing repair blocks neither the start nor add and delete'

# M2: after a repair the start works with the restored settings, not with those of the interrupted switch.
fresh_pair
crash_switch "$b" precommit
(
	settings_ensure_generated() { :; }
	service_recover() { :; }
	runtime_dirs_init() { :; }
	dns_guard() { :; }
	xray_config_key() { return 1; }
	xray_config_generate() { cp "$1" "$2" && printf 'profile-schema 1\n' >"$2.profile"; }
	xray_config_test_key() { echo key; }
	xray_config_test() { return 0; }
	config_check_record() { :; }
	runtime_config_key_store() { :; }
	geodata_prune() { :; }
	geodata_recover() { :; }
	settings_load
	assert_eq proxy-first "$UCI_MODE" 'the interrupted switch left the settings of B in place'
	service_prepare || fail 'service_prepare'
	assert_eq direct-first "$UCI_MODE" 'the start continues with the restored settings'
)
pass 'the start reloads the settings after a repair'

# M3: a failing `touch -d @N` is a warning and the subscription counts as stale.
fresh_pair
(
	touch() { case "$1" in -d) return 1 ;; esac; command touch "$@"; }
	subscription_option_set "$b" updated "$(($(date +%s) - 3600))"
	uci_commit
	: >"$fetches"
	subscription_use "$b" >/dev/null
	assert_file_contains "$tmpdir/warns" 'update time' 'the failed touch is reported'
	assert_eq 1 "$(fetched https://p.example/b)" 'without a usable update time the subscription is updated once'
)
pass 'a failing touch makes the subscription stale'

# M4: an update that was downloaded for another active subscription is not installed.
fresh_pair
(
	eval "$(declare -f http_fetch | sed '1s/http_fetch/real_http_fetch/')"
	http_fetch() {
		[ -e "$tmpdir/switched.once" ] || { : >"$tmpdir/switched.once"; subscription_use "$b" >/dev/null; }
		real_http_fetch "$@"
	}
	rm -f "$tmpdir/switched.once"
	assert_false 'the update of A is refused after the switch to B' subscription_update 2>"$tmpdir/err"
	assert_file_contains "$tmpdir/err" subscription_changed 'the reason is a changed active subscription'
	assert_eq "$b" "$(uci_get subscription)" 'B stays active'
	cmp -s "$XRAY_CONFIG" "$bodies/b" || fail "B's config is not replaced by A's download"
)
pass 'an update does not install into another active subscription'

# L1: a leftover parked copy of the active subscription is swept.
fresh_pair
mkdir -p "$XRAY_SUBS_DIR/$a/share"
ln "$XRAY_SHARE_DIR/geosite.dat" "$XRAY_SUBS_DIR/$a/share/geosite.dat"
printf x >"$XRAY_SUBS_DIR/$a/config.json"
subscription_recover
assert_false 'the active one has no parked copy' test -e "$XRAY_SUBS_DIR/$a"
assert_true "B's parked copy is kept" test -f "$XRAY_SUBS_DIR/$b/config.json"
share_has geosite.dat a
pass 'a leftover parked copy of the active subscription is removed'

# L2: a link that is saved is not given to another subscription.
fresh_pair
before="$(cat "$XRAY_CONFIG")"
assert_false 'the link of B cannot replace the link of A' subscription_update https://p.example/b 2>"$tmpdir/err"
assert_file_contains "$tmpdir/err" subscription_exists 'the reason is a saved link'
assert_eq https://p.example/a "$(subscription_option "$a" url)" "A's link is unchanged"
assert_eq "$before" "$(cat "$XRAY_CONFIG")" 'nothing was installed'
assert_false 'connect with the saved link of B is refused too' subscription_update https://p.example/b 2>/dev/null
subscription_update https://p.example/a >/dev/null || fail "A's own link is accepted"
pass 'update-subscription refuses a link of another subscription'
