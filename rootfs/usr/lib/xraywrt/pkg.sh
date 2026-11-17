#!/bin/ash

# Package-manager adapter for apk (OpenWrt 25.12+).
# install.sh carries a verbatim copy of the functions both need (tests/test_pkg.sh checks parity).

# Read names directly: no package-manager process or per-package queries.
pkg_installed_names() {
	[ -f /lib/apk/db/installed ] || return 0
	awk '/^P:/ { print substr($0, 3) }' /lib/apk/db/installed
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

pkg_remove() {
	apk del "$@"
}

# pkg_file_installed_size <path>: installed-size of a package file's metadata.
pkg_file_installed_size() {
	apk adbdump "$1" 2>/dev/null | awk '$1 == "installed-size:" { print $2; exit }'
}

# Unpack only the payload for candidate tests, without installation or scripts.
pkg_file_extract() {
	apk extract --allow-untrusted --destination "$2" "$1"
}
