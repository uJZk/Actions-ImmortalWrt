#!/bin/bash
# Run from the upstream OpenWrt tree after installing feeds.
set -eu
upnp_root=$(cd "$(dirname "$0")/.." && pwd)

# UPnP NAT loopback (hairpin). miniupnpd does not implement it: every DNAT rule
# it writes carries iif <ext_ifname>, so a LAN client reaching the router's own
# public address never matches.
#
# Two halves, and the order is a safety property: add the fib guard at the jump
# first, and patch the source only once that succeeded. Patching alone degrades
# the rules to proto+dport, which DNATs LAN-to-LAN traffic on the same port to
# the mapped host; the guard alone is harmless.
#
# The guard tests fib rather than a hardcoded public address because the PPPoE
# address changes on redial while miniupnpd's ifup hotplug only restarts on an
# ext_ifname change. LAN/tailscale prefixes are excluded so traffic to the
# router's own addresses on those ports is not hijacked.
#
# Return SNAT is elsewhere: files/usr/share/nftables.d/chain-post/srcnat/.
python3 "$upnp_root/scripts/patch-upnp.py" || {
	echo "::error::failed to patch UPnP configuration and LuCI status"
	exit 1
}
mu=feeds/packages/net/miniupnpd
mn=$mu/files/nftables.d/chain-post/dstnat/20-miniupnpd.nft
mu_guard='fib daddr type local ip daddr != 192.168.0.0/24 ip daddr != 100.64.0.0/10 jump upnp_prerouting'
if [ ! -f "$mn" ]; then
	echo "::warning::$mn does not exist, UPnP NAT loopback not set up -- LAN hosts cannot reach UPnP-mapped ports"
elif grep -qF "$mu_guard" "$mn"; then
	: # already guarded; idempotent on re-run
elif ! grep -q '^jump upnp_prerouting comment' "$mn"; then
	echo "::warning::$mn is not the expected single jump upnp_prerouting line; guard not added, so the miniupnpd patch is skipped too -- recheck upstream"
else
	sed -i "s|^jump upnp_prerouting|$mu_guard|" "$mn"
	mkdir -p "$mu/patches"
fi
# Never remove iif unless the guarded jump is present. Also restore the source
# patch on a second run when the jump has already been transformed.
if grep -qF "$mu_guard" "$mn" 2>/dev/null; then
	mkdir -p "$mu/patches"
	cp "$upnp_root/patches/100-nat-loopback.patch" "$mu/patches/100-nat-loopback.patch"
else
	echo "::error::UPnP hairpin guard is missing; refusing to remove iif"
	exit 1
fi

# Keep all miniupnpd source patches in one explicitly ordered manifest.
for upnp_patch in 110-stun-input.patch 120-internal-client-fallback.patch 130-ipv6-pinhole-client-fallback.patch; do
	[ -f "$mu/Makefile" ] && [ -f "$upnp_root/patches/$upnp_patch" ] || {
		echo "::error::miniupnpd feed or $upnp_patch missing"
		exit 1
	}
	cp "$upnp_root/patches/$upnp_patch" "$mu/patches/$upnp_patch"
done
