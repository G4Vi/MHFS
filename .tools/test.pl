#!/usr/bin/perl
use strict; use warnings;
use feature 'say';

for(my $i = 0; $i < 100; $i++) {
    system "curl -sS 'http://127.0.0.1:8000/get_video?name=abba.mp3&fmt=noconv' -o /dev/null &";    
}
