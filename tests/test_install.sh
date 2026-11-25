#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

# A failed /dev/tty open must not terminate non-interactive BusyBox ash.
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$tmpdir/install-lib.sh"
cat >>"$tmpdir/install-lib.sh" <<'S'
can_prompt || echo no-terminal
echo after-prompt
S
out="$(setsid ash "$tmpdir/install-lib.sh" </dev/null 2>&1)" || fail "can_prompt aborted ash: $out"
assert_eq $'no-terminal\nafter-prompt' "$out" "ash survives absent controlling tty"
pass "can_prompt without tty"

set +u
source_install_lib
set -u
pkg_installed_orig="$(declare -f pkg_installed)"
can_prompt() { return 1; }

installed=""
pkg_installed() { [[ " $installed " == *" $1 "* ]]; }

assert_eq install "$(XRAYWRT_ACTION=update resolve_action)" "update is install"
assert_eq remove "$(XRAYWRT_ACTION=uninstall resolve_action)" "uninstall is remove"
if (XRAYWRT_ACTION=bogus resolve_action) >/dev/null 2>&1; then fail "invalid action must fail"; fi
if (resolve_action) >/dev/null 2>&1; then fail "no tty and no action must fail"; fi
pass "action selection"

# EOF at the menu cancels; it must not pick "remove".
can_prompt() { return 0; }
ask() { return 1; }
if (resolve_action) >/dev/null 2>&1; then fail "EOF at the menu must cancel"; fi
ask() { echo 2; }
assert_eq remove "$(resolve_action)" "menu choice 2 is remove"
ask() { echo 1; }
assert_eq install "$(resolve_action)" "menu choice 1 is install"
can_prompt() { return 1; }
pass "menu cancel on EOF"

assert_eq en "$(resolve_language)" "fresh non-interactive install is English"
installed="luci-app-xraywrt luci-i18n-xraywrt-ru"
assert_eq ru "$(resolve_language)" "update keeps Russian"
installed="luci-app-xraywrt"
assert_eq en "$(resolve_language)" "update keeps English"
assert_eq ru "$(XRAYWRT_LANGUAGE=RU resolve_language)" "explicit language wins"
if (XRAYWRT_LANGUAGE=de resolve_language) >/dev/null 2>&1; then fail "unsupported language must fail"; fi
pass "language preserved"

CORE="$tmpdir/xray"
free_kb() { echo 3072; }
# polish: no core space reserve
(
 set -e
 (check_space) >/dev/null 2>&1 || fail 'no core space reserve: 3 MiB must suffice without a core'
 assert_eq 0 "$(grep -c CORE_SPACE_KB "$ROOT_DIR/install.sh" || true)" 'no CORE_SPACE_KB reserve remains'
)
# Keep the removal no-regression fixture executable.
touch "$CORE"
chmod +x "$CORE"
pass 'no core space reserve'

calls="$tmpdir/calls"
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$calls" >"$tmpdir/bin/apk"
chmod +x "$tmpdir/bin/apk"
PATH="$tmpdir/bin:$PATH"
FW4_BIN="$tmpdir/fw4"
touch "$FW4_BIN"
chmod +x "$FW4_BIN"
installed="luci-app-xraywrt luci-i18n-xraywrt-ru"
(XRAYWRT_ACTION=remove main) >/dev/null
assert_eq $'apk del luci-i18n-xraywrt-ru\napk del luci-app-xraywrt' "$(cat "$calls")" "translation removed before the app"
[[ -e "$CORE" ]] || fail "installer must leave core cleanup to prerm"
# Spec 4.5: the core package goes after the app (its prerm stops the service).
installed="luci-app-xraywrt luci-i18n-xraywrt-ru xraywrt-core"
: >"$calls"
(XRAYWRT_ACTION=remove main) >/dev/null
assert_eq $'apk del luci-i18n-xraywrt-ru\napk del luci-app-xraywrt\napk del xraywrt-core' "$(cat "$calls")" "core package removed last"
pass "remove"

