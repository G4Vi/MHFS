// TODO
// SBAR seek while loading

// BEGIN globals
// DOM globals
var prevbtn    = document.getElementById("prevbtn");
var sktxt      = document.getElementById("seekfield");
var seekbar    = document.getElementById("seekbar");
var ppbtn      = document.getElementById("ppbtn");
var rptrackbtn = document.getElementById("repeattrack");
var curtimetxt = document.getElementById("curtime");
var endtimetxt = document.getElementById("endtime");
var nexttxt    = document.getElementById('next_text');
var prevtxt    = document.getElementById('prev_text');
var playtxt    = document.getElementById('play_text');
var dbarea     = document.getElementById('musicdb');

var MAX_SAMPLE_RATE;
var BITDEPTH;
var USESEGMENTS;
var PTrackUrlParams;
const BUFFER_MS = 300;
const BUFFER_S = (BUFFER_MS / 1000);
var State = 'IDLE';
var CurrentTrack = 0;
var Tracks = [];
var DLImmediately = true;
var SBAR_UPDATING = 0;
var RepeatTrack = 0;
var MainAudioContext;
var NextBufferTime;
var BIndex = 0;
var PlaybackQueue = [];

// END globals

// BEGIN DOM helper functions
function SetCurtimeText(seconds) {   
    curtimetxt.value = seconds.toHHMMSS();
}

function SetEndtimeText(seconds) {   
    endtimetxt.value = seconds.toHHMMSS();
}

function SetNextText(text) {
    nexttxt.innerHTML = '<span>' + text + '</span>';
}

function SetPrevText(text) {
    prevtxt.innerHTML = '<span>' + text + '</span>';
}

function SetPlayText(text) {
    playtxt.innerHTML = '<span>' + text + '</span>';
}

function SetSeekbarValue(seconds) {
    seekbar.value = seconds;           
}

function SetPPText(text) {
    ppbtn.textContent = text;    
}

function GetItemPath(elm) {
    var els = [];
    var lastitem;
    do {
        var elmtemp = elm;
        while (elmtemp.firstChild) {
            elmtemp = elmtemp.firstChild;
        }
        if (elmtemp.textContent != lastitem) {
            lastitem = elmtemp.textContent;
            els.unshift(elmtemp.textContent);
        }

        elm = elm.parentNode;
    } while (elm.id != 'musicdb');
    var path = '';
    //console.log(els);
    els.forEach(function (part) {
        path += part + '/';
    });
    path = path.slice(0, -1);
    return path;
}

function GetChildTracks(path, nnodes) {
    path += '/';
    var nodes = [];
    for (var i = nnodes.length; i--; nodes.unshift(nnodes[i]));
    var tracks = [];
    nodes.splice(0, 1);
    nodes.forEach(function (node) {
        if (node.childNodes.length == 1) {
            var newnodes = node.childNodes[0].childNodes[0].childNodes[0].childNodes;
            var nodearr = [];
            for (var i = newnodes.length; i--; nodearr.unshift(newnodes[i]));
            var felm = nodearr[0].childNodes[0].textContent;
            var ttracks = GetChildTracks(path + felm, nodearr);
            tracks = tracks.concat(ttracks);
        }
        else {
            tracks.push(path + node.childNodes[0].childNodes[0].textContent);
        }

    });
    return tracks;
}
// END DOM helper functions

function AddPTrack(track) {
    PTrackUrlParams.append('ptrack', track);
    window.history.replaceState('playlist', 'Title', 'music?' + PTrackUrlParams.toString());
}

function queueTrack(track) {
    _queueTrack(track);
    AddPTrack(track);
}

function queueTracks(tracks) {
    tracks.forEach(function (track) {
        _queueTrack(track);
        PTrackUrlParams.append('ptrack', track);
    });
    window.history.replaceState('playlist', 'Title', 'music?' + PTrackUrlParams.toString());
}

