#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

command -v node >/dev/null 2>&1 || {
	printf 'skip - ui tests (node missing)\n'
	exit 0
}

node "$ROOT_DIR/tests/js_api.js"

node - "$ROOT_DIR" <<'NODE'
const path = require('path');
const h = require(path.join(process.argv[2], 'tests/js_luci_harness.js'));

// E() stub: records nodes. A plain string child would be parsed as HTML by
// LuCI, so the test fails on any non-array children.
function E(tag, attrs, children) {
	if (Array.isArray(attrs) || typeof attrs === 'string') {
		children = attrs;
		attrs = {};
	}
	if (typeof children === 'string')
		throw new Error(`E('${tag}') got a string child: ${children}`);
	if (Array.isArray(children) && children.some(c => c === null))
  throw new Error(`E('${tag}') would render literal null text`);
 const n = { tag, attrs: attrs || {}, children: children || [], listeners: {}, classList: { add() {}, remove() {} } };
 n.click = function() { return this.listeners.click?.(); };
 n.hasAttribute = name => name in n.attrs;
 n.setAttribute = (k, v) => { n.attrs[k] = v; };
 n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
 n.appendChild = c => n.children.push(c);
 n.removeChild = c => n.children.splice(n.children.indexOf(c), 1);
 n.removeAttribute = k => { delete n.attrs[k]; };
 n.replaceChildren = (...nodes) => { n.children = nodes; };
 Object.defineProperty(n, 'textContent', { get: () => n.children.filter(c => typeof c === 'string').join(''), set: value => { n.children = [value]; } });
 Object.defineProperty(n, 'firstChild', { get: () => n.children[0] });
 return n;
}
// Async blocks share stubs (reads, notices): run them one after another.
let chain = Promise.resolve();
const seq = fn => (chain = chain.then(fn));
const textareaOptions = [];
let lastModal = null;
// Tests may click a modal button themselves; otherwise the confirm button is clicked once.
const ui = {
 addNotification() {},
 activeModal: null,
 autoConfirm: true,
 modalCalls: [],
 showModal(title, children) {
  const modal = lastModal = this.activeModal = { title, children };
  this.modalCalls.push(modal);
  const buttons = collect(E('div', {}, children)).filter(n => n.tag === 'button');
  const choice = buttons.find(n => texts(n).includes('Cancel') === !this.autoConfirm);
  if (this.autoConfirm !== null && choice?.listeners?.click) setTimeout(() => { if (this.activeModal === modal) choice.listeners.click(); }, 0);
 },
 hideModal() { lastModal = this.activeModal = null; },
 Textarea: class {
 constructor(value, options) { this.value = value; this.options = options; textareaOptions.push(options); }
 render() {
  const area = E('textarea', { id: 'widget.' + this.options.id, class: 'cbi-input-textarea' }, [this.value]);
  area.value = this.value.replace(/\r\n?/g, '\n'); // a real textarea normalises line breaks
  area.classList.add = cls => { area.attrs.class = [area.attrs.class, cls].filter(Boolean).join(' '); };
  const wrapper = E('div', { id: this.options.id }, [area]);
  wrapper.querySelector = selector => selector === 'textarea' ? area : null;
  return wrapper;
 }
} };
const origEvaluate = h.evaluateLuCIModule;
h.evaluateLuCIModule = (relPath, globals = {}) => {
 const deps = { ui, ...globals };
 // The real base view builds the Save & Apply footer (luci.js view.addFooter).
 if (relPath.endsWith('/advanced.js') && deps.view)
  deps.view = { ...deps.view, prototype: { addFooter: () => E('div', { class: 'cbi-page-actions' }, []) } };
 if (globals.api && !relPath.endsWith('/configuration.js'))
  deps.configuration = origEvaluate('rootfs/www/luci-static/resources/xraywrt/configuration.js', deps).module;
 const result = origEvaluate(relPath, deps);
 if (relPath.endsWith('/configuration.js')) {
  const render = result.module.render;
  result.module.render = sub => E('div', {}, ['subscription', 'editor', 'runtime'].map(section => render(sub, section)));
 }
 return result;
};
// The real entrypoints request one section; runtime must not inspect subscription data.
{
 const direct = origEvaluate('rootfs/www/luci-static/resources/xraywrt/configuration.js', { E, ui, api: { text: x => [x], style: () => E('style'), toggle: () => E('div'), readOnly: () => false } }).module;
 const sub = { get subscriptions() { throw Error('runtime built subscription controls'); } };
 direct.render(sub, 'runtime');
}
// UX task 8: six visible views; the old page URLs have no aliases.
{
 const fs = require('fs');
 const menu = JSON.parse(h.readSource('rootfs/usr/share/luci/menu.d/luci-app-xraywrt.json'));
 const prefix = 'admin/services/xraywrt/';
 const pages = ['overview', 'subscription', 'traffic', 'updates', 'help', 'advanced'];
 h.assertEq(Object.values(menu).filter(e => e.title && e.action.type === 'view').length, 6, 'six menu entries');
 for (const [i, page] of pages.entries()) {
  h.assertEq(menu[prefix + page]?.order, (i + 1) * 10, page + ' menu order');
  h.assertEq(menu[prefix + page]?.action.path, 'xraywrt/' + page, page + ' view');
  h.assert(fs.existsSync(path.join(process.argv[2], 'rootfs/www/luci-static/resources/view/xraywrt/' + page + '.js')), page + ' exists');
 }
 h.assert(!fs.existsSync(path.join(process.argv[2], 'rootfs/www/luci-static/resources/view/xraywrt/balancers.js')), 'no balancers page');
}
const connectDelays = [];
const api = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, setTimeout: (fn, ms) => { connectDelays.push(ms); setTimeout(fn, 0); } }).module;
const isolatedConfig = origEvaluate('rootfs/www/luci-static/resources/xraywrt/configuration.js', { E, ui, api }).module;
isolatedConfig.render({ get subscriptions() { throw Error('editor built subscription controls'); } }, 'editor');
isolatedConfig.render({ get config_backup() { throw Error('subscription built editor controls'); } }, 'subscription');
h.assertEq(api.trafficSummary({ upload: 1024, download: 1024 }), '2.0 KB / Unlimited', 'missing total is unlimited');
h.assertEq(api.trafficSummary({ upload: 0, download: 512, total: 2048 }), '512 B / 2.0 KB', 'usage and total');
h.assertEq(api.trafficSummary({}), 'Unlimited', 'no usage, no total');
h.assertEq(api.trafficSummary({ total: 1073741824 }), '1.0 GB', 'total only');
{
	const ruApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, document: { documentElement: { lang: 'ru' } } }).module;
	h.assertEq(ruApi.formatBytes(2048), '2,0 KB', 'Russian decimal comma');
	h.assertEq(ruApi.formatBytes(1048575), '1,0 MB', 'Russian rounded KB promotes to MB');
}
h.assertEq(api.formatBytes(1048575), '1.0 MB', 'rounded KB promotes to MB');
h.assertEq(api.formatBytes(1073741823), '1.0 GB', 'rounded MB promotes to GB');
h.assert(api.safeLink('javascript:alert(1)', 'x') === null, 'non-http links are dropped');
h.assertEq(api.safeLink('https://example.com', 'x').attrs.rel, 'noopener noreferrer', 'external links isolated');
h.assertEq(api.subscriptionError, undefined, 'redundant subscription error alias removed');
console.log('ok - api helpers');

function collect(node, out = []) {
	if (Array.isArray(node)) {
		node.forEach((c) => collect(c, out));
		return out;
	}
	if (node && typeof node === 'object') {
		out.push(node);
		(node.children || []).forEach((c) => collect(c, out));
	}
	return out;
}
function texts(node) {
	return collect(node).flatMap((n) => n.children.filter((c) => typeof c === 'string'));
}
function findButton(node, label) { return collect(node).find((n) => n.tag === 'button' && texts(n).includes(label)); }
const settle = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
// Debounce timers run only when the test says so.
function fakeTimers() {
	const timers = [];
	return {
		timers,
		globals: { setTimeout: (fn, ms) => timers.push({ fn, ms, live: true }) - 1, clearTimeout: (id) => { if (timers[id]) timers[id].live = false; } },
		pending: () => timers.filter((t) => t.live),
		flush: async () => { for (const t of timers.filter((x) => x.live)) { t.live = false; await t.fn(); } }
	};
}
// The Subscription view's load()/render() data shape is not part of the contract:
// views are mounted through load() with stubbed api.read/api.readLarge.
const reads = { calls: [], sub: {}, responses: {} };
function resetReads(sub = {}, config = { content: 'proxies: []\n' }) {
	Object.assign(reads, { calls: [], sub: { header_interval: 12, ...sub }, responses: { 'read-config': config, 'runtime-config': { content: '', generated: false } } });
}
const readStubs = {
	read: async (cmd) => {
		reads.calls.push(cmd);
		if (cmd === 'subscription-json') return reads.sub;
		throw Error('unexpected read ' + cmd);
	},
	readLarge: async (cmd) => {
		reads.calls.push(cmd);
		if (!(cmd in reads.responses)) throw Error('unexpected readLarge ' + cmd);
		const reply = reads.responses[cmd];
		if (reply instanceof Error) throw reply;
		return reply;
	}
};
async function mountSubscription(view, sub, config) {
	resetReads(sub, config);
	return view.render(await view.load());
}
async function openToggle(page, label) { await findButton(page, label).listeners.click(); await settle(); }
function toggleOf(page, button) { return collect(page).find((n) => n.attrs.class === 'mw-toggle' && collect(n).includes(button)); }

api.jobNotice = () => E('div', { 'aria-live': 'polite' });

const overview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', { poll: { add() {} },
	E, api, view: { extend: (v) => v }, location: {}, window: {}
}).module;
const base = { core_installed: true, subscription_configured: false, running: false, enabled: false, mode: 'direct-first', version: '0.8.0', core: 'v1.19.32' };

{
	const running = { ...base, subscription_configured: true, running: true };
	const rowValue = (sub) => { const nodes = collect(overview.render([ running, sub, [] ])); return nodes.map(n => n.children.filter(c => typeof c === 'string')).flat(); };
	h.assert(rowValue({ auto_update: true, effective_interval: 0 }).includes('Manual only: the provider does not set an update period'), 'auto-update on without a period');
	h.assert(rowValue({ auto_update: false, effective_interval: 0 }).includes('Off'), 'auto-update off');
	h.assert(rowValue({ auto_update: true, effective_interval: 6 }).includes('every 6 h'), 'auto-update period');
}
let page = overview.render([ base, {}, [] ]);
h.assert(texts(page).includes('Connect a subscription'), 'first-run card shown without subscription');
const firstUrl = collect(page).find(n => n.attrs.id === 'mw-sub-url');
h.assertEq(firstUrl.attrs.type, 'text', 'theme-native first-run text input');
h.assertEq(firstUrl.attrs.inputmode, 'url', 'first-run URL keyboard');

page = overview.render([ Object.assign({}, base, { core_installed: false }), {}, [] ]);
h.assert(texts(page).includes('Xray core is not installed'), 'core card shown when core is missing');
h.assert(texts(page).includes('XrayWRT needs the Xray core. Download it once from GitHub: about 17 MB on the router with the default core.'), 'core card states download and unpacked size');

const evil = '<img src=x onerror=alert(1)>';
page = overview.render([ Object.assign({}, base, { subscription_configured: true, running: true }),
	{ profile_title: evil, announce: evil, effective_interval: 24 } ]);
h.assert(!texts(page).includes('Connect a subscription'), 'first-run card hidden with subscription');
h.assert(texts(page).filter((t) => t === evil).length >= 2, 'provider text rendered as text nodes');
console.log('ok - overview render');

h.assert(!collect(overview.render([ Object.assign({}, base, { subscription_configured: true, running: true }), {} ])).some((n) => n.tag === 'select'), 'no server selection');
console.log('ok - overview without server selection');
{
	const pinned = overview.render([ Object.assign({}, base, { subscription_configured: true, running: true, profile: { name: 'b', selected: 'a', pinned: true } }), {}, [ 'a', 'b' ] ]);
	h.assert(!collect(pinned).some((n) => n.tag === 'select'), 'pinned profile: no server select');
	h.assert(texts(pinned).includes('Server: a (from subscription)'), 'pinned profile: plain server line');
	console.log('ok - overview pinned server line');
}

const diag = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', {
	E, api, view: { extend: (v) => v }, location: {}
}).module;
page = diag.render([Object.assign({}, base, { running: true, dns_ok: false, policy_active: true, config_valid: true,
	custom_dns_servers: [ '9.9.9.9' ], lists: { dst: 1, src: 0, direct: 0 }, route: {}, errors: [] }), {}]);
const all = texts(page);
h.assert(all.includes('Xray does not answer DNS queries'), 'DNS check listed');
h.assert(all.some((t) => t.includes('9.9.9.9')), 'custom dnsmasq server warning');
h.assert(all.includes('Problem:'), 'failures are announced in text, not only by symbol');
console.log('ok - diagnostics checklist');

// DOM helper shared by Traffic controls.
function EL(tag, attrs, children) {
	const n = E(tag, attrs, children);
	n.listeners = {};
	n.addEventListener = (type, fn) => { n.listeners[type] = fn; };
	n.appendChild = (c) => { n.children.push(c); };
	return n;
}
// Saving: a rejected list keeps the form (no map.save) and shows the error.
seq(async () => {
	const calls = [];
	const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/traffic.js', {
		E: EL, view: { extend: (v) => v }, form: {}, widgets: {}, rpc: { declare: () => () => Promise.resolve({}) }, Event,
		api: Object.assign({}, api, {
			upload: async (prefix, c) => { calls.push('upload'); return '/tmp/x'; },
			job: async () => { calls.push('apply'); throw new Error('Line 1 of My rules (abc) has no target. [E:rules_no_target|1|abc|direct, core, proxy]'); },
			errorText: e => { calls.push('map-error'); return api.errorText(e); },
			notify: (msg, level) => calls.push('notify:' + level + ':' + msg)
		})
	}).module;
	tv.lists = { rules: '', src: '', direct_src: '' };
	tv.titles = { rules: 'My rules' };
	tv.map = { parse: async () => { tv.edited.rules = 'abc'; calls.push('parse'); }, save: async () => calls.push('save') };
	await tv.handleSaveApply();
	h.assertEq(tv.saving, false, 'invalid list is handled without rejecting the footer action');
	h.assertEq(tv.edited.rules, 'abc', 'invalid list edit retained');
	h.assertEq(tv.lists.rules, '', 'installed list unchanged');
	h.assertEq(calls.join(','), 'parse,upload,apply,map-error,notify:error:Line 1 of My rules (abc) has no target. Add a space and one of: direct, core, proxy.', 'lists applied before map.save; error shown');
	console.log('ok - traffic save order');
});

// A2.1: no Mihomo web panel on Home, and no panel RPC.
seq(async () => {
 const calls = [];
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, view: { extend: v => v }, poll: { add() {} }, window: { open: () => { throw new Error('Overview must not open windows'); } },
  api: { ...api, readOnly: () => false, busy: (b, fn) => fn(), read: async () => ({}), readLarge: async () => [],
   write: async cmd => { calls.push(cmd); return {}; }, job: async op => { calls.push(op); return {}; } }
 }).module;
 await ov.load();
 const p = ov.render([{ ...base, running: true, subscription_configured: true }, {}, []]);
 h.assert(!collect(p).some(n => /dashboard/i.test(String(texts(n)))), 'Overview has no dashboard text');
 h.assertEq(calls.length, 0, 'Overview load and render make no panel RPC');
 console.log('ok - Overview has no dashboard');
});


