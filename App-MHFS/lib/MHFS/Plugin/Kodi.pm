package MHFS::Plugin::Kodi v0.7.0;
use 5.014;
use strict; use warnings;
use feature 'say';
use Encode qw(encode_utf8);
use Feature::Compat::Try;
use File::Path qw(make_path);
use Scalar::Util qw(weaken);
use MHFS::Kodi::Movies;
use MHFS::Kodi::TVShows;
use MHFS::Process;
use MHFS::Promise;
use MHFS::TMDBClient;
use MHFS::Util qw(base64url_to_str write_text_file_lossy decode_utf_8 fold_case);
BEGIN {
    if( ! (eval "use JSON; 1")) {
        eval "use JSON::PP; 1" or die "No implementation of JSON available";
        warn __PACKAGE__.": Using PurePerl version of JSON (JSON::PP)";
    }
}

sub _get_tmdb_instance {
    my ($self) = @_;
    exists $self->{server}{settings}{TMDB} or die "no TMDB api key set";
    my $api_key = $self->{server}{settings}{TMDB};
    $self->{tmdb} //= MHFS::TMDBClient->new($self->{server}, $api_key)
}

sub _get_tvshows_instance {
    my ($self, $force_reload) = @_;
    my $tmdb;
    try {$tmdb = $self->_get_tmdb_instance()}
    catch ($e){print $e}
    if (! exists $self->{tvshows}) {
        $self->{tvshows} = MHFS::Kodi::TVShows->new($self->{server}, $self->{tvmeta}, $tmdb);
        return $self->{tvshows};
    }
    $self->{tvshows}->build_tv_library() if $force_reload;
    $self->{tvshows}
}

sub _get_movies_instance {
    my ($self, $force_reload) = @_;
    my $tmdb;
    try {$tmdb = $self->_get_tmdb_instance()}
    catch ($e){print $e}
    if (! exists $self->{movies}) {
        $self->{movies} = MHFS::Kodi::Movies->new($self->{server}, $self->{moviemeta}, $tmdb);
        return $self->{movies};
    }
    $self->{movies}->build_movie_library() if $force_reload;
    $self->{movies}
}

# format tv library for kodi http
sub route_tv {
    my ($self, $request, $sources, $kodidir) = @_;
    my $request_path = do {
        try { decode_utf_8($request->{path}{unsafepath}) }
        catch($e) {
            warn "$request->{path}{unsafepath} is not, UTF-8, 404";
            $request->Send404;
            return;
        }
    };
    my $tvshows = $self->_get_tvshows_instance($request_path eq $kodidir);
    my $tvitem;
    if ($request_path ne $kodidir) {
        my $fulltvpath = substr($request_path, length($kodidir)+1);
        say "fulltvpath $fulltvpath";
        my ($showid, $season, $source, $b64_item, $slurp) = split('/', $fulltvpath, 5);
        if ($slurp) {
            say "too many parts";
            $request->Send400;
            return;
        }
        $showid = fold_case($showid);
        $season // do {
            say "no season provided";
            $request->Send400;
            return;
        };
        try {
            $tvitem = $tvshows->get_tv_item($showid, $season, $source, $b64_item);
        } catch($e) {
            say "exception $e";
            $request->Send404;
            return;
        }
        if (substr($request->{'path'}{'unescapepath'}, -1) ne '/') {
            # redirect if we aren't accessing a file
            if (!exists $tvitem->{b_path}) {
                $request->SendRedirect(301, substr($request->{'path'}{'unescapepath'}, rindex($request->{'path'}{'unescapepath'}, '/')+1).'/');
            } else {
                $request->SendFile($tvitem->{b_path});
            }
            return;
        }
    } else {
        $tvitem = $tvshows;
    }
    if(exists $request->{qs}{fmt} && $request->{qs}{fmt} eq 'html') {
        my $buf = $tvitem->TO_HTML;
        $request->SendHTML($buf);
    } else {
        my $diritems = $tvitem->TO_JSON;
        $request->SendAsJSON($diritems);
    }
}

