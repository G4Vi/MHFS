import Module from './drflac.js'

let DrFlac = { 
    'drflac' : true,
    'ready' : false,
    'on' : function(event, cb) {
        if(event === 'ready') {
            this.on_ready = cb;
        }
    }
};

const sleep = m => new Promise(r => setTimeout(r, m));

const waitForEvent = (obj, event) => {
    return new Promise(function(resolve) {
        obj.on(event, function() {
            resolve();
        });
    });
};

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

const NetworkDrFlac = async function(theURL, sigfunc) {    
    // make sure drflac is ready. Inlined to avoid await when it's already ready
    while(typeof DrFlac === 'undefined') {
        console.log('music_drflac, no drflac sleeping 5ms');
        await sleep(5);
    }
    if(!DrFlac.ready) {
        console.log('music_drflac, waiting for drflac to be ready');
        await waitForEvent(DrFlac, 'ready');
    }
    
    let that = {};
    that.sigid = DrFlac.Module.InsertJSObject(sigfunc);        
    that.ptr = await DrFlac.network_drflac_open(theURL, that.sigid);
    if(!that.ptr) {
        throw("Failed network_drflac_open");
    }
    that.totalPCMFrameCount = DrFlac.network_drflac_totalPCMFrameCount(that.ptr);
    that.sampleRate = DrFlac.network_drflac_sampleRate(that.ptr);
    that.bitsPerSample = DrFlac.network_drflac_bitsPerSample(that.ptr);
    that.channels = DrFlac.network_drflac_channels(that.ptr);
    that.mutex = new Mutex();

    that.close = async function() {
        let unlock = await that.mutex.lock();
        network_drflac_close(that.ptr);
        DrFlac.Module.RemoveJSObject(that.sigid);
        unlock();
    };

    that.read_pcm_frames_to_wav = async function(start, count) {
        if(that.bitsPerSample != 16)
        {
            throw('bps not 16');        
        }
        let pcm_frame_size = (that.bitsPerSample == 16) ? 2*that.channels : 4*that.channels;
        let destdata = DrFlac.Module._malloc(44+ (count*pcm_frame_size)); 

        let unlock = await that.mutex.lock();
        let actualsize  = await DrFlac.network_drflac_read_pcm_frames_s16_to_wav(that.ptr, start, count, destdata);
        unlock();

        if(actualsize <= 0) {
            DrFlac.Module._free(destdata);   
            throw("network_drflac_read_pcm_frames_s16_to_wav returned 0 or less");
        }
        let wavData = new Uint8Array(DrFlac.Module.HEAPU8.buffer, destdata, actualsize);
        let todec = new Uint8Array(actualsize);
        todec.set(wavData);
        DrFlac.Module._free(destdata);
        return todec.buffer;   
    };

    return that;
};

export default NetworkDrFlac;

Module().then(function(DrFlacMod){
    DrFlac.Module = DrFlacMod;
    
    DrFlac.network_drflac_open = DrFlacMod.cwrap('network_drflac_open', "number", ["string", "number"], {async : true});

    DrFlac.network_drflac_totalPCMFrameCount = DrFlacMod.cwrap('network_drflac_totalPCMFrameCount', "number", ["number"]);

    DrFlac.network_drflac_sampleRate = DrFlacMod.cwrap('network_drflac_sampleRate', "number", ["number"]);

    DrFlac.network_drflac_bitsPerSample = DrFlacMod.cwrap('network_drflac_bitsPerSample', "number", ["number"]);

    DrFlac.network_drflac_channels = DrFlacMod.cwrap('network_drflac_channels', "number", ["number"]);

    DrFlac.network_drflac_read_pcm_frames_s16_to_wav = DrFlacMod.cwrap('network_drflac_read_pcm_frames_s16_to_wav', "number", ["number", "number", "number", "number"], {async : true});

    DrFlac.network_drflac_close = DrFlacMod.cwrap('network_drflac_close', null, ["number"]);    
    
    console.log('NetworkDrFlac is ready!');
    DrFlac.ready = true;
    if(DrFlac.on_ready) {
        DrFlac.on_ready();
    }    
});









