#!/bin/ash
# Destructive fixtures ONLY for tests/router/start.sh's disposable QEMU guest.
set -eu
WORK=/tmp/xraywrt-network-test
PIDS=""
NAMESPACES=""
LINKS=""
SAVED=0
DEFAULTS=0
CA_MOUNT=0
CURRENT=prerequisites

fatal() { echo "FAIL: $*" >&2; exit 1; }
absent() { if "$@"; then fatal "expected absence: $*"; fi; }
# Shell arithmetic is confined to normalized unsigned inputs.
. /usr/lib/xraywrt/constants.sh
. /usr/lib/xraywrt/helpers.sh
xraywrt_load_modules

record() {
	awk -F '\t' -v row="$1" '$1 != row' "$WORK/results.tsv" >"$WORK/results.new"
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$WORK/results.new"
	mv "$WORK/results.new" "$WORK/results.tsv"
}

snap() {
	local label="$1"
	uname -r >"$WORK/logs/$label.kernel"
	nft list ruleset >"$WORK/logs/$label.nft" 2>&1 || true
	ip -4 rule show >"$WORK/logs/$label.rules4"
	ip -6 rule show >"$WORK/logs/$label.rules6"
	ip -4 route show table all >"$WORK/logs/$label.routes4"
	ip -6 route show table all >"$WORK/logs/$label.routes6"
	ip -o addr show >"$WORK/logs/$label.addresses"
}

ready() {
	local i=""
	for i in $(seq 1 90); do
		/usr/bin/xraywrt status-json | jq -e '.running and .policy_active and .dns_ok' >/dev/null && return 0
		sleep 1
	done
	return 1
}

# Restoring all.disable_ipv6 alone does not restore the addresses Linux removed.
restore_ipv6() {
	local path="" value=""
	[ -f "$WORK/ipv6-disabled" ] || return 0
	sysctl -w net.ipv6.conf.all.disable_ipv6=0
	[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ] || return 1
	while read -r path value; do printf '%s\n' "$value" >"$path" || return 1; done <"$WORK/saved/ipv6.flags"
	ip -6 address restore <"$WORK/saved/ipv6.addresses" || return 1
	ip -6 route restore <"$WORK/saved/ipv6.routes" || return 1
	rm "$WORK/ipv6-disabled"
}

cleanup_precedence() {
	local family="" rc=0
	[ -f "$WORK/precedence" ] || return 0
	nft delete table inet m22_precedence 2>/dev/null || true
	if nft list table inet m22_precedence >/dev/null 2>&1; then rc=1; fi
	for family in 4 6; do
		# Setup can fail partway; verify absence rather than requiring every delete.
		ip -"$family" rule del priority 105 lookup main suppress_prefixlength 0 2>/dev/null || true
		ip -"$family" rule del priority 110 not fwmark 0x1bd00 lookup 20223 2>/dev/null || true
		ip -"$family" rule del priority 2001 fwmark 0x3f00/0x3f00 lookup 20224 2>/dev/null || true
		ip -"$family" route del blackhole default table 20223 2>/dev/null || true
		ip -"$family" route del blackhole default table 20224 2>/dev/null || true
		if ip -"$family" rule show | grep -Eq '^(105|110|2001):'; then rc=1; fi
		if ip -"$family" route show table all | grep -Eq ' table (20223|20224)( |$)'; then rc=1; fi
	done
	[ "$rc" = 0 ] || return 1
	rm "$WORK/precedence"
}

cleanup() {
	local rc=$? pid="" ns="" link="" conf="" restore=0
	# Restoration must finish even if the controlling SSH session goes away.
	trap '' INT TERM HUP PIPE
	trap - EXIT
	set +e
	if [ "$rc" -ne 0 ] && [ "$CURRENT" != prerequisites ] && ! grep -F "$CURRENT	FAIL" "$WORK/results.tsv" >/dev/null; then
		record "$CURRENT" FAIL "exit=$rc; logs/$CURRENT.log (stopped at first failure)"
	fi
	snap final
	for pid in $PIDS; do kill "$pid" 2>/dev/null; done
	for pid in $PIDS; do wait "$pid" 2>/dev/null; done
	if [ "$SAVED" = 1 ]; then
		/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&- >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		restore_ipv6 >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		cleanup_precedence >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		# Restore the user's config through the same API used to install the fixture.
		if [ -f "$WORK/saved/config.json" ]; then
			cp "$WORK/saved/config.json" "$WORK/restore.upload"
			mv "$WORK/restore.upload" /tmp/xraywrt-config.network-restore
			/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-restore >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		else
			rm -f /opt/xraywrt/config.json
		fi
		if [ -f "$WORK/saved/config.json.bak" ]; then
			cp -p "$WORK/saved/config.json.bak" /opt/xraywrt/config.json.bak || restore=1
		else
			rm -f /opt/xraywrt/config.json.bak
		fi
		rm -rf /opt/xraywrt/lst /opt/xraywrt/share /etc/xraywrt/policy-cache
		[ ! -d "$WORK/saved/lst" ] || cp -a "$WORK/saved/lst" /opt/xraywrt/lst
		[ ! -d "$WORK/saved/share" ] || cp -a "$WORK/saved/share" /opt/xraywrt/share
		[ ! -d "$WORK/saved/policy-cache" ] || cp -a "$WORK/saved/policy-cache" /etc/xraywrt/policy-cache
		for conf in xraywrt dhcp firewall network; do
			uci -q revert "$conf"
			cp -p "$WORK/saved/$conf" "/etc/config/$conf" || restore=1
		done
	fi
	if [ "$CA_MOUNT" = 1 ]; then
		umount /etc/ssl/certs/ca-certificates.crt || restore=1
	fi
	if [ "$DEFAULTS" = 1 ]; then
		ip -4 route del default via 198.20.22.2 dev m22w metric 42422 || restore=1
		ip -6 route del default via 2001:db8:ffff::2 dev m22w metric 42422 || restore=1
	fi
	if [ -f "$WORK/occupied" ]; then
		ip -4 rule del priority 50 fwmark 0x220000/0xff0000 lookup 201 || restore=1
		ip -4 route del blackhole 198.19.222.0/24 table 200 || restore=1
	fi
	nft delete table inet m22_netbird 2>/dev/null
	nft delete table inet m22_zapret 2>/dev/null
	nft delete table inet m22_dnskill 2>/dev/null
	nft delete table inet m22_bootstrap 2>/dev/null
	ip -6 addr del 2001:db8:dead::1/128 dev m22w 2>/dev/null
	ip -6 route del unreachable 2001:db8:2200::/56 2>/dev/null
	ip -6 route del 2001:db8:2220::/64 dev m22p table 20222 2>/dev/null
	for ns in $NAMESPACES; do ip netns del "$ns" || restore=1; done
	for link in $LINKS; do
		if ip link show "$link" >/dev/null 2>&1; then ip link del "$link" || restore=1; fi
	done
	if [ "$SAVED" = 1 ]; then
		/etc/init.d/network reload >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/firewall reload >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/dnsmasq restart >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/odhcpd restart >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		[ "$(cat "$WORK/saved/odhcpd.running")" = 1 ] || /etc/init.d/odhcpd stop
		[ "$(cat "$WORK/saved/dnsmasq.running")" = 1 ] || /etc/init.d/dnsmasq stop
		if [ "$(cat "$WORK/saved/xraywrt.running")" = 1 ]; then
			/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&- >>"$WORK/logs/cleanup.log" 2>&1 && ready || restore=1
		fi
		for conf in xraywrt dhcp firewall network; do
			cmp -s "$WORK/saved/$conf" "/etc/config/$conf" || restore=1
		done
		if [ -f "$WORK/saved/config.json" ]; then cmp -s "$WORK/saved/config.json" /opt/xraywrt/config.json || restore=1; fi
		if [ -f "$WORK/saved/config.json.bak" ]; then cmp -s "$WORK/saved/config.json.bak" /opt/xraywrt/config.json.bak || restore=1; fi
	fi
	rm -f /tmp/xraywrt-config.network-restore /tmp/xraywrt-config.network-fixture
	for conf in rules src direct-src; do rm -f "/tmp/xraywrt-policy-list.network-$conf"; done
	if [ "$restore" = 0 ]; then echo PASS >"$WORK/cleanup.status"; else echo FAIL >"$WORK/cleanup.status"; rc=1; fi
	# Snapshots can contain credentials; retain only the evidence directory.
	[ "$restore" != 0 ] || rm -rf "$WORK/saved"
	rm -f "$WORK/guest.pid"
	exit "$rc"
}

# Standalone guest entry also acquires the owned directory; never reuse stale state.
[ "$(cat /sys/class/net/eth0/address)" = 52:54:00:12:34:01 ] || fatal 'not the designated disposable VM'
ubus call system board | grep -q QEMU || fatal 'not QEMU'
if [ ! -e "$WORK" ]; then
	mkdir -m 700 "$WORK"
	echo xraywrt-task-22 >"$WORK/.owner"
fi
[ ! -L "$WORK" ] && [ "$(cat "$WORK/.owner")" = xraywrt-task-22 ] || fatal 'refuse existing unowned work path'
mkdir "$WORK/logs" "$WORK/saved" || fatal 'refuse existing guest fixture state'
: >"$WORK/results.tsv"
for name in 'nft syntax' 'control reachable' 'client IPv6 rejected' 'local and IPv4 retained' \
	'core and other ingress retained' 'NetBird synthetic' 'routes and DNS boundaries' 'local names' 'fake-IP direct devices' lifecycle \
	'port forward and WAN service replies' 'IPv6 disabled' 'policy rule precedence' 'loopback TPROXY' \
	'geodata download' 'geosite fake-IP' 'stale fake-IP' 'DNS query types' 'server bootstrap' \
	'balancer overrides' 'hot subscription TCP' 'routing strategy restart' 'zapret marks' 'guest zone' 'sticky stop' 'DNS path fail-open'; do
	record "$name" 'NOT TESTED' 'not reached'
done
trap cleanup EXIT
trap 'exit 1' INT TERM HUP PIPE
echo $$ >"$WORK/guest.pid"

# Do not install prerequisites implicitly, and never turn missing tools into PASS.
for tool in ip nft tcpdump curl dnsmasq uhttpd odhcp6c odhcpd jq hexdump nc socat netstat; do
	command -v "$tool" >/dev/null || fatal "prerequisite unavailable: $tool"
done
[ -x /opt/xraywrt/bin/xray ] || fatal 'prerequisite unavailable: Xray core'
ip netns list >"$WORK/logs/namespaces.before"
for name in m22-c m22-p m22-w m22-u m22-d m22-n; do
	ip netns list | grep -q "^$name\b" && fatal "refuse existing namespace $name"
done
for name in m22c m22p m22w m22u m22d wt0 m22nb; do
	ip link show "$name" >/dev/null 2>&1 && fatal "refuse existing link $name"
done
for name in m22_netbird m22_zapret m22_dnskill m22_bootstrap; do
	nft list table inet "$name" >/dev/null 2>&1 && fatal "refuse existing nft table $name"
done
grep -q ' /etc/ssl/certs/ca-certificates.crt ' /proc/mounts && fatal 'refuse existing CA bundle mount'
[ ! -e /tmp/xraywrt-config.network-fixture ] && [ ! -L /tmp/xraywrt-config.network-fixture ] || fatal 'refuse existing upload'
[ ! -e /tmp/xraywrt-config.network-restore ] && [ ! -L /tmp/xraywrt-config.network-restore ] || fatal 'refuse existing restore upload'
for name in rules src direct-src; do
	[ ! -e "/tmp/xraywrt-policy-list.network-$name" ] && [ ! -L "/tmp/xraywrt-policy-list.network-$name" ] || fatal "refuse existing list upload $name"
done
for conf in xraywrt dhcp firewall network; do
	[ -z "$(uci changes "$conf")" ] || fatal "refuse uncommitted UCI $conf"
	cp -p "/etc/config/$conf" "$WORK/saved/$conf"
	uci -q show "$conf" | grep -q '^.*\.m22' && fatal "refuse existing UCI fixture names in $conf"
done
[ ! -f /opt/xraywrt/config.json ] || cp -p /opt/xraywrt/config.json "$WORK/saved/config.json"
[ ! -f /opt/xraywrt/config.json.bak ] || cp -p /opt/xraywrt/config.json.bak "$WORK/saved/config.json.bak"
for name in xraywrt dnsmasq odhcpd; do
	if /etc/init.d/"$name" running; then echo 1; else echo 0; fi >"$WORK/saved/$name.running"
done
[ ! -d /opt/xraywrt/lst ] || cp -a /opt/xraywrt/lst "$WORK/saved/lst"
[ ! -d /opt/xraywrt/share ] || cp -a /opt/xraywrt/share "$WORK/saved/share"
[ ! -d /etc/xraywrt/policy-cache ] || cp -a /etc/xraywrt/policy-cache "$WORK/saved/policy-cache"
SAVED=1
snap before
/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-


