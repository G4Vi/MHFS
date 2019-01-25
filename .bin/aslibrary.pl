#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use Data::Dumper;
use Storable;

(@ARGV == 2) or die "Incorrect amount or arguments";
require($ARGV[0]);
my $lib = MusicLibrary::BuildLibrary($ARGV[1]);
store($lib, 'music.db');
print MusicLibrary::read_file('music.db');

