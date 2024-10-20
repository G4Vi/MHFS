#!/usr/bin/perl
use strict; use warnings;

open(my $fh, '<', 'plugin.video.mhfs/addon.xml') or die "failed to open plugin";
while(my $line = <$fh>) {
    if($line =~ /^\s*version="(\d+\.\d+\.\d+)"/) {
        print $1;
        exit 0;
    }
}
