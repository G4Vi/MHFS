#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';
#'--extern-pre-js', 'src/network_drflac.pre.js', 
system('emcc', '-O3', 'src/network_drflac.c', '-o', 'out/drflac.js', '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_open", "_network_drflac_close", "_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels", "_network_drflac_read_pcm_frames_s16_to_wav", "_network_drflac_abort_current"]$,
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap"]$, 
#'-s', 'ASSERTIONS=1',
#'-s', 'ERROR_ON_UNDEFINED_SYMBOLS=0',
) == 0 or die("failed to build");


system('cp', 'out/drflac.js', 'out/drflac.wasm', 'music_drflac.js', 'music_drflac.html', '../static/') == 0 or die("failed to copy to static");
system('cp', 'out/drflac.js', 'out/drflac.wasm', 'music_drflac.js', 'music_drflac.html', '../static/music_inc') == 0 or die("failed to copy to static");
