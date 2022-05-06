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

use constant {
    BDEC_DICT              => 1 << 0,
    BDEC_LIST              => 1 << 1,

    BDEC_END_OK_ALWAYS     => 1 << 2,
    BDEC_END_OK_SOMETIMES  => 1 << 3,

    BDEC_GET_VAL_ALWAYS    => 1 << 4,
    BDEC_GET_VAL_SOMETIMES => 1 << 5
};

use constant BDEC_END_OK => (BDEC_END_OK_ALWAYS | BDEC_END_OK_SOMETIMES);
use constant BDEC_GET_VAL     => (BDEC_GET_VAL_ALWAYS | BDEC_GET_VAL_SOMETIMES);
use constant BDEC_DICT_TOGGLE => BDEC_END_OK_SOMETIMES | BDEC_GET_VAL_SOMETIMES;

use constant BDEC_DICT_GET_KEY => BDEC_DICT | BDEC_END_OK_SOMETIMES;
use constant BDEC_DICT_GET_VAL => BDEC_DICT | BDEC_GET_VAL_SOMETIMES;
use constant BDEC_LIST_GET_VAL => BDEC_LIST | BDEC_END_OK_ALWAYS | BDEC_GET_VAL_ALWAYS;

my @statestack = (BDEC_DICT_GET_KEY);
my $foffset = 0;
my $infostart;
my $infoend;
my $isinfo;
my @data;
my @itemstack = (\@data);
sub itemstack_additem {
    my ($itemstack, $curstate, $item) = @_;
    if(($curstate == BDEC_DICT_GET_KEY) || ($curstate == BDEC_LIST_GET_VAL)) {
        push @{$itemstack->[-1]}, $item;
    }
    elsif($curstate == BDEC_DICT_GET_VAL) {
        $itemstack->[-1][-1]{'value'} = $item->{'value'};
        $itemstack->[-1][-1]{'foffset'} = $item->{'foffset'};
    }
}

sub itemstack_pop {
    my ($itemstack, $curstate, $item) = @_;
    pop @{$itemstack->[-1]}
}

# DICT KEY -> push [key, undef] to parent array
# set current item to [1]

# VALUE
# add to parent: if parent is dict key set parent[1] to []
# if parent is list, push to list

# DICT => create array, add to parent, set current item

# INT => parse INT

# LIST => create array, add to parent

#{
#    [dict, [
#        [dictentry, [key, value]]

#]]

#]
#}







sub indentedprint {
    my $message = ( ' ' x (scalar(@statestack) * 4)) . $_[0];
    say $message;
}
my $contents = read_file($ARGV[0]);

# finally parse
if((length($contents) == 0) || (substr($contents, $foffset++, 1) ne 'd')) {
    say 'invalid file';
    exit 0;
}
indentedprint('dict start');
while(1) {
    indentedprint('state ' . $statestack[-1]);
    my $char = substr($contents, $foffset++, 1);
    my $curstate = $statestack[-1];
    if($curstate & BDEC_END_OK) {
        if($char eq 'e') {
            pop @statestack;
            indentedprint((($curstate & BDEC_DICT) ? 'dict' : 'list') . ' end');
            if(scalar(@statestack) == 0) {
                last;
            }
            next;
        }
    }
    # Change the next dictionary operation (at this level) between GET_KEY and GET_VAL (if it's a dictionary)
    $statestack[-1] ^= BDEC_DICT_TOGGLE;
    if($curstate & BDEC_GET_VAL) {
        if($char eq 'd') {
            indentedprint('dict start');
            push @statestack, BDEC_DICT_GET_KEY;
            next;
        }
        elsif($char eq 'i') {
            my $intstr;
            $char = substr($contents, $foffset++, 1);
            if(($char eq '-') || ($char eq '0'))  {
                $intstr .= $char;
                $char = substr($contents, $foffset++, 1);
            }
            my $cval = ord($char);
            if(($cval < ord('1')) || ($cval > ord('9'))) {
                indentedprint(__LINE__ .' unexpected char '.$char);
                last;
            }
            $intstr .= $char;
            while(1) {
                $char = substr($contents, $foffset++, 1);
                my $cval = ord($char);
                if(($cval < ord('0')) || ($cval > ord('9'))) {
                    if($char ne 'e') {
                        indentedprint(__LINE__ .'unexpected char');
                        exit 0;
                    }
                    indentedprint('int ' . $intstr);
                    last;
                }
                $intstr .= $char;
            }
            next;
        }
        elsif($char eq 'l') {
            indentedprint('list start');
            push @statestack, BDEC_LIST_GET_VAL;
            next;
        }
    }

    my $curbstr;
    if($char eq '0') {
        $curbstr .= $char;
        $char = substr($contents, $foffset++, 1);
        if($char ne ':') {
            indentedprint(__LINE__ .'unexpected char');
            last;
        }
    }
    else {
        while(1) {
            my $cval = ord($char);
            if(($cval < ord('0')) || ($cval > ord('9'))) {
                if(($char ne ':') || (length($curbstr) == 0)) {
                    indentedprint(__LINE__ .'unexpected char '.$char);
                    exit 0;
                }
                my $toprint = ('bstr '.$curbstr.' ') . (($curbstr < 100) ? substr($contents, $foffset, $curbstr) : '');
                indentedprint($toprint);
                $foffset += $curbstr;
                last;
            }
            $curbstr .= $char;
            $char = substr($contents, $foffset++, 1);
        }
    }


}

say "infooffset $infostart length " . ($infoend - $infostart);