# format movies library for kodi http
sub route_movies {
    my ($self, $request, $sources, $kodidir) = @_;
    my $request_path = do {
        try { decode_utf_8($request->{path}{unsafepath}) }
        catch($e) {
            warn "$request->{path}{unsafepath} is not, UTF-8, 404";
            $request->Send404;
            return;
        }
    };
    my $movies = $self->_get_movies_instance($request_path eq $kodidir);
    my $movieitem;
    if($request_path ne $kodidir) {
        my $fullmoviepath = substr($request_path, length($kodidir)+1);
        say "fullmoviepath $fullmoviepath";
        my ($movieid, $source, $b64_editionname, $b64_partname, $b64_subpath, $subname, $slurp) = split('/', $fullmoviepath, 7);
        if ($slurp) {
            say "too many parts";
            $request->Send404;
            return;
        }
        say "movieid $movieid";
        my $editionname;
        my $partname;
        my $subfile;
        try {
            if ($source) {
                say "source $source";
                if ($b64_editionname) {
                    $editionname = base64url_to_str($b64_editionname);
                    say "editionname $editionname";
                    if ($b64_partname) {
                        if (length($b64_partname) < 3) {
                            warn "$b64_partname has invalid format";
                            $request->Send404;
                            return;
                        }
                        $b64_partname = substr($b64_partname, 0, -3);
                        $partname = base64url_to_str($b64_partname);
                        say "partname $partname";
                        if ($b64_subpath && $subname) {
                            if (length($b64_subpath) < 3) {
                                warn "$b64_subpath has invalid format";
                                $request->Send404;
                                return;
                            }
                            $b64_subpath = substr($b64_subpath, 0, -3);
                            my $subpath = base64url_to_str($b64_subpath);
                            $subfile = "$subpath$subname";
                            say "subfile $subfile";
                        }
                    }
                }
            }
            $movieitem = $movies->get_movie_item($movieid, $source, $editionname, $partname, $subfile);
        } catch ($e) {
            $request->Send404;
            return;
        }
        if (substr($request->{'path'}{'unescapepath'}, -1) ne '/') {
            # redirect if we aren't accessing a file
            if (!exists $movieitem->{b_path}) {
                $request->SendRedirect(301, substr($request->{'path'}{'unescapepath'}, rindex($request->{'path'}{'unescapepath'}, '/')+1).'/');
            } else {
                $request->SendFile($movieitem->{b_path});
            }
            return;
        }
    } else {
        $movieitem = $movies;
    }
    # render
    if(exists $request->{qs}{fmt} && $request->{qs}{fmt} eq 'html') {
        my $buf = $movieitem->TO_HTML;
        $request->SendHTML($buf);
    } else {
        my $diritems = $movieitem->TO_JSON;
        $request->SendAsJSON($diritems);
    }
}

sub route_kodi {
    my ($self, $request, $kodidir) = @_;
    my $request_path = do {
        try { decode_utf_8($request->{path}{unsafepath}) }
        catch($e) {
            warn "$request->{path}{unsafepath} is not, UTF-8, 404";
            $request->Send404;
            return;
        }
    };
    my $baseurl = $request->getAbsoluteURL;
    my $repo_addon_version = '0.1.0';
    my $repo_addon_name = "repository.mhfs-$repo_addon_version.zip";
    if ($request_path eq $kodidir) {
        my $html = <<"END_HTML";
<style>ul{list-style: none;} li{margin: 10px 0;}</style>
<h1>MHFS Kodi Setup Instructions</h1>
<ol>
<li>Open Kodi</li>
<li>Go to <b>Settings->File manager</b>, <b>Add source</b> (you may have to double-click), and add <b>$baseurl$kodidir</b> (the URL of this page) as a source.</li>
<li>Go to <b>Settings->Add-ons->Install from zip file</b>, open the source you just added, and select <b>$repo_addon_name</b>. The repository add-on should install.</li>
<li>From <b>Settings->Add-ons</b> (you should still be on that page), <b>Install from repository->MHFS Repository->Video add-ons->MHFS Video</b> and click <b>Install</b>. The plugin addon should install.</li>
<li>Click <b>Configure</b> (or open the MHFS Video settings) and fill in <b>$baseurl</b> (the URL of the MHFS server you want to connect to).</li>
<li>MHFS Video should now be installed, you should be able to access it from <b>Add-ons->Video add-ons->MHFS Video</b> on the main menu</li>
</ol>
<ul>
<a href="$repo_addon_name">$repo_addon_name</a>
</ul>
END_HTML
        $request->SendHTML($html);
        return;
    } elsif (substr($request_path, length($kodidir)+1) ne $repo_addon_name ||
                substr($request->{'path'}{'unescapepath'}, -1) eq '/') {
        $request->Send404;
        return;
    }
    my $xml = <<"END_XML";
<?xml version="1.0" encoding="UTF-8"?>
<addon id="repository.mhfs"
    name="MHFS Repository"
    version="$repo_addon_name"
    provider-name="G4Vi">
<extension point="xbmc.addon.repository" name="MHFS Repository">
<dir>
    <info>$baseurl/static/kodi/addons.xml</info>
    <checksum>$baseurl/static/kodi/addons.xml.md5</checksum>
    <datadir zip="true">$baseurl/static/kodi</datadir>
</dir>
</extension>
<extension point="xbmc.addon.metadata">
<summary lang="en_GB">MHFS Repository</summary>
<description lang="en_GB">TODO</description>
<disclaimer></disclaimer>
<platform>all</platform>
<language></language>
<license>GPL-2.0-or-later</license>
<forum>https://github.com/G4Vi/MHFS/issues</forum>
<website>computoid.com</website>
<source>https://github.com/G4Vi/MHFS</source>
</extension>
</addon>
END_XML
    my $tmpdir = $request->{client}{server}{settings}{GENERIC_TMPDIR};
    say "tmpdir $tmpdir";
    my $addondir = "$tmpdir/repository.mhfs";
    make_path($addondir);
    open(my $fh, '>', "$addondir/addon.xml") or do {
        warn "failed to open $addondir/addon.xml";
        $request->Send404;
        return;
    };
    print $fh $xml;
    close($fh) or do {
        warn "failed to close";
        $request->Send404;
        return;
    };
    _zip_Promise($request->{client}{server}, $tmpdir, ['repository.mhfs'])->then(sub {
        $request->SendBytes('application/zip', $_[0]);
    }, sub {
        warn $_[0];
        $request->Send404;
    });
}

