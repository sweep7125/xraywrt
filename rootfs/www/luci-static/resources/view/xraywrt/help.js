'use strict';
'require view';
'require xraywrt.configuration as configuration';
'require xraywrt.api as api';

const text = api.text;

// Each check: passed? (null = unknown), label, hint shown when it fails.
function checks(st, diagnostics) {
	const state = st.state || (st.running ? 'running' : 'stopped');
	const up = state === 'running' || state === 'degraded';
	let serviceHint;
	if (!st.core_installed)
		serviceHint = _('Install the Xray core first (Updates page).');
	else if (st.config_valid === false)
		serviceHint = _('Fix the configuration first (see the item above), then press Start on Home.');
	else if (state === 'failed')
		serviceHint = _('Press Start on Home. If it stops again, check the log below.') +
			(st.last_error ? '\n' + _('Last error: %s').format(api.errorText(st.last_error)) : '');
	else
		serviceHint = _('Press Start on Home.');
	const kb = (value) => typeof value === 'number' && isFinite(value) ? value : null;
	const flash = kb(diagnostics?.flash_free_kb);
	const ram = kb(diagnostics?.ram_available_kb);
	const coreOk = !!st.core_installed;
	const list = [
		[ coreOk, coreOk ? _('Xray core installed') + (st.core ? ' (%s)'.format(st.core) : '') : _('Xray core is not installed'),
			_('Open the Updates page and install the core.') ],
		(!coreOk || st.config_valid == null)
			? [ null, _('Configuration not checked yet (it is checked at start)'), '' ]
			: [ st.config_valid, st.config_valid ? _('Configuration is valid') : _('Configuration has errors'),
				_('Update the subscription or fix the configuration on the Advanced page.') +
				(st.config_error ? '\n' + _('Xray says: %s').format(api.coreError(st.config_error)) : '') ],
		[ st.subscription_configured || null,
			st.subscription_configured ? _('Subscription configured') : _('No subscription: your own configuration is used'), '' ],
		state === 'starting' ? [ null, _('Starting…'), '' ] : [ up, up ? _('Service is running') : _('XrayWRT is not running'), serviceHint ]
	];
	if (st.subscription_insecure)
		list.push([ false, _('The subscription link uses plain http'),
			_('Anyone on the way can change your configuration. Ask your provider for an https link.') ]);
	if (state === 'degraded')
		list.push(st.degraded_reason === 'observatory'
			? [ false, _('The VPN server is not responding (provider check)'),
				_('Internet traffic goes directly until the VPN recovers.') ]
			: [ false, _('Xray DNS does not answer: traffic goes direct until it recovers'),
				_('Xray cannot resolve names: check that the VPN servers and DNS servers in the config are reachable.') ]);
	if (up) {
		if (state !== 'degraded') {
			const dnsOk = st.dns_ok == null ? null : st.dns_ok === true;
			list.push([ dnsOk, dnsOk === false ? _('Xray does not answer DNS queries') : _('Xray answers DNS queries'),
				_('Xray cannot resolve names: check that the VPN servers and DNS servers in the config are reachable.') ]);
		}
		const policyOk = !!st.policy_active;
		list.push([ policyOk, policyOk ? _('Traffic rules are active') : _('Traffic rules are not active'), _('Restart the service; if it persists, see the log.') ]);
	}
	if ((st.custom_dns_servers || []).length)
		list.push([ false, _('dnsmasq has its own upstream servers: %s').format(st.custom_dns_servers.join(', ')),
			_('These servers answer next to Xray, so some sites may bypass the VPN. Remove them from Network → DHCP and DNS.') ]);
	const conflicts = diagnostics?.conflicts || [];
	if (conflicts.length)
		list.push([ false, _('Other VPN packages are installed: %s').format(conflicts.join(', ')),
			_('These packages also change DNS and the firewall. Use only one VPN package at a time.') ]);
	if (flash != null && flash < 5120)
		list.push([ false, _('Little free flash: %d MB').format(Math.floor(flash / 1024)),
			_('Free some space or the core update may fail.') ]);
	if (ram != null && ram < 20480)
		list.push([ false, _('Little free memory: %d MB').format(Math.floor(ram / 1024)),
			_('Xray may be stopped by the system when memory runs out. Stop other services or use a smaller configuration.') ]);
	return list;
}

function checklist(st, diagnostics) {
	const items = checks(st, diagnostics);
	const problems = items.filter(([ ok ]) => ok === false).length;
	const summary = problems === 0
		? E('p', [ E('strong', text(_('No problems found.'))) ])
		: E('div', { class: 'alert-message warning' },
			text(N_(problems, '%d problem found. Start with the first one.', '%d problems found. Start with the first one.').format(problems)));
	return E('div', [
		summary,
		E('div', { class: 'mw-check' }, items.map(([ ok, label, hint ]) => E('div', [
			E('span', { class: 'mw-mark', 'aria-hidden': 'true' }, text(ok == null ? '–' : ok ? '✓' : '✗')),
			E('span', { class: 'mw-sr' }, text(ok == null ? _('Unknown:') : ok ? _('OK:') : _('Problem:'))),
			E('strong', text(label)),
			(ok || ok == null) ? '' : E('div', { class: 'mw-muted', style: 'margin-left:1.6em; white-space:pre-wrap' }, text(hint))
		])))
	]);
}