// A14.3/A14.6: Settings (spec 13 groups, provider values) and Lists forms.
seq(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, dependencies: [], keylist: [], vallist: [] }); }
  depends(k, v) { this.dependencies.push([k, v]); }
  value(k, label) { this.keylist.push(k); this.vallist.push(label); }
  get values() { return this.keylist.map((k, i) => [k, this.vallist[i]]); }
  remove() {}
  write(sid, value) { uci.set('xraywrt', sid, this.name, value); }
  load(sid) { return uci.get('xraywrt', sid, this.name); }
  cfgvalue() { return this.loaded; }
  isActive() { return this.active !== false; }
  setActive(sid, active) { this.active = active; }
  triggerValidation(sid) {
   const value = this.formvalue?.(sid) || '';
   // LuCI first checks optional, then custom validation; inactive fields are not revalidated by checkDepends.
   this.error = !value && this.rmempty === false && !this.optional ? 'non-empty value' : this.validate?.(sid, value);
   return this.error === true || this.error == null;
  }
  renderWidget() { const n = E('input'); n.style = {}; n.querySelector = () => n; return n; }
 }
 class Flag extends Option {}
 class Map {
  constructor(config, title, description) { Object.assign(this, { options: {}, title, description }); }
  render() {
   uciReady = true; // Map.load loads UCI before options, not before view.render builds them.
   for (const option of Object.values(this.options)) option.loaded = option.load('settings');
   return Promise.resolve(E('form'));
  }
 }
 // Section children are used to move provider fields next to their flags.
 Map.prototype.section = function() {
  const section = { children: [], tabs: [], tab(name, title) { this.tabs.push([name, title]); } };
  section.taboption = (tab, Type, name, title, description) => {
   const o = new Type(name, title, description); o.tab = tab;
   this.options[name] = o; section.children.push(o); return o;
  };
  section.option = (Type, name, title, description) => section.taboption(null, Type, name, title, description);
  return section;
 };
 const form = { Map, Flag, Value: Option, DummyValue: Option, ListValue: Option, TextValue: Option, DynamicList: Option, NamedSection: Option };
 let overrides = ['bypass_ntp']; const ownSettings = {}; let uciReady = true;
 const uci = { get: (pkg, sid, key) => !uciReady ? undefined : key === 'provider_override' ? overrides : ownSettings[key], set: (pkg, section, key, value) => { if (key === 'provider_override') overrides = value; else ownSettings[key] = value; }, unset: () => { overrides = []; } };
 const initCalls = []; let initFail = false;
 // providerScalar lives in api.js and reads uci itself.
 const apiU = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, uci }).module;
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/advanced.js', {
  E, api: { ...apiU, jobNotice: () => E('div'), service: async (a) => { if (initFail) throw new Error('init'); initCalls.push(a); } }, view: { extend: v => v }, form, uci, widgets: { DeviceSelect: Option }, rpc: { declare: (d) => async (...a) => { initCalls.push([d.method, ...a]); return {}; } }
 }).module;
 const renderSettings = async (profile, status = {}, sub = { url: 'https://p.example/sub' }, init = { xraywrt: { enabled: false } }) => {
  await sv.render([profile, status, sub, init]);
  return sv.map.options;
 };
 const compactReads = [], compactProfile = { mode: 'direct-first', provider: {}, netbird: true, subscription: { configured: true, config_backup: true, auto_update: false } };
 const compactView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/advanced.js', {
  E, api: { ...apiU, jobNotice: () => E('div'), read: async (...args) => { compactReads.push(args); return compactProfile; } },
  view: { extend: v => v }, form, uci, widgets: { DeviceSelect: Option },
  rpc: { declare: () => async () => ({ xraywrt: { enabled: true } }) }
 }).module;
 const compactPage = await compactView.render(await compactView.load());
 h.assertEq(JSON.stringify(compactReads), '[["profile-json","--compact"]]', 'Advanced loads only compact profile');
 h.assert(compactView.map.options.netbird_proxy && compactView.map.options.bypass_subscription_dns, 'compact flags retain Advanced options');
 h.assert(texts(compactPage).includes('Subscription updates, including automatic ones, replace your edits.'), 'configured flag retains editor warning');
 const partialPage = await compactView.render([{ netbird: true, subscription: compactProfile.subscription }, { netbird: true }, compactProfile.subscription, {}]);
 h.assert(compactView.map.options.netbird_proxy && compactView.map.options.bypass_subscription_dns, 'partial compact result keeps independent options');
 h.assert(texts(partialPage).includes('Subscription updates, including automatic ones, replace your edits.'), 'partial compact result keeps editor warning');
 let opts = await renderSettings({ mode: 'direct-first', provider: { disable_quic: '0', mode: 'direct-first' } }, { netbird: true });
 // Spec 13 groups; every UCI option of the table that the UI edits sits in its group.
 const groups = { routing: ['source_network_interfaces', 'block_client_ipv6', 'discord_voice', 'disable_quic', 'bypass_ntp', 'netbird_proxy'],
  dns: ['dns_hijack', 'dns_forward_other_types', 'block_https_svcb'],
  core: ['core_log_level', 'bypass_subscription_dns', '_boot'] };
 h.assert(!(await renderSettings({ mode: 'direct-first' }, {}, {})).bypass_subscription_dns, 'no direct subscription download option without a saved link');
 h.assert(!opts.subscription_auto_update && !opts._subscription_url, 'no duplicate subscription settings');
 h.assert(!opts.core_auto_update, 'no core auto-update field (spec 4.4)');
 for (const [tab, names] of Object.entries(groups))
  for (const name of names) h.assertEq(opts[name]?.tab, tab, name + ' in ' + tab);
 h.assertEq(sv.map.title, 'Advanced', 'settings title');
 h.assertEq(opts._boot.title, 'Start on boot', 'boot start checkbox on the Service tab');
 h.assertEq(opts._boot.cfgvalue(), '0', 'boot state from getInitList');
 await opts._boot.write('settings', '0'); h.assertEq(initCalls.length, 0, 'an unchanged boot flag does nothing');
 await opts._boot.write('settings', '1'); await opts._boot.write('settings', '1');
 h.assertEq(opts._boot.cfgvalue(), '1', 'boot flag follows the applied change');
 await opts._boot.write('settings', '0');
 h.assertEq(JSON.stringify(initCalls), '["enable","disable"]', 'boot start changes once per real change, through the init script');
 initFail = true; let bootErr = null;
 try { await opts._boot.write('settings', '1'); } catch (e) { bootErr = e; }
 initFail = false;
 h.assert(bootErr && opts._boot.cfgvalue() === '0', 'a failed init call rejects the save and keeps the shown state');
 h.assert(!(await renderSettings({ mode: 'direct-first' }, {}, {}, {}))._boot, 'no boot flag when its state is unknown');
 const acl = JSON.parse(h.readSource('rootfs/usr/share/rpcd/acl.d/luci-app-xraywrt.json'))['luci-app-xraywrt'];
 h.assertEq(JSON.stringify([acl.read.ubus.luci, acl.write.ubus.luci]), '[["getInitList"],null]', 'ACL grants no init action beyond the own init script');
 h.assert(!opts.mihomo_log_level && !opts.dashboard, 'no Mihomo-only options');
 h.assertEq(sv.map.options && Object.keys(opts).filter(k => opts[k].tab === 'dns').join(' '), groups.dns.join(' '), 'DNS tab order');
 h.assert(!opts.dns_upstream, 'no DNS servers for Xray option: provider dns.servers or the WAN DNS');
 h.assert(opts.dns_hijack.description.includes('DoH/DoT'), 'DNS caveat is explicit');
 h.assert(opts.netbird_proxy.description.includes('through Xray in either traffic mode'), 'NetBird warns about both traffic modes');
 h.assertEq(opts.block_https_svcb.default, '0', 'HTTPS/SVCB blocking defaults off');
 h.assert(opts.block_https_svcb.description.includes('empty HTTPS/SVCB answers'), 'whole-record warning');
 h.assertEq(opts.block_https_svcb.values.length, 0, 'HTTPS/SVCB without subscription flag is a checkbox');
 h.assertEq(opts.discord_voice.values.length, 0, 'Discord Voice without subscription flag is a checkbox');
 h.assert(!opts.dns_refuse_other_types, 'no refuse option (spec 7.5)');
 h.assert(!opts.fake_domains_source, 'fake-IP source belongs on Lists');
 h.assertEq(opts.core_log_level.default, 'warning', 'core log level default');
 h.assertEq(opts.core_log_level.values.map(v => v[0]).join(' '), 'none error warning info debug', 'core log levels');
 h.assertEq(opts.core_log_level.values.map(v => v[1]).join(','), 'Off,Errors,Warnings,Information,Debug', 'core log level labels are translatable words');
 h.assert(!opts.core_channel, 'Core-only settings have no source selector');
 // The NetBird flag shows only on a router with NetBird, or when it is already on.
 opts = await renderSettings({ mode: 'direct-first' });
 h.assert(!opts.netbird_proxy, 'NetBird flag hidden without NetBird');
 ownSettings.netbird_proxy = '1';
 opts = await renderSettings({ mode: 'direct-first' });
 h.assert(opts.netbird_proxy, 'NetBird flag kept when already set');
 delete ownSettings.netbird_proxy;
 opts = await renderSettings({ mode: 'direct-first', provider: { disable_quic: '0', mode: 'direct-first' } });


 opts = await renderSettings({ mode: 'direct-first', provider: { discord_voice: '1' } });
 h.assertEq(opts.discord_voice.values[0][1], 'From subscription: Enabled', 'Discord subscription choice comes first');
 h.assertEq(opts.discord_voice.cfgvalue(), 'provider', 'Discord Voice follows provider');
 opts.discord_voice.write('settings', '0');
 h.assert(overrides.includes('discord_voice'), 'Discord Voice explicit off overrides provider');
 opts.discord_voice.write('settings', 'provider');
 h.assert(!overrides.includes('discord_voice'), 'Discord Voice can return to provider');
 opts = await renderSettings({ mode: 'proxy-first', provider: { discord_voice: '1' } });
 h.assertEq(opts.discord_voice.cfgvalue(), 'provider', 'proxy-first preserves provider preference');
 opts = await renderSettings({ mode: 'direct-first', provider: { block_https_svcb: '1' } });
 h.assertEq(opts.block_https_svcb.values[0][1], 'From subscription: Enabled', 'HTTPS/SVCB subscription choice comes first');
 h.assertEq(opts.block_https_svcb.cfgvalue(), 'provider', 'HTTPS/SVCB follows provider');
 opts.block_https_svcb.write('settings', '0');
 h.assertEq(ownSettings.block_https_svcb, '0', 'HTTPS/SVCB explicit off is saved');
 h.assert(overrides.includes('block_https_svcb'), 'HTTPS/SVCB explicit off overrides provider');
 opts.block_https_svcb.write('settings', 'provider');
 h.assert(!overrides.includes('block_https_svcb'), 'HTTPS/SVCB can return to provider');

 opts = await renderSettings({ mode: 'proxy-first', provider: {} });
 h.assertEq(opts.dns_forward_other_types.default, '1', 'forwarding defaults on');
 opts.dns_forward_other_types.write('settings', '0');
 h.assertEq(ownSettings.dns_forward_other_types, '0', 'forwarding off is saved');
 h.assert(!overrides.includes('dns_forward_other_types'), 'ordinary save does not claim a provider override');
 overrides = [];
 opts = await renderSettings({ mode: 'direct-first', provider: { dns_forward_other_types: '0' } });
 h.assertEq(opts.dns_forward_other_types.cfgvalue(), 'provider', 'forwarding follows provider');
 opts.dns_forward_other_types.write('settings', '1');
 h.assert(overrides.includes('dns_forward_other_types'), 'forwarding user override saved');
 opts.dns_forward_other_types.write('settings', 'provider');
 h.assert(!overrides.includes('dns_forward_other_types'), 'forwarding can return to provider');
 for (const k of Object.keys(ownSettings)) delete ownSettings[k];
 overrides = ['bypass_ntp'];
 opts = await renderSettings({ mode: 'direct-first', provider: { disable_quic: '0', mode: 'direct-first' } });
 // Provider values and own choices share one labelled dropdown.
 h.assertEq(opts.disable_quic.cfgvalue('settings'), 'provider', 'provider selected without override');
 h.assertEq(JSON.stringify(opts.disable_quic.values), JSON.stringify([['provider', 'From subscription: Disabled'], ['1', 'Enabled'], ['0', 'Disabled']]), 'provider and own flag choices');
 h.assertEq(opts.disable_quic.title, 'Block QUIC for VPN traffic', 'normal accessible option title');
 h.assert(!Object.keys(opts).some(k => /^_(own|prov|provoff)_/.test(k)), 'no extra provider rows');
 opts.disable_quic.write('settings', '1');
 h.assertEq(overrides.join(','), 'bypass_ntp,disable_quic', 'own choice preserves other entries');
 opts.disable_quic.write('settings', 'provider');
 h.assertEq(overrides.join(','), 'bypass_ntp', 'provider choice removes only its entry');
 const proxyFirstOpts = await renderSettings({ mode: 'proxy-first', provider: {} });
 h.assertEq(proxyFirstOpts.block_client_ipv6.description, 'No effect in the current mode.', 'client IPv6 flag note in proxy-first');
 h.assertEq(proxyFirstOpts.block_client_ipv6.readonly, true, 'client IPv6 readonly in proxy-first');
 h.assert(!Object.keys(proxyFirstOpts).some(k => k.startsWith('_own_')), 'no override controls without provider keys');
 console.log('ok - settings groups, defaults and provider values');

 const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/traffic.js', {
  E, api: apiU, view: { extend: v => v }, form, uci, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 const renderLists = async p => {
  await tv.render([{ rules: 'example.com direct\n', src: 'src', direct_src: 'devices' }, p, {}]);
  for (const name of ['_rules', '_src', '_direct_src']) {
   if (tv.map.options[name]) h.assertEq(tv.map.options[name].monospace, true, name + ' native TextValue monospace');
  }
  return tv.map.options;
 };
 const directFirstProfile = { mode: 'direct-first', provider: { disable_quic: '0' }, provider_lists: true, targets: ['proxy', 'pool'] };
 opts = await renderLists(directFirstProfile);
 h.assertEq(opts.mode.cfgvalue(), 'provider', 'mode follows the configuration unless overridden');
 h.assertEq(JSON.stringify(opts.mode.values), '[["provider","From subscription: Only selected sites via VPN"],["proxy-first","Everything via VPN except exclusions"],["direct-first","Only selected sites via VPN"]]', 'mode choices');
 h.assertEq(opts.mode.description, 'Only the addresses and devices below, plus the sites your subscription selects, go via VPN; everything else goes direct.', 'direct-first meaning is the description');
 h.assertEq(opts.mode.title, 'Traffic mode', 'mode title has its own msgid');
 h.assert(!opts._mode && !texts(api.style()).join('').includes('mw-mode'), 'no custom mode control');
 h.assert(!opts.disable_quic && opts.lists_interval && !opts.mihomo_log_level, 'provider scalars stay in Advanced; list interval stays on Traffic');
 h.assert(!opts.dst_list_source && !opts.direct_list_source && !opts.fake_domains_source && !opts._dst && !opts._direct && !opts._fake && !opts._direct_domains, 'no source selects and no separate site or address lists');
 // One ordered list, with its format and targets under it.
 h.assertEq(opts._rules.title, 'My rules', 'one list for sites and addresses');
 h.assertEq(opts._rules.cfgvalue(), 'example.com direct\n', 'My rules loaded from lists-json');
 const previewOpts = await renderLists({ mode: 'direct-first', provider: {}, provider_sources: {
  vpn: { addresses: ['192.0.2.1'], links: 2, truncated: true }, direct: { addresses: ['2001:db8::/32'], links: 1, truncated: false } } });
 const previewWidget = previewOpts._rules.renderWidget();
 const previewButton = findButton(previewWidget, 'Subscription lists');
 h.assert(previewButton, 'subscription lists beside personal rules');
 const preview = toggleOf(previewWidget, previewButton).children[1];
 h.assert(preview.hidden, 'subscription lists collapsed');
 const previewText = texts(preview);
 for (const value of ['VPN addresses (Only selected sites via VPN mode)', 'Direct addresses (Everything via VPN except exclusions mode)', '192.0.2.1', '2001:db8::/32', 'Preview truncated.', 'Remote links: 2', 'Remote links: 1']) h.assert(previewText.includes(value), 'provider preview includes ' + value);
 h.assert(!previewText.includes('example.com direct'), 'personal rules excluded from provider preview');
 const rulesWidget = opts._rules.renderWidget();
 h.assert(texts(rulesWidget).includes('direct') && texts(rulesWidget).includes('core'), 'the hint names direct and core');
 h.assert(texts(rulesWidget).includes('proxy, pool') && !findButton(rulesWidget, 'Show the targets'), 'a few targets are listed at once');
 const rulesHelp = toggleOf(rulesWidget, findButton(rulesWidget, 'Entry format')).children[1];
 for (const example of ['google.com direct', 'geosite:youtube core', 'full:www.example.com my-server', '1.2.3.0/24 direct', 'https://example.com/list.txt direct'])
  h.assert(texts(rulesHelp).includes(example), 'format example ' + example);
 h.assert(!texts(rulesHelp).some(t => t.includes('Port syntax')), 'no port syntax for My rules');
 // Many targets hide behind a button; reserved tags are explained once.
 const manyTargets = await renderLists({ mode: 'direct-first', provider: {}, targets: ['a', 'b', 'c', 'd', 'e', 'f', 'g'], reserved: ['direct', 'core'] });
 const manyWidget = manyTargets._rules.renderWidget();
 const targetsButton = findButton(manyWidget, 'Show the targets');
 h.assert(targetsButton && toggleOf(manyWidget, targetsButton).children[1].hidden === true && texts(manyWidget).includes('a, b, c, d, e, f, g'), 'many targets sit behind a toggle');
 h.assertEq(texts(manyWidget).filter(t => t.startsWith('The tags direct, core of the configuration cannot be used here')).length, 1, 'the reserved tags note appears once');
 h.assert(!texts(rulesWidget).some(t => t.startsWith('The tags')), 'no reserved note without such tags');
 // The device list of each mode follows the mode select, also before saving.
 h.assertEq(JSON.stringify(opts._src.dependencies), '[["mode","direct-first"],["mode","provider"]]', 'devices via VPN: direct-first, or the configuration when it is direct-first');
 h.assertEq(JSON.stringify(opts._direct_src.dependencies), '[]', 'devices always direct in both modes');
 const providerProxy = await renderLists({ mode: 'proxy-first', provider: { mode: 'proxy-first' } });
 h.assertEq(JSON.stringify(providerProxy._direct_src.dependencies), '[]', 'devices always direct with provider mode');
 h.assertEq(JSON.stringify(providerProxy._src.dependencies), '[["mode","direct-first"]]', 'devices via VPN do not follow a proxy-first configuration');
 const proxyFirstLists = await renderLists({ mode: 'proxy-first', provider: {}, lists: {} });
 h.assertEq(proxyFirstLists.mode.description, 'Everything goes via VPN except the addresses and devices below.', 'proxy-first meaning is the description');
 h.assertEq(proxyFirstLists.mode.vallist[0], 'From subscription: Everything via VPN except exclusions', 'configuration mode in the first choice');
 // Overridden: the configuration's own mode is shown only when the provider sets it.
 overrides = ['mode']; ownSettings.mode = 'direct-first';
 const overriddenAuto = await renderLists({ mode: 'direct-first', mode_source: 'user', provider: {}, lists: {} });
 h.assertEq(overriddenAuto.mode.vallist[0], 'From subscription', 'unknown configuration mode: no value');
 h.assertEq(overriddenAuto.mode.cfgvalue(), 'direct-first', 'own mode selected');
 h.assertEq((await renderLists({ mode: 'direct-first', mode_source: 'user', provider: { mode: 'proxy-first' }, lists: {} })).mode.vallist[0], 'From subscription: Everything via VPN except exclusions', 'provider mode shown while overridden');
 overrides = ['bypass_ntp']; delete ownSettings.mode;
 const interval = await renderLists({ mode: 'proxy-first', provider: { lists_interval: '24' }, lists: {} });
 h.assertEq(interval.lists_interval.vallist[0], 'From subscription: 24 h', 'list interval follows the provider like on Advanced');
 h.assert(!interval.lists_interval.readonly, 'list interval is an ordinary dropdown');
 const listWidget = proxyFirstLists._rules.renderWidget();
 const entryButton = findButton(listWidget, 'Entry format');
 h.assert(entryButton, 'My rules has an Entry format toggle');
 const entryHelp = toggleOf(listWidget, entryButton).children[1];
 h.assertEq(entryHelp.hidden, true, 'entry syntax starts hidden');
 h.assertEq(entryButton.attrs['aria-controls'], entryHelp.attrs.id, 'toggle controls syntax help');
 entryButton.click();
 h.assertEq(entryHelp.hidden, false, 'Entry format opens syntax');
 h.assertEq(entryButton.attrs['aria-expanded'], 'true', 'open state accessible');
 h.assert(texts(listWidget).some(t => t.startsWith('Site recognition is not enabled') && t.includes('unqualified direct site rules')), 'proxy-first without sniffing: only unqualified direct site rules are skipped');
 h.assert(texts(api.style()).join('').includes('.mw-toggle > [hidden], .mw-page [hidden], .mw-row[hidden] { display: none; }'), 'toggle and row hiding works outside mw-page');
 h.assert(!/go via VPN/.test((await renderLists({ provider: {}, lists: {} }))._mode.cfgvalue()), 'unknown mode: no guessed meaning');
 {
  const unknown = await renderLists({});
  h.assertEq(unknown._mode.cfgvalue(), 'unknown (could not read the configuration)', 'unknown mode not guessed');
  h.assert(!Object.keys(unknown).some(k => k.endsWith('_inactive')), 'no inactive rows without a mode');
 }
 const uploads = [], writes = [];
 const saved = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/traffic.js', {
  E, api: Object.assign({}, apiU, { upload: async (prefix, content) => { uploads.push(content); return content; }, job: async (...args) => writes.push(args), notify() {} }),
  uci: { changes: async () => ({}) }, ui, view: { extend: v => v }, form, rpc: { declare: () => () => Promise.resolve({}) }
 }).module;
 saved.lists = { rules: 'rules', src: 'src', direct_src: 'direct_src' };
 saved.map = { parse: async () => { saved.edited.rules = 'example.com direct'; saved.edited.direct_src = 'edited'; }, save: async () => {} };
 await saved.handleSaveApply();
 h.assertEq(uploads.join(','), 'example.com direct,edited', 'only edited lists uploaded');
 h.assertEq(writes[0].join(','), 'apply-lists,example.com direct,-,edited', 'My rules are the first apply-lists path');
 console.log('ok - lists form, My rules and save');

 // DOM properties used by subscription events mirror actual browser inputs.
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children);
  n.value = n.attrs.value || (tag === 'textarea' ? (n.children || []).join('') : '');
  n.checked = n.attrs.checked != null;
  return n;
 }
 const subCalls = [], notices = [];
 const subview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  api: Object.assign({}, api, readStubs, { busy: async (el, fn) => fn(), write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, job: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: s => notices.push(s), reloadWithNotice: s => notices.push(s) })
 }).module;
 for (const [on, period, hint] of [
  [true, 12, 'Update interval from the subscription: every 12 h.'],
  [true, 0, 'Update interval from the subscription: every 12 h.'],
  [false, 12, 'Only when you press Update now.']
 ]) {
  const p = await mountSubscription(subview, { url: 'https://p.example/sub', auto_update: on, effective_interval: period, header_interval: period || 12 });
  const nodes = collect(p), checkbox = nodes.find(n => n.attrs.id === 'mw-auto');
  h.assertEq(checkbox.attrs.type, 'checkbox', 'auto-update checkbox');
  h.assertEq(checkbox.checked, on, 'auto-update checkbox state');
  h.assert(nodes.some(n => n.textContent === hint), 'auto-update explanation ' + hint);
  h.assert(!nodes.some(n => n.attrs.type === 'number'), 'no numeric interval input');
  await nodes.find(n => n.tag === 'button' && texts(n).includes('Save')).listeners.click();
  h.assertEq(subCalls.at(-1).join(','), 'set-subscription,https://p.example/sub,' + (on ? '1' : '0'), 'Save sends boolean');
  await nodes.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(notices.at(-1), 'Subscription is up to date.', 'unchanged update notice');
  h.assert(texts(p).includes('Subscription link. Leave empty to use your own configuration.'), 'subscription URL hint without format jargon');
  h.assert(texts(p).includes('Subscription updates, including automatic ones, replace your edits.'), 'Advanced update warning');
  h.assert(texts(p).includes('Use Xray JSON with outbounds. For several profiles, use an array and choose by remarks on Home. XrayWRT adds router rules. Put router settings under xraywrt.'), 'config format note');
 }
 // Exercise the widget contract and handlers using the actual returned textarea.
 const yamlUploads = [];
 const yamlView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  api: { ...api, ...readStubs, busy: async (el, fn) => fn(), upload: async (...args) => { yamlUploads.push(args); return '/tmp/yaml'; },
   write: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, job: async (...args) => { subCalls.push(args); return { action: 'unchanged' }; }, notify: message => notices.push(message), reloadWithNotice: message => notices.push(message) }
 }).module;
 const yamlPage = await mountSubscription(yamlView, { url: 'https://p.example/sub' });
 await openToggle(yamlPage, 'Show config editor');
 const yamlNodes = collect(yamlPage);
 const yaml = yamlNodes.find(n => n.tag === 'textarea');
 h.assertEq(textareaOptions.at(-1)?.monospace, true, 'YAML ui.Textarea monospace');
 h.assertEq(textareaOptions.at(-1)?.wrap, false, 'YAML ui.Textarea no wrap');
 h.assert(yamlNodes.some(n => n.attrs.id === 'mw-config' && n.children.includes(yaml)), 'YAML widget id');
 h.assertEq(yaml.attrs.id, 'widget.mw-config', 'LuCI textarea id');
 h.assert(yaml.attrs.class.split(' ').includes('mw-code'), 'YAML editor class');
 h.assertEq(yaml.value, 'proxies: []\n', 'YAML content initialized');
 yaml.value = 'proxies: []\n# edited';
 await yamlNodes.find(n => n.tag === 'button' && texts(n).includes('Save config')).listeners.click();
 h.assertEq(yamlUploads.at(-1).join(','), 'xraywrt-config,' + yaml.value, 'apply uploads live YAML textarea value');
 h.assertEq(subCalls.at(-1).join(','), 'save-config,/tmp/yaml', 'apply saves uploaded YAML');
 h.assertEq(notices.at(-1), 'Configuration is unchanged.', 'unchanged apply notice');
 for (const [action, msg] of [['unchanged', 'Subscription is up to date.'], ['restarted', 'Subscription updated; XrayWRT restarted.'], ['hot_reloaded', 'Subscription updated without restarting Xray.'], ['saved', 'Subscription updated.']]) {
  notices.length = 0;
  const view = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} }, confirm: () => true,
   api: { ...api, ...readStubs, busy: async (el, fn) => fn(), job: async () => ({ action }), write: async () => ({}), reloadWithNotice: m => notices.push(m) }
  }).module;
  const ns = collect(await mountSubscription(view, { url: 'https://p.example/sub' }));
  await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(JSON.stringify(notices), JSON.stringify([msg]), 'update notice ' + action);
 }
 console.log('ok - YAML native monospace widget, live upload and unsaved edits');
 console.log('ok - subscription checkbox, hints, save and unchanged notice');

 const p = overview.render([Object.assign({}, base, { subscription_configured: true }), { announce: 'Pay: https://p.example/pay now\nhttp://x.example' }, []]);
 const links = collect(p).filter(n => n.tag === 'a' && ['https://p.example/pay','http://x.example'].includes(n.attrs.href));
 h.assertEq(links.length, 2, 'announce HTTP links');
 h.assert(links.every(n => n.attrs.rel === 'noopener noreferrer' && n.attrs.target === '_blank'), 'announce safe link attributes');
 h.assert(texts(p).some(t => t.includes(' now\n')), 'announce newline preserved');
 const unsafe = overview.render([Object.assign({}, base, { subscription_configured: true }), { announce: 'javascript:alert(1) <b>x</b>' }, []]);
 h.assert(texts(unsafe).includes('javascript:alert(1) <b>x</b>'), 'unsafe announce plain text');
 h.assert(!collect(unsafe).some(n => n.tag === 'a' && String(n.attrs.href).startsWith('javascript:')), 'no unsafe links');
 console.log('ok - safe announce links');
 for (const valid of [null, false]) {
  const p = diag.render([Object.assign({}, base, { config_valid: valid, config_error: 'bad yaml', dns_mode: 'redir-host' }), { provider: { disable_quic: '0' }, provider_lists: true }]);
  const t = texts(p);
  if (valid == null) h.assert(t.includes('Config will be checked at startup') && t.includes('–'), 'unknown check neutral');
  else h.assert(t.some(s => s.includes('bad yaml')), 'last core error shown');
  for (const label of ['Traffic mode','DNS mode','Provider settings','Provider lists']) h.assert(t.includes(label), 'diagnostic detail ' + label);
  { const cells = texts(collect(p).find(n => n.attrs.class === 'mw-grid' && texts(n).includes('Provider lists'))); h.assertEq(cells[cells.indexOf('Provider lists') + 1], 'yes', 'provider lists row reads profile.provider_lists'); }
 }
 console.log('ok - diagnostics unknown/error and profile details');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Design-review regression cases use the rendered DOM and real event handlers.
seq(async () => {
 h.assertEq(api.safeLink('https://example.org', 'Support').attrs.class, undefined, 'safeLink leaves styling to the theme');
 const messages = {
  http_404: 'not found (HTTP 404)', http_401: 'refused access (HTTP 401)', http_403: 'refused access (HTTP 403)',
  http_500: 'error (HTTP 500)', network: 'cannot reach', too_large: 'too large', invalid_url: 'starts with https://'
 };
 for (const [code, expected] of Object.entries(messages))
  h.assert(api.errorText({ name: 'JobError', message: 'Subscription download failed: ' + code + ' [E:' + ({http_404: 'subscription_not_found', http_401: 'subscription_access|401', http_403: 'subscription_access|403', http_500: 'subscription_http|500', too_large: 'subscription_large', invalid_url: 'subscription_url', network: 'subscription_network|network'})[code] + ']'  }).includes(expected), 'subscription error ' + code);
 h.assertEq(api.errorText('unrelated'), 'unrelated', 'unrelated errors preserved');
 const content = E('pre'); let opens = 0;
 const toggle = api.toggle('Show', 'Hide', content, () => opens++), button = collect(toggle).find(n => n.tag === 'button');
 h.assert(content.hidden && button.attrs['aria-expanded'] === 'false', 'toggle initially hidden');
 button.listeners.click(); h.assert(!content.hidden && button.attrs['aria-expanded'] === 'true' && opens === 1, 'toggle opens and loads');
 button.listeners.click(); h.assert(content.hidden && opens === 1, 'toggle closes without loading');
 button.listeners.click(); h.assertEq(opens, 2, 'toggle reloads on reopen');
 const dates = [];
 class LocaleDate extends Date { toLocaleString(...args) { dates.push(args); return 'date'; } }
 const dateApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, Date: LocaleDate, document: { documentElement: { lang: 'ru' } } }).module;
 dateApi.formatDate(1700000000);
 h.assertEq(JSON.stringify(dates[0]), '["ru",{"dateStyle":"medium","timeStyle":"short"}]', 'date uses document language');
 const active = { ...base, subscription_configured: true, running: true };
 const missing = overview.render([{ ...base, core_installed: false }, {}, []]);
 h.assertEq(collect(missing).filter(n => n.tag === 'button').length, 1, 'missing core only install button');
 const manual = overview.render([{ ...active, subscription_configured: false }, {}, []]);
 h.assert(texts(manual).includes('No subscription: XrayWRT uses the configuration entered on the Advanced page.') && !collect(manual).some(n => n.attrs.id === 'mw-sub-url'), 'manual YAML one-line hint');
 h.assert(texts(overview.render([{ ...base, config_valid: false }, {}, []])).includes('Stopped: Xray did not accept the configuration.'), 'invalid config headline');
 for (const [sub, expected] of [
  [{ expire: 1 }, 'Subscription expired. Renew it with the service.'],
  [{ expire: Date.now()/1000 + 86400 }, 'Subscription expires on'],
  [{ total: 100, download: 90 }, 'Over 90% of the subscription traffic is used.'],
  [{ total: 100, upload: 100 }, 'The subscription traffic is used up.']
 ]) h.assert(texts(overview.render([active, sub, []])).some(t => t.includes(expected)), 'subscription warning ' + expected);
 h.assert(!collect(diag.render([base, {}])).some(n => n.tag === 'ul' || n.tag === 'li'), 'checklist without bullets');
 const translated = [];
 const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', { E, api, view: { extend: v => v }, _: s => { translated.push(s); return s; } }).module;
 const dp = dv.render([{ ...base, config_valid: false, config_error: 'Xray 26.1.1 (Xray, Penetrates Everything.) Custom\nFailed to start: bad proxy in /tmp/xraywrt/config-check.1.json', route: { table: 100, priority: 10 } }, { provider: { dns_hijack: '1', disable_quic: '0' } }]);
 h.assert(texts(dp).includes('Config has errors'), 'negative config wording');
 h.assert(texts(dp).some(t => t.includes('Xray says: Failed to start: bad proxy') && !t.includes('Penetrates') && !t.includes('/tmp/')), 'core error extraction');
 h.assert(texts(dp).includes('dns_hijack, disable_quic'), 'provider names');
 h.assert(translated.includes('%s (priority %s)'), 'priority translated');
 const subCalls = [], errors = []; let fail = false;
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', { ui, Blob, E: (tag, attrs, children) => {
  const n = E(tag, attrs, children); n.value = n.attrs.value || (tag === 'textarea' ? n.children.join('') : ''); n.checked = n.attrs.checked != null; return n;
 }, view: { extend: v => v }, location: { reload() {} }, api: { ...api, ...readStubs, busy: async (el, fn) => { try { return await fn(); } catch(e) { errors.push(e.message); } }, write: async (...args) => { subCalls.push(args); return {}; }, job: async (...args) => { subCalls.push(args); if (fail) throw Object.assign(Error('Subscription not found (HTTP 404). Check the link in your service account.'), { name: 'JobError' }); return {}; }, notify() {} } }).module;
 for (const changed of [false, true]) {
  const p = await mountSubscription(sv, { url: 'https://old.example', auto_update: true }, { content: 'yaml' });
  const ns = collect(p); ns.find(n => n.attrs.id === 'mw-url').value = changed ? 'https://new.example' : 'https://old.example';
  const auto = ns.find(n => n.attrs.id === 'mw-auto'); auto.checked = false; await auto.listeners.change();
  h.assertEq(subCalls.at(-1).join(','), 'set-subscription,https://old.example,0', 'checkbox immediately saves saved URL, not edited input');
  subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
  h.assertEq(subCalls.map(c => c[0]).join(','), changed ? 'update-subscription' : 'set-subscription,update-subscription', 'update order changed=' + changed);
  if (changed) {
   h.assertEq(subCalls[0][1], 'https://new.example', 'new link passed to updater');
   fail = true; subCalls.length = 0; await ns.find(n => n.tag === 'button' && texts(n).includes('Update now')).listeners.click();
   h.assertEq(subCalls.length, 1, 'failed new link never set'); h.assert(errors.at(-1).includes('The previous link is kept.'), 'previous link explanation');
   h.assertEq(errors.at(-1), 'Subscription not found (HTTP 404). Check the link in your service account. The previous link is kept.', 'job failure text from api.job, kept-link note added');
   h.assert(!/subscriptionError/.test(h.readSource('rootfs/www/luci-static/resources/xraywrt/configuration.js')), 'Subscription does not format job errors itself');
  }
 }
 let logReads = 0;
 const logs = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', { E, view: { extend: v => v }, api: { ...api, readLarge: async () => { logReads++; return { available: true, lines: ['hello'] }; } } }).module;
 const lp = logs.render([base, {}]); h.assertEq(logReads, 0, 'log lazy');
 const logButton = collect(lp).find(n => n.tag === 'button' && texts(n).includes('Show the log'));
 h.assert(!!logButton, 'theme log toggle button');
 logButton?.listeners.click();
 await Promise.resolve(); h.assertEq(logReads, 1, 'log loads on open');
 console.log('ok - design-review DOM and event regressions');
}).catch(err => { console.error(err); process.exitCode = 1; });

seq(async () => {
 const polls = [], notices = []; let fail = true;
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, view: { extend: v => v }, poll: { add: fn => polls.push(fn) }, api: { ...api,
   read: async () => { if (fail) throw Error('down'); return { state: 'stopped' }; }, notify: s => notices.push(s)
  }
 }).module;
 ov.render([base, {}, []]);
 await polls[0](); await polls[0](); h.assertEq(notices.length, 1, 'poll error notified once');
 fail = false; await polls[0](); fail = true; await polls[0]();
 h.assertEq(notices.length, 2, 'successful poll resets error notification');
 console.log('ok - overview poll notification recovery');
}).catch(err => { console.error(err); process.exitCode = 1; });

