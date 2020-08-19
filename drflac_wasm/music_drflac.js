'use strict'
var global;
if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
    console.log('music_drflac.js: I am in a web worker');
    global = self;
    global.startPath = '';
    global.loadScripts = function(first, cb) {
        importScripts(...first);
        cb.call(this, null);
    };
} else {
    console.log('music_drflac.js: I am NOT in a web worker');
    global = window;
    global.startPath = 'static/';
    //global.startPath = '';
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

loadScripts([startPath+'drflac.js'], function(){
    /*
    const get_audio = Module.cwrap('get_audio', "number", ["string", "number", "number"], {async : true});
    Object.defineProperty(global, 'get_audio', {
        value: get_audio,
        configurable: false,
        writable: false
    });
    */

    

    const network_drflac_open = Module.cwrap('network_drflac_open', "number", ["string"], {async : true});
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

    const network_drflac_abort_current = Module.cwrap('network_drflac_abort_current');
    DeclareGlobalFunc('network_drflac_abort_current', network_drflac_abort_current);

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




const NetworkDrFlac_load = function() {
    console.log('NetworkDrFlac_load begin');
    while(typeof DrFlac === 'undefined') {
        console.log('music_drflac, no drflac sleeping 5ms');
        return sleep(5);
    }
    if(!DrFlac.ready) {
        console.log('music_drflac, waiting for drflac to be ready');
        return waitForEvent(DrFlac, 'ready');
    }
    console.log('NetworkDrFlac_load end');
    return;
};

const NetworkDrFlacAsyncCall = async function (toRun) {
    while(global.NetworkDrFlac_Promise) {
        await global.NetworkDrFlac_Promise;       
    }
    console.log('NetworkDrFlac launching promise');
    global.NetworkDrFlac_Promise = toRun();
    let retVal = await global.NetworkDrFlac_Promise;
    global.NetworkDrFlac_Promise = null;
    return retVal;    
};

const NetworkDrFlac_open = async(theURL) => {    
    await NetworkDrFlac_load();
    let nwdrflac = {};
    console.log('NetworkDrFlac loaded');
    
    nwdrflac.ptr = await NetworkDrFlacAsyncCall(function() {
        return network_drflac_open(theURL);
    });   
    
    nwdrflac.totalPCMFrameCount = network_drflac_totalPCMFrameCount(nwdrflac.ptr);
    nwdrflac.sampleRate = network_drflac_sampleRate(nwdrflac.ptr);
    nwdrflac.bitsPerSample = network_drflac_bitsPerSample(nwdrflac.ptr);
    nwdrflac.channels = network_drflac_channels(nwdrflac.ptr);
    return nwdrflac;
};

const NetworkDrFlac_close = function(ndrflac) {
    network_drflac_close(ndrflac);
};

const NetworkDrFlac_read_pcm_frames_to_wav = async(ndrflac, start, count) => {
    if(ndrflac.bitsPerSample != 16)
    {
        console.error('bps not 16');
        return;
    }
    let pcm_frame_size = (ndrflac.bitsPerSample == 16) ? 2*ndrflac.channels : 4*ndrflac.channels;
    let destdata = Module._malloc(44+ (count*pcm_frame_size));    
    //let actualsize = await network_drflac_read_pcm_frames_s16_to_wav(ndrflac.ptr, start, count, destdata); 
    
    let actualsize = await NetworkDrFlacAsyncCall(function() {
        return network_drflac_read_pcm_frames_s16_to_wav(ndrflac.ptr, start, count, destdata);
    }); 

    if(actualsize > 0) {
        let wavData = new Uint8Array(Module.HEAPU8.buffer, destdata, actualsize);
        let todec = new Uint8Array(actualsize);
        todec.set(wavData);
        Module._free(destdata);
        return todec.buffer;
    }
    Module._free(destdata);   
};

const NetworkDrFlac_Download = function(thePromise) {    
    // todo actually stop downloading? can we?
    this.stop = function() {
        this.isinvalid = true;
        network_drflac_abort_current();              
    };

    this.abort = function() {
        this.isinvalid = true;
        network_drflac_abort_current();
    };
};



const FLACURLToFloat32 = async (theURL, starttime, maxduration) => {
    await NetworkDrFlac_load();

    let result = await get_audio(theURL, starttime, maxduration);
    if(result != 0)
    {       
  

        /*
        // audio data
        let chans = [];
        for(let i = 0; i < metaData.channels; i++) {
            chans[i] = new Float32Array(Module.HEAPU8.buffer, result+32+(4*metaData.framesDecoded*i), metaData.framesDecoded);
        }       
        
        // leaks mem
        return [metaData, chans];
        */

      
        
        let wavData = new Uint8Array(Module.HEAPU8.buffer, result+32, (metaData.framesDecoded*4)+44);
        let todec = new Uint8Array(wavData.byteLength);
        todec.set(new Uint8Array(wavData));
        Module._free(metaData.ptr);        
        return [metaData, todec.buffer];
    }


};


/*

      // header
        let metaData = {};
        metaData.ptr = result;     
        let uint64s = new BigUint64Array(Module.HEAPU8.buffer, result, 2);
        metaData.framesDecoded = Number(uint64s[0]);
        metaData.totalFrames   = Number(uint64s[1]);
        let uint32s = new Uint32Array(Module.HEAPU8.buffer, result+16, 1);
        metaData.sampleRate =  uint32s[0];
        let uint8s  = new Uint8Array(Module.HEAPU8.buffer, result+20, 2);
        metaData.bps = uint8s[0];
        metaData.channels = uint8s[1];
        console.log('framesDecoded ' + metaData.framesDecoded);
        console.log('totalFrames ' + metaData.totalFrames);
        console.log('sampleRate ' + metaData.sampleRate);
        console.log('bits per sample ' + metaData.bps);
        console.log('num channels ' + metaData.channels);


        */