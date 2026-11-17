#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backup_path="$tmpdir/luci-app-xraywrt.config.json.bak"
list_backup_dir="$tmpdir/luci-app-xraywrt.policy-lists.bak"
live_config="$tmpdir/opt/xraywrt/config.json"
live_uci="$tmpdir/etc/config/xraywrt"
live_list_dir="$tmpdir/opt/xraywrt/lst"
live_dst_list="$live_list_dir/always_proxy_dst.txt"
live_src_list="$live_list_dir/always_proxy_src.txt"
live_direct_list="$live_list_dir/direct_dst.txt"
live_direct_src_list="$live_list_dir/direct_src.txt"
preinst_path="$tmpdir/preinst.sh"
script_path="$tmpdir/postinst.sh"
prerm_path="$tmpdir/prerm.sh"
hook_log="$tmpdir/hook.log"
skip_start="$tmpdir/skip-start"
was_running_marker="$tmpdir/was-running"
fw4_include="$tmpdir/fw4/30-xraywrt.nft"
prerm_constants="$tmpdir/prerm-constants.sh"
printf 'FW4_INPUT_INCLUDE="%s"\n' "$fw4_include" >"$prerm_constants"
acl_file="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-xraywrt.json"
keep_file="$ROOT_DIR/rootfs/lib/upgrade/keep.d/xraywrt"

assert_eq $'/etc/init.d/rpcd\n/etc/init.d/xraywrt' "$(grep -oE '/etc/init.d/[[:alnum:]_-]+' "$ROOT_DIR/Makefile" | sort -u)" "package uses only the main init service and rpcd"

assert_file_contains "$ROOT_DIR/Makefile" 'XRAYWRT_LISTS:=always_proxy_dst always_proxy_src direct_dst direct_src rules' "list names should have one Makefile definition"
render_package_define conffiles >"$tmpdir/conffiles"
if grep -q '^$' "$tmpdir/conffiles"; then
	fail "conffiles should not contain empty lines"
fi
render_package_define preinst >"$tmpdir/preinst.expanded"
render_package_define postinst >"$tmpdir/postinst.expanded"
for list in always_proxy_dst always_proxy_src direct_dst direct_src rules; do
	grep -Fxq "/opt/xraywrt/lst/$list.txt" "$tmpdir/conffiles" || fail "conffiles should preserve $list on its own exact line"
	assert_file_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/xraywrt.list" "/opt/xraywrt/lst/$list.txt" "APK should preserve $list"
done
assert_file_contains "$tmpdir/preinst.expanded" 'for list in always_proxy_dst always_proxy_src direct_dst direct_src rules' "preinst should back up all list files"
assert_file_contains "$tmpdir/postinst.expanded" 'for list in always_proxy_dst always_proxy_src direct_dst direct_src rules' "postinst should restore all list files"
assert_file_contains "$keep_file" '/opt/xraywrt/lst' "sysupgrade should preserve list directory"
assert_file_contains "$tmpdir/postinst.expanded" '. /usr/lib/xraywrt/constants.sh' "postinst should source constants"
assert_file_contains "$tmpdir/postinst.expanded" 'pgrep -f "$SUPERVISOR_PATTERN"' "postinst should use supervisor constant"
# The pattern matches the supervisor only, not a shell whose command line mentions it.
(
	. "$ROOT_DIR/rootfs/usr/lib/xraywrt/constants.sh"
	for line in '/bin/ash /usr/bin/xraywrt run-service' '/bin/sh /usr/bin/xraywrt run-service' '/usr/bin/xraywrt run-service'; do
		echo "$line" | grep -Eq "$SUPERVISOR_PATTERN" || fail "supervisor pattern must match: $line"
	done
	for line in 'ash -c pgrep -f "/usr/bin/xraywrt run-service"' '/bin/ash /usr/bin/xraywrt run-service-x' 'vi /usr/bin/xraywrt run-service'; do
		! echo "$line" | grep -Eq "$SUPERVISOR_PATTERN" || fail "supervisor pattern must not match: $line"
	done
	for f in Makefile core/Makefile; do
		! grep -n 'pgrep -f "/usr/bin/xraywrt run-service"' "$ROOT_DIR/$f" || fail "$f uses an unanchored supervisor pgrep"
	done
) || exit 1
pass "list files consistent and postinst constants sourced"

extract_hook() {
	local hook="$1"

	awk '
		$0=="define Package/$(PKG_NAME)/" hook { in_block=1; next }
		in_block && $0=="endef" { exit }
		in_block { print }
	' hook="$hook" "$ROOT_DIR/Makefile"
}

rewrite_package_paths() {
	sed \
		-e "s|/tmp/luci-app-xraywrt.config.json.bak|$backup_path|g" \
		-e "s|/tmp/luci-app-xraywrt.policy-lists.bak|$list_backup_dir|g" \
		-e "s|/opt/xraywrt/config.json|$live_config|g" \
		-e "s|/etc/config/xraywrt|$live_uci|g" \
		-e "s|/opt/xraywrt/lst|$live_list_dir|g"
}

extract_preinst() {
	render_package_define preinst |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-xraywrt.skip-start|$skip_start|g" \
			-e "s|/tmp/xraywrt.skip-start|$skip_start|g" \
			-e "s|/tmp/luci-app-xraywrt.was-running|$was_running_marker|g" \
			-e "s|/lib/apk/db/installed|$tmpdir/apk-installed|g"
}

extract_postinst() {
	render_package_define postinst |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-xraywrt.skip-start|$skip_start|g" \
			-e "s|/tmp/xraywrt.skip-start|$skip_start|g" \
			-e "s|/tmp/luci-app-xraywrt.was-running|$was_running_marker|g" \
			-e "s|/usr/lib/xraywrt/constants.sh|$XRAYWRT_LIB_DIR/constants.sh|g" \
			-e "s|/usr/bin/xraywrt|$tmpdir/xraywrt|g" \
			-e "s|/etc/init.d/xraywrt |$tmpdir/init-xraywrt |g" \
			-e 's|/etc/init.d/rpcd reload|true|g'
}

