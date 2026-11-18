#!/bin/ash

# XrayWRT core install/update from its release package.
# The candidate is checked in a RAM stage before the flash copy is touched.

# OpenWrt package architecture (DISTRIB_ARCH, e.g. aarch64_cortex-a53).
openwrt_arch() {
	sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" "$OPENWRT_RELEASE_FILE" 2>/dev/null | head -n 1
}

# Xray version of a binary: `<bin> version` exits 0 and its first line is
# "Xray <version> ...". Only the installed core's answer is cached: line 1
# the version, line 2 the file's inode, size and ctime (apk keeps the packaged
# mtime, so a replaced core can be older than the cache).
core_version() {
	local binary="${1:-$XRAY_BIN}" out="" version="" stamp=""

	[ -x "$binary" ] || return 1
	if [ "$binary" = "$XRAY_BIN" ]; then
		stamp="$(ls -lic --full-time "$binary" 2>/dev/null)"
		if [ -n "$stamp" ] && [ -f "$CORE_VERSION_CACHE" ] && [ "$(sed -n 2p "$CORE_VERSION_CACHE")" = "$stamp" ]; then
			sed -n 1p "$CORE_VERSION_CACHE"
			return 0
		fi
	fi
	out="$("$binary" version 2>/dev/null)" || return 1
	version="$(printf '%s\n' "$out" | awk 'NR == 1 && $1 == "Xray" { for (i = 3; i <= NF; i++) if ($i ~ /^[a-z]+-[0-9]+\.[0-9]+\.[0-9]+$/) { sub(/^[a-z]+-/, "", $i); print $i; exit } print $2; exit }')"
	is_valid_core_tag "$version" || return 1
	if [ "$binary" = "$XRAY_BIN" ]; then
		ensure_dir "$PKG_STATE_DIR" && atomic_write "$CORE_VERSION_CACHE" "$version
$stamp"
	fi
	printf '%s\n' "$version"
}

# The marker (<name>-x.y.z in field 3+ of the first line) identifies the core's compatibility, not the publisher of a local file.
core_pkg_version() {
	local out="" version=""

	out="$("$1" version 2>/dev/null)" || return 1
	version="$(printf '%s\n' "$out" | awk 'NR == 1 && $1 == "Xray" { for (i = 3; i <= NF; i++) if ($i ~ /^[a-z]+-[0-9]+\.[0-9]+\.[0-9]+$/) { sub(/^[a-z]+-/, "", $i); print $i; exit } }')"
	[ -n "$version" ] || return 1
	printf '%s\n' "$version"
}

core_version_json() {
	local version=""

	version="$(core_version)"
	xraywrt-json build version --arg v "$version"
}

# core_fetch_verified <url> <out> <limit> <sha256> [size]: <url> over
# github_routes (spec 4.1); every body must match sha256 (and size), a
# rejected one is removed. CORE_FETCH_ERROR: the first route's error, a
# FETCH_ERROR, size or sha256.
core_fetch_verified() {
	local url="" error="" name="${1##*/}"

	CORE_FETCH_ERROR=""
	while read -r url; do
		if ! http_fetch "$url" "$2" "$3" core 0 </dev/null; then
			error="$FETCH_ERROR"
		elif [ -n "${5:-}" ] && [ "$(wc -c <"$2" | tr -d ' ')" != "$5" ]; then
			error=size
		elif [ "$(sha256sum "$2" | cut -d' ' -f1)" != "$4" ]; then
			error=sha256
		else
			log "Core update: $name from $(url_host "$url")"
			return 0
		fi
		rm -f "$2"
		warn "Core update: $name from $(url_host "$url"): $error"
		[ -n "$CORE_FETCH_ERROR" ] || CORE_FETCH_ERROR="$error"
	done <<EOF
$(github_routes "$1")
EOF
	return 1
}

