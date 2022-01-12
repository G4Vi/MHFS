import Module from './bin/_mhfscl.js'

let MHFSCL = {
    'mhfscl' : true,
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

const MHFSCLTrack = async function(theURL, gsignal) {
    // make sure MHFSCL is ready. Inlined to avoid await when it's already ready
    while(typeof MHFSCL === 'undefined') {
        console.log('MHFSCLTrack no MHFSCL sleeping 5ms');
        await sleep(5);
    }
    if(!MHFSCL.ready) {
        console.log('MHFSCLTrack, waiting for MHFSCL to be ready');
        await waitForEvent(MHFSCL, 'ready');
    }
    let that = {};
    that.CHUNKSIZE = 262144;

    that._downloadChunk = async function(start, mysignal) {
        if(start % that.CHUNKSIZE)
        {
            throw("start is not a multiple of CHUNKSIZE: " + start);
        }        
        const def_end = start+that.CHUNKSIZE-1;
        const end = that.filesize ? Math.min(def_end, that.filesize-1) : def_end; 
        let xhr = await makeRequest('GET', theURL, start, end, mysignal);
        that.filesize = GetFileSize(xhr);
        return xhr;
    };

    that._storeChunk = function(xhr, start) {
        let blockptr = MHFSCL.mhfs_cl_track_add_block(that.ptr, start, that.filesize);
        if(!blockptr)
        {
            throw("failed MHFSCL.mhfs_cl_track_add_block");
        }
        let dataHeap = new Uint8Array(MHFSCL.Module.HEAPU8.buffer, blockptr, xhr.response.byteLength);
        dataHeap.set(new Uint8Array(xhr.response));
    };

    that.downloadAndStoreChunk = async function(start, mysignal) {
        let xhr = await that._downloadChunk(start, mysignal);
        that._storeChunk(xhr, start);
        return xhr;
    };

    that.close = async function() {
        if(that.ptr){
            if(that.initialized) {
                MHFSCL.mhfs_cl_track_deinit(that.ptr);
            }
            MHFSCL.Module._free(that.ptr);
            that.ptr = null;
        }                    
    };
    
    that.seek = async function(pcmFrameIndex) {
        if(!MHFSCL.mhfs_cl_track_seek_to_pcm_frame(that.ptr, pcmFrameIndex)) throw("Failed to seek to " + pcmFrameIndex);
    };
    
    that.currentFrame = function() {
        return MHFSCL.mhfs_cl_track_currentFrame(that.ptr);
    };

    // allocate memory for the mhfs_cl_track and return data
    const alignedTrackSize = MHFSCL.AlignedSize(MHFSCL.mhfs_cl_track_sizeof);
    that.ptr = MHFSCL.Module._malloc(alignedTrackSize + MHFSCL.mhfs_cl_track_return_data_sizeof);
    if(!that.ptr) throw("failed malloc");
    const rd = that.ptr + alignedTrackSize;
    try {
        // initialize the track
        let start = 0;
        const firstreq = await that._downloadChunk(start, gsignal);
        const mime = firstreq.getResponseHeader('Content-Type') || '';
        const totalPCMFrames = firstreq.getResponseHeader('X-MHFS-totalPCMFrameCount') || 0;
        MHFSCL.mhfs_cl_track_init(that.ptr, that.CHUNKSIZE, mime, theURL, totalPCMFrames);
        that.initialized = true;
        that._storeChunk(firstreq, start);

        // load enough of the track that the metadata loads
        for(;;) {
            const code = MHFSCL.mhfs_cl_track_read_pcm_frames_f32(that.ptr, 0, 0, rd);
            if(code === MHFSCL.MHFS_CL_TRACK_SUCCESS) break;
            if(code !== MHFSCL.MHFS_CL_TRACK_NEED_MORE_DATA){
                that.close();
                throw("Failed opening MHFSCLTrack");
            }
            start = MHFSCL.UINT32Value(rd);
            await that.downloadAndStoreChunk(start, gsignal);
        }
    }
    catch(error) {
        that.close();
        throw(error);
    }

    that.totalPCMFrameCount = MHFSCL.mhfs_cl_track_totalPCMFrameCount(that.ptr);
    that.sampleRate = MHFSCL.mhfs_cl_track_sampleRate(that.ptr);
    that.bitsPerSample = MHFSCL.mhfs_cl_track_bitsPerSample(that.ptr);
    that.channels = MHFSCL.mhfs_cl_track_channels(that.ptr);
    that.url = theURL;
    that.duration = MHFSCL.mhfs_cl_track_durationInSecs(that.ptr);

    return that;
};
export default MHFSCLTrack;

const MHFSCLDecoder = function(outputSampleRate, outputChannelCount) {
	const that = {};
	that.ptr = MHFSCL.mhfs_cl_decoder_create(outputSampleRate, outputChannelCount);
    if(! that.ptr) throw("Failed to create decoder");
    
    that.outputSampleRate = outputSampleRate;
    that.outputChannelCount = outputChannelCount;

    that.flush = async function() {
        MHFSCL.mhfs_cl_decoder_flush(that.ptr);
    };
	
	that.close = async function(){
		if(that.track) {
            await that.track.close();
            that.track = null;
        }
        if(that.ptr) {
            MHFSCL.mhfs_cl_decoder_close(that.ptr);
            that.ptr = null;
        }		
	};
    
    that.openURL = async function(url, signal) {
        do {         
            if(that.track) {
                if(that.track.url === url) {
                    break;
                }
                await that.track.close();
                that.track = null;
                if(signal.aborted) {
                    throw("abort after closing track");
                }                                
            }
            that.track = await MHFSCLTrack(url, signal);
        } while(0);

        if(signal.aborted) {
            console.log('');
            await that.track.close();
            that.track = null;
            throw("abort after open track success");
        }       
    };
	
	that.seek_input_pcm_frames = async function(pcmFrameIndex) {
        if(!that.track) throw("nothing to seek on");
        await that.track.seek(pcmFrameIndex);
    };

    that.seek = async function(floatseconds) {
        return that.seek_input_pcm_frames(Math.floor(floatseconds * that.track.sampleRate));
    }

    that.read_pcm_frames_f32_deinterleaved = async function(todec, destdata, mysignal) {
              
        while(1) {              
            // attempt to decode the samples
            const rd = MHFSCL.Module._malloc(MHFSCL.mhfs_cl_track_return_data_sizeof);
            const code = MHFSCL.mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved(that.ptr, that.track.ptr, todec, destdata, rd);
            const retdata = MHFSCL.UINT32Value(rd);
            MHFSCL.Module._free(rd);

            // success, retdata is frames read
            if(code === MHFSCL.MHFS_CL_TRACK_SUCCESS)
            {
                return retdata;
            }
            if(code !== MHFSCL.MHFS_CL_TRACK_NEED_MORE_DATA)
            {
                throw("mhfs_cl_track_read_pcm_frames_f32 failed");
            }

            // download more data
            await that.track.downloadAndStoreChunk(retdata, mysignal);
        }        
    };

    that.read_pcm_frames_f32_AudioBuffer = async function(todec, mysignal) {
        const f32_size = 4;
        const pcm_float_frame_size = f32_size * that.outputChannelCount;
        let theerror;
        let returnval;
        const destdata = MHFSCL.Module._malloc(todec*pcm_float_frame_size);
        try {
            const frames = await that.read_pcm_frames_f32_deinterleaved(todec, destdata, mysignal);
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
            MHFSCL.Module._free(destdata);
            if(theerror) throw(theerror);
            return returnval;
        }        
    };

    that.getChannelData = function(ptr, frames, channel) {
        const chansize = frames * 4;
        return new Float32Array(MHFSCL.Module.HEAPU8.buffer, ptr+(chansize*channel), frames);
    };
	
	return that;
};
export { MHFSCLDecoder };


Module().then(function(MHFSCLMod){
    MHFSCL.Module = MHFSCLMod;

    MHFSCL.UINT32Value = function(ptr) {
        return MHFSCL.Module.HEAPU32[ptr >> 2];
    };

    MHFSCL.AlignedSize = function(size) {
        return Math.ceil(size/4) * 4;
    };

    MHFSCL.mhfs_cl_track_return_data_sizeof = MHFSCLMod.ccall('mhfs_cl_track_return_data_sizeof', "number");
    if(MHFSCL.mhfs_cl_track_return_data_sizeof !== 4) {
        throw("Must update usage of MHFSCL.UINT32Value, unexpected MHFSCL.mhfs_cl_track_return_data_sizeof value");
    }
    MHFSCL.mhfs_cl_track_sizeof =  MHFSCLMod.ccall('mhfs_cl_track_sizeof', "number");

    MHFSCL.MHFS_CL_TRACK_SUCCESS = MHFSCLMod.ccall('MHFS_CL_TRACK_SUCCESS_func', "number");
    MHFSCL.MHFS_CL_TRACK_GENERIC_ERROR = MHFSCLMod.ccall('MHFS_CL_TRACK_GENERIC_ERROR_func', "number");
    MHFSCL.MHFS_CL_TRACK_NEED_MORE_DATA = MHFSCLMod.ccall('MHFS_CL_TRACK_NEED_MORE_DATA_func', "number");

    MHFSCL.mhfs_cl_track_init = MHFSCLMod.cwrap('mhfs_cl_track_init', null, ["number", "number", "string", "string", "number"]);

    MHFSCL.mhfs_cl_track_deinit = MHFSCLMod.cwrap('mhfs_cl_track_deinit', null, ["number"]);

    MHFSCL.mhfs_cl_track_add_block = MHFSCLMod.cwrap('mhfs_cl_track_add_block', "number", ["number", "number", "number"]);
    
    MHFSCL.mhfs_cl_track_seek_to_pcm_frame = MHFSCLMod.cwrap('mhfs_cl_track_seek_to_pcm_frame', "number", ["number", "number"]);

    MHFSCL.mhfs_cl_track_read_pcm_frames_f32 = MHFSCLMod.cwrap('mhfs_cl_track_read_pcm_frames_f32', "number", ["number", "number", "number", "number"]);

    MHFSCL.mhfs_cl_track_totalPCMFrameCount = MHFSCLMod.cwrap('mhfs_cl_track_totalPCMFrameCount', "number", ["number"]);

    MHFSCL.mhfs_cl_track_sampleRate = MHFSCLMod.cwrap('mhfs_cl_track_sampleRate', "number", ["number"]);

    MHFSCL.mhfs_cl_track_bitsPerSample = MHFSCLMod.cwrap('mhfs_cl_track_bitsPerSample', "number", ["number"]);
    
    MHFSCL.mhfs_cl_track_channels = MHFSCLMod.cwrap('mhfs_cl_track_channels', "number", ["number"]);

    MHFSCL.mhfs_cl_track_currentFrame =  MHFSCLMod.cwrap('mhfs_cl_track_currentFrame', "number", ["number"]);

    MHFSCL.mhfs_cl_track_durationInSecs = MHFSCLMod.cwrap('mhfs_cl_track_durationInSecs', "number", ["number"]);
    
    MHFSCL.mhfs_cl_decoder_create = MHFSCLMod.cwrap('mhfs_cl_decoder_create', "number", ["number", "number"]);

    MHFSCL.mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved = MHFSCLMod.cwrap('mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved', "number", ["number", "number", "number", "number", "number"]);

    MHFSCL.mhfs_cl_decoder_close = MHFSCLMod.cwrap('mhfs_cl_decoder_close', null, ["number"]);

    MHFSCL.mhfs_cl_decoder_flush = MHFSCLMod.cwrap('mhfs_cl_decoder_flush', null, ["number"]);

    console.log('MHFSCL is ready!');
    MHFSCL.ready = true;
    if(MHFSCL.on_ready) {
        MHFSCL.on_ready();
    }    
});









