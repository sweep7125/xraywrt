#!/bin/ash

# Service lifecycle: runtime directories, policy apply/cleanup, the procd payload with its
# DNS watchdog, reload and scheduled updates.

# Private runtime directories; nothing in the core directory is moved or linked.
runtime_dirs_init() {
	ensure_dir "$PKG_TMP_DIR" && ensure_dir "$PKG_STATE_DIR" || return 1
	chmod 700 "$PKG_STATE_DIR" "$PKG_TMP_DIR" || return 1
	lists_ensure_files
}

apply_partial_message() {
	code_message apply_partial 'Settings were accepted, but routing could not be applied. Restart XrayWRT to retry; review the system log if it fails again.'
}

# Extend accepted-operation results without changing their legacy action/changed fields.
apply_result() {
	local result="$1" warning="${2:-}" status=applied apply_pending="" warnings='[]'

	if [ -n "$warning" ]; then
		ensure_dir "$PKG_STATE_DIR" && atomic_write "$APPLY_WARNING_FILE" "$warning" || return 1
		status=partial
		warnings="$(printf '%s\n' "$warning" | xraywrt-json lines)" || return 1
	elif ! service_ready; then
		status=saved
		if service_running; then
			if [ -f "$DEGRADED_FILE" ]; then apply_pending=degraded; else apply_pending=starting; fi
		else
			apply_pending=stopped
		fi
	fi
	set -- --arg apply_status "$status" --argjson warnings "$warnings"
	[ -z "$apply_pending" ] || set -- "$@" --arg pending_reason "$apply_pending"
	printf '%s\n' "$result" | xraywrt-json merge object "$@"
}

policy_apply() {
	settings_require || return 1

	# A failed atomic nft transaction leaves the previous live policy intact.
	nft_apply || return 1
	if route_setup && dns_apply; then
		rm -f "$APPLY_WARNING_FILE"
		log "Policy applied ($POLICY_MODE)"
		return 0
	fi
	policy_cleanup
	return 1
}

# run_service is long-lived: reload settings, a cron update or a UCI change
# may have switched mode, DNS or lists since it started.
policy_reapply() {
	settings_load && policy_apply
}

policy_reapply_ready() {
	policy_reapply && echo "$$" >"$RUNNING_MARKER"
}

service_ready_apply() {
	balancer_overrides_apply
	policy_reapply_ready
}

policy_cleanup() {
	dns_cleanup
	nft_cleanup
	route_cleanup
	return 0
}

service_pid() {
	local pid=""

	pid="$(cat "$SERVICE_PID_FILE" 2>/dev/null)" || return 1
	is_uint "$pid" && kill -0 "$pid" 2>/dev/null || return 1
	grep -q "$XRAY_BIN" "/proc/$pid/cmdline" 2>/dev/null || return 1
	echo "$pid"
}

service_running() {
	service_pid >/dev/null
}

# Ready = policy applied to a live Xray (run_service writes the marker).
service_ready() {
	[ -f "$RUNNING_MARKER" ] && service_running
}

# Remove leftovers of a crashed or killed service. An Xray without its
# run-service supervisor is an orphan and is stopped too.
service_recover() {
	local pid=""

	pgrep -f "$SUPERVISOR_PATTERN" >/dev/null 2>&1 && return 0
	# Only our service form (core_spawn), never a short `version`/`run -test`
	# run or another Xray instance with its own config.
	for pid in $(service_pid) $(pgrep -f "^$XRAY_BIN run -c $RUNTIME_CONFIG\$" 2>/dev/null); do
		kill -9 "$pid" 2>/dev/null
	done
	policy_cleanup
	rm -f "$RUNNING_MARKER" "$SERVICE_PID_FILE" "$SUPERVISOR_PID_FILE"
}

