package MHFS::Kodi::TVShows v0.7.0;
use 5.014;
use strict; use warnings;
use Cwd qw(abs_path);
use Encode qw(decode encode_utf8);
use Feature::Compat::Try;
use File::Path qw(make_path);
use File::Basename qw(basename);
use MIME::Base64 qw(decode_base64url);
BEGIN {
    if( ! (eval "use JSON; 1")) {
        eval "use JSON::PP; 1" or die "No implementation of JSON available";
        warn __PACKAGE__.": Using PurePerl version of JSON (JSON::PP)";
    }
}

use MHFS::Kodi::Util qw(html_list_item);
use MHFS::Kodi::Season;
use MHFS::Kodi::SeasonLite;
use MHFS::Promise;
use MHFS::Util qw(read_file fold_case read_text_file_lossy write_file write_text_file_lossy);

sub _read_season_meta {
    my ($self, $showid, $seasonid) = @_;
    try {
        my $bytes = read_file($self->{tvmeta}."/$showid/$seasonid/season.json");
        my $meta = decode_json($bytes);
        return (meta => $meta);
    } catch($e) {}
    return ();
}

sub _readtvdir {
    my ($self, $tvshows, $source, $b_tvdir) = @_;
    my $dh;
    if (! opendir ( $dh, $b_tvdir )) {
        warn "Error in opening dir $b_tvdir\n";
        return;
    }
    my @diritems;
    while (my $b_filename = readdir($dh)) {
        next if(($b_filename eq '.') || ($b_filename eq '..'));
        next if(!(-s "$b_tvdir/$b_filename"));
        my $filename = decode('UTF-8', $b_filename, Encode::FB_DEFAULT | Encode::LEAVE_SRC);
        next if (! -d _ && $filename !~ /\.(?:avi|mkv|mp4|m4v)$/);
        if ($filename !~ /^(.+?)(?:[\.\s]+(\d{4}))?[\.\s]+S(?:eason\s)?0*(\d+)/) {
            say "suspicious: $filename";
        }
        if ($filename =~ /S(?:eason\s)?0*(\d+)\-S(?:eason\s)?0*(\d+)/) {
            $self->_readtvdir($tvshows, $source, "$b_tvdir/$b_filename");
            next;
        }
        my $showname = $1 || $filename;
        my $year = $2;
        my $season = $3 // 0;
        next if (! $showname);
        $showname =~ s/\./ /g;
        my $showid = fold_case($showname);
        if (! $tvshows->{$showid}) {
            my %show = (name => $showname, seasons => {});
            my $plot = $self->{tvmeta}."/$showid/plot.txt";
            try { $show{plot} = read_text_file_lossy($plot); }
            catch($e) {}
            $tvshows->{$showid} = \%show;
        }
        $tvshows->{$showid}{seasons}{$season} //= {
            editions => {},
            $self->_read_season_meta($showid, $season),
        };
        $tvshows->{$showid}{seasons}{$season}{editions}{"$source/$b_filename"} = {name => $filename, isdir => (-d _ // 0)+0};
    }
    closedir($dh);
}

sub build_tv_library {
    my ($self) = @_;
    my $sources = $self->{sources};
    my %tvshows;
    foreach my $source (@$sources) {
        if ($self->{server}{settings}{SOURCES}{$source}{type} ne 'local') {
            warn "skipping source $source, only local implemented";
            next;
        }
        my $b_tvdir = $self->{server}{settings}{SOURCES}{$source}{folder};
        $self->_readtvdir(\%tvshows, $source, $b_tvdir);
    }
    $self->{tvshows} = \%tvshows;
}

sub new {
    my ($name, $server, $tvmeta, $tmdb_client) = @_;
    my %optional = (
        ($tmdb_client ? (tmdb => $tmdb_client) : ()),
    );
    my $self = bless {server => $server, sources => $server->{settings}{MEDIASOURCES}{tv}, tvmeta => $tvmeta, %optional}, $name;
    $self->build_tv_library();
    $self
}

sub get_tv_item {
    my ($self, $showid, $seasonid, $source, $b64_item) = @_;
    my $tvshows = $self->{tvshows};
    exists $tvshows->{$showid} or die "showid $showid does not exist";
    exists $tvshows->{$showid}{seasons}{$seasonid} or die "season $seasonid does not exist";
    my $seasonitem = $tvshows->{$showid}{seasons}{$seasonid};
    my $sourcemap = $self->{server}{settings}{SOURCES};
    $source or return bless {season => $seasonitem, id => $seasonid, sourcemap => $sourcemap}, 'MHFS::Kodi::Season';
    $b64_item or die "b64_item not provided";
    my $path = abs_path($self->{server}{settings}{SOURCES}{$source}{folder} .'/' . decode_base64url($b64_item));
    if (!$path || rindex($path, $self->{server}{settings}{SOURCES}{$source}{folder}, 0) != 0 || ! -f $path) {
        die "item not found";
    }
    {b_path => $path}
}

sub get_plot {
    my ($self, $showid, $seasonid, $episode) = @_;
    my $item = $self->{tvshows};
    exists $item->{$showid} or die "showid $showid does not exist";
    $item = $item->{$showid};
    $seasonid // do {
        exists $item->{plot} or die "showid $showid does not have plot yet";
        return $item->{plot};
    };
    exists $item->{seasons}{$seasonid} or die "showid $showid season $seasonid does not exist";
    $item = $item->{seasons}{$seasonid};
    exists $item->{meta} or die "showid $showid season $seasonid does have metadata yet";
    my $meta = $item->{meta};
    $episode // do {
        exists $meta->{overview} or die "showid $showid season $seasonid does not have plot yet";
        return $meta->{overview};
    };
    $meta = MHFS::Kodi::Season::_get_season_episode($meta, $episode);
    exists $meta->{overview} or die "showid $showid season $seasonid episode $episode does not have plot yet";
    $meta->{overview}
}

