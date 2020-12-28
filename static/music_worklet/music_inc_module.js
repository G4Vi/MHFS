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

const ProcessTimes = function(aqitem, time) {
    if(!MHFSPLAYER.AudioQueue[0].starttime) aqitem.isStart = true;    
    aqitem.starttime = time;    
    if(aqitem.isStart) {
        InitPPText();        
        aqitem.timers.push(
        {'time': time, 'aqindex': aqitem.aqindex, 'func': function() {                                    
            aqitem.pbtrack.starttime = time - (aqitem.frameindex / MHFSPLAYER.ac.sampleRate);
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
    const endTime = time + (aqitem.preciseLength/MHFSPLAYER.ac.sampleRate);
    aqitem.endTime = endTime;
    if(aqitem.isEnd) {
        aqitem.timers.push(
        {'time': endTime, 'aqindex': aqitem.aqindex, 'func': function(){
            //console.log('done measured duration ' + (endTime - aqitem.starttime) + ' expected duration ' + aqitem.track.duration);    
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

// READER_MSG - messages sent by the writer (us) to the worklet
// RESET resets the read index, audio frame count, and sets the token on the audio thread
// FRAMES_ADD makes frames available for reading to the audio thread
const READER_MSG = {
    'RESET'     : 0,  // data param token
    'FRAMES_ADD' : 1, // data param number of frames
    'STOP_AT'    : 2  // data parm token, uint64 frame to stop at
};

// WRITER_MSG - messages sent by the reader(worklet) to us
// both messages contain token so the writer knows if they have been sent since last reset
// FRAMES_ADD makes frames available for writing
// START_TIME is sent in response to READER_MSG.FRAMES_ADD and contains when those frames will start
const WRITER_MSG = {
    'FRAMES_ADD' : 0, // data param token and number of frames
    'START_TIME' : 1, // data param token, float32 time
    'START_FRAME': 2, // data param token, uint64 frame
    'WRITE_INFO' : 3  // data param token, writeindex, writecount
}
const MessageInDataLength = [];
MessageInDataLength[WRITER_MSG.FRAMES_ADD] = 1;
MessageInDataLength[WRITER_MSG.START_TIME] = 1;
MessageInDataLength[WRITER_MSG.START_FRAME]= 2;
MessageInDataLength[WRITER_MSG.WRITE_INFO] = 2;


// number of messages in each direction
const MSG_COUNT = {
    'READER' : 0,
    'WRITER' : 1
};






let tok = 0;
let freeFrames = MHFSPLAYER.ARBLen;
// Avoid GC
let tempMessageIn  = new ArrayBuffer(4*4);
let tempMessageInUint32  = new Uint32Array(tempMessageIn);
let tempMessageInFloat32 = new Float32Array(tempMessageIn);
let tempMessageInUint64  = new BigUint64Array(tempMessageIn);
let tempMessageOUT = new Uint32Array(2);
let tempMessageBigOUT = new Uint32Array(4);
let tempMessageBigOUT64 = new BigUint64Array(tempMessageBigOUT.buffer);

// Process messages from the audio thread
const ProcessAudioMessages = function() {
    const messagetotal = Atomics.load(MHFSPLAYER.MessageCount, MSG_COUNT.WRITER);
    let messages = messagetotal;
    while(messages > 0) {
        MHFSPLAYER.MessageReader.read(tempMessageInUint32,Math.min(2, messages));
        messages -= 2;
        const messageid = tempMessageInUint32[0];
        const datalength = MessageInDataLength[messageid];
        const tok_valid = (tempMessageInUint32[1] === tok); 
        MHFSPLAYER.MessageReader.read(tempMessageInUint32, Math.min(datalength, messages));
        messages -= datalength;
        // only process messages with the current tok
        if(!tok_valid) continue;        

        if(messageid === WRITER_MSG.FRAMES_ADD) {
            freeFrames += tempMessageInUint32[0];                
        }
        else if(messageid === WRITER_MSG.START_TIME) {
            for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
                if(MHFSPLAYER.AudioQueue[i].starttime) continue;
                ProcessTimes(MHFSPLAYER.AudioQueue[i], tempMessageInFloat32[0]);
                break;                                   
            }
        }
        else if(messageid === WRITER_MSG.START_FRAME)
        {
            for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
                if(MHFSPLAYER.AudioQueue[i].startframe) continue;
                MHFSPLAYER.AudioQueue[i].startframe = tempMessageInUint64[0];
                break;
            }
        }
        else if(messageid === WRITER_MSG.WRITE_INFO)
        {
            // cancel complete, update write index and write count
            for(let i = 0; i < MHFSPLAYER.AudioWriter.length; i++)
            {
                MHFSPLAYER.AudioWriter[i]._writeindex = tempMessageInUint32[0];
            }                
            freeFrames = MHFSPLAYER.ARBLen - tempMessageInUint32[1];             
        }  
    }
    Atomics.sub(MHFSPLAYER.MessageCount, MSG_COUNT.WRITER, messagetotal);
    return freeFrames;
};

function pushFrames(buffer) {
    for(let chanIndex = 0; chanIndex < buffer.numberOfChannels; chanIndex++) {
        MHFSPLAYER.AudioWriter[chanIndex].write(buffer.getChannelData(chanIndex));        
    }    
    tempMessageOUT[0] = READER_MSG.FRAMES_ADD;
    tempMessageOUT[1] = buffer.getChannelData(0).length;
    MHFSPLAYER.MessageWriter.write(tempMessageOUT);
    Atomics.add(MHFSPLAYER.MessageCount, MSG_COUNT.READER, 2);
    freeFrames -= buffer.getChannelData(0).length;    
}

const StopAudio = function() {
    MHFSPLAYER.AudioQueue = [];    
    for(let i = 0; i < MHFSPLAYER.AudioWriter.length; i++) {
        MHFSPLAYER.AudioWriter[i].reset();
    }    
    freeFrames = MHFSPLAYER.ARBLen;
    tok++;
    if(tok > 4294967295) tok = 0;
    tempMessageOUT[0] = READER_MSG.RESET;
    tempMessageOUT[1] = tok;
    MHFSPLAYER.MessageWriter.write(tempMessageOUT);
    Atomics.add(MHFSPLAYER.MessageCount, MSG_COUNT.READER, 2);

    //console.log('message out inc reset ' + message[0] + ' ' + message[1] + ' tok ' + tok )
};

const StopNextAudio = function() {
    // clear the audio queue of next tracks
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++)
    {
        if(MHFSPLAYER.AudioQueue[i].aqindex !== MHFSPLAYER.AudioQueue[0].aqindex) {
            MHFSPLAYER.AudioQueue.length = i;
            
            // disable writing until cancel has complete
            tok++;
            if(tok > 4294967295) tok = 0;
            freeFrames = 0;
            // cancel the next audio
            tempMessageBigOUT[0] = READER_MSG.STOP_AT;
            tempMessageBigOUT[1] = tok;
            tempMessageBigOUT64[1] = MHFSPLAYER.AudioQueue[i-1].startframe + BigInt(MHFSPLAYER.AudioQueue[i-1].preciseLength);
            MHFSPLAYER.MessageWriter.write(tempMessageBigOUT);
            Atomics.add(MHFSPLAYER.MessageCount, MSG_COUNT.READER, 4);            
            break;
        }
    }    
}

const PumpAudioQueue = async function() {
    while(1) {
        
        const fAvail = ProcessAudioMessages();
        
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
        const item = MHFSPLAYER.AudioQueue[aqindex];
        // if the actual MHFSPLAYER.AudioQueue is full or nothing to queue, sleep     
        if((!item) || (item.preciseLength > fAvail)) {
            let mysignal = MHFSPLAYER.FACAbortController.signal;
            const tosleep = item ? Math.min(20, (item.preciseLength-fAvail)/MHFSPLAYER.ac.sampleRate) : 20;
            await abortablesleep(tosleep, mysignal);
            continue;            
        }
        
        // make the audio available to the audio worklet
        pushFrames(item.buffer);
        item.queued = true;
        item.buffer = null;  
    }
}

const AQDecTime = function() {
    let total = 0
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
        total += MHFSPLAYER.AudioQueue[i].preciseLength;
    }
    return total;
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
        NextAQIndex++;
        let pbtrack = {};       
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
        let dectime = 0;
        if(time) {                         
            dectime = Math.floor(time * MHFSPLAYER.NWDRFLAC.sampleRate);            
            time = 0;
        }
        let isStart = true;      
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
            MHFSPLAYER.AudioQueue.push({'buffer':buffer, 'track':track, 'isStart':isStart, 'isEnd':isEnd, 'frameindex':dectime, 'aqindex':NextAQIndex, 'preciseLength' : buffer.getChannelData(0).length, 'timers' : [], 'pbtrack' : pbtrack});            
            isStart = false;
            dectime += todec;
            // yield in-case it's time to queue
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