#!/bin/ash

# Subscription metadata, settings, downloads and installation.

SUBSCRIPTION_MAX_BYTES="${SUBSCRIPTION_MAX_BYTES:-8388608}"
SUBSCRIPTION_TIMEOUT="${SUBSCRIPTION_TIMEOUT:-60}"
SUBSCRIPTION_META_FILE="${SUBSCRIPTION_META_FILE:-/etc/xraywrt/subscription.json}"

# --- subscription metadata ---------------------------------------------------

# Decode "base64:..." header values. A payload that cannot be decoded (bad
# format, over 16384 characters, invalid UTF-8, NUL) gives an empty value;
# plain values are kept as sent.
subscription_decode_metadata_value() {
	local raw="$1" payload="" decoded=""

	case "$raw" in
	base64:*) ;;
	*)
		printf '%s' "$raw"
		return 0
		;;
	esac
	payload="$(printf '%s' "${raw#base64:}" | tr -d ' \t\r\n')"
	# BusyBox base64 accepts malformed padding, so check the format first.
	case "$payload" in
	'' | *[!A-Za-z0-9+/=]* | *=[!=]* | *===*) return 0 ;;
	esac
	[ $((${#payload} % 4)) -eq 0 ] && [ "${#payload}" -le 16384 ] || return 0
	# Keep metadata compatibility: drop NUL, invalid UTF-8 and U+FFFD.
	decoded="$(printf '%s' "$payload" | xraywrt-json base64 2>/dev/null)"
	printf '%s' "$decoded"
}

subscription_metadata_from_headers() {
	local file="${FETCH_HDR:-/dev/null}"
	local title="" announce="" support="" web="" interval=""
	local upload="" download="" total="" expire=""

	[ -f "$file" ] || file=/dev/null
	{
		IFS= read -r title || true
		IFS= read -r announce || true
		IFS= read -r support || true
		IFS= read -r web || true
		IFS= read -r interval || true
		IFS= read -r upload || true
		IFS= read -r download || true
		IFS= read -r total || true
		IFS= read -r expire || true
	} <<EOF
$(awk '
/^HTTP\// {
	title = ""; announce = ""; support = ""; web = ""; interval = ""; userinfo = ""
}
{
	line = $0
	sub(/\r$/, "", line)
	i = index(line, ":")
	if (i) {
		name = tolower(substr(line, 1, i - 1))
		val = substr(line, i + 1)
		gsub(/[\r\n\t]/, " ", val)
		gsub(/[\001-\037]/, "", val)
		sub(/^[[:space:]]+/, "", val)
		sub(/[[:space:]]+$/, "", val)
		if (name == "profile-title") title = val
		else if (name == "announce") announce = val
		else if (name == "support-url") support = val
		else if (name == "profile-web-page-url") web = val
		else if (name == "profile-update-interval") interval = val
		else if (name == "subscription-userinfo") userinfo = val
	}
}
END {
	if (userinfo != "") {
		n = split(userinfo, parts, ";")
		for (k = 1; k <= n; k++) {
			p = parts[k]
			sub(/^[[:space:]]+/, "", p)
			eq = index(p, "=")
			if (eq) {
				kname = substr(p, 1, eq - 1)
				val = substr(p, eq + 1)
				match(val, /^[0-9]*/)
				digits = substr(val, RSTART, RLENGTH)
				if (kname == "upload" && !has_u) { upload = digits; has_u = 1 }
				else if (kname == "download" && !has_d) { download = digits; has_d = 1 }
				else if (kname == "total" && !has_t) { total = digits; has_t = 1 }
				else if (kname == "expire" && !has_e) { expire = digits; has_e = 1 }
			}
		}
	}
	print title
	print announce
	print support
	print web
	print interval
	print upload
	print download
	print total
	print expire
}' "$file" 2>/dev/null)
EOF

	title="$(subscription_decode_metadata_value "$title")"
	announce="$(subscription_decode_metadata_value "$announce")"

	xraywrt-json build metadata \
		--arg title "$title" \
		--arg announce "$announce" \
		--arg support "$support" \
		--arg web "$web" \
		--arg interval "$interval" \
		--arg upload "$upload" \
		--arg download "$download" \
		--arg total "$total" \
		--arg expire "$expire"
}

subscription_stamp_file() {
	if [ -f "$PKG_STATE_DIR/subscription.stamp" ]; then
		printf '%s\n' "$PKG_STATE_DIR/subscription.stamp"
	elif [ -f "$SUBSCRIPTION_META_FILE" ]; then
		printf '%s\n' "$SUBSCRIPTION_META_FILE"
	else
		return 1
	fi
}

# The usage counters (upload, download) change at every fetch. They live in
# tmpfs so that flash is rewritten only when other metadata changes; after a
# reboot the last flash copy is the fallback.
subscription_usage_file() {
	printf '%s\n' "$PKG_STATE_DIR/subscription-usage.json"
}

# shortcut: relies on the key order of `xraywrt-json build metadata`; any other layout counts as changed.
subscription_without_usage() {
	sed 's/"upload":[^,]*,"download":[^,]*,//' "$1" 2>/dev/null
}

subscription_save_usage() {
	local usage=""

	usage="$(sed -n 's/.*\("upload":[^,]*,"download":[^,]*\),.*/{\1}/p' "$1")"
	[ -z "$usage" ] || printf '%s\n' "$usage" >"$(subscription_usage_file)" 2>/dev/null
	return 0
}

# Display name: the provider's title, else the host of the link.
subscription_name() {
	local title=""

	title="$(xraywrt-json get profile_title empty "$1" 2>/dev/null)"
	[ -n "$title" ] || title="$(url_host "$2")"
	printf '%s' "$title"
}

# JSON array of the saved subscriptions: id, name, updated and their metadata.
subscription_items() {
	local id="" active="" file="" meta="" items="" sep=""

	active="$(uci_get subscription)"
	for id in $(subscription_ids); do
		if [ "$id" = "$active" ]; then file="$SUBSCRIPTION_META_FILE"; else file="$XRAY_SUBS_DIR/$id/subscription.json"; fi
		meta=""
		[ ! -r "$file" ] || meta="$(xraywrt-json object "$file" 2>/dev/null)"
		[ -n "$meta" ] || meta="{}"
		items="$items$sep$(xraywrt-json build object --arg id "$id" --arg name "$(subscription_name "$file" "$(subscription_option "$id" url)")" \
			--arg updated "$(subscription_option "$id" updated)" --argjson meta "$meta")"
		sep=,
	done
	printf '[%s]\n' "$items"
}

# The link is the credential: the read role gets the host only (https://host/…).
subscription_url_masked() {
	local host=""

	[ -n "$1" ] || return 0
	host="$(url_host "$1")"
	case "$host" in *:*) host="[$host]" ;; esac
	printf '%s://%s/…' "${1%%://*}" "$host"
}

# subscription-json [--mask]
subscription_json() {
	local meta="{}" usage="{}" stamp="" backup=false active="" url=""

	case "${1:-}" in '' | --mask) ;; *) return 1 ;; esac

	stamp="$(subscription_stamp_file)" || stamp=""
	[ ! -f "$XRAY_CONFIG_BACKUP" ] || backup=true
	active="$(uci_get subscription)"
	url="$(subscription_option "$active" url)"
	[ "${1:-}" != --mask ] || url="$(subscription_url_masked "$url")"

	# A damaged file must not break the page: fall back to no metadata.
	[ -r "$SUBSCRIPTION_META_FILE" ] && meta="$(xraywrt-json object "$SUBSCRIPTION_META_FILE" 2>/dev/null)"
	[ -n "$meta" ] || meta="{}"
	[ -r "$(subscription_usage_file)" ] && usage="$(xraywrt-json object "$(subscription_usage_file)" 2>/dev/null)"
	[ -n "$usage" ] || usage="{}"
	xraywrt-json build subscription --argjson usage "$usage" --arg url "$url" --arg auto "$(uci_get subscription_auto_update 1)" \
		--arg effective "$(settings_subscription_interval)" --arg updated "$(date -r "$stamp" +%s 2>/dev/null)" --argjson meta "$meta" \
		--argjson backup "$backup" --arg active "$active" --argjson subscriptions "$(subscription_items)"
}

