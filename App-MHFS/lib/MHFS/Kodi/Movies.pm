package MHFS::Kodi::Movies v0.7.0;
use 5.014;
use strict; use warnings;
use Encode qw(encode_utf8);
use Feature::Compat::Try;
use File::Path qw(make_path);
use File::Basename qw(basename);
use MHFS::Kodi::Movie;
use MHFS::Kodi::MovieEdition;
use MHFS::Kodi::MovieEditions;
use MHFS::Kodi::MoviePart;
use MHFS::Kodi::MovieSubtitle;
use MHFS::Kodi::Util qw(html_list_item);
use MHFS::Util qw(decode_utf_8 read_text_file_lossy fold_case write_text_file_lossy read_json_file encode_json write_file write_json_file);

sub _readsubdir{
    my ($subtitles, $source, $b_path) = @_;
    opendir( my $dh, $b_path ) or return;
    while(my $b_filename = readdir($dh)) {
        next if(($b_filename eq '.') || ($b_filename eq '..'));
        my $filename = do {
            try { decode_utf_8($b_filename) }
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
            _readsubdir($subtitles, $nextsource, $b_nextpath);
        }
    }
}

sub _dealias {
    my ($self, $publicid) = @_;
    return $publicid if (! exists $self->{db}{aliases}{$publicid});
    my $movieid = $self->{db}{aliases}{$publicid};
    say "mapping $publicid to $movieid";
    $movieid
}

