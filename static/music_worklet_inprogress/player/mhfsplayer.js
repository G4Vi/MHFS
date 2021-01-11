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
    that.ac = that._createaudiocontext({'sampleRate' : opt.sampleRate}); 
    // connect GainNode  
    that.GainNode = that.ac.createGain();
    that.GainNode.connect(that.ac.destination);
    // create ring buffers
    that.ARBLen  = that.ac.sampleRate * 20;
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