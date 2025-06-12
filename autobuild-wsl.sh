#!/bin/bash

rm -rf ./tmp
git pull
sed -i 's/#src-git helloworld/src-git helloworld/g' ./feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
git checkout .config
make defconfig
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# export PATH=$(echo $PATH | tr ':' '\n' | grep -v '^Files/WindowsApps/Microsoft.WindowsTerminal_1.16.10262.0_x64__8wekyb3d8bbwe$' | tr '\n' ':')
make -j$(nproc) download
make -j$(nproc) || make -j1 V=s

