#!/bin/ash

# Load UCI settings into shell variables and validate them once. Provider
# values from the profile (xraywrt key) replace UCI values unless the user
# overrides that setting (list provider_override).

# During settings_load, use its local snapshot; other callers still read live UCI.
settings_uci_get() {
	local value=""

	if [ "${SETTINGS_UCI_SNAPSHOT:-0}" != 1 ]; then
		uci_get "$1" "${2:-}"
		return
	fi
	case "$1" in '' | *[!a-zA-Z0-9_]*) return 1 ;; esac
	case "$settings_uci_seen" in
	*" $1 "*) eval 'value="${settings_uci_'"$1"':-}"' ;;
	esac
	[ -n "$value" ] || value="${2:-}"
	printf '%s' "$value"
}

# Only these settings belong to the provider; router-only options never do.
settings_provider_key() {
	case "$1" in
	mode | disable_quic | dns_hijack | bypass_ntp | bypass_subscription_dns | block_client_ipv6 | dns_forward_other_types | lists_interval | core_log_level) return 0 ;;
	*) return 1 ;;
	esac
}

settings_provider_entries() {
	profile_entries set | while IFS=' ' read -r key value; do
		if settings_provider_key "$key"; then printf '%s %s\n' "$key" "$value"; fi
	done
}

# UCI value, or the provider's when it sets the option and it is not overridden.
settings_value() {
	settings_provider_key "$1" || { settings_uci_get "$1" "${2:-}"; return; }
	case " $PROVIDER_KEYS " in
	*" $1 "*)
		case " $PROVIDER_OVERRIDES " in
		*" $1 "*) ;;
		*)
			profile_get "set $1"
			return 0
			;;
		esac
		;;
	esac
	settings_uci_get "$1" "${2:-}"
}

# url / profile of the active subscription. Without one (a hand-written
# config) the server choice stays in settings.profile.
settings_subscription_option() {
	local id=""

	id="$(settings_uci_get subscription)"
	if subscription_id_valid "$id"; then
		settings_uci_get "sub_${id}_$1"
	elif [ "$1" = profile ]; then
		settings_uci_get profile
	fi
}

settings_bool() {
	case "$(settings_value "$1" "$2")" in
	1 | on | true | yes | enabled) printf '1' ;;
	*) printf '0' ;;
	esac
}

settings_hours() {
	local value=""

	value="$(settings_value "$1" 24)"
	is_uint "$value" && [ "$value" -le 8760 ] || return 1
	uint_norm "$value"
}

lan_device_detect() {
	local dev=""

	dev="$(uci -q get network.lan.device 2>/dev/null)" || dev=""
	dev="${dev%% *}"
	is_valid_iface_name "$dev" && {
		printf '%s' "$dev"
		return 0
	}
	printf 'br-lan'
}

# Reject marks that would collide with XrayWRT, zapret or NetBird namespaces.
settings_check_netbird_mark() {
	local mark="$1" intercept=$((NFT_INTERCEPT_MARK))

	is_valid_uint32_mark "$mark" || return 1
	case "$mark" in
	0x* | 0X*) mark=$((mark)) ;;
	*) mark="$(uint_norm "$mark")" ;;
	esac
	[ $((mark & 255)) -eq 0 ] || return 1
	[ $((mark & intercept)) -eq 0 ] || return 1
	[ $((mark & NFT_DIRECT_MARK)) -eq 0 ] || return 1
	[ $((mark & ZAPRET_DESYNC_MARK)) -eq 0 ] || return 1
	[ $((mark & ZAPRET_DESYNC_MARK_POSTNAT)) -eq 0 ] || return 1
	[ "$XRAY_ROUTING_MARK" -lt "$mark" ] || [ "$XRAY_ROUTING_MARK" -gt $((mark + 255)) ]
}

# Auto-update on: the provider's profile-update-interval (no valid header =
# no automatic updates, the provider's choice). Off: 0.
settings_subscription_interval() {
	local header=""

	[ "$(settings_uci_get subscription_auto_update 1)" = "0" ] && {
		echo 0
		return 0
	}
	header="$(xraywrt-json get header_interval empty "${SUBSCRIPTION_META_FILE:-/etc/xraywrt/subscription.json}" 2>/dev/null)"
	if is_uint "$header" && [ "$header" -gt 0 ] && [ "$header" -le 8760 ]; then
		uint_norm "$header"
	else
		echo 0
	fi
}

settings_invalid() {
	ensure_dir "$PKG_STATE_DIR" && : >"$CONFIG_INVALID_FILE"
	err "Invalid $1: $2"
	return 1
}

settings_require() {
	[ "${SETTINGS_LOADED:-0}" = 1 ] || settings_load
}

