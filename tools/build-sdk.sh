#!/usr/bin/env bash
#
# tools/build-sdk.sh - Build official OpenWrt x86/64 SDK packages and run Linux test suite.
#
# Builds .apk packages with the OpenWrt 25.12.6 SDK (the only supported release).
#
# Environment / Platform:
#   Darwin (macOS arm64): Uses Docker container with linux/amd64 emulation and a named Docker volume.
#     The macOS APFS filesystem is case-insensitive, making bind mounts unsuitable for SDK compilation.
#     Build directory and SDK feeds are persisted in the named volume 'xraywrt-sdk-25.12.6'.
#     Official OpenWrt SDK only distributes Linux ELF binaries; native macOS builds are unsupported upstream.
#   Linux: Uses the same Docker build path for reproducible isolated builds.
#
# Usage:
#   ./tools/build-sdk.sh [command] [options]
#
# Commands:
#   build          Build luci-app-xraywrt and luci-i18n-xraywrt-ru packages (default).
#   core <binary> <version> <license-file>...
#                  Package a prebuilt core binary as xraywrt-core (spec 4.5)
#                  and update dist/SHA256SUMS-core.
#   test           Run Linux test suite (bash tests/run.sh) in native test container.
#   prepare        Ensure SDK archive, Docker image/volume, feeds (base, packages, luci) and deps.
#   clean          Clean build artifacts from dist/ and SDK package build directory.
#   shell          Launch an interactive shell inside the Linux SDK container.
#   help           Show this documentation.
#
# Options:
#   --rebuild      Force rebuilding the Docker build image.
#   -j<N>          Set parallelism for make (defaults to sane 4 jobs).
#   -v, --verbose  Verbose output (make V=s).
#

set -euo pipefail

# SDK metadata
# shellcheck disable=SC2034
SDK_TARGET="x86"
# shellcheck disable=SC2034
SDK_SUBTARGET="64"
# shellcheck disable=SC2034
SDK_ARCH="x86-64"
SDK_VERSION="25.12.6"
SDK_GCC="14.3.0"
# shellcheck disable=SC2034
SDK_ARCHIVE_SIZE=285832189
SDK_SHA256="1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc"
PKG_EXT="apk"
SDK_DIR_NAME="openwrt-sdk-${SDK_VERSION}-x86-64_gcc-${SDK_GCC}_musl.Linux-x86_64"
SDK_ARCHIVE_NAME="openwrt-sdk-${SDK_VERSION}-x86-64.tar.zst"
SDK_DOWNLOAD_URL="https://downloads.openwrt.org/releases/${SDK_VERSION}/targets/x86/64/${SDK_DIR_NAME}.tar.zst"

# Docker settings
DOCKER_IMAGE="${XRAYWRT_SDK_IMAGE:-xraywrt-sdk:${SDK_VERSION}}"
DOCKER_VOLUME="${XRAYWRT_SDK_VOLUME:-xraywrt-sdk-${SDK_VERSION}}"
TEST_IMAGE="${XRAYWRT_TEST_IMAGE:-xraywrt-test:local}"
CONTAINER_SDK_ROOT="/sdk"
CONTAINER_SDK_DIR="${CONTAINER_SDK_ROOT}/${SDK_DIR_NAME}"

# Path discovery
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK_LOCAL_DIR="${REPO_ROOT}/.sdk"
DIST_DIR="${REPO_ROOT}/dist"

# Default runtime options
COMMAND="build"
CORE_ARGS=()
# xraywrt-core apk architectures (spec 4.5): the same static binary for every
# aarch64 package architecture; CORE_ARCH=x86_64 is for the VM only.
CORE_ARCH="${CORE_ARCH:-aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76}"
REBUILD_IMAGE=0
VERBOSE=0
JOBS="${JOBS:-4}"

log_info() {
	printf '==> [build-sdk] %s\n' "$*"
}

log_warn() {
	printf '==> [build-sdk:WARN] %s\n' "$*" >&2
}

log_err() {
	printf '==> [build-sdk:ERROR] %s\n' "$*" >&2
}

compute_sha256() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		log_err "Neither sha256sum nor shasum is available to calculate SHA256."
		exit 1
	fi
}