# Only the auto-update flag changes here; the link is the active subscription's.
subscription_set() {
	local url="$1" auto="$2"

	case "$auto" in
	0 | 1) ;;
	*)
		err "Auto-update must be 0 or 1"
		return 1
		;;
	esac
	[ "$url" = "$(subscription_option "$(uci_get subscription)" url)" ] || {
		err "The link must be the active subscription's; use add-subscription and delete-subscription to change subscriptions"
		return 1
	}
	# "Update now" saves the same values: no UCI commit, cron or DNS work.
	[ "$auto" = "$(uci_get subscription_auto_update)" ] && return 0
	uci_set subscription_auto_update "$auto" && uci_commit || return 1
	settings_load && cron_update
	[ -f "$RUNNING_MARKER" ] && dns_apply
	return 0
}

# A and AAAA answers for a host from the router resolver (dnsmasq).
subscription_host_addresses() {
	{
		if is_ipv4 "$1" || is_ipv6 "$1"; then
			echo "$1"
		else
			nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/ { name = 1; next } name && /^Address/ { sub(/^Address[^:]*:[[:space:]]*/, ""); print }'
		fi
	} | awk -v range="$FAKEIP_RANGE" '
	function ipv4(ip, octets) {
		split(ip, octets, ".")
		return ((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4]
	}
	BEGIN { split(range, cidr, "/"); size = 2 ^ (32 - cidr[2]); network = int(ipv4(cidr[1]) / size) }
	index($0, ":") || int(ipv4($0) / size) != network { print }'
}

# The service may stop during a download or while waiting for the lock.
subscription_dns_sync() {
	[ -f "$RUNNING_MARKER" ] || return 0
	dns_apply
}

# Restore DNS exceptions from the saved URL after a failed replacement.
subscription_restore_dns() {
	settings_load && with_lock subscription_dns_sync
}

# Keep the installed config, metadata and saved URL in one runtime transaction.
subscription_install() {
	local candidate="$1" meta="$2" new_url="$3" result="" interval="" auto=0 id="" metadata_file="$PKG_TMP_DIR/subscription.$$.json"

	subscription_recover || {
		subscription_repair_error
		return 1
	}
	# The download was made for the subscription that was active then; a switch may have come in between.
	[ $# -lt 4 ] || [ "$(uci_get subscription)" = "$4" ] || {
		err_code subscription_changed "The active subscription changed during the download. Nothing was changed; try again."
		return 1
	}
	# A first link is saved only after the install: the generator must still treat the config as a provider's.
	result="$(SUBSCRIPTION_INSTALLING=1 config_install "$candidate")" || return 1
	ensure_dir "$(dirname "$SUBSCRIPTION_META_FILE")"
	# Written only on change (not counting the usage counters) to spare flash.
	if [ -n "$meta" ]; then
		if ! (umask 077 && printf '%s\n' "$meta" >"$metadata_file"); then
			warn "Cannot write $SUBSCRIPTION_META_FILE"
		else
			subscription_save_usage "$metadata_file"
			if [ "$(subscription_without_usage "$metadata_file")" != "$(subscription_without_usage "$SUBSCRIPTION_META_FILE")" ] &&
				! atomic_copy "$metadata_file" "$SUBSCRIPTION_META_FILE"; then
				warn "Cannot write $SUBSCRIPTION_META_FILE"
			fi
		fi
		rm -f "$metadata_file"
	else
		warn "Subscription metadata could not be parsed; keeping the previous one"
	fi
	id="$(uci_get subscription)"
	if [ -n "$new_url" ] && [ "$new_url" != "$(subscription_option "$id" url)" ]; then
		interval="$(printf '%s' "$meta" | xraywrt-json get header_interval 2>/dev/null)"
		case "$interval" in
		'' | *[!0-9]*) ;;
		*) [ "$interval" -lt 1 ] || [ "$interval" -gt 8760 ] || auto=1 ;;
		esac
		# A new link replaces the active one; the first link creates the first subscription.
		[ -n "$id" ] || id="$(subscription_new_id)"
		if ! { uci -q set "$PKG_CONFIG.$id=subscription" && subscription_option_set "$id" url "$new_url" && subscription_option_set "$id" updated "$(date +%s)" &&
			uci_set subscription "$id" && uci_set subscription_auto_update "$auto" && uci_commit; }; then
			warn "Failed to save the subscription defaults"
		fi
	fi
	touch "$PKG_STATE_DIR/subscription.stamp" 2>/dev/null
	printf '%s\n' "$result"
}

