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

`direct` bypasses the VPN, `core` lets the configuration choose, and a server or
balancer tag selects that target. Available tags appear under the list. The first
matching rule generally wins; direct address bypasses take precedence over
other overlapping addresses. If a tag disappears, affected rules are skipped
and Home warns. Domain recognition can depend on provider sniffing; encrypted DNS
or handshakes can limit it. Remote list URLs contain addresses, not site names.

Device lists accept IP or MAC addresses. A changing private Wi-Fi MAC may stop
matching; keep it fixed for this network. MAC matching requires the same local
network segment. IPv4 entries do not cover IPv6.

## DNS

XrayWRT redirects ordinary client DNS; encrypted DNS (DoH/DoT) can bypass it.
Fake-IP uses IPv4 and mappings are lost when the core restarts. Other query types
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
3. Check **Help** or run `logread -e xraywrt`. Review reports for sensitive data
   before sharing them; arbitrary logs may contain secrets.
4. To prevent restart on reboot, disable **Start on boot** or run
   `service xraywrt disable`.

## Remove

Run `XRAYWRT_ACTION=remove sh install.sh`, or use `apk del` for the installed
`luci-app-xraywrt`, `luci-i18n-xraywrt-ru` and `xraywrt-core` packages. Removal
stops the service and clears its network policy. Configuration, lists and UCI
settings remain for reinstall. `xraywrt uninstall` performs cleanup but does not
remove the packages.
