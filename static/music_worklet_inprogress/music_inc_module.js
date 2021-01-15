import {default as MHFSPlayer} from './player/mhfsplayer.js'

// times in seconds
const AQMaxDecodedTime = 20;    // maximum time decoded, but not queued
const DesiredChannels = 2;
const DesiredSampleRate = 44100;

let SBAR_UPDATING = 0;

(async function () {
let MHFSPLAYER = await MHFSPlayer({'sampleRate' : DesiredSampleRate, 'channels' : DesiredChannels});

function GraphicsLoop() {
    if(!SBAR_UPDATING) {
        UpdateTrack();
    }
    
    if(SBAR_UPDATING) {        
        
    }
    else if(MHFSPLAYER.isplaying()) {
        //don't advance the clock past the end of queued audio  
        const curTime = MHFSPLAYER.tracktime();        
        SetCurtimeText(curTime);
        SetSeekbarValue(curTime);
    }   
    
    window.requestAnimationFrame(GraphicsLoop);
}

function geturl(trackname) {
    let url = '../../music_dl?name=' + encodeURIComponent(trackname);
    url  += '&max_sample_rate=' + DesiredSampleRate;
    url  += '&fmt=flac';
    return url;
}

const onQueueUpdate = function(track) {
    if(track) {
        SetPrevText(track.prev ?  track.prev.trackname : '');
        SetPlayText(track.trackname);
        SetNextText(track.next ? track.next.trackname : '')
    }
    else if(MHFSPLAYER.Tracks_TAIL) {
        SetPrevText(MHFSPLAYER.Tracks_TAIL.trackname);
        SetPlayText('');
        SetNextText('');
    }
}

function _QueueTrack(trackname, after) {
    let track = {'trackname' : trackname, 'url' : geturl(trackname)};

    // if not specified queue at tail
    after = after || MHFSPLAYER.Tracks_TAIL;    
    
    //set the next track
    if(after && after.next) {
        const before = after.next;
        before.prev = track;
        track.next = before;              
    }
    else {
        // if there isn't a next track we are the tail
        MHFSPLAYER.Tracks_TAIL = track;
    }
    
    // set the previous track
    if(after) {
        after.next = track;
        track.prev = after;       
    }
    else {
        // if were' not queued after anything we are the head
        MHFSPLAYER.Tracks_HEAD = track;
    }

    //onQueueUpdate((MHFSPLAYER.AudioQueue[0] ? MHFSPLAYER.AudioQueue[0].track : MHFSPLAYER.Tracks_QueueCurrent)|| track);
    
    // if nothing is being queued, start the queue
    if(!MHFSPLAYER.Tracks_QueueCurrent){
        MHFSPLAYER.Tracks_QueueCurrent = track;
        fillAudioQueue(); 
    }
    else {
        onQueueUpdate(MHFSPLAYER.AudioQueue[0] ? MHFSPLAYER.AudioQueue[0].track : MHFSPLAYER.Tracks_QueueCurrent);
    }

    return track;
}

function _PlayTrack(trackname) {
    let queuePos;
    if(MHFSPLAYER.AudioQueue[0]) {
        queuePos = MHFSPLAYER.AudioQueue[0].track;
    }
    else if(MHFSPLAYER.Tracks_QueueCurrent) {
        queuePos = MHFSPLAYER.Tracks_QueueCurrent;
    }   

    // stop all audio
    StopAudio();
    MHFSPLAYER.Tracks_QueueCurrent = null;
    return _QueueTrack(trackname, queuePos);   
}

// BuildPTrack is expensive so _QueueTrack and _PlayTrack don't call it
function QueueTrack(trackname, after) {
    let res = _QueueTrack(trackname, after);
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

const abortablesleep = (ms, signal) => new Promise(function(resolve) {
    const onTimerDone = function() {
        resolve();
        signal.removeEventListener('abort', stoptimer);
    };
    let timer = setTimeout(function() {
        //console.log('sleep done ' + ms);
        onTimerDone();
    }, ms);

    const stoptimer = function() {
        console.log('aborted sleep');            
        onTimerDone();
        clearTimeout(timer);            
    };
    signal.addEventListener('abort', stoptimer);
});

const abortablesleep_status = async function (ms, signal) {
    await abortablesleep(ms, signal);
    if(signal.aborted) {
        return false;
    }
    return true;
}

const ProcessTimes = function(aqitem, struct_buffer, time) {
    
    /*
    // if there's no starttime or endtime has beeen exceeded we're doing a fresh start
    if(!aqitem.starttime || (MHFSPLAYER.ac.currentTime > aqitem.endTime)) {
        aqitem.starttime = time - (struct_buffer.frameindex / aqitem.track.sampleRate);                
        aqitem._starttime = time;
        aqitem.needsstart = 1;
    }
    */
    if(aqitem.endTime && (MHFSPLAYER.ac.currentTime > aqitem.endTime)) {
        aqitem.skiptime += (aqitem.endTime - aqitem._starttime);
        aqitem.starttime = null;
    }
    if(!aqitem.starttime) {
        aqitem.starttime = time - aqitem.skiptime;
        aqitem._starttime = time;
        aqitem.needsstart = 1;  
    }

    aqitem.endTime = time + (struct_buffer.buffer.length/MHFSPLAYER.ac.sampleRate);    
}

const StopAudio = function() {
    MHFSPLAYER.AudioQueue = [];
    MHFSPLAYER._ab.reset(); 
};


let UpdateTrackTimerID;
const UpdateTrack = function() {
    clearTimeout(UpdateTrackTimerID);

    // determine if a queue update needs to happen
    let needsStart = 0;
    let toDelete = 0;
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
        const aqitem = MHFSPLAYER.AudioQueue[i];
        // mark track as started 
        if(aqitem.needsstart && (aqitem._starttime <= MHFSPLAYER.ac.currentTime)) {
            aqitem.needsstart = 0;
            needsStart = 1;            
        }

        // mark ended track
        if(aqitem.queued) {
            // if there's no endtime or has passed
            if((!aqitem.endTime) || (aqitem.endTime <= MHFSPLAYER.ac.currentTime)) {
                needsStart = 0; //invalidate previous starts as something later ended
                toDelete++;
            }
        }        
    }
    
    // perform the queue update
    if(needsStart || toDelete) {
        let track;
        if(toDelete) {
            track = MHFSPLAYER.AudioQueue[toDelete-1].track.next ? MHFSPLAYER.AudioQueue[toDelete-1].track.next : {'prev' : MHFSPLAYER.AudioQueue[toDelete-1].track, 'trackname' : ''};
            MHFSPLAYER.AudioQueue.splice(0, toDelete);     
        }        
        if(!needsStart) {                  
            SetCurtimeText(0);
            SetSeekbarValue(0);
        }
        
        track = MHFSPLAYER.AudioQueue[0] ? MHFSPLAYER.AudioQueue[0].track : track;           
            
        seekbar.min = 0;
        const duration =  (track && track.duration) ? track.duration : 0;
        seekbar.max = duration;
        SetEndtimeText(duration);
        SetPlayText(track ? track.trackname : '');
        SetPrevText((track && track.prev) ? track.prev.trackname : '');            
        SetNextText((track && track.next) ? track.next.trackname : '');            
    }

    // always run at least once a minute
    UpdateTrackTimerID = setTimeout(UpdateTrack, 60000);
}

const PumpAudioQueue = async function() {
    while(1) {      
    
        // find an unqueued item
        let aqindex;
        for(aqindex = 0; MHFSPLAYER.AudioQueue[aqindex] && MHFSPLAYER.AudioQueue[aqindex].queued; aqindex++);
        let sleeptime = 20;
        do {
            // verify we have decoded audio and enough room for it
            if(!MHFSPLAYER.AudioQueue[aqindex]) break;
            if(MHFSPLAYER.AudioQueue[aqindex].buffers.length === 0) break;
            const space = MHFSPLAYER._ab.getspace();
            const item = MHFSPLAYER.AudioQueue[aqindex];            
            let bufferedTime = MHFSPLAYER._ab.gettime();
            const mindelta = 0.1; // 100ms
            const bufferdelta = (mindelta - bufferedTime);
            const neededspace = (bufferdelta > 0) ? bufferdelta + item.buffers[0].buffer.length : item.buffers[0].buffer.length;
            if(neededspace > space) {
                sleeptime = Math.min(sleeptime, (neededspace-space)/MHFSPLAYER.ac.sampleRate);
                break;
            }

            // make the audio available to the audio worklet
            if(bufferdelta > 0) {
                const len = bufferdelta * MHFSPLAYER.ac.sampleRate;
                const zeroarray = [
                    new Float32Array(len),
                    new Float32Array(len)
                ];
                MHFSPLAYER._ab.write(zeroarray);
                console.log('wrote ' + len + ' zeros bufferedTime ' + bufferedTime);
                bufferedTime = mindelta;
            }            
            // remove a buffer and queue it
            let buffer = item.buffers.shift();
            let data = [];
            for(let i = 0; i < buffer.buffer.numberOfChannels; i++) {
                // this sucks we are creating a new float32 array
                data[i] = buffer.buffer.getChannelData(i);
            }        
            MHFSPLAYER._ab.write(data);             
            ProcessTimes(item, buffer, bufferedTime + MHFSPLAYER.ac.currentTime);
            item.queued = item.donedecode && (item.buffers.length === 0);
        } while(0);

        const mysignal = MHFSPLAYER.FACAbortController.signal;
        await abortablesleep(sleeptime, mysignal);                
    }
}

const AQDecTime = function() {
    let dectime = 0;  
    
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
        for(let j = 0; j < MHFSPLAYER.AudioQueue[i].buffers.length; j++) {
            dectime += MHFSPLAYER.AudioQueue[i].buffers[j].buffer.length;
        }        
    }    

    return dectime; 
}

async function fillAudioQueue(time) {
    MHFSPLAYER.ac.resume();  
    
    // starting a fresh queue, render the text
    InitPPText();    

    // Stop the previous FAQ before starting
    MHFSPLAYER.FACAbortController.abort();
    MHFSPLAYER.FACAbortController = new AbortController();
    const mysignal = MHFSPLAYER.FACAbortController.signal;
    const unlock = await MHFSPLAYER.FAQ_MUTEX.lock();    
    if(mysignal.aborted) {
        console.log('abort after mutex acquire');
        unlock();
        return;
    }

    //const decoder = MHFSPLAYER.OpenDecoder(MHFSPLAYER.sampleRate, MHFSPLAYER.channels);    
    
    time = time || 0;
    // while there's a track to queue
TRACKLOOP:for(; MHFSPLAYER.Tracks_QueueCurrent; MHFSPLAYER.Tracks_QueueCurrent = document.getElementById("repeattrack").checked ?  MHFSPLAYER.Tracks_QueueCurrent : MHFSPLAYER.Tracks_QueueCurrent.next) {
        
        const track = MHFSPLAYER.Tracks_QueueCurrent;
        // render the text if nothing is queued
        if(!MHFSPLAYER.AudioQueue[0]) {
            let track = MHFSPLAYER.Tracks_QueueCurrent;
            let prevtext = track.prev ? track.prev.trackname : '';
            SetPrevText(prevtext);
            SetPlayText(track.trackname + ' {LOADING}');
            let nexttext =  track.next ? track.next.trackname : '';
            SetNextText(nexttext);
            SetCurtimeText(time || 0);
            if(!time) SetSeekbarValue(time || 0);
            SetEndtimeText(track.duration || 0);        
        }

        // open the track in the decoder
        try {
            await MHFSPLAYER.OpenNetworkDrFlac(track.url, mysignal);
        }
        catch(error) {
            time = 0;
            console.error(error);
            if(mysignal.aborted) {
                break;
            }
            continue;
        }

        // seek
        const start_dec_frame = Math.floor(time * MHFSPLAYER.NWDRFLAC.sampleRate);
        const start_output_time = time;
        time = 0;
        try{
            await MHFSPLAYER.NWDRFLAC.seek(start_dec_frame);        
        }
        catch(error) {
            console.error(error);
            if(gsignal.aborted) {
                break;
            }
            continue;
        }        
        track.duration = MHFSPLAYER.NWDRFLAC.totalPCMFrameCount / MHFSPLAYER.NWDRFLAC.sampleRate;
        track.sampleRate = MHFSPLAYER.NWDRFLAC.sampleRate;       

        // decode the track
        let pbtrack = {
            'track' : track,
            'buffers'  : [],            
            'skiptime' : start_output_time
        };
        MHFSPLAYER.AudioQueue.push(pbtrack);        
     
        const todec = MHFSPLAYER.ac.sampleRate;
        const maxsamples = (AQMaxDecodedTime * MHFSPLAYER.ac.sampleRate);            
        SAMPLELOOP: while(1) {
            // yield so buffers can be queued
            if(pbtrack.buffers.length > 0) {
                if(!(await abortablesleep_status(0, mysignal)))
                {
                    break TRACKLOOP;                    
                }
            }           

            // wait for there to be space                         
            while((AQDecTime()+todec) > maxsamples) {
                const tosleep = ((AQDecTime() + todec - maxsamples)/ MHFSPLAYER.ac.sampleRate) * 1000; 
                if(!(await abortablesleep_status(tosleep, mysignal)))
                {
                    break TRACKLOOP;                    
                }
            }
            
            // decode
            let audiobuffer;
            try {
                audiobuffer = await MHFSPLAYER.ReadPcmFramesToAudioBuffer(todec, mysignal);
                // no more audio left, breakout
                if(!audiobuffer) {
                     break SAMPLELOOP;                    
                }
            }
            catch(error) {
                console.error(error);
                if(mysignal.aborted) {
                    break TRACKLOOP;
                }
                MHFSPLAYER.NWDRFLAC.close();
                MHFSPLAYER.NWDRFLAC = null;
                break SAMPLELOOP;
            }                       

            // add the buffer to the queue item
            let struct_buffer = {
                'buffer' : audiobuffer
            };
            pbtrack.buffers.push(struct_buffer);                           
            
            // break out at end
            if(audiobuffer.length < todec) {
                break SAMPLELOOP;
            }                      
        }
        pbtrack.donedecode = 1;
        pbtrack.queued = (pbtrack.buffers.length === 0);
    }
    unlock();
}

var prevbtn    = document.getElementById("prevbtn");
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
    let ti;
    for(ti = 0; MHFSPLAYER.AudioQueue[ti] && MHFSPLAYER.AudioQueue[ti].queued; ti++);
    // everything is queued
    if(!MHFSPLAYER.AudioQueue[ti]) {
        if(ti > 0) {
            MHFSPLAYER.Tracks_QueueCurrent = MHFSPLAYER.AudioQueue[ti-1].track;
            fillAudioQueue();
        }       
        return;
    }    
    
    // not done decoding
    if(!MHFSPLAYER.AudioQueue[ti].donedecode) return;

    // the current track is done decoding, but not queued. make this our last track
    MHFSPLAYER.AudioQueue.length = ti+1;

    // queue the repeat or new track (stopping the current decoding)
    MHFSPLAYER.Tracks_QueueCurrent = e.target.checked ? MHFSPLAYER.AudioQueue[ti].track : MHFSPLAYER.AudioQueue[ti].track.next;
    fillAudioQueue();
});
 
 ppbtn.addEventListener('click', function (e) {
    if ((ppbtn.textContent == 'PAUSE')) {
        MHFSPLAYER.pause();         
        ppbtn.textContent = 'PLAY';                        
    }
    else if ((ppbtn.textContent == 'PLAY')) {
        MHFSPLAYER.play();
        ppbtn.textContent = 'PAUSE';
    }
 });
 
 seekbar.addEventListener('mousedown', function (e) {
    if(!SBAR_UPDATING) {
                
    }
    SBAR_UPDATING = 1;
 });
 
 seekbar.addEventListener('change', function (e) {
    if(!SBAR_UPDATING) {
        return;
    }     
    SBAR_UPDATING = 0;
    if(!MHFSPLAYER.AudioQueue[0]) return;
    MHFSPLAYER.Tracks_QueueCurrent = MHFSPLAYER.AudioQueue[0].track;
    StopAudio();
    let stime = Number(e.target.value);
    console.log('SEEK ' + stime);
    fillAudioQueue(stime);           
 });
 
 prevbtn.addEventListener('click', function (e) {
    let prevtrack;
    if(MHFSPLAYER.AudioQueue[0]) {
        if(!MHFSPLAYER.AudioQueue[0].track.prev) return;
        prevtrack = MHFSPLAYER.AudioQueue[0].track.prev;
    }
    else if(MHFSPLAYER.Tracks_QueueCurrent) {
        if(!MHFSPLAYER.Tracks_QueueCurrent.prev) return;
        prevtrack = MHFSPLAYER.Tracks_QueueCurrent.prev;
    }
    else if(MHFSPLAYER.Tracks_TAIL) {
        prevtrack = MHFSPLAYER.Tracks_TAIL;
    }
    else {
        return;
    }

    MHFSPLAYER.Tracks_QueueCurrent = prevtrack;
    StopAudio();
    fillAudioQueue();    
 });
 
 nextbtn.addEventListener('click', function (e) {        
    let nexttrack;
    if(MHFSPLAYER.AudioQueue[0]) {
        if(!MHFSPLAYER.AudioQueue[0].track.next) return;
        nexttrack = MHFSPLAYER.AudioQueue[0].track.next;
    }
    else if(MHFSPLAYER.Tracks_QueueCurrent) {
        if(!MHFSPLAYER.Tracks_QueueCurrent.next) return;
        nexttrack = MHFSPLAYER.Tracks_QueueCurrent.next;
    }
    else {
        return;
    }

    MHFSPLAYER.Tracks_QueueCurrent = nexttrack;
    StopAudio();
    fillAudioQueue(); 
 });
 
 const volslider = document.getElementById("volslider");
 volslider.addEventListener('input', function(e) {
    MHFSPLAYER.setVolume(e.target.value);
 });

 document.addEventListener('keydown', function(event) {
    if(event.key === ' ') {
        event.preventDefault();
        event.stopPropagation();
        ppbtn.click();
    }
    else if(event.key === 'ArrowRight') {
        event.preventDefault();
        event.stopPropagation();
        nextbtn.click();
    }
    else if(event.key === 'ArrowLeft') {
        event.preventDefault();
        event.stopPropagation();
        prevbtn.click();
    }
    else if(event.key === '+') {
        event.preventDefault();
        event.stopPropagation();
        volslider.stepUp(5);
        MHFSPLAYER.setVolume(volslider.value);
    }
    else if(event.key === '-') {
        event.preventDefault();
        event.stopPropagation();
        volslider.stepDown(5);
        MHFSPLAYER.setVolume(volslider.value);
    }
 });

 document.addEventListener('keyup', function(event) {
    if((event.key === ' ') || (event.key === 'ArrowRight') ||(event.key === 'ArrowLeft') || (event.key === '+') || (event.key === '-')) {
        event.preventDefault();
        event.stopPropagation();
    }
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
    if(MHFSPLAYER.ac.state === "suspended") {
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
   for(let track = MHFSPLAYER.Tracks_HEAD; track; track = track.next) {
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

// queue the tracks in the url
let orig_ptracks = urlParams.getAll('ptrack');
if (orig_ptracks.length > 0) {
    QueueTracks(orig_ptracks);
}

window.requestAnimationFrame(GraphicsLoop);
PumpAudioQueue();

//QueueTrack("Chuck Person - Chuck Person's Eccojams Vol 1 (2016 WEB) [FLAC]/A1.flac");

})();