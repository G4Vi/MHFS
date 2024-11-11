package MHFS::Kodi::Movies v0.7.0;
use 5.014;
use strict; use warnings;

sub TO_JSON {
    my ($self) = @_;
    {movies => MHFS::Plugin::Kodi::_format_movies($self->{movies})}
}

sub TO_HTML {
    my ($self) = @_;
    my $movies = $self->TO_JSON()->{movies};
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $movie (@$movies) {
        $buf .= MHFS::Plugin::Kodi::_html_list_item($movie->{id}, 1);
    }
    $buf .= '</ul>';
    $buf
}
1;
