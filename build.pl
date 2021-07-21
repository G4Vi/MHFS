#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use FindBin;
use File::Spec;

# build music_worklet
system('perl', '-xstatic/music_worklet_inprogress/decoder', 'static/music_worklet_inprogress/decoder/build_cache_worklet.pl') == 0 or die('failed to make worklet emcc');
system('sh', 'static/music_worklet_inprogress/player/ff.sh') == 0 or die('failed to make worklet');

# build flac library
say "current binary " . $FindBin::Bin;
my $flacdir = File::Spec->catdir($FindBin::Bin, 'Mytest');
chdir($flacdir) or die("failed to enter flac dir");
system('make', '-f', 'MakeMakefile.mk') == 0 or die("Failed to make MakeMakefile.mk");
system('make') == 0 or die("Make failed");

exit 0;
