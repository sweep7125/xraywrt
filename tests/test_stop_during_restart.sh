#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
# Stop pressed while a job waits for the supervisor: not a failed restart, so no config rollback.
STOP_DIR="$tmpdir" ash -s <<'ASH'
set -eu
for m in constants helpers validate settings geodata xray-config lists dns config xray-api service; do . "$XRAYWRT_LIB_DIR/$m.sh"; done
SUPERVISOR_PID_FILE="$STOP_DIR/sup" RESTART_RESULT_FILE="$STOP_DIR/result" USER_STOP_FILE="$STOP_DIR/stopped" CORE_READY_WAIT=3
sleep 30 & sup=$!
trap '' USR1
echo "$sup" >"$SUPERVISOR_PID_FILE"
: >"$USER_STOP_FILE"
core_restart
rm -f "$USER_STOP_FILE"
sleep 30 & echo $! >"$SUPERVISOR_PID_FILE"
if core_restart; then echo "silent supervisor must still fail" >&2; exit 1; fi
kill "$sup" $(cat "$SUPERVISOR_PID_FILE") 2>/dev/null || :
# The supervisor aborted its readiness wait on Stop and wrote "fail" first: still not a failed restart.
rm -f "$USER_STOP_FILE"
( trap ': >"$USER_STOP_FILE"; echo fail >"$RESTART_RESULT_FILE"' USR1; while :; do sleep 0.1; done ) & sup=$!
echo "$sup" >"$SUPERVISOR_PID_FILE"
sleep 0.3
core_restart || { kill "$sup" 2>/dev/null; echo "fail answer after Stop must not be a failed restart" >&2; exit 1; }
kill "$sup" 2>/dev/null || :
ASH
pass "stop during a core restart is not a failed restart"
