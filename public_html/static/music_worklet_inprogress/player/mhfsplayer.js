import { MHFSCLDecoder } from '../decoder/mhfscl.js'
import { Float32AudioRingBufferWriter, Float32AudioRingBufferReader } from './AudioWriterReader.js'

// FIFO mutex
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

/*
const TrackQueue = function(starttrack, time) {
    let that = {};

    // store the tail so we don't have to search for it
    that.tail = starttrack;
    for(; that.tail.next; that.tail = that.tail.next);

    const waitForTrack = function() {
        const _waitfortrack = new Promise((resolve) => {
            that.ontrackadded = resolve;
        });
        return _waitfortrack;
    };

    that._FAQ = async function(track, time) {
        if(!track) {
            track = await waitForTrack(); 
        }       
    };

    that.push = function(track) {
        that.tail.next = track;
        that.tail = track;
        track.prev = that.tail;
        // resume FAQ
        if(that.ontrackadded) {
            that.ontrackadded(track);
            that.ontrackadded = null;
        }                
    };

    that.stop() = function (){

    };

    that.onrepeattrackturnedon = function() {
        // determine the currently queuing track
        // stop decodes after it
        // delete after it
    };

    that.onrepeattrackturnedoff = function() {
        // stop decodes of not AQ[0]
        // delete after AQ[0]
    };

    that._FAQ(starttrack, time);
    return that;
};
*/

