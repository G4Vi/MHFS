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
var USEINCREMENTAL;
var USEWAV;
var USEDECDL;
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
let Astart;
var SaveNextBufferTime;
let GainNode;

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

// Incremental loading support

//let FlacWorker = new Worker('static/flacworker.js');

function IncrementalSetup() {
    
    FlacWorker.addEventListener('message', function(e) {
        if((IncCurJob !== null) && (e.data.jobid == IncCurJob)) {
            console.log('job ' + IncCurJob + ' finished message: ' + e.data.message);
            IncCurJob = null;        
        }
        else {
            console.log('job ' + e.data.jobid  + ' not needed, message: ' + e.data.message);
            return;        
        }
        
        //console.log(e.data);
        if(e.data.message == 'decodedone') {
            if(MainAudioContext.sampleRate != e.data.samplerate) {
                console.log('Switching MainAudioContext.sampleRate was: ' + MainAudioContext.sampleRate + ' to: ' + e.data.samplerate);
                MainAudioContext = CreateAudioContext( {'sampleRate' : e.data.samplerate });
                NextBufferTime = -1;
            }            
            let incomingdata = MainAudioContext.createBuffer(e.data.channels, e.data.samples, e.data.samplerate);
            for( let i = 0; i < e.data.channels; i++) {
                let buf = new Float32Array(e.data.outbuffer[i]);
                incomingdata.getChannelData(i).set(buf);        
            }
            
            let source = MainAudioContext.createBufferSource();
            source.connect(MainAudioContext.destination);
            source.buffer = incomingdata;
            if(NextBufferTime < MainAudioContext.currentTime) {
                console.log('IncrementalPumpAudio: TOO SLOW ' + NextBufferTime + ' ' + MainAudioContext.currentTime);
                //NextBufferTime = Math.ceil(MainAudioContext.currentTime + BUFFER_S);
                NextBufferTime = roundUp(MainAudioContext.currentTime + 0.250, 0.250);
            }
            source.start(NextBufferTime, 0);
            
            // update text
            let oldPlaybackIndex = IncPlaybackIndex;
            let startsample = 0;        
            e.data.tickevents.forEach( function(tickevent) {
                let uiupdate = { 'tick' : tickevent.tick};            
                if(tickevent.inctrack > 0) {
                    console.log('increasing playback index from ' + IncPlaybackIndex + ' to ' + (IncPlaybackIndex +tickevent.inctrack));
                    IncPlaybackIndex += tickevent.inctrack;                
                }
                if(tickevent.trackname) {
                    if(Tracks[CurrentTrack].trackname != tickevent.trackname) {
                        console.log('CurrentTrack ' +  CurrentTrack + ' name ' + Tracks[CurrentTrack].trackname + ' diff from tick: ' + tickevent.trackname);                 
                    }              
                }
                if(e.data.samplerate > 0) {            
                    uiupdate.duration = tickevent.total_samples / e.data.samplerate;                
                    uiupdate.astart   = -(NextBufferTime + (startsample / e.data.samplerate));
                    if(tickevent.skipsamples !== null) {
                        uiupdate.astart += (tickevent.skipsamples/e.data.samplerate);
                        uiupdate.skipsamples = tickevent.skipsamples;
                        uiupdate.sbar_update_done = 1;
                        uiupdate.jobid = e.data.jobid;                    
                    }                    
                    uiupdate.time     = NextBufferTime + (startsample / e.data.samplerate);
                }
                else {
                    uiupdate.duration = 0;
                    uiupdate.astart   = null;
                    uiupdate.time     = NextBufferTime;                                
                }
                uiupdate.inctrack = tickevent.inctrack;
                IncrementalTimers.push(uiupdate);
                startsample += tickevent.samples;            
            });
                
            //if(oldPlaybackIndex != IncPlaybackIndex) { }
            console.log('Next to playback should be ' + IncPlaybackIndex + ' ' + (Tracks[IncPlaybackIndex] ? Tracks[IncPlaybackIndex].trackname : ''));              
            
            NextBufferTime = NextBufferTime + source.buffer.duration;
            console.log('IncrementalPumpAudio: queued NextBufferTime is now ' + NextBufferTime + ' duration ' + source.buffer.duration);        
            
        }
        else if(e.data.message == 'decode_no_meta') {
    
        } 
        else if(e.data.message == 'at_end_of_queue') {
            DLImmediately = true;
        }        
    });
    
    var url = '';
    if (MAX_SAMPLE_RATE) url += '&max_sample_rate=' + MAX_SAMPLE_RATE;
    if (BITDEPTH) url += '&bitdepth=' + BITDEPTH;
    if(USEWAV) url += '&fmt=wav';
    url += '&gapless=1&gdriveforce=1';    
    FlacWorker.postMessage({'message': 'setup', 'urlstart' : 'music_dl?name=', 'urlend' : url, 'urlbaseuri' : document.baseURI});     
}