sub _zip {
    my ($server, $start_in, $params, $on_success, $on_failure) = @_;
    MHFS::Process->new_output_child($server->{evp}, sub {
        # done in child
        my ($datachannel) = @_;
        chdir($start_in);
        open(STDOUT, ">&", $datachannel) or die("Can't dup \$datachannel to STDOUT");
        exec('zip', '-r', '-', @$params);
        #exec('zip', '-r', 'repository.mhfs.zip', 'repository.mhfs');
        die "failed to run zip";
    }, sub {
        my ($out, $err, $status) = @_;
        if ($status != 0) {
            $on_failure->('failed to zip');
            return;
        }
        $on_success->($out);
    }) // $on_failure->('failed to fork');
}

sub _zip_Promise {
    my ($server, $start_in, $params) = @_;
    return MHFS::Promise->new($server->{evp}, sub {
        my ($resolve, $reject) = @_;
        _zip($server, $start_in, $params, sub {
            $resolve->($_[0]);
        }, sub {
            $reject->($_[0]);
        });
    });
}

sub DirectoryRoute {
    my ($path_without_end_slash, $cb) = @_;
    return ([
        $path_without_end_slash, sub {
            my ($request) = @_;
            $request->SendRedirect(301, substr($path_without_end_slash, rindex($path_without_end_slash, '/')+1).'/');
        }
    ], [
        "$path_without_end_slash/*", $cb
    ]);
}

sub route_metadata {
    my ($self, $request) = @_;
    my $request_path = do {
        try { decode_utf_8($request->{path}{unsafepath}) }
        catch($e) {
            warn "$request->{path}{unsafepath} is not, UTF-8, 400";
            $request->Send400;
            return;
        }
    };
    my ($mediatype, $metadatatype, $medianame, $season, $episode) = $request_path =~ m!^/kodi/metadata/(movies|tv)/(thumb|fanart|plot)/([^/]+)(?:/0*(\d+)(?:/0*(\d+))?)?$! or do {
        say "no match";
        $request->Send400;
        return;
    };
    if ($medianame =~ /^.(.)?$/ || ($mediatype eq 'movies' && defined $season)) {
        say "no match";
        $request->Send400;
        return;
    }
    if ($metadatatype eq 'fanart') {
        ($season, $episode) = (undef, undef);
    }
    $medianame = fold_case($medianame);
    say "mt $mediatype mmt $metadatatype mn $medianame". (defined $season ? " season $season". (defined $episode ? " episode $episode" : '') : '');
    my $library;
    if ($mediatype eq 'tv') {
        $library = $self->_get_tvshows_instance();
    } elsif ($mediatype eq 'movies') {
        $library = $self->_get_movies_instance();
    } else {
        $request->Send500;
        return;
    }
    weaken($request);
    $library->fetch_metadata($metadatatype, $medianame, $season, $episode)->then(sub {
        my ($result) = @_;
        if ($result->{file}) {
            $request->SendLocalFile($result->{file});
        } elsif ($result->{text}) {
            $request->SendText('text/plain; charset=utf-8', $result->{text});
        } else {
            die "unknown result type";
        }
    })->then(undef, sub {
        print $_[0];
        say "fetch_metadata failure";
        $request->Send404;
    });
    return;
}

sub new {
    my ($class, $settings) = @_;
    my $self =  {};
    bless $self, $class;

    my @subsystems = ('video');
    $self->{moviemeta} = $settings->{'DATADIR'}.'/movies';
    $self->{tvmeta} = $settings->{'DATADIR'}.'/tv';
    make_path($self->{moviemeta}, $self->{tvmeta});

    $self->{'routes'} = [
        DirectoryRoute('/kodi/movies', sub {
            my ($request) = @_;
            route_movies($self, $request, $settings->{'MEDIASOURCES'}{'movies'}, '/kodi/movies');
        }),
        DirectoryRoute('/kodi/tv', sub {
            my ($request) = @_;
            route_tv($self, $request, $settings->{'MEDIASOURCES'}{'tv'}, '/kodi/tv');
        }),
        ['/kodi/metadata/*', sub {
            my ($request) = @_;
            route_metadata($self, $request);
        }],
        DirectoryRoute('/kodi', sub {
            my ($request) = @_;
            route_kodi($self, $request, '/kodi');
        }),
    ];

    return $self;
}


1;
