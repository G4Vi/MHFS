#!/usr/bin/perl

# You must provide event handlers for the events you are listening for
# return undef to have them removed from poll's structures
package EventLoop::Poll {     
    use strict; use warnings;
    use feature 'say';
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use Scalar::Util qw(looks_like_number);
    use Data::Dumper;

    our $POLLRDHUP = 0;
    our $ALWAYSMASK = ($POLLRDHUP | POLLHUP);    
    
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
        $self->{'poll'}->remove($handle);        
        $self->{'fh_map'}{$handle} = undef;          
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
            #say "loop";
            my $pollret = $poll->poll($loop_interval);
            if($pollret > 0){                             
                foreach my $handle ($poll->handles()) {
                    my $revents = $poll->events($handle);
                    my $obj = $self->{'fh_map'}{$handle};                    

                    if($revents & POLLIN) { 
                        #say "readyReady";                                                                  
                        if(! defined($obj->onReadReady)) {
                            $self->remove($handle);
                            next;
                        }                      
                    }
                    
                    if($revents & POLLOUT) {
                        #say "writeReady";                        
                        if(! defined($obj->onWriteReady)) {
                            $self->remove($handle);
                            next;
                        }                                  
                    }
                    
                    if($revents & (POLLHUP | $POLLRDHUP )) { 
                        say "hangUp";                   
                        $obj->onHangUp();
                        $self->remove($handle);                        
                    }                   

                    #if(! looks_like_number($revents ) ) {
                    #    if(! defined $obj->{'route_default'}) {           
                    #        say "client no events;
                    #    }                        
                    #}           
                }
        
            }
            elsif($pollret == 0) {
                #say "pollret == 0";
            }
            else {
                say "Poll ERROR";
                return undef;
            }  
        }
    
    
    }
    
    

    1;
}

package HTTP::BS::Server {
    use strict; use warnings;
    use feature 'say';
    use IO::Socket::INET;
    use Socket qw(IPPROTO_TCP TCP_KEEPALIVE);
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(weaken);
    use Data::Dumper;
    HTTP::BS::Server::Util->import();
    
    sub new {
        my ($class, $settings, $routes, $plugins) = @_;
        
        my $sock = IO::Socket::INET->new(Listen => 50, LocalAddr => $settings->{'HOST'}, LocalPort => $settings->{'PORT'}, Proto => 'tcp', Reuse => 1, Blocking => 0);
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
        my %self = ( 'settings' => $settings, 'routes' => $routes, 'route_default' => pop @$routes, 'plugins' => $plugins, 'sock' => $sock, 'evp' => $evp, 'uploaders' => []);
        bless \%self, $class;

        $evp->set($sock, \%self, POLLIN);
        # load the plugins        
        foreach my $plugin (@{$plugins}) {            
            foreach my $timer (@{$plugin->{'timers'}}) {                              
                $self{'evp'}->add_timer(@{$timer});                                                
            }
            if(my $func = $plugin->{'uploader'}) {
                say "adding function";
                push (@{$self{'uploaders'}}, $func);
            }
            foreach my $route (@{$plugin->{'routes'}}) {
                say "adding route";
                push @{$self{'routes'}}, $route;                
            }
             
        }            
        
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
        
        my $MAX_TIME_WITHOUT_SEND = 30; #600;
        my $cref = HTTP::BS::Server::Client->new($csock, $server);
               
        $server->{'evp'}->set($csock, $cref, POLLIN | $EventLoop::Poll::ALWAYSMASK);    

        weaken($cref); #don't allow this timer to keep the client object alive
        $server->{'evp'}->add_timer($MAX_TIME_WITHOUT_SEND, 0, sub {
            my ($timer, $current_time) = @_;
            if(! defined $cref) {                
                return undef;            
            }
            
            my $time_elapsed = $current_time - $cref->{'time'};
            if($time_elapsed > $MAX_TIME_WITHOUT_SEND) {
                say "\$MAX_TIME_WITHOUT_SEND ($MAX_TIME_WITHOUT_SEND) exceeded, closing CONN";
                say "-------------------------------------------------";               
                say "poll has " . scalar ( $server->{'evp'}{'poll'}->handles) . " handles";
                $server->{'evp'}->remove($cref->{'sock'});
                say "poll has " . scalar ( $server->{'evp'}{'poll'}->handles) . " handles";                             
                return undef;                
            }
            $timer->{'interval'} = $MAX_TIME_WITHOUT_SEND - $time_elapsed;
            return 1;            
        });
        
        return 1;    
    }

    sub getMIME {
        my ($self, $filename) = @_;
        
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
    
        
    
        my ($ext) = $filename =~ /\.([^.]+)$/;
    
        my %combined = (%audioexts, %videoexts, %otherexts);
        return $combined{$ext} if defined($combined{$ext});    
       
        if(open(my $filecmd, '-|', 'file', '-b', '--mime-type', $filename)) {
            my $mime = <$filecmd>;
            chomp $mime;        
            return $mime;
        }
        return 'text/plain';
    }
    
    1;
}

