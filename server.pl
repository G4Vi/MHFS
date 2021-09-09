#!/usr/bin/perl
package EventLoop::Poll::Linux::Timer {
    use strict; use warnings;
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use POSIX qw/floor/;
    use Devel::Peek;
    use feature 'say';
    use constant {
        _clock_REALTIME  => 0,
        _clock_MONOTONIC => 1,
        _clock_BOOTTIME  => 7,
        _clock_REALTIME_ALARM => 8,
        _clock_BOOTTIME_ALARM => 9,
     
        _ENOTTY => 25,  #constant for Linux?
    };
    # x86_64 numbers
    require 'syscall.ph';

    my $TFD_CLOEXEC = 0x80000;
    my $TFD_NONBLOCK = 0x800;     

    sub new {
        my ($class, $evp) = @_;
        say 'timerfd_create ' . SYS_timerfd_create();
        my $timerfd = syscall(SYS_timerfd_create(), _clock_MONOTONIC, $TFD_NONBLOCK | $TFD_CLOEXEC);       
        $timerfd != -1 or die("failed to create timerfd: $!");
        my $timerhandle = IO::Handle->new_from_fd($timerfd, "r");
        $timerhandle or die("failed to turn timerfd into a file handle"); 
        my %self = ('timerfd' => $timerfd, 'timerhandle' => $timerhandle);
        bless \%self, $class;

        $evp->set($self{'timerhandle'}, \%self, POLLIN);
        $self{'evp'} = $evp;
        return \%self;
    }

    sub packitimerspec {
       my ($times) = @_; 
       my $it_interval_sec  = int($times->{'it_interval'});
       my $it_interval_nsec = floor(($times->{'it_interval'} - $it_interval_sec) * 1000000000);
       my $it_value_sec = int($times->{'it_value'});
       my $it_value_nsec = floor(($times->{'it_value'} - $it_value_sec) * 1000000000);
       say "packing $it_interval_sec, $it_interval_nsec, $it_value_sec, $it_value_nsec";
       return pack 'qqqq', $it_interval_sec, $it_interval_nsec, $it_value_sec, $it_value_nsec;
   }

    sub settime_linux {
        my ($self, $start, $interval) = @_;
        # assume start 0 is supposed to run immediately not try to cancel a timer
        $start = ($start > 0.000000001) ? $start : 0.000000001;
        my $new_value = packitimerspec({'it_interval' => $interval, 'it_value' => $start});       
        say "timerfd_settime " . SYS_timerfd_settime();
        my $settime_success = syscall(SYS_timerfd_settime(), $self->{'timerfd'}, 0, $new_value,0);
        ($settime_success == 0) or die("timerfd_settime failed: $!");
    }

    sub onReadReady {
        my ($self) = @_;
        my $nread;
        my $buf;
        while($nread = sysread($self->{'timerhandle'}, $buf, 8)) {
            if($nread < 8) {
                say "timer hit, ignoring $nread bytes";
                next;
            }
            my $expirations = unpack 'Q', $buf;
            say "Linux::Timer there were $expirations expirations";
        }
        if(! defined $nread) {
            if( ! $!{EAGAIN}) {
                say "sysread failed with $!";
            }
            
        }
        $self->{'evp'}->check_timers;
        return 1;
    };
    
1;
};