function Download(url, onLoad, onAbort, onError) {
    var request = new XMLHttpRequest();
    request.open('get', url, true);
    request.responseType = 'arraybuffer';
    request.onload = function () {
        if(request.status !== 200) {
            console.log('DL ' + url + ' error ' + request.status);
            if(onError) onError();
            return;
        }
        onLoad(request);
    };
    request.onabort = onAbort || (function () {
        console.log('DL ' + url + ' aborted');
    });
    request.onerror = onError || (function () {
        console.log('DL ' + url + ' error');
    });
    request.send();
    return request;
}

/* firefox flac decoding is bad */
function toWav(metadata, decData) {
    var samples = interleave(decData, metadata.channels, metadata.bitsPerSample);
	var dataView = encodeWAV(samples, metadata.sampleRate, metadata.channels, metadata.bitsPerSample);
    return dataView.buffer;
}

// Flac to wav
function DecodeFlac(thedata, ondecoded) {
    if(typeof Flac === 'undefined') {
        console.log('DecodeFlac, no Flac - setTimeout');
        setTimeout(function(){ DecodeFlac( thedata, ondecoded);}, 5);               
        return;
    }
    else if(!Flac.isReady()) {
        console.log('DecodeFlac, Flac not ready, handler added');
        Flac.on('ready', function(libFlac){
            DecodeFlac( thedata, ondecoded);  
        });
        return;
    }
    var decData = [];
	var result = decodeFlac(thedata, decData, false);
    console.log('decoded data array: ', decData);
	
	if(result.error){
		console.log(result.error);
	}

	var metaData = result.metaData;
	if(metaData){		
		for(var n in metaData){
			console.log( n + ' ' + 	metaData[n]);
		}		
	}
    ondecoded(toWav(metaData, decData));    
}
/*end firefox flac decoding is bad*/

function TrackDownload(track, onDownloaded, seg) {
    this.track = track;
    this.onDownloaded = onDownloaded;
    this.seg = seg;
    this.stop = function() {
        if(this.download) {
            this.download.abort();
        }
        
        this.onDownloaded = function() {            
            return false;
        };
        console.log('DL ' + this.track.trackname + ' seg ' + this.seg + ' aborted');
    };

    var toDL = geturl(track.trackname);
    var theDownload = this;
    
    function redoDL() {
        setTimeout( function() {
            console.log('redo ' + seg + ' backofftime ' + track.backofftime);
            theDownload.track.currentDownload = new TrackDownload(track, theDownload.onDownloaded, seg);   
        }, track.backofftime);        
    }    
    track.backofftime *= 2;
    
    if (!USESEGMENTS) {
        this.download = Download(toDL, function (req) {
            track.backofftime = 1000;               
            console.log('DL ' + toDL + ' success, beginning decode');            
            MainAudioContext.decodeAudioData(req.response, theDownload.onDownloaded, function () {                
                console.log('DL ' + toDL + ' decode failed');
                redoDL();
            });
        }, function(){}, function(){
            redoDL();            
        });
    }
    else {
        seg = seg || 1;

        function onDecoded(incomingBuffer) {
            var isLastPart = (seg == track.numsegments);
            var isFirstPart = (seg == 1);
            if(!theDownload.onDownloaded(incomingBuffer, isFirstPart, isLastPart)) {
                return;
            }
            if (!isLastPart) {
                theDownload.track.currentDownload = new TrackDownload(track, theDownload.onDownloaded, seg+1);
            }
        }

        //if this segment is already downloaded, no need to download it again
        if(this.track.bufs[seg - 1]) {
            console.log('no need to download seg ' + seg);
            onDecoded(this.track.bufs[seg - 1]);
            return;
        }

        toDL += '&part=' + seg;      
       
        this.download = Download(toDL, function (req) {
            track.backofftime = 1000;            
            console.log('DL ' + toDL + ' (part) success, beginning decode');
            track.duration = Number(req.getResponseHeader('X-MHFS-TRACKDURATION'));
            track.numsegments = Number(req.getResponseHeader('X-MHFS-NUMSEGMENTS'));
            track.maxsegduration = Number(req.getResponseHeader('X-MHFS-MAXSEGDURATION'));         
              
            var todec = Array.from(new Uint8Array(req.response)); // ArrayBuffers gets trashed for some stupid reason        
            MainAudioContext.decodeAudioData(req.response, onDecoded, function () {
                /* firefox fails to decode small flac segments so fallback to software */                
                console.log('DL ' + toDL + ' (part) decode failed. Attempting Software Decode');                
                DecodeFlac(Uint8Array.from(todec), function(wav) {                
                    MainAudioContext.decodeAudioData(wav, onDecoded, function () {
                        console.log('DL ' + toDL + ' (part) decode failed (CRITICAL). Redownloading');
                        redoDL();                
                    });
                });
            });
        }, function(){}, function(){
            redoDL();            
        });
    }
    
    
}

