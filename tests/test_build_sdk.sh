#!/usr/bin/env bash
#
# tests/test_build_sdk.sh - Verification tests for tools/build-sdk.sh, Dockerfile.sdk, and Dockerfile.test
#

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/tools/build-sdk.sh"
DOCKERFILE_SDK="${ROOT_DIR}/Dockerfile.sdk"
DOCKERFILE_TEST="${ROOT_DIR}/Dockerfile.test"

passed=0
failed=0

assert_eq() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'ok - %s\n' "$desc"
		passed=$((passed + 1))
	else
		printf 'not ok - %s (expected %s, got %s)\n' "$desc" "$expected" "$actual" >&2
		failed=$((failed + 1))
	fi
}

assert_contains() {
	local desc="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'ok - %s\n' "$desc"
		passed=$((passed + 1))
	else
		printf 'not ok - %s (needle not found: %s)\n' "$desc" "$needle" >&2
		failed=$((failed + 1))
	fi
}

# Test 1: build-sdk.sh exists and is executable
if [[ -x "$SCRIPT" ]]; then
	printf 'ok - tools/build-sdk.sh exists and is executable\n'
	passed=$((passed + 1))
else
	printf 'not ok - tools/build-sdk.sh not executable\n' >&2
	failed=$((failed + 1))
fi

# Test 2: Shell syntax passes
if bash -n "$SCRIPT"; then
	printf 'ok - tools/build-sdk.sh syntax is valid bash\n'
	passed=$((passed + 1))
else
	printf 'not ok - tools/build-sdk.sh syntax error\n' >&2
	failed=$((failed + 1))
fi

# Test 3: --help works and documents commands and volume
help_out="$("$SCRIPT" --help)"
assert_contains "help output mentions build command" "build" "$help_out"
assert_contains "help output mentions test command" "test" "$help_out"
assert_contains "help output mentions prepare command" "prepare" "$help_out"
assert_contains "help output mentions Docker volume name" "xraywrt-sdk-25.12.6" "$help_out"
assert_contains "help output documents APFS/case-insensitive caveat" "case-insensitive" "$help_out"
assert_contains "help output documents QEMU architecture caveat" "Architecture caveat" "$help_out"
assert_contains "help output defaults to sane 4 jobs" "default: 4" "$help_out"

# Test 4: Dockerfile.sdk exists and contains required components
if [[ -f "$DOCKERFILE_SDK" ]]; then
	printf 'ok - Dockerfile.sdk exists\n'
	passed=$((passed + 1))
	dockerfile_content="$(cat "$DOCKERFILE_SDK")"
	assert_contains "Dockerfile.sdk uses ubuntu:26.04" "ubuntu:26.04" "$dockerfile_content"
	assert_contains "Dockerfile.sdk sets FORCE_UNSAFE_CONFIGURE=1" "FORCE_UNSAFE_CONFIGURE=1" "$dockerfile_content"
	assert_contains "Dockerfile.sdk uses Node 26 LTS" "node:26-slim" "$dockerfile_content"
	assert_contains "Dockerfile.sdk copies Node binary" "COPY --from=node" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs jq" "jq" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs shellcheck" "shellcheck" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs bash" "bash" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs rsync" "rsync" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs zstd" "zstd" "$dockerfile_content"
else
	printf 'not ok - Dockerfile.sdk does not exist\n' >&2
	failed=$((failed + 1))
fi

# Test 5: Dockerfile.test exists and contains native test requirements
if [[ -f "$DOCKERFILE_TEST" ]]; then
	printf 'ok - Dockerfile.test exists\n'
	passed=$((passed + 1))
	test_dockerfile_content="$(cat "$DOCKERFILE_TEST")"
	assert_contains "Dockerfile.test uses alpine" "alpine" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs bash" "bash" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs jq" "jq" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs ucode" "ucode" "$test_dockerfile_content"
	assert_contains "Dockerfile.test uses Node 26 LTS Alpine" "node:26-alpine" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs shellcheck" "shellcheck" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs coreutils" "coreutils" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs gawk" "gawk" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs grep" "grep" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs sed" "sed" "$test_dockerfile_content"
else
	printf 'not ok - Dockerfile.test does not exist\n' >&2
	failed=$((failed + 1))
fi

# Test 6: Script does NOT use fake shellcheck stub
script_content="$(cat "$SCRIPT")"
if [[ "$script_content" == *"sdk-test-shim"* ]]; then
	printf 'not ok - tools/build-sdk.sh still contains fake shellcheck shim\n' >&2
	failed=$((failed + 1))
else
	printf 'ok - tools/build-sdk.sh does not contain fake shellcheck stub\n'
	passed=$((passed + 1))
fi

# Test 7: Script contains Kconfig recursive dependency fix
assert_contains "tools/build-sdk.sh minimal config fixes LIBCURL_LDAP" "CONFIG_LIBCURL_LDAP=n" "$script_content"

# Regression: an interrupted metadata scan leaves an empty tmp/.packageinfo
# that make treats as fresh, so every later build fails with "No rule".
assert_contains "tools/build-sdk.sh rescans an empty package index" '[ -s tmp/.packageinfo ]' "$script_content"

# Test 8: Script asserts both APKs exist
assert_contains "tools/build-sdk.sh asserts luci-app-xraywrt APK" "luci-app-xraywrt-*.apk" "$script_content"
assert_contains "tools/build-sdk.sh asserts luci-i18n-xraywrt-ru APK" "luci-i18n-xraywrt-ru-*.apk" "$script_content"

