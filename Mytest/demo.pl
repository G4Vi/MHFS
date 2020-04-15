#!/usr/bin/perl
use strict; use warnings;
use ExtUtils::testlib;
use Data::Dumper;
use Devel::Peek;
use feature 'say';
use Benchmark qw(:all) ;
use Mytest;
{
my $pv = Mytest::new('../in.flac');

Mytest::get_flac_frames($pv, 4);

my $fcount = Mytest::get_flac_frame_count($pv);

say "fcount " . $fcount;

Mytest::get_flac($pv, 0, 6000);

Dump($pv);

}
#my $res = Mytest::mytest_get_flac_frames($pv, 4);
#my $fcount = Mytest::mytest_get_flac_frame_count($pv);

#Mytest::mytest_get_flac($pv, 0, 500);

say "aaaa";

#Mytest::mytest_get_flac($pv, 0, 8752849);

#timethis(10, sub {
#    Mytest::mytest_get_flac($pv, 0, 8752849);
#});


#timethis(10000, sub {
#    my $pv = Mytest::mytest_new('../in.flac');
#    my $res = Mytest::mytest_get_flac_frames($pv, 50);
#});

#say "res length " . length($res);
#Dump($res);
#print Dumper($aaa);
