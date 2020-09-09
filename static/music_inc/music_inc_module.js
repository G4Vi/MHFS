import {default as NetworkDrFlac} from './music_drflac_module.js'

let MainAudioContext;
let GainNode;
let NextBufferTime;
let PlaybackInfo;
let GraphicsTimers = [];
let AudioQueue = [];
let Tracks = [];
let FACAbortController = new AbortController();

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
    if(NextBufferTime < MainAudioContext.currentTime) {
        let newtime = MainAudioContext.currentTime+0.050;
        if(PlaybackInfo) {
            console.log('fell behind, adjusting time')
            let elapsedtime = NextBufferTime-PlaybackInfo.starttime;
            AddGraphicsTimer(newtime, newtime - elapsedtime, PlaybackInfo.duration);
            PlaybackInfo = null;
        }
        NextBufferTime = newtime;
    }
    
    // don't queue if we have plenty buffered
    let lookaheadtime = MainAudioContext.currentTime + 0.199;
    while(NextBufferTime < lookaheadtime) {
        // everything is scheduled break out
        if(acindex === AudioQueue.length) return;  
        let toQueue = AudioQueue[acindex];

        let source = MainAudioContext.createBufferSource();        
        source.buffer = toQueue.buffer;
        source.connect(GainNode);    
        source.start(NextBufferTime, 0);
        toQueue.source = source;

        toQueue.startTime = NextBufferTime;
        toQueue.endTime = toQueue.startTime + source.buffer.duration;
        if(toQueue.func) toQueue.func(toQueue.startTime);

        NextBufferTime += source.buffer.duration;
        acindex++;        
    }
}

function GraphicsLoop() {
    let removetimers = 0;
    for(let i = 0; i < GraphicsTimers.length; i++) {
        if(GraphicsTimers[i].time <= MainAudioContext.currentTime) {
            GraphicsTimers[i].func(GraphicsTimers[i]);
            removetimers++;
        }
    }
    GraphicsTimers.splice(0, removetimers);
    if(PlaybackInfo) {
        //don't advance the clock past the end of queued audio
        let aclocktime = (NextBufferTime > MainAudioContext.currentTime) ? MainAudioContext.currentTime : NextBufferTime;
        let curTime = aclocktime-PlaybackInfo.starttime;
        // song finished, stop display
        if(curTime >= PlaybackInfo.duration) {
            SetEndtimeText(0);
            curTime = 0;
            PlaybackInfo = null;
        }
        SetCurtimeText(curTime);
        SetSeekbarValue(curTime);
    }   
    
    window.requestAnimationFrame(GraphicsLoop);
}

MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });
NextBufferTime = MainAudioContext.currentTime;
setInterval(function() {
    MainAudioLoop();
}, 25);
window.requestAnimationFrame(GraphicsLoop);

function QueueTrack(trackname) {
    Tracks[Tracks.length] = {'trackname' : trackname};
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

// returns the currently or about to be playing AQID
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

let QueueIndex = 0;
let AQID = 0;

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


function AddGraphicsTimer(time, startTime, duration) {
    GraphicsTimers.push({'time': time, 'func': function(){
        PlaybackInfo = {
            'starttime' : startTime,
            'duration' : duration
        };                   
        seekbar.min = 0;
        seekbar.max = duration;
        SetEndtimeText(duration);
    }});
}


async function fillAudioQueue() {
TRACKLOOP:for(; QueueIndex < Tracks.length; QueueIndex++) {
        let track = Tracks[QueueIndex];        
        
        // open the track
        for(let failedtimes = 0; !track.nwdrflac; ) {
            let mysignal = FACAbortController.signal;                
            try {                
                let nwdrflac = await NetworkDrFlac(track.trackname, function() {
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
                if(failedtimes == 2) {
                    console.log('Encountered error twice, advancing to next track');                    
                    continue TRACKLOOP;
                }
            }
        }

        // queue the track
        let dectime = 0;
        while(dectime < track.duration) {
            // if plenty of audio is queued. Don't download            
            while(AQ_unqueuedTime() >= 10) {
                let mysignal = FACAbortController.signal;
                await sleep(25);
                if(mysignal.aborted) {
                    console.log('aborted sleep');                   
                    return;
                }                    
            }

            let todec = Math.min(1, track.duration - dectime);            
            let buffer;
            for(let failedcount = 0;!buffer;) {
                let mysignal = FACAbortController.signal;
                try {
                    let wav = await track.nwdrflac.read_pcm_frames_to_wav(dectime * track.nwdrflac.sampleRate, todec * track.nwdrflac.sampleRate);
                    if(mysignal.aborted) {
                        console.log('aborted read_pcm_frames success');                   
                        return;
                    }
                    buffer = await MainAudioContext.decodeAudioData(wav);
                    if(mysignal.aborted) {
                        console.log('aborted decodeaudiodata success');                   
                        return;
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
            let aqItem = { 'buffer' : buffer, 'duration' : todec, 'aqid' : AQID, 'queueindex' : QueueIndex};
            // At start of track update the GUI
            if(dectime === 0) {
                aqItem.func = function(startTime) {
                    GraphicsTimers.push({'time': startTime, 'func': function(){
                        PlaybackInfo = {
                            'starttime' : startTime,
                            'duration' : track.duration
                        };                   
                        seekbar.min = 0;
                        seekbar.max = track.duration;
                        SetEndtimeText(track.duration);
                    }});
                }
            }
            AudioQueue.push(aqItem);        
            dectime += todec;
        }
        AQID++;
        if(document.getElementById("repeattrack").checked) {           
            QueueIndex--;
        }           
        
    }
}

QueueTrack('../../music_dl?name=Chuck%20Person%20-%20Chuck%20Person%27s%20Eccojams%20Vol%201%20(2016%20WEB)%20%5BFLAC%5D%2FA5.flac&max_sample_rate=48000&gapless=1&gdriveforce=1');
fillAudioQueue();

// BEGIN UI handlers
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
rptrackbtn.addEventListener('change', function(e) {
    let aqid = AQ_ID();
    if(aqid === -1) return;   // nothing is playing repeattrack should do nothing
    if(aqid === AQID) return; // current playing is still being queued do nothing 
    console.log('rptrack abort');
    AQ_stopAudioWithoutID(aqid); // stop the audio queue of next track(s)
    FACAbortController.abort();  // stop the decode queue of next tracks(s)
    FACAbortController = new AbortController();
    if(e.target.checked) {
        // set QueueIndex to the current track
        QueueIndex = AudioQueue[0].queueindex;
    }
    else {
        // set QueueIndex to the next track
        QueueIndex = AudioQueue[0].queueindex+1;
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

 });
 
 seekbar.addEventListener('change', function (e) {
     
 });
 
 prevbtn.addEventListener('click', function (e) {

 });
 
 nextbtn.addEventListener('click', function (e) {        

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