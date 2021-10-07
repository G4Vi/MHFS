#!/bin/bash

set -e 
set -o pipefail

cd /tmp

git clone https://github.com/G4Vi/MHFS.git --depth 1

cd MHFS

rm -rf .git

source ~/emsdk/emsdk_env.sh

make -j4 music_worklet music_inc

cd ..

RELNAME="MHFS-$1"

#mv MHFS "$RELNAME"

tar -czf "$RELNAME.tar.gz" "MHFS" --owner=0 --group=0

