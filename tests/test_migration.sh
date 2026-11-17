#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh lists.sh dns.sh migration.sh
setup_runtime_paths "$tmpdir"
XRAY_DIR="$tmpdir/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
ROUTE_STATE_FILE="$PKG_STATE_DIR/route.state"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lst"
RULES_FILE="$LIST_DIR/rules.txt"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
mkdir -p "$XRAY_DIR" "$LIST_DIR"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
# Observe the retained generation boundary without generating random settings.
settings_ensure_generated() {
 echo generated >>"$tmpdir/generated.calls"
}
uci() {
 case " $* " in *' commit '*) echo commit >>"$tmpdir/commit.calls" ;; esac
 # Real uci fails when the option to delete is absent: the migration must not stop there.
 case " $* " in *' delete xraywrt.settings.subscription_url '*) command uci "$@"; return 1 ;; esac
 command uci "$@"
}

migrate
assert_eq '1:1:0:1:1' "$(uci_get dns_hijack):$(uci_get disable_quic):$(uci_get netbird_proxy):$(uci_get bypass_ntp):$(uci_get bypass_subscription_dns)" 'flags written when empty'
assert_eq 0 "$(uci_get lists_interval)" 'lists_interval empty becomes 0'
assert_eq warning "$(uci_get core_log_level)" 'core_log_level empty becomes warning'
assert_eq '0 5 * * *' "$(uci_get geodata_cron)" 'geodata_cron empty filled'
assert_eq '0:proxy-first' "$(uci_get dns_forward_other_types):$(uci_get mode)" 'new options filled'
assert_eq '' "$(uci_get dns_raw_upstream)" 'DNS options stay empty: no public resolvers'
assert_eq commit "$(cat "$tmpdir/commit.calls")" 'migrate commits retained defaults'
assert_eq generated "$(cat "$tmpdir/generated.calls")" 'migrate ensures generated settings'
pass 'flags written when empty; lists_interval empty becomes 0'

fake_uci_set xraywrt.settings.dns_hijack 0
fake_uci_set xraywrt.settings.disable_quic 0
fake_uci_set xraywrt.settings.netbird_proxy 1
fake_uci_set xraywrt.settings.bypass_ntp 0
fake_uci_set xraywrt.settings.bypass_subscription_dns 0
fake_uci_set xraywrt.settings.lists_interval 24
fake_uci_set xraywrt.settings.core_log_level debug
fake_uci_set xraywrt.settings.geodata_cron '15 6 * * 1-5'
before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" 'existing Traffic flags and lists_interval kept'
fake_uci_set xraywrt.settings.lists_interval 0
migrate
assert_eq 0 "$(uci_get lists_interval)" 'existing disabled lists_interval kept'
pass 'existing flags and lists_interval kept'

echo 'proxy-ip http://10.0.0.1/old' >"$PROFILE_FILE"
migrate
assert_false 'profile from an older version removed' test -e "$PROFILE_FILE"
pass 'migrate drops the old provider profile'

mkdir -p "$XRAY_DIR"
jq '.xraywrt = {"block-client-ipv6": true}' "$ROOT_DIR/tests/fixtures/xray/src/single.json" >"$XRAY_CONFIG"
printf 'mode proxy-first\nignored block-client-ipv6\n' >"$PROFILE_FILE"
uci delete xraywrt.settings.block_client_ipv6 2>/dev/null || true
migrate
assert_false 'stale profile ignoring the new key removed' test -e "$PROFILE_FILE"
settings_load
assert_file_contains "$PROFILE_FILE" 'set block_client_ipv6 1' 'profile rebuilt with the provider key'
assert_eq 1 "$BLOCK_CLIENT_IPV6" 'rebuilt profile applies the provider key'
assert_false 'migration writes no client IPv6 option' uci -q get xraywrt.settings.block_client_ipv6
cp "$ROOT_DIR/tests/fixtures/xray/src/single.json" "$XRAY_CONFIG"
rm -f "$PROFILE_FILE"
settings_load
assert_eq 0 "$BLOCK_CLIENT_IPV6" 'absent option stays off'
rm -f "$XRAY_CONFIG" "$PROFILE_FILE"
pass 'migrate rebuilds the profile for block-client-ipv6'

# polish: removed migrations
removed_count="$(grep -rEc 'migrate_(dns_uci|route_07|list_suffix|cron|list_headers)|OLD_DNS_BACKUP_FILE|OLD_SUBSCRIPTION_OPTIONS|dns.backup' "$ROOT_DIR/rootfs" | awk -F: '{ n += $NF } END { print n + 0 }' || true)"
assert_eq 0 "$removed_count" 'removed migrations'
pass 'removed migrations'

# Spec 13: the automatic core update option is removed; MihoWRT leftovers are not migrated.
fake_uci_set xraywrt.settings.core_auto_update 1
migrate
assert_false 'core_auto_update removed (spec 13)' uci -q get xraywrt.settings.core_auto_update
assert_false 'no MihoWRT clean-up in the migration' grep -E 'mihomo_log_level|dashboard|runtime\.lock' "$ROOT_DIR/rootfs/usr/lib/xraywrt/migration.sh"
pass 'core_auto_update removed'

# Spec 7.5: refusing other DNS types is gone; forwarding is opt-in.
fake_uci_set xraywrt.settings.dns_refuse_other_types 1
fake_uci_set xraywrt.settings.dns_block_https_rr 1
migrate
assert_false 'dns_refuse_other_types removed' uci -q get xraywrt.settings.dns_refuse_other_types
assert_false 'dns_block_https_rr removed' uci -q get xraywrt.settings.dns_block_https_rr
assert_eq 0 "$(uci_get dns_forward_other_types)" 'dns_forward_other_types stays off'
pass 'dns_refuse_other_types removed'