sub _readmoviedir {
    my ($self, $movies, $source, $b_moviedir) = @_;
    opendir(my $dh, $b_moviedir ) or do {
        warn "Error in opening dir $b_moviedir\n";
        return;
    };
    while(my $b_edition = readdir($dh)) {
        next if(($b_edition eq '.') || ($b_edition eq '..'));
        my $edition = do {
            try { decode_utf_8($b_edition) }
            catch($e) {
                warn "$b_edition is not, UTF-8, skipping";
                next;
            }
        };
        my $b_path = "$b_moviedir/$b_edition";
        # recurse on collections
        if ($edition =~ /(?:Duology|Trilogy|Quadrilogy)/) {
            next if ($edition =~ /\.nfo$/);
            $self->_readmoviedir($movies, "$source/$edition", $b_path);
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
                    try { decode_utf_8($b_editionitem) }
                    catch($e) {
                        warn "$b_editionitem is not, UTF-8, skipping";
                        next;
                    }
                };
                my $type;
                if ($editionitem =~ /\.(?:avi|mkv|mp4|m4v)$/) {
                    $type = 'video' if ($editionitem !~ /sample(?:\-[a-z]+)?\.(?:avi|mkv|mp4|m4v)$/);
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
                _readsubdir(\@subtitles, $subdir, "$b_path/$subdir");
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
        if (exists $self->{userdb}{editions}{"$source/$edition"}) {
            my $editionmeta = $self->{userdb}{editions}{"$source/$edition"};
            exists $editionmeta->{movie_id} and $showname = $editionmeta->{movie_id};
        }
        elsif ($edition =~ /^(.+)[\.\s]+\(?(\d{4})([^p]|$)/) {
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
        $withoutyear //= $showname;
        $showname = fold_case($showname);
        $showname = $self->_dealias($showname);
        if(! $movies->{$showname}) {
            my %diritem = (name => $withoutyear, ($year ? (year => $year) : ()));
            my $b_showname = encode_utf8($showname);
            try {
                my $di = read_json_file($self->{moviemeta}."/$b_showname/movie.json");
                %diritem = (%diritem, %$di);
            } catch($e) {}
            if (exists $self->{userdb}{movies}{$showname}) {
                my $moviemeta = $self->{userdb}{movies}{$showname};
                %diritem = (%diritem, %$moviemeta);
            }
            $movies->{$showname} = \%diritem;
        }
        $movies->{$showname}{editions}{"$source/$edition"} = \%edition;
    }
    closedir($dh);
}

sub _read_user_db {
    my ($self) = @_;
    my $userdb_file = $self->{moviemeta}."/user_db.json";
    try {
        my $userdb = read_json_file($userdb_file);
        exists $userdb->{editions} or die "userdb does not have editions";
        exists $userdb->{movies} or die "userdb does not have movies";
        return $userdb;
    } catch($e) {
        print "$e";
    }
    {
        editions => {},
        movies => {},
    }
}

sub _read_db {
    my ($self) = @_;
    my $db_file = $self->{moviemeta}."/db.json";
    try {
        my $db = read_json_file($db_file);
        exists $db->{aliases} or die "db does not have aliases";
        exists $db->{tmdb_ids} or die "db does not have tmdb_ids";
        return $db;
    } catch($e) {
        print "$e";
    }
    {
        aliases => {},
        tmdb_ids => {},
    }
}

sub build_movie_library {
    my ($self) = @_;
    $self->{userdb} = $self->_read_user_db();
    $self->{db} = $self->_read_db();
    my $sources = $self->{sources};
    my %movies;
    foreach my $source (@$sources) {
        if ($self->{server}{settings}{SOURCES}{$source}{type} ne 'local') {
            warn "skipping source $source, only local implemented";
            next;
        }
        my $b_moviedir = $self->{server}{settings}{SOURCES}{$source}{folder};
        $self->_readmoviedir(\%movies, $source, $b_moviedir);
    }
    $self->{movies} = \%movies;
}

sub new {
    my ($name, $server, $moviemeta, $tmdb_client) = @_;
    my %optional = (
        ($tmdb_client ? (tmdb => $tmdb_client) : ()),
    );
    my $self = bless {server => $server, sources => $server->{settings}{MEDIASOURCES}{movies}, moviemeta => $moviemeta, %optional}, $name;
    $self->build_movie_library();
    $self
}

# dies on not found/error
sub get_movie_item {
    my ($self, $publicid, $source, $editionname, $partname, $subfile) = @_;
    my $movieid = $self->_dealias($publicid);
    my $movies = $self->{movies};
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

sub get_movie {
    my ($self, $movieid) = @_;
    my $db = $self->{movies};
    exists $db->{$movieid} or die "movieid $movieid does not exist";
    $db->{$movieid}
}

sub update_movie_metadata {
    my ($self, $movieid, $metadata) = @_;
    my $item = $self->{movies};
    exists $item->{$movieid} or die "movieid $movieid does not exist";
    @{$item->{$movieid}}{keys %$metadata} = values %$metadata;
    my %json = %{$item->{$movieid}};
    delete $json{editions};
    my $b_metadir = $self->{moviemeta} . '/' . encode_utf8($movieid);
    make_path($b_metadir);
    write_json_file("$b_metadir/movie.json", \%json);
    $item->{$movieid}
}

sub _fetch_metadata_on_movie {
    my ($self, $metadatatype, $medianame, $tmdb, $metadata) = @_;
    my %update = (
        (exists $metadata->{overview} ? (plot => $metadata->{overview}) : ()),
        (exists $metadata->{name} ? (name => $metadata->{name}) : ()),
    );
    # merge if there's an existing entry with the same tmdb id
    if (exists $metadata->{id}) {
        my $tmdb_id = $metadata->{id};
        if (! exists $self->{db}{tmdb_ids}{$tmdb_id}) {
            say "adding tmdb_id $tmdb_id -> $medianame mapping";
            $self->{db}{tmdb_ids}{$tmdb_id} = $medianame;
        } else {
            my $realmovieid = $self->{db}{tmdb_ids}{$tmdb_id};
            if ($medianame ne $realmovieid) {
                say "$medianame is actually $realmovieid";
                my $target = $self->{movies}{$realmovieid};
                my $source = delete $self->{movies}{$medianame};
                $target->{editions} = {%{$target->{editions}}, %{$source->{editions}}};
                $self->{db}{aliases}{$medianame} = $realmovieid;
                $medianame = $realmovieid;
                %update = (
                    ((exists $source->{year} && !exists $target->{year}) ? (year => $source->{year}) : ()),
                    ((exists $source->{plot} && !exists $target->{plot}) ? (plot => $source->{plot}) : ()),
                    %update,
                );
            }
        }
        write_json_file($self->{moviemeta}.'/db.json', $self->{db});
    }
    my $movie = $self->update_movie_metadata($medianame, \%update);
    if ($metadatatype eq 'plot') {
        exists $movie->{plot} or die "plot not found for $medianame";
        return {text => $movie->{plot}};
    }
    # TODO if a merge occured we probably don't need to refetch images
    my $image_type = ($metadatatype eq 'thumb') ? 'poster_path' : 'backdrop_path';
    my $b_metadir = $self->{moviemeta} . '/' . encode_utf8($medianame);
    $tmdb->get_image_from_metadata($metadata, $image_type, $b_metadir, $metadatatype)->then(sub {
        {file => $_[0]}
    })
}

sub _fetch_metadata {
    my ($self, $metadatatype, $medianame) = @_;
    $medianame = $self->_dealias($medianame);
    my $movie = $self->get_movie($medianame);
    # fastest path, grab from the db
    if ($metadatatype eq 'plot' && exists $movie->{plot}) {
        say "fastest path";
        return {text => $movie->{plot}};
    }
    my $b_metadir = $self->{moviemeta} . '/' . encode_utf8($medianame);
    # fast path, check disk
    if ($metadatatype ne 'plot' && -d $b_metadir) {
        my %acceptable = ( 'thumb' => ['png', 'jpg'], 'fanart' => ['png', 'jpg']);
        if(exists $acceptable{$metadatatype}) {
            foreach my $totry (@{$acceptable{$metadatatype}}) {
                my $path = $b_metadir.'/'.$metadatatype.".$totry";
                return {file => $path} if (-f $path);
            }
        }
    }
    # slow path, download it
    exists $self->{tmdb} or die "cannot load metadata without tmdb";
    my $tmdb = $self->{tmdb};
    # id in db
    if (exists $movie->{tmdb_id}) {
        say "tmdb_id in db";
        return $tmdb->get_movie($movie->{tmdb_id})->then(sub {
            my $json = $_[0];
            $json or die "Failed to find item";
            _fetch_metadata_on_movie($self, $metadatatype, $medianame, $tmdb, $json)
        })
    }
    # no id, search for it
    my ($searchname, $year) = $medianame =~ /^(.+)\s\((\d\d\d\d)\)$/;
    $searchname //= $medianame;
    say "searchname $searchname";
    say "primary_release_year $year" if $year;
    my $params = {query => $searchname, ($year ? (primary_release_year => $year) : ())};
    $tmdb->search('movie', $params)->then(sub {
        my $json = $_[0]->{results}[0];
        $json or die "Failed to find item";
        _fetch_metadata_on_movie($self, $metadatatype, $medianame, $tmdb, $json)
    })
    # TODO maybe retry search without year or see if year even helps searches
}

sub fetch_metadata {
    MHFS::Promise::try($_[0]->{server}{evp}, \&_fetch_metadata, @_)
}

sub Format {
    my ($moovies) = @_;
    my @sortedkeys = sort {basename($a) cmp basename($b)} keys %$moovies;
    my @movies = map {
        my $movie = MHFS::Kodi::Movie::Format($moovies->{$_});
        $movie->{id} = $_;
        $movie
    } @sortedkeys;
    \@movies
}

sub TO_JSON {
    my ($self) = @_;
    {movies => Format($self->{movies})}
}

sub TO_HTML {
    my ($self) = @_;
    my $movies = Format($self->{movies});
    my $buf = '<style>ul{list-style: none;} li{margin: 10px 0;}</style><ul>';
    foreach my $movie (@$movies) {
        $buf .= html_list_item($movie->{id}, 1);
    }
    $buf .= '</ul>';
    $buf
}
1;
