#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

# Uncomment feed sources
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Remove feed sources
sed -i '/telephony/d' feeds.conf.default

# Add feed sources
echo 'src-git daed https://github.com/QiuSimons/luci-app-daed' >> feeds.conf.default
echo 'src-git wrtbwmon https://github.com/brvphoenix/wrtbwmon' >> feeds.conf.default
echo 'src-git wrtbwmon_luci https://github.com/brvphoenix/luci-app-wrtbwmon' >> feeds.conf.default
# echo 'src-git sirpdboy https://github.com/sirpdboy/sirpdboy-package' >> feeds.conf.default
