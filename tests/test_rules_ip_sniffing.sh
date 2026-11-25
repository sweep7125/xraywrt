#!/usr/bin/env bash
# My rules, address lines on the real core when the provider's sniffing overrides
# the destination: a connection to an address of `<subnet> <tag>` is made by its
# real address, and the first bytes carry a TLS SNI or an HTTP Host. The test
# starts the core on the generated config and reads from its access log which
# outbound took each connection.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
xray_test_bin 'rules IP lines with sniffing on the real core' || exit 0
command -v node >/dev/null || fail 'node missing from the test image'

proxy_ob='{"tag":"proxy","protocol":"socks","settings":{"servers":[{"address":"192.0.2.1","port":1080}]}}'
direct_ob='{"tag":"direct","protocol":"freedom"}'
# The provider sniffs TLS and HTTP and sends the site of the test to direct.
src_json "{\"outbounds\":[$direct_ob,$proxy_ob],\"routing\":{\"rules\":[{\"domain\":[\"domain:site.example\"],\"outboundTag\":\"direct\"}]},\"inbounds\":[{\"tag\":\"provider-in\",\"protocol\":\"tunnel\",\"listen\":\"127.0.0.1\",\"port\":12345,\"settings\":{\"followRedirect\":true,\"allowedNetwork\":\"tcp,udp\"},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}]}"
printf '%s\n' '203.0.113.0/24 proxy' >"$tmpdir/rules.txt"
gen "$tmpdir/src.json" ".mode_override = true | .mode = \"direct-first\" | .wan_dns = [\"127.0.0.1\"] | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {} | .dns_forward_other_types = 0 | .api_listen = \"$tmpdir/api.sock,0600\""
assert_eq 0 "$rc" "generate: $errtxt"
jq -e '[.routing.rules[] | select(.ruleTag == "xraywrt-rule-1")] | length == 1' <<<"$out" >/dev/null || fail "no ip rule in: $(jq -c .routing <<<"$out")"

# Test inbound: what a TPROXY connection to 203.0.113.7:443 looks like to the core,
# with the sniffing the generator gave the router's own listener.
jq --arg log "$tmpdir/access.log" '
	(.inbounds[] | select(.tag == "xraywrt-tproxy4") | .sniffing) as $sniffing
	| .inbounds = [{tag: "m4-in", listen: "127.0.0.1", port: 18947, protocol: "tunnel", settings: {address: "203.0.113.7", port: 443, network: "tcp"}, sniffing: $sniffing}]
	| .log = {loglevel: "info", access: $log}' <<<"$out" >"$tmpdir/runtime.json"
jq -e '.inbounds[0].sniffing.enabled == true and (.inbounds[0].sniffing.destOverride | index("tls")) and (.inbounds[0].sniffing.routeOnly // false) == false' "$tmpdir/runtime.json" >/dev/null ||
	fail "the generated sniffing is not an overriding one: $(jq -c .inbounds[0].sniffing "$tmpdir/runtime.json")"

cat >"$tmpdir/client.js" <<'NODE'
const net = require('net'), tls = require('tls');
const kind = process.argv[2];
const done = () => process.exit(0);
setTimeout(done, 2500);
if (kind === 'tls') {
	const s = tls.connect({ host: '127.0.0.1', port: 18947, servername: 'site.example', rejectUnauthorized: false });
	s.on('error', done); s.on('close', done);
} else {
	const s = net.connect(18947, '127.0.0.1', () => s.write(kind === 'http' ? 'GET / HTTP/1.1\r\nHost: site.example\r\n\r\n' : 'plain bytes that are neither TLS nor HTTP\r\n'));
	s.on('error', done); s.on('close', done);
}
NODE
# measure <jq filter on the test config>: "plain tls http" outbound results for one core run.
measure() {
	local core="" plain="" tls="" http=""
	jq "${1:-.}" "$tmpdir/runtime.json" >"$tmpdir/measure.json"
	XRAY_LOCATION_ASSET="$XRAY_TEST_ASSETS" "$XRAY_TEST_BIN" run -c "$tmpdir/measure.json" >"$tmpdir/core.log" 2>&1 &
	core=$!
	sleep 2
	kill -0 "$core" || fail "core did not start: $(cat "$tmpdir/core.log")"
	plain="$(outbound_of plain)"
	tls="$(outbound_of tls)"
	http="$(outbound_of http)"
	kill "$core"
	wait "$core" 2>/dev/null || :
	printf 'plain=[%s] tls=[%s] http=[%s]' "$plain" "$tls" "$http"
}
# outbound_of <tls|http|plain>: address and outbound tag of the connection made by this client.
outbound_of() {
	: >"$tmpdir/access.log"
	node "$tmpdir/client.js" "$1" || :
	sleep 1
	sed -n 's/.* accepted [a-z]*:\([^ ]*\) \[m4-in -> \([^]]*\)\].*/\1 \2/p' "$tmpdir/access.log" | head -n 1
}

# Provider sniffing as the generator passes it on (the destination is overridden).
overriding="$(measure)"
printf 'evidence, overriding sniffing: %s\n' "$overriding"
# Control: the same sniffing in route-only mode keeps the address for routing.
route_only="$(measure '.inbounds[0].sniffing.routeOnly = true')"
printf 'evidence, routeOnly sniffing:  %s\n' "$route_only"
assert_eq 'plain=[203.0.113.7:443 proxy] tls=[site.example:443 proxy] http=[site.example:443 proxy]' "$route_only" 'the address rule matches when the sniffed name does not replace the address'
# Known limit (docs/user-guide.md, My rules): with overriding sniffing a sniffed TLS or HTTP
# connection no longer has the address of the rule, so an address line with a server or balancer
# target does not catch it; the provider's rules decide. Traffic without a sniffed name is caught.
assert_eq 'plain=[203.0.113.7:443 proxy] tls=[site.example:443 direct] http=[site.example:443 direct]' "$overriding" 'the address rule misses sniffed connections'
pass 'My rules: address lines with provider sniffing on the real core'