package HTTP::BS::Server::Util {
    use strict; use warnings;
    use feature 'say';
    use Exporter 'import';
    use File::Find;
    use Cwd qw(abs_path getcwd);
    our @EXPORT = ('LOCK_GET_LOCKDATA', 'LOCK_WRITE', 'UNLOCK_WRITE', 'write_file', 'read_file', 'shellcmd_unlock', 'ASYNC_ARR', 'FindFile', 'space2us', 'escape_html', 'function_exists', 'ASYNC', 'shell_stdout', 'shell_escape', 'ssh_stdout');
    sub LOCK_GET_LOCKDATA {
        my ($filename) = @_;
        my $lockname = "$filename.lock";    
        my $bytes = read_file($lockname);
        if($bytes <= 0) {
            return undef;
        }
        return $bytes;
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

    sub write_file {
        my ($filename, $text) = @_;
        open (my $fh, '>', $filename) or die("$! $filename");  
        print $fh $text;
        close($fh);
    }


    sub read_file {
        my ($filename) = @_;
        return do {
            local $/ = undef;
            if(!(open my $fh, "<", $filename)) {
                say "could not open $filename: $!";
                return -1;
            }
            else {
                <$fh>;
            }
        };
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

    sub shellcmd_unlock {
        my ($command_arr, $fullpath) = @_;
        system @$command_arr;    
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

    sub space2us {
        my ($string) = @_;
        $string =~ s/\s/_/g;
        return $string;
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
    
    sub function_exists {    
        no strict 'refs';
        my $funcname = shift;
        return \&{$funcname} if defined &{$funcname};
        return;
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

    sub ssh_stdout {
        my $source = shift;
    return shell_stdout('ssh', $source->{'userhost'}, '-p', $source->{'port'}, @_);
    }
    
    sub shell_escape {
        my ($cmd) = @_;
        ($cmd) =~ s/'/'"'"'/g;
        return $cmd;
    }
}

package HTTP::BS::Server::Client::Request {
    HTTP::BS::Server::Util->import();
    use strict; use warnings;
    use feature 'say';
    use Any::URI::Escape;
    use Cwd qw(abs_path getcwd);
    use File::Basename;
    use File::stat;
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Data::Dumper;
    use Scalar::Util qw(weaken);
    use IPC::Open3;    
    sub new {
        my ($class, $client, $indataRef) = @_;        
        my %self = ( 'client' => $client);
        bless \%self, $class;
        weaken($self{'client'}); #don't allow Request to keep client alive  

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
                     say("raw path: $path\nraw querystring: $querystring");
                     #transformations
                     $path = uri_unescape($path);
                     my $webpath = quotemeta $client->{'server'}{'settings'}{'WEBPATH'};
                     $path =~ s/^$webpath\/?/\//;
                     $path =~ s/(?:\/|\\)+$//;
                     print "path: $path ";                    
                     say "querystring: $querystring";                     
                     #parse path                     
                     my %pathStruct = ( 'unsafepath' => $path);
                     my $abspath = abs_path('.' . $path);                  
                     if (defined $abspath) {
                        print "abs: " . $abspath;
                        $pathStruct{'requestfile'} = $abspath;
                        $pathStruct{'basename'} = basename( $pathStruct{'requestfile'}); 
                     }
                     print "\n";                    
                     #parse querystring
                     my %qsStruct = ( 'querystring' => $querystring);
                     my @qsPairs = split('&', $querystring);
                     foreach my $pair (@qsPairs) {
                         my($key, $value) = split('=', $pair);
                         if(defined $value) {
                             $qsStruct{$key} = uri_unescape($value);
                         }                                      
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
                         $self{'path'} = \%pathStruct;
                         $self{'qs'} = \%qsStruct;
                         $self{'header'} = \%headerStruct;
             $self{'request'} = $$indataRef;
                         _Handle(\%self);
                         return \%self;              
                     }              
                }
                        
            }   
        }
        
        Send403(\%self);
        return \%self;      
    }

    sub _Handle {
        my ($self) = @_;
        my $routes = $self->{'client'}{'server'}{'routes'};        
        foreach my $route (@$routes) {                        
            if($self->{'path'}{'unsafepath'} eq $route->[0]) {
                $route->[1]($self);
                return;
            }
        }
        $self->{'client'}{'server'}{'route_default'}($self);        
    }

    sub _BuildHeaders {
        my ($self, $datalength, $mime, $filename) = @_;
        my $start =  $self->{'header'}{'_RangeStart'};                 
        my $end =  $self->{'header'}{'_RangeEnd'}; 
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
        $headtext .=   'Content-Disposition: inline; filename="' . $filename . "\"\r\n" if ($filename);
        $headtext .=   "Accept-Ranges: bytes\r\n";
        #$headtext .=   "Accept-Ranges: none\r\n";
        $headtext .=   "Connection: keep-alive\r\n";    
        $headtext .= "\r\n";  
        
        return ($retlength, \$headtext);
    }

    sub _SendResponse {
        my ($self, $fileitem) = @_;
        $self->{'response'} = $fileitem;
        $self->{'client'}->SetEvents(POLLOUT | $EventLoop::Poll::ALWAYSMASK );        
    }

    sub Send403 {
        my ($self) = @_;
        my $client = $self->{'client'};
        my $data = "HTTP/1.1 403 Forbidden\r\n";        
        my $mime = $client->{'server'}->getMIME('.html');
        $data .= "Content-Type: $mime\r\n";
        if($self->{'header'}{'Connection'} && ($self->{'header'}{'Connection'} eq 'close')) {
            $data .= "Connection: close\r\n";
        }
        my $msg = "403 Forbidden\r\n";
        $data .= "Content-Length: " . length($msg) . "\r\n";
        $data .= "\r\n";
        $data .= $msg;
        my %fileitem = ( buf => $data);
        $self->_SendResponse(\%fileitem);  
    }

    sub Send404 {
        my ($self) = @_;
        my $client = $self->{'client'};
        my $data = "HTTP/1.1 404 File Not Found\r\n";
        my $mime = $client->{'server'}->getMIME('.html');
        $data .= "Content-Type: $mime\r\n";
        if($self->{'header'}{'Connection'} && ($self->{'header'}{'Connection'} eq 'close')) {
            $data .= "Connection: close\r\n";
        }
        my $msg = "404 Not Found\r\n";
        $data .= "Content-Length: " . length($msg) . "\r\n";
        $data .= "\r\n";
        $data .= $msg;
        my %fileitem = ( buf => $data);
        $self->_SendResponse(\%fileitem);       
    }

    sub Send301 {
        my ($self, $url) = @_;
        my $buf = "HTTP/1.1 301 Moved Permanently\r\nLocation: $url\r\n"; 
        my $msg = "301 Moved Permanently\r\n<a href=\"$url\"></a>\r\n";
        $buf .= "Content-Length: " . length($msg) . "\r\n";
        $buf .= "\r\n";
        $buf .= $msg;
        my %fileitem = ('buf' => $buf);
        $self->_SendResponse(\%fileitem);
    }

    sub Send307 {
        my ($self, $url) = @_;
        my $buf = "HTTP/1.1 307 Temporary Redirect\r\nLocation: $url\r\n"; 
        my $msg = "307 Temporary Redirect\r\n<a href=\"$url\"></a>\r\n";
        $buf .= "Content-Length: " . length($msg) . "\r\n";
        $buf .= "\r\n";
        $buf .= $msg;
        my %fileitem = ('buf' => $buf);
        $self->_SendResponse(\%fileitem);
    }    

    sub SendLocalFile {
        my ($self, $requestfile) = @_;
        my $start =  $self->{'header'}{'_RangeStart'};                 
        my $end =  $self->{'header'}{'_RangeEnd'}; 
        my $client = $self->{'client'};
        if(!( -e $requestfile)) {
            $self->Send404;           
            return;
        }   
        
        my %fileitem;
        my $filelength = LOCK_GET_LOCKDATA($requestfile);    
        if(! open(my $FH, "<", $requestfile)) {
            $self->Send404;
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
        my $mime = $client->{'server'}->getMIME($requestfile);
        
         
        ($fileitem{'length'}, $headtext) = $self->_BuildHeaders($filelength, $mime, basename($requestfile));        
        say "fileitem length: " . $fileitem{'length'};
        
        $fileitem{'buf'} = $$headtext;
        $self->_SendResponse(\%fileitem);        
    }

    sub SendPipe {
        my ($self, $FH, $filename, $filelength, $mime) = @_;
        $mime //= $self->{'client'}{'server'}->getMIME($filename);
        my $start = $self->{'header'}{'_RangeStart'};
        my $end = $self->{'header'}{'_RangeEnd'};
        binmode($FH);
    #seek($FH, 0, 0); #you can't really seek on a pipe, we must create the pipe at the right point
        my %fileitem;
        $fileitem{'fh'} = $FH;  
        my $headtext;
        ($fileitem{'length'}, $headtext) = $self->_BuildHeaders($filelength, $mime, $filename);
        $fileitem{'buf'} = $$headtext;
        $self->_SendResponse(\%fileitem);
    }

    sub SendFromSSH {
        my ($self, $sshsource, $filename, $node) = @_; 
        my @sshcmd = ('ssh', $sshsource->{'userhost'}, '-p', $sshsource->{'port'}); 
        my $fullescapedname = "'" . shell_escape($filename) . "'";   
        my $folder = $sshsource->{'folder'};   
        my $size = $node->[1];
        my @cmd;
        if(defined $self->{'header'}{'_RangeStart'}) {
            my $start = $self->{'header'}{'_RangeStart'};
            my $end = $self->{'header'}{'_RangeEnd'};
            my $bytestoskip =  $start;
            my $count;
            if($end) {
                $count = $end - $start + 1;
            }
            else {
                $count = $size - $start;
            }
            @cmd = (@sshcmd, 'dd', 'skip='.$bytestoskip, 'count='.$count, 'bs=1', 'if='.$fullescapedname);
        }
        else{
            @cmd = (@sshcmd, 'cat', $fullescapedname);
        }
        open(my $cmdh, '-|', @cmd) or die("SendFromSSH $!");
        
        $self->SendPipe($cmdh, basename($filename), $size);            
        return 1;       
    }

    sub Proxy {
    my ($self, $proxy, $node) = @_;
        my $requesttext = $self->{'request'};
        my $webpath = quotemeta $self->{'client'}{'server'}{'settings'}{'WEBPATH'};
        my @lines = split('\r\n', $requesttext);
        my @outlines = (shift @lines);
        $outlines[0] =~ s/^(GET|HEAD)\s+$webpath\/?/$1 \//;
        #$outlines[0] =~ s/music_dl(\?name=[^\s]+)/get_video$1&fmt=noconv/; 
        push @outlines, (shift @lines);
        my $host = $proxy->{'httphost'};
        $outlines[1] =~ s/^(Host\:\s+[^\s]+)/Host\: $host/;
        foreach my $line (@lines) {
            next if($line =~ /^X\-Real\-IP/);
            push @outlines, $line;
        }
        push @outlines, 'Connection: close';
        my $newrequest = '';
        foreach my $outline(@outlines) {
            $newrequest .= $outline . "\r\n";
        }
        say "Making request via proxy:";
        print $newrequest;
        $newrequest .= "\r\n";  
        my ($in, $out, $err);
        use Symbol 'gensym'; $err = gensym;
        my $pid = open3($in, $out, $err, ('nc', $host, $proxy->{'httpport'})) or die "BAD NC";
        print $in $newrequest;
        my $size = $node->[1] if $node;
        my %fileitem = ('fh' => $out, 'length' => $size // 99999999999);
        $self->_SendResponse(\%fileitem);
        return 1;
    }

    sub SendLocalBuf {
        my ($self, $buf, $mime) = @_;        
        my $bytesize;
        {
            use bytes;
            $bytesize = length($buf);
        }
        my $headtext;   
        my %fileitem;        
        ($fileitem{'length'}, $headtext) = $self->_BuildHeaders($bytesize, $mime);    
        $fileitem{'buf'} = $$headtext . $buf;
        $self->_SendResponse(\%fileitem);
    }

    # TODO, check plugins for SendOption
    sub SendFile {
        my ($self, $requestfile) = @_;
        foreach my $uploader (@{$self->{'client'}{'server'}{'uploaders'}}) {
            return if($uploader->($self, $requestfile));
        }
        return $self->SendLocalFile($requestfile);
    }



    1;
}

package HTTP::BS::Server::Client {
    use strict; use warnings;
    use feature 'say';
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use IO::Socket::INET;
    use Errno qw(EINTR EIO :POSIX);
    use Fcntl qw(:seek :mode);
    use File::stat;
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(looks_like_number weaken);
    use Data::Dumper;
    use Carp;
    $SIG{ __DIE__ } = sub { Carp::confess( @_ ) };

    #use HTTP::BS::Server::Request;
    sub new {
        my ($class, $sock, $server) = @_;
        $sock->blocking(0);
        my %self = ('sock' => $sock, 'server' => $server, 'time' => clock_gettime(CLOCK_MONOTONIC), 'inbuf' => '');        
        return bless \%self, $class;
    }

    sub SetEvents {
        my ($self, $events) = @_;
        $self->{'server'}{'evp'}->set($self->{'sock'}, $self, $events);        
            
    }

    # currently only creates HTTP Request objects, but this could change if we allow file uploads
    sub onReadReady {        
        my ($client) = @_;
        my $handle = $client->{'sock'};               
        my $maxlength = 8192;
        my $tempdata;
        my $success = defined($handle->recv($tempdata, $maxlength-length($client->{'inbuf'})));
        if($success) {
            if(length($tempdata) == 0) {
                # read 0 bytes, so put this client to rest for a little while                
                $client->SetEvents($EventLoop::Poll::ALWAYSMASK );
                weaken($client);                
                $client->{'server'}{'evp'}->add_timer(0.1, 0, sub {
                    if(defined $client) {
                        $client->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK );
                    }
                    return undef;
                });
                return '';
            }
            $client->{'inbuf'} .= $tempdata;
        }
        else {
            print ("RECV errno $!\n");
            if(! $!{EAGAIN}) {                
                goto ON_ERROR;
            }
            say "EAGAIN";
        }
        my $pos = index($client->{'inbuf'}, "\r\n\r\n");
        if($pos != -1) {
            $client->SetEvents($EventLoop::Poll::ALWAYSMASK );  
            my $recvdata = substr $client->{'inbuf'}, 0, $pos+4;
            $client->{'inbuf'} = substr $client->{'inbuf'}, $pos+4;
            say "inbuf: " . $client->{'inbuf'} . ' ' . length($client->{'inbuf'});
            $client->{'request'} = HTTP::BS::Server::Client::Request->new($client, \$recvdata);            
            return $client->onWriteReady;            
        }
        elsif(length($client->{'inbuf'}) >= $maxlength) {
            say "End of header not found in $maxlength !!!";                
        }
        else {
            return '';
        }        
        
        ON_ERROR:
        say "ON_ERROR-------------------------------------------------";               
        return undef;       
    }
    
    sub onWriteReady {
        my ($client) = @_;

        # send the response
        if(defined $client->{'request'}{'response'}) {
            my $tsrRet = $client->TrySendResponse;
            if(!defined($tsrRet)) {
                say "-------------------------------------------------";                               
                return undef;
            }            
            elsif($tsrRet ne '') {
                if($client->{'request'}{'header'}{'Connection'} && ($client->{'request'}{'header'}{'Connection'} eq 'close')) {
                    say "Connection close header set closing conn";
                    say "-------------------------------------------------";                               
                    return undef;              
                }
                $client->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK );
                $client->onReadReady;
            }            
        }
        else {             
            say "response not defined, probably going to be set by a timer";                     
        }        
        return 1;        
    }    

    sub TrySendResponse {
        my ($client) = @_;
        my $csock = $client->{'sock'};        
        my $dataitem = $client->{'request'}{'response'};    
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
                use bytes;
                #my $n = length($buf);
                my $remdata = TrySendItem($csock, $buf, $bytesToSend);        
                # critical conn error
                if(! defined($remdata)) {
                    say "-------------------------------------------------";
                    return undef;
                }
                # only update the time if we actually sent some data
                if($remdata ne $buf) {
                    $client->{'time'} = clock_gettime(CLOCK_MONOTONIC);
                }
                # eagain or not all data sent
                if($remdata ne '') {
                    $dataitem->{'buf'} = $remdata;                                        
                    return '';
                }
                #we sent the full buf                
                $buf = undef;                
            }
            
            #try to grab a buf from the file         
            if(defined $dataitem->{'fh'}) {            
                my $FH = $dataitem->{'fh'};                
                my $req_length = $dataitem->{'length'}; # if the file is still locked/we haven't checked for it yet it will be 99999999999                
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
        $client->{'request'}{'response'} = undef;
        
    
        say "DONE Sending Data";    
        #return undef; # commented 10-02-18 for keep-alive
        return 'RequestDone';
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
    
    sub onHangUp {
        my ($client) = @_;
        say "Client Hangup\n";
        return undef;    
    }

    sub DESTROY {
        my $self = shift;
        say "client destructor called";
        if($self->{'sock'}) {
            shutdown($self->{'sock'}, 2);
            close($self->{'sock'});  
        }
    }   
    
    1;  
}



package GDRIVE {
    use strict; use warnings;
    use feature 'say';
    use Cwd qw(abs_path getcwd);
    use File::Find;
    use Data::Dumper;
    use File::stat;
    use File::Basename;
    use Scalar::Util qw(looks_like_number);
    HTTP::BS::Server::Util->import();
    
    sub gdrive_add_tmp_rec {
        my ($id, $gdrivefile, $settings) = @_;
        write_file($settings->{'GDRIVE_TMP_REC_DIR'} . "/$id", $gdrivefile);
    }
    
    sub gdrive_remove_tmp_rec {
        my($self) = @_;
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
                
            }}, $self->{'settings'}{'GDRIVE_TMP_REC_DIR'}); 
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
                exec $self->{'settings'}{'BINDIR'}.'/upload.sh',  '--delete', basename($file), '--config', $self->{'settings'}{'CFGDIR'} . '/.googledrive.conf';        
            });               
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
    
    sub _gdrive_upload {
        my ($filename, $settings) = @_;               
        my $cmdout = shell_stdout('perl', $settings->{'BINDIR'} . '/gdrivemanager.pl', $filename, $settings->{'CFGDIR'} . '/gdrivemanager.json');
        say $cmdout; 
        my ($id, $newurl) = split("\n", $cmdout);   
        my $url;    
        my $fname = $filename . '_gdrive';
        gdrive_add_tmp_rec($id, $fname, $settings);
        my $fname_tmp = $fname . '.tmp';
        write_file($fname_tmp, $newurl);
        rename($fname_tmp, $fname);
    }
    
    sub gdrive_upload {
        my ($file, $settings) = @_;
        #BADHACK, gdrive things not in the temp dir
        #my $tmpdir = $SETTINGS->{'TMPDIR'};
        #if($file =~ /^$tmpdir/)    
        {
            my $fnametmp = $file . '_gdrive.tmp';
            say "fnamtmp $fnametmp";
            open(my $tmpfile, ">>", $fnametmp) or die;
            close($tmpfile);
        }
        ASYNC_ARR(\&_gdrive_upload, $file, $settings);
    }
    
    
    sub uploader {
        my($request, $requestfile) = @_;
        my $handled;
        
        # only send it by gdrive, if it was uploaded in time
        my $gdrivefile = should_gdrive($requestfile);       
        if(defined($gdrivefile) && looks_like_number($gdrivefile) && ($gdrivefile == 0)) {
            $handled = 1;
            my $url = read_file($requestfile . '_gdrive');
            $request->Send307($url);
        }       
        
        # queue up future hls files
        my @togdrive;
        if( $requestfile =~ /^(.+[^\d])(\d+)\.ts$/) {
            my ($start, $num) = ($1, $2);
            # no more than 3 uploads should be occurring at a time
            for(my $i = 0; ($i < 2) && (scalar(@togdrive) < 1); $i++) {                     
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
            gdrive_upload($file, $request->{'client'}{'server'}{'settings'});                                
        }        
        
        return $handled;    
    }
    
    
    sub new {
        my ($class, $settings) = @_;
        my $self =  {'settings' => $settings};
        bless $self, $class;           
        $self->{'timers'} = [
            [0, 0, sub {
                #say "running timer";            
                $self->gdrive_remove_tmp_rec;                                     
                return 1;        
            }],
        ];
        $self->{'uploader'} = \&uploader;
        return $self;
    }

    
    1;
}


