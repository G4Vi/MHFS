#!/usr/bin/perl
use strict; use warnings;
use FindBin;

my @libdirs = ('Alien-Tar-Size/blib/lib', 'MHFS-XS/blib/arch', 'MHFS-XS/lib', 'App-MHFS/lib');

my @include;
foreach my $libdir (@libdirs) {
    push @include, ('-I', $libdir);
}
print STDOUT "cd $FindBin::Bin\n";
chdir($FindBin::Bin) or die("Failed to change to script location");
my @cmd = ('perl', @include , 'App-MHFS/bin/mhfs', '--appdir', 'App-MHFS/share', @ARGV);
print join(' ', @cmd);
exec {$cmd[0]} @cmd;
