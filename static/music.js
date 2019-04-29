
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

var dbarea = document.getElementById('musicdb');
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


const urlParams = new URLSearchParams(window.location.search);
var MAX_SAMPLE_RATE = urlParams.get('max_sample_rate') || 48000;
const BITDEPTH = urlParams.get('bitdepth');
var USESEGMENTS = urlParams.get('segments');
if(USESEGMENTS === null) {
    USESEGMENTS = 1;
}
var PTrackUrlParams;

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

function STAHPPossibleDownloads() {
    if(Tracks[CurrentTrack] && Tracks[CurrentTrack].currentDownload) {      
        console.log('STAHPing ' + CurrentTrack) ; 
        Tracks[CurrentTrack].currentDownload.stop();
        Tracks[CurrentTrack].currentDownload = null;
    }
    if(Tracks[CurrentTrack+1]&& Tracks[CurrentTrack+1].currentDownload){
        console.log('STAHPing ' + CurrentTrack+1) ; 
        Tracks[CurrentTrack+1].currentDownload.stop();
        Tracks[CurrentTrack+1].currentDownload = null;
    }    
};

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
    if (!USESEGMENTS) {
        this.download = Download(toDL, function (req) {            
            console.log('DL ' + toDL + ' success, beginning decode');            
            MainAudioContext.decodeAudioData(req.response, theDownload.onDownloaded, function () {                
                console.log('DL ' + toDL + ' decode failed');
            });
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
            console.log('DL ' + toDL + ' (part) success, beginning decode');
            track.duration = Number(req.getResponseHeader('X-MHFS-TRACKDURATION'));
            track.numsegments = Number(req.getResponseHeader('X-MHFS-NUMSEGMENTS'));
            track.maxsegduration = Number(req.getResponseHeader('X-MHFS-MAXSEGDURATION'));

            MainAudioContext.decodeAudioData(req.response, onDecoded, function () {
                console.log('DL ' + toDL + ' (part) decode failed');
            });
        });
    }
    
    
}