function IncrementalDownloadTrack(trackname, skiptime) {
    FlacWorker.postMessage({'message': 'download', 'trackname' : trackname, 'skiptime' : skiptime});  
}

let IncrementalTimers = [];
let IncrementalSkiptime = null;
let IncPlaybackIndex = 0;
let IncJobCounter = 0;
let IncCurJob = null;
let SBARPrevValue = -1;

function IncrementalAddTrack(_trackname) {
    FlacWorker.postMessage({'message': 'pushPlaybackQueue', 'track' : _trackname});   
}

function IncrementalStartTrack(skiptime) {
    // we're haulting/starting playback, dont mess this up with timers
    IncrementalTimers = [];
    IncCurJob = null;
    /*IncPlaybackIndex = CurrentTrack;
    IncrementalSkiptime = skiptime;
    IncrementalPumpAudio();*/
    let ttracks = [];
    for(let tindex = CurrentTrack; Tracks[tindex]; tindex++) {
        ttracks.push(Tracks[tindex].trackname);                
    }
    IncCurJob = IncJobCounter++;
    FlacWorker.postMessage({'message': 'seek', 'tracks' : ttracks, 'skiptime' : skiptime, 'duration' : 0.250, 'repeat' : RepeatTrack, 'jobid' : IncCurJob});
}

function IncrementalProcessTimers() {
    let dcount = 0;
    for(let i = 0; i < IncrementalTimers.length; i++) {
        if(MainAudioContext.currentTime < IncrementalTimers[i].time) {
            break;
        }
        dcount++;
        console.log('running IncTimer ' + IncrementalTimers[i].time);
        if(IncrementalTimers[i].inctrack > 0) {
            console.log('Increasing CurrentTrack from ' + CurrentTrack + ' to ' + (IncrementalTimers[i].inctrack + CurrentTrack));
            CurrentTrack += IncrementalTimers[i].inctrack
        }
        let prevtext = CurrentTrack > 0 ? Tracks[CurrentTrack-1].trackname : '';
        let playtext = Tracks[CurrentTrack] ? Tracks[CurrentTrack].trackname : '';
        let nexttext = Tracks[CurrentTrack+1] ? Tracks[CurrentTrack+1].trackname : '';
        SetPrevText(prevtext);
        SetPlayText(playtext);
        SetNextText(nexttext);
        SetEndtimeText(IncrementalTimers[i].duration);
        seekbar.min = 0;
        seekbar.max = IncrementalTimers[i].duration;
        Astart = IncrementalTimers[i].astart;
        if(IncrementalTimers[i].duration == 0) {
            SetCurtimeText(0);
            SetPPText('IDLE');
            SetSeekbarValue(0);
            console.log('Reached end of queue, stopping'); 
            DLImmediately = true;            
        }
        else {
            console.log(playtext + ' should now we playing ' + CurrentTrack + ' ' + Tracks[CurrentTrack].trackname);
            SetPPText('PAUSE');            
        }
        if(IncrementalTimers[i].sbar_update_done) {
            if(SBARPrevValue == Number(seekbar.value)) {
                SBAR_UPDATING = 0;    
                console.log('END SBAR UPDATE');
            }
        }            
    }
    if(dcount) {
        IncrementalTimers.splice(0,dcount);   
    }   
}