# You must provide event handlers for the events you are listening for
# return undef to have them removed from poll's structures
package EventLoop::Poll {     
    use strict; use warnings;
    use feature 'say';
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use Scalar::Util qw(looks_like_number);
    use Data::Dumper;    
    use Devel::Peek;

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

    sub getEvents {
        my ($self, $handle) = @_;
        return $self->{'poll'}->mask($handle);
    }
    
    sub remove {
        my ($self, $handle) = @_;
        $self->{'poll'}->remove($handle);        
        $self->{'fh_map'}{$handle} = undef;          
    }

    
   sub _insert_timer {
       my ($self, $timer) = @_;
       my $i;
       for($i = 0; defined($self->{'timers'}[$i]) && ($timer->{'desired'} >= $self->{'timers'}[$i]{'desired'}); $i++) { }
       splice @{$self->{'timers'}}, $i, 0, ($timer);
       return $i;   
   }
   
    
    # all times are relative, is 0 is set as the interval, it will be run every main loop iteration
    # return undef in the callback to delete the timer
    sub add_timer {
        my ($self, $start, $interval, $callback) = @_;        
        my $current_time = clock_gettime(CLOCK_MONOTONIC);
        my $desired = $current_time + $start;
        my $timer = { 'desired' => $desired, 'interval' => $interval, 'callback' => $callback };    
        return _insert_timer($self, $timer);        
    }

    
    
    sub requeue_timers {
        my ($self, $timers, $current_time) = @_;
        foreach my $timer (@$timers) {
            $timer->{'desired'} = $current_time + $timer->{'interval'};
            _insert_timer($self, $timer);    
        }               
    }

    sub check_timers {
        my ($self) = @_;
        my @requeue_timers;
        my $timerhit = 0;
        my $current_time =  clock_gettime(CLOCK_MONOTONIC);            
        while(my $timer = shift (@{$self->{'timers'}})  ) {                
            if($current_time >= $timer->{'desired'}) {
                say "running timer";
                $timerhit = 1;
                if(defined $timer->{'callback'}->($timer, $current_time, $self)) { # callback may change interval
                    push @requeue_timers, $timer;                    
                }               
            }
            else {
                unshift @{$self->{'timers'}}, $timer;
                last;
            }                
        }
        if($timerhit) {
            $self->requeue_timers(\@requeue_timers, $current_time); 
        } 
    }

    sub do_poll {
        my ($self, $loop_interval, $poll) = @_;
        my $pollret = $poll->poll($loop_interval);
        if($pollret > 0){                             
            foreach my $handle ($poll->handles()) {
                my $revents = $poll->events($handle);
                my $obj = $self->{'fh_map'}{$handle};                    
                if($revents & POLLIN) { 
                    #say "read Ready " .$$;                                                                  
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
            }
    
        }
        elsif($pollret == 0) {
            #say "pollret == 0";
        }
        elsif(! $!{EINTR}){
            say "Poll ERROR $!";
            #return undef;
        }
    }   
   
    sub run {
        my ($self, $loop_interval) = @_;
        my $default_lp_interval = $loop_interval // -1;        
        my $poll = $self->{'poll'};    
        for(;;)
        {   
            check_timers($self);        
            print "do_poll $$";
            if($self->{'timers'}) {
                say " timers " . scalar(@{$self->{'timers'}});                    
            }
            else {
                print "\n";
            }  
            # we don't need to expire until a timer is expiring
            if(@{$self->{'timers'}}) {
                $loop_interval = $self->{'timers'}[0]{'desired'} - clock_gettime(CLOCK_MONOTONIC);
            }
            else {
                $loop_interval = $default_lp_interval;
            }         
            do_poll($self, $loop_interval, $poll);           
        }  
    }

    BEGIN {    
        use Config;
        say $Config{archname};
        if(index($Config{archname}, 'x86_64-linux') != -1) {
        #if(0) {
            say "LINUX_X86_64: enabling timerfd support";
            my $new_ = \&new;
            *new = sub {
                my $self = $new_->(@_);         
                $self->{'evp_timer'} = EventLoop::Poll::Linux::Timer->new($self);
                return $self;
            };
            
            my $add_timer_ = \&add_timer;
            *add_timer = sub {                
                my ($self, $start, $interval, $cb) = @_;
                if($add_timer_->($self, $start, $interval, $cb) == 0) {                   
                    say "add_timer, updating linux timer to $start";                
                    $self->{'evp_timer'}->settime_linux($start, 0);
                }
            };
    
            my $requeue_timers_ = \&requeue_timers;
            *requeue_timers = sub {
                $requeue_timers_->(@_);
                my ($self, $timers, $current_time) = @_;
                if(@{$self->{'timers'}}) {
                    my $start = $self->{'timers'}[0]{'desired'} - $current_time;
                    say "requeue_timers, updating linux timer to $start";
                    $self->{'evp_timer'}->settime_linux($start, 0);
                }                                   
            };
    
            *run = sub {
                my ($self, $loop_interval) = @_;
                $loop_interval //= -1;        
                my $poll = $self->{'poll'};    
                for(;;)
                {
                    print "do_poll LINUX_X86_64 $$";
                    if($self->{'timers'}) {
                        say " timers " . scalar(@{$self->{'timers'}});                    
                    }
                    else {
                        print "\n";
                    }                

                    do_poll($self, $loop_interval, $poll);           
                }
            };    
    
        }
        else {
            say "Not LINUX_X86_64, no timerfd support";
        }    
    }   

    1;
}

# bs = byte serving?
package HTTP::BS::Server {
    use strict; use warnings;
    use feature 'say';
    use IO::Socket::INET;
    use Socket qw(IPPROTO_TCP TCP_KEEPALIVE TCP_NODELAY);
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Scalar::Util qw(weaken);
    use Data::Dumper;
    use Config;
   
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
        
        # leaving Nagle's algorithm enabled for now as sometimes headers are sent without data
        #$sock->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1) or die("Failed to set TCP_NODELAY");
        
        # linux specific settings. Check in BEGIN?
        if(index($Config{osname}, 'linux') != -1) {
            use Socket qw(TCP_QUICKACK);
            $sock->setsockopt(IPPROTO_TCP, TCP_QUICKACK, 1) or die("Failed to set TCP_QUICKACK");
        }
        my $evp = EventLoop::Poll->new;
        my %self = ( 'settings' => $settings, 'routes' => $routes, 'route_default' => pop @$routes, 'plugins' => $plugins, 'sock' => $sock, 'evp' => $evp, 'uploaders' => []);
        bless \%self, $class;

        $evp->set($sock, \%self, POLLIN);

        # load the plugins        
        foreach my $plugin (@{$plugins}) {
        
            foreach my $timer (@{$plugin->{'timers'}}) {
                say 'plugin(' . ref($plugin) . '): adding timer';                              
                $self{'evp'}->add_timer(@{$timer});                                                
            }
            if(my $func = $plugin->{'uploader'}) {
                say 'plugin(' . ref($plugin) . '): adding uploader';
                push (@{$self{'uploaders'}}, $func);
            }
            foreach my $route (@{$plugin->{'routes'}}) {
                say 'plugin(' . ref($plugin) . '): adding route ' . $route->[0];
                push @{$self{'routes'}}, $route;                
            }
            $plugin->{'server'} = \%self;             
        }            
        
        $evp->run();
        
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
        my $MAX_TIME_WITHOUT_SEND = 30;
        #my $MAX_TIME_WITHOUT_SEND = 5;
        #my $MAX_TIME_WITHOUT_SEND = 600;
        my $cref = HTTP::BS::Server::Client->new($csock, $server);
               
        #$server->{'evp'}->set($csock, $cref, POLLIN | $EventLoop::Poll::ALWAYSMASK);    

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
    
    1;
}

package HTTP::BS::Server::Util {
    use strict; use warnings;
    use feature 'say';
    use Exporter 'import';
    use File::Find;
    use File::Basename;
    use POSIX ();
    use Cwd qw(abs_path getcwd);
    our @EXPORT = ('LOCK_GET_LOCKDATA', 'LOCK_WRITE', 'UNLOCK_WRITE', 'write_file', 'read_file', 'shellcmd_unlock', 'ASYNC', 'FindFile', 'space2us', 'escape_html', 'function_exists', 'shell_stdout', 'shell_escape', 'ssh_stdout', 'pid_running', 'escape_html_noquote', 'output_dir_versatile', 'do_multiples', 'getMIME');
    # single threaded locks
    sub LOCK_GET_LOCKDATA {
        my ($filename) = @_;
        my $lockname = "$filename.lock";    
        my $bytes = read_file($lockname);
        if(! defined $bytes) {
            return undef;
        }
        return $bytes;
    }

    #sub LOCK_GET_FILESIZE {
    #    my ($filename) = @_; 
    #    my $lockedfilesize = LOCK_GET_LOCKDATA($filename);
    #    if(defined $lockedfilesize) {
    #        
    #    }
    #}

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
        unlink($lockname);
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
            #exit 0;
            POSIX::_exit(0);
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

    sub escape_html_noquote {
        my ($string) = @_;
        my %dangerchars = ('<' => '&lt;', '>' => '&gt;');
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
        print "shell_stdout (BLOCKING): ";
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

    sub output_dir_versatile {
        my ($path, $options) = @_;
        # hide the root path if desired
        my $root = $options->{'root'};  
        $options->{'min_file_size'} //= 0;
    
        my @files;
        ON_DIR:    
        # get the list of files and sort
        my $dir;
        if(! opendir($dir, $path)) {
            warn "outputdir: Cannot open directory: $path $!";
            return;
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
                $options->{'on_dir_end'}->() if($options->{'on_dir_end'});
                next;
            }
            my $file = basename($path);              
            if(-d $path) {
                $options->{'on_dir_start'}->($path, $file) if($options->{'on_dir_start'});
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
            $options->{'on_file'}->($path, $unsafePath, $file) if($options->{'on_file'});  
        }
        return;
    }

    # perform multiple async actions at the same time.
    # continue on with $result_func on failure or completion of all actions
    sub do_multiples {
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

    sub getMIME {
        my ($filename) = @_;
        
        my %audioexts = ( 'mp3' => 'audio/mp3', 
            'flac' => 'audio/flac',
            'opus' => 'audio',
            'ogg'  => 'audio/ogg');
    
        my %videoexts = ('mp4' => 'video/mp4',
            'mkv'  => 'video/mp4',
            'ts'   => 'video/mp2t',
            'mkv'  => 'video/x-matroska',
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
            'wasm'  => 'application/wasm',
            'css' => 'text/css');
    
        
    
        my ($ext) = $filename =~ /\.([^.]+)$/;
    
        my %combined = (%audioexts, %videoexts, %otherexts);
        return $combined{$ext} if defined($combined{$ext});    
        
        say "getMIME (BLOCKING)";
        # we shouldn't need a process to determine the mime type ...
        if(open(my $filecmd, '-|', 'file', '-b', '--mime-type', $filename)) {
            my $mime = <$filecmd>;
            chomp $mime;        
            return $mime;
        }
        return 'text/plain';
    }
    1;
}

package HTTP::BS::Server::Client::Request {
    HTTP::BS::Server::Util->import();
    use strict; use warnings;
    use feature 'say';
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use URI::Escape;
    use Cwd qw(abs_path getcwd);
    use File::Basename;
    use File::stat;
    use IO::Poll qw(POLLIN POLLOUT POLLHUP);
    use Data::Dumper;
    use Scalar::Util qw(weaken);
    use List::Util qw[min max];
    use Symbol 'gensym';
    use Devel::Peek;
    use constant {
        MAX_REQUEST_SIZE => 8192,
    };

    sub new {
        my ($class, $client) = @_;        
        my %self = ( 'client' => $client);
        bless \%self, $class;
        weaken($self{'client'}); #don't allow Request to keep client alive
        $self{'on_read_ready'} = \&want_request_line;
        $self{'outheaders'}{'X-MHFS-CONN-ID'} = $client->{'outheaders'}{'X-MHFS-CONN-ID'};      
        $self{'rl'} = 0;
        # we want the request
        $client->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK );        
        return \%self;
    }

    # on ready ready handlers
    sub want_request_line {
        my ($self) = @_;
        
        my $ipos = index($self->{'client'}{'inbuf'}, "\r\n");
        if($ipos != -1) {
            if(substr($self->{'client'}{'inbuf'}, 0, $ipos+2, '') =~ /^(([^\s]+)\s+([^\s]+)\s+(?:HTTP\/1\.([0-1])))\r\n/) {
                my $rl = $1;
                $self->{'method'}    = $2;                
                $self->{'uri'}       = $3;
                $self->{'httpproto'} = $4;                                
                $self->{'outheaders'}{'X-MHFS-REQUEST-ID'} = clock_gettime(CLOCK_MONOTONIC) * rand(); # BAD UID
                say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . " X-MHFS-REQUEST-ID: " . $self->{'outheaders'}{'X-MHFS-REQUEST-ID'};
                say "RECV: $rl";
                if(($self->{'method'} ne 'GET') && ($self->{'method'} ne 'HEAD') && ($self->{'method'} ne 'PUT')) {
                    say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . 'Invalid method: ' . $self->{'method'}. ', closing conn';
                    return undef;
                }
                my ($path, $querystring) = ($self->{'uri'} =~ /^([^\?]+)(?:\?)?(.*)$/g);             
                say("raw path: $path\nraw querystring: $querystring");
                my $serversettings = $self->{'client'}{'server'}{'settings'};
                #transformations
                $path = uri_unescape($path);
                my %pathStruct = ( 'unescapepath' => $path );
                $path =~ s/(?:\/|\\)+$//;
                print "path: $path ";                    
                say "querystring: $querystring";                     
                #parse path                     
                $pathStruct{'unsafepath'} = $path;
                my $abspath = abs_path($serversettings->{'DOCUMENTROOT'} . $path);                  
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
                $self->{'path'} = \%pathStruct;
                $self->{'qs'} = \%qsStruct;


                $self->{'on_read_ready'} = \&want_headers;
                #return want_headers($self);
                goto &want_headers;
            }
            else {
                say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . ' Invalid Request line, closing conn';
                return undef;
            }            
        }
        elsif(length($self->{'client'}{'inbuf'}) > MAX_REQUEST_SIZE) {
            say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . ' No Request line, closing conn';
            return undef;
        }
        return 1;
    }

    sub want_headers {
        my ($self) = @_;
        my $ipos;
        while($ipos = index($self->{'client'}{'inbuf'}, "\r\n")) {                
            if($ipos == -1) {
                if(length($self->{'client'}{'inbuf'}) > MAX_REQUEST_SIZE) {
                    say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . ' Headers too big, closing conn';
                    return undef;
                }
                return 1;
            }                
            elsif(substr($self->{'client'}{'inbuf'}, 0, $ipos+2, '') =~ /^(([^:]+):\s*(.*))\r\n/) {
                say "RECV: $1";
                $self->{'header'}{$2} = $3;            
            }
            else {                
                say "X-MHFS-CONN-ID: " . $self->{'outheaders'}{'X-MHFS-CONN-ID'} . ' Invalid header, closing conn';
                return undef;
            }        
        }
        # when $ipos is 0 we recieved the end of the headers: \r\n\r\n
        if((defined $self->{'header'}{'Range'}) &&  ($self->{'header'}{'Range'} =~ /^bytes=([0-9]+)\-([0-9]*)$/)) {            
            $self->{'header'}{'_RangeStart'} = $1;
            $self->{'header'}{'_RangeEnd'} = ($2 ne  '') ? $2 : undef;      
        }
        substr($self->{'client'}{'inbuf'}, 0, 2, '');
        $self->{'on_read_ready'} = undef;
        $self->{'client'}->SetEvents($EventLoop::Poll::ALWAYSMASK );  
        # finally handle the request
        #_Handle($self);  
        foreach my $route (@{$self->{'client'}{'server'}{'routes'}}) {                        
            if($self->{'path'}{'unsafepath'} eq $route->[0]) {
                $route->[1]($self);
                return 1;
            }
            else {
                # wildcard ending
                next if(rindex($route->[0], '*') != (length($route->[0])-1));
                next if(rindex($self->{'path'}{'unsafepath'}, substr($route->[0], 0, -1)) != 0);
                $route->[1]($self);
                return 1;
            }
        }
        $self->{'client'}{'server'}{'route_default'}($self);     
        return 1;
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

    sub _ReqDataLength {
        my ($self, $datalength) = @_;
        $datalength //= 99999999999;
        my $end =  $self->{'header'}{'_RangeEnd'} // ($datalength-1);
        my $dl = $end+1;
        say "_ReqDataLength returning: $dl";   
        return $dl;
    }
    
    sub _SendDataItem {
        my ($self, $dataitem, $opt) = @_;
        my $size  = $opt->{'size'};
        my $start =  $self->{'header'}{'_RangeStart'};
        my $end =  $self->{'header'}{'_RangeEnd'};        
        my $isrange = defined $start;
        my $code;
        my $contentlength;      
        if($isrange) {
            if(defined $end) {
                $contentlength = $end - $start + 1;
            }
            elsif(defined $size) {
                say 'Implicitly setting end to size';
                $end = $size - 1;
                $contentlength = $end - $start + 1;
            }
            # no end and size unknown. we have 4 choices:
            # set end to the current end (the satisfiable range on RFC 7233 2.1). Dumb clients don't attempt to request the rest of the data ...
            # send non partial response (200). This will often disable range requests.
            # send multipart. "A server MUST NOT generate a multipart response to a request for a single range"(RFC 7233 4.1) guess not
            
            # LIE, use a large value to signify infinite size. RFC 8673 suggests doing so when client signifies it can.
            # Current clients don't however, so lets hope they can. 
            else {
                say 'Implicitly setting end to 999999999999 to signify unknown end';
                $end = 999999999999;
            }            
            
            if($end < $start) {
                say "_SendDataItem, end < start";
                $self->Send403();
                return;                
            }
            $code = 206;
            $self->{'outheaders'}{'Content-Range'} = "bytes $start-$end/" . ($size // '*');          
        }
        else {
            $code = 200;
            $contentlength = $size;
        }

        # if the CL isn't known we need to sent chunked        
        if(! defined $contentlength) {
            $self->{'outheaders'}{'Transfer-Encoding'} = 'chunked';         
        }
        else {
            $self->{'outheaders'}{'Content-Length'} = "$contentlength";   
        }        
        
        my $mime     = $opt->{'mime'};
        my $filename = $opt->{'filename'};
        my $fullpath = $opt->{'fullname'};
        my %lookup = (
            200 => "HTTP/1.1 200 OK\r\n",
            206 => "HTTP/1.1 206 Partial Content\r\n",
            301 => "HTTP/1.1 301 Moved Permanently\r\n",
            307 => "HTTP/1.1 307 Temporary Redirect\r\n",
            403 => "HTTP/1.1 403 Forbidden\r\n",
            404 => "HTTP/1.1 404 File Not Found\r\n",
            416 => "HTTP/1.1 416 Range Not Satisfiable\r\n",
        );
        
        my $headtext = $lookup{$code};
        if(!$headtext) {
            say "_SendDataItem, bad code $code";
            $self->Send403();
            return;            
        }
        $headtext .=   "Content-Type: $mime\r\n";
        $headtext .=   'Content-Disposition: inline; filename="' . $filename . "\"\r\n" if ($filename);
        $self->{'outheaders'}{'Accept-Ranges'} //= 'bytes';       
        $self->{'outheaders'}{'Connection'} //= $self->{'header'}{'Connection'};
        $self->{'outheaders'}{'Connection'} //= 'keep-alive';
        
        # SharedArrayBuffer
        if($fullpath) {
            my @SABpaths = ('static/music_worklet/index.html', 'static/music_worklet_inprogress/index.html');
            foreach my $sabpath (@SABpaths) {
                if($fullpath =~ /\Q$sabpath\E$/) {
                    say "sending SAB headers";
                    $self->{'outheaders'}{'Cross-Origin-Opener-Policy'} =  'same-origin';
                    $self->{'outheaders'}{'Cross-Origin-Embedder-Policy'} = 'require-corp';
                    last;
                }
            }           
        }        

        # serialize the outgoing headers
        foreach my $header (keys %{$self->{'outheaders'}}) {
            $headtext .= "$header: " . $self->{'outheaders'}{$header} . "\r\n";
        }       
        
        $headtext .= "\r\n";
        $dataitem->{'buf'} = $headtext;        
        $self->_SendResponse($dataitem);      
    }   

    sub _SendResponse {
        my ($self, $fileitem) = @_;        
        if(utf8::is_utf8($fileitem->{'buf'})) {
            warn "_SendResponse: UTF8 flag is set, turning off";
            Encode::_utf8_off($fileitem->{'buf'});
        }
        if($self->{'outheaders'}{'Transfer-Encoding'} && ($self->{'outheaders'}{'Transfer-Encoding'} eq 'chunked')) {
            say "chunked response";
            $fileitem->{'is_chunked'} = 1;
        }


        $self->{'response'} = $fileitem;
        $self->{'client'}->SetEvents(POLLOUT | $EventLoop::Poll::ALWAYSMASK );        
    }

    sub Send403 {
        my ($self) = @_;
        my $client = $self->{'client'};
        my $data = "HTTP/1.1 403 Forbidden\r\n";        
        my $mime = getMIME('.html');
        $data .= "Content-Type: $mime\r\n";
        if($self->{'header'}{'Connection'} && ($self->{'header'}{'Connection'} eq 'close')) {
            $data .= "Connection: close\r\n";
            $self->{'outheaders'}{'Connection'} = 'close';
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
        my $mime = getMIME('.html');
        $data .= "Content-Type: $mime\r\n";
        if($self->{'header'}{'Connection'} && ($self->{'header'}{'Connection'} eq 'close')) {
            $data .= "Connection: close\r\n";
            $self->{'outheaders'}{'Connection'} = 'close';
        }
        my $msg = "404 Not Found\r\n";
        $data .= "Content-Length: " . length($msg) . "\r\n";
        $data .= "\r\n";
        $data .= $msg;
        my %fileitem = ( buf => $data);
        $self->_SendResponse(\%fileitem);       
    }

    sub Send503 {
        my ($self) = @_;
        my $client = $self->{'client'};
        my $data = "HTTP/1.1 503 Service Unavailable\r\n";
        my $mime = getMIME('.html');
        $data .= "Content-Type: $mime\r\n";
        $data .= "Retry-After: 5\r\n";
        if($self->{'header'}{'Connection'} && ($self->{'header'}{'Connection'} eq 'close')) {
            $data .= "Connection: close\r\n";
            $self->{'outheaders'}{'Connection'} = 'close';
        }
        my $msg = "503 Service Unavailable\r\n";
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

    sub Send416 {
        my ($self, $cursize) = @_;
        my $buf = "HTTP/1.1 416 Range Not Satisfiable\r\n";
        $buf .= "Content-Range: */$cursize\r\n";
        $buf .= "Content-Length: 0\r\n";
        $buf .= "\r\n";
        my %fileitem = ('buf' => $buf);
        $self->_SendResponse(\%fileitem);
    }    

    sub SendLocalFile {
        my ($self, $requestfile) = @_;
        my $start =  $self->{'header'}{'_RangeStart'};                 
        my $client = $self->{'client'};
        
        my %fileitem = ('requestfile' => $requestfile);
        my $FH;          
        if(! open($FH, "<", $requestfile)) {
            $self->Send404;
            return;
        }
        
        binmode($FH);
        my $st = stat($FH);
        if(! $st) {
            $self->Send404();
            return;
        }
        my $currentsize = $st->size;
        # seek if a start is specified
        if(defined $start) {
            if($start >= $currentsize) {
                $self->Send416($currentsize);
                return;
            }
            seek($FH, $start, 0); 
        }            
        $fileitem{'fh'} = $FH;
            

   
        my $ts;
        my $get_file_size_locked = sub {
            if(! defined $ts) {
                my $locksz = LOCK_GET_LOCKDATA($requestfile);
                if(defined $locksz) { 
                    #say "get_current_length locksize: $locksz";
                    return ($locksz || 0);
                }                
                my $ist = stat($FH);
                $ts = $ist ? $ist->size : 0;
                say "no longer locked: $ts";
            }
            return $ts;            
        };       
        
        my $get_read_filesize = sub {
            my $maxsize = $get_file_size_locked->();
            if(defined $self->{'header'}{'_RangeEnd'}) {
                my $rangesize = $self->{'header'}{'_RangeEnd'}+1;
                return $rangesize if($rangesize <= $maxsize);                 
            }
            return $maxsize;            
        };        
        
        my $filelength = $get_file_size_locked->();
        
        # truncate the end to the read filesize        
        if(defined $self->{'header'}{'_RangeEnd'}) {
            $self->{'header'}{'_RangeEnd'} = min($filelength-1,  $self->{'header'}{'_RangeEnd'});           
        }
        
        # set function to retrieve the read filesize
        $fileitem{'get_current_length'} = $get_read_filesize;
        
        # set file length
        if($filelength == 99999999999) {
            $filelength = undef;        
        }
        
        # Get the file size if possible
        #my $filelength = LOCK_GET_LOCKDATA($requestfile);        
        #$filelength //= $currentsize;
        ## set how far we're going to read        
        #$fileitem{'length'} = $self->_ReqDataLength($filelength);
               
         
        # build the header based on whether we are sending a full response or range request    
        my $mime = getMIME($requestfile);
        $self->_SendDataItem(\%fileitem, {
           'size'     => $filelength, 
           'mime'     => $mime,
           'filename' => basename($requestfile),
           'fullname'    => $requestfile,          
        });       
    }

    # currently only supports fixed filelength
    sub SendPipe {
        my ($self, $FH, $filename, $filelength, $mime) = @_;
        if(! defined $filelength) {
            $self->Send404();
        }

        $mime //= getMIME($filename);
        binmode($FH);
        my %fileitem;
        $fileitem{'fh'} = $FH;
        $fileitem{'get_current_length'} = sub {
            my $tocheck = defined $self->{'header'}{'_RangeEnd'} ? $self->{'header'}{'_RangeEnd'}+1 : $filelength;
            return min($filelength, $tocheck);
        };

        $self->_SendDataItem(\%fileitem, {
           'size'     => $filelength, 
           'mime'     => $mime,
           'filename' => $filename         
        });        
    }

    # to do get rid of shell escape, launch ssh without blocking
    sub SendFromSSH {
        my ($self, $sshsource, $filename, $node) = @_; 
        my @sshcmd = ('ssh', $sshsource->{'userhost'}, '-p', $sshsource->{'port'}); 
        my $fullescapedname = "'" . shell_escape($filename) . "'";   
        my $folder = $sshsource->{'folder'};   
        my $size = $node->[1];
        my @cmd;
        if(defined $self->{'header'}{'_RangeStart'}) {
            my $start = $self->{'header'}{'_RangeStart'};
            my $end = $self->{'header'}{'_RangeEnd'} // ($size - 1);
            my $bytestoskip =  $start;
            my $count = $end - $start + 1;
            @cmd = (@sshcmd, 'dd', 'skip='.$bytestoskip, 'count='.$count, 'bs=1', 'if='.$fullescapedname);
        }
        else{
            @cmd = (@sshcmd, 'cat', $fullescapedname);
        }
        say "SendFromSSH (BLOCKING)";
        open(my $cmdh, '-|', @cmd) or die("SendFromSSH $!");
        
        $self->SendPipe($cmdh, basename($filename), $size);            
        return 1;       
    }

    # using curl would be better than netcat for https
    # BROKEN
    sub Proxy {
        my ($self, $proxy, $node) = @_;
        my $requesttext = '';
        my @lines = split('\r\n', $requesttext);
        my @outlines = (shift @lines);
        #$outlines[0] =~ s/^(GET|HEAD)\s+$webpath\/?/$1 \//;        
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
        my ($self, $buf, $mime, $options) = @_;

        # TODO less copying
        
        # we want to sent in increments of bytes not characters
        if(utf8::is_utf8($buf)) {
            warn "SendLocalBuf: UTF8 flag is set, turning off";
            Encode::_utf8_off($buf);
        }

        my $bytesize = length($buf);

        my $start =  $self->{'header'}{'_RangeStart'} // 0;
        my $end   =  $self->{'header'}{'_RangeEnd'}  // $bytesize-1;        
        $buf      =  substr($buf, $start, ($end-$start) + 1);
        
        my %fileitem;
        $fileitem{'localbuf'} = $buf;
        $self->_SendDataItem(\%fileitem, {
           'size'     => $bytesize,
           'mime'     => $mime,
           'filename' => $options->{'filename'}            
        });
    }
    
    sub SendCallback {
        my ($self, $callback, $options) = @_; 
        my %fileitem;
        $fileitem{'cb'} = $callback;

        $self->_SendDataItem(\%fileitem, {
           'size'     => $options->{'size'},
           'mime'     => $options->{'mime'},
           'filename' => $options->{'filename'}            
        });           
    }
    
    sub SendAsTar {
        my ($self, $requestfile) = @_;
        say "tarsize $requestfile";
        # HACK, use LD_PRELOAD to hook tar to calculate the size quickly
        my @tarcmd = ('tar', '-C', dirname($requestfile), basename($requestfile), '-c', '--owner=0', '--group=0');
        $self->{'process'} =  HTTP::BS::Server::Process->new(\@tarcmd, $self->{'client'}{'server'}{'evp'}, { 
            'SIGCHLD' => sub {
                my $out = $self->{'process'}{'fd'}{'stdout'}{'fd'};
                my $size;
                read($out, $size, 50);
                chomp $size;                
                say "size: $size";                
                $self->{'process'} = HTTP::BS::Server::Process->new(\@tarcmd, $self->{'client'}{'server'}{'evp'}, { 
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
                        my %fileitem = ('fh' => $out, 'buf' => $header, 'get_current_length' => sub { return undef });
                        $self->_SendResponse(\%fileitem); 
                        return 0;
                    }                
                });
            },                      
        },        
        undef, # fd settings
        {
            'LD_PRELOAD' => $self->{'client'}{'server'}{'settings'}{'APPDIR'}.'/tarsize/tarsize.so'
        });
    }
    
    sub PUTBuf_old {
        my ($self, $handler) = @_;
        if(length($self->{'client'}{'inbuf'}) < $self->{'header'}{'Content-Length'}) {
            $self->{'client'}->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK ); 
        }
        my $sdata;
        $self->{'on_read_ready'} = sub {
            my $contentlength = $self->{'header'}{'Content-Length'};
            $sdata .= $self->{'client'}{'inbuf'};
            my $dlength = length($sdata);                                       
            if($dlength >= $contentlength) {
                say 'PUTBuf datalength ' . $dlength;
                my $data;
                if($dlength > $contentlength) {
                    $data = substr($sdata, 0, $contentlength);
                    $self->{'client'}{'inbuf'} = substr($sdata, $contentlength);
                    $dlength = length($data)
                }
                else {
                    $data = $sdata;
                    $self->{'client'}{'inbuf'} = '';
                }
                $self->{'on_read_ready'} = undef;
                $handler->($data);
            }
            else {
                $self->{'client'}{'inbuf'} = '';
            }
            #return '';
            return 1;
        };
        $self->{'on_read_ready'}->();
    }
    
    sub PUTBuf {
        my ($self, $handler) = @_;
        if($self->{'header'}{'Content-Length'} > 20000000) {
            say "PUTBuf too big";
            $self->{'client'}->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK );
            $self->{'on_read_ready'} = sub { return undef };
            return;
        }
        if(length($self->{'client'}{'inbuf'}) < $self->{'header'}{'Content-Length'}) {
            $self->{'client'}->SetEvents(POLLIN | $EventLoop::Poll::ALWAYSMASK ); 
        }       
        $self->{'on_read_ready'} = sub {
            my $contentlength = $self->{'header'}{'Content-Length'};           
            my $dlength = length($self->{'client'}{'inbuf'});                                       
            if($dlength >= $contentlength) {
                say 'PUTBuf datalength ' . $dlength;
                my $data;
                if($dlength > $contentlength) {
                    $data = substr($self->{'client'}{'inbuf'}, 0, $contentlength, '');                    
                }
                else {
                    $data = $self->{'client'}{'inbuf'};
                    $self->{'client'}{'inbuf'} = '';
                }
                $self->{'on_read_ready'} = undef;
                $handler->($data);
            }            
            return 1;
        };
        $self->{'on_read_ready'}->();
    }

    # TODO, check plugins for SendOption
    sub SendFile {
        my ($self, $requestfile) = @_;
        foreach my $uploader (@{$self->{'client'}{'server'}{'uploaders'}}) {
            return if($uploader->($self, $requestfile));
        }
        say "SendFile - SendLocalFile $requestfile";
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

    sub new {
        my ($class, $sock, $server) = @_;
        $sock->blocking(0);
        my %self = ('sock' => $sock, 'server' => $server, 'time' => clock_gettime(CLOCK_MONOTONIC), 'inbuf' => '');
        $self{'outheaders'}{'X-MHFS-CONN-ID'} = $self{'time'} * rand(); # BAD UID
        bless \%self, $class;
        $self{'request'} = HTTP::BS::Server::Client::Request->new(\%self);      
        return \%self;
    }

    sub SetEvents {
        my ($self, $events) = @_;
        $self->{'server'}{'evp'}->set($self->{'sock'}, $self, $events);            
    }
    
    use constant {
         RECV_SIZE => 65536     
    }; 

    sub do_on_data {
        my ($self) = @_;
        my $res = $self->{'request'}{'on_read_ready'}->($self->{'request'});
        if($res) {
            if(defined $self->{'request'}{'response'}) {
                #say "do_on_data: goto onWriteReady";
                goto &onWriteReady;
                #return onWriteReady($self);
            }
            #else {
            elsif(defined $self->{'request'}{'on_read_ready'}) {
                #say "do_on_data: goto onReadReady inbuf " . length($self->{'inbuf'});
                goto &onReadReady;
                #return onReadReady($self);
            }
            else {
                say "do_on_data: response and on_read_ready not defined, response by timer or poll?"; 
            }
        }
        return $res;
    }

     
    sub onReadReady {        
        my ($self) = @_;             
        my $tempdata;        
        if(defined($self->{'sock'}->recv($tempdata, RECV_SIZE))) {
            if(length($tempdata) == 0) {                
                say 'Server::Client read 0 bytes, client read closed';
                return undef;
            }
            $self->{'inbuf'} .= $tempdata;
            goto &do_on_data;
        }
        if(! $!{EAGAIN}) {                
            print ("HTTP::BS::Server::Client onReadReady RECV errno: $!\n");
            return undef;          
        }
        return '';        
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
                if($client->{'request'}{'outheaders'}{'Connection'} && ($client->{'request'}{'outheaders'}{'Connection'} eq 'close')) {
                    say "Connection close header set closing conn";
                    say "-------------------------------------------------";                               
                    return undef;              
                }
                $client->{'request'} = HTTP::BS::Server::Client::Request->new($client);
                # handle possible existing read data 
                goto &do_on_data;                
            }            
        }
        else {             
            say "response not defined, probably set later by a timer or poll";                     
        }        
        return 1;        
    }

    sub _TSRReturnPrint {
        my ($sentthiscall) = @_;
        if($sentthiscall > 0) {
            say "wrote $sentthiscall bytes";
        }
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
            $bytesToSend = length $buf;        
        }        
        my $sentthiscall = 0;
        do {
            # Try to send the buf if set
            if(defined $buf) {            
                my $remdata = TrySendItem($csock, $buf, $bytesToSend);                     
                
                # critical conn error
                if(! defined($remdata)) {
                    _TSRReturnPrint($sentthiscall);
                    return undef;
                }
                
                # update the number of bytes sent
                $sentthiscall += $bytesToSend - length($remdata); 
                
                # only update the time if we actually sent some data
                if($remdata ne $buf) {
                    $client->{'time'} = clock_gettime(CLOCK_MONOTONIC);
                }
                # eagain or not all data sent
                if($remdata ne '') {
                    $dataitem->{'buf'} = $remdata;
                    _TSRReturnPrint($sentthiscall);                                        
                    return '';
                }
                #we sent the full buf                             
                $buf = undef;                                
            }

            if(defined $dataitem->{'localbuf'}) {
                $buf = $dataitem->{'localbuf'};
                $dataitem->{'localbuf'} = undef;
            }
            elsif(defined $dataitem->{'fh'}) {     
                #try to grab a buf from the file         
                my $FH = $dataitem->{'fh'};                
                #my $req_length = $dataitem->{'length'}; # if the file is still locked/we haven't checked for it yet it will be 99999999999 
                my $req_length = $dataitem->{'get_current_length'}->();               
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
                            say 'FH EOF ' .$filepos;
                            seek($FH, 0, 1);
                            _TSRReturnPrint($sentthiscall);                       
                            return '';
                        }
                    }                                                                              
                }                
            }
            elsif(defined $dataitem->{'cb'}) {
                $buf = $dataitem->{'cb'}->($dataitem);
                $bytesToSend = length $buf;                
            }

            # chunked encoding
            if($dataitem->{'is_chunked'}) {
                if(! $buf) {
                    say "chunk done";
                    $buf = '';
                    $dataitem->{'is_chunked'} = undef;
                    $dataitem->{'fh'} = undef;
                    $dataitem->{'cb'} = undef;
                }                 
                
                #say "chunk with size: " . length($buf);
                my $sizeline = sprintf "%X\r\n", length($buf);
                $buf = $sizeline.$buf."\r\n"; 
            }                  
        } while(defined $buf);        
        $client->{'request'}{'response'} = undef;   
            
        _TSRReturnPrint($sentthiscall);
        say "DONE Sending Data";
        return 'RequestDone'; # not undef because keep-alive
    }
    
    sub TrySendItem {
        my ($csock, $data, $n) = @_;
        my $total = $n;
        my $sret;        
        # croaks when peer is no longer connected
        #$sret = eval { return $csock->send($data, MSG_DONTWAIT); };
        #if ($@) {
        #    warn "func blew up: $@";
        #    print "send errno $!\n";
        #    return undef;       
        #}
        #$sret = $csock->send($data, MSG_DONTWAIT);
        $sret = send($csock, $data, MSG_DONTWAIT);       
        #if(! defined($sret = $csock->send($data, MSG_DONTWAIT))) { 
        if(! defined($sret)) {           
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
            return $data;   
        }
        else {
            # success we sent everything       
            return '';      
        }   
    }
    
    sub onHangUp {
        my ($client) = @_;        
        return undef;    
    }

    sub DESTROY {
        my $self = shift;
        say "$$ HTTP::BS::Server::Client destructor: ";
        say "$$ ".'X-MHFS-CONN-ID: ' . $self->{'outheaders'}{'X-MHFS-CONN-ID'};
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
    use Devel::Peek;

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

    sub _setup_handlers {
        my ($self, $in, $out, $err, $fddispatch, $handlesettings) = @_;
        my $pid = $self->{'pid'};
        my $evp = $self->{'evp'};

        if($fddispatch->{'SIGCHLD'}) {
            say "PID $pid custom SIGCHLD handler";
            $CHILDREN{$pid} = $fddispatch->{'SIGCHLD'};            
        }    
        if($fddispatch->{'STDIN'}) {            
            $self->{'fd'}{'stdin'} = HTTP::BS::Server::FD::Writer->new($self, $in, $fddispatch->{'STDIN'});
            $evp->set($in, $self->{'fd'}{'stdin'}, POLLOUT | $EventLoop::Poll::ALWAYSMASK);                       
        }
        else {                       
            $self->{'fd'}{'stdin'}{'fd'} = $in;        
        }
        if($fddispatch->{'STDOUT'}) {        
            $self->{'fd'}{'stdout'} = HTTP::BS::Server::FD::Reader->new($self, $out, $fddispatch->{'STDOUT'}); 
            $evp->set($out, $self->{'fd'}{'stdout'}, POLLIN | $EventLoop::Poll::ALWAYSMASK);            
        }
        else {
            $self->{'fd'}{'stdout'}{'fd'} = $out;        
        }
        if($fddispatch->{'STDERR'}) {
            $self->{'fd'}{'stderr'} = HTTP::BS::Server::FD::Reader->new($self, $err, $fddispatch->{'STDERR'});
            $evp->set($err, $self->{'fd'}{'stderr'}, POLLIN | $EventLoop::Poll::ALWAYSMASK);       
        }
        else {
            $self->{'fd'}{'stderr'}{'fd'} = $err;
        }

        if($handlesettings->{'O_NONBLOCK'}) {
            my $flags = 0;
            # stderr
            (0 == fcntl($err, Fcntl::F_GETFL, $flags)) or die;#return undef;
            $flags |= Fcntl::O_NONBLOCK;
            (0 == fcntl($err, Fcntl::F_SETFL, $flags)) or die;#return undef;
            # stdout
            (0 == fcntl($out, Fcntl::F_GETFL, $flags)) or die;#return undef;
            $flags |= Fcntl::O_NONBLOCK;
            (0 == fcntl($out, Fcntl::F_SETFL, $flags)) or die;#return undef;
            return $self;
        }
    }    
    
    sub new {
        my ($class, $torun, $evp, $fddispatch, $handlesettings, $env) = @_;        
        my %self = ('time' => clock_gettime(CLOCK_MONOTONIC), 'evp' => $evp);

        
        my %oldenvvars;
        if($env) {            
            foreach my $key(keys %{$env}) {
                # save current value
                $oldenvvars{$key} = $ENV{$key};
                # set new value
                $ENV{$key} = $env->{$key};
                my $oldval = $oldenvvars{$key} // '{undef}';
                my $newval = $env->{$key}  // '{undef}';
                say "Changed \$ENV{$key} from $oldval to $newval";
            }           
        }

        my $pid = open3(my $in, my $out, my $err = gensym, @$torun) or die "BAD process";        
        $self{'pid'} = $pid;
        say 'PID '. $pid . ' NEW PROCESS: ' . $torun->[0];
        if($env) {
            # restore environment
            foreach my $key(keys %oldenvvars) {
                $ENV{$key} = $oldenvvars{$key};
                my $oldval = $env->{$key} // '{undef}';
                my $newval = $oldenvvars{$key} // '{undef}';
                say "Restored \$ENV{$key} from $oldval to $newval";
            }
        }
        _setup_handlers(\%self, $in, $out, $err, $fddispatch, $handlesettings);               
        return bless \%self, $class;
    }

    sub _new_ex {
        my ($make_process, $make_process_args, $context) = @_;
         my $process;
        $context->{'stdout'} = '';
        $context->{'stderr'} = '';        
        my $prochandlers = {
        'STDOUT' => sub {
            my ($handle) = @_;
            my $buf;
            while(read($handle, $buf, 4096)) {
                $context->{'stdout'} .= $buf;        
            }
            if($context->{'on_stdout_data'}) {              
                $context->{'on_stdout_data'}->($context);            
            }
            return 1;        
        },
        'STDERR' => sub {
            my ($handle) = @_;
            my $buf;
            while(read($handle, $buf, 4096)) {
                $context->{'stderr'} .= $buf;        
            }
            return 1;
        },        
        'SIGCHLD' => sub {
            my $obuf;
            my $handle = $process->{'fd'}{'stdout'}{'fd'};
            while(read($handle, $obuf, 100000)) {
                $context->{'stdout'} .= $obuf; 
                say "stdout sigchld read";            
            }            
            my $ebuf;
            $handle = $process->{'fd'}{'stderr'}{'fd'};
            while(read($handle, $ebuf, 100000)) {
                $context->{'stderr'} .= $ebuf;
                say "stderr sigchld read";              
            }
            if($context->{'on_stdout_data'}) {
                $context->{'on_stdout_data'}->($context);
            }
            $context->{'at_exit'}->($context);
            #$make_process_args->{'evp'}->add_timer(0, 0, sub {
            #    $context->{'at_exit'}->($context);
            #    return undef;
            #});        
        },      
        };

        $process = $make_process->($make_process_args, $prochandlers, {'O_NONBLOCK' => 1});
        return $process;
    }

    # launch a command process with poll handlers
    sub _new_cmd {
        my ($mpa, $prochandlers, $handlesettings) = @_;
        return $mpa->{'class'}->new($mpa->{'cmd'}, $mpa->{'evp'}, $prochandlers, $handlesettings);
    }
    
    # launch a command process
    sub new_cmd_process {
        my ($class, $evp, $cmd, $context) = @_;
        my $mpa = {'class' => $class, 'evp' => $evp, 'cmd' => $cmd};
        return _new_ex(\&_new_cmd, $mpa, $context); 
    }

    # subset of command process, just need the data on SIGCHLD
    sub new_output_process {
        my ($class, $evp, $cmd, $handler) = @_;
        #my $context = {
        #    at_exit => sub {
        #        say "at_exit1";
        #    }
        #};
        #return new_cmd_process($class, $evp, $cmd, $context);
        
        return new_cmd_process($class, $evp, $cmd, {   
            'at_exit' => sub {
                my ($context) = @_;
                say 'run handler';
                $handler->($context->{'stdout'}, $context->{'stderr'});
            }
        });
    }

    # launch a process without a new exe with poll handlers
    sub _new_child {
        my ($mpa, $prochandlers, $handlesettings) = @_;
              
        my %self = ('time' => clock_gettime(CLOCK_MONOTONIC), 'evp' => $mpa->{'evp'});
        # inreader/inwriter   is the parent to child data channel
        # outreader/outwriter is the child to parent data channel
        # errreader/errwriter is the child to parent log channel    
        pipe(my $inreader, my $inwriter)   or die("pipe failed $!");
        pipe(my $outreader, my $outwriter) or die("pipe failed $!");
        pipe(my $errreader, my $errwriter) or die("pipe failed $!");
        # the childs stderr will be UTF-8 text
        binmode($errreader, ':encoding(UTF-8)');
        my $pid = fork();
        if($pid == 0) {
            close($inwriter);
            close($outreader);
            close($errreader);
            open(STDIN,  "<&", $inreader) or die("Can't dup \$inreader to STDIN");
            open(STDOUT, ">&", $errwriter) or die("Can't dup \$errwriter to STDOUT");
            open(STDERR, ">&", $errwriter) or die("Can't dup \$errwriter to STDERR");
            $mpa->{'func'}->($outwriter);
            exit 0;
        }
        close($inreader);
        close($outwriter);
        close($errwriter);       
        $self{'pid'} = $pid;
        say 'PID '. $pid . ' NEW CHILD';
        _setup_handlers(\%self, $inwriter, $outreader, $errreader, $prochandlers, $handlesettings);               
        return bless \%self, $mpa->{'class'};
    }

    # launch a process without a new exe with just sigchld handler
    sub new_output_child {
        my ($class, $evp, $func, $handler) = @_;
        my $mpa = {'class' => $class, 'evp' => $evp, 'func' => $func};
        return _new_ex(\&_new_child, $mpa, {
            'at_exit' => sub {
                my ($context) = @_;
                $handler->($context->{'stdout'}, $context->{'stderr'});
            }
        });   
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

package GDRIVE {
    use strict; use warnings;
    use feature 'say';
    use Cwd qw(abs_path getcwd);
    use File::Find;
    use Data::Dumper;
    use File::stat;
    use File::Basename;
    use File::Path qw(make_path);
    use Scalar::Util qw(looks_like_number weaken);
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    HTTP::BS::Server::Util->import();
    
    sub gdrive_add_tmp_rec {
        my ($id, $gdrivefile, $settings) = @_;
        write_file($settings->{'GDRIVE'}{'TMP_REC_DIR'} . "/$id", $gdrivefile);
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
                
            }}, $self->{'settings'}{'GDRIVE'}{'TMP_REC_DIR'}); 
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

    sub tempfile {
        my ($tmpdir, $requestfile) = @_;             
        my $qmtmpdir = quotemeta $tmpdir;
        if($requestfile !~ /^$qmtmpdir/) {
            my $reqbase = basename($requestfile);
            $requestfile = $tmpdir . '/' . $reqbase;
        }
        return $requestfile;
    }
    
    # if it would be optimal to gdrive the file
    # AND it hasn't been gdrived, or is being gdrived return the newname
    # if it is being gdrived return the original file
    # if it has been gdrived, return 0
    # if its too small or is locked return empty string
    # otherwise undef
    # (is defined if the file exists)
    sub should_gdrive {
        my ($requestfile, $tmpfile) = @_;
        if(my $st = stat($requestfile)) {
        $requestfile = $tmpfile if($tmpfile);
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
        my ($file, $settings) = @_;               
        my $cmdout = shell_stdout('perl', $settings->{'BINDIR'} . '/gdrivemanager.pl', $file->{'actualfile'}, $settings->{'CFGDIR'} . '/gdrivemanager.json');
        say $cmdout; 
        my ($id, $newurl) = split("\n", $cmdout);
        if(! $id) {
            say "gdrive upload completely failed proc done";
            return;
        }   
        my $filename = $file->{'tmpfile'};    
        my $fname = $filename . '_gdrive';
        gdrive_add_tmp_rec($id, $fname, $settings);
        my $fname_tmp = $fname . '.tmp';
        write_file($fname_tmp, $newurl);
        rename($fname_tmp, $fname);
    }
    
    sub gdrive_upload {
        my ($file, $settings) = @_;
        my $fnametmp = $file->{'tmpfile'} . '_gdrive.tmp';
        say "fnametmp $fnametmp";
        open(my $tmpfile, ">>", $fnametmp) or die;
        close($tmpfile);        
        ASYNC(\&_gdrive_upload, $file, $settings);
    }   
    
    sub uploader {
        my($request, $requestfile) = @_;
        my $handled;         
        my $tmpdir = $request->{'client'}{'server'}{'settings'}{'TMPDIR'};        
        my $qmtmpdir = quotemeta $tmpdir;
        my $actualfile = $requestfile;
        my $tmpfile;        
        if($actualfile !~ /^$qmtmpdir/) {
            $tmpfile = tempfile($tmpdir, $actualfile);
        }
        else {
            $tmpfile = $actualfile;
        }
                        
        # send if it was uploaded in time
        my $gdrivefile = should_gdrive($actualfile, $tmpfile);       
        if(defined($gdrivefile) && looks_like_number($gdrivefile) && ($gdrivefile == 0)) {
            $handled = 1;
            my $url = read_file($tmpfile . '_gdrive');
            $request->Send307($url);
        }
        
        my @togdrive;
        # if gdrive force was set and should_gdrive, still gdrive it 
        if(((! $handled) && ($request->{'qs'}{'gdriveforce'})) &&
        (defined($gdrivefile) && ($gdrivefile ne ''))) {        
            say 'forcing gdrive';           
            $handled = 1;
            $gdrivefile = $tmpfile . '_gdrive';          
            push @togdrive, {'actualfile' => $actualfile, 'tmpfile' => $tmpfile};
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
        if( $actualfile =~ /^(.+[^\d])(\d+)\.ts$/) {
            my ($start, $num) = ($1, $2);
            # no more than 3 uploads should be occurring at a time
            for(my $i = 0; ($i < 2) && (scalar(@togdrive) < 1); $i++) {
                my $afile = $start . sprintf("%04d", ++$num) . '.ts';                                   
                my $extrafile = $afile =~ /^$qmtmpdir/ ? $afile : tempfile($tmpdir, $afile);                              
                my $shgdrive;                
                if(($shgdrive = should_gdrive($afile, $extrafile)) && ( $shgdrive =~ /_gdrive$/)) {                    
                    push @togdrive, {'actualfile' => $afile, 'tmpfile' => $extrafile};                                              
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
        $settings->{'GDRIVE'}{'TMP_REC_DIR'} ||= $settings->{'TMPDIR'} . '/gdrive_tmp_rec';    
        make_path($settings->{'GDRIVE'}{'TMP_REC_DIR'});        
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
    use Devel::Peek;
    use Fcntl ':mode';
    use File::stat;    
    use File::Basename;
    use File::Path qw(make_path);
    use Scalar::Util qw(looks_like_number);   
    HTTP::BS::Server::Util->import();
    BEGIN {
        if( ! (eval "use JSON; 1")) {
            eval "use JSON::PP; 1" or die "No implementation of JSON available, see doc/dependencies.txt";
            warn "plugin(MusicLibrary): Using PurePerl version of JSON (JSON::PP), see doc/dependencies.txt about installing faster version";
        }
    }
    use Encode qw(decode encode);
    use URI::Escape;
    use Storable qw(dclone);
    use Fcntl ':mode';  
    use Time::HiRes qw( usleep clock_gettime CLOCK_REALTIME CLOCK_MONOTONIC);
    use Scalar::Util qw(looks_like_number weaken);
    use POSIX qw/ceil/;
    use Storable qw( freeze thaw);
    use Encode qw(encode_utf8);
    #use ExtUtils::testlib;
    use FindBin;
    use File::Spec;    
    use List::Util qw[min max];
    use HTML::Template;

    # Optional dependency, MHFS::XS
    use lib File::Spec->catdir($FindBin::Bin, 'XS', 'blib', 'lib');
    use lib File::Spec->catdir($FindBin::Bin, 'XS', 'blib', 'arch');    
    BEGIN {
        if(! (eval "use MHFS::XS; 1")) {
            warn "plugin(MusicLibrary): XS not available";
            our $HAS_MHFS_XS = 0;
        }
        else {
            our $HAS_MHFS_XS = 1;
        }
        #use MHFS::XS;
        #our $HAS_MHFS_XS = 1;
    }
    

    # read the directory tree from desk and store
    # this assumes filenames are UTF-8ish, the octlets will be the actual filename, but the printable filename is created by decoding it as UTF-8
    sub BuildLibrary {
        my ($path) = @_;        
        my $statinfo = stat($path);
        return undef if(! $statinfo);         
        my $basepath = basename($path);       
        
        # determine the UTF-8 name of the file
        my $utf8name;
        {
        local $@;
        eval {
            # Fast path, is strict UTF-8
            $utf8name = decode('UTF-8', $basepath, Encode::FB_CROAK | Encode::LEAVE_SRC);
            1;
        };
        }
        if(! $utf8name) {
            say "MusicLibrary: BuildLibrary slow path decode - " . decode('UTF-8', $basepath);         
            my $loose = decode("utf8", $basepath);
            my $surrogatepairtochar = sub {
                my ($hi, $low) = @_;
                my $codepoint = 0x10000 + (ord($hi) - 0xD800) * 0x400 + (ord($low) - 0xDC00);
                return pack('U', $codepoint);
            };
            $loose =~ s/([\x{D800}-\x{DBFF}])([\x{DC00}-\x{DFFF}])/$surrogatepairtochar->($1, $2)/ueg; #uncode, expression replacement, global
            Encode::_utf8_off($loose);
            $utf8name = decode('UTF-8', $loose);
            say "MusicLibrary: BuildLibrary slow path decode changed to : $utf8name";
        }        
        
        #if($path =~ /Trucks.+07/) {
        #    say "time to die";
        #    die;
        #}              
        if(!S_ISDIR($statinfo->mode)){
        return undef if($path !~ /\.(flac|mp3|m4a|wav|ogg|webm)$/); 
            return [$basepath, $statinfo->size, undef, $utf8name];          
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
            return [$basepath, $size, \@tree, $utf8name];
       }        
    }    

    sub BuildRemoteLibrary {
        my ($self, $source) = @_;
        return undef if($source->{'type'} ne 'ssh');
        my $aslibrary = $self->{'settings'}{'BINDIR'} . '/aslibrary.pl';
        my $userhost = $source->{'userhost'};
        my $port = $source->{'port'};
        my $folder = $source->{'folder'};
          
        my $buf = shell_stdout('ssh', $userhost, '-p', $port, $source->{'aslibrary.pl'}, $source->{'server.pl'}, $folder);
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
        #my $name_unencoded = decode('UTF-8', $files->[0]);
        my $name_unencoded = $files->[3];
        my $name = ${escape_html_noquote($name_unencoded)};        
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

    sub toJSON {
        my ($self) = @_;
        my $head = {'files' => []};
        my @nodestack = ($head);
        my @files = (@{$self->{'library'}});
        while(@files) {
            my $file = shift @files;
            if( ! $file) {
                pop @nodestack;
                next;
            }
            my $node = $nodestack[@nodestack - 1];
            #my $newnode = {'name' => decode('UTF-8', $file->[0])};
            my $newnode = {'name' =>$file->[3]};
            if($file->[2]) {
                $newnode->{'files'} = [];
                push @nodestack, $newnode;
                @files = (@{$file->[2]}, undef, @files);                
            }
            push @{$node->{'files'}}, $newnode;
        }
        return encode_json($head);
    }
    
    
    sub LibraryHTML {
        my ($self) = @_;
        my $buf = '';
        foreach my $file (@{$self->{'library'}}) {
            $buf .= ToHTML($file);
            $buf .= '<br>';
        }

        my $legacy_template = HTML::Template->new(filename => 'templates/music_legacy.html', path => $self->{'settings'}{'APPDIR'} );
        $legacy_template->param(musicdb => $buf);
        $self->{'html'} = encode_utf8($legacy_template->output);

        my $gapless_template = HTML::Template->new(filename => 'templates/music_gapless.html', path => $self->{'settings'}{'APPDIR'} );
        $gapless_template->param(INLINE => 1);
        $gapless_template->param(musicdb => $buf);
        #$gapless_template->param(musicdb => '');       
        $self->{'html_gapless'} = encode_utf8($gapless_template->output);
        $self->{'musicdbhtml'} = encode_utf8($buf);
        $self->{'musicdbjson'} = toJSON($self);
    }

    sub SendLibrary {
        my ($self, $request) = @_;

        # maybe not allow everyone to do these commands?
        if($request->{'qs'}{'forcerefresh'}) {
            say "MusicLibrary: forcerefresh";
            $self->BuildLibraries(); 
        }
        elsif($request->{'qs'}{'refresh'}) {
            say "MusicLibrary: refresh";
            UpdateLibrariesAsync($self, $request->{'client'}{'server'}{'evp'}, sub {
                say "MusicLibrary: refresh done";
                $request->{'qs'}{'refresh'} = 0;
                SendLibrary($self, $request);
            });
            return 1;
        }

        # deduce the format if not provided
        my $fmt = $request->{'qs'}{'fmt'};
        if(! $fmt) {
            if($request->{'qs'}{'segments'} || ($request->{'header'}{'User-Agent'} =~ /Linux/)) {
                $fmt = 'gapless';
            }
            else {
                $fmt = 'worklet';
            }
        }

        # route
        if($fmt eq 'worklet') {
            return $request->Send307('static/music_worklet_inprogress/');
        }
        elsif($fmt eq 'musicdbjson') {
            return $request->SendLocalBuf($self->{'musicdbjson'}, "application/json");
            return 1;
        }
        elsif($fmt eq 'musicdbhtml') {
            return $request->SendLocalBuf($self->{'musicdbhtml'}, "text/html; charset=utf-8");
            return 1;
        }
        elsif($fmt eq 'gapless') {
            return $request->SendLocalBuf($self->{'html_gapless'}, "text/html; charset=utf-8");
        }
        elsif($fmt eq 'musicinc') {
            return $request->Send307('static/music_inc/');
        }
        elsif($fmt eq 'legacy') {
            say "MusicLibrary: legacy";
            return $request->SendLocalBuf($self->{'html'}, "text/html; charset=utf-8");
        }
        else {
            return $request->Send404;
        }
    }
    
    my $SEGMENT_DURATION = 5;
    my %TRACKDURATION;
    my %TRACKINFO;
    sub SendTrack {
        my ($request, $tosend) = @_;        
        if(defined $request->{'qs'}{'part'}) {
            if(! $MusicLibrary::HAS_MHFS_XS) {
                say "MusicLibrary: route not available without XS";
                $request->Send503();
                return;
            }

            if(!defined($TRACKINFO{$tosend}))
            {
                GetTrackInfo($tosend, sub {
                    $TRACKDURATION{$tosend} = $TRACKINFO{$tosend}{'duration'};
                    SendTrack($request, $tosend);
                });
                return;
            }
            
            if($TRACKDURATION{$tosend}) {
                say "no proc, duration cached";
                my $pv = MHFS::XS::new($tosend);
                $request->{'outheaders'}{'X-MHFS-NUMSEGMENTS'} = ceil($TRACKDURATION{$tosend} / $SEGMENT_DURATION);
                $request->{'outheaders'}{'X-MHFS-TRACKDURATION'} = $TRACKDURATION{$tosend};
                $request->{'outheaders'}{'X-MHFS-MAXSEGDURATION'} = $SEGMENT_DURATION;
                my $samples_per_seg = $TRACKINFO{$tosend}{'SAMPLERATE'} * $SEGMENT_DURATION;
                my $spos = $samples_per_seg * ($request->{'qs'}{'part'} - 1);                
                my $samples_left = $TRACKINFO{$tosend}{'TOTALSAMPLES'} - $spos;                
                my $res = MHFS::XS::get_flac($pv, $spos, $samples_per_seg < $samples_left ? $samples_per_seg : $samples_left);
                $request->SendLocalBuf($res, 'audio/flac');
                return;                
            }
        }
        elsif(defined $request->{'qs'}{'fmt'} && ($request->{'qs'}{'fmt'}  eq 'wav')) {
            if(! $MusicLibrary::HAS_MHFS_XS) {
                say "MusicLibrary: route not available without XS";
                $request->Send503();
                return;
            }
            
            if(!defined($TRACKINFO{$tosend}))
            {
                GetTrackInfo($tosend, sub {
                    $TRACKDURATION{$tosend} = $TRACKINFO{$tosend}{'duration'};
                    SendTrack($request, $tosend);
                });
                return;
            }
            
            my $pv = MHFS::XS::new($tosend);
            my $outbuf = '';
            my $wavsize = (44+ $TRACKINFO{$tosend}{'TOTALSAMPLES'} * ($TRACKINFO{$tosend}{'BITSPERSAMPLE'}/8) * $TRACKINFO{$tosend}{'NUMCHANNELS'});
            my $startbyte = $request->{'header'}{'_RangeStart'} || 0;
            my $endbyte = $request->{'header'}{'_RangeEnd'} // $wavsize-1;
            say "start byte" . $startbyte;
            say "end byte " . $endbyte;           
            say "MHFS::XS::wavvfs_read_range " . $startbyte . ' ' . $endbyte;          
            my $maxsendsize;
            $maxsendsize = 1048576/2;            
            say "maxsendsize $maxsendsize " . ' bytespersample ' . ($TRACKINFO{$tosend}{'BITSPERSAMPLE'}/8) . ' numchannels ' . $TRACKINFO{$tosend}{'NUMCHANNELS'};
            $request->SendCallback(sub{
                my ($fileitem) = @_;
                my $actual_endbyte = $startbyte + $maxsendsize - 1;
                if($actual_endbyte >= $endbyte) {
                    $actual_endbyte = $endbyte; 
                    $fileitem->{'cb'} = undef;
                    say "SendCallback last send";
                }                
                my $actual_startbyte = $startbyte;
                $startbyte = $actual_endbyte+1;
                say "SendCallback wavvfs_read_range " . $actual_startbyte . ' ' . $actual_endbyte;               
                return MHFS::XS::wavvfs_read_range($pv, $actual_startbyte, $actual_endbyte);
            }, {
                'mime' => 'audio/wav',
                'size' => $wavsize,            
            });
                      
        }
        else {
            $request->SendLocalFile($tosend);
        }
    }

    sub parseStreamInfo {
        # https://metacpan.org/source/DANIEL/Audio-FLAC-Header-2.4/Header.pm
        my ($buf) = @_;
        my $metaBinString = unpack('B144', $buf);
 
        my $x32 = 0 x 32;
        my $info = {};
        $info->{'MINIMUMBLOCKSIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 0, 16), -32)));
        $info->{'MAXIMUMBLOCKSIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 16, 16), -32)));
        $info->{'MINIMUMFRAMESIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 32, 24), -32)));
        $info->{'MAXIMUMFRAMESIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 56, 24), -32)));
 
        $info->{'SAMPLERATE'}       = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 80, 20), -32)));
        $info->{'NUMCHANNELS'}      = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 100, 3), -32))) + 1;
        $info->{'BITSPERSAMPLE'}    = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 103, 5), -32))) + 1;
 
        # Calculate total samples in two parts
        my $highBits = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 108, 4), -32)));
 
        $info->{'TOTALSAMPLES'} = $highBits * 2 ** 32 +
                unpack('N', pack('B32', substr($x32 . substr($metaBinString, 112, 32), -32)));
 
        # Return the MD5 as a 32-character hexadecimal string
        $info->{'MD5CHECKSUM'} = unpack('H32',substr($buf, 18, 16));
        return $info; 
    }

    sub GetTrackInfo {
        my ($file, $continue) = @_;
        open(my $fh, '<', $file) or die "open failed";
        my $buf = '';
        seek($fh, 8, 0) or die "seek failed";
        (read($fh, $buf, 34) == 34) or die "short read";
        my $info = parseStreamInfo($buf);
        $info->{'duration'} = $info->{'TOTALSAMPLES'}/$info->{'SAMPLERATE'}; 
        $TRACKINFO{$file} = $info;
        print Dumper($info); 
        $continue->(); 
    }
    
    sub SendLocalTrack {
        my ($request, $file) = @_;    
        my $evp = $request->{'client'}{'server'}{'evp'};
        my $tmpfileloc = $request->{'client'}{'server'}{'settings'}{'TMPDIR'} . '/';
        my $nameloc = $request->{'localtrack'}{'nameloc'}; 
        $tmpfileloc .= $nameloc if($nameloc);  
        my $filebase = $request->{'localtrack'}{'basename'};

        # convert to lossy flac if necessary
        my $is_flac = $file =~ /\.flac$/i;
        if(!$is_flac) {
            my $wantjustflac = $request->{'qs'}{'fmt'} && ($request->{'qs'}{'fmt'} eq 'flac');
            if(!$request->{'qs'}{'part'} && !$wantjustflac) {
                SendTrack($request, $file);
                return;
            }
            $filebase =~ s/\.[^.]+$/.lossy.flac/;
            $request->{'localtrack'}{'basename'} = $filebase;
            my $tlossy = $tmpfileloc . $filebase;
            if(-e $tlossy ) {
                $is_flac = 1;
                $file = $tlossy;
            }
            else {    
                make_path($tmpfileloc, {chmod => 0755});
                my @cmd = ('ffmpeg', '-i', $file, '-c:a', 'flac', '-sample_fmt', 's16', $tlossy);
                my $buf;
                $request->{'process'} = HTTP::BS::Server::Process->new(\@cmd, $evp, {
                'SIGCHLD' => sub {
                    # HACK
                    $request->{'client'}{'time'} = clock_gettime(CLOCK_MONOTONIC);
                    SendLocalTrack($request,$tlossy);                
                },                    
                'STDERR' => sub {
                    my ($terr) = @_;
                    read($terr, $buf, 4096);                                     
                }}); 
                return;
            }            
        }

        my $max_sample_rate = $request->{'qs'}{'max_sample_rate'};
        my $bitdepth = $request->{'qs'}{'bitdepth'};             
        # no requirements just send the raw file
        if(! $max_sample_rate) {
            SendTrack($request, $file);
            return;            
        }           
        elsif(! $bitdepth) {
            $bitdepth = $max_sample_rate > 48000 ? 24 : 16;        
        }        
        say "using bitdepth $bitdepth";
        
        # check to see if the raw file fullfills the requirements
        if(!defined($TRACKINFO{$file}))
        {
            GetTrackInfo($file, sub {
                $TRACKDURATION{$file} = $TRACKINFO{$file}{'duration'};
                SendLocalTrack($request, $file);
            });
            return;
        }
        my $samplerate = $TRACKINFO{$file}{'SAMPLERATE'};
        my $inbitdepth = $TRACKINFO{$file}{'BITSPERSAMPLE'};        
        say "input: samplerate $samplerate inbitdepth $inbitdepth";
        say "maxsamplerate $max_sample_rate bitdepth $bitdepth";                    
        if(($samplerate <= $max_sample_rate) && ($inbitdepth <= $bitdepth)) {
            say "samplerate is <= max_sample_rate, not resampling";
            SendTrack($request, $file);
            return;               
        }
        
        # determine the acceptable samplerate, bitdepth combinations to send
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
            my $tmpfile = $tmpfileloc . $setting->[0] . '_' . $setting->[1] . '_' . $filebase;
            if(-e $tmpfile) {
                say "No need to resample $tmpfile exists";
                SendTrack($request, $tmpfile);
                return;
            }                      
        }
        make_path($tmpfileloc, {chmod => 0755});        

        # resampling
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
        my $outfile = $tmpfileloc . $bitdepth . '_' . $desiredrate . '_' . $filebase;
        my @cmd = ('sox', $file, '-G', '-b', $bitdepth, $outfile, 'rate', '-v', '-L', $desiredrate, 'dither');
        say "cmd: " . join(' ', @cmd);
        # HACK
        say "client time was: " . $request->{'client'}{'time'};
        $request->{'client'}{'time'} += 30;
        say "HACK client time extended to " . $request->{'client'}{'time'};
        $request->{'process'} = HTTP::BS::Server::Process->new(\@cmd, $evp, {
        'SIGCHLD' => sub {
            # BUG
            # files isn't necessarily flushed to disk on SIGCHLD. filesize can be wrong

            # HACK
            $request->{'client'}{'time'} = clock_gettime(CLOCK_MONOTONIC); 
            SendTrack($request, $outfile);                                      
        },                    
        'STDERR' => sub {
            my ($terr) = @_;
            my $buf;
            read($terr, $buf, 4096);                                     
        }});  
        return;
    }    
   

    sub BuildLibraries {
        my ($self) = @_;
        my @wholeLibrary;

        $self->{'sources'} = [];
        my $tocheck = dclone($self->{'settings'}{'MusicLibrary'}{'sources'});
       
        foreach my $source (@{$tocheck}) {
            my $lib;
            if($source->{'type'} eq 'local') {
                say "MusicLibrary: building music " . clock_gettime(CLOCK_MONOTONIC);             
                $lib = BuildLibrary($source->{'folder'});
                say "MusicLibrary: done building music " . clock_gettime(CLOCK_MONOTONIC);
            }
            elsif($source->{'type'} eq 'ssh') {
                $lib = $self->BuildRemoteLibrary($source);               
            }
            elsif($source->{'type'} eq 'mhfs') {
                $source->{'type'} = 'ssh';
                $lib = $self->BuildRemoteLibrary($source);
                if(!$source->{'httphost'}) {
                    $source->{'httphost'} =  ssh_stdout($source, 'dig', '@resolver1.opendns.com', 'ANY', 'myip.opendns.com', '+short');
                    if(!  $source->{'httphost'}) {
                        $lib = undef;
                    }
                    else {
                        chop $source->{'httphost'};
                        $source->{'httpport'} //= 8000;
                    }                
                }            
                say "MHFS host at " . $source->{'httphost'} . ':' . $source->{'httpport'} if($source->{'httphost'});                
            }
            if($lib) {                
                $source->{'lib'} = $lib;
                push @{$self->{'sources'}}, $source;
                OUTER: foreach my $item (@{$lib->[2]}) {
                    foreach my $already (@wholeLibrary) {
                        next OUTER if($already->[0] eq $item->[0]);
                    }
                    push @wholeLibrary, $item;
                }
            }
            else {
                $source->{'lib'} = undef;
                warn "invalid source: " . $source->{'type'};
                warn 'folder: '. $source->{'folder'} if($source->{'type'} eq 'local');
            }
        }
        $self->{'library'} = \@wholeLibrary;
        $self->LibraryHTML;
        return \@wholeLibrary;
    }

    sub FindInLibrary {
        my ($source, $name) = @_;
        my @namearr = split('/', $name);
        my $finalstring = $source->{'folder'};
        my $lib = $source->{'lib'};
        FindInLibrary_Outer: foreach my $component (@namearr) {
            foreach my $libcomponent (@{$lib->[2]}) {
                if($libcomponent->[3] eq $component) {
                     $finalstring .= "/".$libcomponent->[0]; 
                    $lib = $libcomponent;
                    next FindInLibrary_Outer;
                }
            }
            return undef;
        }        
        return {
            'node' => $lib,
            'path' => $finalstring
        };            
    }    
    
    # Define source types here
    my %sendFiles = (
        'local' => sub {
            my ($request, $file, $node, $source, $nameloc) = @_;
            return undef if(! -e $file);            
            if( ! -d $file) {
                $request->{'localtrack'} = { 'nameloc' => $nameloc, 'basename' => $node->[0]};                
                SendLocalTrack($request, $file);
            }
            else {
                $request->SendAsTar($file);
            }
            return 1;       
        },
        'mhfs' => sub {
            my ($request, $file, $node, $source) = @_;
            return $request->Proxy($source, $node);
        },
        'ssh' => sub {
            my ($request, $file, $node, $source) = @_;               
            return $request->SendFromSSH($source, $file, $node);       
        },   
    );

    sub SendFromLibrary {
        my ($self, $request) = @_;        
        my $utf8name = decode('UTF-8', $request->{'qs'}{'name'});
        foreach my $source (@{$self->{'sources'}}) {
            my $node = FindInLibrary($source, $utf8name);
            next if ! $node;           
           
            my $nameloc;
            if($utf8name =~ /(.+\/).+$/) {
                $nameloc  = $1;
            }
            if($sendFiles{$source->{'type'}}->($request, $node->{'path'}, $node->{'node'}, $source, $nameloc)) {
                return 1;
            } 
        }
        say "SendFromLibrary: did not find in library, 404ing";
        say "name: " . $request->{'qs'}{'name'};
        $request->Send404;
    }

    sub SendResources {        
        my ($self, $request) = @_;

        if(! $MusicLibrary::HAS_MHFS_XS) {
            say "MusicLibrary: route not available without XS";
            $request->Send503();
            return;
        }

        my $utf8name = decode('UTF-8', $request->{'qs'}{'name'});
        foreach my $source (@{$self->{'sources'}}) {
            my $node = FindInLibrary($source, $utf8name);
            next if ! $node;
            my $comments = MHFS::XS::get_vorbis_comments($node->{'path'});
            my $commenthash = {};
            foreach my $comment (@{$comments}) {
                $comment = decode('UTF-8', $comment);
                my ($key, $value) = split('=', $comment);
                $commenthash->{$key} = $value;
            }
            $request->SendLocalBuf(encode_utf8(encode_json($commenthash)), "text/json; charset=utf-8");
            return 1;             
        }
        say "SendFromLibrary: did not find in library, 404ing";
        say "name: " . $request->{'qs'}{'name'};
        $request->Send404;
    }

    sub UpdateLibrariesAsync {
        my ($self, $evp, $onUpdateEnd) = @_;
        HTTP::BS::Server::Process->new_output_child($evp, sub {            
            # done in child
            my ($datachannel) = @_;

            # save references to before
            my @potentialupdates = ('html_gapless', 'html', 'musicdbhtml', 'musicdbjson');
            my %before;
            foreach my $pupdate (@potentialupdates) {
                $before{$pupdate} = $self->{$pupdate};
            }

            # build the new libraries
            $self->BuildLibraries();

            # determine what needs to be updated
            my @updates = (['sources', $self->{'sources'}]);
            foreach my $pupdate(@potentialupdates) {
                if($before{$pupdate} ne $self->{$pupdate}) {
                    push @updates, [$pupdate, $self->{$pupdate}];
                }
            }

            print STDERR "MusicLibrary: UpdateLibrariesAsync:freezing\n";
            my $pipedata = freeze(\@updates);
            print STDERR "MusicLibrary: UpdateLibrariesAsync: outputting on pipe\n";  
            print $datachannel $pipedata;
            exit 0;
        }, sub {
            my ($out, $err) = @_;
            say "BEGIN_FROM_CHILD---------";
            print $err;
            say "END_FROM_CHILD-----------";
            my $unthawed;           
            {
                local $@;
                unless (eval {
                    $unthawed = thaw($out);
                    return 1;                    
                }) {
                    warn("thaw threw exception");
                }
            }
            if($unthawed){
                foreach my $update (@$unthawed) {
                    say "Updating " . $update->[0];
                    $self->{$update->[0]} = $update->[1];
                }                
            }
            else {
                say "failed to thaw, library not updated.";
            }           
            $onUpdateEnd->();
        });
    }    
  
    sub new {
        my ($class, $settings) = @_;
        my $self =  {'settings' => $settings};
        bless $self, $class;  
        my $pstart = 'plugin(' . ref($self) . '): ';
        
        # no sources until loaded
        $self->{'sources'} = [];
        $self->{'html_gapless'} = 'MusicLibrary not loaded';
        $self->{'html'} = 'MusicLibrary not loaded';
        $self->{'musicdbhtml'} = 'MusicLibrary not loaded';
        $self->{'musicdbjson'} = '{}';

        my $musicpageroute = sub {
            my ($request) = @_;
            return $self->SendLibrary($request);
        };

        my $musicdlroute = sub {
            my ($request) = @_;
            return $self->SendFromLibrary($request);
        };

        my $musicresourcesroute = sub {
            my ($request) = @_;
            return $self->SendResources($request);
        };       

        $self->{'routes'} = [
            ['/music', $musicpageroute],
            ['/music_dl', $musicdlroute],
            ['/music_resources', $musicresourcesroute],
        ];        

        $self->{'timers'} = [
            # update the library at start and periodically
            [0, 300, sub {
                my ($timer, $current_time, $evp) = @_;
                say "$pstart  library timer";                
                UpdateLibrariesAsync($self, $evp, sub {
                    say "$pstart library timer done";
                });
                return 1;
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
    use URI::Escape;
    use Scalar::Util qw(looks_like_number weaken);
    use File::stat;
    HTTP::BS::Server::Util->import();
    BEGIN {
        if( ! (eval "use JSON; 1")) {
            eval "use JSON::PP; 1" or die "No implementation of JSON available, see doc/dependencies.txt";
            warn "plugin(Youtube): Using PurePerl version of JSON (JSON::PP), see doc/dependencies.txt about installing faster version";
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
        my $youtubequery = 'q=' . (uri_escape($request->{'qs'}{'q'}) // '') . '&maxResults=' . ($request->{'qs'}{'maxResults'} // '25') . '&part=snippet&key=' . $self->{'settings'}{'Youtube'}{'key'};
        $youtubequery .= '&type=video'; # playlists not supported yet
        my $tosend = '';
        my @curlcmd = ('curl', '-G', '-d', $youtubequery, 'https://www.googleapis.com/youtube/v3/search');
        print "$_ " foreach @curlcmd;
        print "\n";       
        state $tprocess;
        $tprocess = HTTP::BS::Server::Process->new(\@curlcmd, $evp, {
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

    sub downloadAndServe {
        my ($self, $request, $video) = @_;
        weaken($request);


        my $filename = $video->{'out_filepath'};
        my $sendit = sub {
            # we can send the file
            if(! $request) {
                return;
            }
            say "sending!!!!";
            $request->SendLocalFile($filename);
        };

        my $qs = $request->{'qs'};
        my @cmd = ($self->{'youtube-dl'}, '--no-part', '--print-traffic', '-f', $self->{'fmts'}{$qs->{"media"} // "video"} // "best", '-o', $video->{"out_filepath"}, '--', $qs->{"id"});
        $request->{'process'} = HTTP::BS::Server::Process->new_cmd_process($request->{'client'}{'server'}{'evp'}, \@cmd, {
            'on_stdout_data' => sub {
                my ($context) = @_;

                # determine the size of the file
                # relies on receiving content-length header last
                my ($cl) = $context->{'stdout'} =~ /^.*Content\-Length:\s(\d+)/s;
                return 1 if(! $cl);                
                my ($cr) = $context->{'stdout'} =~ /^.*Content\-Range:\sbytes\s\d+\-\d+\/(\d+)/s;
                if($cr) {
                    say "cr $cr";
                    $cl = $cr if($cr > $cl);                        
                }
                say "cl is $cl";
                UNLOCK_WRITE($filename);
                LOCK_WRITE($filename, $cl);

                # make sure the file exists and within our parameters                
                my $st = stat($filename);
                $st or return;
                my $minsize = 16384;
                $minsize = $cl if($cl < $minsize);
                return if($st->size < $minsize);
                say "sending, currentsize " . $st->size . ' totalsize ' . $cl;                

                # dont need to check the new data anymore
                $context->{'on_stdout_data'} = undef;                
                $sendit->();
                $request = undef;              
            },
            'at_exit' => sub {
                my ($context) = @_;
                UNLOCK_WRITE($filename);
                # last ditch effort, try to send it if we haven't
                $sendit->();
            }
        });
        return 1;
    }    
    
    sub getOutBase {
        my ($self, $qs) = @_;
        return undef if(! $qs->{'id'});

        my $media;
        if(defined $qs->{'media'} && (defined $self->{'fmts'}{$qs->{'media'}})) {
            $media = $qs->{'media'};
        }
        else  {
            $media = 'video';
        }        
        return $qs->{'id'} . '_' . $media; 
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
        
        $self->{'fmts'} = {'music' => 'bestaudio', 'video' => 'best'};
        $self->{'minsize'} = '1048576';
        $self->{'VIDEOFORMATS'} = {'yt' => {'lock' => 1, 'ext' => 'yt', 'plugin' => $self}};
        
        my $pstart = 'plugin(' . ref($self) . '): ';
        my $mhfsytdl = $settings->{'BINDIR'} . '/youtube-dl';  
        if(-e $mhfsytdl) {
            say  $pstart . "Using MHFS youtube-dl. Attempting update";
            if(fork() == 0)
            {
                system "$mhfsytdl", "-U";
                exit 0;
            }
            
            #if(system("$mhfsytdl --help > /dev/null") != 0) {
            #    say $pstart . "youtube-dl binary is invalid. plugin load failed";
            #    return undef;
            #}
            $self->{'youtube-dl'} = $mhfsytdl;
            $settings->{'youtube-dl'} = $mhfsytdl;
        }
        elsif(system('youtube-dl --help > /dev/null') == 0){
            say $pstart . "Using system youtube-dl";
            $self->{'youtube-dl'} = 'youtube-dl';
            $settings->{'youtube-dl'} = 'youtube-dl';        
        }
        else {
            say $pstart . "youtube-dl not found. plugin load failed";
            return undef;
        }       

        return $self;
    }   
    
    
    1;
}

package TAR {
    use strict; use warnings;
    use feature 'say';
    use File::stat;
    use Devel::Peek;
    use Data::Dumper;
    use Fcntl ':mode';

    sub tar {
        my ($file, $out) = @_;
        my $endslash = rindex($file, "/");
        my $toremove = '';
        if($endslash != -1) {
            $toremove = substr($file, 0, $endslash+1);
            say "toremove $toremove";
        }
        my $torem = length($toremove);

        my @files = ($file);
        while(@files) {
            my $file = shift @files;
            my $st = stat($file);
            if(!$st) {
                say "failed to stat $file";
                return;
            }
            my $tarname = substr($file, $torem, 100-1);
            say 'tar filename ' . $tarname;
            my $fullmode = $st->mode;
            my $modestr  = sprintf "%07o", $fullmode & 07777;
            my $ownerstr = sprintf("%07u", $st->uid);
            my $groupstr = sprintf("%07u", $st->gid);
            my $sizestr  = S_ISDIR($fullmode) ? sprintf("%011o", 0) : sprintf("%011o", $st->size);
            my $modtime =   sprintf("%011o", $st->mtime);
            my $checksum = sprintf("           ");
            my $type;
            if(S_ISDIR($fullmode)) {
                $type = 5;
            }
            elsif(S_ISREG($fullmode)) {
                $type = 0;                
            }
            else {
                die;
            }
            my $packstr = sprintf("Z100Z8Z8Z8Z12Z12Z8cx355");           
            my $header = pack($packstr, $tarname, $modestr, $ownerstr, $groupstr, $sizestr, $modtime, $type);
            Dump($header);          
            print Dumper(unpack("H*",$header));
            
            if(S_ISDIR($fullmode)){
                #my $dh = opendir($file);
                #$dh or die("failed to open dir");
                #my @tfiles = readdir($dh);
                #@files = (@tfiles, @files)
            }
            else {
                open(my $fh, '<', $file) or die("couldnt open file");
                my $sv;
                defined(read($fh, $sv, $st->size)) or die("couldn't read file");
            }
        }
        die;        
    }



    1;
}

package MHFS::Settings {
    use strict; use warnings;
    use feature 'say';
    use Scalar::Util qw(reftype);
    use File::Basename;
    HTTP::BS::Server::Util->import();

    sub write_settings_file {
        my ($SETTINGS, $filepath) = @_;
        my $indentcnst = 4;
        my $indentspace = '';
        my $settingscontents = "#!/usr/bin/perl\nuse strict; use warnings;\n\nmy \$SETTINGS = ";
        my @values = ($SETTINGS);
        while(@values) {
            my $value = shift @values;
            my $type = reftype($value);
            if(! defined $type) {
                my $raw;
                my $noindent;               
                if(defined $value) {
                    # process lead control code if provided
                    $raw = ($value eq '__raw');
                    $noindent = ($value eq '__noindent');
                    if($raw || $noindent) {
                        $value = shift @values;
                    }                                                          
                }
                # encode the value if needed
                if(! defined $value) {
                    $value = 'undef';
                }
                elsif($value eq '__indent-') {
                    substr($indentspace, -4, 4, '');
                    # don't actually encode anything
                    $value = '';
                    $raw = 1;
                    $noindent = 1;
                }
                elsif(! $raw) {
                    $value =~ s/'/\\'/g;
                    $value = "'".$value."'";                    
                }
                # add the value to the buffer
                $settingscontents .= $indentspace if(! $noindent);
                $settingscontents .= $value;
                $settingscontents .= ",\n" if(! $raw);                
            }
            elsif($type eq 'HASH') {
                $settingscontents .= $indentspace."{\n";
                $indentspace .= (' ' x $indentcnst);
                my @toprepend;
                foreach my $key (keys %{$value}) {
                    push @toprepend, '__raw', "'$key' => ", '__noindent', $value->{$key};
                }
                push @toprepend, '__indent-', '__raw', "}\n,";
                unshift(@values, @toprepend);
            }
            elsif($type eq 'ARRAY') {
                $settingscontents .= $indentspace."[\n";
                $indentspace .= (' ' x $indentcnst);
                my @toprepend = @{$value};
                push @toprepend, '__indent-', '__raw', "]\n,";
                unshift(@values, @toprepend);
            }
            else {
                die("Unknown type: $type");
            }
        }
        chop $settingscontents;
        chop $settingscontents;
        $settingscontents .= ";\n\n\$SETTINGS;\n";
        write_file($filepath,  $settingscontents);
    }

    sub load {
        my ($scriptpath) = @_;
        # locate files based on appdir
        my $SCRIPTDIR = dirname($scriptpath);
        my $APPDIR = $SCRIPTDIR;
        
        # set the settings dir to the first that exists of $XDG_DATA_DIRS/mhfs
        # if none exist and $APPDIR/.conf use that, otherwise use $XDG_CONFIG_HOME
        # https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
        my $XDG_CONFIG_HOME = $ENV{'XDG_CONFIG_HOME'} || ($ENV{'HOME'} . '/.config');
        my @configdirs = ($XDG_CONFIG_HOME);
        my $XDG_CONFIG_DIRS = $ENV{'XDG_CONFIG_DIRS'} || '/etc/xdg';
        push @configdirs, split(':', $XDG_CONFIG_DIRS);
        my $CFGDIR;
        foreach my $cfgdir (@configdirs) {
            if(-d "$cfgdir/mhfs") {
                $CFGDIR = "$cfgdir/mhfs";
                last;
            }
        }
        my $appdirconfig = $APPDIR . '/.conf';
        my $useappdirconfig = -d $appdirconfig;
        $CFGDIR ||= ($useappdirconfig ? $appdirconfig : ($XDG_CONFIG_HOME.'/mhfs'));
        
        # load the settings
        my $SETTINGS_FILE = $CFGDIR . '/settings.pl';
        my $SETTINGS = do ($SETTINGS_FILE);
        if(! $SETTINGS) {
            warn("No settings file found, using default settings");
            $SETTINGS = {};
        }
        # load defaults for unset values
        $SETTINGS->{'HOST'} ||= "127.0.0.1";
        $SETTINGS->{'PORT'} ||= 8000;
        # write a settings file
        if(! -f $SETTINGS_FILE) {
            write_settings_file($SETTINGS, $SETTINGS_FILE);
        }
        
        # $APPDIR in $SETTINGS takes precedence over previous value
        if($SETTINGS->{'APPDIR'}) {
            if($useappdirconfig && ($APPDIR ne $SETTINGS->{'APPDIR'})) {
                warn('Using $APPDIR different from config path');
                warn("was $APPDIR, changing to $SETTINGS->{'APPDIR'}");
            }
            $APPDIR = $SETTINGS->{'APPDIR'};
        }
        else {
            $SETTINGS->{'APPDIR'} = $APPDIR;
        }
        
        
        if( ! $SETTINGS->{'DOCUMENTROOT'}) {
            $SETTINGS->{'DOCUMENTROOT'} = "$APPDIR/public_html";
        }
        $SETTINGS->{'XSEND'} //= 0;
        $SETTINGS->{'ABSURL'}   ||= 'http://' . $SETTINGS->{'HOST'} . ':' . $SETTINGS->{'PORT'};
        # an absolute urls must be used in m3u8 playlists
        $SETTINGS->{'M3U8_URL'} ||= $SETTINGS->{'ABSURL_HTTP'} || $SETTINGS->{'ABSURL'};        
        $SETTINGS->{'TMPDIR'} ||= $SETTINGS->{'DOCUMENTROOT'} . '/tmp';
        $SETTINGS->{'VIDEO_TMPDIR'} ||= $SETTINGS->{'TMPDIR'};
        $SETTINGS->{'MEDIALIBRARIES'}{'movies'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/movies", 
        $SETTINGS->{'MEDIALIBRARIES'}{'tv'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/tv", 
        $SETTINGS->{'MEDIALIBRARIES'}{'music'} ||= $SETTINGS->{'DOCUMENTROOT'} . "/media/music", 
        $SETTINGS->{'BINDIR'} ||= $APPDIR . '/bin';
        $SETTINGS->{'DOCDIR'} ||= $APPDIR . '/doc';
        $SETTINGS->{'CFGDIR'} ||= $CFGDIR;
        
        if( ! defined $SETTINGS->{'MusicLibrary'}) {
            my $folder = $SETTINGS->{'DOCUMENTROOT'} . "/media/music";
            if(-d $folder) {
                $SETTINGS->{'MusicLibrary'} = {
                'enabled' => 1,
                'sources' => [
                    { 'type' => 'local', 'folder' => $folder},
                    ]
                };
            }
        }

        return $SETTINGS;
    }

    1;
};

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
        eval "use JSON::PP; 1" or die "No implementation of JSON available, see doc/dependencies.txt";
        warn "Using PurePerl version of JSON (JSON::PP), see doc/dependencies.txt about installing faster version";
    }
}
sub uniq (@) {
    my %seen = ();
    grep { not $seen{$_}++ } @_;
}
use IPC::Open3;
use File::stat;
use File::Find;
use File::Path qw(make_path);
use File::Copy;
use POSIX;
use Encode qw(decode encode find_encoding);
use URI::Escape;
use Scalar::Util qw(looks_like_number weaken reftype);
use Encode;
use Devel::Peek;
use Symbol 'gensym';
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

HTTP::BS::Server::Util->import();

$SIG{PIPE} = sub {
    print STDERR "SIGPIPE @_\n";
};

# main
if(scalar(@ARGV) >= 1 ) {
    if($ARGV[0] eq 'flush') {
        STDOUT->autoflush(1);
        STDERR->autoflush(1);
    }
}

# load settings
my $SETTINGS = MHFS::Settings::load(abs_path(__FILE__));

my %RESOURCES; # Caching of resources

# load plugins
my @plugins;
{
    my @plugintotry = ('Youtube');
    #push @plugintotry, 'GDRIVE' if($SETTINGS->{'GDRIVE'});
    push (@plugintotry, 'MusicLibrary') if($SETTINGS->{'MusicLibrary'});
    foreach my $plugin (@plugintotry) {
        next if(defined $SETTINGS->{$plugin}{'enabled'} && (!$SETTINGS->{$plugin}{'enabled'}));
        my $loaded = $plugin->new($SETTINGS);
        next if(! $loaded);
        push @plugins, $loaded;
    }
}

# make the temp dirs
make_path($SETTINGS->{'TMPDIR'}, $SETTINGS->{'VIDEO_TMPDIR'});

# get_video formats
my %VIDEOFORMATS = (
            'hlsold' => {'lock' => 0, 'create_cmd' => "ffmpeg -i '%s' -codec:v copy -bsf:v h264_mp4toannexb -strict experimental -acodec aac -f ssegment -segment_list '%s' -segment_list_flags +live -segment_time 10 '%s%%03d.ts'",  'create_cmd_args' => ['requestfile', 'outpathext', 'outpath'], 'ext' => 'm3u8', 
            'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/hls_player.html'},
            
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
            
            'noconv' => {'lock' => 0, 'ext' => '', 'player_html' => $SETTINGS->{'DOCUMENTROOT'} . '/static/noconv_player.html', },
            'm3u8'   => {'lock' => 0, 'ext' => ''},
            'mkv'    => {'lock' => 0, 'ext' => ''}            
);

# get_video formats from plugins
foreach my $plugin(@plugins) {    
    foreach my $videoformat (keys %{$plugin->{'VIDEOFORMATS'}}) {
        say 'plugin(' . ref($plugin) . '): adding video format ' . $videoformat;
        $VIDEOFORMATS{$videoformat} = $plugin->{'VIDEOFORMATS'}{$videoformat};
    }
}

# web server routes
my @routes = (
    [
        '/get_video', \&get_video
    ],
    [
        '/video', \&player_video
    ],
    [
        '/video/*', sub {
            my ($request) = @_;
            my $rawdir = "/video/tv";
            my $kodidir = "/video/kodi/tv";
            my $tvdir;
            if(index($request->{'path'}{'unsafepath'}, $rawdir) == 0) {
                $tvdir = $rawdir;
                my $urf = $SETTINGS->{'MEDIALIBRARIES'}{'tv'} .'/'.substr($request->{'path'}{'unsafepath'}, length($tvdir));
                my $requestfile = abs_path($urf);
                my $ml = $SETTINGS->{'MEDIALIBRARIES'}{'tv'};
                say "rf $requestfile ";
                if (( ! defined $requestfile) || ($requestfile !~ /^$ml/)){
                    $request->Send404;            
                }
                else {
                    if(-f $requestfile) {
                        $request->SendFile($requestfile);
                    }
                    elsif(-d $requestfile) {
                        # ends with slash
                        if((substr $request->{'path'}{'unescapepath'}, -1) eq '/') {
                            opendir ( my $dh, $requestfile ) or die "Error in opening dir $requestfile\n";
                            my $buf;
                            my $filename;
                            while( ($filename = readdir($dh))) {
                               next if(($filename eq '.') || ($filename eq '..'));
                               next if(!(-s "$requestfile/$filename"));
                               my $url = uri_escape_utf8($filename);
                               $url .= '/' if(-d "$requestfile/$filename");
                               $buf .= '<a href="' . $url .'">'.${escape_html_noquote($filename)} .'</a><br><br>';
                            }
                            closedir($dh);
                            $request->SendLocalBuf($buf, 'text/html');
                        }
                        # redirect to slash path
                        else {
                            $request->Send301(basename($requestfile).'/');
                        }
                    }
                    else {
                        $request->Send404;  
                    }
                }
            }
            elsif(index($request->{'path'}{'unsafepath'}, $kodidir) == 0) {
                $tvdir = $kodidir;

                # read in the shows
                my $isdir = 1;
                my $requestfile = abs_path($SETTINGS->{'MEDIALIBRARIES'}{'tv'});
                opendir ( my $dh, $requestfile ) or die "Error in opening dir $requestfile\n";                       
                my %shows = ();
                my @diritems;
                my $filename;
                while( ($filename = readdir($dh))) {
                    next if(($filename eq '.') || ($filename eq '..'));
                    next if(!(-s "$requestfile/$filename"));
                    # also broken
                    next if($filename !~ /^(.+)[\.\s]+S(?:\d+)|(?:eason)/);
                    my $showname = $1;
                    if($showname) {
                        say "show: $showname";
                        if(! $shows{$showname}) {
                            $shows{$showname} = [];
                            push @diritems, {'item' => $showname, 'isdir' => 1}
                        }                      
                        push @{$shows{$showname}}, "$requestfile/$filename";                        
                    }                                             
                }
                closedir($dh);

                # locate the content
                if($request->{'path'}{'unsafepath'} ne $tvdir) {
                    my $fullshowname = substr($request->{'path'}{'unsafepath'}, length($kodidir)+1);
                    say "fullshowname $fullshowname";
                    my $slash = index($fullshowname, '/');
                    @diritems = ();
                    my $showname = ($slash != -1) ? substr($fullshowname, 0, $slash) : $fullshowname;
                    my @outitems;
                    say "showname $showname";
                    my @initems = @{$shows{$showname}};
                    # todo, items as virtpath, realpath, replace basename usage
                    while(@initems) {
                        my $item = shift @initems;
                        if(-f $item) {
                            say "out item";
                            push @outitems, $item;
                        }
                        elsif(-d $item) {
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
                            say "bad item " . $item;
                        }                        
                    }
                    if($slash == -1) {
                        $isdir = 1;
                        my @items;
                        foreach my $item (@outitems) {
                            push @items, basename($item);                            
                        }
                        my @newitems = uniq @items;
                        foreach my $item (@newitems) {
                            push @diritems, {'item' => $item, 'isdir' => 0};
                        }
                    }
                    else {
                        $isdir = 0;
                        my $showbasename = substr($fullshowname, index($fullshowname, '/')+1);
                        say "showbasename $showbasename";
                        foreach my $item (@outitems) {
                            if($showbasename eq basename($item)) {
                                $requestfile = $item;
                                last;
                            }
                        }
                    }                  
                }                

                # build the response
                if(!$isdir && -f $requestfile) {
                    $request->SendFile($requestfile);
                }
                elsif($isdir) {
                    if((substr $request->{'path'}{'unescapepath'}, -1) ne '/') {                        
                        $request->Send301(substr($request->{'path'}{'unescapepath'}, rindex($request->{'path'}{'unescapepath'}, '/')+1).'/');
                    }
                    else {
                        my $buf = '';
                        foreach my $show (uniq @diritems) {
                            my $showname = $show->{'item'};
                            my $url = uri_escape_utf8($showname);
                            $url .= '/' if($show->{'isdir'});
                            $buf .= '<a href="' . $url .'">'.${escape_html_noquote($showname)} .'</a><br><br>';
                        }
                        $request->SendLocalBuf($buf, 'text/html');
                    }
                }
                else {
                    $request->Send404;  
                }                
            }
            else {
                $request->Send404;
            }
        }
    ],
    [
        '/torrent', \&torrent
    ],
    [
        '/debug', sub {
            my ($request) = @_;
            $request->SendLocalBuf("Trucks Passing Trucks - - x m a s \x{2744} 2 \x{5343} 17 - - - x m a s \x{2744} 2 \x{5343} 19 - - 01 t h i s \x{1f384} x m a s.flac", 'text/html; charset=utf-8');
        }
    ],   
    sub {
        my ($request) = @_;       

        # otherwise attempt to send a file from droot
        my $droot = $SETTINGS->{'DOCUMENTROOT'};
        my $requestfile = $request->{'path'}{'requestfile'};
           
        # not a file or is outside of the document root
        if(( ! defined $requestfile) ||
           ($requestfile !~ /^$droot/)){
            $request->Send404;            
        }
        # is regular file          
        elsif (-f $requestfile) {
            $request->SendFile($requestfile);
        }
        # is directory and directory has index.html
        elsif (-d $requestfile && -f $requestfile.'/index.html') {
            # ends with slash
            if((substr $request->{'path'}{'unescapepath'}, -1) eq '/') {
                $request->SendFile($requestfile.'/index.html');
            }
            # redirect to slash path
            else {
                $request->Send301($request->{'path'}{'basename'}.'/');
            }            
        }
        else {
            $request->Send404;
        }       
    }
);

# finally start the server   
my $server = HTTP::BS::Server->new($SETTINGS, \@routes, \@plugins);

# really acquire media file (with search) and convert
sub get_video {
    my ($request) = @_;
    my ($client, $qs, $header) =  ($request->{'client'}, $request->{'qs'}, $request->{'header'});       
    say "/get_video ---------------------------------------";
    $qs->{'fmt'} //= 'noconv';
    my %video = ('out_fmt' => video_get_format($qs->{'fmt'}));
    if(defined($qs->{'name'})) {        
        if($video{'src_file'} = video_file_lookup($qs->{'name'})) {            
        }
        elsif($video{'src_file'} = media_file_search($qs->{'name'})) {
            say "useragent: " . $header->{'User-Agent'};
            # VLC 2 doesn't handle redirects? VLC 3 does
            if($header->{'User-Agent'} !~ /^VLC\/2\.\d+\.\d+\s/) {                
                my $url = 'get_video?' . $qs->{'querystring'};
                my $qname = uri_escape($video{'src_file'}{'fullname'});
                $url =~ s/name=[^&]+/name=$qname/;
                say "url: $url";
                $request->Send301($url);                
                return 1;
            }           
        }
        else {
            $request->Send404;
            return undef;
        }
        print Dumper($video{'src_file'});
        # no conversion necessary, just SEND IT
        if($video{'out_fmt'} eq 'noconv') {
            say "NOCONV: SEND IT";
            #$request->{'outheaders'}{'Icy-Name'} = 'Ice ice baby';
            $request->SendFile($video{'src_file'}{'filepath'});
            return 1;   
        }        

        $video{'out_base'} = $video{'src_file'}{'name'};
        if($video{'out_fmt'} eq 'm3u8') {
            my $m3u8 = video_get_m3u8(\%video, $SETTINGS->{'M3U8_URL'} . $request->{'path'}{'unsafepath'} . '?name=');
            #$request->{'outheaders'}{'Icy-Name'} = $video{'fullname'};
            $video{'src_file'}{'ext'} = $video{'src_file'}{'ext'} ? '.'. $video{'src_file'}{'ext'} : '';
            $request->SendLocalBuf($$m3u8, 'application/x-mpegURL', {'filename' => $video{'src_file'}{'name'} . $video{'src_file'}{'ext'} . '.m3u8'});
            return 1;            
        }  
        # virtual mkv
        elsif($video{'out_fmt'} eq 'mkv') {
            $video{'out_location'} = $SETTINGS->{'VIDEO_TMPDIR'} . '/' . $video{'out_base'};            
            video_matroska(\%video, $request);
            return 1;
        }      
        # soon https://github.com/video-dev/hls.js/pull/1899
        $video{'out_base'} = space2us($video{'out_base'}) if ($video{'out_fmt'} eq 'hls');        
    }
    elsif($VIDEOFORMATS{$video{'out_fmt'}}{'plugin'}) { 
        $video{'plugin'} = $VIDEOFORMATS{$video{'out_fmt'}}{'plugin'};
        if(!($video{'out_base'} = $video{'plugin'}->getOutBase($qs))) {
            $request->Send404;
            return undef;
        }   
    }
    else {
        $request->Send404;
        return undef;
    }
   
    # Determine the full path to the desired file
    my $fmt = $video{'out_fmt'};    
    $video{'out_location'} = $SETTINGS->{'VIDEO_TMPDIR'} . '/' . $video{'out_base'};    
    $video{'out_filepath'} = $video{'out_location'} . '/' . $video{'out_base'} . '.' . $VIDEOFORMATS{$video{'out_fmt'}}{'ext'};   

    # Serve it up if it has been created
    if(-e $video{'out_filepath'}) {        
        say $video{'out_filepath'} . " already exists";              
        $request->SendFile($video{'out_filepath'});
        return 1;        
    }
    # otherwise create it
    mkdir($video{'out_location'});
    if(($VIDEOFORMATS{$fmt}{'lock'} == 1) && (LOCK_WRITE($video{'out_filepath'}) != 1)) {
        say "FAILED to LOCK";
        # we should do something here 
    }
    if($video{'plugin'}) {
        $video{'plugin'}->downloadAndServe($request, \%video);
        return 1;
    } 
    elsif(defined($VIDEOFORMATS{$fmt}{'create_cmd'}) && ($VIDEOFORMATS{$fmt}{'create_cmd'}[0] ne '')) {       
        my @cmd;
        foreach my $cmdpart (@{$VIDEOFORMATS{$fmt}{'create_cmd'}}) {
            if($cmdpart =~ /^\$/) {
                push @cmd, eval($cmdpart);
            }
            else {
                push @cmd, $cmdpart;
            }                
        }
        print "$_ " foreach @cmd;
        print "\n";           
        
        video_on_streams(\%video, $request, sub {
        #say "there should be no pids around";
        #$request->Send404;
        #return undef; 

        if($fmt eq 'hls') {                    
            $video{'on_exists'} = \&video_hls_write_master_playlist;                                         
        }
        elsif($fmt eq 'dash') {
            $video{'on_exists'} = \&video_dash_check_ready;
        }
        
        # deprecated
        $video{'pid'} = ASYNC(\&shellcmd_unlock, \@cmd, $video{'out_filepath'});             
        
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
                 my $minsize = $VIDEOFORMATS{$fmt}{'minsize'};
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
        });                  
    }
    else {
        say "out_fmt: " . $video{'out_fmt'};
        $request->Send404;
        return undef;
    }
    return 1;    
}

sub ebml_read {
    my $ebml = $_[0];
    my $buf = \$_[1];
    my $amount = $_[2];
    my $lastelm = ($ebml->{'elements'} > 0) ? $ebml->{'elements'}[-1] : undef;
    return undef if($lastelm && defined($lastelm->{'size'}) && ($amount > $lastelm->{'size'}));
    
    my $amtread = read($ebml->{'fh'}, $$buf, $amount);
    if(! $amtread) {
        return $amtread;
    }

    foreach my $elem (@{$ebml->{'elements'}}) {
        if($elem->{'size'}) {
            $elem->{'size'} -= $amtread;
        }
    }
    return $amtread;    
}

sub ebml_seek {
    my ($ebml, $position, $whence) = @_;
    ($whence == SEEK_CUR) or die("unsupported seek");
    return undef if(($ebml->{'elements'} > 0) && $ebml->{'elements'}[-1]{'size'} && ($position > $ebml->{'elements'}[-1]{'size'}));
    return undef if(!seek($ebml->{'fh'}, $position, $whence));
    foreach my $elem (@{$ebml->{'elements'}}) {
        if($elem->{'size'}) {
            $elem->{'size'} -= $position;
        }
    }
    return 1;
}

sub read_vint_from_buf {
    my $bufref   = $_[0];
    my $savewidth = $_[1];

    my $width = 1;
    my $value = unpack('C', substr($$bufref, 0, 1, ''));
    for(;;$width++) {
        last if(($value << ($width-1)) & 0x80);
        $width < 9 or return undef;       
    }

    length($$bufref) >= ($width-1) or return undef;

    for(my $wcopy = $width; $wcopy > 1; $wcopy--) {
        $value <<= 8;
        $value |= unpack('C', substr($$bufref, 0, 1, ''));
    }

    $$savewidth = $width;
    return $value;
}

sub read_and_parse_vint_from_buf {
    my $bufref = $_[0];

    my $width;
    my $value = read_vint_from_buf($bufref, \$width);
    defined($value) or return undef;    

    my $andval = 0xFF >> $width;
    for(my $wcopy = $width; $wcopy > 1; $wcopy--) {
        $andval <<= 8;
        $andval |= 0xFF;               
    }
    $value &= $andval;
    return $value;     
}

sub read_vint {
    my ($ebml, $val, $savewidth) = @_;
    my $value;
    ebml_read($ebml, $value, 1) or return 0;
    my $width = 1;
    $value = unpack('C', $value);      
    for(;;$width++) {
        last if(($value << ($width-1)) & 0x80);
        $width < 9 or return 0;        
    }
    $$savewidth = $width;
    my $byte;
    for(; $width > 1; $width--) {
        $value <<= 8;
        ebml_read($ebml, $byte, 1) or return 0;
        $value |= unpack('C', $byte);
    }
    $$val = $value;
    return 1; 
}

sub read_and_parse_vint {
    my ($ebml, $val) = @_;
    my $value;
    my $width;
    read_vint($ebml, \$value, \$width) or return 0;
    my $andval = 0xFF >> $width;
    for(;$width > 1; $width--) {
        $andval <<= 8;
        $andval |= 0xFF;               
    }
    $value &= $andval;
    $$val = $value;
    return 1;
}

sub ebml_open {
    my ($filename) = @_;
    open(my $fh, "<", $filename) or return 0;
    my $magic;
    read($fh, $magic, 4) or return 0;
    $magic eq "\x1A\x45\xDF\xA3" or return 0;
    my $ebmlheadsize;
    my $ebml = {'fh' => $fh, 'elements' => []};
    read_and_parse_vint($ebml, \$ebmlheadsize) or return 0;
    seek($fh, $ebmlheadsize, SEEK_CUR) or return 0;    
    return $ebml;
}

sub ebml_read_element {
    my ($ebml) = @_;
    my $id;
    read_vint($ebml, \$id) or return undef;
    my $size;
    read_and_parse_vint($ebml, \$size) or return undef;
    my $elm = {'id' => $id, 'size' => $size};
    push @{$ebml->{'elements'}}, $elm;
    return $elm;
}

sub ebml_skip {
    my ($ebml) = @_;
    my $elm = $ebml->{'elements'}[-1];
    ebml_seek($ebml, $elm->{'size'}, SEEK_CUR) or return 0;
    pop @{$ebml->{'elements'}};
    return 1;
}

sub ebml_find_id {
    my ($ebml, $id) = @_;
    for(;;) {
        my $elm = ebml_read_element($ebml);
        $elm or return undef;        
        if($elm->{'id'} == $id) {
            return $elm;
        }
        #say "id " . $elm->{'id'};
        ebml_skip($ebml) or return undef;        
    }
}

sub ebml_make_elms {
    my @elms = @_;
    my @bufstack = ('');
    while(@elms) {
        my $elm = $elms[0];
        if(! $elm) {
            shift @elms;
            $elm = $elms[0];
            $elm->{'data'} = pop @bufstack;
        }
        elsif(! $elm->{'data'}) {
            @elms = (@{$elm->{'elms'}}, undef, @elms);
            push @bufstack, '';
            next;
        }
        shift @elms;
        my $elementid = $elm->{'id'};
        if(! $elementid) {
            print Dumper($elm);
            die;
        }    
        $elementid < 0xFFFFFFFF or return undef;
        my $data = \$elm->{'data'};
    
        my $size = length($$data);
        $size < 0xFFFFFFFFFFFFFF or return undef;
        # pack the id
        my $buf;
        if($elementid > 0xFFFFFF) {
            # pack BE uint32_t
            #$buf = pack('CCCC', ($elementid >> 24) & 0xFF, ($elementid >> 16) & 0xFF, ($elementid >> 8) & 0xFF, $elementid & 0xFF);
            $buf = pack('N', $elementid);
        }
        elsif($elementid > 0xFFFF) {
            # pack BE uint24_t
            $buf = pack('CCC', ($elementid >> 16) & 0xFF, ($elementid >> 8) & 0xFF, $elementid & 0xFF);
        }
        elsif($elementid > 0xFF) {
            # pack BE uint16_t
            #$buf = pack('CC', ($elementid >> 8) & 0xFF, $elementid & 0xFF);
            $buf = pack('n', $elementid);
        }
        else {
            # pack BE uint8_t
            $buf = pack('C', $elementid & 0xFF);
        }

        # pack the size
        if($elm->{'infsize'}) {
            $buf .= pack('C', 0xFF);            
        }
        else {
            # determine the VINT width and marker value, and the size needed for the vint
            my $sizeflag = 0x80;
            my $bitwidth = 0x8;
            while($size >= $sizeflag) {
                $bitwidth += 0x8;
                $sizeflag <<= 0x7;                
            }

            # Apply the VINT marker and pack the vint   
            $size |= $sizeflag;
            while($bitwidth) {
                $bitwidth -= 8;
                $buf .= pack('C', ($size >> $bitwidth) & 0xFF);
            }
        }
        
        # pack the data
        $buf .= $$data;
        $bufstack[-1] .= $buf;
    }
    
    return \$bufstack[0];
}


use constant {
        'EBMLID_EBMLHead'           => 0x1A45DFA3,
        'EBMLID_EBMLVersion'        => 0x4286,
        'EBMLID_EBMLReadVersion'    => 0x42F7,
        'EBMLID_EBMLMaxIDLength'    => 0x42F2,
        'EBMLID_EBMLMaxSizeLength'  => 0x42F3,
        'EBMLID_EBMLDocType'        => 0x4282,
        'EBMLID_EBMLDocTypeVer'     => 0x4287,
        'EBMLID_EBMLDocTypeReadVer' => 0x4285,
        'EBMLID_Segment'            => 0x18538067,
        'EBMLID_SegmentInfo'        => 0x1549A966,
        'EBMLID_TimestampScale'     => 0x2AD7B1,
        'EBMLID_Duration'           => 0x4489,
        'EBMLID_MuxingApp'          => 0x4D80,
        'EBMLID_WritingApp'         => 0x5741,
        'EBMLID_Tracks'             => 0x1654AE6B,
        'EBMLID_Track'              => 0xAE,
        'EBMLID_TrackNumber'        => 0xD7,
        'EBMLID_TrackUID'           => 0x73C5,        
        'EBMLID_TrackType'          => 0x83,
        'EBMLID_CodecID'            => 0x86,
        'EBMLID_CodecPrivData',     => 0x63A2,
        'EBMLID_AudioTrack'         => 0xE1,
        'EBMLID_AudioChannels'      => 0x9F,
        'EBMLID_AudioSampleRate'    => 0xB5,
        'EBMLID_AudioBitDepth'      => 0x6264,
        'EBMLID_Cluster'            => 0x1F43B675,
        'EBMLID_ClusterTimestamp'   => 0xE7,
        'EBMLID_SimpleBlock'        => 0xA3,
        'EBMLID_BlockGroup'         => 0xA0,
        'EBMLID_Block'              => 0xA1
    };

sub matroska_cluster_parse_simpleblock_or_blockgroup {
    my ($elm) = @_;

    my $data = $elm->{'data'};
    if($elm->{'id'} == EBMLID_BlockGroup) {
        say "blockgroup";
        while(1) {
            my $width;
            my $id = read_vint_from_buf(\$data, \$width);
            defined($id) or return undef;
            my $size = read_and_parse_vint_from_buf(\$data);
            defined($size) or return undef;
            say "blockgroup item: $id $size";
            last if($id == EBMLID_Block);
            substr($data, 0, $size, '');
        }
        say "IS BLOCK";
    }
    elsif($elm->{'id'} == EBMLID_SimpleBlock) {
        say "IS SIMPLEBLOCK";
    }
    else {
        die "unhandled block type";
    }
    my $trackno = read_and_parse_vint_from_buf(\$data);
    if((!defined $trackno) || (length($data) < 3)) {
        return undef;
    }
    my $rawts = substr($data, 0, 2, '');
    my $rawflag = substr($data, 0, 1, '');

    return {
        'trackno' => $trackno,
        'rawts' => $rawts,
        'rawflag'  => $rawflag
    };
}

sub telmval {
        my ($track, $stringid) = @_;
        my $constname = "EBMLID_$stringid";
        my $id = App::MHFS->$constname;
        return $track->{$id}{'value'}  // $track->{$id}{'data'};
        #return $track->{"$stringid"}}{'value'} // $track->{$EBMLID->{$stringid}}{'data'};
    }

sub trackno_is_audio {
    my ($tracks, $trackno) = @_;
    foreach my $track (@$tracks) {
        if(telmval($track, 'TrackNumber') == $trackno) {
            return telmval($track, 'TrackType') == 0x2;
        }
    }
    return undef;
}

sub flac_read_METADATA_BLOCK {
    my $fh = $_[0];
    my $type = \$_[1];
    my $done = \$_[2];
    my $buf;
    my $headread = read($fh, $buf, 4);
    ($headread && ($headread == 4)) or return undef;
    my ($blocktypelast, $sizehi, $sizemid, $sizelo) = unpack('CCCC',$buf);
    $$done = $blocktypelast & 0x80;
    $$type = $blocktypelast & 0x7F;
    my $size = ($sizehi << 16) | ($sizemid << 8) | ($sizelo);
    #say "islast $$done type $type size $size";
    $$type != 0x7F or return undef;
    my $tbuf;
    my $dataread = read($fh, $tbuf, $size);
    ($dataread && ($dataread == $size)) or return undef;
    $buf .= $tbuf;
    return \$buf;
}

sub flac_parseStreamInfo {
        # https://metacpan.org/source/DANIEL/Audio-FLAC-Header-2.4/Header.pm
        my ($buf) = @_;
        my $metaBinString = unpack('B144', $buf);
 
        my $x32 = 0 x 32;
        my $info = {};
        $info->{'MINIMUMBLOCKSIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 0, 16), -32)));
        $info->{'MAXIMUMBLOCKSIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 16, 16), -32)));
        $info->{'MINIMUMFRAMESIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 32, 24), -32)));
        $info->{'MAXIMUMFRAMESIZE'} = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 56, 24), -32)));
 
        $info->{'SAMPLERATE'}       = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 80, 20), -32)));
        $info->{'NUMCHANNELS'}      = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 100, 3), -32))) + 1;
        $info->{'BITSPERSAMPLE'}    = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 103, 5), -32))) + 1;
 
        # Calculate total samples in two parts
        my $highBits = unpack('N', pack('B32', substr($x32 . substr($metaBinString, 108, 4), -32)));
 
        $info->{'TOTALSAMPLES'} = $highBits * 2 ** 32 +
                unpack('N', pack('B32', substr($x32 . substr($metaBinString, 112, 32), -32)));
 
        # Return the MD5 as a 32-character hexadecimal string
        $info->{'MD5CHECKSUM'} = unpack('H32',substr($buf, 18, 16));
        return $info; 
    }

