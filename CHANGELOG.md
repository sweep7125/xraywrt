# Changelog

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
