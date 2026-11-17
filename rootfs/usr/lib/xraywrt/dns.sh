#!/bin/ash

# Point dnsmasq at Xray with a conf-dir file (spec 7.1). Nothing in UCI changes, so
# there is nothing to back up: removing the file (or a reboot, it lives in
# tmpfs) restores the user's DNS setup.

# -X prints real names (cfg01411c) for anonymous sections, as dnsmasq's init
# script uses them for the default confdir.
dns_sections() {
	uci -q -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'
}

dns_confdirs() {
	local section="" dir=""

	for section in $(dns_sections); do
		dir="$(uci -q get "dhcp.$section.confdir" 2>/dev/null)" || dir=""
		[ -n "$dir" ] || dir="/tmp/dnsmasq.$section.d"
		printf '%s\n' "${dir%%,*}"
	done
}

# DNS servers of the WAN interfaces, as learned by netifd (provider or custom).
dns_wan_servers() {
	[ -r "$DNS_AUTO_RESOLVFILE" ] || return 0
	awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ && $2 !~ /%/ { print $2 }' "$DNS_AUTO_RESOLVFILE"
}

# Plain DNS names only: anything else could inject dnsmasq syntax.
dns_host_name() {
	case "$1" in
	'' | *[!A-Za-z0-9.-]* | .* | *..*) return 1 ;;
	esac
	is_ipv4 "$1" && return 1
	printf '%s\n' "$1"
}

# Hosts that must resolve even when Xray is broken or loops (spec 7.1, 7.4):
# NTP (TLS needs a correct clock), the subscription server, the core release hosts,
# geodata URLs and the proxy servers themselves.
dns_bypass_hosts() {
	local host="" url=""

	# shellcheck disable=SC2086 # a fixed space-separated host list
	printf '%s\n' $CORE_RELEASE_HOSTS
	profile_entries server-host | while IFS= read -r host; do dns_host_name "$host"; done
	profile_entries geodata | while IFS=' ' read -r _ url; do dns_host_name "$(url_host "$url")"; done

	if [ "${BYPASS_NTP:-1}" = "1" ]; then
		for host in $(uci -q get system.ntp.server 2>/dev/null); do
			dns_host_name "$host"
		done
	fi
	if [ "${BYPASS_SUBSCRIPTION_DNS:-1}" = "1" ] && [ -n "${SUBSCRIPTION_URL:-}" ]; then
		host="$(url_host "$SUBSCRIPTION_URL")"
		dns_host_name "$host"
	fi
}

dns_render() {
	local out="$1" host="" server="" servers=""

	servers="$(dns_wan_servers)"
	{
		printf 'no-resolv\n'
		printf 'server=127.0.0.1#%s\n' "$XRAY_DNS_PORT"
		[ -z "$servers" ] || for host in $(dns_bypass_hosts | sort -u); do
			for server in $servers; do
				printf 'server=/%s/%s\n' "$host" "$server"
			done
		done
	} >"$out"
}

dns_restart_dnsmasq() {
	[ -x /etc/init.d/dnsmasq ] || return 0
	/etc/init.d/dnsmasq restart 6>&- 9>&- >/dev/null 2>&1
}

dns_apply() {
	rm -f "$NET_FP_FILE"
	settings_require || return 1

	local dir="" tmp="" changed=0

	tmp="$PKG_TMP_DIR/dns.conf.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	dns_render "$tmp" || {
		rm -f "$tmp"
		return 1
	}
	for dir in $(dns_confdirs); do
		cmp -s "$tmp" "$dir/$DNS_CONF_NAME" && continue
		if ! { ensure_dir "$dir" && cp "$tmp" "$dir/$DNS_CONF_NAME"; }; then
			rm -f "$tmp"
			err "Failed to write $dir/$DNS_CONF_NAME"
			return 1
		fi
		changed=1
	done
	rm -f "$tmp"
	[ "$changed" -eq 1 ] || return 0
	dns_restart_dnsmasq || {
		err "dnsmasq restart failed"
		return 1
	}
	log "dnsmasq now uses Xray DNS 127.0.0.1#$XRAY_DNS_PORT"
}

dns_cleanup() {
	rm -f "$NET_FP_FILE"
	local file="" removed=0

	for file in $(dns_confdirs | sed "s|\$|/$DNS_CONF_NAME|") /tmp/dnsmasq*.d/"$DNS_CONF_NAME"; do
		[ -e "$file" ] || continue
		rm -f "$file"
		removed=1
	done
	[ "$removed" -eq 1 ] || return 0
	dns_restart_dnsmasq
	log "dnsmasq DNS restored"
}

