'use strict';
'require view';
'require form';
'require ui';
'require rpc';
'require uci';
'require xraywrt.api as api';

const text = api.text;
// Upload order matches lists_install.
const LIST_KINDS = [ 'rules', 'src', 'direct_src' ];

const callLeases = rpc.declare({ object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} } });

const LIST_HELP = _('One IP address or subnet per line, or a link to a list.');
// Targets listed in the hint before the rest hides behind a button.
const TARGETS_SHOWN = 6;

return view.extend({
	lists: {},
	edited: {},

	load: function() {
		return Promise.all([
			api.readLarge('lists-json').then((lists) => {
				if (!LIST_KINDS.every((kind) => typeof lists?.[kind] === 'string'))
					throw new Error(_('Unexpected response from the router.'));
				return lists;
			}).catch((e) => ({ error: api.errorText(e) })),
			api.read('profile-json').catch(() => ({})),
			callLeases().catch(() => null)
		]);
	},

	// Lists are files, not UCI: buffer edits and upload them on save.
	listOption: function(s, kind, title, description) {
		const o = s.option(form.TextValue, '_' + kind, title, description || LIST_HELP);
		o.rows = 6;
		o.monospace = true;
		o.readonly = !!this.listsError;
		o.cfgvalue = () => this.lists[kind];
		o.write = (sid, value) => {
			if (!this.listsError)
				this.edited[kind] = value;
		};
		// Hidden (provider list only): keep the list. Visible and empty: cleared.
		o.remove = (sid) => {
			if (!this.listsError && o.isActive(sid))
				this.edited[kind] = '';
		};
		return o;
	},

	render: function([ lists, profile, leases ]) {
		this.listsError = lists.error;
		this.lists = this.listsError ? { rules: '', src: '', direct_src: '' } : lists;
		this.edited = {};
		this.profile = profile || {};
		const proxyFirst = this.profile.mode === 'proxy-first';
		// profile-json failed: do not guess the mode or call lists inactive.
		const modeKnown = proxyFirst || this.profile.mode === 'direct-first';
		const m = new form.Map('xraywrt', _('What goes via VPN'), _('Choose which sites, addresses and devices go through the VPN and which go directly. These lists belong to the current subscription. Save & Apply applies the changes.'));
		const s = m.section(form.NamedSection, 'settings', 'settings');

		let o;
		if (!modeKnown) {
			o = s.option(form.DummyValue, '_mode', _('Traffic mode'));
			o.cfgvalue = () => api.modeLabel(this.profile.mode) + ' ' + _('(could not read the configuration)');
		}
		else {
			const meaning = proxyFirst ? _('Everything goes via VPN except the addresses and devices below.')
				: _('Only the addresses and devices below, plus the sites your subscription selects, go via VPN; everything else goes direct.');
			// An overridden mode hides the configuration's own one unless it sets it.
			const own = this.profile.mode_source === 'user' ? this.profile.provider?.mode : this.profile.mode;
			o = api.providerScalar(this.profile, form.ListValue, 'mode', (Type) => {
				const mode = s.option(Type, 'mode', _('Traffic mode'), meaning);
				mode.value('proxy-first', api.modeLabel('proxy-first'));
				mode.value('direct-first', api.modeLabel('direct-first'));
				mode.default = this.profile.mode;
				return mode;
			}, own ? _('As in the configuration: %s').format(api.modeLabel(own)) : _('As in the configuration'));
		}

		this.titles = api.LIST_TITLES();
		this.rulesOption(s, proxyFirst);
		// VPN devices apply in direct-first; direct devices apply in both modes.
		if (!modeKnown) {
			this.devicesOption(s, 'src', _('Use a MAC address: it covers IPv4 and IPv6.'), leases);
		}
		else {
			// "As in the configuration" is the mode the configuration gives, or proxy-first when it says nothing.
			const configMode = this.profile.mode_source === 'user' ? this.profile.provider?.mode : this.profile.mode;
			for (const [ mode, kind ] of [ [ 'direct-first', 'src' ] ]) {
				o = this.devicesOption(s, kind, _('Use a MAC address: it covers IPv4 and IPv6.'), leases);
				o.depends('mode', mode);
				if (configMode === mode)
					o.depends('mode', 'provider');
			}
		}

		this.devicesOption(s, 'direct_src', _('Direct devices bypass VPN rules, but client IPv6 blocking still applies.'), leases);

		// Nothing to refresh without a link in a list (provider lists may carry links).
		const hasLinks = !!this.listsError || 'lists_interval' in (this.profile.provider || {}) ||
			this.profile.provider_lists || Object.values(this.lists).some(t => /^\s*https?:\/\//m.test(String(t)));
		if (hasLinks && !api.readOnly()) {
			o = s.option(form.DummyValue, '_refresh_lists', _('Remote lists'), '');
			// Wrapped: themes may right-align a field whose direct child is a button.
			o.renderWidget = () => E('div', {}, [ this.refreshButton() ]);
		}

		// Lists
		if (hasLinks) {
			api.providerScalar(this.profile, form.ListValue, 'lists_interval', (Type = form.ListValue) => {
				const v = s.option(Type, 'lists_interval', _('Auto-update lists'));
				const values = [ '0', '1', '3', '6', '12', '24', '168' ];
				const saved = uci.get('xraywrt', 'settings', 'lists_interval');
				if (saved && /^\d+$/.test(saved) && !values.includes(saved))
					values.push(saved);
				for (const value of values)
					v.value(value, api.intervalLabel(value));
				v.default = '0';
				v.rmempty = false;
				return v;
			});
		}

		this.map = m;
		return m.render().then((node) => {
			// Right after the heading and description, like on the other pages.
			const notice = api.jobNotice();
			const heading = node.querySelector?.('.cbi-map-descr') || node.querySelector?.('h2');
			if (heading?.after)
				heading.after(notice);
			return E('div', {}, [
				api.style(), heading?.after ? null : notice,
				this.listsError ? E('div', { class: 'alert-message error' }, text(
					_('Cannot load the lists: %s').format(this.listsError) + ' ' + _('Reload the page to try again.'))) : null,
				node
			].filter(Boolean));
		});
	},

	// My rules: one ordered list of sites and addresses, each with a target.
	rulesOption: function(s, proxyFirst) {
		const o = this.listOption(s, 'rules', this.titles.rules,
			_('One rule per line: a site, an IP address or subnet, or a link to a list of addresses, then a space and where it goes. The first emitted Xray site route that matches wins. Write a site as its name, not its IP address.'));
		const targets = this.profile.targets || [];
		const reserved = this.profile.reserved || [];
		const recognizesSites = /(?:^|,)(?:http|tls|quic)(?:,|$)/.test(this.profile.sniff || '');
		this.extendWidget(o, (node) => {
			const tags = E('p', text(targets.join(', ')));
			const where = [
				...(this.profile.sniff_skipped_targets || []).map(target => E('p', { class: 'alert-message warning' }, text(_('Rules for %s stay saved but some are not applied because Xray may replace their destination IP with a site name.').format(target)))),
				E('p', [ E('code', text('direct')), ' — ', _('straight to the internet'), '; ',
					E('code', text('core')), ' — ', _('the rules of your subscription decide'),
					targets.length ? '; ' + _('or one of your servers and balancers:') : '.' ].flat()),
				...(targets.length && targets.length <= TARGETS_SHOWN ? [ tags ] : []),
				...(targets.length > TARGETS_SHOWN ? [ api.toggle(_('Show the targets'), _('Hide the targets'), tags) ] : []),
				...(reserved.length ? [ E('p', text(_('The tags %s of the configuration cannot be used here: "direct" means straight to the internet and "core" means that the rules of the subscription decide.').format(reserved.join(', ')))) ] : []),
				...(!proxyFirst ? [ E('p', text(_('A site rule with ports or protocol does not capture traffic on its own. Use an address or subnet for exact capture.'))) ] : []),
				// Direct sites are recognized by the core in this mode only with sniffing.
				...(proxyFirst && !recognizesSites ? [ E('p', text(_('Site recognition is not enabled in the configuration, so unqualified direct site rules are not used. Qualified site rules also need recognized traffic.'))) ] : [])
			];
			const format = E('div', { class: 'cbi-value-description' }, [
				E('p', text(_('One rule per line, for example:'))),
				E('ul', [
					[ 'google.com direct', _('a site and its subdomains, straight to the internet') ],
					[ 'geosite:youtube core', _('a category from geosite.dat, the rules of the subscription decide') ],
					[ 'full:www.example.com my-server', _('only this exact name, through a server or balancer of your configuration') ],
					[ '1.2.3.0/24 direct', _('an address or subnet') ],
					[ 'https://example.com/list.txt direct', _('a link to a list of addresses and subnets') ]
				].map(([ example, meaning ]) => E('li', [ E('code', text(example)), ' — ', meaning ]))),
				E('p', text(_('A site core rule does not stop later routes with overlapping different site matchers. Avoid that overlap when the subscription should decide.'))),
				E('p', text(_('Append ;ports or ;ports;tcp/udp to a site, address or list link; use ;;udp for all UDP ports. Site selectors cannot use core. Semicolons in regexp: remain part of the expression, not selectors.'))),
				E('p', text(_('Other site forms: keyword:video, regexp:^cdn[0-9]+\\.example\\.com$, ext:custom.dat:tag. Comments start with #. Saving is refused until every line is valid.')))
			]);
			const sources = this.profile.provider_sources;
			const listPreview = (title, source) => E('div', [
				E('strong', text(title)),
				source.addresses?.length ? E('ul', { class: 'mw-provider-addresses', tabindex: '0', 'aria-label': title },
					source.addresses.map(address => E('li', [ E('code', text(address)) ]))) : E('p', text(_('None'))),
				E('p', text(_('Remote links: %d').format(source.links || 0))),
				...(source.truncated ? [ E('p', text(_('Preview truncated.'))) ] : [])
			]);
			const subscriptionLists = E('div', sources ? [
				E('p', { class: 'mw-muted' }, text(_('Read-only preview from the subscription. Remote lists are not expanded.'))),
				listPreview(_('VPN addresses (Only selected sites via VPN mode)'), sources.vpn || {}),
				listPreview(_('Direct addresses (Everything via VPN except exclusions mode)'), sources.direct || {})
			] : [ E('p', text(_('Subscription lists are unavailable. Reload the page to try again.'))) ]);
			return E('div', {}, [ node, E('div', { class: 'cbi-value-description' }, where), api.toggle(_('Entry format'), _('Hide entry format'), format),
				api.toggle(_('Subscription lists'), _('Hide subscription lists'), subscriptionLists) ]);
		});
		return o;
	},

	// A device list with the lease picker. The picker carries the description
	// itself, so its notes come after it and not above it.
	devicesOption: function(s, kind, description, leases) {
		const o = this.listOption(s, kind, this.titles[kind], description);
		this.extendWidget(o, (node) => {
			const picker = this.listsError ? node : this.addLeasePicker(node, leases, description);
			o.description = picker === node ? description : '';
			return picker;
		});
		return o;
	},

	// LuCI re-renders the form after saving: extras are added inside the
	// option's widget so they survive that (with any theme).
	extendWidget: function(o, extra) {
		const render = o.renderWidget;
		o.renderWidget = function() {
			return extra(render.apply(this, arguments));
		};
	},

	refreshButton: function() {
		const refresh = E('button', { class: 'cbi-button', type: 'button', 'data-mw-job': '', disabled: api.jobRunning || null }, text(_('Update remote lists')));
		refresh.addEventListener('click', () => api.busy(refresh, async () => {
			const res = await api.job('update-lists');
			api.notifyResult(res, res.changed ? _('Remote lists updated.') : _('Remote lists are up to date.'));
		}));
		return refresh;
	},

	// A MAC covers both address families. DHCPv6 leases may have no MAC.
	addLeasePicker: function(node, leases, description) {
		const area = node.querySelector('textarea');
		if (!area || leases == null)
			return node;
		const address = (lease) => lease.ipaddr || [...(lease.ip6addrs || []), lease.ip6addr]
			.find((addr) => addr && (!addr.includes('/') || /\/128$/.test(addr)))?.replace(/\/128$/, '') || '';
		const all = (leases.dhcp_leases || []).concat(leases.dhcp6_leases || [])
			.filter((lease) => lease.macaddr || address(lease));
		const entries = () => area.value.split('\n').map((line) => line.split('#')[0].trim().toLowerCase()).filter(Boolean);
		const connected = new Set(all.flatMap((lease) => [ lease.macaddr?.toLowerCase(), lease.ipaddr ].filter(Boolean)));
		// Locally administered (randomized) Wi-Fi MAC. Marked statically: a
		// message that appears after adding would shift the layout.
		const isPrivate = (lease) => /^[0-9a-f][26ae]:/i.test(lease.macaddr || '');
		const missing = E('div', { class: 'cbi-value-description', 'aria-live': 'polite' });
		const updateMissing = () => {
			const absent = [...new Set(entries())].filter((entry) =>
				(/^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(entry) || /^\d+\.\d+\.\d+\.\d+$/.test(entry)) && !connected.has(entry));
			missing.textContent = absent.length ? _('Not connected now: %s').format(absent.join(', ')) : '';
		};
		area.addEventListener('change', updateMissing);
		updateMissing();

		// No visible labels: the first option says what the picker does.
		const select = E('select', { class: 'cbi-input-select', 'aria-label': _('Add a device') }, [
			E('option', { value: '' }, text(_('Add a device…')))
		].concat(all.map((lease, index) => E('option', { value: String(index) },
			text((isPrivate(lease) ? _('%s (%s, private MAC)') : '%s (%s)')
				.format(lease.hostname || _('unknown'), address(lease) || lease.macaddr || ''))))));
		select.value = '';
		const addAs = E('select', { class: 'cbi-input-select', 'aria-label': _('Add as') }, [
			E('option', { value: 'mac' }, text(_('MAC (IPv4 + IPv6)'))),
			E('option', { value: 'ip' }, text(_('IP address')))
		]);
		addAs.value = 'mac';
		select.addEventListener('change', () => {
			const lease = select.value === '' ? null : all[select.value];
			select.value = '';
			if (!lease)
				return;
			const byMac = addAs.value === 'mac' && !!lease.macaddr;
			const entry = byMac ? lease.macaddr.toLowerCase() : address(lease);
			if (!entry || entries().includes(entry.toLowerCase()))
				return;
			// Keep a hostname on one comment line, never as list syntax.
			const hostname = (lease.hostname || '').replace(/[\r\n]+/g, ' ');
			area.value = (area.value.replace(/\s*$/, '') + '\n' + entry + (hostname ? ' # ' + hostname : '')).replace(/^\n/, '') + '\n';
			area.dispatchEvent(new Event('change', { bubbles: true }));
		});
		const pickerRow = all.length
			? E('div', { class: 'mw-row mw-picker' }, [ select, addAs ])
			: E('div', { class: 'cbi-value-description' }, text(_('No devices found in DHCP. Enter a MAC address, e.g. aa:bb:cc:dd:ee:ff.')));
		return E('div', {}, [ node, pickerRow,
			description ? E('div', { class: 'cbi-value-description' }, text(description + (all.some(isPrivate)
				? ' ' + _('Keep the device\'s private Wi-Fi address fixed for this network, or this rule will stop matching.') : ''))) : '', missing ]);
	},

	handleSave: null,

	// Lists first: a rejected list must not save or re-render the form.
	handleSaveApply: async function(ev, mode) {
		if (api.jobRunning) {
			try {
				const status = await api.read('job-status');
				api.notify(_('"%s" is running…').format(api.jobLabel(status.op)));
			}
			catch (e) {
				api.notify(api.errorText(e), 'error');
			}
			return;
		}
		if (this.saving)
			return;
		this.saving = true;
		let listResult;
		try {
			this.edited = {};
			await this.map.parse();
			const edited = this.listsError ? [] : LIST_KINDS.filter((kind) =>
				kind in this.edited && this.edited[kind] !== this.lists[kind]);
			if (edited.length) {
				const paths = await Promise.all(LIST_KINDS.map((kind) => edited.includes(kind)
					? api.upload('xraywrt-policy-list', this.edited[kind]) : '-'));
				listResult = await api.job('apply-lists', ...paths);
				for (const kind of edited)
					this.lists[kind] = this.edited[kind];
			}
			try {
				await this.map.save(null, true);
			}
			catch (e) {
				if (edited.length)
					throw new Error(_('Lists were saved, but settings could not be saved: %s. Review the settings and try Save & Apply again.').format(api.errorText(e)));
				throw e;
			}
			const changes = await uci.changes();
			if (Object.keys(changes).some((config) => changes[config].length)) {
				if (listResult?.apply_status === 'partial') api.keepResult(listResult);
				return ui.changes.apply(mode == '0');
			}
			api.notifyResult(listResult, _('Changes applied.'));
		}
		catch (e) {
			api.notify(api.errorText(e), 'error');
		}
		finally {
			this.saving = false;
		}
	}
});