extract_prerm() {
	render_package_define prerm |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-xraywrt.was-running|$was_running_marker|g" \
			-e "s|/etc/init.d/xraywrt|$tmpdir/init-xraywrt|g" \
			-e "s|/usr/bin/xraywrt|$tmpdir/xraywrt|g" \
			-e "s|/usr/lib/xraywrt/constants.sh|$prerm_constants|g" \
			-e "s|/usr/share/nftables.d/chain-pre/input/30-xraywrt.nft|$fw4_include|g"
}

mkdir -p "$(dirname "$live_config")" "$live_list_dir"

extract_hook "preinst" >"$tmpdir/preinst.raw"
assert_file_contains "$tmpdir/preinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)' "preinst should stage policy list backups before package payload install"
assert_file_contains "$tmpdir/preinst.raw" "backup_xraywrt_file" "preinst should use fail-fast backup helper"
assert_file_contains "$tmpdir/preinst.raw" '/opt/xraywrt/lst/$$list.txt' "preinst should back up policy list paths from its loop"
extract_hook "postinst" >"$tmpdir/postinst.raw"
assert_file_contains "$tmpdir/postinst.raw" "/tmp/xraywrt.skip-start" "postinst should clear the skip marker"
assert_file_contains "$tmpdir/postinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt' "postinst should restore policy list backups from its loop"
assert_file_contains "$tmpdir/postinst.raw" "/usr/bin/xraywrt migrate" "postinst should run package migrations on package upgrade"

cat >"$tmpdir/xraywrt" <<EOF
#!/usr/bin/env bash
printf 'xraywrt:%s\n' "\$*" >>"$hook_log"
if [[ "\${1:-}" == "migrate" && "\${TEST_FAIL_MIGRATE:-0}" == "1" ]]; then
	exit 1
fi
exit 0
EOF
chmod +x "$tmpdir/xraywrt"

extract_preinst >"$preinst_path"
chmod +x "$preinst_path"
extract_postinst >"$script_path"
chmod +x "$script_path"

failbin="$tmpdir/failbin"
mkdir -p "$failbin"
cat >"$failbin/cp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$failbin/cp"

# Spec 3: preinst refuses next to a conflicting package and names it.
for package in luci-app-mihowrt xray-core luci-app-xray luci-app-passwall2 adguardhome; do
	rm -f "$tmpdir/apk-installed" "$backup_path"
	printf 'P:luci-base\nV:1\n\nP:%s\nV:1\n' "$package" >"$tmpdir/apk-installed"
	printf 'user-config\n' >"$live_config"
	if IPKG_INSTROOT="" "$preinst_path" 2>"$tmpdir/preinst.err"; then fail "preinst must refuse next to $package"; fi
	assert_eq "luci-app-xraywrt: conflicts with installed package $package; remove it first" "$(cat "$tmpdir/preinst.err")" "$package named"
	[[ ! -e "$backup_path" ]] || fail "refused preinst must not stage backups"
done
rm -f "$tmpdir/apk-installed" "$backup_path"
rm -rf "$list_backup_dir"
pass 'preinst refuses conflicting packages'

printf 'backup-fail-config\n' >"$live_config"
rm -f "$backup_path"
rm -rf "$list_backup_dir"
set +e
PATH="$failbin:$PATH" IPKG_INSTROOT="" "$preinst_path"
preinst_fail_rc=$?
set -e
[[ "$preinst_fail_rc" -ne 0 ]] || fail "preinst should fail when existing config cannot be backed up"
[[ ! -e "$backup_path" ]] || fail "preinst should not leave partial config backup after failed copy"

printf 'user-config\n' >"$live_config"
printf 'user-dst\n' >"$live_dst_list"
printf 'user-src\n' >"$live_src_list"
printf 'user-direct\n' >"$live_direct_list"
printf 'user-device\n' >"$live_direct_src_list"
IPKG_INSTROOT="" "$preinst_path"
rm -f "$skip_start" # apk: the default start already consumed the marker
assert_file_contains "$backup_path" "user-config" "preinst should back up existing config before fresh package install"
assert_file_contains "$list_backup_dir/always_proxy_dst.txt" "user-dst" "preinst should back up existing destination policy list"
assert_file_contains "$list_backup_dir/always_proxy_src.txt" "user-src" "preinst should back up existing source policy list"
assert_file_contains "$list_backup_dir/direct_dst.txt" "user-direct" "preinst should back up existing direct destination policy list"

mkdir -p "${live_uci%/*}"
printf 'user-uci\n' >"$live_uci"
printf 'new-default\n' >"$live_uci.apk-new"
IPKG_INSTROOT="$tmpdir/image" "$script_path"
[[ -f "$live_uci.apk-new" ]] || fail "offline postinst must leave host UCI leftovers alone"

printf 'package-config\n' >"$live_config"
printf 'package-dst\n' >"$live_dst_list"
printf 'package-src\n' >"$live_src_list"
printf 'package-direct\n' >"$live_direct_list"
printf 'package-device\n' >"$live_direct_src_list"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
[[ ! -e "$live_uci.apk-new" ]] || fail "postinst should remove UCI .apk-new default"
assert_eq user-uci "$(cat "$live_uci")" "postinst preserves user UCI byte content"
pass "postinst removes package-manager UCI default leftovers"
assert_file_contains "$live_config" "user-config" "postinst should restore config preserved across sysupgrade reinstall"
assert_file_contains "$live_dst_list" "user-dst" "postinst should restore destination policy list preserved across sysupgrade reinstall"
assert_file_contains "$live_src_list" "user-src" "postinst should restore source policy list preserved across sysupgrade reinstall"
assert_file_contains "$live_direct_list" "user-direct" "postinst should restore direct destination policy list preserved across sysupgrade reinstall"
[[ ! -e "$backup_path" ]] || fail "postinst should consume restored config backup"
[[ ! -e "$list_backup_dir/always_proxy_dst.txt" ]] || fail "postinst should consume restored destination policy list backup"
[[ ! -e "$list_backup_dir/always_proxy_src.txt" ]] || fail "postinst should consume restored source policy list backup"
[[ ! -e "$list_backup_dir/direct_dst.txt" ]] || fail "postinst should consume restored direct destination policy list backup"
assert_file_contains "$live_direct_src_list" user-device "fourth list restored"
[[ ! -d "$list_backup_dir" ]] || fail "postinst should remove empty policy list backup directory"