# A new config is live: reload settings (the period header and provider lists
# may be new), fetch the lists that are due and refresh the cron entry.
subscription_settled() {
	local result="$1"

	settings_load || return 1
	if [ -n "$(lists_urls)" ] && [ "$(lists_update_remote 0)" = changed ]; then
		if ! with_lock lists_policy_apply; then
			apply_result "$result" "$(apply_partial_message)"
			return
		fi
	fi
	cron_update || warn "Failed to update cron schedule"
	printf '%s\n' "$result"
}

# Download the subscription, validate and install it, update metadata.
# With a URL argument that link is tried and saved only if it works, so a
# typo never replaces the working link. With "park" the download is only
# saved next to the active subscription (subscription_store).
subscription_update() {
	local new_url="${1:-}" park="${2:-}" install=subscription_install candidate="$PKG_TMP_DIR/subscription.$$.json" headers_file="$PKG_TMP_DIR/subscription.$$.headers" meta="" result="" bypass="" rc=0 dns_changed=0 saved_host="" active="" id=""

	settings_load || return 1
	saved_host="$(url_host "$SUBSCRIPTION_URL")"
	active="$(uci_get subscription)"
	if [ -n "$new_url" ]; then
		is_http_url "$new_url" || {
			err_code subscription_url "Subscription download failed: invalid_url"
			return 1
		}
		# A saved link belongs to its own subscription: use or update that one.
		if [ -z "$park" ] && id="$(subscription_id_of_url "$new_url")" && [ "$id" != "$active" ]; then
			err_code subscription_exists "This link is already saved as another subscription."
			return 1
		fi
		SUBSCRIPTION_URL="$new_url"
	fi
	[ -n "$SUBSCRIPTION_URL" ] || {
		err "Subscription URL is not set"
		return 1
	}
	ensure_dir "$PKG_TMP_DIR" || return 1
	(umask 077 && : >"$candidate" && : >"$headers_file") || {
		rm -f "$candidate" "$headers_file"
		return 1
	}
	if [ -f "$RUNNING_MARKER" ] && [ "$saved_host" != "$(url_host "$SUBSCRIPTION_URL")" ]; then
		dns_changed=1
		with_lock subscription_dns_sync || {
			rm -f "$candidate" "$headers_file"
			subscription_restore_dns || warn "Failed to restore subscription DNS"
			return 1
		}
	fi
	# Download directly (not through Xray) when the toggle is on: the IPs
	# come from the same resolver curl uses and are removed right after.
	bypass=""
	if [ "${BYPASS_SUBSCRIPTION_DNS:-0}" = "1" ] && nft_active; then
		bypass="$(subscription_host_addresses "$(url_host "$SUBSCRIPTION_URL")")"
		# shellcheck disable=SC2086
		[ -z "$bypass" ] || nft_bypass add $bypass
	fi
	rc=0
	http_fetch "$SUBSCRIPTION_URL" "$candidate" "$SUBSCRIPTION_MAX_BYTES" "$SUBSCRIPTION_TIMEOUT" 1 "$headers_file" || rc=$?
	# shellcheck disable=SC2086
	[ -z "$bypass" ] || nft_bypass delete $bypass
	if [ "$rc" -ne 0 ]; then
		rm -f "$candidate" "$headers_file"
		case "$FETCH_ERROR" in
		http_404) err_code subscription_not_found "Subscription download failed: http_404" ;;
		http_401 | http_403) err_code subscription_access "Subscription download failed: http_%s" "${FETCH_ERROR#http_}" ;;
		http_*) err_code subscription_http "Subscription download failed: http_%s" "${FETCH_ERROR#http_}" ;;
		too_large) err_code subscription_large "Subscription download failed: too_large" ;;
		invalid_url) err_code subscription_url "Subscription download failed: invalid_url" ;;
		*) err_code subscription_network "Subscription download failed: %s" "$FETCH_ERROR" ;;
		esac
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	fi
	[ -s "$candidate" ] || {
		rm -f "$candidate" "$headers_file"
		err_code subscription_empty "Subscription returned an empty config"
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	}
	meta="$(subscription_metadata_from_headers)" || meta=""
	# Download without the lock; only installing needs it. The format
	# (spec 5.1) is checked by the generator inside config_install.
	[ -z "$park" ] || install=subscription_store
	result="$(with_lock "$install" "$candidate" "$meta" "$new_url" "$active")" || {
		rm -f "$candidate" "$headers_file"
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		return 1
	}
	rm -f "$candidate"
	rm -f "$headers_file"
	# A parked subscription changes nothing that runs; only the typed host's DNS exception goes.
	if [ -n "$park" ]; then
		[ "$dns_changed" = 0 ] || subscription_restore_dns || warn "Failed to restore subscription DNS"
		printf '%s\n' "$result"
		return 0
	fi
	subscription_settled "$result"
}

