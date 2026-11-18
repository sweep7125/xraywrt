'use strict';
'require view';
'require poll';
'require uci';
'require ui';
'require xraywrt.api as api';

// Pin, reset and stale removal: one request at a time per row.
function balancerAction(tag, setBusy, restore) {
	let pending = false;
	return (control, target) => {
		if (api.readOnly() || pending)
			return;
		return api.busy(control, async () => {
			pending = true;
			setBusy(true);
			try {
				await api.balancerSet(tag, target);
				api.reloadWithNotice(_('Balancer override saved.'));
			}
			catch (e) {
				restore?.();
				throw e;
			}
			finally {
				pending = false;
				setBusy(false);
			}
		});
	};
}

function balancerState(balancer) {
	if (balancer.error === 'timeout')
		return _('Not checked: the time limit was reached.');
	if (balancer.error)
		return _('Cannot read the balancer state from Xray.');
	return balancer.override || balancer.selected?.join(', ') || '—';
}

function balancerRow(balancer, index) {
	const readOnly = api.readOnly();
	// Spec 16: UCI stores tag=target, so a tag with '=' cannot be saved.
	const locked = readOnly || balancer.settable === false;
	const hintId = 'balancer-pin-hint-' + index;
	const select = E('select', { class: 'cbi-input-select', disabled: locked || null,
		'aria-label': _('Override for %s').format(balancer.tag),
		'aria-describedby': balancer.settable === false ? hintId : 'balancer-fallback-hint' }, [
		E('option', { value: '' }, text(_('Auto'))),
		...balancer.targets.map(tag => E('option', { value: tag }, text(tag)))
	]);
	select.value = balancer.override || '';
	const apply = balancerAction(balancer.tag, busy => { select.disabled = busy || locked; },
		() => select.value = balancer.override || '');
	select.addEventListener('change', () => apply(select, select.value));
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td' }, text(balancer.tag)),
		E('td', { class: 'td' }, [
			E('div', text(balancerState(balancer))),
			...(balancer.stale ? [ E('div', { class: 'cbi-value-description' }, text(_('Saved override %s is not applied.').format(balancer.saved))) ] : [])
		]),
		E('td', { class: 'td' }, text(balancer.fallback || '—')),
		E('td', { class: 'td' }, balancer.targets.length === 1 ? text(_('One server, nothing to choose')) : [
			E('div', { class: 'mw-row mw-picker' }, [ select ]),
			balancer.settable === false ? E('div', { class: 'cbi-value-description', id: hintId }, text(_('A balancer tag with "=" cannot be pinned.'))) : ''
		])
	]);
}

// A saved override whose balancer is gone from the configuration.
function staleRow(entry) {
	const remove = E('button', { class: 'cbi-button cbi-button-remove', type: 'button',
		'aria-label': _('Remove the saved override of %s').format(entry.tag) }, text(_('Reset')));
	const apply = balancerAction(entry.tag, busy => remove.disabled = busy);
	remove.addEventListener('click', () => apply(remove, ''));
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td' }, text(entry.tag)),
		E('td', { class: 'td' }, text(_('Saved override %s is not applied: the configuration has no such balancer.').format(entry.target ?? '—'))),
		E('td', { class: 'td' }, text('—')),
		E('td', { class: 'td' }, api.readOnly() ? [] : [ remove ])
	]);
}

// Xray's API can take 10 s, so the list is read only when the block is opened.
function balancersSection() {
	const content = E('div', {});
	let request = 0;
	const open = () => {
		const mine = ++request;
		content.replaceChildren(E('p', { class: 'spinning' }, text(_('Loading…'))));
		api.balancers().then(data => {
			const stale = data.stale || [];
			if (!data.balancers?.length && !stale.length)
				return E('p', text(_('The configuration has no balancers.')));
			const balancers = data.balancers || [];
			return E('div', [
				E('table', { class: 'table mw-balancers' }, [
					E('tr', { class: 'tr table-titles' }, [ _('Balancer tag'), _('Current target'), _('Fallback'), _('Override') ].map(label => E('th', { class: 'th', scope: 'col' }, text(label)))),
					...balancers.map(balancerRow),
					...stale.map(staleRow)
				]),
				balancers.some(b => b.targets.length !== 1 && b.settable !== false) ? E('p', { class: 'cbi-value-description', id: 'balancer-fallback-hint' }, text(_('Pinning disables automatic fallback.'))) : ''
			]);
		}).catch(() => E('div', { class: 'alert-message warning' }, text(_('Cannot read the balancer state from Xray.'))))
			.then(node => { if (mine === request) content.replaceChildren(node); });
	};
	return api.toggle(_('Show balancers'), _('Hide balancers'), content, open);
}