sub flac_read_to_audio {
    my ($fh) = @_;
    my $buf;    
    my $magic = read($fh, $buf, 4);
    ($magic && ($magic == 4)) or return undef;
    my $streaminfo;
    for(;;) {
        my $type;
        my $done;
        my $bref = flac_read_METADATA_BLOCK($fh, $type, $done);
        $bref or return undef;
        $buf .= $$bref;
        if($type == 0) {
            $streaminfo = flac_parseStreamInfo(substr($$bref, 4));
        }
        last if($done);
    }
    return {'streaminfo' => $streaminfo, 'buf' => \$buf};
}

sub video_matroska {
    my ($video, $request) = @_;

    my $ebml = ebml_open($video->{'src_file'}{'filepath'});
    if(! $ebml) {
        $request->Send404;
        return;
    }

    # find segment
    my $foundsegment = ebml_find_id($ebml, EBMLID_Segment);
    if(!$foundsegment) {
        $request->Send404;
        return;
    }
    say "Found segment";
    my %segment = (id => EBMLID_Segment, 'infsize' => 1, 'elms' => []);    

    # find segment info
    my $foundsegmentinfo = ebml_find_id($ebml, EBMLID_SegmentInfo);
    if(!$foundsegmentinfo) {
        $request->Send404;
        return;
    }
    say "Found segment info";
    my %segmentinfo = (id => EBMLID_SegmentInfo, elms => []);

    # find TimestampScale
    my $tselm = ebml_find_id($ebml, EBMLID_TimestampScale);
    if(!$tselm) {
        $request->Send404;
        return;
    }
    say "Found ts elm";
    my $tsbinary;
    if(!ebml_read($ebml, $tsbinary, $tselm->{'size'})) {
        $request->Send404;
        return;
    }
    Dump($tsbinary);
    if(!ebml_skip($ebml)) {
        $request->Send404;
        return;
    }
    push @{$segmentinfo{'elms'}}, {id => EBMLID_TimestampScale, data => $tsbinary};

    # find Duration
    my $durationelm = ebml_find_id($ebml, EBMLID_Duration);
    if(!$durationelm) {
        $request->Send404;
        return;
    }
    say "Found duration elm";
    my $durbin;
    if(!ebml_read($ebml, $durbin, $durationelm->{'size'})) {
        $request->Send404;
        return;
    }
    Dump($durbin);
    if(!ebml_skip($ebml)) {
        $request->Send404;
        return;
    }
    if(!ebml_skip($ebml)) {
        $request->Send404;
        return;
    }
    push @{$segmentinfo{'elms'}}, {id => EBMLID_Duration, data => $durbin};

    # set multiplexing app and writing application
    push @{$segmentinfo{'elms'}}, {id => EBMLID_MuxingApp, data => 'mhfs-alpha_0'};
    push @{$segmentinfo{'elms'}}, {id => EBMLID_WritingApp, data => 'mhfs-alpha_0'};
    
    push @{$segment{'elms'}}, \%segmentinfo;

    # find Tracks
    my $in_tracks = ebml_find_id($ebml, EBMLID_Tracks);
    if(!$in_tracks) {
        $request->Send404;
        return;
    }
    # loop through the Tracks
    my @tracks;
    for(;;) {
        my $in_track = ebml_find_id($ebml, EBMLID_Track);
        if(! $in_track) {
            ebml_skip($ebml);
            last;
        }       
        my %track = ('id' => EBMLID_Track, 'elms' => []);
        for(;;) {
            my $telm = ebml_read_element($ebml);
            if(!$telm) {
                ebml_skip($ebml);
                last;
            }

            # save the element into tracks
            my %elm = ('id' => $telm->{'id'}, 'data' => '');         
            ebml_read($ebml, $elm{'data'}, $telm->{'size'});
            if($elm{'id'} == EBMLID_TrackNumber) {
                say "trackno";
                $elm{'value'} = unpack('C', $elm{'data'});
                $track{$elm{'id'}} = \%elm;
            }
            elsif($elm{'id'} == EBMLID_CodecID) {
                say "codec";
                $track{$elm{'id'}} = \%elm;
            }
            elsif($elm{'id'} == EBMLID_TrackType) {
                say "tracktype";
                $elm{'value'} = unpack('C', $elm{'data'});
                $track{$elm{'id'}} = \%elm;
            }
            elsif($elm{'id'} == EBMLID_TrackUID) {
                say "trackuid";
                $track{$elm{'id'}} = \%elm;
            }
            push @{$track{'elms'}}, \%elm;
                         
            ebml_skip($ebml);
        }         
        push @tracks, \%track;
    }
    if(scalar(@tracks) == 0) {
        $request->Send404;
        return;
    }
    #print Dumper(@tracks);
    

    # Build the Tracks element
    for my $track (@tracks) {
        say "Track codec: " . telmval($track, 'CodecID') . ' no ' . telmval($track, 'TrackNumber');

        # remake the Track if it's audio and not in FLAC
        if((telmval($track, 'TrackType') == 0x2) && (telmval($track, 'CodecID') ne 'A_FLAC')) {            
            my $flacpath = $video->{'out_location'} . '/' . $video->{'out_base'} . '.' . telmval($track, 'TrackNumber') . '.flac';
            if(! -e $flacpath) {
                mkdir($video->{'out_location'});
                my @cmd = ('ffmpeg', '-i', $video->{'src_file'}{'filepath'}, '-map', '0:'.(telmval($track, 'TrackNumber')-1), $flacpath);
                print Dumper(\@cmd);
                if(!(system(@cmd) == 0)) {
                    say "failed to extract audio track";
                    $request->Send404;
                    return;
                }
                say "converted"; 
            }
            # read the info necessary to make the new flac track
            if(!open($track->{'fh'}, "<", $flacpath)) {
                $request->Send404;
                return;
            }
            my $flac = flac_read_to_audio($track->{'fh'});
            if(! $flac) {
                $request->Send404;
                return;
            }
            
            # replace the track with the new flac track
            my $oldelms = $track->{'elms'};
            $track->{+EBMLID_CodecID}{'data'} = 'A_FLAC';
            $track->{'elms'} = [
                $track->{+EBMLID_TrackNumber},
                $track->{+EBMLID_TrackUID},
                $track->{+EBMLID_CodecID},
                $track->{+EBMLID_TrackType},
                {
                    id => EBMLID_AudioTrack,
                    elms => [
                        {
                            id => EBMLID_AudioChannels,
                            data => pack('C', $flac->{'streaminfo'}{'NUMCHANNELS'})
                        },
                        {
                            id => EBMLID_AudioSampleRate,
                            data => pack('d>', $flac->{'streaminfo'}{'SAMPLERATE'})
                        },
                        {
                            id => EBMLID_AudioBitDepth,
                            data => pack('C', $flac->{'streaminfo'}{'BITSPERSAMPLE'})
                        }
                    ]
                },
                {
                    id => EBMLID_CodecPrivData,
                    data => ${$flac->{'buf'}}
                }
            ];         
        }     
    }
    push @{$segment{'elms'}}, {
        'id' => EBMLID_Tracks,
        'elms' => \@tracks        
    };
           
    my %elmhead = ('id' => EBMLID_EBMLHead, 'elms' => [
        {
            id => EBMLID_EBMLVersion,
            data => pack('C', 1)
        },
        {
            id => EBMLID_EBMLReadVersion,
            data => pack('C', 1)
        },
        {
            id => EBMLID_EBMLMaxIDLength,
            data => pack('C', 4)
        },
        {
            id => EBMLID_EBMLMaxSizeLength,
            data => pack('C', 8)
        },
        {
            id => EBMLID_EBMLDocType,
            data => 'matroska'
        },
        {
            id => EBMLID_EBMLDocTypeVer,
            data => pack('C', 4)
        },
        {
            id => EBMLID_EBMLDocTypeReadVer,
            data => pack('C', 2)
        },
    ]);

    #print Dumper(\%segment);
    #die;
 
    my $ebml_serialized = ebml_make_elms(\%elmhead, \%segment);
    if(!$ebml_serialized) {
        $request->Send404;
        return;
    }

    # loop thorough the clusters
    my @outclusters;
    while(1) {
        my $custer = ebml_find_id($ebml, EBMLID_Cluster);
        last if(! $custer);

        my %outcluster = ('id' => EBMLID_Cluster, elms => []);
        for(;;) {
            my $belm = ebml_read_element($ebml);
            if(!$belm) {
                ebml_skip($ebml);
                last;
            }
            my %elm = ('id' => $belm->{'id'}, 'data' => '');
            say "elm size " . $belm->{'size'};          
            
            ebml_read($ebml, $elm{'data'}, $belm->{'size'});
            if(($elm{'id'} == EBMLID_SimpleBlock) || ($elm{'id'} == EBMLID_BlockGroup)) {
                my $block = matroska_cluster_parse_simpleblock_or_blockgroup(\%elm);
                print Dumper($block);
                if($block && trackno_is_audio(\@tracks, $block->{'trackno'})) {
                    say "block is audio";
                    ebml_skip($ebml);
                    next;
                }                
            }                                           

            push @{$outcluster{'elms'}}, \%elm;                         
            ebml_skip($ebml);
        }
        push @outclusters, \%outcluster;
        #last;     
    }
    my $serializedclusters = ebml_make_elms(@outclusters);
    if(!$serializedclusters) {
        $request->Send404;
        return;
    }
    $$ebml_serialized .= $$serializedclusters;

    $request->SendLocalBuf($$ebml_serialized, 'video/x-matroska', {'filename' => $video->{'out_base'} .'.mhfs.mkv'});
}