printf 'same-config\n' >"$backup_path"
printf 'same-config\n' >"$live_config"
mkdir -p "$list_backup_dir"
printf 'same-dst\n' >"$list_backup_dir/always_proxy_dst.txt"
printf 'same-dst\n' >"$live_dst_list"
touch -d '2024-01-01 00:00:00' "$live_config"
touch -d '2024-01-01 00:00:00' "$live_dst_list"
file_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

printf 'new-default\n' >"$live_uci.apk-new"
before_same_mtime="$(file_mtime "$live_config")"
before_same_list_mtime="$(file_mtime "$live_dst_list")"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
[[ ! -e "$live_uci.apk-new" ]] || fail "reinstall should remove new UCI defaults again"
assert_eq user-uci "$(cat "$live_uci")" "reinstall preserves user UCI"
after_same_mtime="$(file_mtime "$live_config")"
after_same_list_mtime="$(file_mtime "$live_dst_list")"
assert_eq "$before_same_mtime" "$after_same_mtime" "postinst should skip rewriting identical config backup"
assert_eq "$before_same_list_mtime" "$after_same_list_mtime" "postinst should skip rewriting identical policy list backup"
[[ ! -e "$backup_path" ]] || fail "postinst should remove identical config backup after skip"
[[ ! -e "$list_backup_dir/always_proxy_dst.txt" ]] || fail "postinst should remove identical policy list backup after skip"
assert_file_contains "$hook_log" "xraywrt:migrate" "postinst should run migrations"

mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmpdir/init-xraywrt" <<EOF
#!/bin/sh
printf 'init:%s\n' "\$*" >>"$hook_log"
EOF
chmod +x "$tmpdir/bin/pgrep" "$tmpdir/init-xraywrt"
: >"$hook_log"
set +e
PATH="$tmpdir/bin:$PATH" TEST_FAIL_MIGRATE=1 IPKG_INSTROOT="" "$script_path"
postinst_migrate_fail_rc=$?
set -e
[[ "$postinst_migrate_fail_rc" -eq 1 ]] || fail "postinst should fail when package migration fails"
assert_file_contains "$hook_log" "xraywrt:migrate" "postinst should attempt package migration before failing"

assert_file_contains "$hook_log" "init:stop" "running service stopped before migration"
assert_file_contains "$hook_log" "init:start" "service restarted despite migration failure"
assert_eq "$(printf 'init:stop\nxraywrt:migrate\ninit:start')" "$(cat "$hook_log")" "postinst failure restart order"
pass "postinst migrate failure restarts service"

# default_postinst stops the service (skipped start_service) before our
# postinst runs, so the running state is recorded by preinst.
mkdir -p "$tmpdir/bin-running" "$tmpdir/bin-stopped"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/bin-running/pgrep"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/bin-stopped/pgrep"
chmod +x "$tmpdir/bin-running/pgrep" "$tmpdir/bin-stopped/pgrep"

rm -f "$was_running_marker"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$preinst_path"
[[ ! -e "$was_running_marker" ]] || fail "preinst should not mark a stopped service as running"
PATH="$tmpdir/bin-running:$PATH" IPKG_INSTROOT="" "$preinst_path"
rm -f "$skip_start" # apk: the default start already consumed the marker
[[ -e "$was_running_marker" ]] || fail "preinst should record a running supervisor"

: >"$hook_log"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$script_path"
assert_file_contains "$hook_log" "init:start" "marker restarts a service stopped by default_postinst"
[[ ! -e "$was_running_marker" ]] || fail "postinst should remove the was-running marker"

: >"$hook_log"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$script_path"
assert_file_not_contains "$hook_log" "init:" "no marker and no supervisor must not start the service"

: >"$was_running_marker"
: >"$hook_log"
set +e
PATH="$tmpdir/bin-stopped:$PATH" TEST_FAIL_MIGRATE=1 IPKG_INSTROOT="" "$script_path"
marker_fail_rc=$?
set -e
assert_eq 1 "$marker_fail_rc" "migrate failure with marker still exits 1"
assert_file_contains "$hook_log" "init:start" "migrate failure with marker still starts the service"
[[ ! -e "$was_running_marker" ]] || fail "marker removed after failed migrate"
pass "was-running marker keeps service running across upgrade"

printf 'new-config\n' >"$backup_path"
printf 'old-config\n' >"$live_config"
IPKG_INSTROOT="" "$script_path"
assert_file_contains "$live_config" "new-config" "postinst should restore changed config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should consume changed config backup"

# apk runs default_postinst ("/etc/init.d/xraywrt start") before this hook:
# preinst makes that start a no-op (start_service consumes the marker), postinst decides.
rm -f "$skip_start"
IPKG_INSTROOT="" "$preinst_path"
[[ -e "$skip_start" ]] || fail "preinst should skip the default postinst start"
rm -f "$skip_start"
IPKG_INSTROOT="" "$script_path"
[[ ! -e "$skip_start" ]] || fail "postinst should clear the skip marker"

extract_prerm >"$prerm_path"
chmod +x "$prerm_path"

cat >"$tmpdir/init-xraywrt" <<EOF
#!/usr/bin/env bash
printf 'init:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
cat >"$tmpdir/xraywrt" <<EOF
#!/usr/bin/env bash
printf 'xraywrt:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
chmod +x "$tmpdir/init-xraywrt" "$tmpdir/xraywrt"

mkdir -p "${fw4_include%/*}"
printf 'guest input rules\n' >"$fw4_include"
printf '#!/bin/sh\necho "fw4:$*" >>"%s"\n' "$hook_log" >"$tmpdir/bin/fw4"
chmod +x "$tmpdir/bin/fw4"
: >"$hook_log"
PATH="$tmpdir/bin:$PATH" IPKG_INSTROOT="" "$prerm_path"
assert_file_contains "$hook_log" "xraywrt:uninstall" "prerm runs uninstall before package files are removed"
assert_false 'prerm fallback removes fw4 input include' test -e "$fw4_include"
assert_eq 1 "$(grep -c '^fw4:reload$' "$hook_log")" 'prerm fallback reloads after removal'
PATH="$tmpdir/bin:$PATH" IPKG_INSTROOT="" "$prerm_path"
assert_eq 1 "$(grep -c '^fw4:reload$' "$hook_log")" 'prerm with no include does not reload'
pass 'prerm removes stale fw4 input include only once'