for (const [name, check] of [
 ['empty failure headline', () => h.assert(texts(overview.render([{ ...base, state: 'failed', last_error: '' }, {}, []])).includes('Stopped'), 'failed without detail is Stopped')],
 ['headline-only live region', () => { const p = overview.render([base, {}, []]); const headline = collect(p).find(n => n.tag === 'strong'); h.assertEq(headline.attrs['aria-live'], 'polite', 'headline itself is live'); }]
]) { try { check(); console.log('ok - overview ' + name); } catch (e) { console.error(e); process.exitCode = 1; } }
seq(async () => {
 const polls = [];
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', { E, view: { extend: v => v }, poll: { add: fn => polls.push(fn) }, api: { ...api, read: async () => ({ state: 'running', running: true }) } }).module;
 const p = ov.render([base, {}, []]); const buttons = collect(p).filter(n => n.tag === 'button');
 await polls[0](); h.assert(buttons.every(b => collect(p).includes(b)), 'status buttons stay mounted to preserve keyboard focus');
 console.log('ok - overview stable status controls');
}).catch(e => { console.error(e); process.exitCode = 1; });

// C5: a hidden tab does not poll; nothing on the page waits for the core,
// so starting -> running updates the status in place without a reload.
seq(async () => {
 const polls = [], reads = []; let reloads = 0, hidden = false, next = { state: 'running', running: true };
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, view: { extend: v => v }, poll: { add: fn => polls.push(fn) },
  document: { get hidden() { return hidden; } }, api: { ...api, balancers: async () => ({ balancers: [] }), read: async cmd => { reads.push(cmd); return next; },
   reloadWithNotice: () => { reloads++; } }
 }).module;
 ov.render([{ ...base, running: true, state: 'starting' }, {}]);
 hidden = true; await polls[0]();
 h.assertEq(reads.length, 0, 'hidden tab does not read the service state');
 hidden = false; next = { state: 'starting', running: true }; await polls[0]();
 next = { state: 'running', running: true }; await polls[0](); await polls[0]();
 h.assertEq(reads.length, 3, 'visible tab polls the service state');
 h.assertEq(reloads, 0, 'starting -> running does not reload the page');
 console.log('ok - overview polls in place and skips hidden tab');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 17: long actions and service state polling.
seq(async () => {
 const calls = [], polls = [];
 let fresh = { running: true, enabled: true, state: 'running', dns_ok: true };
 const notices = [], delays = connectDelays;
 const bridge = { ...api, jobRunning: false,
  busy: (button, fn) => fn(),
  balancers: async () => ({ balancers: [] }),
  job: async (...args) => { calls.push(['job', ...args]); return { version: 'v1', action: 'unchanged' }; },
  service: async (...args) => calls.push(['service', ...args]),
  write: async (...args) => { throw Error('unexpected synchronous write: ' + args); },
  read: async cmd => { calls.push(['read', cmd]); return cmd === 'service-state-json' ? fresh : cmd === 'status-json' ? { ...base, running: true, state: 'running' } : {}; },
  readLarge: async cmd => { calls.push(['readLarge', cmd]); return []; },
  notify() {}, reloadWithNotice: (...args) => notices.push(args)
 };
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, api: bridge, poll: { add: (fn, seconds) => polls.push({ fn, seconds }) },
  view: { extend: v => v }, location: { reload() {} }, window: { setTimeout: (fn, ms) => { delays.push(ms); setTimeout(fn, 0); } }
 }).module;
 const click = async (status, label) => {
  const p = ov.render([status, {}, []]);
  if (label === 'Connect') collect(p).find(n => n.attrs.id === 'mw-sub-url').value = ' https://p.example/sub ';
  await collect(p).find(n => n.tag === 'button' && texts(n).includes(label)).listeners.click();
 };
 for (const [status, label, expected, notice] of [
  [base, 'Connect', [['job', 'connect', 'https://p.example/sub']], 'Subscription connected. XrayWRT is starting.'],
  [{ ...base, core_installed: false }, 'Install Xray core', [['job', 'core-update']], 'Xray core v1 installed.'],
  [{ ...base, subscription_configured: true }, 'Update subscription', [['job', 'update-subscription']], 'Subscription is up to date.'],
  [base, 'Start', [['service', 'enable'], ['job', 'service', 'start']], 'XrayWRT started.'],
  [{ ...base, enabled: true }, 'Start', [['job', 'service', 'start']], 'XrayWRT started.'],
  [{ ...base, running: true }, 'Stop', [['job', 'service', 'stop']], 'XrayWRT stopped. All traffic bypasses the VPN.'],
  [base, 'Restart', [['job', 'service', 'restart']], 'XrayWRT restarted.']
 ]) {
  calls.length = 0; notices.length = 0; delays.length = 0; await click(status, label);
  h.assertEq(JSON.stringify(calls), JSON.stringify(expected), 'jobs used: ' + label);
  if (notice !== null) h.assertEq(JSON.stringify(notices), JSON.stringify([[notice]]), 'notice passed to reloadWithNotice (before busy ends): ' + label);
  if (label === 'Connect') h.assertEq(JSON.stringify(delays), '[1500]', 'Connect waits 1.5 s inside busy');
 }
 console.log('ok - overview jobs used');
 h.assert(collect(ov.render([base, {}, []])).filter(n => n.attrs['data-mw-job'] != null).every(n => n.attrs.disabled == null), 'idle buttons omit disabled attribute (LuCI stringifies false)');
 bridge.jobRunning = true;
 h.assert(collect(ov.render([base, {}, []])).filter(n => n.attrs['data-mw-job'] != null).every(n => n.attrs.disabled === true), 'already-running job disables buttons at render');
 bridge.jobRunning = false;
 const marked = ov.render([{ ...base, subscription_configured: true }, {}, []]);
 for (const label of ['Start', 'Restart', 'Update subscription'])
  h.assert(collect(marked).find(n => n.tag === 'button' && texts(n).includes(label)).attrs['data-mw-job'] != null, label + ' marked as job starter');
 for (const [details, expected] of [
  [{ state: 'starting' }, 'Starting…'],
  [{ state: 'degraded', running: true }, 'VPN DNS is not responding'],
  [{ state: 'failed', last_error: 'x' }, 'Stopped because of an error.'],
  [{ state: 'failed', last_error: '' }, 'Stopped'],
  [{ state: 'stopped', config_valid: false }, 'Stopped: Xray did not accept the configuration.'],
  [{ state: 'running', running: true, dns_ok: false }, 'Running, but DNS does not answer — see Help']
 ]) {
  const p = ov.render([{ ...base, ...details }, {}, []]);
  h.assert(texts(p).includes(expected), 'headline per state: ' + details.state);
  h.assert(collect(p).some(n => n.attrs['aria-live'] === 'polite' && texts(n).includes(expected)), 'headline is polite');
 }
 console.log('ok - overview headline per state');
 polls.length = 0;
 const p = ov.render([{ ...base, state: 'stopped', config_valid: false }, {}, []]);
 h.assertEq(polls.length, 1, 'one status poll'); h.assertEq(polls[0].seconds, 10, 'poll every 10 seconds');
 const before = collect(p).find(n => n.tag === 'strong');
 calls.length = 0; bridge.jobRunning = true; await polls[0].fn();
 h.assertEq(calls.length, 0, 'poll paused during job');
 bridge.jobRunning = false; await polls[0].fn();
 h.assertEq(JSON.stringify(calls), JSON.stringify([['read', 'service-state-json']]), 'poll uses cheap state read');
 h.assert(collect(p).includes(before), 'status headline stays mounted (focus-safe update)');
 h.assertEq(before.textContent, 'Running', 'headline updated in place');
 await collect(p).find(n => n.tag === 'button' && texts(n).includes('Stop')).listeners.click();
 h.assertEq(JSON.stringify(calls.at(-1)), JSON.stringify(['job', 'service', 'stop']), 'preserved control uses fresh service state');
 h.assertEq(before.attrs['aria-live'], 'polite', 'only headline announces status');
 h.assert(!collect(p).some(n => n.attrs['aria-live'] && collect(n).some(c => c.tag === 'button')), 'live region excludes buttons');
 fresh = { ...fresh, dns_ok: false }; await polls[0].fn();
 h.assert(texts(p).includes('Running, but DNS does not answer — see Help'), 'same-state DNS change updates headline');
 fresh = { running: false, state: 'stopped', enabled: false }; await polls[0].fn();
 h.assert(texts(p).includes('Stopped: Xray did not accept the configuration.'), 'poll preserves full status fields');
 console.log('ok - overview poll');
 const noticeApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', {
  E, ui, fs: {}, setTimeout() {}, location: { reload() {} }
 }).module;
 noticeApi.read = async cmd => { h.assertEq(cmd, 'job-status', 'notice reads current job'); return { state: 'running', op: 'core-update', id: '1' }; };
 const noticeView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, api: noticeApi, poll: { add() {} }, view: { extend: v => v }
 }).module;
 for (const status of [base, { ...base, core_installed: false }]) {
  const p = noticeView.render([status, {}, []]); await Promise.resolve(); await Promise.resolve();
  h.assert(texts(p).includes('"Xray core update" is running…'), 'job notice shown on page');
  h.assert(texts(p).includes('You can close the page — the operation continues on the router.'), 'muted note in job notice');
 }
 console.log('ok - overview job notice');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Stop through the direct fallback while the job slot is taken: the poll must neither
// turn Stop into "started" nor re-enable the busy button, and a failed stop names its reason.
seq(async () => {
 const polls = [], notices = [], writes = [];
 let stateReads = 0, disabledDuringStop = null, toggle = null;
 const stopped = { running: false, state: 'stopped', enabled: true };
 const running = { running: true, state: 'running', enabled: true, dns_ok: true };
 const makeView = (reply) => h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, setTimeout: (fn) => fn(), poll: { add: (fn) => polls.push(fn) }, view: { extend: v => v }, location: {}, window: {},
  api: { ...api, jobRunning: false,
   busy: async (button, fn) => { button.disabled = true; try { return await fn(); } catch (e) { notices.push('error: ' + e.message); } finally { button.disabled = false; } },
   job: async () => { throw new Error('Another operation is running: "Update". Wait until it finishes. [E:operation_busy|Update]'); },
   write: async (cmd) => { writes.push(cmd); return {}; },
   read: async (cmd) => { if (cmd !== 'service-state-json') return {}; return reply(++stateReads); },
   reloadWithNotice: (m) => notices.push(m), notify() {} } }).module;
 const clickStop = async (view) => {
  polls.length = 0;
  const page = view.render([{ ...base, ...running }, {}, []]);
  toggle = collect(page).find(n => n.tag === 'button' && texts(n).includes('Stop'));
  await toggle.listeners.click();
 };
 // Polls run inside the wait loop: one still sees the service running, the next sees it stopped.
 await clickStop(makeView(async (n) => {
  if (n === 1) { await polls[0](); disabledDuringStop = toggle.disabled; await polls[0](); return running; }
  return n === 2 ? running : stopped;
 }));
 h.assertEq(JSON.stringify(writes), '["stop-now"]', 'fallback stop used');
 h.assertEq(disabledDuringStop, true, 'a poll does not re-enable Stop while it works');
 h.assertEq(JSON.stringify(notices), JSON.stringify(['XrayWRT stopped. All traffic bypasses the VPN. Starts again after a router reboot.']), 'the notice says stopped, not started');
 // The service never stops: the reason is the stop, not the busy job.
 notices.length = 0;
 await clickStop(makeView(async () => running));
 h.assertEq(JSON.stringify(notices), JSON.stringify(['error: XrayWRT did not stop. Try again.']), 'failed stop names its own reason');
 console.log('ok - overview Stop fallback');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Lane F2: R14 Overview failed/degraded alert, next steps, config_valid over failed
seq(async () => {
 const ov = overview;
 // config_valid === false wins over state === 'failed'
 const invalidAndFailed = ov.render([{ ...base, state: 'failed', config_valid: false, last_error: 'some error', config_error: 'bad config' }, {}, []]);
 const invalidNodes = collect(invalidAndFailed);
 h.assert(texts(invalidAndFailed).includes('Stopped: Xray did not accept the configuration.'), 'config_valid wins over failed');
 h.assert(invalidNodes.some(n => /alert-message error/.test(n.attrs.class || '')), 'invalid config has alert-message error');
 h.assert(texts(invalidAndFailed).includes('What to do: update the subscription or fix the configuration.'), 'invalid config next step');
 h.assert(invalidNodes.some(n => n.tag === 'a' && n.attrs.href?.includes('help') && texts(n).includes('Open Help')), 'invalid config diagnostics link');
 h.assert(texts(invalidAndFailed).some(t => t.includes('Details:')), 'invalid config shows details');

 // state === 'failed' without config_valid === false
 const failedOnly = ov.render([{ ...base, state: 'failed', last_error: 'service died' }, {}, []]);
 const failedNodes = collect(failedOnly);
 h.assert(texts(failedOnly).includes('Stopped because of an error.'), 'failed headline');
 h.assert(failedNodes.some(n => /alert-message error/.test(n.attrs.class || '')), 'failed has alert-message error');
 h.assert(!texts(failedOnly).includes('What to do: update the subscription or fix the configuration.'), 'a crash is not fixed by the generic step');
 h.assert(failedNodes.some(n => n.tag === 'a' && n.attrs.href?.includes('help') && texts(n).includes('Open Help')), 'failed diagnostics link');
 h.assert(texts(failedOnly).some(t => t.includes('Details:')), 'failed shows details');

 // The generic step is only for configuration errors; other errors say what to do themselves.
 const nextStepFor = (extra) => texts(ov.render([{ ...base, ...extra }, {}, []])).includes('What to do: update the subscription or fix the configuration.');
 h.assert(nextStepFor({ state: 'failed', last_error: 'Config rejected [E:config_rejected]' }), 'failed with a rejected config: generic step');
 h.assert(!nextStepFor({ state: 'failed', last_error: 'Port 53 is used by AdGuardHome [E:dns_port_busy|AdGuardHome]' }), 'failed with its own instruction: no generic step');
 h.assert(!nextStepFor({ state: 'failed', last_error: 'Xray exited unexpectedly' }), 'failed without a code: no generic step');
 h.assert(nextStepFor({ state: 'failed', config_valid: false, config_error: 'Failed to start: main: bad' }), 'core rejection text: generic step');
 h.assert(!nextStepFor({ state: 'failed', config_valid: false, last_error: 'Not enough memory [E:config_test_oom]' }), 'memory error: no generic step');
 h.assert(!nextStepFor({ state: 'stopped', config_valid: false, config_error: 'geodata x.dat: download failed [E:geodata_download|x.dat|network]' }), 'download error: no generic step');

 // state === 'degraded'
 const degraded = ov.render([{ ...base, state: 'degraded' }, {}, []]);
 const degradedNodes = collect(degraded);
 h.assert(degradedNodes.some(n => /alert-message warning/.test(n.attrs.class || '')), 'degraded has alert-message warning');
 h.assert(degradedNodes.some(n => n.tag === 'a' && n.attrs.href?.includes('help') && texts(n).includes('Open Help')), 'degraded diagnostics link');

 // running but dns_ok === false
 const dnsBad = ov.render([{ ...base, state: 'running', running: true, dns_ok: false }, {}, []]);
 const dnsBadNodes = collect(dnsBad);
 h.assert(dnsBadNodes.some(n => /alert-message warning/.test(n.attrs.class || '')), 'running bad dns has alert-message warning');
 h.assert(dnsBadNodes.some(n => n.tag === 'a' && n.attrs.href?.includes('help') && texts(n).includes('Open Help')), 'bad dns diagnostics link');

 // normal stopped / normal running have no alert-message
 const normalStopped = ov.render([{ ...base, state: 'stopped' }, {}, []]);
 h.assert(!collect(normalStopped).some(n => /alert-message/.test(n.attrs.class || '')), 'clean stopped has no alert');
 const normalRunning = ov.render([{ ...base, state: 'running', running: true, dns_ok: true }, {}, []]);
 h.assert(!collect(normalRunning).some(n => /alert-message/.test(n.attrs.class || '')), 'clean running has no alert');

 console.log('ok - overview R14 status alert and diagnostics link');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Lane F2: R41 + R42 + R48
seq(async () => {
 const ov = overview;
 // R42: Restart button hidden when stopped, visible when running
 const stoppedPage = ov.render([{ ...base, running: false }, {}, []]);
 const restartStopped = findButton(stoppedPage, 'Restart');
 h.assert(restartStopped && restartStopped.hidden === true, 'Restart hidden when stopped');
 const runningPage = ov.render([{ ...base, running: true, subscription_configured: true }, {}, []]);
 const restartRunning = findButton(runningPage, 'Restart');
 h.assert(restartRunning && restartRunning.hidden !== true, 'Restart visible when running');

 // R42: Start button without subscription is plain cbi-button with explanation
 const noSubPage = ov.render([{ ...base, running: false, subscription_configured: false }, {}, []]);
 const startNoSub = findButton(noSubPage, 'Start');
 h.assertEq(startNoSub.attrs.class, 'cbi-button', 'Start without subscription is plain button');
 h.assert(texts(noSubPage).includes('Without a subscription XrayWRT starts with the current configuration; by default all traffic goes direct.'), 'no sub explanation note shown');

 // R42: autostart wording
 const bootEnabled = ov.render([{ ...base, enabled: true }, {}, []]);
 h.assert(texts(bootEnabled).includes('Starts automatically when the router boots'), 'autostart enabled wording');
 const bootDisabled = ov.render([{ ...base, enabled: false }, {}, []]);
 h.assert(texts(bootDisabled).includes('Does not start when the router boots'), 'autostart disabled wording');

 console.log('ok - overview R41 R42 R48');
}).catch(err => { console.error(err); process.exitCode = 1; });


// Lane F2: R43 + R44 + R46
seq(async () => {
 const ov = overview;
 // R43: subscription panel shows '—' when no data, and manual-only auto-update
 const emptySub = ov.render([{ ...base, subscription_configured: true, running: true }, {}, []]);
 const emptySubTexts = texts(emptySub);
 h.assert(emptySubTexts.includes('—'), 'subscription shows dash when no data');
 h.assert(!emptySubTexts.includes('Unlimited') && !emptySubTexts.includes('Never'), 'empty sub omits Unlimited/Never');
 h.assert(emptySubTexts.includes('Manual only: the provider does not set an update period'), 'no interval shows manual only');

 // R46: empty DHCP device list shows hint
 const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/traffic.js', {
  E, api, form: { Map: class { section() { return { tab() {}, taboption() { return { renderWidget() { return E('div'); } }; } }; } } },
  uci: { get: () => null, set() {}, unset() {} }, ui, widgets: { DeviceSelect: class {} }, rpc: { declare: () => async () => ({ dhcp_leases: [], dhcp6_leases: [] }) }, view: { extend: v => v }
 }).module;
 const node = E('div'); const area = E('textarea'); area.value = ''; node.querySelector = s => s === 'textarea' ? area : null;
 const emptyLeasesPicker = tv.addLeasePicker(node, { dhcp_leases: [], dhcp6_leases: [] }, 'Device note');
 h.assert(texts(emptyLeasesPicker).includes('No devices found in DHCP. Enter a MAC address, e.g. aa:bb:cc:dd:ee:ff.'), 'empty DHCP hint shown');

 console.log('ok - overview R43 R44 R46');
}).catch(err => { console.error(err); process.exitCode = 1; });


seq(async () => {
 const events = {}, removed = [], calls = [];
 const win = { addEventListener: (name, fn) => { events[name] = fn; }, removeEventListener: (name, fn) => { removed.push(fn); delete events[name]; } };
 const dom = (tag, attrs, children) => { const node = E(tag, attrs, children); node.value = node.attrs.value || ''; node.checked = node.attrs.checked != null; return node; };
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: dom, ui, Blob, window: win, view: { extend: v => v },
  api: { ...api, ...readStubs, busy: async (button, fn) => fn(),
   write: async (...args) => { calls.push(args); return {}; }, job: async (...args) => { calls.push(args); return { action: 'saved' }; },
   upload: async () => '/tmp/yaml', reloadWithNotice() {}, notify() {} }
 }).module;
 const page = await mountSubscription(sv, { url: 'https://p.example/sub', config_backup: true });
 const form = collect(page).find(n => n.tag === 'form'), input = collect(page).find(n => n.attrs.id === 'mw-url');
 form.listeners.submit({ preventDefault() {} }); await settle();
 h.assert(calls.some(c => c[0] === 'update-subscription'), 'Enter with URL updates subscription');
 calls.length = 0; input.value = ''; ui.autoConfirm = false;
 await findButton(page, 'Save').listeners.click();
 h.assertEq(calls.length, 0, 'cancel disable keeps subscription settings');
 ui.autoConfirm = true;
 form.listeners.submit({ preventDefault() {} });
 await new Promise(resolve => setTimeout(resolve, 10)); await settle();
 h.assertEq(calls.at(-1).join(','), 'set-subscription,,1', 'Enter without URL saves settings after confirmation');
 // A fresh page registers a guard after the successful update removed the first one.
 const guarded = await mountSubscription(sv, { url: 'https://p.example/sub', config_backup: true });
 await openToggle(guarded, 'Show config editor');
 collect(guarded).find(n => n.tag === 'textarea').value += '# edit';
 const guard = events.beforeunload;
 const event = { preventDefault() { this.prevented = true; } }; guard(event);
 h.assert(event.prevented && event.returnValue === '', 'beforeunload blocks navigation with YAML edits');
 ui.autoConfirm = false;
 await findButton(guarded, 'Restore previous config').listeners.click();
 h.assertEq(events.beforeunload, guard, 'cancel restore retains edit guard');
 const restoreOk = collect(ui.modalCalls.at(-1).children).find(n => n.tag === 'button' && !texts(n).includes('Cancel'));
 h.assert(restoreOk.attrs.class.includes('cbi-button-negative'), 'YAML restore uses destructive modal button');
 await findButton(guarded, 'Save config').listeners.click();
 h.assert(!events.beforeunload && removed.includes(guard), 'successful YAML save removes beforeunload guard');
 ui.autoConfirm = true;
 // A modal closed from outside never resolves: it must not have locked the job buttons first.
 const busyCalls = [];
 const sv2 = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: dom, ui, Blob, window: win, view: { extend: v => v },
  api: { ...api, ...readStubs, busy: async (button, fn) => { busyCalls.push(button); return fn(); },
   write: async () => ({}), job: async () => ({ action: 'saved' }), upload: async () => '/tmp/yaml', reloadWithNotice() {}, notify() {} }
 }).module;
 const pending = await mountSubscription(sv2, { url: 'https://p.example/sub', config_backup: true });
 await openToggle(pending, 'Show config editor');
 collect(pending).find(n => n.tag === 'textarea').value += '# edit';
 const pendingUrl = collect(pending).find(n => n.attrs.id === 'mw-url');
 ui.autoConfirm = null;
 findButton(pending, 'Restore previous config').listeners.click();
 pendingUrl.value = '';
 findButton(pending, 'Save').listeners.click();
 await settle();
 h.assertEq(busyCalls.length, 0, 'open confirm modals do not lock job buttons');
 ui.hideModal(); ui.autoConfirm = true;
 console.log('ok - subscription modal cancellation, Enter and dirty-navigation guard');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 18: safe editor, large uploads, restore and shared job controls.
