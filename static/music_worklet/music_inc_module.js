//import {default as NetworkDrFlac} from './music_drflac_module.js'
import {default as NetworkDrFlac} from './music_drflac_module.cache.js'
// times in seconds
const AQMaxDecodedTime = 20;    // maximum time decoded, but not queued

let MainAudioContext;
let GainNode;
let Tracks_HEAD;
let Tracks_TAIL;
let Tracks_QueueCurrent;
let FACAbortController = new AbortController();
let SBAR_UPDATING = 0;
let NWDRFLAC;
let Timers = [];
let PlaybackInfo = {};

function DeclareGlobalFunc(name, value) {
    Object.defineProperty(window, name, {
        value: value,
        configurable: false,
        writable: false
    });
};

class Mutex {
    constructor() {
      this._locking = Promise.resolve();
      this._locked = false;
    }
  
    isLocked() {
      return this._locked;
    }
  
    lock() {
      this._locked = true;
      let unlockNext;
      let willLock = new Promise(resolve => unlockNext = resolve);
      willLock.then(() => this._locked = false);
      let willUnlock = this._locking.then(() => unlockNext);
      this._locking = this._locking.then(() => willLock);
      return willUnlock;
    }
}

function CreateAudioContext(options) {
    let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;
    GainNode = mycontext.createGain();
    GainNode.connect(mycontext.destination);
    return mycontext;
}

function GraphicsLoop() {
    // run and remove associated graphics timers
    let timerdel = 0;
    for(let j = 0; j < Timers.length; j++) {
        if(Timers[j].time <= MainAudioContext.currentTime) {
            Timers[j].func(Timers[j]);
            timerdel++;
        }
    }
    if(timerdel)Timers.splice(0, timerdel);
    if(SBAR_UPDATING) {
        
        
        
    }
    // show the deets of the current track, if exists, is queued, and is playing  
    else if(PlaybackInfo && PlaybackInfo.starttime && ((MainAudioContext.currentTime-PlaybackInfo.starttime) >= 0)) {
        //don't advance the clock past the end of queued audio
        let curTime = MainAudioContext.currentTime-PlaybackInfo.starttime;           
        SetCurtimeText(curTime);
        SetSeekbarValue(curTime);
    }   
    
    window.requestAnimationFrame(GraphicsLoop);
}

function geturl(trackname) {
    let url = '../../music_dl?name=' + encodeURIComponent(trackname);
    url  += '&max_sample_rate=48000';
    //url  += '&max_sample_rate=96000';
    /*if (MAX_SAMPLE_RATE) url += '&max_sample_rate=' + MAX_SAMPLE_RATE;
    if (BITDEPTH) url += '&bitdepth=' + BITDEPTH;
    url += '&gapless=1&gdriveforce=1';*/

    return url;
}

function _QueueTrack(trackname, after, before) {
    let track = {'trackname' : trackname, 'url' : geturl(trackname)};
    
    if(!after) {
        after = Tracks_TAIL;        
    }
    if(!before && (after !== Tracks_TAIL)) {
        before = after.next;        
    }
    
    if(after) {
        after.next = track;
        track.prev = after;
        if(after === Tracks_TAIL) {
            Tracks_TAIL = track;
        }
    }    
    if(before) {
        before.prev = track;
        track.next = before;
        if(before === Tracks_HEAD) {
            Tracks_HEAD = track;       
        }        
    }
    
    // we have no link list without a head and a tail
    if(!Tracks_HEAD || !Tracks_TAIL) {
       Tracks_TAIL = track;        
       Tracks_HEAD = track;        
    }
    
    // if nothing is being queued, start the queue
    if(!Tracks_QueueCurrent) {
        Tracks_QueueCurrent = track;
        fillAudioQueue();
    }
    else {
        // Update text otherwise
        let tocheck = (PlaybackInfo) ? PlaybackInfo.track : Tracks_QueueCurrent;
        if(tocheck) {
            if(tocheck.prev === track) {
                SetPrevText(track.trackname);
            }
            else if(tocheck.next === track) {
                SetNextText(track.trackname);
            }
        }            
    }    
    
    return track;
}