# The include path comes from constants.sh; without constants.sh the shipped path is used.
other_include="$tmpdir/fw4/other.nft"
printf 'FW4_INPUT_INCLUDE="%s"\n' "$other_include" >"$prerm_constants"
printf 'guest input rules\n' | tee "$other_include" >"$fw4_include"
PATH="$tmpdir/bin:$PATH" IPKG_INSTROOT="" "$prerm_path"
assert_false 'prerm removes the include named by constants.sh' test -e "$other_include"
assert_true 'prerm leaves other files alone' test -e "$fw4_include"
rm -f "$prerm_constants"
PATH="$tmpdir/bin:$PATH" IPKG_INSTROOT="" "$prerm_path"
assert_false 'prerm falls back to the shipped include path without constants.sh' test -e "$fw4_include"
printf 'FW4_INPUT_INCLUDE="%s"\n' "$fw4_include" >"$prerm_constants"
pass 'prerm reads the fw4 include path from constants.sh with a fallback'

# A stale was-running marker from an earlier run is dropped by preinst.
: >"$was_running_marker"
touch -d '2024-01-01 00:00:00' "$was_running_marker"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$preinst_path"
[[ ! -e "$was_running_marker" ]] || fail "preinst should drop a stale was-running marker"
pass "preinst drops a stale was-running marker"

# The package hooks are apk-only: no opkg path is left in the Makefile.
assert_eq 0 "$(grep -ciE 'opkg|PKG_UPGRADE' "$ROOT_DIR/Makefile" || true)" "Makefile hooks have no opkg code"

# Removal: apk deletes package-owned files, so prerm parks the user's config and
# lists as .keep copies and postrm moves them back (spec 11.1).
printf 'user-config\0bytes\n' >"$live_config"
for list in always_proxy_dst always_proxy_src direct_dst direct_src rules; do
	printf 'user-%s\n1.2.3.4\n' "$list" >"$live_list_dir/$list.txt"
done
sums_before="$(cat "$live_config" "$live_list_dir"/{always_proxy_dst,always_proxy_src,direct_dst,direct_src,rules}.txt | cksum)"
IPKG_INSTROOT="" "$prerm_path"
[[ -f "$live_config.keep" ]] || fail "prerm should park config.json as .keep"
for list in always_proxy_dst always_proxy_src direct_dst direct_src rules; do
	[[ -f "$live_list_dir/$list.txt.keep" ]] || fail "prerm should park $list.txt as .keep"
done
[[ -f "$live_config" ]] || fail "prerm aborted before postrm must not lose config.json"
rm -f "$live_config"
for list in always_proxy_dst always_proxy_src direct_dst direct_src rules; do
	rm -f "$live_list_dir/$list.txt"
done
render_package_define postrm >"$tmpdir/postrm.keep.expanded"
sed -e "s|/tmp/|@ROOT@/tmp/|g" -e "s|/var/run/|@ROOT@/var/run/|g" \
	-e "s|/opt/|@ROOT@/opt/|g" -e "s|/etc/|@ROOT@/etc/|g" \
	-e "s|@ROOT@|$tmpdir|g" "$tmpdir/postrm.keep.expanded" >"$tmpdir/postrm.keep.sh"
IPKG_INSTROOT="" ash "$tmpdir/postrm.keep.sh"
assert_eq "$sums_before" "$(cat "$live_config" "$live_list_dir"/{always_proxy_dst,always_proxy_src,direct_dst,direct_src,rules}.txt | cksum)" "removal keeps config.json and lists byte-identical"
[[ -z "$(find "$tmpdir/opt" -name '*.keep')" ]] || fail "no .keep file left after removal"
pass "removal keeps the config and lists"

: >"$hook_log"
IPKG_INSTROOT="$tmpdir/root" "$prerm_path"
[[ ! -s "$hook_log" ]] || fail "prerm should skip host actions for offline root installs"

assert_eq "null" "$(jq -c '."luci-app-xraywrt".read.file["/opt/xraywrt/bin/xray"] // null' "$acl_file")" "ACL should not allow direct Xray binary execution from LuCI"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".write.file["/opt/xraywrt/config.json"] // null' "$acl_file")" "ACL should not allow bypassing validated config apply"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".read.file["/usr/bin/xraywrt"] // null' "$acl_file")" "ACL read scope should not execute mutating backend"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".read.file["/etc/init.d/xraywrt"] // null' "$acl_file")" "ACL read scope should not execute init service script"
# LuCI upload prefixes, ACL write paths and backend upload checks must name the same files.
upload_prefixes="$(sed -n "s/.*if (!\[ \(.*\) \]\.includes(prefix)).*/\1/p" "$ROOT_DIR/rootfs/www/luci-static/resources/xraywrt/api.js" | tr -d "' " | tr , '\n')"
assert_eq $'xraywrt-config\nxraywrt-policy-list\nxraywrt-geodata' "$upload_prefixes" "LuCI upload prefixes are discovered"
for prefix in $upload_prefixes; do
	assert_eq '["write"]' "$(jq -c --arg p "/tmp/$prefix.*" '."luci-app-xraywrt".write.file[$p]' "$acl_file")" "ACL allows LuCI upload $prefix"
	case "$prefix" in
	# geodata-update --file has its own /tmp check (spec 10).
	xraywrt-geodata) grep -qF 'upload_path_allowed /tmp/ "$2"' "$ROOT_DIR/rootfs/usr/lib/xraywrt/geodata.sh" ;;
	*) grep -rqF "upload_path_allowed /tmp/$prefix. " "$ROOT_DIR/rootfs/usr/lib/xraywrt" ;;
	esac || fail "backend accepts LuCI upload $prefix"
