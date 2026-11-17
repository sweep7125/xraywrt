# shellcheck shell=bash disable=SC2034
# Guest release table shared by start.sh and the harness test.
# Only OpenWrt 25.12 (ROUTER_OPENWRT=25.12, the default) is supported.

router_select_release() {
  case "${ROUTER_OPENWRT:-25.12}" in
  25.12)
    OPENWRT_VERSION=25.12.6
    KERNEL_SHA256=8f70595f3a6eec3112e007450a1a600153904deffa52ab368712342583cb387c
    ROOTFS_SHA256=8c243392d09b960a9f0edbfd996153bec213435b0034e6b2db9437115c5178ec
    DEFAULT_IMAGE_NAME=xraywrt-openwrt-test:latest
    ;;
  *)
    echo "Error: unsupported ROUTER_OPENWRT=${ROUTER_OPENWRT} (only 25.12 is supported)" >&2
    return 1
    ;;
  esac
  KERNEL_NAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-kernel.bin"
  ROOTFS_NAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-rootfs.img.gz"
  BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64"
}
