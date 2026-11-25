#!/bin/sh
# XrayWRT installer: installs or updates the LuCI package (and the optional
# Russian translation) with apk (OpenWrt 25.12+), and uses
# /usr/bin/xraywrt to install or update the core from its release repository
# (spec 4.5). SHA256SUMS comes only from github.com (or
# XRAYWRT_RELEASE_URL); packages from github.com, then the GitHub proxies.
# Non-interactive: XRAYWRT_ACTION=install|remove XRAYWRT_LANGUAGE=en|ru
set -eu

REPO="sweep7125/xraywrt"
RELEASE_URL="${XRAYWRT_RELEASE_URL:-https://github.com/$REPO/releases/latest/download}"
# GITHUB_PROXIES of constants.sh (spec 4.1): package bodies only, never
# SHA256SUMS; not for an XRAYWRT_RELEASE_URL mirror.
GITHUB_PROXIES="gh-proxy.com ghproxy.net"
[ -z "${XRAYWRT_RELEASE_URL:-}" ] || GITHUB_PROXIES=""
PKG="luci-app-xraywrt"
I18N_PKG="luci-i18n-xraywrt-ru"
CORE_PKG="xraywrt-core"
DEPS="luci-base cgi-io nftables ucode ucode-mod-fs kmod-nft-tproxy curl ca-bundle"
CORE="/opt/xraywrt/bin/xray"
XRAYWRT_BIN="/usr/bin/xraywrt"
FW4_BIN="/sbin/fw4"
WORK=""
EXT="apk"

log() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}

cleanup() {
	[ -z "$WORK" ] || rm -rf "$WORK"
}

can_prompt() {
	[ -c /dev/tty ] && ( : </dev/tty ) 2>/dev/null
}

# ask <question> <option1> <option2>: prints 1 or 2 (default 1).
ask() {
	local answer=""

	printf '%s\n1. %s (default)\n2. %s\n' "$1" "$2" "$3" >/dev/tty
	while :; do
		printf 'Choose [1-2]: ' >/dev/tty
		IFS= read -r answer </dev/tty || return 1
		case "$answer" in
		'' | 1) echo 1; return 0 ;;
		2) echo 2; return 0 ;;
		esac
	done
}

# Shared functions are verbatim copies of rootfs/usr/lib/xraywrt/pkg.sh (tests/test_pkg.sh checks parity);
# pkg_installed, pkg_install and pkg_update are the installer's own.
# Read names directly: no package-manager process or per-package queries.
pkg_installed_names() {
	[ -f /lib/apk/db/installed ] || return 0
	awk '/^P:/ { print substr($0, 3) }' /lib/apk/db/installed
}

# pkg_installed <name>: apk also resolves virtual names.
pkg_installed() {
	apk info -e "$1" >/dev/null 2>&1
}

# pkg_version <name>: installed "<version>-<release>", empty when not installed.
# From the database: apk 3 `info -v <name>` prints the description instead.
pkg_version() {
	[ -f /lib/apk/db/installed ] || return 0
	awk -v p="P:$1" '$0 == p { f = 1 } f && /^V:/ { print substr($0, 3); exit } /^$/ { f = 0 }' /lib/apk/db/installed
}

# pkg_install_file <path>: a downloaded package file (apk needs --allow-untrusted).
pkg_install_file() {
	apk add --allow-untrusted "$1"
}

# pkg_install <name>...: packages from the configured feeds.
pkg_install() {
	apk add "$@"
}

pkg_remove() {
	apk del "$@"
}

pkg_update() {
	apk update
}

# dep_installed <name>: nftables is satisfied by either variant.
dep_installed() {
	case "$1" in
	nftables) pkg_installed nftables || pkg_installed nftables-json || pkg_installed nftables-nojson ;;
	*) pkg_installed "$1" ;;
	esac
}

# check_platform: only OpenWrt 25.12+ (apk) with fw4/nftables is supported.
check_platform() {
	command -v apk >/dev/null 2>&1 ||
		die "this installer needs OpenWrt 25.12 or newer (apk); OpenWrt 24.10 (opkg) is not supported"
	[ -x "$FW4_BIN" ] || die "this installer needs OpenWrt 25.12 or newer with firewall4 (fw4 and nftables)"
}

resolve_action() {
	local choice=""

	case "${XRAYWRT_ACTION:-}" in
	install | update | package) echo install ;;
	remove | uninstall) echo remove ;;
	'')
		can_prompt || die "no terminal: set XRAYWRT_ACTION=install or remove"
		choice="$(ask "XrayWRT installer" "Install or update" "Remove XrayWRT and the Xray core")" || die "cancelled"
		case "$choice" in
		1) echo install ;;
		2) echo remove ;;
		*) die "cancelled" ;;
		esac
		;;
	*) die "invalid XRAYWRT_ACTION: $XRAYWRT_ACTION" ;;
	esac
}

