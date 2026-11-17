#!/bin/ash

# Policy lists: one entry per line, IPv4, IPv6 or MAC (device lists only).
#   addr[/prefix][;ports]   e.g. 1.1.1.1, 2001:db8::/32;443
#   ;ports                  any address on these ports
#   URL[;ports]             remote list (cached)
# Remote URLs are fetched by lists_update_remote and read from the cache, so
# applying policy never waits on the network. The provider may ship dst and
# direct lists (xraywrt proxy-ips/direct-ips); they are always used as they
# are. The user's own sites and addresses are one ordered list, My rules
# ($RULES_FILE): `<what> <target>` per line, read by xraywrt-json rules. Its
# addresses join the provider lists here: direct ones bypass, the rest go to
# the core. Device lists are plain files.

LISTS_REMOTE_MAX_BYTES="${LISTS_REMOTE_MAX_BYTES:-1048576}"
LISTS_OWN_MAX_BYTES=1048576
LISTS_REMOTE_MAX_URLS="${LISTS_REMOTE_MAX_URLS:-32}"
LISTS_REMOTE_TIMEOUT="${LISTS_REMOTE_TIMEOUT:-30}"

lists_file() {
	case "$1" in
	rules) printf '%s' "$RULES_FILE" ;;
	src) printf '%s' "$SRC_LIST_FILE" ;;
	direct_src) printf '%s' "$DIRECT_SRC_LIST_FILE" ;;
	*) return 1 ;;
	esac
}

# True when the provider ships this list (key present, even if empty).
lists_provided() {
	case "$1" in
	dst) profile_has proxy-ips ;;
	direct) profile_has direct-ips ;;
	*) return 1 ;;
	esac
}

# Provider URLs may point only to public HTTPS hosts. DNS resolution is not
# checked here; this policy excludes local/reserved literals, not DNS rebinding.
lists_provider_url_ok() {
	local url="$1" host=""

	case "$url" in https://?*) ;; *) return 1 ;; esac
	is_http_url "$url" || return 1
	host="$(url_host "${url%%#*}" | tr '[:upper:]' '[:lower:]')"
	case "$host" in '' | localhost | localhost. | *%*) return 1 ;; esac
	# curl accepts shortened, integer, hex and octal IPv4. Numeric hosts must
	# instead be canonical decimal dotted quads before the public-range check.
	printf '%s\n' "$host" | awk -F. '
		{
			n = NF; if ($n == "") n--
			for (i = 1; i <= n; i++)
				if ($i !~ /^[0-9]+$/ && $i !~ /^0x[0-9a-f]+$/) exit 0
			if (NF != 4 || n != 4) exit 1
			for (i = 1; i <= n; i++)
				if ($i !~ /^(0|[1-9][0-9]*)$/ || $i + 0 > 255) exit 1
		}
	' || return 1
	if is_ipv4 "$host"; then
		printf '%s\n' "$host" | awk -F. '
			{ exit ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224 ||
				($1 == 100 && $2 >= 64 && $2 <= 127) ||
				($1 == 169 && $2 == 254) ||
				($1 == 172 && $2 >= 16 && $2 <= 31) ||
				($1 == 192 && (($2 == 0 && ($3 == 0 || $3 == 2)) ||
					($2 == 88 && $3 == 99) || $2 == 168)) ||
				($1 == 198 && ($2 == 18 || $2 == 19 || ($2 == 51 && $3 == 100))) ||
				($1 == 203 && $2 == 0 && $3 == 113)) ? 1 : 0 }
		'
	elif is_ipv6 "$host"; then
		# Expand :: to reject mapped/compat IPv4 regardless of spelling.
		printf '%s\n' "$host" | awk '
			function group(s) { sub(/^0+/, "", s); return s == "" ? "0" : s }
			{
				dbl = index($0, "::")
				if (dbl) {
					left = substr($0, 1, dbl - 1); right = substr($0, dbl + 2)
					nl = left == "" ? 0 : split(left, l, ":")
					nr = right == "" ? 0 : split(right, r, ":")
					for (i = 1; i <= 8; i++)
						a[i] = i <= nl ? l[i] : (i > 8 - nr ? r[i - (8 - nr)] : "0")
				} else split($0, a, ":")
				zero = 1
				for (i = 1; i <= 5; i++) if (group(a[i]) != "0") zero = 0
				if (zero && (group(a[6]) == "0" || group(a[6]) == "ffff")) exit 1
				first = group(a[1])
				if (first ~ /^f[cd][0-9a-f][0-9a-f]$/ ||
					first ~ /^fe[89a-f][0-9a-f]$/ || first ~ /^ff[0-9a-f][0-9a-f]$/) exit 1
				if (first == "64" && group(a[2]) == "ff9b") {
					zero = 1
					for (i = 3; i <= 6; i++) if (group(a[i]) != "0") zero = 0
					if (zero) exit 1
				}
			}
		'
	else
		# A colon-bearing host that is not a valid IPv6 literal is not public.
		case "$host" in *:*) return 1 ;; esac
	fi
}

