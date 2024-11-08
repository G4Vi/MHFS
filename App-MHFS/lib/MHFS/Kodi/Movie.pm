package MHFS::Kodi::Movie;
use strict; use warnings;

sub TO_JSON {
    my ($self) = @_;
    my %movie = %{$self->{movie}};
    $movie{editions} = MHFS::Plugin::Kodi::_format_movie_editions($movie{editions});
    {movie => \%movie}
}

sub TO_HTML {
    my ($self) = @_;
    my $editions = $self->TO_JSON()->{movie}{editions};
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $edition (@$editions) {
        $buf .= MHFS::Plugin::Kodi::_html_list_item($edition->{id}, 1, $edition->{name});
    }
    $buf .= '</ul>';
    $buf
}
1;