function PumpAudio(skiptime) {
    
    if(typeof skiptime != "undefined") {
        NextBufferTime = 0;
    }
    // queue 6 seconds in advance
    while((NextBufferTime - MainAudioContext.currentTime) < 6) {        
        // find which track to queue if any
        let pbindex = 0;
        let tindex = CurrentTrack;
        while(PlaybackQueue[pbindex] && PlaybackQueue[pbindex].isQueued) {
            if(!RepeatTrack) {
                tindex = PlaybackQueue[pbindex].tindex + 1;
            } 
            pbindex++;                          
        }
        let track = Tracks[tindex];
        if(!track) return;
        if(! PlaybackQueue[pbindex]) {
            //stop running downloads on the track
            track.stopDownload();
            
            // create a pb track
            console.log('passing in skiptime ' + skiptime);
            PlaybackQueue[pbindex] = new QueuedTrack(track, skiptime);     
            PlaybackQueue[pbindex].tindex = tindex;                     
        }              
        let pbtrack = PlaybackQueue[pbindex];
        if(skiptime && (skiptime != pbtrack.skiptime)) {
            console.log('Critical, skiptime specified and not equal to pbtrack.skiptime');
        }        
        
        // can't queue if the part isn't downloaded
        if(!track.bufs) return;       
        skiptime = pbtrack.skiptime || 0;
        if(skiptime) {
            BIndex = Math.floor(skiptime / track.maxsegduration);
            console.log('skiptime BIndex ' + BIndex);                            
        }
        if(!track.bufs[BIndex]) return;
        
        // fix NextBufferTime and set the track time if necessary
        let freshstart = 0;        
        if(NextBufferTime <= MainAudioContext.currentTime) {          
            NextBufferTime = MainAudioContext.currentTime + BUFFER_S;
            pbtrack.astart = skiptime - NextBufferTime;
            freshstart = 1;
        }
        else if(BIndex == 0){
            pbtrack.astart = skiptime - NextBufferTime;
        }        
        
        // actually queue it
        var source = MainAudioContext.createBufferSource();
        source.connect(MainAudioContext.destination);
        source.buffer = track.bufs[BIndex];
        pbtrack.sources.push(source);
        skiptime = (skiptime % track.maxsegduration);
        console.log('Scheduling ' + track.trackname + ' at ' + NextBufferTime + ' segment timeskipped ' + skiptime);
        source.start(NextBufferTime, skiptime);
        var timeleft = source.buffer.duration - skiptime;
        NextBufferTime = NextBufferTime + timeleft;   
        skiptime = 0;
        pbtrack.skiptime = 0;
        BIndex++;    
        // at end of track
        if(BIndex == track.numsegments) {       
            pbtrack.isQueued = true;
            pbtrack._EndTime = NextBufferTime;
            console.log('Set EndTime for track ' + track.trackname + ' to ' +  pbtrack._EndTime);           
            source.onended = function() {
                pbtrack.onEnd();
            };
            // next time queue the next track or repeat
            BIndex = 0;
        }
        
        // playback starting, run startfunc
        if(freshstart) {
            pbtrack.startFunc();
        }
    }   
}

