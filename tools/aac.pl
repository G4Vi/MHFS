#!/usr/bin/perl

use strict; use warnings;
use feature 'say';

scalar(@ARGV) == 1 or die('no file supplied');
my $infile = $ARGV[0];

sub formattime {
    my ($ttime) = @_;
    my $hours = int($ttime / 3600);
    $ttime -= ($hours * 3600);
    my $minutes = int($ttime / 60);
    $ttime -= ($minutes*60);
    my $seconds = int($ttime);
    $ttime -= $seconds; 
    my $mili = int($ttime * 1000000);
    my $tstring = sprintf "%02d:%02d:%02d.%06d", $hours, $minutes, $seconds, $mili;
    #my $tstring = sprintf "%02d:%02d:%02f", $hours, $minutes, $ttime;
    return $tstring;
}


#22:33.14
my $maxtime = (22*60+(33.14));
my @segments;
my $ctime = 0;
my $dtime = 5;
my $segnum = 0;
while($ctime < $maxtime) {
    my $startstr = formattime($ctime);

    my $floatseg = ($dtime * 44100) / 1024;
    my $lower = (int($floatseg)*1024)/44100;
    my $higher = (int($floatseg + 0.5)*1024)/44100;
    my $etime;
    if(abs($dtime - $lower) < abs($higher - $dtime)) {
        $etime = $lower;
    }
    else {
        $etime = $higher;
    }
    my $brokenendtime = $etime;
    $brokenendtime = (int($etime*1000)-1) / 1000; # Forbidden (hack for sample accurate times)
    $etime = $brokenendtime;
    my $endstr = formattime($brokenendtime);
   
    my $filename = sprintf("ed%d.ts", $segnum);
    my $outputoffsetstr = $startstr; #fix this to use precise start
    say "start $startstr end $endstr delta " . formattime($etime-$ctime) . 'offsettime ' . $outputoffsetstr;
    # '-output_ts_offset', $startstr,
    system('ffmpeg', '-i', $infile, '-ss', $startstr, '-to', $endstr, '-vn', '-c', 'copy', '-f', 'mpegts', '-output_ts_offset', $outputoffsetstr, $filename) == 0 or die('failed to transcode');
    push @segments, $filename;
    $ctime = $etime;
    $dtime += 5;
    $segnum++;
}

exit 0;

my $concatstr = 'concat:';
open(my $fh, '>', 'list.txt') or die('could not open list');
foreach my $file (@segments) {
    $concatstr .= "$file|";
    print $fh "file '$file'\n";
}
close($fh);


system('ffmpeg', '-f', 'concat', '-i', 'list.txt', '-c', 'copy', 'concat.aac') == 0 or die('failed to concat');
#chop $concatstr;
#system('ffmpeg', '-i', $concatstr, '-c', 'copy', 'concat.aac') == 0 or die('failed to concat');