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