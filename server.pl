#!/usr/bin/perl

package HTTP::BS::Server {
    use strict; use warnings;
	use feature 'say';
    use IO::Socket::INET;
    use Socket qw(IPPROTO_TCP TCP_KEEPALIVE);
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(weaken);
    sub new {
	    my ($class, $settings) = @_;
		
        my $sock = IO::Socket::INET->new(Listen => 50, LocalAddr => '127.0.0.1', LocalPort => 8000, Proto => 'tcp', Reuse => 1, Blocking => 0);
        if(! $sock) {
            say "server: Cannot create self socket";
            return undef;
        }
         
        if(! $sock->setsockopt( SOL_SOCKET, SO_KEEPALIVE, 1)) {
            say "server: cannot setsockopt";        
            return undef;
        }
        my $TCP_KEEPIDLE  = 4;
        my $TCP_KEEPINTVL   = 5;
        my $TCP_KEEPCNT   = 6;
        my $TCP_USER_TIMEOUT = 18;
        #$SERVER->setsockopt(IPPROTO_TCP, $TCP_KEEPIDLE, 1) or die;    
        #$SERVER->setsockopt(IPPROTO_TCP, $TCP_KEEPINTVL, 1) or die;   
        #$SERVER->setsockopt(IPPROTO_TCP, $TCP_KEEPCNT, 10) or die;
        #$SERVER->setsockopt(IPPROTO_TCP, $TCP_USER_TIMEOUT, 10000) or die; #doesn't work?
        #$SERVER->setsockopt(SOL_SOCKET, SO_LINGER, pack("II",1,0)) or die; #to stop last ack bullshit
        my $evp = EventLoop::Poll->new;
		my %self = ( 'settings' => $settings, 'sock' => $sock, 'evp' => $evp);
		bless \%self, $class;

        $evp->set($sock, \%self, POLLIN);	
        
        # delete old files from google drive
        # BAD
        $self{'evp'}->add_timer(0, 0, sub {
            App::MHFS::gdrive_remove_tmp_rec();
            return 1;        
        });
            
        
        $evp->run(0.1);
        
   		return \%self;
    }
    
    sub onReadReady {
        my ($server) = @_;
        #create a client 
        my $csock = $server->{'sock'}->accept();
        if(! $csock) {
            say "server: cannot accept client";
            return undef;        
        }       
        
        say "-------------------------------------------------";
        say "NEW CONN " . $csock->peerhost() . ':' . $csock->peerport();                   
        
        my $MAX_TIME_WITHOUT_SEND = 600; #600;
		my $cref = HTTP::BS::Server::Client->new($csock, $server);
               
        $server->{'evp'}->set($csock, $cref, POLLIN | POLLOUT | $EventLoop::Poll::POLLRDHUP);    

        weaken($cref);
        $server->{'evp'}->add_timer($MAX_TIME_WITHOUT_SEND, 0, sub {
            my ($timer, $current_time) = @_;
            if(! defined $cref) {                
                return undef;            
            }
            
            my $time_elapsed = $current_time - $cref->{'time'};
            if($time_elapsed > $MAX_TIME_WITHOUT_SEND) {
                say "\$MAX_TIME_WITHOUT_SEND ($MAX_TIME_WITHOUT_SEND) exceeded, closing CONN";
                say "-------------------------------------------------";
                $cref->cleanup();
                $server->{'evp'}->remove($cref->{'sock'});
                return undef;                
            }
            $timer->{'interval'} = $MAX_TIME_WITHOUT_SEND - $time_elapsed;
            return 1;            
        }); 

        
        return 1;
    
    }
	
	1;
}

package HTTP::BS::Server::Request {
    use strict; use warnings;
	use feature 'say';
    use Any::URI::Escape;
	use Cwd qw(abs_path getcwd);
	use File::Basename;
	
    sub new {
	    my ($class, $client, $indataRef) = @_;		
		my %self = ( 'client' => $client);
		bless \%self, $class;
		
		my $success;    
        if($$indataRef =~ /^(?:\r\n)*(.+?)\r\n(.+?)\r\n\r\n(.*)$/s) {  
            my $requestline =  $1;
            my @headerlines = split('\r\n', $2);
            say "RECV: $requestline";
            say "RECV: $_" foreach @headerlines;
            my $body = $2;
            if($requestline =~ /^([^\s]+)\s+([^\s]+)\s+([^\s]+)$/) {
                my $method = $1;
                my $uri = $2;
                my $proto = $3;
                if($proto =~ /^HTTP/i) {
                     #$uri =~ s/%([A-Fa-f\d]{2})/chr hex $1/eg; #decode the uri
                     my ($path, $querystring) = ($uri =~ /^([^\?]+)(?:\?)?(.*)$/g);             
                     say("path: $path\nquerystring: $querystring");
                     #transformations
                     $path = uri_unescape($path);
                     $path =~ s/^\/stream\/?/\//;
                     $querystring =~ s/\?[0-9]+\-[0-9]+$//;
                     $querystring =~ s/\?[0-9]+\-NaN$//;
                     #parse path]
    		         print "fixedpath: $path ";
                     my $abspath = abs_path('.' . $path);                  
    		         print "abs: " . $abspath if (defined $abspath);
                     print "\n";
                     my %pathStruct = ( 'unsafepath' => $path, 'requestfile' => $abspath);
                     $pathStruct{'basename'} = basename( $pathStruct{'requestfile'}) if(defined $pathStruct{'requestfile'});
                     #parse querystring
                     my %qsStruct = ( 'querystring' => $querystring);
                     my @qsPairs = split('&', $querystring);
                     foreach my $pair (@qsPairs) {
                         my($key, $value) = split('=', $pair);                  
                         $qsStruct{$key} = uri_unescape($value);               
                     }
                     #parse headers
                     my %headerStruct;
                     foreach my $headerline (@headerlines) {
                         if($headerline =~ /^\s*([^:]+):\s*(.*)$/) {                         
                             $headerStruct{$1} = $2;    
                         }               
                     }
                     if((defined $headerStruct{'Range'}) &&  ($headerStruct{'Range'} =~ /^bytes=([0-9]+)\-([0-9]*)$/)) {
                         $headerStruct{'_RangeStart'} = $1;
                         $headerStruct{'_RangeEnd'} = $2;                                
                     }                 
                     
                     #dispatch
                     if(($method =~ /^HEAD|GET$/i) ) {                   
                         App::MHFS::HandleGET($client, \%pathStruct, \%qsStruct, \%headerStruct);
                         $success = 1;              
                     }              
                }
                        
            }   
        }
        
        if(! defined($success)) {
             App::MHFS::Send403($client);  
        }
        
        # try to send any data in queue
        my $qdatalen = scalar(@{$client->{'queuedata'}});                   
        if($qdatalen > 0) {
            my $qdret = App::MHFS::TrySendQueueData($client);
                if(!defined $qdret){
                    return undef;
                }                       
        }
        return \%self;
		
	}
    1;
}

package HTTP::BS::Server::Client {
    use strict; use warnings;
	use feature 'say';
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
	#use HTTP::BS::Server::Request;
    sub new {
	    my ($class, $sock, $server) = @_;
        $sock->blocking(0);
		my %self = ('sock' => $sock, 'server' => $server, 'queuedata' => [], 'time' => clock_gettime(CLOCK_MONOTONIC));		
		return bless \%self, $class;
	}

	# currently only creates HTTP Request objects, but this could change if we allow file uploads
    sub onReadReady {
        AGAIN:
        my ($client) = @_;
        my $handle = $client->{'sock'};
        my $recvdata = '';
        my $maxlength = 8192;   
        
        # read until about $maxlength, end of http headers, or error
        my $err;
        for(my $tempdata; ($err = defined($handle->recv($tempdata, 1024))); ) {
            if($tempdata eq '') {
                print("recv  == 0\n");
                goto ON_ERROR;
            }
            $recvdata .= $tempdata;
            
            if(index($tempdata, "\r\n\r\n") != -1) {
                last;       
            }
            
            if(length($recvdata) >= $maxlength) {
                say "TRUNCATED";
                last;
            }       
        }
        
        #if we read until EAGAIN or did not error, handle the data
        if($!{EAGAIN} || ($err == 1)) {
            if($recvdata ne '') {
                # recv twice why?
                my $garbage;
                while($handle->recv($garbage, 4096)){}				
				my $request = HTTP::BS::Server::Request->new($client, \$recvdata); # store this somewhere? 
                if(! defined($request)) {
                    goto ON_ERROR;                
                }
			    return $request;                
            }
            else {
                say "err defined" if defined($err);
                say "eagain" if($!{EAGAIN} );
                print "RECV EAGAIN\n";               
                return '';           
            }       
        }
        elsif($!{ETIMEDOUT}) {
            print "ETIMEDOUT\n";
        }
        else {
            print ("recv errno $!\n");                                  
        }
        
        ON_ERROR:
        say "-------------------------------------------------";                
        $client->cleanup();       
        return undef;
       
    }
    
    sub onWriteReady {
        my ($client) = @_;
        # send the queue until empty, eagain, not all data sent, or error                             
        if(scalar(@{$client->{'queuedata'}}) > 0) {                    
            my $qdret = App::MHFS::TrySendQueueData($client);
            if(!defined $qdret){
            say "-------------------------------------------------";
                $client->cleanup();                
                return undef;
            }                    
        }
        return 1;        
    }
    
    sub onHangUp {
        my ($client) = @_;
        say "Client Hangup\n";
        $client->cleanup(); 
    
    }
    
    sub cleanup {
        my ($client) = @_;
        
        EventLoop::Poll::StopWatchingFileForSock($client->{'sock'});    
        shutdown($client->{'sock'}, 2);
        close($client->{'sock'});        
    }
    
    1;	
}

