#!/usr/bin/perl5
package youtubedl {
use strict; use warnings;
use feature 'say';
use Inline::Python qw(py_eval py_bind_class py_bind_func);
py_eval(<<'END_OF_PYTHON_CODE');
from __future__ import unicode_literals
import sys, youtube_dl
END_OF_PYTHON_CODE
py_bind_func("youtubedl::YoutubeDL", "youtube_dl", "YoutubeDL");
1;
};

use strict; use warnings;
use feature 'say';
package myLogger {
    use strict; use warnings;
    use feature 'say';
    sub new {
        my $class = shift;
        return bless {}, $class;
    }
    sub debug {
    }

    sub warning {
        my ($self, $msg) = @_;
        warn "warning " . $msg;
    }

    sub error {
    }
    1;
};

sub my_hook {
    my ($d) = @_;
    print 'file size ' . $d->{'total_bytes'} if(defined $d->{'total_bytes'});
    if(defined $d->{'downloaded_bytes'}) {
        print 'downloaded_bytes ' . $d->{'downloaded_bytes'};
        print 'tmpfilename ' . $d->{'tmpfilename'} if($d->{'tmpfilename'} && (-e $d->{'tmpfilename'}));
        print ' it exists ' if(-e $d->{'filename'}); 
    }
    print "\n";
    say 'Done downloading ...' if($d->{'status'} eq 'finished');    
}

my $outtmpl = '%(id)s.%(ext)s';
#my $outtmpl = '-';
utf8::upgrade($outtmpl);
my $opts = {
    'format' => 'bestaudio',
    'logger' => new myLogger,
    'progress_hooks' => [\&my_hook],
    'outtmpl' => $outtmpl,
    'nopart' => 1
};

my $ytmusicdl = youtubedl::YoutubeDL($opts);
if(fork() == 0) {
    $ytmusicdl->download(['https://www.youtube.com/watch?v=9bZkp7q19f0']);
}
wait();

