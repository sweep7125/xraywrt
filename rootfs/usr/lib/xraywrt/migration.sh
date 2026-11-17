#!/bin/ash

# Upgrade steps for installed packages. Every step is idempotent.

migrate_settings() {
	# Traffic flags are saved with rmempty=false: write the defaults now, so the
	# first Save & Apply without edits changes no UCI option.
	[ -n "$(uci_get dns_hijack)" ] || uci_set dns_hijack 1
	[ -n "$(uci_get disable_quic)" ] || uci_set disable_quic 1
	[ -n "$(uci_get netbird_proxy)" ] || uci_set netbird_proxy 0
	[ -n "$(uci_get bypass_ntp)" ] || uci_set bypass_ntp 1
	[ -n "$(uci_get bypass_subscription_dns)" ] || uci_set bypass_subscription_dns 1
	[ -n "$(uci_get lists_interval)" ] || uci_set lists_interval 0
	[ -n "$(uci_get core_log_level)" ] || uci_set core_log_level warning
	[ -n "$(uci_get geodata_cron)" ] || uci_set geodata_cron '0 5 * * *'
	# Spec 13: new XrayWRT options; DNS upstreams stay empty (WAN DNS).
	[ -n "$(uci_get mode)" ] || uci_set mode proxy-first
	[ -n "$(uci_get dns_forward_other_types)" ] || uci_set dns_forward_other_types 0
	# Spec 13: no core auto-update; the hourly tick no longer checks the core.
	# Spec 7.5: other DNS types are no longer refused, only forwarded on request.
	# HTTPS records of VPN sites are never forwarded, so the block option is gone.
	for opt in core_auto_update dns_refuse_other_types dns_block_https_rr; do
		[ -z "$(uci_get "$opt")" ] || uci -q delete "$PKG_CONFIG.settings.$opt"
	done
	if [ "$(uci_get mode)" = direct-first ]; then
		case " $(uci_get provider_override) " in
		*" mode "*) ;;
		*) uci add_list "$PKG_CONFIG.settings.provider_override=mode" ;;
		esac
	fi
	# balancer_override has no defaults; preserve every saved list item (spec 16).
	migrate_subscription || return 1
	migrate_rules || return 1
	uci_commit
}

# The saved link and server of earlier versions become the first, active
# subscription. Nothing is downloaded and nothing restarts: the files stay as they are.
migrate_subscription() {
	local url="" id="" profile=""

	url="$(uci_get subscription_url)"
	if [ -n "$url" ] && [ -z "$(uci_get subscription)" ]; then
		id="$(subscription_new_id)" || return 1
		profile="$(uci_get profile)"
		uci -q set "$PKG_CONFIG.$id=subscription" && subscription_option_set "$id" url "$url" || return 1
		[ -z "$profile" ] || subscription_option_set "$id" profile "$profile"
		uci_set subscription "$id"
		uci -q delete "$PKG_CONFIG.settings.profile"
	fi
	uci -q delete "$PKG_CONFIG.settings.subscription_url"
	return 0
}

# One ordered list, My rules, replaces the four lists of sites and addresses.
# $1 is the directory of the old files, $2 and $3 name the file of the old
# address lists, $4 and $5 those of the old site lists, $6 the new file (it
# keeps what it has). The old "always direct" entries become `<entry> direct`
# and come first; old "via VPN" addresses become `<entry> core` (what they did
# before); old "via VPN" sites and address entries with ports have no known
# target and stay as comments. Returns 0 without writing when there is nothing
# to move; the old files are emptied once the new one is in place.
migrate_rules_dir() {
	local dir="$1" dst="$2" direct="$3" fake="$4" direct_domains="$5" rules="$6" tmp="" notes="" file="" moved=0

	for file in "$dir/$dst" "$dir/$direct" "$dir/$fake" "$dir/$direct_domains"; do
		[ ! -s "$file" ] || [ -z "$(lists_clean_lines "$file")" ] || moved=1
	done
	[ "$moved" -eq 1 ] || return 0
	ensure_dir "$PKG_TMP_DIR" || return 1
	tmp="$PKG_TMP_DIR/rules.$$"
	rm -f "$tmp.notes"
	{
		# Plain entries with a target; entries that cannot be expressed to $notes.
		{ lists_clean_lines "$dir/$direct_domains" 2>/dev/null; lists_clean_lines "$dir/$direct" 2>/dev/null; } | awk -v notes="$tmp.notes" '
			index($0, ";") { print "# " $0 >>notes; next }
			{ print $0 " direct" }'
		lists_clean_lines "$dir/$dst" 2>/dev/null | awk -v notes="$tmp.notes" '
			index($0, ";") { print "# " $0 >>notes; next }
			{ print $0 " core" }'
		lists_clean_lines "$dir/$fake" 2>/dev/null | sed 's/^/# /' >>"$tmp.notes"
		if [ -s "$tmp.notes" ]; then
			printf '%s\n' '# Add a target (direct, core or a server tag) to each line below and remove the leading # to use it. Ports (;443) are no longer supported.'
			cat "$tmp.notes"
		fi
	} >"$tmp.new" || { rm -f "$tmp.new" "$tmp.notes"; return 1; }
	rm -f "$tmp.notes"
	# A cut before the old files were emptied leaves this text at the top already.
	if [ ! -f "$rules" ] || ! head -c "$(wc -c <"$tmp.new" | tr -d ' ')" "$rules" | cmp -s - "$tmp.new"; then
		{ cat "$tmp.new"; [ ! -f "$rules" ] || cat "$rules"; } >"$tmp" || { rm -f "$tmp" "$tmp.new"; return 1; }
		atomic_copy "$tmp" "$rules" || { rm -f "$tmp" "$tmp.new"; return 1; }
	fi
	rm -f "$tmp" "$tmp.new"
	for file in "$dir/$dst" "$dir/$direct"; do
		[ ! -s "$file" ] || : >"$file" || return 1
	done
	rm -f "$dir/$fake" "$dir/$direct_domains"
}

migrate_rules() {
	local id="" opt=""

	# The old files stay in the package as empty files; the active
	# subscription keeps them in LIST_DIR, a parked one in its directory.
	migrate_rules_dir "$LIST_DIR" always_proxy_dst.txt direct_dst.txt fake_domains.txt direct_domains.txt "$RULES_FILE" || return 1
	for id in $(subscription_ids); do
		migrate_rules_dir "$XRAY_SUBS_DIR/$id/lists" dst.txt direct.txt fake.txt direct-domains.txt "$XRAY_SUBS_DIR/$id/lists/rules.txt" || return 1
		for opt in fake_domains_source dst_list_source direct_list_source; do
			uci -q delete "$PKG_CONFIG.$id.$opt"
		done
	done
	for opt in fake_domains_source dst_list_source direct_list_source; do
		uci -q delete "$PKG_CONFIG.settings.$opt"
	done
	return 0
}

migrate() {
	migrate_settings || return 1
	# Rebuilt by the next settings_load through the provider URL filter.
	rm -f "$PROFILE_FILE"
	settings_ensure_generated
}