# IF NOT EXISTS unless $force_update is true
sub insert_season_metadata {
    my ($self, $showid, $seasonid, $metadata, $force_update) = @_;
    my $item = $self->{tvshows};
    exists $item->{$showid} or die "showid $showid does not exist";
    $item = $item->{$showid};
    exists $item->{seasons}{$seasonid} or die "showid $showid season $seasonid does not exist";
    $item = $item->{seasons}{$seasonid};
    return if (exists $item->{meta} && !$force_update);
    my $b_metadir = $self->{tvmeta} . '/' . encode_utf8($showid) . '/' . encode_utf8($seasonid);
    make_path($b_metadir);
    my $bytes = encode_json($metadata);
    write_file("$b_metadir/season.json", $bytes);
    $item->{meta} = $metadata;
}

# IF NOT EXISTS unless $force_update is true
sub insert_show_plot {
    my ($self, $showid, $metadata, $force_update) = @_;
    exists $metadata->{overview} or die "metadata does not have plot";
    my $plot = $metadata->{overview};
    my $item = $self->{tvshows};
    exists $item->{$showid} or die "showid $showid does not exist";
    $item = $item->{$showid};
    return if (exists $item->{plot} && !$force_update);
    my $b_metadir = $self->{tvmeta} . '/' . encode_utf8($showid);
    make_path($b_metadir);
    write_text_file_lossy("$b_metadir/plot.txt", $plot);
    $item->{plot} = $plot;
}

# returns a promise
sub fetch_metadata {
    my ($self, $metadatatype, $medianame, $season, $episode) = @_;
    # tv fastest path, grab from the db
    if ($metadatatype eq 'plot') {
        try {
            my $plot = $self->get_plot($medianame, $season, $episode);
            say "fastest path";
            my $result = {text => $plot};
            return MHFS::Promise->new($self->{server}{evp}, sub {
                my ($resolve, $reject) = @_;
                $resolve->($result);
            });
        } catch ($e) {}
    }
    my $b_metadir = $self->{tvmeta} . '/' . encode_utf8($medianame) . (defined $season ? '/'.encode_utf8($season). (defined $episode ? '/'.encode_utf8($episode) : '') : '');
    # fast path, check disk
    if ($metadatatype ne 'plot' && -d $b_metadir) {
        my %acceptable = ( 'thumb' => ['png', 'jpg'], 'fanart' => ['png', 'jpg']);
        if (exists $acceptable{$metadatatype}) {
            foreach my $totry (@{$acceptable{$metadatatype}}) {
                my $path = $b_metadir.'/'.$metadatatype.".$totry";
                if (-f $path) {
                    return MHFS::Promise->new($self->{server}{evp}, sub {
                        my ($resolve, $reject) = @_;
                        $resolve->({file => $path});
                    });
                }
            }
        }
    }
    # slow path, download it
    exists $self->{tmdb} or die "cannot load metadata without tmdb";
    my $tmdb = $self->{tmdb};
    # find the movie or tv show
    my $searchname = $medianame;
    say "searchname $searchname";
    return $tmdb->search('tv', {'query' => $searchname})->then(sub {
        my $json = $_[0]->{results}[0];
        $json or die "Failed to find item";
        $self->insert_show_plot($medianame, $json, ! defined $season && $metadatatype eq 'plot');
        $season // return $json;
        # find the season and then the episode if applicable
        my $showid = $json->{id} // die "showid not available";
        $tmdb->get_tv_season($showid, $season)->then(sub {
            $self->insert_season_metadata($medianame, $season, $_[0], $metadatatype eq 'plot');
            $episode // return $_[0];
            MHFS::Kodi::Season::_get_season_episode($_[0], $episode)
        })
    })->then(sub {
        if ($metadatatype eq 'plot') {
            return {text => $_[0]->{overview}};
        }
        my $image_type = ($metadatatype eq 'thumb') ? (! defined $episode ? 'poster_path' : 'still_path') : 'backdrop_path';
        $tmdb->get_image_from_metadata($_[0], $image_type, $b_metadir, $metadatatype)->then(sub {
            {file => $_[0]}
        })
    });
}

sub Format {
    my ($tvvshows) = @_;
    my @sortedkeys = sort {basename($a) cmp basename($b)} keys %$tvvshows;
    my @tvshows = map {
        my %tvshow = %{$tvvshows->{$_}};
        my @sortedseasons = sort keys %{$tvshow{seasons}};
        my @seasons = map {
            my $season = $tvshow{seasons}{$_};
            MHFS::Kodi::SeasonLite::Format($season, $_)
        } @sortedseasons;
        $tvshow{seasons} = \@seasons;
        \%tvshow
    } @sortedkeys;
    \@tvshows
}

sub TO_JSON {
    my ($self) = @_;
    {tvshows => Format($self->{tvshows})}
}

sub TO_HTML {
    my ($self) = @_;
    my $tvshows = Format($self->{tvshows});
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $tvshow (@$tvshows) {
        $buf .= html_list_item($tvshow->{name}, 1);
    }
    $buf .= '</ul>';
    $buf
}
1;
