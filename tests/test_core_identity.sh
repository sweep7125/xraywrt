#!/usr/bin/env bash
# shellcheck disable=SC2154 # tmpdir comes from core_fixture.sh
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
source "$(dirname "$0")/core_fixture.sh"
install_old
VERSION_LINE='Xray 26.11.1-1424 (Xray, Penetrates Everything.(Jolymmiles)) xcore-0.25.1 (rust linux/aarch64)'
export VERSION_LINE
assert_eq 0.25.1 "$(core_version)" "installed XrayWRT core version uses explicit marker, not compatibility version"

# Any lowercase <name>-x.y.z marker identifies the core; a Go Xray line is not one.
printf '#!/bin/sh\necho "$FAKE_VERSION_LINE"\n' >"$tmpdir/marker-bin" && chmod +x "$tmpdir/marker-bin"
FAKE_VERSION_LINE='Xray 26.11.1-1424 (Xray, Penetrates Everything.) abc-1.2.3 (rust linux/aarch64)' export FAKE_VERSION_LINE
assert_eq 1.2.3 "$(core_pkg_version "$tmpdir/marker-bin")" 'arbitrary lowercase marker accepted'
FAKE_VERSION_LINE='Xray 25.1.1 (Xray, Penetrates Everything.) abc123 (go1.23 linux/amd64)' export FAKE_VERSION_LINE
assert_false 'Go Xray line rejected' core_pkg_version "$tmpdir/marker-bin"
pass 'generic version marker'