# core_asset_fetch [name]: download CORE_URL into the RAM stage
# ($CORE_TMP_DIR/<name>, default xray) and verify it against CORE_SHA256 (and
# CORE_SIZE when published). The stage needs MemAvailable >= size + 16 MiB;
# an unknown size is capped to that budget.
core_asset_fetch() {
	local out="$CORE_TMP_DIR/${1:-xray}" avail="" limit="$CORE_ASSET_MAX_BYTES" size="" need=0

	CORE_ERROR=""
	is_uint "$CORE_SIZE" && need="$(uint_norm "$CORE_SIZE")" && size="$need"
	if [ "$need" -gt "$CORE_ASSET_MAX_BYTES" ]; then
		CORE_ERROR="asset $CORE_ASSET is too large ($CORE_SIZE bytes, limit $CORE_ASSET_MAX_BYTES)"
		return 1
	fi
	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	is_uint "$avail" || {
		CORE_ERROR="cannot check free RAM"
		return 1
	}
	avail=$(($(uint_norm "$avail") * 1024 - 16777216))
	if [ "$avail" -lt "$need" ] || [ "$avail" -le 0 ]; then
		CORE_ERROR="$(code_message core_ram "not enough RAM: need %s MiB, available %s MiB" "$(((need + 16777216 + 1048575) / 1048576))" "$(((avail + 16777216) / 1048576))")"
		return 1
	fi
	[ "$avail" -ge "$limit" ] || limit="$avail"
	# A published size caps the download: no extra bytes reach tmpfs.
	[ "$need" -le 0 ] || limit="$need"
	ensure_dir "$CORE_TMP_DIR" || return 1
	core_fetch_verified "$CORE_URL" "$out" "$limit" "$CORE_SHA256" "$size" && return 0
	case "$CORE_FETCH_ERROR" in
	sha256) CORE_ERROR="$(code_message core_damaged "sha256 mismatch")" ;;
	size) CORE_ERROR="$(code_message core_damaged "downloaded size does not match release")" ;;
	too_large)
		if [ "$need" -gt 0 ]; then
			CORE_ERROR="$(code_message core_damaged "downloaded size does not match release")"
		elif [ "$limit" -lt "$CORE_ASSET_MAX_BYTES" ]; then
			CORE_ERROR="not enough RAM for $CORE_ASSET"
		else
			CORE_ERROR="asset $CORE_ASSET is too large (limit $CORE_ASSET_MAX_BYTES)"
		fi
		;;
	*) CORE_ERROR="$(code_message core_download "%s" "download failed ($CORE_FETCH_ERROR)")" ;;
	esac
	return 1
}

