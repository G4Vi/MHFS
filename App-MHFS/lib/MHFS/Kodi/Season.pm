package MHFS::Kodi::Season v0.7.0;
use 5.014;
use strict; use warnings;
use Encode qw(decode);
use MHFS::Kodi::Util qw(html_list_item);
use MIME::Base64 qw(encode_base64url);

sub _encode_item {
    my ($id, $fullname) = @_;
    my ($prefix, $itemname) = split(/S\d+[\s\.]*/i, $fullname, 2);
    $itemname //= $fullname;
    {id => $id, name => $itemname}
}

sub _read_season_dir {
    my ($unsorted, $source, $b_path) = @_;
    opendir(my $dh, $b_path) or return;
    while(my $b_file = readdir $dh) {
        next if ($b_file eq '.' || $b_file eq '..');
        my $newsource = "$source/$b_file";
        if (! -d $b_file) {
            my ($actualsource, $item) = split('/', $newsource, 2);
            my $id = "$actualsource/".encode_base64url($item);
            my $name = decode('UTF-8', $b_file, Encode::FB_DEFAULT | Encode::LEAVE_SRC);
            push @$unsorted, _encode_item($id, $name);
            next;
        }
        _read_season_dir($unsorted, $newsource, "$b_path/$b_file");
    } 
}

sub Format {
    my ($seeason, $id, $sourcemap) = @_;
    my @unsorted;
    foreach my $path (keys %$seeason) {
        my ($source, $item) = split('/', $path, 2);
        if (!$seeason->{$path}{isdir}) {
            push @unsorted, _encode_item("$source/".encode_base64url($item), $seeason->{$path}{name});
            next;
        }
        my $b_path = $sourcemap->{$source}{folder}."/$item";
        _read_season_dir(\@unsorted, $path, $b_path);
    }
    my @season = sort {
        $a->{name} cmp $b->{name}
    } @unsorted;
    my @items = @season;
    {id => $id+0, items => \@items, name => "Season $id"}
}

sub TO_JSON {
    my ($self) = @_;
    {season => Format($self->{season}, $self->{id}, $self->{sourcemap})}
}

sub TO_HTML {
    my ($self) = @_;
    my $season = Format($self->{season}, $self->{id}, $self->{sourcemap});
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $item (@{$season->{items}}) {
        $buf .= html_list_item($item->{name}, 1);
    }
    $buf .= '</ul>';
    $buf
}
1;
