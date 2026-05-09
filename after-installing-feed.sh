#!/bin/bash

# Modify default IP
sed -i 's/192.168.1.1/192.168.0.1/g' package/base-files/files/bin/config_generate

# Replace ash with bash
sed -i 's/\/bin\/ash/\/bin\/bash/' package/base-files/files/etc/passwd

# Partition alignment
sed -i 's/256/4096/g' target/linux/x86/image/Makefile

# Add kernel config
mv ../config-6.12 target/linux/x86/config-6.12