# Connect only after a successful install. Init owns its runtime lock in a
# separate process, so enable/restart must remain outside with_lock.
subscription_connect() {
	local result=""

	result="$(subscription_update "$1")" || return 1
	/etc/init.d/xraywrt enable 9>&- >/dev/null &&
		/etc/init.d/xraywrt restart 9>&- >/dev/null || return 1
	xraywrt-json build connected --argjson result "$result"
}

subscription_due() {
	local stamp=""

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] || return 1
	stamp="$(subscription_stamp_file)" || return 0
	[ -n "$(find "$stamp" -mmin +$((SUBSCRIPTION_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}

# --- saved subscriptions -----------------------------------------------------
# The active subscription uses the normal paths. Every other one is parked in
# $XRAY_SUBS_DIR/<id>/{config.json,subscription.json,share/}, on the same
# filesystem as share/: its geodata moves by hard link and rename, never by copy.

# Per subscription: the options below (option:default), the lists in
# SUBSCRIPTION_SETTING_LISTS and the policy list files. The active subscription
# keeps them in settings and in LIST_DIR; a parked one in its section and its directory.
SUBSCRIPTION_SETTINGS="mode:proxy-first discord_voice:0 disable_quic:0 dns_hijack:0 bypass_ntp:0 bypass_subscription_dns:0 block_client_ipv6:0 dns_forward_other_types:0 block_https_svcb:0 lists_interval:0 core_log_level:warning dns_raw_upstream: dns_raw_via: dns_raw_lost:"
SUBSCRIPTION_SETTING_LISTS="provider_override balancer_override"
SUBSCRIPTION_LISTS="rules src direct_src"

# The items of a UCI list, one per line (uci show quotes them).
subscription_uci_items() {
	uci -q show "$PKG_CONFIG.$1.$2" 2>/dev/null | awk '
		{
			raw = $0; sub(/^[^=]*=/, "", raw); value = ""; quoted = 0; q = sprintf("%c", 39)
			for (i = 1; i <= length(raw); i++) {
				c = substr(raw, i, 1)
				if (c == q) quoted = !quoted
				else if (!quoted && c == "\\") value = value substr(raw, ++i, 1)
				else if (!quoted && c == " ") { if (value != "") print value; value = "" }
				else value = value c
			}
			if (value != "") print value
		}'
}

# Copy the per-subscription settings between two UCI sections (settings or an
# id). With "defaults" an option the source lacks gets its default, so a new
# subscription starts clean. Committed by the caller.
subscription_copy_settings() {
	local from="$1" to="$2" defaults="${3:-}" pair="" opt="" value="" item=""

	ensure_dir "$PKG_TMP_DIR" || return 1
	for pair in $SUBSCRIPTION_SETTINGS; do
		opt="${pair%%:*}"
		value="$(uci -q get "$PKG_CONFIG.$from.$opt" 2>/dev/null)"
		[ -n "$value" ] || [ -z "$defaults" ] || value="${pair#*:}"
		if [ -n "$value" ]; then
			uci -q set "$PKG_CONFIG.$to.$opt=$value" || return 1
		elif uci -q get "$PKG_CONFIG.$to.$opt" >/dev/null 2>&1; then
			uci -q delete "$PKG_CONFIG.$to.$opt" || return 1
		fi
	done
	for opt in $SUBSCRIPTION_SETTING_LISTS; do
		subscription_uci_items "$from" "$opt" >"$PKG_TMP_DIR/subscription.$$.items"
		if uci -q get "$PKG_CONFIG.$to.$opt" >/dev/null 2>&1; then
			uci -q delete "$PKG_CONFIG.$to.$opt" || return 1
		fi
		while IFS= read -r item; do
			uci -q add_list "$PKG_CONFIG.$to.$opt=$item" || return 1
		done <"$PKG_TMP_DIR/subscription.$$.items"
	done
	rm -f "$PKG_TMP_DIR/subscription.$$.items"
	return 0
}

# Own lists of the active subscription into <id>'s directory, and back (an
# absent parked list empties the live one).
subscription_park_lists() {
	local dir="$XRAY_SUBS_DIR/$1/lists" name="" file=""

	ensure_dir "$dir" || return 1
	for name in $SUBSCRIPTION_LISTS; do
		file="$(lists_file "$name")"
		[ ! -f "$file" ] || cp "$file" "$dir/$name.txt" || return 1
	done
}

subscription_restore_lists() {
	local dir="$XRAY_SUBS_DIR/$1/lists" name="" file=""

	for name in $SUBSCRIPTION_LISTS; do
		file="$(lists_file "$name")"
		if [ -f "$dir/$name.txt" ]; then
			atomic_copy "$dir/$name.txt" "$file" || return 1
		elif [ -f "$file" ]; then
			: >"$file" || return 1
		fi
	done
}

# Only the most recently used inactive subscriptions keep their geodata.
subscription_evict_geodata() {
	local id="" kept=1 active="" ordered=""

	active="$(uci_get subscription)"
	ordered="$(for id in $(subscription_ids); do printf '%s %s\n' "$(subscription_option "$id" used)" "$id"; done | sort -rn | cut -d' ' -f2)"
	for id in $ordered; do
		[ "$id" != "$active" ] || continue
		if [ "$kept" -lt "$SUBSCRIPTION_GEODATA_KEEP" ]; then
			kept=$((kept + 1))
		else
			rm -f "${XRAY_SUBS_DIR:?}/$id/share"/*.dat
		fi
	done
}

subscription_id_of_url() {
	local id=""

	for id in $(subscription_ids); do
		[ "$(subscription_option "$id" url)" != "$1" ] || {
			printf '%s' "$id"
			return 0
		}
	done
	return 1
}

# The user's own rule databases (uploads, geodata_asset links) belong to no subscription.
subscription_own_geodata() {
	case " $(uci_get geodata_asset | sed 's/=[^ ]*//g') " in *" $1 "*) return 0 ;; esac
	grep -qxF "$1" "$GEODATA_MANUAL_FILE" 2>/dev/null
}

# Names of the share/ files that a subscription's provider supplied.
subscription_provider_geodata() {
	local path="" name=""

	for path in "$XRAY_SHARE_DIR"/*.dat; do
		[ -f "$path" ] || continue
		name="${path##*/}"
		! geodata_name_valid "$name" || subscription_own_geodata "$name" || printf '%s\n' "$name"
	done
	return 0
}

