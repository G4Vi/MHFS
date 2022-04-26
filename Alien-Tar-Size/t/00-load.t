#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Alien::Tar::Size' ) || print "Bail out!\n";
}

diag( "Testing Alien::Tar::Size $Alien::Tar::Size::VERSION, Perl $], $^X" );
