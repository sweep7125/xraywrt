# Copyright 2026

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xraywrt
PKG_VERSION:=0.1.10
PKG_RELEASE:=1
PKG_MAINTAINER:=ristavor <90447432+ristavor@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_CONFIG_BACKUP_FILE:=/tmp/$(PKG_NAME).config.json.bak
PKG_POLICY_LIST_BACKUP_DIR:=/tmp/$(PKG_NAME).policy-lists.bak
XRAYWRT_LISTS:=always_proxy_dst always_proxy_src direct_dst direct_src rules
# Spec 3: the same list as CONFLICT_PACKAGES in constants.sh (test_pkg).
XRAYWRT_CONFLICTS:=luci-app-mihowrt xray-core luci-app-xray podkop luci-app-podkop luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy luci-app-nikki nikki luci-app-ssclash luci-app-v2raya luci-app-mihomo https-dns-proxy adguardhome

LUCI_TITLE:=LuCI Support for XrayWRT
LUCI_DEPENDS:=+luci-base +cgi-io +ucode +ucode-mod-fs +nftables +kmod-nft-tproxy +curl +ca-bundle
LUCI_PKGARCH:=all

PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=$(LUCI_TITLE)
	DEPENDS:=$(LUCI_DEPENDS)
	# Spec 3: the SDK 25.12 apk build drops the field, preinst refuses instead.
	CONFLICTS:=$(XRAYWRT_CONFLICTS)
	PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/$(PKG_NAME)/description
	LuCI interface and nft policy layer for XrayWRT on OpenWrt 25.12 (apk).
endef

define Build/Prepare
endef

