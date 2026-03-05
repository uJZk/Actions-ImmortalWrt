#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# 2. Исправляем оболочку с bash на ash (чтобы не ломался SSH)
sed -i 's/\/bin\/bash/\/bin\/ash/g' package/base-files/files/etc/passwd

# 3. Удаляем китайский язык из интерфейса
sed -i '/CONFIG_LUCI_LANG_zh-cn=y/d' .config
