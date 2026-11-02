#!/bin/bash

# Default LAN address. Guarded because an upstream path or content change would
# otherwise leave the sed silently doing nothing.
cg=package/base-files/files/bin/config_generate
if ! grep -q '192\.168\.1\.1' "$cg" 2>/dev/null; then
	echo "::warning::no 192.168.1.1 in $cg, LAN default address was not changed to 192.168.0.1"
else
	sed -i 's/192\.168\.1\.1/192.168.0.1/g' "$cg"
fi

# Give root bash as its login shell. This and CONFIG_PACKAGE_bash=y in .config
# move in lockstep -- editing passwd without installing bash breaks SSH login.
pw=package/base-files/files/etc/passwd
if ! grep -q '^CONFIG_PACKAGE_bash=y$' .config 2>/dev/null; then
	echo "::warning::.config lacks CONFIG_PACKAGE_bash=y, leaving root shell alone (bash would break SSH login)"
elif ! grep -q '/bin/ash' "$pw" 2>/dev/null; then
	echo "::warning::no /bin/ash in $pw, root shell was not switched to bash"
else
	sed -i 's|/bin/ash|/bin/bash|' "$pw"
fi

# Partition alignment. x86's Build/grub-*-img passes the granularity as
# gen_image_generic.sh's 6th argument, which lands at ptgen -l (KB). 4096K puts
# both partition starts on an SSD/eMMC erase-block boundary; upstream uses 256K.
#
# Only the argument alone on its own line is rewritten, and only when it is
# unique. A blanket s/256/4096/g would also catch any other 256 upstream later
# adds -- a partition size, a model name, any constant -- with no error.
img=target/linux/x86/image/Makefile
n256=0
[ -f "$img" ] && n256=$(grep -cE '^[[:space:]]*256$' "$img")
if [ ! -f "$img" ]; then
	echo "::warning::$img does not exist (this repo builds x86 only), partition alignment left at the upstream default"
elif [ "$n256" -eq 1 ] && grep -q 'gen_image_generic.sh' "$img"; then
	sed -i -E 's/^([[:space:]]*)256$/\14096/' "$img"
elif grep -qE '^[[:space:]]*4096$' "$img"; then
	: # already 4096K; idempotent on re-run
else
	echo "::warning::$img has no unique bare 256 alignment argument (found $n256), alignment left unchanged -- recheck upstream Build/grub-*-img"
fi

# luci-app-qbittorrent's LUCI_DEPENDS:=+qbittorrent forms a recursive dependency
# at kconfig time and breaks make defconfig whether or not it is selected, so
# the package is deleted outright. Warn if it is already gone rather than
# silently doing nothing -- upstream may have fixed it or renamed the directory.
qb_found=0
for d in package/feeds/luci/luci-app-qbittorrent feeds/luci/applications/luci-app-qbittorrent; do
	[ -e "$d" ] && { rm -rf "$d"; qb_found=1; }
done
[ "$qb_found" -eq 1 ] || echo "::warning::luci-app-qbittorrent not found, the recursive-dependency workaround is stale -- check whether upstream fixed it"

# This repo's root is the package itself, but OpenWrt's feed indexer only
# recognises <feed>/<pkg>/Makefile, so src-git on it breaks index construction.
# Clone it as an ordinary package instead. (Zerogiven's package-feed repo is a
# prebuilt-apk binary source, not a source feed.)
git clone --depth=1 https://github.com/Zerogiven-OpenWRT-Packages/luci-app-podman \
	package/luci-app-podman

# Keep only the footstrap theme. luci-light names luci-theme-bootstrap as a hard
# dependency, so unchecking it in .config is selected straight back by make
# defconfig and the collection's own dependency has to change. Edit the real
# file under feeds/; package/feeds/luci/luci-light is a symlink to it.
lm=feeds/luci/collections/luci-light/Makefile
if grep -q '+luci-theme-bootstrap' "$lm"; then
	sed -i 's/+luci-theme-bootstrap/+luci-theme-footstrap/' "$lm"
else
	echo "::warning::no +luci-theme-bootstrap in $lm, luci-light's theme dependency may have changed -- recheck"
fi

# Upstream puts the Go module cache in $(DL_DIR)/go-mod-cache. Everything else
# in dl is a PKG_HASH-verified tarball, which is what earns dl its wholesale CI
# cache with a prefix fallback; the module cache is an extracted writable tree
# with no integrity check, so a partial one is restored into every later build
# and reports as "no required module provides package ..." rather than as cache
# damage. Move it under build_dir, alongside the equally regenerable
# $(TMP_DIR)/go-build.
gv=feeds/packages/lang/golang/golang-values.mk
if [ ! -f "$gv" ]; then
	echo "::warning::$gv does not exist, the Go module cache stays under dl/ and will be cached with it"
elif grep -q '^GO_MOD_CACHE_DIR:=\$(BUILD_DIR_BASE)/go-mod-cache$' "$gv"; then
	: # already under build_dir; idempotent on re-run
elif grep -q '^GO_MOD_CACHE_DIR:=\$(DL_DIR)/go-mod-cache$' "$gv"; then
	sed -i 's|^GO_MOD_CACHE_DIR:=\$(DL_DIR)/go-mod-cache$|GO_MOD_CACHE_DIR:=$(BUILD_DIR_BASE)/go-mod-cache|' "$gv"
else
	echo "::warning::no GO_MOD_CACHE_DIR:=\$(DL_DIR)/go-mod-cache line in $gv, module cache path unchanged -- recheck upstream"
fi


# Apply the coordinated UPnP configuration, LuCI, hairpin and STUN patches.
bash "$(dirname "$0")/scripts/apply-upnp-patches.sh" || {
	echo "::error::failed to apply UPnP patches"
	exit 1
}