package MusicLibrary {
    use strict; use warnings;
    use feature 'say';
    use Cwd qw(abs_path getcwd);
    use File::Find;
    use Data::Dumper;
    use File::stat;
    use File::Basename;
    use Scalar::Util qw(looks_like_number);
    use HTML::Entities;
    HTTP::BS::Server::Util->import();
    use Encode qw(decode encode);
    use IPC::Open3;
    use Storable;
    use Fcntl ':mode';  

    sub BuildLibrary {
    my ($path) = @_;        
        my $statinfo = stat($path);
        return undef if(! $statinfo);       
        if(!S_ISDIR($statinfo->mode)){
        return undef if($path !~ /\.(flac|mp3|m4a|wav|ogg|webm)$/); 
            return [basename($path), $statinfo->size];          
        } 
        else {
            my $dir;
            if(! opendir($dir, $path)) {
                warn "outputdir: Cannot open directory: $path $!";
                return undef;
            }        
            my @files = sort { uc($a) cmp uc($b)} (readdir $dir);
            closedir($dir);
            my @tree;
            my $size = 0;
            foreach my $file (@files) {
                next if(($file eq '.') || ($file eq '..'));
                if(my $file = BuildLibrary("$path/$file")) {
                        push @tree, $file;
                        $size += $file->[1];
                }                   
            }
            return undef if( $size eq 0);
            return [basename($path), $size, \@tree];
       } 
        
}

    sub GetPrompt {
        my ($out, $dir) = @_;
        #$dir = quotemeta $dir;
        my ($temp, $buf);
        while(read $out, $temp, 1) {
            $buf .= $temp;
            return $buf if($buf =~ /$dir\$$/);
        }
        return undef;
    }

    sub BuildRemoteLibrary {
        my ($self, $source) = @_;
        return undef if($source->{'type'} ne 'ssh');
        my $bin = $self->{'settings'}{'BIN'};
        my $aslibrary = $self->{'settings'}{'BINDIR'} . '/aslibrary.pl';
        my $userhost = $source->{'userhost'};
        my $port = $source->{'port'};
        my $folder = $source->{'folder'};
        
        #system ('ssh', $userhost, '-p', $port, 'mkdir', '-p', 'MHFS');
        #system ('rsync', '-az', '-e', "ssh -p $port", $bin, "$userhost:MHFS/" . basename($bin));
        system ('rsync', '-az', '-e', "ssh -p $port", $aslibrary, "$userhost:MHFS/" . basename($aslibrary));
                
        
        my $buf = shell_stdout('ssh', $userhost, '-p', $port, 'MHFS/aslibrary.pl', 'MHFS/server.pl', $folder);
        if(! $buf) {
            say "failed to read";
            return undef;
        }
        write_file('music.db', $buf);
        my $lib = retrieve('music.db');
        return $lib;
    }
    
    sub ToHTML {
        my ($files) = @_;
        my $buf = '';
        my $name = encode_entities(decode('UTF-8', $files->[0]));
        if($files->[2]) {
            my $dir = $files->[0]; 
            $buf .= '<tr>';            
            $buf .= '<td>';
            $buf .= '<table border="1" class="tbl_track">';
            $buf .= '<tbody>';
            $buf .= '<tr>';
            $buf .= '<th>' . $name . '</th>';            
            $buf .= '<th>Play</th><th>Queue</th>';
            $buf .= '</tr>';
            foreach my $file (@{$files->[2]}) {
                $buf .= ToHTML($file) ;      
            }            
            $buf .= '</tbody></table>';  
            $buf .= '</td>';
                        
        }
        else {
            $buf .= '<tr class="track">';        
            $buf .= '<td>' . $name . '</td>';
            $buf .= '<td><a href="#">Play</a></td><td><a href="#">Queue</a></td>';                    
        }
        $buf .= '</tr>';     
        return $buf;   
    }
    
    sub LibraryHTML {
        my ($self) = @_;
        my $buf = read_file($self->{'settings'}{'DOCUMENTROOT'} . '/static/music_top.html');
        foreach my $file (@{$self->{'library'}}) {
            $buf .= ToHTML($file);
            $buf .= '<br>';
        }
        $buf .=   read_file($self->{'settings'}{'DOCUMENTROOT'} . '/static/music_bottom.html');      
        $self->{'html'} = $buf;  
    }

    sub SendLibrary {
        my ($self, $request) = @_;
        return $request->SendLocalBuf($self->{'html'}, "text/html; charset=utf-8");
    }

    sub BuildLibraries {
    my ($self, $sources) = @_;
    my @wholeLibrary;
    $self->{'sources'} = [];
    foreach my $source (@{$sources}) {
        my $lib;
        my $folder = quotemeta $source->{'folder'};
        if($source->{'type'} eq 'local') {
            $lib = BuildLibrary($source->{'folder'});
            $source->{'SendFile'} //= sub   {
                my ($request, $file) = @_;
                return undef if(! -e $file);
                return undef if(-d $file); #we can't handle directories right now
                $request->SendLocalFile($file);
                return 1;
            };      
        }
        elsif($source->{'type'} eq 'ssh') {
            $lib = $self->BuildRemoteLibrary($source);
            $source->{'SendFile'} //= sub {
                my ($request, $file, $node) = @_;               
                return $request->SendFromSSH($source, $file, $node);
            };
        }
        elsif($source->{'type'} eq 'mhfs') {
            $source->{'type'} = 'ssh';
            $lib = $self->BuildRemoteLibrary($source);
            if(!$source->{'httphost'}) {
                $source->{'httphost'} =  ssh_stdout($source, 'curl', 'ipinfo.io/ip');
                chop $source->{'httphost'};
                $source->{'httpport'} //= 8000;
            }
            say "MHFS host at " . $source->{'httphost'} . ':' . $source->{'httpport'};
            $source->{'SendFile'} //= sub {
            my ($request, $file, $node) = @_;
                return $request->Proxy($source, $node);
            };
        }
        if($lib) {
        push @{$self->{'sources'}}, $source;
                $source->{'lib'} = $lib;
        OUTER: foreach my $item (@{$lib->[2]}) {
            foreach my $already (@wholeLibrary) {
                next OUTER if($already->[0] eq $item->[0]);
            }
            push @wholeLibrary, $item;
        }
        }
        else {
        $source->{'lib'} = undef;
        }
    }
    $self->{'library'} = \@wholeLibrary;
    $self->LibraryHTML;
    return \@wholeLibrary;
    }

    sub FindInLibrary {
        my ($lib, $name) = @_;
        my @namearr = split('/', $name);
        FindInLibrary_Outer: foreach my $component (@namearr) {
            foreach my $libcomponent (@{$lib->[2]}) {
                if($libcomponent->[0] eq $component) {
                    $lib = $libcomponent;
                    next FindInLibrary_Outer;
                }
            }
            return undef;
        }
        return $lib;
    }

    sub SendFromLibrary {
        my ($self, $request) = @_;
        foreach my $source (@{$self->{'sources'}}) {
            my $node = FindInLibrary($source->{'lib'}, $request->{'qs'}{'name'});
            next if ! $node;

            my $tfile = $source->{'folder'} . '/' . $request->{'qs'}{'name'};
            if($source->{'SendFile'}->($request, $tfile, $node)) {
                return 1;
            } 
        }
        say "SendFromLibrary: did not find in library, 404ing";
        $request->Send404;
    }
    
    sub new {
        my ($class, $settings) = @_;
        my $self =  {'settings' => $settings};
        bless $self, $class;  

    say "building music library";
        $self->BuildLibraries($settings->{'MUSICLIBRARY'}{'sources'});
        say "done build libraries";
        $self->{'routes'} = [
            [ '/music', sub {
                my ($request) = @_;
                return $self->SendLibrary($request);        
            }],
            [ '/music_force', sub {
        my ($request) = @_;
            $self->BuildLibraries($settings->{'MUSICLIBRARY'}{'sources'}); 
            return $self->SendLibrary($request);
        }],
            [ '/music_dl', sub {
        my ($request) = @_;
        return $self->SendFromLibrary($request);
        }], 
        ];
        
        return $self;
    }

    1;
}


