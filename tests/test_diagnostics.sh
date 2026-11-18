#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/proc/123"
export DIAG_FIXTURE="$tmpdir"
cat >"$tmpdir/bin/apk" <<'APK'
#!/bin/ash
echo "$*" >>"$DIAG_FIXTURE/apk.calls"
case "$*" in
info) cat "$DIAG_FIXTURE/installed" ;;
'info -e '*) grep -qxF "$3" "$DIAG_FIXTURE/installed" ;;
*) exit 99 ;;
esac
APK
cat >"$tmpdir/bin/df" <<'DF'
#!/bin/ash
case "$1 $2" in
'-kP /opt/xraywrt') cat "$DIAG_FIXTURE/df" ;;
'-kP /tmp') printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\ntmpfs 64000 4000 60000 7%% /tmp\n' ;;
*) exit 99 ;;
esac
DF
chmod +x "$tmpdir/bin/"*
export PATH="$tmpdir/bin:$PATH"
: >"$tmpdir/installed"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/root 100000 48800 51200 49%% /\n' >"$tmpdir/df"
printf 'MemTotal: 100000 kB\nMemAvailable: 30000 kB\n' >"$tmpdir/proc/meminfo"
printf 'Name: xray\nVmRSS: 45000 kB\n' >"$tmpdir/proc/123/status"
echo 123 >"$tmpdir/pid"
cp "$ROOT_DIR/tests/fixtures/xray/out/single.proxy-first.json" "$tmpdir/runtime.json"
# Relocate kernel files and the temporary storage directory; run the real implementation under BusyBox ash/awk.
sed "s|/proc/|$tmpdir/proc/|g" "$XRAYWRT_LIB_DIR/status.sh" >"$tmpdir/status.sh"
sed "s|/lib/apk/db/installed|$tmpdir/apk-installed|g" "$XRAYWRT_LIB_DIR/pkg.sh" >"$tmpdir/pkg.sh"
cat >"$tmpdir/diagnostics" <<'RUN'
#!/bin/ash
. "$XRAYWRT_LIB_DIR/constants.sh"
. "$XRAYWRT_LIB_DIR/helpers.sh"
. "$DIAG_FIXTURE/status.sh"
. "$XRAYWRT_LIB_DIR/dns.sh"
netstat() { printf '%s\n' "${DIAG_LISTENERS:-}"; }
uci() { :; }
. "$DIAG_FIXTURE/pkg.sh"
RUNTIME_CONFIG="$DIAG_FIXTURE/runtime.json"
PKG_TMP_DIR="$DIAG_FIXTURE/pkgtmp"
XRAY_CONFIG="$DIAG_FIXTURE/config.json"
CONFIG_OK_FILE="$DIAG_FIXTURE/config.ok"
CONFIG_ERR_FILE="$DIAG_FIXTURE/config.err"
service_pid() { cat "$DIAG_FIXTURE/pid" 2>/dev/null; }
awk() {
 case "$*" in *"$DIAG_FIXTURE/apk-installed"*) echo read >>"$DIAG_FIXTURE/db.reads" ;; esac
 busybox awk "$@"
}
diagnostics_json
RUN
chmod +x "$tmpdir/diagnostics"
diag() { ash "$tmpdir/diagnostics"; }

assert_eq null "$(diag | jq .dns_guard_error)" 'diagnostics reports healthy DNS'
export DIAG_LISTENERS='udp 0 0 127.0.0.1:53 0.0.0.0:* 123/AdGuardHome'
assert_true 'diagnostics includes DNS guard error' bash -c '[[ "$1" == *"port 53 is used by AdGuardHome"* ]]' _ "$(diag | jq -r .dns_guard_error)"
unset DIAG_LISTENERS

case "${1:-all}" in
all|conflicts)
 printf 'P:podkop\nV:1\n\nP:foo\n\nP:https-dns-proxy\n' >"$tmpdir/apk-installed"
 assert_eq '["podkop","https-dns-proxy"]' "$(diag | jq -c .conflicts)" 'installed conflicts in authoritative order'
 assert_eq 1 "$(wc -l <"$tmpdir/db.reads" | tr -d ' ')" 'one awk reads package database'
 assert_false 'diagnostics does not invoke package manager' test -e "$tmpdir/apk.calls"
 rm "$tmpdir/apk-installed"
 assert_eq '[]' "$(diag | jq -c .conflicts)" 'no installed conflicts'
 pass 'diagnostics conflicts'
 ;;&