done
assert_eq '["exec"]' "$(jq -c '."luci-app-xraywrt".read.file["/usr/bin/xraywrt-read"]' "$acl_file")" "ACL read scope should execute only read-only backend wrapper"
# A14.1: exactly the backend entry points and upload prefixes LuCI uses.
assert_eq '["/usr/bin/xraywrt-read"]' "$(jq -c '."luci-app-xraywrt".read.file | keys' "$acl_file")" "ACL read files are only the read wrapper"
assert_eq '["/etc/init.d/xraywrt","/tmp/xraywrt-config.*","/tmp/xraywrt-geodata.*","/tmp/xraywrt-policy-list.*","/usr/bin/xraywrt"]' "$(jq -c '."luci-app-xraywrt".write.file | keys' "$acl_file")" "ACL write files are the backend, init script and upload prefixes"

assert_eq '["exec"]' "$(jq -c '."luci-app-xraywrt".read.ubus.file' "$acl_file")" "ACL read scope has no ubus file.read (no LuCI caller)"
# api.readLarge uses fs.exec_direct; cgi-exec checks session cgi-io/exec/read before the file ACL.
assert_eq '["exec"]' "$(jq -c '."luci-app-xraywrt".read."cgi-io"' "$acl_file")" "ACL read scope grants cgi-exec for readLarge"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".write."cgi-io" // null' "$acl_file")" "cgi-exec granted once, in read scope"
assert_eq '["exec"]' "$(jq -c '."luci-app-xraywrt".write.ubus.file' "$acl_file")" "ACL write scope has no ubus file.write (cgi-io stages uploads)"
assert_eq '["exec"]' "$(jq -c '."luci-app-xraywrt".write.file["/usr/bin/xraywrt"]' "$acl_file")" "ACL should keep validated backend execution"
assert_eq '["write"]' "$(jq -c '."luci-app-xraywrt".write.file["/tmp/xraywrt-config.*"]' "$acl_file")" "ACL should allow only XrayWRT temp config staging from LuCI"
assert_eq null "$(jq -c '."luci-app-xraywrt".read.file["/opt/xraywrt/lst/always_proxy_dst.txt"]' "$acl_file")" "ACL should not directly read destination policy list"
assert_eq null "$(jq -c '."luci-app-xraywrt".read.file["/opt/xraywrt/lst/always_proxy_src.txt"]' "$acl_file")" "ACL should not directly read source policy list"
assert_eq null "$(jq -c '."luci-app-xraywrt".read.file["/opt/xraywrt/lst/direct_dst.txt"]' "$acl_file")" "ACL should not directly read direct destination list"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".write.file["/opt/xraywrt/lst/always_proxy_dst.txt"] // null' "$acl_file")" "ACL should not allow direct destination policy list writes from LuCI"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".write.file["/opt/xraywrt/lst/always_proxy_src.txt"] // null' "$acl_file")" "ACL should not allow direct source policy list writes from LuCI"
assert_eq "null" "$(jq -c '."luci-app-xraywrt".write.file["/opt/xraywrt/lst/direct_dst.txt"] // null' "$acl_file")" "ACL should not allow direct policy list writes from LuCI"
assert_eq '["write"]' "$(jq -c '."luci-app-xraywrt".write.file["/tmp/xraywrt-policy-list.*"]' "$acl_file")" "ACL should allow only temp policy list staging from LuCI"