verify_or_download_archive() {
	mkdir -p "${SDK_LOCAL_DIR}"
	local candidate=""
	local target="${SDK_LOCAL_DIR}/${SDK_ARCHIVE_NAME}"

	if [[ -f "$target" ]]; then
		candidate="$target"
	elif [[ -f "${SDK_LOCAL_DIR}/${SDK_DIR_NAME}.tar.zst" ]]; then
		candidate="${SDK_LOCAL_DIR}/${SDK_DIR_NAME}.tar.zst"
	fi

	if [[ -n "$candidate" ]]; then
		log_info "Verifying existing SDK archive: ${candidate}"
		local hash
		hash="$(compute_sha256 "$candidate")"
		if [[ "$hash" == "$SDK_SHA256" ]]; then
			log_info "SHA256 verified (${hash})."
			if [[ "$candidate" != "$target" ]]; then
				cp -p "$candidate" "$target"
			fi
			return 0
		else
			log_warn "Checksum mismatch for ${candidate}: expected ${SDK_SHA256}, got ${hash}. Re-downloading..."
		fi
	fi

	log_info "Downloading official OpenWrt ${SDK_VERSION} x86/64 SDK..."
	log_info "URL: ${SDK_DOWNLOAD_URL}"
	local tmp_file="${target}.tmp.$$"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL -o "$tmp_file" "$SDK_DOWNLOAD_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$tmp_file" "$SDK_DOWNLOAD_URL"
	else
		log_err "Neither curl nor wget available to download SDK archive."
		exit 1
	fi

	local dl_hash
	dl_hash="$(compute_sha256 "$tmp_file")"
	if [[ "$dl_hash" != "$SDK_SHA256" ]]; then
		rm -f "$tmp_file"
		log_err "Downloaded archive checksum mismatch: expected ${SDK_SHA256}, got ${dl_hash}"
		exit 1
	fi

	mv "$tmp_file" "$target"
	log_info "SDK archive downloaded and verified successfully: ${target}"
}

ensure_docker_image() {
	if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1 || [[ "$REBUILD_IMAGE" -eq 1 ]]; then
		log_info "Building Linux SDK Docker image (${DOCKER_IMAGE})..."
		local dockerfile="${REPO_ROOT}/Dockerfile.sdk"
		if [[ ! -f "$dockerfile" ]]; then
			dockerfile="${SCRIPT_DIR}/Dockerfile.sdk"
		fi
		if [[ ! -f "$dockerfile" ]]; then
			log_err "Dockerfile.sdk not found at ${dockerfile}"
			exit 1
		fi
		docker build --platform linux/amd64 -f "$dockerfile" -t "${DOCKER_IMAGE}" "${REPO_ROOT}"
		log_info "Docker image ${DOCKER_IMAGE} ready."
	fi
}

ensure_test_image() {
	if ! docker image inspect "${TEST_IMAGE}" >/dev/null 2>&1 || [[ "$REBUILD_IMAGE" -eq 1 ]]; then
		log_info "Building native test runner Docker image (${TEST_IMAGE})..."
		local dockerfile="${REPO_ROOT}/Dockerfile.test"
		if [[ ! -f "$dockerfile" ]]; then
			log_err "Dockerfile.test not found at ${dockerfile}"
			exit 1
		fi
		docker build -f "$dockerfile" -t "${TEST_IMAGE}" "${REPO_ROOT}"
		log_info "Test Docker image ${TEST_IMAGE} ready."
	fi
}

ensure_docker_volume() {
	if ! docker volume inspect "${DOCKER_VOLUME}" >/dev/null 2>&1; then
		log_info "Creating persistent Docker volume for Linux SDK: ${DOCKER_VOLUME}..."
		docker volume create "${DOCKER_VOLUME}" >/dev/null
	fi
}

