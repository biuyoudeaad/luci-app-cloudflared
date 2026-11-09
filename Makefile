include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cloudflared
PKG_VERSION:=1.2.0
PKG_RELEASE:=94

LUCI_TITLE:=LuCI support for Cloudflare Tunnel
LUCI_DEPENDS:=+curl +ca-bundle +luci-base +luci-lua-runtime
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/cloudflared
endef

# call BuildPackage - OpenWrt buildroot signature
