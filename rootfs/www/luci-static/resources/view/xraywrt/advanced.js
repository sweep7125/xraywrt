'use strict';
'require view';
'require form';
'require ui';
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
		flag('dns', 'dns_forward_other_types', _('Forward other DNS queries'), _('Resolve TXT, SRV, MX and other queries using the configured DNS servers. FakeDNS can block queries for its domains.'), '1');
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
