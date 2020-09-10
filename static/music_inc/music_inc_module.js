import {default as NetworkDrFlac} from './music_drflac_module.js'

let MainAudioContext;
let GainNode;
let GraphicsTimers = [];
let AQID = -1;
let AudioQueue = [];
let Tracks_HEAD;
let Tracks_TAIL;
let Tracks_QueueCurrent;
let FACAbortController = new AbortController();
let SBAR_UPDATING = 0;

function DeclareGlobalFunc(name, value) {
    Object.defineProperty(window, name, {
        value: value,
        configurable: false,
        writable: false
    });
};

function CreateAudioContext(options) {
    let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;
    GainNode = mycontext.createGain();
    GainNode.connect(mycontext.destination);
    return mycontext;
}

function MainAudioLoop() {

    AQ_clean();
    if(AudioQueue.length === 0) return 0;
    
    // advanced past already scheduled audio
    let acindex = 0;
    for(; acindex < AudioQueue.length; acindex++) {
        if(!AudioQueue[acindex].startTime) break;
    }

    // adjust clock
    let bufferTime;
    for(let i = 0; i < AudioQueue.length; i++) {
        if(AudioQueue[i].endTime) {
            bufferTime = AudioQueue[i].endTime;
        }
        else {
            break;
        }
    }
    let timeadjusted = false;
    if(!bufferTime || (bufferTime < MainAudioContext.currentTime)) {
        bufferTime =  MainAudioContext.currentTime+0.100;
        console.log('adjusting time to ' + bufferTime);
        timeadjusted = true;
    }
    
    // don't queue if we have plenty buffered
    let lookaheadtime = MainAudioContext.currentTime + 0.199;
    while(bufferTime < lookaheadtime) {
        // everything is scheduled break out
        if(acindex === AudioQueue.length) return;  
        let toQueue = AudioQueue[acindex];

        let source = MainAudioContext.createBufferSource();        
        source.buffer = toQueue.buffer;
        source.connect(GainNode);    
        source.start(bufferTime, 0);
        toQueue.source = source;

        toQueue.startTime = bufferTime;
        toQueue.endTime = toQueue.startTime + source.buffer.duration;
        if(!toQueue.playbackinfo.starttime || timeadjusted) {
            timeadjusted = false;
            toQueue.playbackinfo.starttime = toQueue.startTime - toQueue.skiptime;
        }
        if(toQueue.func) {                       
            toQueue.func(toQueue.startTime, toQueue.endTime);
        }

        bufferTime = toQueue.endTime;         
        acindex++;        
    }
}

function GraphicsLoop() {
    let removetimers = 0;
    for(let i = 0; i < GraphicsTimers.length; i++) {
        if(GraphicsTimers[i].time <= MainAudioContext.currentTime) {
            console.log('jraphics at current time ' + MainAudioContext.currentTime);
            GraphicsTimers[i].func(GraphicsTimers[i]);
            removetimers++;
        }
    }
    GraphicsTimers.splice(0, removetimers);
    AQ_clean();
    if(SBAR_UPDATING) {
        
        
        
    }
    // show the deets of the current track, if exists, is queued, and is playing  
    else if(AudioQueue[0] && AudioQueue[0].playbackinfo.starttime && ((MainAudioContext.currentTime-AudioQueue[0].playbackinfo.starttime) >= 0)) {
        //don't advance the clock past the end of queued audio
        let curTime = MainAudioContext.currentTime-AudioQueue[0].playbackinfo.starttime;       
        //console.log('current time ' + MainAudioContext.currentTime + 'acurtime ' + curTime + 'starttime ' + AudioQueue[0].playbackinfo.starttime);        
        SetCurtimeText(curTime);
        SetSeekbarValue(curTime);
    }   
    
    window.requestAnimationFrame(GraphicsLoop);
}

MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });
{
let pp = document.getElementById("ppbtn");
if(MainAudioContext.state === "suspended") {
    pp.textContent = "PLAY";
}
else {
    pp.textContent = "PAUSE";
}
}



