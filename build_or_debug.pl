#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use Cwd;
use FindBin;
use File::Spec;

my $ogcwd = getcwd();

# verify MHFS is not running
my $pidsres = `pgrep -d ' ' 'perl'`;
my @pids = split( ' ', $pidsres);
$pidsres = `pgrep -d ' ' -f 'server.pl'`;
my @opids = split( ' ', $pidsres);
foreach my $perls (@pids) {
    foreach my $spls (@opids) {
        if($perls eq $spls) {
            say "server.pl $spls running, attempting to kill it";
            system('kill' , '-9', $perls) == 0 or die("Failed to kill pid " . $perls);             
        }    
    }
}

# build flac library
say "current binary " . $FindBin::Bin;
my $flacdir = File::Spec->catdir($FindBin::Bin, 'Mytest');
chdir($flacdir) or die("failed to enter flac dir");
system('perl', 'Makefile.PL') == 0 or die("Makefile.PL died");
system('make') == 0 or die("Make failed");

# run the server
chdir($FindBin::Bin) or die("Failed to change to script location");
exec('perl', 'server.pl');