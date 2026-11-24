'use strict';
'require baseclass';
'require fs';
'require ui';
'require uci';
'require request';
'require rpc';

// Single bridge between the views and /usr/bin/xraywrt. Read calls go through
// xraywrt-read so the LuCI read ACL can never run a mutating command.
const READ = '/usr/bin/xraywrt-read';
const WRITE = '/usr/bin/xraywrt';
const INIT = '/etc/init.d/xraywrt';

const CSS = `
#tabmenu > .tabs { max-width: 100%; }
.mw-page { display: flex; flex-direction: column; gap: 16px; }
.mw-toggle > [hidden], .mw-page [hidden], .mw-row[hidden] { display: none; }
.mw-page > h2 { margin-bottom: 0; }
.mw-page > .cbi-section { margin: 0; }
.mw-page h3 { margin: 0 0 8px; }
.mw-label { display: block; margin-bottom: 6px; }
.mw-status { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; margin: 0; }
.mw-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mw-row:first-child, .mw-grid .mw-row { margin-top: 0; }
.mw-grid { display: grid; grid-template-columns: minmax(0, max-content) minmax(0, 1fr); gap: 8px 16px; align-items: center; }
.mw-grid > * { min-width: 0; overflow-wrap: anywhere; }
.mw-grid select { max-width: 100%; }
.mw-balancers { table-layout: fixed; width: 100%; }
.mw-balancers td, .mw-balancers th { overflow-wrap: anywhere; }
.mw-pinned-server { text-align: start; margin: 8px 0; overflow-wrap: anywhere; }
.mw-balancers-section { padding-block: 8px; }
.mw-provider-addresses { margin-block: 8px; max-height: 14em; overflow: auto; list-style: none; padding-inline-start: 12px; }
.mw-provider-addresses li { margin: 0; }
.mw-check > div { padding: 4px 0; }
.mw-mark { display: inline-block; min-width: 1.6em; }
.mw-announce { white-space: pre-wrap; overflow-wrap: anywhere; }
.mw-announce + .mw-grid { margin-top: 12px; }
.mw-toggle > .mw-row + * { margin-top: 12px; }
:not(.mw-page) > .mw-toggle { margin-top: 12px; }
.mw-job:empty { position: absolute; }
.mw-settings > .mw-page { margin-top: 16px; }
.mw-settings .cbi-value-field select { width: auto; min-width: min-content; max-width: 100%; }
.mw-settings .cbi-value-description { overflow-wrap: anywhere; }
.mw-picker > select { flex: 1 1 12em; min-width: 0; max-width: 100%; }
.mw-picker + .cbi-value-description { margin-top: 4px; }
.mw-code { width: 100%; min-height: 24em; }
.mw-log { max-height: 30em; overflow: auto; white-space: pre-wrap; }
.mw-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
@media (max-width: 600px) { .mw-grid { grid-template-columns: minmax(0, 1fr); gap: 4px 0; } .mw-grid > label, .mw-grid > .mw-muted { margin-top: 8px; } .mw-actions { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 10em), 1fr)); align-items: stretch; } .mw-actions > .cbi-button { margin: 0; } }
`;

const JOB_LABELS = {
	'connect': _('Connecting the subscription'),
	'add-subscription': _('Adding a subscription'),
	'use-subscription': _('Switching the subscription'),
	'delete-subscription': _('Deleting the subscription'),
	'core-check': _('Checking for a core update'),
	'core-update': _('Xray core update'),
	'geodata-update': _('Rule database update'),
	'auto-update': _('Automatic update'),
	'update-subscription': _('Subscription update'),
	'update-lists': _('Remote list update'),
	'apply-lists': _('Applying lists and settings'),
	'save-config': _('Checking and applying the configuration'),
	'restore-config': _('Restoring the previous configuration'),
	'service': _('Starting, stopping or restarting XrayWRT')
};

const ACCESS_DENIED = _('Access denied. Log in to LuCI again, or ask for write access.');
const CORE_ASSET_MAX_BYTES = 67108864;
const GEODATA_NAME = /^[A-Za-z0-9._-]+\.dat$/;

function jobLabel(op) {
	return JOB_LABELS[op] || op;
}