run_in_docker_container() {
	local cmd="$1"
	shift
	ensure_docker_image
	ensure_docker_volume

	mkdir -p "${DIST_DIR}"

	docker run --rm --platform linux/amd64 \
		-v "${DOCKER_VOLUME}:${CONTAINER_SDK_ROOT}" \
		-v "${REPO_ROOT}:/workspace:ro" \
		-v "${DIST_DIR}:/workspace/dist" \
		-w /workspace \
		-e "FORCE_UNSAFE_CONFIGURE=1" \
		-e "JOBS=${JOBS}" \
		-e "VERBOSE=${VERBOSE}" \
		-e "SDK_DIR_NAME=${SDK_DIR_NAME}" \
		-e "SDK_ARCHIVE_NAME=${SDK_ARCHIVE_NAME}" \
		-e "PKG_EXT=${PKG_EXT}" \
		-e "CONTAINER_SDK_DIR=${CONTAINER_SDK_DIR}" \
		"${DOCKER_IMAGE}" \
		bash -c "$cmd" "$@"
}

prepare_sdk_environment_docker() {
	verify_or_download_archive
	ensure_docker_image
	ensure_docker_volume

	log_info "Checking Linux SDK state in named volume '${DOCKER_VOLUME}'..."
	# shellcheck disable=SC2016
	run_in_docker_container '
		set -euo pipefail
		if [ ! -d "${CONTAINER_SDK_DIR}" ]; then
			echo "==> Extracting SDK archive to named volume..."
			tar -I zstd -xf "/workspace/.sdk/${SDK_ARCHIVE_NAME}" -C /sdk
			echo "==> Extraction complete."
		fi

		cd "${CONTAINER_SDK_DIR}"
		if [ ! -f "feeds/base.index" ] || [ ! -f "feeds/packages.index" ] || [ ! -f "feeds/luci.index" ]; then
			echo "==> Updating pinned feeds: base, packages, luci..."
			./scripts/feeds update base packages luci
		else
			echo "==> Pinned feeds base, packages, luci already initialized."
		fi

		echo "==> Installing host build prerequisite: luci-base..."
		# Clean up any previously linked runtime feed packages that introduce Kconfig cycles
		./scripts/feeds uninstall curl jq nftables 2>/dev/null || true
		rm -rf package/feeds/packages/curl package/feeds/packages/jq package/feeds/packages/nftables package/feeds/base/nftables 2>/dev/null || true
		./scripts/feeds install luci-base
		echo "==> SDK environment ready in volume."
	'
}