installed=""
: >"$calls"
out="$(do_remove)"
[[ "$out" == *"XrayWRT is not installed."* ]] || fail "absent removal must report not installed: $out"
[[ ! -s "$calls" ]] || fail "absent removal must not delete packages"
pass "remove absent package"

# Installer: fixed asset names from releases/latest, verified by SHA256SUMS.
BASE="https://github.com/sweep7125/xraywrt/releases/latest/download"
check_space() { :; }
apk_log="$tmpdir/apk.log"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$apk_log" >"$tmpdir/bin/apk"
installed=""
fake_release() { # fake_release <sums-mode: ok|bad|missing|404>
	SUMS_MODE="$1"
	RU_MODE="${2:-ok}"
	rm -f "$tmpdir/downloads" "$apk_log"
	WORK="$tmpdir/work.$RANDOM"
	mkdir -p "$WORK"
}
curl() {
	local out="" prev="" a url=""
	for a in "$@"; do
		[ "$prev" = "-o" ] && out="$a"
		prev="$a"
		url="$a"
	done
	echo "$url" >>"$tmpdir/downloads"
	# Route modes (ok|down|nopkg|bad): GH_MODE for the release URL, P1_MODE/P2_MODE
	# for the proxies; nopkg fails only the packages.
	case "$url" in
	https://gh-proxy.com/*) mode="${P1_MODE:-ok}" ;;
	https://ghproxy.net/*) mode="${P2_MODE:-ok}" ;;
	*) mode="${GH_MODE:-ok}" ;;
	esac
	case "$mode:$url" in
	down:* | nopkg:*.apk) return 7 ;;
	bad:*.apk) printf 'evil' >"$out"; return 0 ;;
	esac
	case "$url" in
	*/SHA256SUMS)
		[ "$SUMS_MODE" = 404 ] && return 22
		app="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
		ru="$(printf 'ru-bytes' | sha256sum | cut -d' ' -f1)"
		[ "$RU_MODE" = bad ] && ru="$(printf 'ru-byteX' | sha256sum | cut -d' ' -f1)"
		[ "$SUMS_MODE" = bad ] && app="$(printf 'app-byteX' | sha256sum | cut -d' ' -f1)"
		{
			[ "$SUMS_MODE" = missing ] || printf '%s  luci-app-xraywrt-0.10.0-r1.apk\n%s  luci-app-xraywrt.apk\n' "$app" "$app"
			[ "$RU_MODE" = missing ] || printf '%s  luci-i18n-xraywrt-ru-0.10.0-r1.apk\n%s  luci-i18n-xraywrt-ru.apk\n' "$ru" "$ru"
		} >"$out"
		;;
	*/luci-app-xraywrt.apk) printf 'app-bytes' >"$out" ;;
	*/luci-i18n-xraywrt-ru.apk)
		[ "$RU_MODE" = 404 ] && return 22
		printf 'ru-bytes' >"$out"
		;;
	*) return 22 ;;
	esac
}

fake_release ok
out="$(install_packages ru 2>&1)" || fail "install_packages must succeed: $out"
assert_eq "$BASE/SHA256SUMS
$BASE/luci-app-xraywrt.apk
$BASE/luci-i18n-xraywrt-ru.apk" "$(cat "$tmpdir/downloads")" "only fixed release URLs"
if grep -q 'api.github.com\|-r1.apk' "$tmpdir/downloads"; then fail "no API or -r1 URLs"; fi
pass "urls"

# Dependency probes use the manager; update/add only when a dependency is absent.
(
 eval "$pkg_installed_orig"
 apk() {
  echo "apk $*" >>"$apk_log"
  if [ "$1" = info ]; then [[ " $present_deps " == *" $3 "* ]]; fi
 }
 present_deps="$DEPS"
 fake_release ok
 install_packages en >/dev/null
 if grep -qE '^apk (update|add [^-])' "$apk_log"; then fail "present dependencies must not be updated or added"; fi
 for dep in $DEPS; do
  assert_file_contains "$apk_log" "apk info -e $dep" "dependency checked: $dep"
 done
 present_deps="luci-base nftables kmod-nft-tproxy"
 fake_release ok
 install_packages en >/dev/null
 assert_eq 1 "$(grep -c '^apk update$' "$apk_log")" "update once for missing deps"
 assert_file_contains "$apk_log" "apk add cgi-io ucode ucode-mod-fs curl" "only missing deps installed"
)
pass "missing dependencies only"

