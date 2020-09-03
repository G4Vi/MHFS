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

const NetworkDrFlacMutex = new Mutex();

// old api
const NetworkDrFlac_create = function(theURL) {
    return DrFlac.network_drflac_create(theURL);
};

const NetworkDrFlac_open = async function(ndrflac) {
    // make sure drflac is ready. Inlined to avoid await when it's already ready
    while(typeof DrFlac === 'undefined') {
        console.log('music_drflac, no drflac sleeping 5ms');
        await sleep(5);
    }
    if(!DrFlac.ready) {
        console.log('music_drflac, waiting for drflac to be ready');
        await waitForEvent(DrFlac, 'ready');
    }
    
    let unlock = await NetworkDrFlacMutex.lock();    
    let ndrptr = await DrFlac.network_drflac_open(ndrflac);
    let result;
    if(ndrptr) {
        let nwdrflac = {};
        nwdrflac.ptr = ndrptr;
        nwdrflac.totalPCMFrameCount = DrFlac.network_drflac_totalPCMFrameCount(nwdrflac.ptr);
        nwdrflac.sampleRate = DrFlac.network_drflac_sampleRate(nwdrflac.ptr);
        nwdrflac.bitsPerSample = DrFlac.network_drflac_bitsPerSample(nwdrflac.ptr);
        nwdrflac.channels = DrFlac.network_drflac_channels(nwdrflac.ptr);
        result = nwdrflac;
    }    
    unlock();
    return result; 
}

const NetworkDrFlac_close = async function(ndrflac) {
    let unlock = await NetworkDrFlacMutex.lock();
    network_drflac_close(ndrflac.ptr);
    unlock();
};

const NetworkDrFlac_read_pcm_frames_to_wav = async(ndrflac, start, count) => {
    if(ndrflac.bitsPerSample != 16)
    {
        console.error('bps not 16');
        return;
    }
    let pcm_frame_size = (ndrflac.bitsPerSample == 16) ? 2*ndrflac.channels : 4*ndrflac.channels;
    let destdata = DrFlac.Module._malloc(44+ (count*pcm_frame_size));    
    
    let unlock = await NetworkDrFlacMutex.lock();
    let actualsize  = await DrFlac.network_drflac_read_pcm_frames_s16_to_wav(ndrflac.ptr, start, count, destdata);
    unlock();
    
    // copy the data somewhere accessible by DecodeAudioData
    if(actualsize > 0) {
        let wavData = new Uint8Array(DrFlac.Module.HEAPU8.buffer, destdata, actualsize);
        let todec = new Uint8Array(actualsize);
        todec.set(wavData);
        DrFlac.Module._free(destdata);
        return todec.buffer;
    }
    DrFlac.Module._free(destdata);   
};

export {NetworkDrFlac_open, NetworkDrFlac_create, NetworkDrFlac_read_pcm_frames_to_wav, NetworkDrFlac_close};


// new api
const NetworkDrFlac = function(url) {    
    return {
        'mutex' :  new Mutex(),
        'cancel' :  function() {
            if(this.ptr) DrFlac.network_drflac_abort_current(this.ptr);
        },
        '_isInit' : false,
        'init' : async function() {
             // make sure drflac is ready. Inlined to avoid await when it's already ready
            while(typeof DrFlac === 'undefined') {
                console.log('music_drflac, no drflac sleeping 5ms');
                await sleep(5);
            }
            if(!DrFlac.ready) {
                console.log('music_drflac, waiting for drflac to be ready');
                await waitForEvent(DrFlac, 'ready');
            }

            this.ptr = DrFlac.network_drflac_create(url);
            if(!ptr) {
                throw("network_drflac_create failed");
            }
            
            let unlock = await this.mutex.lock();    
            let ndrptr = await DrFlac.network_drflac_open(theURL);
            let result;
            if(ndrptr) {
                let nwdrflac = {};
                nwdrflac.ptr = ndrptr;
                nwdrflac.totalPCMFrameCount = DrFlac.network_drflac_totalPCMFrameCount(nwdrflac.ptr);
                nwdrflac.sampleRate = DrFlac.network_drflac_sampleRate(nwdrflac.ptr);
                nwdrflac.bitsPerSample = DrFlac.network_drflac_bitsPerSample(nwdrflac.ptr);
                nwdrflac.channels = DrFlac.network_drflac_channels(nwdrflac.ptr);
                result = nwdrflac;
            }    
            unlock();
        }
    }
};

export default NetworkDrFlac;

Module().then(function(DrFlacMod){
    DrFlac.Module = DrFlacMod;

    DrFlac.network_drflac_create = DrFlacMod.cwrap('network_drflac_create', "number", ["string"]);

    DrFlac.network_drflac_open = DrFlacMod.cwrap('network_drflac_open', "number", ["number"], {async : true});

    DrFlac.network_drflac_totalPCMFrameCount = DrFlacMod.cwrap('network_drflac_totalPCMFrameCount', "number", ["number"]);

    DrFlac.network_drflac_sampleRate = DrFlacMod.cwrap('network_drflac_sampleRate', "number", ["number"]);

    DrFlac.network_drflac_bitsPerSample = DrFlacMod.cwrap('network_drflac_bitsPerSample', "number", ["number"]);

    DrFlac.network_drflac_channels = DrFlacMod.cwrap('network_drflac_channels', "number", ["number"]);

    DrFlac.network_drflac_read_pcm_frames_s16_to_wav = DrFlacMod.cwrap('network_drflac_read_pcm_frames_s16_to_wav', "number", ["number", "number", "number", "number"], {async : true});

    DrFlac.network_drflac_close = DrFlacMod.cwrap('network_drflac_close', null, ["number"]);

    DrFlac.network_drflac_abort_current = DrFlacMod.cwrap('network_drflac_abort_current', null, ["number"]);
    
    console.log('NetworkDrFlac is ready!');
    DrFlac.ready = true;
    if(DrFlac.on_ready) {
        DrFlac.on_ready();
    }    
});









