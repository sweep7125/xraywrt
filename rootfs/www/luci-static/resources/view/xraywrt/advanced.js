'use strict';
'require view';
'require form';
'require ui';
'require validation';
'require rpc';
'require xraywrt.configuration as configuration';
'require uci';
'require tools.widgets as widgets';
'require xraywrt.api as api';

// Provider overrides and router-specific UCI settings.
const text = api.text;

// Boot start is the init script's, not UCI: read by the standard LuCI call.
const callInitList = rpc.declare({ object: 'luci', method: 'getInitList', params: [ 'name' ], expect: { '': {} } });

return view.extend({
	load: () => Promise.all([
		api.read('profile-json', '--compact').catch(() => ({})),
		callInitList('xraywrt').catch(() => ({}))
	]).then(([ profile, init ]) => [ profile, { netbird: profile.netbird }, profile.subscription || {}, init ]),

	addFooter: () => E([]),

	render: function([ profile, status, sub = {}, init = {} ]) {
		this.profile = profile || {};
		const m = new form.Map('xraywrt', _('Advanced'), _('Overrides apply to the current subscription. “Save & Apply” restarts Xray when needed.'));
		const s = m.section(form.NamedSection, 'settings', 'settings');
		s.tab('routing', _('Routing'));
		s.tab('dns', _('DNS'));
		s.tab('core', _('Service'));

		// Flags with a default must stay in UCI: form.Flag removes empty values.
		const flag = (tab, name, title, description, defaultValue = '0') => api.providerScalar(this.profile, form.ListValue, name, (Type = form.Flag) => {
			const f = s.taboption(tab, Type, name, title, description);
			if (Type === form.ListValue) {
				f.value('1', _('Enabled'));
				f.value('0', _('Disabled'));
			}
			f.default = defaultValue;
			f.rmempty = false;
			return f;
		});

		// Routing
		let o = s.taboption('routing', widgets.DeviceSelect, 'source_network_interfaces', _('Client interfaces'), _('Traffic from these interfaces is handled. Usually br-lan.'));
		o.multiple = true;
		o.noaliases = true;
		const proxyFirst = this.profile.mode === 'proxy-first';
		const ipv6Flag = flag('routing', 'block_client_ipv6', _('Block external IPv6 from clients'), proxyFirst ? _('No effect in the current mode.')
			: _('Keep external IPv6 of client devices from reaching the internet without the VPN.'), '0');
		if (proxyFirst)
			ipv6Flag.readonly = true;
		flag('routing', 'discord_voice', _('Discord Voice'), _('Send detected Discord calls through Xray in direct-first mode. Requires conntrack accounting.'));
		flag('routing', 'disable_quic', _('Block QUIC for VPN traffic'), _('Disables HTTP/3 so sites work more reliably through the VPN.'));
		flag('routing', 'bypass_ntp', _('Time sync without Xray'), _('Time sync (NTP) works even when the VPN is down.'));
		// Only for routers that have NetBird (or already use the option).
		if (status.netbird || uci.get('xraywrt', 'settings', 'netbird_proxy') === '1') {
			o = s.taboption('routing', form.Flag, 'netbird_proxy', _('Route outbound NetBird through VPN'), _('Applies your VPN rules to outgoing NetBird traffic. Running NetBird on this router can also disrupt IPv4 connections from your devices through Xray in either traffic mode.'));
			o.default = '0';
			o.rmempty = false;
		}

		// DNS
		flag('dns', 'dns_hijack', _('Hijack DNS'), _('Send plain DNS to the router. Encrypted DNS (DoH/DoT) stays untouched.'));
		// One control over three UCI keys (dns_forward_other_types, dns_raw_via, dns_raw_upstream); only this select is shown for the flag.
		// A non-empty dns_raw_via forwards in both modes; the flag only in direct-first.
		const forwardKey = 'dns_forward_other_types';
		const providerForward = (this.profile.provider || {})[forwardKey];
		const providerForwardsDirectly = providerForward === '1' && !proxyFirst;
		const lostTag = this.profile.dns_raw_lost || '';
		const other = s.taboption('dns', form.ListValue, '_dns_other', _('Other DNS queries (TXT, SRV, MX…)'), _('Xray handles A and AAAA. Choose where to send other queries. Direct forwarding uses plain DNS visible to your internet provider.'));
		if (lostTag) {
			// LuCI descriptions accept strings only; render the text-only warning beside the widget.
			const renderOther = other.renderWidget;
			other.renderWidget = function() {
				return E('div', {}, [ renderOther.apply(this, arguments), E('p', { class: 'alert-message warning' }, text(_('Forwarding of other DNS query types was turned off because outbound "%s" became unavailable. Choose an outbound to re-enable it, or leave forwarding off.').format(lostTag))) ]);
			};
		}
		if (providerForward != null && !lostTag)
			other.value('provider', _('From subscription: %s').format(providerForwardsDirectly ? _('Forward directly') : _('Do not forward')));
		other.value('off', _('Do not forward'));
		if (!proxyFirst && !lostTag)
			other.value('direct', _('Forward directly'));
		other.value('via', _('Forward through the VPN'));
		other.default = 'off';
		other.rmempty = false;
		other.forcewrite = !!lostTag;
		other.cfgvalue = () => {
			if (lostTag) return 'off';
			if (uci.get('xraywrt', 'settings', 'dns_raw_via'))
				return 'via';
			if (providerForward != null && ![].concat(uci.get('xraywrt', 'settings', 'provider_override') || []).includes(forwardKey))
				return 'provider';
			return uci.get('xraywrt', 'settings', forwardKey) === '1' && !proxyFirst ? 'direct' : 'off';
		};
		other.write = (sid, value) => {
			if (lostTag) {
				uci.set('xraywrt', sid, 'dns_raw_lost', value === 'via' ? '' : lostTag);
				if (value !== 'via') value = 'off';
			}
			if (value === 'provider') {
				api.setProviderOverride(sid, forwardKey, false);
				uci.set('xraywrt', sid, 'dns_raw_via', '');
				return;
			}
			uci.set('xraywrt', sid, forwardKey, value === 'direct' ? '1' : '0');
			if (providerForward != null || lostTag)
				api.setProviderOverride(sid, forwardKey, true);
			uci.set('xraywrt', sid, 'dns_raw_via', value === 'via' ? tagFromValue(via.formvalue(sid)) : '');
		};
		// LuCI revalidates active dependencies only; clear errors when a field becomes hidden too.
		const clearInactiveError = (option) => {
			const setActive = option.setActive;
			option.setActive = function(sid, active) {
				const changed = setActive.apply(this, arguments);
				if (!active) this.triggerValidation(sid);
				return changed;
			};
		};
		o = s.taboption('dns', form.Value, 'dns_raw_upstream', _('DNS server for these queries'), _('Use IP, IPv4:port or [IPv6]:port. Required via VPN. For direct forwarding, leave blank to use your connection’s DNS.'));
		o.optional = true;
		o.validate = function(sid, value) {
			if (!this.isActive(sid)) return true;
			if (!value) return other.formvalue(sid) !== 'via' || _('Enter a DNS server IP[:port] for forwarding through the VPN.');
			const m = value.match(/^\[([^\]]+)\]:(\d+)$/) || value.match(/^([^:]+):(\d+)$/);
			const ip = m ? m[1] : value;
			// LuCI accepts leading-zero IPv4 octets (also in IPv6 tails); the backend's iptoarr does not.
			const ipv4 = ip.includes('.') ? ip.split(':').pop() : '';
			return (!!(validation.parseIPv4(ip) || validation.parseIPv6(ip)) && !/(^|\.)0\d/.test(ipv4) && (!m || +m[2] >= 1 && +m[2] <= 65535))
				|| _('Enter a valid IP address with an optional port (1–65535).');
		};
		clearInactiveError(o);
		o.depends('_dns_other', 'direct');
		o.depends('_dns_other', 'via');
		if (providerForwardsDirectly)
			o.depends('_dns_other', 'provider');
		// LuCI removes an option whose dependency is unmet: keep the server while forwarding is off.
		const removeUpstream = o.remove;
		o.remove = function(sid) { return this.isActive(sid) ? removeUpstream.apply(this, arguments) : null; };
		const tags = this.profile.dns_outbounds || [];
		// Raw tags can shadow methods on LuCI's choice objects; only widget values are encoded.
		const tagFromValue = (value) => tags.find((tag, index) => value === 'outbound-' + index) || '';
		const via = o = s.taboption('dns', form.ListValue, 'dns_raw_via', _('Outbound tag'), tags.length
			? _('Choose an outbound from the original configuration. Chained outbounds keep their configured route.')
			: _('No suitable outbounds. Add a tagged VPN outbound to the configuration.'));
		o.value('', _('Choose an outbound'));
		tags.forEach((tag, index) => o.value('outbound-' + index, tag));
		// Map loads UCI after constructing these options, so inspect the saved tag during option load.
		const loadVia = o.load;
		o.load = function(sid) {
			const savedTag = loadVia.call(this, sid);
			if (!savedTag) return '';
			const value = tags.includes(savedTag) ? 'outbound-' + tags.indexOf(savedTag) : 'missing';
			if (!this.keylist.includes(value)) this.value(value, _('%s (not available)').format(savedTag));
			return value;
		};
		o.default = '';
		o.optional = true;
		o.write = (sid, value) => uci.set('xraywrt', sid, 'dns_raw_via', tagFromValue(value));
		o.depends('_dns_other', 'via');
		o.validate = function(sid, value) {
			return !this.isActive(sid) || !!tagFromValue(value) || _('Choose an available outbound from the configuration.');
		};
		clearInactiveError(o);
		flag('dns', 'block_https_svcb', _('Block HTTPS/SVCB queries'), _('Return empty HTTPS/SVCB answers when forwarding other DNS queries. FakeDNS can still block forwarding for its domains.'), '0');

		// Nothing is downloaded without a saved link.
		if (sub.configured ?? !!sub.url) flag('core', 'bypass_subscription_dns', _('Download the subscription directly'), _('Downloads the subscription directly, even when the VPN is down.'));

		// Core
		api.providerScalar(this.profile, form.ListValue, 'core_log_level', () => {
			const o = s.taboption('core', form.ListValue, 'core_log_level', _('Xray log detail'));
			const labels = { none: _('Off'), error: _('Errors'), warning: _('Warnings'), info: _('Information'), debug: _('Debug') };
			const levels = 'core_log_level' in (this.profile.provider || {})
				? [ 'debug', 'info', 'warning', 'error', 'none' ] : [ 'none', 'error', 'warning', 'info', 'debug' ];
			for (const level of levels)
				o.value(level, labels[level]);
			o.default = 'warning';
			o.rmempty = false;
			return o;
		});

		// Written by Save & Apply like the other options, but through the init script.
		// Unknown boot state (failed read): no checkbox, so a save cannot flip it.
		if (typeof init.xraywrt?.enabled === 'boolean') {
			let boot = init.xraywrt.enabled;
			o = s.taboption('core', form.Flag, '_boot', _('Start on boot'));
			o.rmempty = false;
			o.cfgvalue = () => boot ? '1' : '0';
			// LuCI writes a flag on every save: act only on a real change.
			o.write = (sid, value) => (value === '1') === boot ? null
				: (value === '1' ? api.service('enable') : api.service('disable')).then(() => { boot = value === '1'; });
		}

		this.map = m;
		// The editor acts at once with its own button; the form above is saved by the LuCI footer.
		// The footer belongs under the form, not under the editor: build it here
		// and keep the loader's own call (addFooter below) empty.
		return m.render().then((node) => E('div', { class: 'mw-settings' }, [ api.style(), api.jobNotice(), node, view.prototype.addFooter.call(this), configuration.render(sub, 'editor') ]));
	}
});
