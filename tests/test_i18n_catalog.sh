#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
const root = process.argv[2];
const dir = path.join(root, 'rootfs/www/luci-static/resources');
const files = [...fs.readdirSync(path.join(dir, 'xraywrt')).filter(f => f.endsWith('.js')).map(f => path.join(dir, 'xraywrt', f)), ...fs.readdirSync(path.join(dir, 'view/xraywrt')).map(f => path.join(dir, 'view/xraywrt', f))];
const strings = new Set();
const literal = "'(?:[^'\\\\]|\\\\.)*'";
const decode = s => Function('return ' + s)();
for (const file of files) {
 const source = fs.readFileSync(file, 'utf8');
 for (const m of source.matchAll(new RegExp('(?<![\\w])_\\(\\s*(' + literal + ')', 'g'))) strings.add(decode(m[1]));
 for (const m of source.matchAll(new RegExp('N_\\([^,]+,\\s*(' + literal + '),\\s*(' + literal + ')', 'g'))) { strings.add(decode(m[1])); strings.add(decode(m[2])); }
}
const po = fs.readFileSync(path.join(root, 'po/ru/xraywrt.po'), 'utf8');
const catalog = new Set();
for (const m of po.matchAll(/^msgid(?:_plural)? (".*")(?:\n".*")*/gm)) {
 const value = m[0].replace(/^msgid(?:_plural)? /, '').split('\n').map(s => JSON.parse(s)).join('');
 if (value) {
  assert(!catalog.has(value), 'duplicate msgid: ' + value);
  catalog.add(value);
 }
}
// Menu titles are translated from the same catalog.
const menu = JSON.parse(fs.readFileSync(path.join(root, 'rootfs/usr/share/luci/menu.d/luci-app-xraywrt.json'), 'utf8'));
for (const entry of Object.values(menu)) if (entry.title && entry.title !== 'XrayWRT') strings.add(entry.title);
const missing = [...strings].filter(s => !catalog.has(s));
const obsolete = [...catalog].filter(s => !strings.has(s));
assert.deepStrictEqual(missing, [], 'missing translations');
assert.deepStrictEqual(obsolete, [], 'obsolete translations');
assert(po.includes('Plural-Forms: nplurals=3;'), 'Russian plural header');
for (const [id, translated] of [
 ['Service is running', 'Служба XrayWRT работает'],
 ['Remote lists', 'Списки по ссылкам'],
 ['Update remote lists', 'Обновить списки по ссылкам'],
 ['Starts at boot', 'Запускается при включении роутера'],
 ['System log is not available.', 'Журнал недоступен.'],
 ['Traffic mode', 'Режим'],
 ['VPN addresses (Only selected sites via VPN mode)', 'Адреса через VPN (режим «Через VPN только выбранное»)'],
 ['Update now', 'Обновить подписку']
]) assert(po.includes('msgid ' + JSON.stringify(id) + '\nmsgstr ' + JSON.stringify(translated)), 'glossary: ' + id);

const msgstrs = [...po.matchAll(/msgstr(?:\[\d+\])?\s+(".*"(?:\s*\n".*")*)/g)].map(m => m[1]);
msgstrs.push(JSON.stringify(fs.readFileSync(path.join(root, 'README.ru.md'), 'utf8')));
for (const str of msgstrs) {
 const text = JSON.parse('[' + str.replace(/\n/g, ',') + ']').join('');
 assert(!/(?:GiB|MiB|KiB|ГиБ|МиБ|КиБ)/.test(text), 'forbidden GiB/MiB/KiB in Russian translation: ' + text);
 assert(!/удалённ\S*\s+списк/i.test(text), 'forbidden удалённые списки in Russian translation: ' + text);
 assert(!/(?:профил|прокси-сервер|Обновить сейчас|веб-панел|системный журнал)/i.test(text), 'forbidden glossary term: ' + text);
 assert(!/(?<!интернет-)провайдер/i.test(text), 'use сервис for subscriptions, интернет-провайдер for the ISP: ' + text);
 assert(!/(?:сервис\s+XrayWRT|XrayWRT\s+сервис)/i.test(text), 'XrayWRT is a служба, not a сервис: ' + text);
}

for (const id of ['Everything via VPN except exclusions', 'Only selected sites via VPN', 'My rules', 'Devices via VPN', 'Devices always direct', 'Download the subscription directly', 'Server', 'Subscription', 'Updates', 'Help', 'Advanced', 'Check connection', 'Copy summary', 'Download detailed report']) assert(strings.has(id), 'UX wording missing: ' + id);
for (const id of ['All traffic via proxy except exclusions', 'Only selected traffic via proxy', 'Addresses via proxy', 'Devices via proxy', 'Addresses always direct', 'Domains via fake-IP', 'Subscription server without Xray', 'Profile', 'Configuration', 'Config', 'Core', 'Diagnostics', 'Settings']) assert(!strings.has(id) && !catalog.has(id), 'old UX wording: ' + id);
const proxyExceptions = [];
for (const value of strings) assert(!/\b(?:proxy|proxied)\b/i.test(value) || proxyExceptions.includes(value), 'traffic wording still says proxy: ' + value);

assert(!/VPN-сервис/i.test(po), 'use сервис without the redundant VPN prefix in UI translations');
// Copy edits must preserve formatting arguments in both languages.
for (const block of po.split('\n\n')) {
 const id = block.match(/^msgid (".*")$/m);
 if (!id || !JSON.parse(id[1])) continue;
 const placeholders = value => (value.match(/%(?:\d+\$)?[sd]/g) || []).sort();
 for (const translated of block.matchAll(/^msgstr(?:\[\d+\])? (".*")$/gm))
  assert.deepStrictEqual(placeholders(JSON.parse(translated[1])), placeholders(JSON.parse(id[1])), 'format arguments: ' + id[1]);
}
for (const value of strings) {
 if (/^(?:Paste |Link to the )/.test(value))
  assert(!/Xray JSON/.test(value), 'keep format jargon in format errors and the editor: ' + value);
}
console.log('ok - exact JS translation catalog including plurals');
NODE
