'use strict';

const assert = require('assert').strict;
const nodefs = require('fs');
const h = require('./js_luci_harness');
const apiPath = 'rootfs/www/luci-static/resources/xraywrt/api.js';
function E(tag, attrs, children) {
	if (Array.isArray(attrs)) { children = attrs; attrs = {}; }
	return { tag, attrs: attrs || {}, children: children || [],
		addEventListener(type, fn) { this[type] = fn; }, appendChild(child) { this.children.push(child); },
		replaceChildren(...children) { this.children = children; }, setAttribute(key, value) { this.attrs[key] = value; }, removeAttribute(key) { delete this.attrs[key]; },
		hasAttribute(key) { return key in this.attrs; }, classList: { add() {}, remove() {} }
	};
}
function setup(overrides = {}) {
	const timers = [], calls = [];
	const module = h.evaluateLuCIModule(apiPath, {
		E, ui: { addNotification() {} }, Blob, FormData, crypto: require('crypto').webcrypto,
		L: { env: { cgi_base: '/cgi-bin' } },
		rpc: { getSessionID: () => 'session-secret' },
		request: { post: async () => ({ ok: true, status: 200, json: () => ({}) }) },
		fs: { exec: async (bin, args) => { calls.push([bin, args]); return { code: 0, stdout: JSON.stringify({ id: '1-2' }) }; } },
		setTimeout: (fn, ms) => { timers.push({ fn, ms }); },
		...overrides
	}).module;
	return { api: module, timers, calls };
}
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
async function tick(timers) {
	await flush();
	assert(timers.length, 'a poll must be scheduled');
	const timer = timers.shift(); assert.equal(timer.ms, 2000); timer.fn(); await flush();
}
const tests = [];
function test(name, fn) { tests.push([name, fn]); }
test('job buttons lock together through busy preparation and job completion', async () => {
 const buttons = [false, false, true].map(disabled => ({ disabled, hasAttribute: () => true, classList: { add() {}, remove() {} } }));
 const { api, timers } = setup({ document: { querySelectorAll: () => buttons } });
 api.read = async () => ({ state: 'ok', result: {} });
 let prepare;
 const preparation = new Promise(resolve => { prepare = resolve; });
 const pending = api.busy(buttons[0], async () => { await preparation; return api.job('service', 'start'); });
 assert(buttons.every(b => b.disabled), 'all job buttons disabled before async preparation');
 let invoked = false; await api.busy(buttons[1], () => { invoked = true; });
 assert.equal(invoked, false, 'disabled job button cannot start another action');
 prepare(); await tick(timers); await pending;
 assert.deepEqual(buttons.map(b => b.disabled), [false, false, true]);
 const direct = api.job('core-update'); assert(buttons.every(b => b.disabled));
 await tick(timers); await direct;
 assert.deepEqual(buttons.map(b => b.disabled), [false, false, true]);
});
for (const outcome of ['ok', 'error', 'start-error']) test('job clears old notices on start and running notice on completion: ' + outcome, async () => {
 const notice = { children: ['stale error'], replaceChildren(...children) { this.children = children; } };
 const { api, timers } = setup({ document: { querySelectorAll: selector => selector === '.mw-job' ? [notice] : [] } });
 api.write = async () => {
  assert(!notice.children.includes('stale error'), 'stale notice cleared before job-start');
  assert(notice.children[0].children[0].includes('is running'), 'running notice shown');
  if (outcome === 'start-error') throw Error('start failed');
  return { id: '1' };
 };
 api.read = async () => outcome === 'ok' ? { state: 'ok' } : { state: 'error', error: 'failed' };
 const pending = outcome === 'ok' ? api.job('update-lists') : assert.rejects(api.job('update-lists'));
 if (outcome !== 'start-error') await tick(timers);
 await pending;
 assert.equal(notice.children.length, 0, 'no stale running notice after completion');
});
for (const accepted of [false, true]) test('confirm modal resolves once for confirm or cancel: ' + accepted, async () => {
 let modal, hides = 0;
 const { api } = setup({ ui: { showModal: (title, children) => { modal = { title, children }; }, hideModal: () => { hides++; } } });
 const pending = api.confirm('Restore YAML', 'Replace the current YAML?', 'Restore', { danger: true });
 assert.equal(modal.title, 'Restore YAML');
 assert.equal(modal.children[0].children.join(''), 'Replace the current YAML?');
 const buttons = modal.children[1].children.filter(n => n.tag === 'button');
 assert.equal(buttons[0].children[0], 'Cancel');
 assert(buttons[1].attrs.class.includes('cbi-button-negative'));
 buttons[accepted ? 1 : 0].click();
 buttons[accepted ? 0 : 1].click();
 assert.equal(await pending, accepted);
 assert.equal(hides, 1, 'only the first choice closes the modal');
});
test('jobLabel reuses known labels and falls back to operation', () => {
 const { api } = setup();
 assert.equal(api.jobLabel('apply-lists'), 'Applying lists and settings');
 assert.equal(api.jobLabel('auto-update'), 'Automatic update');
 assert.equal(api.jobLabel('custom-op'), 'custom-op');
});
test('jobNotice locks all job starters until reload', async () => {
 const buttons = [{ disabled: false }]; let reloads = 0;
 const { api, timers } = setup({ document: { querySelectorAll: () => buttons }, location: { reload: () => reloads++ } });
 let reads = 0; api.read = async () => ++reads === 1 ? { id: '1', op: 'service', state: 'running' } : { state: 'ok' };
 api.jobNotice(); await flush();
 assert.equal(api.jobRunning, true); assert.equal(buttons[0].disabled, true);
 await tick(timers); assert.equal(reloads, 1);
});
// C1: a finished background job must not reload over unsaved edits.
for (const outcome of ['ok', 'error']) test('jobNotice keeps unsaved edits when the job ends: ' + outcome, async () => {
 const buttons = [{ disabled: false }], listeners = {}; let reloads = 0, count = 0;
 const { store, sessionStorage } = storage();
 const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ },
  document: { querySelectorAll: () => buttons, addEventListener: (type, fn) => { listeners[type] = fn; } } });
 api.read = async () => ++count === 1 ? { id: '9-1', op: 'update-lists', state: 'running' }
  : outcome === 'ok' ? { state: 'ok' } : { state: 'error', error: "Interrupted: stopped [E:operation_interrupted]" };
 const notice = api.jobNotice(); await flush();
 assert.equal(buttons[0].disabled, true);
 listeners.input();
 await tick(timers);
 assert.equal(reloads, 0, 'no reload over edits');
 assert.equal(store['xraywrt-notice'], undefined, 'nothing kept for a reload');
 assert.equal(notice.children[0].textContent, outcome === 'ok'
  ? '"Remote list update" finished. Reload the page to see the result; your unsaved edits are still here.'
  : '"Remote list update" failed: The operation was interrupted (for example, by a router reboot). You can run it again.');
 assert.equal(api.jobRunning, false, 'job no longer running');
 assert.equal(buttons[0].disabled, false, 'buttons usable to save the edits');
 assert.equal(store['xraywrt-seen-job'], '9-1', 'result shown once');
});
test('jobNotice still reloads without edits', async () => {
 const listeners = {}; let reloads = 0, count = 0;
 const { api, timers } = setup({ location: { reload: () => reloads++ },
  document: { querySelectorAll: () => [], addEventListener: (type, fn) => { listeners[type] = fn; } } });
 api.read = async () => ++count === 1 ? { id: '9-2', op: 'update-lists', state: 'running' } : { state: 'ok' };
 api.jobNotice(); await flush(); await tick(timers);
 assert.equal(reloads, 1);
 assert.equal(typeof listeners.input, 'function', 'edits are watched');
});
test('job ok: three polls spaced 2000 ms, running flag', async () => {
	let polls = 0;
	const { api, timers, calls } = setup();
	api.read = async (...args) => { assert.deepEqual(args, ['job-status', '1-2']); return ++polls < 3 ? { state: 'running' } : { state: 'ok', result: { action: 'saved' } }; };
	assert.equal(api.jobRunning, false);
	const pending = api.job('save-config', '/tmp/xraywrt-config.a');
	assert.equal(api.jobRunning, true);
	for (let i = 0; i < 3; i++) await tick(timers);
	assert.equal((await pending).action, 'saved'); assert.equal(polls, 3); assert.equal(api.jobRunning, false);
	assert.equal(JSON.stringify(calls), JSON.stringify([['/usr/bin/xraywrt', ['job-start', 'save-config', '/tmp/xraywrt-config.a']]]));
});
test('job error preserves backend message and clears flag', async () => {
	const { api, timers } = setup();
	api.read = async () => ({ state: 'error', error: "Xray rejected the configuration [E:config_rejected]" });
	const pending = api.job('save-config');
	const rejected = assert.rejects(pending, /Xray rejected the configuration/);
	await tick(timers); await rejected; assert.equal(api.jobRunning, false);
});
test('poll access denied limit and recovery', async () => {
	for (const failures of [5, 4]) {
		const { api, timers } = setup(); let count = 0;
		api.read = async () => { if (++count <= failures) throw Error('Access denied'); return { state: 'ok', result: { action: 'saved' } }; };
		const pending = api.job('core-update');
		const checked = failures === 5 ? assert.rejects(pending, { message: 'Access denied. Log in to LuCI again, or ask for write access.' }) : pending;
		for (let i = 0; i < 5; i++) await tick(timers);
		await checked; assert.equal(api.jobRunning, false);
	}
});
test('poll expired session shapes map to access denied', async () => {
	const shapes = [
		() => Object.assign(Error('RPC call to file/exec failed with error -32002: Access denied'), { name: 'RPCError' }),
		() => Object.assign(Error('Login session is expired'), { name: 'SessionError' })
	];
	for (const make of shapes) {
		const { api, timers } = setup();
		api.read = async () => { throw make(); };
		const pending = api.job('core-update');
		const checked = assert.rejects(pending, { message: 'Access denied. Log in to LuCI again, or ask for write access.' });
		for (let i = 0; i < 5; i++) await tick(timers);
		await checked; assert.equal(api.jobRunning, false);
	}
});
test('poll failures reset after successful poll; lost connection message', async () => {
	const { api, timers } = setup(); let count = 0;
	api.read = async () => { count++; if (count === 5) return { state: 'running' }; throw Error('network down'); };
	const rejected = assert.rejects(api.job('core-update'), { message: 'Lost connection to the router while waiting for the result.' });
	for (let i = 0; i < 10; i++) await tick(timers);
	await rejected; assert.equal(count, 10);
});
test('upload byte size, session, URL, ACL errors and allowed prefixes', async () => {
	let reply, seen;
	const { api } = setup({ request: { post: async (...args) => { seen = args; return { ok: true, status: 200, json: () => reply }; } } });
	const content = '\uFEFFданные: 1\n', size = new Blob([content]).size;
	reply = { size };
	const path = await api.upload('xraywrt-config', content);
	assert.match(path, /^\/tmp\/xraywrt-config\.[a-z0-9]+$/);
	assert.equal(seen[0], '/cgi-bin/cgi-upload'); assert.equal(seen[2].timeout, 0);
	assert.equal(seen[1].get('sessionid'), 'session-secret'); assert.equal(seen[1].get('filename'), path);
	assert.equal(seen[1].get('filedata').size, size); assert.equal(Buffer.from(await seen[1].get('filedata').arrayBuffer()).toString('utf8'), content);
	reply = { size: size - 1 }; await assert.rejects(api.upload('xraywrt-config', content), { message: 'The upload was incomplete. Try again.' });
	for (const message of ['Access to path denied by ACL', 'Cannot create file', undefined]) {
  reply = { failure: [0, ''], message };
  await assert.rejects(api.upload('xraywrt-config', content), { message: 'The upload failed. Check your LuCI permissions and try again.' });
 }
	await assert.rejects(api.upload('../etc/config', content));
	reply = { size }; assert.match(await api.upload('xraywrt-policy-list', content), /^\/tmp\/xraywrt-policy-list\.[a-z0-9]+$/);
});
test('upload of empty content sends one newline because cgi-upload refuses empty files', async () => {
	let seen;
	const { api } = setup({ request: { post: async (...args) => { seen = args; return { ok: true, status: 200, json: () => ({ size: seen[1].get('filedata').size }) }; } } });
	const path = await api.upload('xraywrt-policy-list', '');
	assert.match(path, /^\/tmp\/xraywrt-policy-list\.[a-z0-9]+$/);
	assert.equal(Buffer.from(await seen[1].get('filedata').arrayBuffer()).toString('utf8'), '\n');
});
test('readLarge uses cgi-exec JSON and rejects non-objects', async () => {
	let reply = { content: 'yaml' }, seen;
	const { api } = setup({ fs: { exec_direct: async (...args) => { seen = args; return reply; } } });
	assert.equal(await api.readLarge('read-config'), reply);
	assert.equal(JSON.stringify(seen), JSON.stringify(['/usr/bin/xraywrt', ['read-config'], 'json']));
	for (reply of ['yaml', null, 3]) await assert.rejects(api.readLarge('read-config'), { message: 'Unexpected response from the router.' });
	reply = []; assert.equal(await api.readLarge('proxies-json'), reply);
});
test('errorText maps transport errors and preserves useful causes', () => {
	const { api } = setup();
	assert.equal(api.errorText(Object.assign(Error('request timed out'), { name: 'TimeoutError' })), 'The router did not answer in time. The operation may still be running; check again in a minute.');
	assert.equal(api.errorText(Object.assign(Error('permission denied'), { name: 'PermissionError' })), 'Access denied. Log in to LuCI again, or ask for write access.');
	assert.equal(api.errorText({ stderr: 'Error: bad yaml\n' }), 'bad yaml');
	assert.equal(api.errorText(Error('bad yaml')), 'bad yaml');
});
test('transport mapping never rewrites backend output or generic error text', async () => {
	const { api } = setup();
	const timeout = 'The router did not answer in time. The operation may still be running; check again in a minute.';
	const denied = 'Access denied. Log in to LuCI again, or ask for write access.';
	assert.equal(api.errorText(Error('XHR request timed out')), timeout);
	assert.equal(api.errorText(Object.assign(Error('RPC call to file/exec failed with ubus code 6: Permission denied'), { name: 'RPCError' })), denied);
	assert.equal(api.errorText(Object.assign(Error('RPC call to file/exec failed with HTTP error 403: Forbidden'), { name: 'RPCError' })), denied);
	assert.equal(api.errorText(Error('Access denied')), denied);
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider', 'XHR request timed out', 'Access denied']) {
		for (const field of ['stderr', 'stdout']) {
			assert.equal(api.errorText({ [field]: message }), message);
			const { api: commandApi } = setup({ fs: { exec: async () => ({ code: 1, [field]: message }) } });
			try { await commandApi.read('read-config'); assert.fail('command must reject'); }
			catch (e) { assert.equal(commandApi.errorText(e), message); }
		}
	}
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider']) assert.equal(api.errorText(Error(message)), message);
});
// C2: backend errors the user can act on, in plain words (EN source; RU in the PO).
const BACKEND_ERRORS = [
	["config: share links are not supported, use the Xray JSON subscription URL [E:config_share]", "This link returns vless://, vmess://… links. Ask the service for an Xray JSON subscription link."],
	["config: Clash/Mihomo YAML is not supported [E:config_yaml]", "This is Clash/Mihomo (YAML). Ask the service for an Xray JSON subscription link."],
	["config: missing DNS IP [E:dns_raw_upstream_required]", "Enter a DNS server IP[:port] for forwarding through the VPN."],
 ["config: invalid DNS IP [E:dns_raw_upstream_invalid]", "Enter a valid IP address with an optional port (1–65535)."],
 ["config: not JSON [E:config_json]", "The configuration is not valid JSON."],
	["config: no outbounds [E:config_outbounds]", "The configuration has no outbounds."],
	["config: routing is not an object [E:config_invalid|routing is not an object]", "The configuration is invalid: routing is not an object"],
	["config needs geosite.dat, but geodata.assets does not provide it [E:geodata_missing|geosite.dat]", "The configuration needs geosite.dat, but the subscription does not supply it. Upload the file on the Updates page."],
	["check failed [E:geodata_check]", "The router core rejected the geodata files with your settings. No files were replaced."],
	["geodata geoip.dat: download failed (network) [E:geodata_download|geoip.dat|network]", "Could not download the geodata file geoip.dat (network). Check the router's internet connection or upload the file on the Updates page."],
	["core missing, run core-update [E:core_missing]", "The Xray core is not installed. Install it on the Updates page."],
	["Another operation is running: update-lists [E:operation_busy|update-lists]", "Another operation is running: \"Remote list update\". Wait until it finishes."],
	["Another operation is running: custom-op [E:operation_busy|custom-op]", "Another operation is running: \"custom-op\". Wait until it finishes."],
	["Interrupted: the operation was stopped before it finished. [E:operation_interrupted]", "The operation was interrupted (for example, by a router reboot). You can run it again."],
	["Subscription returned an empty config [E:subscription_empty]", "The subscription returned an empty configuration."],
	["Subscription URL must start with http:// or https:// [E:subscription_url]", "Enter the subscription link that starts with https://"],
	["Subscription download failed: http_404 [E:subscription_not_found]", "Subscription not found (HTTP 404). Check the link in your service account."],
	["Failed to apply routing rules: nft: syntax error [E:routing_apply|nft: syntax error]", "Xray started, but the routing rules could not be applied: nft: syntax error"],
	["Failed to update 1 of 3 remote lists: Remote lists exceed 8 MiB in total [E:lists_update|1|3|Remote lists exceed 8 MiB in total]", "Could not update 1 of 3 remote lists: Remote lists exceed 8 MiB in total"],
	["Failed to update 1 of 1 remote lists: Remote list download failed: example.org [E:lists_update|1|1|Remote list download failed: example.org]", "Could not update 1 of 1 remote lists: Remote list download failed: example.org"],
	["Remote lists exceed 8 MiB in total [E:lists_large]", "The remote lists are larger than 8 MiB in total. Remove some list links or use smaller lists."],
	["Core update: cannot reach GitHub (API: network) [E:core_download|cannot reach GitHub (API: network)]", "Could not download the Xray core from GitHub. Check the router's internet connection, or install the core by hand: apk add --allow-untrusted xraywrt-core_*.apk. Details: cannot reach GitHub (API: network)"],
	["Core update: download failed (http_403) [E:core_download|download failed (http_403)]", "Could not download the Xray core from GitHub. Check the router's internet connection, or install the core by hand: apk add --allow-untrusted xraywrt-core_*.apk. Details: download failed (http_403)"],
	["Core update: unavailable [E:core_arch|mipsel_24kc]", "The core is not available for this router (mipsel_24kc); the current core is kept."],
	["Core update: channel a/b@v1 publishes no sha256 for Xray-linux-64 [E:core_no_checksum|channel a/b@v1 publishes no sha256 for Xray-linux-64]", "The release does not publish a checksum for this core package, so it cannot be installed. Details: channel a/b@v1 publishes no sha256 for Xray-linux-64"],
	["Core update: not enough flash: need 24 MiB, free 10 MiB [E:core_flash|24|10]", "Not enough free flash for the Xray core: 24 MiB needed, 10 MiB free."],
	["Core update: not enough RAM: need 40 MiB, available 30 MiB [E:core_ram|40|30]", "Not enough free memory to download the Xray core: 40 MiB needed, 30 MiB available."],
	["Core update: not enough RAM for a rollback copy of the old core: need 40 MiB, available 30 MiB; --no-rollback installs without it [E:core_rollback_ram|not enough RAM for a rollback copy of the old core: need 40 MiB, available 30 MiB; --no-rollback installs without it]", "Not enough free memory for a backup copy of the current core. Details: not enough RAM for a rollback copy of the old core: need 40 MiB, available 30 MiB; --no-rollback installs without it"],
	["Core update: new core failed to start; no rollback copy (--no-rollback) [E:core_no_rollback|new core failed to start]", "The new core did not start, and there was no backup copy of the previous one. Install a core again on the Updates page. Details: new core failed to start"],
	["Core update: new core failed to start, previous core restored [E:core_restored|new core failed to start]", "The previous core is restored. Details: new core failed to start"],
	["Core update: new binary does not run on this router [E:core_binary]", "The core file does not run on this router. The current core is kept."],
	["Core update: new core rejects the current config [E:core_config|]", "The new core does not accept your current configuration; the core was not updated."],
	["Core update: sha256 mismatch [E:core_damaged]", "The downloaded core file is damaged. Try again."],
	["Another core update is running [E:core_busy]", "The core is already being updated."],
	["Xray core updated, but the service restart failed: config test failed [E:core_restart|config test failed]", "The Xray core was updated, but XrayWRT could not restart: config test failed. Press Start on Home."],
	["Xray core updated, but the service restart failed [E:core_restart_empty]", "The Xray core was updated, but XrayWRT could not restart. Press Start on Home."],
	["The config is empty: nothing was changed. [E:config_empty]", "The configuration is empty: nothing was changed."],
	["The config is larger than 8 MiB. [E:config_large]", "The configuration is larger than 8 MiB."],
	["There is no previous configuration. [E:config_no_previous]", "There is no previous configuration."],
	["List rules is larger than 1 MiB. [E:list_large|rules]", "The \"My rules\" list is larger than 1 MiB."],
	["List direct_src is larger than 1 MiB. [E:list_large|direct_src]", "The \"Devices always direct\" list is larger than 1 MiB."],
	["List custom is larger than 1 MiB. [E:list_large|custom]", "The \"custom\" list is larger than 1 MiB."],
	["Runtime is busy (process 1234) [E:runtime_busy|1234]", "The router is busy with another task (process 1234). Try again in a minute."],
	["XrayWRT could not start. See the system log. [E:service_start]", "XrayWRT could not start. See the log on the Help page."],
	["Invalid XrayWRT settings [E:settings_invalid]", "XrayWRT settings are damaged. Save the Advanced page again or reinstall the package."],
	["Line 2 of My rules (b.test) has no target. Add a space and one of: direct, core. [E:rules_no_target|2|b.test|direct, core]", "Line 2 of My rules (b.test) has no target. Add a space and one of: direct, core."],
	["Line 1 of My rules (a.test gone): there is no target. [E:rules_unknown_target|1|a.test gone|gone|direct, core, proxy]", "Line 1 of My rules (a.test gone): there is no target \"gone\". Use one of: direct, core, proxy."],
	["Line 3 of My rules (1.2.3.4;443 direct) is not valid. [E:rules_bad_entry|3|1.2.3.4;443 direct]", "Line 3 of My rules (1.2.3.4;443 direct) is not a site, an IP address, a subnet or a list link followed by one target. Write a site as its bare name, for example example.com."],
	["My rules has more than 10000 sites. [E:rules_too_many|10000]", "My rules has more than 10000 sites."],
	["the rule [E:rules_too_large|proxy|10000]", "The rule for \"proxy\" in My rules has more than 10000 addresses and was skipped. Use fewer or smaller lists."],
	["Invalid src entries: aa:bb (21 total) [E:list_invalid|src|aa:bb (21 total)]", "\"Devices via VPN\" has invalid lines: aa:bb (21 in total)"],
	["Invalid src entries: 1.1.1.1 [E:list_invalid|src|1.1.1.1]", "\"Devices via VPN\" has invalid lines: 1.1.1.1"],
	["Xray config not found: /opt/xraywrt/config.json [E:config_missing|/opt/xraywrt/config.json]", "Configuration file not found: /opt/xraywrt/config.json"],
	["Failed to apply nftables policy (see /tmp/ruleset.nft) [E:nft_policy|/tmp/ruleset.nft]", "Failed to apply nftables policy: see /tmp/ruleset.nft. Restart XrayWRT; if it happens again, see the log on Help."],
];
test('invalid list count suffix is translated for address and device lists', () => {
 const { api } = setup({ _: value => value === '(%d in total)' ? '(всего %d)' : value });
 for (const kind of ['dst', 'direct', 'src', 'direct_src']) {
  const message = api.errorText(Error('Invalid ' + kind + ' entries: x (21 total) [E:list_invalid|' + kind + '|x (21 total)]'));
  assert(message.includes('x (всего 21)'));
  assert.equal(api.errorText(Error(message)), message);
 }
});
test('errorText maps backend errors to plain words and is idempotent', () => {
	const { api } = setup();
	for (const [raw, plain] of BACKEND_ERRORS) {
		assert.equal(api.errorText({ stderr: 'Error: ' + raw + '\n' }), plain, raw);
		assert.equal(api.errorText(Object.assign(Error(raw), { name: 'JobError' })), plain, 'job error: ' + raw);
		assert.equal(api.errorText({ stderr: plain }), plain, 'mapped text stays: ' + plain);
	}
});
test('public error path keeps Xray\'s own rejection lines', () => {
 const { api } = setup();
 const raw = "Xray 26.1.1 (Xray, Penetrates Everything.) Custom (go1.25 linux/amd64)\nA unified platform for anti-censorship.\nFailed to start: main: failed to load config files: [/tmp/xraywrt/config-check.1.json] > infra/conf: bad outbound\nXray rejected the configuration [E:config_rejected]";
 for (const value of [raw, { name: 'JobError', message: raw }, { stderr: raw }])
  assert.equal(api.errorText(value), 'Xray rejected the configuration.\nFailed to start: main: failed to load config files: [… > infra/conf: bad outbound');
 assert.equal(api.errorText("Xray rejected the configuration [E:config_rejected]"), 'Xray rejected the configuration.');
 assert.equal(api.coreError('Xray 26.1.1 (Xray, x)\nConfiguration OK.'), 'Configuration OK.');
});
test('core restart errors take priority over nested rejection', () => {
 const { api } = setup();
 assert.equal(api.errorText("Xray core updated, but the service restart failed: Xray rejected the configuration [E:core_restart|Xray rejected the configuration]"),
  'The Xray core was updated, but XrayWRT could not restart: Xray rejected the configuration. Press Start on Home.');
});
test('unmapped multi-line backend output stays intact', () => {
 const { api } = setup();
 const raw = 'first diagnostic line\nsecond diagnostic line';
 assert.equal(api.errorText(raw), raw);
});
test('one-line backend errors map the last non-empty line of job stderr', () => {
 const { api } = setup();
 for (const [raw, plain] of BACKEND_ERRORS)
  assert.equal(api.errorText('time="2026-10-27" level=info msg="checking"\ntime="2026-10-27" level=error msg="bad config"\n' + raw + '\n\n'), plain, raw);
});
for (const op of ['save-config', 'restore-config', 'connect', 'use-subscription', 'update-subscription', 'auto-update', 'service', 'core-update']) {
 test('unchanged-config note is limited to rejected config-install jobs: ' + op, async () => {
  const { api, timers } = setup();
  const configInstall = !['service', 'core-update'].includes(op);
  api.read = async () => ({ state: 'error', error: "Xray rejected the configuration [E:config_rejected]" });
  const rejected = assert.rejects(api.job(op), { name: 'JobError', message: 'Xray rejected the configuration.' +
   (configInstall ? '\n' + 'Nothing was changed, the previous configuration is still running.' : '') });
  await tick(timers); await rejected;
  let shown;
  const status = async () => ({ state: 'error', id: 'config-1', op, finished: 1000, now: 1001, error: "Xray rejected the configuration [E:config_rejected]" });
  const { api: unseen } = setup({ ui: { addNotification: (a, node) => { shown = node.children.join(''); } }, sessionStorage: storage().sessionStorage });
  unseen.read = status;
  unseen.jobNotice(); await flush();
  assert.equal(shown.includes('Nothing was changed'), configInstall, 'background job notice uses the same scope');
 });
}
test('a killed config check is reported as a memory problem, with the unchanged-config note', async () => {
 const { api, timers } = setup();
 api.read = async () => ({ state: 'error', error: 'Not enough memory to check the configuration [E:config_test_oom]' });
 const rejected = assert.rejects(api.job('save-config'), { name: 'JobError', message: 'Not enough memory to check the configuration. Try again in a minute.\nNothing was changed, the previous configuration is still running.' });
 await tick(timers); await rejected;
});
test('command errors carry the plain backend text', async () => {
	const { api } = setup({ fs: { exec: async () => ({ code: 1, stderr: "Error: Another operation is running: core-update [E:operation_busy|core-update]\n" }) } });
	await assert.rejects(api.job('update-lists'), { name: 'CommandError', message: "Another operation is running: \"Xray core update\". Wait until it finishes." });
	assert.equal(api.jobRunning, false);
});
test('background job errors of any operation use the plain backend text', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '6-1', op: 'update-lists', finished: 1000, now: 1001, error: "Interrupted: the operation was stopped before it finished. [E:operation_interrupted]" });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Remote list update" failed: The operation was interrupted (for example, by a router reboot). You can run it again.', 'error' ]]);
});
test('readOnly follows the LuCI view permission', () => {
	assert.equal(setup().api.readOnly(), false, 'no permission info: actions stay');
	for (const [permission, readOnly] of [[false, true], [true, false], [null, false]])
		assert.equal(setup({ L: { env: {}, hasViewPermission: () => permission } }).api.readOnly(), readOnly, String(permission));
});
// E9: one formatter for terminal job errors, applied where the job ends.
for (const op of ['connect', 'update-subscription']) {
	test(`${op} terminal errors carry the plain backend text and stay JobError`, async () => {
		const { store, sessionStorage } = storage();
		const { api, timers } = setup({ sessionStorage });
		api.write = async () => ({ id: '10-1' });
		api.read = async () => ({ state: 'error', error: "Subscription download failed: http_404 [E:subscription_not_found]" });
		const pending = assert.rejects(api.job(op, 'https://p.example/sub'), { name: 'JobError', message: 'Subscription not found (HTTP 404). Check the link in your service account.' });
		await tick(timers); await pending;
		assert.equal(store['xraywrt-seen-job'], '10-1', 'job remembered as seen');
	});
}
test('dead helpers are gone', () => {
	const { api } = setup();
	assert.equal(api.readFile, undefined);
	assert.equal(api.safeLink('https://example.org', 'x', 'cbi-button').attrs.class, undefined, 'safeLink has no class parameter');
	assert(!/safeLink\(/.test(h.extractBetween(h.readSource(apiPath), 'function linkButton', '\n}\n')), 'linkButton checks the URL itself');
});
test('job backend errors reach busy notification unchanged', async () => {
	for (const message of ['dial tcp: i/o timeout', 'Access denied by provider', 'XHR request timed out', 'Access denied']) {
		let notified;
		const { api, timers } = setup({ ui: { addNotification: (title, node) => { notified = node.children[0]; } } });
		api.read = async () => ({ state: 'error', error: message });
		const pending = api.busy(null, () => api.job('save-config'));
		await tick(timers); await pending;
		assert.equal(notified, message);
	}
});
test('readLarge JSON parse errors become a clear router response error; transport stays intact', async () => {
	for (const body of ['', '<html>403 Forbidden</html>', '<html>500 Internal Server Error</html>']) {
		const { api } = setup({ fs: { exec_direct: async () => JSON.parse(body) } });
		await assert.rejects(api.readLarge('read-config'), { message: 'Unexpected response from the router.' });
	}
	for (const err of [Object.assign(Error('Forbidden'), { name: 'PermissionError' }), Error('XHR request timed out')]) {
		const { api } = setup({ fs: { exec_direct: async () => { throw err; } } });
		try { await api.readLarge('read-config'); assert.fail('must reject'); }
		catch (e) { assert.equal(api.errorText(e), api.errorText(err)); }
	}
});
test('upload checks HTTP status before parsing and hides non-JSON errors', async () => {
	for (const status of [200, 403, 500]) for (const body of ['', '<html>403 Forbidden</html>', '<html>500 Internal Server Error</html>']) {
		let parsed = false;
		const { api } = setup({ request: { post: async () => ({ ok: status === 200, status, json: () => { parsed = true; return JSON.parse(body); } }) } });
		await assert.rejects(api.upload('xraywrt-config', 'yaml'), { message: status === 403 ? 'Access denied. Log in to LuCI again, or ask for write access.' : 'Unexpected response from the router.' });
		assert.equal(parsed, status === 200);
	}
});
test('upload suffix uses cryptographic bytes encoded as lowercase hex', async () => {
	let calls = 0;
	const bytes = [0, 1, 10, 15, 16, 127, 128, 255];
	const { api } = setup({
		crypto: { getRandomValues: array => { calls++; assert(array.byteLength >= 8); array.forEach((_, i) => { array[i] = bytes[i % bytes.length]; }); return array; } },
		request: { post: async () => ({ ok: true, status: 200, json: () => ({ size: 4 }) }) }
	});
	const path = await api.upload('xraywrt-config', 'yaml');
	assert.equal(calls, 1);
	assert.match(path, /^\/tmp\/xraywrt-config\.[0-9a-f]{16,}$/);
	assert(path.split('.')[1].startsWith('00010a0f107f80ff'));
});
test('shared helpers', () => {
	const { api } = setup();
	assert.equal(api.modeLabel('proxy-first'), 'Everything via VPN except exclusions');
	assert.equal(api.linkButton('javascript:x', 'y'), null);
	assert.equal(api.linkButton('https://example.org', '<unsafe>').tag, 'button');
	assert.equal(api.infoGrid([['Key', '<unsafe>']]).attrs.class, 'mw-grid');
	for (const [action, message] of Object.entries({ unchanged: 'Subscription is up to date.', restarted: 'Subscription updated; XrayWRT restarted.', saved: 'Subscription updated.' })) assert.equal(api.actionNotice(action), message);
});
test('jobNotice fills live notice and reloads after completion', async () => {
	let count = 0, reloads = 0;
	const { api, timers } = setup({ location: { reload: () => reloads++ } });
	api.read = async (...args) => { assert.deepEqual(args, count ? ['job-status', '1-2'] : ['job-status']); return ++count === 1 ? { id: '1-2', op: 'core-update', state: 'running' } : { state: 'ok' }; };
	const notice = api.jobNotice(); assert.equal(notice.attrs['aria-live'], 'polite');
	assert.equal(notice.attrs.hidden, undefined); assert.equal(notice.hidden, undefined);
	assert.equal(notice.children.length, 0);
	await flush(); assert.equal(notice.children[0].attrs.class, 'alert-message notice');
	assert.equal(notice.children[0].children[0], '"Xray core update" is running…');
	assert.equal(notice.hidden, undefined);
	await tick(timers); assert.equal(reloads, 1);
});
test('jobNotice idle and initial read failure', async () => {
	for (const read of [async () => ({ state: 'none' }), async () => { throw Error('Access denied'); }]) {
		const { api, timers } = setup(); api.read = read;
		const notice = api.jobNotice(); assert.equal(notice.attrs.hidden, undefined); assert.equal(notice.children.length, 0);
		await flush(); assert.equal(timers.length, 0); assert.equal(notice.hidden, undefined);
		if (notice.children.length) assert.equal(notice.children[0].children[0], 'Access denied. Log in to LuCI again, or ask for write access.');
	}
});
// Task 11: a failed background job always shows its error.
function storage() {
	const store = {};
	return { store, sessionStorage: { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = String(v); }, removeItem: k => { delete store[k]; } } };
}
function notifications() {
	const shown = [], roles = [];
	return { shown, roles, ui: { addNotification: (t, node, level) => {
		shown.push([node.children[0], level]);
		return { setAttribute: (k, v) => k === 'role' && roles.push(v) };
	} } };
}
const nowSeconds = () => Math.floor(Date.now() / 1000);
test('running job error reloads with notice', async () => {
	const { store, sessionStorage } = storage(); let reloads = 0, count = 0;
	const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ } });
	api.read = async () => ++count === 1 ? { id: '4-1', op: 'update-subscription', state: 'running' } : { id: '4-1', state: 'error', error: 'boom' };
	api.jobNotice(); await flush();
	await tick(timers);
	assert.equal(reloads, 1);
	assert.deepEqual(JSON.parse(store['xraywrt-notice']), { text: '"Subscription update" failed: boom', type: 'error' });
});
test('running job ok still reloads without a notice', async () => {
	const { store, sessionStorage } = storage(); let reloads = 0, count = 0;
	const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ } });
	api.read = async () => ++count === 1 ? { id: '4-2', op: 'update-subscription', state: 'running' } : { state: 'ok' };
	api.jobNotice(); await flush();
	await tick(timers);
	assert.equal(reloads, 1); assert.equal(store['xraywrt-notice'], undefined);
});
test('finished error shown once', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-1', op: 'core-update', finished: nowSeconds() - 100, error: 'x' });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Xray core update" failed: x', 'error' ]]);
	api.jobNotice(); await flush();
	assert.equal(shown.length, 1, 'second page load shows nothing');
});
test('background subscription error is the plain text, announced as alert', async () => {
	const { sessionStorage } = storage(), { shown, roles, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-8', op: 'update-subscription', finished: 1000, now: 1001, error: "Subscription download failed: http_404 [E:subscription_not_found]" });
	api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ '"Subscription update" failed: Subscription not found (HTTP 404). Check the link in your service account.', 'error' ]]);
	assert.deepEqual(roles, [ 'alert' ]);
});
test('error window uses the router clock', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-9', op: 'core-update', finished: 1000, now: 1100, error: 'x' });
	api.jobNotice(); await flush();
	assert.equal(shown.length, 1, 'recent on the router clock even if the browser clock differs');
});
test('old error silent', async () => {
	const { sessionStorage } = storage(), { shown, ui } = notifications();
	const { api } = setup({ sessionStorage, ui });
	api.read = async () => ({ state: 'error', id: '5-2', op: 'core-update', finished: nowSeconds() - 601, error: 'x' });
	api.jobNotice(); await flush();
	assert.equal(shown.length, 0);
});
test('seen error silent', async () => {
	const { store, sessionStorage } = storage(), { shown, ui } = notifications();
	const { api, timers } = setup({ sessionStorage, ui });
	api.write = async () => ({ id: '7-3' });
	api.read = async (cmd, id) => id ? { state: 'error', error: 'bad' } : { state: 'error', id: '7-3', op: 'core-update', finished: nowSeconds() - 1, error: 'bad' };
	const pending = assert.rejects(api.job('core-update'), { message: 'bad' });
	await tick(timers); await pending;
	assert(String(store['xraywrt-seen-job']).includes('7-3'), 'job() remembers the id it waited for');
	api.jobNotice(); await flush();
	assert.equal(shown.length, 0);
});
test('seen ok job id is stored too', async () => {
	const { store, sessionStorage } = storage();
	const { api, timers } = setup({ sessionStorage });
	api.write = async () => ({ id: '8-1' });
	api.read = async () => ({ state: 'ok', result: {} });
	const pending = api.job('core-update');
	await tick(timers); await pending;
	assert(String(store['xraywrt-seen-job']).includes('8-1'));
});
test('reloadWithNotice survives the reload and shows once', async () => {
	const store = {}; let reloads = 0; const shown = [];
	const sessionStorage = { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; } };
	const ui = { addNotification: (t, node, level) => shown.push([node.children[0], level]) };
	const first = setup({ sessionStorage, ui, location: { reload: () => reloads++ } });
	first.api.reloadWithNotice('XrayWRT restarted.', 'info');
	assert.equal(reloads, 1); assert.equal(shown.length, 0, 'nothing shown before the reload');
	const next = setup({ sessionStorage, ui }); next.api.read = async () => ({ state: 'none' });
	next.api.jobNotice(); await flush();
	assert.deepEqual(shown, [[ 'XrayWRT restarted.', 'info' ]]);
	next.api.jobNotice(); await flush(); assert.equal(shown.length, 1, 'notice shown once');
});
test('reloadWithNotice stores plain text; empty message shows nothing', async () => {
	for (const [message, expected] of [ [ 'Done.', 'Done.' ], [ undefined, '' ], [ null, '' ], [ '', '' ] ]) {
		const store = {}; const shown = [];
		const sessionStorage = { getItem: k => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: k => { delete store[k]; } };
		const ui = { addNotification: (t, node, level) => shown.push(node.children[0]) };
		setup({ sessionStorage, ui, location: { reload() {} } }).api.reloadWithNotice(message);
		assert.equal(JSON.parse(store['xraywrt-notice']).text, expected);
		const next = setup({ sessionStorage, ui }); next.api.read = async () => ({ state: 'none' });
		next.api.jobNotice(); await flush();
		assert.deepEqual(shown, expected ? [ expected ] : []);
	}
});
test('reloadWithNotice falls back to notify when storage throws, and still reloads', () => {
	let reloads = 0; const shown = [];
	const sessionStorage = { getItem: () => null, removeItem() {}, setItem() { throw new Error('quota'); } };
	const ui = { addNotification: (t, node, level) => shown.push([node.children[0], level]) };
	setup({ sessionStorage, ui, location: { reload: () => reloads++ } }).api.reloadWithNotice('Saved.', 'warning');
	assert.deepEqual(shown, [[ 'Saved.', 'warning' ]]); assert.equal(reloads, 1);
});
test('damaged stored notice is dropped silently and the page renders', async () => {
	for (const raw of [ '{not json', '"str"', 'null', '{"text":""}' ]) {
		const store = { 'xraywrt-notice': raw }; const shown = [];
		const sessionStorage = { getItem: k => store[k] ?? null, setItem() {}, removeItem: k => { delete store[k]; } };
		const { api } = setup({ sessionStorage, ui: { addNotification: () => shown.push(1) } }); api.read = async () => ({ state: 'none' });
		const notice = api.jobNotice(); await flush();
		assert.equal(shown.length, 0); assert.equal(notice.tag, 'div'); assert.equal(store['xraywrt-notice'], undefined);
	}
});
test('views keep action notices across reloads except plain load-error retry', () => {
	for (const name of [ 'overview.js', 'subscription.js', 'updates.js' ]) {
		const source = h.readSource('rootfs/www/luci-static/resources/view/xraywrt/' + name);
		assert(!/location\.reload/.test(source.replace("again.addEventListener('click', () => location.reload());", '')), name + ': raw action reload loses the notice');
	}
});
test('api owns the interval label and geodata name rule', () => {
	const { api } = setup();
	assert.deepEqual([ '0', '6', '168' ].map(api.intervalLabel), [ 'Off (only manually)', '6 h', '7 days' ]);
	assert(api.GEODATA_NAME.test('own-1.dat') && !api.GEODATA_NAME.test('../x.dat') && !api.GEODATA_NAME.test('x.txt'));
});
test('no shared helper copies in views', () => {
	for (const name of nodefs.readdirSync(h.sourcePath('rootfs/www/luci-static/resources/view/xraywrt'))) {
		const source = h.readSource('rootfs/www/luci-static/resources/view/xraywrt/' + name);
		assert(!/function\s+(modeLabel|linkButton)\s*\(/.test(source), name + ': helper copy');
		assert(!/intervalLabel\s*[:(=]\s*(?:function|\()|const GEODATA_NAME/.test(source), name + ': interval label or geodata name copy');
		assert(!/rows\.flatMap\(\(\[\s*k,\s*v\s*\]/.test(source), name + ': key/value grid copy');
		assert(!source.includes("res.action === 'hot_reloaded' ? _('Subscription"), name + ': action notice copy');
	}
});
test('Stop works while another operation holds the job slot', () => {
	const source = h.readSource('rootfs/www/luci-static/resources/view/xraywrt/overview.js');
	assert(/status\.running \? \{ class: 'cbi-button' \}/.test(source), 'Stop is not locked by a running job');
	assert(/if \(failed\) \{\s*await api\.write\('stop-now'\)/.test(source));
	assert(/if \(fresh\.running\)\s*throw/.test(source), 'no success notice when the service still runs');
	assert(/^stop-now\)[^;]*init\.d\/xraywrt stop \) [^\n]*&$/m.test(h.readSource('rootfs/usr/bin/xraywrt')), 'stop-now is detached');
});
test('Connect on the Subscription page is the connect job', () => {
	const source = h.readSource('rootfs/www/luci-static/resources/xraywrt/configuration.js');
	assert(/if \(!sub\.url\)\s*return api\.busy\(save, async \(\) => \{[^}]*api\.job\('connect', link\)/.test(source));
});
test('overview has no long synchronous operations', () => {
	assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/xraywrt/overview.js')));
});
const longOperations = /(?:api\.write|fs\.exec)\([^;]*(?:core-check|core-update|geodata-update|update-subscription|add-subscription|use-subscription|delete-subscription|update-lists|apply-lists|save-config)|api\.service\((?!'(?:enable|disable)'\))|fs\.exec\([^;]*\/etc\/init\.d\/xraywrt[^;]*(?:start|stop|restart)/;
test('no long synchronous operations in views', () => {
	for (const name of nodefs.readdirSync(h.sourcePath('rootfs/www/luci-static/resources/view/xraywrt')))
		assert(!longOperations.test(h.readSource('rootfs/www/luci-static/resources/view/xraywrt/' + name)), name);
});
// A14.1: wrappers for the Xray backend commands (spec 14, 15).
test('Xray command wrappers', async () => {
 const execs = [];
 const out = { 'config-check': [1, { ok: false, error: 'bad', output: 'Failed' }], profiles: [0, ['a', 'b']], 'status-json': [0, { state: 'running' }] };
 const { api } = setup({ fs: { exec: async (bin, args) => { execs.push([bin, ...args].join(' ')); const [code, v] = out[args[0]]; return { code, stdout: JSON.stringify(v), stderr: '' }; },
  exec_direct: async (bin, args) => { execs.push([bin, ...args].join(' ')); return { content: '{}', generated: false }; } } });
 const jobs = [];
 api.job = async (...args) => { jobs.push(args.join(' ')); return {}; };
 assert.equal((await api.status()).state, 'running');
 assert.equal(JSON.stringify(await api.profiles()), '["a","b"]');
 assert.equal((await api.configCheck('/tmp/xraywrt-config.1')).error, 'bad', 'config-check JSON survives exit 1');
 assert.equal((await api.runtimeConfig()).generated, false);
 await api.coreCheck();
 await api.coreUpdate();
 await api.coreUpdate({ noRollback: true });
 await api.geodataUpdate({ force: true });
 await api.geodataUpdate({ file: '/tmp/xraywrt-geodata.1', name: 'geosite.dat' });
 assert.deepEqual(execs, ['/usr/bin/xraywrt-read status-json', '/usr/bin/xraywrt-read profiles', '/usr/bin/xraywrt config-check /tmp/xraywrt-config.1',
  '/usr/bin/xraywrt-read runtime-config']);
 assert.deepEqual(jobs, ['core-check', 'core-update', 'core-update --no-rollback', 'geodata-update --force', 'geodata-update --file /tmp/xraywrt-geodata.1 --name geosite.dat']);
});
test('the subscription link comes unmasked only through the write ACL', async () => {
 for (const [permission, bin] of [[true, '/usr/bin/xraywrt'], [null, '/usr/bin/xraywrt'], [false, '/usr/bin/xraywrt-read']]) {
  const execs = [];
  const { api } = setup({ L: { env: {}, hasViewPermission: () => permission }, fs: { exec: async (b, args) => { execs.push([b, ...args].join(' ')); return { code: 0, stdout: '{}', stderr: '' }; } } });
  await api.read('subscription-json');
  await api.read('status-json');
  assert.deepEqual(execs, [bin + ' subscription-json', '/usr/bin/xraywrt-read status-json'], 'view permission ' + permission);
 }
});
test('Xray uploads: geodata prefix, binary blobs, no core upload', async () => {
 const { api } = setup({ request: { post: async (url, data) => ({ ok: true, status: 200, json: () => ({ size: data.get('filedata').size }) }) } });
 const bytes = new Uint8Array([0, 1, 2]);
 await assert.rejects(api.upload('xraywrt-core', new Blob([bytes])), { message: 'Invalid upload path.' });
 assert.match(await api.upload('xraywrt-geodata', new Blob([bytes])), /^\/tmp\/xraywrt-geodata\.[0-9a-f]{32}$/);
});
test('no Mihomo-only wrappers or texts in api.js', () => {
 const src = h.readSource(apiPath);
 assert(!/x-mihowrt|proxies|delay|dashboard|Mihomo (?:core|DNS|rejected)/i.test(src), 'Mihomo leftovers in api.js');
});
test('balancer wrappers preserve empty target and ACL separation', async () => {
 const { api, calls } = setup();
 await api.balancers(); await api.balancerSet('main', '');
 assert.equal(JSON.stringify(calls), JSON.stringify([['/usr/bin/xraywrt-read', ['balancers']], ['/usr/bin/xraywrt', ['balancer-set', 'main', '']]]));
 const acl = JSON.parse(h.readSource('rootfs/usr/share/rpcd/acl.d/luci-app-xraywrt.json'))['luci-app-xraywrt'];
 assert(acl.read.file['/usr/bin/xraywrt-read'].includes('exec'));
 assert(!acl.read.file['/usr/bin/xraywrt'], 'read cannot execute mutating backend');
 assert(acl.write.file['/usr/bin/xraywrt'].includes('exec'));
});
test('support report is readable, allowlisted and contains failures only', () => {
 const { api } = setup();
 const secret = 'https://example.com/token uuid=12345678-1234-abcd-ABCD-123456789012 password=secret';
 const report = api.reportText({ status: { version: '1.2.3', core: '26.1', mode: 'direct-first', state: 'failed', core_installed: true, config_valid: false, config_error: secret, last_error: secret, warnings: [secret], errors: [secret] }, diagnostics: { flash_free_kb: 1234, ram_available_kb: 5678, config_test: { output: [secret] } }, checks: [[false, secret, secret]], logs: { available: true, lines: [secret] } });
 for (const value of ['1.2.3', '26.1', 'Only selected sites via VPN', 'Configuration has errors', 'Update the subscription']) assert(report.includes(value), value);
 for (const value of [secret, 'example.com', 'token', 'secret', '12345678', 'Log:', '{', 'Xray-core']) assert(!report.includes(value), value);
 assert(!report.includes('Press Start on Home.'), 'no misleading start advice when config invalid');
});
test('support report safely identifies invalid settings and a busy DNS port', () => {
 const { api } = setup();
 const st = { core_installed: true, state: 'failed', errors: ['broken secret [E:settings_invalid]'], last_error: 'owner secret [E:dns_port_busy|owner-secret]' };
 const report = api.reportText({ status: st, diagnostics: { dns_guard_error: 'owner secret [E:dns_port_busy|owner-secret]' } });
 assert(report.includes('XrayWRT settings are damaged.'));
 assert(report.includes('Port 53 is occupied.'));
 assert(!report.includes('Press Start on Home.') && !report.includes('No known problems found.'));
 assert(!report.includes('secret') && !report.includes('owner'));
 assert.equal((report.match(/Port 53 is occupied\./g) || []).length, 1);
 const running = api.reportText({ status: { core_installed: true, state: 'running', policy_active: true }, diagnostics: { dns_guard_error: 'private [E:dns_port_busy|private]' } });
 assert(running.includes('Disable the other DNS service.') && !running.includes('then start XrayWRT.'));
 const dnsOnly = api.reportText({ status: { core_installed: true, state: 'failed' }, diagnostics: { dns_guard_error: 'private [E:dns_port_busy|private]' } });
 assert(dnsOnly.includes('Port 53 is occupied.') && !dnsOnly.includes('Press Start on Home.'));
});
test('support report treats current DNS diagnostics as authoritative', () => {
 const { api } = setup();
 const status = { core_installed: true, state: 'failed', last_error: 'private [E:dns_port_busy|private]' };
 const cleared = api.reportText({ status, diagnostics: { dns_guard_error: null } });
 assert(!cleared.includes('Port 53 is occupied.') && cleared.includes('Press Start on Home.'));
 const missing = api.reportText({ status });
 assert(!missing.includes('Port 53 is occupied.') && !missing.includes('private'));
});
test('support report distinguishes degraded state and unknown checks', () => {
 const { api } = setup();
 const degraded = api.reportText({ status: { core_installed: true, state: 'degraded', degraded_reason: 'observatory', policy_active: true } });
 assert(degraded.includes('Degraded') && degraded.includes('VPN server is not responding'));
 const unknown = api.reportText({ status: { core_installed: true, state: 'starting' } });
 assert(unknown.includes('No known problems found.') && !unknown.includes('No problems found.'));
});
test('support report accepts numeric core version and rejects injected version suffixes', () => {
 const { api } = setup();
 assert(api.reportText({ status: { core: 'v26.11.1-1424' } }).includes('v26.11.1-1424'));
 assert(!api.reportText({ status: { core: '26.11.1-secret' } }).includes('secret'));
});
test('support report omits dynamic values and ignores healthy checks', () => {
 const { api } = setup();
 const report = api.reportText({ status: { version: '1.0', core: 'brand secret', mode: 'proxy-first', state: 'running', core_installed: true, config_valid: true, policy_active: true, dns_ok: true, custom_dns_servers: ['secret'] }, checks: [[true, 'OK SECRET', 'SECRET']] });
 assert(!report.includes('brand secret') && !report.includes('OK SECRET') && !report.includes('SECRET'));
 assert(report.includes('dnsmasq has its own upstream servers'));
});
function nodes(n) { return !n || typeof n !== 'object' ? [] : [n, ...(n.children || []).flatMap(nodes)]; }
test('connection check asks the router, shows the direct-first hint and handles errors', async () => {
 for (const outcome of ['ok', 'error', 'malformed']) {
  let read;
  const { api } = setup();
  api.read = async (...args) => { if (args[0] !== 'check-ip') return {}; read = args; if (outcome === 'error') throw Error('exit 1'); return outcome === 'malformed' ? {} : { ip: '<unsafe>', country: 'DE' }; };
  const overview = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/overview.js', {
   E, api, view: { extend: v => v }, poll: { add() {} },
   fetch: async () => { throw Error('the browser must not be asked'); }
  }).module;
  const page = overview.render([{ core_installed: true, mode: 'direct-first', running: true, subscription_configured: true }, {}, []]);
  const all = nodes(page);
  const button = all.find(n => n.tag === 'button' && n.children.includes('Check connection'));
  assert(button, 'connection button');
  assert.equal(read, undefined, 'no request before clicking');
  const proxyPage = overview.render([{ core_installed: true, mode: 'proxy-first', running: true, subscription_configured: true }, {}, []]);
  await button.click();
  assert.deepEqual(read, ['check-ip']);
  assert.equal(button.disabled, false);
  assert(all.some(n => n.textContent === (outcome === 'ok' ? "Router's internet IP: <unsafe>, country DE (sites outside the VPN lists go direct)" : 'Could not check: the check site is unavailable.')));
  assert(nodes(proxyPage).find(n => n.tag === 'button' && n.children.includes('Check connection')), 'proxy-first has the check too');
 }
});
test('Help copies report over plain HTTP without the Clipboard API', async () => {
 let area, removed = false;
 const { api } = setup(); api.readLarge = async () => ({ available: false });
 const help = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', {
  E: (...args) => { const node = E(...args); node.select = () => {}; node.remove = () => { removed = true; }; return node; },
  api, view: { extend: v => v }, configuration: { render: () => E('div') }, navigator: {},
  document: { body: { appendChild: node => { area = node; } }, execCommand: command => { assert.equal(command, 'copy'); return true; } }
 }).module;
 const page = help.render([{ version: '1.2.3' }, {}, {}]);
 await nodes(page).find(n => n.tag === 'button' && n.children.includes('Copy summary')).click();
 assert(area && area.children.join('').includes('1.2.3')); assert(removed, 'temporary selection removed');
});
test('Help copies report without reading logs', async () => {
 let copied, reads = [];
 const { api } = setup();
 api.readLarge = async (...args) => { reads.push(args); return { available: true, lines: ['password=secret'] }; };
 const help = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', {
  E, api, view: { extend: v => v }, configuration: { render: () => E('div') },
  navigator: { clipboard: { writeText: async text => { copied = text; } } }
 }).module;
 const page = help.render([{ version: '1.0', mode: 'proxy-first', flags: { dns_hijack: true, disable_quic: false }, lists: { dst: 777 }, interfaces: ['private-lan'] }, { provider_sources: { vpn: { addresses: ['192.0.2.1'] } } }, { router_model: 'Test router' }]);
 const copy = nodes(page).find(n => n.tag === 'button' && n.children.includes('Copy summary'));
 assert(copy, 'copy summary action'); await copy.click();
 assert.deepEqual(reads, []);
 for (const value of ['1.0', 'Test router', 'dns_hijack: yes', 'disable_quic: no']) assert(copied.includes(value), value);
 for (const value of ['password=secret', '192.0.2.1', '777', 'private-lan']) assert(!copied.includes(value), value);
});
test('Help downloads a local detailed report only after explicit confirmation', async () => {
 for (const scenario of ['cancel', 'download', 'partial', 'readonly']) {
  const { api } = setup(); let warning, report, download; const reads = [];
  api.readOnly = () => scenario === 'readonly';
  api.confirm = async (_title, message) => { warning = message; return scenario !== 'cancel'; };
  api.readLarge = async (...args) => {
   reads.push(args);
   if (args[0] === 'report-config') {
    if (scenario === 'partial') throw Error('secret transport error');
    return { content: '{"privateKey":"test-key"}' };
   }
   if (args[0] === 'lists-json') return { rules: 'test.example core' };
   if (args[0] === 'report-logs') return { available: true, lines: ['[Info] active', '[Debug] detail'] };
   throw Error('unexpected command');
  };
  const help = h.evaluateLuCIModule('rootfs/www/luci-static/resources/view/xraywrt/help.js', {
   E: (...args) => { const n = E(...args); if (n.tag === 'a') n.click = () => { download = n.attrs; }; return n; },
   api, view: { extend: v => v }, configuration: { render: () => E('div') }, Blob,
   URL: { createObjectURL: blob => { report = blob.text(); return 'blob:local'; }, revokeObjectURL() {} }, setTimeout: fn => fn()
  }).module;
  const page = help.render([{ version: '1.0' }, { provider_sources: { vpn: { addresses: ['192.0.2.1'] } } }, { router_model: 'Test router' }]);
  const button = nodes(page).find(n => n.tag === 'button' && n.children.includes('Download detailed report'));
  assert.deepEqual(reads, [], 'no collection on render');
  if (scenario === 'readonly') { assert(!button); continue; }
  assert(button); await button.click(); assert.match(warning, /keys, passwords and tokens/);
  if (scenario === 'cancel') { assert.deepEqual(reads, []); assert(!download); continue; }
  assert.deepEqual(reads, [['report-config'], ['lists-json'], ['report-logs']]);
  assert.equal(download.href, 'blob:local'); assert.equal(download.download, 'xraywrt-report.txt');
  const content = await report;
  for (const value of ['Test router', '192.0.2.1', 'test.example core', '[Info] active', '[Debug] detail']) assert(content.includes(value), value);
  if (scenario === 'partial') assert(content.includes('Not available') && !content.includes('secret transport error'));
  else assert(content.includes('{"privateKey":"test-key"}'));
 }
});
test('connect saved result after restart retains starting notice, partial retains warning', () => {
 const { api } = setup();
 const connected = result => JSON.parse(require('child_process').execFileSync('xraywrt-json', ['build', 'connected', '--argjson', 'result', JSON.stringify(result)], { encoding: 'utf8' }));
 const saved = connected({ action: 'saved', apply_status: 'saved', pending_reason: 'stopped', warnings: [] });
 assert.equal(api.resultNotice(saved, 'Subscription connected. XrayWRT is starting.'), 'Subscription connected. XrayWRT is starting.');
 const partial = connected({ action: 'saved', apply_status: 'partial', warnings: ['Routing needs retry'] });
 assert.equal(api.resultNotice(partial, 'Starting'), 'Routing needs retry');
});
test('partial notice survives LuCI Apply reload without immediate navigation', async () => {
 const { store, sessionStorage } = storage(); let reloads = 0;
 const { api } = setup({ sessionStorage, location: { reload: () => reloads++ } });
 api.keepResult({ apply_status: 'partial', warnings: ['Routing needs retry'] });
 assert.equal(reloads, 0);
 assert.deepEqual(JSON.parse(store['xraywrt-notice']), { text: 'Routing needs retry', type: 'warning' });
 const n = notifications(); const next = setup({ sessionStorage, ui: n.ui }).api;
 next.read = async () => ({ state: 'none' });
 next.jobNotice(); await flush();
 assert.deepEqual(n.shown, [['Routing needs retry', 'warning']]);
});
test('application results distinguish partial, stopped, degraded and old success', () => {
 const { api } = setup();
 assert.equal(api.resultNotice({ warnings: ['Unverified files'] }, 'Installed'), 'Installed Unverified files');
 assert.equal(api.resultNotice({ apply_status: 'partial', warnings: ['Routing failed'] }, 'Applied'), 'Routing failed');
 assert.match(api.resultNotice({ apply_status: 'saved', pending_reason: 'degraded' }, 'Applied'), /saved.*recover/i);
 assert.match(api.resultNotice({ apply_status: 'saved', pending_reason: 'stopped' }, 'Applied'), /saved.*start/i);
 assert.equal(api.resultNotice({ apply_status: 'saved', pending_reason: 'starting' }, 'Applied'), 'Settings saved. XrayWRT is still starting.');
 assert.equal(api.resultNotice({ action: 'restarted' }, 'Old success'), 'Old success');
 assert.equal(api.resultNotice({ action: 'unchanged', apply_status: 'saved', pending_reason: 'stopped' }, 'Configuration is unchanged.'), 'Configuration is unchanged.');
});
for (const edited of [false, true]) test('background partial retains warning across reload or edits: ' + edited, async () => {
 const { store, sessionStorage } = storage(); const listeners = {}; let reads = 0, reloads = 0;
 const { api, timers } = setup({ sessionStorage, location: { reload: () => reloads++ },
  document: { querySelectorAll: () => [], addEventListener: (type, fn) => { listeners[type] = fn; } } });
 api.read = async () => ++reads === 1 ? { id: '77-1', op: 'save-config', state: 'running' }
  : { state: 'ok', result: { apply_status: 'partial', warnings: ['Accepted, routing failed. Retry restart.'] } };
 const notice = api.jobNotice(); await flush(); if (edited) listeners.input(); await tick(timers);
 if (edited) {
  assert.match(notice.children[0].textContent, /routing failed/);
  assert.equal(notice.children[0].attrs.class, 'alert-message warning');
  assert.equal(reloads, 0);
 } else {
  const saved = JSON.parse(store['xraywrt-notice']);
  assert.equal(saved.type, 'warning'); assert.match(saved.text, /routing failed/); assert.equal(reloads, 1);
 }
});
test('unseen completed partial job is announced as warning, not success', async () => {
 const n = notifications(); const { api } = setup({ ...storage(), ui: n.ui });
 api.read = async () => ({ id: '78-1', op: 'save-config', state: 'ok', now: 100, finished: 99,
  result: { apply_status: 'partial', warnings: ['Routing needs retry'] } });
 api.jobNotice(); await flush(); assert.deepEqual(n.shown, [['Routing needs retry', 'warning']]);
});
(async () => {
	for (const [name, fn] of tests) {
		try { await fn(); console.log('ok - api ' + name); }
		catch (err) { console.error('not ok - api ' + name + ': ' + err.message); process.exitCode = 1; }
	}
})();
