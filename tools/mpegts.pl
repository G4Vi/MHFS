#!/usr/bin/perl

use strict; use warnings;
use feature 'say';

sub packet_head_error {
    my ($packethead, $reason) = @_;
    warn(sprintf "packet: 0x%X, $reason", $packethead);
}

sub parse_timestamp {
    my ($tstring, $expectedleadbits) = @_;
    my $val = unpack('Q>', $tstring);
    #say 'theval '. sprintf("0x%X 0x%X 0x%X 0x%X", ($val >> 56) & 0xFF, ($val >> 48) & 0xFF, ($val >> 40) & 0xFF, ($val >> 32) & 0xFF);
    #say "shift val" . ($val >> 60);
    if((($val >> 60) & 0xF) !=  $expectedleadbits) {
        warn "bits before pts are wrong";
        next;
    }
    $val >>= 25;
    return ($val & 0x7FFF) | (($val >> 1) & (0x7FFF << 15)) | (($val >> 2) & (0x7 << 30));
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
    if(($pstart[0] == 0) && ($pstart[1] == 0) && ($pstart[2] == 1)) {
        my $streamtype = (($pstart[3] >= 0xE0) && ($pstart[3] <= 0xEF)) ? 'video ' : (($pstart[3] >= 0xC0) && ($pstart[3] <= 0xDF)) ? 'audio' : 'unknown';
        my $plen = unpack('n', substr($payload, 4, 2));
        say "PID $pid BEGIN PES PACKET streamtype $streamtype plen $plen";
        my $optionalpesheader = substr($payload, 6);
        my ($flags1, $flags2, $opslen) = unpack('CCC', substr($optionalpesheader, 0, 3));
        say sprintf("oph 0x%X 0x%X 0x%X", $flags1, $flags2, $opslen);
        my $isbad_optional = ($flags1 & 0xC0) != 0xC0;
        my $HAS_PTS = 0x80;
        my $HAS_DTS = 0x40;
        my $TSMASK = $HAS_PTS|$HAS_DTS;
        my $tsval = $flags2 & $TSMASK;
        my $PTS_String = ($tsval == $TSMASK) ? 'PTS|DTS' : ($tsval == $HAS_PTS) ? 'PTS' : ($tsval == 0) ? 'nopts' : 'invalid';
        if($tsval & $HAS_PTS) {
            my $pts = parse_timestamp(substr($optionalpesheader, 3), ($tsval >> 6));
            #my $val = unpack('Q>', substr($optionalpesheader, 3));
            #say 'theval '. sprintf("0x%X 0x%X 0x%X 0x%X", ($val >> 56) & 0xFF, ($val >> 48) & 0xFF, ($val >> 40) & 0xFF, ($val >> 32) & 0xFF);
            #say "shift val" . ($val >> 60);
            #say "tsvalshifted " . ($tsval >> 6);
            #if((($val >> 60) & 0xF) !=  ($tsval >> 6)) {
            #    warn "bits before pts are wrong";
            #    next;
            #}
            #$val >>= 25;
            #my $pts = ($val & 0x7FFF) | (($val >> 1) & (0x7FFF << 15)) | (($val >> 2) & (0x7 << 30));
            say "pts $pts";
            if($tsval & $HAS_DTS) {
                my $dts = parse_timestamp(substr($optionalpesheader, 8), 0x1);
                say "dts $dts";
            }
        }

    }
}
say "done";