# HTTPS assets cannot redirect to an insecure protocol; file mirrors still work.
(
 curl() { printf '%s\n' "$@" >"$tmpdir/curl.args"; }
 download_file SHA256SUMS "$tmpdir/sums"
 assert_file_contains "$tmpdir/curl.args" '--proto' "HTTPS protocol restricted"
 assert_file_contains "$tmpdir/curl.args" '--proto-redir' "HTTPS redirects restricted"
 assert_eq 2 "$(grep -c '^=https$' "$tmpdir/curl.args")" "HTTPS only for request and redirects"
 RELEASE_URL=http://mirror
 download_file SHA256SUMS "$tmpdir/sums" >"$tmpdir/http.out" 2>"$tmpdir/http.err"
 assert_file_contains "$tmpdir/http.err" 'Warning: XRAYWRT_RELEASE_URL uses plain HTTP' 'plain HTTP mirror warning on stderr'
 assert_eq '' "$(cat "$tmpdir/http.out")" 'HTTP warning never goes to stdout'
 RELEASE_URL=file:///mirror
 download_file SHA256SUMS "$tmpdir/sums" 2>"$tmpdir/file.err"
 assert_eq '' "$(cat "$tmpdir/file.err")" 'local mirror needs no warning'
 assert_file_not_contains "$tmpdir/curl.args" '--proto' "file mirror allowed"
)
assert_file_contains "$ROOT_DIR/README.md" 'xraywrt@v0.1.0/install.sh' "mirror pinned to release tag"
assert_file_contains "$ROOT_DIR/README.md" 'third-party' "mirror trust risk documented"
pass "release transport restrictions"

# The release base override covers checksums and both APKs.
fake_release ok
out="$(XRAYWRT_RELEASE_URL=file:///mirror source_install_lib; install_packages ru 2>&1)" || fail "mirror install failed: $out"
assert_eq $'file:///mirror/SHA256SUMS\nfile:///mirror/luci-app-xraywrt.apk\nfile:///mirror/luci-i18n-xraywrt-ru.apk' "$(cat "$tmpdir/downloads")" "release URL override covers all assets"
pass "release URL override"