setInterval(function() {
    MainAudioLoop();
}, 25);
window.requestAnimationFrame(GraphicsLoop);


function geturl(trackname) {
    let url = '../../music_dl?name=' + encodeURIComponent(trackname);
    url  += '&max_sample_rate=48000';
    /*if (MAX_SAMPLE_RATE) url += '&max_sample_rate=' + MAX_SAMPLE_RATE;
    if (BITDEPTH) url += '&bitdepth=' + BITDEPTH;
    url += '&gapless=1&gdriveforce=1';*/

    return url;
}

function QueueTrack(trackname, after) {
    let track = {'trackname' : trackname, 'url' : geturl(trackname)};
    
    if(!after) {
        after = Tracks_TAIL;        
    }
    
    if(after) {
        let prev = after;
        after.next = track;
        track.prev = after;
        if(after === Tracks_TAIL) {
            Tracks_TAIL = track;
        }
    }
    else {
        Tracks_TAIL = track;        
        Tracks_HEAD = track;        
    }
    
    if(!Tracks_QueueCurrent) {
        Tracks_QueueCurrent = track;
        fillAudioQueue();
    }
    if(AQ_ID() !== -1) {
        if(AudioQueue[0].track.prev === track) {
            SetPrevText(track.trackname);
        }
        else if(AudioQueue[0].track.next === track) {
            SetNextText(track.trackname);
        }
    }
    else if(Tracks_QueueCurrent === track) {
        let prevtext = track.prev ? track.prev.trackname : '';
        SetPrevText(prevtext);
        SetPlayText(track.trackname);
        let nexttext =  track.next ? track.next.trackname : '';
        SetNextText(nexttext);
    }
    return track;
}

function PlayTrack(trackname) {
    let queuePos;
    if(AQ_ID() !== -1) {
        queuePos = AudioQueue[0].track;
    }
    else if(Tracks_QueueCurrent) {
        queuePos = Tracks_QueueCurrent;
    }
    // otherwise queue at tail

    AQ_stopAudioWithoutID(-1);
    GraphicsTimers = [];
    FACAbortController.abort();  // stop the decode queue of next tracks(s)
    FACAbortController = new AbortController();

    Tracks_QueueCurrent = null;
    return QueueTrack(trackname, queuePos);   
}

function QueueTracks(tracks, after) {
    tracks.forEach(function(elm) {
        after = QueueTrack(elm);
    });
}

function PlayTracks(tracks) {
    let trackname = tracks.shift();
    if(!trackname) return;
    let after = PlayTrack(trackname);
    QueueTracks(tracks, after);
}


// remove references to 
function AQ_clean() {
    // clean up the AQ
    let toDelete = 0;
    for(let i = 0; i < AudioQueue.length; i++) {
        if(! AudioQueue[i].endTime) break;
        if(AudioQueue[i].endTime <= MainAudioContext.currentTime) {
            toDelete++;
        }
    }
    if(toDelete) AudioQueue.splice(0, toDelete);
}

function AQ_unqueuedTime() { 
    let unqueuedtime = 0;
    for(let i = 0; i < AudioQueue.length; i++) {
        if(!AudioQueue[i].startTime) {
            unqueuedtime += AudioQueue[i].duration;
        }        
    }
    return unqueuedtime;
}

// returns the currently or about to be playing aqid
function AQ_ID() {
    AQ_clean();     
    for(let i = 0; i < AudioQueue.length; i++) {        
        return AudioQueue[i].aqid;                    
    }
    return -1;
}

function AQ_IsPlaying() {
    let aqid = AQ_ID();
    if(aqid === -1) return false;
    if(!AudioQueue[0].startTime) return false;
    if(MainAudioContext.currentTime >= AudioQueue[0].startTime) return true;
    return false;
}


function AQ_stopAudioWithoutID(aqid) {
    if(!AudioQueue.length) return;
    let dCount = 0;
    for(let i = AudioQueue.length-1; i >= 0; i--) {
        if(AudioQueue[i].aqid === aqid) {
            break;
        }
        dCount++;
        if(AudioQueue[i].source) {
            AudioQueue[i].source.disconnect();
            AudioQueue[i].source.stop();
        }
    }
    if(dCount) {
        AudioQueue.splice(AudioQueue.length - dCount, dCount);
    }    
}

