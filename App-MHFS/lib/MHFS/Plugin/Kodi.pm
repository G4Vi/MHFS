package MHFS::Plugin::Kodi v0.7.0;
use 5.014;
use strict; use warnings;
use feature 'say';
use File::Basename qw(basename);
use Cwd qw(abs_path getcwd);
use URI::Escape qw(uri_escape);
use Encode qw(decode encode encode_utf8);
use File::Path qw(make_path);
use Data::Dumper qw(Dumper);
use Scalar::Util qw(weaken);
use MIME::Base64 qw(encode_base64url decode_base64url);
use Devel::Peek qw(Dump);
use MHFS::Kodi::Movie;
use MHFS::Kodi::MovieEdition;
use MHFS::Kodi::MovieEditions;
use MHFS::Kodi::MoviePart;
use MHFS::Kodi::Movies;
use MHFS::Kodi::MovieSubtitle;
use MHFS::Process;
use MHFS::Promise;
use MHFS::Util qw(base64url_to_str str_to_base64url uri_escape_path_utf8 read_text_file_lossy);
use Feature::Compat::Try;
BEGIN {
    if( ! (eval "use JSON; 1")) {
        eval "use JSON::PP; 1" or die "No implementation of JSON available";
        warn __PACKAGE__.": Using PurePerl version of JSON (JSON::PP)";
    }
}

# format tv library for kodi http
sub route_tv {
    my ($self, $request, $absdir, $kodidir) = @_;
    # read in the shows
    my $tvdir = abs_path($absdir);
    if(! defined $tvdir) {
        $request->Send404;
        return;
    }
    my $dh;
    if(! opendir ( $dh, $tvdir )) {
        warn "Error in opening dir $tvdir\n";
        $request->Send404;
        return;
    }
    my %shows = ();
    my @diritems;
    while( (my $filename = readdir($dh))) {
        next if(($filename eq '.') || ($filename eq '..'));
        next if(!(-s "$tvdir/$filename"));
        # extract the showname
        next if($filename !~ /^(.+)[\.\s]+S\d+/);
        my $showname = $1;
        if($showname) {
            $showname =~ s/\./ /g;
            if(! $shows{$showname}) {
                $shows{$showname} = [];
                my %diritem = ('item' => $showname, 'isdir' => 1);
                my $plot = $self->{tvmeta}."/$showname/plot.txt";
                if(-f $plot) {
                    my $plotcontents = MHFS::Util::read_text_file($plot);
                    $diritem{plot} = $plotcontents;
                }
                push @diritems, \%diritem;
            }
            push @{$shows{$showname}}, "$tvdir/$filename";
        }
    }
    closedir($dh);

    # locate the content
    if($request->{'path'}{'unsafepath'} ne $kodidir) {
        my $fullshowname = substr($request->{'path'}{'unsafepath'}, length($kodidir)+1);
        my $slash = index($fullshowname, '/');
        @diritems = ();
        my $showname = ($slash != -1) ? substr($fullshowname, 0, $slash) : $fullshowname;
        my $showfilename = ($slash != -1) ? substr($fullshowname, $slash+1) : undef;

        my $showitems = $shows{$showname};
        if(!$showitems) {
            $request->Send404;
            return;
        }
        my @initems = @{$showitems};
        my @outitems;
        # TODO replace basename usage?
        while(@initems) {
            my $item = shift @initems;
            $item = abs_path($item);
            if(! $item) {
                say "bad item";
            }
            elsif(rindex($item, $tvdir, 0) != 0) {
                say "bad item, path traversal?";
            }
            elsif(-f $item) {
                my $filebasename = basename($item);
                if(!$showfilename) {
                    push @diritems, {'item' => $filebasename, 'isdir' => 0};
                }
                elsif($showfilename eq $filebasename) {
                    if(index($request->{'path'}{'unsafecollapse'}, '/', length($request->{'path'}{'unsafecollapse'})-1) == -1) {
                        say "found show filename";
                        $request->SendFile($item);
                    }
                    else {
                        $request->Send404;
                    }
                    return;
                }
            }
            elsif(-d _) {
                opendir(my $dh, $item) or die('failed to open dir');
                my @newitems;
                while(my $newitem = readdir($dh)) {
                    next if(($newitem eq '.') || ($newitem eq '..'));
                    push @newitems, "$item/$newitem";
                }
                closedir($dh);
                unshift @initems, @newitems;
            }
            else {
                say "bad item unknown filetype " . $item;
            }
        }
    }

    # redirect if the slash wasn't there
    if(index($request->{'path'}{'unescapepath'}, '/', length($request->{'path'}{'unescapepath'})-1) == -1) {
        $request->SendRedirect(301, substr($request->{'path'}{'unescapepath'}, rindex($request->{'path'}{'unescapepath'}, '/')+1).'/');
        return;
    }

    # generate the directory html
    if(exists $request->{qs}{fmt} && $request->{qs}{fmt} eq 'html') {
        my $buf = '';
        foreach my $show (@diritems) {
            my $showname = $show->{'item'};
            my $url = uri_escape($showname);
            $url .= '/' if($show->{'isdir'});
            $buf .= '<a href="' . $url .'">'.${MHFS::Util::escape_html_noquote(decode('UTF-8', $showname, Encode::LEAVE_SRC))} .'</a><br><br>';
        }
        $request->SendHTML($buf);
    } else {
        $request->SendAsJSON(\@diritems);
    }
}