# Test 9: all SDK commands use Docker, including on Linux test hosts.
# Keep the fixture isolated: no real Docker daemon, SDK download or build runs.
sdk_fixture="$(mktemp -d)"
trap 'rm -rf "$sdk_fixture"' EXIT
mkdir -p "$sdk_fixture/tools" "$sdk_fixture/bin" "$sdk_fixture/.sdk" "$sdk_fixture/dist"
cp "$SCRIPT" "$sdk_fixture/tools/build-sdk.sh"
: >"$sdk_fixture/.sdk/openwrt-sdk-25.12.6-x86-64.tar.zst"
: >"$sdk_fixture/dist/luci-app-xraywrt-0.1.0-r1.apk"
: >"$sdk_fixture/dist/luci-i18n-xraywrt-ru-0.1.0-r1.apk"
cat >"$sdk_fixture/bin/sha256sum" <<'SHA'
#!/bin/sh
printf '%s  %s\n' 1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc "$1"
SHA
cat >"$sdk_fixture/bin/docker" <<'DOCKER'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_CALLS"
DOCKER
chmod +x "$sdk_fixture/bin/sha256sum" "$sdk_fixture/bin/docker"
for sdk_command in build prepare test clean; do
 : >"$sdk_fixture/docker.calls"
 sdk_rc=0
 PATH="$sdk_fixture/bin:$PATH" DOCKER_CALLS="$sdk_fixture/docker.calls" \
  bash "$sdk_fixture/tools/build-sdk.sh" "$sdk_command" >"$sdk_fixture/output" 2>&1 || sdk_rc=$?
 assert_eq "$sdk_command succeeds through Docker" 0 "$sdk_rc"
 assert_contains "$sdk_command invokes a Docker container" 'run --rm' "$(cat "$sdk_fixture/docker.calls")"
done
native_rc=0
native_err="$(bash "$sdk_fixture/tools/build-sdk.sh" --native build 2>&1)" || native_rc=$?
assert_eq '--native is rejected on every host' 1 "$native_rc"
assert_contains 'native rejection reports unsupported argument' 'Unknown argument: --native' "$native_err"
for removed_name in run_build_native_linux detect_exec_mode USE_DOCKER EXEC_MODE; do
 assert_eq "Docker-only script removes $removed_name" 0 "$(grep -c "$removed_name" "$SCRIPT" || true)"
done
rm -rf "$sdk_fixture"
trap - EXIT

# Test 9b: only the 25.12 SDK (apk) is supported; the XRAYWRT_SDK selector is gone.
sdk_fixture="$(mktemp -d)"
trap 'rm -rf "$sdk_fixture"' EXIT
mkdir -p "$sdk_fixture/tools" "$sdk_fixture/bin" "$sdk_fixture/.sdk" "$sdk_fixture/dist"
cp "$SCRIPT" "$sdk_fixture/tools/build-sdk.sh"
: >"$sdk_fixture/.sdk/openwrt-sdk-25.12.6-x86-64.tar.zst"
: >"$sdk_fixture/dist/luci-app-xraywrt-0.1.0-r1.apk"
: >"$sdk_fixture/dist/luci-i18n-xraywrt-ru-0.1.0-r1.apk"
cat >"$sdk_fixture/bin/sha256sum" <<'SHA'
#!/bin/sh
printf '%s  %s\n' 1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc "$1"
SHA
cat >"$sdk_fixture/bin/docker" <<'DOCKER'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_CALLS"
DOCKER
chmod +x "$sdk_fixture/bin/sha256sum" "$sdk_fixture/bin/docker"
run_sdk_fixture() { # run_sdk_fixture <XRAYWRT_SDK or empty> <command>
 : >"$sdk_fixture/docker.calls"
 sdk_rc=0
 (cd "$sdk_fixture" && env ${1:+XRAYWRT_SDK="$1"} PATH="$sdk_fixture/bin:$PATH" DOCKER_CALLS="$sdk_fixture/docker.calls" \
  bash "$sdk_fixture/tools/build-sdk.sh" "$2" >"$sdk_fixture/output" 2>&1) || sdk_rc=$?
}
run_sdk_fixture "" build
assert_eq "SDK build succeeds" 0 "$sdk_rc"
default_calls="$(cat "$sdk_fixture/docker.calls")"
assert_contains "SDK uses the 25.12.6 volume" "-v xraywrt-sdk-25.12.6:/sdk" "$default_calls"
assert_contains "SDK uses the 25.12.6 image" "xraywrt-sdk:25.12.6" "$default_calls"
assert_contains "SDK extracts the 25.12.6 directory" "SDK_DIR_NAME=openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64" "$default_calls"
assert_contains "SDK builds apk packages" "PKG_EXT=apk" "$default_calls"
run_sdk_fixture 24.10 build
assert_eq "XRAYWRT_SDK=24.10 is ignored: same docker calls as the default" "$default_calls" "$(cat "$sdk_fixture/docker.calls")"
run_sdk_fixture "" clean
assert_eq "clean succeeds" 0 "$sdk_rc"
assert_eq "clean removes apk files" 0 "$(find "$sdk_fixture/dist" -name "*.apk" | wc -l | tr -d ' ')"
assert_eq "build-sdk.sh has no XRAYWRT_SDK selector" 0 "$(grep -cE 'XRAYWRT_SDK([^_A-Z]|$)' "$SCRIPT" || true)"
assert_eq "build-sdk.sh has no ipk or 24.10 leftovers" 0 "$(grep -ciE 'ipk|24\.10|opkg' "$SCRIPT" || true)"
assert_contains "help documents XRAYWRT_SDK_IMAGE" "XRAYWRT_SDK_IMAGE" "$help_out"
rm -rf "$sdk_fixture"
trap - EXIT

