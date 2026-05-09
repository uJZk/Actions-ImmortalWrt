#!/bin/bash

# Remove feed sources
sed -i '/telephony/d' feeds.conf.default
sed -i '/video/d' feeds.conf.default

# Add feed sources
echo 'src-git daed https://github.com/QiuSimons/luci-app-daed' >> feeds.conf.default
echo 'src-git wrtbwmon https://github.com/brvphoenix/wrtbwmon' >> feeds.conf.default
echo 'src-git wrtbwmon_luci https://github.com/brvphoenix/luci-app-wrtbwmon' >> feeds.conf.default
