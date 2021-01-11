import {default as MHFSPlayer} from './player/mhfsplayer.js'

// times in seconds
const AQMaxDecodedTime = 20;    // maximum time decoded, but not queued
const DesiredChannels = 2;
const DesiredSampleRate = 44100;

let SBAR_UPDATING = 0;

(async function () {
let MHFSPLAYER = await MHFSPlayer({'sampleRate' : DesiredSampleRate, 'channels' : DesiredChannels});

function GraphicsLoop() {
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

function _QueueTrack(trackname, after, before) {
    let track = {'trackname' : trackname, 'url' : geturl(trackname)};
    
    if(!after) {
        after = MHFSPLAYER.Tracks_TAIL;        
    }
    if(!before && (after !== MHFSPLAYER.Tracks_TAIL)) {
        before = after.next;        
    }
    
    if(after) {
        after.next = track;
        track.prev = after;
        if(after === MHFSPLAYER.Tracks_TAIL) {
            MHFSPLAYER.Tracks_TAIL = track;
        }
    }    
    if(before) {
        before.prev = track;
        track.next = before;
        if(before === MHFSPLAYER.Tracks_HEAD) {
            MHFSPLAYER.Tracks_HEAD = track;       
        }        
    }
    
    // we have no link list without a head and a tail
    if(!MHFSPLAYER.Tracks_HEAD || !MHFSPLAYER.Tracks_TAIL) {
       MHFSPLAYER.Tracks_TAIL = track;        
       MHFSPLAYER.Tracks_HEAD = track;        
    }

    // update text
    /*let tocheck = (MHFSPLAYER.AudioQueue[0]) ? MHFSPLAYER.AudioQueue[0].track : MHFSPLAYER.Tracks_QueueCurrent;
    // if there's no current track, we are setting it. the prev and next track could have just changed
    if(!tocheck) {
        SetPrevText(track.prev ?  track.prev.trackname : '');
        SetPlayText(track.trackname);
        SetNextText(track.next ? track.next.trackname : '')
    }
    else if (tocheck.next === track) {
        SetNextText(track.trackname);
    }
    // probably impossible
    else if(tocheck.prev === track) {
        SetPrevText(track.trackname);
    }*/

    
    onQueueUpdate((MHFSPLAYER.AudioQueue[0] ? MHFSPLAYER.AudioQueue[0].track : MHFSPLAYER.Tracks_QueueCurrent)|| track);
    
    // if nothing is being queued, start the queue
    if(!MHFSPLAYER.Tracks_QueueCurrent){
        MHFSPLAYER.Tracks_QueueCurrent = track;
        fillAudioQueue(); 
    }

    /*
    // if nothing is being queued, start the queue
    let needsText = 1;
    if(!MHFSPLAYER.Tracks_QueueCurrent) {
        needsText = MHFSPLAYER.AudioQueue[0] ? 1 : 0;
        MHFSPLAYER.Tracks_QueueCurrent = track;
        fillAudioQueue();        
    }

    if(needsText) {
        // Update text otherwise
        let tocheck = (MHFSPLAYER.AudioQueue[0]) ? MHFSPLAYER.AudioQueue[0].track : MHFSPLAYER.Tracks_QueueCurrent;
        if(tocheck) {
            if(tocheck.prev === track) {
                SetPrevText(track.trackname);
            }
            else if(tocheck.next === track) {
                SetNextText(track.trackname);
            }
        }            
    }    
    */
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
    
    let queueAfter; //falsey is tail
    if(queuePos) {
        queueAfter = queuePos.next;        
    }    

    // stop all audio
    StopAudio();
    MHFSPLAYER.Tracks_QueueCurrent = null;
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
    // if there's no starttime or endtime has beeen exceeded we're doing a fresh start
    if(!aqitem.starttime || (MHFSPLAYER.ac.currentTime > aqitem.endTime)) {
        // swithc to buffer frameindex
        aqitem.starttime = time - (struct_buffer.frameindex / aqitem.track.sampleRate);
        InitPPText();        
        aqitem.timers.push(
        {'time': time, 'aqindex': aqitem.aqindex, 'func': function() {         
            // frameindex is actually in decoder units                          
            seekbar.min = 0;
            seekbar.max = aqitem.track.duration;
            SetEndtimeText(aqitem.track.duration);
            SetPlayText(aqitem.track.trackname);
            let prevtext = aqitem.track.prev ? aqitem.track.prev.trackname : '';
            SetPrevText(prevtext);       
            let nexttext =  aqitem.track.next ? aqitem.track.next.trackname : '';
            SetNextText(nexttext);
        }});
    }
       
      
    const endTime = time + (struct_buffer.preciseLength/MHFSPLAYER.ac.sampleRate);
    aqitem.endTime = endTime;
    // set end time
    if(struct_buffer.isEnd) {
        aqitem.timers.push(
        {'time': endTime, 'aqindex': aqitem.aqindex, 'func': function(){           
            let curTime = 0;
            SetEndtimeText(0);                    
            SetCurtimeText(curTime);
            SetSeekbarValue(curTime);
            if(document.getElementById("repeattrack").checked) {
                SetPrevText('');
                SetPlayText('');
                SetNextText('');
            }
            else {
                SetPrevText(aqitem.track.trackname);
                const next = aqitem.track.next;
                const playtext = next ? next.trackname : '';
                SetPlayText(playtext);
                const nexttext = (next && next.next) ? next.next.trackname : '';
                SetNextText(nexttext);
            }            
        }});
    }
}

const StopAudio = function() {
    MHFSPLAYER.AudioQueue = [];
    MHFSPLAYER._ab.reset(); 
};


const StopNextAudio = function() {
    
}




const PumpAudioQueue = async function() {
    while(1) {        
       
        // remove already queued segments
        let toDelete = 0;
        for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
            if(! MHFSPLAYER.AudioQueue[i].endTime) break;
            
            // run and remove associated graphics timers
            let timerdel = 0;
            for(let j = 0; j < MHFSPLAYER.AudioQueue[i].timers.length; j++) {
                if(MHFSPLAYER.AudioQueue[i].timers[j].time <= MHFSPLAYER.ac.currentTime) {
                    MHFSPLAYER.AudioQueue[i].timers[j].func(MHFSPLAYER.AudioQueue[i].timers[j]);
                    timerdel++;
                }
            }
            if(timerdel)MHFSPLAYER.AudioQueue[i].timers.splice(0, timerdel);
            
            // remove if it has passed and it's timers have been run
            if(MHFSPLAYER.AudioQueue[i].timers.length === 0) {
                if(MHFSPLAYER.AudioQueue[i].endTime <= MHFSPLAYER.ac.currentTime) {
                    toDelete++;
                }
            }            
        }
        if(toDelete) {
            // if the AQ is empty and there's a current track we fell behind
            if((toDelete === MHFSPLAYER.AudioQueue.length) && (MHFSPLAYER.Tracks_QueueCurrent)) {
                //SetPlayText(MHFSPLAYER.Tracks_QueueCurrent.trackname + ' {LOADING}');
            }
            MHFSPLAYER.AudioQueue.splice(0, toDelete);
        }
    
        // find an unqueued item
        let aqindex;
        for(aqindex = 0; MHFSPLAYER.AudioQueue[aqindex] && MHFSPLAYER.AudioQueue[aqindex].queued; aqindex++);
        const item = MHFSPLAYER.AudioQueue[aqindex] && (MHFSPLAYER.AudioQueue[aqindex].buffers.length > 0) ? MHFSPLAYER.AudioQueue[aqindex] : 0;
        // if the actual MHFSPLAYER.AudioQueue is full or nothing to queue, sleep
        const space = MHFSPLAYER._ab.getspace();        
        if((!item) || (item.buffers[0].preciseLength > space)) {
            let mysignal = MHFSPLAYER.FACAbortController.signal;
            const tosleep = item ? Math.min(20, (item.buffers[0].preciseLength-space)/MHFSPLAYER.ac.sampleRate) : 20;
            await abortablesleep(tosleep, mysignal);
            continue;            
        }
        
        // make the audio available to the audio worklet
        let bufferedTime = MHFSPLAYER._ab.gettime();
        const mindelta = 0.1; // 100ms
        const bufferdelta = (mindelta - bufferedTime);
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
            data[i] = buffer.buffer.getChannelData(i);
        }        
        MHFSPLAYER._ab.write(data);             
        ProcessTimes(item, buffer, bufferedTime + MHFSPLAYER.ac.currentTime);
        item.queued = buffer.isEnd;         
    }
}

/*

const audioui()
{
    // run timers
    // delete aqmeta
    Sleep(16);
}

const AudioLoop = async function() {
while(1) {    
    let audiospace;
   
    // start filling the buffer if there's room or we aren't already filling it
    if(audiospace >= MHFSPLAYER.ac.sampleRate) {
        await abortable_read_pcm_frames
        queueaudio               
    }
    
    //abortablesleep min AudioLoop audiospace or 20    
}    
};

// DO IN WORKER 1

WHILE(1) {
    decode
    share with worker2
    sleep
}

// DO IN WORKER 2
on_datacallback(pOutput, frameCount) {
    read_pcm_frames(pOutput));
}
*/

const AQDecTime = function() {
    let now = MHFSPLAYER.ac.currentTime;
    let lastEndtime = MHFSPLAYER.ac.currentTime;   
    
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
        if(MHFSPLAYER.AudioQueue[i].endTime) lastEndtime = MHFSPLAYER.AudioQueue[i].endTime;
    }    

    return (lastEndtime - now) * MHFSPLAYER.ac.sampleRate;    
}

