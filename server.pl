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
                            say "poll has " . scalar ( $self->{'poll'}->handles) . " handles";  
                            next;
                        }                      
                    }
                    
                    if($revents & POLLOUT) {
                        #say "writeReady";                        
                        if(! defined($obj->onWriteReady)) {
                            $self->remove($handle);
                             say "poll has " . scalar ( $self->{'poll'}->handles) . " handles";  
                            next;
                        }                                  
                    }
                    
                    if($revents & (POLLHUP | $POLLRDHUP )) { 
                        say "Hangup $handle";                   
                        $obj->onHangUp();
                        $self->remove($handle);
                        say "poll has " . scalar ( $self->{'poll'}->handles) . " handles";                        
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
                #return undef;
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
        #try to create a client 
        my $csock = $server->{'sock'}->accept();
        if(! $csock) {
            say "server: cannot accept client";
            return 1;        
        }
        my $peerhost = $csock->peerhost();
        if(! $peerhost) {
            say "server: no peerhost";
            return 1;        
        }
        my $peerport = $csock->peerport();
        if(! $peerport) {
            say "server: no peerport";
            return 1;
        }        
        
        say "-------------------------------------------------";
        say "NEW CONN " . $peerhost . ':' . $peerport;        
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
            'm3u8_v' => 'application/x-mpegURL',
            'wasm'  => 'application/wasm');
    
        
    
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
    our @EXPORT = ('LOCK_GET_LOCKDATA', 'LOCK_WRITE', 'UNLOCK_WRITE', 'write_file', 'read_file', 'shellcmd_unlock', 'ASYNC', 'FindFile', 'space2us', 'escape_html', 'function_exists', 'shell_stdout', 'shell_escape', 'ssh_stdout', 'pid_running');
    sub LOCK_GET_LOCKDATA {
        my ($filename) = @_;
        my $lockname = "$filename.lock";    
        my $bytes = read_file($lockname);
        if(! defined $bytes) {
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
                #say "could not open $filename: $!";
                return undef;
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

    sub ASYNC {
        my $func = shift;        
        my $pid = fork();
        if($pid == 0) {
            $func->(@_);
            exit 0;
        }
        else {
            say "PID $pid ASYNC";
            return $pid;
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
        my $pid = open(my $cmdh, '-|', @_);
        $pid or die("shell_stdout $!");
        say "PID $pid shell_stdout";        
        <$cmdh>;
        }
    }

    sub ssh_stdout {
        my $source = shift;
        return shell_stdout('ssh', $source->{'userhost'}, '-p', $source->{'port'}, @_);
    }
    
    sub pid_running {
        return kill 0, shift;    
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
    use Symbol 'gensym';    
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
        if($datalength ne '*') {
            $headtext .= "Accept-Ranges: bytes\r\n";
        }
        #$headtext .=   "Accept-Ranges: none\r\n";
        $headtext .=   "Connection: keep-alive\r\n";

        # serialize the outgoing headers
        foreach my $header (keys %{$self->{'outheaders'}}) {
            $headtext .= "$header: " . $self->{'outheaders'}{$header} . "\r\n";
        }       
        
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
        $newrequest .= "\r\n";        
        $self->{'process'} = HTTP::BS::Server::Process->new(['nc', $host, $proxy->{'httpport'}], $self->{'client'}{'server'}{'evp'}, 
        {'STDIN' => sub {
            my ($in) = @_;
            say "proxy sending request";
            print $in $newrequest; #this could block, but probably wont                 
            return 0;
        },
        'STDOUT' => sub {
            my($out) = @_;
            say "proxy sending response";
            my %fileitem = ('fh' => $out);
            $self->_SendResponse(\%fileitem); 
            return 0;
        }
        });       
             
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
    
    sub StartSendingBuf {
        my ($self, $buf, $mime) = @_;
        my $headtext;   
        my %fileitem;        
        ($fileitem{'length'}, $headtext) = $self->_BuildHeaders(99999999999, $mime);    
        $fileitem{'buf'} = $$headtext . $buf;
        $self->_SendResponse(\%fileitem);   
    }
    
    sub SendAsTar {
        my ($self, $requestfile) = @_;
        my $tarsize = $self->{'client'}{'server'}{'settings'}{'BINDIR'} . '/tarsize/tarsize.sh';
        say "tarsize $requestfile";
        my @taropt = ('-C', dirname($requestfile), basename($requestfile), '-c', '--owner=0', '--group=0');
        $self->{'process'} =  HTTP::BS::Server::Process->new([$tarsize, @taropt], $self->{'client'}{'server'}{'evp'}, { 
            'SIGCHLD' => sub {
                my $out = $self->{'process'}{'fd'}{'stdout'}{'fd'};
                my $size;
                read($out, $size, 50);
                chomp $size;                
                say "size: $size";
                $self->{'process'} = HTTP::BS::Server::Process->new(['tar', @taropt], $self->{'client'}{'server'}{'evp'}, { 
                    'STDOUT' => sub {
                        my($out) = @_;
                        say "tar sending response";
                        my $header = "HTTP/1.1 200 OK\r\n";
                        $header .= "Accept-Ranges: none\r\n";
                        $header .= "Content-Length: $size\r\n";
                        $header .= "Content-Type: application/x-tar\r\n";
                        $header .= "Connection: keep-alive\r\n";
                        $header .= 'Content-Disposition: inline; filename="' . basename($requestfile) . ".tar\"\r\n";
                        $header .= "\r\n";
                        my %fileitem = ('fh' => $out, 'buf' => $header);
                        $self->_SendResponse(\%fileitem); 
                        return 0;
                    }                
                });
            },                      
        });
    
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
    use Socket qw(IPPROTO_TCP TCP_NODELAY);
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
        my $maxlength = 65536;
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
            my $bodylen = length($client->{'inbuf'});
            say "body - $bodylen bytes: " . $client->{'inbuf'} if($bodylen > 0);
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
            # TODO only TrySendResponse if there is data in buf or to be read           
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
                elsif($client->{'request'}{'header'}{'Infinite'} && ($client->{'request'}{'header'}{'Infinite'} eq 'true')) {
                    say "Infinite, not moving on";
                    $client->SetEvents($EventLoop::Poll::ALWAYSMASK ); 
                    #setsockopt($client->{'sock'}, IPPROTO_TCP, TCP_NODELAY, 1);
                    #return undef;                    
                    return 1;
                }
                elsif($client->{'request'}{'header'}{'Infinite'}) {
                    say "debugging buffering";
                    $client->SetEvents($EventLoop::Poll::ALWAYSMASK ); 
                    #$client->{'sock'}->autoflush(1);
                    #say "-------------------------------------------------";                               
                    #return undef;
                    #$client->{'sock'}->flush();
                    #setsockopt($client->{'sock'}, IPPROTO_TCP, TCP_NODELAY, 1);
                    #$| = 1;                    
                    return 1;                    
                }
                $client->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK );
                $client->onReadReady;
            }            
        }
        else {             
            #say "response not defined, probably set later by a timer or poll";                     
        }        
        return 1;        
    }    

    # TODO not block on read
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
                    if($req_length) {
                        my $tmpsend = $req_length - $filepos;
                        $readamt = $tmpsend if($tmpsend < $readamt);
                    }
                    # this is blocking, it shouldn't block for long but it could if it's a pipe especially
                    $bytesToSend = read($FH, $buf, $readamt);                    
                    #$bytesToSend = sysread($FH, $buf, $readamt);
                    if(! defined($bytesToSend)) {
                        $buf = undef;
                        say "READ ERROR: $!";            
                    }
                    elsif($bytesToSend == 0) {
                        # read EOF, better remove the error
                        if(! $req_length) {
                            say '$req_length not set and read 0 bytes, treating as EOF';
                            $buf = undef;                        
                        }
                        else {
                            seek($FH, 0, 1);                       
                            return '';
                        }
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
            say "wrote $total bytes";           
            return '';      
        }   
    }
    
    sub onHangUp {
        my ($client) = @_;        
        return undef;    
    }

    sub DESTROY {
        my $self = shift;
        say "client destructor called";
        if($self->{'sock'}) {
            #shutdown($self->{'sock'}, 2);
            close($self->{'sock'});  
        }
    }   
    
    1;  
}

package HTTP::BS::Server::FD::Reader{
    use strict; use warnings;
    use feature 'say';
    use Time::HiRes qw( usleep clock_gettime CLOCK_MONOTONIC);
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(looks_like_number weaken);
    sub new {
        my ($class, $process, $fd, $func) = @_;        
        my %self = ('time' => clock_gettime(CLOCK_MONOTONIC), 'process' => $process, 'fd' => $fd, 'onReadReady' => $func);
        say "PID " . $self{'process'}{'pid'} . 'FD ' . $self{'fd'};
        weaken($self{'process'});
        return bless \%self, $class;
    }
    
    sub onReadReady {
        my ($self) = @_;
        my $ret = $self->{'onReadReady'}($self->{'fd'});  
        if($ret == 0) {
            $self->{'process'}->remove($self->{'fd'});
            return 1;
        }
        if($ret == -1) {
            return undef;
        }
        if($ret == 1) {
            return 1;
        }
    }
    
    sub onHangUp {
    
    }
    
    sub DESTROY {
        my $self = shift;
        print "PID " . $self->{'process'}{'pid'} . ' ' if($self->{'process'});
        print "FD " . $self->{'fd'};
        say 'reader DESTROY called';                        
    }
    
    1;
 }
 
 package HTTP::BS::Server::FD::Writer {
    use strict; use warnings;
    use feature 'say';
    use Time::HiRes qw( usleep clock_gettime CLOCK_MONOTONIC);
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(looks_like_number weaken);
    sub new {
        my ($class, $process, $fd, $func) = @_;        
        my %self = ('time' => clock_gettime(CLOCK_MONOTONIC), 'process' => $process, 'fd' => $fd, 'onWriteReady' => $func); 
        weaken($self{'process'});
        return bless \%self, $class;
    }
    
    sub onWriteReady {
        my ($self) = @_;
        my $ret = $self->{'onWriteReady'}($self->{'fd'});
        if($ret == 0) {
            $self->{'process'}->remove($self->{'fd'});
            return 1;
        }
        if($ret == -1) {
            return undef;
        }
        if($ret == 1) {
            return 1;
        }
    }
    
    sub onHangUp {
    
    }

    sub DESTROY {
        my $self = shift;        
        say "PID " . $self->{'process'}{'pid'} . ' writer DESTROY called' .  " FD " . $self->{'fd'};
                  
    }
    
    1;
 }