sub readsubdir{
    my ($subtitles, $source, $b_path) = @_;
    opendir( my $dh, $b_path ) or return;
    while(my $b_filename = readdir($dh)) {
        next if(($b_filename eq '.') || ($b_filename eq '..'));
        my $filename = do {
            try { decode('UTF-8', $b_filename, Encode::FB_CROAK | Encode::LEAVE_SRC) }
            catch($e) {
                warn "$b_filename is not, UTF-8, skipping";
                next;
            }
        };
        my $b_nextpath = "$b_path/$b_filename";
        my $nextsource = "$source/$filename";
        if(-f $b_nextpath && $filename =~ /\.(?:srt|sub|idx)$/) {
            push @$subtitles, $nextsource;
            next;
        } elsif (-d _) {
            readsubdir($subtitles, $nextsource, $b_nextpath);
        }
    }
}

sub readmoviedir {
    my ($self, $movies, $source, $b_moviedir) = @_;
    opendir(my $dh, $b_moviedir ) or do {
        warn "Error in opening dir $b_moviedir\n";
        return;
    };
    while(my $b_edition = readdir($dh)) {
        next if(($b_edition eq '.') || ($b_edition eq '..'));
        my $edition = do {
            try { decode('UTF-8', $b_edition, Encode::FB_CROAK | Encode::LEAVE_SRC) }
            catch($e) {
                warn "$b_edition is not, UTF-8, skipping";
                next;
            }
        };
        my $b_path = "$b_moviedir/$b_edition";
        # recurse on collections
        if ($edition =~ /(?:Duology|Trilogy|Quadrilogy)/) {
            next if ($edition =~ /\.nfo$/);
            $self->readmoviedir($movies, "$source/$edition", $b_path);
            next;
        }
        -s $b_path or next;
        my $isdir = -d _;
        $isdir || -f _ or next;
        $isdir ||= 0;
        my %edition;
        if (!$isdir) {
            if ($edition !~ /\.(?:avi|mkv|mp4|m4v)$/) {
                warn "Skipping $edition, not a movie file" if ($edition !~ /\.(?:txt)$/);
                next;
            }
            $edition{''} = {};
        } else {
            my @videos;
            my @subtitles;
            my @subtitledirs;
            opendir(my $dh, $b_path) or do {
                warn 'failed to open dir';
                next;
            };
            while(my $b_editionitem = readdir($dh)) {
                next if(($b_editionitem eq '.') || ($b_editionitem eq '..'));
                my $editionitem = do {
                    try { decode('UTF-8', $b_editionitem, Encode::FB_CROAK | Encode::LEAVE_SRC) }
                    catch($e) {
                        warn "$b_editionitem is not, UTF-8, skipping";
                        next;
                    }
                };
                my $type;
                if ($editionitem =~ /\.(?:avi|mkv|mp4|m4v)$/) {
                    $type = 'video' if ($editionitem !~ /sample(?:\-[a-z]+)?\.(?:avi|mkv|mp4)$/);
                } elsif ($editionitem =~ /\.(?:srt|sub|idx)$/) {
                    $type = 'subtitle';
                } elsif ($editionitem =~ /^Subs$/i) {
                    $type = 'subtitledir';
                }
                $type or next;
                if (-f "$b_path/$b_editionitem") {
                    push @videos, $editionitem if($type eq 'video');
                    push @subtitles, $editionitem if($type eq 'subtitle');
                } elsif (-d _ && $type eq 'subtitledir') {
                    push @subtitledirs, $editionitem;
                }
            }
            closedir($dh);
            if (!@videos) {
                warn "not adding edition $edition, no videos found";
                next;
            }
            foreach my $subdir (@subtitledirs) {
                readsubdir(\@subtitles, $subdir, "$b_path/$subdir");
            }
            foreach my $videofile (@videos) {
                my ($withoutext) = $videofile =~ /^(.+)\.[^\.]+$/;
                my %relevantsubs;
                for my $i (reverse 0 .. $#subtitles) {
                    if (basename($subtitles[$i]) =~ /^\Q$withoutext\E/i) {
                        $relevantsubs{splice(@subtitles, $i, 1)} = undef;
                    }
                }
                $edition{"/$videofile"} = scalar %relevantsubs ? {subs => \%relevantsubs} : {};
            }
            if(@subtitles) {
                warn "$edition: unmatched subtitle $_" foreach @subtitles;
            }
        }
        my $showname;
        my $withoutyear;
        my $year;
        if($edition =~ /^(.+)[\.\s]+\(?(\d{4})([^p]|$)/) {
            $showname = "$1 ($2)";
            $withoutyear = $1;
            $year = $2;
            $withoutyear =~ s/\./ /g;
        }
        elsif ($edition =~ /(.+)\s?\[(\d{4})\]/) {
            $showname = "$1 ($2)";
            $withoutyear = $1;
            $year = $2;
            $withoutyear =~ s/\./ /g;
        }
        elsif($edition =~ /^(.+)[\.\s](?i:DVDRip)[\.\s]./) {
            $showname = $1;
        }
        elsif($edition =~ /^(.+)[\.\s](?:DVD|RERIP|BRrip)/) {
            $showname = $1;
        }
        elsif($edition =~ /^(.+)\s\(PSP.+\)/) {
            $showname = $1;
        }
        elsif($edition =~ /^(.+)\.VHS/) {
            $showname = $1;
        }
        elsif($edition =~ /^(.+)[\.\s]+\d{3,4}p\./) {
            $showname = $1;
        }
        elsif($edition =~ /^(.+)\.[a-zA-Z\d]{3,4}$/) {
            $showname = $1;
        }
        else{
            $showname = $edition;
        }
        $showname =~ s/\./ /g;
        if(! $movies->{$showname}) {
            my %diritem;
            if(defined $year) {
                $diritem{name} = $withoutyear;
                $diritem{year} = $year;
            }
            my $b_showname = encode_utf8($showname);
            my $plot = $self->{moviemeta}."/$b_showname/plot.txt";
            try { $diritem{plot} = read_text_file_lossy($plot); }
            catch($e) {}
            $movies->{$showname} = \%diritem;
        }
        $movies->{$showname}{editions}{"$source/$edition"} = \%edition;
    }
    closedir($dh);
}

sub _build_movie_library {
    my ($self, $sources) = @_;
    my %movies;
    foreach my $source (@$sources) {
        if ($self->{server}{settings}{SOURCES}{$source}{type} ne 'local') {
            warn "skipping source $source, only local implemented";
            next;
        }
        my $b_moviedir = $self->{server}{settings}{SOURCES}{$source}{folder};
        $self->readmoviedir(\%movies, $source, $b_moviedir);
    }
    \%movies
}

# dies on not found/error
sub _search_movie_library {
    my ($self, $movies, $movieid, $source, $editionname, $partname, $subfile) = @_;
    unless(exists $movies->{$movieid}) {
        die "movie not found";
    }
    $movies = $movies->{$movieid};
    if (!$source) {
        return bless {movie => $movies}, 'MHFS::Kodi::Movie';
    }
    $movies = $movies->{editions};
    if(!$editionname) {
        my %editions = map { $_ =~ /^$source/ ? ($_ => $movies->{$_}) : () } keys %$movies;
        return bless {editions => \%editions}, 'MHFS::Kodi::MovieEditions';
    }
    unless(exists $movies->{"$source/$editionname"}) {
        die "movie source not found";
    }
    $movies = $movies->{"$source/$editionname"};
    unless(defined $partname) {
        return bless {source => $source, editionname => $editionname, edition => $movies}, 'MHFS::Kodi::MovieEdition';
    }
    unless(exists $movies->{$partname}) {
        die "movie part not found";
    }
    my $b_moviedir = $self->{server}{settings}{SOURCES}{$source}{folder};
    my $b_editionname = encode_utf8($editionname);
    my $b_editiondir = "$b_moviedir/$b_editionname";
    $movies = $movies->{$partname};
    if (!$subfile) {
        my $b_partname = encode_utf8($partname);
        return bless {b_path => "$b_editiondir$b_partname", editionname => $editionname, partname => $partname, part => $movies}, 'MHFS::Kodi::MoviePart';
    }
    unless(exists $movies->{subs} && exists $movies->{subs}{$subfile}) {
        die "subtitle file not found";
    }
    my $b_subfile = encode_utf8($subfile);
    return bless {b_path => "$b_editiondir/$b_subfile", subtitle => $subfile}, 'MHFS::Kodi::MovieSubtitle';
}

sub _format_movie_subs {
    my ($subs) = @_;
    my @subs = map {
        # kodi needs a basename with a parsable extension
        my ($loc, $filename) = $_ =~ /^(.+\/|)([^\/]+)$/;
        $loc = str_to_base64url($loc);
        "$loc-sb/$filename"
    } keys %$subs;
    \@subs
}

sub _format_movie_part {
    my ($editionname, $name, $paart) = @_;
    my $b64_name = str_to_base64url($name);
    my %part = (
        id => "$b64_name-pt",
        name => basename("$editionname$name")
    );
    if (exists $paart->{subs}) {
        $part{subs} = _format_movie_subs($paart->{subs});
    }
    \%part
}

sub _format_movie_edition {
    my ($sourcename, $editionname, $ediition) = @_;
    my @sortedkeys = sort {basename($a) cmp basename($b)} keys %$ediition;
    my @parts = map {
        _format_movie_part($editionname, $_, $ediition->{$_})
    } @sortedkeys;
    my $editionid = "$sourcename/".str_to_base64url($editionname);
    my %edition = ( id => $editionid, name => basename($editionname), parts => \@parts);
    \%edition
}

# transform $diritems{movie}{editions}{source/name}{|parts}
# to        $diritems{movie}{editions}[{name, parts}]
sub _format_movie_editions {
    my ($ediitions) = @_;
    my @sortedkeys = sort {basename($a) cmp basename($b)} keys %$ediitions;
    my @editions = map {
        my ($sourcename, $editionname) = split('/', $_, 2);
        _format_movie_edition($sourcename, $editionname, $ediitions->{$_})
    } @sortedkeys;
    \@editions
}

sub _format_movies {
    my ($moovies) = @_;
    my @sortedkeys = sort {basename($a) cmp basename($b)} keys %$moovies;
    my @movies = map {
        my %movie = %{$moovies->{$_}};
        $movie{id} = $_;
        $movie{editions} = _format_movie_editions($movie{editions});
        \%movie
    } @sortedkeys;
    \@movies
}

sub _html_list_item {
    my ($item, $isdir, $label) = @_;
    $label //= $item;
    my $url = uri_escape_path_utf8($item);
    $url .= '/?fmt=html' if($isdir);
    '<li><a href="' . $url .'">'. ${MHFS::Util::escape_html_noquote($label)} .'</a></li>'
}

# format movies library for kodi http
sub route_movies {
    my ($self, $request, $sources, $kodidir) = @_;
    my $request_path = do {
        try { decode('UTF-8', $request->{path}{unsafepath}, Encode::FB_CROAK | Encode::LEAVE_SRC) }
        catch($e) {
            warn "$request->{path}{unsafepath} is not, UTF-8, 404";
            $request->Send404;
            return;
        }
    };
    # build the movie library
    if(! exists $self->{movies} || $request_path eq $kodidir) {
        $self->{movies} = $self->_build_movie_library($sources);
    }
    my $movies = $self->{movies};
    # find the movie item
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
            $movieitem = $self->_search_movie_library($movies, $movieid, $source, $editionname, $partname, $subfile);
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
        $movieitem = bless {movies => $movies}, 'MHFS::Kodi::Movies';
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
        try { decode('UTF-8', $request->{path}{unsafepath}, Encode::FB_CROAK | Encode::LEAVE_SRC) }
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
    return _curl($server, [$url], sub {
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
    while(1) {
        if($request->{'path'}{'unsafepath'} !~ m!^/kodi/metadata/(movies|tv)/(thumb|fanart|plot)/(.+)$!) {
            last;
        }
        my ($mediatype, $metadatatype, $medianame) = ($1, $2, $3);
        say "mt $mediatype mmt $metadatatype mn $medianame";
        my %allmediaparams  = ( 'movies' => {
            'meta' => $self->{moviemeta},
            'search' => 'movie',
        }, 'tv' => {
            'meta' => $self->{tvmeta},
            'search' => 'tv'
        });
        my $params = $allmediaparams{$mediatype};
        if(index($medianame, '/') != -1 || $medianame =~ /^.(.)?$/) {
            last;
        }
        my $metadir = $params->{meta} . '/' . $medianame;
        # fast path, exists on disk
        if (-d $metadir) {
            my %acceptable = ( 'thumb' => ['png', 'jpg'], 'fanart' => ['png', 'jpg'], 'plot' => ['txt']);
            if(exists $acceptable{$metadatatype}) {
                foreach my $totry (@{$acceptable{$metadatatype}}) {
                    my $path = $metadir.'/'.$metadatatype.".$totry";
                    if(-f $path) {
                        $request->SendLocalFile($path);
                        return;
                    }
                }
            }
        }
        # slow path, download it
        $request->{client}{server}{settings}{TMDB} or last;
        my $searchname = $medianame;
        $searchname =~ s/\s\(\d\d\d\d\)// if($mediatype eq 'movies');
        say "searchname $searchname";
        weaken($request);
        _TMDB_api_promise($request->{client}{server}, 'search/'.$params->{search}, {'query' => $searchname})->then( sub {
            if($metadatatype eq 'plot' || ! -f "$metadir/plot.txt") {
                make_path($metadir);
                MHFS::Util::write_text_file("$metadir/plot.txt", $_[0]->{results}[0]{overview});
            }
            if($metadatatype eq 'plot') {
                $request->SendLocalFile("$metadir/plot.txt");
                return;
            }
            # thumb or fanart
            my $imagepartial = ($metadatatype eq 'thumb') ? $_[0]->{results}[0]{poster_path} : $_[0]->{results}[0]{backdrop_path};
            if (!$imagepartial || $imagepartial !~ /(\.[^\.]+)$/) {
                return MHFS::Promise::throw('path not matched');
            }
            my $ext = $1;
            make_path($metadir);
            return MHFS::Promise->new($request->{client}{server}{evp}, sub {
                my ($resolve, $reject) = @_;
                if(! defined $self->{tmdbconfig}) {
                    $resolve->(_TMDB_api_promise($request->{client}{server}, 'configuration')->then( sub {
                        $self->{tmdbconfig} = $_[0];
                        return $_[0];
                    }));
                } else {
                    $resolve->();
                }
            })->then( sub {
                return _DownloadFile_promise($request->{client}{server}, $self->{tmdbconfig}{images}{secure_base_url}.'original'.$imagepartial, "$metadir/$metadatatype$ext")->then(sub {
                    $request->SendLocalFile("$metadir/$metadatatype$ext");
                    return;
                });
            });
        })->then(undef, sub {
            say $_[0];
            $request->Send404;
            return;
        });
        return;
    }
    $request->Send404;
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
            route_tv($self, $request, $settings->{'MEDIALIBRARIES'}{'tv'}, '/kodi/tv');
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