if(typeof sleep === 'undefined') {
    const sleep = m => new Promise(r => setTimeout(r, m));
    DeclareGlobalFunc('sleep', sleep);
}



/*
let FAQ_STATE = "FAQ_IDLE";
// FAQ_IDLE
// FAQ_OPEN
// FAQ_READ
// FAQ_WAIT

async function FAQOPEN() {
    let track = Tracks[QueueIndex];
    let failedcount = 0;
    while(1) {
    
        let mysignal = FAQ_ABORTCONTROLLER.signal;
        try {            
            let nwdrflac = await NetworkDrFlac(track.trackname, function() {
                return mysignal;
            });
            if(mysignal.aborted) {
                console.log('FAQOPEN aborted success');
                nwdrflac.close();
                return;
            }
            track.nwdrflac = nwdrflac;
            track.duration =  nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate;
            FAQ_STATE = "FAQ_START_READ";
            break;            
        }
        catch (error) {
            console.error(error);
            if(mysignal.aborted) {
                console.log('FAQOPEN aborted catch');
                return;            
            }
            failedcount++;
            if(failedcount == 2) {
                FAQ_STATE = "FAQ_NEXT";
                break;
            }
        }
    
    }
    FAQLOOP();
}

function FAQLOOP()
{
    while(1)
    {        
        if(FAQ_STATE === "FAQ_IDLE") {
            if(!Tracks[QueueIndex]) return;
            if(!Tracks[QueueIndex].nwdrflac) {
                FAQ_STATE = "FAQ_OPEN";
                FAQOPEN();
                return;                
            }
            else {
                FAQ_STATE = "FAQ_START_READ";
            }            
        }
        else if(FAQ_STATE === "FAQ_NEXT") {
            QueueIndex++;
            FAQ_STATE = "FAQ_IDLE";
        }
        else if(FAQ_STATE === "FAQ_START_READ") {

        }
        else if(FAQ_STATE === "FAQ_WAIT") {

            return;
        }
        else {
            return;
        }



        for(; QueueIndex < Tracks.length; QueueIndex++) {
            let track = Tracks[QueueIndex];
        }
    }    
}
*/

