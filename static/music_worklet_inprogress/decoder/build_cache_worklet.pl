#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';
defined $ENV{EMSDK} or die("emsdk not found. maybe source ~/emsdk/emsdk_env.sh");

my $debug = 0;
#$debug = 1;

my $outdir;
my @cmd = ('emcc');
if($debug) {
    push @cmd, ("-O0", "-g4", '--source-map-base', './src/');
    push @cmd, ('-s', 'SAFE_HEAP=1');
    $outdir = 'bin';
}
else {
    push @cmd, ('-O3');
    $outdir = 'bin';
}
system('mkdir', '-p', $outdir) == 0 or die("failed to create $outdir");


push @cmd, (
'src/drflac_cache.c',
'-D', 'NETWORK_DR_FLAC_FORCE_REDBOOK',
'-D', 'DR_FLAC_NO_OGG',
'-o', "$outdir/drflac.js", '-s',
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap", "ccall"]$, 
'-s', 'EXPORT_ES6=1',
'-s', 'ASSERTIONS=1',
#'-s', 'INITIAL_MEMORY=655360000',
'-s', 'ALLOW_MEMORY_GROWTH=1',
'-s', 'MODULARIZE=1');

system(@cmd) == 0 or die("failed to build");

if($debug) {    
    system('rsync', '-a', 'src', $outdir.'/') == 0 or die("failed to copy src to music_inc");
    system("mv", "$outdir/drflac.wasm.map", "$outdir/src/drflac.wasm.map") == 0 or die("Failed to mv source map");
}
