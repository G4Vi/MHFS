#!/usr/bin/perl
use strict; use warnings;
use FindBin;

my @libdirs = ('Alien-Tar-Size/blib/lib', 'MHFS-XS/blib/arch', 'MHFS-XS/lib', 'App-MHFS/lib');

my @include;
foreach my $libdir (@libdirs) {
    push @include, ('-I', $libdir);
}

chdir($FindBin::Bin) or die("Failed to change to script location");
exec('perl', @include , 'App-MHFS/bin/mhfs', @ARGV);