package App::MHFS; #Media Http File Server
unless (caller) {
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
use File::Copy;
use Encode qw(decode encode find_encoding);
use Any::URI::Escape;
use Scalar::Util qw(looks_like_number weaken);
HTTP::BS::Server::Util->import();

$SIG{PIPE} = sub {
    print STDERR "SIGPIPE @_\n";
};

# main
my $SCRIPTDIR = dirname(abs_path(__FILE__));
my $CFGDIR = $SCRIPTDIR . '/.conf';
my $SETTINGS_FILE = $CFGDIR . '/settings.pl';
my $SETTINGS = do ($SETTINGS_FILE);
$SETTINGS or die "Failed to read settings: $@";
if( ! $SETTINGS->{'DOCUMENTROOT'}) {
    die "Must specify DOCUMENTROOT if specifying DROOT_IGNORE" if $SETTINGS->{'DROOT_IGNORE'};
    $SETTINGS->{'DOCUMENTROOT'} = $SCRIPTDIR;
}
if(! $SETTINGS->{'DROOT_IGNORE'}) {
    my $droot = $SETTINGS->{'DOCUMENTROOT'};
    my $BINNAME = quotemeta $0;
    $SETTINGS->{'DROOT_IGNORE'} = qr/^$droot\/(?:(?:\..*)|(?:$BINNAME))/;
}
$SETTINGS->{'BIN'} = abs_path(__FILE__);
$SETTINGS->{'XSEND'} //= 0;
$SETTINGS->{'WEBPATH'} ||= '/';
$SETTINGS->{'DOMAIN'} ||= "127.0.0.1";
$SETTINGS->{'HOST'} ||= "127.0.0.1";
$SETTINGS->{'PORT'} ||= 8000;     
$SETTINGS->{'TMPDIR'} ||= $SETTINGS->{'DOCUMENTROOT'} . '/tmp';
$SETTINGS->{'VIDEO_TMPDIR'} ||= $SETTINGS->{'TMPDIR'};
$SETTINGS->{'VIDEO_ROOT'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/video", 
$SETTINGS->{'MUSIC_ROOT'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/music",
$SETTINGS->{'BINDIR'} ||= $SCRIPTDIR . '/.bin';
$SETTINGS->{'TOOLDIR'} ||= $SCRIPTDIR . '/.tool';
$SETTINGS->{'DOCDIR'} ||= $SCRIPTDIR . '/.doc';
$SETTINGS->{'CFGDIR'} ||= $CFGDIR;

my @plugins;
if(defined $SETTINGS->{'GDRIVE'}) {
    $SETTINGS->{'GDRIVE_TMP_REC_DIR'} ||= $SETTINGS->{'TMPDIR'} . '/gdrive_tmp_rec';    
    push @plugins, GDRIVE->new($SETTINGS); 
    say "GDRIVE plugin Enabled";
}
push @plugins, MusicLibrary->new($SETTINGS);
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
            '$VIDEOFORMATS{"yt"}{"youtube-dl_fmts"}{$qs->{"media"} // "video"} // "best"', '-o', '$video{"out_filepath"}', '$qs->{"id"}'], 'ext' => 'yt', 
            'youtube-dl_fmts' => {'music' => 'bestaudio', 'video' => 'best'}, 'minsize' => '1048576'}
);