seq(async () => {
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null; return n;
 }
 async function check(name, fn) {
  try { await fn(); console.log('ok - subscription ' + name); }
  catch (e) { console.error('not ok - subscription ' + name, e); process.exitCode = 1; }
 }
 const restoreNotices = []; let calls = [], reloads = 0, noticeCalls = 0, applyEvents = [];
 const bridge = { ...api, ...readStubs, jobRunning: false,
  busy: (b, fn) => fn(),
  upload: async (...args) => { calls.push(['upload', ...args]); return '/tmp/xraywrt-config.test'; },
  job: async (...args) => { calls.push(['job', ...args]); return { action: 'unchanged' }; },
  write: async (...args) => { calls.push(['write', ...args]); return {}; },
  jobNotice: () => { noticeCalls++; return E('div', { 'aria-live': 'polite' }); }, notify: m => restoreNotices.push(m),
  reloadWithNotice: m => { restoreNotices.push(m); applyEvents.push('notice'); reloads++; applyEvents.push('reload'); }
 };
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, api: bridge, view: { extend: v => v },
  location: { reload: () => { reloads++; applyEvents.push('reload'); } }
 }).module;
 const render = async (backup = true, auto = true) => {
  const p = await mountSubscription(sv, { url: 'https://old.example', auto_update: auto, config_backup: backup }, { content: 'yaml' });
  await openToggle(p, 'Show config editor');
  return p;
 };
 const button = (p, label) => collect(p).find(n => n.tag === 'button' && texts(n).includes(label));
 // C7: one light read; the backup flag comes with the subscription JSON.
 await check('unknown backup keeps editor usable without status-json', async () => {
  const p = await mountSubscription(sv, { url: 'https://old.example' }, { content: 'yaml' });
  await openToggle(p, 'Show config editor');
  h.assertEq(reads.calls.join(','), 'subscription-json,read-config', 'no status-json read');
  h.assert(collect(p).some(n => n.tag === 'textarea'), 'editor remains available');
  h.assert(button(p, 'Save config') && button(p, 'Update now'), 'actions remain available');
  h.assert(!button(p, 'Restore previous config'), 'unknown backup hides restore');
 });
 await check('malformed YAML response', async () => {
  {
   for (const reply of [{}, { content: null }, { content: 42 }, null]) {
    const p = await mountSubscription(sv, { url: 'https://old.example' }, reply);
    await openToggle(p, 'Show config editor');
    h.assert(texts(p).includes('Cannot load the configuration: Unexpected response from the router.'), 'malformed response error');
    h.assert(!collect(p).some(n => n.tag === 'textarea') && !button(p, 'Save config') && !button(p, 'Restore previous config'), 'no unsafe editor actions');
   }
   const empty = await mountSubscription(sv, { url: 'https://old.example' }, { content: '' });
   await openToggle(empty, 'Show config editor');
   h.assert(collect(empty).some(n => n.tag === 'textarea'), 'empty string is valid YAML content');
  }
 });
 await check('apply reloads after notice', async () => {
  const notify = bridge.notify;
  try {
   for (const [action, msg] of [['unchanged', 'Configuration is unchanged.'], ['restarted', 'Configuration checked and applied; Xray restarted.'], ['hot_reloaded', 'Configuration checked and applied without restarting Xray.'], ['saved', 'Configuration checked and saved.']]) {
    const job = bridge.job; applyEvents = []; restoreNotices.length = 0;
    try {
     bridge.job = async () => ({ action });
     const before = reloads;
     const edited = await render(); collect(edited).find(n => n.tag === 'textarea').value += ' ';
     await button(edited, 'Save config').listeners.click();
     h.assertEq(reloads, before + 1, 'successful apply reloads');
     h.assertEq(applyEvents.join(','), 'notice,reload', 'notice before reload');
     h.assertEq(JSON.stringify(restoreNotices), JSON.stringify([msg]), 'apply notice ' + action);
    } finally { bridge.job = job; }
   }
  } finally { bridge.notify = notify; reloads = 0; }
 });
 await check('apply large YAML and byte limit', async () => {
  const p = await render(), yaml = collect(p).find(n => n.tag === 'textarea');
  yaml.value = 'x'.repeat(1572864); calls = [];
  await button(p, 'Save config').listeners.click();
  h.assertEq(calls[0][0], 'upload', 'upload first'); h.assertEq(calls[0][1], 'xraywrt-config', 'upload prefix');
  h.assertEq(calls[0][2], yaml.value, 'full large content');
  h.assertEq(calls[1].join(','), 'job,save-config,/tmp/xraywrt-config.test', 'save as job');
  for (const content of ['x'.repeat(8388609), 'я'.repeat(4194305)]) {
   yaml.value = content; calls = []; let error = '';
   try { await button(p, 'Save config').listeners.click(); } catch(e) { error = e.message; }
   h.assertEq(error, 'The configuration is larger than 8 MiB.', 'byte limit message'); h.assertEq(calls.length, 0, 'oversize not uploaded');
  }
  yaml.value = 'x'.repeat(8388608); calls = []; await button(p, 'Save config').listeners.click();
  h.assertEq(calls[0][0], 'upload', 'exact limit accepted');
 });
 await check('editor actions share one row, notice after the heading', async () => {
  const p = await render();
  const row = collect(p).find(n => n.attrs.class === 'mw-row' && n.children.includes(button(p, 'Save config')));
  h.assert(row && row.children.includes(button(p, 'Restore previous config')), 'apply and restore in one mw-row');
  const top = p.children.filter(c => c && typeof c === 'object').map(c => c.tag + (c.attrs['aria-live'] ? ':live' : ''));
  h.assert(!top.includes('h2'), 'configuration widgets leave heading and notices to their page');
 });
 await check('restore', async () => {
  reloads = 0;
  const p = await render(); const restore = button(p, 'Restore previous config'); h.assert(restore, 'backup restore button');
  h.assert(texts(p).includes('Automatic updates will replace the restored configuration again.'), 'automatic update warning');
  calls = []; ui.autoConfirm = false; await restore.listeners.click(); h.assertEq(calls.length, 0, 'cancel restore');
  ui.autoConfirm = true; await restore.listeners.click(); h.assertEq(calls[0].join(','), 'job,restore-config', 'restore job'); h.assertEq(reloads, 1, 'reload after restore');
  for (const [action, msg] of [['unchanged', 'Configuration is unchanged.'], ['restarted', 'Configuration checked and applied; Xray restarted.'], ['hot_reloaded', 'Configuration checked and applied without restarting Xray.'], ['saved', 'Configuration checked and saved.']]) {
   bridge.job = async () => ({ action }); restoreNotices.length = 0; await restore.listeners.click();
   h.assertEq(restoreNotices[0], msg, 'restore notice ' + action);
  }
  bridge.job = async (...args) => { calls.push(['job', ...args]); return { action: 'unchanged' }; };
  h.assert(!button(await render(false), 'Restore previous config'), 'no restore without backup');
  const off = await render(true, false), note = collect(off).find(n => n.textContent === 'Automatic updates will replace the restored configuration again.');
  h.assert(note.hidden, 'automatic warning hidden when off');
  const auto = collect(off).find(n => n.attrs.id === 'mw-auto'); auto.checked = true; await auto.listeners.change();
  h.assert(note.hidden, 'editor warning reflects saved settings; subscription lives on another page');
 });
 await check('job notice and shared locks', async () => {
  noticeCalls = 0;
  for (const running of [false, true]) {
   bridge.jobRunning = running; const p = await render();
   for (const label of ['Save', 'Update now', 'Save config', 'Restore previous config']) {
    const b = button(p, label); h.assert(b.attrs['data-mw-job'] != null, label + ' marked');
    h.assert(running ? b.attrs.disabled === true : b.attrs.disabled == null, label + ' running state');
   }
  }
  h.assertEq(noticeCalls, 0, 'configuration widgets leave job notice to the page'); bridge.jobRunning = false;
 });
 await check('update jobs', async () => {
  for (const changed of [false, true]) {
   const p = await render(); collect(p).find(n => n.attrs.id === 'mw-url').value = changed ? 'https://new.example' : 'https://old.example';
   calls = []; await button(p, 'Update now').listeners.click();
   h.assertEq(JSON.stringify(calls), JSON.stringify(changed ? [['job','update-subscription','https://new.example']] : [['write','set-subscription','https://old.example','1'],['job','update-subscription']]), 'update sequence');
  }
 });
 // C9: Save never stores an unchecked new link.
 await check('save with a changed link downloads it first', async () => {
  for (const [link, expected] of [
   ['https://new.example', [['job','update-subscription','https://new.example']]],
   ['https://old.example', [['write','set-subscription','https://old.example','1']]],
   ['', [['write','set-subscription','','1']]]
  ]) {
   const p = await render(); collect(p).find(n => n.attrs.id === 'mw-url').value = link;
   calls = []; restoreNotices.length = 0;
   const savePromise = button(p, 'Save').listeners.click();
   if (link === '' && ui.activeModal) {
    collect(ui.activeModal.children).find(n => n.tag === 'button' && texts(n).includes('Disable'))?.listeners?.click();
   }
   await savePromise;
   h.assertEq(JSON.stringify(calls), JSON.stringify(expected), 'save sequence for ' + (link || 'empty link'));
   h.assertEq(restoreNotices[0], link === 'https://new.example' ? 'Subscription is up to date.' : 'Subscription settings saved.', 'save notice for ' + (link || 'empty link'));
  }
  const job = bridge.job;
  try {
   bridge.job = async (...args) => { calls.push(['job', ...args]); throw Object.assign(Error('Subscription not found (HTTP 404). Check the link in your service account.'), { name: 'JobError' }); };
   const p = await render(); collect(p).find(n => n.attrs.id === 'mw-url').value = 'https://typo.example';
   calls = []; let error = '';
   try { await button(p, 'Save').listeners.click(); } catch (e) { error = e.message; }
   h.assertEq(JSON.stringify(calls), JSON.stringify([['job','update-subscription','https://typo.example']]), 'failed new link never stored');
   h.assert(error.includes('not found (HTTP 404)') && error.includes('The previous link is kept.'), 'failure explained: ' + error);
  } finally { bridge.job = job; }
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 11: Update now must not fall back to the saved link or clear it.
seq(async () => {
 const calls = [], notices = [];
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children);
  n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null;
  n.hasAttribute = name => name in n.attrs;
  return n;
 }
 const subscriptionApi = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', {
  E: DOM, fs: {}, ui: { ...ui, addNotification: (title, node, level) => { notices.push({ node, level }); } }
 }).module;
 Object.assign(subscriptionApi, readStubs, {
  write: async (...args) => { calls.push(['write', ...args]); return {}; },
  job: async (...args) => { calls.push(['job', ...args]); return { action: 'unchanged' }; },
  jobNotice: () => E('div'), reloadWithNotice() {}
 });
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, api: subscriptionApi, view: { extend: v => v }
 }).module;
 const message = 'Enter the subscription link, or press Save to stop using a subscription.';
 for (const empty of ['', ' \t ']) {
  const p = await mountSubscription(sv, { url: 'https://old.example', auto_update: true });
  collect(p).find(n => n.attrs.id === 'mw-url').value = empty;
  calls.length = 0; notices.length = 0;
  await findButton(p, 'Update now').listeners.click();
  h.assertEq(calls.length, 0, 'empty link refused: no update-subscription or set-subscription');
  h.assertEq(notices.length, 1, 'empty link refused: one notice');
  h.assertEq(notices[0].level, 'error', 'empty link refused: error notice');
  h.assertEq(texts(notices[0].node).join(''), message, 'empty link refused: explanation');
  const savePromise = findButton(p, 'Save').listeners.click();
  if (ui.activeModal) {
   collect(ui.activeModal.children).find(n => n.tag === 'button' && texts(n).includes('Disable'))?.listeners?.click();
  }
  await savePromise;
  h.assertEq(JSON.stringify(calls), JSON.stringify([['write', 'set-subscription', '', '1']]), 'Save still accepts an empty link');
 }
 const catalog = require('fs').readFileSync(path.join(process.argv[2], 'po/ru/xraywrt.po'), 'utf8');
 h.assert(catalog.includes('msgid "' + message + '"\nmsgstr "Введите ссылку на подписку или нажмите «Сохранить», чтобы отказаться от подписки."'), 'empty link refused: Russian translation');
 console.log('ok - subscription empty link refused');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Plan task 12: the YAML editor loads on demand; the YAML passed to Mihomo is a second, read-only view.
