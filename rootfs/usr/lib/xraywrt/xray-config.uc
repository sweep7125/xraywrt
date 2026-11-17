// Runtime Xray config generator (spec 6). Loaded by `xraywrt-json gen`;
// errors are thrown as die() text, warnings go to the profile.
'use strict';

const MAX_SOURCE = 8388608;

// Same coded-message format as helpers.sh; values cannot add tail fields.
function code_message(code, fmt, ...args) {
	args = map(args, (arg) => replace('' + arg, /[]|\r\n]/g, '/'));
	return sprintf(fmt, ...args) + ' [E:' + code + (length(args) ? '|' + join('|', args) : '') + ']';
}

// Display text may lose controls; identifiers and URLs must keep their identity.
function profile_field(value, display) {
	let text = '' + value;
	if (index(text, '\x00') >= 0 || match(text, /[[:cntrl:]]/)) {
		if (!display) die(code_message('profile_invalid', 'config: The subscription contains invalid data and was not applied; the previous settings are kept.'));
		text = replace(join(' ', split(text, '\x00')), /[[:cntrl:]]/g, ' ');
	}
	return text;
}

function profile_record(profile, kind, ...fields) {
	let line = join(' ', [kind, ...map(fields, (v) => profile_field(v, kind in ['profile', 'warn', 'ignored']))]);
	push(profile, line);
}

// Validate definitions and references, including ones not emitted in the profile.
function check_identifiers(value) {
	if (type(value) == 'array') {
		for (let item in value) check_identifiers(item);
	} else if (type(value) == 'object') {
		for (let key, item in value) {
			if (key in ['tag', 'ruleTag', 'outboundTag', 'inboundTag', 'balancerTag', 'dialerProxy', 'selector', 'fallbackTag', 'subjectSelector', 'destOverride']) {
				for (let field in (type(item) == 'array' ? item : [item])) profile_field(field, false);
			}
			check_identifiers(item);
		}
	}
}

function warn_code(profile, code, fmt, ...args) {
	profile_record(profile, 'warn', code_message(code, fmt, ...args));
}

