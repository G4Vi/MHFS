use strict;
use warnings;
use 5.010;
use IPC::Cmd qw[can_run run run_forked];
use Test::Simple tests => 3;
use feature 'say';

sub data_cmp_test {
    my ($data1, $data2) = @_;
    if($data1 eq $data2) {
        return 1;
    }

    say "mismatch:";
    say "data 1:";
    print $data1;
    say "data 2: ";
    print $data2;
    return 0;
}

sub http_file_test {
    my ($url, $file, $opt) = @_;

    my @curlcmd = ('curl', '--verbose', 'http://127.0.0.1:8000/stream'.$url);
    push (@curlcmd, ('-r', $opt->('range'))) if (defined $opt->{'range'});
    my $curldata;
    {
    my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = run('command' => \@curlcmd);
    if(!$success) {
         die($error_message);
        return 0;
    }
    $curldata = join "", @$stdout_buf;
    }
    my $dddata;
    my @ddcmd;
    if (defined $opt->{'range'}) {

    }
    else {
        my $bytestoskip = 0; 
        @ddcmd = ('dd', 'bs=1', 'if='.$file);
    }
    {
    my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = run('command' => \@ddcmd);
    if(!$success) {
        die($error_message);
        return 0;
    }
    $dddata = join "", @$stdout_buf;
    }
    
    return data_cmp_test($curldata, $dddata);
}

sub http_buf_test {
    my ($url, $buf, $opt) = @_;
    my @curlcmd = ('curl', '--verbose', 'http://127.0.0.1:8000/'.$url);
    push (@curlcmd, ('-r', $opt->('range'))) if (defined $opt->{'range'});
    my $curldata;
    {
    my( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = run('command' => \@curlcmd);
    if(!$success) {
         die($error_message);
        return 0;
    }
    $curldata = join "", @$stdout_buf;
    }

    return data_cmp_test($curldata, $buf);
};

IPC::Cmd->can_capture_buffer() or die("Cannot run tests without capture buffer support");

# ----------------------------
# Tests on files

# serving file
ok( http_file_test('static/music_worklet_inprogress/index.html', 'static/music_worklet_inprogress/index.html'));
# serving index.html from directory
ok( http_file_test('static/music_worklet_inprogress/', 'static/music_worklet_inprogress/index.html'));
# redirect to directory
ok( http_buf_test('static/music_worklet_inprogress', "301 Moved Permanently\r\n<a href=\"music_worklet_inprogress/\"></a>\r\n"));

# requesting file outside the document root
#ok( http_buf_test('snapshot.sh', "404 Not Found\r\n"));

# test range requests on file
# --------------------------------

# tests on get_video

# tests on video

# tests on torrent


# music library
# tests on music
# tests on music_dl
# tests on music_resources

# youtube
# youtube
# yt
# ytmusic
# ytaudio
# ytplayer
# ytembedplayer


# 404
ok( http_buf_test('/dfdfdfdf', "404 Not Found\r\n"));
ok( http_buf_test('dfdfdfdf', "404 Not Found\r\n"));


# main route. To remove!"
ok( http_file_test('/', 'static/index.html'));
ok( http_file_test('/static/', 'static/index.html'));
ok( http_file_test('/static/index.html', 'static/index.html'));