# Every veth and address is in the VM. Namespace clients never see eth0/eth1.
make_link() {
	local suffix="$1" root="$2" v4="$3" v6="$4"
	ip netns add "m22-$suffix"
	NAMESPACES="$NAMESPACES m22-$suffix"
	ip link add "$root" type veth peer name eth0 netns "m22-$suffix"
	LINKS="$LINKS $root"
	ip link set "$root" up
	ip addr add "$v4.1/24" dev "$root"
	ip -6 addr add "$v6::1/64" dev "$root" nodad
	ip netns exec "m22-$suffix" ip link set lo up
	ip netns exec "m22-$suffix" ip link set eth0 up
	ip netns exec "m22-$suffix" ip addr add "$v4.2/24" dev eth0
	ip netns exec "m22-$suffix" ip -6 addr add "$v6::2/64" dev eth0 nodad
	ip netns exec "m22-$suffix" ip route add default via "$v4.1"
	ip netns exec "m22-$suffix" ip -6 route add default via "$v6::1"
}
make_link c m22c 192.0.2 fd22:10
make_link p m22p 192.0.3 fd22:20
# Synthetic WAN: outside the fake-IP pool 198.18.0.0/15 (spec 7.2) and the static
# localv4 set (test-nets are local), so lists can select it. Exists only inside the VM.
make_link w m22w 198.20.22 2001:db8:ffff
make_link u m22u 192.0.4 2001:db8:30
make_link d m22d 192.0.5 2001:db8:40
make_link n wt0 192.0.6 2001:db8:50
ip netns exec m22-c ip link set eth0 address 02:00:00:22:00:02
ip -6 addr add 2001:db8:10::1/64 dev m22c nodad
ip netns exec m22-c ip -6 addr add 2001:db8:10::2/64 dev eth0 nodad
ip netns exec m22-c ip -6 route change default via fd22:10::1 src 2001:db8:10::2
# RA may add another default; pin only the synthetic WAN prefix's source.
ip netns exec m22-c ip -6 route add 2001:db8:ffff::/64 via fd22:10::1 dev eth0 src 2001:db8:10::2
ip -6 addr add 2001:db8:20::1/64 dev m22p nodad
ip netns exec m22-p ip -6 addr add 2001:db8:20::2/64 dev eth0 nodad
ip -6 addr add 2001:db8:dead::1/128 dev m22w nodad
ip -4 route add default via 198.20.22.2 dev m22w metric 42422
ip -6 route add default via 2001:db8:ffff::2 dev m22w metric 42422
DEFAULTS=1

# Test-only zones permit controls but explicitly deny client -> denied zone.
for name in c p w u d n; do
	case "$name" in n) iface=wt0 ;; *) iface="m22$name" ;; esac
	uci set "firewall.m22$name=zone"
	uci set "firewall.m22$name.name=m22$name"
	uci add_list "firewall.m22$name.device=$iface"
	uci set "firewall.m22$name.input=ACCEPT"
	uci set "firewall.m22$name.output=ACCEPT"
	uci set "firewall.m22$name.forward=REJECT"
done
for name in cw cp uw nw wc; do
	src="$(printf '%s' "$name" | cut -c1)"
	dst="$(printf '%s' "$name" | cut -c2)"
	uci set "firewall.m22$name=forwarding"
	uci set "firewall.m22$name.src=m22$src"
	uci set "firewall.m22$name.dest=m22$dst"
done
uci commit firewall
/etc/init.d/firewall reload
# Netifd/odhcpd fixture: no existing interface or DHCP section is changed here.
uci set network.m22c=interface
uci set network.m22c.proto=static
uci set network.m22c.device=m22c
uci set network.m22c.ipaddr=192.0.2.1
uci set network.m22c.netmask=255.255.255.0
uci add_list network.m22c.ip6addr=fd22:10::1/64
uci add_list network.m22c.ip6addr=2001:db8:10::1/64
uci set dhcp.m22c=dhcp
uci set dhcp.m22c.interface=m22c
uci set dhcp.m22c.ra=server
uci set dhcp.m22c.dhcpv6=server
uci add_list dhcp.m22c.ra_flags=managed-config
uci add_list dhcp.m22c.ra_flags=other-config
uci set 'dhcp.@dnsmasq[0].local=/corp22/'
uci set 'dhcp.@dnsmasq[0].domain=corp22'
uci set "dhcp.@dnsmasq[0].leasefile=$WORK/leases"
uci add_list 'dhcp.@dnsmasq[0].server=/conditional22.test/198.20.22.2'
uci add_list 'dhcp.@dnsmasq[0].server=/openwrt.org/10.0.2.3'
uci set dhcp.m22host=domain
uci set dhcp.m22host.name=m22host.lan
uci set dhcp.m22host.ip=192.0.2.10
uci set dhcp.m22static=domain
uci set dhcp.m22static.name=static22.corp22
uci set dhcp.m22static.ip=192.0.2.9
uci set dhcp.m22static6=domain
uci set dhcp.m22static6.name=static22.corp22
uci set dhcp.m22static6.ip=fd22:10::9
printf '0 02:00:00:22:00:02 192.0.2.2 lease22 *\n' >"$WORK/leases"
uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
uci show dhcp >"$WORK/logs/dhcp.fixture.before"

# Listener fixtures use only tracked foreground processes (no daemonized children).
mkdir "$WORK/www" "$WORK/node"
mkdir "$WORK/www/cgi-bin"
# peer= is the address the WAN server saw: the client, the router (core direct) or the node.
cat >"$WORK/www/cgi-bin/hold" <<'EOF'
#!/bin/ash
printf 'Content-Type: text/plain\r\n\r\nxraywrt-network-fixture\npeer=%s\n' "$REMOTE_ADDR"
sleep 8
EOF
cat >"$WORK/www/cgi-bin/peer" <<'EOF'
#!/bin/ash
printf 'Content-Type: text/plain\r\n\r\nxraywrt-network-fixture\npeer=%s\n' "$REMOTE_ADDR"
EOF
chmod +x "$WORK/www/cgi-bin/hold" "$WORK/www/cgi-bin/peer"
printf 'xraywrt-network-fixture\n' >"$WORK/www/index.html"
for name in p w u d; do
	ip netns exec "m22-$name" uhttpd -f -p 0.0.0.0:8080 -p '[::]:8080' -p 0.0.0.0:8081 -p '[::]:8081' -h "$WORK/www" >"$WORK/logs/http-$name.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
	PIDS="$PIDS $!"
done
uhttpd -f -p 0.0.0.0:8088 -p '[::]:8088' -h "$WORK/www" >"$WORK/logs/http-router.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
# Without upstreams this dnsmasq REFUSES any type it has no record for; musl
# then fails the whole lookup, so hosts-file names carry A and AAAA. Root keeps
# the hosts file in the private work directory readable.
printf '%s\n' '198.20.22.2 geo22.example.net node22.example.net' '2001:db8:ffff::2 geo22.example.net node22.example.net' >"$WORK/node/wan.hosts"
ip netns exec m22-w dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts \
	--bind-interfaces --interface=eth0 --log-queries --log-facility=- \
	--address=/raw22.test/198.20.22.2 --address=/raw22.test/2001:db8:ffff::2 \
	--address=/conditional22.test/198.20.22.2 --address=/primary22.example.net/198.20.22.22 \
	--address=/fake22.example.net/198.20.22.2 --address=/public22.example.org/198.20.22.2 \
	--txt-record=txt22.example.net,m22-txt --dns-rr=public22.example.org,65,000100 \
	--user=root --addn-hosts="$WORK/node/wan.hosts" >"$WORK/logs/dns-wan.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
# geosite.dat built here (GeoSiteList protobuf): list M22 = full:fake22.example.net.
geosite_dat() {
	local code="M22" domain="fake22.example.net" l1="" l2=""
	l2=$((4 + ${#domain})); l1=$((2 + ${#code} + 2 + l2))
	# shellcheck disable=SC2059 # octal escapes for the single-byte protobuf lengths
	{
		printf '\012'; printf "\\$(printf '%03o' "$l1")"
		printf '\012'; printf "\\$(printf '%03o' "${#code}")"; printf '%s' "$code"
		printf '\022'; printf "\\$(printf '%03o' "$l2")"
		printf '\010\003\022'; printf "\\$(printf '%03o' "${#domain}")"; printf '%s' "$domain"
	}
}
geosite_dat >"$WORK/www/geosite.dat"
# HTTPS for geodata assets: the node's TLS tunnel in front of the WAN web server
# (HTTP/1.1 only, as uhttpd has no HTTP/2). The CLI drops CURL_CA_BUNDLE, so the
# test certificate joins the system bundle through a bind mount the cleanup removes.
# NETWORK_NODE_XRAY (host) puts the node's own Xray here; default: the router core.
NODE_XRAY="$WORK/node-xray"; [ -x "$NODE_XRAY" ] || NODE_XRAY=/opt/xraywrt/bin/xray
"$NODE_XRAY" tls cert --ca --domain=geo22.example.net --file="$WORK/node/geo" >/dev/null
cat /etc/ssl/certs/ca-certificates.crt "$WORK/node/geo.crt" >"$WORK/node/ca-bundle.crt"
mount -o bind "$WORK/node/ca-bundle.crt" /etc/ssl/certs/ca-certificates.crt
CA_MOUNT=1
# Synthetic proxy node: a second Xray with a dual-stack SOCKS5 inbound; the
# empty access path sends access lines to node.log with the debug log.
cat >"$WORK/node/node.json" <<EOF
{
  "log": {"loglevel": "debug", "access": ""},
  "dns": {"servers": ["198.20.22.2"]},
  "inbounds": [{"tag": "node22", "listen": "::", "port": 1080, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}},
    {"tag": "geo22", "listen": "::", "port": 8443, "protocol": "tunnel", "settings": {"rewriteAddress": "127.0.0.1", "rewritePort": 8080, "allowedNetwork": "tcp"},
      "streamSettings": {"security": "tls", "tlsSettings": {"alpn": ["http/1.1"], "certificates": [{"certificateFile": "$WORK/node/geo.crt", "keyFile": "$WORK/node/geo.key"}]}}}],
  "outbounds": [{"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"domainStrategy": "UseIP"}}}]
}
EOF
ip netns exec m22-w "$NODE_XRAY" run -c "$WORK/node/node.json" >"$WORK/logs/node.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
tcpdump -ni m22w -U -w "$WORK/logs/wan.pcap" >"$WORK/logs/wan-capture.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
sleep 3
for pid in $PIDS; do kill -0 "$pid" || fatal "fixture process exited: $pid"; done

# Install the user config exclusively through the editor API. No provider-file edits.
# fake-ip = a fakedns server with whitelist domains (spec 7.2); redir-host = none;
# geosite = the whitelist is geosite:m22 from a geodata asset (spec 10).
profile() {
	local mode="$1" dns="$2" flag="$3" hijack="$4" fake="" geodata=""
	case "$dns" in
	fake-ip) fake='{"address": "fakedns", "domains": ["domain:example.org", "full:fake22.example.net"], "skipFallback": true},' ;;
	geosite)
		fake='{"address": "fakedns", "domains": ["geosite:m22"], "skipFallback": true},'
		geodata='"geodata": {"assets": [{"file": "geosite.dat", "url": "https://geo22.example.net:8443/geosite.dat"}]},' ;;
	esac
	uci set "xraywrt.settings.dns_hijack=$hijack"
	uci set xraywrt.settings.disable_quic=0
	# The router owns the core log level (spec 6.2); rows read per-connection core logs.
	uci set xraywrt.settings.core_log_level=debug
	uci set xraywrt.settings.block_client_ipv6=0
	uci -q delete xraywrt.settings.dns_raw_upstream || true
	uci -q delete xraywrt.settings.dns_forward_other_types || true
	uci -q delete xraywrt.settings.provider_override || true
	uci -q delete xraywrt.settings.source_network_interfaces || true
	uci add_list xraywrt.settings.source_network_interfaces=m22c
	uci add_list xraywrt.settings.source_network_interfaces=wt0
	uci commit xraywrt
	cat > /tmp/xraywrt-config.network-fixture <<EOF
{
  "xraywrt": {"mode": "$mode", "block-client-ipv6": $flag},
  $geodata
  "dns": {
    "servers": [
      ${NODE_DNS:-}$fake
      {"address": "198.20.22.2", "domains": ["domain:primary22.example.net"], "skipFallback": true},
      {"address": "10.0.2.3", "domains": ["domain:openwrt.org"], "skipFallback": true},
      "198.20.22.2"
    ]
  },
  "outbounds": [
    {"tag": "proxy", "protocol": "socks", "settings": {"servers": [{"address": "${NODE_ADDRESS:-2001:db8:ffff::2}", "port": 1080}]}${NODE_SOCKOPT:-}},
    {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"domainStrategy": "ForceIP"}}}
  ],
  "routing": {
    "rules": [
      {"domain": ["full:fake22.example.net"], "outboundTag": "proxy"},
      {"port": "8081,9091", "outboundTag": "proxy"},
      {"network": "tcp,udp", "outboundTag": "direct"}
    ]
  }
}
EOF
	/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt reload
	/usr/bin/xraywrt profile-json | jq -e --arg mode "$mode" ' .mode == $mode'
}

# set_lists <selector>: My rules (a plain `<address> core` line sends the address into
# the core) and the device lists, installed with the three-argument apply-lists.
set_lists() {
	local selector="$1" kind=""
	for kind in rules src direct-src; do : >"/tmp/xraywrt-policy-list.network-$kind"; done
	case "$selector" in
	dst) printf '2001:db8:ffff::2 core\n' > /tmp/xraywrt-policy-list.network-rules ;;
	src) printf '2001:db8:10::2\nfd22:10::2\n' > /tmp/xraywrt-policy-list.network-src ;;
	mac) printf '02:00:00:22:00:02\n' > /tmp/xraywrt-policy-list.network-src ;;
	# Address selection of the synthetic node's IPv4 side (port-only entries no longer exist).
	core) printf '198.20.22.2 core\n' > /tmp/xraywrt-policy-list.network-rules ;;
	loopback) printf '198.20.22.2 core\n2001:db8:ffff::2 core\n' > /tmp/xraywrt-policy-list.network-rules ;;
	# Synthetic WAN client as proxied destination, forwarded LAN host as proxied source.
	wanclient)
		printf '198.20.22.2 core\n' > /tmp/xraywrt-policy-list.network-rules
		printf '192.0.2.2\n' > /tmp/xraywrt-policy-list.network-src ;;
	empty) ;;
	*) fatal "unknown list selector: $selector" ;;
	esac
	# The same devices as direct exceptions in blacklist/redir-host must not escape the ban.
	cp /tmp/xraywrt-policy-list.network-src /tmp/xraywrt-policy-list.network-direct-src
	/usr/bin/xraywrt apply-lists /tmp/xraywrt-policy-list.network-rules /tmp/xraywrt-policy-list.network-src /tmp/xraywrt-policy-list.network-direct-src
}

http() {
	local ns="$1" address="$2" port="${3:-8080}" path="${4:-/}"
	ip netns exec "m22-$ns" curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 "http://$address:$port$path"
}

# peer_is <cgi reply> <address>...: the WAN server saw exactly one of these peers.
peer_is() {
	local file="$1" peer="" address=""
	shift
	peer="$(sed -n 's/^peer=\(::ffff:\)\{0,1\}//p' "$file")"
	for address in "$@"; do [ "$peer" = "$address" ] && return 0; done
	return 1
}