function IncrementalGraphicsLoop() {
    if(Tracks[CurrentTrack]) {			
        if (SBAR_UPDATING) {
            console.log('Not updating SBAR, SBAR_UPDATING');            
        }
        else {
            IncrementalProcessTimers();
            if(Tracks[CurrentTrack]) {
                if(Astart === null) {
                    Astart = -MainAudioContext.currentTime;
                    console.log('astart not ready, forcing it.');                    
                }
                var time = MainAudioContext.currentTime + Astart;
                //console.log('astart ' +  Astart, ' curtime ' + MainAudioContext.currentTime, ' time ' + time);  
                SetCurtimeText(time);
                SetSeekbarValue(time);                
            }          
        }       
    }
    //console.log('IncrementalGraphicsLoop looping');    
    window.requestAnimationFrame(IncrementalGraphicsLoop);    
}

function roundUp(x, multiple) {
	var rem = x % multiple;
    if(rem == 0) {
    	return x;		
    }
    else {
		return x + multiple - rem;	    	
    }		
}



function IncrementalPumpAudio() {
    IncrementalProcessTimers();
    //if(Tracks[IncPlaybackIndex]) {
    if(Tracks[CurrentTrack]) {
        
        if(((NextBufferTime - MainAudioContext.currentTime) < 0.250) && (IncCurJob === null)) {	
            IncCurJob = IncJobCounter++;
            console.log('IncrementalPumpAudio: starting job ' + IncCurJob + ' skiptime ' + IncrementalSkiptime);
            
            let message = {'message' : 'pumpAudio', 'repeat' : RepeatTrack, 'duration' : 0.250, 'jobid' : IncCurJob};
            if(IncrementalSkiptime !== null) {
                message.skiptime = IncrementalSkiptime;
                IncrementalSkiptime = null;                
            }
            FlacWorker.postMessage(message);
		}        
    }    
}

function IncrementalOnSeekChanged() {
    if(!SBAR_UPDATING) {
        console.log('SBAR change event fired when !SBAR_UPDATING');
        return;
    }
    
    if(!Tracks[CurrentTrack]) return;
    console.log(Tracks[CurrentTrack].trackname + ' (' + CurrentTrack + ') ' + ' seeking to ' + seekbar.value);  
    Tracks[CurrentTrack].queue(Number(seekbar.value), MainAudioContext.currentTime);               
    SetCurtimeText(Number(seekbar.value));
    SBARPrevValue = Number(seekbar.value); 
}

