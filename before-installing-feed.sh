#!/bin/bash

# Remove feed sources
sed -i '/telephony/d' feeds.conf.default
sed -i '/video/d' feeds.conf.default

# Add feed sources
# Must be inserted ahead of packages. scripts/feeds' install_src honours only
# the first feed that claims a given package name, and install -f's $override
# covers core packages under package/ only, never a name clash between feeds.
# Both daede and packages ship a package named dae, so appending here would
# always build the packages one.
#
# The daede snapshot's do_tproxy_wan_egress returns TC_ACT_PIPE, which is what
# lets qosify's egress filter later on the same clsact still run; the packages
# copy returns TC_ACT_OK for forwarded packets and silently kills egress DSCP
# marking. That tarball rerolls every few days, so the guarantee is not
# permanent -- see CLAUDE.md.
sed -i '1i src-git daede https://github.com/kenzok8/openwrt-daede' feeds.conf.default