assert_file_contains "$ROOT_DIR/Makefile" "\$(1)/lib/upgrade/keep.d" "package should install sysupgrade keep directory"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/usr/bin/xraywrt-read' "package should install read-only backend wrapper"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/lib/upgrade/keep.d/xraywrt' "package should install XrayWRT sysupgrade keep list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/view/xraywrt/*' "package should install LuCI view assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/xraywrt/*' "package should install LuCI helper assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -f /tmp/luci-indexcache' "postinst should clear LuCI index cache after upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -rf /tmp/luci-modulecache' "postinst should clear LuCI module cache after upgrade"
assert_file_contains "$tmpdir/conffiles" '/opt/xraywrt/lst/direct_dst.txt' "package conffiles should include direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/xraywrt/lst/$$$$list.txt' "package should install direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_xraywrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/xraywrt/config.json || exit 1' "postinst should fail if saved config cannot be restored"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_xraywrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt /opt/xraywrt/lst/$$list.txt || exit 1' "postinst should fail if saved policy lists cannot be restored"
render_package_define postrm >"$tmpdir/postrm.expanded"
for forbidden in cron dnsmasq sed /etc/init.d/xraywrt; do
	assert_file_not_contains "$tmpdir/postrm.expanded" "$forbidden" "postrm has no runtime logic: $forbidden"
done
for leftover in /tmp/xraywrt /var/run/xraywrt; do
	assert_file_contains "$tmpdir/postrm.expanded" "$leftover" "postrm removes $leftover"
done
assert_file_not_contains "$tmpdir/postrm.expanded" /tmp/clash "postrm leaves MihoWRT tmpfs alone"
postrm_root="$tmpdir/postrm-root"
mkdir -p "$postrm_root/tmp/xraywrt" "$postrm_root/var/run/xraywrt" "$postrm_root/tmp/clash"
sed -e "s|/tmp/|@ROOT@/tmp/|g" -e "s|/var/run/|@ROOT@/var/run/|g" \
	-e "s|/opt/|@ROOT@/opt/|g" -e "s|/etc/|@ROOT@/etc/|g" \
	-e "s|@ROOT@|$postrm_root|g" "$tmpdir/postrm.expanded" >"$tmpdir/postrm.sh"
IPKG_INSTROOT="$tmpdir/image" ash "$tmpdir/postrm.sh"
[[ -d "$postrm_root/tmp/xraywrt" ]] || fail "postrm skips image builds"
IPKG_INSTROOT="" ash "$tmpdir/postrm.sh"
for leftover in tmp/xraywrt var/run/xraywrt; do
	[[ ! -e "$postrm_root/$leftover" ]] || fail "postrm removes $leftover"
done
[[ -d "$postrm_root/tmp/clash" ]] || fail "postrm keeps MihoWRT /tmp/clash"
[[ ! -e "$postrm_root/opt/xraywrt" ]] || fail "postrm must not create clash directory without keep files"
mkdir -p "$postrm_root/opt/xraywrt/bin" "$postrm_root/opt/xraywrt/lst"
IPKG_INSTROOT="" ash "$tmpdir/postrm.sh"
[[ ! -e "$postrm_root/opt/xraywrt" ]] || fail "postrm removes empty clash and list directories"
mkdir -p "$postrm_root/opt/xraywrt/lst"
printf 'user-data\n' >"$postrm_root/opt/xraywrt/lst/custom.txt"
IPKG_INSTROOT="" ash "$tmpdir/postrm.sh"
assert_file_contains "$postrm_root/opt/xraywrt/lst/custom.txt" user-data "postrm preserves unrelated user files"
pass "postrm removes empty directories without deleting user files"

assert_file_contains "$ROOT_DIR/Makefile" '+curl' "package should depend on curl for subscription and core downloads"
installer_deps="$(sed -n 's/^DEPS="\(.*\)"$/\1/p' "$ROOT_DIR/install.sh")"
package_deps="$(sed -n 's/^LUCI_DEPENDS:=//p' "$ROOT_DIR/Makefile" | tr -d '+')"
assert_eq "$(printf '%s\n' "$package_deps" | tr ' ' '\n' | sort -u)" "$(printf '%s\n' "$installer_deps" | tr ' ' '\n' | sort -u)" "installer and package dependency sets match both ways"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/xraywrt" "subscription_url" "default UCI config has no subscription"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/xraywrt" "policy_remote_update_interval" "default UCI config should use per-URL policy list intervals"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/xraywrt" "route_table_id" "default UCI config should keep route table selection automatic"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/xraywrt" "route_rule_priority" "default UCI config should keep route rule selection automatic"
assert_file_contains "$keep_file" "/etc/config/xraywrt" "sysupgrade keep list should preserve UCI config"
assert_false "sysupgrade excludes the persistent state directory" grep -qxF /etc/xraywrt "$keep_file"
for file in hwid subscription.json core.json; do
 assert_true "sysupgrade preserves $file" grep -qxF "/etc/xraywrt/$file" "$keep_file"
done
assert_file_not_contains "$keep_file" 'policy-cache' "sysupgrade excludes regenerable lists cache"
assert_file_contains "$keep_file" "/opt/xraywrt/config.json" "sysupgrade keep list should preserve the Xray config"
assert_file_contains "$keep_file" "/opt/xraywrt/lst" "sysupgrade keep list should preserve policy lists"
assert_file_contains "$keep_file" "/opt/xraywrt/subs/*/config.json" "sysupgrade keeps the saved subscriptions' configs"
assert_file_contains "$keep_file" "/opt/xraywrt/subs/*/subscription.json" "sysupgrade keeps the saved subscriptions' metadata"
assert_file_contains "$keep_file" "/opt/xraywrt/subs/*/lists" "sysupgrade keeps the saved subscriptions' own lists"
assert_file_not_contains "$keep_file" "subs/*/share" "sysupgrade drops the parked rule databases"
assert_file_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/xraywrt.list" "/opt/xraywrt/lst/direct_dst.txt" "APK protected paths should preserve direct destination list"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/xraywrt.list" "/www/luci-static" "APK protected paths should not preserve stale LuCI assets"

pass "package hook snippets"

source_init_xraywrt_lib
procd_add_reload_trigger() { printf '%s\n' "$@" >"$tmpdir/reload-triggers"; }
service_triggers
assert_eq $'xraywrt\ndhcp' "$(cat "$tmpdir/reload-triggers")" "service reloads for XrayWRT and DHCP changes"
SKIP_START_FILE="$skip_start"
XRAYWRT_CLI="$tmpdir/xraywrt"
procd_open_instance() { printf 'procd:open\n' >>"$hook_log"; }
procd_set_param() { :; }
procd_close_instance() { :; }
: >"$skip_start"
: >"$hook_log"
start_service
[[ ! -e "$skip_start" ]] || fail "start_service should consume the skip marker"
assert_file_not_contains "$hook_log" "xraywrt:prepare" "skipped start should not prepare"
: >"$skip_start"
touch -d '2024-01-01 00:00:00' "$skip_start"
start_service
assert_file_contains "$hook_log" "xraywrt:prepare" "a stale marker (failed install) must not block Start"
[[ ! -e "$skip_start" ]] || fail "stale marker removed"
: >"$hook_log"
assert_file_not_contains "$hook_log" "xraywrt:prepare" "skipped start should not prepare"
start_service
assert_file_contains "$hook_log" "xraywrt:prepare" "next start should run normally"
assert_file_contains "$hook_log" "procd:open" "next start should launch the service"
pass "default postinst start skipped once"

assert_eq null "$(jq -c '."luci-app-xraywrt".read.file["/opt/xraywrt/lst/direct_src.txt"]' "$acl_file")" "fourth list read ACL"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/xraywrt/lst/$$$$list.txt' "fourth list packaged"
assert_file_not_contains "$ROOT_DIR/rootfs/www/luci-static/resources/view/xraywrt/traffic.js" LIST_FILES 'lists uses lists-json, not direct files'
assert_file_contains "$ROOT_DIR/rootfs/www/luci-static/resources/view/xraywrt/traffic.js" "api.readLarge('lists-json')" 'lists reads large JSON through CGI helper'

# Exercise the actual CLI/modules in ash, with all system paths in a fixture.
uninstall_root="$tmpdir/uninstall"
mkdir -p "$uninstall_root/lib" "$uninstall_root/opt/xraywrt/bin" "$uninstall_root/opt/xraywrt/ui" \
	"$uninstall_root/opt/xraywrt/lst" "$uninstall_root/etc/xraywrt/policy-cache" \
	"$uninstall_root/etc/config" "$uninstall_root/etc/init.d" "$uninstall_root/tmp/dnsmasq.test.d" \
	"$uninstall_root/tmp/clash/ruleset" "$uninstall_root/tmp/clash/proxy_providers" \
	"$uninstall_root/tmp/clash/proxies" "$uninstall_root/tmp/clash/rules" \
	"$uninstall_root/var/run/xraywrt" "$uninstall_root/tmp/xraywrt" "$uninstall_root/etc/crontabs"
