include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cloudflared
PKG_VERSION:=1.2.0
PKG_RELEASE:=144

LUCI_TITLE:=LuCI support for Cloudflare Tunnel
LUCI_DEPENDS:=+curl +ca-bundle +luci-base +luci-lua-runtime
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/cloudflared
endef

define Package/$(PKG_NAME)/postinst
[ -n "$${IPKG_INSTROOT}" ] && exit 0

[ -f /lib/functions.sh ] && . /lib/functions.sh
if command -v group_add_next >/dev/null 2>&1; then
	gid="$$(group_add_next cloudflared 2>/dev/null)"
	user_exists cloudflared 2>/dev/null || \
		user_add cloudflared "" "$$gid" "cloudflared" "/tmp/cloudflared" "/bin/false" 2>/dev/null
	group_add_user cloudflared cloudflared 2>/dev/null
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null

# Fresh installs start with autostart disabled. Upgrades must keep whatever
# the user selected with the "Enable on boot" switch.
if [ "$${PKG_UPGRADE:-0}" != "1" ]; then
	/etc/init.d/cloudflared disable 2>/dev/null || true
	/etc/init.d/cloudflared stop 2>/dev/null || true
fi

exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