# Spec 4.1/12: packages from github.com, then each GitHub proxy, every body
# checked against SHA256SUMS; SHA256SUMS itself never through a proxy.
assert_eq "$(sed -n 's/^GITHUB_PROXIES="\(.*\)"$/\1/p' "$ROOT_DIR/rootfs/usr/lib/xraywrt/constants.sh")" "$GITHUB_PROXIES" 'installer proxies = constants.sh'
fake_release ok
out="$(GH_MODE=nopkg P1_MODE=bad install_packages ru 2>&1)" || fail "proxy fallback install failed: $out"
assert_eq "$BASE/SHA256SUMS
$BASE/luci-app-xraywrt.apk
https://gh-proxy.com/$BASE/luci-app-xraywrt.apk
https://ghproxy.net/$BASE/luci-app-xraywrt.apk
$BASE/luci-i18n-xraywrt-ru.apk
https://gh-proxy.com/$BASE/luci-i18n-xraywrt-ru.apk
https://ghproxy.net/$BASE/luci-i18n-xraywrt-ru.apk" "$(cat "$tmpdir/downloads")" "github.com, then each proxy"
[[ "$out" == *"sha256 mismatch for luci-app-xraywrt.apk from gh-proxy.com"* ]] || fail "bad proxy body rejected: $out"
[[ "$out" == *"Downloaded luci-app-xraywrt.apk via ghproxy.net"* ]] || fail "working route named: $out"
assert_file_contains "$apk_log" "apk add --allow-untrusted $WORK/luci-app-xraywrt.apk" "verified proxy body installed"
assert_eq app-bytes "$(cat "$WORK/luci-app-xraywrt.apk")" "the verified body, not the proxy's bad one"
fake_release ok
out="$( (GH_MODE=down install_packages en) 2>&1)" && fail "no SHA256SUMS from github.com must abort"
[[ "$out" == *"cannot download the release checksums"* ]] || fail "checksums message: $out"
assert_eq "$BASE/SHA256SUMS" "$(cat "$tmpdir/downloads")" "SHA256SUMS never through a proxy"
fake_release ok
out="$( (P1_MODE=bad P2_MODE=bad GH_MODE=bad install_packages en) 2>&1)" && fail "bad bodies on every route must abort"
[[ "$out" == *"sha256 mismatch for luci-app-xraywrt.apk"* ]] || fail "all bad message: $out"
assert_eq 3 "$(grep -c 'luci-app-xraywrt.apk$' "$tmpdir/downloads")" "every route tried"
if grep -q 'allow-untrusted' "$apk_log"; then fail "nothing installed after bad bodies"; fi
fake_release ok
out="$(XRAYWRT_RELEASE_URL=file:///mirror source_install_lib; GH_MODE=bad install_packages en 2>&1)" && fail "bad mirror body must abort"
assert_eq $'file:///mirror/SHA256SUMS\nfile:///mirror/luci-app-xraywrt.apk' "$(cat "$tmpdir/downloads")" "no proxy for an XRAYWRT_RELEASE_URL mirror"
pass "packages: github.com, then proxies, each verified"

# Restore the default release fixture for the version assertion below.
fake_release ok
out="$(install_packages ru 2>&1)" || fail "install_packages must succeed: $out"

assert_file_contains "$apk_log" "apk add --allow-untrusted $WORK/luci-app-xraywrt.apk" "matching sums install the app"
[[ "$out" == *"Installing 0.10.0-r1..."* ]] || fail "version from SHA256SUMS: $out"
pass "version message"

fake_release bad
out="$( (install_packages en) 2>&1)" && fail "mismatch must abort"
[[ "$out" == *"sha256 mismatch for luci-app-xraywrt.apk"* ]] || fail "mismatch message: $out"
if grep -q 'allow-untrusted' "$apk_log"; then fail "no apk add after mismatch"; fi
fake_release missing
out="$( (install_packages en) 2>&1)" && fail "missing entry must abort"
[[ "$out" == *"no checksum for luci-app-xraywrt.apk"* ]] || fail "missing message: $out"
if grep -q 'allow-untrusted' "$apk_log"; then fail "no apk add without checksum"; fi
fake_release 404
out="$( (install_packages en) 2>&1)" && fail "404 must abort"
[[ "$out" == *"cannot download the release checksums"* ]] || fail "404 message: $out"
pass "checksum"

# Every chosen APK is verified before anything is installed.
for mode in bad missing; do
	fake_release ok "$mode"
	out="$( (install_packages ru) 2>&1)" && fail "ru $mode must abort"
	[[ "$out" == *"luci-i18n-xraywrt-ru.apk"* ]] || fail "ru $mode message: $out"
	if grep -q 'allow-untrusted' "$apk_log"; then fail "ru $mode: nothing may be installed"; fi
done
fake_release ok 404
out="$(install_packages ru 2>&1)" || fail "ru 404 stays a soft failure: $out"
[[ "$out" == *"Russian translation"* ]] || fail "ru 404 warning: $out"
assert_file_contains "$apk_log" "luci-app-xraywrt.apk" "app installed without ru"
if grep -q 'luci-i18n-xraywrt-ru.apk' "$apk_log"; then fail "ru 404: no ru install"; fi
pass "all apks verified before install"