run_build_docker() {
	prepare_sdk_environment_docker

	log_info "Compiling XrayWRT packages with OpenWrt ${SDK_VERSION} SDK..."
	# shellcheck disable=SC2016
	run_in_docker_container '
		set -euo pipefail
		cd "${CONTAINER_SDK_DIR}"

		echo "==> Synchronizing package sources into SDK..."
		# The core recipe needs its build variables; only `core` builds it.
		rm -rf package/xraywrt-core
		mkdir -p package/luci-app-xraywrt/tools
		rsync -a --delete /workspace/Makefile package/luci-app-xraywrt/
		rsync -a --delete /workspace/tools/harden.sed package/luci-app-xraywrt/tools/
		if [ -d /workspace/rootfs ]; then
			rsync -a --delete /workspace/rootfs package/luci-app-xraywrt/
			# Ensure removed Ace assets do not persist in SDK build tree
			rm -rf package/luci-app-xraywrt/rootfs/www/luci-static/resources/xraywrt/ace.js \
			       package/luci-app-xraywrt/rootfs/www/luci-static/resources/view/xraywrt/ace
		fi
		if [ -d /workspace/po ]; then
			rsync -a --delete /workspace/po package/luci-app-xraywrt/
		else
			rm -rf package/luci-app-xraywrt/po
		fi

		echo "==> Generating minimal .config (no CONFIG_ALL)..."
		cat << "EOF" > .config
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL is not set
CONFIG_IN_SDK=y
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_BOARD="x86"
CONFIG_TARGET_SUBTARGET="64"
CONFIG_TARGET_ARCH_PACKAGES="x86_64"
CONFIG_PACKAGE_luci-app-xraywrt=m
CONFIG_PACKAGE_luci-i18n-xraywrt-ru=m
# CONFIG_LIBCURL_LDAP is not set
CONFIG_LIBCURL_LDAP=n
EOF
		# An interrupted metadata scan leaves an empty index that make treats as
		# up to date; drop it so the package rules are generated again.
		[ -s tmp/.packageinfo ] || rm -rf tmp
		make defconfig >/dev/null 2>&1 || true

		echo "==> Compiling host build dependencies (luci-base/host / po2lmo)..."
		make package/feeds/luci/luci-base/host/compile TOPDIR="$PWD" -j"$JOBS"
		if [ ! -x staging_dir/hostpkg/bin/po2lmo ] && [ ! -x staging_dir/host/bin/po2lmo ]; then
			echo "Error: Host tool po2lmo was not found after host compile" >&2
			exit 1
		fi

		echo "==> Direct building package/luci-app-xraywrt (jobs: $JOBS)..."
		make -C package/luci-app-xraywrt clean TOPDIR="$PWD"
		if [ "$VERBOSE" -eq 1 ]; then
			make -C package/luci-app-xraywrt compile TOPDIR="$PWD" V=s -j"$JOBS"
		else
			make -C package/luci-app-xraywrt compile TOPDIR="$PWD" -j"$JOBS"
		fi

		echo "==> Copying and asserting both XrayWRT ${PKG_EXT} packages..."
		mkdir -p /workspace/dist
		app_pkg="$(find bin/packages/ -type f -name "luci-app-xraywrt-*.apk" | head -n 1)"
		i18n_pkg="$(find bin/packages/ -type f -name "luci-i18n-xraywrt-ru-*.apk" | head -n 1)"

		if [ -z "$app_pkg" ] || [ ! -f "$app_pkg" ]; then
			echo "Error: luci-app-xraywrt ${PKG_EXT} package not found in bin/packages/" >&2
			exit 1
		fi
		if [ -z "$i18n_pkg" ] || [ ! -f "$i18n_pkg" ]; then
			echo "Error: luci-i18n-xraywrt-ru ${PKG_EXT} package not found in bin/packages/" >&2
			exit 1
		fi

		cp -f "$app_pkg" /workspace/dist/
		cp -f "$i18n_pkg" /workspace/dist/
		echo "Copied: $(basename "$app_pkg") -> dist/"
		echo "Copied: $(basename "$i18n_pkg") -> dist/"
	'

	log_info "Build successful! Verified ${PKG_EXT} packages in dist/:"
	ls -l "${DIST_DIR}"/luci-app-xraywrt-*.apk "${DIST_DIR}"/luci-i18n-xraywrt-ru-*.apk
}