# The journal names a switch in progress: "<from> <to> [parked]". "parked" is
# written once <from> is complete in its directory; before that share/ is untouched.
subscription_journal() {
	local journal="$XRAY_SUBS_DIR/.switch"

	ensure_dir "$XRAY_SUBS_DIR" && printf '%s %s %s\n' "$1" "$2" "${3:-}" >"$journal.tmp" && mv -f "$journal.tmp" "$journal" && sync
}

# Copy the active config, metadata (with the latest usage counters), settings and lists, and link its geodata.
subscription_park() {
	local id="$1" dir="$XRAY_SUBS_DIR/$1" name="" stamp="" counters=""

	rm -rf "$dir" && ensure_dir "$dir/share" || return 1
	atomic_copy "$XRAY_CONFIG" "$dir/config.json" && chmod 600 "$dir/config.json" || return 1
	if [ -f "$SUBSCRIPTION_META_FILE" ]; then
		counters="$(sed -n 's/.*"upload":\([^,]*\),"download":\([^,]*\),.*/--argjson upload \1 --argjson download \2/p' "$(subscription_usage_file)" 2>/dev/null)"
		# shellcheck disable=SC2086 # fixed words
		xraywrt-json merge object $counters "$SUBSCRIPTION_META_FILE" >"$dir/subscription.json" 2>/dev/null ||
			cp "$SUBSCRIPTION_META_FILE" "$dir/subscription.json" || return 1
	fi
	for name in $(subscription_provider_geodata); do
		ln -f "$XRAY_SHARE_DIR/$name" "$dir/share/$name" || return 1
	done
	if stamp="$(subscription_stamp_file)"; then
		subscription_option_set "$id" updated "$(date -r "$stamp" +%s)"
	fi
	subscription_option_set "$id" used "$(date +%s)"
	subscription_copy_settings settings "$id" && subscription_park_lists "$id"
}