function QueuedTrack(track, skiptime, start) {
    this.track = track;
    this.sources = [];
    this.isDownloaded = false;
    this.isQueued = false;    
    this.skiptime = skiptime || 0;

    this.startFunc = function () {
        // Update UI             
        seekbar.min = 0;
        SetPPText('PAUSE');
        if(track.duration) {
            SetEndtimeText(track.duration);
            seekbar.max = track.duration;
            console.log(track.trackname + ' should now be playing');
        }
        else {
            console.log(track.trackname + "didn't download in time")
            seekbar.max = 0;
        }
        SetPlayText(track.trackname);  
        var tindex = this.tindex;
        if ((tindex > 0) && Tracks[tindex - 1]) {
             SetPrevText(Tracks[tindex - 1].trackname);
        }
        else {
             SetPrevText('');
        }
        if(Tracks[tindex + 1]) {
            SetNextText(Tracks[tindex + 1].trackname);
        }
        else {
            SetNextText('');
        }       
    };
    
    this.clearSources = function() {
        if (this.sources) {
            this.sources.forEach(function (source) {
                if (!source) return;
                source.onended = function () { };
                source.stop();
                source.disconnect();
            });            
        }
    };    
    
    this.onEnd = function () {       
        var time = MainAudioContext.currentTime + this.astart;               
        console.log('End - track time: ' + time + ' duration ' + this.track.duration);
        // sanity check
        if(time < this.track.duration) {
            // tolerate five milliseconds too early (this.duration isn't completely precise)            
            if((this.track.duration - time) > 0.005) {
                alert( 'onEnd called at ' + time + ' when track duration is ' + this.track.duration);
            }                
        }
        
        // free memory
        this.clearSources();
        
        // advance playback queue
        PlaybackQueue.shift();        

        if(!RepeatTrack) {
            // free more memory            
            if((CurrentTrack-1) >= 0) Tracks[CurrentTrack-1].clearCache();            
            
            // Advance the display to the next track
            SetPrevText(this.trackname);
            CurrentTrack++;
            if (!Tracks[CurrentTrack]) {                
                SetPlayText('');
                SetNextText('');
                SetCurtimeText(0);
                SetEndtimeText(0);
                SetSeekbarValue(0);
                SetPPText('IDLE');            
                console.log('reached end of queue, stopping');
                return;
            }
        }            
        
        PlaybackQueue[0].startFunc();
    };
    
    console.log('should dl');  
    var qtrack = this;
    console.log('track.download skiptime ' + this.skiptime);
    track.download(this.skiptime, function(currentseg) {
        if(! qtrack.numsources) {
            qtrack._startseg = currentseg;
            qtrack.numsources = track.numsegments - qtrack._startseg + 1;            
        }
        if(currentseg == track.numsegments) {
            this.isDownloaded = true;            
        }       
    });      
}


