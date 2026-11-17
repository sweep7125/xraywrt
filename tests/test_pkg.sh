#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

# Package-manager adapter under BusyBox ash with an apk stub, plus
# byte parity between rootfs pkg.sh and the copy embedded in install.sh.

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/apk-bin"

for tool in ash awk grep cat echo; do
	ln -s "$(command -v busybox)" "$tmpdir/apk-bin/$tool" 2>/dev/null || true
done
cat >"$tmpdir/apk-bin/apk" <<'S'
#!/bin/ash
echo "apk $*" >>"$PKG_CALLS"
case "$*" in
'info -e present') exit 0 ;;
'info -e '*) exit 1 ;;
# apk-tools 3.0.5 (OpenWrt 25.12): `info -v <name>` prints the description, not <name>-<version>.
'info -v luci-app-xraywrt') printf 'luci-app-xraywrt: LuCI XrayWRT\nluci-app-xraywrt: \nluci-app-xraywrt: 1 MiB\n' ;;
'adbdump /tmp/a.apk') printf 'info:\n  name: xraywrt-core\n  installed-size: 34406524\n  file-size: 1\n' ;;
esac
S
chmod +x "$tmpdir/apk-bin/apk"

extract_function() { # extract_function <file> <name>
	awk -v n="$2" '$0 == n "() {" { f = 1 } f { print } f && $0 == "}" { exit }' "$1"
}

# Relocate the databases and run the real functions in BusyBox ash: pkg.sh plus
# the installer-only functions of install.sh.
{
	cat "$XRAYWRT_LIB_DIR/pkg.sh"
	for name in pkg_installed pkg_install pkg_update; do extract_function "$ROOT_DIR/install.sh" "$name"; done
} | sed "s|/lib/apk/db/installed|$tmpdir/apk-installed|g" >"$tmpdir/pkg.sh"

# pkg_run <bin dir> <command...>: BusyBox ash with only that stub on PATH.
export PKG_CALLS="$tmpdir/calls"
pkg_run() {
	local dir="$1"
	shift
	PATH="$tmpdir/$dir" ash -c ". '$tmpdir/pkg.sh'; \"\$@\"" pkg "$@"
}

: >"$PKG_CALLS"
pkg_run apk-bin pkg_installed present || fail "apk present"
if pkg_run apk-bin pkg_installed absent; then fail "apk absent"; fi
assert_eq $'apk info -e present\napk info -e absent' "$(cat "$PKG_CALLS")" "apk asks apk info -e"
pass "pkg_installed"

printf 'P:luci-app-xraywrt-extra\nV:9\n\nP:luci-app-xraywrt\nA:noarch\nV:0.10.0-r1\n\nP:other\nV:2\n' >"$tmpdir/apk-installed"
assert_eq 0.10.0-r1 "$(pkg_run apk-bin pkg_version luci-app-xraywrt)" "apk version from the database"
assert_eq "" "$(pkg_run apk-bin pkg_version absent)" "apk absent version"
rm "$tmpdir/apk-installed"
assert_eq "" "$(pkg_run apk-bin pkg_version luci-app-xraywrt)" "no database, no version"
pass "pkg_version"

assert_eq 34406524 "$(pkg_run apk-bin pkg_file_installed_size /tmp/a.apk)" "installed-size from apk adbdump"
pass "pkg_file_installed_size"

: >"$PKG_CALLS"
pkg_run apk-bin pkg_file_extract /tmp/a.apk /tmp/candidate
pkg_run apk-bin pkg_install_file /tmp/a.apk
pkg_run apk-bin pkg_install jq curl
pkg_run apk-bin pkg_remove i18n app
pkg_run apk-bin pkg_update
assert_eq "apk extract --allow-untrusted --destination /tmp/candidate /tmp/a.apk
apk add --allow-untrusted /tmp/a.apk
apk add jq curl
apk del i18n app
apk update" "$(cat "$PKG_CALLS")" "manager command lines"
pass "pkg_install_file pkg_install pkg_remove pkg_update"

# pkg_installed_names reads the apk database.
printf 'P:foo\nV:1\n\nP:bar\n' >"$tmpdir/apk-installed"
assert_eq $'foo\nbar' "$(pkg_run apk-bin pkg_installed_names)" "apk names"
rm "$tmpdir/apk-installed"
pass "pkg_installed_names"

# Parity: install.sh embeds each shared adapter function byte for byte; the
# runtime has no caller of the installer-only ones.
for name in pkg_installed pkg_install pkg_update; do
	[[ -z "$(extract_function "$XRAYWRT_LIB_DIR/pkg.sh" "$name")" ]] || fail "pkg.sh carries the uncalled $name"
	grep -rqE "\b$name\b" "$ROOT_DIR/rootfs" && fail "runtime calls $name" || :
done
for name in pkg_installed_names pkg_version pkg_install_file pkg_remove; do
	module_copy="$(extract_function "$XRAYWRT_LIB_DIR/pkg.sh" "$name")"
	[[ -n "$module_copy" ]] || fail "pkg.sh lacks $name"
	assert_eq "$module_copy" "$(extract_function "$ROOT_DIR/install.sh" "$name")" "install.sh copy of $name equals pkg.sh"
done
pass "installer adapter parity"

# Spec 3: conflicts; one list for status and preinst.
source "$XRAYWRT_LIB_DIR/constants.sh"
for package in luci-app-mihowrt xray-core luci-app-xray luci-app-passwall luci-app-passwall2; do
	case " $CONFLICT_PACKAGES " in *" $package "*) ;; *) fail "CONFLICT_PACKAGES lacks $package" ;; esac
done
assert_file_contains "$ROOT_DIR/Makefile" "XRAYWRT_CONFLICTS:=$CONFLICT_PACKAGES" 'Makefile carries the same conflict list'
pass 'conflict packages'
