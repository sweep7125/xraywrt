#!/bin/ash

# Runtime Xray config from the provider's JSON (spec 6): xray-config.uc does
# the work through `xraywrt-json gen`; this wrapper feeds it the router
# parameters, keys the result and runs `xray run -test`.

# Router parameters for the generator, from settings_load (spec 6.1).
xray_params_json() {
	local rules=""

	[ ! -f "$RULES_FILE" ] || rules="$RULES_FILE"
	# shellcheck disable=SC2086 # UCI list: one value per word
	xraywrt-json build object \
		--arg mode "${UCI_MODE:-proxy-first}" \
		--argjson mode_override "$([ "${MODE_OVERRIDE:-0}" = 1 ] && echo true || echo false)" \
		--argjson dns_forward_override "$([ "${DNS_FORWARD_OVERRIDE:-0}" = 1 ] && echo true || echo false)" \
		--arg profile "${PROFILE_NAME:-}" \
		--argjson from_subscription "$([ -n "${SUBSCRIPTION_URL:-}${SUBSCRIPTION_INSTALLING:-}" ] && echo true || echo false)" \
		--argjson geodata_asset "${GEODATA_ASSETS_JSON:-[]}" \
		--arg geodata_cron "${GEODATA_CRON:-0 5 * * *}" \
		--arg log_level "${UCI_CORE_LOG_LEVEL:-warning}" \
		--argjson log_level_override "$([ "${LOG_LEVEL_OVERRIDE:-0}" = 1 ] && echo true || echo false)" \
		--argjson mark "$XRAY_ROUTING_MARK" \
		--argjson ipv6 "$(route_ipv6_enabled && echo true || echo false)" \
		--argjson ports "{\"tproxy\":$XRAY_TPROXY_PORT,\"direct\":$XRAY_DIRECT_TPROXY_PORT,\"dns\":$XRAY_DNS_PORT,\"api\":$XRAY_API_PORT}" \
		--arg fakeip_range "$FAKEIP_RANGE" \
		--argjson local_nets "$(printf '%s\n' $LOCAL_NETS_V4 $LOCAL_NETS_V6 | xraywrt-json lines)" \
		--argjson wan_dns "$(dns_wan_servers | xraywrt-json lines)" \
		--arg dns_raw_upstream "${DNS_RAW_UPSTREAM:-}" \
		--arg dns_raw_via "${DNS_RAW_VIA:-}" \
		--arg dns_raw_lost "${DNS_RAW_LOST:-}" \
		--argjson dns_forward_other_types "${DNS_FORWARD_OTHER_TYPES:-0}" \
		--arg rules_file "$rules" \
		--argjson rules_remote "$(lists_rules_remote_json)"
}

