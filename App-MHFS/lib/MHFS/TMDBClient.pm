package MHFS::TMDBClient v0.7.0;
use 5.014;
use strict; use warnings;
use feature 'say';
use File::Path qw(make_path);
use Encode qw(encode_utf8);
use URI::Escape qw(uri_escape);
BEGIN {
    if( ! (eval "use JSON; 1")) {
        eval "use JSON::PP; 1" or die "No implementation of JSON available";
        warn __PACKAGE__.": Using PurePerl version of JSON (JSON::PP)";
    }
}

use MHFS::Promise;

sub new {
    my ($name, $server, $api_key) = @_;
    bless {server => $server, api_key => $api_key}, $name
}

sub _curl {
    my ($server, $params, $cb) = @_;
    my $process;
    my @cmd = ('curl', @$params);
    print "$_ " foreach @cmd;
    print "\n";
    $process = MHFS::Process->new_io_process($server->{evp}, \@cmd, sub {
        my ($output, $error) = @_;
        $cb->($output);
    });

    if(! $process) {
        $cb->(undef);
    }

    return $process;
}

sub _TMDB_api {
    my ($server, $route, $qs, $cb) = @_;
    my $url = 'https://api.themoviedb.org/3/' . $route;
    $url .= '?api_key=' . $server->{settings}{TMDB} . '&';
    if($qs){
        foreach my $key (keys %{$qs}) {
            my @values;
            if(ref($qs->{$key}) ne 'ARRAY') {
                push @values, $qs->{$key};
            }
            else {
                @values = @{$qs->{$key}};
            }
            foreach my $value (@values) {
                $url .= uri_escape($key).'='.uri_escape($value) . '&';
            }
        }
    }
    chop $url;
    return _curl($server, [encode_utf8($url)], sub {
        $cb->(decode_json($_[0]));
    });
}

sub _TMDB_api_promise {
    my ($server, $route, $qs) = @_;
    return MHFS::Promise->new($server->{evp}, sub {
        my ($resolve, $reject) = @_;
        _TMDB_api($server, $route, $qs, sub {
            $resolve->($_[0]);
        });
    });
}

sub _DownloadFile {
    my ($server, $url, $dest, $cb) = @_;
    return _curl($server, ['-k', $url, '-o', $dest], $cb);
}

sub _DownloadFile_promise {
    my ($server, $url, $dest) = @_;
    return MHFS::Promise->new($server->{evp}, sub {
        my ($resolve, $reject) = @_;
        _DownloadFile($server, $url, $dest, sub {
            $resolve->();
        });
    });
}

# returns a promise
sub search {
    my ($self, $mediatype, $query) = @_;
    _TMDB_api_promise($self->{server}, "search/$mediatype", $query)
}

# returns a promise
sub get_tv_season {
    my ($self, $series_id, $season, $query) = @_;
    _TMDB_api_promise($self->{server}, "tv/$series_id/season/$season", $query)
}

sub _get_config {
    my ($self) = @_;
    MHFS::Promise->new($self->{server}{evp}, sub {
        my ($resolve, $reject) = @_;
        if(! defined $self->{tmdbconfig}) {
            $resolve->(_TMDB_api_promise($self->{server}, 'configuration')->then( sub {
                $self->{tmdbconfig} = $_[0];
                return $_[0];
            }));
        } else {
            $resolve->($self->{tmdbconfig});
        }
    })
}

# returns a promise to path
sub get_image {
    my ($self, $image_path, $save_path) = @_;
    $self->_get_config()->then(sub {
        my ($config) = @_;
        _DownloadFile_promise($self->{server}, $config->{images}{secure_base_url}.$image_path, $save_path)->then(sub {
            $save_path
        })
    })
}

# returns a promise to path
sub get_image_from_metadata {
    my ($self, $metadata_type, $metadata, $image_type, $destdir) = @_;
    my $imagepartial = ($image_type eq 'thumb') ? ($metadata_type ne 'tv_episode' ? $metadata->{poster_path} : $metadata->{still_path}) : $metadata->{backdrop_path};
    if (!$imagepartial || $imagepartial !~ /(\.[^\.]+)$/) {
        die 'path not matched '.$imagepartial;
    }
    my $ext = $1;
    make_path($destdir);
    $self->get_image("original$imagepartial", "$destdir/$image_type$ext")
}

1;
