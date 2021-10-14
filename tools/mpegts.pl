#!/usr/bin/perl

use strict; use warnings;
use feature 'say';

sub packet_head_error {
    my ($packethead, $reason) = @_;
    warn(sprintf "packet: 0x%X, $reason", $packethead);
}

open(my $fh, $ARGV[0]) or die('unable to open');
say "opened ".$ARGV[0];
while(1) {
    my $packet;
    my $amtread = read($fh, $packet, 188);
    defined($amtread) or die('read error');
    if($amtread < 188) {
        warn("incomplete read of $amtread ") if($amtread != 0);
        last;
    }
    my $packethead = unpack('N', $packet);
    my $syncbyte = ($packethead & 0xff000000) >> 24;
    my $tei = ($packethead & 0x800000) >> 23;
    my $pusi = ($packethead & 0x400000) >> 22;
    my $tpriority = ($packethead & 0x200000) >> 21;
    my $pid = ($packethead & 0x1fff00) >> 8;
    my $tsc = ($packethead & 0xc0) >> 6;
    my $afc = ($packethead & 0x30) >> 4;
    my $continuity = ($packethead & 0xF);
    say sprintf "sync 0x%X TEI %u PUSI %u TP %u PID 0x%X TSC 0x%x AFC 0x%X CC 0x%X", $syncbyte, $tei, $pusi, $tpriority, $pid, $tsc, $afc, $continuity;

    packet_head_error($packethead, "Invalid sync byte") if($syncbyte != 0x47);
    packet_head_error($packethead, "TEI error") if($tei);
    packet_head_error($packethead, "TSC reserved") if($tsc == 0x40);
    my $payload = substr($packet, 4);
    if($afc != 0x1) {
        my ($af_size, $af_flags) = unpack('CC', $payload);
        say "afsize $af_size";
        $payload = substr($payload, $af_size+1);
    }
    if(length($payload) < 4) {
        say "not printing payload, too small";
        next;
    }
    my @pstart = unpack('CCCC', $payload);
    say sprintf("payload start %X %X %X %X", @pstart);
}
say "done";
