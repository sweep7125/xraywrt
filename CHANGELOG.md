# Changelog

## 0.1.7

- Move the Xray management API to a private Unix socket. For manual upgrades, install XrayWRT core 0.26.5-r2 or newer before updating the app. The installer checks managed core compatibility.
- Restore LuCI controls after lost job polling, simplify configuration views, and reduce the data loaded by Advanced and Help.
- Preserve cached lists and scheduled retries when URL discovery fails. Reuse inputs during configuration and firewall reloads.
- Harden watchdog recovery, subscription staging, and rollback. Document the NetBird routing caveat.

## 0.1.6

- Add an optional Discord Voice detector for IPv4 in direct-first mode. It uses the existing Xray ingress and respects explicit bypass rules.
- Add an option to suppress HTTPS and SVCB DNS records. Keep app-added WAN DNS direct and preserve the provider's explicit DNS routing.
- Respect direct-device exceptions in both traffic modes, reuse unambiguous provider DIRECT and BLOCK outbounds, and keep stale FakeIP traffic from leaking to WAN.
- Use proxy-first and leave optional traffic settings off when no setting or provider preference exists. Keep existing saved preferences.

## 0.1.5

- Match provider and personal address rules by destination ports and TCP or UDP, including entries from cached lists. Qualified personal sites match traffic already intercepted and recognized by Xray.
- Preserve the resolver's routing tag and answer filters for direct domain rules in direct-first mode. If that resolver fails, do not fall back to FakeDNS for those domains.

## 0.1.3

- Left-align the subscription-pinned server on Home, with even vertical spacing.

## 0.1.2

- Split Help reports into a short summary and a detailed, local download. The detailed file can contain credentials and requires confirmation.
- Improve spacing on Home and Advanced, shorten the balancer warning, and make subscription address lists visibly read-only.

## 0.1.1

- Use the separate public core release repository for core updates and rollback.
- Improve diagnostics, support reports, and traffic and update guidance.

## 0.1.0

First release.

- LuCI app for OpenWrt 25.12 (apk), with transparent IPv4/IPv6 routing and DNS.
- Xray JSON subscriptions: save several and use one at a time; manual config is supported.
- Traffic modes, device lists and ordered site/address rules with direct, core or tagged targets.
- Provider profile and balancer selection on Home, when available.
- Manual core updates using the separate `xraywrt-core` package.
- Watchdog recovery and Stop restore direct networking; this is not a kill switch.
- English and Russian interfaces.
- Upgrades from the old separate lists convert entries to My rules. Old sites-via-VPN
  entries and entries with ports become comments until edited; previously disabled
  own lists can become active. Review the converted rules after upgrade.
