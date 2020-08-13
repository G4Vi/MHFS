#!/usr/bin/perl
use strict;
use warnings;
use feature 'say';

system('emcc', 'drflac.c', '-o', 'drflac.js', '-s', 'ASYNCIFY', '-s', 'ASYNCIFY_IMPORTS=["do_fetch"]', '-s', qq$EXPORTED_FUNCTIONS=["_get_audio"]$, '-s', qq$EXPORTED_RUNTIME_METHODS=["cwrap"]$) == 0 or die("failed to build");
