#!/usr/bin/env bash
# Pinned Go Xray experiment, no VM; run explicitly in xraywrt-test:local.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
xray_test_bin 'live geodata probe' || exit 0
tmpdir="$(make_temp_dir)"
XRAY_API_SOCKET="$tmpdir/api.sock"
pid='' http='' rc=0
trap 'rc=$?; [ "$rc" = 0 ] || cat "$tmpdir/core.log"; kill ${pid:-} ${http:-} 2>/dev/null || :; rm -rf "$tmpdir"' EXIT
export XRAY_LOCATION_ASSET="$tmpdir"
# Minimal protobuf GeoSiteList / GeoIPList, with one named category each.
write_data() {
 node - "$tmpdir" "$1" <<'NODE'
const fs = require('fs'), dir = process.argv[2], changed = process.argv[3] === 'changed';
const field = (n, b) => Buffer.concat([Buffer.from([n * 8 + 2, b.length]), b]);
const text = (n, s) => field(n, Buffer.from(s));
const site = field(1, Buffer.concat([text(1, 'TEST'), field(2, Buffer.concat([Buffer.from([8, 3]), text(2, changed ? 'other.test' : 'probe.test')]))]));
const ip = field(1, Buffer.concat([text(1, 'TEST'), field(2, Buffer.from([10, 4, ...(changed ? [192, 0, 2, 1] : [127, 0, 0, 1]), 16, 32]))]));
fs.writeFileSync(dir + '/geosite.dat', site); fs.writeFileSync(dir + '/custom.dat', site); fs.writeFileSync(dir + '/geoip.dat', ip);
NODE
}
node -e 'require("http").createServer((q,s)=>{s.writeHead(204);s.end()}).listen(18080,"127.0.0.1")' &
http=$!
jq --arg listen "$XRAY_API_SOCKET,0600" '.api.listen = $listen | .inbounds += [{tag:"probe",protocol:"socks",listen:"127.0.0.1",port:18081,settings:{auth:"noauth",udp:false}}] | .outbounds = [{tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIP"}},{tag:"block",protocol:"blackhole"}] | .routing.balancers = [] | del(.observatory) | .dns = {hosts:{"probe.test":"127.0.0.1","other.test":"127.0.0.1"},servers:["localhost"]}' "$ROOT_DIR/tests/fixtures/xray-api/config.json" >"$tmpdir/base.json"
status() {
 node - "$1" <<'NODE'
const net = require('net'), host = process.argv[2];
const s = net.connect(18081, '127.0.0.1'); let phase = 0, buf = Buffer.alloc(0), done = false;
const end = code => { if (!done) { done = true; console.log(code); s.destroy(); } };
s.setTimeout(2000, () => end('000')); s.on('error', () => end('000')); s.on('end', () => end('000'));
s.on('connect', () => s.write(Buffer.from([5, 1, 0])));
s.on('data', b => {
 buf = Buffer.concat([buf, b]);
 if (phase === 0 && buf.length >= 2) { phase = 1; buf = Buffer.alloc(0); s.write(Buffer.concat([Buffer.from([5, 1, 0, 3, host.length]), Buffer.from(host), Buffer.from([70, 160])])); }
 else if (phase === 1 && buf.length >= 10) { if (buf[1] !== 0) return end('000'); phase = 2; buf = Buffer.alloc(0); s.write(`GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`); }
 else if (phase === 2) { const m = buf.toString().match(/^HTTP\/1\.[01] (\d+)/); if (m) end(m[1]); }
});
NODE
}
for ref in geosite:TEST geoip:TEST ext:custom.dat:TEST; do
 write_data initial
 "$XRAY_TEST_BIN" run -c "$tmpdir/base.json" >"$tmpdir/core.log" 2>&1 & pid=$!
 for _ in {1..50}; do
  "$XRAY_TEST_BIN" api adrules --server="unix:$XRAY_API_SOCKET" "$tmpdir/base.json" >/dev/null 2>&1 && break
  sleep .1
 done
 field=domain target=probe.test
 [[ "$ref" != geoip:* ]] || { field=ip; target=127.0.0.1; }
 jq --arg ref "$ref" --arg field "$field" '.routing.rules += [{($field):[$ref],outboundTag:"block"}]' "$tmpdir/base.json" >"$tmpdir/rules.json"
 assert_eq 204 "$(status "$target")" "$ref unused at start"
 "$XRAY_TEST_BIN" run -test -c "$tmpdir/rules.json" >"$tmpdir/test.log" 2>&1
 "$XRAY_TEST_BIN" api adrules --server="unix:$XRAY_API_SOCKET" "$tmpdir/rules.json"
 assert_eq 000 "$(status "$target")" "$ref newly referenced file/category loaded by adrules"
 write_data changed
 "$XRAY_TEST_BIN" api adrules --server="unix:$XRAY_API_SOCKET" "$tmpdir/rules.json"
 after="$(status "$target")"
 assert_eq 000 "$after" "$ref running core retains cached bytes"
 printf 'probe %s changed same-name file: HTTP %s\n' "$ref" "$after"
 # Restart comparison on identical candidate + disk bytes.
 kill "$pid"; wait "$pid" || :; pid=''
 "$XRAY_TEST_BIN" run -c "$tmpdir/rules.json" >"$tmpdir/core.log" 2>&1 & pid=$!
 sleep .3
 assert_eq 204 "$(status "$target")" "$ref restart uses changed file"
 printf 'probe %s restart: HTTP 204\n' "$ref"
 kill "$pid"; wait "$pid" || :; pid=''