// The test E() supports appendChild, removeChild and textContent; views may also use replaceChildren.
seq(async () => {
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null;
  n.replaceChildren = (...nodes) => { n.children = nodes; };
  return n;
 }
 async function check(name, fn) {
  try { await fn(); console.log('ok - subscription ' + name); }
  catch (e) { console.error('not ok - subscription ' + name, e); process.exitCode = 1; }
 }
 const jobs = [];
 const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, location: { reload() {} },
  api: { ...api, ...readStubs, busy: async (el, fn) => fn(), upload: async () => '/tmp/yaml', write: async () => ({}),
   job: async (...args) => { jobs.push(args); return { action: 'unchanged' }; }, notify() {}, reloadWithNotice() {} }
 }).module;
 const editorLabel = 'Show config editor', effectiveShow = 'Show running config', effectiveHide = 'Hide running config';
 const readCount = cmd => reads.calls.filter(c => c === cmd).length;
 const editorAreas = p => collect(p).filter(n => n.tag === 'textarea');
 await check('no yaml at load', async () => {
  resetReads({ url: 'https://p.example/sub' });
  const p = sv.render(await sv.load());
  h.assertEq(readCount('read-config'), 0, 'load does not read the YAML');
  h.assertEq(readCount('runtime-config'), 0, 'load does not read the effective YAML');
  const open = findButton(p, editorLabel);
  await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 1, 'first opening reads the YAML');
  h.assertEq(editorAreas(p)[0]?.value, 'proxies: []\n', 'editor shows the loaded YAML');
  await open.listeners.click(); await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 1, 'second opening does not read again after success');
  h.assertEq(editorAreas(p).length, 1, 'still one editor');
 });
 await check('yaml load error retry', async () => {
  resetReads({ url: 'https://p.example/sub' }, Error('x'));
  const p = sv.render(await sv.load());
  const open = findButton(p, editorLabel), box = toggleOf(p, open);
  await open.listeners.click(); await settle();
  h.assert(texts(box).includes('Cannot load the configuration: x'), 'error alert inside the toggle');
  h.assertEq(editorAreas(p).length, 0, 'no textarea after a failed load');
  h.assert(!findButton(p, 'Save config'), 'no Save config after a failed load');
  await open.listeners.click();
  reads.responses['read-config'] = { content: 'proxies: []\n' };
  await open.listeners.click(); await settle();
  h.assertEq(readCount('read-config'), 2, 'reopening retries');
  h.assertEq(editorAreas(p).length, 1, 'editor after a successful retry');
  h.assert(findButton(p, 'Save config'), 'Save config after a successful retry');
  h.assert(!texts(box).includes('Cannot load the configuration: x'), 'error alert gone after the retry');
 });
 await check('update confirm only when edited', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  ui.modalCalls.length = 0; jobs.length = 0;
  await findButton(p, 'Update now').listeners.click();
  h.assertEq(ui.modalCalls.length, 0, 'editor never opened: no confirm');
  h.assert(jobs.some(j => j[0] === 'update-subscription'), 'update ran');
  await openToggle(p, editorLabel);
  jobs.length = 0;
  await findButton(p, 'Update now').listeners.click();
  h.assertEq(ui.modalCalls.length, 0, 'editor opened but not edited: no confirm');
  h.assert(jobs.some(j => j[0] === 'update-subscription'), 'update ran after an unedited opening');
 });
 await check('effective yaml', async () => {
  const content = 'mixed-port: 7890\nsecret: "s"\ntproxy-port: 7894\n';
  for (const generated of [false, true]) {
   const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
   reads.responses['runtime-config'] = { content, generated };
   const show = findButton(p, effectiveShow), box = toggleOf(p, show);
   h.assert(show, 'toggle label ' + effectiveShow);
   h.assertEq(readCount('runtime-config'), 0, 'not read before opening');
   const before = textareaOptions.length;
   await show.listeners.click(); await settle();
   h.assert(texts(show).includes(effectiveHide), 'toggle label ' + effectiveHide);
   h.assertEq(readCount('runtime-config'), 1, 'opening reads runtime-config');
   const area = collect(box).find(n => n.tag === 'textarea');
   h.assert(area, 'read-only textarea inside the toggle');
   h.assertEq(area.value, content, 'textarea equals the reply');
   const opts = textareaOptions.slice(before).find(o => o.readonly);
   h.assert(opts, 'ui.Textarea created with readonly');
   h.assertEq(opts.monospace, true, 'monospace');
   h.assertEq(opts.wrap, false, 'no wrap');
   h.assertEq(opts.rows, 24, '24 rows');
   h.assert(texts(box).includes('Config passed to Xray, with router rules added. Secrets are masked with ***.'), 'note text');
   const stopped = collect(box).some(n => String(n.textContent).includes('XrayWRT is not running; this is what it would pass at start.'));
   h.assertEq(stopped, generated, 'not-running line only when generated');
   await show.listeners.click(); await show.listeners.click(); await settle();
   h.assertEq(readCount('runtime-config'), 2, 'each opening reads again');
   h.assert(!editorAreas(p).some(n => n.attrs.id === 'widget.mw-config'), 'the YAML editor stays unloaded');
   h.assertEq(readCount('read-config'), 0, 'effective view does not read the editable YAML');
  }
 });
 await check('effective yaml keeps the latest reply', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  let release;
  const slow = new Promise(r => { release = r; });
  const real = reads.responses;
  let n = 0;
  reads.responses = new Proxy(real, { get: (t, k) => k === 'runtime-config' ? (n++ === 0 ? slow : { content: 'new', generated: false }) : t[k], has: (t, k) => k in t });
  const show = findButton(p, effectiveShow), box = toggleOf(p, show);
  await show.listeners.click(); await show.listeners.click(); await show.listeners.click(); await settle();
  release({ content: 'old', generated: false }); await settle();
  h.assertEq(collect(box).find(n => n.tag === 'textarea')?.value, 'new', 'a slower earlier reply does not replace the newer one');
  reads.responses = real;
 });
 await check('load error offers Try again', async () => {
  resetReads({ url: 'https://p.example/sub' }, Error('x'));
  const p = sv.render(await sv.load());
  const open = findButton(p, editorLabel), box = toggleOf(p, open);
  h.assert(open.attrs['aria-controls'] && box.children[1].attrs.id === open.attrs['aria-controls'], 'toggle button controls its region');
  await open.listeners.click(); await settle();
  h.assert(collect(box).some(n => n.attrs.role === 'alert'), 'load error is an alert');
  reads.responses['read-config'] = { content: 'proxies: []\n' };
  await findButton(box, 'Try again').listeners.click(); await settle();
  h.assertEq(editorAreas(p).length, 1, 'Try again loads the editor');
 });
 await check('effective yaml error', async () => {
  const p = await mountSubscription(sv, { url: 'https://p.example/sub' });
  reads.responses['runtime-config'] = Error('boom');
  const show = findButton(p, effectiveShow), box = toggleOf(p, show);
  await show.listeners.click(); await settle();
  h.assert(texts(box).includes('Cannot load the configuration: boom'), 'error alert inside the effective toggle');
  h.assert(!collect(box).some(n => n.tag === 'textarea'), 'no textarea after a failed load');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 19: one Save & Apply, partial file writes, and MAC-aware leases.
seq(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, dependencies: [], keylist: [], vallist: [] }); }
  depends(...args) { this.dependencies.push(args); }
  value(k, label) { this.keylist.push(k); this.vallist.push(label); }
  get values() { return this.keylist.map((k, i) => [k, this.vallist[i]]); }
  cfgvalue() { return this.uci.get('xraywrt', 'settings', this.name) ?? this.default; }
  write(sid, value) { this.uci.set('xraywrt', sid, this.name, value); }
  remove(sid) { this.uci.unset('xraywrt', sid, this.name); }
  isActive() { return !this.dependencies.length || this.dependencies.some(([key, value]) => this.options[key].cfgvalue('settings') === value); }
  renderWidget() { const n = E('input'); n.style = {}; n.querySelector = () => n; return n; }
 }
 class Map {
  constructor(name, title, description) { Object.assign(this, { name, title, description, options: {} }); }
  section() {
   const section = { children: [], tab() {} };
   section.taboption = (tab, Type, name, title, description) => {
    const o = new Type(name, title, description); o.tab = tab; section.children.push(o); this.options[name] = o; return o;
   };
   section.option = (Type, name, title, description) => section.taboption(null, Type, name, title, description);
   return section;
  }
  render() { return Promise.resolve(E('form')); }
 }
 const form = { Map, Flag: class extends Option {}, Value: Option, DummyValue: Option, ListValue: Option, TextValue: Option, DynamicList: Option, NamedSection: Option };
 const lists = { rules: 'https://example.com/list.txt direct\n', src: '', direct_src: '' };
 // view: traffic.js (default) or advanced.js, whose render takes [profile, status].
 const setup = (overrides = {}, leasesRPC = async () => ({}), view = 'traffic') => {
  const calls = [], notices = [], edits = {};
  const bridge = { ...api, jobRunning: false, busy: (button, fn) => fn(),
   readLarge: async cmd => { calls.push(['readLarge', cmd]); return { ...lists }; },
   read: async () => ({}), upload: async (...args) => { calls.push(['upload', ...args]); return '/tmp/xraywrt-policy-list.test'; },
   job: async (...args) => { calls.push(['job', ...args]); return {}; },
   notify: (...args) => notices.push(args), jobNotice: () => { calls.push(['jobNotice']); return E('div', { 'aria-live': 'polite' }, ['JOB NOTICE']); },
   ...overrides
  };
  const settings = {};
  const uci = {
   get: (pkg, sid, key) => settings[key],
   set: (pkg, sid, key, value) => { settings[key] = value; },
   unset: (pkg, sid, key) => { delete settings[key]; },
   changes: async () => { calls.push(['changes']); return {}; }
  };
  const ui = {
   changes: { apply: checked => calls.push(['apply', checked]) },
   showModal(title, children) {
    calls.push(['modal', title, children]);
    const confirm = collect(E('div', {}, children)).find(n => n.tag === 'button' && !texts(n).includes('Cancel'));
    if (confirm?.listeners?.click) setTimeout(confirm.listeners.click, 0);
   },
   hideModal() {}
  };
  // providerScalar lives in api.js and reads this test's uci.
  bridge.providerScalar = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, uci }).module.providerScalar.bind(bridge);
  const tv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/' + view + '.js', {
   E, api: bridge, form, uci, ui, Event, window: { confirm: msg => { calls.push(['confirm', msg]); return true; } }, widgets: { DeviceSelect: Option }, rpc: { declare: () => leasesRPC }, view: { extend: v => v }
  }).module;
  const render = async (data = { ...lists }, profile = {}) => {
   const page = await tv.render(view === 'traffic' ? [data, profile, {}] : [profile, {}, { url: 'https://p.example/sub' }]);
   for (const o of Object.values(tv.map.options)) Object.assign(o, { uci, options: tv.map.options });
   return page;
  };
  const saving = () => {
   tv.map.parse = async () => { calls.push(['parse']); Object.assign(tv.edited, edits); };
   tv.map.save = async (...args) => { calls.push(['save', ...args]); await tv.map.parse(); };
   calls.length = 0;
  };
  return { tv, ui, bridge, calls, notices, edits, uci, settings, render, saving };
 };
 async function check(name, fn) {
  try { await fn(); console.log('ok - lists ' + name); }
  catch (e) { console.error('not ok - lists ' + name, e); process.exitCode = 1; }
 }
 const settingsSetup = overrides => setup(overrides, undefined, 'advanced');
 async function checkSettings(name, fn) {
  try { await fn(); console.log('ok - settings ' + name); }
  catch (e) { console.error('not ok - settings ' + name, e); process.exitCode = 1; }
 }
 // Plan task 20: Advanced client IPv6 policy uses the existing provider controls.
 const ipv6Flag = t => {
  const o = t.tv.map.options.block_client_ipv6;
  h.assert(o instanceof (t.tv.profile?.provider?.block_client_ipv6 ? form.ListValue : form.Flag), 'client IPv6 uses the appropriate control');
  return o;
 };
 const ipv6Title = 'Block external IPv6 from clients';
 const ipv6Description = 'Keep external IPv6 of client devices from reaching the internet without the VPN.';
 await checkSettings('client IPv6 off by default', async () => {
  const t = settingsSetup(); await t.render(); const o = ipv6Flag(t);
  h.assertEq(o.tab, 'routing', 'client IPv6 is in Routing');
  h.assertEq(o.title, ipv6Title, 'client IPv6 title');
  h.assertEq(o.description, ipv6Description, 'client IPv6 scope and limits');
  h.assertEq(o.default, '0', 'client IPv6 default off');
  h.assertEq(o.cfgvalue('settings'), '0', 'unset UCI defaults off');
  h.assertEq(o.rmempty, false, 'explicit off must stay in UCI');
  h.assert(!t.tv.map.options._own_block_client_ipv6, 'no override without provider');
  const catalog = require('fs').readFileSync(path.join(process.argv[2], 'po/ru/xraywrt.po'), 'utf8');
  for (const [english, russian] of [
   [ipv6Title, 'Блокировать внешний IPv6 клиентов'],
   [ipv6Description, 'Не пускать IPv6 устройств в интернет мимо VPN.']
  ]) h.assert(catalog.includes(`msgid "${english.replace(/"/g, '\\"')}"\nmsgstr "${russian}"`), 'exact Russian translation: ' + english);
 });
 await checkSettings('provider dropdown preserves saved own value', async () => {
  const t = settingsSetup(); t.settings.block_client_ipv6 = '0'; t.settings.provider_override = ['bypass_ntp'];
  await t.render(lists, { provider: { block_client_ipv6: '1' } });
  const o = ipv6Flag(t);
  h.assertEq(o.cfgvalue('settings'), 'provider', 'provider applies initially');
  h.assertEq(o.values[0][1], 'From subscription: Enabled', 'provider value displayed');
  h.assertEq(o.title, ipv6Title, 'dropdown keeps accessible title');
  o.write('settings', '0');
  h.assertEq(t.settings.provider_override.join(','), 'bypass_ntp,block_client_ipv6', 'own adds override');
  h.assertEq(t.settings.block_client_ipv6, '0', 'own choice saved');
  h.assertEq(o.cfgvalue('settings'), '0', 'own off wins');
  o.write('settings', 'provider');
  h.assertEq(t.settings.provider_override.join(','), 'bypass_ntp', 'provider removes only this override');
  h.assertEq(t.settings.block_client_ipv6, '0', 'provider choice keeps saved own off');
  h.assertEq(o.cfgvalue('settings'), 'provider', 'provider selected again');
  t.settings.provider_override = ['block_client_ipv6']; o.remove('advanced');
  h.assert(!('provider_override' in t.settings), 'last override removed cleanly');
  h.assertEq(t.settings.block_client_ipv6, '0', 'remove also preserves own value');
 });
 await checkSettings('override survives provider removal and return', async () => {
  const t = settingsSetup();
  await t.render(lists, { provider: { block_client_ipv6: '1' } });
  ipv6Flag(t).write('settings', '0');
  await t.render(lists, {});
  h.assert(ipv6Flag(t) instanceof form.Flag, 'provider disappears: plain flag');
  h.assertEq(ipv6Flag(t).cfgvalue('settings'), '0', 'own off used without provider');
  h.assertEq(t.settings.provider_override.join(','), 'block_client_ipv6', 'override retained');
  await t.render(lists, { provider: { block_client_ipv6: '1' } });
  h.assertEq(ipv6Flag(t).cfgvalue('settings'), '0', 'override restored when provider returns');
 });
 await checkSettings('provider log level dropdown', async () => {
  const t = settingsSetup(); t.settings.core_log_level = 'error';
  await t.render(lists, { provider: { core_log_level: 'debug' } });
  let o = t.tv.map.options.core_log_level;
  h.assertEq(o.cfgvalue('settings'), 'provider', 'log level follows provider');
  h.assertEq(o.values[0][1], 'From subscription: Debug', 'provider log level readable label');
  h.assertEq(o.values.map(v => v[0]).join(','), 'provider,debug,info,warning,error,none', 'all own log levels');
  o.write('settings', 'none');
  h.assertEq(t.settings.core_log_level, 'none', 'own log level saved');
  h.assertEq(t.settings.provider_override.join(','), 'core_log_level', 'log override saved');
  o.write('settings', 'provider');
  h.assertEq(t.settings.core_log_level, 'none', 'provider choice preserves own level');
  h.assert(!t.settings.provider_override, 'log override removed');
  await t.render(lists, {}); o = t.tv.map.options.core_log_level;
  h.assertEq(o.default, 'warning', 'plain log default remains warning');
  h.assertEq(o.cfgvalue('settings'), 'none', 'saved own log value without provider');
  h.assertEq(o.values.map(v => v[0]).join(','), 'none,error,warning,info,debug', 'plain log choices unchanged');
 });
 await checkSettings('routing defaults are off', async () => {
  const t = settingsSetup(); await t.render();
  for (const name of ['dns_hijack', 'disable_quic', 'bypass_ntp']) {
   const o = t.tv.map.options[name];
   h.assertEq(o.default, '0', name + ' default is off');
   h.assertEq(o.rmempty, false, name + ' explicit on stays saved');
  }
 });
 await checkSettings('stock Save & Apply', async () => {
  const t = settingsSetup(); await t.render();
  h.assertEq(t.tv.handleSaveApply, undefined, 'UCI-only page keeps the LuCI form Save & Apply');
 });
 await check('buttons', async () => {
  const t = setup(); const p = await t.render();
  h.assertEq(t.tv.handleSave, null, 'no plain Save'); h.assertEq(typeof t.tv.handleSaveApply, 'function', 'Save & Apply defined');
  h.assertEq(t.tv.map.description, 'Choose which sites, addresses and devices go through the VPN and which go directly. These lists belong to the current subscription. Save & Apply applies the changes.', 'map description');
  h.assert(texts(p).includes('JOB NOTICE'), 'job notice on page');
 });
 await checkSettings('flags keep explicit values', async () => {
  const t = settingsSetup(); await t.render({ ...lists }, { provider: { dns_hijack: '1', lists_interval: '6' } });
  const flags = Object.values(t.tv.map.options).filter(o => o instanceof form.Flag);
  h.assert(flags.length >= 4, 'flags rendered');
  h.assert(flags.every(o => o.rmempty === false), 'flags with a default value must not be removed by form.Flag.parse');
 });
 await check('no null or empty children', async () => {
  const t = setup(); const p = await t.render({ ...lists });
  h.assert(collect(p).every(n => n.children.every(c => c != null && c !== false)), 'no null child that LuCI would print');
  h.assert(texts(p).includes('JOB NOTICE'), 'job notice present');
  h.assert(!t.tv.map.options._mode.cfgvalue().includes('To change the mode'), 'mode help is not part of the value');
 });
 await check('save unchanged lists', async () => {
  for (const snapshot of [lists, { ...lists, src: 'aa:bb:cc:dd:ee:ff # phone\n' }]) {
   const t = setup(); await t.render({ ...snapshot }); t.saving();
   // LuCI removes optional empty values even when they were already empty.
   for (const [kind, value] of Object.entries(snapshot)) t.edits[kind] = value;
   await t.tv.handleSaveApply(null, '0');
   h.assert(!t.calls.some(c => ['upload', 'job', 'apply'].includes(c[0])), 'no uploads, list job, or UCI apply');
   h.assertEq(JSON.stringify(t.calls.find(c => c[0] === 'save')), JSON.stringify(['save', null, true]), 'map saved silently');
   h.assertEq(t.notices.at(-1)[0], 'Changes applied.', 'empty changes success notice');
  }
 });
 await check('save one list', async () => {
  const t = setup(); await t.render(); t.saving(); t.edits.src = '192.168.1.5';
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(JSON.stringify(t.calls.filter(c => ['upload', 'job', 'save'].includes(c[0]))), JSON.stringify([
   ['upload', 'xraywrt-policy-list', '192.168.1.5'], ['job', 'apply-lists', '-', '/tmp/xraywrt-policy-list.test', '-'], ['save', null, true]
  ]), 'one upload then partial job then map.save');
  h.assertEq(t.tv.lists.src, '192.168.1.5', 'snapshot refreshed');
 });
 await check('clearing a list uploads and applies it', async () => {
  const t = setup(); await t.render({ ...lists, src: '192.168.1.5\n' }); t.saving(); t.edits.src = '';
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(JSON.stringify(t.calls.filter(c => ['upload', 'job'].includes(c[0]))), JSON.stringify([
   ['upload', 'xraywrt-policy-list', ''], ['job', 'apply-lists', '-', '/tmp/xraywrt-policy-list.test', '-']
  ]), 'cleared list uploaded and applied');
  h.assertEq(t.tv.lists.src, '', 'snapshot cleared');
 });
 await check('apply with foreign changes', async () => {
  for (const mode of ['0', '1']) for (const changedList of [false, true]) {
   const t = setup(); await t.render(); t.saving();
   if (changedList) t.edits.src = '192.168.1.5';
   t.uci.changes = async () => ({ network: [['set', 'lan', 'ipaddr', '192.168.2.1']] });
   await t.tv.handleSaveApply(null, mode);
   h.assertEq(JSON.stringify(t.calls.filter(c => c[0] === 'apply')), JSON.stringify([['apply', mode === '0']]), 'foreign UCI changes applied like stock LuCI');
  }
  const t = setup(); await t.render(); t.saving(); t.uci.changes = async () => ({ xraywrt: [] });
  await t.tv.handleSaveApply(null, '0'); h.assert(!t.calls.some(c => c[0] === 'apply'), 'empty change arrays do not apply');
 });
 await check('partial list warning survives UCI apply', async () => {
  const order = [];
  const result = { apply_status: 'partial', warnings: ['Routing needs retry'] };
  const t = setup({ job: async () => result, keepResult: r => { h.assertEq(r, result, 'partial result retained'); order.push('keep'); } });
  await t.render(); t.saving(); t.edits.src = '192.168.1.5';
  t.uci.changes = async () => ({ xraywrt: [['set', 'settings', 'mode', 'direct-first']] });
  const apply = t.ui.changes.apply;
  t.ui.changes.apply = mode => { order.push('apply'); return apply(mode); };
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(order.join(','), 'keep,apply', 'warning kept before LuCI reload flow');
 });
 await check('rejected list', async () => {
  const t = setup({ job: async () => { throw Object.assign(Error(api.errorText(Error("Invalid src entries: x [E:list_invalid|src|x]"))), { name: 'JobError' }); } }); await t.render(); t.saving(); t.edits.src = 'x';
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(t.tv.saving, false, 'save guard released after rejection');
  h.assertEq(t.notices.at(-1)[0], '"Devices via VPN" has invalid lines: x', 'list title in notice');
  h.assert(!t.calls.some(c => c[0] === 'save'), 'settings not saved');
  h.assertEq(t.tv.edited.src, 'x', 'edits retained'); h.assertEq(t.tv.lists.src, '', 'installed snapshot unchanged');
 });
 await check('settings failure after lists', async () => {
  const t = setup(); await t.render(); t.saving(); t.edits.src = '192.168.1.5';
  t.tv.map.save = async () => { throw Error('disk full'); };
  await t.tv.handleSaveApply(null, '0');
  h.assertEq(t.tv.saving, false, 'save guard released after settings failure');
  h.assert(t.notices.at(-1)[0].includes('Lists were saved, but settings could not be saved: disk full'), 'partial success explained');
  h.assertEq(t.tv.lists.src, '192.168.1.5', 'applied lists remembered');
  h.assert(!t.calls.some(c => c[0] === 'apply'), 'no UCI apply after failed save');
 });
 await check('lists load failure', async () => {
  for (const result of ['reject', null, {}, { ...lists, src: null }]) {
   const t = setup({ readLarge: async cmd => { h.assertEq(cmd, 'lists-json', 'lists use readLarge'); if (result === 'reject') throw Error('read failed'); return result; } });
   const p = await t.tv.render(await t.tv.load());
   h.assert(collect(p).some(n => /alert-message error/.test(n.attrs.class || '')), 'load error box');
   h.assert(texts(p).some(s => s.includes('Cannot load the lists:')), 'error cause shown');
   for (const name of ['_rules', '_src']) h.assertEq(t.tv.map.options[name].readonly, true, name + ' read-only');
   t.saving(); t.edits.src = 'accidental'; await t.tv.handleSaveApply(null, '0');
   h.assert(!t.calls.some(c => c[0] === 'upload' || c[0] === 'job'), 'failed load never uploads');
  }
 });
 await check('mode help', async () => {
  const t = setup(); await t.render({ ...lists }, { mode: 'proxy-first' });
  h.assertEq(t.tv.map.options.mode.description, 'Everything goes via VPN except the addresses and devices below.', 'mode help is the description');
  h.assertEq(t.tv.map.options.mode.cfgvalue(), 'provider', 'mode follows the configuration');
  h.assert(!Object.keys(t.tv.map.options).some(k => k.endsWith('_inactive')), 'no inactive list rows: each mode shows its own device list');
 });
 const lease = { hostname: 'phone', macaddr: 'AA:BB:CC:DD:EE:FF', ipaddr: '192.168.1.5' };
 const picker = (t, leases, value = '', description) => {
  const area = { value, listeners: {}, addEventListener(k, fn) { this.listeners[k] = fn; }, dispatchEvent(ev) { this.listeners[ev.type]?.(); } };
  const widget = E('div'); widget.querySelector = q => q === 'textarea' ? area : null;
  const p = t.tv.addLeasePicker(widget, leases, description), selects = collect(p).filter(n => n.tag === 'select');
  return { p, area, select: selects[0], addAs: selects[1] };
 };
 const add = (p, index) => { p.select.value = p.select.children[index + 1].attrs.value; p.select.listeners.change(); };
 await check('picker add as', async () => {
  const t = setup();
  const p = picker(t, { dhcp_leases: [lease], dhcp6_leases: [{ hostname: 'tv', ip6addrs: ['2001:db8::5/128'] }, { ip6addr: '2001:db8::6' }] });
  h.assert(p.addAs, 'two selects'); h.assertEq(p.addAs.value, 'mac', 'MAC default');
  add(p, 0); add(p, 0); h.assertEq(p.select.value, '', 'picker resets after repeated selection');
  h.assertEq(p.area.value, 'aa:bb:cc:dd:ee:ff # phone\n', 'MAC lower-case, hostname, once');
  p.addAs.value = 'ip'; add(p, 0); add(p, 0);
  h.assertEq(p.area.value, 'aa:bb:cc:dd:ee:ff # phone\n192.168.1.5 # phone\n', 'IP hostname, once');
  for (const as of ['mac', 'ip']) { p.addAs.value = as; add(p, 1); }
  h.assertEq(p.area.value.split('2001:db8::5').length - 1, 1, 'DHCPv6 fallback strips prefix and deduplicates');
  h.assert(p.area.value.includes('2001:db8::5 # tv'), 'IPv6 hostname'); add(p, 2); h.assert(p.area.value.includes('2001:db8::6'), 'singular ip6addr fallback');
 });
 await check('picker without labels', async () => {
  const p = picker(setup(), { dhcp_leases: [lease] });
  const outsideOptions = collect(p.p).filter(n => n.tag !== 'option').flatMap(n => n.children.filter(c => typeof c === 'string'));
  h.assert(!outsideOptions.includes('Add a device') && !outsideOptions.includes('Add as'), 'no visible label text outside <option>');
  h.assert(!collect(p.p).some(n => n.tag === 'label'), 'no label elements');
  h.assertEq(p.select.attrs['aria-label'], 'Add a device', 'device select accessible name');
  h.assertEq(texts(p.select.children[0]).join(''), 'Add a device…', 'device select placeholder option');
  h.assertEq(p.addAs.attrs['aria-label'], 'Add as', 'Add as select accessible name');
  h.assertEq(JSON.stringify(p.addAs.children.map(o => [o.attrs.value, texts(o).join('')])), JSON.stringify([['mac', 'MAC (IPv4 + IPv6)'], ['ip', 'IP address']]), 'Add as options');
  h.assertEq(p.addAs.value, 'mac', 'MAC is the default');
  const row = collect(p.p).find(n => (n.attrs.class || '').split(' ').includes('mw-picker'));
  h.assert(row && row.attrs.class.split(' ').includes('mw-row'), 'picker row is mw-row mw-picker');
  h.assert(row.children.includes(p.select) && row.children.includes(p.addAs), 'selects are direct children of the picker row (.mw-picker > select)');
 });
 await check('DHCPv6 host address only', async () => {
  const p = picker(setup(), { dhcp6_leases: [
   { ip6addrs: ['2001:db8:1::/56', '2001:db8::7/128'] },
   { ip6addrs: ['2001:db8:2::/64'], ip6addr: '2001:db8::8/128' },
   { ip6addrs: ['2001:db8:3::/64'] },
   { ip6addr: '2001:db8:4::/56' },
   { macaddr: lease.macaddr, ip6addr: '2001:db8:5::/64' },
   { ipaddr: '192.168.1.6', ip6addr: '2001:db8:6::/64' }
  ] });
  h.assertEq(p.select.children.length, 5, 'prefix-only leases without MAC or IPv4 omitted');
  add(p, 0); add(p, 1); add(p, 2); add(p, 3);
  h.assertEq(p.area.value, '2001:db8::7\n2001:db8::8\naa:bb:cc:dd:ee:ff\n192.168.1.6\n', 'host addresses chosen, never delegated prefixes');
 });
 await check('leases unavailable', async () => {
  const t = setup({}, async () => { throw Error('RPC unavailable'); });
  const data = await t.tv.load(); h.assertEq(data[2], null, 'failed leases remain unavailable');
  const p = picker(t, data[2], '192.168.1.9\naa:bb:cc:dd:ee:ff');
  h.assert(!texts(p.p).some(s => s.includes('Not connected now:')), 'no false offline note');
  h.assert(!p.select, 'unavailable picker omitted');
 });
 await check('offline note changes only on change', async () => {
  const p = picker(setup(), {}, '192.168.1.9');
  const note = collect(p.p).find(n => n.textContent.startsWith('Not connected now:'));
  h.assert(note, 'initial note'); p.area.value = '192.168.1.10';
  p.area.listeners.input?.();
  h.assertEq(note.textContent, 'Not connected now: 192.168.1.9', 'typing does not recompute');
  p.area.listeners.change(); h.assertEq(note.textContent, 'Not connected now: 192.168.1.10', 'change recomputes');
 });
 await check('private mac marked, no notification', async () => {
  const help = 'Keep the device\'s private Wi-Fi address fixed for this network, or this rule will stop matching.';
  const t = setup(), p = picker(t, { dhcp_leases: [{ hostname: 'phone', macaddr: 'DA:A1:19:00:00:01', ipaddr: '192.168.1.7' }, { macaddr: 'DA:A1:19:00:00:02' }, { hostname: 'laptop', macaddr: '00:11:22:33:44:55' }] }, '', 'Devices text.');
  h.assertEq(texts(p.select.children[1]).join(''), 'phone (192.168.1.7, private MAC)', 'private MAC marked in the option');
  h.assertEq(texts(p.select.children[2]).join(''), 'unknown (DA:A1:19:00:00:02, private MAC)', 'private MAC without host or IP');
  h.assertEq(texts(p.select.children[3]).join(''), 'laptop (00:11:22:33:44:55)', 'global MAC not marked');
  const descs = collect(p.p).filter(n => n.attrs?.class === 'cbi-value-description' && texts(n).join('').startsWith('Devices text.'));
  h.assertEq(descs.map(n => texts(n).join('')).join('|'), 'Devices text. ' + help, 'static help in the field description');
  const before = JSON.stringify(collect(p.p).map(n => n.tag));
  add(p, 0); add(p, 1);
  h.assertEq(t.notices.length, 0, 'adding a private MAC shows no notification');
  h.assertEq(JSON.stringify(collect(p.p).map(n => n.tag)), before, 'no element appears or disappears');
  const plain = setup(), q = picker(plain, { dhcp_leases: [{ hostname: 'laptop', macaddr: '00:11:22:33:44:55' }] }, '', 'Devices text.');
  h.assert(!collect(q.p).some(n => texts(n).join('').includes(help)), 'no help when no lease has a private MAC');
 });
 await check('not connected now', async () => {
  const value = 'aa:bb:cc:dd:ee:ff # phone\n192.168.1.9\n2001:db8::5';
  for (const present of [false, true]) {
   const leases = { dhcp_leases: [lease, ...(present ? [{ ipaddr: '192.168.1.9' }] : [])] };
   const p = picker(setup(), leases, value);
   const notes = collect(p.p).filter(n => !n.hidden && typeof n.textContent === 'string' && n.textContent.startsWith('Not connected now:'));
   h.assertEq(notes.map(n => n.textContent).join(''), present ? '' : 'Not connected now: 192.168.1.9', 'only absent MAC and IPv4 listed');
  }
  const p = picker(setup(), {}, 'aa:bb:cc:dd:ee:ff # phone');
  h.assert(texts(p.p).includes('Not connected now: aa:bb:cc:dd:ee:ff'), 'absence even without leases');
 });
 // C4: the refresh button does not depend on who sets the interval. Own value:
 // next to the field (as in 0.11.0). Provider may own it: a separate row, the
 // button wrapped (themes right-align a field whose direct child is a button).
 // The interval is a setting; the button stays on Lists, wrapped (themes
 // right-align a field whose direct child is a button).
 await check('refresh remote lists button always reachable', async () => {
  const button = (n) => collect(n).find((x) => x.tag === 'button');
  for (const profile of [{}, { provider: { lists_interval: '6' } }]) {
   const t = setup(); await t.render({ ...lists }, profile);
   const o = t.tv.map.options._refresh_lists;
   h.assert(o && t.tv.map.options.lists_interval, 'refresh row without the interval field');
   h.assertEq(o.title, 'Remote lists', 'refresh row title');
   h.assertEq(o.dependencies.length, 0, 'refresh row has no depends');
   const b = o.renderWidget();
   h.assertEq(b.tag, 'div', 'refresh button wrapped'); h.assertEq(texts(button(b)).join(''), 'Update remote lists', 'button label');
  }
  const none = setup(); await none.render({ ...lists, rules: '1.2.3.0/24 core\n' }, {});
  h.assert(!none.tv.map.options._refresh_lists && !none.tv.map.options.lists_interval, 'no links: no refresh row and no interval');
  const shipped = setup(); await shipped.render({ ...lists, rules: '' }, { provider_lists: true });
  h.assert(shipped.tv.map.options._refresh_lists && shipped.tv.map.options.lists_interval, 'provider lists may carry links: refresh row and interval');
  const t = setup({ readOnly: () => true }); await t.render();
  h.assert(!t.tv.map.options._refresh_lists, 'read-only user gets no refresh row');
 });
 await checkSettings('lists interval presets and custom saved value', async () => {
  const t = setup(); await t.render();
  h.assertEq(t.tv.map.options.lists_interval.cfgvalue('settings'), '0', 'unset interval matches backend default');
  t.settings.lists_interval = '5'; await t.render();
  let o = t.tv.map.options.lists_interval;
  h.assertEq(o.tab, null, 'interval on Traffic');
  h.assertEq(JSON.stringify(o.values.map(v => v[0])), '["0","1","3","6","12","24","168","5"]', 'presets plus saved custom');
  h.assertEq(o.values[0][1], 'Off (only manually)', 'manual label');
  h.assertEq(o.cfgvalue('settings'), '5', 'custom survives Save');
  await t.render(lists, { provider: { lists_interval: '6' } });
  o = t.tv.map.options.lists_interval;
  h.assertEq(o.cfgvalue('settings'), 'provider', 'provider interval is the first choice');
  h.assertEq(o.vallist[0], 'From subscription: 6 h', 'provider interval label');
  h.assert(!o.readonly, 'provider interval is changed here');
 });
 await check('update lists job', async () => {
  const t = setup(); const b = t.tv.refreshButton();
  h.assert(b.attrs['data-mw-job'] != null, 'update is a shared job starter');
  await b.listeners.click(); h.assert(t.calls.some(c => c.join(',') === 'job,update-lists'), 'remote list job');
  t.bridge.jobRunning = true; h.assertEq(t.tv.refreshButton().attrs.disabled, true, 'running job disables refresh at render');
  await t.render(); t.saving(); t.bridge.read = async cmd => { h.assertEq(cmd, 'job-status', 'read running operation'); return { op: 'update-lists' }; };
  await t.tv.handleSaveApply(null, '0'); h.assertEq(t.calls.length, 0, 'running jobs do not save');
  h.assertEq(t.notices.at(-1)[0], '"Remote list update" is running…', 'running job label shown');
  t.bridge.read = async () => { throw Error('status unavailable'); };
  await t.tv.handleSaveApply(null, '0'); h.assertEq(t.notices.at(-1)[0], 'status unavailable', 'status read errors visible');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// C16: a read-only LuCI user sees no action buttons.
seq(async () => {
 function DOM(tag, attrs, children) {
  const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null;
  return n;
 }
 const actions = ['Save', 'Update now', 'Save config', 'Restore previous config'];
 for (const readOnly of [false, true]) {
  const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E: DOM, ui, Blob, view: { extend: v => v }, api: { ...api, ...readStubs, readOnly: () => readOnly }
  }).module;
  const p = await mountSubscription(sv, { url: 'https://p.example/sub', config_backup: true }, { content: 'yaml' });
  // The raw configuration (with keys) is for the write role: read-only users get no editor.
  h.assertEq(!!findButton(p, 'Show config editor'), !readOnly, 'editor toggle shown=' + !readOnly);
  if (!readOnly) await openToggle(p, 'Show config editor');
  for (const label of actions) h.assertEq(!!findButton(p, label), !readOnly, label + ' shown=' + !readOnly);
  h.assertEq(collect(p).some(n => n.tag === 'textarea'), !readOnly, 'YAML visible only to the write role, read-only=' + readOnly);
  h.assertEq(reads.calls.includes('read-config'), !readOnly, 'read-only never reads the raw config');
  h.assert(findButton(p, 'Show running config'), 'viewing stays available');
 }
 console.log('ok - subscription read-only hides actions');
}).catch(err => { console.error(err); process.exitCode = 1; });

seq(async () => {
 const check = async (name, fn) => {
  try { await fn(); console.log('ok - subscription ' + name); }
  catch (e) { console.error('not ok - subscription ' + name + ': ' + e.message); process.exitCode = 1; }
 };
 await check('read-only Enter prevents submit without mutations', async () => {
  const calls = [];
  const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E, ui, Blob, view: { extend: v => v },
   api: { ...api, readOnly: () => true, busy: async (button, fn) => fn(),
    write: async (...args) => { calls.push(args); return {}; }, job: async (...args) => { calls.push(args); return {}; }, reloadWithNotice() {} }
  }).module;
  const page = sv.render({ url: 'https://p.example/sub' });
  const input = collect(page).find(n => n.attrs.id === 'mw-url'); input.value = 'https://p.example/sub';
  let prevented = false;
  collect(page).find(n => n.tag === 'form').listeners.submit({ preventDefault() { prevented = true; } });
  await settle();
  h.assert(prevented, 'read-only form prevents navigation');
  h.assertEq(calls.length, 0, 'Enter sends no write/job in read-only mode');
 });
 await check('load-error retry directly reloads without saving an empty notice', async () => {
  let reloads = 0, noticeReloads = 0;
  const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E, ui, view: { extend: v => v }, location: { reload() { reloads++; } },
   api: { ...api, reloadWithNotice() { noticeReloads++; } }
  }).module;
  findButton(sv.render({ error: Error('read failed') }), 'Try again').listeners.click();
  h.assertEq(reloads, 1, 'retry directly reloads');
  h.assertEq(noticeReloads, 0, 'retry does not save an empty notice');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// C16: Overview uses the same read-only check as the other views.
seq(async () => {
 for (const readOnly of [false, true]) {
  const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
   E, poll: { add() {} }, view: { extend: v => v }, api: { ...api, readOnly: () => readOnly }
  }).module;
  for (const running of [false, true]) {
   const p = ov.render([{ ...base, subscription_configured: true, running }, {}, []]);
   for (const label of [running ? 'Stop' : 'Start', 'Restart', 'Update subscription'])
    h.assertEq(!!findButton(p, label), !readOnly, 'overview ' + label + ' shown=' + !readOnly);
   h.assert(texts(p).some(t => t.includes('XrayWRT ')), 'version stays visible');
  }
  const missingCore = ov.render([{ ...base, core_installed: false }, {}, []]);
  h.assertEq(!!findButton(missingCore, 'Install Xray core'), !readOnly, 'install core shown=' + !readOnly);
  const firstRun = ov.render([{ ...base, subscription_configured: false, running: false }, {}, []]);
  h.assertEq(!!findButton(firstRun, 'Connect'), !readOnly, 'connect shown=' + !readOnly);
  const noSubNote = collect(firstRun).find(n => texts(n).includes('Without a subscription XrayWRT starts with the current configuration; by default all traffic goes direct.') && n.attrs.class === 'mw-muted');
  h.assertEq(noSubNote.hidden, readOnly, 'no-subscription Start explanation hidden in read-only mode');
 }
 console.log('ok - overview read-only hides service and core actions');
}).catch(err => { console.error(err); process.exitCode = 1; });

seq(async () => {
 const errors = texts(diag.render([{ ...base, errors: ["Invalid XrayWRT settings [E:settings_invalid]"] }, {}, {}]));
 h.assert(errors.includes('XrayWRT settings are damaged. Save the Advanced page again or reinstall the package.'), 'diagnostics maps status errors');
}).catch(err => { console.error(err); process.exitCode = 1; });

