#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XRAYWRT_LIB_DIR="${XRAYWRT_LIB_DIR:-$ROOT_DIR/rootfs/usr/lib/xraywrt}"
export XRAYWRT_LIB_DIR
export PATH="$ROOT_DIR/rootfs/usr/bin:$PATH"

XRAY_TEST_ASSETS="${XRAY_TEST_ASSETS:-/usr/local/share/xray-test}"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

pass() {
	printf 'ok - %s\n' "$*"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"

	[[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_true() {
	local message="$1"
	shift

	"$@" || fail "$message"
}

assert_false() {
	local message="$1"
	shift

	if "$@"; then
		fail "$message"
	fi
}

assert_file_contains() {
	local file="$1"
	local needle="$2"
	local message="$3"

	grep -qF -- "$needle" "$file" || fail "$message"
}

assert_file_not_contains() {
	local file="$1"
	local needle="$2"
	local message="$3"

	if grep -qF -- "$needle" "$file"; then
		fail "$message"
	fi
}

assert_symlink_target() {
	local path="$1"
	local expected="$2"
	local message="$3"
	local actual

	[[ -L "$path" ]] || fail "$message: '$path' not symlink"
	actual="$(readlink "$path")"
	[[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

# xray_test_bin <suite>: the pinned Go Xray of Dockerfile.test in
# XRAY_TEST_BIN. Missing binary: explicit skip line and return 1, or a
# failure with XRAY_TEST_REQUIRED=1. Usage: xray_test_bin 'suite' || exit 0
xray_test_bin() {
	XRAY_TEST_BIN="${XRAY_TEST_BIN:-/usr/local/bin/xray-test}"
	[ -x "$XRAY_TEST_BIN" ] && return 0
	[ "${XRAY_TEST_REQUIRED:-}" != 1 ] || fail "$1: xray test binary $XRAY_TEST_BIN missing"
	printf 'skip - %s (xray test binary %s missing; set XRAY_TEST_REQUIRED=1 to fail)\n' "$1" "$XRAY_TEST_BIN"
	return 1
}

make_temp_dir() {
	mktemp -d "${TMPDIR:-/tmp}/xraywrt-tests.XXXXXX"
}

source_install_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/install.sh"
	sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	trap - EXIT INT TERM HUP
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

strip_xraywrt_cli_bootstrap() {
	sed '/^check_required_file \/lib\/functions\.sh$/,/^unset XRAYWRT_HELPERS_AUTOLOAD$/d' \
		"$ROOT_DIR/rootfs/usr/bin/xraywrt"
}

source_xraywrt_cli_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/xraywrt.sh"
	strip_xraywrt_cli_bootstrap |
		sed '/^[[:space:]]*case "\$1" in$/,$d' >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

source_init_xraywrt_lib() {
	local fixture_path
	fixture_path="$(make_temp_dir)/init.sh"
	sed -e '1d' -e "s|/usr/lib/xraywrt/constants.sh|$XRAYWRT_LIB_DIR/constants.sh|g" "$ROOT_DIR/rootfs/etc/init.d/xraywrt" >"$fixture_path"
	# shellcheck disable=SC1090
	source "$fixture_path"
	rm -f "$fixture_path"
	rmdir "${fixture_path%/*}"
}

# Source runtime modules from the repository in the given order.
load_modules() {
	local module
	for module in "$@"; do
		# xray_config_test fetches geodata first (spec 10).
		# shellcheck disable=SC1090,SC1091
		[ "$module" != xray-config.sh ] || source "$XRAYWRT_LIB_DIR/geodata.sh"
		# shellcheck disable=SC1090
		source "$XRAYWRT_LIB_DIR/$module"
	done
}

# Fake uci/logger on PATH. Values live in $FAKE_UCI_DB as key=value lines.
setup_fake_uci() {
	local dir="$1"

	mkdir -p "$dir/bin"
	export FAKE_UCI_DB="$dir/uci.db"
	: >"$FAKE_UCI_DB"
	cat >"$dir/bin/uci" <<'UCI'
#!/usr/bin/env bash
while [ "${1:-}" = "-q" ] || [ "${1:-}" = "-X" ]; do shift; done
cmd="${1:-}"; shift || true
case "$cmd" in
get)
	awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); f = 1; exit } END { exit !f }' "$FAKE_UCI_DB"
	;;
set)
	key="${1%%=*}"
	awk -v k="$key=" 'index($0, k) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	printf '%s\n' "$1" >>"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
delete)
	# A section takes its options with it.
	awk -v k="$1=" -v o="$1." 'index($0, k) != 1 && index($0, o) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
show)
	grep "^${1:-}" "$FAKE_UCI_DB" || true
	;;
add_list)
	name="${1%%=*}"
	old="$(awk -v k="$name=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$FAKE_UCI_DB")"
	awk -v k="$name=" 'index($0, k) != 1' "$FAKE_UCI_DB" >"$FAKE_UCI_DB.tmp"
	echo "$name=${old:+$old }${1#*=}" >>"$FAKE_UCI_DB.tmp"
	mv "$FAKE_UCI_DB.tmp" "$FAKE_UCI_DB"
	;;
commit | revert) ;;
*) exit 1 ;;
esac
UCI
	cat >"$dir/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