my %RESOURCES;
my @routes = (
    [
        '', sub {
            my ($request) = @_;
            my $droot = $SETTINGS->{'DOCUMENTROOT'};
            say $droot . "/static/stream.html";
            my $startpos =  $request->{'header'}{'_RangeStart'};                 
            my $endpos =  $request->{'header'}{'_RangeEnd'}; 
            $request->SendLocalFile("$droot/static/stream.html");
        }
    ],
    [
        '/get_video', \&get_video
    ],
    [
        '/video', \&player_video
    ],
    [
        '/play_audio', sub {
            my ($request) = @_;
            my $buf = '<audio controls autoplay src="get_video?' . $request->{'qs'}{'querystring'} . '">Terrible</audio>';            
            $request->SendLocalBuf($buf, 'text/html');
        }
    ],
    [
        '/play_video', sub {
            my ($request) = @_;
            my $buf = '<video controls autoplay src="get_video?' . $request->{'qs'}{'querystring'} . '">Terrible</video>';            
            $request->SendLocalBuf($buf, 'text/html');
        }
    ],
    # otherwise attempt to send a file from droot
    sub {
        my ($request) = @_;
        my $droot = $SETTINGS->{'DOCUMENTROOT'};
        my $requestfile = $request->{'path'}{'requestfile'};       
        if(( ! defined $requestfile) ||
           ($requestfile !~ /^$droot/) ||
           (! -f $requestfile)){
            $request->Send404;            
        }
        elsif($requestfile =~ $SETTINGS->{'DROOT_IGNORE'}) {
            say $requestfile . ' is forbidden';
            $request->Send404;
        }
        else {
            $request->SendFile($requestfile);
        }       
    }
);



        
my $server = HTTP::BS::Server->new($SETTINGS, \@routes, \@plugins);

