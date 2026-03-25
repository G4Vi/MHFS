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
    $api_key //= $server->{settings}{TMDB};
    bless {server => $server, api_key => $api_key}, $name
}

sub _curl_Promise {
    my ($server, $params) = @_;
    MHFS::Promise->new($server->{evp}, sub {
        my ($resolve, $reject) = @_;
        my @cmd = ('curl', @$params);
        print "$_ " foreach @cmd;
        print "\n";
        my $process = MHFS::Process->new_io_process($server->{evp}, \@cmd, sub {
            my ($output, $error, $exit_status) = @_;
            $resolve->({exit_code => $exit_status >> 8, stdout => $output, stderr => $error});
        });
        if(! $process) {
            $reject->('failed to start process');
        }
    })
}

sub _TMDB_api_promise {
    my ($self, $route, $qs) = @_;
    MHFS::Promise::try($self->{server}{evp}, sub {
        my $url = 'https://api.themoviedb.org/3/' . $route;
        $url .= '?api_key=' . $self->{api_key} . '&';
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
        _curl_Promise($self->{server}, ['-f', encode_utf8($url)])->then(sub {
            $_[0]->{exit_code} == 0 or die "curl to $url failed with " . $_[0]->{exit_code};
            decode_json($_[0]->{stdout})
        })
    })
}

sub _DownloadFile_promise {
    my ($server, $url, $dest) = @_;
    _curl_Promise($server, ['-f', $url, '-o', $dest])->then(sub {
        $_[0]->{exit_code} == 0 or die "curl to $url failed with " . $_[0]->{exit_code};
        undef
    })
}

# returns a promise
sub search {
    my ($self, $mediatype, $query) = @_;
    $self->_TMDB_api_promise("search/$mediatype", $query)
}

# returns a promise
sub get_tv_season {
    my ($self, $series_id, $season, $query) = @_;
    $self->_TMDB_api_promise("tv/$series_id/season/$season", $query)
}

sub _get_config {
    my ($self) = @_;
    MHFS::Promise::try($self->{server}{evp}, sub {
        return $self->{tmdbconfig} if exists $self->{tmdbconfig};
        $self->_TMDB_api_promise('configuration')->then( sub {
            $self->{tmdbconfig} = $_[0];
            $_[0]
        })
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
    my ($self, $metadata, $image_type, $destdir, $save_base) = @_;
    MHFS::Promise::try($self->{server}{evp}, sub {
        exists $metadata->{$image_type} && $metadata->{$image_type} or die "$image_type does not exist in metadata";
        my $imagepartial = $metadata->{$image_type};
        my ($ext) = $imagepartial =~ /(\.[^\.]+)$/ or die "file extension not found in $imagepartial";
        make_path($destdir);
        $self->get_image("original$imagepartial", "$destdir/$save_base$ext")
    })
}

1;