# Make the provider's files in share/ exactly the set parked for <id>.
subscription_share_from() {
	local name="" path=""

	for name in $(subscription_provider_geodata); do
		rm -f "$XRAY_SHARE_DIR/$name" || return 1
	done
	for path in "$XRAY_SUBS_DIR/$1/share"/*.dat; do
		[ -f "$path" ] || continue
		name="${path##*/}"
		{ geodata_name_valid "$name" && ! subscription_own_geodata "$name"; } || continue
		ln -f "$path" "$XRAY_SHARE_DIR/$name" || return 1
	done
}

# Set the download time <2> as the mtime of <1>. Where touch cannot, the
# subscription counts as stale and is updated at the next chance.
subscription_touch() {
	touch -d "@$2" "$1" 2>/dev/null && return 0
	warn "Cannot set the update time of $1; the subscription will be updated at the next chance"
	touch -t 197001010000 "$1"
}

# <to> is installed: its metadata and download time replace the old ones. The
# journal goes before the parked copy, which is what recovery compares against.
# The switch itself is complete here, so a failure only warns: it must not keep the journal.
subscription_switch_finish() {
	local dir="$XRAY_SUBS_DIR/$1" updated=""

	if [ -f "$dir/subscription.json" ]; then
		atomic_copy "$dir/subscription.json" "$SUBSCRIPTION_META_FILE" || warn "Cannot copy the metadata of the new subscription to $SUBSCRIPTION_META_FILE"
	else
		rm -f "$SUBSCRIPTION_META_FILE"
	fi
	# The previous config belonged to the other subscription; so did its counters.
	rm -f "$XRAY_CONFIG_BACKUP" "$(subscription_usage_file)"
	updated="$(subscription_option "$1" updated)"
	is_uint "$updated" || updated=0
	ensure_dir "$PKG_STATE_DIR" && subscription_touch "$PKG_STATE_DIR/subscription.stamp" "$updated"
	[ ! -f "$SUBSCRIPTION_META_FILE" ] || subscription_touch "$SUBSCRIPTION_META_FILE" "$updated"
	rm -f "$XRAY_SUBS_DIR/.switch"
	rm -rf "$dir"
	subscription_evict_geodata
}

