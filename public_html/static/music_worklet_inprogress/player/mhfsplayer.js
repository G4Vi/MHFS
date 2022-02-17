import { MHFSCLDecoder } from '../decoder/mhfscl.js'
import { Float32AudioRingBufferWriter, Float32AudioRingBufferReader } from './AudioWriterReader.js'

let CDIMAGE;

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

    that.artmap = {};

    const cdimage = new Blob ([CDIMAGE], { type: 'image/svg+xml' });
    that.cdimage = URL.createObjectURL(cdimage);


    that.sampleRate = opt.sampleRate;
    that.channels   = opt.channels;
    that.pborder = "pborder_default";
    that.maxdecodetime = opt.maxdecodetime;

    that._createaudiocontext = function(options) {
        let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;        
        return mycontext;
    };
    // create AC
    that.ac = that._createaudiocontext({'sampleRate' : opt.sampleRate, 'latencyHint' : 0.1});
    that.lastACState = that.ac.state;
    that.ac.onstatechange = function() {
        console.log('changing acstate was ' + that.lastACState + ' now ' + that.ac.state);
        that.lastACState = that.ac.state;
        if(! that.Tracks_HEAD) {
            console.log('Not updating ppbtn, there are no tracks');
            return;
        }
        that.gui.InitPPText(that.lastACState);
    };

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

    // open the decoder
    that.decoder = await MHFSCLDecoder(that.sampleRate, that.channels);


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

            // nothing more to do if track hasn't ended
            if( (!aqitem.queued) || (aqitem.endTime && (aqitem.endTime > that.ac.currentTime))) {
                break;
            }

            // mark ended track
            needsStart = 0; //invalidate previous starts as something later ended
            toDelete++;
        }

        let startedLoading = that.AudioQueue[0] && that.AudioQueue[0].startedLoading;
        
        // perform the queue update
        if(needsStart || toDelete || startedLoading || that.redraw) {
            that.redraw = 0;
            if(startedLoading) {
                that.AudioQueue[0].startedLoading = undefined;
                const time = that.AudioQueue[0].skiptime;
                that.gui.SetCurtimeText(time || 0);
                if(!time) that.gui.SetSeekbarValue(time || 0);
            }

            // determine the current track;
            let track;
            if(toDelete) {
                const lastTrack = that.AudioQueue[that.AudioQueue.length-1].track;
                that.AudioQueue.splice(0, toDelete);
                that.gui.onTrackEnd(that.AudioQueue.length === 0);
                if(that.AudioQueue.length === 0) {
                    track = lastTrack;
                    that.playlistCursor = track;
                    startedLoading = 0;
                }
            }
            track ||= that.AudioQueue[0].track;

            // show the track
            seekbar.min = 0;
            const duration =  track.duration || 0;
            seekbar.max = duration;
            that.gui.SetEndtimeText(duration);
            that.gui.SetPrevTrack(track.prev);
            that.gui.SetPlayTrack(track, startedLoading);
            that.gui.SetNextTrack(track.next);
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
    that.playlistCursor;

    const getNextTrack = function(currentTrack) {
        if(that.pborder === "pborder_rptrack") {
            return currentTrack;
        }
        else if(that.pborder === "pborder_rpplaylist") {
            return currentTrack.next ? currentTrack.next : that.Tracks_HEAD;
        }
        else if(that.pborder === "pborder_random") {
            // count the tracks
            let tcount = 0;
            for(let track = that.Tracks_HEAD; track; track = track.next) {
                tcount++;
            }
            if(tcount === 0) {
                console.log("Tried to get random track when there aren't any tracks!");
                return undefined;
            }
            // decide on a random track
            let tracknum = Math.floor(Math.random() * tcount);
            console.log('pborder_random, chose track ' + tracknum + ' tcount ' + tcount);
            // find the track
            let track = that.Tracks_HEAD;
            while(tracknum > 0) {
                track = track.next;
                tracknum--;
            }
            return track;
        }
        else if(that.pborder === 'pborder_reverse') {
            return currentTrack.prev;
        }

        // default playback order
        return currentTrack.next;
    };

    that.FAQ_MUTEX = new Mutex();

    async function fillAudioQueue(track, time) {
        if(that.QState !== that.STATES.NEED_FAQ) {
            console.error("Can't FAQ in invalid state");
            return;        
        }
        that.QState = that.STATES.FAQ_RUNNING;
        if(that.ac.state === "running") {
            that.gui.InitPPText('running');
        }
        that.ac.resume();
        
        that.FACAbortController = new AbortController();  
        const mysignal = that.FACAbortController.signal;
        const unlock = await that.FAQ_MUTEX.lock();    
        if(mysignal.aborted) {
            console.log('abort after mutex acquire');
            unlock();
            that.QState = that.STATES.NEED_FAQ;
            return;
        }

        const decoder = that.decoder;
        time = time || 0;
        // while there's a track to queue
        let firstFailedTrack;
    TRACKLOOP:for(; track; track = getNextTrack(track)) {
    
            // open the track in the decoder and seek to where we want to start decoding if necessary
            const start_output_time = time;
            const pbtrack = {
                'track' : track,
                'skiptime' : start_output_time,
                'sampleCount' : 0,
                'startedLoading' : 1
            };
            that.AudioQueue.push(pbtrack)
            time = 0;
            try {
                await decoder.openTrack(mysignal, track, start_output_time);
            }
            catch(error) {
                pbtrack.startedLoading = undefined;
                pbtrack.donedecode = 1;
                pbtrack.queued = 1;
                console.error(error);
                if(mysignal.aborted) {
                    break;
                }
                if(firstFailedTrack === track) {
                    console.error("FAQ done, encountered same track failing again");
                    break;
                }
                firstFailedTrack ||= track;
                continue;
            }

            firstFailedTrack = undefined;
            // We better not modify the AQ if we're cancelled
            if(mysignal.aborted) break;

            // art
            if(! that.artmap[track.trackname]) {
                that.artmap[track.trackname] = decoder.track._loadPictureIfExists() || track.arturl;
                track.arturl = that.artmap[track.trackname];
            }
    
            // decode the track
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
                while(that.decoderdatawriter.getspace() < that.ac.sampleRate) {
                    if(!(await abortablesleep_status(250, mysignal)))
                    {
                        break TRACKLOOP;                    
                    }
                }
                
                // decode
                let decdata;
                try {
                    decdata = await decoder.read_pcm_frames_f32_arrs(todec, mysignal);
                    pbtrack.startedLoading = undefined;
                    if(!decdata) break SAMPLELOOP;
                }
                catch(error) {
                    console.error(error);
                    if(mysignal.aborted) {
                        break TRACKLOOP;
                    }
                    await decoder.closeCurrentTrack();
                    break SAMPLELOOP;
                }
                // We better not modify the AQ if we're cancelled
                if(mysignal.aborted) break TRACKLOOP;                     
    
                pbtrack.sampleCount += decdata.length;
                that.decoderdatawriter.write(decdata.chanData);
                
                // break out at end
                if(decdata.length < todec) {
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
        const track = {'trackname' : trackname, 'url' : that.gui.geturl(trackname), 'arturl' : that.artmap[trackname] || that.cdimage};

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
            that.redraw = 1;
        }
    
        return track;
    };

    that._playtrack = async function(trackname) {
        let queuePos;
        if(that.AudioQueue[0]) {
            queuePos = that.AudioQueue[0].track;
        }
        else if(that.playlistCursor) {
            queuePos = that.playlistCursor;
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
        else if(that.playlistCursor) {
            if(!that.playlistCursor.prev) return;
            prevtrack = that.playlistCursor.prev;
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
        else if(that.playlistCursor) {
            if(!that.playlistCursor.next) return;
            nexttrack = that.playlistCursor.next;
        }
        else {
            return;
        }
        
        await that.StopQueue();
        that.StopAudio();
        that.StartQueue(nexttrack);  
    };

    that._seek = async function(time) {
        let track;
        if(that.AudioQueue[0]) {
            track = that.AudioQueue[0].track;
        }
        else if(that.playlistCursor) {
            track = that.playlistCursor;
        }
        else {
            return;
        }
        const stime = Number(time);
        console.log('SEEK ' + stime);
    
        await that.StopQueue();
        that.StopAudio();        
        that.StartQueue(track, stime); 
    };

    that._pborderchanged = async function(pbstate) {
        that.pborder = pbstate;

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
        
        // determine the next track we want to queue
        const track = getNextTrack(that.AudioQueue[ti].track);
        
        await that.StopQueue();

        // cancel cached decoded audio that's not apart of AQ
        that.truncateDecoded();
        
        if(!that.AudioQueue[ti]) {
            console.log('no track');
        }
        
        // queue following the playback order        
        that.StartQueue(track);
    };

    // API

    that.setVolume = function(val) {
        that.GainNode.gain.setValueAtTime(val, that.ac.currentTime);
    };

    that.play = function() {
        that.ac.resume();

        // start playback again
        if((that.AudioQueue.length === 0) && that.playlistCursor) {
            that.StartQueue(that.playlistCursor);
        }
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

    that.pborderchange = async function(pbstate) {
        const unlock = await that.USERMUTEX.lock();
        await that._pborderchanged(pbstate);
        unlock();
    };
    
    // start the audio pump
    PumpAudio();

    return that;
};

export default MHFSPlayer;
// CD image svg below
// By derex99 - Own work, CC BY-SA 3.0, https://commons.wikimedia.org/w/index.php?curid=3836116
CDIMAGE = `<?xml version="1.0" encoding="UTF-8"?>
<!-- Generator: Adobe Illustrator 13.0.0, SVG Export Plug-In . SVG Version: 6.00 Build 14948)  -->
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px" width="128px" height="128px" viewBox="0 0 128 128" enable-background="new 0 0 128 128" xml:space="preserve">
<defs>
<filter id="Gaussian_Blur">
<feGaussianBlur in="SourceGraphic" stdDeviation="3"/>
</filter>
<filter id="Gaussian_Blur2">
<feGaussianBlur in="SourceGraphic" stdDeviation="1"/>
</filter>
</defs>
<g id="Layer_3" opacity="0.6">
	<g>
		<path d="M63.063,8.67c-30.427,0-55.092,24.666-55.092,55.092c0,30.428,24.666,55.093,55.092,55.093    c30.428,0,55.092-24.665,55.092-55.093C118.155,33.335,93.491,8.67,63.063,8.67z M63.063,79.033    c-7.609,0-13.777-6.168-13.777-13.776c0-7.609,6.168-13.778,13.777-13.778c7.607,0,13.777,6.169,13.777,13.778    C76.841,72.865,70.671,79.033,63.063,79.033z" style="filter:url(#Gaussian_Blur2)"/>
	</g>
</g>
<g id="Layer_3_copy">
	<g>
		<path fill="#E5E5E5" stroke="#858585" stroke-width="0.5" d="M61.5,6.466c-30.427,0-55.092,24.666-55.092,55.092    c0,30.428,24.666,55.092,55.092,55.092c30.428,0,55.092-24.664,55.092-55.092C116.592,31.132,91.928,6.466,61.5,6.466z     M61.5,76.83c-7.609,0-13.777-6.169-13.777-13.777S53.891,49.276,61.5,49.276c7.607,0,13.777,6.168,13.777,13.777    S69.107,76.83,61.5,76.83z"/>
	</g>
</g>
<g id="Layer_1">
	<g>
		<linearGradient id="SVGID_1_" gradientUnits="userSpaceOnUse" x1="56.686" y1="13.9155" x2="66.353" y2="109.582">
			<stop offset="0" style="stop-color:#CCCCCC"/>
			<stop offset="1" style="stop-color:#A1A6A8"/>
		</linearGradient>
		<path fill="url(#SVGID_1_)" d="M61.5,8.389c-29.365,0-53.17,23.805-53.17,53.17s23.805,53.17,53.17,53.17    s53.17-23.805,53.17-53.17S90.865,8.389,61.5,8.389z M61.5,76.297c-7.344,0-13.297-5.953-13.297-13.296S54.156,49.705,61.5,49.705    c7.343,0,13.297,5.953,13.297,13.296S68.843,76.297,61.5,76.297z"/>
	</g>
	<g>
		<g>
			<defs>
				<path id="SVGID_2_" d="M61.5,8.389c-29.365,0-53.17,23.805-53.17,53.17s23.805,53.17,53.17,53.17s53.17-23.805,53.17-53.17      S90.865,8.389,61.5,8.389z M61.5,76.297c-7.344,0-13.297-5.953-13.297-13.296S54.156,49.705,61.5,49.705      c7.343,0,13.297,5.953,13.297,13.296S68.843,76.297,61.5,76.297z"/>
			</defs>
			<clipPath id="SVGID_3_">
				<use xlink:href="#SVGID_2_" overflow="visible"/>
			</clipPath>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#FF3D45" points="152.237,72.892 61.5,64.288 -29.238,72.892      -29.238,55.687 61.5,64.288 152.237,55.687    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#E0FFFF" points="-10.94,127.093 61.184,63.012 75.678,-32.375      133.301,-1.077 61.184,63.012 46.678,158.391    " style="filter:url(#Gaussian_Blur)"/>
			<polygon clip-path="url(#SVGID_3_)" fill="#FFFFFF" points="0.146,133.114 61.182,63.011 86.764,-26.354 122.215,-7.099      61.182,63.011 35.592,152.368    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#FF8000" points="144.783,84.571 61.5,64.288 -24.111,60.02      -21.784,44.008 61.5,64.288 147.11,68.559    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#FFFF00" points="137.329,96.25 61.5,64.288 -18.984,47.148      -14.329,32.329 61.5,64.288 141.984,81.431    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#5EFF00" points="129.875,107.929 61.5,64.288 -13.857,34.276      -6.875,20.65 61.5,64.288 136.857,94.303    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#00D3DF" points="122.421,119.608 61.5,64.289 -8.73,21.403 0.58,8.97      61.5,64.289 131.731,107.175    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#0012DF" points="114.967,131.287 61.501,64.289 -3.604,8.532      8.034,-2.708 61.501,64.289 126.605,120.047    " style="filter:url(#Gaussian_Blur)"/>
			<polygon opacity="0.5" clip-path="url(#SVGID_3_)" fill="#6B476B" points="107.513,142.967 61.501,64.289 1.523,-4.34      15.488,-14.387 61.501,64.289 121.479,132.919    " style="filter:url(#Gaussian_Blur)"/>
		</g>
	</g>
</g>
<g id="Layer_2">
	<g>
		<path opacity="0.22" fill="#636363" stroke="#000000" stroke-width="0.25" d="M61.5,46.661c-9.024,0-16.34,7.315-16.34,16.34    c0,9.024,7.315,16.339,16.34,16.339S77.84,72.024,77.84,63C77.84,53.976,70.524,46.661,61.5,46.661z M61.5,68.316    c-2.986,0-5.407-2.421-5.407-5.406c0-2.986,2.421-5.406,5.407-5.406c2.985,0,5.407,2.42,5.407,5.406    C66.906,65.896,64.485,68.316,61.5,68.316z"/>
	</g>
	<circle opacity="0.5" fill="none" stroke="#505050" stroke-width="0.25" cx="61.5" cy="62.88" r="10.693"/>
	<ellipse opacity="0.3" fill="none" stroke="#505050" stroke-width="0.25" cx="61.5" cy="62.88" rx="6.788" ry="6.667"/>
</g>
</svg>`;
