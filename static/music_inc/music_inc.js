let MainAudioContext;
let GainNode;
let NextBufferTime;
let PlaybackInfo;
let GraphicsTimers = [];
let AudioQueue = [];
let Tracks = [];

function CreateAudioContext(options) {
    let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;
    GainNode = mycontext.createGain();
    GainNode.connect(mycontext.destination);
    return mycontext;
}

function MainAudioLoop() {

    // clean up the AQ
    let toDelete = 0;
    for(let i = 0; i < AudioQueue.length; i++) {
        if(! AudioQueue[i].endTime) break;
        if(AudioQueue[i].endTime < MainAudioContext.currentTime) {
            toDelete++;
        }
    }
    if(toDelete) AudioQueue.splice(0, toDelete);
    if(AudioQueue.length === 0) return 0;
    
    // advanced past already scheduled audio
    let acindex = 0;
    for(; acindex < AudioQueue.length; acindex++) {
        if(!AudioQueue[acindex].startTime) break;        
    }    
    
    // don't queue if we have plenty buffered
    let lookaheadtime = MainAudioContext.currentTime + 0.199;
    NextBufferTime = Math.max(NextBufferTime, MainAudioContext.currentTime+0.050);
    while(NextBufferTime < lookaheadtime) {
        // everything is scheduled break out
        if(acindex === AudioQueue.length) return;  
        let toQueue = AudioQueue[acindex];

        let source = MainAudioContext.createBufferSource();        
        source.buffer = toQueue.buffer;
        source.connect(GainNode);    
        source.start(NextBufferTime, 0);

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
    let curTime = 0;
    if(PlaybackInfo) {
        curTime = MainAudioContext.currentTime-PlaybackInfo.starttime;
        if(curTime > PlaybackInfo.duration) {
            SetEndtimeText(0);
            curTime = 0;
            PlaybackInfo = null;
        }
    }
   
    SetCurtimeText(curTime);
    SetSeekbarValue(curTime);

    window.requestAnimationFrame(GraphicsLoop);
}

async function Track(name) {
    let nwdrflac = await NetworkDrFlac_open(name);
    if(!nwdrflac) {
        console.error('failed to NetworkDrFlac_open');
        return;
    }
    return {
        'nwdrflac' : nwdrflac,
        'duration' : nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate,
        'decoded'  : 0
    };
}

MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });
NextBufferTime = MainAudioContext.currentTime;
setInterval(function() {
    MainAudioLoop();
}, 25);
window.requestAnimationFrame(GraphicsLoop);

function QueueTrack(trackname) {
    Tracks[Tracks.length] = {'trackname' : trackname, 'decoded' : 0};
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

function FAQ() {

}

if(typeof sleep === 'undefined') {
    const sleep = m => new Promise(r => setTimeout(r, m));
    DeclareGlobalFunc('sleep', sleep);
}


function FAQ_TRACK(){}

async function fillAudioQueue() {
    for(let i = 0; i < Tracks.length; i++) {
        let track = Tracks[i];
        if(!track.queued) {
            if(!track.nwdrflac) {
                let nwdrflac = await NetworkDrFlac_open(track.trackname);
                if(!nwdrflac) {
                    console.error('failed to NetworkDrFlac_open');
                    return;
                }
                track.nwdrflac = nwdrflac;
                track.duration =  nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate;
            }
            while(track.decoded < track.duration) {
                // if plenty of audio is queued. Don't download
                while(AQ_unqueuedTime() >= 10) {
                    await sleep(25);                    
                }

                let todec = Math.min(0.100, track.duration - track.decoded);        
                let wav = await NetworkDrFlac_read_pcm_frames_to_wav(track.nwdrflac, track.decoded * track.nwdrflac.sampleRate, todec * track.nwdrflac.sampleRate);
                if(!wav) {
                    console.error('bad wav');
                    return;
                }
                let buffer = await MainAudioContext.decodeAudioData(wav);
                if(!buffer) {
                    console.error('bad wav decode');
                    return;
                }
             
                // Add to the audio queue
                let aqItem = { 'buffer' : buffer, 'duration' : todec};
                // At start of track update the GUI
                if(track.decoded === 0) {
                    aqItem.func = function(startTime) {
                        GraphicsTimers.push({'time': startTime, 'func': function(data){
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
                track.decoded += todec;
            }
            track.queued = true;
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