core_free_kb() {
	df -k "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

core_fail() {
	CORE_ERROR="$*"
	err "Core update: $*"
	rm -rf "$CORE_TMP_DIR" "$XRAY_BIN.new" "$XRAY_BIN.old"
	return 1
}

# Service control of the low-flash path. Runs under core.flock only: the
# init script takes the runtime lock itself.
core_service_stop() {
	XRAYWRT_UPDATE_CONTROL=1 /etc/init.d/xraywrt stop 9>&- >/dev/null 2>&1
}

core_service_start() {
	[ ! -f "$USER_STOP_FILE" ] || return 0
	# A stale start error must not end the wait early.
	rm -f "$LAST_ERROR_FILE"
	XRAYWRT_UPDATE_CONTROL=1 /etc/init.d/xraywrt start 9>&- >/dev/null 2>&1 || return 1
	core_wait_ready
}

# Ready = run_service applied the policy to a live core (spec 9.1 waits
# 30 s for the ports); a recorded start error ends the wait at once.
core_wait_ready() {
	local i=0

	while ! service_ready; do
		[ ! -f "$USER_STOP_FILE" ] || return 0
		[ ! -s "$LAST_ERROR_FILE" ] && [ "$i" -lt "$CORE_READY_WAIT" ] || return 1
		sleep 1
		i=$((i + 1))
	done
}

# core_old_copy <size>: RAM copy of the current core ($CORE_TMP_DIR/xray.old)
# for a rollback; needs MemAvailable > size + 16 MiB.
core_old_copy() {
	local avail=""

	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	is_uint "$avail" || {
		CORE_ERROR="cannot check free RAM"
		return 1
	}
	avail=$(($(uint_norm "$avail") * 1024))
	[ "$avail" -gt $(($1 + 16777216)) ] || {
		CORE_ERROR="$(code_message core_rollback_ram "%s" "not enough RAM for a rollback copy of the old core: need $((($1 + 16777216 + 1048575) / 1048576)) MiB, available $((avail / 1048576)) MiB; --no-rollback installs without it")"
		return 1
	}
	cp "$XRAY_BIN" "$CORE_TMP_DIR/xray.old" 2>/dev/null &&
		[ "$(sha256sum "$CORE_TMP_DIR/xray.old" | cut -d' ' -f1)" = "$(sha256sum "$XRAY_BIN" | cut -d' ' -f1)" ] || {
		CORE_ERROR="cannot copy the old core to RAM for rollback"
		return 1
	}
}

# Put the old core back (the flash hardlink $XRAY_BIN.old, else the RAM copy)
# and start it if it was running. Appends the outcome to CORE_ERROR.
core_rollback() {
	local restart="$1" restored=0

	rm -f "$XRAY_BIN.new"
	if [ -f "$XRAY_BIN.old" ]; then
		mv -f "$XRAY_BIN.old" "$XRAY_BIN" && restored=1
	elif cp "$CORE_TMP_DIR/xray.old" "$XRAY_BIN.restore" && chmod 755 "$XRAY_BIN.restore" && sync && mv -f "$XRAY_BIN.restore" "$XRAY_BIN"; then
		restored=1
	fi
	if [ "$restored" = 0 ]; then
		rm -f "$XRAY_BIN.restore"
		CORE_ERROR="$(code_message core_restore_failed "%s; the previous core could not be restored, run core-update again" "${CORE_ERROR% \[E:*}")"
		return 1
	fi
	if [ "$restart" = 1 ] && ! core_service_start; then
		CORE_ERROR="$(code_message core_restore_unready "%s; previous core restored, but it did not start either" "${CORE_ERROR% \[E:*}")"
		return 1
	fi
	CORE_ERROR="$(code_message core_restored "%s, previous core restored" "${CORE_ERROR% \[E:*}")"
}

# Field list ($1, e.g. source:channel:tag) of core.json, ':'-joined; empty
# fields without the file.
core_json_get() {
	if [ -f "$CORE_JSON_FILE" ]; then
		xraywrt-json get "$1" empty "$CORE_JSON_FILE" 2>/dev/null
	else
		printf '%s\n' "$1" | tr -cd :
		echo
	fi
}

# Router-only base config for `run -test` while there is no config.json.
# shortcut: fixed tunnel + freedom JSON, not the generator's router sections
# (the generator needs provider outbounds); upgrade if the spec names a source.
core_base_config_write() {
	printf '{"inbounds":[{"listen":"127.0.0.1","port":%s,"protocol":"tunnel","settings":{"network":"tcp,udp"}}],"outbounds":[{"protocol":"freedom"}]}\n' "$XRAY_DNS_PORT" >"$1"
}

# A package candidate must accept the current runtime before publication.
core_candidate_test() {
	local test_config="$CORE_TMP_DIR/test.json" out="" ref=""

	if [ -f "$XRAY_CONFIG" ]; then
		if ! { settings_require && xray_config_generate "$XRAY_CONFIG" "$test_config" 2>"$test_config.err"; }; then
			CORE_ERROR="cannot generate the runtime config: $(awk 'NF { l = $0 } END { sub(/^Error: /, "", l); print l }' "$test_config.err")"
			return 1
		fi
		# Geodata missing from share/ (reinstall after uninstall) is fetched at
		# service start; it must not block the core: test the base config then.
		while read -r ref; do
			[ -z "$ref" ] || [ -f "$XRAY_SHARE_DIR/$ref" ] && continue
			core_base_config_write "$test_config" || { CORE_ERROR="cannot write test config"; return 1; }
			break
		done <<EOF
$(sed -n 's/^geodata-ref //p' "$test_config.profile")
EOF
	else
		core_base_config_write "$test_config" || { CORE_ERROR="cannot write test config"; return 1; }
	fi
	out="$(XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$1" run -test -c "$test_config" 2>&1)" || {
		CORE_ERROR="$(code_message core_config "new core rejects the current config: %s" "$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }')")"
		return 1
	}
}

# core_update [--no-rollback]: install the XrayWRT core from the release
# package after `version` and `run -test` pass. Sets
# CORE_UPDATED/CORE_VERIFIED/CORE_RESTARTED (0|1), CORE_VERSION,
# CORE_SHA256, CORE_ERROR. CORE_RESTARTED=1: the low-flash path already
# restarted the service.
core_update() {
	local old="" rollback=1

	CORE_UPDATED=0 CORE_VERIFIED=0 CORE_RESTARTED=0 CORE_ERROR="" CORE_SHA256="" CORE_TAG="" CORE_ASSET="" CORE_SIZE=""
	while [ $# -ge 1 ]; do
		case "$1" in
		--no-rollback) rollback=0 ;;
		*) break ;;
		esac
		shift
	done
	[ $# -eq 0 ] ||
		core_fail "usage: core-update [--no-rollback]" || return 1
	rm -rf "$CORE_TMP_DIR" "$XRAY_BIN.new" "$XRAY_BIN.old"
	# A package core reports its package version, a channel core its tag.
	old="$(core_json_get version)"
	[ -n "$old" ] || old="$(core_json_get tag)"
	[ -n "$old" ] || old="$(core_version)" || old=""
	CORE_VERSION="$old"
	settings_load 2>/dev/null || true
	ensure_dir "$CORE_TMP_DIR" || core_fail "cannot create $CORE_TMP_DIR" || return 1
	core_pkg_update "$rollback"
}

# Spec 4.5: latest core release, asset xraywrt-core_<version>_<arch>.apk
# (<arch> = DISTRIB_ARCH: one static binary in a package per aarch64 package
# architecture), sha256 from the API digest, or without the
# API from SHA256SUMS-core. Sets CORE_TAG, CORE_ASSET, CORE_URL, CORE_SIZE,
# CORE_SHA256, CORE_PKG_VERSION; CORE_ERROR on failure.
core_pkg_resolve() {
	local json="$CORE_TMP_DIR/release.json" arch="" meta="" digest="" repo="$XRAYWRT_CORE_RELEASE_REPO"

	CORE_TAG="" CORE_ASSET="" CORE_URL="" CORE_SIZE="" CORE_SHA256="" CORE_PKG_VERSION="" CORE_ERROR=""
	arch="$(openwrt_arch)"
	case "$arch" in
	'' | *[!A-Za-z0-9._-]*)
		CORE_ERROR="cannot read the package architecture (DISTRIB_ARCH in $OPENWRT_RELEASE_FILE)"
		return 1
		;;
	esac
	ensure_dir "$CORE_TMP_DIR" || return 1
	if http_fetch "https://api.github.com/repos/$repo/releases/latest" "$json" "$CORE_RELEASE_JSON_MAX_BYTES" 30 0; then
		CORE_TAG="$(xraywrt-json get tag_name empty "$json")"
		# Versions have no '_': the architecture follows the second '_'.
		meta="$(xraywrt-json assets "$json" | awk -F '\t' -v p="${CORE_PACKAGE}_" -v a="$arch.apk" \
			'{ r = substr($1, length(p) + 1) } index($1, p) == 1 && sub(/^[^_]*_/, "", r) && r == a { print; exit }')"
		rm -f "$json"
		is_valid_core_tag "$CORE_TAG" || {
			CORE_TAG="" CORE_ERROR="release $repo has no valid release tag"
			return 1
		}
		[ -n "$meta" ] || {
			CORE_ERROR="$(code_message core_arch "The core is not available for this router (%s); the current core is kept." "$arch")"
			return 1
		}
		CORE_ASSET="$(printf '%s' "$meta" | cut -f1)"
		digest="$(printf '%s' "$meta" | cut -f2)"
		CORE_SIZE="$(printf '%s' "$meta" | cut -f3)"
		is_sha256_hex "${digest#sha256:}" && [ "${digest#sha256:}" != "$digest" ] && CORE_SHA256="${digest#sha256:}"
	else
		rm -f "$json"
		case "$FETCH_ERROR" in
		network | http_403 | http_429 | http_5??) core_pkg_resolve_direct "$arch" || return 1 ;;
		http_404)
			CORE_ERROR="release $repo has no releases (GitHub API: http_404)"
			return 1
			;;
		*)
			CORE_ERROR="$(code_message core_download "%s" "cannot read the latest release of $repo (GitHub API: $FETCH_ERROR)")"
			return 1
			;;
		esac
	fi
	CORE_PKG_VERSION="${CORE_ASSET#"${CORE_PACKAGE}_"}"
	CORE_PKG_VERSION="${CORE_PKG_VERSION%"_$arch.apk"}"
	is_valid_core_tag "$CORE_PKG_VERSION" || {
		CORE_ERROR="release $repo@$CORE_TAG has an invalid package version in $CORE_ASSET"
		return 1
	}
	case "$CORE_ASSET" in
	*[!A-Za-z0-9._+-]*) CORE_ERROR="release $repo@$CORE_TAG has an invalid asset name"; return 1 ;;
	esac
	CORE_URL="https://github.com/$repo/releases/download/$CORE_TAG/$CORE_ASSET"
	case "$CORE_URL" in
	https://*) ;;
	*)
		CORE_ERROR="release $repo@$CORE_TAG publishes a non-https URL for $CORE_ASSET"
		return 1
		;;
	esac
	[ -n "$CORE_SHA256" ] || {
		CORE_ERROR="$(code_message core_no_checksum "%s" "release $repo@$CORE_TAG publishes no sha256 for $CORE_ASSET")"
		return 1
	}
}

