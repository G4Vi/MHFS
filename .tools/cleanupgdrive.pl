#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use File::Basename;
use Cwd qw(abs_path getcwd);
my $SCRIPTDIR = dirname(abs_path(__FILE__));
my $cfgdir = $SCRIPTDIR . '/.conf';

my $listcmd = './gdrive --config ' . $cfgdir .' --service-account cred.json list --max 10000  --no-header';
my $delcmd = './gdrive --config '.$cfgdir.' -service-account cred.json delete ';
my $firstlistout = `$listcmd`;

foreach my $line (split('\n', $firstlistout)) {
    my ($id) = $line =~ /^([^\s]+)\s+/;
    my $fincmd = $delcmd . $id;
    say $fincmd;
    system $fincmd;
}

say `$listcmd`;
