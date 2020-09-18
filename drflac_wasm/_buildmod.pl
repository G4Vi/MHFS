#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';

my $debug = 0;
#my $debug = 1;

my $outdir;
my @cmd = ('emcc');
if($debug) {
    push @cmd, ("-O0", "-g4", '--source-map-base', './'); #'--source-map-base', 'https://computoid.com/stream/static/music_inc/'); # for chrome
    #push @cmd, ('-s', 'SAFE_HEAP=1');
    $outdir = 'mod_dbg';
}
else {
    push @cmd, ('-O3');
    $outdir = 'mod_rel';
}
system('mkdir', '-p', $outdir) == 0 or die("failed to create $outdir");

push @cmd, ('--pre-js', 'src/jspass.js',
'src/network_drflac.c', '-o', "$outdir/drflac.js", '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_open", "_network_drflac_close", "_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels", "_network_drflac_read_pcm_frames_s16_to_wav", "_network_drflac_read_pcm_frames_f32"]$,
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap", "ccall"]$, 
'-s', 'EXPORT_ES6=1',
'-s', 'MODULARIZE=1');

system(@cmd) == 0 or die("failed to build");

system('rsync', '-a', $outdir.'/', '../static/music_inc')== 0 or die("failed to copy to music_inc");
if($debug) {
    system('rsync', '-a', 'src', '../static/music_inc/') == 0 or die("failed to copy src to music_inc");
}
