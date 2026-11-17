# XrayWRT

[Русский](README.ru.md)

XrayWRT adds a LuCI interface and transparent proxy routing to OpenWrt.
It uses an Xray JSON subscription or a manually supplied Xray JSON configuration.
Several subscriptions can be saved; only one is active at a time.
YAML subscriptions and share links such as `vless://` are not supported.

## Requirements

- OpenWrt **25.12**, with apk and firewall4/nftables; opkg is not supported.
- A supported 64-bit ARM core package matching `cat /etc/apk/arch`.
- **256 MB RAM recommended** and approximately **32 MB free flash** for installation.
  Core updates and geodata may require more space; download files also use RAM.
- Hardware checked: Cudy WR3000S v1 with OpenWrt 25.12.6.
- Remove conflicting proxy and DNS packages before installation; the installer
  reports conflicts. Run only one proxy stack at a time.

## Install

On the router, as root:

```sh
wget -qO- https://raw.githubusercontent.com/sweep7125/xraywrt/main/install.sh | sh
```

Choose install and language. The installer checks package checksums, installs
LuCI packages and dependencies, and runs `xraywrt core-update` to install the
separate core package. If no core package matches the architecture, the app
remains installed with the service disabled. For Russian LuCI, also install
`luci-i18n-base-ru`.

1. Open **LuCI → Services → XrayWRT → Subscription**, enter a JSON subscription
   URL and press **Connect**. Or enter a manual configuration under
   **Advanced → Xray configuration**.
2. Check **Home** and use **What goes via VPN** to set traffic mode and rules.
3. Use **Home** to start or stop the service and select a provider server when
   a selector is available. See the [user guide](docs/user-guide.md).

## Updates

Run the installer again to update app packages and an installed core package.
The core is not updated automatically: use **Updates → Update the core** or
`xraywrt core-update`. Subscription and remote-list updates are separate.
Check available flash and RAM before updating. A stopped service stays stopped.

## No access to GitHub

If `raw.githubusercontent.com` is blocked, the release-pinned installer mirror
may help. This is a **third-party** trust point: its script runs as root. It
mirrors neither packages nor the core.

```sh
wget -qO- https://cdn.jsdelivr.net/gh/sweep7125/xraywrt@v0.1.0/install.sh | sh
```

Alternatively, transfer release APKs from a trusted computer. Check app packages
against `SHA256SUMS` and the matching core APK against `SHA256SUMS-core` before
copying. Checksums verify integrity, not release authenticity; packages are not
signed. Install dependencies on the router:

```sh
apk update && apk add luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl ca-bundle
```

Then follow [local installation](docs/user-guide.md#install-from-local-files).
A custom `XRAYWRT_RELEASE_URL` package mirror is another trust point; plain HTTP
cannot protect its checksum file. It does not provide the core.

## If internet is lost

Open LuCI at the router address, go to **Services → XrayWRT → Home**, and press
**Stop**. Or connect by SSH and run:

```sh
service xraywrt stop
logread -e xraywrt
```

Stop removes XrayWRT DNS redirection and routing policy to restore direct access.
It lasts until reboot. Disable autostart in **Advanced → Service → Start on boot**
or run `service xraywrt disable`. This is not a kill switch.

## Remove

Run `XRAYWRT_ACTION=remove sh install.sh`, or remove installed packages:

```sh
apk del luci-i18n-xraywrt-ru luci-app-xraywrt xraywrt-core
```

Removal stops the service and clears its network policy. Configuration and list
files remain for reinstall; see the [guide](docs/user-guide.md#remove).

## Documentation

[User guide](docs/user-guide.md) · [Development](docs/development.md) ·
[Changelog](CHANGELOG.md) · [License](LICENSE)
