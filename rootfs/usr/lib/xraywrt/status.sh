#!/bin/ash

# Read-only status for LuCI and the CLI.

service_enabled() {
	local link=""

	for link in /etc/rc.d/S*xraywrt; do
		[ -e "$link" ] && return 0
	done
	return 1
}

json_bool() {
	if "$@"; then echo true; else echo false; fi
}

service_state() {
	local running="${1:-}"

	[ -n "$running" ] || running="$(json_bool service_running)"
	if [ "$running" = true ]; then
		if [ -f "$DEGRADED_FILE" ]; then echo degraded
		elif [ -f "$RUNNING_MARKER" ]; then echo running
		else echo starting
		fi
	elif [ -f "$USER_STOP_FILE" ]; then echo stopped
	elif [ -f "$LAST_ERROR_FILE" ]; then echo failed
	else echo stopped
	fi
}

# Read small snapshots without an external cat; callers strip trailing newlines.
status_file_read() {
	local line=""

	{
		while IFS= read -r line || [ -n "$line" ]; do
			printf '%s\n' "$line"
		done <"$1"
	} 2>/dev/null || :
}

health_json() {
	case "$(status_file_read "$HEALTH_FILE")" in
	ok) echo true ;;
	fail) echo false ;;
	*) echo null ;;
	esac
}

degraded_reason() {
	[ -f "$DEGRADED_FILE" ] || return 0
	case "$(status_file_read "$DEGRADED_FILE")" in
	observatory) echo observatory ;;
	*) echo dns ;;
	esac
}

service_state_json() {
	local running=false

	service_running && running=true
	xraywrt-json build service --argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--arg state "$(service_state "$running")" \
		--arg degraded_reason "$(degraded_reason)" \
		--argjson dns_ok "$(health_json)" \
		--arg apply_warning "$(error_text "$APPLY_WARNING_FILE" 2>/dev/null)" \
		--arg last_error "$(error_text "$LAST_ERROR_FILE" 2>/dev/null)"
}

# Last recorded check of the installed config: true, false or null (unknown).
# Status never runs the core itself (slow and memory-hungry on routers).
config_valid_json() {
	if [ -f "$CONFIG_OK_FILE" ] && ! [ "$XRAY_CONFIG" -nt "$CONFIG_OK_FILE" ]; then
		echo true
	elif [ -f "$CONFIG_ERR_FILE" ] && ! [ "$XRAY_CONFIG" -nt "$CONFIG_ERR_FILE" ]; then
		echo false
	else
		echo null
	fi
}

# Profile warnings for the Overview (spec 15): `warn`, `ignored` and a
# direct-first config without fake-IP domains (spec 7.2).
status_warnings() {
	if [ -n "${DNS_RAW_LOST:-}${DNS_RAW_VIA:-}" ]; then
		code_message dns_raw_lost 'Forwarding of other DNS query types was turned off because its outbound became unavailable. Choose an outbound in Advanced DNS to re-enable it, or leave forwarding off.'
		printf '\n'
	fi
	[ -r "$PROFILE_FILE" ] || return 0
	# Cached warning records can belong to the previous subscription or a repaired selection.
	sed -n '/\[E:dns_raw_lost\]$/!s/^warn //p' "$PROFILE_FILE"
	sed -n 's/^ignored //p' "$PROFILE_FILE" | while IFS= read -r setting; do
		code_message setting_ignored "ignored invalid or unknown setting '%s'" "$setting"
		printf '\n'
	done
	if grep -qx 'mode direct-first' "$PROFILE_FILE" && grep -qx 'fake-enabled 0' "$PROFILE_FILE"; then
		code_message direct_no_domains 'direct-first has no fake-IP domains: only proxy IP lists are intercepted'
		printf '\n'
	fi
	return 0
}

# name asset(0|1) referenced(0|1) present(0|1) size mtime, sorted by name.
status_geodata() {
	local name="" path=""

	[ -r "$PROFILE_FILE" ] || return 0
	sed -n 's/^geodata \([^ ]*\) .*/\1/p; s/^geodata-ref //p' "$PROFILE_FILE" | sort -u | while IFS= read -r name; do
		path="$XRAY_SHARE_DIR/$name"
		printf '%s %s %s ' "$name" "$(grep -q "^geodata $name " "$PROFILE_FILE" && echo 1 || echo 0)" \
			"$(grep -qxF "geodata-ref $name" "$PROFILE_FILE" && echo 1 || echo 0)"
		if [ -f "$path" ]; then
			printf '1 %s %s\n' "$(wc -c <"$path" | tr -d ' ')" "$(date -r "$path" +%s)"
		else
			echo '0 - -'
		fi
	done
}

