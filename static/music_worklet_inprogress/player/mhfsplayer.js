import {default as NetworkDrFlac, MHFSDecoder} from '../decoder/music_drflac_module.cache.js'
import { Float32AudioRingBufferWriter, Float32AudioRingBufferReader } from './AudioWriterReader.js'

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

const MHFSPlayer = async function(opt) {
    let that = {};
    that.sampleRate = opt.sampleRate;
    that.channels   = opt.channels;

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
    await that.ac.audioWorklet.addModule('player/worklet_processor.js'); // is annoying the path isn't consistent with import
    let MusicNode = new AudioWorkletNode(that.ac, 'MusicProcessor',  {'numberOfOutputs' : 1, 'outputChannelCount': [that.channels]});
    MusicNode.connect(that.GainNode);
    MusicNode.port.postMessage({'message' : 'init', 'audiobuffer' : that._ab.to()});     

    // TEMP
    that.NetworkDrFlac = NetworkDrFlac; 
    
    that.STATES = {
        'NEED_FAQ' : 0,
        'FAQ_RUNNING'     : 1
    };

    that.QState = that.STATES.NEED_FAQ;
    that.Tracks_HEAD;
    that.Tracks_TAIL;
    
    that.FACAbortController = new AbortController();
    that.NWDRFLAC;
    that.AudioQueue = [];
    that.FAQ_MUTEX = new Mutex();
    
    
    //that.dataconverter = 
    that.OpenNetworkDrFlac = async function(theURL, gsignal) {
        
        // get a valid nwdrflac for the track
        let nwdrflac;
        do {
            if(that.NWDRFLAC) {
                if(that.NWDRFLAC.url === theURL) {
                    nwdrflac = that.NWDRFLAC;
                    that.NWDRFLAC = null;
                    break;
                }
                await that.NWDRFLAC.close();
                that.NWDRFLAC = null;
                if(gsignal.aborted) {
                    throw("abort after closing NWDRFLAC");
                }                
            }
            nwdrflac = await NetworkDrFlac(theURL, that.channels, gsignal);
            if(gsignal.aborted) {
                console.log('');
                await nwdrflac.close();
                throw("abort after open NWDRFLAC success");
            }           
        } while(0);                           
        
        that.NWDRFLAC = nwdrflac;              
    };

    // read frames
    that.ReadPcmFramesToAudioBuffer = async function(todec, mysignal) {
        let buffer;
        for(let tries = 0; tries < 2; tries++) {
            try {
                buffer = await that.NWDRFLAC.read_pcm_frames_to_AudioBuffer(todec, mysignal);
                if(mysignal.aborted) {
                    throw('aborted decodeaudiodata success');                    
                }
                return buffer;                                          
            }
            catch(error) {
                console.error(error);
                if(mysignal.aborted) {
                    throw('aborted read_pcm_frames decodeaudiodata catch');                    
                }                   
                
                if(tries === 2) {
                    break;
                }        

                // probably a network error, sleep before retry
                if(!(await abortablesleep_status(2000, mysignal)))
                {
                    throw('aborted sleep');  
                }               
            }
        }
        throw('read_pcm_frames decodeaudiodata failed');
    };
	
    that.MHFSDecoder = MHFSDecoder;
    that.Float32AudioRingBufferWriter = Float32AudioRingBufferWriter;
    that.Float32AudioRingBufferReader = Float32AudioRingBufferReader; 
	

    // END TEMP

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

    // NOT IMPLEMENTED
    

    

    that.prev = function() {

    };

    that.next = function () {

    };

    that.onrepeattrackturnedon = function() {

    };

    that.onrepeattrackturnedoff = function() {

    };

    // END NOT IMPLEMENTED

    return that;
};

export default MHFSPlayer;