#!/bin/bash

# for root user
export FORCE_UNSAFE_CONFIGURE=1

rm -rf ./tmp
git pull
sed -i 's/#src-git helloworld/src-git helloworld/g' ./feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
git checkout .config
make defconfig
make -j$(nproc) download
make -j$(nproc) || make -j1 V=s