function Track(trackname) {
    this.trackname = trackname;
    this.bufs = [];

    /*
    this.queueRepeat = function () {        
        if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearSources();      // remove the next track from the web audio queue         
        STAHPNextDownload();                                                  // stop the possible next track download so it doesn't enter the web audio queue     
        return;
      
        // queue the same track        
        if(this.isDownloaded) {
            // reset NextBufferTime in case repeatrack was just turned on           
            if(NextBufferTime != this._EndTime) {
                console.log('this.queueRepeat rollback NextBufferTime to ' + this._EndTime);
                NextBufferTime = this._EndTime;                
            }
            // store the currently playing track end time for good            
            SaveNextBufferTime = NextBufferTime;
            // queue up the repeat
            DLImmediately = true;
            this.WantQueue = false;                         
            Tracks[CurrentTrack].queue(0);                
        }
        else {
            // flag to do this on download of the last part
            this.WantQueue = true;
            SaveNextBufferTime = 0;            
        }
    };

    this.queueNext = function() {
        if (Tracks[CurrentTrack + 1]) {
            if(this.isDownloaded) {
                console.log('theres another track and its not downloaded,DLImmediately' );
                DLImmediately = true;                
                Tracks[CurrentTrack + 1].queue(0);               
            }

            return;            
            if(this.isDownloaded &&  !this.queuednext) {
                console.log('theres another track and its not downloaded,DLImmediately' );
                DLImmediately = true;
                this.queuednext = true;
                Tracks[CurrentTrack + 1].queue(0);                
            }
            else {
                this.queuednext = false;
            }                
            //this.queuednext = false;
        }
        else {
            if(this.isDownloaded) {
                console.log('no next track and this.isDownloaded, DLImmediately');
                DLImmediately = true;
            }            
        }        
    };        

    this.clearSources = function() {
        if (this.source) {
            this.source.onended = function () { };
            this.source.stop();
            this.source.disconnect();
            this.source = null;
        }
        else if (this.sources) {
            this.sources.forEach(function (source) {
                if (!source) return;
                source.onended = function () { };
                source.stop();
                source.disconnect();
            });
            this.sources = [];
        }
    };    


    this.queueBuffer = function (buffer, skiptime, isFirstPart, isLastPart, start) {
        if(skiptime) {
            console.log('PumpAudio skiptime');
            NextBufferTime = start;
            PumpAudio(skiptime);            
        }
        if(isLastPart) {
            this.isDownloaded = true;            
            if(this ===  Tracks[CurrentTrack]) {
                // perform neglected cueing operations as the track started before it was downloaded
                console.log('last part of current track downloaded');
                if(!RepeatTrack) {                                
                    DLImmediately = true;
                    if (Tracks[CurrentTrack + 1]) {
                        console.log('Track.queueBuffer, queue');                       
                        Tracks[CurrentTrack + 1].queue(0);
                    }
                }
            }                              
        }       
    };
    */

    // skiptime is the amount of time in the beginning segment to not play or skip over    
    this.download = function (skiptime, onPartDownloaded) {
        DLImmediately = false;  
        skiptime = skiptime || 0;        
        var seg;        
        if (skiptime) {
            seg = Math.floor(skiptime / this.maxsegduration) + 1;
            console.log('skiptime sources ' + (this.numsegments - seg + 1)); // so we clear the right amount of sources                    
        }
        else {
            seg = 1;
        }           
        var track = this;
        this.backofftime = 1000;            
        this.currentDownload = new TrackDownload(this, function (buffer, isFirstPart, isLastPart) {                
            track.bufs[seg - 1] = buffer;
            console.log('seg ' + seg + ' ' + this.track.trackname + ' should be dled');
            onPartDownloaded(seg);
            seg++;            
            return true;
        }, seg);       
    };

    this.clearCache = function() {
        this.buf = null;
        this.bufs = [];
    };
    
    this.stopDownload = function() {
        if(this.currentDownload) {
            this.currentDownload.stop();
        }
        this.currentDownload = null;        
    }
}

function loop() {
    if(Tracks[CurrentTrack]) {              
        if (SBAR_UPDATING) {
            console.log('Not updating SBAR, SBAR_UPDATING');            
        }
        else {                       
            var time = 0;
            if(PlaybackQueue[0] && PlaybackQueue[0].astart) {
                time = MainAudioContext.currentTime + PlaybackQueue[0].astart;
            }
            SetCurtimeText(time);
            SetSeekbarValue(time);
        }
        PumpAudio();        
    }
    window.requestAnimationFrame(loop);
}

Number.prototype.toHHMMSS = function () {
    var sec_num = Math.floor(this); //parseInt(this, 10); // don't forget the second param
    var hours = Math.floor(sec_num / 3600);
    var minutes = Math.floor((sec_num - (hours * 3600)) / 60);
    var seconds = sec_num - (hours * 3600) - (minutes * 60);
    var str;
    if (hours > 0) {
        if (hours < 10) { hours = "0" + hours; }
        str = hours + ':'
    }
    else {
        str = '';
    }
    //if (minutes < 10) {minutes = "0"+minutes;}
    if (seconds < 10) { seconds = "0" + seconds; }
    return str + minutes + ':' + seconds;
}

