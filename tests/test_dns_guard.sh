#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh dns.sh subscription.sh service.sh status.sh
setup_runtime_paths "$tmpdir"
netstat() {
 if [ "${no_p:-0}" = 1 ] && [ "$1" = -lnp ]; then return 1; fi
 printf '%s\n' "$fixture_listeners"
}
pidof() { [ "${dnsmasq_running:-1}" = 1 ] && echo 2807; }
uci() { printf "%s\n" "dhcp.cfg=dnsmasq" "dhcp.cfg.server='$fixture_servers'"; }
fixture_servers=''
fixture_listeners='tcp 0 0 127.0.0.1:53 0.0.0.0:* LISTEN 2807/dnsmasq
udp 0 0 127.0.0.1:53 0.0.0.0:* 2807/dnsmasq'
assert_true 'dnsmasq owns TCP and UDP 53' dns_guard
for proto in tcp udp; do
 fixture_listeners="$proto 0 0 :::53 :::* $([ "$proto" != tcp ] || echo LISTEN) 123/AdGuardHome"
 assert_false 'foreign listener rejected' dns_guard 2>"$tmpdir/error"
 assert_file_contains "$tmpdir/error" 'port 53 is used by AdGuardHome' 'foreign program identified from last field'
 assert_file_contains "$tmpdir/error" ' [E:dns_port_busy|AdGuardHome]' 'foreign listener error code'
done
fixture_listeners='udp 0 0 127.0.0.1:5353 0.0.0.0:* 123/AdGuardHome'
assert_true 'other ports allowed' dns_guard
fixture_listeners='udp 0 0 127.0.0.1:53 0.0.0.0:*'
no_p=1 dnsmasq_running=0
assert_false 'unsupported -p without dnsmasq rejected' dns_guard 2>"$tmpdir/error"
assert_file_contains "$tmpdir/error" ' [E:dns_port_busy|unknown program]' 'fallback carries the port code'
dnsmasq_running=1
assert_true 'unsupported -p with dnsmasq allowed' dns_guard
fixture_listeners='' no_p=0
fixture_servers='8.8.8.8'
assert_false 'global forwarder rejected' dns_guard 2>"$tmpdir/error"
assert_file_contains "$tmpdir/error" 'dnsmasq forwards DNS to 8.8.8.8' 'forwarder named'
service_recover() { :; }
settings_ensure_generated() { :; }
settings_load() { :; }
runtime_dirs_init() { :; }
cron_update() { :; }
runtime_config_build() { touch "$tmpdir/built"; }
assert_false 'prepare aborts on DNS guard' service_prepare_cmd 2>"$tmpdir/prepare.error"
assert_file_contains "$LAST_ERROR_FILE" 'dnsmasq forwards DNS to 8.8.8.8' 'prepare records guard error'
assert_file_contains "$LAST_ERROR_FILE" ' [E:dns_forwarders|8.8.8.8]' 'prepare preserves the forwarder code'
assert_false 'guard prevents config build' test -e "$tmpdir/built"
fixture_servers='/lan/192.168.1.1'
assert_true 'domain forwarder allowed' dns_guard
pass 'DNS guard listeners, forwarders and prepare error'