define Build/Compile
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	po2lmo ./po/ru/xraywrt.po $(PKG_BUILD_DIR)/xraywrt.ru.lmo
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/xraywrt
/opt/xraywrt/config.json
$(subst $(space),$(newline),$(addprefix /opt/xraywrt/lst/,$(addsuffix .txt,$(XRAYWRT_LISTS))))
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/xraywrt $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./rootfs/etc/config/xraywrt $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/iface/90-xraywrt $(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/etc/xraywrt

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./rootfs/usr/bin/xraywrt $(1)/usr/bin/
	$(INSTALL_BIN) ./rootfs/usr/bin/xraywrt-read $(1)/usr/bin/
	$(INSTALL_BIN) ./rootfs/usr/bin/xraywrt-json $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/lib/xraywrt
	$(CP) ./rootfs/usr/lib/xraywrt/* $(1)/usr/lib/xraywrt/
	sed -i -f ./tools/harden.sed $(1)/usr/bin/xraywrt $(1)/usr/bin/xraywrt-read $(1)/usr/lib/xraywrt/helpers.sh $(1)/etc/init.d/xraywrt
	sed -i 's/^PKG_VERSION=.*/PKG_VERSION="$(PKG_VERSION)"/' $(1)/usr/lib/xraywrt/constants.sh

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./rootfs/usr/share/luci/menu.d/luci-app-xraywrt.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./rootfs/usr/share/rpcd/acl.d/luci-app-xraywrt.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/xraywrt
	$(CP) ./rootfs/www/luci-static/resources/view/xraywrt/* $(1)/www/luci-static/resources/view/xraywrt/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/xraywrt
	$(CP) ./rootfs/www/luci-static/resources/xraywrt/* $(1)/www/luci-static/resources/xraywrt/

	$(INSTALL_DIR) $(1)/opt/xraywrt/bin
	$(INSTALL_DIR) $(1)/opt/xraywrt/lst
	$(INSTALL_DATA) ./rootfs/opt/xraywrt/config.json $(1)/opt/xraywrt/
	for list in $(XRAYWRT_LISTS); do \
		$(INSTALL_DATA) ./rootfs/opt/xraywrt/lst/$$$$list.txt $(1)/opt/xraywrt/lst/ || exit 1; \
	done

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./rootfs/lib/upgrade/keep.d/xraywrt $(1)/lib/upgrade/keep.d/

ifdef CONFIG_USE_APK
	$(INSTALL_DIR) $(1)/etc/apk/protected_paths.d
	$(INSTALL_DATA) ./rootfs/etc/apk/protected_paths.d/xraywrt.list $(1)/etc/apk/protected_paths.d/
endif
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	# Spec 3: refuse next to another proxy stack. Read the database directly,
	# apk holds its lock while running this hook.
	installed="$$(awk '/^P:/ { print substr($$0, 3) }' /lib/apk/db/installed 2>/dev/null)"
	for package in $(XRAYWRT_CONFLICTS); do
		if printf '%s\n' "$$installed" | grep -qxF "$$package"; then
			echo "$(PKG_NAME): conflicts with installed package $$package; remove it first" >&2
			exit 1
		fi
	done
	# default_postinst may stop the service (skipped start below), so
	# record the running state now; the new constants.sh is not installed yet.
	rm -f /tmp/luci-app-xraywrt.was-running
	if pgrep -f "^(/bin/a?sh )?/usr/bin/xraywrt run-service$$" >/dev/null 2>&1; then
		: >/tmp/luci-app-xraywrt.was-running
	fi
	backup_xraywrt_file() {
		src="$$1"
		backup_file="$$2"
		[ -f "$$src" ] || return 0
		mkdir -p "$${backup_file%/*}" || return 1
		cp -p "$$src" "$$backup_file" || return 1
	}
	# apk runs default_postinst, which calls "/etc/init.d/xraywrt start",
	# before our postinst: skip that start, postinst decides.
	: >/tmp/xraywrt.skip-start
	rm -f $(PKG_CONFIG_BACKUP_FILE) || exit 1
	rm -rf $(PKG_POLICY_LIST_BACKUP_DIR) || exit 1
	backup_xraywrt_file /opt/xraywrt/config.json $(PKG_CONFIG_BACKUP_FILE) || exit 1
	for list in $(XRAYWRT_LISTS); do
		backup_xraywrt_file /opt/xraywrt/lst/$$list.txt $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt || exit 1
	done
}
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	. /usr/lib/xraywrt/constants.sh
	restore_xraywrt_backup_file() {
		backup_file="$$1"
		target_file="$$2"
		[ -f "$$backup_file" ] || return 0
		if [ ! -f "$$target_file" ] || ! cmp -s "$$backup_file" "$$target_file"; then
			mkdir -p "$${target_file%/*}" 2>/dev/null || return 1
			mv "$$backup_file" "$$target_file" || return 1
		else
			rm -f "$$backup_file" || return 1
		fi
	}
	restore_xraywrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/xraywrt/config.json || exit 1
	for list in $(XRAYWRT_LISTS); do
		restore_xraywrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt /opt/xraywrt/lst/$$list.txt || exit 1
	done
	rmdir $(PKG_POLICY_LIST_BACKUP_DIR) 2>/dev/null || true
	# default_postinst's start already consumed the skip marker; drop a leftover.
	rm -f /tmp/xraywrt.skip-start
	# An upgrade leaves the old service running from memory: stop it so
	# it removes its own state, migrate, then start the new version.
	rc=0
	was_running=0
	[ -e /tmp/luci-app-xraywrt.was-running ] && was_running=1
	pgrep -f "$$SUPERVISOR_PATTERN" >/dev/null 2>&1 && was_running=1
	rm -f /tmp/luci-app-xraywrt.was-running
	[ "$$was_running" = 1 ] && /etc/init.d/xraywrt stop >/dev/null 2>&1
	[ -x /usr/bin/xraywrt ] && /usr/bin/xraywrt migrate >/dev/null 2>&1 || rc=1
	# apk never merges the shipped default; migration.sh owns new options.
	rm -f /etc/config/xraywrt.apk-new
	[ "$$was_running" != 1 ] || /etc/init.d/xraywrt start >/dev/null 2>&1
	/etc/init.d/rpcd reload
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	exit $$rc
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	[ -x /usr/bin/xraywrt ] && /usr/bin/xraywrt uninstall >/dev/null 2>&1 || true
	fw4_include="$$(. /usr/lib/xraywrt/constants.sh 2>/dev/null && printf %s "$$FW4_INPUT_INCLUDE")"
	[ -n "$$fw4_include" ] || fw4_include=/usr/share/nftables.d/chain-pre/input/30-xraywrt.nft
	if [ -e "$$fw4_include" ] && rm -f "$$fw4_include"; then
		fw4 reload 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || true
	fi
	# apk deletes package-owned files on removal; park the user's copies for postrm.
	# cp, not mv: if the removal aborts, the originals are still in place.
	[ ! -f /opt/xraywrt/config.json ] || cp -p /opt/xraywrt/config.json /opt/xraywrt/config.json.keep || true
	for list in $(XRAYWRT_LISTS); do
		[ ! -f /opt/xraywrt/lst/$$list.txt ] || cp -p /opt/xraywrt/lst/$$list.txt /opt/xraywrt/lst/$$list.txt.keep || true
	done
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	rm -rf /tmp/xraywrt /var/run/xraywrt
	[ ! -f /opt/xraywrt/config.json.keep ] || mv -f /opt/xraywrt/config.json.keep /opt/xraywrt/config.json
	for list in $(XRAYWRT_LISTS); do
		[ ! -f /opt/xraywrt/lst/$$list.txt.keep ] || mv -f /opt/xraywrt/lst/$$list.txt.keep /opt/xraywrt/lst/$$list.txt
	done
	rmdir /opt/xraywrt/bin /opt/xraywrt/lst /opt/xraywrt /etc/xraywrt 2>/dev/null || true
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

define Package/luci-i18n-xraywrt-ru
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=$(PKG_NAME) - Russian translation
	DEPENDS:=$(PKG_NAME)
	PKGARCH:=all
endef

define Package/luci-i18n-xraywrt-ru/description
	Russian translation for $(PKG_NAME).
endef

define Package/luci-i18n-xraywrt-ru/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/xraywrt.ru.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	( \
		echo '#!/bin/sh'; \
		echo 'uci -q get luci.languages.ru >/dev/null || {'; \
		echo '	uci set luci.languages.ru='\''русский (Russian)'\'';'; \
		echo '	uci commit luci'; \
		echo '}'; \
		echo 'exit 0'; \
	) > $(1)/etc/uci-defaults/luci-i18n-xraywrt-ru
	chmod 0755 $(1)/etc/uci-defaults/luci-i18n-xraywrt-ru
endef

define Package/luci-i18n-xraywrt-ru/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	uci -q get luci.languages.ru >/dev/null || {
		uci set luci.languages.ru='русский (Russian)'
		uci commit luci
	}
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,luci-i18n-xraywrt-ru))
