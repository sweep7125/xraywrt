#!/usr/bin/env bash
# Behavioral regressions; each named case also runs independently.
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

cases=(startup_settings watchdog_settings auto_update_ready lists_refresh_ready profile_race curl_device curl_plain lists_star lists_brackets)
if [ "$#" -eq 0 ]; then
	failed=0
	for name in "${cases[@]}"; do
		if bash "$0" "$name"; then :; else failed=1; fi
	done
	exit "$failed"
fi
name="$1"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh xray-config.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh xray-api.sh service.sh config.sh core.sh
setup_runtime_paths "$tmpdir"
src="$XRAY_CONFIG"
out="$tmpdir/runtime.json"
events="$tmpdir/events"
: >"$events"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.auto"
printf 'nameserver 192.0.2.53\n' >"$DNS_AUTO_RESOLVFILE"
# provider <jq filter>: the single-node fixture as the installed config.
provider() { jq "$1" "$ROOT_DIR/tests/fixtures/xray/src/single.json"; }
generate() { xray_config_generate "$src" "$out" || fail "$name: generation failed"; }
case "$name" in
startup_settings|watchdog_settings)
	RUNTIME_CONFIG="$out"
	RUNTIME_LOCK_FILE="$tmpdir/lock"
	SERVICE_PID_FILE="$PKG_STATE_DIR/pid"
	RUNNING_MARKER="$PKG_STATE_DIR/running"
	XRAY_BIN="$tmpdir/core"
	printf '#!/bin/sh\nexec sleep 30\n' >"$XRAY_BIN"
	chmod +x "$XRAY_BIN"
	cp "$ROOT_DIR/tests/fixtures/xray/out/single.proxy-first.json" "$RUNTIME_CONFIG"
	printf 'direct-first\n' >"$tmpdir/mode"
	settings_load() { POLICY_MODE="$(cat "$tmpdir/mode")"; echo load >>"$events"; }
	# Change settings after the initial load, before startup policy is installed.
	wait_for_ready() { [ "$name" != startup_settings ] || echo proxy-first >"$tmpdir/mode"; }
	policy_apply() {
		assert_true "$name: policy applies under flock" test "${LOCK_DEPTH:-0}" -gt 0
		assert_false "$name: own lock is not busy" lock_busy
		echo "apply:$POLICY_MODE" >>"$events"
	}
	policy_cleanup() { :; }
	WATCHDOG_INTERVAL=0.01
	WATCHDOG_FAILS=1
	probe_count=0
	service_recovery_schedule() { with_lock policy_reapply_ready && rm -f "$DEGRADED_FILE"; }
	# Probe 1 degrades, 2-4 recover, probe 5 finds a dead core.
	# shellcheck disable=SC2154 # pid: the core of the calling run_service
	dns_probe() {
		probe_count=$((probe_count + 1))
		[ "$probe_count" -lt 5 ] || kill -9 "$pid"
		if [ "$probe_count" = 2 ]; then
			assert_false "$name: marker absent while degraded" test -e "$RUNNING_MARKER"
			echo proxy-first >"$tmpdir/mode"
		fi
		[ "$probe_count" -ge 2 ] && [ "$probe_count" -le 4 ]
	}
	rc=0
	run_service 2>/dev/null || rc=$?
	assert_eq 1 "$rc" "$name: dead core exits for respawn"
	if [ "$name" = startup_settings ]; then
		assert_eq proxy-first "$(sed -n 's/^apply://p' "$events" | head -n1)" "$name: startup applies freshly loaded settings"
	else
		assert_eq $'direct-first\nproxy-first' "$(sed -n 's/^apply://p' "$events")" "$name: recovery uses changed profile"
		assert_eq 3 "$(grep -c '^load$' "$events")" "$name: settings reloaded at startup and recovery"
	fi
	;;
