#!/bin/ash

# Geodata (spec 10): the router only fetches files that the provider's
# geodata.assets list and share/ lacks; the core refreshes them by its cron.
# State of the last geodata_ensure:
#   GEODATA_FETCHED   candidate files staged in tmpfs; journal owns publication
#   GEODATA_ERROR     reason of a failure
#   GEODATA_TRANSIENT 1 when only a download failed or the config check was killed (a retry may help)
GEODATA_FETCHED=""
GEODATA_PREPARING=0

# AddRule caches files already read by the core; newly referenced files are safe.
# A missing snapshot is unknown state and must use a restart.
geodata_snapshot() {
	local file="" snapshot="${1:-$RUNTIME_CONFIG.geodata}"

	set --
	for file in "$XRAY_SHARE_DIR"/*.dat; do
		[ ! -f "$file" ] || set -- "$@" "$file"
	done
	if [ "$#" -gt 0 ]; then
		sha256sum "$@" >"$snapshot.tmp.$$" || return 1
	else
		: >"$snapshot.tmp.$$" || return 1
	fi
	mv -f "$snapshot.tmp.$$" "$snapshot"
}

geodata_unchanged() {
	local snapshot="${1:-$RUNTIME_CONFIG.geodata}"

	[ -f "$snapshot" ] || return 1
	[ -s "$snapshot" ] || return 0
	sha256sum -c "$snapshot" >/dev/null 2>&1
}

geodata_name_valid() {
	case "$1" in
	'' | .dat | *[!A-Za-z0-9._-]*) return 1 ;;
	*.dat) return 0 ;;
	esac
	return 1
}

geodata_assets() {
	sed -n 's/^geodata \([^ ]*\) .*/\1/p' "$1"
}

# geodata_routes <url>: <url>; for a GitHub repo file its jsDelivr twin (or
# the raw twin of a jsDelivr url), for a release asset none; then each
# GITHUB_PROXIES host before the github/raw url (spec 10). Other hosts: <url>.
geodata_routes() {
	local rest="" owner="" repo="" ref="" gh="$1" proxy=""

	printf '%s\n' "$1"
	case "$1" in
	https://raw.githubusercontent.com/*/*/*/?* | https://github.com/*/*/raw/*/?*)
		rest="${1#https://*/}"
		owner="${rest%%/*}" rest="${rest#*/}"
		repo="${rest%%/*}" rest="${rest#*/}"
		case "$1:$rest" in
		https://github.com/*:raw/*) rest="${rest#raw/}" ;;
		https://github.com/*) return 0 ;;
		esac
		case "$rest" in refs/heads/*/?*) rest="${rest#refs/heads/}" ;; esac
		ref="${rest%%/*}"
		printf 'https://cdn.jsdelivr.net/gh/%s/%s@%s/%s\n' "$owner" "$repo" "$ref" "${rest#*/}"
		;;
	https://github.com/*/*/releases/download/*/?* | https://github.com/*/*/releases/latest/download/?*) ;;
	https://cdn.jsdelivr.net/gh/*/*/?*)
		rest="${1#https://cdn.jsdelivr.net/gh/}"
		owner="${rest%%/*}" rest="${rest#*/}"
		repo="${rest%%/*}" ref=HEAD
		case "$repo" in *@?*) ref="${repo#*@}" repo="${repo%%@*}" ;; esac
		gh="https://raw.githubusercontent.com/$owner/$repo/$ref/${rest#*/}"
		printf '%s\n' "$gh"
		;;
	*) return 0 ;;
	esac
	for proxy in $GITHUB_PROXIES; do
		printf 'https://%s/%s\n' "$proxy" "$gh"
	done
}

