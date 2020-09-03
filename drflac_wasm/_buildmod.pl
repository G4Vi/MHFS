#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';

system('mkdir', '-p', 'modout') == 0 or die("failed to make mod out dir");

#'--extern-pre-js', 'src/network_drflac.pre.js', 
system('emcc', '-O3', 'src/network_drflac.c', '-o', 'modout/drflac.js', '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_create", "_network_drflac_open", "_network_drflac_close", "_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels", "_network_drflac_read_pcm_frames_s16_to_wav", "_network_drflac_abort_current"]$,
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap"]$, 
#'-s', 'ASSERTIONS=1',
#'-s', 'ERROR_ON_UNDEFINED_SYMBOLS=0',
'-s', 'EXPORT_ES6=1',
'-s', 'MODULARIZE=1',
) == 0 or die("failed to build");

system('cp', 'modout/drflac.js', 'modout/drflac.wasm', '../static/music_inc') == 0 or die("failed to copy to static");
