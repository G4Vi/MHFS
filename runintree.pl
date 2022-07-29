#!/usr/bin/perl
use strict; use warnings;
use FindBin;

my @libdirs = ('Alien-Tar-Size/blib/lib', 'MHFS-XS/blib/arch', 'MHFS-XS/lib', 'App-MHFS/lib');

# switch to absolute path
$_ =  "$FindBin::Bin/$_" foreach(@libdirs);

push @ARGV, '--appdir', "$FindBin::Bin/App-MHFS/share";

if($^O ne 'MSWin32') {
    # build the includes
    my @include;
    foreach my $libdir (@libdirs) {
        push @include, ('-I', $libdir);
    }

    # run
    my @cmd = ('perl', @include , "$FindBin::Bin/App-MHFS/bin/mhfs", @ARGV);
    print join(' ', @cmd);
    exec {$cmd[0]} @cmd;
}
# exec is weird on windows so instead just load the module and run
else {
    unshift @INC, $_ foreach(@libdirs);
    eval "use App::MHFS; 1;" or die("failed to load MHFS");
    App::MHFS->run;
}