sub get_video {
    my ($request) = @_;
    my ($client, $qs, $header) =  ($request->{'client'}, $request->{'qs'}, $request->{'header'});
    my $droot = $SETTINGS->{'DOCUMENTROOT'};
    my $vroot = $SETTINGS->{'VIDEO_ROOT'};
    say "/get_video ---------------------------------------";
    my %video = ('out_fmt' => video_get_format($qs->{'fmt'}));
    if(defined($qs->{'name'})) {        
        my $src_file;
        if($src_file = video_file_lookup($qs->{'name'})) {
            $video{'src_file'} = $src_file;
            $video{'out_base'} = $src_file->{'name'};
        }
        elsif($src_file = media_file_search($qs->{'name'})) {
            say "useragent: " . $header->{'User-Agent'};
            if($header->{'User-Agent'} !~ /^VLC\/2\.\d+\.\d+\s/) {                
                my $url = 'get_video?' . $qs->{'querystring'};
                my $qname = uri_escape($src_file->{'qname'});
                $url =~ s/name=[^&]+/name=$qname/;
                say "url: $url";
                $request->Send301($url);                
                return 1;
            }
            $video{'src_file'} = $src_file;
            $video{'out_base'} = $src_file->{'name'};
        }
        else {
            $request->Send404;
            return undef;
        }        
    }
    elsif(defined($qs->{'id'})) {    
        my $media;
        if(defined $qs->{'media'} && (defined $VIDEOFORMATS{$video{'out_fmt'}}{'youtube-dl_fmts'}{$qs->{'media'}})) {
            $media = $qs->{'media'};
        }
        else  {
            $media = 'video';
        }        
        $video{'out_base'} = $qs->{'id'} . '_' . $media;
    }
    else {
        $request->Send404;
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
        my $tdir = $SETTINGS->{'TMPDIR'};
        my $tmpfile = $video{'out_filepath'};
        if($video{'out_filepath'} !~ /$tdir/) {
            $tmpfile = $SETTINGS->{'TMPDIR'} . '/'  . basename($video{'out_filepath'});
            if(!symlink($video{'out_filepath'}, $tmpfile)) {
                say "failed to create symlink";
            }            
            if(! -e $tmpfile) {
                # otherwise we can copy
                # TODO remove this or make it not block
                if(!copy($video{'out_filepath'}, $SETTINGS->{'TMPDIR'})) {
                    say "File copy failed for " . $video{'out_filepath'} . " $!";
                    $request->Send404;
                    return undef;
                }
            }         
        }
                 
        $request->SendFile($tmpfile);                
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
            video_get_streams(\%video);
            if($fmt eq 'hls') {                    
                $video{'on_exists'} = \&video_hls_write_master_playlist;                                         
            }
            elsif($fmt eq 'dash') {
                $video{'on_exists'} = \&video_dash_check_ready;
            }            
            ASYNC_ARR(\&shellcmd_unlock, \@cmd, $video{'out_filepath'});            
        }           
        else {
            $request->Send404;
            return undef;
        }        
        
        # our file isn't ready yet, so create a timer to check the progress and act
        weaken($request); # the only one who should be keeping $request alive is $client                    
        $request->{'client'}{'server'}{'evp'}->add_timer(0, 0, sub {
            if(! defined $request) {
                say "\$request undef, ignoring CB";
                return undef;
            }            
            my $filename = $video{'out_filepath'};
            if(! -e $filename) {
                return 1;
            }
            my $minsize = $VIDEOFORMATS{$fmt}->{'minsize'};
            if(defined($minsize) && ((-s $filename) < $minsize)) {                      
                return 1;
            }
            if(defined $video{'on_exists'}) {
                (return 1) if (! $video{'on_exists'}->(\%video));              
            }
            say "get_video_timer is destructing";
            $request->SendLocalFile($filename);
            return undef;          
        });
        say "get_video: added timer " . $video{'out_filepath'};                  
    }
    return 1;    
}