// END Incremental support
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

        // if doing a decode download ...
        if(USEDECDL) {
            track.maxsegduration = 1;
            let startTime = track.maxsegduration * (seg-1);
            let currentDownload = this;           
            let ndrpromise = async function() {
                if(!track.nwdrflac) {                  
                    track.nwdrflac = await NetworkDrFlac_open(toDL);
                    if(!track.nwdrflac) {
                        console.error('failed to NetworkDrFlac_open');
                        return;
                    }
                    track.duration = track.nwdrflac.totalPCMFrameCount / track.nwdrflac.sampleRate;
                    track.numsegments = Math.ceil(track.duration/track.maxsegduration);
                }
    
                let startFrame = startTime * track.nwdrflac.sampleRate;
                let count = track.maxsegduration * track.nwdrflac.sampleRate;
                let fdecoded = await NetworkDrFlac_read_pcm_frames_to_wav(track.nwdrflac, startFrame, count);
                if(! fdecoded){
                    console.error('failed to NetworkDrFlac_read_pcm_frames_to_wav');
                    return;
                }
                let decoded = await MainAudioContext.decodeAudioData(fdecoded);
                if(! decoded){
                    console.error('failed to MainAudioContext.decodeAudioData');
                    return;
                }
                return decoded;                
            }();
            currentDownload.download = new NetworkDrFlac_Download();
            (async function(){                               
                let ndrres = await ndrpromise;
                if(!ndrres || currentDownload.download.isinvalid) {
                    // should we ever redo?
                }
                else {
                    onDecoded(ndrres);
                }        
            })();
            
            return;
        }

        // serverside segmenting mhfs download
        toDL += '&part=' + seg;       
        this.download = Download(toDL, function (req) {
            track.backofftime = 1000;            
            console.log('DL ' + toDL + ' (part) success, beginning decode');
            track.duration = Number(req.getResponseHeader('X-MHFS-TRACKDURATION'));
            track.numsegments = Number(req.getResponseHeader('X-MHFS-NUMSEGMENTS'));
            track.maxsegduration = Number(req.getResponseHeader('X-MHFS-MAXSEGDURATION'));         
              
            let todec = new Uint8Array(req.response.byteLength);
            todec.set(new Uint8Array(req.response));

            async function webAudioDecode() {
                let res;
                try {
                    res = await MainAudioContext.decodeAudioData(req.response);
                    console.log('webAudioDecode success');
                }
                catch(error) {
                }
                return res;
            }

            async function OGfallbackDecode() {
                let res;
                try {
                    let wav = await FlacToWav(todec);
                    res = await MainAudioContext.decodeAudioData(wav);
                    console.log('OGfallbackDecode success');
                }
                catch(error) {
                }
                return res;
            }

            async function fallbackDecode() {
                let fdecoded = await FLACToFloat32(todec);
                if(fdecoded) {
                    let metadata = fdecoded[0];
                    let chandata = fdecoded[1];
                    
                    /*if(MainAudioContext.sampleRate != metadata.sampleRate) {
                        MainAudioContext = CreateAudioContext( {'sampleRate' : metadata.sampleRate });
                    }*/
                    
                    
                    let buf = MainAudioContext.createBuffer(metadata.channels, metadata.total_samples, metadata.sampleRate);
                    for(let i = 0; i < metadata.channels; i++){
                        buf.getChannelData(i).set(chandata[i]);
                    }
                    
                    console.log('fallbackDecode success');
                    return buf;
                }
            }            
            
            (async function(){
                
                /*if(MainAudioContext.sampleRate != 96000) {
                    MainAudioContext = CreateAudioContext( {'sampleRate' : 96000 });
                }*/
                
                /*let webaudio = await webAudioDecode();
                if(webaudio) {
                    console.log(webaudio.getChannelData(0));
                    console.log(webaudio.getChannelData(1));
                    console.log(webaudio);
                }*/
                
                
                /*
                let ogfallback = await OGfallbackDecode();
                if(ogfallback) {
                    console.log(ogfallback.getChannelData(0));
                    console.log(ogfallback.getChannelData(1));
                    console.log(ogfallback);
                }
                */
                
                
                /*
                let fallback = await fallbackDecode();
                if(fallback) {
                    console.log(fallback.getChannelData(0));
                    console.log(fallback.getChannelData(1));
                    console.log(fallback);
                }
                */
                
                
                /*for(let i = 0; i < 480000; i++) {
                    let d1 = (webaudio.getChannelData(0)[i] - fallback.getChannelData(0)[i]);
                    if((d1 > 0.1) || (d1 < -0.1)) {
                        alert('we deviated');
                    }
                    let d2 = (webaudio.getChannelData(1)[i] - fallback.getChannelData(1)[i]);
                    if((d2 > 0.1) || (d2 < -0.1)) {
                        alert('we deviated');
                    }
                }
                */
                

                let decoded = (await webAudioDecode()) || (await fallbackDecode());
                //let decoded = (await webAudioDecode()) || (await OGfallbackDecode());
                //let decoded = await fallbackDecode();
                //let decoded = await OGfallbackDecode();
                //let decoded = ogfallback;
                //let decoded = fallback;
                //let decoded = webaudio;
                if(decoded) {
                    onDecoded(decoded);                    
                }
                else {
                    console.log('DL ' + toDL + ' (part) decode failed (CRITICAL). Redownloading');
                    redoDL();
                }
            })();         
            
        }, function(){}, function(){
            redoDL();            
        });
    }

    // grab metadata
    if(! track.metadata) {
        let metaurl = 'music_resources?name=' + encodeURIComponent(track.trackname);
        Download(metaurl, function(req) {
            let decodedString = String.fromCharCode.apply(null, new Uint8Array(req.response));
            track.metadata = JSON.parse(decodedString);
            console.log('track metadata ' + track.metadata);

            // Update the displayed metadata
            function SetPlayTextTrack(thetrack, extratext) {
                //SetPlayText(track.metadata.TITLE + ' - ' + track.metadata.ARTIST + extratext );
            }

            if(CurrentTrack > 0) {
                if(Tracks[CurrentTrack-1] && (Tracks[CurrentTrack-1].trackname === track.trackname)) {
                
                }
            }           

            if(Tracks[CurrentTrack] && (Tracks[CurrentTrack].trackname === track.trackname)) {
                SetPlayTextTrack(track, '');
            }

            if(Tracks[CurrentTrack+1] && (Tracks[CurrentTrack+1].trackname === track.trackname)) {

            }            
            
        }, function(){}, function(){});
    }    
}