exit 0
LOGGER
	printf '#!/bin/sh\nexit 0\n' >"$dir/bin/fw4"
	chmod +x "$dir/bin/uci" "$dir/bin/logger" "$dir/bin/fw4"
	export PATH="$dir/bin:$PATH"
}

# Hold a kernel flock independently of the implementation under test.
start_runtime_lock_holder() {
	local lock="$1" ready="$2" i

	rm -f "$ready"
	RUNTIME_LOCK_FILE="$lock" ash -c '
		exec 9>>"$RUNTIME_LOCK_FILE"
		busybox flock -n 9 || exit 1
		echo "$$" >"$RUNTIME_LOCK_FILE.owner"
		echo "$$" >"$1"
		exec sleep 300
	' ash "$ready" &
	LOCK_HOLDER_PID=$!
	for i in {1..100}; do
		[ ! -f "$ready" ] || return 0
		sleep 0.02
	done
	fail "runtime lock holder did not become ready"
}

# The active subscription as a UCI section (settings.subscription names it).
set_active_subscription() {
	local id="${2:-s1}"

	uci set "xraywrt.$id=subscription"
	uci set "xraywrt.$id.url=$1"
	uci set "xraywrt.settings.subscription=$id"
}

active_subscription_url() {
	subscription_option "$(uci_get subscription)" url
}

fake_uci_reset() {
	: >"$FAKE_UCI_DB"
}

fake_uci_set() {
	uci set "$1=$2"
}

# Keep provider profiles, check state and the fourth list inside each fixture.
# Runtime ash does not use nounset; initialize values read before settings_load.
setup_runtime_paths() {
	local dir="$1"

	XRAY_CONFIG="$dir/source.json"
	PROFILE_FILE="$dir/profile"
	XRAY_SHARE_DIR="$dir/share"
	XRAY_SUBS_DIR="$dir/subs"
	GEODATA_MANUAL_FILE="$XRAY_SHARE_DIR/.manual"
	GEODATA_TMP_DIR="$dir/tmp/geodata"
	# Fixtures reference geoip/geosite; fake cores never read the stubs.
	mkdir -p "$XRAY_SHARE_DIR"
	touch "$XRAY_SHARE_DIR/geoip.dat" "$XRAY_SHARE_DIR/geosite.dat"
	DIRECT_SRC_LIST_FILE="$dir/direct_src.txt"
	PKG_PERSIST_DIR="$dir/persist"
	PKG_TMP_DIR="$dir/tmp"
	PKG_STATE_DIR="$dir/run"
	HEALTH_FILE="$PKG_STATE_DIR/health"
	DEGRADED_FILE="$PKG_STATE_DIR/degraded"
	OBSERVATORY_FILE="$PKG_STATE_DIR/observatory"
	LAST_ERROR_FILE="$PKG_STATE_DIR/last_error"
	APPLY_WARNING_FILE="$PKG_STATE_DIR/apply_warning"
	CONFIG_INVALID_FILE="$PKG_STATE_DIR/config.invalid"
	CORE_VERSION_CACHE="$PKG_STATE_DIR/core.version"
	RUNNING_MARKER="$PKG_STATE_DIR/running"
	SERVICE_PID_FILE="$PKG_STATE_DIR/xray.pid"
	SUPERVISOR_PID_FILE="$PKG_STATE_DIR/supervisor.pid"
	RESTART_RESULT_FILE="$PKG_STATE_DIR/restart.result"
	USER_STOP_FILE="$PKG_STATE_DIR/stopped"
	CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
	CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
	CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
	NFT_APPLIED_FILE="$dir/nft.applied"
	FW4_INPUT_INCLUDE="$dir/fw4/30-xraywrt.nft"
	NET_FP_FILE="$PKG_STATE_DIR/net.fp"
	ROUTE_PROC_ROOT="$dir/proc"
	mkdir -p "$ROUTE_PROC_ROOT/net" "$ROUTE_PROC_ROOT/sys/net/ipv6/conf/"{all,lo}
	: >"$ROUTE_PROC_ROOT/net/if_inet6"
	printf '0\n' >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/all/disable_ipv6"
	printf '0\n' >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/lo/disable_ipv6"
	mkdir -p "$PKG_STATE_DIR" "$PKG_TMP_DIR" "$PKG_PERSIST_DIR"
}

# Evaluate package defines with GNU make, without loading the SDK build system.
package_makefile() {
	# Whitespace helpers normally supplied by the SDK's rules.mk.
	cat <<'EOF'
empty:=
space:= $(empty) $(empty)
define newline


endef
EOF
	sed -e '/^include /d' -e '/^$(eval $(call BuildPackage,/d' "$ROOT_DIR/Makefile"
}

render_package_define() {
	local name="$1" fixture_dir
	fixture_dir="$(make_temp_dir)"
	package_makefile >"$fixture_dir/package.mk"
	cat >>"$fixture_dir/package.mk" <<'EOF'
.PHONY: render
render:
	$(file >$(OUTPUT),$(Package/$(PKG_NAME)/$(DEFINE)))
	@:
EOF
	make -s -f "$fixture_dir/package.mk" render DEFINE="$name" OUTPUT="$fixture_dir/output"
	cat "$fixture_dir/output"
	rm -rf "$fixture_dir"
}