sub video_get_format {
    my ($fmt) = @_; 
    if(!defined($fmt) || !defined($VIDEOFORMATS{$fmt})) {
        $fmt = 'hls';
    }
    return $fmt;
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

sub video_hls_write_master_playlist {
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
            $default = 'YES' if($sub->{'is_default'});
            $forced = 'YES' if($sub->{'is_forced'});     
        }
        # assume its in english
        $newm3ucontent .= '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT='.$default.',FORCED='.$forced.',URI="' . $subm3u . '",LANGUAGE="en"' . "\n";                         
    }
    write_file($requestfile, $newm3ucontent);
    return 1;
}

sub video_dash_check_ready {
    my ($video) = @_;
    my $mpdcontent = read_file($video->{'out_filepath'});

    foreach my $line (split("\n", $mpdcontent)) {
        return 1 if($line =~ /<S.+d=.+\/>/);
    }
    return undef;
}

sub media_filepath_to_src_file {
    my ($filepath) = @_;
    my ($name, $loc, $ext) = fileparse($filepath, '\.[^\.]*');
    $ext =~ s/^\.//;
    return { 'filepath' => $filepath, 'name' => $name, 'location' => $loc, 'ext' => $ext};
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

sub GetResource {
    my ($filename) = @_;
    $RESOURCES{$filename} //= read_file($filename); 
    return \$RESOURCES{$filename};
}

sub player_video {
    my ($request) = @_;
    my $qs = $request->{'qs'};   
    my $fmt = video_get_format($qs->{'fmt'});
    my $buf =  "<html>";
    $buf .= "<head>";
    $buf .= '<style type="text/css">';
    my $temp = GetResource($SETTINGS->{'DOCUMENTROOT'} . '/static/' . 'video_style.css');
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
    
    if($qs->{'name'}) {      
        $temp = uri_escape($qs->{'name'});
        say $temp;      
        if($qs->{'fmt'} ne 'jsmpeg') {
            $buf .= '_SetVideo("get_video?name=' .  $temp . '&fmt=" + CURRENT_FORMAT);';
            $buf .= "window.location.hash = '#video';";        
        }        
    }
    
    $buf .= '</script>';
    $buf .= "</body>";
    $buf .= "</html>";  
    $request->SendLocalBuf($buf, "text/html"); 
}

sub output_dir {
    my ($path, $fmt) = @_;
    my $dir;
    if(! opendir($dir, $path)) {
        warn "outputdir: Cannot open directory: $path $!";
        return \"";
    }
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



}
1;