# dns_asked <decoded capture> <port> <type> <name>: count of <type> queries for exactly <name> sent to <port>.
dns_asked() {
	grep -cE " > [^ ]+[.]$2: .* $3[?] $(printf '%s' "$4" | sed 's/[.]/[.]/g')[.] " "$1" || true
}

# foreign_syns <decoded capture> <address>: connection-opening SYNs whose source is not <address>.
foreign_syns() {
	awk -v src="$2." '/Flags \[S\],/ {s = ""; for (i = 1; i < NF; i++) if ($i == "IP" || $i == "IP6") {s = $(i + 1); break}; if (index(s, src) != 1) print}' "$1"
}

# Synthetic node access/debug lines since the current row started.
node_log_row() {
	tail -n +"$(($(cat "$WORK/node.row-start") + 1))" "$WORK/logs/node.log"
}

# BusyBox nc has no UDP/timeout switches. nslookup supplies UDP; a tracked
# watchdog bounds it, while nc carries a length-prefixed DNS packet for TCP.
bounded() {
	local pid="" rc=0 i=""
	# An asynchronous command gets /dev/null as stdin unless it is redirected explicitly.
	if [ -n "${BOUNDED_STDIN:-}" ]; then
		"$@" <"$BOUNDED_STDIN" 6>&- 7>&- 8>&- 9>&- &
	else
		"$@" 6>&- 7>&- 8>&- 9>&- &
	fi
	pid=$!
	for i in $(seq 1 5); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" || rc=$?
	return "$rc"
}

dns_udp() {
	local server="$1" name="$2" type="$3" expected="$4"
	bounded ip netns exec m22-c nslookup "-type=$type" "$name" "$server" >"$WORK/logs/dns-last.log" 2>&1
	cat "$WORK/logs/dns-last.log"
	# PTR replies have no Name: line; the answer is everything after the server header.
	# fake-ip = any address of the pool 198.18.0.0/15 (spec 7.2).
	case "$expected" in
	fake-ip) awk 'answer; /^$/ {answer=1}' "$WORK/logs/dns-last.log" | grep -E '^Address:? +198[.]1[89][.]' ;;
	*) awk 'answer; /^$/ {answer=1}' "$WORK/logs/dns-last.log" | grep -F "$expected" ;;
	esac
}

# dns_tcp_query <netns suffix|router> <server> <port> <name> <type>: one TCP
# query with ID 0x1234; the reply goes to logs/dns-tcp-last.hex.
dns_tcp_query() {
	local ns="$1" server="$2" port="$3" name="$4" type="$5" label="" size="" hi="" lo="" oldifs="$IFS"
	# Build DNS query bytes without od/base64/Python; command substitution would strip NUL, so only fixed printf formats emit them.
	{
		printf '\022\064\001\000\000\001\000\000\000\000\000\000'
		IFS=.
		for label in $name; do printf '%b%s' "$(printf '\\%03o' "${#label}")" "$label"; done
		IFS="$oldifs"
		printf '\000'
		case "$type" in
		A) printf '\000\001' ;; AAAA) printf '\000\034' ;; PTR) printf '\000\014' ;;
		TXT) printf '\000\020' ;; HTTPS) printf '\000\101' ;; *) return 1 ;;
		esac
		printf '\000\001'
	} >"$WORK/query.bin"
	size="$(uint_norm "$(wc -c <"$WORK/query.bin")")"
	hi=$((size / 256)); lo=$((size % 256))
	# shellcheck disable=SC2059 # octal escapes for the fixed 2-byte TCP DNS length prefix
	{ printf "\\$(printf '%03o' "$hi")\\$(printf '%03o' "$lo")"; cat "$WORK/query.bin"; } >"$WORK/query.tcp"
	# nc can wait for EOF after a valid reply; the watchdog status is not the DNS oracle.
	if [ "$ns" = router ]; then
		BOUNDED_STDIN="$WORK/query.tcp" bounded nc "$server" "$port" >"$WORK/reply.bin" || true
	else
		BOUNDED_STDIN="$WORK/query.tcp" bounded ip netns exec "m22-$ns" nc "$server" "$port" >"$WORK/reply.bin" || true
	fi
	hexdump -v -e '1/1 "%02x"' "$WORK/reply.bin" >"$WORK/logs/dns-tcp-last.hex"
	cat "$WORK/logs/dns-tcp-last.hex"
}

# Reply header of the last TCP query: response code and answer count (hex digits).
dns_tcp_rcode() { cut -c12 "$WORK/logs/dns-tcp-last.hex"; }
dns_tcp_answers() { cut -c17-20 "$WORK/logs/dns-tcp-last.hex"; }

dns_tcp() {
	local server="$1" name="$2" type="$3" expected="$4"
	dns_tcp_query c "$server" 53 "$name" "$type"
	# ID 0x1234, standard successful response, at least one answer and payload.
	grep -Eq '^....1234[89][0-9a-f]80' "$WORK/logs/dns-tcp-last.hex"
	grep -q "$expected" "$WORK/logs/dns-tcp-last.hex"
}

check_nft() {
	local mode="" dns="" flag="" hijack=""
	for pair in direct-first:fake-ip proxy-first:fake-ip proxy-first:redir-host; do
		mode="${pair%:*}"; dns="${pair#*:}"
		for flag in false true; do
			for hijack in 0 1; do
				profile "$mode" "$dns" "$flag" "$hijack"
				# nft.applied keeps only the ruleset hash: re-check the live table text.
				nft list table inet xraywrt >"$WORK/logs/syntax-$mode-$dns-$flag-$hijack.applied"
				[ -s "$WORK/logs/syntax-$mode-$dns-$flag-$hijack.applied" ]
				{ echo 'delete table inet xraywrt'; cat "$WORK/logs/syntax-$mode-$dns-$flag-$hijack.applied"; } >"$WORK/syntax.nft"
				nft -c -f "$WORK/syntax.nft"
				snap "syntax-$mode-$dns-$flag-$hijack"
			done
		done
	done
}

check_control() {
	profile direct-first fake-ip false 0
	http c 198.20.22.2 | grep xraywrt-network-fixture
	http c '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
	http c 192.0.3.2 | grep xraywrt-network-fixture
	http c '[fd22:20::2]' | grep xraywrt-network-fixture
	dns_udp 198.20.22.2 raw22.test A 198.20.22.2
	dns_udp 2001:db8:ffff::2 raw22.test AAAA 2001:db8:ffff::2
	profile direct-first fake-ip false 1
	# Unique fake-IP answer proves Xray DNS, not raw WAN DNS reachability.
	dns_udp 2001:db8:ffff::2 public22.example.org A fake-ip
	if awk '/^Name:/ {answer=1} answer' "$WORK/logs/dns-last.log" | grep -q '198.20.22.2'; then fatal 'raw DNS answer instead of Xray fake-IP'; fi
}

reject_fresh() {
	local label="$1" cap="$WORK/logs/reject-$1.pcap" pid="" wanpid="" start="" end="" rc=0
	# Independent capture for each fresh TCP and UDP/NTP flow.
	tcpdump -ni m22c -U -w "$cap" 'ip6 and (host 2001:db8:ffff::2 or icmp6)' >"$WORK/logs/reject-$label.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
	pid=$!
	tcpdump -ni m22w -U -w "$WORK/logs/reject-$label.wan.pcap" 'ip6 and dst host 2001:db8:ffff::2 and (tcp dst port 8080 or udp dst port 123)' >"$WORK/logs/reject-$label.wan-capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
	wanpid=$!
	trap 'kill "$pid" "$wanpid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; wait "$wanpid" 2>/dev/null || true' EXIT
	sleep 1
	nft list chain inet xraywrt client_ipv6_egress >"$WORK/logs/reject-$label.before"
	start="$(date +%s)"
	http c '[2001:db8:ffff::2]' >"$WORK/logs/reject-$label.http" 2>&1 || rc=$?
	end="$(date +%s)"
	printf 'TCP expected=refused (not timeout) actual_exit=%s elapsed_seconds=' "$rc"
	awk -v start="$start" -v end="$end" 'BEGIN {print end-start}'
	# Curl 7 = failed connect. Timeout 28 must never count as rejection.
	[ "$rc" = 7 ]
	printf 'unlisted-ntp-probe' >"$WORK/udp-probe"
	BOUNDED_STDIN="$WORK/udp-probe" bounded ip netns exec m22-c socat - 'UDP6-DATAGRAM:[2001:db8:ffff::2]:123' >"$WORK/logs/reject-$label.udp" 2>&1 || true
	sleep 1
	kill "$pid" "$wanpid"; wait "$pid" 2>/dev/null || true; wait "$wanpid" 2>/dev/null || true
	trap - EXIT
	tcpdump -nn -vv -r "$cap" >"$WORK/logs/reject-$label.decoded" 2>&1
	cat "$WORK/logs/reject-$label.decoded"
	grep -Eq 'Flags \[R\.?\]' "$WORK/logs/reject-$label.decoded"
	# Decode raw bytes too: ICMPv6 type=1/code=1, not a generic unreachable.
	tcpdump -nn -r "$cap" 'icmp6 and ip6[40] == 1 and ip6[41] == 1' >"$WORK/logs/reject-$label.admin" 2>&1
	grep -q 'unreachable' "$WORK/logs/reject-$label.admin"
	nft list chain inet xraywrt client_ipv6_egress >"$WORK/logs/reject-$label.after"
	awk '/counter packets/ {for(i=1;i<=NF;i++) if($i=="packets") print $(i+1)}' "$WORK/logs/reject-$label.before" >"$WORK/count.before"
	awk '/counter packets/ {for(i=1;i<=NF;i++) if($i=="packets") print $(i+1)}' "$WORK/logs/reject-$label.after" >"$WORK/count.after"
	awk 'NR==FNR {before[FNR]=$1; n=FNR; next} {if($1<=before[FNR]) bad=1; m=FNR} END {exit bad || n!=2 || m!=2}' "$WORK/count.before" "$WORK/count.after"
	# No WAN-bound connection or DNS query, even if a broken guard hid the client
	# behind the core's router-originated socket. Capture is scoped to this flow.
	tcpdump -nn -r "$WORK/logs/reject-$label.wan.pcap" >"$WORK/logs/reject-$label.wan-decoded" 2>&1
	absent grep -q 'IP6 ' "$WORK/logs/reject-$label.wan-decoded"
	core_log_row >"$WORK/logs/reject-$label.core.log"

}

# Syslog since the current row started: the ring keeps earlier runs' sessions.
core_log_row() {
	logread | awk 'index($0, "m22 row start: ") {n = NR} {l[NR] = $0} END {for (i = n + 1; i <= NR; i++) print l[i]}'
}

# Observe marked IPv6 immediately before delivery to the core. A positive
# counter plus the WAN server seeing the router (the core's direct socket), not
# the client, prove the selected path.
selected_ipv6() {
	local label="$1"
	nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip6 daddr 2001:db8:ffff::2 tcp dport 8080 counter comment selected-ipv6
	http c '[2001:db8:ffff::2]' 8080 /cgi-bin/peer | tee "$WORK/logs/selected-$label.http" | grep xraywrt-network-fixture
	nft list chain inet xraywrt proxy_redirect >"$WORK/logs/selected-$label.nft"
	grep 'comment "selected-ipv6"' "$WORK/logs/selected-$label.nft" | grep -Eq 'counter packets [1-9]'
	peer_is "$WORK/logs/selected-$label.http" 2001:db8:ffff::1
}

check_reject() {
	local pair="" hijack="" selector="" flag=""
	for hijack in 0 1; do
		profile direct-first fake-ip true "$hijack"
		set_lists empty
		(reject_fresh "direct-first-$hijack-unlisted")
		if [ "$hijack" = 1 ]; then
			dns_udp 2001:db8:ffff::2 public22.example.org A fake-ip
		fi
		for selector in dst src mac; do
			set_lists "$selector"
			selected_ipv6 "$hijack-$selector"
		done
	done
	# Proxy-first's explicit exceptions are not banned by this flag. Compare
	# applied transactions as well as fresh successful external IPv6 requests.
	for pair in proxy-first:fake-ip proxy-first:redir-host; do
		for hijack in 0 1; do
			for flag in false true; do
				profile proxy-first "${pair#*:}" "$flag" "$hijack"
				set_lists dst
				absent nft list chain inet xraywrt client_ipv6_egress
				cp /tmp/xraywrt/nft.applied "$WORK/$flag.nft"
				http c '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
				if [ "$hijack" = 1 ]; then
					if [ "${pair#*:}" = fake-ip ]; then
						dns_udp 2001:db8:ffff::2 fake22.example.net A fake-ip
					else
						dns_udp 2001:db8:ffff::2 public22.example.org A 198.20.22.2
					fi
				fi
			done
			cmp -s "$WORK/false.nft" "$WORK/true.nft"
		done
	done
}

