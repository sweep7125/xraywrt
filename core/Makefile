# xraywrt-core (spec 4.5): the owner's prebuilt core binary as the XrayWRT
# core /opt/xraywrt/bin/xray, plus its licenses. The source repository is private:
# nothing is compiled. Build with the SDK of the router's architecture:
#   ./tools/build-sdk.sh core <binary> <version> <license-file>...
# or in an SDK tree:
#   make package/xraywrt-core/compile CORE_BIN=<binary> CORE_VERSION=<version> CORE_LICENSES="<files>"
# One static aarch64 binary is packed once per apk architecture (CORE_ARCH,
# e.g. aarch64_cortex-a53): apk itself refuses a package of another
# architecture, while a refusing pre-install would be ignored (spec 4.5).

include $(TOPDIR)/rules.mk

PKG_NAME:=xraywrt-core
PKG_VERSION:=$(CORE_VERSION)
PKG_RELEASE:=2
PKG_LICENSE:=MPL-2.0
PKG_MAINTAINER:=ristavor <90447432+ristavor@users.noreply.github.com>
CORE_ARCH ?= aarch64_generic

include $(INCLUDE_DIR)/package.mk

# A prebuilt binary of the target architecture: the SDK must not strip it.
STRIP:=:
RSTRIP:=:

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=XrayWRT core ($(CORE_ARCH))
	PKGARCH:=$(CORE_ARCH)
endef

define Package/$(PKG_NAME)/description
	Prebuilt XrayWRT core, installed as /opt/xraywrt/bin/xray.
endef

define Build/Prepare
	@[ -n "$(CORE_VERSION)" ] || { echo "$(PKG_NAME): set CORE_VERSION" >&2; exit 1; }
	@[ -f "$(CORE_BIN)" ] || { echo "$(PKG_NAME): set CORE_BIN to the prebuilt core binary" >&2; exit 1; }
	@[ -n "$(CORE_LICENSES)" ] || { echo "$(PKG_NAME): set CORE_LICENSES to the license files" >&2; exit 1; }
	@for f in $(CORE_LICENSES); do [ -f "$$$$f" ] || { echo "$(PKG_NAME): no license file $$$$f" >&2; exit 1; }; done
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/opt/xraywrt/bin
	$(INSTALL_BIN) $(CORE_BIN) $(1)/opt/xraywrt/bin/xray
	$(INSTALL_DIR) $(1)/usr/share/licenses/xraywrt-core
	$(INSTALL_DATA) $(CORE_LICENSES) $(1)/usr/share/licenses/xraywrt-core/
endef

# A manual "apk add" would leave the running service on the replaced binary.
# Restart only if, once apk has exited, the running core (xray.pid is the core's pid)
# still executes the replaced file. A restart by luci-app-xraywrt's postinst
# after this hook leaves a core on the new file: nothing is repeated. The app's
# own core update holds core.flock and restarts by itself. The job is detached
# with every fd closed so that apk does not wait for it.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	(
		i=0; while pidof apk >/dev/null && [ $$i -lt 60 ]; do sleep 1; i=$$((i + 1)); done; sleep 2
		pid="$$(cat /var/run/xraywrt/xray.pid 2>/dev/null)"
		case "$$(readlink "/proc/$$pid/exe" 2>/dev/null)" in
		*"/xray (deleted)") ;;
		*) exit 0 ;;
		esac
		flock -n /var/run/xraywrt/core.flock true 2>/dev/null && /etc/init.d/xraywrt restart
	) </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- &
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
