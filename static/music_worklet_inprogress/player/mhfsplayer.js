import {default as NetworkDrFlac} from '../decoder/music_drflac_module.cache.js'
import { Float32AudioRingBufferWriter } from './AudioWriterReader.js'

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

const MHFSPlayer = async function(opt) {
    let that = {};
    that.sampleRate = opt.sampleRate;
    that.channels   = opt.channels;

    that._createaudiocontext = function(options) {
        let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;        
        return mycontext;
    };
    // create AC
    that.ac = that._createaudiocontext({'sampleRate' : opt.sampleRatelatencyHint, 'latencyHint' : 0.1}); 
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

    that.Tracks_HEAD;
    that.Tracks_TAIL;
    that.Tracks_QueueCurrent;
    
    that.FACAbortController = new AbortController();
    that.NWDRFLAC;
    that.AudioQueue = [];
    that.FAQ_MUTEX = new Mutex();

    that.OpenNetworkDrFlac = async function(theURL, deschannels, gsignal) {
        do {
            if(!that.NWDRFLAC) break;
            if(that.NWDRFLAC.url !== theURL) {
                await that.NWDRFLAC.close();
                that.NWDRFLAC = null;
                break;
            } 
            return that.NWDRFLAC;
        } while(0);        
        
        if(gsignal.aborted) {
            throw("abort after closing NWDRFLAC");
        }
        const nwdrflac = await NetworkDrFlac(theURL, deschannels, gsignal);
        if(gsignal.aborted) {
            console.log('');
            await nwdrflac.close();
            throw("abbort after open NWDRFLAC success");
        }
        that.NWDRFLAC = nwdrflac;         
    };

    that.ReadPcmFramesToAudioBuffer = async function(dectime, todec, mysignal, audiocontext) {
        let buffer;
        for(let tries = 0; tries < 2; tries++) {
            try {
                buffer = await that.NWDRFLAC.read_pcm_frames_to_AudioBuffer(dectime, todec, mysignal, that.ac);
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
        return (that.AudioQueue[0] && that.AudioQueue[0].starttime && ((that.ac.currentTime-that.AudioQueue[0].starttime) >= 0) && (that.ac.currentTime <= that.AudioQueue[0].endTime));
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