# core <binary> <version> <license-file>...: the prebuilt binary and the
# licenses are staged in .build/core-input (inside the read-only /workspace).
run_build_core_docker() {
	if [[ "${#CORE_ARGS[@]}" -lt 3 || ! -f "${CORE_ARGS[0]}" ]]; then
		log_err "usage: ./tools/build-sdk.sh core <binary> <version> <license-file>..."
		exit 1
	fi
	local input="${REPO_ROOT}/.build/core-input" version="${CORE_ARGS[1]}" file="" arch="" apk=""
	local -a archs=()
	read -r -a archs <<<"$CORE_ARCH"
	if [[ ! "$version" =~ ^[0-9][A-Za-z0-9._+~]*$ ]]; then
		log_err "invalid core version: ${version}"
		exit 1
	fi
	[[ "${#archs[@]}" -gt 0 ]] || { log_err "CORE_ARCH is empty"; exit 1; }
	for arch in "${archs[@]}"; do
		if [[ ! "$arch" =~ ^[a-z0-9_-]+$ ]]; then
			log_err "invalid CORE_ARCH: ${arch}"
			exit 1
		fi
	done
	rm -rf "$input"
	mkdir -p "$input/licenses"
	cp "${CORE_ARGS[0]}" "$input/xray"
	for file in "${CORE_ARGS[@]:2}"; do
		[[ -f "$file" ]] || { log_err "no license file: ${file}"; exit 1; }
		cp "$file" "$input/licenses/"
	done
	prepare_sdk_environment_docker

	log_info "Packaging xraywrt-core ${version} with OpenWrt ${SDK_VERSION} SDK..."
	# shellcheck disable=SC2016
	run_in_docker_container '
		set -euo pipefail
		cd "${CONTAINER_SDK_DIR}"
		rm -rf package/xraywrt-core
		mkdir -p package/xraywrt-core
		rsync -a /workspace/core/Makefile package/xraywrt-core/
		cat << "EOF" > .config
CONFIG_IN_SDK=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_BOARD="x86"
CONFIG_TARGET_SUBTARGET="64"
CONFIG_TARGET_ARCH_PACKAGES="x86_64"
CONFIG_PACKAGE_xraywrt-core=m
EOF
		[ -s tmp/.packageinfo ] || rm -rf tmp
		make defconfig >/dev/null 2>&1 || true
		licenses="$(echo /workspace/.build/core-input/licenses/*)"
		for arch in "$@"; do
			find bin/packages/ -type f -name "xraywrt-core-$0-r*.apk" -delete 2>/dev/null || true
			make -C package/xraywrt-core clean TOPDIR="$PWD" CORE_VERSION="$0" CORE_ARCH="$arch"
			make -C package/xraywrt-core compile TOPDIR="$PWD" CORE_VERSION="$0" CORE_ARCH="$arch" \
				CORE_BIN=/workspace/.build/core-input/xray CORE_LICENSES="$licenses"
			pkg="$(find bin/packages/ -type f -name "xraywrt-core-$0-r*.apk" | head -n 1)"
			[ -n "$pkg" ] || { echo "Error: xraywrt-core package for $arch not found in bin/packages/" >&2; exit 1; }
			version="${pkg##*/xraywrt-core-}"
			version="${version%.apk}"
			cp -f "$pkg" "/workspace/dist/xraywrt-core_${version}_${arch}.apk"
			echo "Copied: $(basename "$pkg") -> dist/xraywrt-core_${version}_${arch}.apk"
		done
		rm -rf package/xraywrt-core
	' "$version" "${archs[@]}"

	for arch in "${archs[@]}"; do
		apk=""
		for file in "${DIST_DIR}/xraywrt-core_${version}"-r*_"${arch}.apk"; do
			[[ -f "$file" ]] && { [[ -z "$apk" ]] || [[ "$file" -nt "$apk" ]]; } && apk="$file"
		done
		[[ -n "$apk" ]] || { log_err "no dist/xraywrt-core_${version}-r<N>_${arch}.apk after the build"; exit 1; }
		core_sums_update "${apk##*/}"
	done
}

# SHA256SUMS-core (spec 4.5): one sha256sum line per architecture in dist/;
# a rebuild replaces its architecture's line. The owner uploads it with the
# core packages to the release.
core_sums_update() {
	local name="$1" sums="${DIST_DIR}/SHA256SUMS-core" arch=""

	# Versions have no '_': the architecture follows the second '_'.
	arch="${name#xraywrt-core_}"
	arch="${arch#*_}"
	{
		[[ ! -f "$sums" ]] || awk -v a="$arch" '{ f = $2; sub(/^\*/, "", f); r = substr(f, 14) }
			!(index(f, "xraywrt-core_") == 1 && sub(/^[^_]*_/, "", r) && r == a)' "$sums"
		(cd "$DIST_DIR" && sha256sum "$name")
	} >"$sums.new"
	mv -f "$sums.new" "$sums"
	log_info "dist/SHA256SUMS-core updated: upload it with ${name} to the release"
}

run_test() {
	ensure_test_image
	log_info "Running test suite (bash tests/run.sh) in native container (${TEST_IMAGE})..."
	docker run --rm \
		-v "${REPO_ROOT}:/workspace:ro" \
		-w /workspace \
		"${TEST_IMAGE}" \
		bash tests/run.sh "$@"
}

run_clean() {
	log_info "Cleaning dist/ directory..."
	rm -rf "${DIST_DIR}"/*.apk
	if docker volume inspect "${DOCKER_VOLUME}" >/dev/null 2>&1; then
		log_info "Cleaning package build inside Docker volume '${DOCKER_VOLUME}'..."
		# shellcheck disable=SC2016
		run_in_docker_container '
			if [ -d "${CONTAINER_SDK_DIR}" ]; then
				cd "${CONTAINER_SDK_DIR}"
				make -C package/luci-app-xraywrt clean TOPDIR="$PWD" 2>/dev/null || true
				rm -rf bin/packages/*/*luci*xraywrt* 2>/dev/null || true
			fi
		'
	fi
	log_info "Clean completed."
}