done
# Default-outbound and balancer replacement semantics also bound hot apply.
"$XRAY_TEST_BIN" run -c "$tmpdir/base.json" >"$tmpdir/core.log" 2>&1 & pid=$!
sleep .3
assert_eq 204 "$(status probe.test)" 'default direct initially'
"$XRAY_TEST_BIN" api rmo --server="unix:$XRAY_API_SOCKET" direct
jq '{outbounds:[.outbounds[0]]}' "$tmpdir/base.json" >"$tmpdir/add.json"
"$XRAY_TEST_BIN" api ado --server="unix:$XRAY_API_SOCKET" "$tmpdir/add.json"
printf 'probe remove/add default outbound: HTTP %s\n' "$(status probe.test)"
load_modules constants.sh helpers.sh validate.sh xray-api.sh
XRAY_API_SOCKET="$tmpdir/api.sock"
XRAY_BIN="$XRAY_TEST_BIN" XRAY_SHARE_DIR="$tmpdir" XRAY_API_SOCKET="$tmpdir/api.sock"
jq '.outbounds[0] = {tag:"direct",protocol:"blackhole"}' "$tmpdir/base.json" >"$tmpdir/default.json"
xray_api_apply "$tmpdir/base.json" "$tmpdir/default.json"
assert_eq 000 "$(status probe.test)" 'changed default uses replacement handler, not its old pointer'
xray_api_apply "$tmpdir/default.json" "$tmpdir/base.json"
assert_eq 204 "$(status probe.test)" 'restored default uses replacement freedom handler'
echo 'probe changed default handler: HTTP 000 then 204'
jq '.routing.balancers = [{tag:"main",selector:["direct"],strategy:{type:"random"}}]' "$tmpdir/base.json" >"$tmpdir/balancer.json"
"$XRAY_TEST_BIN" api adrules --server="unix:$XRAY_API_SOCKET" "$tmpdir/balancer.json"
"$XRAY_TEST_BIN" api bi --server="unix:$XRAY_API_SOCKET" -json main
"$XRAY_TEST_BIN" api adrules --server="unix:$XRAY_API_SOCKET" "$tmpdir/base.json"
if "$XRAY_TEST_BIN" api bi --server="unix:$XRAY_API_SOCKET" -json main; then
 fail 'adrules left a removed balancer present'
else
 echo 'probe removed balancer: absent'
fi
jq '.outbounds += [{tag:"new",protocol:"freedom"}] | .routing.rules += [{domain:["full:probe.test"],outboundTag:"block"}]' "$tmpdir/base.json" >"$tmpdir/hot.json"
xray_api_apply "$tmpdir/base.json" "$tmpdir/hot.json"
assert_eq 000 "$(status probe.test)" 'shared API wrapper adds outbound and replaces rules'
jq '(.outbounds[] | select(.tag == "block")) |= {tag:"block",protocol:"freedom",settings:{domainStrategy:"UseIP"}}' "$tmpdir/hot.json" >"$tmpdir/hot-next.json"
xray_api_apply "$tmpdir/hot.json" "$tmpdir/hot-next.json"
assert_eq 204 "$(status probe.test)" 'shared API wrapper replaces just changed outbound'
echo 'probe shared xray_api_apply: HTTP 000 then 204, core PID unchanged'