package HTTP::BS::Server::Process {
    use strict; use warnings;
    use feature 'say';
    use Symbol 'gensym'; 
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use POSIX ":sys_wait_h";
    use IO::Socket::INET;
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Errno qw(EINTR EIO :POSIX);
    use Fcntl qw(:seek :mode);
    use File::stat;
    use IPC::Open3;
    use Scalar::Util qw(looks_like_number weaken);
    use Data::Dumper;
    use Carp;
    $SIG{ __DIE__ } = sub { Carp::confess( @_ ) };
    
    my %CHILDREN;
    $SIG{CHLD} = sub {
        while((my $child = waitpid(-1, WNOHANG)) > 0) {
            my ($wstatus, $exitcode) = ($?, $?>> 8);
            if(defined $CHILDREN{$child}) {                
                say "PID $child reaped (func) $exitcode"; 
                $CHILDREN{$child}->($exitcode);
                $CHILDREN{$child} = undef;
            }
            else {
                say "PID $child reaped (No func) $exitcode"; 
            }        
        }    
    };    
    
    sub new {
        my ($class, $torun, $evp, $fddispatch) = @_;        
        my %self = ('time' => clock_gettime(CLOCK_MONOTONIC), 'evp' => $evp);             
        my $pid = open3(my $in, my $out, my $err = gensym, @$torun) or die "BAD process";
        if($fddispatch->{'SIGCHLD'}) {
            say "PID $pid custom SIGCHLD handler";
            $CHILDREN{$pid} = $fddispatch->{'SIGCHLD'};            
        }
        $self{'pid'} = $pid;
        say 'PID '. $pid . ' NEW PROCESS: ' . $torun->[0];    
        if($fddispatch->{'STDIN'}) {            
            $self{'fd'}{'stdin'} = HTTP::BS::Server::FD::Writer->new(\%self, $in, $fddispatch->{'STDIN'});
            $evp->set($in, $self{'fd'}{'stdin'}, POLLOUT | $EventLoop::Poll::ALWAYSMASK);                       
        }
        else {                       
            $self{'fd'}{'stdin'}{'fd'} = $in;        
        }
        if($fddispatch->{'STDOUT'}) {        
            $self{'fd'}{'stdout'} = HTTP::BS::Server::FD::Reader->new(\%self, $out, $fddispatch->{'STDOUT'}); 
            $evp->set($out, $self{'fd'}{'stdout'}, POLLIN | $EventLoop::Poll::ALWAYSMASK);            
        }
        else {
            $self{'fd'}{'stdout'}{'fd'} = $out;        
        }
        if($fddispatch->{'STDERR'}) {
            $self{'fd'}{'stderr'} = HTTP::BS::Server::FD::Reader->new(\%self, $err, $fddispatch->{'STDERR'});
            $evp->set($err, $self{'fd'}{'stderr'}, POLLIN | $EventLoop::Poll::ALWAYSMASK);       
        }
        else {
            $self{'fd'}{'stderr'}{'fd'} = $err;
        }
               
        return bless \%self, $class;
    }

    sub new_output_process {       
        my ($class, $evp, $cmd, $handler, $stdin) = @_;
        my $stdout;
        my $stderr;
        my $process;
        
        my $prochandlers = {
        'STDOUT' => sub {
            my ($handle) = @_;
            my $buf;
            say "begin stdout read";
            while(read($handle, $buf, 100)) {
                $stdout .= $buf;        
            }
            say "broke out stdout";
            return 1;        
        },
        'STDERR' => sub {
            my ($handle) = @_;
            my $buf;
            say "begin stderr read";
            while(read($handle, $buf, 100)) {
                $stderr .= $buf;        
            }
            say "broke out stderr";
            return 1;
        },        
        'SIGCHLD' => sub {
            my $obuf;
            my $handle = $process->{'fd'}{'stdout'}{'fd'};
            while(read($handle, $obuf, 100000)) {
                $stdout .= $obuf; 
                say "stdout sigchld read";            
            }
            my $ebuf;
            $handle = $process->{'fd'}{'stderr'}{'fd'};
            while(read($handle, $ebuf, 100000)) {
                $stderr .= $ebuf;
                say "stderr sigchld read";              
            }
            $handler->($stdout, $stderr);         
        },      
        };
        
        if($stdin) {
            $prochandlers->{'STDIN'} = sub {
                # how to deadlock
                my ($in) = @_;
                say "output_process stdin";
                print $in $stdin; # this could block               
                return 0;        
            };   
        }
        
        $process =  $class->new($cmd, $evp, $prochandlers);
        
        my $flags = 0;
        my $handle = $process->{'fd'}{'stderr'}{'fd'};
        return unless defined $handle ;
        (0 == fcntl($handle, Fcntl::F_GETFL, $flags)) or return undef;
        $flags |= Fcntl::O_NONBLOCK;
        (0 == fcntl($handle, Fcntl::F_SETFL, $flags)) or return undef;
        $handle = $process->{'fd'}{'stdout'}{'fd'};
        return unless defined $handle ;
        (0 == fcntl($handle, Fcntl::F_GETFL, $flags)) or return undef;
        $flags |= Fcntl::O_NONBLOCK;
        (0 == fcntl($handle, Fcntl::F_SETFL, $flags)) or return undef;
        return $process;
    } 

    sub remove {
        my ($self, $fd) = @_;
        $self->{'evp'}->remove($fd);
        say "poll has " . scalar ( $self->{'evp'}{'poll'}->handles) . " handles";
        foreach my $key (keys %{$self->{'fd'}}) {
            if(defined($self->{'fd'}{$key}{'fd'}) && ($fd == $self->{'fd'}{$key}{'fd'})) {
                $self->{'fd'}{$key} = undef;
                last;                
            }
        }       
    }    
    
    
    sub DESTROY {
        my $self = shift;
        say "PID " . $self->{'pid'} . ' DESTROY called';              
    }
    
    1;    
}

