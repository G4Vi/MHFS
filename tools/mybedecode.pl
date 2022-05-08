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

sub write_file {
    my ($filename, $text) = @_;
    open (my $fh, '>', $filename) or die("$! $filename");
    print $fh $text;
    close($fh);
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
my $headnode = ['dict', undef];
my $curnode = $headnode;

sub _node_addchild {
    my ($node, $chld) = @_;
    push @{$node}, $chld;
}

use Scalar::Util qw(weaken);
sub node_addchilddict {
    my ($node) = @_;
    weaken($node);
    my $dictnode = ['dict', $node];
    _node_addchild($node, $dictnode);
    return $dictnode;
}

sub node_addchildlist {
    my ($node) = @_;
    weaken($node);
    my $listnode = ['list', $node];
    _node_addchild($node, $listnode);
    return $listnode;
}

sub node_addinteger {
    my ($node, $val) = @_;
    my $chldnode = ['int', $val];
    _node_addchild($node, $chldnode);
}

sub node_addbstr {
    my ($node, $val) = @_;
    my $chldnode = ['bstr', $val];
    _node_addchild($node, $chldnode);
}

sub node_parent {
    my ($node) = @_;
    return $node->[1];
}

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
            $curnode = node_parent($curnode);
            next;
        }
    }
    # Change the next dictionary operation (at this level) between GET_KEY and GET_VAL (if it's a dictionary)
    $statestack[-1] ^= BDEC_DICT_TOGGLE;
    if($curstate & BDEC_GET_VAL) {
        if($char eq 'd') {
            indentedprint('dict start');
            push @statestack, BDEC_DICT_GET_KEY;
            $curnode = node_addchilddict($curnode);
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
                    last;
                }
                $intstr .= $char;
            }
            indentedprint('int ' . $intstr);
            node_addinteger($curnode, $intstr);
            next;
        }
        elsif($char eq 'l') {
            indentedprint('list start');
            push @statestack, BDEC_LIST_GET_VAL;
            $curnode = node_addchildlist($curnode);
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
                last;
            }
            $curbstr .= $char;
            $char = substr($contents, $foffset++, 1);
        }
    }
    my $toprint = ('bstr '.$curbstr.' ') . (($curbstr < 100) ? substr($contents, $foffset, $curbstr) : '');
    indentedprint($toprint);
    node_addbstr($curnode, substr($contents, $foffset, $curbstr));
    $foffset += $curbstr;
}

use Data::Dumper;

print Dumper($headnode);

sub bencode {
    my ($node) = @_;
    my $output;

    my $type = $node->[0];
    if($type eq 'dict') {
        $output .= 'd';
        for(my $i = 2; $i < scalar(@{$node});) {
            my $key = $node->[$i++];
            $output .= bencode($key);
            my $value = $node->[$i++];
            $output .= bencode($value);
        }
        $output .= 'e';
    }
    elsif($type eq 'list') {
        $output .= 'l';
        for(my $i = 2; $i < scalar(@{$node}); $i++) {
            my $value = $node->[$i];
            $output .= bencode($value);
        }
        $output .= 'e';
    }
    elsif($type eq 'bstr') {
        $output .= sprintf("%u:%s", length($node->[1]), $node->[1]);
    }
    elsif($type eq 'int') {
        $output .= 'i'.$node->[1].'e';
    }

    return $output;
}

my $reenc = bencode($headnode);
say "reenc length " . length($reenc);
write_file('out.torrent', $reenc);

my $infohashnode;
for(my $i = 2; $i < scalar(@{$headnode}); $i += 2) {
    if(($headnode->[$i][1] eq 'info') && ($headnode->[$i+1][0] eq 'dict')) {
        $infohashnode = $headnode->[$i+1];
        say "found infohash";
        last;
    }
}
$infohashnode or die("didn't find infohahs");
write_file('out.infohash', bencode($infohashnode));

