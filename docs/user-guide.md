# XrayWRT user guide

[English README](../README.md) · [Русский](../README.ru.md)

## Configuration and subscriptions

XrayWRT needs native Xray JSON with outbounds. YAML and share links are not
supported. On **Subscription**, enter a JSON subscription URL and press
**Connect**. You can save several subscriptions and select **Use** to switch;
only one is active and configurations are not merged. Each subscription keeps
its own rules and server choice. Automatic updates cover the active subscription.

Alternatively, enter your own JSON under **Advanced → Xray configuration**.
Subscription updates replace the current `config.json`; its previous version is
kept as `config.json.bak` and can be restored in the editor. Review your config
before switching or updating. Subscription safety filtering restricts listeners;
manual configurations are your responsibility. Deleting the last subscription
keeps its configuration as manual config, without subscription-only filtering.
Treat subscription links as secrets: a LuCI read-only user may read stored links.

If a subscription contains multiple profiles, select one on Home. The provider's
routing and balancers decide where traffic goes; XrayWRT does not create its own
server selector. Home can show a dropdown to pin an available provider balancer
to a server. A pinned server has no automatic fallback if it fails; choose Auto
to return control to the balancer.

## Traffic and rules

On **What goes via VPN**, choose a traffic mode and save it:

- **proxy-first** sends client traffic to the core except direct rules and devices.
- **direct-first** sends selected traffic and devices to the core; other traffic
  goes direct. Provider rules still determine the core's outbound.

**My rules** is an ordered list of sites and addresses. Put one entry per line,
followed by a target:

```text
example.com direct
example.org core
203.0.113.0/24 my-server
```

IP and subnet `direct` rules bypass the core for real-IP traffic, regardless of DNS mode.
Intercepted client traffic matching a site `direct` rule can be handled by Xray
and use the provider's unique `DIRECT` outbound when available. That outbound may
itself chain through a proxy, including for Fake-IP.
Otherwise XrayWRT uses its own direct outbound.
`core` lets the configuration choose, and a server or balancer tag selects that target. Available tags appear under the list. The first
matching emitted Xray site route wins. An unqualified site `core` rule does not
stop later overlapping rules with different site matchers; avoid that overlap
when the provider should decide. Bare address lists keep direct bypasses ahead of
overlapping addresses. With address selectors, the first matching personal
address rule wins. Provider direct and device bypasses still apply. If a tag
disappears, affected rules are skipped
and Home warns. Domain recognition can depend on provider sniffing; encrypted DNS
or handshakes can limit it. Remote list URLs contain addresses, not site names.

Append `;ports`, `;ports;tcp`, or `;ports;udp` to a site, IP address, subnet, or list
URL to match destination ports and transport. Qualified sites use `direct` or a
named target, not `core`. They apply only to traffic already intercepted and
recognized by Xray; they do not add FakeDNS or capture traffic themselves. In
direct-first mode use an address or subnet for exact capture. The `regexp:` form
does not support qualifiers: semicolons remain part of the expression. For example,
`203.0.113.0/24;443;udp direct` bypasses only UDP destination port 443.
Use `;80,443,8000-8080` for several ports or ranges, and `;;udp` for UDP on any
port. Without a protocol, a port selector matches TCP and UDP. A remote row
inherits missing qualifiers from the URL, keeps its explicit ports, and is
skipped if its explicit protocol conflicts with the URL's protocol.

Device lists accept IP or MAC addresses. A changing private Wi-Fi MAC may stop
matching; keep it fixed for this network. MAC matching requires the same local
network segment. IPv4 entries do not cover IPv6. Direct devices bypass the core for real-IP traffic regardless of DNS mode.
Their Fake-IP traffic uses the selected `DIRECT` outbound.

## DNS

Router DNS redirection is off by default and can be enabled in **Advanced → DNS**.
Clients using the router as their DNS server still use its DNS path; encrypted DNS
(DoH/DoT) can bypass redirection. Fake-IP uses IPv4 and mappings are lost when the core restarts. Other query types
such as TXT, SRV and MX receive empty answers by default. Under **Advanced → DNS**
you can enable direct forwarding in direct-first mode, or VPN forwarding.
VPN forwarding requires an explicit DNS server IP and a suitable outbound tag.
It never falls back to WAN DNS. If the saved tag disappears or is unsuitable,
forwarding is forced off and a warning appears; select a valid tag and server
and enable it again. A remote server may intercept DNS, so the chosen resolver
may not receive queries. Confirm that chained outbounds use the intended VPN.