# core_pkg_resolve_direct <arch>: API unavailable. Tag from the github.com
# redirect, sha256 from the one SHA256SUMS-core line of <arch> (spec 4.5),
# both directly from github.com; size unknown.
core_pkg_resolve_direct() {
	local arch="$1" repo="$XRAYWRT_CORE_RELEASE_REPO" api_error="$FETCH_ERROR" sums="$CORE_TMP_DIR/SHA256SUMS-core" lines=""

	warn "Core update: GitHub API unavailable ($api_error); using github.com"
	CORE_TAG="$(github_latest_tag "$repo")" || {
		CORE_TAG=""
		CORE_ERROR="$(code_message core_download "%s" "cannot reach GitHub (API: $api_error)")"
		return 1
	}
	is_valid_core_tag "$CORE_TAG" || {
		CORE_TAG="" CORE_ERROR="release $repo has no valid release tag"
		return 1
	}
	http_fetch "https://github.com/$repo/releases/download/$CORE_TAG/SHA256SUMS-core" "$sums" 65536 30 0 || {
		CORE_ERROR="release $repo@$CORE_TAG has no SHA256SUMS-core ($FETCH_ERROR); GitHub API unavailable ($api_error): retry later"
		return 1
	}
	# Versions have no '_': the architecture follows the second '_'.
	lines="$(awk -v p="${CORE_PACKAGE}_" -v a="$arch.apk" '{ f = $2; sub(/^\*/, "", f); r = substr(f, length(p) + 1) }
		index(f, p) == 1 && sub(/^[^_]*_/, "", r) && r == a { print $1 " " f }' "$sums")"
	rm -f "$sums"
	case "$lines" in
	'')
		CORE_ERROR="$(code_message core_arch "The core is not available for this router (%s); the current core is kept." "$arch")"
		return 1
		;;
	*"
