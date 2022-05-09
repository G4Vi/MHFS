#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use Data::Dumper;

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

# a node is an array with the first element being the type, followed by the value(s)
# ('int', iv)          - integer node, MUST have one integer value, bencoded as iIVe
# ('bstr', bytestring) - byte string node, MUST have one bytestring value, bencoded as bytestringLength:bytestring where bytestringLength is the length as ASCII numbers
# ('l', values)        - list node, MAY have one or more values of type int, bstr, list, and dict bencoded as lVALUESe
# ('d', kvpairs)       - dict node, special case of list, MAY one or more key and value pairs. A dict node MUST have multiple of 2 values; a bstr key with corespoding value
# ('null', value)      - null node, MAY have one value, used internally by bdecode to avoid dealing with the base case of no parent
# ('e')                - end node, MUST NOT have ANY values, used internally by bencode to handle writing list/dict end

sub bdecode {
    my ($contents, $foffset) = @_;
    my @headnode = ('null');
    my @nodestack = (\@headnode);
    my $startoffset = $foffset;

    while(1) {
        # a bstr is always valid as it can be a dict key
        if(substr($$contents, $foffset) =~ /^(0|[1-9][0-9]*):/) {
            my $count = $1;
            $foffset += length($count)+1;
            my $bstr = substr($$contents, $foffset, $count);
            my $node = ['bstr', $bstr];
            $foffset += $count;
            push @{$nodestack[-1]}, $node;
        }
        elsif(($nodestack[-1][0] ne 'd') || ((scalar(@{$nodestack[-1]}) % 2) == 0)) {
            my $firstchar = substr($$contents, $foffset++, 1);
            if(($firstchar eq 'd') || ($firstchar eq 'l')) {
                my $node = [$firstchar];
                push @{$nodestack[-1]}, $node;
                push @nodestack, $node;
            }
            elsif(substr($$contents, $foffset-1) =~ /^i(0|\-?[1-9][0-9]*)e/) {
                my $node = ['int', $1];
                $foffset += length($1)+1;
                push @{$nodestack[-1]}, $node;
            }
            else {
                say "bad elm $firstchar $foffset";
                return undef;
            }
        }
        elsif((substr($$contents, $foffset, 1) eq 'e') &&
        (scalar(@nodestack) != 1) &&
        (($nodestack[-1][0] ne 'd') || ((scalar(@{$nodestack[-1]}) % 2) == 1)))
        {
            pop @nodestack;
            $foffset++;
        }
        else {
            say "bad elm $foffset";
            return undef;
        }

        if(scalar(@nodestack) == 1) {
            return [$headnode[1], $foffset-$startoffset];
        }
    }
}

sub bencode {
    my ($node) = @_;
    my @toenc = ($node);
    my $output;

    while(my $node = shift @toenc) {
        my $type = $node->[0];
        if(($type eq 'd') || ($type eq 'l')) {
            $output .= $type;
            my @nextitems = @{$node};
            shift @nextitems;
            push @nextitems, ['e'];
            unshift @toenc, @nextitems;
        }
        elsif($type eq 'bstr') {
            $output .= sprintf("%u:%s", length($node->[1]), $node->[1]);
        }
        elsif($type eq 'int') {
            $output .= 'i'.$node->[1].'e';
        }
        elsif($type eq 'e') {
            $output .= 'e';
        }
        else {
            return undef;
        }
    }

    return $output;
}

sub bdictfind {
    my ($node, $keys, $valuetype) = @_;
    NEXTKEY: foreach my $key (@{$keys}) {
        if($node->[0] ne 'd') {
            say "cannot search non dictionary";
            return undef;
        }
        for(my $i = 1; $i < scalar(@{$node}); $i+=2) {
            if($node->[$i][1] eq $key) {
                $node = $node->[$i+1];
                last NEXTKEY;
            }
        }
        say "failed to find key $key";
        return undef;
    }
    if(($valuetype) && ($node->[0] ne $valuetype)) {
        say "node has wrong type, expected $valuetype got ". $node->[0];
        return undef;
    }
    return $node;
}

sub bdictgetkeys {
    my ($node) = @_;
    if($node->[0] ne 'd') {
        say "cannot search non dictionary";
        return undef;
    }
    my @keys;
    for(my $i = 1; $i < scalar(@{$node}); $i+=2) {
        push @keys, $node->[$i][1];
    }
    return \@keys;
}

my $contents = read_file($ARGV[0]);
my $ret = bdecode(\$contents, 0);
defined($ret) or die('failed to bedecode');
say 'readlen ' . $ret->[1];
my $headnode = $ret->[0];

my $reenc = bencode($headnode);
defined($reenc) or die('failed to bencode');
say "reenc length " . length($reenc);
write_file('out.torrent', $reenc);

my $infohashnode = bdictfind($headnode, ['info'], 'd');
$infohashnode or die("didn't find infohash");
write_file('out.infohash', bencode($infohashnode));

my $dkeys = bdictgetkeys($headnode);
foreach my $key (@{$dkeys}) {
    say "key: $key";
}

my $ikeys = bdictgetkeys($infohashnode);
foreach my $key (@{$ikeys}) {
    say "key: $key";
}