function pageLink(page, label) {
	return E('a', { href: L.url('admin/services/xraywrt/' + page) }, text(label));
}

function firstRunCard() {
	const url = E('input', {
		// type=text: some themes (openwrt-2020) style only text inputs.
		id: 'mw-sub-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
		class: 'cbi-input-text', style: 'flex: 1 1 16em; min-width: 0; width: auto',
		placeholder: 'https://provider.example/sub/…', 'aria-label': _('Subscription URL')
	});
	const connect = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Connect')));

	connect.addEventListener('click', () => api.busy(connect, async () => {
		const value = url.value.trim();
		if (!/^https?:\/\//i.test(value))
			throw new Error(_('Enter the subscription link that starts with https://'));
		// The link is saved only after a successful download.
		const res = await api.job('connect', value);
		// Give the service a moment to start; stay inside busy so the buttons stay disabled until the reload.
		await new Promise(resolve => window.setTimeout(resolve, 1500));
		api.reloadResult(res, _('Subscription connected. XrayWRT is starting.'));
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Connect a subscription'))),
		E('p', text(_('Paste your subscription link. Settings are applied automatically.'))),
		E('label', { for: 'mw-sub-url' }, text(_('Subscription URL'))),
		E('div', { class: 'mw-row' }, [ url, !api.readOnly() ? connect : '' ])
	]);
}

// Running on a configuration entered by hand: no big card, just a pointer.
function subscriptionHint() {
	return E('div', { class: 'cbi-section' }, [
		E('p', { class: 'mw-muted' }, [
			text(_('No subscription: XrayWRT uses the configuration entered on the Advanced page.'))[0], ' ',
			pageLink('subscription', _('Connect a subscription'))
		])
	]);
}

// Updating the subscription helps only with a configuration error; other errors name their own step.
const CONFIG_ERROR = /\[E:(config_(rejected|invalid|json|share|yaml|outbounds|empty|large)|profile_invalid)[|\]]/;

function coreMissingCard() {
	const install = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Install Xray core')));

	install.addEventListener('click', () => api.busy(install, async () => {
		const res = await api.coreUpdate();
		api.reloadWithNotice(_('Xray core %s installed.').format(res.version || ''));
	}));
	return E('div', { class: 'cbi-section' }, [
		E('h3', text(_('Xray core is not installed'))),
		E('p', text(_('XrayWRT needs the Xray core. Download it once from GitHub: about 17 MB on the router with the default core.'))),
		E('p', text(_('If the router cannot reach GitHub, copy xraywrt-core_*.apk from the xraywrt-core release to the router and install it over SSH. The service restarts by itself.'))),
		E('p', [ E('code', {}, text('apk add --allow-untrusted xraywrt-core_*.apk')) ]),
		E('div', { class: 'mw-row' }, [ !api.readOnly() ? install : '' ])
	]);
}

function statusSection(status) {
	// Stop works during any other operation: a slow download must not hold the internet.
	const toggle = E('button', status.running ? { class: 'cbi-button' } : { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button' },
		text(status.running ? _('Stop') : _('Start')));
	const restart = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button' }, text(_('Restart')));
	const noSubNote = E('div', { class: 'mw-muted' }, text(_('Without a subscription XrayWRT starts with the current configuration; by default all traffic goes direct.')));

	toggle.addEventListener('click', () => api.busy(toggle, async () => {
		// A status poll may replace `status` while the stop waits.
		const wasRunning = status.running;
		if (!wasRunning && !status.enabled)
			await api.service('enable');
		if (wasRunning) {
			let failed = api.jobRunning;
			// A job this page did not see (cron update) also holds the slot: fall back to the direct stop.
			if (!failed) try { await api.job('service', 'stop'); } catch (e) { failed = e; }
			if (failed) {
				await api.write('stop-now');
				let fresh = status;
				for (let i = 0; i < 30 && (fresh = await api.read('service-state-json')).running; i++)
					await new Promise(r => setTimeout(r, 1000));
				if (fresh.running)
					throw new Error(_('XrayWRT did not stop. Try again.'));
			}
		}
		else
			await api.job('service', 'start');
		const stopNotice = status.enabled
			? _('XrayWRT stopped. All traffic bypasses the VPN. Starts again after a router reboot.')
			: _('XrayWRT stopped. All traffic bypasses the VPN.');
		api.reloadWithNotice(wasRunning ? stopNotice : _('XrayWRT started.'));
	}));
	restart.addEventListener('click', () => api.busy(restart, async () => {
		await api.job('service', 'restart');
		api.reloadWithNotice(_('XrayWRT restarted.'));
	}));

	const headline = E('strong', { 'aria-live': 'polite' });
	const boot = E('span', { class: 'mw-muted' });
	const modeSpan = E('span', { class: 'mw-muted' });
	const details = E('div', { class: 'mw-muted' });
	const versions = E('div', { class: 'mw-muted' }, text(status.core
		? _('Version %s · core %s').format(status.version || '—', status.core)
		: _('Version %s').format(status.version || '—')));
	const nextStep = E('div', {});
	const applyWarning = E('div', { role: 'status' });
	const statusBox = E('div', { class: 'mw-status' }, [
		headline,
		versions,
		details,
		nextStep,
		applyWarning,
		modeSpan,
		boot
	]);
	const block = E('div', { class: 'cbi-section' }, [
		statusBox,
		!api.readOnly() ? E('div', { class: 'mw-row' }, [ toggle, restart ]) : '',
		noSubNote
	]);
	const diagnosticsLink = () => [ pageLink('help', _('Open Help')) ];
	const update = fresh => {
		status = Object.assign({}, status, fresh);
		applyWarning.textContent = api.errorText(status.apply_warning || '');
		applyWarning.hidden = !status.apply_warning;
		applyWarning.setAttribute('class', status.apply_warning ? 'alert-message warning' : '');
		const state = status.state || (status.running ? 'running' : 'stopped');
		let label = _('Stopped');
		let alertClass = null;
		let detailText = '';
		let nextStepContent = null;

		if (state === 'starting') {
			label = _('Starting…');
		}
		else if (state === 'running') {
			if (status.dns_ok === false) {
				label = _('Running, but DNS does not answer — see Help');
				alertClass = 'warning';
				nextStepContent = diagnosticsLink();
			}
			else {
				label = _('Running');
			}
		}
		else if (state === 'degraded') {
			label = status.degraded_reason === 'observatory' ? _('The VPN server is not responding (provider check)') : _('VPN DNS is not responding');
			detailText = _('Internet traffic goes directly until the VPN recovers.');
			alertClass = 'warning';
			nextStepContent = diagnosticsLink();
		}
		else if (status.config_valid === false) {
			label = _('Stopped: Xray did not accept the configuration.');
			alertClass = 'error';
			detailText = status.last_error || api.coreError(status.config_error || '');
			nextStepContent = /\[E:/.test(detailText) && !CONFIG_ERROR.test(detailText) ? diagnosticsLink()
				: [ _('What to do: update the subscription or fix the configuration.'), ' ', ...diagnosticsLink() ];
		}
		// The backend calls the error state "failed".
		else if (state === 'failed') {
			label = status.last_error ? _('Stopped because of an error.') : _('Stopped');
			alertClass = 'error';
			detailText = status.last_error || '';
			nextStepContent = CONFIG_ERROR.test(detailText) ? [ _('What to do: update the subscription or fix the configuration.'), ' ', ...diagnosticsLink() ] : diagnosticsLink();
		}

		if (headline.textContent !== label)
			headline.textContent = label;

		if (detailText) {
			details.textContent = state === 'degraded' ? detailText : _('Details: %s').format(api.errorText(detailText));
			details.hidden = false;
		}
		else {
			details.textContent = '';
			details.hidden = true;
		}

		if (nextStepContent) {
			nextStep.replaceChildren(...nextStepContent);
			nextStep.hidden = false;
		}
		else {
			nextStep.replaceChildren();
			nextStep.hidden = true;
		}

		statusBox.setAttribute('class', 'mw-status' + (alertClass ? ' alert-message ' + alertClass : ''));
		modeSpan.textContent = _('Mode: %s').format(api.modeLabel(status.mode));
		boot.textContent = status.enabled ? _('Starts automatically when the router boots') : _('Does not start when the router boots');
		toggle.textContent = status.running ? _('Stop') : _('Start');
		// Start becomes Stop: enable it. A running Stop keeps its busy state.
		if (status.running) {
			if (toggle.hasAttribute('data-mw-job')) { toggle.removeAttribute('data-mw-job'); toggle.disabled = false; }
		}
		else toggle.setAttribute('data-mw-job', '');
		const noSub = !status.subscription_configured && !status.running;
		noSubNote.hidden = api.readOnly() || !noSub;
		restart.hidden = !status.running;
		toggle.setAttribute('class', 'cbi-button' + (status.running ? ' cbi-button-reset' : (!status.subscription_configured ? '' : ' cbi-button-action')));
	};
	update(status);
	return { block, update };
}

function liveStatus(status) {
	const section = statusSection(status);
	let pollFailed = false;
	poll.add(async () => {
		if (api.jobRunning || document.hidden)
			return;
		try {
			const fresh = await api.read('service-state-json');
			pollFailed = false;
			if (api.jobRunning)
				return;
			section.update(fresh);
		}
		catch (e) {
			if (!pollFailed)
				api.notify(api.errorText(e), 'error');
			pollFailed = true;
		}
	}, 10);
	return section.block;
}


function connectionCheck(mode) {
	const button = E('button', { class: 'cbi-button', type: 'button' }, text(_('Check connection')));
	const result = E('span', { role: 'status', 'aria-live': 'polite' }, []);
	button.addEventListener('click', async () => {
		if (button.disabled)
			return;
		button.disabled = true;
		result.textContent = _('Loading…');
		try {
			const data = await api.read('check-ip');
			if (typeof data.ip !== 'string' || typeof data.country !== 'string')
				throw new Error('Invalid IP response');
			result.textContent = _('Router\'s internet IP: %s, country %s').format(data.ip, data.country)
				+ (mode === 'direct-first' ? ' ' + _('(sites outside the VPN lists go direct)') : '');
		}
		catch (e) {
			result.textContent = _('Could not check: the check site is unavailable.');
		}
		finally {
			button.disabled = false;
		}
	});
	return E('div', { class: 'mw-row' }, [ button, result ]);
}

function warningsSection(status) {
	const warnings = status.warnings || [];
	if (!warnings.length)
		return '';
	return E('div', { class: 'alert-message warning' }, [
		E('strong', text(_('Configuration warnings'))),
		E('ul', warnings.map(line => E('li', text(api.errorText(line)))))
	]);
}

// The profile (element of a configuration array) is a UCI option of the active subscription: changing it
// is a normal Save & Apply, and the reload restarts Xray with the new profile.
function profileSection(status, profiles, sub) {
	if (status.profile?.pinned)
		return E('div', { class: 'cbi-section' }, [ E('p', { class: 'mw-pinned-server' }, text(_('Server: %s (from subscription)').format(status.profile.selected ?? ''))) ]);
	if (!Array.isArray(profiles) || profiles.length < 2)
		return '';
	// selected is the running profile with control bytes shown as spaces;
	// name is the original UCI choice, which may have been rejected.
	const running = status.profile?.selected;
	const shown = p => String(p).replace(/[\x00-\x1f\x7f]/g, ' ');
	const name = status.profile?.name;
	const current = profiles.includes(name) && (running == null || shown(name) === running) ? name :
		(profiles.find(p => shown(p) === running) || profiles[0]);
	const select = E('select', { id: 'mw-profile', class: 'cbi-input-select', disabled: api.readOnly() || api.jobRunning || null },
		profiles.map(name => E('option', { value: name, selected: name === current ? '' : null }, text(name))));
	select.value = current;
	select.addEventListener('change', async () => {
		const name = select.value;
		if (name === current)
			return;
		if (!await api.confirm(_('Change the server'), _('XrayWRT restarts Xray with the server "%s"; the internet drops for a few seconds.').format(name), _('Change'))) {
			select.value = current;
			return;
		}
		return api.busy(null, async () => {
			// Each subscription keeps its own choice; without one it stays in settings.
			uci.set('xraywrt', sub?.active || 'settings', 'profile', name);
			await uci.save();
			return ui.changes.apply(true);
		});
	});
	return E('div', { class: 'cbi-section' }, [
		E('div', { class: 'mw-grid' }, [
			E('label', { for: 'mw-profile' }, text(_('Server'))),
			E('div', { class: 'mw-row mw-picker' }, [ select ])
		])
	]);
}

// Provider text stays text; only http(s) runs become safe links.
function announce(value) {
	return String(value).split(/(https?:\/\/\S+)/i).map((part, i) =>
		(i % 2) ? (api.safeLink(part, part) || part) : part).filter((part) => part !== '');
}

// Expiry within 3 days or 90 % of the traffic used: the provider's limits
// are the usual reason a working router suddenly stops proxying.
function subscriptionWarning(sub) {
	const now = Date.now() / 1000;
	const expire = Number(sub.expire);
	const total = Number(sub.total);
	const used = (Number(sub.upload) || 0) + (Number(sub.download) || 0);
	if (expire > 0 && expire < now)
		return _('Subscription expired. Renew it with the service.');
	if (expire > 0 && expire - now < 3 * 86400)
		return _('Subscription expires on %s. Renew it with the service.').format(api.formatDate(expire));
	if (total > 0 && used >= total)
		return _('The subscription traffic is used up.');
	if (total > 0 && used >= total * 0.9)
		return _('Over 90% of the subscription traffic is used.');
	return '';
}

function subscriptionSection(sub) {
	const update = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action' }, text(_('Update subscription')));
	const hasTrafficData = sub?.upload != null || sub?.download != null || sub?.total != null;
	const trafficText = hasTrafficData ? api.trafficSummary(sub) : '—';
	const expireText = sub?.expire != null ? (Number(sub.expire) === 0 ? _('Never') : api.formatDate(sub.expire)) : '—';
	const autoUpdateText = sub.effective_interval > 0 ? _('every %d h').format(sub.effective_interval)
		: sub.auto_update !== false ? _('Manual only: the provider does not set an update period') : _('Off');
	const rows = [
		[ _('Data used'), trafficText ],
		[ _('Expires'), expireText ],
		[ _('Last update'), sub.last_update ? api.formatDate(sub.last_update) : _('Not yet') ],
		[ _('Auto-update'), autoUpdateText ]
	];
	const links = [ api.linkButton(sub.support_url, _('Support')), api.linkButton(sub.web_page_url, _('Website')) ].filter(Boolean);
	const warning = subscriptionWarning(sub);

	update.addEventListener('click', () => api.busy(update, async () => {
		const res = await api.job('update-subscription');
		api.reloadResult(res, api.actionNotice(res.action));
	}));

	return E('div', { class: 'cbi-section' }, [
		E('h3', text(sub.profile_title || _('Subscription'))),
		warning ? E('div', { class: 'alert-message warning' }, text(warning)) : '',
		sub.announce ? E('p', { class: 'mw-announce' }, announce(sub.announce)) : '',
		api.infoGrid(rows),
		E('div', { class: 'mw-row mw-actions' }, (!api.readOnly() ? [ update ] : []).concat(links))
	]);
}

const text = api.text;

return view.extend(api.guardView({
	load: () => Promise.all([
		api.status(),
		api.read('subscription-json').catch(() => ({})),
		api.profiles().catch(() => [])
	]),

	render: ([ status, sub, profiles ]) => {
		const body = [ api.style(), E('h2', text(_('XrayWRT'))), api.jobNotice() ];

		// Without the core nothing else can work yet: only the install card.
		if (!status.core_installed) {
			body.push(coreMissingCard());
			return E('div', { class: 'mw-page' }, body);
		}
		if (!status.subscription_configured)
			body.push(status.running ? subscriptionHint() : firstRunCard());
		const live = liveStatus(status);
		live.appendChild(connectionCheck(status.mode));
		body.push(live);
		body.push(warningsSection(status));
		if (status.overrides > 0)
			body.push(E('p', {}, [ pageLink('advanced', _('You changed %d provider settings.').format(status.overrides)) ]));
		if (status.subscription_configured)
			body.push(subscriptionSection(sub));
		body.push(profileSection(status, profiles, sub));
		if (status.has_balancers)
			body.push(E('section', { class: 'cbi-section mw-balancers-section' }, [ balancersSection() ]));
		return E('div', { class: 'mw-page' }, body.filter(Boolean));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
}, _('XrayWRT')));
