#!/usr/bin/perl
use strict; use warnings;
use feature 'say';
use Cwd 'abs_path';
use File::Basename;
use JSON::PP;
use Data::Dumper;
use IPC::Open3;

my $configfile = abs_path($ARGV[1]);
#say "Config file: $configfile";


my $configdata = (-e $configfile) ? read_file($configfile) : '{}';
my $CONFIG = decode_json($configdata);

my $configchanged;
if( ! $CONFIG->{'client_id'}) {
    $configchanged = 1;
    die "client_id not set";
}



if( ! $CONFIG->{'client_secret'}) {
    $configchanged = 1;
    die "client_secret not set";
}

my $ACCESS_TOKEN;
if(! $CONFIG->{'refresh_token'}) {
    if($ARGV[0] ne '__setup__') {
        die "refresh_token not set";
    }
    $configchanged = 1;
    my $curlcmd = 'curl --silent "https://accounts.google.com/o/oauth2/device/code" --data "client_id=' . $CONFIG->{'client_id'} . '&scope=https://docs.google.com/feeds"';
    my $response =  `$curlcmd`;
    say $response;
    my $codejson = decode_json($response);

    say "Go to ".$codejson->{'verification_url'}." and enter ".$codejson->{'user_code'}." to grant access to this application. Hit enter when done...";
	<STDIN>;
    $curlcmd = 'curl --silent "https://accounts.google.com/o/oauth2/token" --data "client_id='.$CONFIG->{'client_id'}.'&client_secret='.$CONFIG->{'client_secret'}.'&code='.$codejson->{'device_code'}.'&grant_type=http://oauth.net/grant_type/device/1.0"';
    $response =  `$curlcmd`;
    my $tokenjson = decode_json($response);
    $CONFIG->{'refresh_token'} = $tokenjson->{'refresh_token'};
    $ACCESS_TOKEN = $tokenjson->{'access_token'};
}
else {
    my $curlcmd = 'curl --silent "https://accounts.google.com/o/oauth2/token" --data "client_id='.$CONFIG->{'client_id'}.'&client_secret='.$CONFIG->{'client_secret'}."&refresh_token=".$CONFIG->{'refresh_token'}.'&grant_type=refresh_token"';
    my $response = `$curlcmd`;
    #say $response;
    my $tokenjson = decode_json($response);
    $ACCESS_TOKEN = $tokenjson->{'access_token'};
}

if($configchanged) {
    my $json = JSON::PP->new->pretty(1);    
    $configdata = $json->encode($CONFIG);
    write_file($configfile, $configdata);
}

use Symbol 'gensym'; 
sub gdrive_create_upload_session {
    #say "create upload session";
    my($wtr, $rdr, $err);
    $err = gensym;
    my $pid = open3($wtr, $rdr, $rdr, 'curl', '-s', '-D', '-', '-X', 'POST', '-H', "Authorization: Bearer $ACCESS_TOKEN", '-H', "Content-Type: application/json", '-d', '{"parents": [{"id":"1_oUiDf_H7-pXHAaJkkGOGoYFC_ozqCTi"}]}', "https://www.googleapis.com/upload/drive/v2/files?uploadType=resumable");
    my $uploadurl;
    while(<$rdr>) {
        #say;    
        if( /^location:\s+(.+)\r$/) {
            $uploadurl = $1;
	    last;
        } 
    }
    waitpid( $pid, 0 );     
    #my $child_exit_status = $? >> 8;
    return $uploadurl;
}

sub gdrive_upload {
    my ($session, $file) = @_;    
    my $pid = open(my $stdout, '-|', 'curl', '-s', '-X', 'PUT', '-H', "Authorization: Bearer $ACCESS_TOKEN", '-T', $file, $session) or die "upload failed";
    local $/;
    my $res = <$stdout>;
    waitpid($pid, 0); 
    return $res;
}

sub gdrive_share_linkonly {
    my ($id) = @_;    
    my $pid = open(my $stdout, '-|', 'curl', '-s', '-X', 'POST', '-H', "Authorization: Bearer $ACCESS_TOKEN", '-H', "Content-Type: application/json", '-d', '{"role": "reader","type": "anyone", "withLink": true}', "https://www.googleapis.com/drive/v2/files/$id/permissions") or die "upload failed";
    local $/;
    my $res = <$stdout>;
    waitpid($pid, 0); 
    return $res;
}


@ARGV or die "no file specified";
my $uploadurl = gdrive_create_upload_session() or die "Can't create upload url";
my $upload_out = gdrive_upload($uploadurl, $ARGV[0]);
#print $upload_out;
my $uploadinfo = decode_json($upload_out);
say $uploadinfo->{'id'};
print $uploadinfo->{'downloadUrl'} . '&access_token=' . $ACCESS_TOKEN;

exit 0;

sub read_file {
    my ($filename) = @_;
    my $data;
    open(my $ch, '<', $filename) or die "can't open configfile: $filename, $!";
    {
        local $/;
        $data = <$ch>;
    }
    return $data;
}

sub write_file {
    my ($filename, $data) = @_;
    open my $file, '>', $filename or die $!;
    print $file $data;
}




