package MHFS::Kodi::SeasonLite v0.7.0;
use 5.014;
use strict; use warnings;
use MHFS::Kodi::Util qw(html_list_item);
use MIME::Base64 qw(encode_base64url);

sub Format {
    my ($seeason, $id) = @_;
    my $plot = exists $seeason->{meta} && exists $seeason->{meta}{overview} && $seeason->{meta}{overview};
    my $editions = $seeason->{editions};
    my @sorteditems = sort {
        $editions->{$a}{name} cmp $editions->{$b}{name}
    } keys %{$editions};
    my @items = map {
        my ($source, $item) = split('/', $_, 2);
        my %item = %{$editions->{$_}};
        $item{id} = "$source/".encode_base64url($item);
        \%item
    } @sorteditems;
    {id => $id+0, items => \@items, name => "Season $id", ($plot ? (plot => $plot) : ())}
}

sub TO_JSON {
    my ($self) = @_;
    {season => Format($self->{season}, $self->{id})}
}

sub TO_HTML {
    my ($self) = @_;
    my $season = Format($self->{season}, $self->{id});
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $item (@{$season->{items}}) {
        $buf .= html_list_item($item->{name}, 1);
    }
    $buf .= '</ul>';
    $buf
}
1;