# Makefile: apk-only protected paths, conffiles for both package formats.
protected_block="$(awk '/^ifdef CONFIG_USE_APK/{f=1} f{print} /^endif/{if(f)exit}' "${ROOT_DIR}/Makefile")"
assert_contains "protected_paths.d is installed only on apk builds" "protected_paths.d" "$protected_block"
assert_eq "protected_paths.d appears nowhere else in the Makefile" "$(grep -c 'protected_paths' <<<"$protected_block")" "$(grep -c 'protected_paths' "${ROOT_DIR}/Makefile")"
assert_contains "Makefile lists conffiles" "define Package/\$(PKG_NAME)/conffiles" "$(cat "${ROOT_DIR}/Makefile")"
if grep -q 'OpenWrt 25.12 APK systems' "${ROOT_DIR}/Makefile"; then
	printf 'not ok - Makefile description must not be apk-only\n' >&2
	failed=$((failed + 1))
else
	printf 'ok - Makefile description is not apk-only\n'
	passed=$((passed + 1))
fi

# Test 10: Feeds installs only luci-base host prerequisite
assert_contains "tools/build-sdk.sh installs luci-base feed" "./scripts/feeds install luci-base" "$script_content"
assert_contains "tools/build-sdk.sh uninstalls cyclic runtime feeds" "./scripts/feeds uninstall curl jq nftables" "$script_content"

# Test 11: Host target po2lmo validation
assert_contains "tools/build-sdk.sh builds host dependency luci-base/host" "make package/feeds/luci/luci-base/host/compile" "$script_content"
assert_contains "tools/build-sdk.sh validates host tool po2lmo" "staging_dir/hostpkg/bin/po2lmo" "$script_content"

# Test 12: Direct package compile without target cross-compiler
assert_contains "tools/build-sdk.sh runs direct package clean" "make -C package/luci-app-xraywrt clean" "$script_content"
assert_contains "tools/build-sdk.sh runs direct package compile" "make -C package/luci-app-xraywrt compile" "$script_content"

assert_contains "SDK sync includes shared package hardening rules" 'rsync -a --delete /workspace/tools/harden.sed package/luci-app-xraywrt/tools/' "$script_content"

# Test 13: Verify SDK archive exists and sha256 matches expected
archive="${ROOT_DIR}/.sdk/openwrt-sdk-25.12.6-x86-64.tar.zst"
if [[ -f "$archive" ]]; then
	if command -v shasum >/dev/null 2>&1; then
		sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
	else
		sha="$(sha256sum "$archive" | awk '{print $1}')"
	fi
	assert_eq "SDK archive sha256 matches expected official hash" "1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc" "$sha"
else
	printf 'ok - SDK archive download helper will trigger on missing file\n'
	passed=$((passed + 1))
fi

