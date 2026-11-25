#!/bin/ash

# The source config.json: read, validate, install with backup (spec 5, 9.3).

# Uploads from LuCI land in /tmp/xraywrt-config.* (file ACL); nothing else.
config_temp_path_allowed() {
	upload_path_allowed /tmp/xraywrt-config. "$1"
}

config_read_json() {
	local path="${1:-$XRAY_CONFIG}"

	[ "$path" = "$XRAY_CONFIG" ] || config_temp_path_allowed "$path" || {
		err "Config path not allowed: $path"
		return 1
	}
	if [ -r "$path" ]; then
		# shellcheck disable=SC2094 # $path is only read
		xraywrt-json build config --arg p "$path" <"$path"
	else
		xraywrt-json build object --arg path "$path" --arg content ""
	fi
}

# The JSON passed to Xray. Not started since boot: what it would get at
# start (built from config.json, without the core test).
runtime_config_json() {
	# A preview is opened often; the real build at start logs the warnings.
	local scratch="" rc=0 XRAYWRT_QUIET=1

	if [ -r "$RUNTIME_CONFIG" ]; then
		xraywrt-json build runtime --argjson generated false <"$RUNTIME_CONFIG"
		return
	fi
	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	scratch="$(mktemp "$PKG_TMP_DIR/runtime-preview.XXXXXX")" || return 1
	if xray_config_generate "$XRAY_CONFIG" "$scratch"; then
		xraywrt-json build runtime --argjson generated true <"$scratch" || rc=1
	else
		rc=1
	fi
	rm -f "$scratch" "$scratch.profile"
	return "$rc"
}

# Spec 5.3: profile names (`remarks`) of config.json.
config_profiles_json() {
	[ -r "$XRAY_CONFIG" ] || {
		echo '[]'
		return 0
	}
	xraywrt-json profiles "$XRAY_CONFIG"
}

# config-check [tmp]: generation + `run -test`; missing geodata may be
# published under the runtime lock. A checked config upload is removed.
# {"ok": bool, "error": text|null, "output": core output|null}.
config_check_json() {
	local path="${1:-$XRAY_CONFIG}" scratch="" error="" rc=0 XRAYWRT_QUIET=1

	[ "$path" = "$XRAY_CONFIG" ] || config_temp_path_allowed "$path" || {
		err "Config path not allowed: $path"
		return 1
	}
	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	# Xray picks the config format by the .json extension.
	scratch="$PKG_TMP_DIR/config-check.$$.json"
	# xray_config_test sets CONFIG_TEST_OUTPUT: no command substitution.
	CONFIG_TEST_OUTPUT=""
	if ! xray_config_generate "$path" "$scratch" 2>"$scratch.err" >/dev/null ||
		! xray_config_test "$scratch" 2>"$scratch.err" >/dev/null; then
		rc=1
		error="$(awk 'NF { l = $0 } END { sub(/^Error: /, "", l); print l }' "$scratch.err")"
	fi
	rm -f "$scratch" "$scratch.profile" "$scratch.err"
	# A checked upload is not needed again (save-config uploads anew).
	[ "$path" = "$XRAY_CONFIG" ] || rm -f "$path"
	xraywrt-json build config-check --arg ok "$((1 - rc))" --arg e "$error" --arg out "$CONFIG_TEST_OUTPUT"
	return "$rc"
}

config_locked() {
	with_lock "$@"
}

# The profile (mode, DNS, provider settings and lists) changed: re-apply
# schedule and policy. A DNS mode switch also flushes the dnsmasq cache so
# clients do not keep fake-IP answers.
config_profile_apply() {
	local old="$1" old_dns=""

	cmp -s "$old" "$PROFILE_FILE" && [ ! -s "$APPLY_WARNING_FILE" ] && return 0
	# FakeDNS activation, including servers without domain restrictions.
	[ ! -f "$old" ] || case "$(sed -n 's/^fake-enabled //p' "$old")" in
	1) old_dns=fake-ip ;;
	*) old_dns=redir-host ;;
	esac
	settings_load || return 1
	cron_update || warn "Failed to update cron schedule"
	service_ready || return 0
	policy_apply || return 1
	if [ -n "$old_dns" ] && [ "$old_dns" != "$DNS_MODE" ]; then
		dns_restart_dnsmasq || return 1
		log "DNS mode changed ($old_dns -> $DNS_MODE): dnsmasq cache flushed"
	fi
	return 0
}

