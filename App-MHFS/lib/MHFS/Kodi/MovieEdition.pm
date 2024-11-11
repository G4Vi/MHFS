package MHFS::Kodi::MovieEdition v0.7.0;
use 5.014;
use strict; use warnings;

sub TO_JSON {
    my ($self) = @_;
    {edition => MHFS::Plugin::Kodi::_format_movie_edition($self->{source}, $self->{editionname}, $self->{edition})}
}

sub TO_HTML {
    my ($self) = @_;
    my $parts = $self->TO_JSON()->{edition}{parts};
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $part (@$parts) {
        $buf .= MHFS::Plugin::Kodi::_html_list_item($part->{id}, 1, $part->{name});
    }
    $buf .= '</ul>';
    $buf
}
1;
