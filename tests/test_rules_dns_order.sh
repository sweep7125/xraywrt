#!/usr/bin/env bash
# My rules, DNS order on the real core: the first matching line wins for
# overlapping names. The generator puts one DNS server entry per run of lines in
# line order before the provider's servers; Xray then asks the first entry whose
# domains match, whatever the kind of the matcher (domain, full, keyword).
# A "direct" name must get a real address, a "core" or tag name a fake IP.

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
source "$ROOT_DIR/tests/xray_gen_lib.sh"
xray_test_bin 'rules DNS order on the real core' || exit 0
command -v node >/dev/null || fail 'node missing from the test image'

# gen_rules <mode> <rules text>: runtime config of the router with My rules,
# without the TPROXY listeners (no NET_ADMIN in the test container). The WAN
# DNS is the fake upstream of the probe on 127.0.0.1:53.
gen_rules() {
	printf '%s\n' "$2" >"$tmpdir/rules.txt"
	gen "$FX/src/single.json" ".mode_override = true | .mode = \"$1\" | .wan_dns = [\"127.0.0.1\"] | .rules_file = \"$tmpdir/rules.txt\" | .rules_remote = {}"
	assert_eq 0 "$rc" "generate: $errtxt"
	jq '.inbounds |= map(select(.tag == "xraywrt-dns-in"))' <<<"$out" >"$tmpdir/runtime.json"
}

# probe <names...>: starts the core on $tmpdir/runtime.json and prints
# "<name> real|fake" for each name asked through the router DNS inbound.
cat >"$tmpdir/probe.js" <<'NODE'
const dgram = require('dgram'), cp = require('child_process');
const [ , , config, ...names ] = process.argv;
const ask = (name, timeout = 4000) => new Promise((resolve) => {
	const socket = dgram.createSocket('udp4'), id = Math.floor(Math.random() * 65535);
	const labels = name.split('.').flatMap((l) => [ Buffer.from([ l.length ]), Buffer.from(l) ]);
	const query = Buffer.concat([ Buffer.from([ id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 ]), ...labels, Buffer.from([ 0, 0, 1, 0, 1 ]) ]);
	const timer = setTimeout(() => { socket.close(); resolve('timeout'); }, timeout);
	socket.on('message', (m) => {
		clearTimeout(timer); socket.close();
		if (!m.readUInt16BE(6)) return resolve('empty');
		const ip = [ ...m.subarray(m.length - 4) ];
		resolve(ip[0] === 198 && (ip[1] === 18 || ip[1] === 19) ? 'fake' : ip.join('.') === '192.0.2.80' ? 'real' : 'other ' + ip.join('.'));
	});
	socket.send(query, 7874, '127.0.0.1');
});
const upstream = dgram.createSocket('udp4');
// The WAN DNS of the test: every A query gets 192.0.2.80.
upstream.on('message', (m, r) => {
	let i = 12;
	while (m[i]) i += m[i] + 1;
	const head = Buffer.from(m.subarray(0, i + 5));
	head[2] = 0x81; head[3] = 0x80; head[7] = 1;
	upstream.send(Buffer.concat([ head, Buffer.from([ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 80 ]) ]), r.port, r.address);
});
upstream.bind(53, '127.0.0.1', async () => {
	const core = cp.spawn(process.env.XRAY_TEST_BIN, [ 'run', '-c', config ], { env: { ...process.env, XRAY_LOCATION_ASSET: process.env.XRAY_TEST_ASSETS } });
	core.stdout.pipe(process.stderr);
	core.stderr.pipe(process.stderr);
	let exit = null;
	core.on('error', (err) => { exit = err.message; });
	core.on('exit', (code, signal) => { exit = `code ${code}, signal ${signal}`; });
	let ready = false;
	for (let i = 0; i < 20 && exit === null; i++) {
		if (await ask('readiness.example', 500) === 'real') { ready = true; break; }
	}
	if (!ready || exit !== null) {
		console.error('core readiness failed: ' + (exit ?? 'timed out after 10 seconds'));
		process.exitCode = 1;
	} else {
		for (const name of names) console.log(name + ' ' + await ask(name));
	}
	core.kill();
	upstream.close();
});
NODE
probe() {
	XRAY_TEST_BIN="$XRAY_TEST_BIN" XRAY_TEST_ASSETS="$XRAY_TEST_ASSETS" node "$tmpdir/probe.js" "$tmpdir/runtime.json" "$@" 2>"$tmpdir/probe.log"
}

# check <mode> <rules> <expected "name=real|fake" ...>
check() {
	local mode="$1" rules="$2" answers="" item=""
	shift 2
	gen_rules "$mode" "$rules"
	answers="$(probe "${@%%=*}")" || fail "probe failed for: $rules; core output: $(cat "$tmpdir/probe.log")"
	for item in "$@"; do
		grep -qx "${item%%=*} ${item#*=}" <<<"$answers" || fail "$mode, rules '$(tr '\n' ';' <<<"$rules")': expected ${item%%=*} ${item#*=}, got: $(tr '\n' ';' <<<"$answers"); core output: $(cat "$tmpdir/probe.log")"
	done
}

# The example of the brief: disjoint blocks of different targets.
check direct-first $'google.ai direct\ngoogle.com core' google.ai=real www.google.com=fake other.org=real
# Nested names, the longer one first and the shorter one first.
check direct-first $'mail.example.com core\nexample.com direct' mail.example.com=fake a.mail.example.com=fake www.example.com=real
check direct-first $'example.com direct\nmail.example.com core' mail.example.com=real a.mail.example.com=real www.example.com=real
# The kind of the matcher does not decide: the earlier line does.
check direct-first $'example.com direct\nfull:mail.example.com core' mail.example.com=real
check direct-first $'full:mail.example.com core\nexample.com direct' mail.example.com=fake www.example.com=real
check direct-first $'keyword:mail core\nexample.com direct' mail.example.com=fake www.example.com=real
check direct-first $'example.com direct\nkeyword:mail core' mail.example.com=real mail.other.org=fake
# A direct run between two runs of one target does not merge them.
check direct-first $'a.example core\nb.example.org direct\nc.example core\nexample.org core' a.example=fake b.example.org=real c.example=fake www.example.org=fake
# A tag target is a fake IP like core.
check direct-first $'mail.example.com proxy\nexample.com direct' mail.example.com=fake www.example.com=real
pass 'My rules: the first matching line decides the DNS answer on the real core'
