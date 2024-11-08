package MHFS::Kodi::MovieSubtitle;
use strict; use warnings;
use File::Basename qw(basename);
sub TO_JSON {
    my ($self) = @_;
    {subtitle => $self->{subtitle}}
}
sub TO_HTML {
    my ($self) = @_;
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    my $subname = basename($self->{subtitle});
    $buf .= MHFS::Plugin::Kodi::_html_list_item("../$subname", 0, $subname);
    $buf .= '</ul>';
    $buf
}
1;
