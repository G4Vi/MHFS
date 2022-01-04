import Module from './bin/drflac.js'

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

const GetFileSize = function(xhr) {
    let re = new RegExp('/([0-9]+)');
    let res = re.exec(xhr.getResponseHeader('Content-Range'));
    if(!res) throw("Failed to get filesize");
    return Number(res[1]);
};

const NetworkDrFlac = async function(theURL, gsignal) {    
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
    that.CHUNKSIZE = 262144;
    that.ptr = DrFlac.network_drflac_open(that.CHUNKSIZE);
    if(!that.ptr) throw("failed network_drflac_open");    
    
    that.downloadChunk = async function(start, mysignal) {
        if(start % that.CHUNKSIZE)
        {
            throw("start is not a multiple of CHUNKSIZE: " + start);
        }        
        const def_end = start+that.CHUNKSIZE-1;
        const end = that.filesize ? Math.min(def_end, that.filesize-1) : def_end; 
        let xhr = await makeRequest('GET', theURL, start, end, mysignal);
        that.filesize = GetFileSize(xhr);
        let blockptr = DrFlac.network_drflac_add_block(that.ptr, start, that.filesize);
        if(!blockptr)
        {
            throw("failed DrFlac.network_drflac_add_block");
        }
        let dataHeap = new Uint8Array(DrFlac.Module.HEAPU8.buffer, blockptr, xhr.response.byteLength);
        dataHeap.set(new Uint8Array(xhr.response));         
        return xhr.response.byteLength;
    };  

    that.close = async function() {
        if(that.ptr){
            DrFlac.network_drflac_close(that.ptr);
            that.ptr = null;
        }                    
    };
    
    that.seek = async function(pcmFrameIndex) {
        if(!DrFlac.network_drflac_seek_to_pcm_frame(that.ptr, pcmFrameIndex)) throw("Failed to seek to " + pcmFrameIndex);                
    };
    
    that.currentFrame = function() {
        return DrFlac.network_drflac_currentFrame(that.ptr);         
    };

    // open drflac for the first time   
    for(let start = 0; ;) {
        try {
            await that.downloadChunk(start, gsignal);
        } catch(error) {
            that.close();
            throw(error); 
        }
        const rd = DrFlac.Module._malloc(DrFlac.NetworkDrFlac_ReturnData_sizeof)
        const code = DrFlac.network_drflac_read_pcm_frames_f32(that.ptr, 0, 0, rd);
        start = DrFlac.UINT32Value(rd);
        DrFlac.Module._free(rd);
        if(code === DrFlac.NDRFLAC_SUCCESS) break;
        if(code !== DrFlac.NDRFLAC_NEED_MORE_DATA){
            that.close();
            throw("Failed opening drflac");
        }
    }
       

    that.totalPCMFrameCount = DrFlac.network_drflac_totalPCMFrameCount(that.ptr);
    that.sampleRate = DrFlac.network_drflac_sampleRate(that.ptr);
    that.bitsPerSample = DrFlac.network_drflac_bitsPerSample(that.ptr);
    that.channels = DrFlac.network_drflac_channels(that.ptr);
    that.url = theURL;
    that.duration = that.totalPCMFrameCount / that.sampleRate;

    return that;
};
export default NetworkDrFlac;

const MHFSDecoder = function(outputSampleRate, outputChannelCount) {
	const that = {};
	that.ptr = DrFlac.mhfs_decoder_create(outputSampleRate, outputChannelCount);
    if(! that.ptr) throw("Failed to create decoder");
    
    that.outputSampleRate = outputSampleRate;
    that.outputChannelCount = outputChannelCount;

    that.flush = async function() {
        DrFlac.mhfs_decoder_flush(that.ptr);
    };
	
	that.close = async function(){
		if(that.nwdrflac) {
            await that.nwdrflac.close();
            that.nwdrflac = null;
        }
        if(that.ptr) {
            DrFlac.mhfs_decoder_close(that.ptr);
            that.ptr = null;
        }		
	};
    
    that.openURL = async function(url, signal) {
        do {         
            if(that.nwdrflac) {
                if(that.nwdrflac.url === url) {                 
                    break;
                }
                await that.nwdrflac.close();
                that.nwdrflac = null;
                if(signal.aborted) {
                    throw("abort after closing NWDRFLAC");
                }                                
            }
            that.nwdrflac = await NetworkDrFlac(url, signal);
        } while(0);

        if(signal.aborted) {
            console.log('');
            await that.nwdrflac.close();
            that.nwdrflac = null;
            throw("abort after open NWDRFLAC success");
        }       
    };
	
	that.seek_input_pcm_frames = async function(pcmFrameIndex) {
        if(!that.nwdrflac) throw("nothing to seek on");
        await that.nwdrflac.seek(pcmFrameIndex);
    };

    that.seek = async function(floatseconds) {
        return that.seek_input_pcm_frames(Math.floor(floatseconds * that.nwdrflac.sampleRate));
    }

    that.read_pcm_frames_f32_interleaved = async function(todec, destdata, mysignal) {
              
        while(1) {              
            // attempt to decode the samples
            const rd = DrFlac.Module._malloc(DrFlac.NetworkDrFlac_ReturnData_sizeof);
            const code = DrFlac.mhfs_decoder_read_pcm_frames_f32_deinterleaved(that.ptr, that.nwdrflac.ptr, todec, destdata, rd);
            const retdata = DrFlac.UINT32Value(rd);
            DrFlac.Module._free(rd);

            // success, retdata is frames read
            if(code === DrFlac.NDRFLAC_SUCCESS)
            {
                return retdata;
            }
            if(code !== DrFlac.NDRFLAC_NEED_MORE_DATA)
            {
                throw("network_drflac_read_pcm_frames_f32 failed");
            }

            // download more data
            await that.nwdrflac.downloadChunk(retdata, mysignal);
        }        
    };

    that.read_pcm_frames_f32_interleaved_AudioBuffer = async function(todec, mysignal) {
        const f32_size = 4;
        const pcm_float_frame_size = f32_size * that.outputChannelCount;
        let theerror;
        let returnval;
        const destdata = DrFlac.Module._malloc(todec*pcm_float_frame_size);
        try {
            const frames = await that.read_pcm_frames_f32_interleaved(todec, destdata, mysignal);
            if(frames) {
                const audiobuffer = new AudioBuffer({'length' : frames, 'numberOfChannels' : that.outputChannelCount, 'sampleRate' : that.outputSampleRate});                
                for( let i = 0; i < that.outputChannelCount; i++) {
                    const buf = that.getChannelData(destdata, frames, i);
                    audiobuffer.copyToChannel(buf, i);
                }
                returnval = audiobuffer;
            }            
        }
        catch(error) {
            theerror = error;
        }
        finally {
            DrFlac.Module._free(destdata);
            if(theerror) throw(theerror);
            return returnval;
        }        
    };

    that.getChannelData = function(ptr, frames, channel) {
        const chansize = frames * 4;
        return new Float32Array(DrFlac.Module.HEAPU8.buffer, ptr+(chansize*channel), frames);
    };
	
	return that;
};
export { MHFSDecoder };