function details(st, profile, diagnostics) {
	const rows = [
		[ _('XrayWRT version'), st.version ],
		[ _('Traffic mode'), api.modeLabel(st.mode) ],
		[ _('DNS mode'), st.dns_mode || '' ],
		[ _('Block external IPv6 from clients'), !st.block_client_ipv6 ? _('no')
			: st.mode === 'direct-first' ? _('in effect') : _('no effect in this mode') ],
		[ _('Provider settings'), Object.keys(profile?.provider || {}).join(', ') || _('none') ],
		[ _('Provider lists'), profile?.provider_lists ? _('yes') : _('no') ],
		[ _('Client interfaces'), (st.interfaces || []).join(', ') ],
		[ _('Routing table'), st.route?.table ? _('%s (priority %s)').format(st.route.table, st.route.priority) : _('not active') ],
		[ _('Starts at boot'), st.enabled ? _('yes') : _('no') ]
	];
	// RSS is shown as the nearest MB; free flash/RAM floor so a warning never overstates what is left.
	if (typeof diagnostics?.xray_rss_kb === 'number')
		rows.push([ _('Xray memory'), _('%d MB').format(Math.round(diagnostics.xray_rss_kb / 1024)) ]);
	if (typeof diagnostics?.tmp_xraywrt_kb === 'number')
		rows.push([ _('XrayWRT temporary files (runtime config, downloads)'), api.formatBytes(diagnostics.tmp_xraywrt_kb * 1024) ]);
	return api.infoGrid(rows);
}

// Spec 15: the last `xray run -test` result; the backend keeps Xray's
// output of a failed check.
function configTest(diagnostics) {
	const test = diagnostics?.config_test;
	if (test?.valid == null)
		return E('p', { class: 'mw-muted' }, text(_('Not checked yet: Xray checks the configuration at start.')));
	if (test.valid)
		return E('p', text(_('Xray accepted the configuration.')));
	return E('div', [
		E('p', text(_('Xray rejected the configuration:'))),
		E('pre', { class: 'mw-log' }, text((test.output || []).join('\n')))
	]);
}

return view.extend(api.guardView({
	load: () => Promise.all([
		api.read('status-json'),
		api.read('profile-json').catch(() => ({})),
		api.read('diagnostics-json').catch((e) => ({ unavailable: api.errorText(e) }))
	]),

	render: ([ st, profile, diagnostics ]) => {
		const logBox = E('pre', { class: 'mw-log' }, text(_('Loading…')));
		const loadLog = () => api.readLarge('logs-json', '300')
			.then((res) => {
				logBox.textContent = res.available ? (res.lines.join('\n') || _('No XrayWRT log lines yet.')) : _('System log is not available.');
				logBox.scrollTop = logBox.scrollHeight;
			})
			.catch((e) => { logBox.textContent = _('Cannot read the log: %s').format(api.errorText(e)); });
		const refresh = E('button', { class: 'cbi-button' }, text(_('Check again')));

		refresh.addEventListener('click', () => location.reload());

		const copy = E('button', { class: 'cbi-button', type: 'button' }, text(_('Copy report')));
		copy.addEventListener('click', () => api.busy(copy, async () => {
			const report = api.reportText({ status: st, diagnostics });
			if (navigator.clipboard)
				await navigator.clipboard.writeText(report);
			else {
				// LuCI is often served over HTTP, where the Clipboard API is unavailable.
				const area = E('textarea', { style: 'position:fixed;opacity:0', 'aria-hidden': 'true', tabindex: '-1', readonly: '' }, text(report));
				document.body.appendChild(area);
				try {
					area.select();
					if (!document.execCommand('copy'))
						throw new Error(_('Could not copy the report. Allow clipboard access and try again.'));
				}
				finally {
					area.remove();
					copy.focus?.();
				}
			}
			api.notify(_('Report copied.'));
		}));

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Help'))),
			api.jobNotice(),
			diagnostics?.unavailable != null ? E('div', { class: 'alert-message warning' }, [
				E('div', text(_('Cannot load diagnostics: %s').format(diagnostics.unavailable))),
				E('div', text(_('Reload the page to try again.'))) ]) : '',
			E('div', { class: 'cbi-section' }, [ checklist(st, diagnostics), E('div', { class: 'mw-row' }, [ refresh, copy ]) ]),
			configuration.render({}, 'runtime'),
			(st.errors || []).length ? E('div', { class: 'alert-message warning' }, text(st.errors.map(api.errorText).join('; '))) : '',
			E('div', { class: 'cbi-section' }, [ E('h3', text(_('Details'))),
				st.observatory_signal ? '' : E('div', { class: 'cbi-value-description' }, text(_('The subscription has no server check, so XrayWRT notices a failed server only when DNS stops answering.'))),
				api.toggle(_('Show details'), _('Hide details'), details(st, profile, diagnostics)) ]),
			E('div', { class: 'cbi-section' }, [ E('h3', text(_('Last configuration check'))), configTest(diagnostics) ]),
			E('div', { class: 'cbi-section' }, [ E('h3', text(_('Log'))),
				api.toggle(_('Show the log'), _('Hide the log'), logBox, loadLog) ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
}, _('Help')));