# Version comes from the line whose hash equals the app APK hash.
fake_release ok
curl_orig="$(declare -f curl)"
sums_other="$(printf 'other' | sha256sum | cut -d' ' -f1)"
app_h="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
curl() {
	local out="" prev="" a
	for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
	case "$a" in
	*/SHA256SUMS) printf '%s  luci-app-xraywrt-9.9.9-r9.apk\n%s *luci-app-xraywrt-0.10.0-r2.apk\n%s  luci-app-xraywrt.apk\n' "$sums_other" "$app_h" "$app_h" >"$out" ;;
	*/luci-app-xraywrt.apk) printf 'app-bytes' >"$out" ;;
	*) return 22 ;;
	esac
}
out="$(install_packages en 2>&1)" || fail "install must succeed: $out"
[[ "$out" == *"Installing 0.10.0-r2..."* ]] || fail "version by hash: $out"
eval "$curl_orig"
pass "version by hash"

# A failed core-update shows the backend error.
CORE="$tmpdir/absent-core"
XRAYWRT_BIN="$tmpdir/xraywrt-stub"
cat >"$XRAYWRT_BIN" <<'S'
#!/bin/sh
echo 'Error: Core update: not enough flash: need 62 MiB, free 40 MiB' >&2
echo '{"updated":false,"error":"not enough flash: need 62 MiB, free 40 MiB"}'
exit 1
S
chmod +x "$XRAYWRT_BIN"
install_packages() { :; }
resolve_language() { echo en; }
out="$( (XRAYWRT_ACTION=install do_install) 2>&1 >/dev/null)" && fail "core-update failure must abort"
[[ "$out" == *"not enough flash: need 62 MiB, free 40 MiB"* ]] || fail "core error shown: $out"
[[ "$out" == *"Xray core installation failed"* ]] || fail "failure message: $out"
printf '#!/bin/sh\necho "Error: boom" >&2\nexit 1\n' >"$XRAYWRT_BIN"
out="$( (XRAYWRT_ACTION=install do_install) 2>&1 >/dev/null)" && fail "no-JSON failure must abort"
[[ "$out" == *"Xray core installation failed"* ]] || fail "generic failure message: $out"
pass "core error shown"

# Exercise successful installs with only the init-script path relocated.
(
 sed -e '/^main "\$@"$/d' -e "s|/etc/init.d/xraywrt|$tmpdir/init-xraywrt|g" "$ROOT_DIR/install.sh" >"$tmpdir/install-success.sh"
 source "$tmpdir/install-success.sh"
 CORE="$tmpdir/existing-core"
 printf '#!/bin/sh\n[ "$*" = "run -test -c stdin:" ] || exit 1\ngrep -q "api.sock,0600.*resolve"\n' >"$CORE"
 apk() { echo "="; }
 chmod +x "$CORE"
 printf '#!/bin/sh\necho "$*" >>"%s"\n' "$tmpdir/init.calls" >"$tmpdir/init-xraywrt"
 chmod +x "$tmpdir/init-xraywrt"
 resolve_language() { echo en; }
 pkg_installed() { [ "$1" = "$PKG" ] && [ "$fresh_case" = 0 ]; }
 pkg_version() { cat "$tmpdir/installed.version"; }
 install_packages() { echo "$next_version" >"$tmpdir/installed.version"; }
 for fresh_case in 1 0; do
  for old_version in 0.9.0-r1 0.10.0-r1; do
   next_version=0.10.0-r1
   echo "$old_version" >"$tmpdir/installed.version"
   : >"$tmpdir/init.calls"
   out="$(do_install)"
   if [ "$fresh_case" = 1 ]; then
    assert_eq enable "$(cat "$tmpdir/init.calls")" "fresh install enables service"
    [[ "$out" == *"XrayWRT is installed."* ]] || fail "fresh install message: $out"
   else
    [[ ! -s "$tmpdir/init.calls" ]] || fail "existing install must preserve autostart preference"
    if [ "$old_version" = "$next_version" ]; then
     [[ "$out" == *"XrayWRT is reinstalled (version unchanged)."* ]] || fail "same version message: $out"
    else
     [[ "$out" == *"XrayWRT is updated."* ]] || fail "changed version message: $out"
    fi
   fi
  done
 done
)
pass "install preserves autostart and reports version changes"