for module in "$XRAYWRT_LIB_DIR"/*.sh; do
	sed -e "s|/opt/xraywrt|@ROOT@/opt/xraywrt|g" \
		-e "s|/etc/|@ROOT@/etc/|g" \
		-e "s|/tmp/|@ROOT@/tmp/|g" \
		-e "s|/var/run/xraywrt|@ROOT@/var/run/xraywrt|g" \
		-e "s|/usr/share/nftables.d|@ROOT@/usr/share/nftables.d|g" \
		-e "s|@ROOT@|$uninstall_root|g" \
		"$module" >"$uninstall_root/lib/${module##*/}"
done
# Recovery still uses real dns_cleanup; nft/routes have no host effects.
cat >>"$uninstall_root/lib/service.sh" <<'EOF'
service_pid() { return 1; }
nft_cleanup() { :; }
route_cleanup() { :; }
fw4() { echo "fw4:$*" >>"$XRAY_DIR/../../actions"; }
nft() { [ "$*" = 'list table inet fw4' ]; }
EOF
cat >"$uninstall_root/etc/init.d/xraywrt" <<EOF
#!/bin/ash
[ ! -e /proc/self/fd/9 ] || exit 1
printf 'init:%s\n' "\$*" >>"$uninstall_root/actions"
EOF
for daemon in cron dnsmasq; do
	printf '#!/bin/ash\necho "%s:$*" >>"%s/actions"\n' "$daemon" "$uninstall_root" >"$uninstall_root/etc/init.d/$daemon"
done
chmod +x "$uninstall_root/etc/init.d/"*
mkdir -p "$uninstall_root/opt/xraywrt/share"
for removed in bin/xray share/geoip.dat share/geosite.dat share/.manual; do
	touch "$uninstall_root/opt/xraywrt/$removed"
done
for removed in subscription.json core.json policy-cache/x; do
	touch "$uninstall_root/etc/xraywrt/$removed"
done
mkdir -p "$uninstall_root/opt/clash/bin"
for kept in opt/xraywrt/config.json opt/xraywrt/config.json.bak opt/xraywrt/lst/custom.txt opt/xraywrt/manual.txt etc/config/xraywrt etc/xraywrt/hwid opt/clash/bin/clash opt/clash/config.json opt/clash/GeoIP.dat opt/clash/mihomo.sock tmp/clash/mihomo.sock; do
	printf 'keep\n' >"$uninstall_root/$kept"
done
# Directories the core may write in its own dir are user data now: no tmpfs links.
for name in ruleset proxy_providers proxies rules; do
	mkdir -p "$uninstall_root/opt/xraywrt/$name"
	printf 'keep\n' >"$uninstall_root/opt/xraywrt/$name/user.json"
done
printf '0 * * * * user-job\n0 * * * * /usr/bin/xraywrt auto-update # xraywrt auto-update\n' >"$uninstall_root/etc/crontabs/root"
touch "$uninstall_root/tmp/dnsmasq.test.d/xraywrt.conf"
mkdir -p "$uninstall_root/usr/share/nftables.d/chain-pre/input"
printf 'guest input rules\n' >"$uninstall_root/usr/share/nftables.d/chain-pre/input/30-xraywrt.nft"
sed "s|/etc/init.d/xraywrt|$uninstall_root/etc/init.d/xraywrt|g" "$ROOT_DIR/rootfs/usr/bin/xraywrt" >"$uninstall_root/cli"
XRAYWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall
assert_eq 'init:stop' "$(head -n 1 "$uninstall_root/actions")" "uninstall stops first, outside runtime lock"
assert_false 'uninstall removes fw4 input include even with a lingering policy' test -e "$uninstall_root/usr/share/nftables.d/chain-pre/input/30-xraywrt.nft"
assert_eq 1 "$(grep -c '^fw4:reload$' "$uninstall_root/actions")" 'uninstall reloads fw4 after removing include'
for removed in bin/xray share; do
	[[ ! -e "$uninstall_root/opt/xraywrt/$removed" && ! -L "$uninstall_root/opt/xraywrt/$removed" ]] || fail "uninstall removes $removed"
done
for removed in etc/xraywrt/subscription.json etc/xraywrt/core.json etc/xraywrt/policy-cache tmp/xraywrt var/run/xraywrt tmp/dnsmasq.test.d/xraywrt.conf; do
	[[ ! -e "$uninstall_root/$removed" ]] || fail "uninstall removes $removed"
done
for kept in opt/xraywrt/config.json opt/xraywrt/config.json.bak opt/xraywrt/lst/custom.txt opt/xraywrt/manual.txt opt/xraywrt/ruleset/user.json opt/xraywrt/proxy_providers/user.json opt/xraywrt/proxies/user.json opt/xraywrt/rules/user.json etc/config/xraywrt etc/xraywrt/hwid opt/clash/bin/clash opt/clash/config.json opt/clash/GeoIP.dat opt/clash/mihomo.sock tmp/clash/mihomo.sock; do
	assert_file_contains "$uninstall_root/$kept" keep "uninstall keeps $kept"
done
assert_eq '0 * * * * user-job' "$(cat "$uninstall_root/etc/crontabs/root")" "uninstall keeps unrelated cron jobs"
assert_eq 1 "$(grep -c '^cron:restart$' "$uninstall_root/actions")" "uninstall restarts cron once"
assert_eq 1 "$(grep -c '^dnsmasq:restart$' "$uninstall_root/actions")" "uninstall restores DNS once"
pass "uninstall removes generated assets and keeps user files"

# A lingering supervisor must not leave the router pointing at a deleted core.
# Keep markers outside removed directories to prove their explicit removal.
cat >>"$uninstall_root/lib/service.sh" <<'EOF_STUBS'
pgrep() { return 0; }
RUNNING_MARKER="$XRAY_DIR/test-running"
SERVICE_PID_FILE="$XRAY_DIR/test-pid"
dns_cleanup() { [ -e /proc/self/fd/9 ] || return 1; echo dns >>"$XRAY_DIR/cleanup-calls"; }
nft_cleanup() { echo nft >>"$XRAY_DIR/cleanup-calls"; }
route_cleanup() { echo route >>"$XRAY_DIR/cleanup-calls"; }
EOF_STUBS
touch "$uninstall_root/opt/xraywrt/test-running" "$uninstall_root/opt/xraywrt/test-pid"
for name in proxies rules; do
 mkdir -p "$uninstall_root/opt/xraywrt/$name"
 printf 'legacy cache\n' >"$uninstall_root/opt/xraywrt/$name/provider"