async function fillAudioQueue(time) {
    let initializing = 1;
TRACKLOOP:while(1) {
        AQID++;
        if(!initializing) {
            if(!document.getElementById("repeattrack").checked) {
                Tracks_QueueCurrent = Tracks_QueueCurrent.next;
            }
        }
        initializing = 0;        
        let track = Tracks_QueueCurrent;
        if(! track) return;
        
        // cleanup other nwdrflacs
        let mysig = FACAbortController.signal;  
        let prev;
        while(prev = track.prev) {
            if(!prev.nwdrflac) break;
            await prev.nwdrflac.close()
            prev.nwdrflac = null;
        }
        if(mysig.aborted) {
            console.log('abort after cleanup');
        }
        
        // open the track
        for(let failedtimes = 0; !track.nwdrflac; ) {
            let mysignal = FACAbortController.signal;                
            try {                
                let nwdrflac = await NetworkDrFlac(track.url, function() {
                    return mysignal;
                });
                if(mysignal.aborted) {
                    console.log('open aborted success');
                    nwdrflac.close();
                    return;
                }                
                track.nwdrflac = nwdrflac;
                track.duration =  nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate;
            }
            catch(error) {
                console.error(error);
                if(mysignal.aborted) {
                    console.log('open aborted catch');                   
                    return;
                }
                failedtimes++;
                console.log('Encountered error OPEN');     
                if(failedtimes == 2) {
                    console.log('Encountered error twice, advancing to next track');                    
                    continue TRACKLOOP;
                }
            }
        }

        // queue the track
        let dectime = 0;
        if(time) {                         
            dectime = Math.floor(time * track.nwdrflac.sampleRate);            
            time = 0;
        }
        let isStart = true;
        let playbackinfo = {'duration' : track.duration};        
        while(dectime < track.nwdrflac.totalPCMFrameCount) {
            // if plenty of audio is queued. Don't download            
            while(AQ_unqueuedTime() >= 10) {
                let mysignal = FACAbortController.signal;
                await sleep(25);
                if(mysignal.aborted) {
                    console.log('aborted sleep');                   
                    return;
                }                    
            }

            let todec = Math.min(track.nwdrflac.sampleRate, track.nwdrflac.totalPCMFrameCount - dectime);            
            let buffer;
            for(let failedcount = 0;!buffer;) {
                let mysignal = FACAbortController.signal;
                try {
                    let wav = await track.nwdrflac.read_pcm_frames_to_wav(dectime, todec);
                    if(mysignal.aborted) {
                        console.log('aborted read_pcm_frames success');                   
                        return;
                    }
                    buffer = await MainAudioContext.decodeAudioData(wav);
                    if(mysignal.aborted) {
                        console.log('aborted decodeaudiodata success');                   
                        return;
                    }
                    if(buffer.duration !== (todec / track.nwdrflac.sampleRate)) {
                        console.log('HARAM');
                    }                        
                }
                catch(error) {
                    console.error(error);
                    if(mysignal.aborted) {
                        console.log('aborted read_pcm_frames decodeaudiodata catch');                   
                        return;
                    }
                    failedcount++;
                    if(failedcount == 2) {
                        console.log('Encountered error twice, advancing to next track');                        
                        continue TRACKLOOP;
                    }
                }
            }
         
            // Add to the audio queue
            let aqItem = { 'buffer' : buffer, 'duration' : todec, 'aqid' : AQID, 'skiptime' : (dectime / track.nwdrflac.sampleRate), 'track' : track, 'playbackinfo' : playbackinfo};
            // At start and end track update the GUI
            let isEnd = ((dectime+todec) === track.nwdrflac.totalPCMFrameCount);
            if(isStart || isEnd) {            
                aqItem.func = function(startTime, endTime) {
                    if(isStart) {
                        console.log('Graphics start timer at ' + startTime); 
                        GraphicsTimers.push({'time': startTime, 'func': function() {                               
                            seekbar.min = 0;
                            seekbar.max = playbackinfo.duration;
                            SetEndtimeText(playbackinfo.duration);
                            SetPlayText(track.trackname);
                            let prevtext = track.prev ? track.prev.trackname : '';
                            SetPrevText(prevtext);       
                            let nexttext =  track.next ? track.next.trackname : '';
                            SetNextText(nexttext);
                        }});
                        isStart = false;
                    }
                    if(isEnd) {
                        console.log('Graphics end timer at ' + endTime);
                        GraphicsTimers.push({'time': endTime, 'func': function(){
                            let curTime = 0;
                            SetEndtimeText(0);                    
                            SetCurtimeText(curTime);
                            SetSeekbarValue(curTime);
                            SetPrevText(track.trackname);
                            SetPlayText('');
                            SetNextText('');
                        }});
                    }
                }
            }
            AudioQueue.push(aqItem);        
            dectime += todec;
        }        
    }
}

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
QueueTrack("Chuck Person - Chuck Person's Eccojams Vol 1 (2016 WEB) [FLAC]/A1.flac");


// BEGIN UI handlers