function CreateAudioContext() {
    return (window.hasWebKit) ? new webkitAudioContext() : (typeof AudioContext != "undefined") ? new AudioContext() : null;
}

function playTrackNow(track) {
    let tarra = [track];
    playTracksNow(tarra);    
}

function playTracksNow(tracks) {    
    if(! Tracks[CurrentTrack]) {
        queueTracks(tracks);
    }
    else {
        if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearSources();             
        var i = 1;
        tracks.forEach(function (track) {
            Tracks.splice(CurrentTrack + i, 0, new Track(track));
            i++;
        });
        nextbtn.click();
        BuildPTrack();
    }
}

function geturl(trackname) {
    var url = 'music_dl?name=' + encodeURIComponent(trackname);
    if (MAX_SAMPLE_RATE) url += '&max_sample_rate=' + MAX_SAMPLE_RATE;
    if (BITDEPTH) url += '&bitdepth=' + BITDEPTH;
    url += '&gapless=1&gdriveforce=1';    
    return url;
}

function _queueTrack(_trackname) {
    var track = new Track(_trackname);
    Tracks.push(track);   
    if ((CurrentTrack + 1) == (Tracks.length - 1)) {
        SetNextText(Tracks[Tracks.length - 1].trackname);
    }
    else if (CurrentTrack == (Tracks.length - 1)) {
        SetPlayText(Tracks[CurrentTrack].trackname + ' {![LOADING]!}');
    }
}

function _BuildPTrack() {
    PTrackUrlParams = new URLSearchParams();
    if (MAX_SAMPLE_RATE) PTrackUrlParams.append('max_sample_rate', MAX_SAMPLE_RATE);
    if (BITDEPTH) PTrackUrlParams.append('bitdepth', BITDEPTH);
    if (USESEGMENTS) PTrackUrlParams.append('segments', USESEGMENTS);
    Tracks.forEach(function (track) {
        PTrackUrlParams.append('ptrack', track.trackname);
    });
}

function BuildPTrack() {
    _BuildPTrack();
    var urlstring = PTrackUrlParams.toString();
    if (urlstring != '') {
        window.history.replaceState('playlist', 'Title', 'music?' + urlstring);
    }
}

function PlaybackQueueEmpty() {
    while(PlaybackQueue.length > 0) {
        pbtrack = PlaybackQueue.shift();
        pbtrack.clearSources();
        pbtrack.track.stopDownload();        
    }
    PlaybackQueue = [];    
}

// BEGIN UI handlers
rptrackbtn.addEventListener('change', function(e) {         
   if(e.target.checked) {
       console.log("rptrackbtn checked");
       RepeatTrack = 1;     
       
       // queue up the repeat
               
   }
   else {
       console.log("rptrackbtn unchecked");
       RepeatTrack = 0;
       // stop any sources other than what is currently playing
       // if the rest of the currently playing track is downloaded, abort dl and decode operations
       // rollback NextBufferTime to the end of track
       // queue up the next track      
   }           
});

ppbtn.addEventListener('click', function (e) {
    if (ppbtn.textContent == 'PAUSE') {
        MainAudioContext.suspend();           
        ppbtn.textContent = 'PLAY';                        
    }
    else if (ppbtn.textContent == 'PLAY') {
        MainAudioContext.resume();
        ppbtn.textContent = 'PAUSE';
    }
});

seekbar.addEventListener('mousedown', function (e) {
    do {
        if (ppbtn.textContent == 'PLAY') {
            break;
        }
        if (ppbtn.textContent  == 'PAUSE') break;
        return;
    } while (0);

    console.log('BEGIN SBAR UPDATE');
    SBAR_UPDATING = 1;
});