# lists_profile_filter <profile>: drop provider list URLs the policy rejects.
# Runs once per config build, so readers of the profile never re-check them.
lists_profile_filter() {
	local profile="$1" line="" url=""

	[ -f "$profile" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"proxy-ip "*://* | "direct-ip "*://*)
			url="$(printf '%s\n' "${line#* }" | lists_clean_lines)"
			url="${url%%;*}"
			lists_provider_url_ok "$url" || {
				warn "xraywrt: ignored list URL $url (only public https URLs)"
				continue
			}
			;;
		esac
		printf '%s\n' "$line"
	done <"$profile" >"$profile.tmp" || {
		rm -f "$profile.tmp"
		return 1
	}
	mv -f "$profile.tmp" "$profile"
}

lists_provider_entries() {
	case "$1" in
	dst) profile_entries proxy-ip | lists_clean_lines ;;
	direct) profile_entries direct-ip | lists_clean_lines ;;
	esac
	return 0
}

# Target tags of the configuration, as the generator recorded them.
lists_rule_targets() {
	profile_entries rules-target
}

# Addresses and list links of My rules whose target is direct, or all others
# (core and tags). Lines whose target is not in the configuration are skipped,
# as in the generator.
lists_rules_entries() {
	[ -r "$RULES_FILE" ] || return 0
	lists_rule_targets | xraywrt-json rules entries "$RULES_FILE" "$1"
}

# Every list link of My rules, whatever its target.
lists_rules_urls() {
	[ -r "$RULES_FILE" ] || return 0
	xraywrt-json rules urls "$RULES_FILE"
}

# Where the generator finds the cache of each link of My rules.
lists_rules_remote_json() {
	local url=""

	lists_rules_urls | while IFS= read -r url; do
		printf '%s\t%s\n' "$url" "$(lists_cache_file "$url")"
	done | xraywrt-json pairs
}

# The generator output depends on the fetched lists that feed routing rules.
lists_rules_remote_hashes() {
	local url="" cache=""

	lists_rules_urls | while IFS= read -r url; do
		cache="$(lists_cache_file "$url")"
		[ ! -f "$cache" ] || sha256sum <"$cache"
	done
}

# Cleaned entries that apply for one kind. Provider lists are always used; the
# direct one only in proxy-first, where it is the whole policy.
lists_source() {
	local kind="$1" file=""

	case "$kind" in
	dst)
		lists_provider_entries dst
		lists_rules_entries proxy
		;;
	direct)
		[ "${POLICY_MODE:-}" != proxy-first ] || lists_provider_entries direct
		lists_rules_entries direct
		;;
	src | direct_src)
		file="$(lists_file "$kind")"
		[ ! -r "$file" ] || lists_clean_lines "$file"
		;;
	*) return 1 ;;
	esac
	return 0
}

lists_ensure_files() {
	local kind=""

	ensure_dir "$LIST_DIR" || return 1
	for kind in rules src direct_src; do
		[ -f "$(lists_file "$kind")" ] || : >"$(lists_file "$kind")"
	done
}