# Test 14: CI and release workflows (static checks; first real run is on push)
TEST_YML="${ROOT_DIR}/.github/workflows/test.yml"
RELEASE_YML="${ROOT_DIR}/.github/workflows/release.yml"
test_yml="$(cat "$TEST_YML" 2>/dev/null || true)"
release_yml="$(cat "$RELEASE_YML" 2>/dev/null || true)"
assert_contains "test.yml runs on push" "push:" "$test_yml"
assert_contains "test.yml runs on pull_request" "pull_request:" "$test_yml"
assert_contains "test.yml builds the test image" "docker build -t xraywrt-test:local -f Dockerfile.test ." "$test_yml"
assert_contains "test.yml runs the suite" "bash tests/run.sh" "$test_yml"
assert_contains "test.yml has 20 min job timeout" "timeout-minutes: 20" "$test_yml"
assert_contains "test.yml has concurrency group" "concurrency:" "$test_yml"
assert_contains "test.yml cancels in progress" "cancel-in-progress: true" "$test_yml"
assert_contains "release.yml triggers on v* tags" "tags: ['v*']" "$release_yml"
assert_contains "release.yml has contents: write" "contents: write" "$release_yml"
assert_contains "release.yml has a build job" $'\n  build:' "$release_yml"
assert_contains "release.yml has a publish job" $'\n  publish:' "$release_yml"
assert_contains "release.yml publish needs build" "needs: build" "$release_yml"
assert_contains "release.yml top-level permissions are empty" $'\npermissions: {}' "$release_yml"
assert_contains "release.yml build job is read-only" $'  build:\n    runs-on: ubuntu-26.04\n    permissions:\n      contents: read' "$release_yml"
assert_contains "release.yml publish job can write" $'    needs: build\n    runs-on: ubuntu-26.04\n    permissions:\n      contents: write' "$release_yml"
assert_eq "test.yml pins its job runner to ubuntu-26.04" 1 "$(grep -Ec '^    runs-on: ubuntu-26[.]04$' "$TEST_YML" || true)"
assert_eq "test.yml has one job runner" 1 "$(grep -Ec '^[[:space:]]*runs-on:' "$TEST_YML" || true)"
assert_eq "release.yml pins both job runners to ubuntu-26.04" 2 "$(grep -Ec '^    runs-on: ubuntu-26[.]04$' "$RELEASE_YML" || true)"
assert_eq "release.yml has two job runners" 2 "$(grep -Ec '^[[:space:]]*runs-on:' "$RELEASE_YML" || true)"
assert_eq "workflows do not use ubuntu-latest" 0 "$(grep -hc 'ubuntu-latest' "$TEST_YML" "$RELEASE_YML" | awk '{n += $1} END {print n+0}')"
assert_contains "release.yml checkout drops credentials" "persist-credentials: false" "$release_yml"
assert_contains "release.yml uploads artifacts with pinned v7" "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7" "$release_yml"
assert_contains "release.yml downloads artifacts with pinned v8" "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8" "$release_yml"
assert_contains "release.yml names the repo for gh" '--repo "$GITHUB_REPOSITORY"' "$release_yml"
assert_contains "test.yml checkout drops credentials" "persist-credentials: false" "$test_yml"
assert_eq "test.yml pins checkout v7" 1 "$(grep -Fc 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7' "$TEST_YML" || true)"
assert_eq "release.yml pins both checkout steps to v7" 2 "$(grep -Fc 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7' "$RELEASE_YML" || true)"
assert_contains "release.yml compares the tag with PKG_VERSION" 'PKG_VERSION' "$release_yml"
assert_contains "release.yml builds with build-sdk" "./tools/build-sdk.sh build" "$release_yml"
assert_contains "release.yml writes SHA256SUMS with sha256sum" "sha256sum" "$release_yml"
assert_contains "release.yml lists the fixed-name app APK" "luci-app-xraywrt.apk" "$release_yml"
assert_contains "release.yml lists the fixed-name i18n APK" "luci-i18n-xraywrt-ru.apk" "$release_yml"
assert_contains "release.yml creates the release" "gh release create" "$release_yml"
assert_contains "release.yml uses the workflow token" "secrets.GITHUB_TOKEN" "$release_yml"
assert_contains "release.yml triggers on workflow_dispatch" "workflow_dispatch:" "$release_yml"
assert_contains "release.yml inspects built APKs with apk adbdump" "apk adbdump" "$release_yml"
assert_contains "release.yml asserts noarch arch" "noarch" "$release_yml"
assert_contains "release.yml asserts executable modes" "etc/init.d/xraywrt" "$release_yml"
assert_contains "release.yml guards publish on tag refs" "startsWith(github.ref, 'refs/tags/')" "$release_yml"
assert_contains "release.yml has concurrency group" "concurrency:" "$release_yml"
assert_contains "release.yml does not cancel in progress" "cancel-in-progress: false" "$release_yml"
assert_contains "release.yml build job has 45 min timeout" "timeout-minutes: 45" "$release_yml"
assert_eq "release.yml has no SDK matrix" 0 "$(grep -c 'matrix' <<<"$release_yml" || true)"
assert_contains "release.yml cache key names the 25.12 SDK" "key: sdk-25.12" "$release_yml"
assert_eq "release.yml has no 24.10 or IPK leftovers" 0 "$(grep -ciE 'ipk|24\.10' <<<"$release_yml" || true)"
assert_eq "release.yml does not set XRAYWRT_SDK" 0 "$(grep -c 'XRAYWRT_SDK' <<<"$release_yml" || true)"
assert_contains "release.yml caches SDK archive with pinned cache v6" "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6" "$release_yml"
assert_contains "release.yml verifies release tags are on main" "git merge-base --is-ancestor" "$release_yml"
assert_contains "release.yml fetches main with depth for ancestry check" "origin main" "$release_yml"
for wf in "$TEST_YML" "$RELEASE_YML"; do
	if [[ -f "$wf" ]] && ! grep -P '\t' "$wf" >/dev/null && ! grep -q '@master\|@main' "$wf"; then
		printf 'ok - %s has no tabs and no floating action refs\n' "${wf##*/}"
		passed=$((passed + 1))
	else
		printf 'not ok - %s missing, has tabs or floating action refs\n' "${wf##*/}" >&2
		failed=$((failed + 1))
	fi
done