"*)
		CORE_ERROR="release $repo@$CORE_TAG lists more than one ${CORE_PACKAGE}_<version>_$arch.apk in SHA256SUMS-core"
		return 1
		;;
	esac
	CORE_ASSET="${lines#* }"
	# A bad hash leaves CORE_SHA256 empty: core_pkg_resolve refuses it.
	! is_sha256_hex "${lines%% *}" || CORE_SHA256="${lines%% *}"
}

# The installed package's .apk by tag/asset from core.json into
# $CORE_TMP_DIR/old.apk, verified by its sha256 (spec 4.5 rollback).
# Needs MemAvailable > size + 16 MiB. Sets CORE_OLD_ERROR on failure.
core_pkg_old_fetch() {
	local fields="" source="" tag="" asset="" sha="" size="" avail="" repo="" out="$CORE_TMP_DIR/old.apk"

	CORE_OLD_ERROR=""
	fields="$(core_json_get source:tag:asset:sha256:size)"
	source="${fields%%:*}" fields="${fields#*:}"
	tag="${fields%%:*}" fields="${fields#*:}"
	asset="${fields%%:*}" fields="${fields#*:}"
	sha="${fields%%:*}" size="${fields#*:}"
	case "$asset" in "${CORE_PACKAGE}_"*.apk) ;; *) asset="" ;; esac
	case "$asset" in *[!A-Za-z0-9._+-]*) asset="" ;; esac
	if ! { [ "$source" = package ] && is_valid_core_tag "$tag" && [ -n "$asset" ] && is_sha256_hex "$sha" && is_uint "$size"; }; then
		CORE_OLD_ERROR="core.json does not name the installed package for a rollback"
		return 1
	fi
	repo="$(xraywrt-json core-repo "$CORE_JSON_FILE" 2>/dev/null)" || repo=""
	case "$repo" in "$XRAYWRT_RELEASE_REPO" | "$XRAYWRT_CORE_RELEASE_REPO") ;; *)
		CORE_OLD_ERROR="core.json has an invalid rollback repository"
		return 1 ;; esac
	size="$(uint_norm "$size")"
	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	is_uint "$avail" && [ $(($(uint_norm "$avail") * 1024)) -gt $((size + 16777216)) ] || {
		CORE_OLD_ERROR="not enough RAM for the rollback copy $asset: need $(((size + 16777216 + 1048575) / 1048576)) MiB"
		return 1
	}
	core_fetch_verified "https://github.com/$repo/releases/download/$tag/$asset" "$out" "$size" "$sha" "$size" || {
		case "$CORE_FETCH_ERROR" in
		sha256 | size) CORE_OLD_ERROR="the downloaded rollback package $asset does not match core.json" ;;
		*) CORE_OLD_ERROR="cannot download the installed package $asset for a rollback ($CORE_FETCH_ERROR)" ;;
		esac
		return 1
	}
}