# Updates keep the current language unless XRAYWRT_LANGUAGE says otherwise.
resolve_language() {
	case "${XRAYWRT_LANGUAGE:-}" in
	en | EN) echo en; return 0 ;;
	ru | RU) echo ru; return 0 ;;
	'') ;;
	*) die "invalid XRAYWRT_LANGUAGE: $XRAYWRT_LANGUAGE" ;;
	esac
	if pkg_installed "$PKG"; then
		pkg_installed "$I18N_PKG" && echo ru || echo en
	elif can_prompt; then
		[ "$(ask "Choose language / Выберите язык" "English" "Русский")" = 2 ] && echo ru || echo en
	else
		echo en
	fi
}

free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Package reserve only; core-update checks the flash for the core itself.
check_space() {
	local need=2048 free=""

	mkdir -p /opt/xraywrt
	free="$(free_kb /opt/xraywrt)"
	[ -n "$free" ] || return 0
	[ "$free" -ge "$need" ] ||
		die "not enough flash: need $((need / 1024)) MiB, free $((free / 1024)) MiB"
}

# download_file <name> <out> [url]: fixed-name release asset.
download_file() {
	local name="$1" out="$2" url="${3:-$RELEASE_URL/$1}"

	# Keep explicit non-HTTPS mirrors usable (for example local file:// assets).
	set --
	case "$RELEASE_URL" in
	https://*) set -- --proto =https --proto-redir =https ;;
	http://*) warn "XRAYWRT_RELEASE_URL uses plain HTTP; downloads and checksums are unauthenticated" ;;
	esac
	curl -fsSL "$@" --retry 3 --connect-timeout 15 --max-time 300 -o "$out" "$url"
}

# fetch_asset <name> <out>: the release asset from RELEASE_URL, then via each
# GitHub proxy; every body must match the SHA256SUMS line for <name>
# ("<hash>  <name>"). A missing entry, or only mismatching bodies, abort;
# returns 1 when no route served the file.
fetch_asset() {
	local name="$1" out="$2" url="$RELEASE_URL/$1" proxy="" want="" bad=0

	for proxy in "" $GITHUB_PROXIES; do
		[ -z "$proxy" ] || url="https://$proxy/$RELEASE_URL/$name"
		download_file "$name" "$out" "$url" || continue
		want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$WORK/SHA256SUMS")"
		[ -n "$want" ] || die "no checksum for $name"
		if [ "$(sha256sum "$out" | awk '{ print $1 }')" = "$want" ]; then
			[ -z "$proxy" ] || log "Downloaded $name via $proxy"
			return 0
		fi
		rm -f "$out"
		bad=1
		warn "sha256 mismatch for $name from ${proxy:-${RELEASE_URL%%/releases/*}}"
	done
	[ "$bad" = 0 ] || die "sha256 mismatch for $name"
	return 1
}

# release_version: <version>-<release> from the versioned app package line of
# SHA256SUMS whose hash equals the hash of the fixed-name app package
# (luci-app-xraywrt-<ver>.apk).
release_version() {
	local hash="" name=""

	hash="$(awk -v n="$PKG.$EXT" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$WORK/SHA256SUMS")"
	[ -n "$hash" ] || return 0
	name="$(awk -v p="$PKG" -v fixed="$PKG.$EXT" -v e=".$EXT" -v h="$hash" '{ f = $2; sub(/^\*/, "", f) } $1 == h && f != fixed && index(f, p) == 1 && substr(f, length(f) - length(e) + 1) == e { print f; exit }' "$WORK/SHA256SUMS")"
	name="${name#"$PKG"}"
	name="${name#[-_]}"
	name="${name%.apk}"
	echo "$name"
}

install_packages() {
	local lang="$1" version="" with_ru=0 dep="" missing=""

	for dep in $DEPS; do
		dep_installed "$dep" || missing="${missing:+$missing }$dep"
	done
	if [ -n "$missing" ]; then
		log "Installing dependencies..."
		pkg_update >/dev/null || die "apk update failed"
		# shellcheck disable=SC2086
		pkg_install $missing >/dev/null || die "cannot install dependencies: $missing"
	fi
	check_space

	log "Downloading the latest XrayWRT release..."
	download_file SHA256SUMS "$WORK/SHA256SUMS" || die "cannot download the release checksums"
	fetch_asset "$PKG.$EXT" "$WORK/$PKG.$EXT" || die "cannot download $PKG.$EXT"
	if [ "$lang" = ru ]; then
		if fetch_asset "$I18N_PKG.$EXT" "$WORK/$I18N_PKG.$EXT"; then
			with_ru=1
		else
			warn "release has no Russian translation package"
		fi
	fi

	version="$(release_version)"
	log "Installing ${version:-the latest release}..."
	pkg_install_file "$WORK/$PKG.$EXT" >/dev/null || die "package installation failed"
	if [ "$with_ru" = 1 ]; then
		pkg_install_file "$WORK/$I18N_PKG.$EXT" >/dev/null || err "Russian translation failed to install"
	elif [ "$lang" != ru ] && pkg_installed "$I18N_PKG"; then
		pkg_remove "$I18N_PKG" >/dev/null || true
	fi
}