# The switch failed: the previous subscription's files and the active id come back.
subscription_switch_abort() {
	local journal="$XRAY_SUBS_DIR/.switch" from="" to="" state="" active=""

	read -r from to state <"$journal"
	subscription_id_valid "$from" || return 1
	# Staged edits of the switch are not committed; the flash holds what counts.
	uci -q revert "$PKG_CONFIG"
	active="$(uci_get subscription)"
	if [ "$state" = parked ]; then
		subscription_share_from "$from" && subscription_restore_lists "$from" || return 1
		# A's settings reached its section only with the commit of the switch.
		[ "$active" != "$to" ] || subscription_copy_settings "$from" settings defaults || return 1
	fi
	[ "$active" = "$from" ] || { uci_set subscription "$from" && uci_commit; } || return 1
	rm -f "$journal"
	rm -rf "${XRAY_SUBS_DIR:?}/$from"
	geodata_prune "$PROFILE_FILE"
	# A core that restarted on the other geodata reads the restored files again.
	! service_running || geodata_unchanged || core_restart || :
}

# Repair a switch that did not end (power loss, killed job): if <to> is the
# committed active subscription and its config is installed the switch
# finishes, otherwise it is undone. Equal config bytes alone prove nothing.
# Caller holds the lock.
subscription_recover() {
	local journal="$XRAY_SUBS_DIR/.switch" from="" to="" state="" active=""

	if [ ! -f "$journal" ]; then
		# A crash between the journal and the parked copy leaves the active one's directory.
		active="$(uci_get subscription)"
		[ -z "$active" ] || ! subscription_id_valid "$active" || rm -rf "${XRAY_SUBS_DIR:?}/$active"
		return 0
	fi
	read -r from to state <"$journal"
	if ! { subscription_id_valid "$from" && subscription_id_valid "$to"; }; then
		rm -f "$journal"
		return 0
	fi
	uci -q revert "$PKG_CONFIG"
	if [ "$(uci_get subscription)" = "$to" ] && cmp -s "$XRAY_CONFIG" "$XRAY_SUBS_DIR/$to/config.json"; then
		subscription_switch_finish "$to"
	else
		subscription_switch_abort
	fi
}

subscription_repair_error() {
	err_code subscription_repair "Cannot finish an interrupted subscription switch. Free some space on the router (delete a subscription you do not use) and try again."
}

# Park the active subscription, bring in <id>'s geodata and install its stored
# config through the normal transaction; any failure restores the previous one.
subscription_switch() {
	local id="$1" from="" dir="$XRAY_SUBS_DIR/$1" result=""

	subscription_recover || {
		subscription_repair_error
		return 1
	}
	geodata_recover || return 1
	from="$(uci_get subscription)"
	[ "$id" != "$from" ] || {
		printf '{"action":"unchanged"}\n'
		return 0
	}
	if [ -z "$from" ] || [ -z "$(subscription_option "$id" url)" ] || [ ! -f "$dir/config.json" ]; then
		err_code subscription_missing "This subscription is not saved on the router."
		return 1
	fi
	settings_load && ensure_dir "$XRAY_SHARE_DIR" && subscription_journal "$from" "$id" || return 1
	if ! { subscription_park "$from" && subscription_journal "$from" "$id" parked && subscription_share_from "$id" &&
		subscription_copy_settings "$id" settings defaults && subscription_restore_lists "$id" &&
		subscription_option_set "$id" used "$(date +%s)" && uci_set subscription "$id" && uci_commit && settings_load && result="$(config_install "$dir/config.json")"; }; then
		subscription_switch_abort || warn "Cannot restore the previous subscription; the next start repairs it"
		settings_load
		return 1
	fi
	subscription_switch_finish "$id" || warn "Cannot finish the subscription switch; the next start repairs it"
	# The config may be the same bytes or give the same runtime while the settings and lists are not: apply them.
	service_reload || result="$(apply_result "$result" "$(apply_partial_message)")"
	printf '%s\n' "$result" | xraywrt-json merge object --arg action switched --arg id "$id"
}