# One awk pass validates and classifies entries (a fork per entry is far too
# slow on router CPUs). Prints "<family> <entry>", family 4, 6, mac or any; with
# bad=1 prints only invalid lines. Optional output paths instead receive each
# family and diagnostics (total count, then at most 20 invalid-line samples).
lists_classify() {
	awk -v bad="${1:-0}" -v kind="${2:-}" \
		-v o4="${3:-}" -v o6="${4:-}" -v omac="${5:-}" -v diag="${6:-}" '
		function port_ok(p) { return p ~ /^[0-9]+$/ && p + 0 >= 1 && p + 0 <= 65535 }
		function ports_ok(s,   n, i, a, r) {
			if (s == "" || s ~ /^,|,$|,,/) return 0
			n = split(s, a, ",")
			for (i = 1; i <= n; i++) {
				if (split(a[i], r, "-") == 2) {
					if (!port_ok(r[1]) || !port_ok(r[2]) || r[1] + 0 > r[2] + 0) return 0
				} else if (!port_ok(a[i])) return 0
			}
			return 1
		}
		function prefix_ok(p, max) { return p ~ /^[0-9]+$/ && p + 0 <= max }
		# Canonical decimals: nft reads leading zeros as octal or a hostname.
		function nprefix(s) { return index(s, "/") ? substr(s, 1, index(s, "/") - 1) "/" (substr(s, index(s, "/") + 1) + 0) : s }
		function nv4(s,   a) { s = nprefix(s); split(s, a, "[./]"); return (a[1] + 0) "." (a[2] + 0) "." (a[3] + 0) "." (a[4] + 0) (index(s, "/") ? "/" a[5] : "") }
		function nports(s,   n, i, a, r, out) {
			n = split(s, a, ",")
			for (i = 1; i <= n; i++)
				out = out (i > 1 ? "," : "") (split(a[i], r, "-") == 2 ? (r[1] + 0) "-" (r[2] + 0) : a[i] + 0)
			return out
		}
		function v4(s,   n, i, a) {
			if (index(s, "/")) { if (!prefix_ok(substr(s, index(s, "/") + 1), 32)) return 0; s = substr(s, 1, index(s, "/") - 1) }
			if (split(s, a, ".") != 4) return 0
			for (i = 1; i <= 4; i++) if (a[i] !~ /^[0-9][0-9]?[0-9]?$/ || a[i] + 0 > 255) return 0
			return 1
		}
		function mac(s,   i, a) {
			if (split(tolower(s), a, ":") != 6) return 0
			for (i = 1; i <= 6; i++) if (a[i] !~ /^[0-9a-f][0-9a-f]$/) return 0
			return 1
		}
		function v6(s,   n, i, a, g, dbl) {
			if (index(s, "/")) { if (!prefix_ok(substr(s, index(s, "/") + 1), 128)) return 0; s = substr(s, 1, index(s, "/") - 1) }
			if (s !~ /:/ || s ~ /[^0-9A-Fa-f:]/ || s ~ /:::/) return 0
			dbl = gsub(/::/, "&", s)
			if (dbl > 1) return 0
			if (s ~ /^:[^:]/ || s ~ /[^:]:$/) return 0
			n = split(s, a, ":"); g = 0
			for (i = 1; i <= n; i++) if (a[i] != "") { if (length(a[i]) > 4) return 0; g++ }
			return dbl ? g <= 7 : g == 8
		}
		$0 == "https://" { remote = 1; next }
		{
			addr = $0; ports = ""
			if (index($0, ";")) { addr = substr($0, 1, index($0, ";") - 1); ports = substr($0, index($0, ";") + 1) }
			fam = ""
			if (index($0, ";") && !ports_ok(ports)) fam = ""
			else if (addr == "") fam = (ports != "") ? "any" : ""
			else if (v4(addr)) fam = "4"
			else if (v6(addr)) fam = "6"
			else if (!index($0, ";") && mac(addr) && kind != "dst" && kind != "direct") { fam = "mac"; $0 = tolower($0) }
			if (fam == "") {
				if (diag != "" && !remote) { invalid++; if (invalid <= 20) samples[invalid] = $0 }
				if (bad) print
				next
			}
			if (bad) next
			if (fam != "mac") {
				if (fam == "4") addr = nv4(addr)
				else if (fam == "6") addr = nprefix(addr)
				$0 = addr (index($0, ";") ? ";" nports(ports) : "")
			}
			if (o4 == "") { print fam " " $0; next }
			if (fam == "4" || fam == "any") print >o4
			if (fam == "6" || fam == "any") print >o6
			if (fam == "mac" && omac != "") print >omac
		}
		END {
			if (diag != "") {
				print invalid + 0 >diag
				for (i = 1; i <= invalid && i <= 20; i++) print samples[i] >diag
			}
		}
	'
}