seekbar.addEventListener('change', function (e) {
    if(!SBAR_UPDATING) {
        console.log('SBAR change event fired when !SBAR_UPDATING');
        return;
    }
    SBAR_UPDATING = 0;
    if(!PlaybackQueue[0]){
        console.log('seekbar change: no PlaybackQueue track');
        return;
    }   
    console.log(PlaybackQueue[0].track.trackname + ' (' + CurrentTrack + ') ' + ' seeking to ' + seekbar.value);
    SetCurtimeText(Number(seekbar.value));  
    PlaybackQueueEmpty();
    PumpAudio(Number(seekbar.value));           
    console.log('END SBAR UPDATE');        
});

prevbtn.addEventListener('click', function (e) {
    if ((CurrentTrack - 1) < 0) return;
    console.log('prevtrack');
    if(ppbtn.textContent == "PLAY") {
        MainAudioContext.resume();
    }  
    if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearCache();   
    CurrentTrack--;   
    SetCurtimeText(0);
    if (Tracks[CurrentTrack].duration) SetEndtimeText(Tracks[CurrentTrack].duration);
    PlaybackQueueEmpty();
    PumpAudio();    
});

nextbtn.addEventListener('click', function (e) {        
    if (!Tracks[CurrentTrack + 1]) return;
    console.log('nexttrack');
    if(ppbtn.textContent == "PLAY") {
        MainAudioContext.resume();
    }    
    if((CurrentTrack-1) >= 0) Tracks[CurrentTrack-1].clearCache();   
    CurrentTrack++;   
    SetCurtimeText(0);
    if (Tracks[CurrentTrack].duration) SetEndtimeText(Tracks[CurrentTrack].duration);
    SetPrevText(Tracks[CurrentTrack-1].trackname);
    SetPlayText(Tracks[CurrentTrack].trackname + ' {![LOADING]!}');
    if (Tracks[CurrentTrack+1]) {
        SetNextText(Tracks[CurrentTrack+1].trackname);
    }
    else {
        SetNextText('');
    }
    PlaybackQueueEmpty();
    PumpAudio();
});

dbarea.addEventListener('click', function (e) {
    if (e.target !== e.currentTarget) {
        console.log(e.target + ' clicked with text ' + e.target.textContent);
        if (e.target.textContent == 'Queue') {
            path = GetItemPath(e.target.parentNode.parentNode);
            console.log("Queuing - " + path);
            if (e.target.parentNode.tagName == 'TD') {
                queueTrack(path);
            }
            else {
                var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                queueTracks(tracks);
            }
            e.preventDefault();
        }
        else if (e.target.textContent == 'Play') {
            path = GetItemPath(e.target.parentNode.parentNode);
            console.log("Playing - " + path);
            if (e.target.parentNode.tagName == 'TD') {
                playTrackNow(path);
            }
            else {
                var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                playTracksNow(tracks);
            }
            e.preventDefault();
        }
    }
    e.stopPropagation();
});
// END UI handlers

// Initialize the rest of globals and launch
{
    let urlParams = new URLSearchParams(window.location.search);
    MAX_SAMPLE_RATE = urlParams.get('max_sample_rate') || 48000;
    BITDEPTH        = urlParams.get('bitdepth');
    USESEGMENTS     = urlParams.get('segments');
    if(USESEGMENTS === null) {
        USESEGMENTS = 1;
    }
    else {
        USESEGMENTS = Number(USESEGMENTS);
    }        
    MainAudioContext = CreateAudioContext();
    NextBufferTime = MainAudioContext.currentTime;
    
    // update url bar with parameters
    _BuildPTrack();
    
    // queue the tracks in the url
    let orig_ptracks = urlParams.getAll('ptrack');
    if (orig_ptracks.length > 0) {
        queueTracks(orig_ptracks);
    }
    
    // launch the main loop for ui updates
    window.requestAnimationFrame(loop);
}