A conflicting DNS server or global dnsmasq forward can prevent startup. Stop the
other server or remove global forwards, and configure resolvers on WAN or in the
Xray configuration. The watchdog can restore direct traffic after repeated DNS
failures; XrayWRT is not a kill switch.

## Start, stop and update

Use **Home** for Start, Stop and status. Stop lasts until reboot. Set **Advanced →
Service → Start on boot** or use `service xraywrt enable` / `service xraywrt disable`
to control autostart. Core updates are manual: choose **Updates → Update the core**
or run `xraywrt core-update`. Subscriptions and remote lists have separate update
controls. Core updates need free flash and RAM; check the Updates page first.

Geodata is supplied by the configuration or by you, not bundled. Add a rule
database on Updates if a configuration requires one. Downloaded geodata has no
checksum; use a source you trust. After sysupgrade, reinstall the app and core;
configuration and lists are retained by the package backup settings.

## Install from local files

Use OpenWrt 25.12 (apk), 256 MB RAM recommended and about 32 MB free flash.
On the router run `cat /etc/apk/arch` and choose the core APK with exactly that
architecture. Obtain the app APK, optional Russian translation APK, and core
APK from a trusted release or local build. App releases are in
`sweep7125/xraywrt`; core releases are in `sweep7125/xraywrt-core`. Verify
`SHA256SUMS` and `SHA256SUMS-core` from the respective releases before transfer.
Latest selects stable releases, not prereleases. Packages are not signed; checksums do not
authenticate their source.

Copy files to `/tmp`, for example using `scp -O`, then run on the router:

```sh
apk update && apk add luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl ca-bundle
apk add --allow-untrusted /tmp/luci-app-xraywrt*.apk /tmp/xraywrt-core_*.apk
# Optional Russian UI:
apk add --allow-untrusted /tmp/luci-i18n-xraywrt-ru*.apk
apk add luci-i18n-base-ru
```

Remove transferred APKs from `/tmp` afterward to free RAM. A manually installed
core may lack a verified rollback package; the updater asks before continuing
without a backup. Confirm only if you accept the recovery risk.

## If internet is lost

1. Open LuCI at your router address and choose **Services → XrayWRT → Home → Stop**,
   or run `service xraywrt stop` over SSH.
2. Stop removes XrayWRT DNS redirection and routing policy, restoring direct access.
3. Check **Help** or run `logread -e xraywrt`. **Copy summary** leaves out all
   lists, configuration and raw log lines. **Download detailed report** saves a
   local text file with settings, personal rules, the current runtime config if
   available, and up to 1,000 recent XrayWRT and Xray log lines at any recorded
   level. The detailed file does not mask credentials. Share it privately and
   only with someone you trust.
4. To prevent restart on reboot, disable **Start on boot** or run
   `service xraywrt disable`.

## Remove

Run `XRAYWRT_ACTION=remove sh install.sh`, or use `apk del` for the installed
`luci-app-xraywrt`, `luci-i18n-xraywrt-ru` and `xraywrt-core` packages. Removal
stops the service and clears its network policy. Configuration, lists and UCI
settings remain for reinstall. `xraywrt uninstall` performs cleanup but does not
remove the packages.

### Discord Voice

Advanced → Routing offers Discord Voice, off by default. Providers can set the boolean `xraywrt.discord-voice`; each subscription can follow the provider or override it. Proxy-first ignores the request without changing the saved preference. In direct-first mode it sends recognized IPv4 discovery flows from configured client interfaces to the existing Xray ingress. Existing device and address decisions still apply; Xray chooses the outbound. The signature is heuristic and does not identify every Discord flow. The feature requires conntrack accounting (`net.netfilter.nf_conntrack_acct=1`); if unavailable, the normal policy remains active and the detector is skipped. Enable accounting using your system configuration, then reload XrayWRT.

The detector uses conntrack mark bit `0x01000000`, preserving other bits. XrayWRT has no other conntrack mark owner; packet mark values are separate, but third-party firewall, QoS or VPN rules can copy marks between namespaces or reuse this bit. Enable it only when XrayWRT has exclusive ownership of that conntrack bit on a known supported stack. Arbitrary third-party use of the same bit is unsupported. Flow offload can bypass packet inspection and is not certified. Turning the option off does not clear existing conntrack marks; an existing marked flow can resume detection when re-enabled.
