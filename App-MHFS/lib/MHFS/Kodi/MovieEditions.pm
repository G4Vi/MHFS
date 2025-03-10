package MHFS::Kodi::MovieEditions v0.7.0;
use 5.014;
use strict; use warnings;

sub TO_JSON {
    my ($self) = @_;
    {editions => MHFS::Plugin::Kodi::_format_movie_editions($self->{editions})}
}

sub TO_HTML {
    my ($self) = @_;
    my $editions = $self->TO_JSON()->{editions};
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $edition (@$editions) {
        $buf .= MHFS::Plugin::Kodi::_html_list_item("../".$edition->{id}, 1, $edition->{name});
    }
    $buf .= '</ul>';
    $buf
}
1;
