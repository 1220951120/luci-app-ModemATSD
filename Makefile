# Copyright (C) Manper

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ModemATSD
PKG_VERSION:=2.9
PKG_RELEASE:=40

LUCI_TITLE:=LuCI for ModemATSD
LUCI_DEPENDS:=@(aarch64) +luci-compat +python3 +python3-requests +bash +curl +flock
LUCI_PKGARCH:=aarch64_cortex-a53

define Package/$(PKG_NAME)/conffiles
/etc/config/modem-AK68
/usr/bin/smstrun-title-AK68.conf
endef

include $(TOPDIR)/feeds/luci/luci.mk

# $(eval $(call BuildPackage,luci-app-ModemATSD))