# Strip comments and whitespace.
lists_clean_lines() {
	sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$@"
}

lists_url_key() {
	printf '%s' "$1" | sha256sum | cut -c1-16
}

lists_cache_file() {
	printf '%s/%s.txt' "$POLICY_CACHE_DIR" "$(lists_url_key "$1")"
}

lists_urls() {
	local kind=""

	{
		for kind in dst src direct direct_src; do
			lists_source "$kind"
		done
		lists_rules_urls
	} | sed -n 's/;.*//; /^https\?:\/\//p' | awk '!seen[$0]++'
}

# Retain caches for every current URL, including those beyond the fetch cap.
lists_cache_gc() {
	local keys="" cache="" url=""

	[ -r "$XRAY_CONFIG" ] && ! profile_ensure && return 0
	keys="$(printf '%s\n' "${1-$(lists_urls)}" | while IFS= read -r url; do lists_url_key "$url"; echo; done)"
	for cache in "$POLICY_CACHE_DIR"/*.txt; do
		[ -f "$cache" ] || continue
		printf '%s\n' "$keys" | grep -Fxq "$(basename "$cache" .txt)" || rm -f "$cache" "$(lists_stamp_file "$cache")"
	done
}

# File arguments preserve UTF-8, escaping and trailing newlines without shell
# argument-size limits; a missing file has the same contents as /dev/null.
lists_json() {
	local kind="" file=""

	set --
	for kind in rules src direct_src; do
		file="$(lists_file "$kind")" || return 1
		[ -f "$file" ] || file=/dev/null
		set -- "$@" --rawfile "$kind" "$file"
	done
	xraywrt-json build object "$@"
}

# Optional fourth argument receives device MACs, separately from IP families.
lists_resolve() {
	local kind="$1" out4="$2" out6="$3" outmac="${4:-}" src="" line="" url="" ports="" cache="" bad="" bad_count=0

	src="$PKG_TMP_DIR/list.$kind.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	lists_source "$kind" >"$src" || return 1
	if ! { : >"$out4" && : >"$out6" && { [ -z "$outmac" ] || : >"$outmac"; }; }; then
		rm -f "$src"
		return 1
	fi
	{
		grep -v '^https\?://' "$src" || true
		# Bare "https://" cannot be a local line here: it ends the diagnosed part.
		printf '%s\n' 'https://'
		# Remote entries inherit the URL's ports unless they carry their own.
		sed -n '/^https\?:\/\//p' "$src" | while IFS= read -r line; do
			url="${line%%;*}"
			ports=""
			[ "$url" = "$line" ] || ports="${line#*;}"
			cache="$(lists_cache_file "$url")"
			[ -r "$cache" ] || continue
			awk -v p="$ports" 'p != "" && !index($0, ";") { $0 = $0 ";" p } { print }' "$cache"
		done
	} | lists_classify 0 "$kind" "$out4" "$out6" "$outmac" "$src.bad" || {
		rm -f "$src" "$src.bad"
		return 1
	}
	{
		IFS= read -r bad_count
		while IFS= read -r line; do bad="$bad$line "; done
	} <"$src.bad"
	if [ "$bad_count" -gt 0 ]; then
		[ "$bad_count" -le 20 ] || bad="$bad($bad_count total; first 20 shown)"
		warn "Ignoring invalid $kind entries: $bad"
	fi
	rm -f "$src" "$src.bad"
	# BusyBox sort on OpenWrt has no -o.
	sort -u "$out4" >"$out4.sorted" && mv -f "$out4.sorted" "$out4" &&
		sort -u "$out6" >"$out6.sorted" && mv -f "$out6.sorted" "$out6" || return 1
	if [ -n "$outmac" ]; then
		sort -u "$outmac" >"$outmac.sorted" && mv -f "$outmac.sorted" "$outmac" || return 1
	fi
	return 0
}

# Check times are kept in tmpfs so an unchanged list never writes to flash.
# The stamp is named like its cache; after a reboot the cache mtime decides.
lists_stamp_file() {
	local key="${1##*/}"

	printf '%s/lists-stamp/%s' "$PKG_STATE_DIR" "${key%.txt}"
}