geodata_fetch() {
	local file="$1" url="$2" tmp="$GEODATA_TMP_DIR/$1" avail="" limit="$GEODATA_MAX_BYTES"
	local route="" error="" fetched=0 rc=0

	case "$url" in
	https://*) ;;
	*)
		GEODATA_ERROR="geodata $file: url is not https"
		return 1
		;;
	esac
	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	if is_uint "$avail"; then
		avail=$(($(uint_norm "$avail") * 1024 - 16777216))
		[ "$avail" -ge "$limit" ] || limit="$avail"
	fi
	[ "$limit" -gt 0 ] || {
		GEODATA_ERROR="geodata $file: not enough RAM"
		return 1
	}
	ensure_dir "$GEODATA_TMP_DIR" || return 1
	while read -r route; do
		[ "$route" = "$url" ] || warn "geodata $file: $(url_host "$url") unavailable, using $(url_host "$route")"
		if http_fetch "$route" "$tmp" "$limit" geodata 0 </dev/null; then
			fetched=1
			break
		fi
		[ -n "$error" ] || error="$FETCH_ERROR"
	done <<EOF
$(geodata_routes "$url")
EOF
	[ "$fetched" = 1 ] || {
		GEODATA_ERROR="$(code_message geodata_download "geodata %s: download failed (%s)" "$file" "$error")"
		[ "$error" = too_large ] || GEODATA_TRANSIENT=1
		rm -f "$tmp"
		return 1
	}
	geodata_stage_file "$tmp" "$file" || rc=1
	rm -f "$tmp"
	return "$rc"
}

# Staging is tmpfs only. Existing assets are linked, never copied to RAM.
geodata_stage_begin() {
	geodata_recover || return 1
	GEODATA_FETCHED=""
	GEODATA_ERROR=""
	GEODATA_TRANSIENT=0
	GEODATA_PREPARING=0
	[ ! -L "$XRAY_SHARE_DIR" ] && ensure_dir "$XRAY_SHARE_DIR" && ensure_dir "$GEODATA_TMP_DIR" || return 1
	rm -rf "$GEODATA_TMP_DIR/assets"
	mkdir "$GEODATA_TMP_DIR/assets" || return 1
	local path=""
	for path in "$XRAY_SHARE_DIR"/*.dat; do
		[ ! -f "$path" ] || ln -s "$path" "$GEODATA_TMP_DIR/assets/${path##*/}" || return 1
	done
}

geodata_stage_file() {
	local source="$1" name="$2" size="" avail="" target="$XRAY_SHARE_DIR/$2"

	if ! { geodata_name_valid "$name" && [ -f "$source" ] && [ ! -L "$source" ] &&
		[ ! -L "$target" ] && { [ ! -e "$target" ] || [ -f "$target" ]; }; }; then
		GEODATA_ERROR="$(code_message geodata_path 'The geodata file name or path is unsafe. No files were replaced.')"
		return 1
	fi
	size="$(wc -c <"$source" | tr -d ' ')"
	[ "$size" -gt 0 ] && [ "$size" -le "$GEODATA_MAX_BYTES" ] || {
		GEODATA_ERROR="$(code_message geodata_size 'The geodata file is empty or too large. No files were replaced.')"
		return 1
	}
	avail="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_FILE" 2>/dev/null)"
	if is_uint "$avail" && [ $(($(uint_norm "$avail") * 1024)) -lt $((size + 16777216)) ]; then
		GEODATA_ERROR="$(code_message geodata_ram 'Not enough router memory to check the geodata files. No files were replaced.')"
		return 1
	fi
	rm -f "$GEODATA_TMP_DIR/assets/$name"
	# Same tmpfs: a hardlink costs no RAM, a copy only across filesystems.
	ln -f "$source" "$GEODATA_TMP_DIR/assets/$name" 2>/dev/null || cp "$source" "$GEODATA_TMP_DIR/assets/$name" || return 1
	case " $GEODATA_FETCHED " in *" $name "*) ;; *) GEODATA_FETCHED="$GEODATA_FETCHED $name" ;; esac
}

