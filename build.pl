#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use FindBin;
use File::Spec;

# build flac library
say "current binary " . $FindBin::Bin;
my $flacdir = File::Spec->catdir($FindBin::Bin, 'Mytest');
chdir($flacdir) or die("failed to enter flac dir");
system('perl', 'Makefile.PL') == 0 or die("Makefile.PL died");
system('make') == 0 or die("Make failed");

exit 0;