done
XRAYWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall
assert_eq $'dns\nnft\nroute' "$(cat "$uninstall_root/opt/xraywrt/cleanup-calls" 2>/dev/null || true)" "lingering supervisor still restores DNS/nft/routes under lock"
for marker in test-running test-pid; do
	[[ ! -e "$uninstall_root/opt/xraywrt/$marker" ]] || fail "uninstall explicitly removes $marker"
done
for name in proxies rules; do
	assert_file_contains "$uninstall_root/opt/xraywrt/$name/provider" 'legacy cache' "uninstall keeps a real $name directory with its files"
done
pass "uninstall restores router state despite lingering supervisor"

cat >>"$uninstall_root/lib/service.sh" <<'EOF_STUBS'
cron_sync() { return 1; }
EOF_STUBS
mkdir -p "$uninstall_root/opt/xraywrt/share"
touch "$uninstall_root/opt/xraywrt/bin/xray" "$uninstall_root/opt/xraywrt/share/geoip.dat"
rc=0
XRAYWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall || rc=$?
assert_eq 1 "$rc" "uninstall reports cron cleanup failure"
[[ ! -e "$uninstall_root/opt/xraywrt/bin/xray" ]] || fail "cron failure must not skip core deletion"
[[ ! -e "$uninstall_root/opt/xraywrt/share" ]] || fail "cron failure must not skip geodata deletion"
pass "uninstall continues deletions after cron failure"

# Spec 3: XrayWRT owns /opt/xraywrt and /tmp/xraywrt; MihoWRT paths stay untouched.
hits="$(grep -rnE '/opt/clash|/tmp/clash|\bCLASH_(BIN|DIR)\b|MIHOMO_(REPO|RELEASES_API)' "$ROOT_DIR/rootfs" "$ROOT_DIR/Makefile" "$ROOT_DIR/install.sh" "$ROOT_DIR/tools" "$ROOT_DIR/.github" || true)"
assert_eq '' "$hits" 'no MihoWRT core paths or constants'
(
	source "$ROOT_DIR/rootfs/usr/lib/xraywrt/constants.sh"
	assert_eq '/opt/xraywrt:/opt/xraywrt/bin/xray:/opt/xraywrt/lst' "$XRAY_DIR:$XRAY_BIN:$LIST_DIR" 'Xray paths'
)
[ -d "$ROOT_DIR/rootfs/opt/xraywrt/lst" ] && [ ! -e "$ROOT_DIR/rootfs/opt/clash" ] || fail 'package tree ships /opt/xraywrt'
pass 'XrayWRT core paths'

# xraywrt-core postinst: one restart, only for a core that still runs the replaced binary.
core_hook="$tmpdir/core-postinst.sh"
core_proc="$tmpdir/core-proc"
core_state="$tmpdir/core-state"
core_restarts="$tmpdir/core-restarts"
printf '#!/bin/sh\necho restart >>"%s"\n' "$core_restarts" >"$tmpdir/core-init"
chmod +x "$tmpdir/core-init"
awk '$0=="define Package/$(PKG_NAME)/postinst" { in_block=1; next } in_block && $0=="endef" { exit } in_block { print }' "$ROOT_DIR/core/Makefile" |
	sed 's/\$\$/$/g' >"$tmpdir/core-postinst.raw"
assert_file_contains "$tmpdir/core-postinst.raw" ') </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- &' "core hook runs as a detached job without apk's fds"
# Fake /proc and state dir; the job runs in the foreground and without the delay.
sed \
	-e "s|/var/run/xraywrt|$core_state|g" \
	-e "s|/proc/|$core_proc/|g" \
	-e "s|/etc/init.d/xraywrt|$tmpdir/core-init|" \
	-e 's|^\t\ti=0; while pidof apk .*$|\t\ttrue|' \
	-e 's|^\t) </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- &$|\t) </dev/null >/dev/null 2>\&1|' \
	"$tmpdir/core-postinst.raw" >"$core_hook"
assert_file_contains "$core_hook" "$tmpdir/core-init restart" "core hook test rewrites the restart command"
run_core_hook() {
	local exe="$1" pid_file="$2" lock="${3:-free}" lock_pid=""

	rm -rf "$core_proc" "$core_state" "$core_restarts"
	mkdir -p "$core_state" "$core_proc/4242"
	[[ -z "$exe" ]] || ln -s "$exe" "$core_proc/4242/exe"
	[[ -z "$pid_file" ]] || echo 4242 >"$core_state/xray.pid"
	if [[ "$lock" == held ]]; then
		flock -x "$core_state/core.flock" sleep 5 &
		lock_pid=$!
		sleep 0.3
	fi
	ash "$core_hook"
	[[ -z "$lock_pid" ]] || { kill "$lock_pid" 2>/dev/null; wait "$lock_pid" 2>/dev/null || true; }
	if [[ -f "$core_restarts" ]]; then wc -l <"$core_restarts" | tr -d ' '; else echo 0; fi
}
assert_eq 1 "$(run_core_hook '/opt/xraywrt/bin/xray (deleted)' yes)" 'core replaced under a running core: one restart'
assert_eq 0 "$(run_core_hook '/opt/xraywrt/bin/xray' yes)" 'core already on the new binary (the app restarted it): no restart'
assert_eq 0 "$(run_core_hook '' '')" 'service stopped (no pid file): no restart'
assert_eq 0 "$(run_core_hook '' yes)" 'stale pid file: no restart'
assert_eq 0 "$(run_core_hook '/opt/xraywrt/bin/xray (deleted)' yes held)" "the app's own core update holds core.flock: no restart"
pass "core postinst restarts once, only a core on the replaced binary"