# xray_config_generate <src> <dst> [key]
# With "key", print a fingerprint of every generator input instead: params,
# source, domain lists and the generator itself.
# Returns 2 when the config itself is rejected ("config: ..."), 1 otherwise.
xray_config_generate() {
	local src="$1" dst="$2" mode="${3:-}" tmp="" params="" lib="" line="" key=""

	[ -r "$src" ] || {
		err_code config_missing "Xray config not found: %s" "$src"
		return 1
	}
	lib="$(xraywrt_lib_dir)"
	params="$(xray_params_json)" || return 1
	if [ "$mode" = key ]; then
		key="$({
			printf '%s\n' "$params"
			sha256sum <"$src"
			sha256sum <"$lib/xray-config.uc"
			[ ! -f "$RULES_FILE" ] || sha256sum <"$RULES_FILE"
			lists_rules_remote_hashes
		} | sha256sum)" || return 1
		printf '%s\n' "${key%% *}"
		return 0
	fi
	ensure_dir "$(dirname "$dst")" || return 1
	tmp="$dst.tmp.$$"
	printf '%s\n' "$params" >"$tmp.params" || return 1
	# The generator parses up to 8 MiB: let the kernel kill it before the router.
	if ! (
		{ printf '1000\n' >/proc/self/oom_score_adj; } 2>/dev/null || :
		exec xraywrt-json gen "$src" "$tmp" "$tmp.params" 2>"$tmp.err"
	); then
		line="$(sed -n 's/^xraywrt-json: //p' "$tmp.err" | tail -n 1)"
		rm -f "$tmp" "$tmp.profile" "$tmp.params" "$tmp.err"
		case "$line" in
		'config: no DNS server:'*)
			err "$line"
			# Empty WAN DNS at boot: not the config's fault, the WAN ifup retries.
			[ -n "$(dns_wan_servers)" ] || return 1
			return 2
			;;
		config:*)
			err "$line"
			return 2
			;;
		esac
		err "Failed to generate runtime config${line:+: $line}"
		return 1
	fi
	rm -f "$tmp.params" "$tmp.err"
	sed -n 's/^warn //p' "$tmp.profile" | while IFS= read -r line; do warn "config: $line"; done
	sed -n 's/^ignored //p' "$tmp.profile" | while IFS= read -r line; do
		warn_code setting_ignored "xraywrt: ignored invalid or unknown setting '%s'" "$line"
	done
	lists_profile_filter "$tmp.profile" || {
		rm -f "$tmp" "$tmp.profile"
		err "Failed to generate runtime config"
		return 1
	}
	chmod 600 "$tmp" && mv -f "$tmp.profile" "$dst.profile" && mv -f "$tmp" "$dst"
}

xray_config_key() {
	xray_config_generate "$1" "" key
}

# Accepted runtimes only, under the caller's lock. Keep a UCI snapshot until publication succeeds.
dns_forward_safety_save() {
	local profile="$1" snapshot="$2" lost="" overrides="" option="" value="" added=0 newline='
'

	# A no-op must not leave an earlier transaction's enabling snapshot available to rollback.
	rm -f "$snapshot" || {
		err_code dns_raw_persist 'Cannot discard the previous DNS forwarding protection snapshot. The new configuration was not applied; free storage and try again.'
		return 1
	}
	lost="$(sed -n 's/^dns-raw-lost //p' "$profile")" || {
		err_code dns_raw_persist 'Cannot read DNS forwarding protection metadata. The new configuration was not applied; try again.'
		return 1
	}
	[ -n "$lost" ] || return 0
	overrides="$(uci_get provider_override)"
	if [ "$(uci_get dns_raw_lost)" = "$lost" ] && [ -z "$(uci_get dns_raw_via)" ] && [ "$(uci_get dns_forward_other_types)" = 0 ]; then
		case " $overrides " in *" dns_forward_other_types "*) return 0 ;; esac
	fi
	case " $overrides " in *" dns_forward_other_types "*) ;; *) added=1 ;; esac
	if ! (umask 077; {
		for option in dns_raw_lost dns_raw_via dns_forward_other_types; do
			if value="$(uci -q get "$PKG_CONFIG.settings.$option" && printf '.')"; then
				value="${value%.}"
				case "$value" in *"$newline") value="${value%"$newline"}" ;; *) exit 1 ;; esac
				[ "$value" = "$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\037\177')" ] || exit 1
				printf '1%s\n' "$value" || exit 1
			else
				printf '0\n' || exit 1
			fi
		done
		printf '%s\n' "$added"
	} >"$snapshot"); then
		rm -f "$snapshot"
		err_code dns_raw_persist 'Cannot save DNS forwarding protection. The new configuration was not applied; free storage and try again.'
		return 1
	fi
	if uci_set dns_raw_lost "$lost" && uci_set dns_raw_via '' && uci_set dns_forward_other_types 0 &&
		{ case " $overrides " in *" dns_forward_other_types "*) true ;; *) uci -q add_list "$PKG_CONFIG.settings.provider_override=dns_forward_other_types" ;; esac; } && uci_commit; then
		return 0
	fi
	dns_forward_safety_restore "$snapshot" || :
	err_code dns_raw_persist 'Cannot save DNS forwarding protection. The new configuration was not applied; free storage and try again.'
	return 1
}