settings_load() {
	local iface="" SETTINGS_UCI_SNAPSHOT=1 settings_uci_seen=" "

	# UCI show uses shell-quoted scalars and space-separated quoted list items.
	# Decode once, then quote literal values again before eval (never eval UCI).
	# The url and profile of every subscription section come along as sub_<id>_<option>.
	eval "$(uci -q show "$PKG_CONFIG" 2>/dev/null | awk -v prefix="$PKG_CONFIG.settings." -v config="$PKG_CONFIG." '
		function json_string(s,    out, j, ch) {
			# Control bytes cannot be represented safely in profile records.
			if (s ~ /[[:cntrl:]]/) return "\"invalid UCI entry\""
			out = "\""
			for (j = 1; j <= length(s); j++) {
				ch = substr(s, j, 1)
				if (ch == "\\" || ch == "\"") out = out "\\" ch
				else out = out ch
			}
			return out "\""
		}
		index($0, config) == 1 {
			if (index($0, prefix) == 1) {
				pos = index($0, "=")
				key = substr($0, length(prefix) + 1, pos - length(prefix) - 1)
			} else if (match(substr($0, length(config) + 1), /^[a-z0-9_]+\.(url|profile)=/)) {
				pos = length(config) + RLENGTH
				key = substr($0, length(config) + 1, RLENGTH - 1)
				sub(/\./, "_", key)
				key = "sub_" key
			} else next
			if (key !~ /^[a-zA-Z0-9_]+$/) next
			raw = substr($0, pos + 1)
			value = ""; quoted = 0; assets = ""; q = sprintf("%c", 39)
			for (i = 1; i <= length(raw); i++) {
				c = substr(raw, i, 1)
				if (c == q) quoted = !quoted
				else if (!quoted && c == "\\") value = value substr(raw, ++i, 1)
				else if (key == "geodata_asset" && !quoted && c == " ") {
					assets = assets (assets == "" ? "" : ",") json_string(value)
					value = ""
				} else value = value c
			}
			if (key == "geodata_asset")
				value = quoted ? "[\"invalid UCI entry\"]" : "[" assets (assets == "" ? "" : ",") json_string(value) "]"
			escaped = q
			for (i = 1; i <= length(value); i++) {
				c = substr(value, i, 1)
				escaped = escaped (c == q ? q "\\" q q : c)
			}
			print "local settings_uci_" key "=" escaped q
			seen = seen key " "
		}
		END { print "settings_uci_seen=\" " seen "\"" }
	')"

	SETTINGS_LOADED=0
	PROVIDER_OVERRIDES="$(settings_uci_get provider_override)" || PROVIDER_OVERRIDES=""
	settings_generator_load || return 1
	# Mode and fake-IP follow the generated profile; none = no config yet.
	profile_ensure 2>/dev/null || true
	POLICY_MODE="$(profile_get mode)"
	case "$POLICY_MODE" in
	direct-first | proxy-first) ;;
	*) POLICY_MODE="proxy-first" ;;
	esac
	# Spec 8: fake-IP nft rules and the direct listener follow fakedns
	# activation in the generated config.
	DNS_MODE=redir-host DIRECT_LISTENER=0
	case "$(profile_get fake-enabled)" in
	1) DNS_MODE=fake-ip DIRECT_LISTENER=1 ;;
	esac
	PROVIDER_KEYS="$(settings_provider_entries | cut -d' ' -f1 | tr '\n' ' ')"
	CORE_LOG_LEVEL="$(settings_value core_log_level warning)"

	SOURCE_INTERFACES="$(settings_uci_get source_network_interfaces)" || SOURCE_INTERFACES=""
	[ -n "$SOURCE_INTERFACES" ] || SOURCE_INTERFACES="$(lan_device_detect)"
	for iface in $SOURCE_INTERFACES; do
		is_valid_iface_name "$iface" || settings_invalid source_network_interfaces "$iface" || return 1
	done

	DNS_HIJACK="$(settings_bool dns_hijack 1)"
	DISABLE_QUIC="$(settings_bool disable_quic 1)"
	NETBIRD_PROXY="$(settings_bool netbird_proxy 0)"
	BYPASS_NTP="$(settings_bool bypass_ntp 1)"
	BYPASS_SUBSCRIPTION_DNS="$(settings_bool bypass_subscription_dns 1)"
	BLOCK_CLIENT_IPV6="$(settings_bool block_client_ipv6 0)"

	NETBIRD_MARK="$(settings_uci_get netbird_mark "$NETBIRD_DEFAULT_MARK")"
	settings_check_netbird_mark "$NETBIRD_MARK" || settings_invalid netbird_mark "$NETBIRD_MARK" || return 1
	case "$NETBIRD_MARK" in
	0x* | 0X*) NETBIRD_MARK=$((NETBIRD_MARK)) ;;
	*) NETBIRD_MARK="$(uint_norm "$NETBIRD_MARK")" ;;
	esac
	NETBIRD_INTERFACE="$(settings_uci_get netbird_interface "$NETBIRD_DEFAULT_IFACE")"
	is_valid_iface_name "$NETBIRD_INTERFACE" || settings_invalid netbird_interface "$NETBIRD_INTERFACE" || return 1

	SUBSCRIPTION_URL="$(settings_subscription_option url)"
	[ -z "$SUBSCRIPTION_URL" ] || is_http_url "$SUBSCRIPTION_URL" || settings_invalid subscription_url "$SUBSCRIPTION_URL" || return 1
	SUBSCRIPTION_INTERVAL="$(settings_subscription_interval)"
	LISTS_INTERVAL="$(settings_hours lists_interval)" || settings_invalid lists_interval "$(settings_value lists_interval)" || return 1

	CRON_MINUTE="$(settings_uci_get cron_minute 17)"
	is_uint "$CRON_MINUTE" && [ "$CRON_MINUTE" -le 59 ] || CRON_MINUTE=17
	CRON_MINUTE="$(uint_norm "$CRON_MINUTE")"
	SETTINGS_LOADED=1
	return 0
}