package HTTP::BS::Server::Process::Python {
    use strict; use warnings;
    use feature 'say';

    # create the pool of python
    my $MAX_PYTHONS = 10;
    my $initialized; 
    my @freeprocesses;
    my @waiting;      

    sub new {
        my ($class, $evp, $do_hash) = @_;

        if(! $initialized) {
            for(my $i = 0; $i< $MAX_PYTHONS; $i++) {
                my $process = HTTP::BS::Server::Process(['python'], $evp, {
                    'STDIN' => sub {
                        say "HTTP::BS::Server::Process::Python stdin";
                        # write here
                    },
                    'STDOUT' => sub {
                        say "HTTP::BS::Server::Process::Python stdout";
                        # read and process
                    },
                    'STDERR' => sub {
                        say "HTTP::BS::Server::Process::Python stderr";
                        # read and process
                    },
                    'SIGCHLD' => sub {
                        say "HTTP::BS::Server::Process::Python SIGCHLD";
                        # read and process
                    }                    
                });
                push @freeprocesses, $process;
            }
            say "HTTP::BS::Server::Process::Python pool initialized, " . scalar(@freeprocesses) . ' processes';
        }
        my %self = ( 'evp' => $evp, 'do_hash' => $do_hash);
        bless \%self, $class;
        my $process = shift @freeprocesses;
        if(!$process) {
            say "out of free python processes, queuing";
            push @waiting, \%self;
            return \%self;
        }
        # set do_hash for process

        # manage file descriptors

        # return
        return \%self;
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
    use Scalar::Util qw(looks_like_number weaken);
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
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
            say "fnametmp $fnametmp";
            open(my $tmpfile, ">>", $fnametmp) or die;
            close($tmpfile);
        }
        ASYNC(\&_gdrive_upload, $file, $settings);
    }
    
    
    sub uploader {
        my($request, $requestfile) = @_;
        my $handled;
        
        # if the file isn't in the tempdir, create a symlink to it in th tmpdir
        my $tmpdir = $request->{'client'}{'server'}{'settings'}{'TMPDIR'};        
        my $qmtmpdir = quotemeta $tmpdir;
        if($requestfile !~ /^$qmtmpdir/) {
             my $reqbase = basename($requestfile);
             my $tmpfile = $tmpdir . '/' . $reqbase;
             if(! -e $tmpfile) {
                 symlink($requestfile, $tmpfile);
             }
             $requestfile = $tmpfile;
        }
                        
        # send if it was uploaded in time
        my $gdrivefile = should_gdrive($requestfile);       
        if(defined($gdrivefile) && looks_like_number($gdrivefile) && ($gdrivefile == 0)) {
            $handled = 1;
            my $url = read_file($requestfile . '_gdrive');
            $request->Send307($url);
        }
        
        my @togdrive;
        # if gdrive force was set and should_gdrive, still gdrive it 
        if(((! $handled) && ($request->{'qs'}{'gdriveforce'})) &&
        (defined($gdrivefile) && ($gdrivefile ne ''))) {        
            say 'forcing gdrive';           
            $handled = 1;
            $gdrivefile = $requestfile . '_gdrive';          
            push @togdrive, $requestfile;
            weaken($request); # the only one who should be keeping $request alive is $client                    
            $request->{'client'}{'server'}{'evp'}->add_timer(0, 0, sub {
                if(! defined $request) {
                    say "\$request undef, ignoring CB";
                    return undef;
                }                                       
                if(! -e $gdrivefile) {
                    my $current_time = clock_gettime(CLOCK_MONOTONIC);                                              
                    if(($current_time - $request->{'client'}{'time'}) < 6) {
                        say "extending time for gdrive";                    
                        $request->{'client'}{'time'} -= 6;
                    }
                    return 1;
                }                
                say "gdrivefile found";
                my $url = read_file($gdrivefile);
                $request->Send307($url);
                return undef;                    
            });            
        }                
        
        # queue up future hls files        
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
    HTTP::BS::Server::Util->import();
    use HTML::Entities;
    use Encode qw(decode encode);
    use Any::URI::Escape;
    use URI::Escape;
    use IPC::Open3;
    use Storable;
    use Fcntl ':mode';  
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use Scalar::Util qw(looks_like_number weaken);
    use POSIX qw/ceil/;
    
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
        #system ('rsync', '-az', '-e', "ssh -p $port", $aslibrary, "$userhost:MHFS/" . basename($aslibrary));        
        my $buf = shell_stdout('ssh', $userhost, '-p', $port, 'MHFS/.bin/aslibrary.pl', 'MHFS/server.pl', $folder);
        if(! $buf) {
            say "failed to read";
            return undef;
        }
        write_file('music.db', $buf);
        my $lib = retrieve('music.db');
        return $lib;
    }
    
    sub ToHTML {
        my ($files, $where) = @_;
        $where //= '';
        my $buf = '';
        my $name_unencoded = decode('UTF-8', $files->[0]);
        my $name = encode_entities($name_unencoded);        
        if($files->[2]) {
            my $dir = $files->[0]; 
            $buf .= '<tr>';            
            $buf .= '<td>';
            $buf .= '<table border="1" class="tbl_track">';
            $buf .= '<tbody>';
            $buf .= '<tr class="track">';
            $buf .= '<th>' . $name . '</th>';            
            $buf .= '<th><a href="#">Play</a></th><th><a href="#">Queue</a></th><th><a href="music_dl?action=dl&name=' . uri_escape_utf8($where.$name_unencoded) . '">DL</a></th>';
            $buf .= '</tr>'; 
            $where .= $name_unencoded . '/';            
            foreach my $file (@{$files->[2]}) {                
                $buf .= ToHTML($file, $where) ;      
            }            
            $buf .= '</tbody></table>';  
            $buf .= '</td>';
                        
        }
        else {
            if($where eq '') {
                 $buf .= '<table border="1" class="tbl_track">';
                 $buf .= '<tbody>';
            }
            $buf .= '<tr class="track">';        
            $buf .= '<td>' . $name . '</td>';             
            $buf .= '<td><a href="#">Play</a></td><td><a href="#">Queue</a></td><td><a href="music_dl?action=dl&name=' . uri_escape_utf8($where.$name_unencoded).'">DL</a></td>'; 
            if($where eq '') {
                 $buf .= '</tr>';
                 $buf .= '</tbody></table>';
                 return $buf;              
            }             
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
        
        $self->{'html'} = $buf .  read_file($self->{'settings'}{'DOCUMENTROOT'} . '/static/music_bottom.html');         
        #$self->{'html_gapless'} = $buf . read_file($self->{'settings'}{'DOCUMENTROOT'} . '/static/music_bottom_gapless.html');
        $self->{'html_gapless'} = $buf . read_file($self->{'settings'}{'DOCUMENTROOT'} . '/static/music_bottom_better.html');
    }

    sub SendLibrary {
        my ($self, $request) = @_;
        return $request->SendLocalBuf($self->{'html'}, "text/html; charset=utf-8");
    }
    
    my $SEGMENT_DURATION = 5;
    sub SendLocalTrackSegment {
        my ($request, $file) = @_;
        my $filebase = basename($file);
        $filebase =~ s/\.flac//i;
        my $tmpdir = $request->{'client'}{'server'}{'settings'}{'TMPDIR'}; 
        my $tosend = sprintf "$tmpdir/$filebase%03u.flac", $request->{'qs'}{'part'};
        if(-e $tosend) {
            $request->SendLocalFile($tosend);
            return;
        }
        my $evp = $request->{'client'}{'server'}{'evp'}; 
        $request->{'process'} = HTTP::BS::Server::Process->new(['sox', $file, "$tmpdir/$filebase.flac", 'trim', '0', $SEGMENT_DURATION, ':', 'newfile', ':', 'restart'], $evp, { 
            'SIGCHLD' => sub {
                $request->SendLocalFile($tosend);            
            }       
        });   
        
        #say "creating timer to watch for $tosend";
        #weaken($request); # the only one who should be keeping $request alive is $client                    
        #$evp->add_timer(0, 0, sub {
        #    if(! defined $request) {
        #        say "\$request undef, ignoring CB";
        #        return undef;
        #    }            
        #    if(! -e $tosend) {
        #        return 1;
        #    }
        #    #my $minsize = $VIDEOFORMATS{$fmt}->{'minsize'};
        #    #if(defined($minsize) && ((-s $filename) < $minsize)) {                      
        #    #    return 1;
        #    #}            
        #    say "SendLocalTrackSegment timer is destructing";
        #    $request->SendLocalFile($tosend);
        #    return undef;          
        #});   
    }
    
    sub SendLocalTrack {
        my ($request, $file) = @_;    
        my $evp = $request->{'client'}{'server'}{'evp'}; 
        my $SendFile = sub {
            my($tosend) = @_;    

            #my $gapless = $request->{'qs'}{'gapless'};            
            #if($gapless) {
            #    $request->SendFile($tosend);
            #}
            my $part = $request->{'qs'}{'part'};
            if(defined $part) {
                $request->{'process'} = HTTP::BS::Server::Process->new(['soxi', '-D', $tosend], $evp, {
                    'STDOUT' => sub {
                        my ($stdout) = @_;
                        my $buf;
                        $request->{'process'} = undef;
                        if(!read($stdout, $buf, 4096)) {
                            say "failed to read soxi";
                            $request->Send404;
                        }
                        else {
                            my ($duration) = $buf =~ /^(.+)$/;
                            $request->{'outheaders'}{'X-MHFS-NUMSEGMENTS'} = ceil($duration / $SEGMENT_DURATION);
                            $request->{'outheaders'}{'X-MHFS-TRACKDURATION'} = $duration;
                            $request->{'outheaders'}{'X-MHFS-MAXSEGDURATION'} = $SEGMENT_DURATION;
                            
                            SendLocalTrackSegment($request, $tosend);
                        }
                        return -1;                        
                    },                
                });
            }
            else {
                $request->SendLocalFile($tosend);
            }        
        };        
            
        
        my $tmpdir = $request->{'client'}{'server'}{'settings'}{'TMPDIR'};  
        my $filebase = basename($file);
        # determine if we need to convert to flac or to search for lossy flacs       
        my $is_flac = $file =~ /\.flac$/i;
        if(!$is_flac) {
            $filebase =~ s/\.[^.]+$/.lossy.flac/;
            my $tlossy = $tmpdir . '/' . $filebase;
            if(-e $tlossy ) {
                $is_flac = 1;
                $file = $tlossy;
            }            
        }
        my $max_sample_rate = $request->{'qs'}{'max_sample_rate'};
        # bitdepth only makes sense with PCM audio
        # however we do all processing in PCM (in flac)
        my $bitdepth = $request->{'qs'}{'bitdepth'};                
        if(! $max_sample_rate) {
            $SendFile->($file);
            return;            
        }           
        elsif(! $bitdepth) {
            $bitdepth = $max_sample_rate > 48000 ? 24 : 16;        
        }        
        say "using bitdepth $bitdepth";
        my %rates = (
            '48000' => [192000, 96000, 48000],
            '44100' => [176400, 88200, 44100]        
        );              
        my @acceptable_settings = ( [24, 192000], [24, 96000], [24, 48000], [24, 176400],  [24, 88200], [16, 48000], [16, 44100]);            
        my @desired = ([$bitdepth, $max_sample_rate]);           
        foreach my $setting (@acceptable_settings) {            
            if(($setting->[0] <= $bitdepth) && ($setting->[1] <= $max_sample_rate)) {                
                push @desired, $setting;
            }                
        }
                
        # if we already transcoded/resampled, don't waste time doing it again        
        foreach my $setting (@desired) {
            my $tmpfile = $tmpdir . '/' . $setting->[0] . '_' . $setting->[1] . '_' . $filebase;
            if(-e $tmpfile) {
                say "No need to resample $tmpfile exists";
                $SendFile->($tmpfile);
                return;
            }                      
        }
        
        # HACK
        say "client time was: " . $request->{'client'}{'time'};
        $request->{'client'}{'time'} += 30;
        say "HACK client time extended to " . $request->{'client'}{'time'};
        
        # convert to pcm (flac) and retry if not already
        if(!$is_flac) {
            if(! $request->{'qs'}{'part'}) {
                $SendFile->($file);
                return;
            }            
            
            my $outfile = $tmpdir . '/' . $filebase;          
            #my @cmd = ('ffmpeg', '-i', $file, $outfile);
            my @cmd = ('ffmpeg', '-i', $file, '-c:a', 'flac', '-sample_fmt', 's16', $outfile);
            my $buf;
            $request->{'process'} = HTTP::BS::Server::Process->new(\@cmd, $evp, {
            'SIGCHLD' => sub {
                # HACK
                $request->{'client'}{'time'} = clock_gettime(CLOCK_MONOTONIC);
                SendLocalTrack($request,$outfile);                
            },                    
            'STDERR' => sub {
                my ($terr) = @_;
                read($terr, $buf, 4096);                                     
            }}); 
            return;                     
        }
        
        # have ffmpeg determine the input file parameters and act accordingly                           
        $request->{'process'} = HTTP::BS::Server::Process->new(['ffmpeg', '-i', $file], $evp, {
        'STDERR' => sub {
            my ($err) = @_;
            my $buf;
            my $samplerate;                      
            my $rfailed = ! read($err, $buf, 4096);
            while(1) {
                if($rfailed) {                
                }                
                elsif($buf =~ /Audio:\s[^\s]+\s(\d+)\sHz,\s[a-z]+,\s(?:(?:s(16))|(?:s32\s\((24)\sbit\)))/) {
                    $samplerate = $1;
                    my $inbitdepth = $2 || $3;
                    #$inbitdepth = $3 if(! $inbitdepth);
                    say "input: samplerate $samplerate inbitdepth $inbitdepth";
                    say "maxsamplerate $max_sample_rate bitdepth $bitdepth";                    
                    if(($samplerate <= $max_sample_rate) && ($inbitdepth <= $bitdepth)) {
                        say "samplerate is <= max_sample_rate";
                        $SendFile->($file);
                        return -1;                
                    }                    
                    last;                
                }               
                say "regex or ffmpeg failed";
                say $buf if($buf);                
                $SendFile->($file);
                return -1;            
            }                                     
                        
            # choose the sample rate                
            my $desiredrate;
            RATE_FACTOR: foreach my $key (keys %rates) {
                if(($samplerate % $key) == 0) {
                    foreach my $rate (@{$rates{$key}}) {
                        if(($rate <= $samplerate) && ($rate <= $max_sample_rate)) {
                            $desiredrate = $rate;
                            last RATE_FACTOR;
                        }                      
                    }
                }                
            }
            $desiredrate //= $max_sample_rate;                
            say "desired rate: $desiredrate";
            # build the command                       
            my $outfile = $tmpdir . '/' . $bitdepth . '_' . $desiredrate . '_' . $filebase;
            my @cmd = ('sox', $file, '-G', '-b', $bitdepth, $outfile, 'rate', '-v', '-L', $desiredrate, 'dither');
            say "cmd: " . join(' ', @cmd);
            
            $request->{'process'} = HTTP::BS::Server::Process->new(\@cmd, $evp, {
            'SIGCHLD' => sub {
                # HACK
                $request->{'client'}{'time'} = clock_gettime(CLOCK_MONOTONIC); 
                $SendFile->($outfile);                                      
            },                    
            'STDERR' => sub {
                my ($terr) = @_;
                read($terr, $buf, 4096);                                     
            }});                  
            
            return -1;
            
        }});   
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
                    #return undef if(-d $file); #we can't handle directories right now
                    if( ! -d $file) {
                        SendLocalTrack($request, $file);
                    }
                    else {
                        $request->SendAsTar($file);
                    }
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
                    if(!  $source->{'httphost'}) {
                        $lib = undef;
                    }
                    else {
                        chop $source->{'httphost'};
                        $source->{'httpport'} //= 8000;
                    }                
                }            
                say "MHFS host at " . $source->{'httphost'} . ':' . $source->{'httpport'} if($source->{'httphost'});
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
        say "name: " . $request->{'qs'}{'name'};
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
            [ '/music_legacy', sub {
                my ($request) = @_;
                return $self->SendLibrary($request);        
            }],
            [ '/music_force', sub {
                my ($request) = @_;
                $self->BuildLibraries($settings->{'MUSICLIBRARY'}{'sources'}); 
                return $self->SendLibrary($request);
            }],
            [ '/music_gapless', sub {
               my ($request) = @_;
               $request->SendLocalBuf($self->{'html_gapless'}, "text/html; charset=utf-8");
            
            }],
            ['/music', sub {
                my ($request) = @_;
                foreach my $route (@{$self->{'routes'}}) {
                    if($route->[0] eq '/music_gapless') {
                        $route->[1]->($request);
                        last;
                    }
                }                
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

package Youtube {
    use strict; use warnings;
    use feature 'say';
    use Data::Dumper;
    use feature 'state';
    use Encode;
    use Any::URI::Escape;
    HTTP::BS::Server::Util->import();
    BEGIN {
        if( ! (eval "use JSON; 1")) {
            eval "use JSON::PP; 1" or die "No implementation of JSON available, see .doc/dependencies.txt";
            warn "Youtube: Using PurePerl version of JSON (JSON::PP), see .doc/dependencies.txt about installing faster version";
        }
    }

    sub searchbox {
        my ($self, $request) = @_;
        #my $html = '<form  name="searchbox" action="' . $request->{'path'}{'basename'} . '">';
        my $html = '<form  name="searchbox" action="yt">';
        $html .= '<input type="text" width="50%" name="q" ';
        my $query = $request->{'qs'}{'q'};
        if($query) {
            $query =~ s/\+/ /g;
            my $escaped = escape_html($query);
            $html .= 'value="' . $$escaped . '"';            
        }        
        $html .=  '>';
        if($request->{'qs'}{'media'}) {
            $html .= '<input type="hidden" name="media" value="' . $request->{'qs'}{'media'} . '">';
        }
        $html .= '<input type="submit" value="Search">';
        $html .= '</form>';
        return $html;
    }
    
    sub ytplayer {
        my ($self, $request) = @_;
        my $html = '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0" /><iframe src="static/250ms_silence.mp3" allow="autoplay" id="audio" style="display:none"></iframe>';
        my $url = 'get_video?fmt=yt&id=' . uri_escape($request->{'qs'}{'id'});
        $url .= '&media=' . uri_escape($request->{'qs'}{'media'}) if($request->{'qs'}{'media'});        
        if($request->{'qs'}{'media'} && ($request->{'qs'}{'media'} eq 'music')) {
            $request->{'path'}{'basename'} = 'ytaudio';
            $html .= '<audio controls autoplay src="' . $url . '">Great Browser</audio>';
        }        
        else {
            $request->{'path'}{'basename'} = 'yt';
            $html .= '<video controls autoplay src="' . $url . '">Great Browser</video>';
        }
        return $html;        
    }

    sub sendAsHTML {
        my ($self, $request, $response) = @_;
        my $json = decode_json($response);
        if(! $json){
            $request->Send404;
            return;
        }
        my $html = $self->searchbox($request);
        $html .= '<div id="vidlist">';
        foreach my $item (@{$json->{'items'}}) {
            my $id = $item->{'id'}{'videoId'};
            next if (! defined $id);         
            $html .= '<div>';
            my $mediaurl = 'ytplayer?fmt=yt&id=' . $id;
            my $media =  $request->{'qs'}{'media'};
            $mediaurl .= '&media=' . uri_escape($media) if(defined $media);
            $html .= '<a href="' . $mediaurl . '">' . $item->{'snippet'}{'title'} . '</a>';
            $html .= '<br>';
            $html .= '<a href="' . $mediaurl . '"><img src="' . $item->{'snippet'}{'thumbnails'}{'default'}{'url'} . '" alt="Excellent image loading"></a>';
            $html .= ' <a href="https://youtube.com/channel/' . $item->{'snippet'}{'channelId'} . '">' .  $item->{'snippet'}{'channelTitle'} . '</a>';
            $html .= '<p>' . $item->{'snippet'}{'description'} . '</p>';
            $html .= '<br>-----------------------------------------------';
            $html .= '</div>'
        }
        $html .= '</div>';
        $html .= '<script>
        var vidlist = document.getElementById("vidlist");
        vidlist.addEventListener("click", function(e) {                
            console.log(e);
            let target = e.target.pathname ? e.target : e.target.parentElement;           
            if(target.pathname && target.pathname.endsWith("ytplayer")) {
                e.preventDefault();
                console.log(target.href);                
                let newtarget = target.href.replace("ytplayer", "ytembedplayer");
                fetch(newtarget).then( response => response.text()).then(function(data) {
                    if(data) {
                        window.history.replaceState(vidlist.innerHTML, null);                        
                        window.history.pushState(data, null, target.href);
                        vidlist.innerHTML = data;                        
                    }                    
                });
            }   
        });
        
        window.onpopstate = function(event) {
            console.log(event.state);            
            vidlist.innerHTML = event.state;            
        }
        </script>';        
        $request->SendLocalBuf(encode_utf8($html), "text/html; charset=utf-8");        
    }

    sub onYoutube {
        my ($self, $request) = @_;         
        my $evp = $request->{'client'}{'server'}{'evp'};        
        my $youtubequery = 'q=' . (uri_escape($request->{'qs'}{'q'}) // '') . '&maxResults=' . ($request->{'qs'}{'maxResults'} // '25') . '&part=snippet&key=' . $self->{'settings'}{'YOUTUBE'}{'key'};
        $youtubequery .= '&type=video'; # playlists not supported yet
        my $tosend = '';
        my @curlcmd = ('curl', '-G', '-d', $youtubequery, 'https://www.googleapis.com/youtube/v3/search');
        print "$_ " foreach @curlcmd;
        print "\n";       
        state $tprocess;
        $tprocess = HTTP::BS::Server::Process->new(\@curlcmd, $evp, {
            #'STDOUT' => sub {
            #    my ($stdout) = @_;
            #    my $buf;
            #    if(read($stdout, $buf, 100000)) {  
            #        say "did read stdout";             
            #        $tosend .= $buf;
            #    }
            #    return 1;   
            #},
            'SIGCHLD' => sub {
                my $stdout = $tprocess->{'fd'}{'stdout'}{'fd'};
                my $buf;
                while(length($tosend) == 0) {
                    while(read($stdout, $buf, 24000)) {
                        say "did read sigchld";
                        $tosend .= $buf;
                    }                    
                }
                undef $tprocess;
                $request->{'qs'}{'fmt'} //= 'html';
                if($request->{'qs'}{'fmt'} eq 'json'){
                    $request->SendLocalBuf($tosend, "text/json; charset=utf-8");
                }
                else {
                    $self->sendAsHTML($request, $tosend);
                }               
            },
        });
        $request->{'process'} = $tprocess;
        return -1;
    }

    sub new {
        my ($class, $settings) = @_;
        my $self =  {'settings' => $settings};
        bless $self, $class;       

        $self->{'routes'} = [ 
        ['/youtube', sub {
            my ($request) = @_;
            $self->onYoutube($request);
        }],

        ['/yt', sub {
            my ($request) = @_;
            $self->onYoutube($request);
        }],

        ['/ytmusic', sub {
            my ($request) = @_;
            $request->{'qs'}{'media'} //= 'music';
            $self->onYoutube($request);
        }],

        ['/ytaudio', sub {
            my ($request) = @_;
            $request->{'qs'}{'media'} //= 'music';
            $self->onYoutube($request);
        }],
        ['/ytplayer', sub {
            my ($request) = @_;
            my $html = $self->searchbox($request);            
            $html .= $self->ytplayer($request);                   
            $request->SendLocalBuf($html, "text/html; charset=utf-8");
        }],
        ['/ytembedplayer', sub {
            my ($request) = @_;
            $request->SendLocalBuf($self->ytplayer($request), "text/html; charset=utf-8");        
        }],
        
        ];
        
        my $mhfsytdl = $settings->{'BINDIR'} . '/youtube-dl';  
        if(-e $mhfsytdl) {
            say "Using MHFS youtube-dl. Attempting update";
            system "$mhfsytdl", "-U";
            if(system("$mhfsytdl --help > /dev/null") != 0) {
                say "youtube-dl binary is invalid. plugin load failed";
                return undef;
            }
            $settings->{'youtube-dl'} = $mhfsytdl;
        }
        elsif(system('youtube-dl --help > /dev/null') == 0){
            say "Using system youtube-dl";
            $settings->{'youtube-dl'} = 'youtube-dl';        
        }
        else {
            say "youtube-dl not found. plugin load failed";
            return undef;
        }       

        return $self;
    }
    
    1;
}


package App::MHFS; #Media Http File Server
unless (caller) {
use strict; use warnings;
use feature 'say';
use feature 'state';
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
use POSIX;
use Encode qw(decode encode find_encoding);
use Any::URI::Escape;
use Scalar::Util qw(looks_like_number weaken);
use HTML::Entities;
use Encode;
use Symbol 'gensym';
binmode(STDOUT, ":utf8");
HTTP::BS::Server::Util->import();

$SIG{PIPE} = sub {
    print STDERR "SIGPIPE @_\n";
};

sub output_process {
    warn "output_process alias deprecated, use HTTP::BS::Server::Process->new_output_process";
    return HTTP::BS::Server::Process->new_output_process(@_);
}

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
$SETTINGS->{'MEDIALIBRARIES'}{'movies'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/movies", 
$SETTINGS->{'MEDIALIBRARIES'}{'tv'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/tv", 
$SETTINGS->{'MEDIALIBRARIES'}{'music'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/music", 
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
my $youtubeplugin = Youtube->new($SETTINGS);
push (@plugins, $youtubeplugin) if($youtubeplugin);
my $EXT_SOURCE_SITES = $SETTINGS->{'EXT_SOURCE_SITES'};

# make the temp dirs
make_path($SETTINGS->{'TMPDIR'}, $SETTINGS->{'VIDEO_TMPDIR'}, $SETTINGS->{'GDRIVE_TMP_REC_DIR'});

our %VIDEOFORMATS = (
            'hlsold' => {'lock' => 0, 'create_cmd' => "ffmpeg -i '%s' -codec:v copy -bsf:v h264_mp4toannexb -strict experimental -acodec aac -f ssegment -segment_list '%s' -segment_list_flags +live -segment_time 10 '%s%%03d.ts'",  'create_cmd_args' => ['requestfile', 'outpathext', 'outpath'], 'ext' => 'm3u8', 
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/hls_player.html'},

            #'hls' => {'lock' => 0, 'create_cmd' => ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-codec:v', 'copy', '-strict', 'experimental', '-codec:a', 'aac', '-ac', '2', '-f', 'hls', '-hls_time', '5', '-hls_list_size', '0',  '-hls_segment_filename', '$video{"out_location"} . "/" . $video{"out_base"} . "%04d.ts"', '-master_pl_name', '$video{"out_base"} . ".m3u8"', '$video{"out_filepath"} . "_v"'], 'ext' => 'm3u8', 'desired_audio' => 'aac',
            'hls' => {'lock' => 0, 'create_cmd' => ['ffmpeg', '-i', '$video{"src_file"}{"filepath"}', '-codec:v', 'libx264', '-strict', 'experimental', '-codec:a', 'aac', '-ac', '2', '-f', 'hls', '-hls_time', '5', '-hls_list_size', '0',  '-hls_segment_filename', '$video{"out_location"} . "/" . $video{"out_base"} . "%04d.ts"', '-master_pl_name', '$video{"out_base"} . ".m3u8"', '$video{"out_filepath"} . "_v"'], 'ext' => 'm3u8', 'desired_audio' => 'aac',
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
            
            'yt' => {'lock' => 1, 'create_cmd' => [$SETTINGS->{'youtube-dl'}, '--no-part', '--print-traffic', '-f', 
            '$VIDEOFORMATS{"yt"}{"youtube-dl_fmts"}{$qs->{"media"} // "video"} // "best"', '-o', '$video{"out_filepath"}', '--', '$qs->{"id"}'], 'ext' => 'yt', 
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
    [
        '/torrent', \&torrent
    ],
    [
        '/radio', sub {
            my ($request) = @_;
            $request->Send404; 
            return;
            $request->{'qs'}{'action'} //= 'listen';                      
            state $abuf;
            state $asegtime = 15;
            
            $request->{'header'}{'Infinite'} = 'true';
            if( $request->{'qs'}{'action'} eq 'broadcast') {
                my $atbuf; 
                $abuf = undef;
                my $evp = $request->{'client'}{'server'}{'evp'};                
                my $file = $SETTINGS->{'MEDIALIBRARIES'}{'music'} . '/Alphaville - Forever Young (1984) [FLAC24-192] {P-13065}/02 - Summer in Berlin.flac';
                my $bitdepth = 16;
                my $desiredrate = 48000;
                my $atime = 0;              
                my $afmt = 'flac';
                
                state $processSegmentProcess;                
                my $processSegment = sub {
                    my ($onSegment) = @_;
                    my @cmd = ('sox', '-t', 'sox', '-', '-V3', '-G', '-R', '-b', $bitdepth, '-t', $afmt, '-', 'rate', '-v', '-L', $desiredrate, 'dither');
                    say "cmd: " . join(' ', @cmd);
                    $atbuf = undef;                    
                    $processSegmentProcess = HTTP::BS::Server::Process->new(\@cmd, $evp, {
                    #'STDIN' => sub {
                    #    my ($in) = @_;
                    #    print $in $data;
                    #    return 0;
                    #},
                    'SIGCHLD' => sub {                       
                        my $buf;
                        # dump stderr                        
                        my $stderr = $processSegmentProcess->{'fd'}{'stderr'}{'fd'};
                        while(read($stderr, $buf, 65536)) {
                            print $buf;
                        }                                               
                        my $stdout = $processSegmentProcess->{'fd'}{'stdout'}{'fd'};
                        while(read($stdout, $buf, 65536)) {
                            say 'sigchld read';
                            $atbuf .= $buf;
                        }                                               
                                             
                        # don't write the meta, only frames (inc header)
                        sub getNthByte {
                            my ($pos, $sbuf) = @_;                            
                            return ord(substr( $sbuf, $pos, 1));
                        }                       
                        for(my $pos = 0;;$pos++) {
                            my $bytea = getNthByte($pos, $atbuf);
                            my $byteb = getNthByte($pos+1, $atbuf);
                            my $val = ($bytea << 8) + $byteb;                            
                            if( ($val & 0xFFFE) == 0xFFF8) {
                                say sprintf "synccode bytes: %x%x %c%c", $bytea, $byteb , $bytea, $byteb;
                                $atbuf = substr $atbuf, $pos;
                                last;
                            } 
                            elsif($pos == length($atbuf)) {
                                use bytes;
                                say "no synccode found, length" . length($atbuf);
                                last;
                            }                                          
                        }
                        undef  $processSegmentProcess; 
                        say "processSegment done, executing onSegment";
                        $onSegment->();                        
                        $request->{'process'} = undef;                        
                    },
                   'STDOUT' => sub {
                        my ($output) = @_;
                        my $buf;                       
                        if(my $bytes = read($output, $buf, 65536*2)) {
                            $atbuf .= $buf;                                                       
                        }                                               
                        return 1;
                   }                 
                   });
                };
                state $getSegmentProcess;
                my $getSegment = sub {
                    my ($onSegment) = @_;                 
                    my @cmd = ('sox', $file, '-t', 'sox', '-', 'trim', $atime, $asegtime);
                    $atime +=  $asegtime;
                    say "cmd: " . join(' ', @cmd);
                    my $segment;                    
                    $getSegmentProcess = HTTP::BS::Server::Process->new(\@cmd, $evp, {
                    'SIGCHLD' => sub {                        
                        my $buf;
                        my $stdout = $getSegmentProcess->{'fd'}{'stdout'}{'fd'};
                        binmode($stdout, ":bytes");
                        while(read($stdout, $buf, 65536)) {
                            say 'sigchld read';
                            $segment .= $buf;
                        }                      
                        my $dfd = $processSegmentProcess->{'fd'}{'stdin'}{'fd'};
                        print $dfd $segment;
                        close($dfd);# so the other end pipe knows we are done writing                       
                        undef  $getSegmentProcess;
                        say "getSegment first proc done";
                    },
                    'STDOUT' => sub {
                        my ($output) = @_;
                        binmode($output, ":bytes");
                        my $buf;                        
                        if(my $bytes = read($output, $buf, 65536*2)) {
                           $segment .= $buf;                                                       
                        }                                               
                        return 1;
                    },                
                    'STDERR' => sub {
                        my ($terr) = @_;                       
                        my $buf;                    
                        read($terr, $buf, 1);
                        say "stderr: $buf";                    
                    }});                                      
                };
                weaken($request); # the only one who should be keeping $request alive is $client    
                $getSegment->();
                $processSegment->( sub {                   
                    {
                        use bytes;
                        say "atbuf length " . length($atbuf);                    
                    }
                    $request->StartSendingBuf($atbuf, 'audio/flac');
                    $abuf = $atbuf;                                     
                    #$afmt = 'raw';                                     
                    my $setSegTimer = sub {
                        my ($self, $when) = @_;                                     
                        $evp->add_timer($when, 0, sub {
                            if(! defined $request) {
                                say "\$request undef, ignoring CB";
                                return undef;
                            }
                            $getSegment->();
                            $processSegment->(
                            sub {                               
                                return if(! $atbuf);
                                {
                                    use bytes;
                                    say "atbuf length " . length($atbuf);                    
                                }
                                $request->{'response'}{'buf'} .= $atbuf;
                                $request->{'client'}->SetEvents(POLLOUT | $EventLoop::Poll::ALWAYSMASK );                                 
                                $abuf = $atbuf; 
                                $request->{'header'}{'Infinite'} = 'false';                            
                                $self->($self, 0);#$asegtime);
                                
                            });                                                       
                            return undef;
                        });                                                                     
                    };                    
                    $setSegTimer->($setSegTimer, 0);                                    
                });                           
            }
            else {
                $request->StartSendingBuf($abuf, 'audio/flac');            
            }        
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

# really acquire media file (with search) and convert
sub get_video {
    my ($request) = @_;
    my ($client, $qs, $header) =  ($request->{'client'}, $request->{'qs'}, $request->{'header'});       
    say "/get_video ---------------------------------------";
    $qs->{'fmt'} //= 'noconv';
    my %video = ('out_fmt' => video_get_format($qs->{'fmt'}));
    if(defined($qs->{'name'})) {        
        my $src_file;
        if($src_file = video_file_lookup($qs->{'name'})) {
            $video{'src_file'} = $src_file;
            $video{'out_base'} = $src_file->{'name'};
        }
        elsif($src_file = media_file_search($qs->{'name'})) {
            say "useragent: " . $header->{'User-Agent'};
            # VLC 2 doesn't handle redirects? VLC 3 does
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
            # elseif(0) {
            elsif($fmt eq 'yt') {
                # delete lock?
                weaken($request);
                my ($stdout, $done);
                $request->{'process'} = HTTP::BS::Server::Process->new(\@cmd, $request->{'client'}{'server'}{'evp'}, {
                'STDOUT' => sub {
                    my($out) = @_;
                    my $buf;
                    while(read($out, $buf, 100)) {
                        $stdout .= $buf;        
                    }
                    return 1 if($done);
                    my $filename = $video{'out_filepath'};
                    return 1 if(! (-e $filename));
                    my $minsize = $VIDEOFORMATS{$fmt}->{'minsize'};
                    if(defined($minsize) && ((-s $filename) < $minsize)) {                      
                        return 1;
                    }                    
                    my ($cl) = $stdout =~ /^.*Content\-Length:\s(\d+)/s;
                    return 1 if(! $cl);
                    say "stdout $stdout";
                    my ($cr) = $stdout =~ /^.*Content\-Range:\sbytes\s\d+\-\d+\/(\d+)/s;
                    if($cr) {
                        say "cr $cr";
                        $cl = $cr if($cr > $cl);                        
                    }                    
                    say "cl is $cl";
                    UNLOCK_WRITE($filename);
                    LOCK_WRITE($filename, $cl);
                    if($request) {
                        $request->SendLocalFile($filename);                        
                    }
                    else {
                        say "request died, not sending";
                    }                    
                    $done = 1;
                    return 1;
                },
                'STDERR' => sub {                    
                    my ($err) = @_;
                    my $buf;
                    # log this somewhere?
                    while(read($err, $buf, 100)) { }
                    return 1;
                },
                'SIGCHLD' => sub {
                    my ($exitcode) = @_;
                    if (!$done) {
                        my $filename = $video{'out_filepath'};
                        if(! -e $filename) {
                            say "youtube-dl failed ($exitcode), file not done in SIGCHLD. file doesnt exist 404";
                            $request->Send404 if($request);
                        }
                        else {
                            say "youtube-dl probably failed ($exitcode). sending file anyways";
                            $request->SendLocalFile($filename) if($request);
                        }
                    }
                },
                });
                my $process = $request->{'process'}; 
                my $flags = 0;
                my $handle = $process->{'fd'}{'stderr'}{'fd'};
                return unless defined $handle ;
                (0 == fcntl($handle, Fcntl::F_GETFL, $flags)) or return undef;
                $flags |= Fcntl::O_NONBLOCK;
                (0 == fcntl($handle, Fcntl::F_SETFL, $flags)) or return undef;
                $handle = $process->{'fd'}{'stdout'}{'fd'};
                return unless defined $handle ;
                (0 == fcntl($handle, Fcntl::F_GETFL, $flags)) or return undef;
                $flags |= Fcntl::O_NONBLOCK;
                (0 == fcntl($handle, Fcntl::F_SETFL, $flags)) or return undef;  

                return 1;
            }
            # deprecated
            $video{'pid'} = ASYNC(\&shellcmd_unlock, \@cmd, $video{'out_filepath'});            
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
            # test if its ready to send
            while(1) {
                 my $filename = $video{'out_filepath'};
                 if(! -e $filename) {
                     last;
                 }
                 my $minsize = $VIDEOFORMATS{$fmt}->{'minsize'};
                 if(defined($minsize) && ((-s $filename) < $minsize)) {                      
                     last;
                 }
                 if(defined $video{'on_exists'}) {
                     last if (! $video{'on_exists'}->(\%video));              
                 }
                 say "get_video_timer is destructing";
                 $request->SendLocalFile($filename);
                 return undef;            
            }
            # 404, if we didn't send yet the process is not running
            if(pid_running($video{'pid'})) {
                return 1;
            }
            say "pid not running: " . $video{'pid'} . " get_video_timer done with 404";
            $request->Send404;
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
    my @locations = ($SETTINGS->{'MEDIALIBRARIES'}{'movies'}, $SETTINGS->{'MEDIALIBRARIES'}{'tv'}, $SETTINGS->{'MEDIALIBRARIES'}{'music'});    
    
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
    my $pid = open3(my $in, my $out, my $err = gensym, @command) or say "BAD FFMPEG";
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
    my @locations = ($SETTINGS->{'MEDIALIBRARIES'}{'movies'}, $SETTINGS->{'MEDIALIBRARIES'}{'tv'}, $SETTINGS->{'MEDIALIBRARIES'}{'music'});

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





sub ptp_request {
    my ($evp, $url, $handler, $tried_login) = @_;
    my $atbuf;
    my @cmd = ('curl', '-s', '-v', '-b', '/tmp/ptp', '-c', '/tmp/ptp', 'https://xxxxxxx.domain/' . $url);    

    my $process;
    $process    = output_process($evp, \@cmd, sub {
        my ($output, $error) = @_;
        if($output) {
            #say 'ptprequest output: ' . $output;
            $handler->($output);
        }
        else {
            say 'ptprequest error: ' . $error;
            if($tried_login) {
                $handler->(undef);
                return;            
            }
            $tried_login = 1;
            my $postdata = 'username=' . $SETTINGS->{'PTP'}{'username'} . '&password=' . $SETTINGS->{'PTP'}{'password'} . '&passkey=' . $SETTINGS->{'PTP'}{'passkey'};
            my @logincmd = ('curl', '-s', '-v', '-b', '/tmp/ptp', '-c', '/tmp/ptp', '-d', $postdata,  'https://xxxxxxx.domain/ajax.php?action=login');
            $process = output_process($evp, \@logincmd, sub {
                 my ($output, $error) = @_;
                 # todo error handling
                 ptp_request($evp, $url, $handler, 1);            
            
            });
                        
        }
    });
    return $process;
}

sub rtxmlrpc {
    my ($evp, $params, $cb, $stdin) = @_;
    my $process;
    my @cmd = ('rtxmlrpc', @$params, '--config-dir', '~/MHFS/.conf/.pyroscope/');
    $process    = output_process($evp, \@cmd, sub {
        my ($output, $error) = @_;
        chomp $output;
        #say 'rtxmlrpc output: ' . $output;
        $cb->($output);   
    }, $stdin);
    return $process;
}

sub lstor {
    my ($evp, $params, $cb) = @_;
    my $process;
    my @cmd = ('lstor', '-q', @$params);
    $process    = output_process($evp, \@cmd, sub {
        my ($output, $error) = @_;
        chomp $output;
        say 'lstor output: ' . $output;
        $cb->($output);   
    });
    return $process;
}

sub torrent_file_hash {
    my ($evp, $file, $cb) = @_;
    lstor($evp, ['-o', '__hash__', $file], $cb);
}

sub torrent_d_bytes_done {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.bytes_done', $infohash ], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);      
    });
}

sub torrent_d_size_bytes {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.size_bytes', $infohash ],sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);       
    });
}

# awful and broken
sub torrent_load_raw_verbose {
    my ($evp, $data, $callback) = @_;
    rtxmlrpc($evp, ['load.raw_verbose', '@-' ],sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);       
    }, $data);
}


sub torrent_load_verbose {
    my ($evp, $filename, $callback) = @_;
    rtxmlrpc($evp, ['load.verbose', '', $filename], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);     
    });
}


sub torrent_d_directory_set {
    my ($evp, $infohash, $directory, $callback) = @_;
    rtxmlrpc($evp, ['d.directory.set', $infohash, $directory], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);      
    });
}

sub torrent_d_start {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.start', $infohash], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);      
    });
}

sub torrent_start {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.stop', $infohash], sub {
    my ($output) = @_;
    if($output =~ /ERROR/) {
        $callback->(undef);
        return;            
    }
    torrent_d_start($evp, $infohash, $callback);    
    });



}

sub torrent_d_delete_tied {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.delete_tied', $infohash], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);    
    });
}


sub torrent_d_name{
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.name', $infohash], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);    
    });
}