core_compatible() {
	local version="" comparison=""
	version="$(pkg_version "$CORE_PKG")"
	[ -n "$version" ] && comparison="$(apk version -t "$version" 0.27.1-r1)" || return 1
	case "$comparison" in '=' | '>') return 0 ;; *) return 1 ;; esac
}

# Verify both features required by the app for manually installed cores.
core_binary_compatible() {
	"$CORE" run -test -c stdin: >/dev/null 2>&1 <<'EOF'
{"api":{"tag":"api","listen":"/var/run/xraywrt/api.sock,0600","services":["HandlerService"]},"outbounds":[{"protocol":"dns","settings":{"rules":[{"action":"resolve"}]}}]}
EOF
}

do_install() {
	local lang="" fresh=1 result="" reason="" before="" after="" core_updated=0

	lang="$(resolve_language)"
	if pkg_installed "$PKG"; then
		fresh=0
		before="$(pkg_version "$PKG")"
	fi
	WORK="$(mktemp -d /tmp/xraywrt-install.XXXXXX)" || die "cannot create a temporary directory"
	if [ -x "$CORE" ] && ! pkg_installed "$CORE_PKG" && ! core_binary_compatible; then
		die "A compatible XrayWRT core 0.27.1 or newer is required; XrayWRT was not updated"
	fi
	# Keep the running service on the old app until its managed core can be updated.
	if [ "$fresh" = 0 ] && pkg_installed "$CORE_PKG"; then
		if [ -x "$XRAYWRT_BIN" ]; then
			log "Updating the Xray core..."
			"$XRAYWRT_BIN" core-update >/dev/null ||
				die "Xray core update failed; XrayWRT was not updated"
			core_updated=1
		fi
		core_compatible || die "Xray core 0.27.1-r1 or newer is required; XrayWRT was not updated"
	fi
	install_packages "$lang"

	# The default core source is the core package: install it, or update it.
	if [ ! -x "$CORE" ] || { [ "$core_updated" = 0 ] && pkg_installed "$CORE_PKG"; }; then
		log "Installing the Xray core..."
		# stdout is the JSON; the backend's own "Error: ..." line stays on stderr.
		result="$("$XRAYWRT_BIN" core-update)" || {
			reason="$(printf '%s' "$result" | xraywrt-json get error empty 2>/dev/null)" || reason=""
			case "$reason" in
			*"[E:core_arch|"* | *" has no releases "*)
				# Spec 12: the package stays, the service stays disabled.
				log ""
				log "XrayWRT is installed, but the core is not available for this router."
				log "No alternate core is supported. Install a trusted xraywrt-core package for this architecture with: apk add --allow-untrusted xraywrt-core_*.apk, then enable the service."
				return 0
				;;
			esac
			die "Xray core installation failed${reason:+: $reason}; retry from LuCI → Services → XrayWRT"
		}
	fi
	if pkg_installed "$CORE_PKG" && ! core_compatible; then
		die "XrayWRT is installed, but Xray core 0.27.1-r1 or newer is required; the service was not enabled"
	fi
	log ""
	if [ "$fresh" = 1 ]; then
		/etc/init.d/xraywrt enable
		log "XrayWRT is installed. Open LuCI → Services → XrayWRT and connect your subscription."
	else
		after="$(pkg_version "$PKG")"
		if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
			log "XrayWRT is updated."
		else
			log "XrayWRT is reinstalled (version unchanged)."
		fi
	fi
}

do_remove() {
	local removed=0

	log "Removing XrayWRT..."
	if pkg_installed "$I18N_PKG"; then
		pkg_remove "$I18N_PKG" >/dev/null
		removed=1
	fi
	if pkg_installed "$PKG"; then
		pkg_remove "$PKG" >/dev/null
		removed=1
	fi
	# After the app: its prerm stops the service that runs this core.
	if pkg_installed "$CORE_PKG"; then
		pkg_remove "$CORE_PKG" >/dev/null
		removed=1
	fi
	if [ "$removed" = 1 ]; then
		log "XrayWRT and the Xray core are removed. Your configs stay in /opt/xraywrt."
	else
		log "XrayWRT is not installed."
	fi
}

main() {
	local action=""

	check_platform
	trap cleanup EXIT
	action="$(resolve_action)" || exit 1
	case "$action" in
	install) do_install ;;
	remove) do_remove ;;
	esac
}

main "$@"