package EventLoop::Poll {     
    use strict; use warnings;
	use feature 'say';
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    
    our $POLLRDHUP = 0;
    
    # BEGIN bad   
    our $WAITING_FILES = []; 
    
    sub StopWatchingFileForSock {
        my ($csock) = @_;   
        
        for (my $i = $#$WAITING_FILES; $i >= 0; $i--) {
            my $fsock = ${ $WAITING_FILES}[$i]->{'sock'};
            if($fsock == $csock) {
                my $filename = ${ $WAITING_FILES}[$i]->{'filename'};    
                say "StopWatchingFileForSock - removing file: $filename";
                splice @$WAITING_FILES, $i, 1;  #should only be one file per sock
                last;           
            }              
        }
    }
    
    # Change to timer system?
    sub CheckWaitingFiles {
        my ($filepairs) = @_;
        #say "There are " . @$filepairs .  " filepairs";
        for (my $i = $#$filepairs; $i >= 0; $i--) {
            my $filename = ${ $filepairs}[$i]->{'filename'};        
            if((-e $filename)){ 
                my $fmt =  ${ $filepairs}[$i]->{'fmt'};         
                if($fmt && defined($App::MHFS::VIDEOFORMATS{$fmt}->{'minsize'}) && ((-s $filename) < $App::MHFS::VIDEOFORMATS{$fmt}->{'minsize'})) {                      
                    next;
                }            
                
                if(defined $filepairs->[$i]{'on_exists'}) {
                    next if (! $filepairs->[$i]{'on_exists'}{'func'}->($filepairs->[$i]{'on_exists'}{'param'}));              
                }
                say "CheckWaitingFiles - removing file: $filename";
               
    	        if(defined($filepairs->[$i]{'client'})) {
                    my $client = ${ $filepairs}[$i]->{'client'};
                    my $startpos = ${ $filepairs}[$i]->{'startpos'};
                    my $endpos = ${ $filepairs}[$i]->{'endpos'};
                    print "startpos $startpos\n" if defined($startpos);
                    print "endpos $endpos\n" if(defined($endpos));
                    App::MHFS::QueueLocalFile($client, $filename, $startpos, $endpos);                
    	        }
    	        elsif($filepairs->[$i]{'no_remove'}) {
                    next;
    	        }
    	        splice @$filepairs, $i, 1;
            }        
        }
    }
    # END BAD
    
    
    sub new {
        my ($class) = @_;
        
        my %self = ('poll' => IO::Poll->new(), 'fh_map' => {}, 'timers' => []);
        bless \%self, $class;              
        
        return \%self;   
    }
    
    sub set {
        my ($self, $handle, $obj, $events) = @_;
        $self->{'poll'}->mask($handle, $events);
        $self->{'fh_map'}{$handle} = $obj;    
    }
    
    sub remove {
        my ($self, $handle) = @_;
        $self->{'fh_map'}{$handle} = undef;
        $self->{'poll'}->remove($handle);    
    }
    
    # all times are relative, is 0 is set as the interval, it will be run every main loop iteration
    # return undef in the callback to delete the timer
    sub add_timer {
        my ($self, $start, $interval, $callback) = @_;
        my $current_time = clock_gettime(CLOCK_MONOTONIC);
        my $desired = $current_time + $start;
        my $timer = { 'desired' => $desired, 'interval' => $interval, 'callback' => $callback };
        my $i;
        for($i = 0; defined($self->{'timers'}[$i]) && ($desired >= $self->{'timers'}[$i]{'desired'}); $i++) { }
        splice @{$self->{'timers'}}, $i, 0, ($timer);   
    }
    
    sub requeue_timers {
        my ($self, $timers, $current_time) = @_;
        foreach my $timer (@$timers) {
            $timer->{'desired'} = $current_time + $timer->{'interval'};
            my $i;
            for($i = 0; defined($self->{'timers'}[$i]) && ($timer->{'desired'} >= $self->{'timers'}[$i]{'desired'}); $i++) { }
            splice @{$self->{'timers'}}, $i, 0, ($timer);       
        }         
    }    
   
    sub run {
        my ($self, $loop_interval) = @_;
        
        my $poll = $self->{'poll'};
    
        for(;;)
        {
            
            # check to see if a file we were waiting on exists
            CheckWaitingFiles($WAITING_FILES);           
            
            # check timers
            my @requeue_timers;
            my $current_time =  clock_gettime(CLOCK_MONOTONIC);            
            while(my $timer = shift (@{$self->{'timers'}})  ) {
                if($current_time >= $timer->{'desired'}) {
                    if(defined $timer->{'callback'}->($timer, $current_time)) { # callback may change interval
                        push @requeue_timers, $timer;                    
                    }               
                }
                else {
                    unshift @{$self->{'timers'}}, $timer;
                    last;
                }                
            }
            $self->requeue_timers(\@requeue_timers, $current_time);
            
               
            
            # check all the handles  
            my $pollret = $poll->poll($loop_interval);
            if($pollret > 0){
                foreach my $handle ($poll->handles()) {
                    my $revents = $poll->events($handle);
                    my $obj = $self->{'fh_map'}{$handle};          
                    if($revents & POLLIN) {                    
                        if(! defined($obj->onReadReady)) {
                            $self->remove($handle);
                            next;
                        }                      
                    }
                    
                    if($revents & POLLOUT) {
                        if(! defined($obj->onWriteReady)) {
                            $self->remove($handle);
                            next;
                        }                                  
                    }
                    
                    if($revents & (POLLHUP | $POLLRDHUP )) {                    
                        $obj->onHangUp();
                        $self->remove($handle);                        
                    }            
        
                }
        
            }
            elsif($pollret == 0) {
            
            }
            else {
                say "Poll ERROR";
                return undef;
            }  
        }
    
    
    }
    
    

    1;
}

package App::MHFS; #Media Http File Server

use strict; use warnings;
use feature 'say';
use Data::Dumper;
use IO::Socket::INET;
use File::Basename;
use Cwd qw(abs_path getcwd);
use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
use IO::Poll qw(POLLIN POLLOUT POLLHUP);
use Errno qw(EINTR EIO :POSIX);
use Fcntl qw(:seek :mode);
BEGIN {
    if( ! (eval "use JSON; 1")) {
        eval "use JSON::PP; 1" or die "No implementation of JSON available, see .doc/dependencies.txt";
        warn "Using PurePerl version of JSON (JSON::PP), see .doc/dependencies.txt about installing faster version";
    }
}
use IPC::Open3;
use File::stat;
use File::Find;
use File::Path qw(make_path);
use Encode qw(decode encode find_encoding);
use Any::URI::Escape;
use Scalar::Util qw(looks_like_number);

$SIG{PIPE} = sub {
    print STDERR "SIGPIPE @_\n";
};

# main
my $SCRIPTDIR = dirname(abs_path(__FILE__));
my $CFGDIR = $SCRIPTDIR . '/.conf';
my $SETTINGS_FILE = $CFGDIR . '/settings.pl';
my $SETTINGS = do ($SETTINGS_FILE);
$SETTINGS or die "Failed to read settings";
$SETTINGS->{'DOCUMENTROOT'} ||= $SCRIPTDIR;
$SETTINGS->{'TMPDIR'} ||= $SETTINGS->{'DOCUMENTROOT'} . '/tmp';
$SETTINGS->{'VIDEO_TMPDIR'} ||= $SETTINGS->{'TMPDIR'};
$SETTINGS->{'GDRIVE_TMP_REC_DIR'} ||= $SETTINGS->{'VIDEO_TMPDIR'} . '/gdrive_tmp_rec';
$SETTINGS->{'BINDIR'} ||= $SCRIPTDIR . '/.bin';
$SETTINGS->{'TOOLDIR'} ||= $SCRIPTDIR . '/.tool';
$SETTINGS->{'DOCDIR'} ||= $SCRIPTDIR . '/.doc';
$SETTINGS->{'CFGDIR'} ||= $CFGDIR;
my $EXT_SOURCE_SITES = $SETTINGS->{'EXT_SOURCE_SITES'};

# make the temp dirs
make_path($SETTINGS->{'TMPDIR'}, $SETTINGS->{'VIDEO_TMPDIR'}, $SETTINGS->{'GDRIVE_TMP_REC_DIR'});

