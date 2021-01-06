#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';
defined $ENV{EMSDK} or die("emsdk not found. maybe source ~/emsdk/emsdk_env.sh");

my $debug = 0;
$debug = 1;

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
'-o', "$outdir/drflac.js", '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_open_mem", "_network_drflac_read_pcm_frames_f32_mem", "_network_drflac_close",
"_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels",
"_network_drflac_mem_create", "_network_drflac_mem_free", "_network_drflac_mem_add_block", "_network_drflac_mem_bufptr",
"_network_drflac_create_error", "_network_drflac_free_error", "_network_drflac_error_code", "_network_drflac_extra_data",
"_network_drflac_mem_realloc_buf"]$,
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