# Spec 4.3: no release or no asset for this router: the package stays,
# the service stays disabled, the user gets the apk add instruction.
(
 sed -e '/^main "\$@"$/d' -e "s|/etc/init.d/xraywrt|$tmpdir/init-xraywrt|g" "$ROOT_DIR/install.sh" >"$tmpdir/install-noasset.sh"
 source "$tmpdir/install-noasset.sh"
 CORE="$tmpdir/absent-core"
 XRAYWRT_BIN="$tmpdir/xraywrt-noasset"
 printf '#!/bin/sh
echo "$*" >>"%s"
' "$tmpdir/init.calls" >"$tmpdir/init-xraywrt"
 chmod +x "$tmpdir/init-xraywrt"
 resolve_language() { echo en; }
 pkg_installed() { return 1; }
 install_packages() { :; }
 for e in 'The core is not available for this router (mipsel_24kc); the current core is kept. [E:core_arch|mipsel_24kc]' 'release sweep7125/xraywrt has no releases (GitHub API: http_404)'; do
  printf '#!/bin/sh\necho "Error: Core update: %s" >&2\necho %s\nexit 1\n' "$e" "'{\"updated\":false,\"error\":\"$e\"}'" >"$XRAYWRT_BIN"
  chmod +x "$XRAYWRT_BIN"
  : >"$tmpdir/init.calls"
  out="$(do_install 2>&1)" || fail "no asset must not fail the install: $out"
  [[ "$out" == *"$e"* ]] || fail "reason shown: $out"
  [[ "$out" != *"--channel"* ]] || fail "removed channel advertised: $out"
  [[ "$out" == *"No alternate core is supported."* ]] || fail "Core-only refusal: $out"
  [[ "$out" == *"apk add --allow-untrusted xraywrt-core_*.apk"* ]] || fail "manual install hint: $out"
  [[ "$out" != *"--file"* ]] || fail "removed file install advertised: $out"
  [[ ! -s "$tmpdir/init.calls" ]] || fail "service must stay disabled: $(cat "$tmpdir/init.calls")"
 done
)
pass "no core asset: instruction, package kept, service disabled"

# Spec 0.6/12: the core comes as xraywrt-core through core-update (default
# source core: latest release, sha256 from the API digest); an installed
# core package is updated the same way, a channel or file core is kept.
(
 sed -e '/^main "\$@"$/d' -e "s|/etc/init.d/xraywrt|$tmpdir/init-xraywrt|g" "$ROOT_DIR/install.sh" >"$tmpdir/install-core.sh"
 source "$tmpdir/install-core.sh"
 XRAYWRT_BIN="$tmpdir/xraywrt-core-stub"
 printf '#!/bin/sh\necho "$*" >>"%s"\necho "{\\"updated\\":true}"\n' "$tmpdir/core.calls" >"$XRAYWRT_BIN"
 chmod +x "$XRAYWRT_BIN"
 printf '#!/bin/sh\n' >"$tmpdir/init-xraywrt"
 chmod +x "$tmpdir/init-xraywrt"
 resolve_language() { echo en; }
 install_packages() { :; }
 pkg_version() { echo 0.27.1-r1; }
 apk() { echo '='; }
 for case in missing core channel; do
  rm -f "$tmpdir/core.calls" "$tmpdir/core-core"
  CORE="$tmpdir/core-core"
  [ "$case" = missing ] || { printf '#!/bin/sh\n[ "$*" = "run -test -c stdin:" ] || exit 1\ngrep -q "api.sock,0600.*resolve"\n' >"$CORE"; chmod +x "$CORE"; }
  pkg_installed() { [ "$1" = xraywrt-core ] && [ "$case" = core ]; }
  do_install >/dev/null 2>&1 || fail "install with $case core"
  if [ "$case" = channel ]; then
   assert_false "channel core kept without core-update" test -e "$tmpdir/core.calls"
  else
   assert_eq core-update "$(cat "$tmpdir/core.calls")" "$case core: core-update installs the core package"
  fi
 done
)
pass "core package installed and updated through core-update"