# Validate a candidate (generation + `run -test`), install it and publish
# the runtime by hot apply or restart (spec 9.3/17). A core that does not start
# gets the previous runtime back, and the previous config.json too.
config_install() {
	local candidate="$1" runtime_candidate="$PKG_TMP_DIR/runtime.candidate.json"
	local old_profile="$PKG_TMP_DIR/profile.old" old_config="$XRAY_CONFIG.previous.$$"
	local action=saved inputs="" warning="" params="" XRAY_RULE_REMOTE=""

	# Same bytes: spare the flash and the restart.
	if [ -f "$XRAY_CONFIG" ] && cmp -s "$candidate" "$XRAY_CONFIG"; then
		if [ -s "$APPLY_WARNING_FILE" ] || { [ -n "${SUBSCRIPTION_INSTALLING:-}" ] && [ -z "$(uci_get subscription)" ]; }; then
			service_reload || warning="$(cat "$APPLY_WARNING_FILE" 2>/dev/null)"
		fi
		apply_result '{"action":"unchanged"}' "$warning"
		return
	fi
	settings_load || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	xray_config_prepare "$candidate"
	if ! { xray_config_generate "$candidate" "$runtime_candidate" "" "$params" && xray_config_test "$runtime_candidate"; }; then
		rm -f "$runtime_candidate" "$runtime_candidate.profile"
		return 1
	fi
	# Also what a power cut during an earlier install left on the flash.
	rm -f "$old_profile" "$XRAY_CONFIG".previous.*
	if ! {
		{ [ ! -f "$PROFILE_FILE" ] || cp "$PROFILE_FILE" "$old_profile"; } &&
			{ [ ! -f "$XRAY_CONFIG" ] || ln -f "$XRAY_CONFIG" "$old_config" 2>/dev/null || cp -p "$XRAY_CONFIG" "$old_config"; }
	}; then
		rm -f "$old_profile" "$old_config" "$runtime_candidate" "$runtime_candidate.profile"
		err "Cannot back up $XRAY_CONFIG"
		return 1
	fi
	if ! { cp "$candidate" "$XRAY_CONFIG.tmp" && chmod 600 "$XRAY_CONFIG.tmp" && mv -f "$XRAY_CONFIG.tmp" "$XRAY_CONFIG"; }; then
		rm -f "$XRAY_CONFIG.tmp" "$runtime_candidate" "$runtime_candidate.profile" "$old_profile" "$old_config"
		err "Cannot write $XRAY_CONFIG"
		return 1
	fi
	config_check_record ok
	if cmp -s "$runtime_candidate" "$RUNTIME_CONFIG" && geodata_unchanged; then
		# Only the xraywrt key changed: the core keeps running.
		if ! { mv -f "$runtime_candidate.profile" "$PROFILE_FILE" && touch "$PROFILE_FILE"; }; then
			warning="$(apply_partial_message)"
		fi
		rm -f "$runtime_candidate" "$runtime_candidate.profile"
	elif runtime_publish "$runtime_candidate"; then
		[ "$RUNTIME_RESTARTED" -eq 0 ] || action=restarted
		[ "$RUNTIME_HOT_RELOADED" -eq 0 ] || action=hot_reloaded
	else
		rm -f "$runtime_candidate" "$runtime_candidate.profile"
		if [ -f "$old_config" ]; then
			mv -f "$old_config" "$XRAY_CONFIG" || err "the previous config is saved in $old_config"
		else
			rm -f "$XRAY_CONFIG"
		fi
		config_profile_apply "$old_profile" >/dev/null 2>&1 || :
		rm -f "$old_profile"
		return 1
	fi
	if [ -n "$warning" ]; then
		runtime_config_key_store ""
	elif ! config_profile_apply "$old_profile"; then
		warning="$(apply_partial_message)"
		warn "$warning"
	elif service_ready; then
		rm -f "$APPLY_WARNING_FILE"
	fi
	[ -n "$warning" ] || runtime_config_key_store "$inputs"
	rm -f "$old_profile"
	if [ -f "$old_config" ]; then
		mv -f "$old_config" "$XRAY_CONFIG_BACKUP" || {
			warning="$(code_message apply_backup 'The new configuration was accepted, but its backup could not be saved. Check free storage before making more changes.')"
			warn "$warning"
		}
	fi
	apply_result "{\"action\":\"$action\"}" "$warning"
}

config_has_keys() {
	grep -q '[^[:space:]]' "$1"
}

config_save() {
	local tmp="$1" rc=0

	config_temp_path_allowed "$tmp" || {
		err "Config path not allowed: $tmp"
		return 1
	}
	if [ "$(wc -c <"$tmp")" -gt "$SUBSCRIPTION_MAX_BYTES" ]; then
		err_code config_large "The config is larger than 8 MiB."
		rm -f "$tmp"
		return 1
	fi
	if ! config_has_keys "$tmp"; then
		err_code config_empty "The config is empty: nothing was changed."
		rm -f "$tmp"
		return 1
	fi
	config_install "$tmp" || rc=$?
	rm -f "$tmp"
	return "$rc"
}

# Install a copy: config_install replaces the backup with the current config.
config_restore() {
	local candidate="" rc=0

	[ -f "$XRAY_CONFIG_BACKUP" ] || {
		err_code config_no_previous "There is no previous configuration."
		return 1
	}
	ensure_dir "$PKG_TMP_DIR" || return 1
	candidate="$(mktemp "$PKG_TMP_DIR/restore.XXXXXX")" || return 1
	if cp "$XRAY_CONFIG_BACKUP" "$candidate"; then
		config_install "$candidate" || rc=$?
	else
		rc=1
	fi
	rm -f "$candidate"
	return "$rc"
}