auto_update_ready|lists_refresh_ready)
	RUNNING_MARKER="$PKG_STATE_DIR/running"
	service_running() { return 0; }
	settings_load() { LISTS_INTERVAL=1; }
	subscription_due() { return 1; }
	lists_update_remote() { echo changed; }
	lists_urls() { echo https://lists.example/list; }
	with_lock() { "$@"; }
	nft_apply() { echo nft >>"$events"; }
	command_name="${name%_ready}"
	rc=0
	"$command_name" >/dev/null || rc=$?
	if [ "$name" = lists_refresh_ready ]; then
		assert_eq 0 "$rc" "$name: accepted lists wait for recovery without error"
	else
		assert_eq 0 "$rc" "$name: automatic update tolerates stopped service"
	fi
	assert_eq '' "$(cat "$events")" "$name: no nft while core runs without marker"
	touch "$RUNNING_MARKER"
	"$command_name" >/dev/null
	assert_eq nft "$(cat "$events")" "$name: nft when ready"
	;;
profile_race)
	XRAY_CONFIG_BACKUP="$tmpdir/backup.json"
	RUNTIME_CONFIG="$out"
	provider '.xraywrt = {"disable-quic": true}' >"$src"
	generate
	cp "$out.profile" "$PROFILE_FILE"
	provider '.xraywrt = {"disable-quic": false}' >"$tmpdir/candidate"
	xray_config_test() { :; }
	service_running() { return 0; }
	service_ready() { return 0; }
	core_restart() { fail "$name: provider-key-only change must not restart the core"; }
	cron_update() { :; }
	policy_apply() { echo policy >>"$events"; }
	# Interleave an unlocked status reader immediately after the config rename.
	mv() {
		command mv "$@"
		if [ "${*: -1}" = "$XRAY_CONFIG" ]; then
			touch -d '2000-01-01' "$PROFILE_FILE"
			profile_ensure
			assert_file_contains "$PROFILE_FILE" 'set disable_quic 0' "$name: reader regenerated new profile"
			echo reader >>"$events"
		fi
	}
	config_install "$tmpdir/candidate" >/dev/null
	assert_eq $'reader\npolicy' "$(cat "$events")" "$name: policy change survives concurrent profile regeneration"
	;;
curl_device|curl_plain)
	cat >"$tmpdir/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CURL_LOG"
while [ "$#" -gt 0 ]; do
 case "$1" in
 -D) printf 'HTTP/1.1 200 OK\r\n' >"$2"; shift ;;
 -o) printf data >"$2"; shift ;;
 esac
 shift
done
CURL
	chmod +x "$tmpdir/bin/curl"
	export CURL_LOG="$tmpdir/curl.argv"
	device_hwid() { echo test-hwid; }
	device_os_version() { echo test-os; }
	device_model() { echo test-model; }
	device=0
	[ "$name" != curl_device ] || device=1
	http_fetch 'https://example.com/[1-3]' "$tmpdir/body" 100 10 "$device"
	grep -Eq '^-[^-]*g' "$CURL_LOG" || fail "$name: curl argv missing globoff (-g)"
	if [ "$device" = 1 ]; then assert_file_contains "$CURL_LOG" 'x-hwid: test-hwid' "$name: device branch exercised"; fi
	;;
lists_star|lists_brackets)
	cd "$tmpdir"
	mkdir -p 'https:/example.com'
	if [ "$name" = lists_star ]; then fixture_url='https://example.com/list*'; else fixture_url='https://example.com/list[1-3]'; fi
	touch 'https:/example.com/list1'
	# Verify this cwd really would expand the provider URL without set -f.
	compgen -G "$fixture_url" >/dev/null || fail "$name: missing matching glob fixture"
	POLICY_CACHE_DIR="$tmpdir/cache"
	lists_urls() { printf '%s\n' "$fixture_url"; }
	http_fetch() { printf '%s\n' "$1" >>"$events"; printf '1.2.3.4\n' >"$2"; }
	assert_eq changed "$(lists_update_remote 1)" "$name: cache updated"
	assert_eq "$fixture_url" "$(cat "$events")" "$name: URL passed literally, not cwd-expanded"
	assert_file_contains "$(lists_cache_file "$fixture_url")" '1.2.3.4' "$name: literal URL cache populated"
	;;
*) fail "unknown review regression: $name" ;;
esac
pass "review regression: $name"