// Spec 5.1: one Xray config object (or an array of them) with outbounds.
function load_source(text, parse) {
	if (length(text) > MAX_SOURCE) die(code_message('config_invalid', 'config: %s', 'larger than 8 MiB'));
	// ucode \x escapes are code points, not bytes: chr() for the UTF-8 BOM.
	if (substr(text, 0, 3) == chr(239, 187, 191)) text = substr(text, 3);
	let first = match(text, /^[[:space:]]*(.?)/)[1], value;
	if (first != '{' && first != '[' && first != '"') {
		let t = trim(text), plain = t;
		if (match(t, /^[A-Za-z0-9+\/=_\r\n-]+$/)) plain = b64dec(replace(replace(t, /[\r\n]/g, ''), /[-_]/g, (c) => c == '-' ? '+' : '/')) ?? t;
		if (match(plain, /(^|\n)[ \t]*(vless|vmess|trojan|ss|hy2|hysteria2?|tuic|wireguard|socks|https?):\/\//))
			die(code_message('config_share', 'config: share links are not supported, use the Xray JSON subscription URL'));
		if (match(t, /(^|\n)["']?(proxies|proxy-groups)["']?[ \t]*:/))
			die(code_message('config_yaml', 'config: Clash/Mihomo YAML is not supported'));
		die(code_message('config_json', 'config: not JSON'));
	}
	try {
		value = parse(text);
	} catch (e) {
		die(code_message('config_json', 'config: not JSON'));
	}
	let list = type(value) == 'array' ? value : [value];
	if (!length(list)) die(code_message('config_outbounds', 'config: no outbounds'));
	return {list, array: type(value) == 'array'};
}

function has_outbounds(cfg) {
	return type(cfg) == 'object' && type(cfg.outbounds) == 'array' && length(cfg.outbounds) > 0;
}

function bool_of(v) {
	if (type(v) == 'bool') return v ? '1' : '0';
	if (type(v) == 'int' && (v == 0 || v == 1)) return '' + v;
	if (type(v) != 'string') return null;
	v = lc(trim(v));
	if (v in ['true', 'yes', 'on', '1']) return '1';
	if (v in ['false', 'no', 'off', '0']) return '0';
	return null;
}

// xraywrt.router-profile names the `remarks` of the profile the router must
// use. The provider's template repeats the key in every element, so the first
// non-empty string counts. An element with that name is the provider's choice
// and beats the user's; a missing name pins nothing.
function pinned_name(src) {
	if (!src.array) return null;
	let named = filter(src.list, (c) => type(c) == 'object' && type(c.xraywrt) == 'object' &&
		type(c.xraywrt['router-profile']) == 'string' && c.xraywrt['router-profile'] != '')[0];
	return named ? named.xraywrt['router-profile'] : null;
}

function pinned_profile(src) {
	let name = pinned_name(src);
	return name == null ? null : filter(src.list, (c) => type(c) == 'object' && c.remarks == name)[0];
}

// Spec 5.3: array element by `remarks`; empty or unknown profile takes the
// first element (unknown with a warning). An object source ignores profile.
function select_profile(src, want, profile) {
	let list = src.list, cfg = list[0], pinned = pinned_profile(src);
	if (pinned) {
		cfg = pinned;
		profile_record(profile, 'profile-pinned', 1);
	} else if (src.array && want) {
		let found = filter(list, (c) => type(c) == 'object' && c.remarks == want);
		if (length(found)) cfg = found[0];
		else warn_code(profile, 'profile_missing', 'profile "%s" not found, using "%s"', want, cfg?.remarks ?? '');
	}
	if (!pinned && pinned_name(src) != null)
		warn_code(profile, 'router_profile_missing', 'router-profile "%s" not found', pinned_name(src));
	if (!has_outbounds(cfg)) die(code_message('config_outbounds', 'config: no outbounds'));
	if (type(cfg.remarks) == 'string' && cfg.remarks != '') profile_record(profile, 'profile', cfg.remarks);
	return cfg;
}

const BOOL_KEYS = {
	'disable-quic': 'disable_quic', 'dns-hijack': 'dns_hijack', 'bypass-ntp': 'bypass_ntp',
	'bypass-subscription-dns': 'bypass_subscription_dns', 'block-client-ipv6': 'block_client_ipv6',
	'dns-forward-other-types': 'dns_forward_other_types'
};

function hours_of(v) {
	if (type(v) == 'string' && match(v, /^[0-9]+$/)) v = +v;
	return type(v) == 'int' && v >= 0 && v <= 8760 ? v : null;
}

// URL list items get the lists_clean_lines cleanup (comment, whitespace).
function list_of(v) {
	if (v == null) return [];
	if (type(v) != 'array') return null;
	let urls = [];
	for (let item in v) {
		if (type(item) != 'string') return null;
		profile_field(item, false);
		item = replace(replace(item, /#.*/, ''), /[ \t\r\n]/g, '');
		if (item != '') push(urls, item);
	}
	return urls;
}

// Spec 5.2: the provider key `xraywrt` becomes profile lines that
// settings.sh and lists.sh read like x-mihowrt in MihoWRT.
function provider_keys(x, profile) {
	if (x == null) return;
	if (type(x) != 'object') {
		profile_record(profile, 'ignored', 'xraywrt');
		return;
	}
	for (let key, val in x) {
		let v = null;
		if (key == 'router-profile') continue;
		if (key == 'mode') {
			if (val in ['proxy-first', 'direct-first']) v = ['mode', val];
		} else if (key in BOOL_KEYS) {
			v = bool_of(val);
			if (v != null) v = [BOOL_KEYS[key], v];
		} else if (key == 'lists-interval') {
			v = hours_of(val);
			if (v != null) v = ['lists_interval', v];
		} else if (key in ['proxy-ips', 'direct-ips']) {
			let urls = list_of(val);
			if (urls != null) {
				profile_record(profile, 'has', key);
				for (let u in urls) profile_record(profile, key == 'proxy-ips' ? 'proxy-ip' : 'direct-ip', u);
				continue;
			}
		}
		if (v != null) profile_record(profile, 'set', ...v);
		else profile_record(profile, 'ignored', key);
	}
}

// Deletes every `masterKeyLog` below value; returns whether one was found.
function strip_key_log(value) {
	let found = false;
	if (type(value) == 'array') {
		for (let item in value) found = strip_key_log(item) || found;
	} else if (type(value) == 'object') {
		if ('masterKeyLog' in value) {
			delete value.masterKeyLog;
			found = true;
		}
		for (let key, item in value) found = strip_key_log(item) || found;
	}
	return found;
}

// Spec 6.2: router-owned sections are dropped or replaced, everything else
// is the provider's and passes through unchanged.
function apply_ownership(cfg, params, profile) {
	if (cfg.log?.loglevel in ['debug', 'info', 'warning', 'error', 'none']) {
		profile_record(profile, 'set', 'core_log_level', cfg.log.loglevel);
		if (!params.log_level_override) params.log_level = cfg.log.loglevel;
	}
	let out = {};
	for (let k, v in cfg)
		if (!(k in ['remarks', 'xraywrt', 'api', 'stats', 'metrics'])) out[k] = v;
	out.log = {loglevel: params.log_level, access: 'none', dnsLog: false};
	if (cfg.inbounds != null && type(cfg.inbounds) != 'array') die(code_message('config_invalid', 'config: %s', 'inbounds is not an array'));
	let seen = {};
	out.inbounds = filter(cfg.inbounds ?? [], (ib, i) => {
		let name = ib?.tag || sprintf('#%d', i + 1);
		if (ib?.protocol == 'tun') {
			warn_code(profile, 'inbound_tun', 'inbound %s (tun) removed: the router uses TPROXY', name);
			return false;
		}
		if (!params.from_subscription || type(ib) != 'object') return true;
		// A subscription is not trusted to open ports on the network or to bind files.
		if (type(ib.listen) == 'string' && match(ib.listen, /^[\/@]/)) {
			warn_code(profile, 'inbound_socket', 'inbound %s removed: a subscription must not listen on a file', name);
			return false;
		}
		if (type(ib.listen) != 'string' || !match(ib.listen, /^(127\.[0-9.]+|::1|localhost)$/)) {
			ib.listen = '127.0.0.1';
			warn_code(profile, 'inbound_listen', 'inbound %s listens on 127.0.0.1 only: a subscription must not open ports on the network', name);
		}
		// 0.0.0.0 and :: on one port both became 127.0.0.1: the core would fail to bind at start.
		// tcp and udp inbounds may share a port.
		let key = sprintf('%s:%s:%s', ib.listen, ib.port, ib.settings?.network ?? '');
		if (seen[key]) {
			warn_code(profile, 'inbound_duplicate', 'inbound %s removed: its address and port are already used by another inbound', name);
			return false;
		}
		seen[key] = true;
		return true;
	});
	// Xray appends TLS session keys to this file as root.
	if (params.from_subscription && strip_key_log([out.inbounds, cfg.outbounds]))
		warn_code(profile, 'master_key_log', 'masterKeyLog removed: a subscription must not make Xray write files');
	if ('fakedns' in cfg) {
		warn_code(profile, 'fakedns_replaced', 'fakedns section replaced');
		delete out.fakedns;
	}
	return out;
}

const RESERVED = 'xraywrt-';

function check_tag(tag) {
	if (type(tag) == 'string' && substr(tag, 0, length(RESERVED)) == RESERVED)
		die(code_message('config_invalid', 'config: %s', sprintf('tag "%s" uses reserved prefix %s', tag, RESERVED)));
}

// Tags the provider defines; references to router tags stay allowed.
function check_reserved(cfg) {
	for (let ib in (type(cfg.inbounds) == 'array' ? cfg.inbounds : [])) check_tag(ib?.tag);
	for (let ob in cfg.outbounds) check_tag(ob?.tag);
	for (let b in (type(cfg.routing?.balancers) == 'array' ? cfg.routing.balancers : [])) check_tag(b?.tag);
	for (let r in (type(cfg.routing?.rules) == 'array' ? cfg.routing.rules : [])) check_tag(r?.ruleTag);
	for (let s in (type(cfg.dns?.servers) == 'array' ? cfg.dns.servers : [])) check_tag(s?.tag);
	for (let k in ['bridges', 'portals'])
		for (let r in (type(cfg.reverse?.[k]) == 'array' ? cfg.reverse[k] : [])) check_tag(r?.tag);
}

// Transport outbounds only. Explicit freedom chains remain choices; their route is the provider's.
function dns_outbound_tags(cfg) {
	return uniq(map(filter(cfg.outbounds, (o) => type(o?.tag) == 'string' && o.tag != '' &&
		substr(o.tag, 0, length(RESERVED)) != RESERVED && type(o.protocol) == 'string' && o.protocol != '' &&
		!(o.protocol in ['blackhole', 'dns', 'loopback']) &&
		(o.protocol != 'freedom' || !!o.streamSettings?.sockopt?.dialerProxy)), (o) => o.tag));
}

// Read the selected original source without generating it, so invalid saved DNS settings can be repaired.
function dns_outbounds(text, want, api) {
	let cfg = select_profile(load_source(text, api.parse), want, []);
	check_identifiers(cfg);
	return dns_outbound_tags(cfg);
}

// Spec 7.5: address for raw (non A/AAAA) queries: dns_raw_upstream
// ("ip", "ip:port", "[ip6]:port") or, for direct forwarding only, the first WAN DNS; null = none.
function raw_target(params, strict) {
	if (strict && params.dns_raw_via && !params.dns_raw_upstream)
		die(code_message('dns_raw_upstream_required', 'config: dns_raw_upstream is required with dns_raw_via; set an explicit DNS server IP address and optional port'));
	let v = params.dns_raw_upstream || params.wan_dns?.[0];
	if (!v) return null;
	let m = match(v, /^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$/) ?? match(v, /^([^:]+):([0-9]+)$/);
	let ip = m ? m[1] : v, port = m ? +m[2] : 53;
	if (type(v) != 'string' || !iptoarr(ip) || port < 1 || port > 65535) {
		if (!strict) return null;
		die(code_message('dns_raw_upstream_invalid', 'config: dns_raw_upstream must be an IP address with an optional port (1-65535)'));
	}
	return [ip, port];
}

// Raw forwarding only via dns_raw_via or, in direct-first, on request;
// otherwise other types get an empty answer and never leave the router.
function raw_forward(params) {
	if (!params.dns_raw_via && !(params.mode == 'direct-first' && bool_of(params.dns_forward_other_types) == '1'))
		return null;
	return raw_target(params, true);
}

function with_mark(ob, mark) {
	if (type(ob.streamSettings) != 'object') ob.streamSettings = {};
	if (type(ob.streamSettings.sockopt) != 'object') ob.streamSettings.sockopt = {};
	ob.streamSettings.sockopt.mark = mark;
	return ob;
}

// Spec 6.4: every provider outbound (chains too) dials with the router mark,
// so nft lets core traffic out without a TPROXY loop. The first outbound
// stays first (Xray's default); service outbounds go last.
function apply_outbounds(cfg, params, profile) {
	let mark = params.mark;
	for (let i, ob in cfg.outbounds) {
		if (type(ob) != 'object') die(code_message('config_invalid', 'config: %s', sprintf('outbound #%d is not an object', i + 1)));
		let old = ob.streamSettings?.sockopt?.mark;
		if (old != null && old != mark)
			warn_code(profile, 'outbound_mark', 'outbound "%s" mark %s replaced with %s', ob.tag ?? '#' + (i + 1), old, mark);
		with_mark(ob, mark);
	}
	// Direct devices dial like the provider's own direct outbound (spec 6.4).
	let sockopt = {};
	for (let ob in cfg.outbounds) {
		let he = ob.streamSettings?.sockopt?.happyEyeballs;
		if (ob.tag == 'direct' && ob.protocol == 'freedom' && type(he) == 'object')
			sockopt.happyEyeballs = he;
	}
	// ForceIP: internal DNS skips fakedns, AsIs would get the fake-IP back.
	sockopt.domainStrategy = 'ForceIP';
	push(cfg.outbounds,
		with_mark({tag: 'xraywrt-direct', protocol: 'freedom', streamSettings: {sockopt}}, mark));
	// Spec 6.4: nft never sends private addresses to the core, so only a
	// whitelist domain resolving to one (DNS rebinding) reaches them here.
	let nets = params.local_nets ?? [];
	if (!length(nets)) die(code_message('config_invalid', 'config: %s', 'local_nets is empty'));
	// A saved inactive server must not prevent disabling forwarding; invalid values grant no exemption.
	let head = [{action: 'allow', port: '53'}], raw = params.dns_raw_upstream ? raw_target(params, false) : null;
	if (raw) push(head, {action: 'allow', ip: [raw[0]]});
	push(head, {action: 'block', ip: nets});
	for (let i, ob in cfg.outbounds) {
		if (ob.protocol != 'freedom' || ob.streamSettings.sockopt.dialerProxy) continue;
		if (ob.settings == null) ob.settings = {};
		let own = ob.settings.finalRules ?? [];
		if (type(own) != 'array') die(code_message('config_invalid', 'config: %s', sprintf('outbound "%s" finalRules is not an array', ob.tag ?? '#' + (i + 1))));
		ob.settings.finalRules = [...head, ...own];
	}
	push(cfg.outbounds,
		{tag: 'xraywrt-block', protocol: 'blackhole'},
		with_mark({tag: 'xraywrt-dns', protocol: 'dns'}, mark));
}

function is_fakedns(s) {
	return s == 'fakedns' || type(s) == 'object' && s.address == 'fakedns';
}

// UX 4.1: prefer an enabled sniffing block, then the provider's transparent listener.
function provider_sniffing(cfg) {
	let inbounds = type(cfg.inbounds) == 'array' ? cfg.inbounds : [];
	let sniffers = filter(inbounds, (ib) => type(ib?.sniffing) == 'object');
	let enabled = filter(sniffers, (ib) => ib.sniffing.enabled == true);
	if (length(enabled)) sniffers = enabled;
	let transparent = filter(sniffers, (ib) => ib.protocol in ['tunnel', 'dokodemo-door'] &&
		ib.streamSettings?.sockopt?.tproxy in ['tproxy', 'redirect']);
	let source = transparent[0] ?? sniffers[0];
	return source ? json(sprintf('%J', source.sniffing)) : null;
}

function tproxy_inbound(tag, listen, port, sniffing) {
	let inbound = {tag, protocol: 'tunnel', listen, port,
		settings: {allowedNetwork: 'tcp,udp', followRedirect: true},
		streamSettings: {sockopt: {tproxy: 'tproxy'}}};
	if (sniffing != null) inbound.sniffing = sniffing;
	return inbound;
}

// Spec 6.3: listeners match the nft tproxy targets on loopback.
function router_inbounds(params, fake, sniffing) {
	let p = params.ports;
	if (fake) {
		if (sniffing?.enabled != true) sniffing = {enabled: true, destOverride: ['fakedns']};
		else if (!('fakedns' in (sniffing.destOverride ?? [])))
			sniffing.destOverride = ['fakedns', ...(sniffing.destOverride ?? [])];
	}
	let list = [tproxy_inbound('xraywrt-tproxy4', '127.0.0.1', p.tproxy, sniffing)];
	// ::1 does not exist, and the core cannot bind it, when IPv6 is off.
	if (params.ipv6) push(list, tproxy_inbound('xraywrt-tproxy6', '::1', p.tproxy, sniffing));
	// nft sends only the IPv4 fake pool of direct devices here (spec 6.3, 7.2).
	if (fake)
		push(list, tproxy_inbound('xraywrt-fakeip-direct', '127.0.0.1', p.direct, {enabled: true, destOverride: ['fakedns']}));
	let dns = {allowedNetwork: 'tcp,udp'}, raw = raw_forward(params);
	if (raw) {
		dns.rewriteAddress = raw[0];
		dns.rewritePort = raw[1];
	}
	push(list, {tag: 'xraywrt-dns-in', protocol: 'tunnel', listen: '127.0.0.1', port: p.dns, settings: dns});
	return list;
}

// Spec 6.2: `run -test` binds no ports, so a provider inbound on a router
// port would pass the check and only fail at start.
function check_inbound_ports(cfg, params) {
	let p = params.ports, own = [p.tproxy, p.direct, p.dns, p.api];
	for (let i, ib in cfg.inbounds) {
		let v = ib?.port;
		if (v == null) continue;
		for (let part in split('' + v, ',')) {
			let m = match(trim(part), /^([0-9]+)(-([0-9]+))?$/);
			if (!m) continue;
			let lo = +m[1], hi = m[3] != null ? +m[3] : lo;
			for (let x in own)
				if (x >= lo && x <= hi)
					die(code_message('config_invalid', 'config: %s', sprintf('inbound %s port %s collides with a router port',
						type(ib.tag) == 'string' ? sprintf('"%s"', ib.tag) : '#' + (i + 1), '' + v)));
		}
	}
}

// Spec 16: with `listen` the commander serves gRPC itself and registers no
// outbound, so no inbound or rule can route provider traffic to it.
function router_api(params) {
	let p = params.ports;
	if (p.api in [p.dns, p.tproxy, p.direct]) die(code_message('config_invalid', 'config: %s', sprintf('API port %d collides with a router port', p.api)));
	return {tag: 'xraywrt-api', listen: '127.0.0.1:' + p.api, services: ['HandlerService', 'RoutingService', 'StatsService']};
}

// Spec 6.5: router rules go first, the provider's follow unchanged.
// direct_ips: WAN DNS that the internal DNS may reach directly (7.3).
// own: the routing rules of My rules, already in the order of its lines.
function router_rules(cfg, params, fake, direct_ips, own) {
	if (cfg.routing == null) cfg.routing = {};
	if (type(cfg.routing) != 'object') die(code_message('config_invalid', 'config: %s', 'routing is not an object'));
	let provider = cfg.routing.rules ?? [];
	if (type(provider) != 'array') die(code_message('config_invalid', 'config: %s', 'routing.rules is not an array'));
	let rules = [
		{inboundTag: ['xraywrt-dns-in'], outboundTag: 'xraywrt-dns'},
		{inboundTag: ['xraywrt-dns-internal'], ip: ['127.0.0.1', ...direct_ips], port: 53, outboundTag: 'xraywrt-direct'}
	];
	if (fake)
		push(rules, {ip: [params.fakeip_range], outboundTag: 'xraywrt-block'},
			{inboundTag: ['xraywrt-fakeip-direct'], outboundTag: 'xraywrt-direct'});
	cfg.routing.rules = [...rules, ...own, ...provider];
}

const SERVER_PROTOCOLS = ['vless', 'vmess', 'trojan', 'shadowsocks', 'socks', 'http', 'hysteria', 'wireguard'];

// Host names only: IPs need no bootstrap, and anything else must not reach
// the dnsmasq config.
function host_name(v) {
	if (type(v) != 'string') return null;
	v = lc(v);
	if (match(v, /^[0-9.]+$/) || index(v, ':') >= 0) return null;
	return match(v, /^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*$/) && length(v) <= 253 ? v : null;
}

// Spec 7.4: domain addresses of the provider's proxy servers.
function server_hosts(cfg) {
	let hosts = [];
	let add = (v) => {
		let h = host_name(v);
		if (h != null && !(h in hosts)) push(hosts, h);
	};
	let each = (list, f) => {
		if (type(list) == 'array') for (let x in list) if (type(x) == 'object') f(x);
	};
	for (let ob in cfg.outbounds) {
		if (type(ob) != 'object') continue;
		let s = ob.settings;
		if (!(ob.protocol in SERVER_PROTOCOLS) || type(s) != 'object') continue;
		add(s.address);
		each(s.vnext, (x) => add(x.address));
		each(s.servers, (x) => add(x.address));
		each(s.peers, (x) => {
			let m = type(x.endpoint) == 'string' ? match(x.endpoint, /^([A-Za-z0-9._-]+):[0-9]+$/) : null;
			if (m) add(m[1]);
		});
	}
	return hosts;
}

const DNS_TAG = 'xraywrt-dns-internal';

function server_label(s) {
	if (type(s) != 'object') return '' + s;
	return s.port != null ? sprintf('%s:%s', s.address, s.port) : '' + s.address;
}

// Spec 7.3: a plain (UDP/TCP) server on loopback port 53 or the DNS inbound
// port, or the system resolver, sends queries back through dnsmasq to Xray.
function loops_back(s, params) {
	if (type(s) == 'object' && type(s.domains) == 'array' && length(s.domains)) return false;
	let addr = type(s) == 'object' ? s.address : s, port = type(s) == 'object' ? s.port : null;
	if (type(addr) != 'string') return false;
	if (addr == 'localhost') return true;
	let m = match(addr, /^([a-z+]+):\/\/(.*)$/);
	if (m) {
		if (!(m[1] in ['udp', 'tcp', 'tcp+local'])) return false;
		addr = m[2];
	}
	m = match(addr, /^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$/) ?? match(addr, /^([^:]+):([0-9]+)$/);
	let host = m ? m[1] : addr;
	port = m ? +m[2] : (port ?? 53);
	return (match(host, /^127\./) || host in ['::1', 'localhost']) && port in [53, params.ports.dns];
}

// Spec 7.3, 7.4: the provider's dns stays; the router sets the tag and adds
// the WAN DNS when there is no regular server. Proxy hosts resolve
// through the dnsmasq bypass. Returns the WAN DNS that must go direct.
function router_dns(cfg, params, profile) {
	let dns = cfg.dns ?? {};
	if (type(dns) != 'object') die(code_message('config_invalid', 'config: %s', 'dns is not an object'));
	let servers = dns.servers ?? [];
	if (type(servers) != 'array') die(code_message('config_invalid', 'config: %s', 'dns.servers is not an array'));
	for (let s in servers)
		if (loops_back(s, params))
			die(code_message('config_invalid', 'config: %s', sprintf('DNS server "%s" loops back to dnsmasq or Xray; restrict it with domains', server_label(s))));
	if (type(dns.tag) == 'string' && dns.tag != DNS_TAG)
		for (let r in (type(cfg.routing?.rules) == 'array' ? cfg.routing.rules : []))
			if (type(r?.inboundTag) == 'array' && dns.tag in r.inboundTag) {
				r.inboundTag = map(r.inboundTag, (t) => t == dns.tag ? DNS_TAG : t);
				warn_code(profile, 'dns_tag', 'dns tag "%s" renamed to %s', dns.tag, DNS_TAG);
			}
	let list = [...servers], direct = [];
	if (!length(filter(servers, (s) => !is_fakedns(s)))) {
		if (length(params.wan_dns ?? [])) {
			push(list, ...params.wan_dns);
			profile_record(profile, 'uses-wan-dns');
			if (params.mode == 'direct-first') direct = params.wan_dns;
			else warn_code(profile, 'dns_wan', 'no proxy DNS configured, using WAN DNS');
		} else {
			die(code_message('config_invalid', 'config: %s', 'no DNS server: add dns.servers to the configuration'));
		}
	}
	let out = {tag: DNS_TAG, servers: list};
	for (let k, v in dns) if (!(k in ['tag', 'servers'])) out[k] = v;
	cfg.dns = out;
	return direct;
}

const FAKE_LIMIT = 10000;
// Addresses of one routing rule of My rules, typed or fetched.
const RULE_IPS_LIMIT = 10000;
// Reserved targets: never a provider tag.
const RULE_WORDS = ['direct', 'core'];

// Spec 11: one Xray domain per line, no prefix = domain:, # comments.
function fake_entry(line) {
	let m = match(line, /^([a-z]+):(.*)$/), kind = m ? m[1] : 'domain', v = m ? m[2] : line;
	switch (kind) {
	case 'domain': case 'full':
		let h = host_name(v);
		return h ? kind + ':' + h : null;
	case 'geosite': case 'keyword':
		return match(v, /^[^ \t\n:]+$/) ? kind + ':' + v : null;
	case 'regexp':
		return length(v) ? line : null;
	case 'ext':
		return match(v, /^[^ \t\n:]+:[^ \t\n:]+$/) ? line : null;
	}
	return null;
}

// A provider tag that My rules can name: a proxy outbound or a balancer whose
// tag is a single word that is not reserved.
function rule_targets(cfg) {
	let tags = [], reserved = [];
	let take = (tag) => {
		if (type(tag) != 'string') return;
		if (tag in RULE_WORDS) {
			if (!(tag in reserved)) push(reserved, tag);
		} else if (tag != '' && !match(tag, /[[:space:]#]/) && substr(tag, 0, length(RESERVED)) != RESERVED && !(tag in tags)) {
			push(tags, tag);
		}
	};
	for (let ob in cfg.outbounds)
		if (type(ob) == 'object' && !(ob.protocol in ['freedom', 'blackhole', 'dns'])) take(ob.tag);
	for (let b in (type(cfg.routing?.balancers) == 'array' ? cfg.routing.balancers : []))
		if (type(b) == 'object') take(b.tag);
	return {tags, reserved};
}

// What a line of My rules points at: an address or subnet, a link to a list
// of them, or a site in the Xray domain syntax.
function rule_what(word) {
	let m = match(word, /^(.*)\/([0-9]+)$/), bits = m ? +m[2] : null;
	let addr = iptoarr(m ? m[1] : word);
	if (addr) {
		if (bits != null && bits > length(addr) * 8) return null;
		return {kind: 'ip', value: arrtoip(addr) + (bits != null ? '/' + bits : '')};
	}
	// A link needs a path: https://youtube.com is a site, written without the scheme.
	if (match(word, /^https?:\/\/[^\/;[:space:][:cntrl:]]+\/[^;[:space:][:cntrl:]]+$/)) return {kind: 'url', value: word};
	// 1.2.3.4-1.2.3.9 is a mistyped address, not a site.
	if (match(word, /^[0-9.-]+$/)) return null;
	let site = fake_entry(word);
	return site != null ? {kind: 'site', value: site} : null;
}

// Lines of My rules: `<what> <target>`, `#` starts a comment. `error` is
// bad_entry, no_target or unknown_target; the rest are usable as they stand.
function parse_rules(text, tags) {
	let out = [], number = 0;
	for (let raw in split(text ?? '', '\n')) {
		number++;
		let line = trim(replace(raw, /#.*/, ''));
		if (!length(line)) continue;
		let words = split(line, /[ \t]+/), what = rule_what(words[0]);
		let e = {line: number, text: line, ...(what ?? {}), target: words[1]};
		if (!what || length(words) > 2) e.error = 'bad_entry';
		else if (length(words) < 2) e.error = 'no_target';
		else if (!(e.target in RULE_WORDS) && !(e.target in tags)) e.error = 'unknown_target';
		push(out, e);
	}
	return out;
}

// Problems of a saved My rules text: bad lines, unknown targets and too many sites.
function check_rules(text, tags) {
	let errors = [], sites = 0;
	for (let e in parse_rules(text, tags)) {
		if (e.error) push(errors, {line: e.line, text: e.text, code: e.error, target: e.target});
		else if (e.kind == 'site' && ++sites == FAKE_LIMIT + 1) push(errors, {line: e.line, text: e.text, code: 'limit'});
	}
	return errors;
}

// Addresses, subnets and list links of the usable lines that go direct, or all others.
function rule_addresses(text, tags, direct) {
	return map(filter(parse_rules(text, tags), (e) => !e.error && e.kind != 'site' && (e.target == 'direct') == direct), (e) => e.value);
}

// List links whose target is a tag: their addresses are routing conditions.
function rule_routed_urls(text, tags) {
	return uniq(map(filter(parse_rules(text, tags), (e) => !e.error && e.kind == 'url' && !(e.target in RULE_WORDS)), (e) => e.value));
}

// Every list link of My rules, whatever its target: its cache stays.
function rule_urls(text) {
	return uniq(map(filter(parse_rules(text, []), (e) => e.kind == 'url' && (e.error == null || e.error == 'unknown_target')), (e) => e.value));
}

// Addresses and subnets of the cached fetch of a remote list. Anything else
// (an entry with ports, a MAC, text) cannot be a routing condition.
function cached_ips(path, api) {
	let list = [];
	for (let line in split(path ? api.readfile(path) ?? '' : '', '\n')) {
		let what = rule_what(line);
		if (what?.kind == 'ip') push(list, what.value);
	}
	return list;
}

// My rules (spec 11): the own lines of the router, in order. Adjacent lines
// with the same target and kind make one run, so a run is one DNS server
// entry and one routing rule and first-match order is that of the lines.
// Returns the DNS entries and routing rules for the generator.
function own_rules(cfg, params, api, profile) {
	let found = rule_targets(cfg), balancers = map(type(cfg.routing?.balancers) == 'array' ? cfg.routing.balancers : [], (b) => b?.tag);
	for (let tag in found.tags) profile_record(profile, 'rules-target', tag);
	for (let tag in found.reserved) profile_record(profile, 'rules-reserved', tag);
	let text = params.rules_file ? api.readfile(params.rules_file) : null;
	let runs = [], seen = {}, missing = [], sites = 0, limited = false;
	for (let e in parse_rules(text, found.tags)) {
		if (e.error == 'unknown_target') {
			if (!(e.target in missing)) push(missing, e.target);
			continue;
		}
		if (e.error) {
			warn_code(profile, 'rule_ignored', 'My rules: line %s "%s" ignored', e.line, e.text);
			continue;
		}
		if (seen[e.value]) continue;
		seen[e.value] = true;
		let kind = e.kind == 'site' ? 'site' : 'ip';
		if (kind == 'site' && sites >= FAKE_LIMIT) {
			if (!limited) warn_code(profile, 'rules_limit', 'My rules has more than %s sites, the rest is ignored', FAKE_LIMIT);
			limited = true;
			continue;
		}
		if (kind == 'site') sites++;
		let last = runs[-1];
		if (last && last.kind == kind && last.target == e.target) push(last.items, e);
		else push(runs, {kind, target: e.target, items: [e]});
	}
	if (length(missing)) warn_code(profile, 'rules_target_missing', 'My rules: the targets %s are not in the configuration, their lines are skipped', join(', ', missing));
	// UX 4.2: fake-IP sniffing alone cannot recognize arbitrary direct sites in
	// proxy-first. Direct-first answers these names with real addresses, so they
	// never reach the core and need no recognition.
	let sniff = filter(profile, (l) => substr(l, 0, 6) == 'sniff ')[0];
	let recognizes = length(filter(split(substr(sniff ?? '', 6), ','), (s) => s in ['http', 'tls', 'quic'])) > 0;
	let direct_sites = filter(runs, (r) => r.kind == 'site' && r.target == 'direct');
	if (params.mode != 'direct-first' && length(direct_sites) && !recognizes) {
		warn_code(profile, 'direct_no_sniffing', 'direct domains ignored: the provider config has no sniffing');
		runs = filter(runs, (r) => !(r.kind == 'site' && r.target == 'direct'));
	}
	// Direct sites in direct-first get a real address from a general server:
	// one limited to its own domains may not answer these.
	let plain = filter(cfg.dns.servers, (s) => !is_fakedns(s));
	let server = filter(plain, (s) => type(s) != 'object' || !length(s.domains))[0] ?? plain[0];
	let dns = [], rules = [], direct_count = 0, fake_count = 0;
	for (let i, run in runs) {
		let values = map(run.items, (e) => e.value), ref;
		if (run.target == 'direct') ref = {outboundTag: 'xraywrt-direct'};
		else if (run.target in balancers) ref = {balancerTag: run.target};
		else ref = {outboundTag: run.target};
		if (run.kind == 'site') {
			if (run.target == 'direct') {
				direct_count += length(values);
				if (params.mode == 'direct-first') {
					let entry = {address: type(server) == 'object' ? server.address : server, domains: values, skipFallback: true};
					if (type(server) == 'object' && server.port != null) entry.port = server.port;
					push(dns, entry);
				}
			} else {
				fake_count += length(values);
				push(dns, {address: 'fakedns', domains: values, skipFallback: true, queryStrategy: 'UseIPv4'});
			}
			if (run.target != 'core') push(rules, {domain: values, ...ref, ruleTag: sprintf('xraywrt-rule-%d', i + 1)});
		} else if (run.target != 'direct' && run.target != 'core') {
			// Addresses to direct bypass in nft; core ones need no routing rule.
			let ips = [], got = {};
			for (let e in run.items) {
				for (let ip in (e.kind == 'url' ? cached_ips(params.rules_remote?.[e.value], api) : [e.value])) {
					if (got[ip]) continue;
					got[ip] = true;
					push(ips, ip);
					if (length(ips) > RULE_IPS_LIMIT) break;
				}
				if (length(ips) > RULE_IPS_LIMIT) break;
			}
			// A list that grew must not stop the start: skip the rule, tell Home.
			if (length(ips) > RULE_IPS_LIMIT) {
				warn_code(profile, 'rules_too_large', 'My rules: the rule "%s" has more than %s addresses and is skipped', run.target, RULE_IPS_LIMIT);
				continue;
			}
			if (length(ips)) push(rules, {ip: ips, ...ref, ruleTag: sprintf('xraywrt-rule-%d', i + 1)});
		}
	}
	profile_record(profile, 'direct-domains', direct_count);
	return {dns, rules, fake_count};
}

// Spec 7.2: the router's own fakedns server goes first, IPv4-only pool;
// returns whether fake-IP is in use. `own` are the DNS server entries of
// My rules in line order; they sit before the provider's servers.
function router_fakedns(cfg, params, own, profile) {
	let servers = cfg.dns.servers, provided = 0;
	for (let s in servers)
		if (is_fakedns(s) && type(s) == 'object' && type(s.domains) == 'array')
			provided += length(s.domains);
	profile_record(profile, 'provider-fake-domains', provided);
	let count = own.fake_count, out = [];
	for (let s in servers) {
		if (is_fakedns(s)) {
			if (type(s) != 'object') s = {address: 'fakedns'};
			s.queryStrategy ??= 'UseIPv4';
			count += type(s.domains) == 'array' ? length(s.domains) : 0;
		}
		push(out, s);
	}
	cfg.dns.servers = [...own.dns, ...out];
	profile_record(profile, 'fake-domains', count);
	let fake = length(filter(cfg.dns.servers, is_fakedns)) > 0;
	profile_record(profile, 'fake-enabled', fake ? 1 : 0);
	if (fake) cfg.fakedns = [{ipPool: params.fakeip_range, poolSize: 65535}];
	return fake;
}

// Spec 7.5: A/AAAA go to the internal DNS, everything else is answered
// empty or sent raw to the inbound's rewriteAddress.
function dns_outbound(cfg, params, profile) {
	let ob = filter(cfg.outbounds, (o) => o.tag == 'xraywrt-dns')[0], rules = [];
	push(rules, {qType: '1,28', action: 'hijack'});
	let domains = [], seen = {};
	for (let s in cfg.dns.servers)
		if (is_fakedns(s) && type(s.domains) == 'array')
			for (let d in s.domains) if (!seen[d]) { seen[d] = true; push(domains, d); }
	let via = params.dns_raw_via;
	// Recorded even while WAN DNS is still empty at boot, so net_refresh rebuilds once it arrives.
	if (!via && !params.dns_raw_upstream && params.mode == 'direct-first' && bool_of(params.dns_forward_other_types) == '1' && !('uses-wan-dns' in profile))
		profile_record(profile, 'uses-wan-dns');
	if (!raw_forward(params)) {
		push(rules, {action: 'return'});
	} else {
		if (length(domains)) push(rules, {domain: domains, action: 'return'});
		// A fakedns server without domains covers every name: HTTPS/SVCB
		// records would hand clients real addresses past the fake-IP range.
		if (length(filter(cfg.dns.servers, (s) => is_fakedns(s) && type(s.domains) != 'array')))
			push(rules, {qType: '65,64', action: 'return'});
		if (via) {
			ob.streamSettings.sockopt.dialerProxy = via;
		}
		push(rules, {action: 'direct'});
	}
	ob.settings = {rules};
}

function geo_file(f) {
	if (type(f) != 'string' || !match(f, /^[A-Za-z0-9._-]+\.dat$/))
		die(code_message('config_invalid', 'config: %s', sprintf('geodata file "%s" is invalid', f ?? '')));
	return f;
}

function geo_walk(v, refs) {
	if (type(v) == 'array') {
		for (let x in v) geo_walk(x, refs);
	} else if (type(v) == 'object') {
		for (let k, x in v) geo_walk(x, refs);
	} else if (type(v) == 'string') {
		let m = match(v, /^(geosite|geoip):/), f = m ? m[1] + '.dat' : null;
		if (!f && (m = match(v, /^ext:(.*):[^:]*$/))) f = geo_file(m[1]);
		if (f && !(f in refs)) push(refs, f);
	}
}

// Numeric five-field cron, matching the Core editor's validation.
function geodata_cron_valid(value) {
	if (type(value) != 'string') return false;
	let fields = split(trim(value), /[[:space:]]+/);
	if (length(fields) != 5) return false;
	let low = [0, 0, 1, 1, 0], high = [59, 23, 31, 12, 6];
	for (let i = 0; i < 5; i++) {
		for (let part in split(fields[i], ',')) {
			let m = match(part, /^(\*|[0-9]+(-[0-9]+)?)(\/([0-9]+))?$/);
			if (!m || (m[4] != null && (+m[4] < 1 || +m[4] > high[i] - low[i] + 1))) return false;
			if (m[1] == '*') continue;
			let range = split(m[1], '-'), a = +range[0], b = +(range[1] ?? range[0]);
			if (a < low[i] || b > high[i] || a > b) return false;
		}
	}
	return true;
}

// Values a cron field of the given range matches: `*`, `a`, `a-b`, lists and /step.
function cron_values(field, low, high) {
	let count = 0;
	for (let part in split(field, ',')) {
		let m = match(part, /^(\*|[0-9]+(-[0-9]+)?)(\/([0-9]+))?$/), lo = low, hi = high;
		if (m[1] != '*') {
			let range = split(m[1], '-');
			lo = +range[0];
			hi = range[1] != null ? +range[1] : (m[4] != null ? high : lo);
		}
		count += int((hi - lo) / +(m[4] ?? 1)) + 1;
	}
	return count;
}

// The provider's schedule must be valid and run at most once a day; else the router's applies.
function geodata_provider_cron(cfg, params, profile) {
	let cron = cfg.geodata?.cron;
	if (cron == null) return;
	if (geodata_cron_valid(cron)) {
		let fields = split(trim(cron), /[[:space:]]+/);
		if (cron_values(fields[0], 0, 59) * cron_values(fields[1], 0, 23) <= 1) return;
	}
	let own = geodata_cron_valid(params.geodata_cron) ? params.geodata_cron : '0 5 * * *';
	warn_code(profile, 'geodata_provider_cron', 'geodata cron "%s" from the subscription is invalid or more frequent than daily, using %s', cron, own);
	cfg.geodata.cron = own;
}

function geodata_user_assets(cfg, params, profile) {
	let entries = params.geodata_asset ?? [], own_names = [];
	for (let entry in entries) {
		let m = type(entry) == 'string' ? match(entry, /^([A-Za-z0-9._-]+\.dat)=(https:\/\/[^[:space:][:cntrl:]]+)$/) : null;
		if (!m || !match(m[2], /^https:\/\/[^\/[:space:]?#]+/)) {
			warn_code(profile, 'geodata_entry', 'geodata asset: invalid entry, expected NAME.dat=https://URL');
			continue;
		}
		let g = cfg.geodata;
		// Provider validation remains in geodata_refs; never repair invalid input.
		if (g != null && (type(g) != 'object' || (g.assets != null && type(g.assets) != 'array'))) continue;
		if (length(filter(g?.assets ?? [], (a) => a?.file == m[1]))) {
			let own = m[1] in own_names;
			if (own) warn_code(profile, 'geodata_duplicate', 'geodata %s: duplicate file name, entry skipped', m[1]);
			else warn_code(profile, 'geodata_collision', 'geodata %s: the subscription already has a file with this name, rename yours', m[1]);
			continue;
		}
		if (g == null) cfg.geodata = g = {};
		if (g.assets == null) g.assets = [];
		push(g.assets, {file: m[1], url: m[2]});
		push(own_names, m[1]);
	}
	if (length(own_names) && !cfg.geodata.cron) {
		let cron = params.geodata_cron ?? '0 5 * * *';
		if (!geodata_cron_valid(cron)) {
			warn_code(profile, 'geodata_cron', 'geodata cron: invalid schedule, using 0 5 * * *');
			cron = '0 5 * * *';
		}
		cfg.geodata.cron = cron;
	}
}

// Spec 10: the provider's geodata section stays; the profile lists its
// assets and every file that routing or dns refers to.
function geodata_files(cfg) {
	let refs = [];
	geo_walk(cfg.routing, refs);
	geo_walk(cfg.dns, refs);
	return sort(refs);
}

function geodata_refs(cfg, profile) {
	let g = cfg.geodata;
	if (g != null) {
		if (type(g) != 'object') die(code_message('config_invalid', 'config: %s', 'geodata is not an object'));
		if (g.assets != null && type(g.assets) != 'array') die(code_message('config_invalid', 'config: %s', 'geodata.assets is not an array'));
		for (let a in g.assets ?? []) {
			let f = geo_file(a?.file);
			profile_field(a?.url, false);
			if (type(a.url) != 'string' || !match(a.url, /^https:\/\/[^ \t\n]+$/))
				die(code_message('config_invalid', 'config: %s', sprintf('geodata url "%s" is not https', a.url ?? '')));
			profile_record(profile, 'geodata', f, a.url);
		}
	}
	for (let f in geodata_files(cfg)) profile_record(profile, 'geodata-ref', f);
}

// UX 4.1a: only a rule covering all traffic replaces the default outbound.
function infer_mode(cfg, profile) {
	let target = cfg.outbounds[0];
	for (let r in (type(cfg.routing?.rules) == 'array' ? cfg.routing.rules : [])) {
		if (type(r) != 'object') continue;
		let conditions = filter(keys(r), (k) => !(k in ['type', 'outboundTag', 'balancerTag', 'ruleTag']));
		let all = !length(conditions);
		if (length(conditions) == 1) {
			let k = conditions[0], v = r[k];
			if (k == 'network' && type(v) == 'string') {
				let networks = map(split(v, ','), (n) => trim(n));
				all = 'tcp' in networks && 'udp' in networks;
			} else if (k == 'ip' && type(v) == 'array') all = '0.0.0.0/0' in v && '::/0' in v;
			else if (k == 'port') all = v in ['0-65535', '1-65535'];
		}
		if (!all) continue;
		target = r.balancerTag != null ? null : filter(cfg.outbounds, (ob) => ob.tag == r.outboundTag)[0];
		break;
	}
	let selected = 'has proxy-ips' in profile || length(filter(cfg.dns.servers,
		(s) => is_fakedns(s) && type(s) == 'object' && type(s.domains) == 'array' && length(s.domains)));
	return target?.protocol == 'freedom' && !target.streamSettings?.sockopt?.dialerProxy && selected ? 'direct-first' : 'proxy-first';
}

function generate(text, params, api) {
	let profile = [];
	profile_record(profile, 'profile-schema', 1);
	let cfg = select_profile(load_source(text, api.parse), params.profile ?? '', profile);
	check_identifiers(cfg);
	provider_keys(cfg.xraywrt, profile);
	// Effective mode: the provider's unless UCI provider_override lists it.
	let pm = filter(profile, (l) => substr(l, 0, 9) == 'set mode ');
	let mode_at = length(profile);
	let mode_source = params.mode_override ? 'user' : length(pm) ? 'provider' : 'auto';
	if (mode_source == 'provider') params.mode = substr(pm[0], 9);
	let pf = filter(profile, (l) => substr(l, 0, 28) == 'set dns_forward_other_types ');
	if (length(pf) && !params.dns_forward_override) params.dns_forward_other_types = substr(pf[0], 28);
	let sniffing = provider_sniffing(cfg);
	let sniff = sniffing?.enabled == true ? join(',', sniffing.destOverride ?? []) : '';
	profile_record(profile, 'sniff', (sniff || '0'));
	if (!sniff && length(filter(type(cfg.routing?.rules) == 'array' ? cfg.routing.rules : [], (r) => r?.domain != null)))
		warn_code(profile, 'provider_no_sniffing', 'the provider config has no sniffing: domain rules see only IP addresses');
	if (type(cfg.observatory) == 'object' || type(cfg.burstObservatory) == 'object')
		for (let b in (type(cfg.routing?.balancers) == 'array' ? cfg.routing.balancers : []))
			if (b?.strategy?.type in ['leastPing', 'leastLoad'] && type(b.tag) == 'string' && b.tag != '')
				profile_record(profile, 'observe-balancer', b.tag);
	check_reserved(cfg);
	// Preview only: accepted-runtime callers persist this decision under the runtime lock.
	let lost = params.dns_raw_lost || (params.dns_raw_via && !(params.dns_raw_via in dns_outbound_tags(cfg)) ? params.dns_raw_via : '');
	if (lost) {
		profile_record(profile, 'dns-raw-lost', lost);
		warn_code(profile, 'dns_raw_lost', 'Forwarding of other DNS query types was turned off because its outbound became unavailable. Choose an outbound in Advanced DNS to re-enable it, or leave forwarding off.');
		params.dns_raw_via = '';
		params.dns_forward_other_types = 0;
	}
	cfg = apply_ownership(cfg, params, profile);
	let hosts = server_hosts(cfg);
	for (let h in hosts) profile_record(profile, 'server-host', h);
	apply_outbounds(cfg, params, profile);
	let direct_ips = router_dns(cfg, params, profile);
	if (mode_source == 'auto') params.mode = infer_mode(cfg, profile);
	// Keep the mode near provider settings in the line-oriented profile.
	let mode_records = [];
	profile_record(mode_records, 'mode', params.mode);
	profile_record(mode_records, 'mode-source', mode_source);
	profile = [...slice(profile, 0, mode_at), ...mode_records, ...slice(profile, mode_at)];
	// WAN DNS routing depends on the effective mode, not the stored UCI value.
	if ('uses-wan-dns' in profile) {
		direct_ips = params.mode == 'direct-first' ? params.wan_dns : [];
		profile = filter(profile, (l) => !match(l, / \[E:dns_wan\]$/));
		if (params.mode != 'direct-first') warn_code(profile, 'dns_wan', 'no proxy DNS configured, using WAN DNS');
	}
	let own = own_rules(cfg, params, api, profile);
	let fake = router_fakedns(cfg, params, own, profile);
	check_inbound_ports(cfg, params);
	push(cfg.inbounds, ...router_inbounds(params, fake, sniffing));
	cfg.api = router_api(params);
	router_rules(cfg, params, fake, direct_ips, own.rules);
	dns_outbound(cfg, params, profile);
	if (type(cfg.geodata) == 'object') geodata_provider_cron(cfg, params, profile);
	geodata_user_assets(cfg, params, profile);
	geodata_refs(cfg, profile);
	let warnings = {};
	profile = filter(profile, (line) => {
		if (substr(line, 0, 5) != 'warn ') return true;
		if (warnings[line]) return false;
		warnings[line] = true;
		return true;
	});
	return {config: cfg, profile};
}

// Spec 5.3: `remarks` of the profiles of an array source (object: none).
function profiles(text, api) {
	let src = load_source(text, api.parse);
	if (!src.array || pinned_profile(src)) return [];
	return map(filter(src.list, (c) => type(c) == 'object' && type(c.remarks) == 'string' && c.remarks != ''), (c) => c.remarks);
}

function equal_config(a, b) {
	if (type(a) != type(b)) return false;
	if (type(a) != 'array' && type(a) != 'object') return a == b;
	if (length(a) != length(b)) return false;
	for (let k, v in a)
		if ((type(a) == 'object' && !(k in b)) || !equal_config(v, b[k])) return false;
	return true;
}

// AddRule replaces rules/balancers, not router settings such as domainStrategy.
function diff_sections(old, next) {
	for (let k in uniq([...keys(old), ...keys(next)]))
		if (!(k in ['outbounds', 'routing']) && (!(k in old) || !(k in next) || !equal_config(old[k], next[k]))) return 'restart';
	// Untagged/duplicate handlers and a different default cannot be replayed by tag.
	for (let cfg in [old, next]) {
		let tags = [];
		for (let ob in cfg.outbounds ?? []) {
			if (type(ob.tag) != 'string' || ob.tag == '' || index(ob.tag, '\x00') >= 0 || match(ob.tag, /[[:cntrl:]]/) || ob.tag in tags) return 'restart';
			push(tags, ob.tag);
		}
	}
	if (old.outbounds?.[0]?.tag != next.outbounds?.[0]?.tag) return 'restart';
	let a = old.routing ?? {}, b = next.routing ?? {};
	for (let k in uniq([...keys(a), ...keys(b)]))
		if (!(k in ['rules', 'balancers']) && (!(k in a) || !(k in b) || !equal_config(a[k], b[k]))) return 'restart';
	return 'hot';
}

// `add` keeps candidate order: when the default (first) handler changed,
// rmo clears the core's default and AddOutbound makes the first added
// handler the new default, so it must lead the ado file.
function outbound_delta(old, next) {
	let a = old.outbounds ?? [], b = next.outbounds ?? [];
	return {
		remove: map(filter(a, (o) => !length(filter(b, (n) => equal_config(o, n)))), (o) => o.tag),
		add: filter(b, (n) => !length(filter(a, (o) => equal_config(o, n))))
	};
}

return { generate, profiles, dns_outbounds, diff_sections, outbound_delta, code_message, geodata_files, rule_targets, check_rules, rule_addresses, rule_urls, rule_routed_urls };