check_local() {
	local flag="" linklocal="" pid=""
	for flag in false true; do
		profile direct-first fake-ip "$flag" 1
		http c 198.20.22.2 | grep xraywrt-network-fixture
		http c '[fd22:20::2]' | grep xraywrt-network-fixture
		http c '[2001:db8:20::2]' | grep xraywrt-network-fixture
		linklocal="$(ip -6 -o addr show dev m22p scope link | awk '{split($4,a,"/");print a[1];exit}')"
		ip netns exec m22-p ping -6 -c 1 -W 2 "$linklocal%eth0"
		ip netns exec m22-c ping -6 -c 1 -W 2 fd22:10::1
		# The fw4 denied zone stays denied even though its prefix is localv6.
		if http c '[2001:db8:40::2]'; then fatal "fw4 denied inter-zone path opened ($flag)"; fi
		dns_udp fd22:10::1 static22.corp22 A 192.0.2.9
		dns_udp fd22:10::1 static22.corp22 AAAA fd22:10::9
		dns_udp fd22:10::1 9.2.0.192.in-addr.arpa PTR static22
		dns_udp fd22:10::1 lease22.corp22 A 192.0.2.2
		dns_tcp fd22:10::1 static22.corp22 A c0000209
		dns_tcp fd22:10::1 static22.corp22 AAAA fd220010000000000000000000000009
		dns_tcp fd22:10::1 9.2.0.192.in-addr.arpa PTR 7374617469633232
		# odhcp6c actively solicits RA/DHCPv6 on the selected client link.
		tcpdump -ni m22c -U -w "$WORK/logs/local-$flag.pcap" 'icmp6 or udp port 546 or udp port 547' >"$WORK/logs/local-$flag.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
		pid=$!
		trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
		# tcpdump needs a moment to open the capture; a ping sent earlier is invisible to it.
		sleep 2
		# Earlier pings cached both neighbours; clear both caches so ND is a fresh on-wire exchange.
		ip netns exec m22-c ip -6 neigh flush dev eth0
		ip -6 neigh flush dev m22c
		ip netns exec m22-c ip -6 neigh show dev eth0 >"$WORK/logs/neigh-$flag.flushed"
		ip netns exec m22-c ping -6 -c 1 -W 2 fd22:10::1
		bounded ip netns exec m22-c odhcp6c -s /bin/true -N try eth0 >"$WORK/logs/dhcpv6-$flag.log" 2>&1 || true
		sleep 1
		kill "$pid"; wait "$pid" 2>/dev/null || true
		trap - EXIT
		tcpdump -nn -vv -r "$WORK/logs/local-$flag.pcap" >"$WORK/logs/local-$flag.decoded" 2>&1
		grep -q 'router advertisement' "$WORK/logs/local-$flag.decoded"
		grep -Eq 'dhcp6 (advertise|reply)' "$WORK/logs/local-$flag.decoded"
		grep -q 'neighbor solicitation' "$WORK/logs/local-$flag.decoded"
		grep -q 'neighbor advertisement' "$WORK/logs/local-$flag.decoded"
	done
}

check_core() {
	local pid=""
	profile direct-first fake-ip true 0
	# The node's IPv4 address is selected into the core while IPv6 to the node is core output.
	set_lists core
	pid="$(cat /var/run/xraywrt/xray.pid)"
	http c 198.20.22.2 8081 | grep xraywrt-network-fixture
	# Earlier DNS controls may give the core a reverse mapping for this IP.
	grep -Eq 'accepted tcp:198[.]20[.]22[.]2:8081 \[node22 (->|>>) direct\]' "$WORK/logs/node.log"
	# Packet evidence proves an actual IPv6 connection to the SOCKS5 node.
	sleep 1
	tcpdump -nn -r "$WORK/logs/wan.pcap" 'ip6 and dst host 2001:db8:ffff::2 and dst port 1080' >"$WORK/logs/core-node-ipv6.log" 2>&1
	grep -q 'Flags \[S\]' "$WORK/logs/core-node-ipv6.log"
	curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep xraywrt-network-fixture
	http u '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
}

netbird_rules() {
	local base="$1" port="$2" source="$3" mark="$4"
	nft delete table inet m22_netbird 2>/dev/null || true
	# Pre-policy producer and post-policy observer: conntrack marks must not be
	# confused with packet marks. Reply traffic is generated by the root HTTP server.
	nft -f - <<EOF
add table inet m22_netbird
add chain inet m22_netbird producer { type route hook output priority -151; policy accept; }
add chain inet m22_netbird observer { type route hook output priority -149; policy accept; }
add rule inet m22_netbird producer tcp dport $port meta mark 0 $source mark set $mark
add rule inet m22_netbird producer tcp sport 8088 meta mark set $base
add rule inet m22_netbird observer tcp dport $port meta mark & 0x08000000 == 0x08000000 counter comment "intercepted"
add rule inet m22_netbird observer tcp dport $port meta mark & 0x08000000 == 0 counter comment "direct"
add rule inet m22_netbird observer tcp sport 8088 ct direction reply meta mark $base counter comment "reply-direct"
EOF
}

check_netbird() {
	local pair="" iface="" base="" proxy="" path="" mark="" expected="" phase="" ns="m22-n"
	for pair in wt0:0x1bd00 m22nb:0x2bd00; do
		iface="${pair%:*}"; base="${pair#*:}"
		if [ "$iface" = m22nb ]; then
			ip link set wt0 name m22nb
			uci -q delete firewall.m22n.device
			uci add_list firewall.m22n.device=m22nb
			uci commit firewall
			/etc/init.d/firewall reload
		fi
		uci set "xraywrt.settings.netbird_interface=$iface"
		uci set "xraywrt.settings.netbird_mark=$base"
		for proxy in 0 1; do
			profile proxy-first redir-host true 0
			uci add_list "xraywrt.settings.source_network_interfaces=$iface"
			uci set "xraywrt.settings.netbird_proxy=$proxy"
			uci commit xraywrt
			for phase in producer-first service-first reconnect fw4-reload; do
				case "$phase" in
				producer-first)
					/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
					netbird_rules "$base" 8080 meta "$base"
					/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready ;;
				service-first) nft delete table inet m22_netbird; /usr/bin/xraywrt reload ;;
				reconnect)
					ip link set "$iface" down; ip link set "$iface" up
					# Linux drops IPv6 addresses on admin-down; record that, then reconfigure like a reconnecting tunnel.
					ip -6 addr show dev "$iface" >"$WORK/logs/nb-$iface-$proxy-reconnect.addr6-after-up"
					ip -6 addr replace 2001:db8:50::1/64 dev "$iface" nodad
					/usr/bin/xraywrt net-refresh ;;
				fw4-reload) /etc/init.d/firewall reload; /usr/bin/xraywrt net-refresh ;;
				esac
				# Selected NetBird ingress remains direct despite the client ban.
				ip netns exec "$ns" curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep xraywrt-network-fixture
				for path in meta ct; do
					for offset in 0 16 17 32 33 34; do
						base_dec="$(uint_norm "$(printf '%d' "$base")")"
						offset="$(uint_norm "$offset")"
						mark="$(printf '0x%x' "$((base_dec | offset))")"
						netbird_rules "$base" 8080 "$path" "$mark"
						curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep xraywrt-network-fixture
						expected=direct
						if [ "$path" = ct ] || { [ "$proxy" = 1 ] && [ "$offset" = 0 ]; }; then expected=intercepted; fi
						nft list table inet m22_netbird >"$WORK/logs/nb-$iface-$proxy-$phase-$path-$offset.nft"
						grep "comment \"$expected\"" "$WORK/logs/nb-$iface-$proxy-$phase-$path-$offset.nft" | grep -Eq 'counter packets [1-9][0-9]*'
					done
				done
				netbird_rules "$base" 8080 meta "$base"
				http w 198.20.22.1 8088 | grep xraywrt-network-fixture
				nft list table inet m22_netbird | grep 'comment "reply-direct"' | grep -Eq 'counter packets [1-9][0-9]*'
			done
		done
		if [ "$iface" = m22nb ]; then
			ip link set m22nb name wt0
			uci -q delete firewall.m22n.device
			uci add_list firewall.m22n.device=wt0
			uci commit firewall
			/etc/init.d/firewall reload
		fi
	done
	nft delete table inet m22_netbird
	uci set xraywrt.settings.netbird_interface=wt0
	uci set xraywrt.settings.netbird_mark=0x1bd00
	uci set xraywrt.settings.netbird_proxy=0
	uci commit xraywrt
}

has_local6() { nft get element inet xraywrt localv6 "{ $1 }"; }