# Fetch the whole candidate set; no active file changes before run -test.
geodata_ensure() {
	local profile="$1" force="${2:-0}" file="" url=""

	[ -z "$GEODATA_FETCHED" ] || return 0
	GEODATA_ERROR=""
	GEODATA_TRANSIENT=0
	geodata_recover || return 1
	while read -r file url; do
		[ -n "$file" ] || continue
		geodata_name_valid "$file" && [ ! -L "$XRAY_SHARE_DIR/$file" ] || {
			GEODATA_ERROR="$(code_message geodata_path 'The geodata file name or path is unsafe. No files were replaced.')"
			return 1
		}
		[ "$force" = 1 ] || [ ! -f "$XRAY_SHARE_DIR/$file" ] || continue
		[ -n "$GEODATA_FETCHED" ] || geodata_stage_begin || return 1
		geodata_fetch "$file" "$url" || return 1
	done <<EOF
$(sed -n 's/^geodata //p' "$profile" 2>/dev/null)
EOF
	while read -r file; do
		[ -n "$file" ] || continue
		if ! { geodata_name_valid "$file" && { [ -f "$XRAY_SHARE_DIR/$file" ] || [ -f "$GEODATA_TMP_DIR/assets/$file" ]; }; }; then
			GEODATA_ERROR="$(code_message geodata_missing 'config needs %s, but geodata.assets does not provide it' "$file")"
			GEODATA_TRANSIENT=0
			return 1
		fi
	done <<EOF
$(sed -n 's/^geodata-ref //p' "$profile" 2>/dev/null)
EOF
}

# One journal owns the backups; never infer a transaction from loose .old files.
geodata_journal_stage() {
	local stage="$1" journal="$XRAY_SHARE_DIR/.geodata-transaction"
	{ printf '%s\n' "$stage"; sed '1d' "$journal"; } >"$journal.tmp" &&
		mv -f "$journal.tmp" "$journal" && sync
}

geodata_publish() {
	local name="" size=0 free="" present=0 journal="$XRAY_SHARE_DIR/.geodata-transaction"

	GEODATA_PREPARING=0
	[ -n "$GEODATA_FETCHED" ] || return 0
	[ ! -e "$journal" ] && [ ! -L "$journal" ] || return 1
	for name in $GEODATA_FETCHED; do
		[ "$name" = .manual ] || geodata_name_valid "$name" || return 1
		[ ! -L "$XRAY_SHARE_DIR/$name" ] &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name" ] || [ -f "$XRAY_SHARE_DIR/$name" ]; } &&
			[ ! -L "$XRAY_SHARE_DIR/$name.old" ] &&
			[ ! -L "$XRAY_SHARE_DIR/$name.new" ] &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name.old" ] || [ -f "$XRAY_SHARE_DIR/$name.old" ]; } &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name.new" ] || [ -f "$XRAY_SHARE_DIR/$name.new" ]; } || return 1
		size=$((size + $(wc -c <"$GEODATA_TMP_DIR/assets/$name")))
	done
	free="$(df -k "$XRAY_SHARE_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
	is_uint "$free" && [ $(($(uint_norm "$free") * 1024)) -ge $((size + 1048576)) ] || {
		GEODATA_ERROR="$(code_message geodata_space 'Not enough router storage for the geodata update and backup. No files were replaced.')"
		err "$GEODATA_ERROR"
		return 1
	}
	[ ! -L "$journal.tmp" ] && { [ ! -e "$journal.tmp" ] || [ -f "$journal.tmp" ]; } || return 1
	GEODATA_PREPARING=1
	printf 'prepare\n' >"$journal.tmp" || return 1
	for name in $GEODATA_FETCHED; do
		present=0
		if [ -f "$XRAY_SHARE_DIR/$name" ]; then
			rm -f "$XRAY_SHARE_DIR/$name.old" &&
				ln -f "$XRAY_SHARE_DIR/$name" "$XRAY_SHARE_DIR/$name.old" || return 1
			present=1
		else
			rm -f "$XRAY_SHARE_DIR/$name.old" || return 1
		fi
		rm -f "$XRAY_SHARE_DIR/$name.new" &&
			cp "$GEODATA_TMP_DIR/assets/$name" "$XRAY_SHARE_DIR/$name.new" || return 1
		printf '%s %s\n' "$name" "$present" >>"$journal.tmp" || return 1
	done
	# Backups and the journal must survive a reboot before the first rename.
	sync && mv -f "$journal.tmp" "$journal" && sync || return 1
	for name in $GEODATA_FETCHED; do
		mv -f "$XRAY_SHARE_DIR/$name.new" "$XRAY_SHARE_DIR/$name" || return 1
	done
	geodata_journal_stage published
}