our %VIDEOFORMATS = (
            'hlsold' => {'lock' => 0, 'create_cmd' => "ffmpeg -i '%s' -codec:v copy -bsf:v h264_mp4toannexb -strict experimental -acodec aac -f ssegment -segment_list '%s' -segment_list_flags +live -segment_time 10 '%s%%03d.ts'",  'create_cmd_args' => ['requestfile', 'outpathext', 'outpath'], 'ext' => 'm3u8', 
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/hls_player.html'},

            'hls' => {'lock' => 0, 'create_cmd' => ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-codec:v', 'copy', '-strict', 'experimental', '-codec:a', 'aac', '-ac', '2', '-f', 'hls', '-hls_time', '5', '-hls_list_size', '0',  '-hls_segment_filename', '$video{"out_location"} . "/" . $video{"out_base"} . "%04d.ts"', '-master_pl_name', '$video{"out_base"} . ".m3u8"', '$video{"out_filepath"} . "_v"'], 'ext' => 'm3u8', 'desired_audio' => 'aac',
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/hls_player.html'},

            'dash' => {'lock' => 0, 'create_cmd' => #['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-codec:v', 'copy', '-strict', 'experimental', '-codec:a', 'aac', '-ac', '2', '-map', 'v:0', '-map', 'a:0',  '-f', 'dash',  '$video{"out_filepath"}', '-flush_packets', '1', '-map', '0:2', '-f', 'webvtt', '$video{"out_filepath"} . ".vtt"']
            ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-codec:v', 'copy', '-strict', 'experimental', '-codec:a', 'aac', '-ac', '2', '-f', 'dash',  '$video{"out_filepath"}']
            , 'ext' => 'mpd', 'desired_audio' => 'aac',
	    'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/dash_player.html'}, #'-use_timeline', '0', '-min_seg_duration', '20000000',
            
            'flv' => {'lock' => 1, 'create_cmd' => "ffmpeg -re -i '%s' -strict experimental -acodec aac -ab 64k -vcodec copy -flush_packets 1 -f flv '%s'", 'create_cmd_args' => ['requestfile', 'outpathext'], 'ext' => 'flv',
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/flv_player.html', 'minsize' => '1048576'},
            
            'jsmpeg' => {'lock' => 0, 'create_cmd' => ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-f', 'mpegts', '-codec:v', 'mpeg1video', '-codec:a', 'mp2', '-b', '0',  '$video{"out_filepath"}'], 'ext' => 'ts',
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/jsmpeg_player.html', 'minsize' => '1048576'},
            #'-c:v', 'copy'
            'mp4' => {'lock' => 1, 'create_cmd' => ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-c:v', 'copy', '-c:a', 'aac', '-f', 'mp4', '-movflags', 'frag_keyframe+empty_moov', '$video{"out_filepath"}'], 
            'ext' => 'mp4',
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/mp4_player.html', 'minsize' => '1048576'}, 
            
            'mp4seg' => {'lock' => 0, 'create_cmd' => '',  'create_cmd_args' => ['requestfile', 'outpathext', 'outpath'], 'ext' => 'm3u8', 
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/mp4seg_player.html', }, #'minsize' => '20971520'},
            
            'noconv' => {'lock' => 0, 'create_cmd' => [''], 'ext' => '', 'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/noconv_player.html', },
            
            'yt' => {'lock' => 1, 'create_cmd' => ['youtube-dl', '--no-part', '--print-traffic', '-f', 
            '$VIDEOFORMATS{"yt"}{"youtube-dl_fmts"}{$querystringStruct->{"media"} // "video"} // "best"', '-o', '$video{"out_filepath"}', '$querystringStruct->{"id"}'], 'ext' => 'yt', 
            'youtube-dl_fmts' => {'music' => 'bestaudio', 'video' => 'best'}, 'minsize' => '1048576'}
);

my %RESOURCES;
my $server = HTTP::BS::Server->new($SETTINGS);

sub shell_escape {
    my ($cmd) = @_;
    ($cmd) =~ s/'/'"'"'/g;
    return $cmd;
}


sub HandleGET {
    my ($client, $pathStruct, $querystringStruct, $headerStruct) = @_;   
    my $unsafePath = $pathStruct->{'unsafepath'};
    my $requestfile = $pathStruct->{'requestfile'};       
    my $startpos =  $headerStruct->{'_RangeStart'};                 
    my $endpos =  $headerStruct->{'_RangeEnd'}; 
    
    # if the file exists in or below this directory
    my $droot = $SETTINGS->{'DOCUMENTROOT'};
    
    # send player
    if($unsafePath =~ /^(\/(index\.htm(l)?)?)?$/) {
        say "$droot/static/stream.html";
        QueueLocalFile($client, "$droot/static/stream.html", $startpos, $endpos);    
    }
    elsif($unsafePath =~ /^\/video\/?$/) {
        player_video($client, $querystringStruct, $headerStruct);       
    }
    elsif($unsafePath =~ /^\/get_video$/) {
        if(!get_video($client, $querystringStruct, $headerStruct)) {
            Send404($client); 
        }
    }
    elsif($unsafePath =~ /^\/play_video$/) {
        my $buf = '<audio controls autoplay src="get_video?' . $querystringStruct->{'querystring'} . '">Fuck off</video>';
	    QueueBuf($client, $buf, 'text/html', $startpos, $endpos);
    }
    elsif(($unsafePath =~ /^\/yt$/)) {
        youtube_search($client, $querystringStruct);
    }
    elsif($unsafePath =~ /^\/browseext$/) {
        browseext($client, $querystringStruct); 
    }
    elsif($unsafePath =~ /^\/foreign$/) {   
        foreign($client, $querystringStruct);
    }
    elsif($unsafePath =~ /^\/dlext$/) { 
        dlext($client, $querystringStruct);
    }
    elsif($unsafePath =~ /^\/rpc$/) {
        rpc($client, $querystringStruct);    
    }
    elsif(defined $requestfile) {
        if(($requestfile =~ /^$droot/) && (-e $requestfile)) {
            my @badfiles = (abs_path(__FILE__), $SETTINGS->{'CFGDIR'}, $SETTINGS->{'BINDIR'}, $SETTINGS->{'TOOLDIR'}, $SETTINGS->{'DOCDIR'});
            foreach my $badfile (@badfiles) {
                if($requestfile =~ /^\Q$badfile/) {
                    Send404($client);
                    return;
                }
            }
            AcquireFile($client, $requestfile, $headerStruct);                           
        }        
    }     
    else {       
        Send404($client);        
    }
}

# if it would be optimal to gdrive the file
# AND it hasn't been gdrived, or is being gdrived return the newname
# if it is being gdrived return the original file
# if it has been gdrived, return 0
# if its too small or is locked return empty string
# otherwise undef
# (is defined if the file exists)
sub should_gdrive {
    my ($requestfile) = @_;
    if(my $st = stat($requestfile)) {
	if(($st->size > 524288) && (! defined (LOCK_GET_LOCKDATA($requestfile))))   {
            my $gdrivename = $requestfile . '_gdrive';
            if(! -e $gdrivename) {
                if(! -e $gdrivename . '.tmp') {
                    say "should_gdrive: $requestfile";
                    return $gdrivename;
                }
                else {
                    say "Already gdriving: $requestfile";
                    return $requestfile;
                }                            
            }
            say "gdrivefile already exists";
            return 0;            
        } 
        say "should not gdrive, file is locked or LEQ 1M";
        return '';        
    }
    else {
        say "Should not gdrive can't stat: $requestfile";
    }
    return undef;    
}

sub rpc {
    my ($client, $querystringStruct) = @_;
    
    my $event = $querystringStruct->{'event'};
    if($event) {
        my $infoHash = $querystringStruct->{'infoHash'};
        if($event eq 'inserted') {
            say "RPC: inserted $infoHash";
            Send404($client);
            return;
        }    
    }
    Send404($client);
}

sub curl {
    my ($url, $cookiefile, $postdata) = @_;
    my @command = ('curl', '-s', '-v');
    push @command, '-b', $cookiefile, '-c',  $cookiefile if defined $cookiefile;
    push @command, '-d', $postdata if defined $postdata;
    push @command, $url;
    print $_ . ' ' foreach @command;
    print "\n";
    my $response = '';
    my $verbose = '';
    
    my ($in, $out, $err);
    use Symbol 'gensym'; $err = gensym;
    my $pid = open3($in, $out, $err, @command) or say "BAD CURL";
    {
        local $/;
        $response = <$out> if $out;
        $verbose = <$err> if $err;
    }
    #open(my $rfh,  '-|' , @command) or die $!;
    #{
    #    local $/;
    #    $response = <$rfh> if $rfh;
    #}
    #close($rfh);
    #say $response;
    say $verbose;
    return (\$response, \$verbose);
}

sub xmlrpc {    
    my @command = ('xmlrpc', $SETTINGS->{'XMLRPC_DEETS'}{'site'}, @_, '-username=' . $SETTINGS->{'XMLRPC_DEETS'}{'username'}, '-password=' . $SETTINGS->{'XMLRPC_DEETS'}{'password'});    
    print $_ . ' ' foreach @command;
    print "\n";
    my $response = '';
    my @results;
    open(my $rfh,  '-|' , @command) or die $!;
    while(my $line = <$rfh>) {
        my @subresults;     
        if($line =~ /Index\s+\d+\sArray\sof\s+(\d+)\sitems/) {          
            my $numitems = $1;                      
            for(my $i = 0; $i < $numitems; $i++) {
                $line = <$rfh>;
                if(($line =~ /String:\s'(.+)'$/) || ($line =~ /integer:\s(.+)$/)) {
                    push @subresults, $1;               
                }           
            }                   
        }
        elsif(($line =~ /String:\s'(.+)'$/) || ($line =~ /integer:\s(.+)$/)) {          
            push @subresults, $1;                           
        }
        else {
            next;
        }
        push @results, \@subresults;        
    }
    close($rfh);
    return \@results;
}

sub filename2findex {
    my ($filename, $hash) = @_;
    my $xmlrpcres = xmlrpc('f.multicall', $hash, '', 'f.path=');
    for(my $i = 0; $i < (@$xmlrpcres); $i++) {
        if($xmlrpcres->[$i][0] eq $filename) {
            return $i;            
        }        
    }
}

sub gazelleRequest {
    my ($site_index, $url) = @_;
    my ($curlres, $curlverbose) = curl($EXT_SOURCE_SITES->[$site_index]->{'url'} . $url, $EXT_SOURCE_SITES->[$site_index]->{'cookiefile'});
    my @verboselines = split("\n", $$curlverbose);
    my ($gotRedirect, $isLogin);
    foreach my $line (@verboselines) {
        if($line =~ /HTTP\/[^\s]+\s+302/) {
            $gotRedirect = 1;        
        }
        elsif($gotRedirect && ($line =~ /location:\s+login\.php/i)) {
            my $curldata = 'username=' . $EXT_SOURCE_SITES->[$site_index]->{'username'} . '&password=' . $EXT_SOURCE_SITES->[$site_index]->{'password'};
            curl($EXT_SOURCE_SITES->[$site_index]->{'url'} . '/login.php', $EXT_SOURCE_SITES->[$site_index]->{'cookiefile'}, $curldata); 
            my $verbose;
            ($curlres, $verbose) = curl($EXT_SOURCE_SITES->[$site_index]->{'url'} . $url, $EXT_SOURCE_SITES->[$site_index]->{'cookiefile'});
            say "updated res";
            last;            
        }    
    }    
    return $curlres;
}

sub gazelleJSON {
    my ($site_index, $url) = @_;
    my $res = gazelleRequest($site_index, $url);
    return if ! $$res;
    my $tjson = decode_json($$res);
    return if($tjson->{'status'} ne 'success');
    $tjson = $tjson->{'response'};
    return $tjson;
}

sub torrentLoadURL {
   my ($url, $infoHash, $onLoaded) = @_;
   # ASYNC(xmlrpc, 
   

}


sub dlext {
    my ($client, $querystringStruct) = @_;
    
    my $media = $querystringStruct->{'media'};
    $media //= 'music';
    my $siteindex = $querystringStruct->{'site'};
    $siteindex //= 0;
    my $findex = $querystringStruct->{'findex'};
    my $filename = $querystringStruct->{'filename'};
    
    if($media eq 'music') {
        # get the torrent information
        $querystringStruct->{'id'} =~ s/^\s+|\s+$//g;       
        my $tjson = gazelleJSON($siteindex, '/ajax.php?action=torrent&id=' . $querystringStruct->{'id'}) or return;             

        # check if it's in rtorrent
        my $infoHash = $tjson->{'torrent'}{'infoHash'} or return;
        my $fileCount = $tjson->{'torrent'}{'fileCount'};
        my $torrentSize = $tjson->{'torrent'}{'size'};                                            
     
        
        my ($torrentDone, $torrentLoaded, $fileToQueue, $torrentPath);        

        my $xmlrpcres = xmlrpc('d.bytes_done', $infoHash);
        if(defined $xmlrpcres->[0][0]) {
            $torrentDone = ($xmlrpcres->[0][0] == $torrentSize);
            $torrentLoaded = 1;
            $torrentPath = xmlrpc("d.directory", $infoHash)->[0][0];
        }
        if( ! $torrentDone) {
            say "torrent not done";
            if(!$torrentLoaded) {
                # download the torrent
                my $torrent_dllink = $EXT_SOURCE_SITES->[$siteindex]->{'url'} . '/torrents.php?action=download&id=' . $querystringStruct->{'id'} . '&authkey=' . $EXT_SOURCE_SITES->[$siteindex]->{'authkey'} . '&torrent_pass=' . $EXT_SOURCE_SITES->[$siteindex]->{'torrent_pass'} ;#. '&usetoken=1'; 
                say $torrent_dllink; 
                xmlrpc('load_verbose', $torrent_dllink);                                
                while(1) {
                    xmlrpc("d.directory.set", $infoHash, $SETTINGS->{'MUSIC_ROOT'});
                    say "-------------";
                    $torrentPath = xmlrpc("d.directory", $infoHash)->[0][0];
                    if($torrentPath) {
                        say "torrentPath: $torrentPath";
                        last if(index($torrentPath, $SETTINGS->{'MUSIC_ROOT'}) != -1);
                    }                    
                    sleep 1;
                }

                # set the priority                
                $findex = filename2findex($filename, $infoHash) if(! defined($findex) && defined($filename));
                if(defined($findex)) {
                    xmlrpc('f.multicall', $infoHash, '', 'f.priority.set=0');                                       
                    xmlrpc('f.priority.set', "$infoHash:f$findex", '1');                   
                    print Dumper(xmlrpc('d.update_priorities', $infoHash));                    
                }
                
                # start the torrent
                print Dumper(xmlrpc('d.start', $infoHash));                              
            }
            else {
                # set the priority
                $findex = filename2findex($filename, $infoHash) if(! defined($findex) && defined($filename));
                if(! defined($findex)) {
                    xmlrpc('f.multicall', $infoHash, '', 'f.priority.set=1');                
                }
                else {
                    xmlrpc('f.priority.set', "$infoHash:f$findex", '1');                
                }                
                print Dumper(xmlrpc('d.update_priorities', $infoHash));    
                
                # start the torrent
                print Dumper(xmlrpc('d.stop', $infoHash)); 
                print Dumper(xmlrpc('d.start', $infoHash));                
                
            }
            #say "priority dump";
            #print Dumper( xmlrpc('f.multicall', $infoHash, '', "f.priority="));
            
            # wait for the file(s) to be downloaded
            my $target;
            my @watchcmd;            
            if(defined($findex)) {
                my $xmlrpcout = xmlrpc('f.size_chunks', "$infoHash:f$findex");
                $target = $xmlrpcout->[0][0];                
                @watchcmd = ('f.completed_chunks', "$infoHash:f$findex");                
            }
            else {
                $target = $torrentSize;
                @watchcmd = ("d.bytes_done", $infoHash);
            }            
            while(xmlrpc(@watchcmd)->[0][0] != $target) {
                say "sleep 1";
                sleep 1;
            }
        }
        else {
            $findex = filename2findex($filename, $infoHash) if(! defined($findex) && defined($filename));        
        }

        if(! defined($findex)) {
            my $fname = $tjson->{'torrent'}{'filePath'};
            $fileToQueue = $SETTINGS->{'DOCUMENTROOT'} . "/tmp/" . $fname . '.tar';
            say $fileToQueue;
            system "tar", "-cvPf", $fileToQueue, $torrentPath;
        }
        else {
            binmode(STDOUT, ':utf8');            
            #$torrentPath = encode("utf8", $torrentPath);
            $torrentPath = eval "qq#$torrentPath#"; # Absolutely HARAM
            #$torrentPath = encode("utf8", $torrentPath); 
            #$encoding or die;
            say "torrentPath: $torrentPath";
            $fileToQueue = $torrentPath . '/' . xmlrpc('f.path', "$infoHash:f$findex")->[0][0];            
            say "fileToQueue $fileToQueue";        
        }
        QueueLocalFile($client, $fileToQueue);                     
    }    
    else {    
    
    }
}

sub browseext {
    my ($client, $querystringStruct) = @_;
    
    my $media = $querystringStruct->{'media'};
    $media //= 'music';
    my $siteindex = $querystringStruct->{'site'};
    $siteindex //= 0;
    my $format = $querystringStruct->{'format'};
    $format //= 'html';
    
    my $data = '';  
    if($format eq 'html') {
        my $tmp = GetResource($SETTINGS->{'DOCUMENTROOT'} . '/static/' .  'browse_gazelle_music.html');
        $data .= $$tmp; 
    }
    my $mime;
    if($querystringStruct->{'action'}) {        
        if($format eq 'html') {
            $mime = getMIME('.html');
            $querystringStruct->{'format'} = 'json';
            my $turl = 'browseext?';
            foreach my $key (keys %$querystringStruct) {
                if($key ne 'querystring') {
                    $turl .= "$key=" . $querystringStruct->{$key} . '&';                
                }           
            }
            chop $turl;         
            $data .= '<script>get_browse(\'' .  $turl . '\');</script>';
        }
        else {
            $mime = getMIME('.json');
            if($media eq 'music') {
                my $turl = '/ajax.php?';
                foreach my $key (keys %$querystringStruct) {
                    if ($key ~~ [qw( querystring media site format )]) {
                        next;
                    }
                    $turl .= "$key=" . $querystringStruct->{$key} . '&';                                
                }
                chop $turl;             
                              
                my $response = gazelleRequest($siteindex, $turl);
                $$response =~ s/https/foreign\?url=https/g;                
                $data .= $$response;                
            }       
        }
    }
    QueueBuf($client, $data, $mime);    
}

sub foreign {
    my ($client, $querystringStruct) = @_;
    my $url = $querystringStruct->{'url'};
    my ($response, $verbose) = curl($url);
    QueueBuf($client, $$response, getMIME($url), 0);
}

sub SendByGDRIVE {
    my ($client, $tmpname) = @_;
    my $gdrivename = $tmpname . '_gdrive';
    if( ! -e $gdrivename) {
        ASYNC(\&_gdrive_upload, $tmpname);
        say "After ASYNC";    
        my %filepair = ( 'sock' => $client->{'sock'}, 'client' => $client, 'filename' => $gdrivename, 'fmt' => '302');
        say "SendByGDRIVE: adding waiting_files $gdrivename";
        push @$EventLoop::Poll::WAITING_FILES, \%filepair;
    }
    else {    
        QueueLocalFile($client, $gdrivename);     
    }

}

sub video_get_format {
    my ($fmt) = @_; 
    if(!defined($fmt) || !defined($VIDEOFORMATS{$fmt})) {
        $fmt = 'hls';
    }
    return $fmt;
}

sub gdrive_upload {
    my ($file) = @_;
    #BADHACK, gdrive things not in the temp dir
    #my $tmpdir = $SETTINGS->{'TMPDIR'};
    #if($file =~ /^$tmpdir/) 
    
    {
        my $fnametmp = $file . '_gdrive.tmp';
        open(my $tmpfile, ">>", $fnametmp) or die;
        close($tmpfile);
    }
    ASYNC(\&_gdrive_upload, $file);
}

sub url_effective {
    my ($url, $cookiefile) = @_;
    my @cmd = ('curl', '-Ls', '-I', '-w', '%{url_effective}', $url);
    push (@cmd, ('-b', $cookiefile)) if($cookiefile);
    my $cmdout = shell_stdout(@cmd);
    say "url_effective res:----------------";
    print $cmdout;
    say "end url_effective res-------------";
    my @lines = split("\n", $cmdout);
    my $effective = $lines[@lines - 1];
    #say "effective: $effective";
    return $effective;
}

sub _gdrive_upload {
    my ($filename) = @_;    
    my $cmdout = shell_stdout('perl', $SETTINGS->{'BINDIR'} . '/gdrivemanager.pl', $filename, $SETTINGS->{'CFGDIR'} . '/gdrivemanager.json');
    say $cmdout; 
    my ($id, $newurl) = split("\n", $cmdout);   
    my $url;    
    my $fname = $filename . '_gdrive';
    gdrive_add_tmp_rec($id, $fname);
    my $fname_tmp = $fname . '.tmp';
    write_file($fname_tmp, $newurl);
    rename($fname_tmp, $fname);
}

sub gdrive_add_tmp_rec {
    my ($id, $gdrivefile) = @_;
    write_file($SETTINGS->{'GDRIVE_TMP_REC_DIR'} . "/$id", $gdrivefile);
}

sub gdrive_remove_tmp_rec {

    my @files;

    my $curdir = getcwd();
    # find all files newer that are older than
    my $current_time = time();
    eval {
        File::Find::find({wanted => sub {        
            if((($current_time - stat($_)->mtime) > 1000) && ($_ ne '.')) {
                push @files, $File::Find::name; 
                die if(@files == 10); # only delete 10 files at a time because api limits               
            }
            
        }}, $SETTINGS->{'GDRIVE_TMP_REC_DIR'}); 
    };    
    chdir($curdir);
    
    say "deleting: " if @files;
    foreach my $file (@files) {
        say "id: $file";
        my $gdrivefile = read_file($file);
        say "gdrivefile: $gdrivefile";
        unlink($gdrivefile);
        unlink($file);
        ASYNC(sub {
            exec $SETTINGS->{'BINDIR'}.'/upload.sh',  '--delete', basename($file), '--config', $SETTINGS->{'CFGDIR'} . '/.googledrive.conf';        
        });               
    }
}

sub youtube_search {
    my ($client, $querystringStruct) = @_;
    my $media = $querystringStruct->{'media'};
    $media //= 'music';
    my $musicchecked = '';
    my $videochecked = '';
    if($media eq 'music') {
        $musicchecked = 'checked';
    }
    elsif($media eq 'video') {
    $videochecked = 'checked';
    }
    my $tmptext = $querystringStruct->{'search_query'};
    $tmptext //= '';
    my $html = '<html><head></head><body>';
    if(! defined $querystringStruct->{'pdfonly'}) {
        #$html .= '<form id="searchfrm">';
        $html .= '<input type="text" id="squery" name="search_query" value="' . "$tmptext\">";
        $html .= '<input type="radio" name="media" value="music" ' . "$musicchecked> music ";
        $html .= '<input type="radio" name="media" value="video" ' . "$videochecked> video ";
        $html .= '<button id="searchbtn">Search</button>';
        $html .= '<br><br>';
        #$html .= '</form>';
        $html .= '<script>';
        $html .= 'var sbtn = document.getElementById("searchbtn");';        
        $html .= "sbtn.addEventListener('click', function() { 
        var radios = document.getElementsByName('media');
        
        function loadDoc(url, cFunction) {
  var xhttp;
  xhttp=new XMLHttpRequest();
  xhttp.onreadystatechange = function() {
    if (this.readyState == 4 && this.status == 200) {
      cFunction(this);
    }
  };
  xhttp.open(\"GET\", url, true);
  xhttp.send();
}

        var media;
for (var i = 0, length = radios.length; i < length; i++)
{
 if (radios[i].checked)
 {
  // do whatever you want with the checked radio
  media = radios[i].value;

  // only one radio can be logically checked, don't check the rest
  break;
 }
}
        var sq = document.getElementById('squery').value;       
       
        loadDoc('yt?search_query=' + sq + '&media=' + media + '&pdfonly=1', function (xhttp) {
            var pdfplace = document.getElementById(\"pdfarea\");
            pdfplace.innerHTML = xhttp.responseText;
        });     
        
        }, false);";
        $html .= '</script>';
    }
    
    if(defined $querystringStruct->{'id'}) {
        my $url = '/music/playyt.php?id=' . $querystringStruct->{'id'} . "&media=$media";
        if($media eq 'music') {
            $html .= "<audio src=\"$url\" controls autoplay> Your browser sux lol </audio>";
        }
        elsif($media eq 'video') {
            $html .= "<video src=\"$url\" controls autoplay> Your browser sux lol </video>";
        }
        else {
            say "UNKNOWN MEDIA youtube_search";
        }       
    }
    
    #$querystringStruct->{'search_query'} //= '';
    $html .= '<div id="pdfarea">';
    if(defined $querystringStruct->{'search_query'}) {
        my $param = $querystringStruct->{'search_query'};
        my $droot = $SETTINGS->{'DOCUMENTROOT'};
        say "searchparam: $param";
            system "google-chrome --headless --print-to-pdf='$droot/tmp/$param.pdf' 'https://www.youtube.com/results?search_query=$param'";
        $html .= '<iframe id="ytframe" src="' . "tmp/$param.pdf" . '" width="1280" height="720" ></iframe>';
        #my $embedded = '<object data="' . "$param.pdf" . '" type="application/pdf">sampletext</object>';
        #write_file("$droot/tmp/$param.html", $embedded);
        $html .= '</div>';
        
        my $pdfcontent = read_file("$droot/tmp/$param.pdf");
        my $domain = quotemeta $SETTINGS->{'DOMAIN'};
        $pdfcontent =~ s/www\.youtube\.com\/watch\?v=(.+)\)/$domain\/stream\/yt?id=$1&media=$media\)/g;
        $pdfcontent =~ s/www\.youtube\.com\/results/$domain\/stream\/yt/g;
        $pdfcontent =~ s/https:\/\/www\.youtube\.com//g;
        write_file("$droot/tmp/$param.pdf", $pdfcontent);
    }
    QueueBuf($client, $html, 'text/html');
}

sub urlencode {
    my ($string) = @_;
    $string =~ s/([^^A-Za-z0-9\-_.!~*'()])/ sprintf "%%%0x", ord $1 /eg;
    return $string;
}

sub space2us {
    my ($string) = @_;
    $string =~ s/\s/_/g;
    return $string;
}

sub shell_stdout {
    return do {
	local $/ = undef;
    print "shell_stdout: ";
    print "$_ " foreach @_;
    print "\n";
    open(my $cmdh, '-|', @_) or die("shell_stdout $!");
	<$cmdh>;
    }
}

sub video_get_streams {
    my ($video) = @_;
    my $input_file = $video->{'src_file'}{'filepath'};    
    my @command = ('ffmpeg', '-i', $input_file);
    my ($in, $out, $err);
    use Symbol 'gensym'; $err = gensym;
    my $pid = open3($in, $out, $err, @command) or say "BAD FFMPEG";
    $video->{'audio'} = [];
    $video->{'video'} = [];
    $video->{'subtitle'} = [];
    
    my $current_stream;
    my $current_element;
    while(my $eline = <$err>) {      
       if($eline =~ /^\s*Stream\s#0:(\d+)(?:\((.+)\)){0,1}:\s(.+):\s(.+)(.*)$/) {           
           my $type = $3;
           $current_stream = $1;
           $current_element = { 'sindex' => $current_stream, 'lang' => $2, 'fmt' => $4, 'additional' => $5, 'metadata' => '' };
           $current_element->{'is_default'} = 1 if($current_element->{'fmt'} =~ /\(default\)$/i);
	       $current_element->{'is_forced'} = 1 if($current_element->{'fmt'} =~ /FORCED/i);
           if($type =~ /audio/i) {
               push @{$video->{'audio'}} , $current_element;       
           }
           elsif($type =~ /video/i) {
               push @{$video->{'video'}} , $current_element;
           }
           elsif($type =~ /subtitle/i) {           
               push @{$video->{'subtitle'}} , $current_element;
           }
           say $eline;       
       }
       elsif($eline =~ /^\s+Duration:\s+(\d\d):(\d\d):(\d\d)\.(\d\d)/) {
           #TODO add support for over day long video
           $video->{'duration'} //= "PT$1H$2M$3.$4S";
           write_file($video->{'out_location'} . '/duration',  $video->{'duration'});        
       }     
       elsif(defined $current_stream) {
           if($eline !~ /^\s\s+/) {
               $current_stream = undef;
               $current_element = undef;
               next;                
           }      
           $current_element->{'metadata'} .= $eline;
           if($eline =~ /\s+title\s*:\s*(.+)$/) {            
               $current_element->{'title'} = $1;
           }
       }              
    }
    print Dumper($video);
    return $video;
}

sub video_buildcmd_map_notdefault_subs {
    my ($video) = @_;
    my @maps;
    foreach my $sub (@{$video->{'subtitle'}}) {
	next if($sub->{'is_default'} || $sub->{'is_forced'});
        push @maps, ('-flush_packets', '1', '-map', '0:' . $sub->{'sindex'}, '-f', 'webvtt');
    }
    return \@maps;
}

sub media_filepath_to_src_file {
    my ($filepath) = @_;
    my ($name, $loc, $ext) = fileparse($filepath, '\.[^\.]*');
    $ext =~ s/^\.//;
    return { 'filepath' => $filepath, 'name' => $name, 'location' => $loc, 'ext' => $ext};
}

sub video_file_lookup {
    my ($filename) = @_; 
    my @locations = ($SETTINGS->{'VIDEO_ROOT'}, $SETTINGS->{'MUSIC_ROOT'});    
    
    my $filepath;
    foreach my $location (@locations) {
	    my $absolute = abs_path("$location/$filename");
        if($absolute && -e $absolute  && ($absolute =~ /^$location/)) {
	        $filepath = $absolute;
	        last;
	    }
    }    
    return if(! $filepath);

    return media_filepath_to_src_file($filepath);  
}

sub media_file_search {
    my ($filename) = @_;
    my @locations = ($SETTINGS->{'VIDEO_ROOT'}, $SETTINGS->{'MUSIC_ROOT'});

    say "basename: " . basename($filename) . " dirname: " . dirname($filename);
    my $dir = dirname($filename);
    $dir = undef if ($dir eq '.');    
    my $filepath = FindFile(\@locations, basename($filename), $dir);
    return if(! $filepath);
    
    my $src_file =  media_filepath_to_src_file($filepath);    
    foreach my $location(@locations) {        
        if($filepath =~ /^$location\/(.+)$/) {            
            $src_file->{'qname'} = $1;
            return $src_file;
        }
    }    
}

sub get_video {
    my ($client, $querystringStruct, $headerStruct) = @_;
    my $droot = $SETTINGS->{'DOCUMENTROOT'};
    my $vroot = $SETTINGS->{'VIDEO_ROOT'};
    say "/get_video ---------------------------------------";
    my %video = ('out_fmt' => video_get_format($querystringStruct->{'fmt'}));
    if(defined($querystringStruct->{'name'})) {        
        my $src_file;
        if($src_file = video_file_lookup($querystringStruct->{'name'})) {
	        $video{'src_file'} = $src_file;
            $video{'out_base'} = $src_file->{'name'};
        }
        elsif($src_file = media_file_search($querystringStruct->{'name'})) {
	    say "useragent: " . $headerStruct->{'User-Agent'};
            if($headerStruct->{'User-Agent'} !~ /^VLC\/2\.\d+\.\d+\s/) {
	    my $url = 'get_video?' . $querystringStruct->{'querystring'};
            my $qname = uri_escape($src_file->{'qname'});
            $url =~ s/name=[^&]+/name=$qname/;
            say "url: $url";
            my $buf = "HTTP/1.1 301 Found\r\nLocation: $url\r\n"; 
            $buf .= "\r\n";
            my %fileitem;
            $fileitem{'length'} = 0;
            $fileitem{'buf'} = $buf;
            push(@{$client->{'queuedata'}}, \%fileitem);
            return 1;
    }
            $video{'src_file'} = $src_file;
            $video{'out_base'} = $src_file->{'name'};
        }
        else {
            return undef;
        }        
    }
    elsif(defined($querystringStruct->{'id'})) {    
        my $media;
        if(defined $querystringStruct->{'media'} && (defined $VIDEOFORMATS{$video{'out_fmt'}}{'youtube-dl_fmts'}{$querystringStruct->{'media'}})) {
            $media = $querystringStruct->{'media'};
        }
        else  {
            $media = 'video';
        }        
        $video{'out_base'} = $querystringStruct->{'id'} . '_' . $media;
    }
    else {
        return undef;
    }
   
    my $fmt = $video{'out_fmt'};
    # soon https://github.com/video-dev/hls.js/pull/1899
    $video{'out_base'} = space2us($video{'out_base'}) if ($video{'out_fmt'} eq 'hls');
	$video{'out_location'} = $SETTINGS->{'VIDEO_TMPDIR'} . '/' . $video{'out_base'};
	$video{'out_filepath'} = $video{'out_location'} . '/' . $video{'out_base'} . '.' . $VIDEOFORMATS{$video{'out_fmt'}}->{'ext'};
    $video{'base_url'} = 'tmp/' . $video{'out_base'} . '/';
    if($video{'out_fmt'} eq 'noconv') {
        $video{'out_filepath'} = $video{'src_file'}->{'filepath'};    
    }
    if(-e $video{'out_filepath'}) {        
         say $video{'out_filepath'} . " already exists";
         
         #shell_stdout('ln', '-s', $video{'out_filepath'}, $SETTINGS->{'TMPDIR'});
         my $tdir = $SETTINGS->{'TMPDIR'};
         my $tmpfile = $video{'out_filepath'};
         if($video{'out_filepath'} !~ /$tdir/) {
             $tmpfile = $SETTINGS->{'TMPDIR'} . '/'  . basename($video{'out_filepath'});
             if(! -e $tmpfile) {
                 shell_stdout('cp', $video{'out_filepath'}, $SETTINGS->{'TMPDIR'});
             }         
         }
                 
         AcquireFile($client, $tmpfile, $headerStruct);
         #QueueLocalFile($client, $video{'out_filepath'},  $headerStruct->{'_RangeStart'}, $headerStruct->{'_RangeEnd'});          
    }
    elsif( defined($VIDEOFORMATS{$fmt}->{'create_cmd'})) {
	    mkdir($video{'out_location'});
	    say "FAILED to LOCK" if(($VIDEOFORMATS{$fmt}->{'lock'} == 1) && (LOCK_WRITE($video{'out_filepath'}) != 1));                       
	    if($VIDEOFORMATS{$fmt}->{'create_cmd'}[0] ne '') {
            my @cmd;
            foreach my $cmdpart (@{$VIDEOFORMATS{$fmt}->{'create_cmd'}}) {
                if($cmdpart =~ /^\$/) {
                    push @cmd, eval($cmdpart);
                }
                else {
                    push @cmd, $cmdpart;
                }                
            }
            print "$_ " foreach @cmd;
            print "\n";
            #if(defined $video{'src_file'}) {
            #    video_get_streams(\%video);
            #}
            video_get_streams(\%video);
            if($fmt eq 'hls') {                    
                $video{'on_exists'} = \&video_write_master_playlist;                                         
            }
	        elsif($fmt eq 'dash') {
                $video{'on_exists'} = \&video_dash_check_ready;
	        }
            #elsif($mft eq 'yt') {
            #    $video{'on_exists'}            
            #}
	        ASYNC_ARR(\&shellcmd_unlock, \@cmd, $video{'out_filepath'});            
        }           
        else {
	        return undef;
        }         
        
        my %filepair = ( 'sock' => $client->{'sock'}, 'client' => $client, 'filename' => $video{'out_filepath'}, 'startpos' => $headerStruct->{'_RangeStart'}, 'endpos' => $headerStruct->{'_RangeEnd'}, 'fmt' => $fmt);
        if(defined $video{'on_exists'}) {
            $filepair{'on_exists'} = { 'func' => $video{'on_exists'}, 'param' => \%video };
        }
        say "get_video: adding waiting_files " . $video{'out_filepath'};
        push @$EventLoop::Poll::WAITING_FILES, \%filepair;               
    }
    return 1;    
}

sub video_dash_check_ready {
    my ($video) = @_;
    my $mpdcontent = read_file($video->{'out_filepath'});

    foreach my $line (split("\n", $mpdcontent)) {
        return 1 if($line =~ /<S.+d=.+\/>/);
    }
}

sub video_dash_write_manifest {
    my ($video) = @_;
    my $requestfile = $video->{'out_filepath'};    
    ($requestfile =~ /^(.+)\.mpd$/);
    my $base = "tmp/" . basename($1) . "/";
    my $mpdcontent = read_file($requestfile);
    my $newmpd = '';
    my $wrote_duration;
    foreach my $line (split("\n", $mpdcontent)) {
        $line =~ s/(initialization=")(init-stream)/$1$base$2/;
	    $line =~ s/(media=")(chunk-stream)/$1$base$2/;
   
	    if($line =~ /^(\s+)type="dynamic"/) {
            my $out_location = dirname($requestfile);
            if(-e "$out_location/duration") {
                my $duration = read_file("$out_location/duration");                
                $newmpd .= $1 . 'mediaPresentationDuration="' . $duration . '"' . "\n";
	    	    $wrote_duration = 1;      
            }            
	    }
        elsif($wrote_duration && ($line =~ /mediaPresentationDuration/)) {
            $line = '';      
        }
	    $newmpd .= $line . "\n";
    }
    write_file($requestfile, $newmpd);
    return 1;
}
sub video_write_master_playlist {
    # Rebuilt the master playlist because reasons; YOU ARE TEARING ME APART, FFMPEG!
    my ($video) = @_;
    my $requestfile = $video->{'out_filepath'};    
    
    # fix the path to the video playlist to be correct    
    my $m3ucontent = read_file($requestfile);
    my $subm3u;
    my $newm3ucontent = '';
    foreach my $line (split("\n", $m3ucontent)) {
        if($line =~ /^(.+)\.m3u8_v$/) {                 
            $subm3u = "tmp/$1/$1";
             $line = $subm3u . '.m3u8_v';	        	    
        }
        $newm3ucontent .= $line . "\n";
    }
    
    # Always start at 0, even if we encoded half of the movie
    #$newm3ucontent .= '#EXT-X-START:TIME-OFFSET=0,PRECISE=YES' . "\n";
    
    # if ffmpeg created a sub include it in the playlist
    ($requestfile =~ /^(.+)\.m3u8$/);    
    my $reqsub = "$1_vtt.m3u8";  
    if($subm3u && -e $reqsub) {
        $subm3u .= "_vtt.m3u8";                       
        say "subm3u $subm3u";
        my $default = 'NO';
        my $forced =  'NO';
        foreach my $sub (@{$video->{'subtitle'}}) {
	        #if($sub->{'is_default'} || $sub->{'is_forced'}) {
            #    $default = 'YES';
            #    $forced = 'YES';
                $default = 'YES' if($sub->{'is_default'});
                $forced = 'YES' if($sub->{'is_forced'});            
            #}        
        }
        # assume its in english
        $newm3ucontent .= '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT='.$default.',FORCED='.$forced.',URI="' . $subm3u . '",LANGUAGE="en"' . "\n";	                       
    }
    write_file($requestfile, $newm3ucontent);
    return 1;
}

sub shellcmd_unlock {
    my ($command_arr, $fullpath) = @_;
    system @$command_arr;
    #say "FP $fullpath";
    UNLOCK_WRITE($fullpath);
}

sub ASYNC_ARR {
    my $func = shift;
    $SIG{CHLD} = "IGNORE";
    if(fork() == 0) {
        $func->(@_);
	exit 0;
    }
}

sub ASYNC {
    my ($func, $arg) = @_;
    $SIG{CHLD} = "IGNORE";
    if(fork() == 0) {
    $func->($arg);
    exit 0;
    }    
}

sub AcquireFile {
    my($client, $requestfile, $header) = @_;
   
    my @togdrive;            
    if(my $gdrivefile = should_gdrive($requestfile)) {
        if($gdrivefile =~ /_gdrive$/) {
            push @togdrive, $requestfile;
        }
        else {
            $gdrivefile .= '_gdrive';
        }
	    
        if($header->{'User-Agent'} !~ /Linux.+Firefox/){
	        my %filepair = ( 'sock' => $client->{'sock'}, 'client' => $client, 'filename' => $gdrivefile);    
	        push @$EventLoop::Poll::WAITING_FILES, \%filepair;
	    }
	    else {
	        # The file is not ready on google drive, so send it from here, but cancel when it is
	        # so it is resumed on google drive
	        QueueLocalFile($client, $requestfile, $header->{'_RangeStart'}, $header->{'_RangeEnd'});
	        push(@$EventLoop::Poll::WAITING_FILES, {'filename' => $gdrivefile, 'no_remove' => 1, 'sock' => $client->{'sock'}, 'on_exists' => { 'func' => sub {
                $client->cleanup();    
	        }}});
        }
    }
    else {
        my $tosend = $requestfile;
        if((defined $gdrivefile) && looks_like_number($gdrivefile)) {                                        
            $tosend .= '_gdrive';
        }
        QueueLocalFile($client, $tosend, $header->{'_RangeStart'}, $header->{'_RangeEnd'});                                
    }

    # queue up future hls files
    if( $requestfile =~ /^(.+[^\d])(\d+)\.ts$/) {
        my ($start, $num) = ($1, $2);
        # no more than 3 uploads should be occurring at a time
        for(my $i = 0; ($i < 3) && (scalar(@togdrive) < 3); $i++) {                     
            my $extrafile = $start . sprintf("%04d", ++$num) . '.ts';                    
            my $shgdrive;
            if(($shgdrive = should_gdrive($extrafile)) && ( $shgdrive =~ /_gdrive$/)) {
                push @togdrive, $extrafile;                                               
            }
            else {
                last if(! defined($shgdrive));
            }                    
        }                                   
    }
    
    foreach my $file (@togdrive) {
        gdrive_upload($file);                                
    }
}

sub TrySendQueueData {
    my ($client) = @_;
    my $csock = $client->{'sock'};
    
    # foreach queue item
    while(scalar(@{$client->{'queuedata'}}) > 0) {
        my $dataitem = $client->{'queuedata'}->[0];

        my ($buf, $bytesToSend);
        if(defined $dataitem->{'buf'}) {
            $buf = $dataitem->{'buf'};
            $dataitem->{'buf'} = undef; 
            use bytes;
            $bytesToSend = length $buf;        
        }        
        
        do {
            # Try to send the buf if set
            if(defined $buf) {
                $client->{'time'} = clock_gettime(CLOCK_MONOTONIC);
                use bytes;
                #my $n = length($buf);
                my $remdata = TrySendItem($csock, $buf, $bytesToSend);        
                # critical conn error
                if(! defined($remdata)) {
                    say "-------------------------------------------------";
                    return undef;
                }
                # eagain or not all data sent
                elsif($remdata ne '') {
                    $dataitem->{'buf'} = $remdata;                    
                    return '';
                }
                else {
                    #we sent the full buf
                }
                $buf = undef;                
            }
            
            #try to grab a buf from the file         
            if(defined $dataitem->{'fh'}) {            
                my $FH = $dataitem->{'fh'};                
                my $req_length = $dataitem->{'length'};
                if(($req_length == 99999999999) && (! defined(LOCK_GET_LOCKDATA($dataitem->{'requestfile'})))) {
                    $req_length = stat($FH)->size;
                    $dataitem->{'length'} = $req_length;
                    say "length is actually $req_length";                    
                }
                my $filepos = tell($FH);
                if($req_length && ($filepos >= $req_length)) {
                    if($filepos > $req_length) {
                        die "Reading too much tell: $filepos req_length: $req_length";
                    }
                    say "file read done";
                    close($FH);
                }
                else {
                    my $readamt = 24000;
                    my $tmpsend = $req_length - $filepos;
                    $readamt = $tmpsend if($tmpsend < $readamt);
                    $bytesToSend = read($FH, $buf, $readamt);
                    
                    #$bytesToSend = sysread($FH, $buf, $readamt);
                    if(! defined($bytesToSend)) {
                        $buf = undef;
                        say "READ ERROR: $!";            
                    }
                    elsif($bytesToSend == 0) {
                        # read EOF, better remove the error
                        seek($FH, 0, 1);                       
                        return '';
                    }                    
                }
            }        
                  
        } while(defined $buf);        
        splice(@{$client->{'queuedata'}}, 0, 1);
    }

    say "DONE Sending Data";    
    return undef; # commented 10-02-18 for keep-alive
    #return ''; # messes with incomplete partial requests
}

sub TrySendItem {
    my ($csock, $data, $n) = @_;
    my $total = $n;
    my $sret;
    if(! defined($sret = $csock->send($data, MSG_DONTWAIT))) {                
        if($!{ECONNRESET}) {
            print "ECONNRESET\n";
            return undef;
        }
        elsif($!{EPIPE}) {
            print "EPIPE\n";
            return undef;
        }
        elsif($!{EAGAIN}) {         
            #say "SEND EAGAIN\n";
            return $data;           
        }
        else {
            print "send errno $!\n";
            return undef;
        }       
            
    }
    elsif($sret != $n) {
        $data = substr($data, $sret);
        $n = $n - $sret;
        say "Wrote $sret bytes out of $total, $n bytes to go";
        return $data;   
    }
    else {
        # success we sent everything
        return '';      
    }   
}

sub read_file {
my ($filename) = @_;
return do {
    local $/ = undef;
    if(!(open my $fh, "<", $filename)) {
        #say "could not open $filename: $!";
        return -1;
    }
    else {
        <$fh>;
    }
};
}

sub LOCK_WRITE {    
    my ($filename, $lockdata) = @_;
    my $lockname = "$filename.lock";
    if(-e $lockname) {
        return 0;       
    }
    $lockdata //= "99999999999"; #99 Billion
    write_file($lockname, $lockdata); 
    return 1;
}


sub UNLOCK_WRITE {
    my ($filename) = @_;    
    my $lockname = "$filename.lock";
    if (-e $lockname) {
        unlink($lockname);
    }
}   

sub LOCK_GET_LOCKDATA {
    my ($filename) = @_;
    my $lockname = "$filename.lock";    
    my $bytes = read_file($lockname);
    if($bytes <= 0) {
        return undef;
    }
    return $bytes;
}

sub HTTP_BuildHeaders {
    my ($datalength, $mime, $start, $end) = @_;
    my $retlength;
    my $headtext;   
    my $cend =  $datalength - 1;    
    my $is_partial = ( defined $start);
    if(! defined $start) {
        $start = 0;    
    }
    $retlength = $datalength;
    say "datalength: $datalength";
    if($datalength == 99999999999) {
        $datalength = '*';             
        #$is_partial = 0;
    }
    #$is_partial = 0;
    if (! $is_partial) {
        $headtext = "HTTP/1.1 200 OK\r\n";
    }
    else {
	    say "end: $end" if(defined($end));
        $cend = $end if(defined($end) && $end ne '');
        $headtext = "HTTP/1.1 206 Partial Content\r\n"; 
        $retlength = $cend+1;        
	    say "cend: $cend";
        $headtext .= "Content-Range: bytes $start-$cend/$datalength\r\n";
    }
    if($datalength ne '*') {
        say "sending contentlength";
        my $contentlength = $cend - $start + 1;
        $headtext .= "Content-Length: $contentlength\r\n";
    }
    else {
        say "sending contentlength";
        $headtext .= "Content-Length: *\r\n";
    }
    $headtext .=   "Content-Type: $mime\r\n";
    $headtext .=   "Accept-Ranges: bytes\r\n";
    #$headtext .=   "Accept-Ranges: none\r\n";
    $headtext .=   "Connection: keep-alive\r\n";    
    $headtext .= "\r\n";  
    
    return ($retlength, \$headtext);
}

sub QueueBuf {
    my ($client, $buf, $mime, $start, $end) = @_;
    
    my $bytesize;
    {
        use bytes;
        $bytesize = length($buf);
    }
    my $headtext;   
    my %fileitem;
    ($fileitem{'length'}, $headtext) = HTTP_BuildHeaders($bytesize, $mime, $start, $end);    
    $fileitem{'buf'} = $$headtext . $buf;
    push @{$client->{'queuedata'}}, \%fileitem;
}

sub QueueLocalFile {
    my ($client, $requestfile, $start, $end) = @_;    
    if(!( -e $requestfile)) {       
        Send404($client);
        return;
    }

    # Dash has some issues
    if($requestfile =~ /\.mpd$/) {
	my $video = { 'out_filepath' => $requestfile };
        video_dash_write_manifest($video);
    }   

    #if it's googledrive read the link and redirect
    if($requestfile =~ /_gdrive$/) {
        my $url = read_file($requestfile);
        my $buf = "HTTP/1.1 307 Temporary Redirect";
        #my $buf = "HTTP/1.1 301 Moved Permanently";
        $buf .= "\r\nLocation: $url\r\n"; # https://cors-anywhere.herokuapp.com/$url\r\n"
        $buf .= "\r\n";
        my %fileitem;
        $fileitem{'length'} = 0;
        $fileitem{'buf'} = $buf;
        push(@{$client->{'queuedata'}}, \%fileitem);
        return;
    }
    
    my %fileitem;
    my $filelength = LOCK_GET_LOCKDATA($requestfile);    
    my $VIA_XSEND = ((! defined $filelength) && ($SETTINGS->{'XSEND'} == 1));
    if($VIA_XSEND) {
        #let nginx handle Content-Length for us
        die("ENOTIMPLEMENTED");
    }
    elsif(! open(my $FH, "<", $requestfile)) {
        Send404($client);
        return;
    }
    else {
        binmode($FH);
        seek($FH, $start // 0, 0);   
        $fileitem{'fh'} = $FH;
        $fileitem{'requestfile'} = $requestfile;
        if(! defined $filelength) {
            $filelength = stat($FH)->size;
        }
        # if tailing file, force return a partial response #invalid comment
        elsif(defined($start) && !$end && ($filelength == 99999999999)) {
            say "setting end";
            $end = (stat($FH)->size - 1);
        }
    }
     
    # build the header based on whether we are sending a full response or range request
    my $headtext;    
    my $mime = getMIME($requestfile);
    
    my $ENABLE_JSMPEG_HACK = (($mime eq 'video/mp2t') && $filelength == 99999999999);
    $filelength-- if($ENABLE_JSMPEG_HACK);    
    ($fileitem{'length'}, $headtext) = HTTP_BuildHeaders($filelength, $mime, $start, $end);    
    $fileitem{'length'}++ if($ENABLE_JSMPEG_HACK);
    say "fileitem length: " . $fileitem{'length'};
    
    $fileitem{'buf'} = $$headtext;
    push @{$client->{'queuedata'}}, \%fileitem;    
}

sub Send404 {
    my ($client) = @_;
    my $data = "HTTP/1.1 404 File Not Found\r\n";
    my $mime = getMIME('.html');
    $data .= "Content-Type: $mime\r\n";
    $data .= "\r\n";
    my %fileitem = ( buf => $data);
    push @{$client->{'queuedata'}}, \%fileitem;  
   
}

sub Send403 {
    my ($client) = @_;
    my $data = "HTTP/1.1 403 Forbidden\r\n";
    my $mime = getMIME('.html');
    $data .= "Content-Type: $mime\r\n";
    $data .= "\r\n";
    my %fileitem = ( buf => $data);
    push @{$client->{'queuedata'}}, \%fileitem;  
}

sub getMIME {
    my ($filename) = @_;
    
    my %audioexts = ( 'mp3' => 'audio/mp3', 
        'flac' => 'audio/flac',
        'opus' => 'audio',
        'ogg'  => 'audio/ogg');

    my %videoexts = ('mp4' => 'video/mp4',
        'mkv'  => 'video/mp4',
        'ts'   => 'video/mp2t',
        'webm' => 'video/webm',
        'flv'  => 'video/x-flv');

    my %otherexts = ('html' => 'text/html; charset=utf-8',
        'json' => 'text/json',
        'js'   => 'application/javascript',
        'txt' => 'text/plain',
        'pdf' => 'application/pdf',
        'jpg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'bmp' => 'image/bmp',
        'tar' => 'application/x-tar',
        'mpd' => 'application/dash+xml',
        'm3u8' => 'application/x-mpegURL',
        'm3u8_v' => 'application/x-mpegURL');

    my $defaultmime = 'text/plain';

    my ($ext) = $filename =~ /\.([^.]+)$/;

    my %combined = (%audioexts, %videoexts, %otherexts);
    return $combined{$ext} if defined($combined{$ext});
    
    print "mime time: " . `date`;
    if(open(my $filecmd, '-|', 'file', '-b', '--mime-type', $filename)) {
	my $mime = <$filecmd>;
	chomp $mime;
	print "mime time: " . `date`;
	return $mime;
    }
    

    if($ext eq 'yt') { 
        my %video = ( 'out_location' => dirname($filename), 'src_file' => { 'filepath' => $filename });
        do {
            video_get_streams(\%video);        
        } while(@{$video{'audio'}} == 0);
        if(defined $video{'video'}[0]) {            
            if($video{'video'}[0]{'fmt'} =~ /^vp/) {
                return $videoexts{'webm'};
            }
            elsif($video{'video'}[0]{'fmt'} =~ /^h264/) {
                return $videoexts{'mp4'};
            }
            elsif($video{'video'}[0]{'fmt'} =~ /^([^,]+),/) {
                return $videoexts{$1} if(defined $videoexts{$1});            
            }            
        }
        elsif(defined $video{'audio'}[0]) {           
            if($video{'audio'}[0]{'fmt'} =~ /^vorbis/) {
                return $audioexts{'ogg'};
            }
            if($video{'audio'}[0]{'fmt'} =~ /^opus/) {
                return 'audio/webm';
            }
            elsif($video{'audio'}[0]{'fmt'} =~ /^([^,]+),/) {
                return $audioexts{$1} if(defined $audioexts{$1});            
            }                        
        }
        
        die $video{'video'}[0]{'fmt'} . ' ' . $video{'audio'}[0]{'fmt'};
    }

    return $defaultmime;

}

sub escape_html {
    my ($string) = @_;
    my %dangerchars = ( '"' => '&quot;', "'" => '&#x27;', '<' => '&lt;', '>' => '&gt;', '/' => '&#x2F;');
    $string =~ s/&/&amp;/g;
    foreach my $key(keys %dangerchars) {
        my $val = $dangerchars{$key};
        $string =~ s/$key/$val/g;
    }
    return \$string;
}

sub output_dir {
    my ($path, $fmt) = @_;
    opendir(my $dir, $path) or die "Cannot open directory: $!";
    #my @files = sort(readdir $dir);
    my @files = sort { uc($a) cmp uc($b)} (readdir $dir);
    closedir($dir);
    my $vroot = $SETTINGS->{'VIDEO_ROOT'};
    my $buf =  "<ul>";    
    foreach my $file (@files) {
        if($file !~ /^..?$/) {
        my $safename = escape_html($file);
            
            if(!(-d "$path/$file")) {   
                #$buf .= "<li><a href=\"javascript:SetVideo('$path/$file');\">$file</a></li>";
                my $unsafePath = "$path/$file";
                
                $unsafePath =~ s/^$vroot\///;
                my $data_file = escape_html($unsafePath);
                $buf .= '<li><a href="video?name=' . $$data_file . '&fmt=' . $fmt . '" data-file="'. $$data_file . '">' . $$safename . '</a>    <a href="get_video?name=' . $$data_file . '&fmt=' . $fmt . '">DL</a></li>';
            }
            else {
                $buf .= '<li>';
                $buf .= '<div class="row">';
                $buf .= '<a href="#' . $$safename . '_hide" class="hide" id="' . $$safename . '_hide">' . "$$safename</a>";
                $buf .= '<a href="#' . $$safename . '_show" class="show" id="' . $$safename . '_show">' . "$$safename</a>";                
                $buf .= '<div class="list">';
                my $tmp = output_dir("$path/$file", $fmt);              
                $buf .= $$tmp;
                $buf .= '</div></div>';
                $buf .= '</li>';
            }
        }   
    }
    $buf .= "</ul>";
    return \$buf;
}

sub GetResource {
    my ($filename) = @_;
    $RESOURCES{$filename} //= read_file($filename); 
    return \$RESOURCES{$filename};
}

sub player_video {
    my ($client, $querystringStruct, $headerStruct) = @_;   
    
    my $fmt = video_get_format($querystringStruct->{'fmt'});
    my $buf =  "<html>";
    $buf .= "<head>";
    $buf .= '<style type="text/css">';
    my $temp =GetResource($SETTINGS->{'DOCUMENTROOT'} . '/static/' . 'video_style.css');
    $buf .= $$temp;
    $buf .= '</style>';
    $buf .= "</head>";
    $buf .= "<body>";   
    $buf .= '<div id="medialist">';
    $temp = output_dir($SETTINGS->{'VIDEO_ROOT'}, $fmt);
    $buf .= $$temp;
    $buf .= '</div>';
    $temp = GetResource($VIDEOFORMATS{$fmt}->{'player_html'});
    $buf .= $$temp; 
    $buf .= '<script>';
    $buf .= "var CURRENT_FORMAT = '$fmt';\n";
    $temp = GetResource($SETTINGS->{'DOCUMENTROOT'} . '/static/' . 'setVideo.js');
    $buf .= $$temp;
    
    if($querystringStruct->{'name'}) {      
        $temp = uri_escape($querystringStruct->{'name'});
        say $temp;      
        if($querystringStruct->{'fmt'} ne 'jsmpeg') {
            $buf .= '_SetVideo("get_video?name=' .  $temp . '&fmt=" + CURRENT_FORMAT);';
            $buf .= "window.location.hash = '#video';";
        
        }
        
    }
    
    $buf .= '</script>';
    $buf .= "</body>";
    $buf .= "</html>";  
    QueueBuf($client, $buf, "text/html"); 
}

sub write_file {
    my ($filename, $text) = @_;
    open (my $fh, '>', $filename) or die("$! $filename");  
    print $fh $text;
    close($fh);
}

# This is not fast
sub FindFile {
    my ($directories, $name_req, $path_req) = @_;
    my $curdir = getcwd();
    my $foundpath;
    eval {
        my $dir_matches = 1;
        my %options = ('wanted' => sub {
            return if(! $dir_matches);
            if(/$name_req/i) {
                return if( -d );
                $foundpath = $File::Find::name;
			    die;
            }
        });
        
        if(defined $path_req) {
            $options{'preprocess'} = sub {
                $dir_matches = ($File::Find::dir =~ /$path_req/i);
                return @_;            
            };        
        }
        
    
        find(\%options, @$directories);
    };
    chdir($curdir);
    return $foundpath;
}