(
 sed -e '/^main "\$@"$/d' -e "s|/etc/init.d/xraywrt|$tmpdir/init-xraywrt|g" "$ROOT_DIR/install.sh" >"$tmpdir/install-fresh-old.sh"
 source "$tmpdir/install-fresh-old.sh"
 CORE="$tmpdir/fresh-old-core"
 XRAYWRT_BIN="$tmpdir/fresh-old-cli"
 printf '#!/bin/sh\necho core-update >>"%s"\n' "$tmpdir/fresh-old.calls" >"$XRAYWRT_BIN"
 printf '#!/bin/sh\necho enable >>"%s"\n' "$tmpdir/fresh-old.calls" >"$tmpdir/init-xraywrt"
 touch "$CORE"
 chmod +x "$CORE" "$XRAYWRT_BIN" "$tmpdir/init-xraywrt"
 resolve_language() { echo en; }
 pkg_installed() { [ "$1" = "$CORE_PKG" ]; }
 pkg_version() { echo 0.26.5-r2; }
 apk() { echo '<'; }
 install_packages() { echo app >>"$tmpdir/fresh-old.calls"; }
 : >"$tmpdir/fresh-old.calls"
 out="$(do_install 2>&1)" && fail "fresh install with old managed core must fail"
 assert_eq $'app\ncore-update' "$(cat "$tmpdir/fresh-old.calls")" "old core leaves fresh app installed and service disabled"
 [[ "$out" == *"XrayWRT is installed, but Xray core 0.27.1-r1 or newer is required; the service was not enabled"* ]] || fail "partial install message: $out"
)
pass "fresh install rejects old managed core before enabling service"

(
 resolve_language() { echo en; }
 pkg_installed() { return 0; }
 pkg_version() { if [ "$1" = "$CORE_PKG" ]; then echo "${core_version_case:-0.27.1-r1}"; else echo 0.1.6-r1; fi; }
 apk() { [ "$*" = 'version -t 0.27.1-r1 0.27.1-r1' ] && echo '=' || echo '<'; }
 install_packages() { echo app >>"$tmpdir/upgrade-order"; }
 XRAYWRT_BIN="$tmpdir/upgrade-core"
 CORE="$tmpdir/upgrade-xray"
 printf '#!/bin/sh\necho "$1" >>"%s"\n' "$tmpdir/upgrade-order" >"$XRAYWRT_BIN"
 printf '#!/bin/sh\nexit 0\n' >"$CORE"
 chmod +x "$XRAYWRT_BIN" "$CORE"
 do_install >/dev/null
 assert_eq $'core-update\napp' "$(cat "$tmpdir/upgrade-order")" "update compatible managed core before replacing the app"
 : >"$tmpdir/upgrade-order"
 if (core_version_case=0.26.5-r2 do_install >/dev/null 2>&1); then fail "old managed package must abort"; fi
 assert_eq core-update "$(cat "$tmpdir/upgrade-order")" "successful update with old package keeps the old app"
 : >"$tmpdir/upgrade-order"
 if (XRAYWRT_BIN="$tmpdir/missing-cli" core_version_case=0.26.5-r2 do_install >/dev/null 2>&1); then fail "old managed package without CLI must abort"; fi
 [[ ! -s "$tmpdir/upgrade-order" ]] || fail "missing CLI with old core keeps the old app"
 : >"$tmpdir/upgrade-order"
 printf 'exit 1\n' >>"$XRAYWRT_BIN"
 if (do_install >/dev/null 2>&1); then fail "failed managed core update must abort"; fi
 assert_eq core-update "$(cat "$tmpdir/upgrade-order")" "failed core update keeps the old app"
)
pass "upgrade updates managed core before the app"

