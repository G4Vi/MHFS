#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';

system('mkdir', '-p', 'out') == 0 or die("failed to make out dir");

#'--extern-pre-js', 'src/network_drflac.pre.js', 
system('emcc', '-O3', 
'--pre-js', 'src/jspass.js', 
'src/network_drflac.c', '-o', 'out/drflac.js', '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_open", "_network_drflac_close", "_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels", "_network_drflac_read_pcm_frames_s16_to_wav", "_network_drflac_set_cancel"]$,
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap", "ccall"]$, 
#'-s', 'ASSERTIONS=1',
#'-s', 'ERROR_ON_UNDEFINED_SYMBOLS=0',
) == 0 or die("failed to build");


system('cp', 'out/drflac.js', 'out/drflac.wasm', 'music_drflac.js', '../static/') == 0 or die("failed to copy to static");

