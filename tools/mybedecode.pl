#!/usr/bin/perl
use strict; use warnings;
use feature 'say';

@ARGV >= 1 or die("no files specified");

sub read_file {
    my ($filename) = @_;
    return do {
        local $/ = undef;
        if(!(open my $fh, "<", $filename)) {
            #say "could not open $filename: $!";
            return undef;
        }
        else {
            <$fh>;
        }
    };
}

my @typestack;
my $istring = '';
my $lastbstring;
my $foffset = 0;
my $infostart;
my $infoend;
my $infodepth;

sub indentedprint {
    my $message = ( ' ' x (scalar(@typestack) * 4)) . $_[0];
    say $message;
}


my $contents = read_file($ARGV[0]);
while(1) {
    if($foffset == length($contents)) {
        if(@typestack) {
            indentedprint("Unexpected eof");
        }
        last;
    }
    my $typeid = substr($contents, $foffset++, 1);
    my $curtype = $typestack[-1];
    if($curtype) {
        if($curtype eq 'i') {
            if($typeid ne 'e'){
                $istring .= $typeid;
                next;
            }
            else {
                if($istring =~ /^(-?[0-9]+)$/) {
                    indentedprint("integer $1");
                    $istring = '';
                }
                else {
                    indentedprint("invalid integer: $istring");
                    last;
                }
            }
        }
        if($typeid eq 'e') {
            my $popped = pop @typestack;
            indentedprint("leave $popped");
            if($infodepth && (scalar(@typestack) < $infodepth)) {
                $infodepth = 0;
                $infoend = $foffset;
            }
            next;
        }
    }
    if(($typeid eq 'd') ||  ($typeid eq 'l') || ($typeid eq 'i')){
        indentedprint("enter $typeid");
        push @typestack, $typeid;
        if($lastbstring eq 'info') {
            $infostart = $foffset-1;
            $infodepth = scalar(@typestack);
        }
    }
    else {
        my $bstringcolon = index($contents, ':', $foffset);
        if($bstringcolon == -1) {
            indentedprint("invalid bstring " . (length($contents) - $foffset));
            last;
        }
        my $rdcount = ($bstringcolon-$foffset);
        my $bstringlen = $typeid .= substr($contents, $foffset, $rdcount);
        $foffset += $rdcount;
        my $ilen;
        if($bstringlen =~ /^([0-9]+)$/) {
            $ilen = $1;
            indentedprint("integer $1");
        }
        else {
            indentedprint("invalid bstring integer $bstringlen");
            last;
        }
        substr($contents, $foffset++, 1) eq ':' or die("vadreading");
        if(length($contents) < $ilen) {
            indentedprint("unexpected eof in bstring");
            last;
        }
        my $bstring = substr($contents, $foffset, $ilen);
        $foffset += $ilen;
        indentedprint("bstring $bstring");
        $lastbstring = $bstring;
    }
}

use constant {
    BDEC_SCAN       = 1 << 0,
    BDEC_DICT_KEY   = 1 << 1,
    BDEC_DICT_VAL   = 1 << 2,
    BDEC_BSTR_INT   = 1 << 3,
    BDEC_LIST       = 1 << 4,
    BDEC_INT_SIGN   = 1 << 5,
    BDEC_INT_ZERO   = 1 << 6,
    BDEC_INT_NORMAL = 1 << 7

};
my @statestack = (BDEC_SCAN);
my $curbstr;
while(1) {
    if($foffset == length($contents)) {
        if($statestack[-1] != BDEC_SCAN) {
            indentedprint("Unexpected eof");
        }
        last;
    }
    my $char = substr($contents, $foffset++, 1);
    if($statestack[-1] == BDEC_SCAN) {
        if($char ne 'd') {
            indentedprint("Expected dictionary");
            last;
        }
        indentedprint('dict start');
        push @statestack, BDEC_DICT_KEY;
    }
    elsif($statestack[-1] == BDEC_DICT_KEY) {
        if($char ne 'e') {
            my $cval = ord($char);
            if(($cval < ord('0')) || ($cval > ord('9'))) {
                indentedprint('unexpected char');
                last;
            }
            $curbstr = $char;
            push @statestack, BDEC_BSTR_INT;
        }
        else {
            pop @statestack;
            indentedprint('dict end');
        }
    }
    elsif($statestack[-1] == BDEC_BSTR_INT) {
        if($char ne ':') {
            my $cval = ord($char);
            if(($cval < ord('0')) || ($cval > ord('9'))) {
                indentedprint('unexpected char');
                last;
            }
            $curbstr .= $char;
        }
        else {
            pop @statestack;
            $foffset += $curbstr;
            $curbstr = '';
            $statestack[-1] = BDEC_DICT_VAL;
        }
    }
    elsif($statestack[-1] == BDEC_DICT_VAL) {
        if($char eq 'd') {
            indentedprint('dict start');
            push @statestack, BDEC_DICT_KEY;
        }
        

    }
}


say "infooffset $infostart length " . ($infoend - $infostart);