seq(async () => {
 const last_error = "config: no outbounds [E:config_outbounds]";
 const detail = 'The configuration has no outbounds.';
 const status = { ...base, state: 'failed', last_error };
 h.assert(texts(overview.render([status, {}, []])).some(t => t.includes(detail)), 'overview maps backend status error');
 h.assert(texts(diag.render([status, {}, {}])).some(t => t.includes('Last error: ' + detail)), 'diagnostics maps backend status error');
 const raw = "Xray 26.1.1 (Xray, Penetrates Everything.) Custom\nFailed to start: bad proxy\nXray rejected the configuration [E:config_rejected]";
 const headline = 'Xray rejected the configuration.\nFailed to start: bad proxy';
 h.assert(texts(overview.render([{ ...status, last_error: raw }, {}, []])).some(t => t.includes(headline)), 'overview summarizes core rejection');
 h.assert(texts(diag.render([{ ...status, last_error: raw }, {}, {}])).some(t => t.includes('Last error: ' + headline)), 'diagnostics summarizes core rejection');
 const invalid = { ...status, config_valid: false, last_error, config_error: 'Xray 26.1.1 (Xray, Penetrates Everything.)\nraw bad config' };
 h.assert(texts(overview.render([invalid, {}, []])).includes('Details: ' + detail), 'overview prefers mapped last_error to raw config output');
 const rawOnly = overview.render([{ ...invalid, last_error: '' }, {}, []]);
 h.assert(texts(rawOnly).includes('Details: raw bad config'), 'overview extracts error message when only config_error exists');
 h.assert(!texts(rawOnly).some(t => t.includes('Penetrates')), 'overview hides the version banner');
 console.log('ok - status views map backend errors and core rejection');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task 20: diagnostics keeps its checklist while exposing runtime risks.
seq(async () => {
 const check = async (name, fn) => {
  try { await fn(); console.log('ok - diagnostics ' + name); }
  catch (e) { console.error('not ok - diagnostics ' + name + ': ' + e.message); process.exitCode = 1; }
 };
 const healthy = { ...base, state: 'running', running: true, dns_ok: true, policy_active: true };
 const resources = { conflicts: [], flash_free_kb: 5120, ram_available_kb: 20480, xray_rss_kb: 45000, open_proxy_ports: [] };
 const render = (st = healthy, diagnostics = resources) => diag.render([st, {}, diagnostics]);
 const item = (p, label) => collect(p).find(n => n.tag === 'div' && n.children.some(c => c?.tag === 'strong' && texts(c).includes(label)));
 await check('plain-http subscription', () => {
  const label = 'The subscription link uses plain http';
  const hint = 'Anyone on the way can change your configuration. Ask your provider for an https link.';
  const row = item(render({ ...healthy, subscription_insecure: true }), label);
  h.assert(row && texts(row).includes('Problem:'), 'insecure subscription is a problem item');
  h.assert(texts(row).includes(hint), 'insecure subscription hint');
  for (const value of [false, undefined])
   h.assert(!item(render({ ...healthy, subscription_insecure: value }), label), 'no warning without insecure subscription');
  const catalog = require('fs').readFileSync(path.join(process.argv[2], 'po/ru/xraywrt.po'), 'utf8');
  for (const message of [label, hint])
   h.assert(catalog.includes('msgid "' + message + '"\nmsgstr "') && !catalog.includes('msgid "' + message + '"\nmsgstr ""'), 'Russian translation: ' + message);
 });
 await check('subscription row is unknown without a subscription', () => {
  const row = item(render({ ...healthy, subscription_configured: false }), 'No subscription. Using your config.');
  h.assert(row && texts(row).includes('Unknown:') && !texts(row).includes('Problem:'), 'no subscription is not a failed check');
  h.assert(texts(item(render({ ...healthy, subscription_configured: true }), 'Subscription configured')).includes('OK:'), 'subscription present is OK');
 });
 await check('client IPv6 flag effect', () => {
  const value = (st) => { const p = render(st); const t = texts(p); const i = t.indexOf('Block external IPv6 from clients'); return i < 0 ? null : t[i + 1]; };
  h.assertEq(value({ ...healthy, block_client_ipv6: false, mode: 'direct-first' }), 'no', 'flag off');
  h.assertEq(value({ ...healthy, block_client_ipv6: true, mode: 'direct-first' }), 'in effect', 'flag on in direct-first');
  h.assertEq(value({ ...healthy, block_client_ipv6: true, mode: 'proxy-first' }), 'no effect in this mode', 'flag on in proxy-first');
  h.assertEq(value({ ...healthy, mode: 'direct-first' }), 'no', 'old backend without the field');
 });
 await check('failed state', () => {
  const row = item(render({ ...healthy, state: 'failed', last_error: 'x' }), 'XrayWRT is not running');
  h.assert(texts(row).includes('Problem:'), 'failed state overrides stale running boolean');
  h.assert(texts(row).some(t => t.split('\n').includes('Last error: x')), 'last_error in failed hint');
  const stopped = item(render({ ...healthy, state: 'stopped', running: false, last_error: 'x' }), 'XrayWRT is not running');
  h.assert(!texts(stopped).some(t => t.includes('Last error:')), 'no last_error unless failed');
 });
 await check('unknown DNS answer', () => {
  const row = item(render({ ...healthy, dns_ok: null }), 'Xray answers DNS queries');
  h.assert(row && texts(row).includes('Unknown:') && !texts(row).includes('Problem:'), 'null dns_ok is unknown, not a problem');
  h.assert(texts(item(render({ ...healthy, dns_ok: false }), 'Xray does not answer DNS queries')).includes('Problem:'), 'false dns_ok is a problem');
 });
 await check('log read error', async () => {
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', { E, view: { extend: v => v }, api: { ...api,
   readLarge: async () => { throw Object.assign(Error('denied'), { name: 'PermissionError' }); } } }).module;
  const p = dv.render([healthy, {}, resources]);
  collect(p).find(n => n.tag === 'button' && texts(n).includes('Show the log')).listeners.click();
  await new Promise(r => setTimeout(r, 0));
  h.assert(texts(p).includes('Cannot read the log: Access denied. Log in to LuCI again, or ask for write access.'), 'log error uses errorText');
 });
 await check('degraded state', () => {
  const row = item(render({ ...healthy, state: 'degraded' }), 'Xray DNS does not answer: traffic goes direct until it recovers');
  h.assert(row && texts(row).includes('Problem:'), 'degraded service is a failed check');
 });
 await check('starting and stopped states', () => {
  h.assert(texts(render({ ...healthy, state: 'starting' })).includes('Starting…'), 'starting state has neutral wording');
  h.assert(texts(item(render({ ...healthy, state: 'stopped' }), 'XrayWRT is not running')).includes('Problem:'), 'stopped state is not running');
 });
 await check('conflicts', () => {
  const row = item(render(healthy, { ...resources, conflicts: ['podkop'] }), 'Other VPN packages are installed: podkop');
  h.assert(texts(row).includes('Problem:'), 'conflicting package is a failure');
  h.assert(texts(row).includes('These packages also change DNS and the firewall. Use only one VPN package at a time.'), 'conflict hint');
  h.assert(!texts(render()).some(t => t.startsWith('Other VPN packages')), 'no conflict item for empty list');
 });
 await check('resources', () => {
  const p = render(healthy, { ...resources, flash_free_kb: 4000, ram_available_kb: 15000 });
  h.assert(texts(p).includes('Little free flash: 3 MB'), 'flash floor MB');
  h.assert(texts(p).includes('Little free memory: 14 MB'), 'memory floor MB');
  h.assert(texts(p).includes('Xray may be stopped by the system when memory runs out. Stop other services or use a smaller configuration.'), 'memory hint');
  h.assert(texts(p).includes('Xray memory') && texts(p).includes('44 MB'), 'RSS detail rounds to MB');
 });
 await check('resource thresholds and unknowns', () => {
  for (const value of [null, undefined, 5120]) {
   const p = render(healthy, { ...resources, flash_free_kb: value, ram_available_kb: value == 5120 ? 20480 : value, xray_rss_kb: null });
   h.assert(!texts(p).some(t => t.startsWith('Little free')), 'no false low resource warning');
   h.assert(!texts(p).includes('0 MB'), 'unknown RSS not zero');
  }
  h.assert(texts(render(healthy, { ...resources, flash_free_kb: 0 })).includes('Little free flash: 0 MB'), 'zero flash is low');
 });
 await check('list entry summary', () => {
  h.assert(!texts(render()).includes('List entries'), 'raw source-line totals are not presented as effective entries');
 });
 await check('temporary storage', () => {
  const values = texts(render(healthy, { ...resources, tmp_xraywrt_kb: 2560, tmp_free_kb: 6399 }));
  const size = 'XrayWRT temporary files (runtime config, downloads)';
  const free = 'Free temporary storage';
  h.assertEq(values[values.indexOf(size) + 1], '2.5 MB', 'temporary files use byte formatter');
  h.assert(!values.includes(free), 'free tmpfs row removed');
  const small = texts(render(healthy, { ...resources, tmp_xraywrt_kb: 12 }));
  h.assertEq(small[small.indexOf(size) + 1], '12.0 KB', 'small temporary files are not zero MB');
  h.assert(!texts(render(healthy, { ...resources, tmp_xraywrt_kb: null, tmp_free_kb: null })).includes(size), 'unknown sizes absent');
  const zero = texts(render(healthy, { ...resources, tmp_xraywrt_kb: 0, tmp_free_kb: 0 }));
  h.assertEq(zero[zero.indexOf(size) + 1], '0 B', 'empty directory is zero');
 });
 await check('no proxy port warning (the generator keeps only loopback inbounds)', () => {
  h.assert(!texts(render(healthy, { ...resources, open_proxy_ports: [7890] })).some(t => t.includes('7890')), 'no open ports item');
 });
 await check('last configuration check', () => {
  h.assert(texts(render(healthy, { ...resources, config_test: { valid: null, output: [] } })).includes('Xray checks the config at startup.'), 'unchecked');
  h.assert(texts(render(healthy, { ...resources, config_test: { valid: true, output: [] } })).includes('Xray accepted the config.'), 'accepted');
  const bad = render(healthy, { ...resources, config_test: { valid: false, output: ['Failed to start: x', 'line 2'] } });
  h.assert(texts(bad).includes('Xray rejected the config:') && texts(bad).includes('Failed to start: x\nline 2'), 'run -test output shown');
 });
 await check('diagnostics read and partial failure', async () => {
  const calls = [];
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', { E, view: { extend: v => v }, api: { ...api,
   read: async (...args) => { calls.push(args); if (args[0] === 'diagnostics-json') throw Error('Access denied'); return args[0] === 'status-json' ? healthy : {}; }
  } }).module;
  const data = await dv.load(); const p = dv.render(data);
  h.assert(calls.some(c => c.length === 1 && c[0] === 'diagnostics-json'), 'diagnostics-json without args');
  h.assert(calls.some(c => c[0] === 'profile-json' && c[1] === '--compact'), 'Help requests compact profile');
  h.assert(texts(p).includes('Service is running') && texts(p).includes('Details'), 'rest remains usable');
  h.assert(texts(p).some(t => t.includes('Cannot load diagnostics: Access denied. Log in to LuCI again, or ask for write access.')), 'partial failure cause uses errorText');
  h.assert(texts(p).includes('Reload the page to try again.'), 'partial failure retry hint');
 });
 await check('large log and job notice', async () => {
  const calls = []; let notices = 0;
  const dv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', { E, view: { extend: v => v }, api: { ...api,
   readLarge: async (...args) => { calls.push(args); return { available: true, lines: ['hello'] }; },
   jobNotice: () => { notices++; return E('div', { 'aria-live': 'polite' }); }
  } }).module;
  const p = dv.render([healthy, {}, resources]);
  h.assertEq(notices, 1, 'shared job notice included');
  h.assertEq(calls.length, 0, 'log remains lazy');
  collect(p).find(n => n.tag === 'button' && texts(n).includes('Show the log')).listeners.click();
  await Promise.resolve();
  h.assertEq(calls.map(c => c.join(',')).join(';'), 'logs-json,300', 'log through readLarge');
  h.assert(texts(p).includes('hello'), 'loaded log shown');
 });
 await check('R14 summary line and negative labels and hints', () => {
  const pHealthy = render(healthy);
  h.assert(texts(pHealthy).includes('No problems found.'), 'summary shows no problems when healthy');

  const pStopped = render({ ...healthy, state: 'stopped', running: false });
  h.assert(texts(pStopped).includes('1 problem found. Start with the first one.'), 'summary shows 1 problem');
  const pMultiple = render({ ...healthy, state: 'stopped', running: false, core_installed: false });
  h.assert(texts(pMultiple).includes('2 problems found. Start with the first one.'), 'summary shows multiple problems');

  const coreMissing = item(pMultiple, 'Xray core is not installed');
  h.assert(coreMissing && texts(coreMissing).includes('Problem:'), 'negative label for core missing');
  const configRowWithoutCore = item(pMultiple, 'Config will be checked at startup');
  h.assert(configRowWithoutCore && texts(configRowWithoutCore).includes('Unknown:'), 'config unknown without core');

  const stoppedRow = item(pStopped, 'XrayWRT is not running');
  h.assert(stoppedRow && texts(stoppedRow).includes('Problem:'), 'negative label for stopped service');

  const pDnsFail = render({ ...healthy, dns_ok: false });
  const dnsRow = item(pDnsFail, 'Xray does not answer DNS queries');
  h.assert(dnsRow && texts(dnsRow).includes('Problem:'), 'negative label for failed DNS');

  const pPolicyFail = render({ ...healthy, policy_active: false });
  const policyRow = item(pPolicyFail, 'Traffic rules are not active');
  h.assert(policyRow && texts(policyRow).includes('Problem:'), 'negative label for inactive policy');

  h.assert(texts(stoppedRow).includes('Press Start on Home.'), 'stopped hint is press start');
  const pCoreMissing = render({ ...healthy, state: 'stopped', running: false, core_installed: false });
  h.assert(texts(item(pCoreMissing, 'XrayWRT is not running')).includes('Install the Xray core first (Updates page).'), 'core missing hint');
  const pConfigBad = render({ ...healthy, state: 'failed', core_installed: true, config_valid: false });
  h.assert(texts(item(pConfigBad, 'XrayWRT is not running')).includes('Fix the config, then press Start on Home.'), 'config invalid hint');
 });
 await check('R40 subscription improvements', async () => {
  const windowListeners = {}, windowRemoved = {};
  const mockWindow = {
   addEventListener(event, fn) { windowListeners[event] = fn; },
   removeEventListener(event, fn) { windowRemoved[event] = fn; delete windowListeners[event]; }
  };
  function DOM(tag, attrs, children) {
   const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null;
   n.replaceChildren = (...nodes) => { n.children = nodes; };
   return n;
  }
  let reloads = 0;
  const mockApi = {
   ...api, ...readStubs, jobRunning: false,
   read: async (cmd) => {
    if (cmd === 'subscription-json') throw new Error('sub read failed');
    return {};
   },
   readLarge: async () => ({ content: 'yaml: test' }),
   upload: async () => '/tmp/cfg',
   job: async () => ({ action: 'saved' }),
   reloadWithNotice: () => { reloads++; }
  };
  const sv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E: DOM, ui, Blob, api: mockApi, view: { extend: v => v }, window: mockWindow,
   location: { reload: () => { reloads++; } }
  }).module;

  const errData = await sv.load();
  const errPage = sv.render(errData);
  h.assert(texts(errPage).some(t => t.includes('Cannot load subscription settings: sub read failed')), 'load error shows alert');
  const retryBtn = collect(errPage).find(n => n.tag === 'button' && texts(n).includes('Try again'));
  h.assert(retryBtn, 'load error has retry button');
  retryBtn.listeners.click();
  h.assertEq(reloads, 1, 'retry button reloads');

  const svOk = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
   E: DOM, ui, Blob, view: { extend: v => v }, window: mockWindow,
   api: { ...mockApi, read: async () => ({ url: 'https://sub.example', auto_update: true, header_interval: 12 }) },
   location: { reload: () => { reloads++; } }
  }).module;
  const page = svOk.render(await svOk.load());

  h.assert(collect(page).some(n => n.attrs.class === 'alert-message warning' && texts(n).includes('Subscription updates, including automatic ones, replace your edits.')), 'overwrite note is alert-message warning');

  const formNode = collect(page).find(n => n.tag === 'form');
  h.assert(formNode, 'form wraps URL input');
  const urlInput = collect(formNode).find(n => n.attrs.id === 'mw-url');
  h.assert(urlInput, 'url input is inside form');
  let prevented = false;
  formNode.listeners.submit({ preventDefault: () => { prevented = true; } });
  h.assert(prevented, 'form submit calls preventDefault');

  urlInput.value = '';
  ui.activeModal = null;
  const disablePending = findButton(page, 'Save').listeners.click();
  h.assert(ui.activeModal && ui.activeModal.title === 'Stop using the subscription?', 'modal shown on empty URL save');
  h.assert(texts(ui.activeModal.children).includes('XrayWRT keeps the current configuration, but it will no longer be updated.'), 'modal description');

  await disablePending;
  h.assert(windowListeners.beforeunload, 'beforeunload listener registered');
  const fakeEvent = { preventDefault() { this.defaultPrevented = true; } };
  windowListeners.beforeunload(fakeEvent);
  h.assert(!fakeEvent.defaultPrevented, 'no beforeunload block without edits');
 });
}).catch(err => { console.error(err); process.exitCode = 1; });

// A14.2: Overview state, profile, core and profile warnings (spec 15).
seq(async () => {
 const sets = [], applies = [];
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, poll: { add() {} }, view: { extend: v => v },
  uci: { set: (...args) => sets.push(args), save: async () => sets.push(['save']) },
  ui: { ...ui, changes: { apply: checked => applies.push(checked) } },
  api: { ...api, busy: (b, fn) => fn() }
 }).module;
 const st = { ...base, subscription_configured: true, running: true, state: 'running',
  profile: { name: 'Fast', selected: 'Main' }, core_source: { source: 'channel', channel: 'Jolymmiles/Xray-core', tag: 'v26.11.1' },
  warnings: ["profile \"Fast\" not found, using \"Main\" [E:profile_missing|Fast|Main]", "ignored invalid or unknown setting 'foo' [E:setting_ignored|foo]", "direct-first has no fake-IP domains: only proxy IP lists are intercepted [E:direct_no_domains]", 'fake_domains.txt: bad line', "no proxy DNS configured, using WAN DNS [E:dns_wan]",
  'inbound tun-in (tun) removed: the router uses TPROXY [E:inbound_tun|tun-in]', "fakedns section replaced [E:fakedns_replaced]", "outbound \"proxy\" mark 255 replaced with 1 [E:outbound_mark|proxy|255|1]", "dns tag \"dns-in\" renamed to xraywrt-dns-internal [E:dns_tag|dns-in|xraywrt-dns-internal]",
  "My rules: line 4 \"bad domain\" ignored [E:rule_ignored|4|bad domain]", "My rules has more than 10000 sites, the rest is ignored [E:rules_limit|10000]",
  "My rules: the targets gone are not in the configuration, their lines are skipped [E:rules_target_missing|gone]",
  "geodata own.dat: the subscription already has a file with this name, rename yours [E:geodata_collision|own.dat]",
  "geodata own.dat: duplicate file name, entry skipped [E:geodata_duplicate|own.dat]",
  "geodata asset: invalid entry, expected NAME.dat=https://URL [E:geodata_entry]",
  "geodata cron: invalid schedule, using 0 5 * * * [E:geodata_cron]", 'something new from a later version'] };
 const p = ov.render([st, {}, ['Main', 'Backup']]);
 const t = texts(p);
 h.assert(t.includes('Mode: Only selected sites via VPN'), 'mode shown');
 h.assert(!t.includes('Core source') && t.includes('Version 0.8.0 · core v1.19.32'), 'Home shows the core version, not its source');
 for (const w of ['Server "Fast" is not in the configuration; "Main" is used.', 'The subscription setting "foo" is unknown or invalid and was ignored.',
  'In the "Only selected sites via VPN" mode no sites are chosen: only the addresses of the subscription and of My rules go via VPN. Add sites to My rules on the What goes via VPN page.', 'fake_domains.txt: bad line',
  'No VPN DNS is configured: the DNS servers of the internet connection (WAN) are used directly.',
  'Inbound tun-in (tun) was removed: the router uses TPROXY.',
  'The "fakedns" section of the configuration is replaced by the one XrayWRT generates.',
  'The outbound "proxy" had the mark 255; XrayWRT replaced it with 1.',
  'The DNS tag "dns-in" is renamed to xraywrt-dns-internal in the routing rules.',
  'Line 4 of My rules ("bad domain") is not valid and was ignored.',
  'My rules has more than 10000 sites; the rest is ignored.',
  'These targets of My rules are not in the configuration, so the lines that name them are skipped: gone.',
  'Geodata file own.dat is already supplied by the subscription. Rename your file.',
  'Geodata file own.dat is listed more than once; the duplicate was skipped.',
  'A geodata link was skipped: use NAME.dat and an HTTPS URL without spaces.',
  'The geodata schedule is invalid; 0 5 * * * is used.',
  'something new from a later version'])
  h.assert(t.includes(w), 'warning: ' + w);
 const select = collect(p).find(n => n.attrs.id === 'mw-profile');
 h.assertEq(select.value, 'Main', 'profile dropdown shows the used profile');
 const collision = collect(ov.render([{ ...st, profile: { name: 'A\tB', selected: 'A B' } }, {}, ['A\tB', 'A B']])).find(n => n.attrs.id === 'mw-profile');
 h.assertEq(collision.value, 'A\tB', 'profile dropdown uses original identity despite display collision');
 h.assertEq(collect(collision).find(n => n.tag === 'option' && n.attrs.selected === '').attrs.value, 'A\tB', 'original option is selected');
 const rejected = collect(ov.render([{ ...st, profile: { name: 'B\nX', selected: 'A' } }, {}, ['A', 'B\nX']])).find(n => n.attrs.id === 'mw-profile');
 h.assertEq(rejected.value, 'A', 'rejected profile choice shows the running profile');
 h.assertEq(collect(select).filter(n => n.tag === 'option').length, 2, 'profiles from the backend');
 h.assert(collect(p).some(n => n.tag === 'label' && n.attrs.for === 'mw-profile'), 'profile dropdown labelled');
 select.value = 'Backup'; await select.listeners.change(); await settle();
 h.assertEq(JSON.stringify(sets), '[["xraywrt","settings","profile","Backup"],["save"]]', 'profile saved to UCI');
 h.assertEq(JSON.stringify(applies), '[true]', 'Save & Apply reloads XrayWRT with the profile');
 sets.length = 0;
 const pSub = ov.render([st, { active: 's1234' }, ['Main', 'Backup']]), selectSub = collect(pSub).find(n => n.attrs.id === 'mw-profile');
 selectSub.value = 'Backup'; await selectSub.listeners.change(); await settle();
 h.assertEq(JSON.stringify(sets), '[["xraywrt","s1234","profile","Backup"],["save"]]', 'the server is saved in the active subscription');
 ui.autoConfirm = false; sets.length = 0;
 const p2 = ov.render([st, {}, ['Main', 'Backup']]), select2 = collect(p2).find(n => n.attrs.id === 'mw-profile');
 select2.value = 'Backup'; await select2.listeners.change(); await settle();
 h.assertEq(sets.length, 0, 'cancelled profile change saves nothing'); h.assertEq(select2.value, 'Main', 'selection restored');
 ui.autoConfirm = true;
 h.assert(!collect(ov.render([st, {}, ['Main']])).some(n => n.attrs.id === 'mw-profile'), 'no dropdown for a single profile');
 h.assert(!collect(ov.render([{ ...st, warnings: [] }, {}, []])).some(n => texts(n).includes('Configuration warnings')), 'no empty warnings box');
 const ro = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', { E, poll: { add() {} }, view: { extend: v => v }, uci: {}, api: { ...api, readOnly: () => true } }).module;
 h.assertEq(collect(ro.render([st, {}, ['Main', 'Backup']])).find(n => n.attrs.id === 'mw-profile').attrs.disabled, true, 'read-only profile dropdown');
 const reads = [];
 const loader = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', { E, poll: { add() {} }, view: { extend: v => v }, uci: {},
  api: { ...api, read: async cmd => { reads.push(cmd); if (cmd === 'profiles') throw Error('x'); return {}; } } }).module;
 h.assertEq(JSON.stringify((await loader.load())[2]), '[]', 'profiles failure keeps the page');
 h.assertEq(reads.join(','), 'status-json,subscription-json,profiles', 'overview first render reads no balancers');
 h.assert(!/server selection|proxies-json|delay|dashboard/i.test(h.readSource('rootfs/www/luci-static/resources/view/xraywrt/overview.js')), 'no Mihomo server selection');
 console.log('ok - overview profile, core, mode and warnings');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Task set 2: immediate themed checkbox and pretty JSON keep dirty guard clean.
seq(async () => {
 function DOM(tag, attrs, children) { const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null; return n; }
 const calls = [], notes = []; let guard, reject = false;
 const v = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, view: { extend: v => v }, window: { addEventListener: (event, fn) => { guard = fn; }, removeEventListener() {} },
  api: { ...api, ...readStubs, busy: async (el, fn) => { try { await fn(); } catch {} },
   write: async (...args) => { calls.push(args); if (reject) throw Error('failed'); }, notify: msg => notes.push(msg) }
 }).module;
 const raw = '{"outbounds":[{"protocol":"freedom"}]}', pretty = JSON.stringify(JSON.parse(raw), null, 2);
 const p = await mountSubscription(v, { url: 'https://saved.example', auto_update: false }, { content: raw });
 const checkbox = collect(p).find(n => n.attrs.id === 'mw-auto');
 h.assert(collect(p).some(n => n.attrs.class === 'cbi-checkbox' && collect(n).includes(checkbox)), 'theme checkbox markup');
 collect(p).find(n => n.attrs.id === 'mw-url').value = 'https://unsaved.example';
 checkbox.checked = true; await checkbox.listeners.change();
 h.assertEq(JSON.stringify(calls), JSON.stringify([['set-subscription', 'https://saved.example', '1']]), 'toggle saves saved URL immediately');
 h.assertEq(notes.at(-1), 'Subscription settings saved.', 'toggle save notice');
 reject = true; checkbox.checked = false; await checkbox.listeners.change();
 h.assertEq(checkbox.checked, true, 'failed toggle restored'); reject = false;
 await openToggle(p, 'Show config editor');
 h.assertEq(collect(p).find(n => n.tag === 'textarea').value, pretty, 'one-line JSON is pretty-printed on open');
 let dirty = false; guard({ preventDefault() { dirty = true; } }); h.assert(!dirty, 'pretty-printed text is clean');
 // Large integers and key order survive; saving unchanged text does nothing.
 const exact = '{"b":1,"a":12345678901234567890123,"outbounds":[]}';
 const q = await mountSubscription(v, { url: '' }, { content: exact });
 await openToggle(q, 'Show config editor');
 const area = collect(q).find(n => n.tag === 'textarea');
 h.assertEq(area.value, exact, 'large integer and key order kept');
 calls.length = 0; notes.length = 0;
 await findButton(q, 'Save config').listeners.click(); await settle();
 h.assertEq(calls.length, 0, 'unchanged text is not saved'); h.assertEq(notes.at(-1), 'Configuration is unchanged.', 'unchanged notice');
 // Multi-line text is shown as stored; a CRLF config opened and saved untouched is unchanged.
 for (const stored of ['{\n"a":1}', '{\r\n  "a": 1\r\n}\r\n']) {
  const m = await mountSubscription(v, { url: '' }, { content: stored });
  await openToggle(m, 'Show config editor');
  h.assertEq(collect(m).find(n => n.tag === 'textarea').value, stored.replace(/\r\n/g, '\n'), 'multi-line text shown as stored');
  const guardEvent = { preventDefault() { this.prevented = true; } }; guard(guardEvent);
  h.assert(!guardEvent.prevented, 'untouched multi-line text is clean');
  calls.length = 0; notes.length = 0;
  await findButton(m, 'Save config').listeners.click(); await settle();
  h.assertEq(calls.length, 0, 'untouched multi-line text is not saved'); h.assertEq(notes.at(-1), 'Configuration is unchanged.', 'untouched multi-line notice');
 }
 reads.responses['runtime-config'] = { content: raw };
 await openToggle(p, 'Show running config');
 h.assertEq(collect(p).filter(n => n.tag === 'textarea')[1].value, pretty, 'runtime pretty JSON');
 const blank = await mountSubscription(v, { url: '' });
 h.assertEq(collect(blank).find(n => n.attrs.id === 'mw-auto').attrs.disabled, true, 'toggle disabled without saved URL');
 h.assert(!collect(overview.render([base, {}, []])).some(n => n.tag === 'a' && texts(n).includes('Updates')), 'Home has no update block');
 console.log('ok - immediate checkbox and pretty JSON');
}).catch(err => { console.error(err); process.exitCode = 1; });

