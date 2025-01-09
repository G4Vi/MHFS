package MHFS::Kodi::MoviePart v0.7.0;
use 5.014;
use strict; use warnings;
use File::Basename qw(basename);

sub TO_JSON {
    my ($self) = @_;
    {part => MHFS::Plugin::Kodi::_format_movie_part($self->{editionname}, $self->{partname}, $self->{part})}
}
sub TO_HTML {
    my ($self) = @_;
    my $part = $self->TO_JSON()->{part};
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    $buf .= MHFS::Plugin::Kodi::_html_list_item("../".$part->{id}, 0, $part->{name});
    if (exists $part->{subs}) {
        foreach my $sub (@{$part->{subs}}) {
            $buf .= MHFS::Plugin::Kodi::_html_list_item($sub, 0, basename($sub));
        }
    }
    $buf .= '</ul>';
    $buf
}
1;
