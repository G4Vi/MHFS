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
var DLImmediately = true; // controls when user track add operations (queue or play track) should download and enter the playback queue
var StartTimer = null;
var SBAR_UPDATING = 0;
var RepeatTrack = 0;
var MainAudioContext;
var NextBufferTime;
var RepeatAstart;
var SaveNextBufferTime;

//var CurrentSources;
//var NextSources;

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

function STAHPNextDownload() {
    if(Tracks[CurrentTrack+1]&& Tracks[CurrentTrack+1].currentDownload){
        console.log('STAHPing ' + (CurrentTrack+1)) ; 
        Tracks[CurrentTrack+1].currentDownload.stop();
        Tracks[CurrentTrack+1].currentDownload = null;
    }   
};

function STAHPPossibleDownloads() {
    if(Tracks[CurrentTrack] && Tracks[CurrentTrack].currentDownload) {      
        console.log('STAHPing ' + CurrentTrack) ; 
        Tracks[CurrentTrack].currentDownload.stop();
        Tracks[CurrentTrack].currentDownload = null;
    }
    STAHPNextDownload();        
};

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

function Track(trackname) {
    this.trackname = trackname;
    if (USESEGMENTS) {
        this.sources = [];
        this.bufs = [];
    }

    this.updateNumSources = function() {
        // calculate the number of sources up to the end
        /*var time = MainAudioContext.currentTime + Tracks[CurrentTrack].astart;  
        var startseg = Math.floor(time / this.maxsegduration) + 1;           
        startseg = startseg || 1;
        if(startseg < 1) {
            console.log('startseg (' + startseg + ')less than 1, not sure what to do, setting to 1');
            startseg = 1;
        }
        if(startseg != this._startseg) {
            console.log('startseg ' + startseg +  ' _startseg ' + this._startseg);
            alert('startseg');            
        }
        */         
        var startseg = this._startseg;               
        this.numsources = this.numsegments - this._startseg + 1; // so we clear the right amount of sources     
        if(this.numsources > this.numsegments) {
            console.log('wrong ' + this.numsegments + ' ' + startseg + ' ' + time +  ' ' + this.maxsegduration + ' ' + startseg) ;
            alert('wrong');
        }            
        console.log('updateNumSources ' + this.numsources + ' sources');
    }; 


    this.queueRepeat = function () {        
        if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearSources();      // remove the next track from the web audio queue         
        STAHPNextDownload();                                                   // stop the possible next track download so it doesn't enter the web audio queue
        RepeatAstart = Tracks[CurrentTrack].astart;                            // proper current time display            
        DLImmediately = false;                                                 // we should never queue from user when repeat track is turned on
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
            if(this.isDownloaded &&  !this.queuednext) {
                console.log('The next track is not queued, queueing');                
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

    this.startFunc = function () {
        if(! this) {
            console.log('StartFunc with no track WHY');    
            alert('StartFunc with no track WHY');                    
            return;            
        }       
        
        // update how many sources belong to this playback
        this.updateNumSources(); 
       
        // if in Repeat mode queue it up again
        if(RepeatTrack) {                       
            this.queueRepeat();                           
        }        
        //Set up the next track
        else {
            this.queueNext();            
        }
        
        // Update UI             
        seekbar.min = 0;
        SetPPText('PAUSE');
        if(this.duration) {
            SetEndtimeText(this.duration);
            seekbar.max = this.duration;
            console.log(this.trackname + ' should now be playing');
        }
        else {
            console.log(this.trackname + "didn't download in time")
            seekbar.max = 0;
        }       

        SetPlayText(this.trackname);  
        if ((CurrentTrack > 0) && Tracks[CurrentTrack - 1]) {
             SetPrevText(Tracks[CurrentTrack - 1].trackname);
        }
        else {
             SetPrevText('');
        }
        if(Tracks[CurrentTrack + 1]) {
            SetNextText(Tracks[CurrentTrack + 1].trackname);
        }
        else {
            SetNextText('');
        }            
        StartTimer = null;
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
    
    this.clearFirstSources = function(num) {
        if (this.sources) {
            console.log('clearing ' + num + ' sources, totalsegments ' + this.numsegments);
            for(var i = 0; i < num; i++) {
                var source= this.sources.shift();
                if(!source) continue;
                source.onended = function () { };
                source.stop();
                source.disconnect();                 
            }            
        }       
    };
    
    this.clearSecondSources = function() {
        if(this.sources) {
            while(this.sources.length > this.numsources) {
                console.log('pop source');
                var source = this.sources.pop();
                if(!source) continue;
                source.onended = function () { };
                source.stop();
                source.disconnect();                
            }           
        }
        
    }

    this.onEnd = function () {         
        var astart = RepeatTrack ? RepeatAstart : this.astart; 
        var time = MainAudioContext.currentTime + astart;               
        console.log('End - track time: ' + time + ' duration ' + this.duration);
        // sanity check
        if(time < this.duration) {
            // tolerate five milliseconds too early (this.duration isn't completely precise)            
            if((this.duration - time) > 0.005) {
                alert( 'onEnd called at ' + time + ' when track duration is ' + this.duration);
            }                
        }        

        //if there's still a start timer, we likely seeked to the end
        if (StartTimer) {
            console.log('starttimer present, running it now instead');
            clearTimeout(StartTimer);
            this.startFunc();            
            StartTimer = null;
        }
        
        if(RepeatTrack) {
            console.log('repeat track onended');
            // free memory
            Tracks[CurrentTrack].clearFirstSources(this.numsources);                      
        }
        else {
            // free memory
            this.clearSources();        
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
        
        Tracks[CurrentTrack].startFunc();
    };

    this.createStartTimer = function (WHEN) {
        var track = this;
        StartTimer = setTimeout(function() {
            track.startFunc();
        }, WHEN);
    };

    this.queueBuffer = function (buffer, skiptime, isFirstPart, isLastPart, start) {
        //console.log('start ' +start +  'NextBufferTime ' + NextBufferTime + ' currentTime ' + MainAudioContext.currentTime);
        start = start || NextBufferTime;
        var freshstart = 0;
        if (start <= MainAudioContext.currentTime) {           
            start = MainAudioContext.currentTime + BUFFER_S;
            this.astart =  skiptime - start;
            //this.createStartTimer(BUFFER_MS);
             freshstart = 1;
        }
        var source = MainAudioContext.createBufferSource();
        source.connect(MainAudioContext.destination);
        source.buffer = buffer;
        if (isFirstPart) {
            this.astart = skiptime - start;
        }
        if (isLastPart) {
            var theTrack = this;
            source.onended = function() {
                theTrack.onEnd();
            };
            this.isDownloaded = true;
        }           
        if (!USESEGMENTS) {
            this.duration = source.buffer.duration;
            this.source = source;
            console.log('Scheduling ' + this.trackname + ' for ' + start);
        }
        else {
            this.sources.push(source);
            skiptime = (skiptime % this.maxsegduration);
            console.log('Scheduling ' + this.trackname + 'at ' + start + ' segment timeskipped ' + skiptime);
        }
        source.start(start, skiptime);
        var timeleft = source.buffer.duration - skiptime;
        NextBufferTime = start + timeleft;
        
        if(isLastPart) {                       
            this._EndTime = NextBufferTime;
            console.log('Set EndTime for track' + this.trackname + ' to ' +  this._EndTime);           
        }
         // better to run it here than have race conditions with start timer
        if(freshstart) {
            this.startFunc();
        }
        else if(isLastPart) {                        
            if(this ===  Tracks[CurrentTrack]) {
                // perform neglected cueing operations as the track started before it was downloaded
                console.log('last part of current track downloaded');
                if(RepeatTrack) {
                    if(this.WantQueue) {
                        this.WantQueue = false;
                        console.log('wasntdownloaded');                       
                        SaveNextBufferTime = NextBufferTime;                     
                        Tracks[CurrentTrack].queue(0);
                    }                    
                }
                else {                   
                    if (Tracks[CurrentTrack + 1]) {
                        console.log('Track.queueBuffer, queue');                
                        this.queuednext = true;
                        Tracks[CurrentTrack + 1].queue(0);
                    }
                    else {                        
                        DLImmediately = true;
                    }
                }
            }                              
        }       
    };

    // skiptime is the amount of time in the beginning segment to not play or skip over
    // set start to set a specific starttime; to reset NextBufferTime pass in a value <= MainAudioContext.currentTime
    this.queue = function (skiptime, start) {
        DLImmediately = false;
        this.isDownloaded = false;
        this.queuednext = false;
        skiptime = skiptime || 0;
        if (this.buf) {
            this.queueBuffer(this.buf, skiptime, true, true, start);
        }
        else {
            console.log('should dl');
            var seg;
            if (USESEGMENTS) {
                if (skiptime) {
                    seg = Math.floor(skiptime / this.maxsegduration) + 1;
                    console.log('skiptime sources ' + (this.numsegments - seg + 1)); // so we clear the right amount of sources                    
                }
                else {
                    seg = 1;
                }
                this._startseg = seg;                
            }
            var track = this;
            this.backofftime = 1000;            
            this.currentDownload = new TrackDownload(this, function (buffer, isFirstPart, isLastPart) {                
                if (!USESEGMENTS) {
                    track.buf = buffer;
                    isFirstPart = true;
                    isLastPart = true;
                    console.log(track.trackname + ' should be dled');
                }
                else {
                    track.bufs[seg - 1] = buffer;
                    console.log('seg ' + seg + ' ' + this.track.trackname + ' should be dled');
                    seg++;
                    
                }
                track.queueBuffer(buffer, skiptime, isFirstPart, isLastPart, start);
                start = null;
                skiptime = 0;
                return true;
            }, seg);            
        }        
    };

    this.clearCache = function() {
        this.buf = null;
        this.bufs = [];
    };
}

function loop() {
    if(Tracks[CurrentTrack]) {              
        if (SBAR_UPDATING) {
            console.log('Not updating SBAR, SBAR_UPDATING');            
        }
        else {
            var astart;
            if(!RepeatTrack || !Tracks[CurrentTrack].astart) {
                astart = Tracks[CurrentTrack].astart;
            }
            else {
                astart = RepeatAstart;
            }            
            var time = MainAudioContext.currentTime + astart;
            SetCurtimeText(time);
            SetSeekbarValue(time);
        }       
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
    if(! Tracks[CurrentTrack]) {
        queueTrack(track);
    }
    else {
        if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearSources();      
        STAHPPossibleDownloads(); 
        var toadd = new Track(track);
        Tracks.splice(CurrentTrack + 1, 0, toadd);
        nextbtn.click();
        BuildPTrack();
    }
    RepeatAstart = Number.NaN; // why
}

function playTracksNow(tracks) {    
    if(! Tracks[CurrentTrack]) {
        queueTracks(tracks);
    }
    else {
        if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearSources();    
        STAHPPossibleDownloads();       
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
    if (DLImmediately) {
        if(Tracks[CurrentTrack] && ((typeof Tracks[CurrentTrack].isDownloaded === 'undefined') || Tracks[CurrentTrack].isDownloaded )) {
            console.log('downloading immediately');
            track.queue(0);
        }
        else if(Tracks[CurrentTrack]) {
            console.log('Current track is still downloading, not queuing');
        }            
    }
    else {
        console.log('queued track for later dl');
    }
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

// BEGIN UI handlers
rptrackbtn.addEventListener('change', function(e) {         
   if(e.target.checked) {
       console.log("rptrackbtn checked");
       RepeatTrack = 1;       
       if (!Tracks[CurrentTrack]) return;                                // can't repeat nonexistant track
       
       // queue up the repeat
       if(Tracks[CurrentTrack].astart) {
           Tracks[CurrentTrack].queueRepeat();
       }           
   }
   else {
       console.log("rptrackbtn unchecked");
       RepeatTrack = 0;
       if(RepeatAstart) {
           Tracks[CurrentTrack].astart = RepeatAstart;
           // stop any sources other than what is currently playing
           Tracks[CurrentTrack].clearSecondSources();
           if(Tracks[CurrentTrack+1]) {                             
               Tracks[CurrentTrack+1].clearSources();
               Tracks[CurrentTrack].queuednext = false;
           }
           // if the rest of the currently playing track is downloaded, abort dl and decode operations           
           if(!Tracks[CurrentTrack].WantQueue) {
               STAHPPossibleDownloads();               
               Tracks[CurrentTrack].isDownloaded = true;
           }
           // rollback NextBufferTime to the end of track
           if(SaveNextBufferTime) {
               console.log('restoring NextBufferTime to ' + SaveNextBufferTime);
               NextBufferTime = SaveNextBufferTime; 
               Tracks[CurrentTrack]._EndTime = SaveNextBufferTime;              
           }
           else {
               console.log('No SaveNextBufferTime, leaving it alone ' + NextBufferTime);
           }
          
           // queue up the next track
           Tracks[CurrentTrack].queueNext();
       }
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
    if(!Tracks[CurrentTrack]) return;
    if(!Tracks[CurrentTrack].astart) return;
    if(RepeatTrack && !RepeatAstart) return;
    console.log(Tracks[CurrentTrack].trackname + ' (' + CurrentTrack + ') ' + ' seeking to ' + seekbar.value);
    
    Tracks[CurrentTrack].clearSources();
    if(Tracks[CurrentTrack+1]) {           
        Tracks[CurrentTrack+1].clearSources();
    }
    STAHPPossibleDownloads();    
    Tracks[CurrentTrack].queue(Number(seekbar.value), MainAudioContext.currentTime);               
    SetCurtimeText(Number(seekbar.value));          
    console.log('END SBAR UPDATE');        
});

prevbtn.addEventListener('click', function (e) {
    if ((CurrentTrack - 1) < 0) return;
    if(ppbtn.textContent == "PLAY") {
        MainAudioContext.resume();
    }
   
    if(Tracks[CurrentTrack]) Tracks[CurrentTrack].clearSources();
    if(Tracks[CurrentTrack+1]) {           
        Tracks[CurrentTrack+1].clearSources();
    }
    STAHPPossibleDownloads();
    if(Tracks[CurrentTrack+1]) Tracks[CurrentTrack+1].clearCache();
    clearTimeout(StartTimer);
    StartTimer = null;
    console.log('prevtrack');    
    CurrentTrack--;
    Tracks[CurrentTrack].queue(0, MainAudioContext.currentTime);  
    SetCurtimeText(0);
    if (Tracks[CurrentTrack].duration) SetEndtimeText(Tracks[CurrentTrack].duration);  
});

nextbtn.addEventListener('click', function (e) {        
    if (!Tracks[CurrentTrack + 1]) return;
    if(ppbtn.textContent == "PLAY") {
        MainAudioContext.resume();
    }
    if(Tracks[CurrentTrack]) {
        Tracks[CurrentTrack].clearSources();            
    }
    Tracks[CurrentTrack+1].clearSources();        
    STAHPPossibleDownloads();
    if((CurrentTrack-1) >= 0) Tracks[CurrentTrack-1].clearCache();       
    clearTimeout(StartTimer);
    StartTimer = null;
    console.log('nexttrack');    
    CurrentTrack++;       
    Tracks[CurrentTrack].queue(0, MainAudioContext.currentTime);       
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