function Track(trackname) {
    //this.trackname = 'test.wav';
    this.trackname = trackname;
    if (USESEGMENTS) {
        this.sources = [];
        this.bufs = [];
    }

    this.updateNumSources = function() {
        // calculate the number of sources up to the end        
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
        
        // update the astart
        Astart = Tracks[CurrentTrack].astart; 
       
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
        var time = MainAudioContext.currentTime + Astart;               
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
            freshstart = 1;
        }
        var source = MainAudioContext.createBufferSource();        
        source.buffer = buffer;
        source.connect(GainNode); // route through volume
        
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

        if(USEINCREMENTAL) {
            console.log('incremental queue');
            //IncrementalDownloadTrack(this.trackname, skiptime);
            IncrementalStartTrack(skiptime);            
        }        
        else if (this.buf) {
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
    if(Tracks[CurrentTrack] && Astart) {			
        if (SBAR_UPDATING) {
            console.log('Not updating SBAR, SBAR_UPDATING');            
        }
        else {                    
            var time = MainAudioContext.currentTime + Astart;
            if(!Astart || (time < 0)) {
                time = 0;
            }            
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

function CreateAudioContext(options) {
    let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;
    //if(mycontext.state === 'suspended') {
    //    alert('I am suspended');
    //}
    return mycontext;
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
    if(!USEINCREMENTAL) {
        Astart = Number.NaN; // why
    }
    else {
        Astart = 1;
    }
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
    if(USEINCREMENTAL) {
        
        let hastrack = Tracks[CurrentTrack];
        Tracks.push(track);        
        if(!hastrack) {
            IncrementalStartTrack(0);            
        }
        else {
            IncrementalAddTrack(_trackname);            
        }
        
        if ((CurrentTrack + 1) == (Tracks.length - 1)) {
            SetNextText(Tracks[Tracks.length - 1].trackname);
        }
        else if (CurrentTrack == (Tracks.length - 1)) {
            SetPlayText(Tracks[CurrentTrack].trackname + ' {![LOADING]!}');
        }
        return;
    }
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
    if (USEINCREMENTAL) PTrackUrlParams.append('inc', USEINCREMENTAL);
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

function loadScripts(scriptUrls, cb){
	function loadNext(err){
		if(err){
			console.error('error ', err);
			return cb(err);
		}
		scriptUrls.length? loadScripts(scriptUrls, cb) : cb(null);
	}
	var s = scriptUrls.shift();
	addScript(s, loadNext);
}

function addScript(scriptUrl, cb) {

	var head = document.getElementsByTagName('head')[0];
	var script = document.createElement('script');
	script.type = 'text/javascript';
	script.src = scriptUrl;
	script.onload = function() {
		cb && cb.call(this, null);
	};
	script.onerror = function(e) {
		var msg = 'Loading script failed for "' + scriptUrl + '" ';
		cb? cb.call(this, msg + e) : console.error(msg, e);
	};
	head.appendChild(script);
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
       let wasRepeat = RepeatTrack;
       RepeatTrack = 0;       
       if(wasRepeat && Astart) {
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
    if(USEINCREMENTAL) {
        IncrementalOnSeekChanged();        
        return;
    }
    if(!SBAR_UPDATING) {
        console.log('SBAR change event fired when !SBAR_UPDATING');
        return;
    }
    SBAR_UPDATING = 0;
    if(!Tracks[CurrentTrack]) return;
    if(!Astart) return;
    console.log(Tracks[CurrentTrack].trackname + ' (' + CurrentTrack + ') ' + ' seeking to ' + seekbar.value);
    
    Tracks[CurrentTrack].clearSources();
    if(Tracks[CurrentTrack+1]) {           
        Tracks[CurrentTrack+1].clearSources();
    }
    STAHPPossibleDownloads();
    
    // lie to not jostle the seekbar
    Astart = null;
    SetCurtimeText(Number(seekbar.value));
    
    if(Math.abs(Tracks[CurrentTrack].duration - Number(seekbar.value)) <= 0.0002) {    
        seekbar.value = Tracks[CurrentTrack].duration - 0.001;
    }
    Tracks[CurrentTrack].queue(Number(seekbar.value), MainAudioContext.currentTime);               
             
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

document.getElementById("volslider").addEventListener('input', function(e) {
    GainNode.gain.setValueAtTime(e.target.value, MainAudioContext.currentTime); 
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
    //load libflac.js in-case we need the fallback
    /*
    loadScripts(['static/libflac.js/util/check-support.js'], function(){
        var global = window;  
        var wasmDisable = false;
        var min = true;
        var variant = min ? 'min/' : '';
        global.FLAC_SCRIPT_LOCATION = 'static/libflac.js/dist/';
        var lib;
        if(!wasmDisable && isWebAssemblySupported()){
        		lib = 'libflac.'+variant.replace('/', '.')+'wasm.js';
        	} else {
        		lib = 'libflac.'+variant.replace('/', '.')+'js';
        }
        var libFile = global.FLAC_SCRIPT_LOCATION.replace('//','/') + lib;
        loadScripts([libFile, 'static/libflac.js/decode-func.js', 'static/libflac.js/util/data-util.js'], function(err){
            console[err? 'error' : 'info'](err? 'encountered error '+err : 'scripts initialized successfully');
        });
    });
    */

    let urlParams = new URLSearchParams(window.location.search);
    MAX_SAMPLE_RATE = urlParams.get('max_sample_rate') || 48000;
    BITDEPTH        = urlParams.get('bitdepth');
    USESEGMENTS     = urlParams.get('segments');
    USEINCREMENTAL  = urlParams.get("inc");
    USEDECDL        = urlParams.get("decdl");
    if((USESEGMENTS === null) && (USEINCREMENTAL === null)) {
        USESEGMENTS = 1;
        console.log('default USESEGMENTS');
    }
    else if(USEINCREMENTAL) {
        USEINCREMENTAL = Number(USEINCREMENTAL);
        console.log('USEINCREMENTAL');
        USEWAV = 1;
        window.FlacWorker = new Worker('static/flacworker.js');
        IncrementalSetup();
        setInterval(IncrementalPumpAudio, 20);
    }
    else {
        console.log('USESEGMENTS');
        USESEGMENTS = Number(USESEGMENTS);
    } 
    
    if(USEDECDL == null){
        //USEDECDL = 1;
    }

    MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });
    NextBufferTime = MainAudioContext.currentTime;

    //volume
    GainNode = MainAudioContext.createGain();
    GainNode.connect(MainAudioContext.destination);

    // update url bar with parameters
    _BuildPTrack();
    
    // queue the tracks in the url
    let orig_ptracks = urlParams.getAll('ptrack');
    if (orig_ptracks.length > 0) {
        queueTracks(orig_ptracks);
    }
    
    // launch the main loop for ui updates
    if(!USEINCREMENTAL) {
        window.requestAnimationFrame(loop);
    }
    else {
        window.requestAnimationFrame(IncrementalGraphicsLoop);
    }
}

