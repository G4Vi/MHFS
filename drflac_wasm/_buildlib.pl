#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';

system('emcc', 'drflac.c', '-o', 'drflac.js', '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s',
qq$EXPORTED_FUNCTIONS=["_network_drflac_open", "_network_drflac_totalPCMFrameCount", "_network_drflac_sampleRate", "_network_drflac_bitsPerSample", "_network_drflac_channels", "_network_drflac_read_pcm_frames_s16_to_wav"]$,
'-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap"]$) == 0 or die("failed to build");

system('cp', 'drflac.js', 'music_drflac.js', 'drflac.wasm', 'music_drflac.html', '../static/') == 0 or die("failed to copy to static");