sub torrent_d_is_multi_file {
    my ($evp, $infohash, $callback) = @_;
    rtxmlrpc($evp, ['d.is_multi_file', $infohash], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);    
    });
}


sub torrent_set_priority {
    my ($evp, $infohash, $priority, $callback) = @_;
    rtxmlrpc($evp, ['f.multicall', $infohash, '', 'f.priority.set=' . $priority], sub {
    my ($output) = @_;
    if($output =~ /ERROR/) {
        $callback->(undef);
        return;        
    }
    rtxmlrpc($evp, ['d.update_priorities', $infohash], sub {
    if($output =~ /ERROR/) {
        $output = undef;          
    }
    $callback->($output);    
    })});
}


# lookup the findex for the file and then set the priority on it
# ENOTIMPLEMENTED
sub torrent_set_file_priority {
    my ($evp, $infohash, $file, $priority, $callback) = @_;
    rtxmlrpc($evp, ['f.multicall', $infohash, '', 'f.path='], sub {
    my ($output) = @_;
    if($output =~ /ERROR/) {
        $callback->(undef);
        return;        
    }
    say "torrent_set_file_priority";
    say $output;
    die;
    
    $callback->($output);
    });
}

sub torrent_list_torrents {
    my ($evp, $callback) = @_;
    rtxmlrpc($evp, ['d.multicall2', '', 'default', 'd.name=', 'd.hash=', 'd.size_bytes=', 'd.bytes_done='], sub {
        my ($output) = @_;
        if($output =~ /ERROR/) {
            $output = undef;           
        }
        $callback->($output);    
    });
}


