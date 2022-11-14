#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use LWP::UserAgent;
use Data::Dumper qw(Dumper);

my $module = shift @ARGV;
my $ua  = LWP::UserAgent->new;
my $url = "https://fastapi.metacpan.org/v1/download_url/".$module;
my $res = $ua->get($url);
if(! $res->is_success) {
    print Dumper($res);
    die "Failed to find package";
}
my $jsonresponse = decode_json( $res->decoded_content );
exists $jsonresponse->{download_url} or die "Failed to find package";
$jsonresponse->{download_url} =~ /\/([a-zA-Z\-]+)\-[vV]?[\d\.]*((?:\.[a-zA-Z]+)+)$/ or die "Unable to parse out filename";
my $finalname = "$1$2";
my $tres = $ua->get($jsonresponse->{download_url});
$tres->is_success or die "Failed to download package";
open(my $fh, '>', $finalname) or die "Failed save package to disk";
print $fh $tres->decoded_content;
close($fh);