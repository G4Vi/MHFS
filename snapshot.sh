#!/bin/bash
currentDate=`date`
rsync -av --progress ../MHFS/ ../Sync/Code/MHFS/MHFS_"$(date +'%Y-%m-%d-%H-%M-%S')"/ --exclude tmp