# A rejected publication must not disable a still-valid selection in the previous source.
dns_forward_safety_restore() {
	local snapshot="$1" option="" record="" value="" added="" ok=1

	[ -f "$snapshot" ] || return 0
	{
		for option in dns_raw_lost dns_raw_via dns_forward_other_types; do
			IFS= read -r record || { ok=0; break; }
			case "$record" in
				0) if uci -q get "$PKG_CONFIG.settings.$option" >/dev/null; then uci -q delete "$PKG_CONFIG.settings.$option" || ok=0; fi ;;
				1*) value="${record#1}"; uci_set "$option" "$value" || ok=0 ;;
				*) ok=0 ;;
			esac
		done
		IFS= read -r added || ok=0
		case "$added" in
			1) uci -q del_list "$PKG_CONFIG.settings.provider_override=dns_forward_other_types" || ok=0 ;;
			0) ;;
			*) ok=0 ;;
		esac
	} <"$snapshot"
	if [ "$ok" = 1 ] && uci_commit; then
		rm -f "$snapshot"
		return 0
	fi
	# If rollback cannot commit, discard its staged enabling values and retain the committed off latch.
	uci -q revert "$PKG_CONFIG"
	err_code dns_raw_persist 'Cannot restore DNS forwarding settings. Forwarding may remain off; free storage and review Advanced DNS.'
	return 1
}

# Remember the inputs $RUNTIME_CONFIG was generated from, or forget them with
# no key. Callers drop the key before replacing the config and store it only
# once the new config is live, so it never claims a file it does not describe.
runtime_config_key_store() {
	local file="$RUNTIME_CONFIG.inputs"

	rm -f "$file"
	[ -n "$1" ] || return 0
	{ printf '%s\n' "$1" >"$file.tmp.$$" && chmod 600 "$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"; } ||
		rm -f "$file" "$file.tmp.$$"
	return 0
}

# Provider profile of the installed config. Rebuilt when missing or older
# than the config (e.g. after a reboot with the service disabled).
profile_ensure() {
	local scratch="$PKG_TMP_DIR/profile.$$.json" XRAYWRT_QUIET=1

	if [ -f "$PROFILE_FILE" ]; then
		if grep -qx 'profile-schema 1' "$PROFILE_FILE" && grep -qx 'fake-enabled [01]' "$PROFILE_FILE"; then
			[ -r "$XRAY_CONFIG" ] || return 1
			! [ "$XRAY_CONFIG" -nt "$PROFILE_FILE" ] && return 0
		else
			# A failed rebuild must not leave legacy records trusted by readers.
			rm -f "$PROFILE_FILE" || return 1
		fi
	fi
	[ -r "$XRAY_CONFIG" ] || return 1
	ensure_dir "$PKG_TMP_DIR" || return 1
	if xray_config_generate "$XRAY_CONFIG" "$scratch" 2>/dev/null &&
		mv -f "$scratch.profile" "$PROFILE_FILE"; then
		rm -f "$scratch"
		return 0
	fi
	rm -f "$scratch" "$scratch.profile"
	return 1
}

profile_get() {
	[ -r "$PROFILE_FILE" ] || return 0
	sed -n "/^$1 /{s/^$1 //p;q;}" "$PROFILE_FILE"
}

profile_has() {
	[ -r "$PROFILE_FILE" ] && grep -qx "has $1" "$PROFILE_FILE"
}

profile_entries() {
	[ -r "$PROFILE_FILE" ] || return 0
	sed -n "s/^$1 //p" "$PROFILE_FILE"
}

# A start may reuse a successful test only for these bytes, this core and
# the same geodata files.
xray_config_test_key() {
	local hash="" version="" share=""

	hash="$(sha256sum "$1" 2>/dev/null)" || return 1
	version="$(core_version "${2:-$XRAY_BIN}" 2>/dev/null)" || return 1
	[ -n "$version" ] || return 1
	# shellcheck disable=SC2012 # names come from the provider's geodata keys
	share="$(ls -ln "$XRAY_SHARE_DIR" 2>/dev/null | sha256sum)"
	printf '%s %s %s\n' "${hash%% *}" "$version" "${share%% *}"
}