// A14.4: Config page Validate (config-check) shows Xray's error.
seq(async () => {
 function DOM(tag, attrs, children) { const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null; return n; }
 let checkReply = { ok: false, error: 'Xray rejected the configuration [E:config_rejected]', output: 'Xray 26 (Xray, x)\nFailed to start: bad outbound' };
 const calls = [];
 const cv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', {
  E: DOM, ui, Blob, view: { extend: v => v },
  api: { ...api, ...readStubs, busy: async (b, fn) => fn(), upload: async (prefix, content) => { calls.push(['upload', prefix, content]); return '/tmp/xraywrt-config.v'; },
   configCheck: async path => { calls.push(['check', path]); return checkReply; }, job: async (...a) => { calls.push(a); return {}; } }
 }).module;
 const p = await mountSubscription(cv, { url: '' }, { content: '{"outbounds":[]}' });
 await openToggle(p, 'Show config editor');
 collect(p).find(n => n.tag === 'textarea').value = '{"outbounds":[{}]}';
 await findButton(p, 'Validate').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["upload","xraywrt-config","{\\"outbounds\\":[{}]}"],["check","/tmp/xraywrt-config.v"]]', 'Validate checks the edited text without installing');
 const result = collect(p).find(n => n.attrs['aria-live'] === 'polite' && collect(n).some(c => c.attrs?.role === 'alert'));
 h.assert(result && texts(result).includes('Xray rejected the configuration.') && texts(result).includes('Failed to start: bad outbound'), 'Xray error shown in a live region');
 checkReply = { ok: true, error: null, output: null };
 await findButton(p, 'Validate').listeners.click(); await settle();
 h.assert(texts(p).includes('The configuration is valid: Xray accepts it.'), 'valid result');
 h.assertEq(reads.calls.filter(c => c === 'runtime-config').length, 0, 'runtime view stays lazy');
 const ro = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', { E: DOM, ui, Blob, view: { extend: v => v }, api: { ...api, ...readStubs, readOnly: () => true } }).module;
 const rp = await mountSubscription(ro, { url: '' }, { content: '{}' });
 h.assert(!findButton(rp, 'Show config editor') && !findButton(rp, 'Validate'), 'read-only user has no editor and cannot run config-check');
 console.log('ok - config Validate');
}).catch(err => { console.error(err); process.exitCode = 1; });

// A14.5: Updates page: version only (no channel field or presets), Check/Update/Upload, --no-rollback, space, geodata.
seq(async () => {
 function DOM(tag, attrs, children) { const n = E(tag, attrs, children); n.value = n.attrs.value || ''; n.checked = n.attrs.checked != null; return n; }
 const calls = [], notices = [], uciCalls = [];
 let uploads = 0, jobError = null;
 let checkReply = { installed: {}, latest: { tag: 'v26.12.1', size: 30 * 1048576 }, update_available: true, channel_changed: true, error: null };
 const bridge = { ...api, busy: async (b, fn) => { try { return await fn(); } catch (e) { notices.push('error:' + e.message); } },
  coreCheck: async () => { calls.push(['check']); return checkReply; },
  upload: async (prefix, file) => { calls.push(['upload', prefix, file.name]); return '/tmp/' + prefix + '.' + (++uploads); },
  job: async (...a) => { calls.push(a); if (jobError && a[0] === 'core-update' && !a.includes('--no-rollback')) throw Object.assign(new Error(jobError), { name: 'JobError' }); return { updated: true, version: 'v26.12.1', restarted: true }; },
  reloadWithNotice: m => notices.push(m), notify: (m, l) => notices.push((l || 'info') + ':' + m) };
 const uci = { load: async () => {}, get: () => undefined, set: (...a) => uciCalls.push(['set', ...a]), unset: (...a) => uciCalls.push(['unset', ...a]), save: async () => uciCalls.push(['save']) };
 const coreUi = { ...ui, changes: { apply: async checked => uciCalls.push(['apply', checked]) } };
 const cv = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/updates.js', { E: DOM, ui: coreUi, uci, view: { extend: v => v }, api: bridge }).module;
 const st = { ...base, core: '26.11.1', core_source: { source: 'file' }, core_channel: { current: 'Jolymmiles/Xray-core', default: 'Jolymmiles/Xray-core' },
  geodata: [{ file: 'geosite.dat', asset: true, referenced: true, present: true, size: 2048, mtime: 1700000000 }, { file: 'ext.dat', asset: false, referenced: true, present: false, size: null, mtime: null }] };
 const render = (diag = { flash_free_kb: 20 * 1024, ram_available_kb: 100 * 1024 }) => cv.render([st, diag]);
 let p = render();
 h.assert(texts(p).includes('By link') && texts(p).includes('From a file'), 'geodata links and upload are on Updates');
 h.assert(!collect(p).some(n => n.attrs.id === 'mw-channel' || (n.tag === 'select' && n.attrs.id !== 'mw-geodata-cron')), 'no channel field or presets on the Updates page');
 h.assert(!texts(p).some(t => /Presets|zip only/.test(t)), 'no preset texts');
 h.assert(texts(p).includes('Core version') && texts(p).includes('26.11.1') && texts(p).includes('—'), 'installed core version; an old file source shows a dash');
 // One grid: version, source, free flash/RAM share the value column and the row gap.
 const coreGrids = () => collect(p).filter(n => /\bmw-grid\b/.test(n.attrs.class || ''));
 h.assertEq(coreGrids().length, 1, 'core facts in a single aligned grid');
 h.assert(['Core version', 'Core source'].every(t => texts(coreGrids()[0]).includes(t)) && !['Free flash', 'Free memory'].some(t => texts(coreGrids()[0]).includes(t)), 'only version and source rows in that grid');
 await findButton(p, 'Check for updates').listeners.click(); await settle();
 h.assertEq(uciCalls.length, 0, 'Updates page writes no UCI');
 h.assert(texts(p).includes('A new core is available: v26.12.1.'), 'latest tag shown');
 h.assert(!h.readSource('rootfs/www/luci-static/resources/view/xraywrt/updates.js').includes('Checking…'), 'progress only on the busy button, not a second line');
 h.assert(!texts(p).some(t => /another channel/.test(t)), 'no channel selection advice');
 h.assert(!texts(p).includes('flash 34 MB, memory 46 MB'), 'compressed APK size is not installed size');
 h.assert(!texts(p).includes('Installed size is checked on the router before installation.'), 'redundant installed-size note removed');
 h.assert(!texts(p).includes('Little free flash: the update removes the current core first and stops XrayWRT while the core is replaced.'), 'compressed size cannot predict flash replacement');
 h.assert(!texts(p).includes('Free flash') && !texts(p).includes('Free memory'), 'resource rows absent');
 // Same version as the file-installed core: not "a new core".
 checkReply = { installed: { source: 'file', channel: null, tag: null }, xray_version: '26.11.1-1424', latest: { tag: 'v26.11.1-1424', size: 30 * 1048576 }, update_available: true, channel_changed: false, error: null };
 await findButton(p, 'Check for updates').listeners.click(); await settle();
 h.assert(texts(p).includes('A new core is available: v26.11.1-1424.'), 'package migration available even when compatibility version matches');
 h.assertEq(coreGrids().length, 1, 'still one grid after the check');
 checkReply = { latest: { tag: null, size: null }, error: 'cannot reach GitHub (API: network) [E:core_download|cannot reach GitHub (API: network)]' };
 await findButton(p, 'Check for updates').listeners.click(); await settle();
 h.assert(texts(p).some(t => t.startsWith('Could not download the Xray core from GitHub.')), 'check error mapped');
 // Spec 4.4/15: Update = core-check, then core-update only when update_available.
 p = render(); calls.length = 0; uciCalls.length = 0;
 checkReply = { installed: {}, latest: { tag: 'v26.12.1', size: 30 * 1048576 }, update_available: true, channel_changed: false, error: null };
 await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"]]', 'check, then the update job'); h.assertEq(uciCalls.length, 0, 'Update writes no UCI');
 h.assertEq(notices.at(-1), 'Xray core updated to v26.12.1; XrayWRT restarted.', 'update notice');
 checkReply = { installed: {}, latest: { tag: 'v26.12.1', size: null }, update_available: false, channel_changed: false, error: null };
 calls.length = 0; await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"]]', 'no update job without an update');
 h.assertEq(notices.at(-1), 'info:No update available.', 'no update message');
 checkReply = { installed: {}, latest: { tag: null }, update_available: false, error: 'the core does not run on this router [E:core_binary]' };
 calls.length = 0; await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"]]', 'no update job after a check error');
 h.assertEq(notices.at(-1), 'error:The core file does not run on this router. The current core is kept.', 'check error shown');
 checkReply = { installed: {}, latest: { tag: 'v26.12.1', size: 30 * 1048576 }, update_available: true, channel_changed: false, error: null };
 h.assert(!collect(p).some(n => n.attrs.id === 'mw-no-rollback') && !texts(p).some(t => /backup copy/.test(t)), 'no backup-copy checkbox on the page');
 // A normal update asks the normal question and never sends the flag.
 ui.modalCalls.length = 0; calls.length = 0; uploads = 0;
 await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"]]', 'normal update has no --no-rollback');
 h.assertEq(JSON.stringify(ui.modalCalls.map(m => m.title)), '["Update the core"]', 'one normal confirm');
 const press = label => collect(E('div', {}, ui.activeModal.children)).find(n => n.tag === 'button' && texts(n).includes(label)).listeners.click();
 const ramError = 'not enough RAM for a rollback copy of the old core: need 40 MiB, available 30 MiB; --no-rollback installs without it';
 const ramJobError = api.errorText('Core update: ' + ramError + ' [E:core_rollback_ram|' + ramError + ']');
 jobError = ramJobError;
 // No backup possible: ask, then rerun with the flag.
 ui.modalCalls.length = 0; calls.length = 0; notices.length = 0;
 await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"],["core-update","--no-rollback"]]', 'confirmed: rerun without a backup copy');
 h.assertEq(JSON.stringify(ui.modalCalls.map(m => m.title)), '["Update the core","Update without a backup copy?"]', 'normal confirm first, then the danger confirm');
 h.assert(collect(ui.modalCalls.at(-1).children).some(n => n.tag === 'button' && /cbi-button-negative/.test(n.attrs.class)), 'no-backup confirm is destructive');
 h.assert(texts(E('div', {}, ui.modalCalls.at(-1).children)).some(t => t.startsWith('Not enough free memory for a backup copy of the current core.') && t.includes('If the new core does not start, there is no working core')), 'danger body: the reason, then the consequence');
 h.assertEq(notices.at(-1), 'Xray core updated to v26.12.1; XrayWRT restarted.', 'retry result shown');
 // Cancelled: the first error as usual, no second job.
 ui.autoConfirm = null; ui.modalCalls.length = 0; calls.length = 0; notices.length = 0;
 let pending = findButton(p, 'Update the core').listeners.click(); await settle();
 await press('Update'); await settle(); await settle();
 h.assertEq(ui.activeModal?.title, 'Update without a backup copy?', 'danger confirm is open');
 await press('Cancel'); await pending;
 ui.autoConfirm = true;
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"]]', 'cancelled: no second job');
 h.assert(notices.at(-1).startsWith('error:Not enough free memory for a backup copy of the current core.'), 'cancelled: the original error is shown');
 // Another failure: no modal, only the error.
 jobError = api.errorText('Core update: new binary does not run on this router [E:core_binary]');
 ui.modalCalls.length = 0; calls.length = 0; notices.length = 0;
 await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"]]', 'other failure: no second job');
 h.assertEq(JSON.stringify(ui.modalCalls.map(m => m.title)), '["Update the core"]', 'other failure: no danger confirm');
 h.assertEq(notices.at(-1), 'error:The core file does not run on this router. The current core is kept.', 'other failure: error shown');
 // The old package cannot be fetched: same suffix, no error code.
 jobError = api.errorText('Core update: cannot download the installed package xraywrt-core-1.apk for a rollback (http_404); --no-rollback installs without it');
 calls.length = 0; ui.modalCalls.length = 0;
 await findButton(p, 'Update the core').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["check"],["core-update"],["core-update","--no-rollback"]]', 'uncoded suffix text also asks');
 jobError = null;
 h.assert(!collect(p).find(n => n.attrs.id === 'mw-core-file') && !findButton(p, 'Install from file'), 'no core file install');
 // Geodata table and actions.
 const rows = collect(collect(p).find(n => n.tag === 'table')).filter(n => n.tag === 'tr');
 h.assertEq(rows.length, 3, 'header and two geodata files');
 h.assert(texts(rows[1]).includes('geosite.dat') && texts(rows[1]).includes('2.0 KB') && texts(rows[1]).includes('yes'), 'present asset row');
 h.assert(texts(rows[2]).includes('ext.dat') && texts(rows[2]).includes('no'), 'missing reference row');
 calls.length = 0; await findButton(p, 'Update rule databases').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["geodata-update","--force"]]', 'forced geodata update');
 const geoFile = collect(p).find(n => n.attrs.id === 'mw-geo-file'), geoName = collect(p).find(n => n.attrs.id === 'mw-geo-name');
 geoFile.files = [{ name: 'ext.dat', size: 10 }]; geoName.value = '';
 // Closing a confirmation without resolving it must never hold the job lock.
 const oldConfirm = bridge.confirm, oldBusy = bridge.busy; let busyCalls = 0;
 bridge.busy = async (button, fn) => { busyCalls++; return oldBusy(button, fn); };
 bridge.confirm = () => new Promise(() => {});
 findButton(p, 'Upload').listeners.click();
 h.assertEq(busyCalls, 0, 'upload confirmation does not acquire job lock');
 bridge.confirm = oldConfirm; bridge.busy = oldBusy;
 // A real busy operation started while the modal is open must block upload.
 let resumeConfirmation, finishOther, racedUploads = 0; const lockedButtons = [];
 const real = origEvaluate('rootfs/www/luci-static/resources/xraywrt/api.js', {
  E: DOM, ui: coreUi, fs: {}, document: { querySelectorAll: () => lockedButtons }
 }).module;
 Object.assign(real, { confirm: () => new Promise(resolve => { resumeConfirmation = resolve; }),
  upload: async () => { racedUploads++; return '/tmp/unused'; }, readOnly: () => false });
 const realView = origEvaluate('rootfs/www/luci-static/resources/view/xraywrt/updates.js', { E: DOM, ui: coreUi, uci, view: { extend: v => v }, api: real }).module;
 const racePage = realView.render([st, {}]), raceUpload = findButton(racePage, 'Upload');
 collect(racePage).find(n => n.attrs.id === 'mw-geo-file').files = [{ name: 'ext.dat', size: 10 }];
 const other = E('button', { 'data-mw-job': '' }); lockedButtons.push(raceUpload, other);
 const pendingUpload = raceUpload.listeners.click();
 const pendingOther = real.busy(other, () => new Promise(resolve => { finishOther = resolve; }));
 h.assert(raceUpload.disabled, 'other action locks upload while confirmation is open');
 resumeConfirmation(true); await pendingUpload;
 h.assertEq(racedUploads, 0, 'confirmation cannot start upload during another action');
 h.assert(raceUpload.disabled, 'confirmation does not start upload or release the other action');
 finishOther(); await pendingOther;
 h.assert(!raceUpload.disabled, 'upload unlocks after the other action');
 calls.length = 0; uploads = 0; await findButton(p, 'Upload').listeners.click(); await settle();
 h.assertEq(JSON.stringify(calls), '[["upload","xraywrt-geodata","ext.dat"],["geodata-update","--file","/tmp/xraywrt-geodata.1","--name","ext.dat"]]', 'geodata upload with the file name');
 h.assert(texts(E('div', {}, ui.modalCalls.at(-1).children)).some(t => t.includes('cannot be checked now')), 'unverified warning before geodata upload');
 h.assert(texts(E('div', {}, ui.modalCalls.at(-1).children)).some(t => t.includes('unless another required file is still missing')), 'confirm explains incomplete-set validation exception');
 geoName.value = '../x.dat'; calls.length = 0; await findButton(p, 'Upload').listeners.click(); await settle();
 h.assertEq(calls.length, 0, 'bad geodata name refused');
 h.assert(texts(cv.render([{ ...st, geodata: [] }, {}])).includes('The configuration uses no rule database files.'), 'empty geodata');
 // User geodata editor (on Updates) validates before touching UCI, then uses LuCI apply.
 const rules = collect(p).find(n => n.attrs.class === 'cbi-section' && collect(n).some(c => c.tag === 'h3' && texts(c).includes('Rule databases')));
 const ownToggles = collect(rules).filter(n => n.attrs.class === 'mw-toggle');
 h.assertEq(ownToggles.length, 1, 'rule databases have one toggle for own files');
 const ownToggle = ownToggles[0];
 h.assertEq(texts(ownToggle.children[0]).join(), 'Add my own rule database', 'own database toggle label');
 h.assert(ownToggle.children[1].hidden === true, 'own databases: collapsed without saved links');
 h.assert(collect(ownToggle).some(n => n.tag === 'table') === false && collect(ownToggle).some(n => n.attrs['aria-label'] === 'File name') === false, 'no link rows yet');
 h.assert(findButton(ownToggle, 'Add file') && findButton(ownToggle, 'Save links') && collect(ownToggle).some(n => n.attrs.id === 'mw-geo-file') && collect(ownToggle).some(n => n.attrs.id === 'mw-geodata-cron'), 'one block holds the link controls and the file upload');
 const ownTexts = texts(ownToggle);
 h.assert(ownTexts.indexOf('By link') > 0 && ownTexts.indexOf('By link') < ownTexts.indexOf('From a file'), 'intro, then By link, then From a file');
 h.assert(ownTexts.some(t => t.startsWith('For a .dat file the subscription does not supply.')), 'one intro line');
 const editor = ownToggle.children[1];
 h.assert(!collect(editor).some(n => n.tag === 'table'), 'no empty table header without rows');
 h.assert(collect(editor).some(n => /\bmw-row\b/.test(n.attrs.class || '') && collect(n).includes(findButton(editor, 'Add file'))), 'Add file sits in an mw-row');
 await findButton(editor, 'Add file').click();
 h.assert(collect(editor).some(n => n.tag === 'table'), 'table appears with the first row');
 let inputs = collect(editor).filter(n => n.attrs['aria-label'] === 'File name' || n.attrs['aria-label'] === 'File URL');
 h.assertEq(inputs.length, 2, 'name + URL table row');
 inputs[0].value = '../bad.dat'; inputs[1].value = 'https://own.example/a.dat';
 uciCalls.length = 0;
 await findButton(editor, 'Save links').click();
 h.assertEq(uciCalls.length, 0, 'invalid name prevents save');
 inputs[0].value = 'own.dat'; inputs[1].value = 'http://own.example/a.dat';
 await findButton(editor, 'Save links').click();
 h.assertEq(uciCalls.length, 0, 'HTTP URL prevents save');
 inputs[1].value = 'https://own.example/a\x01bad';
 await findButton(editor, 'Save links').click();
 h.assertEq(uciCalls.length, 0, 'control byte URL prevents save');
 inputs[1].value = 'https://own.example/a.dat?x=y';
 const cron = collect(editor).find(n => n.attrs.id === 'mw-geodata-cron');
 h.assertEq(cron.tag + ':' + cron.children.map(o => o.attrs.value).join('|'), 'select:0 5 * * *|0 5 */3 * *|0 5 * * 0', 'schedule is a choice of three, not a cron field');
 cron.value = '0 5 * * 0';
 await findButton(editor, 'Save links').click();
 h.assertEq(JSON.stringify(uciCalls), '[["set","xraywrt","settings","geodata_asset",["own.dat=https://own.example/a.dat?x=y"]],["set","xraywrt","settings","geodata_cron","0 5 * * 0"],["save"],["apply",true]]', 'the same UCI save/apply as other settings, no settings form');
 await findButton(editor, 'Remove').click();
 h.assert(!collect(editor).some(n => n.tag === 'table'), 'table disappears with the last row');
 uciCalls.length = 0;
 await findButton(editor, 'Save links').click();
 h.assertEq(uciCalls[0][0], 'unset', 'empty table unsets assets');
 uci.get = (pkg, sid, key) => key === 'geodata_asset' ? ['saved.dat=https://own.example/saved'] : '0 7 * * *';
 const savedPage = render();
 h.assert(collect(savedPage).some(n => n.attrs.value === 'saved.dat'), 'saved asset loaded');
 const savedToggle = collect(savedPage).find(n => n.attrs.class === 'mw-toggle' && findButton(n, 'Hide my own rule databases'));
 h.assert(savedToggle && savedToggle.children[1].hidden === false && savedToggle.children[0].children[0].attrs['aria-expanded'] === 'true', 'own databases start open when links are saved');
 h.assert(collect(savedPage).some(n => n.attrs.id === 'mw-geodata-cron' && n.value === '0 7 * * *' && n.children.length === 4), 'a hand-written schedule stays as a fourth option');
 uci.get = () => undefined;
 // Advanced keeps only the editor below the settings form.
 const advanced = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/advanced.js', { E: DOM, ui: coreUi, uci, view: { extend: v => v }, api: bridge, widgets: {}, rpc: { declare: () => async () => ({}) }, form: { Map: class { section() { return { tab() {}, taboption() { return { value() {}, depends() {} }; } }; } render() { return Promise.resolve(E('form')); } } } }).module;
 const advancedPage = await advanced.render([{}, st, {}]);
 h.assert(!texts(advancedPage).includes('By link') && !texts(advancedPage).includes('Add my own rule database'), 'geodata links are not on Advanced');
 // Advanced: the editor card has one heading with its note, below the settings form.
 const maint = collect(advancedPage).find(n => n.attrs.class === 'cbi-section' && collect(n).some(c => c.tag === 'h3' && texts(c).includes('Xray config')));
 h.assert(maint, 'Advanced has an Xray config card');
 h.assert(!collect(advancedPage).some(n => /^h[1-6]$/.test(n.tag) && texts(n).includes('Maintenance')), 'no Maintenance heading');
 h.assertEq(collect(advancedPage).filter(n => n.tag === 'h3').length, 1, 'one heading below the settings form');
 const headingAt = collect(maint).findIndex(n => n.tag === 'h3');
 h.assertEq(texts(collect(maint)[headingAt + 1]).join(''), 'Use “Save config” below to apply editor changes.', 'the note sits right under the heading');
 h.assert(collect(advancedPage).findIndex(n => n.tag === 'form') < collect(advancedPage).indexOf(maint), 'the editor card sits below the settings form');
 for (const label of ['Show config editor']) {
  const opener = findButton(maint, label);
  h.assert(opener && toggleOf(maint, opener).children[1].hidden === true, label + ': collapsed');
 }
 h.assert(!findButton(advancedPage, 'Save & Apply'), 'no second Save & Apply beside the LuCI footer');
 // The LuCI footer sits between the settings form and the editor card; the loader's own footer is empty.
 const nodesOf = collect(advancedPage);
 h.assert(nodesOf.findIndex(n => n.attrs.class === 'cbi-page-actions') > nodesOf.findIndex(n => n.tag === 'form')
  && nodesOf.findIndex(n => n.attrs.class === 'cbi-page-actions') < nodesOf.indexOf(maint), 'footer is built under the settings form, above the editor card');
 h.assertEq(advanced.addFooter().children.length, 0, 'the view own addFooter adds nothing');
 // A card that holds only a button has no heading row and no top margin of its own: Help's runtime card.
 const helpCard = collect(diag.render([base, {}, {}])).find(n => /\bcbi-section\b/.test(n.attrs.class || '') && findButton(n, 'Show running config'));
 h.assert(helpCard && !collect(helpCard).some(n => /^h[1-6]$/.test(n.tag)) && /\bmw-page\b/.test(helpCard.attrs.class), 'button-only card: no heading, toggle directly in the page spacing');
 // Subscription: no LuCI form and footer, only its own buttons.
 const subView = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/subscription.js', { E: DOM, ui: coreUi, view: { extend: v => v }, api: bridge }).module;
 h.assert(subView.handleSave === null && subView.handleSaveApply === null && subView.handleReset === null, 'Subscription has no LuCI footer');
 h.assert(!/form\.Map|'require form'/.test(h.readSource('rootfs/www/luci-static/resources/view/xraywrt/subscription.js')), 'no form.Map on Subscription');
 h.assert(findButton(subView.render({ url: 'https://sub.example' }), 'Update now'), 'Subscription keeps its own buttons');
 // Without a saved link: only the URL field and Save; one heading.
 const noUrl = subView.render({ url: '' });
 h.assert(!findButton(noUrl, 'Update now') && !findButton(noUrl, 'Save') && findButton(noUrl, 'Connect'), 'no saved link: Connect only');
 h.assert(!texts(noUrl).includes('No automatic update schedule. Press "Update now" to update manually.'), 'no update-period hint without a saved link');
 h.assertEq(collect(noUrl).filter(n => /^h[23]$/.test(n.tag) && texts(n).includes('Subscription')).length, 1, 'one Subscription heading');
 // Expert controls sit behind one collapsed toggle per section.
 const expert = render();
 h.assert(!findButton(expert, 'Show advanced options'), 'no advanced options toggle');
 h.assert(collect(expert).some(n => /\bcbi-value\b/.test(n.attrs.class || '') && collect(n).some(c => c.attrs?.id === 'mw-geo-file')), 'the file input sits in a standard row, so the focus outline stays inside the card');
 // Spec 15: the package core is shown as <version> (package); its check shows the package version.
 const pkgPage = cv.render([{ ...st, core_source: { source: 'package', channel: 'core', tag: 'v0.2.0', version: '26.11.1-r1' } }, {}]);
 h.assert(texts(pkgPage).includes('26.11.1-r1 (package)'), 'package source shown');
  h.assert(!findButton(pkgPage, 'Show advanced options') && collect(pkgPage).filter(n => n.attrs.class === 'mw-toggle').length === 1, 'package core: no empty core toggle, only the own-database one');
 h.assert(texts(pkgPage).includes('The core is installed as the XrayWRT core package. "Update the core" updates that package.'), 'package core explains update action');
 checkReply = { installed: { source: 'package', channel: 'core', version: '26.10.1-r1' }, latest: { tag: 'v0.2.0', version: '26.11.1-r1', size: null }, update_available: true, channel_changed: false, error: null };
 await findButton(pkgPage, 'Check for updates').listeners.click(); await settle();
 h.assert(texts(pkgPage).includes('A new core is available: 26.11.1-r1.'), 'package version as the new core');
 const ro = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/updates.js', { E: DOM, ui, uci, view: { extend: v => v }, api: { ...bridge, readOnly: () => true } }).module;
 const rp = ro.render([st, {}]);
 for (const label of ['Check for updates', 'Update the core', 'Add my own rule database', 'Update rule databases', 'Upload', 'Add file', 'Save links']) h.assert(!findButton(rp, label), 'read-only hides ' + label);
 h.assert(texts(rp).includes('geosite.dat'), 'read-only still sees geodata');
 console.log('ok - core page version, updates, space and geodata');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Backend failure in load(): an inline error with the message and a retry, not "Loading view…" forever.