sub get_SI_size {
    my ($bytes) = @_;
    my $mebibytes = ($bytes / 1048576);
    if($mebibytes >= 1024) {
        return  sprintf("%.2f GiB", $bytes / 1073741824);                       
    }
    else {
        return sprintf("%.2f MiB", $mebibytes);                        
    }
}

#sub torrent_information {
#    my ($evp, $infohash, $cb) = @_;
#    rtxmlrpc($evp, ['d.multicall2', $infohash, '', 'd.name=', 'd.size_bytes=', 'd.bytes_done='], sub {    
#    my ($output) = @_;
#    if($output =~ /ERROR/) {
#        $output = undef;           
#    }
#    $callback->($output);    
#    });
#}

sub torrent_file_information {
    my ($evp, $infohash, $name, $cb) = @_;
    rtxmlrpc($evp, ['f.multicall', $infohash, '', 'f.path=', 'f.size_bytes='], sub {    
    my ($output) = @_;
    if($output =~ /ERROR/) {
        $output = undef;           
    }
    
    my @pairs = split( /\]\n\[/, $output);    
    my %files;
    foreach my $pair (@pairs) {
        #say "pair: $pair";
        my ($file, $size) = $pair =~ /\[?'(.+)',\n?\s(\d+)/mg;
        #say "file $file size $size";
        if((! defined $file) || (!defined $size)) {
            $cb->(undef);
            return;        
        }
        $files{$file} = {'size' => $size};
    }
    my @fkeys = (keys %files);
    if(@fkeys == 1) {
        my $key = $fkeys[0];
        torrent_d_is_multi_file($evp, $infohash, sub {
        my ($res) = @_;
        if(! defined $res) {
            $cb->(undef);        
        }
        if($res == 1) {
            %files = (   $name . '/' . $key => $files{$key});      
        }
        $cb->(\%files);
        });
        return;
    }
    my %newfiles;
    foreach my $key (@fkeys) {
        $newfiles{$name . '/' . $key} = $files{$key};
    }    
    $cb->(\%newfiles);      
    });
}



sub is_video {
    my ($name) = @_;
    my ($ext) = $name =~ /\.(mkv|avi|mp4|webm|flv|ts|mpeg|mpg|m2t|m2ts|wmv)$/i;
    return $ext;
}

# is supported by mhfs music
sub is_mhfs_music_playable {
    my ($name) = @_;
    my ($ext) = $name =~ /\.(flac)$/i;
    return $ext;
}

sub play_in_browser_link {
    my ($file, $torrent_path) = @_;
    return '<a href="video?name=' . $torrent_path . '&fmt=hls">HLS (Watch in browser)</a>' if(is_video($file));
    return '<a href="music?ptrack=' . $torrent_path . '">Play in MHFS Music</a>' if(is_mhfs_music_playable($file));
    return 'N/A';
}

# perform multiple async actions at the same time.
# continue on with $result_func on failure or completion of all actions
sub do_multiples{
    my ($multiples, $result_func) = @_;    
    my %data;
    my @mkeys = keys %{$multiples};
    foreach my $multiple (@mkeys) {
        my $multiple_cb = sub {
            my ($res) = @_;
            $data{$multiple} = $res;
            # return failure if this multiple failed
            if(! defined $data{$multiple}) {
                $result_func->(undef);
                return;          
            }
            # yield if not all the results in             
            foreach my $m2 (@mkeys) {
                return if(! defined $data{$m2});            
            }
            # all results in we can continue
            $result_func->(\%data);            
        };
        say "launching multiple key: $multiple";
        $multiples->{$multiple}->($multiple_cb);  
    }
}

sub torrent_on_contents {
    my ($evp, $request, $result, $tname, $saveto) = @_;
    if(! $result) {
        say "failed to dl torrent";
        $request->Send404;
        return;                  
    }
    else {        
        write_file($tname, $result);
        torrent_file_hash($evp, $tname, sub {
        # error handling bad hashes?
        my ($asciihash) = @_;
        say 'infohash ' . $asciihash;
        
        # see if the hash is already in rtorrent
        torrent_d_bytes_done($evp, $asciihash, sub {
        my ($bytes_done) = @_;
        if(! defined $bytes_done) {                    
        # load, set directory, and download it (race condition)
        # 02/05/2020 what race condition?           
            torrent_load_verbose($evp, $tname, sub {                
            if(! defined $_[0]) {
                $request->Send404;
                unlink($tname);
                return;                
            }     
            
            torrent_d_delete_tied($evp, $asciihash, sub {
            unlink($tname);                
            if(! defined $_[0]) { $request->Send404; return;}              
            
            torrent_d_directory_set($evp, $asciihash, $saveto, sub {
            if(! defined $_[0]) { $request->Send404; return;}           
            
            torrent_d_start($evp, $asciihash, sub {
            if(! defined $_[0]) { $request->Send404; return;}

            say 'downloading ' . $asciihash;
            $request->Send301('torrent?infohash=' . $asciihash);                    
            })})})});
        }
        else {
        # set the priority and download
            torrent_set_priority($evp, $asciihash, '1', sub {
            if(! defined $_[0]) { $request->Send404; return;}                    
            
            torrent_d_start($evp, $asciihash, sub {
            if(! defined $_[0]) { $request->Send404; return;}
            
            say 'downloading (existing) ' . $asciihash;
            $request->Send301('torrent?infohash=' . $asciihash);                                     
            })});
        }                
        })});                                  
    }
}

# if an infohash is provided and it exists in rtorrent it reports the status of it
    # starting or stopping it if requested. 
# if an id is provided, it downloads the torrent file to lookup the infohash and adds it to rtorrent if necessary
    # by default it starts it. 
sub torrent {
    my ($request) = @_;
    my $qs = $request->{'qs'};
    my $evp = $request->{'client'}{'server'}{'evp'};
    # dump out the status, if the torrent's infohash is provided
    if(defined $qs->{'infohash'}) {
        my $hash = $qs->{'infohash'};
        do_multiples({
        'bytes_done' => sub { torrent_d_bytes_done($evp, $hash, @_); },
        'size_bytes' => sub { torrent_d_size_bytes($evp, $hash, @_); },
        'name'       => sub { torrent_d_name($evp, $hash, @_); },  
        }, sub {        
        if( ! defined $_[0]) { $request->Send404; return;}        
        my ($data) = @_;    
        my $torrent_raw = $data->{'name'};
        my $bytes_done  = $data->{'bytes_done'};
        my $size_bytes  = $data->{'size_bytes'};
        # print out the current torrent status
        my $torrent_name = ${escape_html($torrent_raw)};        
        my $size_print = get_SI_size($size_bytes);
        my $done_print = get_SI_size($bytes_done); 
        my $percent_print = (sprintf "%u%%", ($bytes_done/$size_bytes)*100);
        my $buf = '<h1>Torrent</h1>';
        $buf  .=  '<h3><a href="video?action=browsemovies">Browse Movies</a> | <a href="video">Video</a> | <a href="music">Music</a></h3>';
        $buf   .= '<table border="1" >';
        $buf   .= '<thead><tr><th>Name</th><th>Size</th><th>Done</th><th>Downloaded</th></tr></thead>';
        $buf   .= "<tbody><tr><td>$torrent_name</td><td>$size_print</td><td>$percent_print</td><td>$done_print</td></tr></tbody>";
        $buf   .= '</table>';       
        
        # Assume we are downloading, if the bytes don't match
        if($bytes_done < $size_bytes) {
            $buf   .= '<meta http-equiv="refresh" content="3">';   
            $request->SendLocalBuf($buf , 'text/html');            
        }
        else {
        # print out the files with usage options        
            torrent_file_information($evp, $qs->{'infohash'}, $torrent_raw, sub {
            if(! defined $_[0]){ $request->Send404; return; };
            my ($tfi) = @_;
            my @files = sort (keys %$tfi);
            $buf .= '<br>';
            $buf .= '<table border="1" >';
            $buf .= '<thead><tr><th>File</th><th>Size</th><th>DL</th><th>Play in browser</th></tr></thead>';
            $buf .= '<tbody';
            foreach my $file (@files) {                
                my $torrent_path = ${ escape_html($file)} ;
                my $link = '<a href="get_video?name=' . $torrent_path . '&fmt=noconv">DL</a>';
                my $playlink = play_in_browser_link($file, $torrent_path);
                $buf .= "<tr><td>$torrent_path</td><td>" . get_SI_size($tfi->{$file}{'size'}) . "</td><td>$link</td>";
                $buf .= "<td>$playlink</td>" if(!defined($qs->{'playinbrowser'}) || ($qs->{'playinbrowser'} == 1));
                $buf .= "</tr>"; 
            }
            $buf .= '</tbody';
            $buf .= '</table>';            
                    
            $request->SendLocalBuf($buf , 'text/html');
            });                 
        }
        
        });                
    }
    # convert id to infohash (by downloading it and adding it to rtorrent if necessary
    elsif(defined $qs->{'ptpid'}) {
        ptp_request($evp, 'torrents.php?action=download&id=' . $qs->{'ptpid'}, sub {  
            my ($result) = @_;        
            my $tname = '/tmp/ptp_' . $qs->{'ptpid'} . '.torrent';
            torrent_on_contents($evp, $request, $result, $tname, $SETTINGS->{'MEDIALIBRARIES'}{'movies'});
        });
    }
    elsif(defined $qs->{'list'}) {
        torrent_list_torrents($evp, sub{
            if(! defined $_[0]){ $request->Send404; return; };
            my ($rtresponse) = @_;
            my @lines = split( /\n/, $rtresponse);
            my $buf = '<h1>Torrents</h1>';
            $buf  .=  '<h3><a href="video?action=browsemovies">Browse Movies</a> | <a href="video">Video</a> | <a href="music">Music</a></h3>';
            $buf   .= '<table border="1" >';
            $buf   .= '<thead><tr><th>Name</th><th>Hash</th><th>Size</th><th>Done</th></tr></thead>';
            $buf   .= "<tbody>";
            my $curtor = '';
            while(1) {               
                if($curtor =~ /^\[(u?)['"](.+)['"],\s'(.+)',\s([0-9]+),\s([0-9]+)\]$/) {
                    my %torrent;
                    my $is_unicode = $1;
                    $torrent{'name'} = $2;
                    $torrent{'hash'} = $3;
                    $torrent{'size_bytes'} = $4;
                    $torrent{'bytes_done'} = $5;
                    if($is_unicode) {
                        my $escaped_unicode = $torrent{'name'};                        
                        $torrent{'name'} =~ s/\\u(.{4})/chr(hex($1))/eg;                                          
                        $torrent{'name'} =~ s/\\x(.{2})/chr(hex($1))/eg;
                        my $decoded_as = $torrent{'name'};                     
                        $torrent{'name'} = ${escape_html($torrent{'name'})};
                        #$torrent{'name'} = encode_entities($torrent{'name'});
                        if($qs->{'logunicode'}) {
                            say 'unicode escaped: ' . $escaped_unicode;
                            say 'decoded as: ' . $decoded_as;
                            say 'html escaped ' . $torrent{'name'};
                        }
                    }
                    $buf .= '<tr><td>' . $torrent{'name'} . '</td><td>' . $torrent{'hash'} . '</td><td>' . $torrent{'size_bytes'} . '</td><td>' . $torrent{'bytes_done'} . '</td></tr>';
                    $curtor = '';                    
                }
                else {
                    my $line = shift @lines;
                    if(! $line) {
                        last;
                    }                    
                    $curtor .= $line;                   
                }                
            }            
            $buf   .= '</tbody></table>';   
            $request->SendLocalBuf(encode('UTF-8', $buf), 'text/html; charset=utf-8');
        });
    }
    else {
        $request->Send404;
    }
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
    $buf .= '.searchfield { width: 50%; margin: 30px;}';
    $buf .= '</style>';
    $buf .= "</head>";
    $buf .= "<body>";   
    
    $qs->{'action'} //= 'library';
    if($qs->{'action'} eq 'browsemovies') {
        my $evp = $request->{'client'}{'server'}{'evp'};    
        $buf .= '<h1>Browse Movies</h1>';
        $buf .= '<h3><a href="video">Video</a> | <a href="music">Music</a></h3>';        
        $buf .= '<form action="video" method="GET">';
        $buf .= '<input type="hidden" name="action" value="browsemovies">';
        $buf .= '<input type="text" placeholder="Search" name="searchstr" class="searchfield">';
        $buf .= '<button type="submit">Search</button>';
        $buf .= '</form>';  
        $qs->{'searchstr'} //= '';
        my $url = 'torrents.php?searchstr=' . $qs->{'searchstr'} . '&json=noredirect';
        $qs->{'page'} = int($qs->{'page'});
        $url .= '&page=' . $qs->{'page'} if( $qs->{'page'});         
        ptp_request($evp, $url, sub {        
            my ($result) = @_;
            if(! $result) {
                $buf .= '<h2>Search Failed</h2>';              
            }
            else {                
                #$request->SendLocalBuf($result, "text/json");
                #return;
                my $moviedir;               
                my @dlmovies;
                if(opendir($moviedir, $SETTINGS->{'MEDIALIBRARIES'}{'movies'})) {
                    while(my $movie = readdir($moviedir)) {
                        if(! -d ($SETTINGS->{'MEDIALIBRARIES'}{'movies'} . '/' . $movie)) {
                            $movie =~ s/\.[^.]+$//;
                        }
                        push @dlmovies, $movie;
                    }
                    closedir($moviedir);                    
                }
                my $json = decode_json($result);
                my $numresult = $json->{'TotalResults'};
                my $numpages = ceil($numresult/50);
                say "numresult $numresult pages $numpages";                
                foreach my $movie (@{$json->{'Movies'}}) {
                    $buf .= '<table class="tbl_movie" border="1"><tbody>';
                    $buf .= '<tr><th>' . $movie->{'Title'} . ' [' . $movie->{'Year'} . ']</th><th>Time</th><th>Size</th><th>Snatches</th><th>Seeds</th><th>Leeches</th></tr>';
                    foreach my $torrent ( @{$movie->{'Torrents'}}) {
                        $buf .= '<tr><td>' . $torrent->{'Codec'} . ' / ' . $torrent->{'Container'} . ' / ' . $torrent->{'Source'} . ' / ' . $torrent->{'Resolution'};
                        ($buf .= ' / ' . $torrent->{'Scene'}) if $torrent->{'Scene'} eq 'true';
                        ($buf .= ' / ' . $torrent->{'RemasterTitle'}) if $torrent->{'RemasterTitle'};                        
                        ($buf .= ' / ' . $torrent->{'GoldenPopcorn'}) if $torrent->{'GoldenPopcorn'} eq 'true';
                        my $sizeprint = get_SI_size($torrent->{'Size'});  
                        my $viewtext = '[DL]';
                        # attempt to note already downloaded movies. this has false postive matches
                        # todo compare sizes
                        my $releasename = $torrent->{'ReleaseName'};
                        say 'testing releasename ' . $releasename;                        
                        foreach my $dlmovie (@dlmovies) {                                                       
                            if($dlmovie eq $releasename) {
                                $viewtext = '[VIEW]';
                                say 'match with ' . $dlmovie;
                                last;     
                            }                        
                        }                       
                        $buf .= '<a href="torrent?ptpid=' . $torrent->{'Id'} . '">' . $viewtext . '</a></td><td>' . $torrent->{'UploadTime'} . '</td><td>' . $sizeprint . '</td><td>' . $torrent->{'Snatched'} . '</td><td>' .  $torrent->{'Seeders'} . '</td><td>' .  $torrent->{'Leechers'} . '</td></tr>';                    
                    }
                    $buf .= '<tbody></table><br>';                    
                }
                $qs->{'page'} ||= 1;
                if( $qs->{'page'} > 1) {
                    $buf .= '<a href="video?action=browsemovies&searchstr=' .  $qs->{'searchstr'} . '&page=1">' . ${escape_html('<<First')}  .'</a> |';
                    $buf .= '<a href="video?action=browsemovies&searchstr=' .  $qs->{'searchstr'} . '&page=' . ($qs->{'page'} - 1) . '">' . ${escape_html('<Prev')} . '</a>';                
                }
                if ($qs->{'page'} < $numpages) {
                    $buf .= '<a href="video?action=browsemovies&searchstr=' .  $qs->{'searchstr'} . '&page=' . ($qs->{'page'} + 1) . '">' . ${escape_html('Next>')} . '</a> |';                 
                    $buf .= '<a href="video?action=browsemovies&searchstr=' .  $qs->{'searchstr'} . '&page=' . $numpages . '">' . ${escape_html('Last>>')} . '</a>';                                    
                }
            }           
            $buf .= "</body>";
            $buf .= "</html>";  
            $request->SendLocalBuf($buf, "text/html");
        
        });   
        return;
    }   
    
    # action=library    
    $buf .= '<div id="medialist">';
    $qs->{'library'} //= 'all';
    $qs->{'library'} = lc($qs->{'library'});
    my @libraries = ('movies', 'tv', 'other');
    if($qs->{'library'} ne 'all') {
        @libraries = ($qs->{'library'});    
    }
    my %libraryprint = ( 'movies' => 'Movies', 'tv' => 'TV', 'other' => 'Other');
    foreach my $library (@libraries) {
        my $dir = $SETTINGS->{'MEDIALIBRARIES'}{$library};
        (-d $dir) or next;
        $buf .= "<h1>" . $libraryprint{$library} . "</h1>\n";        
        $temp = output_dir($dir, {
            'root' => $dir,
            'file_item_text' => \&video_file_item_text,
            'file_item_text_opt' => [$fmt],
            'min_file_size' => 100000          
        });
        $buf .= $$temp;   
    }
    
   
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

# returns the text of a video file item
sub video_file_item_text {
    my ($safe_item_basename, $item_path, $fmt) = @_;
    return '<a href="video?name=' . $item_path . '&fmt=' . $fmt . '" data-file="'. $item_path . '">' . $safe_item_basename . '</a>    <a href="get_video?name=' . $item_path . '&fmt=' . $fmt . '">DL</a>';
}

sub output_dir {
    my ($path, $options) = @_;
    # get the list of files and sort
    my $dir;
    if(! opendir($dir, $path)) {
        warn "outputdir: Cannot open directory: $path $!";
        return \"";
    }   
    my @files = sort { uc($a) cmp uc($b)} (readdir $dir);
    closedir($dir);
    # hide the root path if desired
    my $root = $options->{'root'};   
    my $unsafeDir = $path;    
    if($root) {
        #say "removing root : $root";    
        $unsafeDir =~ s/^$root(\/)?//;
        #say "dir after $unsafeDir";
    }
    # set what to do for each file
    $options->{'file_item_text'} //= sub {
        my ($safe_item_basename, $item_path) = @_;
        return '<a href="' . $item_path . '">' . $safe_item_basename . '</a>';     
    };
    $options->{'min_file_size'} //= 0;
    # finally generate the html
    my $buf =  "<ul>";    
    foreach my $file (@files) {
        if($file !~ /^..?$/) {
        my $safename = escape_html($file);            
            if(!(-d "$path/$file")) { 
                next if( (-s "$path/$file") < $options->{'min_file_size'});            
                my $unsafePath = $unsafeDir ? "$unsafeDir/$file" : $file;                
                my $data_file = escape_html($unsafePath);
                $buf .= '<li>' . $options->{'file_item_text'}->($$safename, $$data_file, @{$options->{'file_item_text_opt'}}) . '</li>';
            }
            else {
                $buf .= '<li>';
                $buf .= '<div class="row">';
                $buf .= '<a href="#' . $$safename . '_hide" class="hide" id="' . $$safename . '_hide">' . "$$safename</a>";
                $buf .= '<a href="#' . $$safename . '_show" class="show" id="' . $$safename . '_show">' . "$$safename</a>";                
                $buf .= '<div class="list">';
                my $tmp = output_dir("$path/$file", $options);              
                $buf .= $$tmp;
                $buf .= '</div></div>';
                $buf .= '</li>';
            }
        }   
    }
    $buf .= "</ul>";
    return \$buf;
}

sub output_dir_nonrecurse {
    my ($path, $options) = @_;
    
    # hide the root path if desired
    my $root = $options->{'root'};   
    
    
    # set what to do for each file
    $options->{'file_item_text'} //= sub {
        my ($safe_item_basename, $item_path) = @_;
        return '<a href="' . $item_path . '">' . $safe_item_basename . '</a>';     
    };
    $options->{'min_file_size'} //= 0;
    
    my $buf =  "<ul>"; 
    my @files;
    ON_DIR:    
    # get the list of files and sort
    my $dir;
    if(! opendir($dir, $path)) {
        warn "outputdir: Cannot open directory: $path $!";
        return \"";
    }  
    my @newfiles = sort { uc($a) cmp uc($b)} (readdir $dir); 
    closedir($dir); 
    my @newpaths = ();
    foreach my $file (@newfiles) {
        next if($file =~ /^..?$/);
        push @newpaths, "$path/$file";        
    }    
    @files = @files ? (@newpaths, undef, @files) : @newpaths;      
    while(@files)
    {        
        $path = shift @files;          
        if(! defined $path) {            
            $buf .= "</ul>";
            $buf .= '</div></div>';
            $buf .= '</li>';            
            next;
        }        
        my $file = basename($path);       
        my $safename = escape_html($file);                 
        if(-d $path) {            
            $buf .= '<li>';
            $buf .= '<div class="row">';
            $buf .= '<a href="#' . $$safename . '_hide" class="hide" id="' . $$safename . '_hide">' . "$$safename</a>";
            $buf .= '<a href="#' . $$safename . '_show" class="show" id="' . $$safename . '_show">' . "$$safename</a>";                
            $buf .= '<div class="list">';
            $buf .= '<ul>';
            goto ON_DIR;
        }
        my $unsafePath = $path;    
        if($root) {            
            $unsafePath =~ s/^$root(\/)?//;            
        }
        my $size = -s $path;
        if(! defined $size) {
            say "size  not defined path $path file $file";
            next;
        }
        next if( $size < $options->{'min_file_size'});   
        my $data_file = escape_html($unsafePath);
        $buf .= '<li>' . $options->{'file_item_text'}->($$safename, $$data_file, @{$options->{'file_item_text_opt'}}) . '</li>';    
    }    
    $buf .= "</ul>";
    return \$buf;    
 
}



}
1;