const MHFSPlayer = async function(opt) {
    let that = {};
    that.gui = opt.gui;
    that.sampleRate = opt.sampleRate;
    that.channels   = opt.channels;
    that.repeattrack = 0;
    that.maxdecodetime = opt.maxdecodetime;

    that._createaudiocontext = function(options) {
        let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;        
        return mycontext;
    };
    // create AC
    that.ac = that._createaudiocontext({'sampleRate' : opt.sampleRate, 'latencyHint' : 0.1}); 
    // connect GainNode  
    that.GainNode = that.ac.createGain();
    that.GainNode.connect(that.ac.destination);
    // create ring buffers
    that.ARBLen  = that.ac.sampleRate * 2;
    if (!self.SharedArrayBuffer) {
        console.error('SharedArrayBuffer is not supported in browser');
    }
    that._ab = Float32AudioRingBufferWriter.create(that.ARBLen, that.channels, that.sampleRate);   

    // create worklet
    let workletProcessorPath = 'player/worklet_processor.js';
    if(navigator.userAgent.toLowerCase().indexOf('firefox') > -1){
        // Firefox can't handle import in worklet so use concat version
        workletProcessorPath = 'player/worklet_processor_ff.js';
    }
    await that.ac.audioWorklet.addModule(workletProcessorPath);
    let MusicNode = new AudioWorkletNode(that.ac, 'MusicProcessor',  {'numberOfOutputs' : 1, 'outputChannelCount': [that.channels]});
    MusicNode.connect(that.GainNode);
    MusicNode.port.postMessage({'message' : 'init', 'audiobuffer' : that._ab.to()});     


    that.FACAbortController = new AbortController();

    // Audio playback
    that.AudioQueue = [];
    that.decoderdatawriter = Float32AudioRingBufferWriter.create(that.sampleRate * that.maxdecodetime, that.channels, that.sampleRate);
    that.decoderdatareader = Float32AudioRingBufferReader.from(that.decoderdatawriter);
    that.StopAudio = function() {
        that.AudioQueue = [];
        that.decoderdatawriter._writer._setwriteindex(0);
        that.decoderdatareader._reader._setreadindex(0);
        that._ab.reset();
    };
    that.truncateDecoded = function() {
        let neededdecode = 0;
        for(let i = 0; i < that.AudioQueue.length; i++) {
            neededdecode += that.AudioQueue[i].sampleCount;
        }
        const wi = (that.decoderdatawriter._writer._rb._readindex() + neededdecode) % that.decoderdatawriter._writer._rb._size;
        that.decoderdatawriter._writer._setwriteindex(wi);
    };

    // queues gui updates
    const ProcessTimes = function(aqitem, duration, time) {    
        if(aqitem.endTime && (that.ac.currentTime > aqitem.endTime)) {
            aqitem.skiptime += (aqitem.endTime - aqitem._starttime);
            aqitem.starttime = null;
        }
        if(!aqitem.starttime) {
            aqitem.starttime = time - aqitem.skiptime;
            aqitem._starttime = time;
            aqitem.needsstart = 1;  
        }
    
        aqitem.endTime = time + (duration/that.ac.sampleRate);    
    }

    // runs gui updates
    const UpdateTrack = function() {    
        // determine if a queue update needs to happen
        let needsStart = 0;
        let toDelete = 0;
        for(let i = 0; i < that.AudioQueue.length; i++) {
            const aqitem = that.AudioQueue[i];
            // mark track as started 
            if(aqitem.needsstart && (aqitem._starttime <= that.ac.currentTime)) {
                aqitem.needsstart = 0;
                needsStart = 1;            
            }
    
            // mark ended track
            if(aqitem.queued) {
                // if there's no endtime or has passed
                if((!aqitem.endTime) || (aqitem.endTime <= that.ac.currentTime)) {
                    needsStart = 0; //invalidate previous starts as something later ended
                    toDelete++;
                }
            }        
        }
        
        // perform the queue update
        if(needsStart || toDelete) {
            let track;
            if(toDelete) {
                track = that.AudioQueue[toDelete-1].track.next ? that.AudioQueue[toDelete-1].track.next : {'prev' : that.AudioQueue[toDelete-1].track, 'trackname' : ''};
                that.AudioQueue.splice(0, toDelete);
                that.gui.onTrackEnd(!needsStart);                 
            }        
            
            
            track = that.AudioQueue[0] ? that.AudioQueue[0].track : track;           
                
            seekbar.min = 0;
            const duration =  (track && track.duration) ? track.duration : 0;
            seekbar.max = duration;
            that.gui.SetEndtimeText(duration);
            that.gui.SetPlayText(track ? track.trackname : '');
            that.gui.SetPrevText((track && track.prev) ? track.prev.trackname : '');            
            that.gui.SetNextText((track && track.next) ? track.next.trackname : '');            
        }
    }

    // passes in the dest array, the maximum frames to read and when they will be played
    const ReadAudioQueue = function (dest, count, when) {
        UpdateTrack();
        let framesWritten = 0;
        let destoffset = 0;
        for(let i = 0; that.AudioQueue[i]; i++) {
            const item = that.AudioQueue[i];
            if(item.queued) continue;
            if(item.sampleCount === 0) break;
            const toread = Math.min(count, item.sampleCount);
            that.decoderdatareader.read(dest, toread, destoffset);         
            framesWritten += toread;
            item.sampleCount -= toread;
            ProcessTimes(item, toread, when);        
            item.queued = item.donedecode && (item.sampleCount === 0);
            if(!item.queued) break;
            count -= toread;
            if(count === 0) break;
            destoffset = framesWritten;
            when += (toread / that.sampleRate); 
        }
        return framesWritten;
    };

    // The Audio Pump
    const PumpAudioData = [];
    for(let i = 0; i < that.channels; i++) {
        PumpAudioData[i] = new Float32Array(that.ARBLen);
    }
    const PumpAudioZeros = [];
    for(let i = 0; i < that.channels; i++) {
        PumpAudioZeros[i] = new Float32Array(that.ARBLen);
    }    
    const PumpAudio = async function() {
        while(1) {
            do {                

                let bufferedTime = that._ab.gettime();
                const mindelta = 0.1;
                let space = that._ab.getspace();
                if(space === 0) break;
                // ensure we are queuing at least 100 ms in advance
                if(bufferedTime < mindelta) {
                    const bufferFrames = 0.1 * that.sampleRate;
                    const towrite = Math.min(bufferFrames, space);
                    that._ab.write(PumpAudioZeros, towrite);
                    space -= towrite;
                    if(space === 0) break;
                    bufferedTime += (towrite / that.sampleRate);           
                }
                const towrite = ReadAudioQueue(PumpAudioData, space, bufferedTime + that.ac.currentTime);
                if(towrite > 0) {
                    that._ab.write(PumpAudioData, towrite);
                }
            } while(0);
            const mysignal = that.FACAbortController.signal;
            await abortablesleep(50, mysignal);   
        }
    };

    // Audio queuing / decoding
    that.STATES = {
        'NEED_FAQ'   : 0,
        'FAQ_RUNNING': 1
    };

    that.QState = that.STATES.NEED_FAQ;
    that.Tracks_HEAD;
    that.Tracks_TAIL;   
    that.CurrentMHFSCLTrack;
    that.FAQ_MUTEX = new Mutex();	
    that.MHFSCLDecoder = MHFSCLDecoder;

    async function fillAudioQueue(track, time) {
        if(that.QState !== that.STATES.NEED_FAQ) {
            console.error("Can't FAQ in invalid state");
            return;        
        }
        that.QState = that.STATES.FAQ_RUNNING;
        that.ac.resume();        
        that.gui.InitPPText(that.ac.state);    
        
        that.FACAbortController = new AbortController();  
        const mysignal = that.FACAbortController.signal;
        const unlock = await that.FAQ_MUTEX.lock();    
        if(mysignal.aborted) {
            console.log('abort after mutex acquire');
            unlock();
            that.QState = that.STATES.NEED_FAQ;
            return;
        }
    
        if(!that.decoder) that.decoder = that.MHFSCLDecoder(that.sampleRate, that.channels);
        const decoder = that.decoder;    
        
        time = time || 0;
        // while there's a track to queue
    TRACKLOOP:for(; track; track = that.repeattrack ?  track : track.next) {
            
            // render the text if nothing is queued
            if(!that.AudioQueue[0]) {
                let prevtext = track.prev ? track.prev.trackname : '';
                that.gui.SetPrevText(prevtext);
                that.gui.SetPlayText(track.trackname + ' {LOADING}');
                let nexttext =  track.next ? track.next.trackname : '';
                that.gui.SetNextText(nexttext);
                that.gui.SetCurtimeText(time || 0);
                if(!time) that.gui.SetSeekbarValue(time || 0);
                that.gui.SetEndtimeText(track.duration || 0);        
            }
    
            // open the track in the decoder
            try {
                await decoder.openURL(track.url, mysignal);
                that.CurrentMHFSCLTrack = decoder.track;
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
            const start_output_time = time;
            time = 0;
            try{
                await decoder.seek(start_output_time);
            }
            catch(error) {
                console.error(error);
                if(mysignal.aborted) {
                    break;
                }
                continue;
            }        
            track.duration = that.CurrentMHFSCLTrack.duration;

            // We better not modify the AQ if we're cancelled
            if(mysignal.aborted) break;      
    
            // decode the track
            let pbtrack = {
                'track' : track,          
                'skiptime' : start_output_time,
                'sampleCount' : 0
            };
            that.AudioQueue.push(pbtrack);        
         
            const todec = that.ac.sampleRate;         
            SAMPLELOOP: while(1) {
                // yield so buffers can be queued
                if(pbtrack.sampleCount > 0) {
                    if(!(await abortablesleep_status(0, mysignal)))
                    {
                        break TRACKLOOP;                    
                    }
                }           
    
                // wait for there to be space                         
                /*while((AQDecTime()+todec) > maxsamples) {
                    const tosleep = ((AQDecTime() + todec - maxsamples)/ that.ac.sampleRate) * 1000; 
                    if(!(await abortablesleep_status(tosleep, mysignal)))
                    {
                        break TRACKLOOP;                    
                    }
                }*/
                while(that.decoderdatawriter.getspace() < that.ac.sampleRate) {
                    if(!(await abortablesleep_status(250, mysignal)))
                    {
                        break TRACKLOOP;                    
                    }
                }
                
                // decode
                let audiobuffer;
                try {
                    audiobuffer = await decoder.read_pcm_frames_f32_interleaved_AudioBuffer(todec, mysignal);
                    if(!audiobuffer) break SAMPLELOOP;                
                }
                catch(error) {
                    console.error(error);
                    if(mysignal.aborted) {
                        break TRACKLOOP;
                    }
                    that.CurrentMHFSCLTrack.close();
                    that.CurrentMHFSCLTrack = null;
                    decoder.track = null;
                    break SAMPLELOOP;
                }
                // We better not modify the AQ if we're cancelled
                if(mysignal.aborted) break TRACKLOOP;                     
    
                pbtrack.sampleCount += audiobuffer.length;
                let arrs = [];
                for(let i = 0; i < that.channels; i++) {
                    arrs[i] = audiobuffer.getChannelData(i);
                }
                that.decoderdatawriter.write(arrs);                         
                
                // break out at end
                if(audiobuffer.length < todec) {
                    break SAMPLELOOP;
                }                      
            }
            pbtrack.donedecode = 1;
            pbtrack.queued = (pbtrack.sampleCount === 0);
        }
        decoder.flush();
        unlock();
        that.QState = that.STATES.NEED_FAQ;
    }

    let FAQPromise;
    const StartQueue = function(track, time) {
        FAQPromise = fillAudioQueue(track, time);    
    };
    
    const StopQueue = async function() {
        that.FACAbortController.abort();
        await FAQPromise;    
    }
    that.StartQueue = StartQueue;
    that.StopQueue  = StopQueue;
    
    // Main playlist queuing. must be done when holding the USERMUTEX

    that.USERMUTEX = new Mutex(); 
    that._queuetrack = function(trackname, after) {
        const track = {'trackname' : trackname, 'url' : that.gui.geturl(trackname)};

        // if not specified queue at tail
        after = after || that.Tracks_TAIL;    
        
        //set the next track
        if(after && after.next) {
            const before = after.next;
            before.prev = track;
            track.next = before;              
        }
        else {
            // if there isn't a next track we are the tail
            that.Tracks_TAIL = track;
        }
        
        // set the previous track
        if(after) {
            after.next = track;
            track.prev = after;       
        }
        else {
            // if were' not queued after anything we are the head
            that.Tracks_HEAD = track;
        }
       
        // if nothing is being queued, start the queue
        if(that.QState === that.STATES.NEED_FAQ){
            that.StartQueue(track); 
        }
        else {
            that.gui.OnQueueUpdate(that.AudioQueue[0] ? that.AudioQueue[0].track : null);
        }
    
        return track;
    };

    that._playtrack = async function(trackname) {
        let queuePos;
        if(that.AudioQueue[0]) {
            queuePos = that.AudioQueue[0].track;
        }       
    
        // stop all audio
        await that.StopQueue();
        that.StopAudio();    
        return that._queuetrack(trackname, queuePos);
    };

    that._queuetracks = function(tracks, after) {
        tracks.forEach(function(track) {
            after = that._queuetrack(track, after);
        });
    }; 
    
    that._prev = async function() {        
        let prevtrack;
        if(that.AudioQueue[0]) {
            if(!that.AudioQueue[0].track.prev) return;
            prevtrack = that.AudioQueue[0].track.prev;
        }    
        else if(that.Tracks_TAIL) {
            prevtrack = that.Tracks_TAIL;
        }
        else {
            return;
        }    
        
        await that.StopQueue();
        that.StopAudio();
        that.StartQueue(prevtrack);    
    };

    that._next = async function() {
        let nexttrack;
        if(that.AudioQueue[0]) {
            if(!that.AudioQueue[0].track.next) return;
            nexttrack = that.AudioQueue[0].track.next;
        }    
        else {
            return;
        }
        
        await that.StopQueue();
        that.StopAudio();
        that.StartQueue(nexttrack);  
    };

    that._seek = async function(time) {
        if(!that.AudioQueue[0]) return;
        const stime = Number(time);
        console.log('SEEK ' + stime);
        const track = that.AudioQueue[0].track;
    
        await that.StopQueue();
        that.StopAudio();        
        that.StartQueue(track, stime); 
    };

    that._rptrackchanged = async function(isOn) {
        that.repeattrack = isOn;
        // we need either the last decoded but not queued track or the last track if everything is queued
        let ti;
        for(ti = 0; ;ti++) {
            if(!that.AudioQueue[ti]) {
                if(ti === 0) return;
                ti--;
                break;
            }
            if(!that.AudioQueue[ti].donedecode) return;
            if(!that.AudioQueue[ti].queued) break;
        }   
    
        // make ti our last track
        that.AudioQueue.length = ti+1;       
        
        await that.StopQueue();        
        
        // cancel cached decoded audio that's not apart of AQ
        that.truncateDecoded();        
        
        // queue the repeat or new track (stopping the current decoding)
        const track = that.repeattrack ? that.AudioQueue[ti].track : that.AudioQueue[ti].track.next;
        that.StartQueue(track);
    };

    // API

    that.setVolume = function(val) {
        that.GainNode.gain.setValueAtTime(val, that.ac.currentTime);
    };

    that.play = function() {
        that.ac.resume();
    };

    that.pause = function() {
        that.ac.suspend();
    };

    that.isplaying = function() {
        return (that.AudioQueue[0] && that.AudioQueue[0]._starttime && (that.ac.currentTime >= that.AudioQueue[0]._starttime) && (that.ac.currentTime <= that.AudioQueue[0].endTime));
    };

    that.tracktime = function() {
        return that.ac.currentTime-that.AudioQueue[0].starttime;
    };   

    that.queuetrack = async function(trackname) {
        const unlock = await that.USERMUTEX.lock();
        that._queuetrack(trackname);
        unlock();
    };

    that.playtrack = async function(trackname) {
        const unlock = await that.USERMUTEX.lock();
        await that._playtrack(trackname);
        unlock();
    };

    that.queuetracks = async function(tracknames) {
        const unlock = await that.USERMUTEX.lock();
        that._queuetracks(tracknames);     
        unlock();
    };

    that.playtracks = async function(tracknames) {
        const unlock = await that.USERMUTEX.lock();
        const firsttrack = tracknames.shift();
        const after = await that._playtrack(firsttrack);
        that._queuetracks(tracknames, after);        
        unlock();
    };    

    that.prev = async function() {
        const unlock = await that.USERMUTEX.lock();
        await that._prev();
        unlock();
    };

    that.next = async function() {
        const unlock = await that.USERMUTEX.lock();
        await that._next();
        unlock();
    };

    that.seek = async function(time) {
        const unlock = await that.USERMUTEX.lock();
        await that._seek(time);
        unlock();
    };

    that.rptrackchanged = async function(isOn) {
        const unlock = await that.USERMUTEX.lock();
        await that._rptrackchanged(isOn);
        unlock();
    };
    
    // start the audio pump
    PumpAudio();

    return that;
};

export default MHFSPlayer;