sub video_get_format {
    my ($fmt) = @_; 
    if(!defined($fmt) || !defined($VIDEOFORMATS{$fmt})) {
        $fmt = 'noconv';
    }
    return $fmt;
}

sub video_file_lookup {
    my ($filename) = @_; 
    my @locations = ($SETTINGS->{'MEDIALIBRARIES'}{'movies'}, $SETTINGS->{'MEDIALIBRARIES'}{'tv'}, $SETTINGS->{'MEDIALIBRARIES'}{'music'});    
    my $filepath;
    my $flocation;
    foreach my $location (@locations) {
        my $absolute = abs_path("$location/$filename");
        if($absolute && -e $absolute  && ($absolute =~ /^$location/)) {
            $filepath = $absolute;
            $flocation = $location;
            last;
        }
    }    
    return if(! $filepath);

    return media_filepath_to_src_file($filepath, $flocation);  
}

sub video_on_streams {
    my ($video, $request, $continue) = @_;
    $video->{'audio'} = [];
    $video->{'video'} = [];
    $video->{'subtitle'} = [];
    my $input_file = $video->{'src_file'}{'filepath'};    
    my @command = ('ffmpeg', '-i', $input_file);
    my $evp = $request->{'client'}{'server'}{'evp'};
    HTTP::BS::Server::Process->new_output_process($evp, \@command, sub {
        my ($output, $error) = @_;
        my @lines = split(/\n/, $error);
        my $current_stream;
        my $current_element;
        foreach my $eline (@lines) {
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
        $continue->();
    });
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
    my ($filepath, $flocation) = @_;
    my ($name, $loc, $ext) = fileparse($filepath, '\.[^\.]*');
    $ext =~ s/^\.//;
    return { 'filepath' => $filepath, 'name' => $name, 'containingdir' => $loc, 'ext' => $ext, 'fullname' => substr($filepath, length($flocation)+1), 'root' => $flocation};
}

sub media_file_search {
    my ($filename) = @_;
    my @locations = ($SETTINGS->{'MEDIALIBRARIES'}{'movies'}, $SETTINGS->{'MEDIALIBRARIES'}{'tv'}, $SETTINGS->{'MEDIALIBRARIES'}{'music'});

    say "basename: " . basename($filename) . " dirname: " . dirname($filename);
    my $dir = dirname($filename);
    $dir = undef if ($dir eq '.');    
    my $filepath = FindFile(\@locations, basename($filename), $dir);
    return if(! $filepath);
    
    # a better find algorithm would tell us $location so we don't have to find it again
    my $flocation;    
    foreach my $location(@locations) {
        if(rindex($filepath, $location, 0) == 0) {
            $flocation = $location;
            last;
        }        
    }
    return media_filepath_to_src_file($filepath, $flocation);     
}

sub GetResource {
    my ($filename) = @_;
    $RESOURCES{$filename} //= read_file($filename); 
    return \$RESOURCES{$filename};
}

sub ptp_request {
    my ($evp, $url, $handler, $tried_login) = @_;
    my $atbuf;
    my @cmd = ('curl', '-s', '-v', '-b', '/tmp/ptp', '-c', '/tmp/ptp', $SETTINGS->{'PTP'}{'url'}.'/' . $url);

    my $process;
    $process    = HTTP::BS::Server::Process->new_output_process($evp, \@cmd, sub {
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
            my @logincmd = ('curl', '-s', '-v', '-b', '/tmp/ptp', '-c', '/tmp/ptp', '-d', $postdata, $SETTINGS->{'PTP'}{'url'}.'/ajax.php?action=login');
            $process = HTTP::BS::Server::Process->new_output_process($evp, \@logincmd, sub {
                 my ($output, $error) = @_;
                 # todo error handling
                 ptp_request($evp, $url, $handler, 1);            
            
            });
                        
        }
    });
    return $process;
}

