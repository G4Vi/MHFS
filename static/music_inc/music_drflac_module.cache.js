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

function makeRequest (method, url, start, end, signal) {
return new Promise(function (resolve, reject) {
    var xhr = new XMLHttpRequest();
    
    const handler = function(){
        console.log('ABORT XHR');
        xhr.abort();
    };
    
    signal.addEventListener('abort', handler);            
    xhr.open(method, url);
    xhr.responseType = 'arraybuffer';
    xhr.setRequestHeader('Range', 'bytes='+start+'-'+end);
    xhr.onload = function () {
        signal.removeEventListener('abort', handler);
        if (this.status >= 200 && this.status < 300) {
            //console.log('xhr success');
            resolve(xhr);
        } else {
            console.log('xhr fail');                   
            reject({
                status: this.status,
                statusText: xhr.statusText
            });
        }
    };
    xhr.onerror = function () {
        console.log('xhr onerror');
        signal.removeEventListener('abort', handler);
        reject({
            status: this.status,
            statusText: xhr.statusText
        });
    };
    
    xhr.onabort = function() {
        console.log('xhr onabort');
        signal.removeEventListener('abort', handler);
        reject({
            status: this.status,
            statusText: xhr.statusText
        });
    };
    xhr.send();
    //console.log('sending xhr');
});
}
const NDRFLAC_MEM_NEED_MORE = 0xFFFFFFFF;
const NetworkDrFlac = async function(theURL, mysignal) {    
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
    that.MAXBUFSIZE = 262144;
    
    // load up mem
    let end = 262144-1;    
    for(let attempts = 0; attempts < 20; attempts++)
    {
        let xhr = await makeRequest('GET', theURL, 0, end, mysignal);
        let re = new RegExp('/([0-9]+)');
        let res = re.exec(xhr.getResponseHeader('Content-Range'));
        if(!res) throw("Failed to get filesize")
        that.filesize = Number(res[1]);
        //let bufptr = DrFlac.Module._malloc(xhr.response.byteLength);
        let bufptr = DrFlac.Module._malloc(that.filesize);
        let dataHeap = new Uint8Array(DrFlac.Module.HEAPU8.buffer, bufptr, xhr.response.byteLength);
        dataHeap.set(new Uint8Array(xhr.response));  
        
        // finally open
        that.ptr = DrFlac.network_drflac_open_mem(theURL, that.filesize, bufptr, xhr.response.byteLength);    
        if(!that.ptr) {
            DrFlac.Module._free(bufptr);
            throw("Failed network_drflac_open");
        }
        else if(that.ptr === NDRFLAC_MEM_NEED_MORE)
        {
            DrFlac.Module._free(bufptr);
            that.ptr = 0;
            end = end*2;
        }
        that.bufs = [bufptr];
        that.sizes = [xhr.response.byteLength];
        break;
    }

    that.totalPCMFrameCount = DrFlac.network_drflac_totalPCMFrameCount(that.ptr);
    that.sampleRate = DrFlac.network_drflac_sampleRate(that.ptr);
    that.bitsPerSample = DrFlac.network_drflac_bitsPerSample(that.ptr);
    that.channels = DrFlac.network_drflac_channels(that.ptr);
   

    that.close = async function() {
        DrFlac.network_drflac_close(that.ptr);
        for(let i = 0; i < that.bufs.length; i++) {
            DrFlac.Module._free(that.bufs[i]);
        }
        that.bufs = [];
        that.sizes = [];
    };

    that.read_pcm_frames_to_AudioBuffer_f32_mem = async function(start, count, mysignal, audiocontext) {
        const f32_size = 4;
        const pcm_float_frame_size = f32_size * that.channels;
        const ptrsize = 4;
        const u32_size = 4;
        while(1) {
        // store the bufs and bufsizes in the ptr array        
        let ptrarray = DrFlac.Module._malloc(ptrsize * that.bufs.length);
        let jsptrarray = new Uint32Array(DrFlac.Module.HEAPU8.buffer, ptrarray, that.bufs.length);
        let sizearray = DrFlac.Module._malloc(u32_size * that.bufs.length);
        let jssizearray = new Uint32Array(DrFlac.Module.HEAPU8.buffer, sizearray, that.bufs.length);
        for(let i = 0; i < that.bufs.length; i++) {
            jsptrarray[i] = that.bufs[i];
            jssizearray[i] = that.sizes[i];
        }
              
        // attempt to decode the samples
        let destdata = DrFlac.Module._malloc(count*pcm_float_frame_size);
        let samples;
        try {
        samples = DrFlac.network_drflac_read_pcm_frames_f32_mem(that.ptr, start, count, destdata, ptrarray, sizearray, that.bufs.length);
  
        /*if(start < 176400) {
        let tarr =  new Uint8Array(DrFlac.Module.HEAPU8.buffer, destdata, count*pcm_float_frame_size);
        var blob = new Blob([tarr], {type: "application/octet-stream"});
        var objectUrl = URL.createObjectURL(blob);
        window.open(objectUrl);
        }*/
        }
        catch(e) {
            if(e.name !== 'moremem') {
                throw(e);
            }
            else {
                console.log('handling moremem');
                samples = -1;
            }
        }
        finally {
            DrFlac.Module._free(ptrarray);
            DrFlac.Module._free(sizearray); 
        }
               
        if(samples === 0) {
            DrFlac.Module._free(destdata);   
            throw("network_drflac_read_pcm_frames_f32_mem returned 0 or less");
        }
        else if(samples < 0) {
            // download more
            let start = 0;
            for(let i = 0; i < that.sizes.length; i++) {
                start += that.sizes[i];
            }
            const end = Math.min(start+that.MAXBUFSIZE-1, that.filesize-1);
            let xhr = await makeRequest('GET', theURL, start, end, mysignal);
            let dataHeap = new Uint8Array(DrFlac.Module.HEAPU8.buffer, that.bufs[0]+that.sizes[0], xhr.response.byteLength);
            dataHeap.set(new Uint8Array(xhr.response));
            that.sizes[0] += xhr.response.byteLength;
            
            /*let bufptr = DrFlac.Module._malloc(xhr.response.byteLength);
            let dataHeap = new Uint8Array(DrFlac.Module.HEAPU8.buffer, bufptr, xhr.response.byteLength);
            dataHeap.set(new Uint8Array(xhr.response));            
            that.bufs.push(bufptr);
            that.sizes.push(xhr.response.byteLength);*/

            continue;
        }

        let audiobuffer = audiocontext.createBuffer(that.channels, samples, that.sampleRate);
        const chansize = samples * f32_size;
        for( let i = 0; i < that.channels; i++) {
            let buf = new Float32Array(DrFlac.Module.HEAPU8.buffer, destdata+(chansize*i), samples);
            audiobuffer.getChannelData(i).set(buf);        
        }

        DrFlac.Module._free(destdata);
        return audiobuffer;
        }        
    };

    that.read_pcm_frames_to_AudioBuffer = async function(start, count, mysignal, audiocontext) {
        //return that.read_pcm_frames_to_AudioBuffer_wav(start, count, mysignal, audiocontext);
        return that.read_pcm_frames_to_AudioBuffer_f32_mem(start, count, mysignal, audiocontext);
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

    DrFlac.network_drflac_read_pcm_frames_s16_to_wav = DrFlacMod.cwrap('network_drflac_read_pcm_frames_s16_to_wav', "number", ["number", "number", "number", "number", "number"], {async : true});

    DrFlac.network_drflac_read_pcm_frames_f32 = DrFlacMod.cwrap('network_drflac_read_pcm_frames_f32', "number", ["number", "number", "number", "number", "number"], {async : true});

    DrFlac.network_drflac_close = DrFlacMod.cwrap('network_drflac_close', null, ["number"]);    

    DrFlac.network_drflac_open_mem = DrFlacMod.cwrap('network_drflac_open_mem', "number", ["string", "number", "number", "number"]);

    DrFlac.network_drflac_read_pcm_frames_f32_mem = DrFlacMod.cwrap('network_drflac_read_pcm_frames_f32_mem', "number", ["number", "number", "number", "number", "number", "number", "number"]);

    /*
    DrFlac.network_drflac_clone  = DrFlacMod.cwrap('network_drflac_clone', "number", ["number"]);
    DrFlac.network_drflac_restore = DrFlacMod.cwrap('network_drflac_restore', null, ["number", "number"]);
    DrFlac.network_drflac_free_clone = DrFlacMod.cwrap('network_drflac_free_clone', null, ["number"]);
    */
   
    console.log('NetworkDrFlac is ready!');
    DrFlac.ready = true;
    if(DrFlac.on_ready) {
        DrFlac.on_ready();
    }    
});