# Caller holds the runtime lock (including startup). Restoration is repeatable:
# keep every backup until the complete old set has been restored and synced.
geodata_recover() {
	geodata_recover_files && return 0
	err_code geodata_rollback 'The previous geodata could not be restored. Backup files were kept. Do not delete them; free router storage and restart XrayWRT.'
	return 1
}

geodata_recover_files() {
	local journal="$XRAY_SHARE_DIR/.geodata-transaction" stage="" name="" present="" extra=""

	[ -e "$journal" ] || { [ ! -L "$journal" ]; return; }
	[ -f "$journal" ] && [ ! -L "$journal" ] || return 1
	IFS= read -r stage <"$journal"
	case "$stage" in prepare | published | committed) ;; *) return 1 ;; esac
	# Validate the entire journal before touching any path.
	while read -r name present extra; do
		{ [ "$name" = .manual ] || geodata_name_valid "$name"; } &&
			{ [ "$present" = 0 ] || [ "$present" = 1 ]; } && [ -z "$extra" ] &&
			[ ! -L "$XRAY_SHARE_DIR/$name" ] &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name" ] || [ -f "$XRAY_SHARE_DIR/$name" ]; } &&
			[ ! -L "$XRAY_SHARE_DIR/$name.old" ] &&
			[ ! -L "$XRAY_SHARE_DIR/$name.new" ] &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name.old" ] || [ -f "$XRAY_SHARE_DIR/$name.old" ]; } &&
			{ [ ! -e "$XRAY_SHARE_DIR/$name.new" ] || [ -f "$XRAY_SHARE_DIR/$name.new" ]; } || return 1
	done <<EOF
$(sed '1d' "$journal")
EOF
	if [ "$stage" != committed ]; then
		while read -r name present; do
			if [ "$present" = 1 ]; then
				[ "$XRAY_SHARE_DIR/$name" -ef "$XRAY_SHARE_DIR/$name.old" ] && continue
				rm -f "$XRAY_SHARE_DIR/$name.new" &&
					ln -f "$XRAY_SHARE_DIR/$name.old" "$XRAY_SHARE_DIR/$name.new" &&
					mv -f "$XRAY_SHARE_DIR/$name.new" "$XRAY_SHARE_DIR/$name" || return 1
			else
				rm -f "$XRAY_SHARE_DIR/$name" || return 1
			fi
		done <<EOF
$(sed '1d' "$journal")
EOF
		sync && geodata_journal_stage committed || return 1
	fi
	while read -r name present; do
		rm -f "$XRAY_SHARE_DIR/$name.old" "$XRAY_SHARE_DIR/$name.new" || return 1
	done <<EOF
$(sed '1d' "$journal")
EOF
	rm -f "$journal" && sync
}

geodata_settle() {
	local result="$1" name=""
	if [ "$result" = ok ] && [ -f "$XRAY_SHARE_DIR/.geodata-transaction" ]; then
		geodata_journal_stage committed || return 1
	fi
	geodata_recover || return 1
	if [ "$GEODATA_PREPARING" = 1 ]; then
		for name in $GEODATA_FETCHED; do
			rm -f "$XRAY_SHARE_DIR/$name.old" "$XRAY_SHARE_DIR/$name.new" || return 1
		done
		rm -f "$XRAY_SHARE_DIR/.geodata-transaction.tmp" || return 1
	fi
	GEODATA_PREPARING=0
	GEODATA_FETCHED=""
	rm -rf "$GEODATA_TMP_DIR/assets"
	return 0
}

# Remove share/ files that no asset lists and no rule references, except
# manual uploads (share/.manual) - they only take flash.
geodata_prune() {
	local profile="$1" path="" name=""

	[ -r "$profile" ] || return 0
	for path in "$XRAY_SHARE_DIR"/*; do
		[ -f "$path" ] || continue
		name="${path##*/}"
		grep -qxF "geodata-ref $name" "$profile" && continue
		geodata_assets "$profile" | grep -qxF "$name" && continue
		grep -qxF "$name" "$GEODATA_MANUAL_FILE" 2>/dev/null && continue
		rm -f "$path"
	done
}