# Always execute the core on these assets, without publishing or caching them.
# Returns the core's status: above 128 means a signal, usually the OOM killer.
xray_config_test_run() {
	local config="$1" bin="$2" assets="$3" rc=0

	CONFIG_TEST_OUTPUT="$(
		{ printf '1000\n' >/proc/self/oom_score_adj; } 2>/dev/null || :
		XRAY_LOCATION_ASSET="$assets" exec "$bin" run -test -c "$config" 2>&1
	)" || rc=$?
	[ "$rc" != 0 ] || return 0
	printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 >&2
	return "$rc"
}

# Validate a generated config with Xray itself (`run -test`). Its own error
# text is the most useful message for the user, so it is passed through.
xray_config_test() {
	local config="$1" bin="${2:-$XRAY_BIN}" key="${3:-}" assets="$XRAY_SHARE_DIR" file="" warning="" rc=0

	CONFIG_TEST_OUTPUT=""
	GEODATA_TRANSIENT=0
	[ -x "$bin" ] || {
		CONFIG_TEST_OUTPUT="$(code_message core_missing "core missing, run core-update")"
		err "$CONFIG_TEST_OUTPUT"
		return 1
	}
	# Missing files are staged in RAM; the core must read the candidate set.
	geodata_ensure "$config.profile" || {
		CONFIG_TEST_OUTPUT="$GEODATA_ERROR"
		geodata_settle err
		return 1
	}
	for file in $GEODATA_FETCHED; do
		grep -qxF "geodata-ref $file" "$config.profile" && continue
		warning="$(code_message geodata_unverified 'These files are not used by the current settings, so they cannot be checked now. They will be checked when settings start using them.')"
		grep -qxF "warn $warning" "$config.profile" || printf 'warn %s\n' "$warning" >>"$config.profile"
		warn "$warning"
	done
	[ -z "$GEODATA_FETCHED" ] || { key=""; assets="$GEODATA_TMP_DIR/assets"; }
	xray_config_test_run "$config" "$bin" "$assets" || rc=$?
	if [ "$rc" = 0 ]; then
		if ! geodata_publish || ! geodata_settle ok; then
			geodata_settle err
			CONFIG_TEST_OUTPUT="$GEODATA_ERROR"
			return 1
		fi
		if [ -n "$key" ] || key="$(xray_config_test_key "$config" "$bin")"; then
			ensure_dir "$PKG_STATE_DIR" && atomic_write "$CONFIG_TESTED_FILE" "$key"
		fi
		return 0
	fi
	if [ "$rc" = 137 ]; then
		# Killed, not rejected (OOM): same as a failed download, a retry may help.
		GEODATA_TRANSIENT=1
		CONFIG_TEST_OUTPUT="$(code_message config_test_oom "Not enough memory to check the configuration")"
		err "$CONFIG_TEST_OUTPUT"
	else
		err_code config_rejected "Xray rejected the configuration"
	fi
	geodata_settle err
	return 1
}

# Remember the last check of a config built from $XRAY_CONFIG, so status
# never has to run the core. ok|err (err keeps Xray's last 20 lines).
config_check_record() {
	ensure_dir "$PKG_STATE_DIR" || return 1
	if [ "$1" = ok ]; then
		rm -f "$CONFIG_ERR_FILE" "$CONFIG_INVALID_FILE"
		touch "$CONFIG_OK_FILE"
	else
		# A rejection waits for config/UCI changes or a manual Start; a failed
		# geodata download is retried by the next hotplug.
		[ ! -x "$XRAY_BIN" ] || [ "${GEODATA_TRANSIENT:-0}" = 1 ] || : >"$CONFIG_INVALID_FILE"
		rm -f "$CONFIG_OK_FILE"
		printf '%s\n' "$CONFIG_TEST_OUTPUT" | tail -n 20 | error_text >"$CONFIG_ERR_FILE"
	fi
}