# True when the cache for a URL is missing or its last check is older than
# LISTS_INTERVAL hours.
lists_remote_due() {
	local cache="$1" checked=""

	[ -f "$cache" ] || return 0
	[ "${LISTS_INTERVAL:-0}" -gt 0 ] || return 1
	checked="$(lists_stamp_file "$cache")"
	[ -f "$checked" ] || checked="$cache"
	[ -n "$(find "$checked" -mmin +$((LISTS_INTERVAL * 60 - 5)) 2>/dev/null)" ]
}

# Fetch due remote lists into the cache. Prints "changed" or "unchanged".
lists_update_remote() {
	local force="${1:-0}" urls="${2-$(lists_urls)}" url="" cache="" tmp="" line="" count=0 changed=0 failed=0 first_error=""
	local total="" next_total=""

	ensure_dir "$POLICY_CACHE_DIR" && ensure_dir "$PKG_STATE_DIR/lists-stamp" || return 1
	lists_cache_gc "$urls" || return 1
	tmp="$PKG_TMP_DIR/list.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	# URLs come from providers too: no pathname expansion.
	set -f
	for url in $urls; do
		[ "$count" -lt "$LISTS_REMOTE_MAX_URLS" ] || {
			warn "Too many remote lists; only $LISTS_REMOTE_MAX_URLS are used"
			break
		}
		count=$((count + 1))
		cache="$(lists_cache_file "$url")"
		[ "$force" = "1" ] || lists_remote_due "$cache" || continue
		if ! http_fetch "$url" "$tmp" "$LISTS_REMOTE_MAX_BYTES" "$LISTS_REMOTE_TIMEOUT" 0; then
			line="Remote list fetch failed: $(url_host "$url") ($FETCH_ERROR)"
			warn "$line"
			[ -n "$first_error" ] || first_error="$line"
			failed=$((failed + 1))
			continue
		fi
		lists_clean_lines "$tmp" | lists_classify | cut -d' ' -f2- >"$tmp.clean"
		# An error page or empty body must not wipe a working list.
		if [ ! -s "$tmp.clean" ] && [ -s "$cache" ]; then
			line="Remote list has no valid entries, previous copy kept: $(url_host "$url")"
			warn "$line"
			[ -n "$first_error" ] || first_error="$line"
			failed=$((failed + 1))
			continue
		fi
		if cmp -s "$tmp.clean" "$cache"; then
			: >"$(lists_stamp_file "$cache")"
		else
			# Count once, only when a fetch would change a cache. Failed writes
			# do not consume space; replacing a cache releases its old bytes.
			if [ -z "$total" ]; then
				# Globbing is off for provider URLs; re-enable it only in this subshell.
				# (OpenWrt BusyBox may lack find -exec {} +.)
				total="$(set +f; { cat "$POLICY_CACHE_DIR"/*.txt 2>/dev/null || true; } | wc -c)"
				total="${total##* }"
			fi
			if ! next_total="$({ wc -c "$tmp.clean" "$cache" 2>/dev/null || true; } | awk -v total="$total" -v max="$LISTS_CACHE_MAX_TOTAL" '
				NR == 1 { size = $1 }
				NR == 2 && $2 != "total" { old = $1 }
				END { n = total + size - old; if (n > max) exit 1; printf "%.0f", n }
			')"; then
				line="$(code_message lists_large "Remote lists exceed 8 MiB in total")"
				warn "$line"
				[ -n "$first_error" ] || first_error="$line"
				failed=$((failed + 1))
				continue
			fi
			if atomic_copy "$tmp.clean" "$cache"; then
				total="$next_total"
				changed=1
				: >"$(lists_stamp_file "$cache")"
			else
				line="Remote list cache write failed: $(url_host "$url")"
				warn "$line"
				[ -n "$first_error" ] || first_error="$line"
				failed=$((failed + 1))
			fi
		fi
	done
	set +f
	rm -f "$tmp" "$tmp.clean"
	if [ "$changed" -eq 1 ]; then
		echo changed
	else
		echo unchanged
	fi
	if [ "$failed" -gt 0 ]; then
		err_code lists_update "Failed to update %s of %s remote lists: %s" "$failed" "$count" "${first_error% \[E:*}"
		return 1
	fi
	return 0
}