show_help() {
	cat << EOF
XrayWRT SDK Build Tool
Official OpenWrt x86/64 SDK package builder (25.12.6 apk) and Linux test runner.

Usage:
  ./tools/build-sdk.sh [command] [options]

Commands:
  build          Build luci-app-xraywrt and luci-i18n-xraywrt-ru packages (default)
  core <binary> <version> <license-file>...
                 Package a prebuilt core binary as xraywrt-core for each apk
                 architecture in CORE_ARCH (default: aarch64_generic
                 aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76;
                 x86_64 only for the VM); dist/ gets
                 xraywrt-core_<version>-r1_<arch>.apk per architecture and
                 their lines in dist/SHA256SUMS-core (upload all to the release)
  test           Run full Linux test suite (bash tests/run.sh) in native test container
  prepare        Ensure archive, Docker image, Docker volume, and feeds cache
  clean          Remove built packages from dist/ and clean package build directory
  shell          Open an interactive bash shell in the Linux SDK container
  help, -h       Show this help message

Options:
  --rebuild      Force rebuilding the Docker build image
  -j<N>          Set number of parallel jobs for compilation (default: 4)
  -v, --verbose  Verbose build output (make V=s)

Environment Variables:
  XRAYWRT_SDK_IMAGE    Docker image name (default: xraywrt-sdk:25.12.6)
  XRAYWRT_SDK_VOLUME   Docker volume name (default: xraywrt-sdk-25.12.6)
  XRAYWRT_TEST_IMAGE   Test runner Docker image name (default: xraywrt-test:local)

Architecture & Volume Notes:
  - Architecture caveat: Official OpenWrt SDKs only distribute Linux ELF binaries;
    native macOS is unsupported upstream. Furthermore, macOS APFS is case-insensitive, which
    causes OpenWrt buildroot failures on host bind mounts.
  - This script extracts and builds the SDK inside a persistent named Docker volume
    ('${DOCKER_VOLUME}' mounted at /sdk), providing native case-sensitive Linux filesystem semantics.
  - Feeds and host prerequisite isolation: For noarch packages, only luci-base/host
    is compiled (providing po2lmo). Runtime dependencies (curl, ucode, ucode-mod-fs, nftables) remain in
    package metadata without installing feed directories, preventing Kconfig dependency loops.
  - Direct package compile: Compiles directly via 'make -C package/luci-app-xraywrt' after
    validating host target tools, avoiding unnecessary target C cross-compilation.
  - Test mode executes natively via multi-arch Alpine container ('${TEST_IMAGE}'), ensuring
    tools like shellcheck and node run without emulation issues or fake stubs.
  - Source files (Makefile, rootfs, po) are synchronized via rsync into the SDK package
    directory, removing obsolete Ace assets and avoiding recursive symlinks.
EOF
}

# Parse command line
while [[ $# -gt 0 ]]; do
	case "$1" in
		build|test|prepare|clean|shell|help|core)
			COMMAND="$1"
			shift
			;;
		--rebuild)
			REBUILD_IMAGE=1
			shift
			;;
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		-j*)
			JOBS="${1#-j}"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			if [[ "$COMMAND" == core ]]; then
				CORE_ARGS+=("$1")
				shift
				continue
			fi
			log_err "Unknown argument: $1"
			show_help
			exit 1
			;;
	esac
done

case "$COMMAND" in
	help)
		show_help
		;;
	prepare)
		prepare_sdk_environment_docker
		;;
	build)
		run_build_docker
		;;
	core)
		run_build_core_docker
		;;
	test)
		run_test "$@"
		;;
	clean)
		run_clean
		;;
	shell)
		ensure_docker_image
		ensure_docker_volume
		log_info "Launching interactive shell in SDK container..."
		docker run -it --rm --platform linux/amd64 \
			-v "${DOCKER_VOLUME}:${CONTAINER_SDK_ROOT}" \
			-v "${REPO_ROOT}:/workspace:ro" \
			-v "${DIST_DIR}:/workspace/dist" \
			-w /workspace \
			-e "FORCE_UNSAFE_CONFIGURE=1" \
			"${DOCKER_IMAGE}" \
			bash
		;;
esac