function _PlayTrack(trackname) {
    let queuePos;
    if(PlaybackInfo) {
        queuePos = PlaybackInfo.track;
    }
    else if(Tracks_QueueCurrent) {
        queuePos = Tracks_QueueCurrent;
    }
    
    let queueAfter; //falsey is tail
    if(queuePos) {
        queueAfter = queuePos.next;        
    }    

    // stop all audio
    StopAudio();
    Tracks_QueueCurrent = null;
    return _QueueTrack(trackname, queuePos, queueAfter);   
}

// BuildPTrack is expensive so _QueueTrack and _PlayTrack don't call it
function QueueTrack(trackname, after, before) {
    let res = _QueueTrack(trackname, after, before);
    BuildPTrack();
    return res;
}

function PlayTrack(trackname) {
    let res = _PlayTrack(trackname);
    BuildPTrack();
    return res;
}

function QueueTracks(tracks, after) {
    tracks.forEach(function(elm) {
        after = _QueueTrack(elm, after);
    });
    BuildPTrack();
    return after;
}

function PlayTracks(tracks) {
    let trackname = tracks.shift();
    if(!trackname) return;
    let after = _PlayTrack(trackname);
    if(!tracks.length) return;  
    QueueTracks(tracks, after);
}

if(typeof abortablesleep === 'undefined') {
    //const sleep = m => new Promise(r => setTimeout(r, m));
    const abortablesleep = (ms, signal) => new Promise(function(resolve) {
        const onTimerDone = function() {
            resolve();
            signal.removeEventListener('abort', stoptimer);
        };
        let timer = setTimeout(function() {
            console.log('sleep done ' + ms);
            onTimerDone();
        }, ms);

        const stoptimer = function() {
            console.log('aborted sleep');            
            onTimerDone();
            clearTimeout(timer);            
        };
        signal.addEventListener('abort', stoptimer);
    });
    DeclareGlobalFunc('abortablesleep', abortablesleep);
}

const abortablesleep_status = async function (ms, signal) {
    await abortablesleep(ms, signal);
    if(signal.aborted) {
        return false;
    }
    return true;
}