rptrackbtn.addEventListener('change', function(e) {
    let aqid = AQ_ID();
    if(aqid === -1) return;   // nothing is playing repeattrack should do nothing
    if(aqid === AQID) return; // current playing is still being queued do nothing 
    
    console.log('rptrack abort');
    AQ_stopAudioWithoutID(aqid); // stop the audio queue of next track(s)
    GraphicsTimers = [];
    FACAbortController.abort();  // stop the decode queue of next tracks(s)
    FACAbortController = new AbortController();

    if(e.target.checked) {
        // repeat the currently playing track
        Tracks_QueueCurrent = AudioQueue[0].track;
    }
    else {
        // queue the next track
        Tracks_QueueCurrent = AudioQueue[0].track.next;
    }
    fillAudioQueue();
 });
 
 ppbtn.addEventListener('click', function (e) {
     if ((ppbtn.textContent == 'PAUSE')) {
         MainAudioContext.suspend();           
         ppbtn.textContent = 'PLAY';                        
     }
     else if ((ppbtn.textContent == 'PLAY') || (ppbtn.textContent == 'IDLE')) {
         MainAudioContext.resume();
         ppbtn.textContent = 'PAUSE';
     }
 });
 
 seekbar.addEventListener('mousedown', function (e) {
     if(!SBAR_UPDATING) {
         SBAR_UPDATING = 1;         
     }
 });
 
 seekbar.addEventListener('change', function (e) {
     if(!SBAR_UPDATING) {
         return;
     }     
     SBAR_UPDATING = 0;
     if(AudioQueue[0]) {
         Tracks_QueueCurrent = AudioQueue[0].track;    
         AQ_stopAudioWithoutID(-1);
         GraphicsTimers = [];
         FACAbortController.abort();  // stop the decode queue of next tracks(s)
         FACAbortController = new AbortController();
         
         let stime = Number(e.target.value);
         console.log('SEEK ' + stime);
         SetSeekbarValue(stime);
         SetCurtimeText(stime);     
         fillAudioQueue(stime);
     }         
 });
 
 prevbtn.addEventListener('click', function (e) {
    let prevtrack;
    if(AudioQueue[0]) {
        if(!AudioQueue[0].track.prev) return;
        prevtrack = AudioQueue[0].track.prev;
    }
    else if(Tracks_QueueCurrent) {
        if(!Tracks_QueueCurrent.prev) return;
        prevtrack = Tracks_QueueCurrent.prev;
    }
    else if(Tracks_TAIL) {
        prevtrack = Tracks_TAIL;
    }
    else {
        return;
    }

    Tracks_QueueCurrent = prevtrack;
    AQ_stopAudioWithoutID(-1);
    GraphicsTimers = [];
    FACAbortController.abort();  // stop the decode queue of next tracks(s)
    FACAbortController = new AbortController();

    fillAudioQueue();    
 });
 
 nextbtn.addEventListener('click', function (e) {        
    let nexttrack;
    if(AudioQueue[0]) {
        if(!AudioQueue[0].track.next) return;
        nexttrack = AudioQueue[0].track.next;
    }
    else if(Tracks_QueueCurrent) {
        if(!Tracks_QueueCurrent.next) return;
        nexttrack = Tracks_QueueCurrent.next;
    }
    else {
        return;
    }

    Tracks_QueueCurrent = nexttrack;
    AQ_stopAudioWithoutID(-1);
    GraphicsTimers = [];
    FACAbortController.abort();  // stop the decode queue of next tracks(s)
    FACAbortController = new AbortController();

    fillAudioQueue(); 
 });
 
 document.getElementById("volslider").addEventListener('input', function(e) {
     GainNode.gain.setValueAtTime(e.target.value, MainAudioContext.currentTime); 
 });

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
 
 dbarea.addEventListener('click', function (e) {
     if (e.target !== e.currentTarget) {
         console.log(e.target + ' clicked with text ' + e.target.textContent);
         if (e.target.textContent == 'Queue') {
             let path = GetItemPath(e.target.parentNode.parentNode);
             console.log("Queuing - " + path);
             if (e.target.parentNode.tagName == 'TD') {
                QueueTrack(path);
             }
             else {
                 var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                 QueueTracks(tracks);
             }
             e.preventDefault();
         }
         else if (e.target.textContent == 'Play') {
             let path = GetItemPath(e.target.parentNode.parentNode);
             console.log("Playing - " + path);
             if (e.target.parentNode.tagName == 'TD') {
                PlayTrack(path);
             }
             else {
                 var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                 PlayTracks(tracks);
             }
             e.preventDefault();
         }
     }
     e.stopPropagation();
 });
 // End ui handlers
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