#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use FindBin;
use File::Spec;

# build music_worklet
system('make', '-C', 'static/music_worklet_inprogress/decoder') == 0 or die('failed to make wasm');
system('make', '-C', 'static/music_worklet_inprogress/player/') == 0 or die('failed to make worklet');

# build xs library for server
say "current binary " . $FindBin::Bin;
my $flacdir = File::Spec->catdir($FindBin::Bin, 'Mytest');
chdir($flacdir) or die("failed to enter flac dir");
system('make', '-f', 'MakeMakefile.mk') == 0 or die("Failed to make MakeMakefile.mk");
system('make') == 0 or die("Make failed");

exit 0;