seq(async () => {
 let reloads = 0;
 const failing = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui, fs: {}, location: { reload: () => reloads++ } }).module;
 const reject = async () => { throw new Error('backend is down'); };
 const stub = { ...failing, read: reject, readLarge: reject, status: reject, profiles: reject };
 for (const [name, title] of [['overview', 'XrayWRT'], ['updates', 'Updates'], ['help', 'Help']]) {
  const v = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/' + name + '.js', { E, ui, uci: { load: async () => {} }, poll: { add() {} }, view: { extend: x => x }, api: stub }).module;
  const page = v.render(await v.load());
  h.assert(texts(page).includes(title) && texts(page).includes('Cannot load the page: backend is down'), name + ' shows the failure inline');
  h.assert(collect(page).some(n => n.attrs?.role === 'alert'), name + ' failure is an alert');
  const before = reloads;
  findButton(page, 'Try again').listeners.click();
  h.assertEq(reloads, before + 1, name + ' retry reloads the view');
 }
 console.log('ok - views show a load failure with retry');
}).catch(err => { console.error(err); process.exitCode = 1; });


seq(async () => {
 const menu = JSON.parse(h.readSource('rootfs/usr/share/luci/menu.d/luci-app-xraywrt.json'));
 h.assertEq(JSON.stringify(Object.keys(menu).filter(k => menu[k].action.type === 'alias')), '["admin/services/xraywrt"]', 'only the section entry is an alias; no old page URLs');
 const calls = [], notices = [];
 let balancerData = { balancers: [] }, balancerReads = 0;
 const bridge = { ...api, status: async () => base, profiles: async () => [], read: async () => ({}), balancers: async () => { balancerReads++; return balancerData; },
  balancerSet: async (...args) => calls.push(args), busy: async (b, fn) => fn(),
  reloadWithNotice: msg => notices.push(msg) };
 const evalView = extra => h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
  E, poll: { add() {} }, view: { extend: v => v }, api: { ...bridge, ...extra }
 }).module;
 const homeData = [{ ...base, core_installed: true, subscription_configured: true }, {}, []];
 // The status says whether the block exists (has_balancers); the list is read only when it is opened.
 const create = extra => {
  const v = evalView(extra);
  return { render: async (data, present = Boolean(data?.balancers?.length || data?.stale?.length)) => {
   balancerData = data;
   const page = v.render([{ ...homeData[0], has_balancers: present }, {}, []]);
   const show = findButton(page, 'Show balancers');
   if (show) { await show.listeners.click(); await settle(); }
   return page;
  } };
 };
 const v = create();
 const empty = await v.render({ balancers: [], stale: [] });
 h.assert(!texts(empty).includes('The configuration has no balancers. Add them on the Advanced page.') && !findButton(empty, 'Show balancers'), 'no balancers: no section and no placeholder');
 h.assertEq(balancerReads, 0, 'Home without balancers never reads them');
 balancerReads = 0;
 const closed = evalView().render([{ ...homeData[0], has_balancers: true }, {}, []]);
 h.assertEq(balancerReads, 0, 'Home with balancers reads nothing until the block is opened');
 h.assert(toggleOf(closed, findButton(closed, 'Show balancers')).children[1].hidden === true, 'balancers are collapsed by default');
 balancerData = { balancers: [] };
 await findButton(closed, 'Show balancers').listeners.click(); await settle();
 h.assertEq(balancerReads, 1, 'opening the block reads the balancers once');
 h.assert(texts(closed).includes('The configuration has no balancers.'), 'a stale flag opens to a plain message, not an empty table');
 h.assert(Array.isArray(evalView({ balancers: () => new Promise(() => {}) }).render(homeData).children), 'a pending balancer read does not block the first render');
 const b = { tag: '<main>', targets: ['node-a', 'node-b'], selected: ['node-a'], override: null };
 let page = await v.render({ balancers: [b, { ...b, tag: 'backup', override: 'node-b' }] });
 h.assert(findButton(page, 'Hide balancers'), 'balancers sit in a disclosure');
 h.assert(texts(page).includes('<main>') && texts(page).includes('node-a'), 'tag and current target shown as text');
 h.assertEq(collect(page).filter(n => n.tag === 'tr').length, 3, 'header and two balancers');
 const select = collect(page).find(n => n.tag === 'select');
 h.assertEq(select.attrs.disabled, null, 'enabled dropdown omits disabled attribute');
 h.assert(select.attrs['aria-label'].includes('<main>'), 'dropdown labelled with balancer tag');
 const hint = collect(page).find(n => n.attrs.id === select.attrs['aria-describedby']);
 h.assert(hint && texts(hint).includes('Pinning disables automatic fallback.'), 'pin warning visible and associated with control');
 h.assertEq(collect(select).filter(n => n.tag === 'option').map(n => n.attrs.value).join(','), ',node-a,node-b', 'only candidates plus Auto');
 select.value = 'node-b'; await select.listeners.change();
 h.assertEq(JSON.stringify(calls.at(-1)), '["<main>","node-b"]', 'pin without restart');
 h.assert(!findButton(page, 'Auto'), 'Auto is only an option');
 select.value = ''; await select.listeners.change();
 h.assertEq(JSON.stringify(calls.at(-1)), '["<main>",""]', 'automatic passes empty target');
 h.assertEq(notices.at(-1), 'Balancer override saved.', 'successful change refreshes live selection');
 h.assert(texts(page).includes('Fallback'), 'fallback column heading');
 const single = await v.render({ balancers: [{ ...b, targets: ['node-a'], fallback: 'node-b' }] });
 h.assert(texts(single).includes('One server, nothing to choose') && texts(single).includes('node-b'), 'single target and fallback shown');
 h.assert(!collect(single).some(n => n.tag === 'select' || n.attrs.id?.startsWith('balancer-pin-hint-')), 'single target has no selector or pin hint');
 const ro = create({ readOnly: () => true }); page = await ro.render({ balancers: [b] });
 h.assert(!findButton(page, 'Auto'), 'read-only cannot reset');
 h.assertEq(collect(page).find(n => n.tag === 'select').attrs.disabled, true, 'read-only dropdown disabled');
 let notified = false;
 const bad = create({ balancerSet: async () => { throw Error('API down'); }, busy: async (el, fn) => { try { await fn(); } catch { notified = true; } } });
 page = await bad.render({ balancers: [b] });
 const failedSelect = collect(page).find(n => n.tag === 'select'); failedSelect.value = 'node-b'; await failedSelect.listeners.change();
 h.assert(notified, 'mutation failure reaches shared error notification'); h.assertEq(failedSelect.value, '', 'failed dropdown restored');
 const broken = create({ balancers: async () => { throw Error('API unavailable'); } });
 page = await broken.render({ balancers: [b] }, true);
 h.assert(!texts(page).includes('API unavailable') && texts(page).includes('Cannot read the balancer state from Xray.') && texts(page).includes('Stopped'), 'balancer read failure leaves Home usable');
 console.log('ok - Balancers table, actions, empty/error and read-only states');
 // Spec 15/16: stopped core, per-balancer errors, unsettable tags, stale overrides.
 page = await v.render({ running: false, balancers: [], stale: [] });
 h.assert(!texts(page).includes('Start XrayWRT to see balancers.') && !collect(page).some(n => n.tag === 'select'), 'stopped core: no balancers section');
 h.assertEq(api.errorText({ name: 'CommandError', message: 'Error: Xray is not running [E:not_running]' }), 'Xray is not running', 'stopped core set error mapped');
 page = await v.render({ running: true, balancers: [{ ...b, error: 'api' }, { ...b, tag: 'b', error: 'timeout' }], stale: [] });
 h.assert(texts(page).includes('Cannot read the balancer state from Xray.') && texts(page).includes('Not checked: the time limit was reached.'), 'per-balancer errors shown');
 page = await v.render({ running: true, balancers: [{ ...b, tag: 'a=b', settable: false }], stale: [] });
 h.assertEq(collect(page).find(n => n.tag === 'select').attrs.disabled, true, 'tag with = cannot be pinned');
 h.assert(!findButton(page, 'Auto') && texts(page).includes('A balancer tag with "=" cannot be pinned.'), 'unsettable tag explained');
 page = await v.render({ running: true, balancers: [{ ...b, saved: 'node-b', stale: true }], stale: [{ tag: 'gone', target: 'node-a' }] });
 h.assert(texts(page).includes('Saved override node-b is not applied.'), 'stale override of a live balancer marked');
 h.assert(texts(page).includes('gone') && texts(page).includes('Saved override node-a is not applied: the configuration has no such balancer.'), 'stale override of an absent balancer marked');
 await findButton(page, 'Reset').listeners.click();
 h.assertEq(JSON.stringify(calls.at(-1)), '["gone",""]', 'stale override removable');
 page = await ro.render({ running: true, balancers: [], stale: [{ tag: 'gone', target: 'node-a' }] });
 h.assert(!findButton(page, 'Reset'), 'read-only cannot remove stale overrides');
 console.log('ok - Balancers stopped, error, unsettable and stale states');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Home: state first, then warnings, subscription, server, balancers; the connection check sits with the state.
seq(async () => {
 const fs = require('fs'), path = require('path');
 const ov = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', { E, poll: { add() {} }, view: { extend: v => v }, uci: {}, api: { ...api, balancers: async () => ({ balancers: [] }) } }).module;
 const st = { ...base, core_installed: true, subscription_configured: true, running: true, warnings: ['w'], has_balancers: true };
 const page = ov.render([st, { profile_title: 'P' }, ['A', 'B']]);
 const all = collect(page);
 const headline = all.find(n => n.tag === 'strong' && n.attrs['aria-live'] === 'polite');
 const order = [ headline,
  all.find(n => n.attrs.class === 'alert-message warning' && texts(n).includes('Configuration warnings')),
  findButton(page, 'Update subscription'),
  all.find(n => n.attrs.id === 'mw-profile'),
  findButton(page, 'Show balancers') ].map(n => all.indexOf(n));
 h.assert(order.every((i, k) => i >= 0 && (k === 0 || i > order[k - 1])), 'Home order: state, warnings, subscription, server, balancers: ' + order);
 h.assert(!all.some(n => n.tag === 'a' && texts(n).includes('Updates')) && !texts(page).includes('Core version'), 'no update block on Home');
 h.assert(texts(page).includes('Version 0.8.0 · core v1.19.32'), 'state block names the app and core versions');
 const stateBlock = all.find(n => n.attrs.class === 'cbi-section' && collect(n).includes(headline));
 h.assert(findButton(stateBlock, 'Check connection'), 'connection check is a row of the state block');
 h.assert(!all.some(n => n.tag === 'h3' && texts(n).includes('Check connection')), 'no separate connection section');
 // No user-visible text calls the first page "Overview": the menu says Home.
 const dir = 'rootfs/www/luci-static/resources/';
 for (const f of [...fs.readdirSync(path.join(h.rootDir, dir, 'view/xraywrt')).map(x => dir + 'view/xraywrt/' + x), dir + 'xraywrt/api.js', dir + 'xraywrt/configuration.js'])
  h.assert(!/_\('[^']*\bOverview\b/.test(h.readSource(f)), f + ' calls Home "Overview"');
 h.assert(!/msgid "[^"]*\bOverview\b/.test(h.readSource('po/ru/xraywrt.po')), 'catalog calls Home "Overview"');
 const helpNodes = collect(diag.render([base, {}, {}]));
 const helpAt = label => helpNodes.indexOf(helpNodes.find(n => n.tag === 'button' && texts(n).includes(label)));
 h.assert(helpAt('Check again') >= 0 && helpAt('Check again') < helpAt('Show running config'), 'Help: the configuration passed to Xray sits below the checklist');
 console.log('ok - Home order and naming');
}).catch(err => { console.error(err); process.exitCode = 1; });

// UX task 9: provider-first controls, missing subscription period, degraded reasons and direct sites.
seq(async () => {
 class Option {
  constructor(name, title, description) { Object.assign(this, { name, title, description, keylist: [], vallist: [] }); }
  value(k, v) { this.keylist.push(k); this.vallist.push(v); }
  depends() {}
  isActive() { return this.active !== false; }
  setActive(sid, active) { this.active = active; }
  triggerValidation(sid) {
   const value = this.formvalue?.(sid) || '';
   // LuCI first checks optional, then custom validation; inactive fields are not revalidated by checkDepends.
   this.error = !value && this.rmempty === false && !this.optional ? 'non-empty value' : this.validate?.(sid, value);
   return this.error === true || this.error == null;
  }
  renderWidget() { return E('input'); }
 }
 class Map {
  constructor() { this.options = {}; }
  section() {
   const option = (Type, name, title, description) => this.options[name] = new Option(name, title, description);
   return { option, taboption: (tab, ...args) => option(...args), tab() {} };
  }
  render() { return Promise.resolve(E('form')); }
 }
 const form = { Map, DummyValue: Option, TextValue: Option, ListValue: Option, Flag: Option, NamedSection: Option };
 const settings = { provider_override: ['disable_quic'] }, writes = [];
 const uci = { get: (p, s, k) => settings[k], set: (p, s, k, v) => { settings[k] = v; writes.push([k, v]); }, unset: (p, s, k) => { delete settings[k]; }, save: async () => writes.push(['save']) };
 const apiUci = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui: { ...ui, changes: { apply: async () => writes.push(['apply']) } }, fs: {}, uci }).module;
 const bridge = { ...apiUci, busy: async (el, fn) => fn() };
 const traffic = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/traffic.js', {
  E, api: bridge, uci, ui: { ...ui, changes: { apply: async () => writes.push(['apply']) } }, form, rpc: { declare: () => async () => ({}) }, view: { extend: v => v }
 }).module;
 const lists = { rules: 'example.com direct\n', src: '', direct_src: '' };
 for (const source of ['provider', 'auto']) {
  await traffic.render([lists, { mode: 'proxy-first', mode_source: source, sniff: 'tls' }, {}]);
  const modeOption = traffic.map.options.mode;
  h.assertEq(modeOption.cfgvalue(), 'provider', 'mode follows the configuration: ' + source);
  h.assertEq(modeOption.description, 'Everything goes via VPN except the addresses and devices below.', 'one line explains the current mode');
  modeOption.write('settings', 'direct-first');
  h.assertEq(settings.mode, 'direct-first', 'mode choice saved');
  h.assertEq(settings.provider_override.join(','), 'disable_quic,mode', 'mode override preserves other choices');
  await traffic.render([lists, { mode: 'direct-first', mode_source: 'user', sniff: 'tls' }, {}]);
  h.assertEq(traffic.map.options.mode.cfgvalue(), 'direct-first', 'own mode shown');
  traffic.map.options.mode.write('settings', 'provider');
  h.assertEq(settings.provider_override.join(','), 'disable_quic', 'first choice removes only the mode override');
  h.assert(!collect(traffic.map.options.mode.renderWidget()).some(n => n.tag === 'button'), 'no extra buttons beside the mode list');
 }
 // Direct sites in proxy-first need site recognition; the editor stays editable and says so.
 for (const sniff of ['0', 'fakedns', 'tls', 'fakedns,http', 'quic']) {
  await traffic.render([lists, { mode: 'proxy-first', sniff }, {}]);
  const field = traffic.map.options._rules;
  const available = /(?:^|,)(?:http|tls|quic)(?:,|$)/.test(sniff);
  h.assert(field && !field.readonly && !field.disabled, 'My rules stay editable: ' + sniff);
  h.assertEq(field.cfgvalue(), 'example.com direct\n', 'saved rules stay visible');
  h.assertEq(texts(field.renderWidget()).some(t => t.startsWith('Site recognition is not enabled')), !available, 'recognition note only without sniffing: ' + sniff);
 }
 await traffic.render([lists, { mode: 'direct-first', sniff: 'tls', sniff_skipped_targets: ['proxy'] }, {}]);
 const sniffWarning = texts(traffic.map.options._rules.renderWidget()).join(' ');
 h.assert(sniffWarning.includes('proxy') && sniffWarning.includes('saved') && sniffWarning.includes('not applied') && sniffWarning.includes('replace'), 'My rules shows affected target and explains sniffing skip');
 // Direct-first needs no site recognition.
 for (const sniff of ['0', 'fakedns']) {
  await traffic.render([lists, { mode: 'direct-first', sniff }, {}]);
  h.assert(!texts(traffic.map.options._rules.renderWidget()).some(t => t.startsWith('Site recognition is not enabled')), 'direct-first needs no recognition note: ' + sniff);
 }
 await traffic.render([lists, { mode: 'direct-first', sniff: 'tls' }, {}]);
 const listCalls = [];
 bridge.upload = async (prefix, content) => { listCalls.push(['upload', prefix, content]); return '/tmp/xraywrt-policy-list.direct'; };
 bridge.job = async (...args) => { listCalls.push(args); return {}; };
 bridge.notify = () => {};
 uci.changes = async () => ({});
 const rulesField = traffic.map.options._rules;
 traffic.map.parse = async () => rulesField.write('settings', 'full:direct.example direct\n');
 traffic.map.save = async () => {};
 await traffic.handleSaveApply();
 h.assertEq(JSON.stringify(listCalls), JSON.stringify([['upload', 'xraywrt-policy-list', 'full:direct.example direct\n'], ['apply-lists', '/tmp/xraywrt-policy-list.direct', '-', '-']]), 'My rules use the first upload slot');
 const advanced = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/advanced.js', {
  E, api: bridge, uci, ui: { ...ui, changes: { apply: async () => writes.push(['apply']) } }, widgets: {}, form, view: { extend: v => v }, rpc: { declare: () => async () => ({}) }
 }).module;
 await advanced.render([{ mode: 'proxy-first', provider: { disable_quic: '0' } }, {}, {}]);
 const overridden = advanced.map.options.disable_quic;
 h.assert(overridden.description.includes('Your override.'), 'Advanced marks overridden fields');
 await findButton(overridden.renderWidget('settings'), 'Use subscription setting').click();
 h.assert(!settings.provider_override, 'Advanced reset removes the last override');
 bridge.readOnly = () => false;
 h.assert(h.readSource('rootfs/www/luci-static/resources/view/xraywrt/traffic.js').includes('api.LIST_TITLES'), 'one list title table');
 h.assert(!h.readSource('rootfs/www/luci-static/resources/view/xraywrt/advanced.js').includes('geodataCronValid'), 'no client cron parser');
 const configuration = origEvaluate('rootfs/www/luci-static/resources/xraywrt/configuration.js', { E, ui, api: bridge, Blob }).module;
 for (const sub of [{ url: 'https://sub.example', effective_interval: 12 }, { url: 'https://sub.example', header_interval: 0 }]) {
  const p = configuration.render(sub, 'subscription');
  h.assert(!collect(p).some(n => n.attrs.id === 'mw-auto'), 'no checkbox without provider header');
  h.assert(texts(p).includes('No automatic update schedule. Press "Update now" to update manually.'), 'manual subscription explanation');
 }
 h.assert(collect(configuration.render({ url: 'https://sub.example', header_interval: 12 }, 'subscription')).some(n => n.attrs.id === 'mw-auto'), 'checkbox with provider header');
 const changed = overview.render([{ ...base, overrides: 2 }, {}, []]);
 h.assert(texts(changed).includes('You changed 2 provider settings.'), 'Home override count');
 h.assert(collect(changed).some(n => n.tag === 'a' && n.attrs.href?.endsWith('/advanced')), 'override link to Advanced');
 h.assert(!texts(overview.render([{ ...base, overrides: 0 }, {}, []])).some(t => t.startsWith('You changed')), 'no zero override notice');
 for (const [reason, message] of [['dns', 'VPN DNS is not responding'], ['observatory', 'The VPN server is not responding (provider check)'], [undefined, 'VPN DNS is not responding']]) {
  const p = overview.render([{ ...base, state: 'degraded', degraded_reason: reason }, {}, []]);
  h.assert(texts(p).includes(message), 'degraded reason: ' + reason);
  h.assert(texts(p).includes('Internet traffic goes directly until the VPN recovers.'), 'degraded direct path explained');
 }
 const observatoryHelp = texts(diag.render([{ ...base, state: 'degraded', degraded_reason: 'observatory', dns_ok: true }, {}, {}]));
 h.assert(observatoryHelp.includes('The VPN server is not responding (provider check)'), 'Help reports observatory degradation');
 h.assert(observatoryHelp.includes('Internet traffic goes directly until the VPN recovers.'), 'Help explains observatory recovery');
 h.assert(!observatoryHelp.includes('Xray DNS does not answer: traffic goes direct until it recovers'), 'Help does not blame healthy DNS');
 h.assert(texts(diag.render([base, {}, {}])).includes('The subscription has no server check, so XrayWRT notices a failed server only when DNS stops answering.'), 'Help explains DNS-only detection');
 {
  const helpNodes = collect(diag.render([base, {}, {}]));
  const hintAt = helpNodes.findIndex(n => n.attrs.class === 'cbi-value-description' && texts(n).includes('The subscription has no server check, so XrayWRT notices a failed server only when DNS stops answering.'));
  h.assert(hintAt > helpNodes.findIndex(n => n.attrs.class === 'mw-check'), 'DNS-only hint sits below the checklist');
 }
 h.assert(!texts(diag.render([{ ...base, observatory_signal: true }, {}, {}])).includes('The subscription has no server check, so XrayWRT notices a failed server only when DNS stops answering.'), 'Help hides DNS-only warning with a live observatory signal');
 console.log('ok - provider-first mode, auto-update, direct sites, degraded reasons and DRY');
}).catch(err => { console.error(err); process.exitCode = 1; });

// Several saved subscriptions: the table, its buttons and the add form.
seq(async () => {
 const calls = [];
 const apiReal = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/api.js', { E, ui }).module;
 const bridge = { ...apiReal, readOnly: () => false, busy: async (el, fn) => fn(), confirm: async (...a) => { calls.push(['confirm', a[0]]); return true; },
  job: async (...args) => { calls.push(args); return { action: args[0] === 'add-subscription' ? 'added' : 'switched' }; },
  reloadResult: (res, note) => calls.push(['notice', note]) };
 const configuration = h.evaluateLuCIModule('rootfs/www/luci-static/resources/xraywrt/configuration.js', { E, ui, api: bridge, Blob }).module;
 const sub = { url: 'https://p.example/a', auto_update: true, header_interval: 12, active: 'sa', subscriptions: [
  { id: 'sa', name: 'Alpha', active: true, updated: 1700000000, meta: { upload: 1, download: 2, total: 100, expire: 0 } },
  { id: 'sb', name: 'Beta', active: false, updated: null, meta: {} } ] };
 const page = configuration.render(sub, 'subscription');
 const table = collect(page).find(n => n.tag === 'table' && /cbi-section-table/.test(n.attrs.class));
 h.assert(table, 'standard LuCI section table');
 h.assertEq(texts(collect(table).find(n => n.attrs.class === 'tr table-titles')).join('|'), 'Name|Status|Data used|Expires|Last update|Actions', 'table columns');
 const rows = collect(table).filter(n => n.tag === 'tr' && n.attrs.class === 'tr');
 h.assertEq(rows.length, 2, 'one row per subscription');
 h.assert(texts(rows[0]).includes('Alpha') && texts(rows[0]).includes('Active') && texts(rows[0]).includes('Never'), 'active row: name, marker, expiry');
 h.assert(!findButton(rows[0], 'Use') && !findButton(rows[0], 'Delete'), 'active row has no Use, and no Delete while others exist');
 h.assert(texts(rows[1]).includes('Beta') && !texts(rows[1]).includes('Active') && texts(rows[1]).filter(t => t === '—').length === 3, 'inactive row without data shows dashes');
 h.assert(findButton(rows[1], 'Use') && findButton(rows[1], 'Delete'), 'inactive row has Use and Delete');
 h.assert(!collect(page).some(n => n.attrs.id === 'mw-url') && !findButton(page, 'Connect') && findButton(page, 'Update now'), 'detail block keeps Update now, no link field');
 await findButton(rows[1], 'Use').click();
 h.assertEq(JSON.stringify(calls.splice(0)), JSON.stringify([['use-subscription', 'sb'], ['notice', 'Subscription "Beta" is now in use.']]), 'Use starts the switch job');
 await findButton(rows[1], 'Delete').click();
 h.assertEq(JSON.stringify(calls.splice(0)), JSON.stringify([['confirm', 'Delete the subscription?'], ['delete-subscription', 'sb'], ['notice', 'Subscription deleted.']]), 'Delete asks first');
 const input = collect(page).find(n => n.attrs.id === 'mw-add-url');
 const add = findButton(page, 'Add subscription');
 let message = '';
 input.value = '';
 try { await add.click(); } catch (e) { message = e.message; }
 h.assertEq(message, 'Enter the subscription link.', 'empty link refused');
 h.assertEq(calls.length, 0, 'empty link starts no job');
 input.value = ' https://p.example/c ';
 await add.click();
 h.assertEq(JSON.stringify(calls.splice(0)), JSON.stringify([['add-subscription', 'https://p.example/c'], ['notice', 'Subscription added. Press "Use" to switch to it.']]), 'Add sends the trimmed link');
 const only = collect(configuration.render({ ...sub, subscriptions: [sub.subscriptions[0]] }, 'subscription')).filter(n => n.tag === 'tr' && n.attrs.class === 'tr');
 h.assert(findButton(only[0], 'Delete') && !findButton(only[0], 'Use'), 'the last subscription can be deleted');
 bridge.readOnly = () => true;
 const readOnly = configuration.render(sub, 'subscription');
 h.assert(!findButton(readOnly, 'Use') && !findButton(readOnly, 'Delete') && !findButton(readOnly, 'Add subscription'), 'read-only role sees no buttons');
 h.assert(collect(readOnly).some(n => n.tag === 'table'), 'read-only role still sees the table');
bridge.readOnly = () => false;
 const first = configuration.render({ url: '', subscriptions: [] }, 'subscription');
 h.assert(findButton(first, 'Connect') && !collect(first).some(n => n.tag === 'table'), 'no subscription: the Connect form');
 console.log('ok - subscription table, Use, Delete, Add and read-only');
}).catch(err => { console.error(err); process.exitCode = 1; });

NODE