# Use <id>. If auto-update is on and the subscription's own period has passed
# since its last download, update it now; a failed update keeps the stored config.
subscription_use() {
	local id="$1" result="" updated="" action="" errfile="$PKG_TMP_DIR/subscription.$$.err"

	subscription_id_valid "$id" || {
		err "Invalid subscription id: $id"
		return 1
	}
	result="$(with_lock subscription_switch "$id")" || return 1
	action="$(printf '%s\n' "$result" | xraywrt-json get action)"
	[ "$action" != unchanged ] || {
		printf '%s\n' "$result"
		return 0
	}
	settings_load || return 1
	result="$(subscription_settled "$result")" || return 1
	with_lock subscription_dns_sync || warn "Failed to update the subscription DNS exception"
	if subscription_due; then
		ensure_dir "$PKG_TMP_DIR" || return 1
		if updated="$(subscription_update 2>"$errfile")"; then
			result="$(printf '%s\n' "$updated" | xraywrt-json merge object --arg action switched --arg id "$id")"
		else
			result="$(printf '%s\n' "$result" | xraywrt-json merge object --arg apply_status partial --argjson warnings "$({
				code_message subscription_stale 'The subscription was switched, but its update failed. The saved configuration is in use.'
				printf '\n'
				error_text "$errfile"
			} | xraywrt-json lines)")"
		fi
		rm -f "$errfile"
	fi
	printf '%s\n' "$result"
}

# Save a downloaded subscription next to the active one. Only the format is
# checked here; the core tests it when the subscription is switched to.
subscription_store() {
	local candidate="$1" meta="$2" url="$3" probe="$PKG_TMP_DIR/subscription.$$.probe" id="" dir=""

	subscription_recover || warn "Cannot repair an interrupted subscription switch; the next start tries again"
	xray_config_generate "$candidate" "$probe" >/dev/null || {
		rm -f "$probe" "$probe.profile"
		return 1
	}
	rm -f "$probe" "$probe.profile"
	id="$(subscription_new_id)" && dir="$XRAY_SUBS_DIR/$id" || return 1
	if ! { ensure_dir "$dir/share" && atomic_copy "$candidate" "$dir/config.json" && chmod 600 "$dir/config.json" &&
		{ [ -z "$meta" ] || (umask 077 && printf '%s\n' "$meta" >"$dir/subscription.json"); } &&
		uci -q set "$PKG_CONFIG.$id=subscription" && subscription_option_set "$id" url "$url" &&
		subscription_option_set "$id" updated "$(date +%s)" && uci_commit; }; then
		rm -rf "$dir"
		err "Cannot save the subscription"
		return 1
	fi
	xraywrt-json build object --arg action added --arg id "$id"
}

# Add <url>. The first subscription is a normal Connect; the others are saved
# inactive and nothing that runs changes. A saved link is not added twice.
subscription_add() {
	local url="$1" id=""

	is_http_url "$url" || {
		err_code subscription_url "Subscription URL must start with http:// or https://"
		return 1
	}
	if id="$(subscription_id_of_url "$url")"; then
		xraywrt-json build object --arg action exists --arg id "$id"
	elif [ -z "$(uci_get subscription)" ]; then
		subscription_connect "$url"
	else
		subscription_update "$url" park
	fi
}

# Delete <id>. The active one only when it is the last: the config then stays as
# a hand-written one. Caller holds the lock.
subscription_delete() {
	local id="$1" profile="" last=0

	subscription_id_valid "$id" || {
		err "Invalid subscription id: $id"
		return 1
	}
	# Delete frees space: it goes on if the repair of an old switch fails.
	subscription_recover || warn "Cannot repair an interrupted subscription switch; the next start tries again"
	if [ -z "$(subscription_option "$id" url)" ]; then
		err_code subscription_missing "This subscription is not saved on the router."
		return 1
	fi
	# The repair failed: undoing the switch still needs the parked copy of <from>.
	if [ -f "$XRAY_SUBS_DIR/.switch" ] && [ "$id" = "$(cut -d' ' -f1 "$XRAY_SUBS_DIR/.switch")" ]; then
		subscription_repair_error
		return 1
	fi
	if [ "$id" = "$(uci_get subscription)" ]; then
		# shellcheck disable=SC2046 # ids are words
		set -- $(subscription_ids)
		[ "$#" -le 1 ] || {
			err_code subscription_active "Switch to another subscription before deleting this one."
			return 1
		}
		last=1
		profile="$(subscription_option "$id" profile)"
		uci -q delete "$PKG_CONFIG.settings.subscription"
		[ -z "$profile" ] || uci_set profile "$profile"
	fi
	uci -q delete "$PKG_CONFIG.$id" && uci_commit || return 1
	[ "$last" = 0 ] || rm -f "$SUBSCRIPTION_META_FILE" "$PKG_STATE_DIR/subscription.stamp" "$(subscription_usage_file)"
	rm -rf "${XRAY_SUBS_DIR:?}/$id"
	settings_load && cron_update
	subscription_dns_sync || warn "Failed to update the subscription DNS exception"
	printf '{"action":"deleted"}\n'
}