# Generator inputs (spec 6.1, 13) from UCI only: the provider's own values
# come from the config itself, so they cannot feed its generation.
settings_generator_load() {
	UCI_MODE="$(settings_uci_get mode proxy-first)"
	case "$UCI_MODE" in
	proxy-first | direct-first) ;;
	*) settings_invalid mode "$UCI_MODE" || return 1 ;;
	esac
	MODE_OVERRIDE=0
	case " $PROVIDER_OVERRIDES " in *" mode "*) MODE_OVERRIDE=1 ;; esac
	DNS_FORWARD_OVERRIDE=0
	case " $PROVIDER_OVERRIDES " in *" dns_forward_other_types "*) DNS_FORWARD_OVERRIDE=1 ;; esac
	PROFILE_NAME="$(settings_subscription_option profile)"
	GEODATA_ASSETS_JSON="$(settings_uci_get geodata_asset '[]')"
	GEODATA_CRON="$(settings_uci_get geodata_cron '0 5 * * *')"
	DNS_RAW_UPSTREAM="$(settings_uci_get dns_raw_upstream)"
	case "$DNS_RAW_UPSTREAM" in
	*[!0-9A-Fa-f:.\[\]]*) settings_invalid dns_raw_upstream "$DNS_RAW_UPSTREAM" || return 1 ;;
	esac
	DNS_RAW_LOST="$(settings_uci_get dns_raw_lost)"
	case "$DNS_RAW_LOST" in
	*[[:cntrl:]]*) settings_invalid dns_raw_lost "$DNS_RAW_LOST" || return 1 ;;
	esac
	DNS_RAW_VIA="$(settings_uci_get dns_raw_via)"
	case "$DNS_RAW_VIA" in
	*[[:cntrl:]]*) settings_invalid dns_raw_via "$DNS_RAW_VIA" || return 1 ;;
	esac
	DNS_FORWARD_OTHER_TYPES="$(PROVIDER_KEYS='' settings_bool dns_forward_other_types 0)"
	LOG_LEVEL_OVERRIDE=0
	case " $PROVIDER_OVERRIDES " in *" core_log_level "*) LOG_LEVEL_OVERRIDE=1 ;; esac
	UCI_CORE_LOG_LEVEL="$(settings_uci_get core_log_level warning)"
	case "$UCI_CORE_LOG_LEVEL" in
	debug | info | warning | error | none) ;;
	*) settings_invalid core_log_level "$UCI_CORE_LOG_LEVEL" || return 1 ;;
	esac
}

random_hex() {
	hexdump -n "$1" -v -e '/1 "%02x"' /dev/urandom 2>/dev/null
}

# Generate per-device values once: the cron minute that spreads
# subscription requests across the hour.
settings_ensure_generated() {
	local changed=0 minute=""

	minute="$(uci_get cron_minute)"
	if ! is_uint "$minute" || [ "$minute" -gt 59 ]; then
		minute=$(( 0x$(random_hex 1) % 60 ))
		uci_set cron_minute "$minute" || return 1
		changed=1
	fi

	[ "$changed" -eq 0 ] || uci_commit
}

# Spec 16: an absent list is empty; UCI show preserves quoted list boundaries.
settings_balancer_overrides() {
	uci -q show "$PKG_CONFIG.settings.balancer_override" 2>/dev/null | xraywrt-json balancers overrides
}