check_routes_dns() {
	local table="" priority=""
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	# Refuse occupied fixture slots instead of replacing anything already present.
	if ip -4 route show table all | grep -Eq ' table (200|201)( |$)'; then fatal 'refuse occupied route fixture slot'; fi
	if ip -4 rule show | grep -Eq '(^50:| lookup (200|201)( |$))'; then fatal 'refuse occupied rule fixture slot'; fi
	if ip -6 rule show | grep -Eq '(^50:| lookup (200|201)( |$))'; then fatal 'refuse occupied IPv6 rule fixture slot'; fi
	ip -4 route add blackhole 198.19.222.0/24 table 200
	ip -4 rule add priority 50 fwmark 0x220000/0xff0000 lookup 201
	: >"$WORK/occupied"
	profile direct-first fake-ip true 1
	/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready
	table="$(sed -n 's/^TABLE=//p' /var/run/xraywrt/route.state)"
	priority="$(sed -n 's/^PRIORITY=//p' /var/run/xraywrt/route.state)"
	[ "$table" != 200 ] && [ "$table" != 201 ] && [ "$priority" != 50 ]
	ip -4 route show table 200 | grep 'blackhole 198.19.222.0/24'
	ip -4 rule show | grep '^50:.*0x220000/0xff0000.*lookup 201'
	has_local6 2001:db8:10::2
	has_local6 2001:db8:20::2
	has_local6 2001:db8:30::2
	absent has_local6 2001:db8:ffff::2
	ip -6 route add unreachable 2001:db8:2200::/56
	ip -6 route add 2001:db8:2210::/64 via fd22:20::2 dev m22p
	ip -6 route add 2001:db8:2220::/64 dev m22p table 20222
	/usr/bin/xraywrt net-refresh
	has_local6 2001:db8:2200::1
	absent has_local6 2001:db8:2210::1
	absent has_local6 2001:db8:2220::1
	ip -6 route del unreachable 2001:db8:2200::/56
	ip -6 route del 2001:db8:2210::/64 via fd22:20::2 dev m22p
	ip -6 route del 2001:db8:2220::/64 dev m22p table 20222
	ip -6 addr del 2001:db8:30::1/64 dev m22u
	/usr/bin/xraywrt net-refresh
	absent has_local6 2001:db8:2200::1
	absent has_local6 2001:db8:30::2
	ip -6 addr add 2001:db8:30::1/64 dev m22u nodad
	# No-default semantics (D7): the former WAN connected prefix becomes local.
	ip -6 route del default via 2001:db8:ffff::2 dev m22w metric 42422
	/usr/bin/xraywrt net-refresh
	has_local6 2001:db8:ffff::2
	ip -6 route add default via 2001:db8:ffff::2 dev m22w metric 42422
	/usr/bin/xraywrt net-refresh
	absent has_local6 2001:db8:ffff::2
	absent has_local6 2001:db8:dead::1
	dns_udp 2001:db8:dead::1 static22.corp22 A 192.0.2.9
	dns_udp 2001:db8:dead::1 static22.corp22 AAAA fd22:10::9
	dns_tcp 2001:db8:dead::1 static22.corp22 A c0000209
	dns_udp 2001:db8:dead::1 conditional22.test A 198.20.22.2
	grep -q 'conditional22.test' "$WORK/logs/dns-wan.log"
	# Restart dnsmasq to clear its cache; an uncached real public DNS control.
	/etc/init.d/dnsmasq restart
	dns_udp 2001:db8:dead::1 openwrt.org A 'Address:'
	uci show dhcp >"$WORK/logs/dhcp.fixture.after"
	cmp "$WORK/logs/dhcp.fixture.before" "$WORK/logs/dhcp.fixture.after"
	# Both local and unique upstream answers must complete within the bounded probe.
	# Not .test: OpenWrt rfc6761.conf answers that TLD locally and never forwards it.
	if ! dns_udp fd22:10::1 primary22.example.net A 198.20.22.22; then
		/usr/bin/xraywrt logs-json 300 >"$WORK/logs/routes-core.json" 2>&1 || true
		cat /var/etc/dnsmasq.conf.* /tmp/dnsmasq.*.d/* >"$WORK/logs/dnsmasq-effective.conf" 2>&1 || true
		logread -e dnsmasq >"$WORK/logs/dnsmasq-syslog.log" 2>&1 || true
		return 1
	fi
}

check_local_names() {
	local pair="" router="" router_hex=""
	router="$(uci -q get system.@system[0].hostname)"
	[ -n "$router" ]
	router_hex="$(printf '%s' "$router" | hexdump -v -e '1/1 "%02x"')"
	for pair in direct-first:fake-ip proxy-first:fake-ip proxy-first:redir-host; do
		profile "${pair%:*}" "${pair#*:}" false 1
		set_lists empty
		dns_udp 192.0.2.1 m22host.lan A 192.0.2.10
		absent grep -q '198[.]1[89][.]' "$WORK/logs/dns-last.log"
		dns_tcp 192.0.2.1 m22host.lan A c000020a
		dns_udp 192.0.2.1 "$router.corp22" A 192.0.2.1
		absent grep -q '198[.]1[89][.]' "$WORK/logs/dns-last.log"
		dns_tcp 192.0.2.1 "$router.corp22" A c0000201
		dns_udp 192.0.2.1 10.2.0.192.in-addr.arpa PTR m22host.lan
		dns_tcp 192.0.2.1 10.2.0.192.in-addr.arpa PTR 6d3232686f7374036c616e
		dns_udp 192.0.2.1 1.2.0.192.in-addr.arpa PTR "$router"
		dns_tcp 192.0.2.1 1.2.0.192.in-addr.arpa PTR "$router_hex"
	done
}

check_fakeip_direct() {
	local address="" direct_pid="" proxy_pid=""
	profile proxy-first fake-ip true 1
	set_lists empty
	uci add_list xraywrt.settings.source_network_interfaces=m22u
	uci commit xraywrt
	/usr/bin/xraywrt reload
	cp /tmp/xraywrt/config.json "$WORK/runtime-before-device-list"
	printf '02:00:00:22:00:02\n' >/tmp/xraywrt-policy-list.network-direct-src
	/usr/bin/xraywrt apply-lists - - /tmp/xraywrt-policy-list.network-direct-src
	cmp -s /tmp/xraywrt/config.json "$WORK/runtime-before-device-list"
	dns_udp 192.0.2.1 fake22.example.net A fake-ip
	address="$(awk '/^Name:/ {answer=1} answer && /^Address/ {for(i=1;i<=NF;i++) if($i ~ /^198[.]1[89][.]/) {print $i;exit}}' "$WORK/logs/dns-last.log")"
	[ -n "$address" ]
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 20 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/hold >"$WORK/logs/fake-direct.http" 2>&1 6>&- 7>&- 8>&- 9>&- &
	direct_pid=$!; PIDS="$PIDS $direct_pid"
	ip netns exec m22-u curl --noproxy '*' -fsS --max-time 20 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/hold >"$WORK/logs/fake-proxy.http" 2>&1 6>&- 7>&- 8>&- 9>&- &
	proxy_pid=$!; PIDS="$PIDS $proxy_pid"
	wait "$direct_pid"; wait "$proxy_pid"
	PIDS="${PIDS% "$direct_pid" "$proxy_pid"}"
	grep -q xraywrt-network-fixture "$WORK/logs/fake-direct.http"
	grep -q xraywrt-network-fixture "$WORK/logs/fake-proxy.http"
	# Rule 6.5.4 is the only route from a fake-IP domain to a freedom outbound (the
	# provider rule sends it to proxy, an unrestored fake-IP goes to xraywrt-block):
	# the WAN server sees the listed device from the router, the unlisted one from the node.
	peer_is "$WORK/logs/fake-direct.http" 198.20.22.1 2001:db8:ffff::1
	peer_is "$WORK/logs/fake-proxy.http" 198.20.22.2 2001:db8:ffff::2
	node_log_row | grep -q 'accepted tcp:fake22[.]example[.]net:8080 '
	# Real IPv4 and IPv6 stay outside the core, even with the IPv6 flag on.
	http c 198.20.22.2 | grep xraywrt-network-fixture
	http c '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
	snap fake-direct
}

check_lifecycle() {
	local pid="" old="" i="" opened=0
	profile direct-first fake-ip true 0
	set_lists empty
	pid="$(cat /var/run/xraywrt/xray.pid)"
	nft list chain inet xraywrt client_ipv6_egress
	uci set xraywrt.settings.block_client_ipv6=0
	uci add_list xraywrt.settings.provider_override=block_client_ipv6
	uci commit xraywrt
	/usr/bin/xraywrt reload
	absent nft list chain inet xraywrt client_ipv6_egress
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
	/usr/bin/xraywrt reload
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
	# Key removal/re-add uses fresh API uploads, preserving own-value override.
	/usr/bin/xraywrt read-config | jq -r .content | jq 'del(.xraywrt["block-client-ipv6"])' > /tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-fixture
	absent nft list chain inet xraywrt client_ipv6_egress
	/usr/bin/xraywrt read-config | jq -r .content | jq '.xraywrt["block-client-ipv6"] = true' > /tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-fixture
	absent nft list chain inet xraywrt client_ipv6_egress
	uci -q delete xraywrt.settings.provider_override
	uci commit xraywrt
	/usr/bin/xraywrt reload
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
	nft list chain inet xraywrt client_ipv6_egress
	# Real failed kernel transaction through nft_apply, with a fixture-only fault.
	(
		settings_load
		BLOCK_CLIENT_IPV6=0
		# shellcheck disable=SC2329 # nft_apply calls the scoped fault injector
		nft() {
			if [ "$1" = -f ]; then printf '\nthis is an intentionally invalid fixture transaction\n' >>"$2"; fi
			/usr/sbin/nft "$@"
		}
		if nft_apply; then exit 1; fi
	)
	nft list chain inet xraywrt client_ipv6_egress
	(reject_fresh failed-transaction)
	/usr/bin/xraywrt reload
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	absent nft list table inet xraywrt
	http c '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
	/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready
	(reject_fresh restart)
	old="$(cat /var/run/xraywrt/xray.pid)"
	kill -STOP "$old"
	# Three failed DNS probes (spec 9.2) fail open: the policy is removed.
	for i in $(seq 1 150); do
		if ! nft list table inet xraywrt >/dev/null 2>&1; then opened=1; break; fi
		sleep 1
	done
	[ "$opened" = 1 ]
	http c '[2001:db8:ffff::2]' | grep xraywrt-network-fixture
	# A hung core is not restarted: three good probes restore the policy in place.
	kill -CONT "$old"
	ready
	[ "$old" = "$(cat /var/run/xraywrt/xray.pid)" ]
	(reject_fresh watchdog-recovered)
	# A dead core is respawned by procd with a new pid.
	kill -KILL "$old"
	sleep 5
	ready
	[ "$old" != "$(cat /var/run/xraywrt/xray.pid)" ]
	(reject_fresh watchdog-restart)
}

# A1: replies of inbound connections are never marked. A WAN client reaches a
# policy-selected LAN host through an fw4 DNAT redirect and a router WAN service;
# any marked reply would be TPROXY'd by proxy_redirect, where the counters sit.
stop_reply_listeners() {
	local pid=""
	for pid in "$@"; do kill "$pid" 2>/dev/null || true; done
	sleep 1
	for pid in "$@"; do
		# Do not signal a recycled PID; only these owned fixture commands qualify.
		if grep -qF "$WORK/www" "/proc/$pid/cmdline" 2>/dev/null ||
			grep -Eq 'UDP4-RECVFROM:(8088|8091)' "/proc/$pid/cmdline" 2>/dev/null; then
			kill -KILL "$pid" 2>/dev/null || true
		fi
		wait "$pid" 2>/dev/null || true
	done
}

udp_echo() (
	local label="$1" address="$2" port="$3" ns="$4" listen_port="$5" pid="" reply_src="" attempt=""
	# One bounded foreground echo per probe: no untracked forked listeners.
	if [ "$ns" = router ]; then
		socat -T 4 "UDP4-RECVFROM:$listen_port" PIPE >"$WORK/logs/a1-$label.listener" 2>&1 6>&- 7>&- 8>&- 9>&- &
	else
		ip netns exec "$ns" socat -T 4 "UDP4-RECVFROM:$listen_port" PIPE >"$WORK/logs/a1-$label.listener" 2>&1 6>&- 7>&- 8>&- 9>&- &
	fi
	pid=$!
	trap 'stop_reply_listeners "$pid"' EXIT
	sleep 1
	kill -0 "$pid"
	printf 'a1-%s' "$label" >"$WORK/udp-probe"
	# Keep ash xtrace out of the payload (the echo deliberately has no newline).
	(BOUNDED_STDIN="$WORK/udp-probe" bounded ip netns exec m22-w socat -t 2 -T 3 - "UDP4:$address:$port") >"$WORK/logs/a1-$label.udp" 2>"$WORK/logs/a1-$label.stderr" || true
	cmp "$WORK/udp-probe" "$WORK/logs/a1-$label.udp"
	# Observe this tuple before teardown/later probes can retire the UDP flow.
	# A /proc dump can omit a live entry during concurrent table changes.
	case "$ns" in router) reply_src='198[.]20[.]22[.]1' ;; *) reply_src='192[.]0[.]2[.]2' ;; esac
	for attempt in 1 2 3 4 5; do
		cat /proc/net/nf_conntrack >"$WORK/logs/a1-$label.conntrack-all"
		if grep -E "udp .*src=198[.]20[.]22[.]2 dst=198[.]20[.]22[.]1 sport=[0-9]+ dport=$port .*src=$reply_src dst=198[.]20[.]22[.]2 sport=$listen_port dport=" "$WORK/logs/a1-$label.conntrack-all" >"$WORK/logs/a1-$label.conntrack"; then
			absent grep -q UNREPLIED "$WORK/logs/a1-$label.conntrack"
			return 0
		fi
		sleep 1
	done
	return 1
)

# Handle of the nth rule of an xraywrt chain.
chain_handle() {
	nft -a list chain inet xraywrt "$1" | awk -v n="$2" '/^\t\t.*# handle / {if (++seen == n) {print $NF; exit}}'
}

check_forward_replies() {
	local pair="" mode="" pids="" pid="" mark="" reply=""
	trap 'stop_reply_listeners $pids' EXIT
	netstat -lnu >"$WORK/logs/a1-ports-router.before"
	ip netns exec m22-c netstat -lntu >"$WORK/logs/a1-ports-lan.before"
	absent grep -Eq ':8088[[:space:]]' "$WORK/logs/a1-ports-router.before"
	absent grep -Eq ':8091[[:space:]]' "$WORK/logs/a1-ports-lan.before"
	uci set firewall.m22dnat=redirect
	uci set firewall.m22dnat.name=m22dnat
	uci set firewall.m22dnat.src=m22w
	uci set firewall.m22dnat.src_dip=198.20.22.1
	uci set firewall.m22dnat.src_dport=18091
	uci set firewall.m22dnat.dest=m22c
	uci set firewall.m22dnat.dest_ip=192.0.2.2
	uci set firewall.m22dnat.dest_port=8091
	uci set firewall.m22dnat.proto='tcp udp'
	uci set firewall.m22dnat.target=DNAT
	uci commit firewall
	/etc/init.d/firewall reload
	nft list chain inet fw4 dstnat_m22w | grep 'dnat ip to 192.0.2.2:8091'
	# LAN host TCP listener; the router TCP listener already belongs to PIDS.
	ip netns exec m22-c uhttpd -f -p 0.0.0.0:8091 -h "$WORK/www" >"$WORK/logs/a1-http-lan.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
	pids="$!"
	sleep 2
	for pid in $pids; do kill -0 "$pid" || fatal "listener exited: $pid"; done
	for pair in proxy-first:empty direct-first:wanclient; do
		mode="${pair%:*}"
		profile "$mode" fake-ip false 0
		set_lists "${pair#*:}"
		ready
		nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip daddr 198.20.22.2 meta l4proto '{ tcp, udp }' th sport '{ 8088, 8091 }' counter comment a1-reply
		nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip daddr 198.20.22.2 meta l4proto '{ tcp, udp }' th dport 8080 counter comment a1-control
		# DNAT port forward, then router WAN service; each TCP and UDP.
		http w 198.20.22.1 18091 | grep xraywrt-network-fixture
		udp_echo "$mode-forward" 198.20.22.1 18091 m22-c 8091
		http w 198.20.22.1 8088 | grep xraywrt-network-fixture
		udp_echo "$mode-router" 198.20.22.1 8088 router 8088
		# Control: a client-originated flow to the same WAN address is marked and counted.
		http c 198.20.22.2 8080 | grep xraywrt-network-fixture
		nft list chain inet xraywrt proxy_redirect >"$WORK/logs/a1-$mode.nft"
		grep 'comment "a1-reply"' "$WORK/logs/a1-$mode.nft" | grep -q 'counter packets 0 '
		grep 'comment "a1-control"' "$WORK/logs/a1-$mode.nft" | grep -Eq 'counter packets [1-9]'
		# Conntrack accounting may insert packet/byte fields between the tuples.
		cat /proc/net/nf_conntrack >"$WORK/logs/a1-$mode.conntrack-all"
		{
			grep -E 'tcp .*dport=18091 .*src=192\.0\.2\.2 dst=198\.20\.22\.2 sport=8091 ' "$WORK/logs/a1-$mode.conntrack-all"
			grep -E 'tcp .*dport=8088 .*src=198\.20\.22\.1 dst=198\.20\.22\.2 sport=8088 ' "$WORK/logs/a1-$mode.conntrack-all"
			cat "$WORK/logs/a1-$mode-forward.conntrack" "$WORK/logs/a1-$mode-router.conntrack"
		} >"$WORK/logs/a1-$mode.conntrack"
		absent grep -q UNREPLIED "$WORK/logs/a1-$mode.conntrack"
		# Fixture sensitivity: without the reply rule the same flows break and the counter moves.
		nft list chain inet xraywrt prerouting_policy >"$WORK/logs/a1-$mode.prerouting.before"
		nft list chain inet xraywrt mangle_output >"$WORK/logs/a1-$mode.output.before"
		reply="$(chain_handle prerouting_policy 1)"
		nft -a list chain inet xraywrt prerouting_policy | grep "ct direction reply return # handle $reply"
		nft delete rule inet xraywrt prerouting_policy handle "$reply"
		if http w 198.20.22.1 18091; then fatal "DNAT reply passed without the reply rule ($mode)"; fi
		nft insert rule inet xraywrt prerouting_policy ct direction reply return
		mark="$(chain_handle mangle_output 1)"; reply="$(chain_handle mangle_output 2)"
		nft -a list chain inet xraywrt mangle_output | grep "ct direction reply return # handle $reply"
		nft delete rule inet xraywrt mangle_output handle "$reply"
		if http w 198.20.22.1 8088; then fatal "router reply passed without the reply rule ($mode)"; fi
		nft add rule inet xraywrt mangle_output position "$mark" ct direction reply return
		nft list chain inet xraywrt prerouting_policy | cmp - "$WORK/logs/a1-$mode.prerouting.before"
		nft list chain inet xraywrt mangle_output | cmp - "$WORK/logs/a1-$mode.output.before"
		nft list chain inet xraywrt proxy_redirect | grep 'comment "a1-reply"' | grep -Eq 'counter packets [1-9]'
		# Restored rules serve fresh flows again.
		http w 198.20.22.1 18091 | grep xraywrt-network-fixture
		http w 198.20.22.1 8088 | grep xraywrt-network-fixture
	done
	uci delete firewall.m22dnat
	uci commit firewall
	/etc/init.d/firewall reload
	stop_reply_listeners $pids
	trap - EXIT
}

selected_ipv4() {
	local label="$1"
	nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip daddr 198.20.22.2 tcp dport 8080 counter comment selected-ipv4
	http c 198.20.22.2 8080 /cgi-bin/peer | tee "$WORK/logs/selected-$label.http" | grep xraywrt-network-fixture
	nft list chain inet xraywrt proxy_redirect >"$WORK/logs/selected-$label.nft"
	grep 'comment "selected-ipv4"' "$WORK/logs/selected-$label.nft" | grep -Eq 'counter packets [1-9]'
	peer_is "$WORK/logs/selected-$label.http" 198.20.22.1
}

check_ipv6_disabled() {
	local path="" chain="" table="" priority=""
	profile direct-first fake-ip true 0
	set_lists wanclient
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ]
	[ "$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6)" = 0 ]
	ip -6 address save >"$WORK/saved/ipv6.addresses"
	ip -6 route save table all >"$WORK/saved/ipv6.routes"
	for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
		printf '%s %s\n' "$path" "$(cat "$path")"
	done >"$WORK/saved/ipv6.flags"
	: >"$WORK/ipv6-disabled"
	sysctl -w net.ipv6.conf.all.disable_ipv6=1
	ip -6 rule show >"$WORK/logs/a2-disabled.before.rules6"
	ip -6 route show table all >"$WORK/logs/a2-disabled.before.routes6"
	/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready
	snap a2-disabled
	cmp "$WORK/logs/a2-disabled.before.rules6" "$WORK/logs/a2-disabled.rules6"
	cmp "$WORK/logs/a2-disabled.before.routes6" "$WORK/logs/a2-disabled.routes6"
	# Inert ip6 sets/guards remain; IPv6 cannot reach a mark setter or TPROXY.
	absent grep -E '(ip6|meta nfproto ipv6).*tproxy' "$WORK/logs/a2-disabled.nft"
	for chain in prerouting_policy mangle_output; do
		nft list chain inet xraywrt "$chain" >"$WORK/logs/a2-disabled-$chain.nft"
		awk '/meta nfproto ipv6 return/ {guard=1}
			/meta mark set.*0x08000000/ {seen=1; if (!guard) bad=1}
			END {exit bad || !guard || !seen}' "$WORK/logs/a2-disabled-$chain.nft"
	done
	selected_ipv4 a2-disabled
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	restore_ipv6
	/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready
	table="$(sed -n 's/^TABLE=//p' /var/run/xraywrt/route.state)"
	priority="$(sed -n 's/^PRIORITY=//p' /var/run/xraywrt/route.state)"
	ip -6 rule show | grep "^$priority:.*0x8000000/0x8000000.*lookup $table"
	ip -6 route show table "$table" | grep 'local default dev lo'
	# Select the WAN IPv6 destination too, proving restored interception, not raw reachability.
	set_lists dst
	selected_ipv6 a2-restored
	snap a2-restored
}

check_rule_precedence() {
	local family="" table="" priority=""
	profile direct-first fake-ip false 0
	set_lists wanclient
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	nft list table inet m22_precedence >/dev/null 2>&1 && fatal 'refuse existing precedence nft fixture'
	for family in 4 6; do
		if ip -"$family" rule show | grep -Eq '^(105|110|1000|2001):| lookup (20223|20224|20225)( |$)'; then fatal 'refuse occupied precedence rule fixture'; fi
		if ip -"$family" route show table all | grep -Eq ' table (20223|20224|20225)( |$)'; then fatal 'refuse occupied precedence route fixture'; fi
	done
	: >"$WORK/precedence"
	printf 'TABLE=20225\nPRIORITY=1000\n' >/var/run/xraywrt/route.state
	for family in 4 6; do
		ip -"$family" route add blackhole default table 20223
		ip -"$family" route add blackhole default table 20224
		ip -"$family" rule add priority 105 lookup main suppress_prefixlength 0
		ip -"$family" rule add priority 110 not fwmark 0x1bd00 lookup 20223
		ip -"$family" rule add priority 2001 fwmark 0x3f00/0x3f00 lookup 20224
		ip -"$family" route add local default dev lo table 20225
		ip -"$family" rule add priority 1000 fwmark 0x08000000/0x08000000 lookup 20225
		ip -"$family" rule show >"$WORK/logs/a3-before.rules$family"
	done
	/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-; ready
	table="$(sed -n 's/^TABLE=//p' /var/run/xraywrt/route.state)"
	priority="$(sed -n 's/^PRIORITY=//p' /var/run/xraywrt/route.state)"
	case "$priority" in [5-9][0-9]) ;; *) fatal "priority outside 50-99: $priority" ;; esac
	for family in 4 6; do
		ip -"$family" rule show >"$WORK/logs/a3-after.rules$family"
		grep "^$priority:.*0x8000000/0x8000000.*lookup $table" "$WORK/logs/a3-after.rules$family"
		absent grep '^1000:' "$WORK/logs/a3-after.rules$family"
		ip -"$family" route show table all >"$WORK/logs/a3-after.routes$family"
		absent grep ' table 20225 ' "$WORK/logs/a3-after.routes$family"
		grep -E '^(105|110|2001):' "$WORK/logs/a3-before.rules$family" >"$WORK/rules.before"
		grep -E '^(105|110|2001):' "$WORK/logs/a3-after.rules$family" >"$WORK/rules.after"
		cmp "$WORK/rules.before" "$WORK/rules.after"
	done
	# Both intercept and mwan3 bits must survive, yet the TPROXY rule wins first.
	nft -f - <<'EOF'
add table inet m22_precedence
add chain inet m22_precedence producer { type filter hook prerouting priority -151; policy accept; }
add rule inet m22_precedence producer iifname "m22c" meta mark set meta mark | 0x3f00
add chain inet m22_precedence observe { type filter hook prerouting priority -149; policy accept; }
add rule inet m22_precedence observe ip daddr 198.20.22.2 tcp dport 8080 meta mark & 0x08003f00 == 0x08003f00 counter comment "combined4"
add rule inet m22_precedence observe ip6 daddr 2001:db8:ffff::2 tcp dport 8080 meta mark & 0x08003f00 == 0x08003f00 counter comment "combined6"
EOF
	selected_ipv4 a3-precedence
	set_lists dst
	selected_ipv6 a3-precedence
	nft list table inet m22_precedence >"$WORK/logs/a3-marks.nft"
	grep 'comment "combined4"' "$WORK/logs/a3-marks.nft" | grep -Eq 'counter packets [1-9]'
	grep 'comment "combined6"' "$WORK/logs/a3-marks.nft" | grep -Eq 'counter packets [1-9]'
	ip -4 route get 198.20.22.2 mark 0x08003f00 >"$WORK/logs/a3-lookup4"
	ip -6 route get 2001:db8:ffff::2 mark 0x08003f00 >"$WORK/logs/a3-lookup6"
	grep "local .*table $table" "$WORK/logs/a3-lookup4"
	grep "local .*table $table" "$WORK/logs/a3-lookup6"
	snap a3-precedence
	cleanup_precedence
}

# Spec 6.3 / plan 0.4: TPROXY delivers to the core's loopback-only listeners.
# One bounded UDP echo in the WAN namespace per probe, reached through the core and the SOCKS node.
udp_via_core() (
	local family="$1" address="$2" pid=""
	ip netns exec m22-w socat -T 4 "UDP$family-RECVFROM:9091" PIPE >"$WORK/logs/loopback-udp$family.listener" 2>&1 6>&- 7>&- 8>&- 9>&- &
	pid=$!
	trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
	sleep 1
	kill -0 "$pid"
	printf 'loopback-udp%s' "$family" >"$WORK/udp-probe"
	(BOUNDED_STDIN="$WORK/udp-probe" bounded ip netns exec m22-c socat -t 2 -T 3 - "UDP$family:$address:9091") >"$WORK/logs/loopback-udp$family.udp" 2>"$WORK/logs/loopback-udp$family.stderr" || true
	cmp "$WORK/udp-probe" "$WORK/logs/loopback-udp$family.udp"
)

check_loopback_tproxy() {
	local proto=""
	profile direct-first fake-ip false 0
	set_lists loopback
	# Listeners on loopback only, and the nft targets point at them.
	netstat -lntu >"$WORK/logs/loopback-listeners"
	for proto in tcp udp; do
		grep -Eq "^$proto +[0-9]+ +[0-9]+ 127[.]0[.]0[.]1:7894 " "$WORK/logs/loopback-listeners"
		grep -Eq "^$proto +[0-9]+ +[0-9]+ ::1:7894 " "$WORK/logs/loopback-listeners"
	done
	absent grep -Eq ' (0[.]0[.]0[.]0|::):789[45] ' "$WORK/logs/loopback-listeners"
	nft list chain inet xraywrt proxy_redirect >"$WORK/logs/loopback-redirect.nft"
	grep -q 'tproxy ip to 127.0.0.1:7894' "$WORK/logs/loopback-redirect.nft"
	grep -q 'tproxy ip6 to \[::1\]:7894' "$WORK/logs/loopback-redirect.nft"
	nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 meta nfproto ipv4 meta l4proto '{ tcp, udp }' th dport '{ 8081, 9091 }' counter comment loopback4
	nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 meta nfproto ipv6 meta l4proto '{ tcp, udp }' th dport '{ 8081, 9091 }' counter comment loopback6
	# TCP and UDP, IPv4 and IPv6: each flow is delivered to the core and leaves through the node.
	http c 198.20.22.2 8081 /cgi-bin/peer | tee "$WORK/logs/loopback-tcp4.http" | grep xraywrt-network-fixture
	http c '[2001:db8:ffff::2]' 8081 /cgi-bin/peer | tee "$WORK/logs/loopback-tcp6.http" | grep xraywrt-network-fixture
	udp_via_core 4 198.20.22.2
	udp_via_core 6 '[2001:db8:ffff::2]'
	nft list chain inet xraywrt proxy_redirect >"$WORK/logs/loopback-counters.nft"
	grep 'comment "loopback4"' "$WORK/logs/loopback-counters.nft" | grep -Eq 'counter packets [1-9]'
	grep 'comment "loopback6"' "$WORK/logs/loopback-counters.nft" | grep -Eq 'counter packets [1-9]'
	# The WAN server sees the node, not the client (forwarded) or the router (direct).
	peer_is "$WORK/logs/loopback-tcp4.http" 198.20.22.2
	peer_is "$WORK/logs/loopback-tcp6.http" 2001:db8:ffff::2
	# The node got each flow from the router's proxy outbound, in this row.
	node_log_row >"$WORK/logs/loopback-node.log"
	grep -Eq 'from (tcp:)?(198[.]20[.]22[.]1|\[2001:db8:ffff::1\]):[0-9]+ accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/loopback-node.log"
	grep -Eq 'from (tcp:)?(198[.]20[.]22[.]1|\[2001:db8:ffff::1\]):[0-9]+ accepted tcp:\[2001:db8:ffff::2\]:8081 ' "$WORK/logs/loopback-node.log"
	grep -Eq 'from (udp:)?(198[.]20[.]22[.]1|\[2001:db8:ffff::1\]):[0-9]+ accepted udp:198[.]20[.]22[.]2:9091 ' "$WORK/logs/loopback-node.log"
	grep -Eq 'from (udp:)?(198[.]20[.]22[.]1|\[2001:db8:ffff::1\]):[0-9]+ accepted udp:\[2001:db8:ffff::2\]:9091 ' "$WORK/logs/loopback-node.log"
}

# WAN DNS (resolv.conf.auto) for bypass hosts: the synthetic WAN resolver, or DHCP again.
wan_dns() {
	local server="$1" expected="$1" i=""
	uci -q delete network.wan.dns || true
	if [ "$server" = dhcp ]; then
		uci -q delete network.wan.peerdns || true
		expected=10.0.2.3
	else
		uci set network.wan.peerdns=0
		uci add_list "network.wan.dns=$server"
	fi
	uci commit network
	ifup wan
	for i in $(seq 1 60); do
		grep -qx "nameserver $expected" /tmp/resolv.conf.d/resolv.conf.auto && break
		sleep 1
	done
	grep -qx "nameserver $expected" /tmp/resolv.conf.d/resolv.conf.auto
	/usr/bin/xraywrt net-refresh
}

# Spec 10: a missing asset is fetched from its https url before the config is used.
check_geodata_download() {
	local before=""
	wan_dns 198.20.22.2
	profile direct-first fake-ip false 0
	rm -f /opt/xraywrt/share/geosite.dat /opt/xraywrt/share/geosite.dat.old
	before="$(wc -l <"$WORK/logs/node.log")"
	profile direct-first geosite false 0
	cmp "$WORK/www/geosite.dat" /opt/xraywrt/share/geosite.dat
	jq -e '[.dns.servers[] | objects | select(.address == "fakedns") | .domains[]] | index("geosite:m22") != null' /tmp/xraywrt/config.json
	tail -n +"$((before + 1))" "$WORK/logs/node.log" >"$WORK/logs/geodata-node.log"
	grep -Eq 'from (tcp:)?198[.]20[.]22[.]1:[0-9]+ accepted tcp:127[.]0[.]0[.]1:8080 \[geo22 (->|>>) direct\]' "$WORK/logs/geodata-node.log"
	# The asset host resolves through WAN DNS, never through the core (spec 7.1).
	grep -qx 'server=/geo22.example.net/198.20.22.2' /tmp/dnsmasq.*.d/xraywrt.conf
	wan_dns dhcp
}

# Spec 7.2, 8: direct-first fake-IP only for the geosite list; the rest is real and bypasses Xray.
check_geosite_fakeip() {
	local address=""
	profile direct-first geosite false 0
	set_lists empty
	uci add_list xraywrt.settings.source_network_interfaces=m22u
	uci commit xraywrt
	/usr/bin/xraywrt reload
	dns_udp 192.0.2.1 fake22.example.net A fake-ip
	address="$(awk '/^Name:/ {answer=1} answer && /^Address/ {for(i=1;i<=NF;i++) if($i ~ /^198[.]1[89][.]/) {print $i;exit}}' "$WORK/logs/dns-last.log")"
	[ -n "$address" ]
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 10 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/peer | tee "$WORK/logs/geosite-proxy.http" | grep xraywrt-network-fixture
	peer_is "$WORK/logs/geosite-proxy.http" 198.20.22.2 2001:db8:ffff::2
	node_log_row | grep -q 'accepted tcp:fake22[.]example[.]net:8080 '
	# Outside the list: the real address, not intercepted and unseen by the core.
	dns_udp 192.0.2.1 public22.example.org A 198.20.22.2
	absent grep -q '198[.]1[89][.]' "$WORK/logs/dns-last.log"
	nft insert rule inet xraywrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip daddr 198.20.22.2 tcp dport 8080 counter comment geosite-real
	http c 198.20.22.2 8080 /cgi-bin/peer | tee "$WORK/logs/geosite-real.http" | grep xraywrt-network-fixture
	nft list chain inet xraywrt proxy_redirect | grep 'comment "geosite-real"' | grep -q 'counter packets 0 '
	# The WAN server sees the client itself: no core socket carried the request.
	peer_is "$WORK/logs/geosite-real.http" 192.0.2.2
	# A direct device keeps fake-IP but leaves through xraywrt-direct; others still use the list rule.
	printf '02:00:00:22:00:02\n' >/tmp/xraywrt-policy-list.network-direct-src
	/usr/bin/xraywrt apply-lists - - /tmp/xraywrt-policy-list.network-direct-src
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 10 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/peer | tee "$WORK/logs/geosite-direct.http" | grep xraywrt-network-fixture
	ip netns exec m22-u curl --noproxy '*' -fsS --max-time 10 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/peer | tee "$WORK/logs/geosite-unlisted.http" | grep xraywrt-network-fixture
	# As in fake-IP direct devices: router = xraywrt-direct (rule 6.5.4), node = the list rule.
	peer_is "$WORK/logs/geosite-direct.http" 198.20.22.1 2001:db8:ffff::1
	peer_is "$WORK/logs/geosite-unlisted.http" 198.20.22.2 2001:db8:ffff::2
}

# Spec 7.2, 6.5.3: a fake-IP without a record after a core restart is refused;
# a fresh DNS answer works again.
check_stale_fakeip() {
	local address="" old="" pid="" rc=0
	profile direct-first geosite false 0
	set_lists empty
	dns_udp 192.0.2.1 fake22.example.net A fake-ip
	address="$(awk '/^Name:/ {answer=1} answer && /^Address/ {for(i=1;i<=NF;i++) if($i ~ /^198[.]1[89][.]/) {print $i;exit}}' "$WORK/logs/dns-last.log")"
	[ -n "$address" ]
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 10 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/ | grep xraywrt-network-fixture
	old="$(cat /var/run/xraywrt/xray.pid)"
	kill -KILL "$old"
	sleep 5
	ready
	[ "$old" != "$(cat /var/run/xraywrt/xray.pid)" ]
	# Every SYN on every link during the probe (SSH transport excluded).
	tcpdump --immediate-mode -ni any -U -w "$WORK/logs/stale.pcap" 'tcp and not port 22' >"$WORK/logs/stale.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
	pid=$!
	trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
	sleep 2
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 10 "http://$address:8080/" || rc=$?
	sleep 1
	kill "$pid"; wait "$pid" 2>/dev/null || true
	trap - EXIT
	tcpdump -nn -r "$WORK/logs/stale.pcap" >"$WORK/logs/stale.decoded" 2>&1
	# xraywrt-block: the core accepts the TPROXY connection and closes it empty
	# (curl 52, not refused/timeout), and nothing but the client opens a TCP connection.
	[ "$rc" = 52 ]
	grep -Eq "IP 192[.]0[.]2[.]2[.][0-9]+ > $(printf '%s' "$address" | sed 's/[.]/[.]/g')[.]8080: Flags \[S\]," "$WORK/logs/stale.decoded"
	foreign_syns "$WORK/logs/stale.decoded" 192.0.2.2 >"$WORK/logs/stale.foreign-syns"
	[ ! -s "$WORK/logs/stale.foreign-syns" ]
	# FakeDNS answers carry TTL 1: let dnsmasq's copy expire, then ask again.
	sleep 2
	dns_udp 192.0.2.1 fake22.example.net A fake-ip
	address="$(awk '/^Name:/ {answer=1} answer && /^Address/ {for(i=1;i<=NF;i++) if($i ~ /^198[.]1[89][.]/) {print $i;exit}}' "$WORK/logs/dns-last.log")"
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 10 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/ | grep xraywrt-network-fixture
}

# Spec 7.5: HTTPS/SVCB answered empty; other types empty by default, raw to
# dns_raw_upstream only with dns_forward_other_types (direct-first).
check_dns_types() {
	local before=""
	profile direct-first fake-ip false 0
	set_lists empty
	# Control: the WAN resolver has an HTTPS record; through the router it is empty.
	dns_tcp_query c 198.20.22.2 53 public22.example.org HTTPS
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0001 ]
	dns_tcp_query c 192.0.2.1 53 public22.example.org HTTPS
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0000 ]
	dns_tcp_query router 127.0.0.1 7874 public22.example.org HTTPS
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0000 ]
	# Default: other types get an empty answer and never reach the WAN resolver.
	jq -e '.inbounds[] | select(.tag == "xraywrt-dns-in") | .settings | has("rewriteAddress") | not' /tmp/xraywrt/config.json
	before="$(grep -c 'query\[TXT\] txt22.example.net' "$WORK/logs/dns-wan.log" || true)"
	dns_tcp_query c 192.0.2.1 53 txt22.example.net TXT
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0000 ]
	[ "$(grep -c 'query\[TXT\] txt22.example.net' "$WORK/logs/dns-wan.log" || true)" = "$before" ]
	# Forward: raw to dns_raw_upstream; whitelist domains still get an empty answer.
	uci set xraywrt.settings.dns_raw_upstream=198.20.22.2
	uci set xraywrt.settings.dns_forward_other_types=1
	uci commit xraywrt
	/usr/bin/xraywrt reload
	jq -e '.inbounds[] | select(.tag == "xraywrt-dns-in") | .settings.rewriteAddress == "198.20.22.2"' /tmp/xraywrt/config.json
	before="$(grep -c 'query\[TXT\] txt22.example.net from 198.20.22.1' "$WORK/logs/dns-wan.log" || true)"
	dns_tcp_query c 192.0.2.1 53 txt22.example.net TXT
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0001 ]
	grep -q 6d32322d747874 "$WORK/logs/dns-tcp-last.hex"
	[ "$(grep -c 'query\[TXT\] txt22.example.net from 198.20.22.1' "$WORK/logs/dns-wan.log")" -gt "$before" ]
	dns_tcp_query router 127.0.0.1 7874 fake22.example.net TXT
	[ "$(dns_tcp_rcode)" = 0 ] && [ "$(dns_tcp_answers)" = 0000 ]
	uci -q delete xraywrt.settings.dns_raw_upstream
	uci -q delete xraywrt.settings.dns_forward_other_types
	uci commit xraywrt
	/usr/bin/xraywrt reload
}

# Spec 7.4: a proxy server given by name resolves through the dnsmasq bypass to
# WAN DNS (hosts file of the WAN resolver), never back through the core. With
# ForceIPv4 the provider adds the loopback server for the host (user guide).
check_server_bootstrap() {
	local strategy="" before="" node_before="" pid="" boot='{"address": "127.0.0.1", "port": 53, "domains": ["full:node22.example.net"], "skipFallback": true}'
	NODE_ADDRESS='' NODE_SOCKOPT='' NODE_DNS=''
	wan_dns 198.20.22.2
	for strategy in AsIs ForceIPv4; do
		NODE_SOCKOPT='' NODE_DNS=''
		[ "$strategy" = AsIs ] || { NODE_SOCKOPT=', "streamSettings": {"sockopt": {"domainStrategy": "ForceIPv4"}}'; NODE_DNS="$boot,"; }
		NODE_ADDRESS=node22.example.net
		profile direct-first fake-ip false 0
		set_lists core
		grep -qx 'server=/node22.example.net/198.20.22.2' /tmp/dnsmasq.*.d/xraywrt.conf
		# The router adds no server of its own for proxy hosts.
		[ "$(jq '[.dns.servers[] | select(.domains? == ["full:node22.example.net"])] | length' /tmp/xraywrt/config.json)" = "$([ "$strategy" = AsIs ] && echo 0 || echo 1)" ]
		# Fresh caches: the name must be resolved again for this request.
		/etc/init.d/dnsmasq restart
		sleep 2
		before="$(grep -c 'query\[A\] node22.example.net from 198.20.22.1' "$WORK/logs/dns-wan.log" || true)"
		# The core's own DNS module dials through xraywrt-direct, which carries the
		# router mark; a system resolver lookup does not.
		nft -f - <<EOF
add table inet m22_bootstrap
add chain inet m22_bootstrap output { type filter hook output priority 0; policy accept; }
add rule inet m22_bootstrap output ip daddr 127.0.0.1 meta l4proto { tcp, udp } th dport 53 meta mark & 0x000000ff == $XRAY_ROUTING_MARK counter comment "core-dns"
add rule inet m22_bootstrap output ip6 daddr ::1 meta l4proto { tcp, udp } th dport 53 meta mark & 0x000000ff == $XRAY_ROUTING_MARK counter comment "core-dns"
EOF
		tcpdump -ni lo -U -w "$WORK/logs/bootstrap-$strategy.pcap" 'port 53 or port 7874' >"$WORK/logs/bootstrap-$strategy.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
		pid=$!
		trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
		sleep 2
		node_before="$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log" || true)"
		http c 198.20.22.2 8081 | grep xraywrt-network-fixture
		sleep 1
		kill "$pid"; wait "$pid" 2>/dev/null || true
		trap - EXIT
		[ "$(grep -c 'query\[A\] node22.example.net from 198.20.22.1' "$WORK/logs/dns-wan.log")" -gt "$before" ]
		[ "$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log")" -gt "$node_before" ]
		nft list table inet m22_bootstrap >"$WORK/logs/bootstrap-$strategy.nft"
		nft delete table inet m22_bootstrap
		[ "$(grep -c 'comment "core-dns"' "$WORK/logs/bootstrap-$strategy.nft")" = 2 ]
		tcpdump -nn -r "$WORK/logs/bootstrap-$strategy.pcap" >"$WORK/logs/bootstrap-$strategy.decoded" 2>&1
		# Never back through the core's DNS inbound: no loop.
		[ "$(dns_asked "$WORK/logs/bootstrap-$strategy.decoded" 7874 A node22.example.net)" = 0 ]
		[ "$(dns_asked "$WORK/logs/bootstrap-$strategy.decoded" 7874 AAAA node22.example.net)" = 0 ]
		# ForceIPv4: exactly one lookup by the core (marked, A only), answered by the
		# provider's loopback server (dnsmasq); AsIs: none by the core.
		if [ "$strategy" = ForceIPv4 ]; then
			[ "$(dns_asked "$WORK/logs/bootstrap-$strategy.decoded" 53 A node22.example.net)" = 1 ]
			[ "$(dns_asked "$WORK/logs/bootstrap-$strategy.decoded" 53 AAAA node22.example.net)" = 0 ]
			grep -Eq '[.]53 > [^ ]+: .* A 198[.]20[.]22[.]2' "$WORK/logs/bootstrap-$strategy.decoded"
			grep 'comment "core-dns"' "$WORK/logs/bootstrap-$strategy.nft" | grep -Eq 'counter packets [1-9]'
		else
			[ "$(dns_asked "$WORK/logs/bootstrap-$strategy.decoded" 53 A node22.example.net)" -ge 1 ]
			[ "$(grep 'comment "core-dns"' "$WORK/logs/bootstrap-$strategy.nft" | grep -c 'counter packets 0 ')" = 2 ]
		fi
	done
	NODE_SOCKOPT='' NODE_ADDRESS='' NODE_DNS=''
	wan_dns dhcp
}

# Spec 16: two runtime balancers, live override without restart and persistence.
check_balancer_overrides() {
	local old="" phase="" before=""
	profile direct-first fake-ip false 0
	set_lists core
	/usr/bin/xraywrt read-config | jq -r .content | jq '
		.routing.balancers = [{tag:"main",selector:["proxy","direct"],strategy:{type:"random"}},
			{tag:"backup",selector:["proxy"],strategy:{type:"random"}}] |
		.routing.rules[1] |= (del(.outboundTag) | .balancerTag = "main")' >/tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt balancers >"$WORK/logs/balancers-before.json"
	jq -e '[.balancers[].tag] == ["main","backup"] and .balancers[0].targets == ["proxy","direct"]' "$WORK/logs/balancers-before.json"
	old="$(cat /var/run/xraywrt/xray.pid)"
	/usr/bin/xraywrt balancer-set main proxy
	[ "$old" = "$(cat /var/run/xraywrt/xray.pid)" ]
	for phase in pinned restarted; do
		if [ "$phase" = restarted ]; then
			/etc/init.d/xraywrt restart 6>&- 7>&- 8>&- 9>&-
			ready
			[ "$old" != "$(cat /var/run/xraywrt/xray.pid)" ]
		fi
		/usr/bin/xraywrt balancers >"$WORK/logs/balancers-$phase.json"
		jq -e '.balancers[] | select(.tag == "main") | .override == "proxy"' "$WORK/logs/balancers-$phase.json"
		before="$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log" || true)"
		http c 198.20.22.2 8081 /cgi-bin/peer | tee "$WORK/logs/balancers-$phase.http" | grep xraywrt-network-fixture
		# Pinned proxy: the WAN server sees the node, not the router (direct target).
		peer_is "$WORK/logs/balancers-$phase.http" 198.20.22.2
		[ "$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log")" -gt "$before" ]
	done
	/usr/bin/xraywrt balancer-set main ""
	/usr/bin/xraywrt balancers >"$WORK/logs/balancers-auto.json"
	jq -e '.balancers[] | select(.tag == "main") | .override == null' "$WORK/logs/balancers-auto.json"
	absent sh -c "uci -q get xraywrt.settings.balancer_override | grep -q 'main='"
	http c 198.20.22.2 8081 | grep xraywrt-network-fixture
}

# Both C3 rows begin with a known core/cache state and an unused second handler.
hot_subscription_fixture() {
	profile direct-first fake-ip false 0
	set_lists core
	/usr/bin/xraywrt read-config | jq -r .content | jq '
		.routing.domainStrategy = "AsIs" |
		.outbounds += [{tag:"hot-idle",protocol:"freedom"}]' >/tmp/xraywrt-config.network-fixture
	/usr/bin/xraywrt save-config /tmp/xraywrt-config.network-fixture
	/etc/init.d/xraywrt restart 6>&- 7>&- 8>&- 9>&-
	ready
}

# One curl, no retries: bytes on both sides of update prove the same TCP stream.
check_hot_subscription() (
	local client="" old="" attempt="" before=""
	trap 'touch "$WORK/hot-release"; kill "$client" 2>/dev/null || true; wait "$client" 2>/dev/null || true' EXIT
	hot_subscription_fixture
	rm -f "$WORK/hot-release"
	cat >"$WORK/www/cgi-bin/hot-hold" <<EOF
#!/bin/ash
printf 'Content-Type: text/plain\r\n\r\npeer=%s\nhot-tcp.before\n' "\$REMOTE_ADDR"
i=0
while [ "\$i" -lt 120 ]; do
	if [ -f "$WORK/hot-release" ]; then printf 'hot-tcp.after\n'; exit 0; fi
	sleep 1
	i=\$((i + 1))
done
exit 1
EOF
	chmod +x "$WORK/www/cgi-bin/hot-hold"
	old="$(cat /var/run/xraywrt/xray.pid)"
	printf '%s\n' "$old" >"$WORK/logs/hot-tcp.pid-before"
	before="$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log" || true)"
	ip netns exec m22-c curl --noproxy '*' --http1.1 -N -v -fsS --connect-timeout 5 --max-time 150 \
		http://198.20.22.2:8081/cgi-bin/hot-hold >"$WORK/logs/hot-tcp.stream" 2>"$WORK/logs/hot-tcp.curl" 6>&- 7>&- 8>&- 9>&- &
	client=$!
	for attempt in $(seq 1 30); do
		grep -q '^hot-tcp.before$' "$WORK/logs/hot-tcp.stream" && break
		kill -0 "$client"
		sleep 1
	done
	grep -q '^hot-tcp.before$' "$WORK/logs/hot-tcp.stream"
	# The stream runs through proxy: the WAN server sees the node.
	peer_is "$WORK/logs/hot-tcp.stream" 198.20.22.2
	/usr/bin/xraywrt read-config | jq -r .content | jq '
		(.outbounds[] | select(.tag == "hot-idle")) = {tag:"hot-idle",protocol:"blackhole"}' >"$WORK/www/hot-subscription.json"
	/usr/bin/xraywrt update-subscription http://198.20.22.2:8080/hot-subscription.json >"$WORK/logs/hot-subscription.result.json"
	jq -e '.action == "hot_reloaded"' "$WORK/logs/hot-subscription.result.json"
	cat /var/run/xraywrt/xray.pid >"$WORK/logs/hot-tcp.pid-after"
	[ "$old" = "$(cat "$WORK/logs/hot-tcp.pid-after")" ]
	kill -0 "$client"
	touch "$WORK/hot-release"
	wait "$client"
	client=""
	grep -q '^hot-tcp.after$' "$WORK/logs/hot-tcp.stream"
	[ "$(grep -c 'accepted tcp:198[.]20[.]22[.]2:8081 ' "$WORK/logs/node.log")" -eq $((before + 1)) ]
	jq -e '.outbounds[] | select(.tag == "hot-idle") | .protocol == "blackhole"' /tmp/xraywrt/config.json
)

check_routing_strategy_restart() {
	local old=""
	hot_subscription_fixture
	old="$(cat /var/run/xraywrt/xray.pid)"
	printf '%s\n' "$old" >"$WORK/logs/strategy.pid-before"
	/usr/bin/xraywrt read-config | jq -r .content | jq '.routing.domainStrategy = "IPIfNonMatch"' >"$WORK/www/hot-subscription.json"
	/usr/bin/xraywrt update-subscription http://198.20.22.2:8080/hot-subscription.json >"$WORK/logs/strategy.result.json"
	jq -e '.action == "restarted"' "$WORK/logs/strategy.result.json"
	ready
	cat /var/run/xraywrt/xray.pid >"$WORK/logs/strategy.pid-after"
	[ "$old" != "$(cat "$WORK/logs/strategy.pid-after")" ]
	jq -e '.routing.domainStrategy == "IPIfNonMatch"' /tmp/xraywrt/config.json
	http c 198.20.22.2 8081 | grep xraywrt-network-fixture
}

# zapret_rules <mark|none>: router output to the listed WAN host, marked before
# the policy (zapret's desync mark), observed after it.
zapret_rules() {
	nft delete table inet m22_zapret 2>/dev/null || true
	nft -f - <<EOF
add table inet m22_zapret
add chain inet m22_zapret producer { type route hook output priority -151; policy accept; }
add chain inet m22_zapret observer { type route hook output priority -149; policy accept; }
add rule inet m22_zapret observer ip daddr 198.20.22.2 tcp dport 8080 meta mark & 0x08000000 == 0x08000000 counter comment "intercepted"
add rule inet m22_zapret observer ip daddr 198.20.22.2 tcp dport 8080 meta mark & 0x08000000 == 0 counter comment "direct"
EOF
	[ "$1" = none ] || nft add rule inet m22_zapret producer ip daddr 198.20.22.2 tcp dport 8080 meta mark set meta mark \| "$1"
}

# Spec 8 (MihoWRT nft kept): zapret desync marks leave router output uninterceptable.
check_zapret() {
	local mark="" expected=""
	profile direct-first fake-ip false 0
	set_lists wanclient
	for mark in none 0x40000000 0x20000000; do
		zapret_rules "$mark"
		curl --noproxy '*' -fsS --connect-timeout 5 --max-time 5 http://198.20.22.2:8080/ | grep xraywrt-network-fixture
		expected=direct
		[ "$mark" != none ] || expected=intercepted
		nft list table inet m22_zapret >"$WORK/logs/zapret-$mark.nft"
		grep "comment \"$expected\"" "$WORK/logs/zapret-$mark.nft" | grep -Eq 'counter packets [1-9]'
	done
	nft delete table inet m22_zapret
}

# Guest network: fw4 input REJECT on the client zone. The fw4 include keeps
# TPROXY and hijacked DNS working; other router services stay rejected.
check_guest() {
	local handle=""
	profile direct-first fake-ip false 1
	set_lists wanclient
	uci set firewall.m22c.input=REJECT
	uci commit firewall
	/etc/init.d/firewall reload
	nft list chain inet fw4 input >"$WORK/logs/guest-input.nft"
	grep -q 'meta mark & 0x08000000 == 0x08000000 accept' "$WORK/logs/guest-input.nft"
	grep -q 'th dport 53 ct status dnat accept' "$WORK/logs/guest-input.nft"
	if http c 192.0.2.1 8088; then fatal 'guest zone reached a router service'; fi
	dns_udp 198.20.22.2 fake22.example.net A fake-ip
	selected_ipv4 guest
	# Sensitivity: without the include's DNS rule, hijacked DNS is rejected.
	handle="$(nft -a list chain inet fw4 input | awk '/th dport 53 ct status dnat accept/ {print $NF; exit}')"
	nft delete rule inet fw4 input handle "$handle"
	if dns_udp 198.20.22.2 fake22.example.net A fake-ip; then fatal 'hijacked guest DNS passed without the fw4 include'; fi
	/etc/init.d/firewall reload
	dns_udp 198.20.22.2 fake22.example.net A fake-ip
	uci set firewall.m22c.input=ACCEPT
	uci commit firewall
	/etc/init.d/firewall reload
}

# Spec 9.1: Stop is sticky; hotplug, UCI triggers and reload do not start it.
check_sticky_stop() {
	local i="" started=0
	/etc/init.d/xraywrt enabled || fatal 'prerequisite: xraywrt must be enabled'
	profile direct-first fake-ip false 0
	set_lists empty
	/etc/init.d/xraywrt stop 6>&- 7>&- 8>&- 9>&-
	[ -f /var/run/xraywrt/stopped ]
	ifup m22c
	uci set xraywrt.settings.core_log_level=info
	uci commit xraywrt
	reload_config
	/etc/init.d/xraywrt reload 6>&- 7>&- 8>&- 9>&-
	sleep 20
	absent /etc/init.d/xraywrt running
	absent nft list table inet xraywrt
	/usr/bin/xraywrt status-json | jq -e '.state == "stopped"'
	# Control: without the Stop marker the same hotplug event starts the service.
	rm /var/run/xraywrt/stopped
	ifup m22c
	for i in $(seq 1 60); do
		if /etc/init.d/xraywrt running; then started=1; break; fi
		sleep 1
	done
	[ "$started" = 1 ]
	ready
}

# Spec 9.2: a live core whose DNS path is dead fails open (policy and dnsmasq
# redirect removed) and recovers in place once DNS answers again.
check_dns_fail_open() {
	local pid="" i="" opened=0
	profile direct-first fake-ip false 0
	set_lists wanclient
	ready
	pid="$(cat /var/run/xraywrt/xray.pid)"
	nft -f - <<'EOF'
add table inet m22_dnskill
add chain inet m22_dnskill output { type filter hook output priority 0; policy accept; }
add rule inet m22_dnskill output ip daddr != 127.0.0.0/8 meta l4proto { tcp, udp } th dport 53 counter drop
add rule inet m22_dnskill output ip6 daddr != ::1 meta l4proto { tcp, udp } th dport 53 counter drop
EOF
	for i in $(seq 1 200); do
		# The degraded marker is written just before the policy cleanup.
		if /usr/bin/xraywrt status-json | jq -e '.state == "degraded"' >/dev/null &&
			! nft list table inet xraywrt >/dev/null 2>&1; then opened=1; break; fi
		sleep 1
	done
	[ "$opened" = 1 ]
	absent nft list table inet xraywrt
	absent ls /tmp/dnsmasq.*.d/xraywrt.conf
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
	http c 198.20.22.2 | grep xraywrt-network-fixture
	nft list table inet m22_dnskill | grep -Eq 'counter packets [1-9]'
	nft delete table inet m22_dnskill
	ready
	[ "$pid" = "$(cat /var/run/xraywrt/xray.pid)" ]
	nft list table inet xraywrt >/dev/null
}

row() {
	local name="$1" expected="$2" fn="$3" rc=0
	# Development-only row filter; the host entry never sets it, and a filtered run cannot be exit 0.
	case ",${NETWORK_ROWS:-all}," in *,all,*|*",$name,"*) ;; *) return 0 ;; esac
	CURRENT="$name"
	logger -t xraywrt "m22 row start: $name"
	wc -l <"$WORK/logs/node.log" >"$WORK/node.row-start"
	printf '\n==> %s: expected %s\n' "$name" "$expected"
	# A separate, non-conditional subshell keeps ash errexit effective in checks.
	set +e
	(set -e; set -x; "$fn") >"$WORK/logs/$name.log" 2>&1
	rc=$?
	set -e
	cat "$WORK/logs/$name.log"
	if [ "$rc" != 0 ]; then
		record "$name" FAIL "expected=$expected; actual=failed; exit=$rc; logs/$name.log"
		exit 1
	fi
	record "$name" PASS "expected=$expected; actual=matched; exit=0; logs/$name.log"
	snap "$name"
}

profile direct-first fake-ip false 0
set_lists empty
/etc/init.d/xraywrt start 6>&- 7>&- 8>&- 9>&-
ready
row 'nft syntax' '12 live kernel syntax checks' check_nft
row 'control reachable' 'dual-stack raw controls and separate Xray DNS path' check_control
row 'client IPv6 rejected' 'direct-first unlisted REJECT, selected IPv6 TPROXY, IPv6 DNS redirected; proxy-first flag unchanged' check_reject
row 'local and IPv4 retained' 'IPv4, local DNS UDP/TCP, local IPv6, ND/RA/DHCPv6 and fw4 denial unchanged' check_local
row 'core and other ingress retained' 'IPv4 via IPv6 SOCKS5 node, router output and unselected ingress succeed' check_core
row 'NetBird synthetic' '2 interfaces/bases, 2 proxy settings, packet/ct original/reply paths, start orders/reconnect/fw4' check_netbird
row 'routes and DNS boundaries' 'occupied slots preserved, live prefix updates and DNS ownership/conditional boundaries' check_routes_dns
row 'local names' 'fixture host and router names resolve to LAN addresses over UDP/TCP, with local reverse answers in fake-ip/redir-host' check_local_names
row 'fake-IP direct devices' 'listed MAC fake-IP uses xraywrt-direct; unlisted device uses the SOCKS node; real addresses bypass' check_fakeip_direct
row lifecycle 'provider/override, no-op, failed transaction, stop/watchdog/restart fresh flows' check_lifecycle
row 'port forward and WAN service replies' 'DNAT forward and router WAN service, TCP+UDP, proxy-first and direct-first: replies unmarked, rule-less control breaks' check_forward_replies
row 'IPv6 disabled' 'disabled stack starts with IPv4 TPROXY only, no IPv6 policy changes; re-enable restores IPv6 interception' check_ipv6_disabled
row 'policy rule precedence' 'priority 50-99 precedes NetBird 105/110 and mwan3 2001, preserves marks and foreign rules, cleans stale 1000 state' check_rule_precedence
row 'loopback TPROXY' 'TCP and UDP over IPv4 and IPv6 reach the core on 127.0.0.1/::1 only and leave through the SOCKS node' check_loopback_tproxy
row 'geodata download' 'missing geosite.dat fetched from the asset https url via WAN DNS bypass before the config is used' check_geodata_download
row 'geosite fake-IP' 'direct-first: geosite domain gets fake-IP and the proxy, others real IP past Xray; direct device fake-IP via xraywrt-direct' check_geosite_fakeip
row 'stale fake-IP' 'fake-IP without a record after a core restart is refused (xraywrt-block); a fresh DNS answer works' check_stale_fakeip
row 'DNS query types' 'HTTPS RR empty; TXT empty by default; raw to dns_raw_upstream with dns_forward_other_types, empty for whitelist domains' check_dns_types
row 'server bootstrap' 'proxy server by name resolves via dnsmasq bypass to WAN DNS without a loop, AsIs and ForceIPv4' check_server_bootstrap
row 'balancer overrides' 'two balancers listed; live pin reaches selected proxy, survives restart, empty target restores auto' check_balancer_overrides
row 'hot subscription TCP' 'subscription changes only hot-idle; proxy TCP delivers before/after bytes without reconnect or core restart' check_hot_subscription
row 'routing strategy restart' 'subscription changes only domainStrategy; action restarted, new PID, candidate live and traffic works' check_routing_strategy_restart
row 'zapret marks' 'router output with zapret desync marks 0x40000000/0x20000000 stays direct; unmarked control is intercepted' check_zapret
row 'guest zone' 'fw4 input REJECT: TPROXY and hijacked DNS accepted by the include, router service rejected, rule-less control breaks' check_guest
row 'sticky stop' 'Stop survives hotplug ifup, UCI reload trigger and reload; without the marker hotplug starts it' check_sticky_stop
row 'DNS path fail-open' 'dead upstream DNS: degraded, policy removed, client direct, same core recovers in place' check_dns_fail_open
CURRENT=complete