// Only Xray's own error lines: no version banner, temp paths shortened.
function coreError(raw) {
	return String(raw ?? '').split('\n')
		.filter(l => l.trim() && !/^Xray \S+ \(|^A unified platform|^Xray rejected the configuration$/.test(l))
		.map(l => l.replace(/\/tmp\/[^\s"'<>]+/g, '…')).join('\n');
}

const LIST_TITLES = () => ({
	rules: _('My rules'),
	src: _('Devices via VPN'),
	direct_src: _('Devices always direct')
});

const ERRORS = {
	recovery_inputs: _('The latest changes could not be applied. XrayWRT is using the previous working configuration. Review the settings or update the subscription.'),
	apply_lists: _('Lists were saved, but some remote lists could not be fetched. Retry Update remote lists.'),
	apply_partial: _('Settings were accepted, but routing could not be applied. Restart XrayWRT to retry; review the system log if it fails again.'),
	apply_backup: _('The new configuration was accepted, but its backup could not be saved. Check free storage before making more changes.'),
	config_empty: _('The configuration is empty: nothing was changed.'),
	profile_invalid: _('The subscription contains invalid data and was not applied; the previous settings are kept.'),
	config_invalid: _('The configuration is invalid: %s'),
	discord_voice_accounting: _('Discord Voice inactive: enable conntrack accounting if needed (nf_conntrack_acct=1) and reload XrayWRT.'),
	dns_raw_lost: _('Forwarding of other DNS query types was turned off because its outbound became unavailable. Choose an outbound in Advanced DNS to re-enable it, or leave forwarding off.'),
	dns_raw_persist: _('DNS forwarding protection could not be saved or restored. Free storage and review Advanced DNS before trying again.'),
	dns_raw_upstream_required: _('Enter a DNS server IP[:port] for forwarding through the VPN.'),
	dns_raw_upstream_invalid: _('Enter a valid IP address with an optional port (1–65535).'),
	config_json: _('The configuration is not valid JSON.'),
	config_large: _('The configuration is larger than 8 MiB.'),
	config_missing: _('Configuration file not found: %s'),
	config_no_previous: _('There is no previous configuration.'),
	config_outbounds: _('The configuration has no outbounds.'),
	check_ip: _('Could not check: the check site is unavailable.'),
	config_rejected: _('Xray rejected the configuration.'),
	config_share: _('This link returns vless://, vmess://… links. Ask the service for an Xray JSON subscription link.'),
	config_test_oom: _('Not enough memory to check the configuration. Try again in a minute.'),
	config_yaml: _('This is Clash/Mihomo (YAML). Ask the service for an Xray JSON subscription link.'),
	core_binary: _('The core file does not run on this router. The current core is kept.'),
	core_busy: _('The core is already being updated.'),
	core_config: _('The new core does not accept your current configuration; the core was not updated. %s'),
	core_damaged: _('The downloaded core file is damaged. Try again.'),
	core_download: _('Could not download the Xray core from GitHub. Check the router\'s internet connection, or install the core by hand: apk add --allow-untrusted xraywrt-core_*.apk. Details: %s'),
	core_flash: _('Not enough free flash for the Xray core: %s MiB needed, %s MiB free.'),
	core_missing: _('The Xray core is not installed. Install it on the Updates page.'),
	core_no_checksum: _('The release does not publish a checksum for this core package, so it cannot be installed. Details: %s'),
	core_no_rollback: _('The new core did not start, and there was no backup copy of the previous one. Install a core again on the Updates page. Details: %s'),
	core_arch: _('The core is not available for this router (%s); the current core is kept.'),
	core_restart_failed: _('Core update failed: %s. Could not restart the current core.'),
	core_ram: _('Not enough free memory to download the Xray core: %s MiB needed, %s MiB available.'),
	core_removed: _('Core update failed: %s. The old core was removed without a backup. Install a core again on the Updates page.'),
	core_restart: _('The Xray core was updated, but XrayWRT could not restart: %s. Press Start on Home.'),
	core_restart_empty: _('The Xray core was updated, but XrayWRT could not restart. Press Start on Home.'),
	core_restore_failed: _('Core update failed: %s. The previous core could not be restored. Install a core again on the Updates page.'),
	core_restore_unready: _('Core update failed: %s. The previous core is restored, but did not start either.'),
	core_restored: _('The previous core is restored. Details: %s'),
	core_rollback_ram: _('Not enough free memory for a backup copy of the current core. Details: %s'),
	direct_no_domains: _('In the "Only selected sites via VPN" mode no sites are chosen: only the addresses of the subscription and of My rules go via VPN. Add sites to My rules on the What goes via VPN page.'),
	direct_no_sniffing: _('Sites of My rules that go direct are ignored: the subscription has no site recognition.'),
	dns_forwarders: _('dnsmasq forwards DNS to %s; some queries would bypass the VPN. Remove them: Network → DHCP and DNS → Forwards.'),
	dns_port_busy: _('Port 53 is used by %s; disable it, XrayWRT routes the router DNS itself.'),
	dns_tag: _('The DNS tag "%s" is renamed to %s in the routing rules.'),
	dns_wan: _('No VPN DNS is configured: the DNS servers of the internet connection (WAN) are used directly.'),
	fakedns_replaced: _('The "fakedns" section of the configuration is replaced by the one XrayWRT generates.'),
	geodata_collision: _('Geodata file %s is already supplied by the subscription. Rename your file.'),
	geodata_cron: _('The geodata schedule is invalid; 0 5 * * * is used.'),
	geodata_download: _('Could not download the geodata file %s (%s). Check the router\'s internet connection or upload the file on the Updates page.'),
	geodata_duplicate: _('Geodata file %s is listed more than once; the duplicate was skipped.'),
	geodata_entry: _('A geodata link was skipped: use NAME.dat and an HTTPS URL without spaces.'),
	geodata_path: _('The geodata file name or path is unsafe. No files were replaced.'),
	geodata_ram: _('Not enough router memory to check the geodata files. No files were replaced.'),
	geodata_size: _('The geodata file is empty or too large. No files were replaced.'),
	geodata_space: _('Not enough router storage for the geodata update and backup. No files were replaced.'),
	geodata_rollback: _('The previous geodata could not be restored. Backup files were kept. Do not delete them; free router storage and restart XrayWRT.'),
	geodata_unverified: _('These files are not used by the current settings, so they cannot be checked now. They will be checked when settings start using them.'),
	geodata_incomplete: _('%s saved. %s is still missing; upload it to finish.'),
	geodata_finalize: _('The geodata update could not be finalized. Restart XrayWRT to finish recovery; this may restore the previous files. Do not delete backup files.'),
	geodata_check: _('The router core rejected the geodata files with your settings. No files were replaced.'),
	geodata_write: _('The geodata update could not be saved. The previous files were kept.'),
	geodata_provider_cron: _('The subscription asks for a rule database update schedule "%s" that is invalid or more frequent than daily; %s is used instead.'),
	geodata_restart_rollback: _('The previous geodata was restored, but XrayWRT could not restart. Traffic may go direct. Restart XrayWRT and check the system log.'),
	geodata_restart: _('The new geodata could not be applied. The previous files were restored.'),
	geodata_missing: _('The configuration needs %s, but the subscription does not supply it. Upload the file on the Updates page.'),
	inbound_listen: _('Inbound %s now listens on the router only (127.0.0.1): a subscription must not open ports on the network.'),
	inbound_duplicate: _('Inbound %s was removed: its address and port are already used by another inbound.'),
	inbound_socket: _('Inbound %s was removed: a subscription must not listen on a file.'),
	inbound_tun: _('Inbound %s (tun) was removed: the router uses TPROXY.'),
	list_invalid: _('"%s" has invalid lines: %s'),
	list_large: _('The "%s" list is larger than 1 MiB.'),
	lists_large: _('The remote lists are larger than 8 MiB in total. Remove some list links or use smaller lists.'),
	lists_update: _('Could not update %s of %s remote lists: %s'),
	master_key_log: _('The subscription asked Xray to write TLS keys to a file; this was removed.'),
	nft_policy: _('Failed to apply nftables policy: see %s. Restart XrayWRT; if it happens again, see the log on Help.'),
	not_running: _('Xray is not running'),
	operation_busy: _('Another operation is running: "%s". Wait until it finishes.'),
	operation_interrupted: _('The operation was interrupted (for example, by a router reboot). You can run it again.'),
	outbound_mark: _('The outbound "%s" had the mark %s; XrayWRT replaced it with %s.'),
	rule_ignored: _('Line %s of My rules ("%s") is not valid and was ignored.'),
	rules_bad_entry: _('Line %s of My rules (%s) is not a site, an IP address, a subnet or a list link followed by one target. Write a site as its bare name, for example example.com.'),
	rules_qualified_domain_core: _('Line %s of My rules (%s): a site with ports or protocol cannot use core. Use direct or a named target.'),
	rules_limit: _('My rules has more than %s sites; the rest is ignored.'),
	rules_no_target: _('Line %s of My rules (%s) has no target. Add a space and one of: %s.'),
	rules_target_missing: _('These targets of My rules are not in the configuration, so the lines that name them are skipped: %s.'),
	rules_sniff_override: _('Qualified named address selectors incompatible with sniffing were skipped. Specify a safe protocol or use direct or core.'),
	rules_too_large: _('The rule for "%s" in My rules has more than %s addresses and was skipped. Use fewer or smaller lists.'),
	rules_too_many: _('My rules has more than %s sites.'),
	rules_unknown_target: _('Line %s of My rules (%s): there is no target "%s". Use one of: %s.'),
	profile_missing: _('Server "%s" is not in the configuration; "%s" is used.'),
	provider_no_sniffing: _('The subscription has no site recognition: domain rules see only IP addresses.'),
	router_profile_missing: _('The subscription selects server "%s", but it is missing from the configuration.'),
	routing_apply: _('Xray started, but the routing rules could not be applied: %s'),
	runtime_busy: _('The router is busy with another task (process %s). Try again in a minute.'),
	service_start: _('XrayWRT could not start. See the log on the Help page.'),
	setting_ignored: _('The subscription setting "%s" is unknown or invalid and was ignored.'),
	settings_invalid: _('XrayWRT settings are damaged. Save the Advanced page again or reinstall the package.'),
	subscription_access: _('The provider refused access (HTTP %s). The subscription may have expired or the link is wrong.'),
	subscription_repair: _('Cannot finish an interrupted subscription switch. Free some space on the router (delete a subscription you do not use) and try again.'),
	subscription_changed: _('The active subscription changed during the download. Nothing was changed; try again.'),
	subscription_exists: _('This link is already saved as another subscription.'),
	subscription_active: _('Switch to another subscription before deleting the active one.'),
	subscription_empty: _('The subscription returned an empty configuration.'),
	subscription_http: _('The provider server answered with an error (HTTP %s). Try again later.'),
	subscription_large: _('The subscription is too large.'),
	subscription_missing: _('This subscription is not saved on the router.'),
	subscription_network: _('The router cannot reach the subscription server. Check the internet connection and the link. (%s)'),
	subscription_not_found: _('Subscription not found (HTTP 404). Check the link in your service account.'),
	subscription_stale: _('The subscription was switched, but its update failed. The saved configuration is in use.'),
	subscription_url: _('Enter the subscription link that starts with https://'),
};

function codedErrorText(message) {
	const raw = String(message ?? '');
	const match = / \[E:([a-z0-9_]+)((?:\|[^|\]]*)*)\]$/.exec(raw);
	if (!match) return raw;
	const plain = raw.slice(0, match.index);
	if (!Object.prototype.hasOwnProperty.call(ERRORS, match[1])) return plain;
	const args = match[2] ? match[2].slice(1).split('|') : [];
	if (args.length !== (ERRORS[match[1]].match(/%s/g) || []).length) return plain;
	if (match[1] === 'operation_busy') args[0] = jobLabel(args[0]);
	if (['list_large', 'list_invalid'].includes(match[1])) args[0] = LIST_TITLES()[args[0]] || args[0];
	if (match[1] === 'list_invalid')
		args[1] = args[1].replace(/\((\d+) total\)$/, (suffix, n) => _('(%d in total)').format(n));
	const translated = ERRORS[match[1]].format(...args).trim();
	if (match[1] === 'config_rejected') {
		const details = coreError(plain.replace(/(?:^|\n)Xray rejected the configuration$/, ''));
		return translated + (details ? '\n' + details : '');
	}
	return translated;
}

function jobErrorText(op, message) {
	const mapped = codedErrorText(message);
	return ['save-config', 'restore-config', 'connect', 'add-subscription', 'use-subscription', 'update-subscription', 'auto-update'].includes(op)
		&& / \[E:config_(rejected|test_oom)\]$/.test(String(message).trim())
		? mapped + '\n' + _('Nothing was changed, the previous configuration is still running.') : mapped;
}

// Installed core source (spec 15): <version> (package).
function coreOrigin(src) {
	if (src?.source === 'package')
		return _('%s (package)').format(src.version || '—');
	return '—';
}

function errorText(res) {
	const output = res?.stderr || res?.stdout;
	const message = String(output || res?.message || (typeof res === 'string' ? res : '')).replace(/^Error: /gm, '').trim();
	// Backend output is not a LuCI transport error, even if it mentions one.
	if (output || res?.name === 'CommandError' || res?.name === 'JobError')
		return codedErrorText(message) || _('Unknown error');
	if (res?.name === 'TimeoutError' || (res?.name === 'Error' && message === 'XHR request timed out'))
		return _('The router did not answer in time. The operation may still be running; check again in a minute.');
	// An expired session reaches us as SessionError, or as rpc error -32002.
	if (res?.name === 'PermissionError' || res?.name === 'SessionError' || (res?.name === 'Error' && message === 'Access denied')
		|| (res?.name === 'RPCError' && /failed with (?:ubus code 6:|HTTP error 403:|error -32002:)/.test(message)))
		return ACCESS_DENIED;
	return codedErrorText(message) || _('Unknown error');
}

async function exec(bin, args) {
	let res;
	try {
		res = await fs.exec(bin, args);
	}
	catch (e) {
		throw new Error(errorText(e));
	}
	return res;
}

async function run(bin, args) {
	const res = await exec(bin, args);
	if (res.code !== 0)
		throw Object.assign(new Error(errorText(res)), { name: 'CommandError' });
	return res.stdout || '';
}

async function json(bin, args) {
	const out = await run(bin, args);
	try {
		return JSON.parse(out || '{}');
	}
	catch (e) {
		throw new Error(_('Unexpected response from the router: %s').format(out.slice(0, 200)));
	}
}

async function readLarge(cmd, ...args) {
	let reply;
	try {
		// Config exports with keys are for the write role only.
		reply = await fs.exec_direct(['read-config', 'report-config', 'report-logs'].includes(cmd) ? WRITE : READ, [ cmd, ...args ], 'json');
	}
	catch (e) {
		if (e.name === 'SyntaxError')
			throw new Error(_('Unexpected response from the router.'));
		throw e;
	}
	if (!reply || typeof reply !== 'object')
		throw new Error(_('Unexpected response from the router.'));
	return reply;
}

async function checkJson(args) {
	const res = await exec(WRITE, args);
	try {
		const reply = JSON.parse(res.stdout || '');
		if (reply && typeof reply === 'object')
			return reply;
	}
	catch (e) {}
	throw Object.assign(new Error(errorText(res)), { name: 'CommandError' });
}

function randomSuffix() {
	return Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
}

let waitingJobs = 0;
let jobButtonLocks = 0;
const jobButtons = new Map();

// Shared by job(), busy() preparation, and jobs discovered at page load.
function lockJobButtons() {
	jobButtonLocks++;
	for (const button of document.querySelectorAll?.('[data-mw-job]') || []) {
		if (!jobButtons.has(button))
			jobButtons.set(button, button.disabled);
		button.disabled = true;
	}
}

function unlockJobButtons() {
	if (--jobButtonLocks > 0)
		return;
	for (const [ button, disabled ] of jobButtons)
		button.disabled = disabled;
	jobButtons.clear();
}

// Every poll forks the backend on the router: poll gently.
async function waitJob(api, id, op) {
	let failures = 0;
	for (;;) {
		await new Promise(resolve => setTimeout(resolve, 2000));
		let status;
		try {
			status = await api.read('job-status', id);
			failures = 0;
		}
		catch (e) {
			if (++failures < 5)
				continue;
			throw new Error(errorText(e) === ACCESS_DENIED ? ACCESS_DENIED
				: _('Lost connection to the router while waiting for the result.'));
		}
		if (status.state === 'ok')
			return status.result;
		if (status.state === 'error')
			throw Object.assign(new Error(jobErrorText(op, status.error)), { name: 'JobError' });
	}
}

function reportText(data) {
	const st = data.status || {}, d = data.diagnostics || {};
	const version = v => typeof v === 'string' && /^v?[0-9]+(?:\.[0-9]+){1,4}(?:-[0-9]+)?(?:-r[0-9]+)?$/.test(v) ? v : '—';
	const state = st.state || (st.running ? 'running' : 'stopped');
	const states = { running: _('Service is running'), stopped: _('XrayWRT is not running'),
		failed: _('Stopped because of an error.'), starting: _('Starting…'), degraded: _('Degraded') };
	const model = typeof d.router_model === 'string' ? d.router_model.replace(/[\x00-\x1f\x7f]/g, ' ').trim() : '';
	const rows = [ _('Router model') + ': ' + (model || '—'),
		_('XrayWRT version') + ': ' + version(st.version),
		_('Core version') + ': ' + version(st.core),
		_('Traffic mode') + ': ' + (['direct-first', 'proxy-first'].includes(st.mode) ? modeLabel(st.mode) : '—'),
		_('Service') + ': ' + (states[state] || '—') ];
	for (const key of ['dns_hijack', 'disable_quic', 'bypass_ntp', 'bypass_subscription_dns', 'block_client_ipv6', 'enabled']) {
		const value = st.flags?.[key];
		if (typeof value === 'boolean')
			rows.push(key + ': ' + (value ? _('yes') : _('no')));
	}
	const problems = [];
	const add = (label, hint) => problems.push('- ' + label + '\n  ' + hint);
	const hasCode = (message, code) => new RegExp(' \\[E:' + code + '(?:\\|[^\\]]*)?\\]$').test(String(message || '').trim());
	const settingsInvalid = (st.errors || []).some(error => hasCode(error, 'settings_invalid'));
	const dnsPortBusy = hasCode(d.dns_guard_error, 'dns_port_busy');
	if (settingsInvalid)
		add(_('XrayWRT settings are damaged.'), _('Save the Advanced page again or reinstall the package.'));
	if (dnsPortBusy)
		add(_('Port 53 is occupied.'), _('Disable the other DNS service.'));
	if (!st.core_installed)
		add(_('Xray core is not installed'), _('Open the Updates page and install the core.'));
	else if (st.config_valid === false)
		add(_('Config has errors'), _('Update the subscription or fix the config in Advanced.'));
	else if ((state === 'stopped' || state === 'failed') && !settingsInvalid && !dnsPortBusy)
		add(_('XrayWRT is not running'), _('Press Start on Home.'));
	if (st.subscription_insecure)
		add(_('The subscription link uses plain http'), _('Anyone on the way can change your configuration. Ask your provider for an https link.'));
	if (state === 'degraded') {
		if (st.degraded_reason === 'observatory')
			add(_('The VPN server is not responding (provider check)'), _('Internet traffic goes directly until the VPN recovers.'));
		else
			add(_('Xray DNS does not answer: traffic goes direct until it recovers'), _('Xray cannot resolve names: check that the VPN servers and DNS servers in the config are reachable.'));
	}
	else if (state === 'running' && st.dns_ok === false)
		add(_('Xray does not answer DNS queries'), _('Xray cannot resolve names: check that the VPN servers and DNS servers in the config are reachable.'));
	if ((state === 'running' || state === 'degraded') && !st.policy_active)
		add(_('Traffic rules are not active'), _('Restart the service; if it persists, see the log.'));
	if ((st.custom_dns_servers || []).length)
		add(_('dnsmasq has its own upstream servers'), _('These servers answer next to Xray, so some sites may bypass the VPN. Remove them from Network → DHCP and DNS.'));
	if ((d.conflicts || []).length)
		add(_('Other VPN packages are installed'), _('These packages also change DNS and the firewall. Use only one VPN package at a time.'));
	if (typeof d.flash_free_kb === 'number' && isFinite(d.flash_free_kb) && d.flash_free_kb < 5120)
		add(_('Little free flash: %d MB').format(Math.floor(d.flash_free_kb / 1024)), _('Free some space or the core update may fail.'));
	if (typeof d.ram_available_kb === 'number' && isFinite(d.ram_available_kb) && d.ram_available_kb < 20480)
		add(_('Little free memory: %d MB').format(Math.floor(d.ram_available_kb / 1024)), _('Xray may be stopped by the system when memory runs out. Stop other services or use a smaller configuration.'));
	return rows.join('\n') + '\n\n' + (problems.length ? problems.join('\n') : _('No known problems found.'));
}

// Add or drop `name` in the list of options the user keeps (provider_override).
function setProviderOverride(sid, name, own) {
	const list = [].concat(uci.get('xraywrt', 'settings', 'provider_override') || []).filter((v) => v !== name);
	if (own)
		list.push(name);
	if (list.length)
		uci.set('xraywrt', sid, 'provider_override', list);
	else
		uci.unset('xraywrt', sid, 'provider_override');
}

function intervalLabel(value) {
	return String(value) === '0' ? _('Off (only manually)')
		: String(value) === '168' ? _('7 days') : _('%s h').format(value);
}

function modeLabel(mode) {
	return mode === 'proxy-first' ? _('Everything via VPN except exclusions')
		: mode === 'direct-first' ? _('Only selected sites via VPN')
		: _('unknown');
}

// Provider links as theme buttons (some themes leave a.cbi-button unstyled).
function linkButton(url, label) {
	if (!/^https?:\/\//i.test(String(url || '')))
		return null;
	const button = E('button', { class: 'cbi-button', type: 'button' }, text(label));
	button.addEventListener('click', () => window.open(String(url), '_blank', 'noopener,noreferrer'));
	return button;
}

function infoGrid(rows) {
	return E('div', { class: 'mw-grid' }, rows.flatMap(([ k, v ]) => [ E('span', { class: 'mw-muted' }, text(k)), E('span', text(v)) ]));
}

function actionNotice(action) {
	return action === 'unchanged' ? _('Subscription is up to date.')
		: action === 'restarted' ? _('Subscription updated; XrayWRT restarted.')
		: action === 'hot_reloaded' ? _('Subscription updated without restarting Xray.') : _('Subscription updated.');
}

function resultNotice(result, fallback) {
	if (result?.warnings?.length)
		return [result.apply_status === 'partial' ? null : fallback, ...result.warnings.map(errorText)].filter(Boolean).join(' ');
	if (result?.apply_status === 'partial')
		return (result.warnings || []).map(errorText).join(' ') || ERRORS.apply_partial;
	if (result?.apply_status === 'saved' && result.action !== 'unchanged') {
		if (result.pending_reason === 'starting') return _('Settings saved. XrayWRT is still starting.');
		return result.pending_reason === 'degraded'
			? _('Settings saved. Traffic stays direct until the VPN recovers; XrayWRT will apply them automatically.')
			: _('Settings saved. Start XrayWRT to apply them.');
	}
	return fallback;
}

// Values from providers are untrusted: they always become text nodes.
function text(value) {
	return [ String(value ?? '') ];
}

function formatBytes(value) {
	let n = Number(value);
	const units = [ _('B'), _('KB'), _('MB'), _('GB'), _('TB') ];
	let i = 0;

	if (!Number.isFinite(n) || n < 0)
		return '';
	while ((i ? Math.round(n * 10) / 10 : n) >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	let lang;
	try {
		lang = typeof document !== 'undefined' ? document.documentElement?.lang : undefined;
	}
	catch (e) {}
	const formatted = i
		? (lang && /^ru\b/i.test(lang)
			? n.toFixed(1).replace('.', ',')
			: n.toLocaleString(lang || undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 }))
		: String(n);
	return '%s %s'.format(formatted, units[i]);
}

// Dates follow the LuCI language, not the browser's.
function formatDate(epoch) {
	const n = Number(epoch);
	if (!Number.isFinite(n) || n <= 0)
		return '';
	try {
		return new Date(n * 1000).toLocaleString(document.documentElement.lang || undefined, { dateStyle: 'medium', timeStyle: 'short' });
	}
	catch (e) {
		return new Date(n * 1000).toLocaleString();
	}
}

// Traffic line for a subscription. Missing total means unlimited; missing
// usage means unknown.
function trafficSummary(sub) {
	const hasUsage = sub?.upload != null || sub?.download != null;
	const used = (Number(sub?.upload) || 0) + (Number(sub?.download) || 0);
	const total = (sub?.total != null && Number(sub.total) > 0) ? formatBytes(sub.total) : _('Unlimited');

	return hasUsage ? '%s / %s'.format(formatBytes(used), total) : total;
}

function safeLink(url, label) {
	return /^https?:\/\//i.test(String(url || ''))
		? E('a', { href: String(url), target: '_blank', rel: 'noopener noreferrer' }, text(label))
		: null;
}

// Show/hide a block with a theme button (no <details>: some themes hide
// its marker). onOpen runs on every opening by the button; startOpen skips it.
let toggleCount = 0;
function toggle(showLabel, hideLabel, content, onOpen, startOpen = false) {
	const id = 'mw-toggle-' + (++toggleCount);
	const button = E('button', { class: 'cbi-button', type: 'button', 'aria-expanded': String(startOpen), 'aria-controls': id }, text(startOpen ? hideLabel : showLabel));
	content.setAttribute('id', id);
	content.hidden = !startOpen;
	button.addEventListener('click', () => {
		content.hidden = !content.hidden;
		button.textContent = content.hidden ? showLabel : hideLabel;
		button.setAttribute('aria-expanded', content.hidden ? 'false' : 'true');
		if (!content.hidden && onOpen)
			onOpen();
	});
	return E('div', { class: 'mw-toggle' }, [ E('div', { class: 'mw-row' }, [ button ]), content ]);
}

function confirm(title, body, okLabel, { danger = false } = {}) {
	return new Promise(resolve => {
		let settled = false;
		const finish = value => {
			if (settled)
				return;
			settled = true;
			ui.hideModal();
			resolve(value);
		};
		const cancel = E('button', { class: 'cbi-button', type: 'button' }, text(_('Cancel')));
		const ok = E('button', { class: 'cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-action'), type: 'button' }, text(okLabel));
		cancel.addEventListener('click', () => finish(false));
		ok.addEventListener('click', () => finish(true));
		ui.showModal(title, [
			E('p', text(body)),
			E('div', { class: 'mw-row right', style: 'justify-content: flex-end;' }, [ cancel, ' ', ok ])
		]);
	});
}

// Disable a button while an async action runs; report failures.
async function busy(button, action) {
	const startsJob = button?.hasAttribute('data-mw-job');
	if (button?.disabled || (startsJob && this.jobRunning))
		return null;
	if (startsJob)
		lockJobButtons();
	if (button) {
		button.disabled = true;
		button.classList.add('spinning');
	}
	try {
		return await action();
	}
	catch (e) {
		notify(errorText(e), 'error');
		return null;
	}
	finally {
		if (button) {
			if (!startsJob)
				button.disabled = false;
			button.classList.remove('spinning');
		}
		if (startsJob)
			unlockJobButtons();
	}
}

// The LuCI banner has no role: announce it to screen readers.
function notify(message, level) {
	const node = ui.addNotification(null, E('p', text(message)), level || 'info');
	node?.setAttribute?.('role', level === 'error' ? 'alert' : 'status');
}

const NOTICE_KEY = 'xraywrt-notice';
// Last job whose result a page already showed (or waited for).
const SEEN_JOB_KEY = 'xraywrt-seen-job';
const JOB_ERROR_WINDOW = 600;

function markJobSeen(id) {
	try {
		sessionStorage.setItem(SEEN_JOB_KEY, String(id));
	}
	catch (e) {
		// No session storage: a later page may show the error once more.
	}
}

function jobSeen(id) {
	try {
		return sessionStorage.getItem(SEEN_JOB_KEY) === String(id);
	}
	catch (e) {
		// Without session storage the notice cannot be shown exactly once.
		return true;
	}
}

function keepNotice(message, level) {
	try {
		sessionStorage.setItem(NOTICE_KEY, JSON.stringify({ text: String(message ?? ''), type: level || 'info' }));
	}
	catch (e) {
		notify(message, level);
	}
}

function showPendingNotice() {
	try {
		const raw = sessionStorage.getItem(NOTICE_KEY);
		sessionStorage.removeItem(NOTICE_KEY);
		const pending = raw ? JSON.parse(raw) : null;
		if (pending?.text)
			notify(pending.text, pending.type);
	}
	catch (e) {
		// No session storage or a damaged value: there is no notice to show.
	}
}

function style() {
	return E('style', text(CSS));
}

// A rejected load() leaves LuCI on "Loading view…" under a red banner: keep the
// failure for render() and show it inline with a way to retry.
const LOAD_FAILED = Symbol('load failed');

function guardView(definition, title) {
	const { load, render } = definition;
	return Object.assign({}, definition, {
		load: function() {
			return Promise.resolve().then(() => load.apply(this, arguments)).catch((e) => ({ [LOAD_FAILED]: e }));
		},
		render: function(data) {
			if (!data?.[LOAD_FAILED])
				return render.apply(this, arguments);
			const again = E('button', { class: 'cbi-button', type: 'button' }, text(_('Try again')));
			again.addEventListener('click', () => location.reload());
			return E('div', { class: 'mw-page' }, [
				style(),
				E('h2', text(title)),
				E('div', { class: 'alert-message error', role: 'alert' }, [
					E('p', text(_('Cannot load the page: %s').format(errorText(data[LOAD_FAILED])))),
					again
				])
			]);
		}
	});
}

return baseclass.extend({
	// The subscription link is a credential: xraywrt-read masks it, only a user with the write ACL gets it whole.
	read: function(cmd, ...args) { return json(cmd === 'subscription-json' && !this.readOnly() ? WRITE : READ, [ cmd, ...args ]); },
	status: function() { return this.read('status-json'); },
	profiles: function() { return this.read('profiles'); },
	balancers: function() { return this.read('balancers'); },
	balancerSet: function(tag, target) { return this.write('balancer-set', tag, target); },
	runtimeConfig: function() { return this.readLarge('runtime-config'); },
	// config-check prints its JSON also when it fails.
	configCheck: (path) => checkJson([ 'config-check', ...(path ? [ path ] : []) ]),
	// The GitHub query can outlast the LuCI rpc timeout: a job.
	coreCheck: function() { return this.job('core-check'); },
	coreUpdate: function({ noRollback } = {}) {
		return this.job('core-update', ...(noRollback ? [ '--no-rollback' ] : []));
	},
	geodataUpdate: function({ force, file, name } = {}) {
		return this.job('geodata-update', ...(file ? [ '--file', file, '--name', name ] : force ? [ '--force' ] : []));
	},
	CORE_ASSET_MAX_BYTES,
	GEODATA_NAME,
	write: (cmd, ...args) => json(WRITE, [ cmd, ...args ]),
	service: (action) => run(INIT, [ action ]),
	// A provider-controlled option: the first choice follows the provider, the others
	// are own values. The provider choice changes only the override list, never the
	// saved own value. `choice` is the first choice's text from a caller that explains
	// it itself: no generic note and no reset button then.
	setProviderOverride,
	providerScalar: function(profile, type, name, make, choice) {
		const provider = profile.provider || {};
		if (!(name in provider) && choice == null)
			return make();

		const o = make(type);
		const overrides = () => [].concat(uci.get('xraywrt', 'settings', 'provider_override') || []);
		const generic = choice == null;
		if (generic) {
			const value = name === 'lists_interval' ? intervalLabel(provider[name])
				: name === 'core_log_level' ? o.vallist[o.keylist.indexOf(provider[name])]
				: provider[name] === '1' ? _('Enabled') : _('Disabled');
			choice = _('From subscription: %s').format(value);
		}
		o.value('provider', choice);
		// Keep the provider choice first, followed by the ordinary choices.
		o.keylist.unshift(o.keylist.pop());
		o.vallist.unshift(o.vallist.pop());
		o.cfgvalue = () => overrides().includes(name)
			? uci.get('xraywrt', 'settings', name) ?? o.default : 'provider';
		o.write = (sid, value) => {
			if (value !== 'provider')
				uci.set('xraywrt', sid, name, value);
			setProviderOverride(sid, name, value !== 'provider');
		};
		o.remove = (sid) => o.write(sid, 'provider');
		if (generic && overrides().includes(name)) {
			o.description += ' ' + _('Your override.');
			const render = o.renderWidget;
			const api = this;
			o.renderWidget = function(sid) {
				const reset = E('button', { type: 'button', class: 'cbi-button cbi-button-reset', disabled: api.jobRunning || null }, text(_('Use subscription setting')));
				reset.addEventListener('click', () => api.busy(reset, async () => {
					o.write(sid, 'provider');
					await uci.save();
					return ui.changes.apply(true);
				}));
				return E('div', {}, [ render.apply(this, arguments), ...(api.readOnly() ? [] : [ reset ]) ]);
			};
		}
		return o;
	},
	jobRunning: false,
	jobLabel,
	// C16: the LuCI ACL gives this user read access only.
	readOnly: () => L.hasViewPermission?.() === false,
	job: async function(op, ...args) {
		for (const el of document.querySelectorAll?.('.mw-job') || [])
			el.replaceChildren ? el.replaceChildren() : (el.innerHTML = '');
		waitingJobs++;
		this.jobRunning = true;
		lockJobButtons();
		for (const el of document.querySelectorAll?.('.mw-job') || []) {
			const alert = E('div', { class: 'alert-message notice' }, [
				_('"%s" is running…').format(this.jobLabel(op)), ' ',
				E('span', { class: 'mw-muted' }, text(_('You can close the page — the operation continues on the router.')))
			]);
			el.replaceChildren ? el.replaceChildren(alert) : el.appendChild?.(alert);
		}
		try {
			const started = await this.write('job-start', op, ...args);
			let result;
			try {
				result = await waitJob(this, started.id, op);
			}
			catch (e) {
				if (e.name === 'JobError')
					markJobSeen(started.id);
				throw e;
			}
			markJobSeen(started.id);
			return result;
		}
		finally {
			for (const el of document.querySelectorAll?.('.mw-job') || [])
				el.replaceChildren ? el.replaceChildren() : (el.innerHTML = '');
			this.jobRunning = --waitingJobs > 0;
			unlockJobButtons();
		}
	},
	// A notice shown right before location.reload() is lost: keep it for the next page load.
	reloadWithNotice: (message, level) => {
		keepNotice(message, level);
		location.reload();
	},
	keepResult: result => keepNotice(resultNotice(result), result.apply_status === 'partial' ? 'warning' : 'info'),
	resultNotice,
	reloadResult: function(result, fallback) {
		if (!result?.apply_status && !result?.warnings?.length) return this.reloadWithNotice(fallback);
		this.reloadWithNotice(resultNotice(result, fallback), result.apply_status === 'partial' || result.warnings?.length ? 'warning' : 'info');
	},
	notifyResult: function(result, fallback) {
		if (!result?.apply_status) return this.notify(fallback);
		this.notify(resultNotice(result, fallback), result.apply_status === 'partial' ? 'warning' : 'info');
	},
	jobNotice: function() {
		showPendingNotice();
		const notice = E('div', { class: 'mw-job', 'aria-live': 'polite' });
		// A reload would lose what the user typed meanwhile.
		let edited = false, alert;
		document.addEventListener?.('input', () => { edited = true; }, { once: true });
		const keepEdits = message => {
			alert.textContent = message;
			this.jobRunning = waitingJobs > 0;
			unlockJobButtons();
		};
		const failed = (status, error) => _('"%s" failed: %s').format(this.jobLabel(status.op), jobErrorText(status.op, error));
		this.read('job-status').then(async status => {
			// A job that failed while no page waited for it: show it once.
			if (status.state === 'error' && status.id && !jobSeen(status.id)
				&& Number(status.now ?? Date.now() / 1000) - Number(status.finished) <= JOB_ERROR_WINDOW) {
				markJobSeen(status.id);
				notify(failed(status, status.error || _('The operation failed.')), 'error');
				return;
			}
			if (status.state === 'ok' && (status.result?.apply_status === 'partial' || status.result?.warnings?.length) && status.id && !jobSeen(status.id)
				&& Number(status.now ?? Date.now() / 1000) - Number(status.finished) <= JOB_ERROR_WINDOW) {
				markJobSeen(status.id);
				notify(resultNotice(status.result), 'warning');
			}
			if (status.state !== 'running')
				return;
			this.jobRunning = true;
			lockJobButtons();
			alert = E('div', { class: 'alert-message notice' }, [
				_('"%s" is running…').format(this.jobLabel(status.op)), ' ',
				E('span', { class: 'mw-muted' }, text(_('You can close the page — the operation continues on the router.')))
			]);
			notice.appendChild(alert);
			let result;
			try {
				result = await waitJob(this, status.id, status.op);
			}
			catch (e) {
				// A terminal job error still requires fresh page data. A lost
				// connection does not: keep its recovery message visible.
				if (e.name !== 'JobError') {
					keepEdits(errorText(e));
					return;
				}
				markJobSeen(status.id);
				const message = failed(status, e.message || _('The operation failed.'));
				if (edited)
					keepEdits(message);
				else
					this.reloadWithNotice(message, 'error');
				return;
			}
			markJobSeen(status.id);
			if (edited) {
				keepEdits(resultNotice(result, _('"%s" finished. Reload the page to see the result; your unsaved edits are still here.').format(this.jobLabel(status.op))));
				if (result?.apply_status === 'partial') alert.setAttribute('class', 'alert-message warning');
			}
			else if (result?.apply_status || result?.warnings?.length)
				this.reloadResult(result, _('Operation finished.'));
			else
				location.reload();
		}).catch(e => {
			notice.appendChild(E('div', { class: 'alert-message notice' }, text(errorText(e))));
		});
		return notice;
	},
	upload: async (prefix, content) => {
		if (![ 'xraywrt-config', 'xraywrt-policy-list', 'xraywrt-geodata' ].includes(prefix))
			throw new Error(_('Invalid upload path.'));
		const path = '/tmp/%s.%s'.format(prefix, randomSuffix());
		// cgi-upload refuses empty files; a blank line means an empty list to the backend.
		const blob = content instanceof Blob ? content : new Blob([ content === '' ? '\n' : content ]);
		const data = new FormData();
		data.append('sessionid', rpc.getSessionID());
		data.append('filename', path);
		data.append('filedata', blob);
		const response = await request.post(L.env.cgi_base + '/cgi-upload', data, { timeout: 0 });
		if (!response.ok || response.status !== 200)
			throw new Error(response.status === 403 ? ACCESS_DENIED : _('Unexpected response from the router.'));
		let reply;
		try {
			reply = response.json();
		}
		catch (e) {
			if (e.name === 'SyntaxError')
				throw new Error(_('Unexpected response from the router.'));
			throw e;
		}
		if (reply?.failure)
			throw new Error(_('The upload failed. Check your LuCI permissions and try again.'));
		if (reply?.size !== blob.size)
			throw new Error(_('The upload was incomplete. Try again.'));
		return path;
	},
	readLarge,
	intervalLabel,
	modeLabel,
	reportText,
	LIST_TITLES,
	linkButton,
	infoGrid,
	guardView,
	actionNotice,
	confirm,
	errorText,
	coreError,
	coreOrigin,
	text,
	formatBytes,
	formatDate,
	trafficSummary,
	safeLink,
	toggle,
	connect: async function(link) {
		if (!/^https?:\/\//i.test(link))
			throw new Error(_('Enter the subscription link that starts with https://'));
		const res = await this.job('connect', link);
		await new Promise(resolve => setTimeout(resolve, 1500));
		this.reloadResult(res, _('Subscription connected. XrayWRT is starting.'));
	},
	busy,
	notify,
	style
});
