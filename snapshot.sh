#!/bin/bash
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
pushd $SCRIPTPATH

# cleanup
pushd Mytest
make clean
popd

# do the backup
currentDate=`date`
rsync -av --progress ../MHFS/ ../Sync/Code/MHFS/MHFS_"$(date +'%Y-%m-%d-%H-%M-%S')"/ --exclude tmp

popd
