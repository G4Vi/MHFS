package MHFS::EventLoop::Poll;
use strict; use warnings;
use feature 'say';

my $selbackend;
BEGIN {
my @backends = ("'MHFS::EventLoop::Poll::Linux'",
                "'MHFS::EventLoop::Poll::Base'");

foreach my $backend (@backends) {
    if(eval "use parent $backend; 1;") {
        $selbackend = $backend;
        last;
    }
}
$selbackend or die("Failed to load MHFS::EventLoop::Poll backend");
}

sub backend {
    return $selbackend;
}

1;