# Entries that apply (provider and/or own, per the list source).
lists_count() {
	lists_source "$1" | wc -l | tr -d ' '
}

# The coded error for the first bad line of My rules (xraywrt-json rules check
# lines: number, code, target, text), naming the valid targets.
lists_rules_error() {
	local line="" code="" target="" text="" tags=""

	IFS="$(printf '\t')" read -r line code target text
	tags="direct, core$(lists_rule_targets | head -n 20 | sed 's/^/, /' | tr -d '\n')"
	[ "$(lists_rule_targets | wc -l)" -le 20 ] || tags="$tags, ..."
	text="$(printf '%s' "$text" | cut -c1-90)"
	case "$code" in
	limit) err_code rules_too_many "My rules has more than %s sites." "$RULES_SITES_LIMIT" ;;
	no_target) err_code rules_no_target "Line %s of My rules (%s) has no target. Add a space and one of: %s." "$line" "$text" "$tags" ;;
	unknown_target) err_code rules_unknown_target "Line %s of My rules (%s): there is no target \"%s\". Use one of: %s." "$line" "$text" "$target" "$tags" ;;
	*) err_code rules_bad_entry "Line %s of My rules (%s) is not a site, an IP address, a subnet or a list link followed by a target." "$line" "$text" ;;
	esac
}

