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
    #my $seconds = int($ttime);
    #$ttime -= $seconds;
    #say "ttime $ttime";
    #my $mili = int($ttime * 1000000);
    #say "mili $mili";
    #my $tstring = sprintf "%02d:%02d:%02d.%06d", $hours, $minutes, $seconds, $mili;
    my $tstring = sprintf "%02d:%02d:%f", $hours, $minutes, $ttime;
    return $tstring;
}

sub get_end_time {
    my ($segnum) = @_;
    my $deslen = 5;
    my $destime = ($segnum+1) * $deslen;
    my $floatseg = ($destime * 44100) / 1024;
    my $lower = (int($floatseg)*1024)/44100;
    my $higher = (int($floatseg + 0.5)*1024)/44100;
    my $etime;
    if(abs($destime - $lower) < abs($higher - $destime)) {
        $etime = $lower;
    }
    else {
        $etime = $higher;
    }
    return $etime;
}

sub hls_audio_get_actual_time {
    my ($destime) = @_;
    my $floatseg = ($destime * 44100) / 1024;
    my $lower = (int($floatseg)*1024)/44100;
    my $higher = (int($floatseg + 0.5)*1024)/44100;
    my $etime;
    if(abs($destime - $lower) < abs($higher - $destime)) {
        $etime = $lower;
    }
    else {
        $etime = $higher;
    }
    return $etime;
}

sub round_down {
    my ($time) = @_;
    return (int($time*1000)-1) / 1000; # Forbidden (hack for sample accurate times)
}

sub hls_audio_get_seg {
    my ($number) = @_;


    my $fullstime = 0;

    my $target = 0;
    my $lasttime = 0;
    for(my $i = 0; $i <= $number; $i++) {
        $fullstime = $lasttime;

        $target += 5;
        my $atarget = ($target - $lasttime);
        $lasttime = hls_audio_get_actual_time($atarget)+$fullstime;
    }

    my $fullendtime = $lasttime;
    my $startstr = formattime($fullstime > 0 ? round_down($fullstime) : $fullstime);
    my $endstr = formattime(round_down($fullendtime));

    #my $startstr = "00:00:00";
    #if($number > 0) {
    #    $fullstime = get_end_time($number-1);
    #    my $stime = round_down($fullstime);
    #    $startstr = formattime($stime);
    #}
    #my $fullendtime = get_end_time($number);
    #my $endtime = round_down($fullendtime);
    #my $endstr = formattime($endtime);
    return {'startstr' => $startstr, 'endstr' => $endstr, 'etime' => $fullendtime, 'stime' => $fullstime};
}

sub get_id3 {
    my ($time) = @_;

    my $tstime = int($time*90000)+126000;
    my $packedtstime = $tstime & 0x1FFFFFFFF; # 33 bits

    my $id3 = 'ID3'.pack('CCCCCCC', 0x4, 0, 0, 0, 0, 0, 0x3F).
    'PRIV'.pack('CCCCCC', 0, 0, 0, 0x35, 0, 0).
    'com.apple.streaming.transportStreamTimestamp'.pack('C', 0).
    pack('Q>', $packedtstime);

    return $id3;
}


#22:33.14
my $maxtime = (22*60+(33.14));
my @segments;
my $ctime = 0;
my $dtime = 5;
my $segnum = 0;
my $outputoffsetstr = "00:00:00";
while($ctime < $maxtime) {
    #my $startstr = formattime($ctime);
#
    #my $floatseg = ($dtime * 44100) / 1024;
    #my $lower = (int($floatseg)*1024)/44100;
    #my $higher = (int($floatseg + 0.5)*1024)/44100;
    #my $etime;
    #if(abs($dtime - $lower) < abs($higher - $dtime)) {
    #    $etime = $lower;
    #}
    #else {
    #    $etime = $higher;
    #}
    #my $brokenendtime = $etime;
    #$brokenendtime = (int($etime*1000)-1) / 1000; # Forbidden (hack for sample accurate times)
    #my $endstr = formattime($brokenendtime);
    #say "etime $etime, endstr $endstr btime $brokenendtime";
#
    #say "start $startstr end $endstr delta " . formattime($etime-$ctime) . 'offsettime ' . $outputoffsetstr;
    ##my $filename = sprintf("ed%d.ts", $segnum);
    ##system('ffmpeg', '-i', $infile, '-ss', $startstr, '-to', $endstr, '-vn', '-c', 'copy', '-f', 'mpegts', '-output_ts_offset', $outputoffsetstr, $filename) == 0 or die('failed to transcode');
    #my $filename = sprintf("ed%d.adts", $segnum);
    #system('ffmpeg', '-i', $infile, '-ss', $startstr, '-to', $endstr, '-vn', '-c', 'copy', '-f', 'adts', $filename) == 0 or die('failed to transcode');
    #push @segments, $filename;
#
    #$outputoffsetstr = formattime($etime);
    #$etime = $brokenendtime;
    #$ctime = $etime;
    #$dtime += 5;
    #$segnum++;

    my $filename = sprintf("ed%d.adts", $segnum);
    my $tstrings = hls_audio_get_seg($segnum);
    my $startstr = $tstrings->{'startstr'};
    my $endstr   = $tstrings->{'endstr'};
    say "start $startstr end $endstr delta " . formattime($tstrings->{'etime'}-$tstrings->{'stime'});
    system('ffmpeg', '-i', $infile, '-ss', $startstr, '-to', $endstr, '-vn', '-c', 'copy', '-f', 'adts', $filename) == 0 or die('failed to transcode');
    #push @segments, $filename;
    $segnum++;
    $ctime = $tstrings->{'etime'};

    open(my $out, '>', $filename.'.id3.adts') or die('unable to open id3 file');
    print $out get_id3($tstrings->{'stime'});
    open(my $in, '<', $filename) or die('unable to open src file');
    my $buf;
    while(read($in, $buf, 16384)) {
        print $out $buf;
    }
    close($in);
    close($out);
    push @segments, $filename.'.id3.adts';
}

my $concatstr = 'concat:';
open(my $fh, '>', 'list.txt') or die('could not open list');
foreach my $file (@segments) {
    $concatstr .= "$file|";
    print $fh "file '$file'\n";
}
close($fh);


system('ffmpeg', '-f', 'concat', '-i', 'list.txt', '-c', 'copy', 'concat.adts') == 0 or die('failed to concat');
#chop $concatstr;
#system('ffmpeg', '-i', $concatstr, '-c', 'copy', 'concat.aac') == 0 or die('failed to concat');