# Called under the runtime lock, after init stop was attempted outside it.
uninstall_cleanup() {
	local rc=0

	service_recover || rc=1
	# Uninstall must restore direct routing even if run-service is still alive.
	policy_cleanup || rc=1
	# Inert while stopped (nothing sets the intercept mark): only uninstall removes it.
	nft_fw4_input_cleanup || rc=1
	rm -f "$RUNNING_MARKER" "$SERVICE_PID_FILE" || rc=1
	cron_sync "$CRON_MARKER" 0 "" || rc=1
	# Spec 12: the xraywrt-core package removes its own binary.
	core_package_installed || rm -f "$XRAY_BIN" || rc=1
	rm -f "$XRAY_BIN.new" "$XRAY_BIN.old" || rc=1
	rm -rf "$XRAY_SHARE_DIR" "$XRAY_SUBS_DIR"/*/share || rc=1
	# A journal left behind would be replayed after a reinstall.
	rm -f "$XRAY_SUBS_DIR/.switch" || rc=1
	rm -f "$PKG_PERSIST_DIR/subscription.json" "$CORE_JSON_FILE" || rc=1
	rm -rf "$POLICY_CACHE_DIR" || rc=1
	rm -rf "$PKG_TMP_DIR" "$PKG_STATE_DIR" || rc=1
	return "$rc"
}

# Build and check a runtime config from $XRAY_CONFIG; remember the result.
# Without the core the generated config stays for status, the check fails.
runtime_config_build() {
	local key="" inputs="" params="" XRAY_RULE_REMOTE=""

	geodata_recover || return 1
	# Recovery or a completed switch during the lock wait may have changed the active settings.
	subscription_recover || warn "Cannot repair an interrupted subscription switch; the next start tries again"
	settings_load || return 1

	xray_config_prepare "$XRAY_CONFIG"
	runtime_config_key_store ""
	xray_config_generate "$XRAY_CONFIG" "$1" "" "$params" || {
		# A rejected config fails the same way on every hotplug retry.
		# The parser's reason is already the last error; the check itself failed.
		[ "$?" != 2 ] || { CONFIG_TEST_OUTPUT="" GEODATA_TRANSIENT=0; config_check_record err && : >"$CONFIG_INVALID_FILE"; }
		return 1
	}
	[ -x "$XRAY_BIN" ] || { xray_config_test "$1"; return 1; }
	# Spec 10: files nothing needs only take flash; before the stamp key,
	# which hashes the share/ listing.
	geodata_prune "$1.profile"
	if { key="$(xray_config_test_key "$1")" && [ "$key" = "$(cat "$CONFIG_TESTED_FILE" 2>/dev/null)" ]; } ||
		xray_config_test "$1" "$XRAY_BIN" "$key"; then
		if ! dns_forward_safety_save "$1.profile" "$1.dns-uci"; then
			rm -f "$1" "$1.profile"
			return 1
		fi
		rm -f "$1.dns-uci"
		config_check_record ok
		runtime_config_key_store "$inputs"
		return 0
	fi
	config_check_record err
	return 1
}

cron_update() {
	settings_require || return 1

	local enabled=0 urls=""

	[ "$SUBSCRIPTION_INTERVAL" -gt 0 ] && [ -n "$SUBSCRIPTION_URL" ] && enabled=1
	if [ "$enabled" -eq 0 ] && [ "$LISTS_INTERVAL" -gt 0 ]; then
		urls="$(lists_urls)" || return 1
		[ -z "$urls" ] || enabled=1
	fi
	cron_sync "$CRON_MARKER" "$enabled" "$CRON_MINUTE * * * * /usr/bin/xraywrt auto-update >/dev/null 2>&1"
}

# Everything that can fail before procd starts Xray, with clear errors.
service_prepare() {
	service_recover
	settings_ensure_generated && settings_load || return 1
	runtime_dirs_init || return 1
	dns_guard || return 1
	cron_update || warn "Failed to update cron schedule"
	runtime_config_build "$RUNTIME_CONFIG"
}

# last_error_record <stderr-file>: the start error shown in the UI.
last_error_record() {
	local error=""

	error="$(error_text "$1" 2>/dev/null)"
	atomic_write "$LAST_ERROR_FILE" "${error:-$(code_message service_start "XrayWRT could not start. See the system log.")}"
	return 0
}

# `xraywrt prepare`: service_prepare under the lock; a failure is recorded.
service_prepare_cmd() {
	local errfile="$LAST_ERROR_FILE.err.$$" rc=0

	ensure_dir "$PKG_STATE_DIR" || return 1
	with_lock service_prepare 2>"$errfile" || rc=$?
	cat "$errfile" >&2
	[ "$rc" -eq 0 ] || last_error_record "$errfile"
	rm -f "$errfile"
	return "$rc"
}

port_listening() {
	local proto="$1" port="" file=""

	port="$(printf ':%04X' "$2")"
	for file in "/proc/net/$proto" "/proc/net/${proto}6"; do
		[ -r "$file" ] || continue
		awk -v p="$port" -v tcp="$([ "$proto" = tcp ] && echo 1)" \
			'$2 ~ p"$" && (!tcp || $4 == "0A") { f = 1 } END { exit !f }' "$file" && return 0
	done
	return 1
}

wait_for_ready() {
	local pid="$1" i=0

	while [ "$i" -lt 30 ]; do
		# Called from run_service: abort when a stop was requested.
		[ "${stop:-0}" -eq 0 ] || return 1
		kill -0 "$pid" 2>/dev/null || return 1
		[ -S "$XRAY_API_SOCKET" ] && port_listening tcp "$XRAY_TPROXY_PORT" && port_listening udp "$XRAY_DNS_PORT" && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# An A answer from the core DNS inbound, asked past dnsmasq: the core takes,
# routes and resolves queries. -retry=0 is rejected by BusyBox.
dns_probe() {
	nslookup -type=a -port="$XRAY_DNS_PORT" -timeout=5 -retry=1 "$WATCHDOG_PROBE_DOMAIN" 127.0.0.1 >/dev/null 2>&1
}

stop_child() {
	local pid="$1" i=0

	kill "$pid" 2>/dev/null || return 0
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

# Start the core on $RUNTIME_CONFIG; sets pid (run_service local).
core_spawn() {
	pid=""
	chmod 700 "$PKG_STATE_DIR" || return 1
	# Ferrum leaves the socket after SIGKILL. Its lock is released by the kernel.
	if [ -S "$XRAY_API_SOCKET" ]; then
		flock -n "$XRAY_API_SOCKET.lock" rm -f "$XRAY_API_SOCKET" || return 1
	fi
	rm -f "$OBSERVATORY_FILE"
	geodata_snapshot || { rm -f "$RUNTIME_CONFIG.geodata" "$RUNTIME_CONFIG.geodata.tmp.$$"; warn "Cannot record core geodata state; hot apply disabled"; }
	XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -c "$RUNTIME_CONFIG" 9>&- &
	pid=$!
	echo "$pid" >"$SERVICE_PID_FILE"
}

# Restart the core on the published $RUNTIME_CONFIG (spec 9.3) through the
# supervisor: nft stays in place, so a restart never sends proxied traffic
# direct. Caller holds the runtime lock, which also pauses the watchdog.
core_restart() {
	local sup="" i=0 result=""

	sup="$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)" || return 1
	is_uint "$sup" && kill -0 "$sup" 2>/dev/null || return 1
	rm -f "$RESTART_RESULT_FILE"
	kill -USR1 "$sup" 2>/dev/null || return 1
	while [ "$i" -lt "$CORE_READY_WAIT" ]; do
		{ IFS= read -r result <"$RESTART_RESULT_FILE"; } 2>/dev/null || :
		[ -z "$result" ] || break
		# Stop pressed meanwhile: the supervisor never answers; not a config failure.
		[ ! -f "$USER_STOP_FILE" ] || { rm -f "$RESTART_RESULT_FILE"; return 0; }
		sleep 1
		i=$((i + 1))
	done
	rm -f "$RESTART_RESULT_FILE"
	# A "fail" answer after Stop is the supervisor giving up its readiness wait.
	[ "$result" = ok ] || [ -f "$USER_STOP_FILE" ]
}

# Publish a generated and tested candidate (<file> with <file>.profile) as
# the runtime config after API apply, or restart for unsupported changes/errors.
# A failed restart restores the previous runtime (spec 9.3 step 4).
runtime_publish() {
	local candidate="$1" file="" running=0 hot=0 attempted=0 snapshot="$RUNTIME_CONFIG.geodata.next" safety="$1.dns-uci"

	RUNTIME_RESTARTED=0 RUNTIME_HOT_RELOADED=0
	service_running && [ -f "$SUPERVISOR_PID_FILE" ] && running=1
	# A starting supervisor waits for this lock: a restart request would time out twice.
	if [ "$running" = 1 ] && ! service_ready && [ ! -f "$DEGRADED_FILE" ]; then
		err_code runtime_busy "The router is busy with another task (process %s). Try again in a minute." "$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)"
		return 1
	fi
	rm -f "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
	for file in "$RUNTIME_CONFIG" "$PROFILE_FILE"; do
		[ ! -f "$file" ] || cp -p "$file" "$file.prev" || {
			rm -f "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
			return 1
		}
	done
	runtime_config_key_store ""
	if ! dns_forward_safety_save "$candidate.profile" "$safety"; then
		rm -f "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev"
		return 1
	fi
	if [ "$running" -eq 1 ] && geodata_unchanged &&
		[ "$(xraywrt-json diff "$RUNTIME_CONFIG" "$candidate" 2>/dev/null)" = hot ] && geodata_snapshot "$snapshot"; then
		attempted=1
		xray_api_apply "$RUNTIME_CONFIG" "$candidate" && geodata_unchanged "$snapshot" && hot=1
	fi
	if ! { mv -f "$candidate.profile" "$PROFILE_FILE" && mv -f "$candidate" "$RUNTIME_CONFIG"; }; then
		runtime_restore_prev
		dns_forward_safety_restore "$safety" || :
		# The core's state after partial API work is unknown: without a snapshot
		# every change restarts until the next core_spawn records one.
		[ "$attempted" -eq 0 ] || core_restart || {
			rm -f "$RUNTIME_CONFIG.geodata"
			warn "Cannot restore the running config after hot apply"
		}
		rm -f "$snapshot" "$snapshot.tmp.$$"
		err "Cannot publish the runtime config"
		return 1
	fi
	if [ "$hot" -eq 1 ]; then
		balancer_overrides_apply 1 && geodata_unchanged "$snapshot" && mv -f "$snapshot" "$RUNTIME_CONFIG.geodata" || hot=0
	fi
	rm -f "$snapshot" "$snapshot.tmp.$$"
	if [ "$hot" -eq 1 ]; then
		RUNTIME_HOT_RELOADED=1
		log "Xray hot reloaded with the new config"
	elif [ "$running" -eq 1 ]; then
		if ! core_restart; then
			runtime_restore_prev
			dns_forward_safety_restore "$safety" || :
			core_restart || {
				[ "$attempted" -eq 0 ] || rm -f "$RUNTIME_CONFIG.geodata"
				warn "The previous config did not start either"
			}
			err "new config failed to start, previous restored"
			return 1
		fi
		RUNTIME_RESTARTED=1
		log "Xray restarted with the new config"
	fi
	# dnsmasq would keep answers of the old site lists until their TTL ends.
	[ "$running" -eq 0 ] || killall -HUP dnsmasq 2>/dev/null || :
	rm -f "$RUNTIME_CONFIG.prev" "$PROFILE_FILE.prev" "$safety"
}

runtime_restore_prev() {
	local file=""

	for file in "$RUNTIME_CONFIG" "$PROFILE_FILE"; do
		if [ -f "$file.prev" ]; then
			mv -f "$file.prev" "$file"
		else
			rm -f "$file"
		fi
	done
}

service_error() {
	atomic_write "$LAST_ERROR_FILE" "$*"
	err "$*"
}

# Recovery runs outside the supervisor: runtime_refresh may wait for its USR1 reply.
service_recovery_schedule() {
	[ -z "$recovery_pid" ] || ! kill -0 "$recovery_pid" 2>/dev/null || return 0
	"${SUPERVISOR_CMD% *}" recover-runtime "$$" 6>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
	recovery_pid=$!
}

service_recovery_allowed() {
	[ ! -f "$USER_STOP_FILE" ] && [ -f "$DEGRADED_FILE" ] &&
		[ "$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)" = "$1" ] &&
		kill -0 "$1" 2>/dev/null && service_running
}

# Called under the runtime lock, after three successful watchdog cycles.
service_recovery_reload() {
	local rc=0

	service_recovery_allowed "$1" || return 0
	settings_load || return 1
	runtime_refresh || rc=$?
	# Stop may arrive while core_restart waits for the supervisor.
	service_recovery_allowed "$1" || return 0
	if policy_reapply; then
		if ! service_recovery_allowed "$1"; then
			policy_cleanup
			return 0
		fi
		if ! atomic_write "$RUNNING_MARKER" "$1"; then
			policy_cleanup
			return 1
		fi
		if ! service_recovery_allowed "$1"; then
			[ "$(cat "$RUNNING_MARKER" 2>/dev/null)" != "$1" ] || rm -f "$RUNNING_MARKER"
			policy_cleanup
			return 0
		fi
		rm -f "$DEGRADED_FILE" "$LAST_ERROR_FILE" "$APPLY_WARNING_FILE"
		if [ "$rc" -ne 0 ]; then
			atomic_write "$APPLY_WARNING_FILE" "$(code_message recovery_inputs 'The latest changes could not be applied. XrayWRT is using the previous working configuration. Review the settings or update the subscription.')" || return 1
		fi
		log "watchdog: Xray recovered, policy restored"
		return 0
	fi
	return 1
}

# procd payload. Exit 0 = stopped on request; exit 1 = failure, procd respawns.
run_service() {
	local pid="" fails=0 oks=0 stop=0 rc=1 degraded=0 error="" health="" restart=0 reason="" recovery_pid="" tick="" observe_ok=1 observe_wait=0

	# A long-lived supervisor must never retain its caller's lock.
	exec 9>&-
	LOCK_DEPTH=0

	if [ -e "$XRAY_SHARE_DIR/.geodata-transaction" ] || [ -L "$XRAY_SHARE_DIR/.geodata-transaction" ]; then
		# A killed supervisor may have left the policy on: never keep it without a core.
		RUNTIME_LOCK_TIMEOUT=10 with_lock geodata_recover || { policy_cleanup; return 1; }
	fi
	ensure_dir "$PKG_STATE_DIR" || { policy_cleanup; return 1; }
	rm -f "$HEALTH_FILE" "$DEGRADED_FILE" "$OBSERVATORY_FILE"
	error="$LAST_ERROR_FILE.err.$$"
	# Saved DNS routes/latches require a checked build, not bytes left by a preview or failed start.
	if ! { settings_load && {
		{ [ -s "$RUNTIME_CONFIG" ] && [ -z "${DNS_RAW_VIA:-}${DNS_RAW_LOST:-}" ]; } ||
			with_lock runtime_config_build "$RUNTIME_CONFIG"
	}; } 2>"$error"; then
		cat "$error" >&2
		last_error_record "$error"
		rm -f "$error"
		policy_cleanup
		return 1
	fi
	cat "$error" >&2
	rm -f "$error"
	trap 'stop=1; XRAYWRT_STOP=1' INT TERM HUP
	trap 'restart=1' USR1
	echo "$$" >"$SUPERVISOR_PID_FILE"
	# A core left by a killed supervisor holds the ports: the new one would die.
	for pid in $(pgrep -f "^$XRAY_BIN run -c $RUNTIME_CONFIG\$" 2>/dev/null); do
		# The kernel frees the ports a moment after the kill.
		kill -9 "$pid" 2>/dev/null && sleep 1
	done
	if ! { core_spawn && wait_for_ready "$pid"; }; then
		service_error "core did not become ready; router stays on direct routing"
	elif with_lock service_ready_apply 2>"$error"; then
		cat "$error" >&2
		rm -f "$error"
		rm -f "$LAST_ERROR_FILE"
		log "XrayWRT ready (Xray pid $pid)"
		rc=0
		# Catch settings saved before or during startup; unchanged inputs are a no-op.
		"${SUPERVISOR_CMD% *}" reload 6>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
		while [ "$stop" -eq 0 ]; do
			if [ "$restart" -eq 0 ]; then
				sleep "$WATCHDOG_INTERVAL" 9>&- &
				tick=$!
				# SIGCHLD ends the wait at once when the core dies, so clients
				# are not left on a dead tproxy port until the next tick.
				trap : CHLD
				while [ "$stop" -eq 0 ] && [ "$restart" -eq 0 ] &&
					kill -0 "$tick" 2>/dev/null && kill -0 "$pid" 2>/dev/null; do
					wait "$tick" 2>/dev/null
				done
				trap - CHLD
			fi
			[ "$stop" -eq 0 ] || break
			if [ "$restart" -eq 1 ]; then
				# core_restart asked for the new runtime config.
				restart=0
				stop_child "$pid"
				if core_spawn && wait_for_ready "$pid"; then
					balancer_overrides_apply
					atomic_write "$RESTART_RESULT_FILE" ok
				else
					atomic_write "$RESTART_RESULT_FILE" fail
				fi
				fails=0
				oks=0
				observe_ok=1
				observe_wait=0
				continue
			fi
			kill -0 "$pid" 2>/dev/null || break
			lock_busy && continue
			health=""
			{ IFS= read -r health <"$HEALTH_FILE"; } 2>/dev/null || :
			reason=""
			if dns_probe; then
				[ "$health" = ok ] || atomic_write "$HEALTH_FILE" ok
			else
				[ "$health" = fail ] || atomic_write "$HEALTH_FILE" fail
				reason=dns
			fi
			# Each check forks the core CLI: skip it on most ticks while the last result was good.
			if [ "$observe_ok" -eq 1 ] && [ "$observe_wait" -gt 0 ] && [ "$degraded" -eq 0 ]; then
				observe_wait=$((observe_wait - 1))
			elif watchdog_observatory_ok; then
				observe_ok=1
				observe_wait=$((WATCHDOG_OBSERVE_TICKS - 1))
			else
				observe_ok=0
				[ -n "$reason" ] || reason=observatory
			fi
			# The external recovery worker clears the shared degraded state.
			[ -f "$DEGRADED_FILE" ] || degraded=0
			if [ -z "$reason" ]; then
				fails=0
				[ "$degraded" -eq 1 ] || continue
				oks=$((oks + 1))
				[ "$oks" -ge 3 ] || continue
				service_recovery_schedule
				oks=0
				continue
			fi
			oks=0
			[ "$degraded" -eq 1 ] && continue
			fails=$((fails + 1))
			warn "watchdog: Xray $reason check failed ($fails/$WATCHDOG_FAILS)"
			[ "$fails" -ge "$WATCHDOG_FAILS" ] || continue
			# A live core with broken upstream DNS: go direct in place and
			# keep probing; a dead core ends the loop and procd restarts it.
			RUNTIME_LOCK_TIMEOUT=0 lock_acquire 2>/dev/null || continue
			atomic_write "$DEGRADED_FILE" "$reason"
			rm -f "$RUNNING_MARKER"
			policy_cleanup
			lock_release
			degraded=1
			warn "watchdog: Xray $reason unresponsive, traffic goes direct"
		done
		[ "$stop" -eq 1 ] || kill -0 "$pid" 2>/dev/null || {
			service_error "Xray exited unexpectedly"
			rc=1
		}
	else
		last_error_record "$error"
		rm -f "$error"
		error="$(cat "$LAST_ERROR_FILE")"
		service_error "$(code_message routing_apply "Failed to apply routing rules: %s" "${error% \[E:*}")"
		rc=1
	fi

	# A second stop signal or a late core_restart request must not kill us
	# before the cleanup; procd's term_timeout bounds a hung one.
	# (A no-op handler, not '': children would inherit an ignored TERM.)
	trap : INT TERM HUP
	trap '' USR1
	XRAYWRT_STOP=0
	# Restore direct DNS/routing first: a hung Xray may need SIGKILL. Bound
	# the lock wait for procd's 30 s stop budget.
	if RUNTIME_LOCK_TIMEOUT=10 lock_acquire; then
		rm -f "$RUNNING_MARKER"
		policy_cleanup
		lock_release
	else
		warn "Runtime lock busy at stop; cleaning up without it"
		rm -f "$RUNNING_MARKER"
		policy_cleanup
	fi
	stop_child "$pid"
	rm -f "$SERVICE_PID_FILE" "$SUPERVISOR_PID_FILE" "$HEALTH_FILE" "$DEGRADED_FILE" "$OBSERVATORY_FILE"
	[ "$stop" -eq 1 ] && {
		log "XrayWRT stopped"
		return 0
	}
	return "$rc"
}

# Called after procd sent the stop signal: wait until run-service finished its
# cleanup so `stop` is synchronous, then clear anything left behind.
service_wait_stopped() {
	local owner="" i=0

	owner="$(cat "$RUNNING_MARKER" 2>/dev/null)"
	while { pgrep -f "$SUPERVISOR_PATTERN" >/dev/null 2>&1 || { is_uint "$owner" && kill -0 "$owner" 2>/dev/null; }; } && [ "$i" -lt 35 ]; do
		sleep 1
		i=$((i + 1))
	done
	# No supervisor left: an Xray still alive after 5 s is an orphan.
	i=0
	while service_running && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
	RUNTIME_LOCK_TIMEOUT=10 with_lock service_recover || service_recover
}

# Apply changed UCI settings to a running service (spec 9.3): the same
# generation key and unchanged geodata only re-apply policy; otherwise test
# and hot apply or restart, with the previous config back if it does not start.
service_reload() {
	local rc=0

	settings_load || return 1
	cron_update || warn "Failed to update cron schedule"
	if ! service_ready && ! { service_running && [ -f "$DEGRADED_FILE" ]; }; then
		# A starting supervisor needs this lock for initial readiness; it reloads once ready.
		service_running && return 0
		# A stopped service still accepts selected-profile changes: latch a lost DNS route now.
		[ -z "${DNS_RAW_VIA:-}" ] || runtime_refresh
		return $?
	fi
	[ ! -f "$USER_STOP_FILE" ] || return 0
	runtime_refresh || rc=$?
	[ "$rc" -ne 1 ] || return 1
	# A degraded live core accepts runtime updates, but only the watchdog restores policy.
	service_ready || { [ "$rc" -eq 0 ]; return; }
	[ ! -f "$USER_STOP_FILE" ] || return 0
	if settings_load && policy_apply && [ "$rc" -eq 0 ]; then
		rm -f "$APPLY_WARNING_FILE"
		return 0
	fi
	atomic_write "$APPLY_WARNING_FILE" "$(apply_partial_message)"
	return 1
}

# Regenerate the runtime config of a running core; a changed one is tested
# and published (hot apply or restart, rollback on failure). Unchanged output
# with the same core geodata never restarts the core. 0 = up to date, 1 = rejected (live config kept),
# 2 = publish failed.
runtime_refresh() {
	local candidate="$PKG_TMP_DIR/config.candidate.json" inputs="" stored="" params="" XRAY_RULE_REMOTE=""

	xray_config_prepare "$XRAY_CONFIG"
	{ IFS= read -r stored <"$RUNTIME_CONFIG.inputs"; } 2>/dev/null || :
	[ -z "$inputs" ] || [ "$inputs" != "$stored" ] || ! [ -f "$RUNTIME_CONFIG" ] || ! [ -f "$PROFILE_FILE" ] || ! geodata_unchanged || return 0
	xray_config_generate "$XRAY_CONFIG" "$candidate" "" "$params" || {
		rm -f "$candidate" "$candidate.profile"
		return 1
	}
	if cmp -s "$candidate" "$RUNTIME_CONFIG" && geodata_unchanged; then
		dns_forward_safety_save "$candidate.profile" "$candidate.dns-uci" || {
			rm -f "$candidate" "$candidate.profile"
			return 1
		}
		rm -f "$candidate.dns-uci"
		mv -f "$candidate.profile" "$PROFILE_FILE" || {
			rm -f "$candidate" "$candidate.profile"
			return 1
		}
		rm -f "$candidate"
		runtime_config_key_store "$inputs"
		return 0
	fi
	if xray_config_test "$candidate"; then
		config_check_record ok
	else
		config_check_record err
		rm -f "$candidate" "$candidate.profile"
		return 1
	fi
	runtime_publish "$candidate" || {
		rm -f "$candidate" "$candidate.profile"
		return 2
	}
	runtime_config_key_store "$inputs"
}

# Hourly cron entry: downloads run unlocked, applying takes the runtime lock.
# A stopped core applies updated lists on its next start; only live apply can fail.
auto_update_policy() {
	service_ready || return 0
	lists_policy_apply
}

auto_update() {
	local urls="" result="" rc=0

	settings_load || return 1
	if subscription_due; then
		subscription_update || rc=1
	fi
	if [ "$LISTS_INTERVAL" -gt 0 ]; then
		urls="$(lists_urls)" || return 1
		if [ -n "$urls" ]; then
			result="$(lists_update_remote 0 "$urls")" || rc=1
			[ "$result" != changed ] || with_lock auto_update_policy || rc=1
		fi
	fi
	return "$rc"
}