all|resources)
 assert_eq '{"conflicts":[],"flash_free_kb":51200,"ram_available_kb":30000,"xray_rss_kb":45000}' "$(diag | jq -c 'del(.tmp_xraywrt_kb, .tmp_free_kb, .config_test, .dns_guard_error)')" 'baseline diagnostics JSON unchanged except temporary storage fields'
 assert_eq '[51200,30000,45000]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.xray_rss_kb]')" 'resource snapshot'
 rm "$tmpdir/pid"
 assert_eq null "$(diag | jq .xray_rss_kb)" 'stopped Xray has no RSS'
 echo 123 >"$tmpdir/pid"
 rm "$tmpdir/proc/123/status" "$tmpdir/proc/meminfo"
 : >"$tmpdir/df"
 assert_eq '[null,null,null]' "$(diag | jq -c '[.flash_free_kb,.ram_available_kb,.xray_rss_kb]')" 'missing resources are null'
 mkdir -p "$tmpdir/pkgtmp"
 printf cache >"$tmpdir/pkgtmp/fixture"
 expected="$(du -sk "$tmpdir/pkgtmp" | awk '{print $1}')"
 assert_eq "$expected" "$(diag | jq -r .tmp_xraywrt_kb)" 'temporary storage snapshot'
 assert_eq false "$(diag | jq 'has("tmp_free_kb")')" 'unused free temporary storage omitted'
 rm -rf "$tmpdir/pkgtmp"
 assert_eq null "$(diag | jq .tmp_xraywrt_kb)" 'absent temporary files unknown'
 pass 'diagnostics resources'
 ;;&
all|ports)
 # The obsolete ports snapshot is not part of diagnostics.
 assert_eq 'false' "$(diag | jq 'has("open_proxy_ports") or has("ports")')" 'no open proxy ports with a runtime config'
 rm "$tmpdir/runtime.json"
 assert_eq 'false' "$(diag | jq 'has("open_proxy_ports") or has("ports")')" 'missing runtime config'
 pass 'diagnostics omit unused ports'
 ;;&
all|configtest)
 # Spec 15: the last `run -test` result.
 assert_eq '{"valid":null,"output":[]}' "$(diag | jq -c .config_test)" 'no recorded test'
 echo '{}' >"$tmpdir/config.json"
 touch -d '2000-01-01' "$tmpdir/config.json"
 printf 'Failed to start: main: failed to load config files\n> infra/conf: unknown protocol\n' >"$tmpdir/config.err"
 assert_eq '{"valid":false,"output":["Failed to start: main: failed to load config files","> infra/conf: unknown protocol"]}' "$(diag | jq -c .config_test)" 'recorded rejection'
 rm "$tmpdir/config.err"
 touch "$tmpdir/config.ok"
 assert_eq '{"valid":true,"output":[]}' "$(diag | jq -c .config_test)" 'recorded success'
 pass 'diagnostics last config test'
 ;;&
all|wrapper)
 assert_eq diagnostics-json "$(XRAYWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/xraywrt-read" diagnostics-json)" 'read wrapper allows diagnostics'
 assert_false 'read wrapper rejects extra argument' env XRAYWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/xraywrt-read" diagnostics-json extra
 assert_false 'read wrapper rejects empty argument' env XRAYWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/xraywrt-read" diagnostics-json ''
 strip_xraywrt_cli_bootstrap >"$tmpdir/cli"
 sed -i '/^case "$cmd" in/i diagnostics_json() { echo diagnostics-dispatched; }' "$tmpdir/cli"
 assert_eq diagnostics-dispatched "$(ash "$tmpdir/cli" diagnostics-json)" 'CLI dispatches diagnostics'
 assert_false 'CLI rejects arguments' ash "$tmpdir/cli" diagnostics-json extra >/dev/null 2>&1
 pass 'diagnostics read boundary'
 ;;
esac