(
 resolve_language() { echo en; }
 pkg_installed() { [ "$1" = "$PKG" ]; }
 pkg_version() { echo 0.1.9-r1; }
 install_packages() { echo app >>"$tmpdir/manual-order"; }
 CORE="$tmpdir/manual-core"
 : >"$tmpdir/manual-order"
 printf '#!/bin/sh\nexit 1\n' >"$CORE"
 chmod +x "$CORE"
 if (do_install >/dev/null 2>&1); then fail 'incompatible manual core must abort'; fi
 [[ ! -s "$tmpdir/manual-order" ]] || fail 'incompatible manual core must not replace app'
 printf '#!/bin/sh\n[ "$*" = "run -test -c stdin:" ] || exit 1\ngrep -q "api.sock,0600.*resolve"\n' >"$CORE"
 do_install >/dev/null || fail 'compatible manual core accepted'
 assert_eq app "$(cat "$tmpdir/manual-order")" 'compatible manual core keeps normal install'
)
pass 'manual core checked before app install'

# release_version reads the versioned apk line whose hash equals the fixed-name asset.
(
 WORK="$tmpdir/rv"
 mkdir -p "$WORK"
 app="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
 printf '%s  luci-app-xraywrt-0.12.0-r3.apk\n%s  luci-app-xraywrt.apk\n' "$app" "$app" >"$WORK/SHA256SUMS"
 assert_eq 0.12.0-r3 "$(release_version)" "apk name format"
 printf '%s  luci-app-xraywrt_0.12.0-r3_all.ipk\n%s  luci-app-xraywrt.apk\n' "$app" "$app" >"$WORK/SHA256SUMS"
 assert_eq "" "$(release_version)" "an ipk line is not a version"
)
pass "release_version"

# Only OpenWrt 25.12+ (apk) is supported: opkg-only and manager-less systems are refused.
mkdir -p "$tmpdir/obin" "$tmpdir/nobin" "$tmpdir/abin"
printf '#!/bin/sh\necho "opkg $*" >>"%s"\n' "$tmpdir/opkg.log" >"$tmpdir/obin/opkg"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/abin/apk"
chmod +x "$tmpdir/obin/opkg" "$tmpdir/abin/apk"
(
 check_platform_with() { # check_platform_with <bin dir>: check_platform with only that dir on PATH
  ( export PATH="$tmpdir/$1"; check_platform ) 2>&1
 }
 FW4_BIN="$tmpdir/fw4"
 for bin in obin nobin; do
  out="$(check_platform_with "$bin")" && fail "$bin: a system without apk must be refused"
  [[ "$out" == *"needs OpenWrt 25.12 or newer (apk)"* ]] || fail "$bin refusal message: $out"
  [[ "$out" == *"24.10 (opkg) is not supported"* ]] || fail "$bin names the unsupported release: $out"
 done
 [[ ! -e "$tmpdir/opkg.log" ]] || fail "opkg must not be called"
 FW4_BIN="$tmpdir/no-such-fw4"
 out="$(check_platform_with abin)" && fail "missing fw4 must abort"
 [[ "$out" == *"firewall4"* ]] || fail "fw4 message: $out"
 FW4_BIN="$tmpdir/fw4"
 check_platform_with abin || fail "apk with fw4 must pass"
)
# The whole installer exits before touching anything on an opkg-only PATH.
for tool in awk grep cat rm mkdir; do
 ln -s "$(command -v "$tool")" "$tmpdir/obin/$tool" 2>/dev/null || true
done
out="$(PATH="$tmpdir/obin" XRAYWRT_ACTION=install /bin/sh "$ROOT_DIR/install.sh" 2>&1)" && fail "installer must refuse an opkg-only system"
[[ "$out" == *"needs OpenWrt 25.12 or newer (apk)"* ]] || fail "installer refusal message: $out"
[[ ! -e "$tmpdir/opkg.log" ]] || fail "installer must not call opkg"
pass "apk-only platform gate"