function Track(trackname) {
    this.trackname = trackname;
    if (USESEGMENTS) {
        this.sources = [];
        this.bufs = [];
    }    

    this.startFunc = function () {
        
        if (this) {            
            SetPlayText(this.trackname);            
            var seekbar = document.getElementById("seekbar");
            seekbar.min = 0;
            SetPPText('PAUSE');
            if(this.duration) {
                SetEndtimeText(this.duration);
                seekbar.max = this.duration;
                console.log(this.trackname + ' should now be playing');
            }
            else {
                console.log(this.trackname + ' still downloading should now be playing')
                seekbar.max = 0;
            }           
        }
        else {
            console.log('WHY - Reached end of queue');
        }

        //Set up the previous track incase we went backw
        if ((CurrentTrack > 0) && Tracks[CurrentTrack - 1]) {
             SetPrevText(Tracks[CurrentTrack - 1].trackname);
        }
        else {
             SetPrevText('');
        }
        
        //Set up the next track
        if (Tracks[CurrentTrack + 1]) { 
            if(this.isDownloaded &&  !this.queuednext) {
                console.log('theres another track and its not downloaded,DLImmediately' );
                DLImmediately = true;
                Tracks[CurrentTrack + 1].queue(0);                
            }   
            SetNextText(Tracks[CurrentTrack + 1].trackname);
            this.queuednext = false;
        }
        else {
            if(this.isDownloaded) {
                console.log('no next track and this.isDownloaded, DLImmediately');
                DLImmediately = true;
            }
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

    this.onEnd = function () {
        var time = MainAudioContext.currentTime + this.astart;        
        console.log('End - track time: ' + time + ' duration ' + this.duration);

        //if there's still a start timer, we likely seeked to the end
        if (StartTimer) {
            console.log('starttimer present, running it now instead');
            clearTimeout(StartTimer);
            this.startFunc();            
            //play();
            StartTimer = null;
        }

        // free memory
        this.clearSources();
        //this.clearCache();
        if((CurrentTrack-1) >= 0) Tracks[CurrentTrack-1].clearCache();
        
        SetPrevText(this.trackname);
        
        // start the next track
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
        Tracks[CurrentTrack].startFunc();
    };

    this.createStartTimer = function (WHEN) {
        var track = this;
        StartTimer = setTimeout(function() {
            track.startFunc();
        }, WHEN);
    };

    this.queueBuffer = function (buffer, skiptime, isFirstPart, isLastPart, start) {
        start = start || NextBufferTime;
        if (start <= MainAudioContext.currentTime) {           
            start = MainAudioContext.currentTime + BUFFER_S;
            this.astart =  skiptime - start;
            this.createStartTimer(BUFFER_MS);
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
            this.isDownloaded = true;           
            if(this ===  Tracks[CurrentTrack]) {
                console.log('last part of current track downloaded, DLImediately');
                DLImmediately = true;
                if (Tracks[CurrentTrack + 1]) {
                    console.log('Track.queueBuffer, queue');                
                    this.queuednext = true;
                    Tracks[CurrentTrack + 1].queue(0);
                }
            }                              
        }
    };

    this.queue = function (skiptime, start) {
        this.isDownloaded = false;
        this.queuednext = false;
        skiptime = skiptime || 0;
        if (this.buf) {
            this.queueBuffer(this.buf, skiptime, true, true, start);
        }
        else if (DLImmediately) {
            console.log('should dl');
            var seg;
            if (USESEGMENTS) {
                if (skiptime) {
                    seg = Math.floor(skiptime / this.maxsegduration) + 1;
                }
                else {
                    seg = 1;
                }
            }
            var track = this;            
            this.currentDownload = new TrackDownload(this, function (buffer, isFirstPart, isLastPart) {                
                if (!USESEGMENTS) {
                    track.buf = buffer;
                    isFirstPart = true;
                    isLastPart = true;
                    console.log(this.track.trackname + ' should be dled');
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
        DLImmediately = false;  
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
            var time = MainAudioContext.currentTime + Tracks[CurrentTrack].astart;
            SetCurtimeText(time);
            SetSeekbarValue(time);
        }            
        
    }
    window.requestAnimationFrame(loop);
}
window.requestAnimationFrame(loop);

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

function SetCurtimeText(seconds) {
    var curtime = document.getElementById("curtime");
    curtime.value = seconds.toHHMMSS();
}
function SetEndtimeText(seconds) {
    var endtime = document.getElementById("endtime");
    endtime.value = seconds.toHHMMSS();
}

function SetNextText(text) {
    document.getElementById('next_text').innerHTML = '<span>' + text + '</span>';
}

function SetPrevText(text) {
    document.getElementById('prev_text').innerHTML = '<span>' + text + '</span>';
}

function SetPlayText(text) {
    document.getElementById('play_text').innerHTML = '<span>' + text + '</span>';
}

function SetSeekbarValue(seconds) {
    document.getElementById("seekbar").value = seconds;           
}

function SetPPText(text) {
    document.getElementById("ppbtn").textContent = text;    
}

function CreateAudioContext() {
    return (window.hasWebKit) ? new webkitAudioContext() : (typeof AudioContext != "undefined") ? new AudioContext() : null;
}


var MainAudioContext = CreateAudioContext();
const BUFFER_MS = 300; //in MS
const BUFFER_S = (BUFFER_MS / 1000);
var State = 'IDLE';
var CurrentTrack = 0;
var Tracks = [];
var DLImmediately = true;

var StartTimer = null;
var NextBufferTime = MainAudioContext.currentTime;
var SBAR_UPDATING = 0;

function playTrackNow(track) {    
    if(! Tracks[CurrentTrack]) {
        queueTrack(track);
    }
    else {
        STAHPPossibleDownloads(); 
        var toadd = new Track(track);
        Tracks.splice(CurrentTrack + 1, 0, toadd);
        nextbtn.click();
        BuildPTrack();
    }
}

function playTracksNow(tracks) {    
    if(! Tracks[CurrentTrack]) {
        queueTracks(tracks);
    }
    else {
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
        console.log('downloading immediately');
        track.queue(0);             
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

window.onload = function () {
    var prevbtn = document.getElementById("prevbtn");
    var sktxt = document.getElementById("seekfield");
    var seekbar = document.getElementById("seekbar");
    var ppbtn = document.getElementById("ppbtn");

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
        SBAR_UPDATING = 0;
        if(!Tracks[CurrentTrack]) return;
        console.log(Tracks[CurrentTrack].trackname + ' (' + CurrentTrack + ') ' + ' seeking to ' + seekbar.value);
        
        Tracks[CurrentTrack].clearSources();
        if(Tracks[CurrentTrack+1]) {           
            Tracks[CurrentTrack+1].clearSources();
        }
        STAHPPossibleDownloads();
        DLImmediately = true;
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
        DLImmediately = true;
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
        DLImmediately = true;
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

};

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

_BuildPTrack();
var orig_ptracks = urlParams.getAll('ptrack');
if (orig_ptracks.length > 0) {
    queueTracks(orig_ptracks);
}