let NextAQIndex = 0;

async function fillAudioQueue(time) {
    MHFSPLAYER.ac.resume();
    
    // starting a fresh queue, render the text
    if(!MHFSPLAYER.AudioQueue[0] && MHFSPLAYER.Tracks_QueueCurrent) {
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

    // Stop the previous FAQ before starting
    MHFSPLAYER.FACAbortController.abort();
    MHFSPLAYER.FACAbortController = new AbortController();
    let mysignal = MHFSPLAYER.FACAbortController.signal;
    let unlock = await MHFSPLAYER.FAQ_MUTEX.lock();    
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
                MHFSPLAYER.Tracks_QueueCurrent = MHFSPLAYER.Tracks_QueueCurrent.next;
            }
        }
        initializing = 0; 
        NextAQIndex++;       ;       
        let track = MHFSPLAYER.Tracks_QueueCurrent;
        if(! track) {
            unlock();
            return;
        }

        // cleanup nwdrflac
        if(MHFSPLAYER.NWDRFLAC) {
            // we can reuse it if the urls match
            if(MHFSPLAYER.NWDRFLAC.url !== track.url)
            {
                await MHFSPLAYER.NWDRFLAC.close();
                MHFSPLAYER.NWDRFLAC = null;
                if(mysignal.aborted) {
                    console.log('abort after cleanup');
                    unlock();
                    return;
                }
            }
            else{
                track.duration = MHFSPLAYER.NWDRFLAC.totalPCMFrameCount / MHFSPLAYER.NWDRFLAC.sampleRate;
                track.sampleRate = MHFSPLAYER.NWDRFLAC.sampleRate;
            }
        }       
        
        // open the track
        for(let failedtimes = 0; !MHFSPLAYER.NWDRFLAC; ) {             
            try {                
                let nwdrflac = await MHFSPLAYER.NetworkDrFlac(track.url, DesiredChannels, mysignal);
                if(mysignal.aborted) {
                    console.log('open aborted success');
                    await nwdrflac.close();
                    unlock();
                    return;
                }
                MHFSPLAYER.NWDRFLAC = nwdrflac;                 
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
        let pbtrack = {
            'track' : track,
            'aqindex' : NextAQIndex,
            'buffers' : [],
            'timers'  : []
        };        
        let dectime = 0;
        if(time) {                         
            dectime = Math.floor(time * MHFSPLAYER.NWDRFLAC.sampleRate);            
            time = 0;
        }     
        while(dectime < MHFSPLAYER.NWDRFLAC.totalPCMFrameCount) {
            const todec = Math.min(MHFSPLAYER.NWDRFLAC.sampleRate, MHFSPLAYER.NWDRFLAC.totalPCMFrameCount - dectime);

            // wait for there to be space
            const maxsamples = (AQMaxDecodedTime * MHFSPLAYER.ac.sampleRate);
            while((AQDecTime()+todec) > maxsamples) {
                const tosleep = ((AQDecTime() + todec - maxsamples)/ MHFSPLAYER.ac.sampleRate) * 1000; 
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
                    buffer = await MHFSPLAYER.NWDRFLAC.read_pcm_frames_to_AudioBuffer(dectime, todec, mysignal, MHFSPLAYER.ac);
                    if(mysignal.aborted) {
                        console.log('aborted decodeaudiodata success');
                        unlock();                        
                        return;
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
                    // probably a network error, sleep before retry
                    if(!(await abortablesleep_status(2000, mysignal)))
                    {
                        unlock();
                        return;
                    }
                    //if(failedcount == 2) {
                    if(0) {
                        console.log('Encountered error twice, advancing to next track');
                         // assume it's corrupted. force free it
                        await MHFSPLAYER.NWDRFLAC.close();
                        MHFSPLAYER.NWDRFLAC = null;                      
                        continue TRACKLOOP;
                    }
                }
            }

            const isEnd = ((dectime+todec) === MHFSPLAYER.NWDRFLAC.totalPCMFrameCount);

            // add the buffer to the queue item
            let struct_buffer = {
                'buffer' : buffer,
                'preciseLength' : buffer.getChannelData(0).length,
                'frameindex' : dectime,
                'isEnd' : isEnd
            };
            pbtrack.buffers.push(struct_buffer);

            // if the aqindex doesn't match we need tthe queue item to the queue
            if((!MHFSPLAYER.AudioQueue[MHFSPLAYER.AudioQueue.length-1]) || (MHFSPLAYER.AudioQueue[MHFSPLAYER.AudioQueue.length-1].aqindex !== NextAQIndex)) {
                MHFSPLAYER.AudioQueue.push(pbtrack);
            }
            
            dectime += todec;
            // yield in-case it's time to queue
            if(!(await abortablesleep_status(0, mysignal)))
            {
                unlock();
                return;
            }
        }
        // Update the resampler info

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
    if(!MHFSPLAYER.AudioQueue[0]) return;                              // nothing is playing repeattrack should do nothing
    if(MHFSPLAYER.AudioQueue[0].aqindex === NextAQIndex) return;       // current playing is still being queued do nothing
    
    console.log('rptrack abort');    
    StopNextAudio();  

    if(e.target.checked) {
        // repeat the currently playing track
        MHFSPLAYER.Tracks_QueueCurrent = MHFSPLAYER.AudioQueue[0].track;
    }
    else {
        // queue the next track
        MHFSPLAYER.Tracks_QueueCurrent = MHFSPLAYER.AudioQueue[0].track.next;
    }
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