sub rtxmlrpc {
    my ($evp, $params, $cb) = @_;
    my $process;
    my @cmd = ('rtxmlrpc', @$params, '--config-dir', $SETTINGS->{'CFGDIR'} . '/.pyroscope/');
    $process    = HTTP::BS::Server::Process->new_output_process($evp, \@cmd, sub {
        my ($output, $error) = @_;
        chomp $output;
        #say 'rtxmlrpc output: ' . $output;
        $cb->($output);   
    });
    return $process;
}

sub lstor {
    my ($evp, $params, $cb) = @_;
    my $process;
    my @cmd = ('lstor', '-q', @$params);
    $process    = HTTP::BS::Server::Process->new_output_process($evp, \@cmd, sub {
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


sub torrent_d_name {
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

sub player_video_browsemovies {
    my ($request, $buf) = @_;
    my $evp = $request->{'client'}{'server'}{'evp'}; 
    my $qs = $request->{'qs'};   
    $buf .= '<h1>Browse Movies</h1>';
    $buf .= '<h3><a href="video">Video</a> | <a href="music">Music</a></h3>';        
    $buf .= '<form action="video" method="GET">';
    $buf .= '<input type="hidden" name="action" value="browsemovies">';
    $buf .= '<input type="text" placeholder="Search" name="searchstr" class="searchfield">';
    $buf .= '<button type="submit">Search</button>';
    $buf .= '</form>';  
    $qs->{'searchstr'} //= '';
    my $url = 'torrents.php?searchstr=' . $qs->{'searchstr'} . '&json=noredirect';
    if( $qs->{'page'}) {
        $qs->{'page'} = int($qs->{'page'});
        $url .= '&page=' . $qs->{'page'} ; 
    }                
    ptp_request($evp, $url, sub {        
        my ($result) = @_;
        if(! $result) {
            $buf .= '<h2>Search Failed</h2>';              
        }
        else {                
            # get a list of movies on disk
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

            # compare with the search results and display
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

            # navigation between pages of search results
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
        $request->SendLocalBuf(encode_utf8($buf), "text/html");
    
    });
}

sub player_video {
    my ($request) = @_;
    my $qs = $request->{'qs'};   
   
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
        player_video_browsemovies($request, $buf);   
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
    my $fmt = video_get_format($qs->{'fmt'});
    foreach my $library (@libraries) {
        my $dir = $SETTINGS->{'MEDIALIBRARIES'}{$library};
        (-d $dir) or next;
        $buf .= "<h1>" . $libraryprint{$library} . "</h1>\n";        
        $temp = video_library_html($dir, {'fmt' => $fmt});
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
    $request->SendLocalBuf(encode_utf8($buf), "text/html; charset=utf-8"); 
}

sub video_library_html {
    my ($dir, $opt) = @_;
    my $fmt = $opt->{'fmt'};
    my $buf = '<ul>';
    output_dir_versatile($dir, {
        'root' => $dir,
        'min_file_size' => 100000,
        'on_dir_start' => sub {
            my ($path, $file) = @_;
            my $safename = escape_html($file);  
            $buf .= '<li><div class="row">';
            $buf .= '<a href="#' . $$safename . '_hide" class="hide" id="' . $$safename . '_hide">' . "$$safename</a>";
            $buf .= '<a href="#' . $$safename . '_show" class="show" id="' . $$safename . '_show">' . "$$safename</a>";
            $buf .= '    <a href="get_video?name=' . $$safename . '&fmt=m3u8">M3U</a>';                
            $buf .= '<div class="list"><ul>';           
        },
        'on_dir_end' => sub {
            $buf .= '</ul></div></div></li>';  
        },
        'on_file' => sub {            
            my ($path, $unsafePath, $file) = @_;
            my $safe_item_basename = escape_html($file);
            my $item_path = escape_html($unsafePath);            
            $buf .= '<li><a href="video?name='.$$item_path.'&fmt=' . $fmt . '" data-file="'. $$item_path . '">' . $$safe_item_basename . '</a>    <a href="get_video?name=' . $$item_path . '&fmt=' . $fmt . '">DL</a>    <a href="get_video?name=' . $$item_path . '&fmt=m3u8">M3U</a></li>';        
        }    
    });
    $buf .=  '</ul>';
    return \$buf;
}

sub video_get_m3u8 {
    my ($video, $urlstart) = @_;
    my $buf;
    my $m3u8 = <<'M3U8END';
#EXTM3U
#EXTVLCOPT:network-caching=40000'
M3U8END

    my @files;
    if(! -d $video->{'src_file'}{'filepath'}) {
        push @files, $video->{'src_file'}{'fullname'};
    }
    else {
        output_dir_versatile($video->{'src_file'}{'filepath'}, {
            'root' => $video->{'src_file'}{'root'},
            'on_file' => sub {
                my ($path, $shortpath) = @_;
                push @files, $shortpath;            
            }   
        });    
    }
    
    foreach my $file (@files) {
        $m3u8 .= '#EXTINF:0, ' . $file . "\n";
        $m3u8 .= $urlstart . $file . "\n";
    }
    return \$m3u8;
}





}
1;

