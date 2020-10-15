'use strict'
var global;
if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
    console.log('music_drflac.js: I am in a web worker');
    global = self;
    global._NetworkDrFlac_startPath  = '';
    global.loadScripts = function(first, cb) {
        importScripts(...first);
        cb.call(this, null);
    };
} else {
    console.log('music_drflac.js: I am NOT in a web worker');
    global = window;
    global._NetworkDrFlac_startPath = 'static/';
    global.loadScripts = function (scriptUrls, cb){
        function loadNext(err){
            if(err){
                console.error('error ', err);
                return cb(err);
            }
            scriptUrls.length? loadScripts(scriptUrls, cb) : cb(null);
        }
        var s = scriptUrls.shift();
        addScript(s, loadNext);
    }
    
    function addScript(scriptUrl, cb) {
    
        var head = document.getElementsByTagName('head')[0];
        var script = document.createElement('script');
        script.type = 'text/javascript';
        script.src = scriptUrl;
        script.onload = function() {
            cb && cb.call(this, null);
        };
        script.onerror = function(e) {
            var msg = 'Loading script failed for "' + scriptUrl + '" ';
            cb? cb.call(this, msg + e) : console.error(msg, e);
        };
        head.appendChild(script);
    }     
}
if(global.NetworkDrFlac_startPath === undefined) global.NetworkDrFlac_startPath = global._NetworkDrFlac_startPath;

global.DrFlac = { 
    'drflac' : true,
    'ready' : false,
    'on' : function(event, cb) {
        if(event === 'ready') {
            this.on_ready = cb;
        }
    }
};

function DeclareGlobalFunc(name, value) {
    Object.defineProperty(global, name, {
        value: value,
        configurable: false,
        writable: false
    });
};

function DeclareGlobal(name, value) {
    Object.defineProperty(global, name, {
        value: value,
        //configurable: false,
        writable: true
    });
};

loadScripts([NetworkDrFlac_startPath+'drflac.js'], function(){

    const network_drflac_open = Module.cwrap('network_drflac_open', "number", ["string", "number"], {async : true});
    DeclareGlobalFunc('network_drflac_open', network_drflac_open);

    const network_drflac_totalPCMFrameCount = Module.cwrap('network_drflac_totalPCMFrameCount', "number", ["number"]);
    DeclareGlobalFunc('network_drflac_totalPCMFrameCount', network_drflac_totalPCMFrameCount);

    const network_drflac_sampleRate = Module.cwrap('network_drflac_sampleRate', "number", ["number"]);
    DeclareGlobalFunc('network_drflac_sampleRate', network_drflac_sampleRate);
    
    const network_drflac_bitsPerSample = Module.cwrap('network_drflac_bitsPerSample', "number", ["number"]);
    DeclareGlobalFunc('network_drflac_bitsPerSample', network_drflac_bitsPerSample); 

    const network_drflac_channels = Module.cwrap('network_drflac_channels', "number", ["number"]);
    DeclareGlobalFunc('network_drflac_channels', network_drflac_channels);
    
    const network_drflac_read_pcm_frames_s16_to_wav = Module.cwrap('network_drflac_read_pcm_frames_s16_to_wav', "number", ["number", "number", "number", "number"], {async : true});
    DeclareGlobalFunc('network_drflac_read_pcm_frames_s16_to_wav', network_drflac_read_pcm_frames_s16_to_wav); 

    const network_drflac_close = Module.cwrap('network_drflac_close', null, ["number"]);
    DeclareGlobalFunc('network_drflac_close', network_drflac_close);

    Module.onRuntimeInitialized = function() {
        console.log('NetworkDrFlac is ready!');
        global.DrFlac.ready = true;
        if(global.DrFlac.on_ready) {
            global.DrFlac.on_ready();
        }
    };
});

if(typeof sleep === 'undefined') {
    const sleep = m => new Promise(r => setTimeout(r, m));
    DeclareGlobalFunc('sleep', sleep);
}

if(typeof waitForEvent  === 'undefined') {
    const waitForEvent = (obj, event) => {
        return new Promise(function(resolve) {
            obj.on(event, function() {
                resolve();
            });
        });
    };
    DeclareGlobalFunc('waitForEvent', waitForEvent);
}


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

const NetworkDrFlac_open = async(theURL, signalfunc) => { 
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
    let sigid = Module.InsertJSObject(signalfunc);    
    let ndrptr = await network_drflac_open(theURL, sigid);
    let result;
    if(ndrptr) {
        let nwdrflac = {};
        nwdrflac.ptr = ndrptr;
        nwdrflac.totalPCMFrameCount = network_drflac_totalPCMFrameCount(nwdrflac.ptr);
        nwdrflac.sampleRate = network_drflac_sampleRate(nwdrflac.ptr);
        nwdrflac.bitsPerSample = network_drflac_bitsPerSample(nwdrflac.ptr);
        nwdrflac.channels = network_drflac_channels(nwdrflac.ptr);
        nwdrflac.sigid = sigid;
        result = nwdrflac;
    }    
    unlock();

    return result; 
};

const NetworkDrFlac_close = async function(ndrflac) {
    if(!ndrflac) return;
    let unlock = await NetworkDrFlacMutex.lock();
    network_drflac_close(ndrflac.ptr);
    Module.RemoveJSObject(ndrflac.sigid);
    unlock();
};

const NetworkDrFlac_read_pcm_frames_to_wav = async(ndrflac, start, count) => {
    if(ndrflac.bitsPerSample != 16)
    {
        console.error('bps not 16');
        return;
    }
    let pcm_frame_size = (ndrflac.bitsPerSample == 16) ? 2*ndrflac.channels : 4*ndrflac.channels;
    let destdata = Module._malloc(44+ (count*pcm_frame_size));    
    
    let unlock = await NetworkDrFlacMutex.lock();
    let actualsize  = await network_drflac_read_pcm_frames_s16_to_wav(ndrflac.ptr, start, count, destdata);
    unlock();
    
    // copy the data somewhere accessible by DecodeAudioData
    if(actualsize > 0) {
        let wavData = new Uint8Array(Module.HEAPU8.buffer, destdata, actualsize);
        let todec = new Uint8Array(actualsize);
        todec.set(wavData);
        Module._free(destdata);
        return todec.buffer;
    }
    Module._free(destdata);   
};




