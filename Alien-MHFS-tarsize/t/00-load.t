#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Alien::MHFS::tarsize' ) || print "Bail out!\n";
}

diag( "Testing Alien::MHFS::tarsize $Alien::MHFS::tarsize::VERSION, Perl $], $^X" );