# Install edited lists uploaded by LuCI (/tmp/xraywrt-policy-list.*) after
# validating every line. Runs under the runtime lock; prints 1 if changed.
# Arguments in order of lists_kinds_all: My rules, devices via VPN, devices direct.
lists_install() {
	local kind="" tmp="" bad="" changed=0 dst="" size="" failed=0 kinds="rules src direct_src"

	for kind in $kinds; do
		tmp="$1"
		shift
		eval "LIST_TMP_$kind=\"\$tmp\""
		[ "$tmp" != - ] || continue
		upload_path_allowed /tmp/xraywrt-policy-list. "$tmp" || {
			err "List path not allowed: $tmp"
			return 1
		}
		size="$(wc -c <"$tmp" | tr -d ' ')"
		[ "$size" -le "$LISTS_OWN_MAX_BYTES" ] || {
			err_code list_large "List %s is larger than 1 MiB." "$kind"
			return 1
		}
		if [ "$kind" = rules ]; then
			# Targets come from the installed configuration's profile, built with the saved settings.
			settings_load >/dev/null 2>&1 || :
			profile_ensure 2>/dev/null || :
			bad="$(lists_rule_targets | xraywrt-json rules check "$tmp")" || {
				err "My rules could not be checked"
				return 1
			}
			[ -z "$bad" ] || {
				printf '%s\n' "$bad" | head -n 1 | lists_rules_error
				return 1
			}
			continue
		fi
		# Samples appear twice in coded errors; keep stderr below 4096 bytes.
		bad="$(
			lists_clean_lines "$tmp" | lists_classify 1 "$kind" |
				LC_ALL=C awk 'NR <= 20 { printf "%s ", substr($0, 1, 90) } END { if (NR) printf "(%d total)", NR }'
		)"
		[ -z "$bad" ] || {
			err_code list_invalid "Invalid %s entries: %s" "$kind" "$bad"
			return 1
		}
	done
	for kind in $kinds; do
		rm -f "$(lists_file "$kind").new."*
	done
	for kind in $kinds; do
		eval "tmp=\"\$LIST_TMP_$kind\""
		[ "$tmp" != - ] || continue
		dst="$(lists_file "$kind")"
		case "$kind" in
		src | direct_src)
			# Only MAC lines are case-normalized; preserve comments and IP text.
			if ! { awk '
				{
					entry = $0; sub(/#.*/, "", entry); gsub(/[[:space:]]/, "", entry)
					if (split(entry, a, ":") == 6) {
						valid = 1
						for (i = 1; i <= 6; i++) if (a[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) valid = 0
						if (valid) {
							comment = index($0, "#")
							$0 = comment ? tolower(substr($0, 1, comment - 1)) substr($0, comment) : tolower($0)
						}
					}
					print
				}
			' "$tmp" >"$tmp.normalized" && mv -f "$tmp.normalized" "$tmp"; }; then
				rm -f "$tmp.normalized"
				failed=1
				break
			fi
			;;
		esac
		if ! cmp -s "$tmp" "$dst"; then
			cp "$tmp" "$dst.new.$$" || { failed=1; break; }
			changed=1
		fi
	done
	if [ "$failed" -eq 0 ]; then
		for kind in $kinds; do
			dst="$(lists_file "$kind")"
			[ -f "$dst.new.$$" ] || continue
			mv -f "$dst.new.$$" "$dst" || { failed=1; break; }
		done
	fi
	for kind in $kinds; do
		rm -f "$(lists_file "$kind").new.$$"
	done
	[ "$failed" -eq 0 ] || return 1
	settings_load && cron_update
	echo "$changed"
}

# Fetched lists changed: a list that feeds a routing rule needs the config
# rebuilt, any other only the firewall. Called under the runtime lock.
lists_policy_apply() {
	if [ -r "$RULES_FILE" ] && [ -n "$(lists_rule_targets | xraywrt-json rules routed-urls "$RULES_FILE")" ]; then
		service_reload
	else
		nft_apply_if_ready
	fi
}

# apply-lists: install under the lock, fetch new remote URLs without it,
# then rebuild nft (and the config, when My rules changed) under the lock.
lists_apply() {
	local changed="" rc=0 tmp="" warning="" rules="${1:--}"

	# My rules change the generated config, not only nft.
	if [ "$rules" != - ] && [ -f "$rules" ] && cmp -s "$rules" "$RULES_FILE"; then
		rules=-
	fi
	changed="$(with_lock lists_install "$@")" || rc=1
	for tmp in "$@"; do
		[ "$tmp" = - ] || ! upload_path_allowed /tmp/xraywrt-policy-list. "$tmp" || rm -f "$tmp"
	done
	[ "$rc" -eq 0 ] || return 1
	if service_ready || { service_running && [ -f "$DEGRADED_FILE" ]; }; then
		if settings_load; then
			lists_update_remote 0 >/dev/null || warning="$(code_message apply_lists 'Lists were saved, but some remote lists could not be fetched. Retry Update remote lists.')"
			if [ "$rules" != - ]; then
				with_lock service_reload || rc=1
			elif service_ready; then
				with_lock nft_apply_if_ready || rc=1
			fi
		else
			rc=1
		fi
	fi
	[ "$rc" -eq 0 ] || warning="$(apply_partial_message)"
	if [ -z "$warning" ] && grep -q '\[E:apply_lists' "$APPLY_WARNING_FILE" 2>/dev/null; then
		rm -f "$APPLY_WARNING_FILE"
	fi
	apply_result "$(xraywrt-json build changed --arg c "$changed")" "$warning"
}

lists_refresh() {
	local result="" rc=0 warning=""

	settings_load || return 1
	result="$(lists_update_remote 1)" || rc=1
	if [ "$result" = changed ]; then
		if service_ready; then
			with_lock lists_policy_apply || warning="$(apply_partial_message)"
		fi
		[ "$rc" -eq 0 ] || [ -n "$warning" ] || warning="$(code_message apply_lists 'Lists were saved, but some remote lists could not be fetched. Retry Update remote lists.')"
	else
		[ "$rc" -eq 0 ] || return 1
	fi
	if [ -z "$warning" ] && grep -q '\[E:apply_lists' "$APPLY_WARNING_FILE" 2>/dev/null; then
		rm -f "$APPLY_WARNING_FILE"
	fi
	apply_result "$(xraywrt-json build changed --arg r "$result")" "$warning"
}