# Test 14b: run the release staging step on fake dist files
if [[ -n "$release_yml" ]]; then
	stage_script="$(awk '/- name: Stage release assets/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - name:/{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
	stage_dir="$(mktemp -d)"
	mkdir -p "$stage_dir/dist"
	printf a > "$stage_dir/dist/luci-app-xraywrt-0.10.0-r1.apk"
	printf b > "$stage_dir/dist/luci-i18n-xraywrt-ru-0.10.0-r1.apk"
	(cd "$stage_dir" && bash -c "$stage_script" >/dev/null 2>&1) || true
	sums="$(cat "$stage_dir/release/SHA256SUMS" 2>/dev/null || true)"
	assert_contains "staging lists the versioned app APK by bare name" "  luci-app-xraywrt-0.10.0-r1.apk" "$sums"
	assert_contains "staging lists the fixed-name i18n APK by bare name" "  luci-i18n-xraywrt-ru.apk" "$sums"
	if [[ "$sums" == *"/"* || "$sums" == *"dist"* ]]; then
		printf 'not ok - SHA256SUMS contains paths\n' >&2
		failed=$((failed + 1))
	else
		printf 'ok - SHA256SUMS has no paths\n'
		passed=$((passed + 1))
	fi
	if [[ -n "$sums" ]] && (cd "$stage_dir/release" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
		printf 'ok - SHA256SUMS verifies inside release/\n'
		passed=$((passed + 1))
	else
		printf 'not ok - SHA256SUMS does not verify inside release/\n' >&2
		failed=$((failed + 1))
	fi
	rm -rf "$stage_dir"
fi

# Test 14c: extract and run the version boundary; never contact GitHub.
version_script="$(awk '/- name: Check tag against PKG_VERSION/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
publish_script="$(awk '/- name: Create GitHub release/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
workflow_dir="$(mktemp -d)"
trap 'rm -rf "$workflow_dir"' EXIT
cp "$ROOT_DIR/Makefile" "$workflow_dir/Makefile"
assert_contains 'version-check block extracted from release.yml' 'PKG_VERSION' "$version_script"
for tag_case in v0.1.0:0:0 v0.1.0-rc1:0:1 v0.1.0-rc:1:- v0.1.1:1:- v0.1.0-beta1:1:-; do
 IFS=: read -r tag expected_rc expected_prerelease <<<"$tag_case"
 : >"$workflow_dir/env"; : >"$workflow_dir/output"
 tag_rc=0
 (cd "$workflow_dir" && GITHUB_REF_NAME="$tag" GITHUB_ENV="$workflow_dir/env" GITHUB_OUTPUT="$workflow_dir/output" bash -c "$version_script") >"$workflow_dir/tag.stdout" 2>"$workflow_dir/tag.stderr" || tag_rc=$?
 assert_eq "$tag version-check status" "$expected_rc" "$tag_rc"
 if [[ "$expected_rc" = 0 ]]; then
  actual_prerelease="$(sed -n 's/^PRERELEASE=//p' "$workflow_dir/env")"
  assert_eq "$tag prerelease flag" "$expected_prerelease" "$actual_prerelease"
 fi
done

# Check cross-job transport without prescribing the step/output identifier.
build_job="$(awk '/^  build:/{f=1;next} f&&/^  [^ ]/{exit} f{print}' "$RELEASE_YML")"
publish_job="$(awk '/^  publish:/{f=1;next} f{print}' "$RELEASE_YML")"
assert_contains 'build exposes job outputs' '    outputs:' "$build_job"
assert_contains 'build writes a step output' 'GITHUB_OUTPUT' "$build_job"
assert_contains 'publish receives prerelease through a build output' 'needs.build.outputs.' "$publish_job"
prerelease_output="$(printf '%s\n' "$publish_job" | sed -n 's/^[[:space:]]*PRERELEASE:.*needs\.build\.outputs\.\([A-Za-z0-9_-]*\).*$/\1/p')"
if [[ -n "$prerelease_output" ]]; then
 build_outputs="$(printf '%s\n' "$build_job" | awk '/^    outputs:/{f=1;next} f&&/^    [^ ]/{exit} f{print}')"
 assert_contains 'publish PRERELEASE output is declared by build' "$prerelease_output:" "$build_outputs"
 assert_contains 'build job outputs reference a step output' '.outputs.' "$build_outputs"
else
 assert_eq 'publish PRERELEASE is wired to a build output' 'build output reference' "$prerelease_output"
fi

# Execute the extracted publish block with a local gh recorder: only flag 1
# may produce --prerelease. The real gh executable is never invoked.
mkdir -p "$workflow_dir/bin" "$workflow_dir/release"
cat >"$workflow_dir/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$@" >"$GH_CALLS"
GH
chmod +x "$workflow_dir/bin/gh"
printf app >"$workflow_dir/release/app.apk"
printf sum >"$workflow_dir/release/SHA256SUMS"
: >"$workflow_dir/release-notes.md"
assert_contains 'publish block extracted from release.yml' 'gh release create' "$publish_script"
for prerelease_flag in 0 1; do
 publish_rc=0
 (cd "$workflow_dir" && PATH="$workflow_dir/bin:$PATH" GH_CALLS="$workflow_dir/gh.calls" PRERELEASE="$prerelease_flag" GITHUB_REF_NAME=v0.1.0 GITHUB_REPOSITORY=fixture/xraywrt bash -c "$publish_script") >"$workflow_dir/publish.stdout" 2>"$workflow_dir/publish.stderr" || publish_rc=$?
 assert_eq "publish PRERELEASE=$prerelease_flag status" 0 "$publish_rc"
 prerelease_count="$(grep -cx -- '--prerelease' "$workflow_dir/gh.calls" || true)"
 assert_eq "publish --prerelease only when PRERELEASE=$prerelease_flag" "$prerelease_flag" "$prerelease_count"
done
rm -rf "$workflow_dir"
trap - EXIT

# Test 14d: extract and test inspect-apks block from release.yml
inspect_body="$(awk '/- name: Inspect built APKs/{f=1;next} f&&/<< .EOF./{r=1;next} r&&/^[[:space:]]*EOF/{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
assert_contains "inspect script extracted from release.yml" "apk adbdump" "$inspect_body"
inspect_test_dir="$(mktemp -d)"
mkdir -p "$inspect_test_dir/bin" "$inspect_test_dir/dist"
touch "$inspect_test_dir/dist/luci-app-xraywrt-0.1.0.apk"
cat > "$inspect_test_dir/bin/apk" << 'MOCK_APK'
#!/bin/sh
cat << 'MOCK_DUMP'
info:
  arch: noarch
  depends:
    - libc
scripts:
  post-install: |
    exit 0
paths:
  - name: etc/init.d
    files:
      - name: xraywrt
        acl:
          mode: 0755
  - name: usr/bin
    files:
      - name: xraywrt
        acl:
          mode: 0755
MOCK_DUMP
MOCK_APK
chmod +x "$inspect_test_dir/bin/apk"
mock_rc=0
(cd "$inspect_test_dir" && PATH="$inspect_test_dir/bin:$PATH" bash -c "$inspect_body" >/dev/null 2>&1) || mock_rc=$?
assert_eq "inspect script succeeds on valid APK" 0 "$mock_rc"

cat > "$inspect_test_dir/bin/apk" << 'MOCK_APK'
#!/bin/sh
cat << 'MOCK_DUMP'
info:
  arch: x86_64
  depends:
    - libc
scripts:
  post-install: |
    exit 0
paths:
  - name: etc/init.d
    files:
      - name: xraywrt
        acl:
          mode: 0755
  - name: usr/bin
    files:
      - name: xraywrt
        acl:
          mode: 0755
MOCK_DUMP
MOCK_APK
chmod +x "$inspect_test_dir/bin/apk"
mock_bad_arch_rc=0
(cd "$inspect_test_dir" && PATH="$inspect_test_dir/bin:$PATH" bash -c "$inspect_body" >/dev/null 2>&1) || mock_bad_arch_rc=$?
assert_eq "inspect script fails on non-noarch" 1 "$mock_bad_arch_rc"

cat > "$inspect_test_dir/bin/apk" << 'MOCK_APK'
#!/bin/sh
cat << 'MOCK_DUMP'
info:
  arch: noarch
  depends:
    - libc
scripts:
  post-install: |
    exit 0
paths:
  - name: etc/init.d
    files:
      - name: xraywrt
        acl:
          mode: 0644
  - name: usr/bin
    files:
      - name: xraywrt
        acl:
          mode: 0755
MOCK_DUMP
MOCK_APK
chmod +x "$inspect_test_dir/bin/apk"
mock_bad_mode_rc=0
(cd "$inspect_test_dir" && PATH="$inspect_test_dir/bin:$PATH" bash -c "$inspect_body" >/dev/null 2>&1) || mock_bad_mode_rc=$?
assert_eq "inspect script fails on non-executable etc/init.d/xraywrt" 1 "$mock_bad_mode_rc"
rm -rf "$inspect_test_dir"

# Test 14f: installer download names match release.yml SHA256SUMS step
pkg_name="$(sed -n 's/^PKG="*\([^"]*\)"*/\1/p' "${ROOT_DIR}/install.sh")"
i18n_pkg_name="$(sed -n 's/^I18N_PKG="*\([^"]*\)"*/\1/p' "${ROOT_DIR}/install.sh")"
staging_step="$(awk '/- name: Stage release assets/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{print}' "$RELEASE_YML")"
assert_contains "SHA256SUMS step lists installer apk app package" "${pkg_name}.apk" "$staging_step"
assert_contains "SHA256SUMS step lists installer apk i18n package" "${i18n_pkg_name}.apk" "$staging_step"

# Test 14g: extract and test tag ancestry verification step from release.yml
ancestry_script="$(awk '/- name: Verify release commit is on main/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
assert_contains "ancestry-check block extracted from release.yml" "git merge-base --is-ancestor" "$ancestry_script"
ancestry_dir="$(mktemp -d)"
mkdir -p "$ancestry_dir/bin"
cat >"$ancestry_dir/bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = "rev-parse" ]; then
	echo "fake-sha"
	exit 0
fi
if [ "$1" = "fetch" ]; then
	exit 0
fi
if [ "$1" = "merge-base" ]; then
	[ "${MOCK_ANCESTOR:-1}" = "1" ] && exit 0 || exit 1
fi
exit 0
EOF
chmod +x "$ancestry_dir/bin/git"

# Case 1: rc tag skips ancestry check (exits 0 even if MOCK_ANCESTOR=0)
rc_status=0
(PATH="$ancestry_dir/bin:$PATH" MOCK_ANCESTOR=0 GITHUB_REF_NAME="v0.1.0-rc1" bash -c "$ancestry_script") >/dev/null 2>&1 || rc_status=$?
assert_eq "ancestry check skips rc tag" 0 "$rc_status"

# Case 2: non-rc tag fails when not an ancestor
non_rc_fail=0
(PATH="$ancestry_dir/bin:$PATH" MOCK_ANCESTOR=0 GITHUB_REF_NAME="v0.1.0" bash -c "$ancestry_script") >/dev/null 2>&1 || non_rc_fail=$?
assert_eq "ancestry check rejects release tag not on main" 1 "$non_rc_fail"

# Case 3: non-rc tag succeeds when commit is an ancestor
non_rc_ok=0
(PATH="$ancestry_dir/bin:$PATH" MOCK_ANCESTOR=1 GITHUB_REF_NAME="v0.1.0" bash -c "$ancestry_script") >/dev/null 2>&1 || non_rc_ok=$?
assert_eq "ancestry check accepts release tag on main" 0 "$non_rc_ok"

rm -rf "$ancestry_dir"

# Test 15: license and package metadata
BUG_YML="${ROOT_DIR}/.github/ISSUE_TEMPLATE/bug.yml"
if [[ -f "$BUG_YML" ]]; then
	printf 'ok - bug.yml exists\n'
	passed=$((passed + 1))
	bug_yml="$(cat "$BUG_YML")"
	assert_contains "bug.yml asks for OpenWrt version" "OpenWrt version" "$bug_yml"
	assert_contains "bug.yml asks for device/arch" "device/arch" "$bug_yml"
	assert_contains "bug.yml asks for XrayWRT version" "XrayWRT version" "$bug_yml"
	assert_contains "bug.yml asks for diagnostics JSON" "xraywrt diagnostics-json" "$bug_yml"
	assert_contains "bug.yml renders diagnostics as json" "render: json" "$bug_yml"
	assert_contains "bug.yml asks for steps to reproduce" "Steps to reproduce" "$bug_yml"
	assert_contains "bug.yml asks for expected/actual" "Expected / actual" "$bug_yml"
	if ! grep -P '[\x80-\xFF]' "$BUG_YML" >/dev/null; then
		printf 'ok - bug.yml is English only (no non-ASCII bytes)\n'
		passed=$((passed + 1))
	else
		printf 'not ok - bug.yml has non-ASCII bytes\n' >&2
		failed=$((failed + 1))
	fi
else
	printf 'not ok - bug.yml exists\n' >&2
	failed=$((failed + 1))
fi

makefile_content="$(cat "${ROOT_DIR}/Makefile")"
assert_contains "Makefile declares PKG_LICENSE" "PKG_LICENSE:=GPL-3.0-or-later" "$makefile_content"
assert_contains "Makefile declares PKG_LICENSE_FILES" "PKG_LICENSE_FILES:=LICENSE" "$makefile_content"
assert_contains "Makefile maintainer has an email" "PKG_MAINTAINER:=ristavor <90447432+ristavor@users.noreply.github.com>" "$makefile_content"
if grep -qE '(/workspace/|[[:space:]])LICENSE([[:space:]"]|$)' "$SCRIPT"; then
	printf 'not ok - build-sdk.sh must not copy LICENSE (PKG_LICENSE_FILES is metadata only)\n' >&2
	failed=$((failed + 1))
else
	printf 'ok - build-sdk.sh does not copy LICENSE into the SDK\n'
	passed=$((passed + 1))
fi
license_head="$(head -n 2 "${ROOT_DIR}/LICENSE" 2>/dev/null || true)"
assert_contains "LICENSE is GPL" "GNU GENERAL PUBLIC LICENSE" "$license_head"
assert_contains "LICENSE is version 3" "Version 3, 29 June 2007" "$license_head"
changelog_content="$(cat "${ROOT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
assert_contains "CHANGELOG.md has a 0.1.0 section" "## 0.1.0" "$changelog_content"
readme_content="$(cat "${ROOT_DIR}/docs/development.md")"
assert_contains "README documents the release order" "git tag vX && git push origin vX" "$readme_content"

# Spec 4.5 (plan F5): xraywrt-core packs the owner's prebuilt binary and its licenses.
core_mk="$(cat "${ROOT_DIR}/core/Makefile" 2>/dev/null || true)"
assert_contains "core recipe names the package" "PKG_NAME:=xraywrt-core" "$core_mk"
assert_contains "core package version is the core version" 'PKG_VERSION:=$(CORE_VERSION)' "$core_mk"
assert_contains "core binary installed as the XrayWRT core" '$(INSTALL_BIN) $(CORE_BIN) $(1)/opt/xraywrt/bin/xray' "$core_mk"
assert_contains "core licenses installed" '$(INSTALL_DATA) $(CORE_LICENSES) $(1)/usr/share/licenses/xraywrt-core/' "$core_mk"
assert_contains "core prebuilt binary is not stripped by the SDK" 'RSTRIP:=:' "$core_mk"
assert_contains "core recipe refuses a missing binary" 'set CORE_BIN' "$core_mk"
assert_contains "core package architecture is CORE_ARCH, apk refuses others (spec 4.5)" 'PKGARCH:=$(CORE_ARCH)' "$core_mk"
assert_eq "core package is not noarch" 0 "$(grep -c 'PKGARCH:=all' <<<"$core_mk" || true)"
assert_eq "core package has no other hooks or conffiles" 0 "$(grep -cE 'preinst|prerm|postrm|conffiles' <<<"$core_mk" || true)"
assert_contains "core postinst restarts only a core still running the replaced binary, unless the app's own update holds core.flock" 'flock -n /var/run/xraywrt/core.flock true' "$core_mk"
assert_eq "luci-app-xraywrt does not depend on xraywrt-core" 0 "$(grep -c 'xraywrt-core' "${ROOT_DIR}/Makefile" || true)"
core_fixture="$(mktemp -d)"
trap 'rm -rf "$core_fixture"' EXIT
mkdir -p "$core_fixture/tools" "$core_fixture/bin" "$core_fixture/.sdk" "$core_fixture/dist" "$core_fixture/in"
cp "$SCRIPT" "$core_fixture/tools/build-sdk.sh"
: >"$core_fixture/.sdk/openwrt-sdk-25.12.6-x86-64.tar.zst"
printf '#!/bin/sh\necho "Xray 26.11.1 (xcore)"\n' >"$core_fixture/in/xray"
echo 'core license' >"$core_fixture/in/LICENSE"
echo 'third-party notices' >"$core_fixture/in/NOTICE"
printf '#!/bin/sh\nprintf "%%s  %%s\\n" 1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc "$1"\n' >"$core_fixture/bin/sha256sum"
# The docker stub "builds" $FAKE_APK.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$DOCKER_CALLS"\nfor f in $FAKE_APK; do : >"$f"; done\n' >"$core_fixture/bin/docker"
chmod +x "$core_fixture/bin/sha256sum" "$core_fixture/bin/docker"
# Spec 4.5: SHA256SUMS-core keeps one line per architecture.
printf '%s  %s\n' aaaa xraywrt-core_26.10.1-r1_aarch64_cortex-a53.apk bbbb xraywrt-core_26.10.1-r1_x86_64.apk >"$core_fixture/dist/SHA256SUMS-core"
: >"$core_fixture/dist/xraywrt-core_26.10.1-r1_x86_64.apk"
core_rc=0
core_d="$core_fixture/dist/xraywrt-core_26.11.1-r1"
PATH="$core_fixture/bin:$PATH" DOCKER_CALLS="$core_fixture/docker.calls" FAKE_APK="${core_d}_aarch64_generic.apk ${core_d}_aarch64_cortex-a53.apk ${core_d}_aarch64_cortex-a72.apk ${core_d}_aarch64_cortex-a76.apk" \
	bash "$core_fixture/tools/build-sdk.sh" core "$core_fixture/in/xray" 26.11.1 "$core_fixture/in/LICENSE" "$core_fixture/in/NOTICE" >"$core_fixture/output" 2>&1 || core_rc=$?
assert_eq "core build succeeds through Docker" 0 "$core_rc"
core_h=1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc
assert_eq "SHA256SUMS-core: every rebuilt architecture's line replaced, others kept" "bbbb  xraywrt-core_26.10.1-r1_x86_64.apk
$core_h  xraywrt-core_26.11.1-r1_aarch64_generic.apk
$core_h  xraywrt-core_26.11.1-r1_aarch64_cortex-a53.apk
$core_h  xraywrt-core_26.11.1-r1_aarch64_cortex-a72.apk
$core_h  xraywrt-core_26.11.1-r1_aarch64_cortex-a76.apk" "$(cat "$core_fixture/dist/SHA256SUMS-core" 2>/dev/null || true)"
core_calls="$(cat "$core_fixture/docker.calls" 2>/dev/null || true)"
assert_contains "core build passes the version" "26.11.1" "$core_calls"
assert_contains "core build compiles the recipe" "make -C package/xraywrt-core compile" "$core_calls"
assert_contains "core build passes CORE_ARCH to the recipe" 'CORE_ARCH="$arch"' "$core_calls"
assert_eq "core build defaults to every aarch64 package architecture" "26.11.1 aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76" "$(tail -n 1 "$core_fixture/docker.calls" | sed 's/^[[:space:]]*//')"
assert_eq "core binary staged for the container" "$(cat "$core_fixture/in/xray")" "$(cat "$core_fixture/.build/core-input/xray" 2>/dev/null || true)"
assert_eq "core licenses staged for the container" "LICENSE NOTICE" "$(cd "$core_fixture/.build/core-input/licenses" 2>/dev/null && echo *)"
core_rc=0
PATH="$core_fixture/bin:$PATH" DOCKER_CALLS="$core_fixture/docker.calls" \
	bash "$core_fixture/tools/build-sdk.sh" core "$core_fixture/in/xray" 26.11.1 >"$core_fixture/output" 2>&1 || core_rc=$?
assert_eq "core build without licenses is refused" 1 "$core_rc"
assert_contains "core usage names the arguments" "core <binary> <version> <license-file>..." "$(cat "$core_fixture/output")"
rm -f "$core_fixture/dist/SHA256SUMS-core"
core_rc=0
: >"$core_fixture/docker.calls"
PATH="$core_fixture/bin:$PATH" DOCKER_CALLS="$core_fixture/docker.calls" FAKE_APK="$core_fixture/dist/xraywrt-core_26.12.1-r1_mipsel_24kc.apk" CORE_ARCH=mipsel_24kc \
	bash "$core_fixture/tools/build-sdk.sh" core "$core_fixture/in/xray" 26.12.1 "$core_fixture/in/LICENSE" >"$core_fixture/output" 2>&1 || core_rc=$?
assert_eq "core build without SHA256SUMS-core succeeds" 0 "$core_rc"
assert_eq "CORE_ARCH chooses the package architecture" "26.12.1 mipsel_24kc" "$(tail -n 1 "$core_fixture/docker.calls" | sed 's/^[[:space:]]*//')"
assert_eq "SHA256SUMS-core created" "1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc  xraywrt-core_26.12.1-r1_mipsel_24kc.apk" "$(cat "$core_fixture/dist/SHA256SUMS-core" 2>/dev/null || true)"
core_rc=0
PATH="$core_fixture/bin:$PATH" DOCKER_CALLS="$core_fixture/docker.calls" FAKE_APK="" \
	bash "$core_fixture/tools/build-sdk.sh" core "$core_fixture/in/xray" 26.13.1 "$core_fixture/in/LICENSE" >"$core_fixture/output" 2>&1 || core_rc=$?
assert_eq "core build without a package fails" 1 "$core_rc"
rm -rf "$core_fixture"
trap - EXIT

assert_contains "XrayWRT core package declares tagged-source license" 'PKG_LICENSE:=MPL-2.0' "$(cat "$ROOT_DIR/core/Makefile")"

printf '\nSummary: %d passed, %d failed\n' "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
	exit 1
fi
