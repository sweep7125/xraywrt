#!/bin/ash

# bi needs an explicit tag and -json; multiple tags produce separate JSON objects.
xray_api_bi_raw() {
	"$XRAY_BIN" api bi --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_TIMEOUT" -json -- "$1"
}

xray_api_bi() {
	local result=""

	result="$(xray_api_bi_raw "$1")" || return 1
	result="$(printf '%s\n' "$result" | xraywrt-json object)" || return 1
	[ -n "$result" ] || return 1
	printf '%s\n' "$result"
}

xray_api_bo() {
	if [ -n "$2" ]; then
		"$XRAY_BIN" api bo --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_TIMEOUT" -b "$1" -- "$2"
	else
		"$XRAY_BIN" api bo --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_TIMEOUT" -b "$1" -r
	fi
}

# Caller holds the runtime lock; on any partial failure restart the candidate.
# rmo loads any argument it can open (file, stdin:, URL) as a config, so the
# removed tags go in a file of tag-only outbounds, never on argv.
xray_api_apply() {
	local old="$1" candidate="$2" added="$2.outbounds" removed="$2.removed" rc=0

	rm -f "$added" "$removed"
	xraywrt-json outbound-delta "$old" "$candidate" "$added" "$removed" || rc=1
	if [ "$rc" -eq 0 ] && [ -f "$removed" ]; then
		XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" api rmo --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_APPLY_TIMEOUT" "$removed" >/dev/null || rc=1
	fi
	if [ "$rc" -eq 0 ] && [ -f "$added" ]; then
		XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" api ado --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_APPLY_TIMEOUT" "$added" >/dev/null || rc=1
	fi
	rm -f "$added" "$removed"
	[ "$rc" -eq 0 ] || return 1
	# No -append: the CLI defaults to shouldAppend=false (rules + balancers).
	XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" api adrules --server="$XRAY_API_HOST:$XRAY_API_PORT" --timeout="$XRAY_API_APPLY_TIMEOUT" "$candidate" >/dev/null
}

# Spec 16: one bi per balancer; a failing one is marked, the rest stay
# listed, and after XRAY_API_LIST_TIMEOUT seconds the rest are skipped.
balancers_json() {
	local tags="" tag="" info="" rows="" entries="" deadline="" reason="" ifs="$IFS"

	service_running || { printf '%s\n' '{"running":false,"balancers":[],"stale":[]}'; return 0; }
	tags="$(xraywrt-json balancers tags "$RUNTIME_CONFIG")" || return 1
	entries="$(settings_balancer_overrides)" || return 1
	deadline=$(($(date +%s) + XRAY_API_LIST_TIMEOUT))
	while IFS= read -r tag; do
		[ -n "$tag" ] || continue
		reason=""
		if [ "$(date +%s)" -ge "$deadline" ]; then
			reason=timeout
		elif ! { info="$(xray_api_bi "$tag")" && info="$(printf '%s\n' "$info" | xraywrt-json balancers info "$RUNTIME_CONFIG" "$tag")"; }; then
			reason=api
		fi
		[ -z "$reason" ] || info="$(xraywrt-json balancers error "$RUNTIME_CONFIG" "$tag" "$reason")" || return 1
		rows="$rows$info
"
	done <<EOF_TAGS
$tags
EOF_TAGS
	# One saved override per line; names may contain spaces.
	set -f
	IFS='
'
	# shellcheck disable=SC2086
	set -- $entries
	IFS="$ifs"
	set +f
	printf '%s' "$rows" | xraywrt-json balancers list "$RUNTIME_CONFIG" "$@"
}

# Replace the saved override of <tag> with <target> ("" = none).
balancer_uci_set() {
	local tag="$1" target="$2" entry=""

	while IFS= read -r entry; do
		[ "${entry%%=*}" != "$tag" ] || uci -q del_list "$PKG_CONFIG.settings.balancer_override=$entry" || return 1
	done <<EOF_OVERRIDES
$3
EOF_OVERRIDES
	[ -z "$target" ] || uci -q add_list "$PKG_CONFIG.settings.balancer_override=$tag=$target" || return 1
	uci_commit
}

# Caller holds the runtime lock. An API failure never writes persistent state;
# a UCI failure reverts the staged list and the core override.
balancer_set() {
	local tag="$1" target="$2" entries="" previous=""

	service_running || { err_code not_running "Xray is not running"; return 1; }
	entries="$(settings_balancer_overrides)" || return 1
	if [ -z "$target" ] && ! xraywrt-json balancers tags "$RUNTIME_CONFIG" 2>/dev/null | grep -Fxq -- "$tag"; then
		# Spec 16: a balancer gone from the runtime only loses its saved entry.
		balancer_uci_set "$tag" "" "$entries" || {
			uci -q revert "$PKG_CONFIG.settings.balancer_override"
			err "Cannot save balancer override"
			return 1
		}
	else
		xraywrt-json balancers check "$RUNTIME_CONFIG" "$tag" "$target" || return 1
		previous="$(xray_api_bi "$tag" | xraywrt-json balancers override)" || return 1
		xray_api_bo "$tag" "$target" >/dev/null || return 1
		balancer_uci_set "$tag" "$target" "$entries" || {
			uci -q revert "$PKG_CONFIG.settings.balancer_override"
			xray_api_bo "$tag" "$previous" >/dev/null || warn "Cannot restore the override of balancer $tag"
			err "Cannot save balancer override"
			return 1
		}
	fi
	xraywrt-json build object --argjson ok true
}

# Stale tags stay in UCI; strict=1 makes a hot-apply API failure restart the core.
balancer_overrides_apply() {
	local entries="" entry="" tag="" target="" reason=""

	entries="$(settings_balancer_overrides)" || { warn "Cannot read balancer overrides"; return 0; }
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		tag="${entry%%=*}" target="${entry#*=}"
		if reason="$(xraywrt-json balancers check "$RUNTIME_CONFIG" "$tag" "$target" 2>&1)" && [ "$entry" != "$tag" ]; then
			xray_api_bo "$tag" "$target" >/dev/null 2>&1 || {
				warn "Cannot apply balancer override $entry"
				[ "${1:-0}" != 1 ] || return 1
			}
		else
			warn "Skipping balancer override $entry: $reason"
		fi
	done <<EOF_OVERRIDES
$entries
EOF_OVERRIDES
	return 0
}

# Empty targets at startup are not evidence of failure until a target was alive.
# observatory-target parses the core's answer itself: one ucode start per check.
watchdog_observatory_ok() {
	local tags="" tag="" info="" target="" live=0 unknown=0

	tags="$(profile_entries observe-balancer)"
	[ -n "$tags" ] || { rm -f "$OBSERVATORY_FILE"; return 0; }
	while IFS= read -r tag; do
		if info="$(xray_api_bi_raw "$tag" 2>/dev/null)" && target="$(printf '%s\n' "$info" | xraywrt-json observatory-target 2>/dev/null)"; then
			[ "$target" != live ] || live=1
		else
			unknown=1
		fi
	done <<EOF_TAGS
$tags
EOF_TAGS
	if [ "$live" -eq 1 ]; then
		[ -f "$OBSERVATORY_FILE" ] || atomic_write "$OBSERVATORY_FILE" live
		return 0
	fi
	[ "$unknown" -eq 1 ] || [ ! -f "$OBSERVATORY_FILE" ]
}