# core_pkg_restore <start>: remove the new package, put the previous core
# back (old .apk, or the RAM copy of a channel/file core) and start it when
# <start>=1. Appends the outcome to CORE_ERROR.
core_pkg_restore() {
	local start="$1"

	! core_package_installed || pkg_remove "$CORE_PACKAGE" >/dev/null 2>&1
	if [ -f "$CORE_TMP_DIR/xray.old" ]; then
		core_rollback "$start"
		return
	fi
	if [ ! -f "$CORE_TMP_DIR/old.apk" ] ||
		! pkg_install_file "$CORE_TMP_DIR/old.apk" >/dev/null 2>&1; then
		CORE_ERROR="$(code_message core_restore_failed "%s; the previous core could not be restored, run core-update again" "${CORE_ERROR% \[E:*}")"
		return 1
	fi
	rm -f "$CORE_VERSION_CACHE"
	if [ "$start" = 1 ] && ! core_service_start; then
		CORE_ERROR="$(code_message core_restore_unready "%s; previous core restored, but it did not start either" "${CORE_ERROR% \[E:*}")"
		return 1
	fi
	CORE_ERROR="$(code_message core_restored "%s, previous core restored" "${CORE_ERROR% \[E:*}")"
}

# One line of a package-manager error output.
core_apk_text() {
	printf '%s\n' "$1" | awk 'NF { $1 = $1; s = s (s == "" ? "" : " ") $0 } END { print s }'
}

# core_json_record <package-file-size>: remember the release package that is
# installed; the next update takes its rollback copy from this record.
core_json_record() {
	if ! { ensure_dir "${CORE_JSON_FILE%/*}" &&
		atomic_write "$CORE_JSON_FILE" "$(xraywrt-json build object --arg tag "$CORE_TAG" \
			--arg asset "$CORE_ASSET" --arg sha256 "$CORE_SHA256" --argjson size "$1" \
			--arg version "$CORE_PKG_VERSION" --arg repo "$XRAYWRT_CORE_RELEASE_REPO" --arg source package --argjson installed_at "$(date +%s)")"; }; then
		warn "Core update: cannot write $CORE_JSON_FILE"
	fi
}

# core_pkg_update <rollback>: install or update the xraywrt-core package
# (spec 4.5). Normal path: apk add over the old package. Tight flash (room
# only without the old package): the old .apk is the rollback, apk del
# first. A channel/file core is removed before apk add, its RAM copy is the
# rollback. The service restarts here and must become ready.
core_pkg_update() {
	local rollback="$1" candidate_version="" new="$CORE_TMP_DIR/new.apk" size="" free="" old_size=0 tight=0 had_pkg=0 same=0 was_running=0 out=""

	core_pkg_resolve || core_fail "$CORE_ERROR" || return 1
	core_package_installed && had_pkg=1
	[ "$had_pkg" = 1 ] && [ "$(pkg_version "$CORE_PACKAGE")" = "$CORE_PKG_VERSION" ] && same=1
	if [ "$same" = 1 ] && [ -x "$XRAY_BIN" ]; then
		# Added by hand or after a reinstall of the app: no record yet. An unknown size (no API) cannot be recorded.
		if [ ! -f "$CORE_JSON_FILE" ] && is_uint "$CORE_SIZE"; then
			core_json_record "$CORE_SIZE"
		fi
		CORE_VERSION="$CORE_PKG_VERSION"
		rm -rf "$CORE_TMP_DIR"
		return 0
	fi
	core_asset_fetch new.apk || core_fail "$CORE_ERROR" || return 1
	CORE_VERIFIED=1
	size="$(pkg_file_installed_size "$new")"
	is_uint "$size" || core_fail "cannot read installed-size of $CORE_ASSET" || return 1
	size="$(uint_norm "$size")"
	# apk extract is available on supported OpenWrt; never execute package scripts in staging.
	local avail="" candidate="$CORE_TMP_DIR/candidate/opt/xraywrt/bin/xray"
	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	is_uint "$avail" && [ $(($(uint_norm "$avail") * 1024)) -gt $((size + 16777216)) ] ||
		core_fail "not enough RAM to validate the unpacked core package" || return 1
	mkdir -p "$CORE_TMP_DIR/candidate" &&
		pkg_file_extract "$new" "$CORE_TMP_DIR/candidate" >/dev/null 2>&1 ||
		core_fail "cannot extract the core candidate package" || return 1
	candidate_version="$(core_pkg_version "$candidate")" || core_fail "$(code_message core_binary "new binary is not a runnable XrayWRT core")" || return 1
	[ "$candidate_version" = "${CORE_PKG_VERSION%-r*}" ] || core_fail "core candidate version does not match the release package version" || return 1
	core_candidate_test "$candidate" || core_fail "$CORE_ERROR" || return 1
	rm -rf "$CORE_TMP_DIR/candidate"
	ensure_dir "${XRAY_BIN%/*}" || core_fail "cannot create ${XRAY_BIN%/*}" || return 1
	free="$(core_free_kb "${XRAY_BIN%/*}")"
	is_uint "$free" || core_fail "cannot check free space" || return 1
	free="$(uint_norm "$free")"
	[ -f "$XRAY_BIN" ] && old_size="$(wc -c <"$XRAY_BIN" | tr -d ' ')"
	if [ $((free * 1024)) -lt $((size + 4194304)) ]; then
		[ $((free * 1024 + old_size)) -ge $((size + 4194304)) ] ||
			core_fail "$(code_message core_flash "not enough flash: need %s MiB, free %s MiB" "$(((size + 4194304 + 1048575) / 1048576))" "$((free / 1024))")" || return 1
		tight=1
	fi
	# apk add of an installed version does not repair missing files.
	[ "$same" = 0 ] || tight=1
	if [ "$rollback" = 1 ]; then
		if [ "$same" = 1 ]; then
			ln "$new" "$CORE_TMP_DIR/old.apk" || core_fail "cannot stage the repair rollback package" || return 1
		elif [ "$had_pkg" = 0 ]; then
			[ ! -f "$XRAY_BIN" ] || core_old_copy "$old_size" || core_fail "$CORE_ERROR" || return 1
		else
			core_pkg_old_fetch || core_fail "$CORE_OLD_ERROR; --no-rollback installs without it" || return 1
		fi
	fi
	service_running && was_running=1
	if [ "$tight" = 1 ]; then
		warn "Core update: the service stops while the package is replaced"
		[ "$was_running" = 0 ] || core_service_stop
		if [ "$had_pkg" = 1 ] && ! pkg_remove "$CORE_PACKAGE" >/dev/null 2>&1; then
			CORE_ERROR="cannot remove the old $CORE_PACKAGE package"
			if [ "$was_running" = 1 ] && ! core_service_start; then
				CORE_ERROR="$(code_message core_restart_failed "%s; could not restart the current core" "$CORE_ERROR")"
			fi
			core_fail "$CORE_ERROR"
			return 1
		fi
	fi
	# A channel/file core belongs to no package: remove it, apk 3.0.5 would silently overwrite it.
	[ "$had_pkg" = 1 ] || rm -f "$XRAY_BIN"
	rm -f "$CORE_VERSION_CACHE"
	if ! out="$(pkg_install_file "$new" 2>&1 >/dev/null)" || {
		[ "$(core_pkg_version "$XRAY_BIN")" != "$candidate_version" ] &&
			out="installed core version does not match the validated candidate"
	}; then
		CORE_ERROR="cannot install $CORE_ASSET: $(core_apk_text "$out")"
		if [ "$rollback" = 1 ]; then
			[ "$was_running" = 0 ] || core_service_stop
			core_pkg_restore "$was_running"
		elif [ "$had_pkg" = 0 ] || [ "$tight" = 1 ]; then
			CORE_ERROR="$(code_message core_removed "%s; the old core was removed (--no-rollback), install a core again" "${CORE_ERROR% \[E:*}")"
		fi
		core_fail "$CORE_ERROR"
		return 1
	fi
	# Stop pressed during the install: the user's Stop wins over the restart.
	[ ! -f "$USER_STOP_FILE" ] || was_running=0
	if [ "$was_running" = 1 ]; then
		[ "$tight" = 1 ] || core_service_stop
		if ! core_service_start; then
			CORE_ERROR="new core failed to start"
			if [ "$rollback" = 1 ]; then
				core_service_stop
				core_pkg_restore 1
				core_fail "$CORE_ERROR"
				return 1
			fi
			CORE_ERROR="$(code_message core_no_rollback "%s; no rollback copy (--no-rollback)" "${CORE_ERROR% \[E:*}")"
		fi
		CORE_RESTARTED=1
	fi
	core_json_record "$(wc -c <"$new" | tr -d ' ')"
	rm -rf "$CORE_TMP_DIR"
	CORE_UPDATED=1
	CORE_VERSION="$CORE_PKG_VERSION"
	if [ -n "$CORE_ERROR" ]; then
		err "Core update: $CORE_ERROR"
		return 1
	fi
	log "Core updated: package $CORE_PACKAGE $CORE_PKG_VERSION from $XRAYWRT_CORE_RELEASE_REPO@$CORE_TAG"
}

# CLI/job boundary of core-update: [--no-rollback], at most once.
core_args_valid() {
	local seen=""

	while [ $# -gt 0 ]; do
		case "$seen" in *"<$1>"*) return 1 ;; esac
		seen="$seen<$1>"
		case "$1" in
		--no-rollback) shift ;;
		*) return 1 ;;
		esac
	done
}

# core_update_locked [args]: core_update_json under core.flock, then the
# service restart outside it (stop waits for run-service, which needs the
# runtime lock). Prints the result JSON with `restarted`.
core_update_locked() {
	local result="" rc=0 restarted=false restart_error="" out=""

	core_lock || return 1
	result="$(core_update_json "$@")" || rc=$?
	core_unlock
	# The low-flash path restarted the service itself.
	if [ "$(printf '%s' "$result" | xraywrt-json get restarted empty)" = true ]; then
		printf '%s\n' "$result"
		return "$rc"
	fi
	if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$result" | xraywrt-json get updated)" = true ] && service_running && [ ! -f "$USER_STOP_FILE" ]; then
		if out="$(XRAYWRT_UPDATE_CONTROL=1 /etc/init.d/xraywrt restart 2>&1 >/dev/null 9>&-)"; then
			restarted=true
		else
			out="$(printf '%s\n' "$out" | awk 'NF { l = $0 } END { sub(/^Error: /, "", l); print l }')"
			if [ -n "$out" ]; then
				restart_error="$(code_message core_restart "Xray core updated, but the service restart failed: %s" "${out% \[E:*}")"
			else
				restart_error="$(code_message core_restart_empty "Xray core updated, but the service restart failed")"
			fi
			err "$restart_error"
			rc=1
		fi
	fi
	printf '%s\n' "$result" | xraywrt-json merge restart --argjson restarted "$restarted" --arg e "$restart_error"
	return "$rc"
}

# fd 7 on core.flock keeps a second core update or check out; the runtime
# lock is not taken (the download can take minutes).
core_lock() {
	ensure_dir "$PKG_STATE_DIR" || return 1
	exec 7>>"$PKG_STATE_DIR/core.flock"
	flock -n 7 && return 0
	exec 7>&-
	err_code core_busy "Another core update is running"
	xraywrt-json build object --argjson updated false --arg version "$(core_version)" \
		--arg error "$(code_message core_busy "Another core update is running")" --argjson restarted false
	return 1
}

core_unlock() {
	flock -u 7
	exec 7>&-
}

# Spec 4.5: read the apk database, no package-manager process (status polls it).
core_package_installed() {
	pkg_installed_names | grep -qxF "$CORE_PACKAGE"
}

# Only the core package release is queried; historical metadata is read-only.
core_check_json() {
	local installed="" rc=0 available=0 version=""

	installed="$(core_json_get source:tag)"
	version="$(core_package_installed && pkg_version "$CORE_PACKAGE")"
	CORE_TAG="" CORE_SIZE="" CORE_PKG_VERSION="" CORE_ERROR=""
	core_pkg_resolve || rc=1
	[ "$rc" -ne 0 ] || { [ -x "$XRAY_BIN" ] && [ "$version" = "$CORE_PKG_VERSION" ]; } || available=1
	rm -rf "$CORE_TMP_DIR"
	xraywrt-json build core-check --arg source "${installed%%:*}" \
		--arg tag "${installed#*:}" --arg iversion "$version" --arg latest "$CORE_TAG" --arg size "$CORE_SIZE" \
		--arg lversion "$CORE_PKG_VERSION" --arg available "$available" \
		--arg version "$(core_version)" --arg e "$CORE_ERROR"
	return "$rc"
}

core_check_locked() {
	local rc=0

	core_lock >/dev/null || return 1
	core_check_json || rc=$?
	core_unlock
	return "$rc"
}

core_update_json() {
	local rc=0

	core_update "$@" || rc=$?
	if [ "$CORE_RESTARTED" = 1 ]; then
		xraywrt-json build core --arg v "$CORE_VERSION" --arg e "$CORE_ERROR" --arg u "$CORE_UPDATED" --arg verified "$CORE_VERIFIED" --arg sha "$CORE_SHA256" |
			xraywrt-json merge restart --argjson restarted true --arg e ""
	else
		xraywrt-json build core --arg v "$CORE_VERSION" --arg e "$CORE_ERROR" --arg u "$CORE_UPDATED" --arg verified "$CORE_VERIFIED" --arg sha "$CORE_SHA256"
	fi
	return "$rc"
}
