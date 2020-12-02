#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use FindBin;


# verify MHFS is not running
my $pidsres = `pgrep -d ' ' 'perl'`;
my @pids = split( ' ', $pidsres);
$pidsres = `pgrep -d ' ' -f 'server.pl'`;
my @opids = split( ' ', $pidsres);
foreach my $perls (@pids) {
    foreach my $spls (@opids) {
        if($perls eq $spls) {
            my $pwdxres = `pwdx $spls`;
            $pwdxres =~ /(\/.+)$/;
            if($1 eq $FindBin::Bin) {
                say "server.pl $spls running, attempting to kill it";
                system('kill' , '-9', $perls) == 0 or die("Failed to kill pid " . $perls);
            }                       
        }    
    }
}

chdir($FindBin::Bin) or die("Failed to change to script location");

# build mhfs
system('perl', 'build.pl') == 0 or die("Failed to build MHFS");

# run the server
exec('perl', 'server.pl', 'flush');