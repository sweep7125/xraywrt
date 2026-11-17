#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
source "$XRAYWRT_LIB_DIR/helpers.sh"
logger() { :; }
actual="$(err_code x 'a %s' 'p|q]' 2>&1)"
assert_eq 'Error: a p/q/ [E:x|p/q/]' "$actual" 'coded error sanitizes arguments'
actual="$(err_code x 'a %s' $'p\nq' 2>&1)"
assert_eq 'Error: a p/q [E:x|p/q]' "$actual" 'coded error stays on one line'
logger() { printf '%s\n' "$*"; }
actual="$(warn_code x 'a %s' 'p|q]')"
assert_eq '-p daemon.warn -t xraywrt a p/q/ [E:x|p/q/]' "$actual" 'coded warning uses syslog'
assert_eq '' "$(XRAYWRT_QUIET=1 warn_code x 'a %s' 'p|q]')" 'quiet warning stays quiet'
logger() { :; }
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
jq --arg profile $'p|q]\n' '.profile = $profile' "$ROOT_DIR/tests/fixtures/xray/params/default.json" >"$tmpdir/params.json"
xraywrt-json gen "$ROOT_DIR/tests/fixtures/xray/src/remnawave-array.json" "$tmpdir/out.json" "$tmpdir/params.json"
assert_file_contains "$tmpdir/out.json.profile" ' [E:profile_missing|p/q//|NL Amsterdam]' 'ucode sanitizes delimiters and newlines'
for command in profiles gen; do
 actual="$(xraywrt-json "$command" "$tmpdir/missing" "$tmpdir/out.json" "$tmpdir/params.json" 2>&1)" && fail 'missing config accepted'
 assert_eq "xraywrt-json: config: cannot read $tmpdir/missing [E:config_missing|$tmpdir/missing]" "$actual" 'JSON entrypoint codes unreadable sources'
done
node - "$ROOT_DIR" <<'NODE'
const assert = require('assert').strict, path = require('path');
const h = require(path.join(process.argv[2], 'tests/js_luci_harness'));
const api = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { _: s => 'translated: ' + s }).module;
assert.equal(api.errorText('boom [E:dns_port_busy|AdGuardHome]'), 'translated: Port 53 is used by AdGuardHome; disable it, XrayWRT routes the router DNS itself.');
assert.equal(api.errorText('plain'), 'plain');
assert.equal(api.errorText('boom [E:x|1]'), 'boom');
assert.equal(api.errorText('broken [E:list_invalid|dst]'), 'broken', 'damaged tail must not break the page');
const fs = require('fs'), vm = require('vm');
const apiSource = h.readSource('rootfs/www/luci-static/resources/xraywrt/api.js');
const table = vm.runInContext('(' + /const ERRORS = (\{[\s\S]*?\n\});/.exec(apiSource)[1] + ')', h.createContext());
const used = new Set();
function scan(dir) {
 for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
  const file = path.join(dir, entry.name);
  if (entry.isDirectory()) { scan(file); continue; }
  const source = fs.readFileSync(file, 'utf8');
  const literal = `("(?:[^"\\\\]|\\\\.)*"|'(?:[^'\\\\]|\\\\.)*')`;
  const patterns = file.endsWith('.uc') || source.startsWith('#!/usr/bin/ucode')
   ? [new RegExp("(?:warn_code\\(profile,|code_message\\()\\s*'([a-z0-9_]+)',\\s*" + literal, 'g')]
   : [new RegExp('(?:err_code|warn_code|code_message) ([a-z0-9_]+) ' + literal, 'g')];
  for (const pattern of patterns) for (const match of source.matchAll(pattern)) {
   const [, code, quoted] = match;
   used.add(code);
   assert(Object.hasOwn(table, code), file + ': missing translation ' + code);
   const fmt = vm.runInNewContext(quoted);
   assert.equal((fmt.match(/%s/g) || []).length, (table[code].match(/%s/g) || []).length, file + ': placeholder count ' + code);
  }
 }
}
scan(path.join(process.argv[2], 'rootfs/usr'));
assert.deepEqual([...used].sort(), Object.keys(table).sort(), 'every code has one used translation');
const po = fs.readFileSync(path.join(process.argv[2], 'po/ru/xraywrt.po'), 'utf8');
const translations = new Map([...po.matchAll(/^msgid (".*")\nmsgstr (".*")$/gm)].map(m => [JSON.parse(m[1]), JSON.parse(m[2])]));
for (const [code, message] of Object.entries(table)) {
 assert(translations.has(message), 'Russian translation for ' + code);
 assert.equal((message.match(/%s/g) || []).length, (translations.get(message).match(/%s/g) || []).length, 'Russian placeholders: ' + code);
}

assert(!apiSource.includes('backendErrorText'), 'English error recognition removed');
assert(!h.readSource('rootfs/www/luci-static/resources/view/xraywrt/overview.js').includes('warningText'), 'warning recognition removed');
console.log('ok - code coverage, format placeholders, and translation fallback');
NODE
pass 'coded errors'