# B3 / spec 16: empty list needs no placeholder; existing overrides survive upgrades.
assert_eq '' "$(settings_balancer_overrides)" 'no saved overrides by default'
fake_uci_set xraywrt.settings.balancer_override "'main=node-a' 'backup=node-b'"
migrate
assert_eq $'main=node-a\nbackup=node-b' "$(settings_balancer_overrides)" 'migration preserves balancer overrides'
pass 'balancer override migration'

# UX 6.1a: preserve an explicit old direct-first choice, once.
assert_eq '' "$(uci_get provider_override)" 'proxy-first needs no mode override'
uci_set mode direct-first
uci add_list xraywrt.settings.provider_override=disable_quic
migrate
assert_eq 'disable_quic mode' "$(uci_get provider_override)" 'direct-first migrated to override'
before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" 'mode migration idempotent'
pass 'legacy mode migration'

# My rules replace the four lists of sites and addresses. Old "always direct" entries
# become `<entry> direct` and come first; old "via VPN" addresses keep what they did
# (`core`); sites via VPN and entries with ports have no target and stay as comments.
legacy="$LIST_DIR"
printf '# own\n1.1.1.1\nhttps://dst.example/list\n2.2.2.2;443\n' >"$legacy/always_proxy_dst.txt"
printf '77.88.8.0/24\n2a02:6b8::/32\n9.9.9.9;53\nhttps://direct.example/list\n' >"$legacy/direct_dst.txt"
printf 'geosite:youtube\ndomain:vpn.example\n' >"$legacy/fake_domains.txt"
printf 'example.com\nfull:direct.example.org\n' >"$legacy/direct_domains.txt"
printf '192.168.1.5\n' >"$SRC_LIST_FILE"
fake_uci_set xraywrt.settings.dst_list_source own
fake_uci_set xraywrt.settings.direct_list_source merge
fake_uci_set xraywrt.settings.fake_domains_source own
note='# Add a target (direct, core or a server tag) to each line below and remove the leading # to use it. Ports (;443) are no longer supported.'
expected="example.com direct
full:direct.example.org direct
77.88.8.0/24 direct
2a02:6b8::/32 direct
https://direct.example/list direct
1.1.1.1 core
https://dst.example/list core
$note
# 9.9.9.9;53
# 2.2.2.2;443
# geosite:youtube
# domain:vpn.example"
migrate
assert_eq "$expected" "$(cat "$RULES_FILE")" 'old entries become My rules, direct first'
assert_eq '' "$(cat "$legacy/always_proxy_dst.txt")$(cat "$legacy/direct_dst.txt")" 'old address lists emptied'
assert_false 'old site lists removed' test -e "$legacy/fake_domains.txt" -o -e "$legacy/direct_domains.txt"
assert_eq 192.168.1.5 "$(cat "$SRC_LIST_FILE")" 'device lists untouched'
assert_eq '' "$(uci_get dst_list_source)$(uci_get direct_list_source)$(uci_get fake_domains_source)" 'the three source options are removed'
cp "$RULES_FILE" "$tmpdir/rules.migrated"
migrate
assert_true 'migration is idempotent' cmp -s "$RULES_FILE" "$tmpdir/rules.migrated"
# Every moved line is a valid rule, and the comments are not rules.
printf 'proxy\n' | xraywrt-json rules check "$RULES_FILE" >"$tmpdir/rules.check"
assert_eq '' "$(cat "$tmpdir/rules.check")" 'the migrated list passes the same check as a saved one'
pass 'old lists migrate to My rules'

# A parked subscription migrates in its own directory; an existing My rules text is kept below.
mkdir -p "$XRAY_SUBS_DIR/s1/lists"
printf '3.3.3.3\n' >"$XRAY_SUBS_DIR/s1/lists/dst.txt"
printf 'old.example\n' >"$XRAY_SUBS_DIR/s1/lists/direct-domains.txt"
printf 'kept.example core\n' >"$XRAY_SUBS_DIR/s1/lists/rules.txt"
uci -q set xraywrt.s1=subscription
uci -q set xraywrt.s1.dst_list_source=own
subscription_ids() { echo s1; }
migrate
assert_eq $'old.example direct\n3.3.3.3 core\nkept.example core' "$(cat "$XRAY_SUBS_DIR/s1/lists/rules.txt")" 'parked subscription migrated, its own rules kept'
assert_false 'parked old file removed' test -e "$XRAY_SUBS_DIR/s1/lists/direct-domains.txt"
assert_eq '' "$(uci -q get xraywrt.s1.dst_list_source || true)" 'parked source option removed'
# A power cut between writing My rules and emptying the old files: the next run adds nothing twice.
cp "$XRAY_SUBS_DIR/s1/lists/rules.txt" "$tmpdir/rules.s1"
printf '3.3.3.3\n' >"$XRAY_SUBS_DIR/s1/lists/dst.txt"
printf 'old.example\n' >"$XRAY_SUBS_DIR/s1/lists/direct-domains.txt"
migrate
assert_true 'an interrupted migration is not repeated' cmp -s "$XRAY_SUBS_DIR/s1/lists/rules.txt" "$tmpdir/rules.s1"
assert_eq '' "$(cat "$XRAY_SUBS_DIR/s1/lists/dst.txt")" 'the old file is emptied on the second run'
assert_false 'the old site list is removed on the second run' test -e "$XRAY_SUBS_DIR/s1/lists/direct-domains.txt"
pass 'parked subscription lists migrate'