# core.json fields source:channel:tag:version; an installed xraywrt-core
# package wins over a missing or stale core.json (e.g. installed by hand).
status_core_source() {
	local fields="" version=""

	fields="$(core_json_get source:channel:tag:version)"
	# One database read: an installed package always has a version.
	if [ "${fields%%:*}" != package ] && version="$(pkg_version "$CORE_PACKAGE")" && [ -n "$version" ]; then
		fields="package:core::$version"
	fi
	printf '%s' "$fields"
}

# Whether Home has a balancers block: the running config has balancers, or a
# saved override is left to remove. A text match, not a parse: Home shows an
# empty block on a false hit.
status_has_balancers() {
	service_running || return 1
	grep -q '"balancers"' "$RUNTIME_CONFIG" 2>/dev/null || [ -n "$(settings_balancer_overrides 2>/dev/null)" ]
}

# NetBird is on the router: its interface exists or its program is installed.
status_netbird_present() {
	[ -d "/sys/class/net/${NETBIRD_INTERFACE:-$NETBIRD_DEFAULT_IFACE}" ] || have_command netbird
}

status_json() {
	local running=false policy=false config_valid=null config_error="" errors="" dns_outbounds=null

	settings_load 2>/dev/null || errors="$(code_message settings_invalid "Invalid XrayWRT settings")"
	if [ -n "${DNS_RAW_VIA:-}" ] && [ -z "${DNS_RAW_LOST:-}" ]; then
		dns_outbounds="$(xraywrt-json dns-outbounds "$XRAY_CONFIG" "${PROFILE_NAME:-}" 2>/dev/null || echo null)"
	fi
	service_running && running=true
	if [ "$running" = true ]; then
		nft_active && route_active && policy=true
	fi
	config_valid="$(config_valid_json)"
	[ "$config_valid" = false ] && config_error="$(error_text "$CONFIG_ERR_FILE" 2>/dev/null)"
	route_state_read 2>/dev/null

	xraywrt-json build status \
		--arg observatory_signal "$(test -f "$OBSERVATORY_FILE" && echo 1)" \
		--arg has_balancers "$(status_has_balancers && echo 1)" \
		--arg netbird "$(status_netbird_present && echo 1)" \
		--argjson running "$running" \
		--argjson enabled "$(json_bool service_enabled)" \
		--argjson dns_ok "$(health_json)" \
		--arg state "$(service_state "$running")" \
		--arg degraded_reason "$(degraded_reason)" \
		--arg apply_warning "$(error_text "$APPLY_WARNING_FILE" 2>/dev/null)" \
		--arg last_error "$(error_text "$LAST_ERROR_FILE" 2>/dev/null)" \
		--argjson policy "$policy" \
		--argjson config_valid "$config_valid" \
		--argjson config_backup "$(json_bool test -f "$XRAY_CONFIG_BACKUP")" \
		--arg config_error "$config_error" \
		--arg dns_mode "${DNS_MODE:-}" \
		--arg version "$PKG_VERSION" \
		--arg core "$(core_version)" \
		--arg mode "${POLICY_MODE:-}" \
		--arg provider "$(settings_provider_entries)" --arg overrides "$PROVIDER_OVERRIDES" \
		--arg block_client_ipv6 "${BLOCK_CLIENT_IPV6:-0}" \
		--arg dns_hijack "${DNS_HIJACK:-}" --arg disable_quic "${DISABLE_QUIC:-}" \
		--arg bypass_ntp "${BYPASS_NTP:-}" --arg bypass_subscription_dns "${BYPASS_SUBSCRIPTION_DNS:-}" \
		--arg url "${SUBSCRIPTION_URL:-}" \
		--arg custom "$(dns_global_custom_servers | tr '\n' ' ')" \
		--arg table "${ROUTE_TABLE:-}" \
		--arg priority "${ROUTE_PRIORITY:-}" \
		--arg interfaces "${SOURCE_INTERFACES:-}" \
		--arg dst "$(lists_count dst)" --arg src "$(lists_count src)" --arg direct "$(lists_count direct)" \
		--arg direct_src "$(lists_count direct_src)" \
		--arg errors "$errors" \
		--arg profile_name "${PROFILE_NAME:-}" --arg profile_selected "$(profile_get profile)" \
		--arg profile_pinned "$(profile_get profile-pinned)" \
		--arg core_source "$(status_core_source)" \
		--arg fake_enabled "$(profile_get fake-enabled)" \
		--arg direct_domains "$(profile_get direct-domains)" --arg sniff "$(profile_get sniff)" \
		--arg warnings "$(status_warnings)" --arg fake_domains "$(profile_get fake-domains)" \
		--argjson dns_outbounds "$dns_outbounds" \
		--arg dns_raw_lost "${DNS_RAW_LOST:-}" --arg dns_raw_via "${DNS_RAW_VIA:-}" \
		--arg geodata "$(status_geodata)"
}