# Interface updates change both DNS servers and connected/delegated routes.
net_refresh() {
	service_ready || { service_running && [ -f "$DEGRADED_FILE" ]; } || return 0
	[ ! -f "$USER_STOP_FILE" ] || return 0
	local rc=0 fingerprint="" previous="" line="" new_dns="" old_dns="" new_v6=0 old_v6=0
	fingerprint="$(
		# Toggling disable_ipv6 changes the rendered ruleset without a prefix change.
		route_ipv6_enabled && printf '%s\n' '--ipv6--'
		{ nft_connected_prefixes 4; nft_connected_prefixes 6; } | sort -u
		printf '%s\n' '--dns--'
		dns_wan_servers | sort -u
	)"
	{
		while IFS= read -r line || [ -n "$line" ]; do
			previous="${previous}${previous:+
}$line"
		done <"$NET_FP_FILE"
	} 2>/dev/null || :
	# A flushed policy table must still be restored by the next interface event.
	[ "$fingerprint" != "$previous" ] || ! nft_active || return 0
	settings_load || return 1
	# Spec 7.3, 7.5: the generator marks WAN DNS in the runtime config (default
	# resolver or raw address) with uses-wan-dns; runtime_refresh restarts the
	# core only when the output really changed.
	new_dns="${fingerprint#*--dns--}"
	case "$previous" in *--dns--*) old_dns="${previous#*--dns--}" ;; esac
	# The generator emits the ::1 tproxy inbound only while IPv6 routing is on.
	case "$fingerprint" in "--ipv6--"*) new_v6=1 ;; esac
	case "$previous" in "--ipv6--"*) old_v6=1 ;; esac
	if [ "$new_v6" != "$old_v6" ] ||
		{ [ "$new_dns" != "$old_dns" ] && grep -qx uses-wan-dns "$PROFILE_FILE" 2>/dev/null; }; then
		runtime_refresh || rc=1
		settings_load || return 1
	fi
	# Degraded cores accept DNS inputs without restoring interception early.
	[ -f "$RUNNING_MARKER" ] && [ ! -f "$USER_STOP_FILE" ] || return "$rc"
	dns_apply || rc=1
	route_setup || rc=1
	# New prefixes must reach nft even when dnsmasq could not be updated.
	nft_apply || rc=1
	[ "$rc" -ne 0 ] || printf '%s' "$fingerprint" >"$NET_FP_FILE"
	return "$rc"
}

# fd 6 coalesces interface bursts without holding the runtime lock while idle.
net_refresh_coalesced() {
	local pending="$PKG_STATE_DIR/net-refresh.pending" rc=0

	NET_REFRESH_DELAY="${NET_REFRESH_DELAY:-2}"
	ensure_dir "$PKG_STATE_DIR" || return 1
	while :; do
		exec 6>>"$PKG_STATE_DIR/net-refresh.flock"
		: >"$pending" || { exec 6>&-; return 1; }
		if ! flock -n 6; then
			exec 6>&-
			return "$rc"
		fi
		sleep "$NET_REFRESH_DELAY"
		while :; do
			rm -f "$pending"
			rc=0
			with_lock net_refresh || rc=$?
			[ -f "$pending" ] || break
		done
		flock -u 6
		exec 6>&-
		# An event arriving after the last check still needs an owner.
		[ -f "$pending" ] || return "$rc"
	done
}

dns_custom_servers() {
	uci -q show dhcp 2>/dev/null | sed -n "s/^dhcp\.[^.]*\.server='\(.*\)'$/\1/p" | tr "'" ' '
}

# Plain upstream servers in dnsmasq bypass Xray; domain-scoped ones are fine.
dns_global_custom_servers() {
	local server=""

	for server in $(dns_custom_servers); do
		case "$server" in
		/*) ;;
		*) echo "$server" ;;
		esac
	done
}

# BusyBox UDP has no State column: the owner is always the last field.
dns_guard() {
	local listeners="" owners="" owner="" servers="" has_pid=1

	listeners="$(netstat -lnp 2>/dev/null)" || {
		has_pid=0
		listeners="$(netstat -ln 2>/dev/null)"
	}
	owners="$(printf '%s\n' "$listeners" | awk -v pid="$has_pid" '
		$1 ~ /^(tcp|udp)/ && $4 ~ /:53$/ {
			if (pid) { owner = $NF; sub(/^[0-9]+\//, "", owner); print owner }
			else print "unknown program"
		}' | sort -u)"
	while IFS= read -r owner; do
		[ -n "$owner" ] || continue
		# A no-PID netstat can only rule out dnsmasq when it is not running.
		[ "$has_pid" = 1 ] || ! pidof dnsmasq >/dev/null 2>&1 || continue
		[ "$owner" != dnsmasq ] || continue
		[ "$owner" != - ] || owner="unknown program"
		err_code dns_port_busy "port 53 is used by %s; disable it, XrayWRT routes the router DNS itself" "$owner"
		return 1
	done <<EOF
$owners
EOF
	servers="$(dns_global_custom_servers | tr '\n' ' ' | sed 's/ $//')"
	[ -z "$servers" ] || {
		err_code dns_forwarders "dnsmasq forwards DNS to %s; part of the queries would bypass the VPN. Remove them: Network → DHCP and DNS → Forwards" "$servers"
		return 1
	}
	return 0
}