let AudioQueue = [];
const PumpAudioQueue = async function() {
    while(1) {        
        const fAvail = FreeFrames();
        const item = AudioQueue[0];
        if((!item) || (item.buffer.getChannelData(0).length > fAvail)) {
            let mysignal = FACAbortController.signal;
            const tosleep = item ? Math.min(20, (item.buffer.getChannelData(0).length-fAvail)/MainAudioContext.sampleRate) : 20;
            await abortablesleep(tosleep, mysignal);
            continue;            
        }
        AudioQueue.shift();
        const buffer = item.buffer;
        const isStart = item.isStart;
        const isEnd = item.isEnd;
        const track = item.track;
        const frameindex = item.frameindex;
        const bufferFrames = buffer.getChannelData(0).length;

        // not precise as MainAudioContext.currentTime isn't read as the exact time as the frames
        const fBuffered = ARBLen - fAvail;    
        const beforeTime = MainAudioContext.currentTime; + (fBuffered/MainAudioContext.sampleRate);
        pushFrames(buffer);    
        if(isStart) {
            InitPPText();
            const timerTime = beforeTime + (fBuffered / MainAudioContext.sampleRate);
            const startTime = beforeTime + ((fBuffered-frameindex) / MainAudioContext.sampleRate);
            Timers.push({'time': timerTime, 'func': function() {
                PlaybackInfo = {'starttime':startTime, 'track':track, 'aqindex': item.aqindex};                              
                seekbar.min = 0;
                seekbar.max = track.duration;
                SetEndtimeText(track.duration);
                SetPlayText(track.trackname);
                let prevtext = track.prev ? track.prev.trackname : '';
                SetPrevText(prevtext);       
                let nexttext =  track.next ? track.next.trackname : '';
                SetNextText(nexttext);
            }});
        }
        if(isEnd) {
            const endTime = MainAudioContext.currentTime + ((fBuffered+bufferFrames)/MainAudioContext.sampleRate);
            Timers.push({'time': endTime, 'func': function(){
                PlaybackInfo = null;
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

const AQDecTime = function() {
    let total = 0
    for(let i = 0; i < AudioQueue.length; i++) {
        total += AudioQueue[i].buffer.getChannelData(0).length;
    }
    return total;
}

let NextAQIndex = 0;
let MusicNode;
let FAQ_MUTEX = new Mutex();
async function fillAudioQueue(time) {
    // starting a fresh queue, render the text
    if(Tracks_QueueCurrent) {
        let track = Tracks_QueueCurrent;
        let prevtext = track.prev ? track.prev.trackname : '';
        SetPrevText(prevtext);
        SetPlayText(track.trackname + ' {LOADING}');
        let nexttext =  track.next ? track.next.trackname : '';
        SetNextText(nexttext);
        SetCurtimeText(time || 0);
        if(!time) SetSeekbarValue(time || 0);
        SetEndtimeText(track.duration || 0);        
    }

    // Stop the previous FAQ before starting
    FACAbortController.abort();
    FACAbortController = new AbortController();
    let mysignal = FACAbortController.signal;
    let unlock = await FAQ_MUTEX.lock();    
    if(mysignal.aborted) {
        console.log('abort after mutex acquire');
        unlock();
        return;
    }
    let initializing = 1;
    
TRACKLOOP:while(1) {
        // advance the track
        if(!initializing) {
            if(!document.getElementById("repeattrack").checked) {
                Tracks_QueueCurrent = Tracks_QueueCurrent.next;
            }
        }
        initializing = 0;        
        let track = Tracks_QueueCurrent;
        if(! track) {
            unlock();
            return;
        }
        
        // cleanup nwdrflac
        if(NWDRFLAC) {
            // we can reuse it if the urls match
            if(NWDRFLAC.url !== track.url)
            {
                await NWDRFLAC.close();
                NWDRFLAC = null;
                if(mysignal.aborted) {
                    console.log('abort after cleanup');
                    unlock();
                    return;
                }
            }
            else{
                track.duration = NWDRFLAC.totalPCMFrameCount / NWDRFLAC.sampleRate;
                track.sampleRate = NWDRFLAC.sampleRate;
            }
        }       
        
        // open the track
        for(let failedtimes = 0; !NWDRFLAC; ) {             
            try {                
                let nwdrflac = await NetworkDrFlac(track.url, mysignal);
                if(mysignal.aborted) {
                    console.log('open aborted success');
                    await nwdrflac.close();
                    unlock();
                    return;
                }
                NWDRFLAC = nwdrflac;                 
                track.duration =  nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate;
                track.sampleRate = nwdrflac.sampleRate;
            }
            catch(error) {
                console.error(error);
                if(mysignal.aborted) {
                    console.log('open aborted catch');
                    unlock();                    
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
        NextAQIndex++;
        let dectime = 0;
        if(time) {                         
            dectime = Math.floor(time * NWDRFLAC.sampleRate);            
            time = 0;
        }
        let isStart = true;      
        while(dectime < NWDRFLAC.totalPCMFrameCount) {
            const todec = Math.min(NWDRFLAC.sampleRate, NWDRFLAC.totalPCMFrameCount - dectime);

            // wait for there to be space
            const maxsamples = (AQMaxDecodedTime * MainAudioContext.sampleRate);
            while((AQDecTime()+todec) > maxsamples) {
                const tosleep = ((AQDecTime() + todec - maxsamples)/ MainAudioContext.sampleRate) * 1000; 
                if(!(await abortablesleep_status(tosleep, mysignal)))
                {
                    unlock();
                    return;
                }
            }
            
            // decode
            let buffer;
            for(let failedcount = 0;!buffer;) {
                try {
                    buffer = await NWDRFLAC.read_pcm_frames_to_AudioBuffer(dectime, todec, mysignal, MainAudioContext);
                    if(mysignal.aborted) {
                        console.log('aborted decodeaudiodata success');
                        unlock();                        
                        return;
                    }
                    if(buffer.duration !== (todec / NWDRFLAC.sampleRate)) {                       
                        buffer = null;
                        throw('network error? buffer wrong length');
                    }                        
                }
                catch(error) {
                    console.error(error);
                    if(mysignal.aborted) {
                        console.log('aborted read_pcm_frames decodeaudiodata catch');
                        unlock();                        
                        return;
                    }                   
                    failedcount++;
                    if(failedcount == 2) {
                        console.log('Encountered error twice, advancing to next track');
                         // assume it's corrupted. force free it
                        await NWDRFLAC.close();
                        NWDRFLAC = null;                      
                        continue TRACKLOOP;
                    }
                }
            }

            const isEnd = ((dectime+todec) === NWDRFLAC.totalPCMFrameCount);
            AudioQueue.push({'buffer':buffer, 'track':track, 'isStart':isStart, 'isEnd':isEnd, 'frameindex':dectime, 'aqindex':NextAQIndex});
            MainAudioContext.resume();
            isStart = false;
            dectime += todec;
            //yield
            if(!(await abortablesleep_status(0, mysignal)))
            {
                unlock();
                return;
            }

        }        
    }
    unlock();
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

// BEGIN UI handlers

rptrackbtn.addEventListener('change', function(e) {
    if(!PlaybackInfo) return;                              // nothing is playing repeattrack should do nothing
    if(PlaybackInfo.aqindex === NextAQIndex) return; // current playing is still being queued do nothing
    
    console.log('rptrack abort');
    // clear the audio queue of next tracks
    for(let i = 0; i < AudioQueue.length; i++)
    {
        if(AudioQueue[i].aqindex !== PlaybackInfo.aqindex) {
            AudioQueue.length = i;
            break;
        }
    }
    
    if(e.target.checked) {
        // repeat the currently playing track
        Tracks_QueueCurrent = PlaybackInfo.track;
    }
    else {
        // queue the next track
        Tracks_QueueCurrent = PlaybackInfo.track.next;
    }
    fillAudioQueue();
 });
 
 ppbtn.addEventListener('click', function (e) {
     if ((ppbtn.textContent == 'PAUSE')) {
         MainAudioContext.suspend();           
         ppbtn.textContent = 'PLAY';                        
     }
     else if ((ppbtn.textContent == 'PLAY')) {
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
     if(PlaybackInfo) {
         Tracks_QueueCurrent = PlaybackInfo.track;    
         // stop all audio
         StopAudio();
         let stime = Number(e.target.value);
         console.log('SEEK ' + stime);
        fillAudioQueue(stime);
     }         
 });
 
 prevbtn.addEventListener('click', function (e) {
    let prevtrack;
    if(Tracks_QueueCurrent) {
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
    StopAudio();
    fillAudioQueue();    
 });
 
 nextbtn.addEventListener('click', function (e) {        
    let nexttrack;
    if(PlaybackInfo) {
        if(!PlaybackInfo.track.next) return;
        nexttrack = PlaybackInfo.track.next;
    }
    else if(Tracks_QueueCurrent) {
        if(!Tracks_QueueCurrent.next) return;
        nexttrack = Tracks_QueueCurrent.next;
    }
    else {
        return;
    }

    Tracks_QueueCurrent = nexttrack;
    StopAudio();
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


function InitPPText() {
    if(MainAudioContext.state === "suspended") {
        ppbtn.textContent = "PLAY";
    }
    else {
        ppbtn.textContent = "PAUSE";
    }        
}

let PTrackUrlParams;
function _BuildPTrack() {
    PTrackUrlParams = new URLSearchParams();
    /*if (MAX_SAMPLE_RATE) PTrackUrlParams.append('max_sample_rate', MAX_SAMPLE_RATE);
    if (BITDEPTH) PTrackUrlParams.append('bitdepth', BITDEPTH);
    if (USESEGMENTS) PTrackUrlParams.append('segments', USESEGMENTS);
    if (USEINCREMENTAL) PTrackUrlParams.append('inc', USEINCREMENTAL);*/
    /*Tracks.forEach(function (track) {
        PTrackUrlParams.append('ptrack', track.trackname);
    });
    */
   for(let track = Tracks_HEAD; track; track = track.next) {
       PTrackUrlParams.append('ptrack', track.trackname);
   }
}

function BuildPTrack() {
    // window.history.replaceState is slow :(
    setTimeout(function() {
    _BuildPTrack();
    var urlstring = PTrackUrlParams.toString();
    if (urlstring != '') {
        console.log('replace state begin');
        //window.history hangs the page
        //window.history.replaceState('playlist', 'Title', '?' + urlstring);        
        console.log('replace state end');
    }
    }, 5000);
}


// Main
MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });

// queue the tracks in the url
let orig_ptracks = urlParams.getAll('ptrack');
if (orig_ptracks.length > 0) {
    QueueTracks(orig_ptracks);
}

const READER_MSG = {
    'RESET'     : 0, // data param token
    'FRAMES_ADD' : 1 // data param number of frames
};

// number of message slots in use
const MSG_COUNT = {
    'READER' : 0,
    'WRITER' : 1
};

const ARBLen  = MainAudioContext.sampleRate * 2;
if (!self.SharedArrayBuffer) {
    console.error('SharedArrayBuffer is not supported in browser');
}
const SharedBuffers = {
    message_count : new SharedArrayBuffer(4*2),
    reader_messages: new SharedArrayBuffer(4*32),
    writer_messages : new SharedArrayBuffer(4*4096),
    arb : [new SharedArrayBuffer(ARBLen * 4), new SharedArrayBuffer(ARBLen * 4)]
};


import { RingBuffer } from './AudioWriterReader.js'
const MessageCount = new Uint32Array(SharedBuffers.message_count);
const AudioWriter    = [RingBuffer.writer(SharedBuffers.arb[0], Float32Array), RingBuffer.writer(SharedBuffers.arb[1], Float32Array)];
const MessageWriter = RingBuffer.writer(SharedBuffers.reader_messages, Uint32Array);
const MessageReader = RingBuffer.reader(SharedBuffers.writer_messages, Uint32Array);
let tok = 0;
let freeFrames = ARBLen;
// Avoid GC
let tempMessageIN  = new Uint32Array(2);
let tempMessageOUT = new Uint32Array(2);
const FreeFrames = function() {
    const messagetotal = Atomics.load(MessageCount, MSG_COUNT.WRITER);
    let messages = messagetotal;
    while(messages > 0) {
        MessageReader.read(tempMessageIN,messages);
        // only process messages with the current token
        if(tempMessageIN[0] === tok) {
            freeFrames += tempMessageIN[1];
        }
        //console.log('message in inc ' + message[0] + ' ' + message[1] + ' tok ' + tok )
        messages -= 2;
    }
    Atomics.sub(MessageCount, MSG_COUNT.WRITER, messagetotal);
    return freeFrames;
};

function pushFrames(buffer) {
    for(let chanIndex = 0; chanIndex < buffer.numberOfChannels; chanIndex++) {
        AudioWriter[chanIndex].write(buffer.getChannelData(chanIndex));        
    }
    tempMessageOUT[0] = READER_MSG.FRAMES_ADD;
    tempMessageOUT[1] = buffer.getChannelData(0).length;
    MessageWriter.write(tempMessageOUT);
    //console.log('message out inc ' + message[0] + ' ' + message[1] + ' tok ' + tok )
    Atomics.add(MessageCount, MSG_COUNT.READER, 2);
    freeFrames -= buffer.getChannelData(0).length;    
}



const StopAudio = function() {
    AudioQueue = [];
    for(let i = 0; i < AudioWriter.length; i++) {
        AudioWriter[i].reset();
    }    
    freeFrames = ARBLen;
    tok++;
    if(tok > 4294967295) tok = 0;
    tempMessageOUT[0] = READER_MSG.RESET;
    tempMessageOUT[1] = tok;
    MessageWriter.write(tempMessageOUT);
    Atomics.add(MessageCount, MSG_COUNT.READER, 2);    
    PlaybackInfo = null;
    //console.log('message out inc reset ' + message[0] + ' ' + message[1] + ' tok ' + tok )
};

(async function() {
    await MainAudioContext.audioWorklet.addModule('worklet_processor.js');
    MusicNode = new AudioWorkletNode(MainAudioContext, 'MusicProcessor',  {'numberOfOutputs' : 1, 'outputChannelCount': [2]});
    MusicNode.connect(GainNode);
    MusicNode.port.postMessage({'message' : 'init', sharedbuffers : SharedBuffers});    
})();


window.requestAnimationFrame(GraphicsLoop);
PumpAudioQueue();

//QueueTrack("Chuck Person - Chuck Person's Eccojams Vol 1 (2016 WEB) [FLAC]/A1.flac");