Module().then(function(DrFlacMod){
    DrFlac.Module = DrFlacMod;

    DrFlac.UINT32Value = function(ptr) {
        return DrFlac.Module.HEAPU32[ptr >> 2];
    };

    DrFlac.NetworkDrFlac_ReturnData_sizeof = DrFlacMod.ccall('NetworkDrFlac_ReturnData_sizeof', "number");

    if(DrFlac.NetworkDrFlac_ReturnData_sizeof !== 4) {
        throw("Must update usage of DrFlac.UINT32Value, unexpected DrFlac.NetworkDrFlac_ReturnData_sizeof value");
    }

    DrFlac.NDRFLAC_SUCCESS = DrFlacMod.ccall('NDRFLAC_SUCCESS_func', "number");
    DrFlac.NDRFLAC_GENERIC_ERROR = DrFlacMod.ccall('NDRFLAC_GENERIC_ERROR_func', "number");
    DrFlac.NDRFLAC_NEED_MORE_DATA = DrFlacMod.ccall('NDRFLAC_NEED_MORE_DATA_func', "number");

    DrFlac.network_drflac_init = DrFlacMod.cwrap('network_drflac_init', null, ["number", "number"]);

    DrFlac.network_drflac_deinit = DrFlacMod.cwrap('network_drflac_deinit', null, ["number"]);

    DrFlac.network_drflac_add_block = DrFlacMod.cwrap('network_drflac_add_block', "number", ["number", "number", "number"]);
    
    DrFlac.network_drflac_seek_to_pcm_frame = DrFlacMod.cwrap('network_drflac_seek_to_pcm_frame', "number", ["number", "number"]);

    DrFlac.network_drflac_read_pcm_frames_f32 = DrFlacMod.cwrap('network_drflac_read_pcm_frames_f32', "number", ["number", "number", "number", "number"]);

    DrFlac.network_drflac_open = DrFlacMod.cwrap('network_drflac_open', "number", ["number"]);

    DrFlac.network_drflac_close = DrFlacMod.cwrap('network_drflac_close', null, ["number"]);

    DrFlac.network_drflac_totalPCMFrameCount = DrFlacMod.cwrap('network_drflac_totalPCMFrameCount', "number", ["number"]);

    DrFlac.network_drflac_sampleRate = DrFlacMod.cwrap('network_drflac_sampleRate', "number", ["number"]);

    DrFlac.network_drflac_bitsPerSample = DrFlacMod.cwrap('network_drflac_bitsPerSample', "number", ["number"]);
    
    DrFlac.network_drflac_channels = DrFlacMod.cwrap('network_drflac_channels', "number", ["number"]);

    DrFlac.network_drflac_currentFrame =  DrFlacMod.cwrap('network_drflac_currentFrame', "number", ["number"]);
    
    DrFlac.mhfs_decoder_create = DrFlacMod.cwrap('mhfs_decoder_create', "number", ["number", "number"]);

    DrFlac.mhfs_decoder_read_pcm_frames_f32_deinterleaved = DrFlacMod.cwrap('mhfs_decoder_read_pcm_frames_f32_deinterleaved', "number", ["number", "number", "number", "number", "number"]);

    DrFlac.mhfs_decoder_close = DrFlacMod.cwrap('mhfs_decoder_close', null, ["number"]);

    DrFlac.mhfs_decoder_flush = DrFlacMod.cwrap('mhfs_decoder_flush', null, ["number"]);

    console.log('NetworkDrFlac is ready!');
    DrFlac.ready = true;
    if(DrFlac.on_ready) {
        DrFlac.on_ready();
    }    
});