# CLI/job boundary: [--force] | --file F --name N.
geodata_args_valid() {
	case "$#:${1:-}:${3:-}" in
	0:: | 1:--force:) return 0 ;;
	4:--file:--name) upload_path_allowed /tmp/ "$2" && geodata_name_valid "$4" ;;
	*) return 1 ;;
	esac
}

# Report preparation failures only after restoring/cleaning the attempted set.
geodata_fail() {
	geodata_settle err || return 1
	if [ -n "$GEODATA_ERROR" ]; then
		err "$GEODATA_ERROR"
	else
		err_code geodata_write 'The geodata update could not be saved. The previous files were kept.'
	fi
	return 1
}

# Test both pending settings and the accepted runtime against the candidate set.
# The ref walker cannot see every reference (negated geoip, sniffing
# exclusions), so an installed core always tests the candidate; only the
# restart and the "unverified" warning depend on the walker.
geodata_apply() {
	local candidate="$PKG_TMP_DIR/geodata-check.json" rc=0

	geodata_apply_checked "$@" || rc=$?
	rm -f "$candidate" "$candidate.profile" "$candidate.pending-refs" "$candidate.live-refs"
	return "$rc"
}

geodata_apply_checked() {
	local manual="${1:-}" candidate="$PKG_TMP_DIR/geodata-check.json" name="" used=0 live_used=0 running=0 warning="" missing="" pending_missing="" live_missing=""

	service_running && running=1
	rm -f "$candidate" "$candidate.profile"
	if [ -f "$XRAY_CONFIG" ]; then
		xray_config_generate "$XRAY_CONFIG" "$candidate" || { geodata_settle err; return 1; }
	else
		: >"$candidate.profile" || { geodata_fail; return 1; }
	fi
	: >"$candidate.pending-refs" || { geodata_fail; return 1; }
	if [ -f "$candidate" ] && ! xraywrt-json geodata-refs "$candidate" >"$candidate.pending-refs"; then
		geodata_settle err || return 1
		err_code geodata_check 'The router core rejected the geodata files with your settings. No files were replaced.'
		return 1
	fi
	: >"$candidate.live-refs" || { geodata_fail; return 1; }
	if [ "$running" = 1 ] && ! xraywrt-json geodata-refs "$RUNTIME_CONFIG" >"$candidate.live-refs"; then
		geodata_settle err || return 1
		err_code geodata_check 'The router core rejected the geodata files with your settings. No files were replaced.'
		return 1
	fi
	for name in $GEODATA_FETCHED; do
		if ! grep -qxF "$name" "$candidate.pending-refs" &&
			! grep -qxF "$name" "$candidate.live-refs"; then
			warning="$(code_message geodata_unverified 'These files are not used by the current settings, so they cannot be checked now. They will be checked when settings start using them.')"
		else
			used=1
		fi
		if grep -qxF "$name" "$candidate.live-refs"; then
			live_used=1
		fi
	done
	while read -r name; do
		[ -n "$name" ] || continue
		[ -f "$GEODATA_TMP_DIR/assets/$name" ] && continue
		pending_missing="$name"
		break
	done <"$candidate.pending-refs"
	while read -r name; do
		[ -n "$name" ] || continue
		[ -f "$GEODATA_TMP_DIR/assets/$name" ] && continue
		live_missing="$name"
		break
	done <"$candidate.live-refs"
	if [ -n "$manual" ] && [ "$used" = 1 ]; then
		missing="$pending_missing"
		[ -n "$missing" ] || missing="$live_missing"
		if [ -n "$missing" ]; then
			warning="$(code_message geodata_incomplete '%s saved. %s is still missing; upload it to finish.' "$manual" "$missing")"
		fi
	fi
	if [ -x "$XRAY_BIN" ]; then
		if [ -z "$pending_missing" ] && [ -f "$candidate" ] && ! xray_config_test_run "$candidate" "$XRAY_BIN" "$GEODATA_TMP_DIR/assets"; then
			geodata_settle err || return 1
			err_code geodata_check 'The router core rejected the geodata files with your settings. No files were replaced.'
			return 1
		fi
		# The same bytes need no second run when the pending config is the live one.
		if [ -z "$live_missing" ] && [ "$running" = 1 ] && [ -f "$RUNTIME_CONFIG" ] && ! { [ -f "$candidate" ] && cmp -s "$candidate" "$RUNTIME_CONFIG"; }; then
			xray_config_test_run "$RUNTIME_CONFIG" "$XRAY_BIN" "$GEODATA_TMP_DIR/assets" || {
				geodata_settle err || return 1
				err_code geodata_check 'The router core rejected the geodata files with your settings. No files were replaced.'
				return 1
			}
		fi
	fi
	[ -z "$live_missing" ] || live_used=0
	if [ -n "$manual" ]; then
		[ ! -L "$GEODATA_MANUAL_FILE" ] || { geodata_fail; return 1; }
		if [ -e "$GEODATA_MANUAL_FILE" ]; then
			awk '!seen[$0]++' "$GEODATA_MANUAL_FILE" >"$GEODATA_TMP_DIR/assets/.manual" || { geodata_fail; return 1; }
		else
			: >"$GEODATA_TMP_DIR/assets/.manual" || { geodata_fail; return 1; }
		fi
		grep -qxF "$manual" "$GEODATA_TMP_DIR/assets/.manual" ||
			printf '%s\n' "$manual" >>"$GEODATA_TMP_DIR/assets/.manual" || { geodata_fail; return 1; }
		GEODATA_FETCHED="$GEODATA_FETCHED .manual"
	fi
	geodata_publish || { geodata_fail; return 1; }
	# Invalidate both caches before attempting a restart, including rollback.
	rm -f "$CONFIG_TESTED_FILE" "$RUNTIME_CONFIG.geodata"
	if [ "$live_used" = 1 ] && service_running && ! core_restart; then
		geodata_settle err || return 1
		if ! core_restart; then
			err_code geodata_restart_rollback 'The previous geodata was restored, but XrayWRT could not restart. Traffic may go direct. Restart XrayWRT and check the system log.'
		else
			err_code geodata_restart 'The new geodata could not be applied. The previous files were restored.'
		fi
		return 1
	fi
	geodata_settle ok || {
		rm -rf "$GEODATA_TMP_DIR/assets"
		err_code geodata_finalize 'The geodata update could not be finalized. Restart XrayWRT to finish recovery; this may restore the previous files. Do not delete backup files.'
		return 1
	}
	xraywrt-json build object --argjson warnings "$(printf '%s\n' "$warning" | sed '/^$/d' | xraywrt-json lines)"
}