# Bounded, validated provider literals only; URL contents never leave the router.
provider_list_preview() {
	local kind="$1"
	lists_provided "$kind" || { printf 'links 0\n'; return; }
	lists_provider_entries "$kind" | awk '
		tolower($0) ~ /^https?:\/\// { links++; next }
		length($0) > 256 || ++candidates > 100 { truncated = 1 }
		END { print "links " links+0; if (truncated) print "truncated 1" }
	'
	lists_provider_entries "$kind" | awk '
		tolower($0) ~ /^https?:\/\// || length($0) > 256 { next }
		++candidates <= 100 { print }
	' | lists_classify 0 "$kind" | awk '
		NR <= 50 { sub(/^[^ ]+ /, ""); print "address " $0 }
		END { if (NR > 50) print "truncated 1" }
	'
}

# Provider profile for the Lists page: mode, DNS, provider settings,
# the user's overrides and provider list state.
profile_json() {
	local preview_unavailable=1 vpn_preview="" direct_preview=""
	settings_load || return 1
	if [ -r "$XRAY_CONFIG" ] && [ -r "$PROFILE_FILE" ] &&
		grep -qx 'profile-schema 1' "$PROFILE_FILE" && grep -qx 'fake-enabled [01]' "$PROFILE_FILE" &&
		! [ "$XRAY_CONFIG" -nt "$PROFILE_FILE" ]; then
		preview_unavailable=0
		vpn_preview="$(provider_list_preview dst)"
		direct_preview="$(provider_list_preview direct)"
	fi
	xraywrt-json build profile \
		--arg mode "$POLICY_MODE" --arg mode_source "$(profile_get mode-source)" \
		--arg fake_enabled "$(profile_get fake-enabled)" \
		--arg direct_domains "$(profile_get direct-domains)" --arg sniff "$(profile_get sniff)" --arg dns "$DNS_MODE" \
		--arg provider "$(settings_provider_entries)" \
		--arg overrides "$PROVIDER_OVERRIDES" \
		--argjson dns_outbounds "$(xraywrt-json dns-outbounds "$XRAY_CONFIG" "$PROFILE_NAME" 2>/dev/null || echo null)" \
		--arg dns_raw_lost "${DNS_RAW_LOST:-}" --arg dns_raw_via "${DNS_RAW_VIA:-}" \
		--arg sniff_skipped_targets "$(profile_entries rules-sniff-skipped-target)" \
		--arg targets "$(lists_rule_targets)" --arg reserved "$(profile_entries rules-reserved)" \
		--arg provider_lists "$({ lists_provided dst || lists_provided direct; } && echo 1)" \
		--arg preview_unavailable "$preview_unavailable" --arg vpn_preview "$vpn_preview" --arg direct_preview "$direct_preview"
}

diagnostics_json() {
	local dns_error="" package="" installed="" conflicts="" flash="" ram="" rss="" pid="" tmp_xraywrt=""

	dns_error="$(dns_guard 2>&1)" || :
	installed="$(pkg_installed_names)"
	for package in $CONFLICT_PACKAGES; do
		case "
$installed
" in
		*"
$package
"*) conflicts="${conflicts}${package}
" ;;
		esac
	done
	tmp_xraywrt="$(du -sk "$PKG_TMP_DIR" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
	flash="$(df -kP /opt/xraywrt 2>/dev/null | awk 'END { if (NR > 1 && $4 ~ /^[0-9]+$/) print $4 }')"
	ram="$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	if pid="$(service_pid)"; then
		rss="$(awk '$1 == "VmRSS:" && $2 ~ /^[0-9]+$/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)"
	fi
	xraywrt-json build diagnostics --arg model "$(head -c 256 /tmp/sysinfo/model 2>/dev/null)" \
		--arg conflicts "$conflicts" --arg flash "$flash" --arg ram "$ram" \
		--arg rss "$rss" --arg tmp_xraywrt "$tmp_xraywrt" \
		--arg dns_guard_error "$(printf '%s' "$dns_error" | error_text)" \
		--argjson config_valid "$(config_valid_json)" \
		--arg config_output "$([ "$(config_valid_json)" != false ] || cat "$CONFIG_ERR_FILE" 2>/dev/null)"
}

logs_json() {
	local limit="${1:-200}" detail="${2:-}"

	is_uint "$limit" && [ "$limit" -ge 1 ] || limit=200
	[ "$limit" -le 1000 ] || limit=1000
	have_command logread || {
		xraywrt-json build logs --argjson available false
		return 0
	}
	# Drop every core line about DNS traffic to the core DNS port, not only the watchdog's
	# probe (one line every 15 s buries everything else).
	logread 2>/dev/null | grep -iE 'xraywrt|xray' | {
		if [ "$detail" = full ]; then cat; else grep -vF "handling DNS traffic to 127.0.0.1:$XRAY_DNS_PORT/udp"; fi
	} | tail -n "$limit" | xraywrt-json build logs --rawfile l /dev/stdin
}