# geodata-update [--force] | --file F --name N; CLI and jobs hold the lock.
geodata_update() {
	local force=0

	geodata_args_valid "$@" || { err 'Invalid geodata update arguments'; return 1; }
	if [ "${1:-}" = --file ]; then
		geodata_install_file "$2" "$4"
		return $?
	fi
	[ "${1:-}" != --force ] || force=1
	settings_load && profile_ensure || return 1
	geodata_ensure "$PROFILE_FILE" "$force" || {
		err "$GEODATA_ERROR"
		geodata_settle err
		return 1
	}
	if [ -n "$GEODATA_FETCHED" ]; then
		geodata_apply || return 1
	else
		printf '{}\n'
	fi
	geodata_prune "$PROFILE_FILE"
}

# The uploaded file (up to 64 MB of RAM in /tmp) is removed on every exit path.
geodata_install_file() {
	local file="$1" rc=0

	geodata_install_uploaded "$@" || rc=$?
	! upload_path_allowed /tmp/xraywrt-geodata. "$file" || rm -f "$file"
	return "$rc"
}

geodata_install_uploaded() {
	local file="$1" name="$2"

	if ! { geodata_name_valid "$name" && upload_path_allowed /tmp/ "$file"; }; then
		err_code geodata_path 'The geodata file name or path is unsafe. No files were replaced.'
		return 1
	fi
	settings_load || return 1
	geodata_stage_begin || { geodata_fail; return 1; }
	geodata_stage_file "$file" "$name" || { geodata_fail; return 1; }
	geodata_apply "$name"
}
