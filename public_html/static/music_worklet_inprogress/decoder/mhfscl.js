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

const DownloadManager = function(chunksize) {
    const that = {};
    that.CHUNKSIZE = chunksize;

    that._newDownload = async function(url, startOffset) {
        that.done = 0;
        that.url = url;
        that.aController = new AbortController();
        that.acSignal = that.aController.signal;
        that.curOffset = startOffset;
        that.fetchResponse = await fetch(url, {
            signal: that.acSignal,
            headers: {
                'Range': 'bytes='+startOffset+'-'
            }
        });
        const contentrange = that.fetchResponse.headers.get('Content-Range');
        const re = new RegExp('/([0-9]+)');
        const res = re.exec(contentrange);
        if(!res) throw("Failed to get filesize");
        that.size = Number(res[1]);
        that.reader = that.fetchResponse.body.getReader();
        that.data = new Uint8Array(0);
        that.headers = {};
        const ct = that.fetchResponse.headers.get('Content-Type');
        if(ct) {
            that.headers['Content-Type'] = ct;
        }
        const tpcmcnt = that.fetchResponse.headers.get('X-MHFS-totalPCMFrameCount');
        if(tpcmcnt) {
            that.headers['X-MHFS-totalPCMFrameCount'] = tpcmcnt;
        }
    };

    that._AbortIfExists = function() {
        if(that.aController) {
            console.log('abort req');
            that.aController.abort();
            that.aController = null;
        }
    };

    that.GetChunk = async function(url, startOffset, signal) {
        if(that.inuse) {
            throw("GetChunk is inuse");
        }
        that.inuse = 1;

        try {
            if(that.ExternalSignal) {
                that.ExternalSignal.removeEventListener('abort', that._AbortIfExists);
            }
            that.ExternalSignal = signal;
            that.ExternalSignal.addEventListener('abort', that._AbortIfExists);

            const sd = (that.curOffset === startOffset) ? ' SAME' : ' DIFF DFDFDFDFDFFSDFSFS';
            console.log('curOffset '+ that.curOffset + 'startOffset ' + startOffset + sd);

            // if the url doesn't match or the offset isn't within range, launch a new request
            //if((url !== that.url) || (that.curOffset !== startOffset)) {
            if((url !== that.url) || (startOffset < that.curOffset) || ((that.curOffset + that.data.byteLength) < startOffset)) {
                console.log('abort from url or size');
                that._AbortIfExists();
                await that._newDownload(url, startOffset);
            }
            // skip to the requested data
            else if(that.curOffset !== startOffset) {
                const toskip = startOffset - that.curOffset;
                that.data = new Uint8Array(that.data.subarray(toskip));
                that.curOffset = startOffset;
            }
            for(;;) {
                if((that.data.byteLength >= that.CHUNKSIZE) || that.done) {
                    const maxread = Math.min(that.data.byteLength, that.CHUNKSIZE);
                    const tmp = new Uint8Array(that.data.subarray(0, maxread));
                    that.data = new Uint8Array(that.data.subarray(maxread));
                    that.curOffset += maxread;
                    //console.log('set CI to ' + that.curOffset + ' tmp length ' + tmp.byteLength);
                    return {'filesize' : that.size, 'data' : tmp, 'headers' : that.headers};
                }
                const { value: chunk, done: readerDone } = await that.reader.read();
                if(chunk) {
                    const tmp = new Uint8Array(that.data.byteLength + chunk.byteLength);
                    tmp.set(that.data, 0);
                    tmp.set(chunk, that.data.byteLength);
                    that.data = tmp;
                }
                that.done = readerDone;
            }
        }
        catch(err) {
            if(err.name === "AbortError") {
                throw('AbortError');
            }
            else {
                throw('other that.GetChunk error');
            }
        }
        finally {
            that.inuse = 0;
        }
    };


    return that;

};

const GetFileSize = function(xhr) {
    let re = new RegExp('/([0-9]+)');
    let res = re.exec(xhr.getResponseHeader('Content-Range'));
    if(!res) throw("Failed to get filesize");
    return Number(res[1]);
};

const DefDownloadManager = function(chunksize) {
    const that = {};
    that.CHUNKSIZE = chunksize;
    that.curOffset;
    that.GetChunk = async function(url, startOffset, signal) {
        const sd = (that.curOffset === startOffset) ? ' SAME' : ' DIFF DFDFDFDFDFFSDFSFS';
        console.log('curOffset '+ that.curOffset + 'startOffset ' + startOffset + sd);
        const def_end = startOffset+that.CHUNKSIZE-1;
        const end = that.filesize ? Math.min(def_end, that.filesize-1) : def_end;
        const xhr = await makeRequest('GET', url, startOffset, end, signal);
        that.filesize = GetFileSize(xhr);
        const headers = {};
        const ct = xhr.getResponseHeader('Content-Type');
        if(ct) {
            headers['Content-Type'] = ct;
        }
        const tpcmcnt = xhr.getResponseHeader('X-MHFS-totalPCMFrameCount');
        if(tpcmcnt) {
            headers['X-MHFS-totalPCMFrameCount'] = tpcmcnt;
        }
        that.curOffset = startOffset + xhr.response.byteLength;

        return {'filesize' : that.filesize, 'data' : new Uint8Array(xhr.response), 'headers' : headers};
    };

    return that;
};

const ObjectMap = function() {
    const that = {};
    that.data = [];
    that.addData = function(data) {
        for( let i = 0; i < that.data.length; i++) {
            if(that.data[i] === null) {
                that.data[i] = data;
                return i;
            }
        }
        const di = that.data.length;
        that.data.push(data);
        return di;
    };
    that.removeData = function(di) {
        that.data[di] = null;
        while((di+1) === that.data.length) {
            that.data.length--;
            di--;
            if(that.data.length === 0) break;
        }
    };
    that.getData = function(di) {
        return that.data[di];
    };
    return that;
};

const MHFSCLObjectMap = ObjectMap();

const MHFSCLTrackOnMeta = function(mhfscltrackid, blockType, pBlock) {
    console.log('MHFSCLTrackOnMeta called');
    const mhfscltrack = MHFSCLObjectMap.getData(mhfscltrackid);
    if(blockType === MHFSCL.TRACK_M_AUDIOINFO) {
        mhfscltrack.totalPCMFrameCount = MHFSCL.mhfs_cl_track_meta_audioinfo_totalPCMFrameCount(pBlock);
        mhfscltrack.sampleRate = MHFSCL.mhfs_cl_track_meta_audioinfo_sampleRate(pBlock);
        mhfscltrack.bitsPerSample = MHFSCL.mhfs_cl_track_meta_audioinfo_bitsPerSample(pBlock);
        mhfscltrack.channels = MHFSCL.mhfs_cl_track_meta_audioinfo_channels(pBlock);
        mhfscltrack.duration = MHFSCL.mhfs_cl_track_meta_audioinfo_durationInSecs(pBlock);
    }
    else if(blockType === MHFSCL.TRACK_M_PICTURE) {
        const pictureType = MHFSCL.mhfs_cl_track_meta_picture_type(pBlock);
        console.log('pictureType ' + pictureType);
        let setPicture = !mhfscltrack.picture;
        if(!setPicture) {
            // pcover top priority, disc second priority, everything else same priority
            switch(pictureType)
            {
                case 6:
                if(mhfscltrack.picture.type === 6) break;
                case 3:
                setPicture = (mhfscltrack.picture.type !== 3);
            }
        }
        if(setPicture) {
            mhfscltrack.picture = {
                type : pictureType,
                mime : MHFSCL.Module.UTF8ToString(MHFSCL.mhfs_cl_track_meta_picture_mime(pBlock), MHFSCL.mhfs_cl_track_meta_picture_mime_size(pBlock)),
                pictureSize : MHFSCL.mhfs_cl_track_meta_picture_data_size(pBlock),
                pPicture : MHFSCL.mhfs_cl_track_meta_picture_data(pBlock)
            };
        }
    }
};

const MHFSCLTrack = async function(gsignal, theURL, DLMGR) {
    if(!MHFSCL.ready) {
        console.log('MHFSCLTrack, waiting for MHFSCL to be ready');
        await waitForEvent(MHFSCL, 'ready');
    }
    const that = {};
    that.CHUNKSIZE = 262144;
    that.url = theURL;

    DLMGR ||= DefDownloadManager(that.CHUNKSIZE);

    that._downloadChunk = async function(start, mysignal) {
        if(start % that.CHUNKSIZE)
        {
            throw("start is not a multiple of CHUNKSIZE: " + start);
        }
        const chunk = await DLMGR.GetChunk(theURL, start, mysignal);
        that.filesize = chunk.filesize;
        return chunk;
    };

    that._storeChunk = function(chunk, start) {
        let blockptr = MHFSCL.mhfs_cl_track_add_block(that.ptr, start, that.filesize);
        if(!blockptr)
        {
            throw("failed MHFSCL.mhfs_cl_track_add_block");
        }
        let dataHeap = new Uint8Array(MHFSCL.Module.HEAPU8.buffer, blockptr, chunk.data.byteLength);
        dataHeap.set(chunk.data);
    };

    that.downloadAndStoreChunk = async function(start, mysignal) {
        const chunk = await that._downloadChunk(start, mysignal);
        that._storeChunk(chunk, start);
        return chunk;
    };

    that.close = function() {
        if(that.ptr){
            if(that.initialized) {
                MHFSCL.mhfs_cl_track_deinit(that.ptr);
            }
            MHFSCL.Module._free(that.ptr);
            that.ptr = null;
        }                    
    };
    
    that.seek = function(pcmFrameIndex) {
        if(!MHFSCL.mhfs_cl_track_seek_to_pcm_frame(that.ptr, pcmFrameIndex)) throw("Failed to seek to " + pcmFrameIndex);
    };

    that.seekSecs = function(floatseconds) {
        that.seek(Math.floor(floatseconds * that.sampleRate));
    };
    
    that.currentFrame = function() {
        return MHFSCL.mhfs_cl_track_currentFrame(that.ptr);
    };

    that._openPictureIfExists = function() {
        if(!that.picture) {
            return undefined;
        }
        that.picture.hash = MHFSCL.mhfs_cl_djb2(that.picture.pPicture, that.picture.pictureSize);
        that.picture.toURL = function() {
            const srcData = new Uint8Array(MHFSCL.Module.HEAPU8.buffer, that.picture.pPicture, that.picture.pictureSize);
            const picData = new Uint8Array(srcData);
            const blobert = new Blob([picData.buffer], {
                'type' : that.picture.mime
            });
            const url = URL.createObjectURL(blobert);
            return url;
        };
        return that.picture;
    };

    // allocate memory for the mhfs_cl_track and return data
    const alignedTrackSize = MHFSCL.AlignedSize(MHFSCL.mhfs_cl_track_sizeof);
    that.ptr = MHFSCL.Module._malloc(alignedTrackSize + MHFSCL.mhfs_cl_track_return_data_sizeof);
    if(!that.ptr) throw("failed malloc");
    const rd = that.ptr + alignedTrackSize;
    const thatid = MHFSCLObjectMap.addData(that);
    try {
        // initialize the track
        let start = 0;
        const firstreq = await that._downloadChunk(start, gsignal);
        const mime = firstreq.headers['Content-Type'] || '';
        const totalPCMFrames = firstreq.headers['X-MHFS-totalPCMFrameCount'] || 0;
        MHFSCL.mhfs_cl_track_init(that.ptr, that.CHUNKSIZE, mime, theURL, totalPCMFrames);
        that.initialized = true;
        that._storeChunk(firstreq, start);

        // load enough of the track that the metadata loads
        for(;;) {
            that.picture = null;
            const code = MHFSCL.mhfs_cl_track_load_metadata(that.ptr, rd, MHFSCL.pMHFSCLTrackOnMeta, thatid);
            if(code === MHFSCL.MHFS_CL_TRACK_SUCCESS) {
                break;
            }
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
    finally {
        MHFSCLObjectMap.removeData(thatid);
    }

    return that;
};
export { MHFSCLTrack };

const MHFSCLAllocation = function(size) {
    const that = {};
    that.size = 0;
    that.ptr = 0;

    // return a ptr to a block of memory of at least sz bytes
    that.with = function(sz) {
        if(sz <= that.size) {
            return that.ptr;
        }
        const ptr = MHFSCL.Module._realloc(that.ptr, sz);
        if(!ptr) {
            throw("realloc failed");
        }
        that.ptr = ptr;
        that.size = sz;
        return ptr;
    };
    that.free = function() {
        if(that.ptr) {
            MHFSCL.Module._free(that.ptr);
            that.ptr = 0;
            that.size = 0;
        }
    };

    that.with(size);
    return that;
};

// allocates size bytes for each item. creates array of ptrs to point to the data
// [[ptr0, ptr1, ptr...][data0][data1][data...]]
const MHFSCLArrsAlloc = function(nitems, size) {
    const that = {};
    that.nitems = nitems;
    that.ptrarrsize = nitems * MHFSCL.PTRSIZE;
    that.size = 0;

    that.free = function() {
        if(that.alloc) {
            that.alloc.free();
            that.alloc = null;
        }
        that.nitems = 0;
        that.ptrarrsize = 0;
        that.size = 0;
    };

    that.setptrs = function(size) {
        const myarr = new Uint32Array(MHFSCL.Module.HEAPU8.buffer, that.alloc.ptr, that.nitems);
        let dataptr = that.alloc.ptr + that.ptrarrsize;
        for( let i = 0; i < that.nitems; i++) {
            myarr[i] = dataptr;
            dataptr += size;
        }
    };

    that.with = function(sz) {
        sz = MHFSCL.AlignedSize(sz);
        if(that.alloc && (sz <= that.size)) {
            return that.alloc.ptr;
        }
        that.alloc = MHFSCLAllocation(that.ptrarrsize + (nitems * sz));
        that.size = sz;
        that.setptrs(sz);
        return that.alloc.ptr;
    };
    that.with(size);
    return that;
};

const MHFSCLDecoder = async function(outputSampleRate, outputChannelCount) {
    if(!MHFSCL.ready) {
        console.log('MHFSCLDecoder, waiting for MHFSCL to be ready');
        await waitForEvent(MHFSCL, 'ready');
    }
	const that = {};
	that.ptr = MHFSCL.mhfs_cl_decoder_open(outputSampleRate, outputChannelCount, outputSampleRate);
    if(! that.ptr) throw("Failed to open decoder");

    that.outputSampleRate = outputSampleRate;
    that.outputChannelCount = outputChannelCount;
    that.f32_size = 4;
    that.pcm_float_frame_size = that.f32_size * that.outputChannelCount;

    that.returnDataAlloc = MHFSCLAllocation(MHFSCL.mhfs_cl_track_return_data_sizeof);
    that.deinterleaveDataAlloc = MHFSCLArrsAlloc(outputChannelCount, that.outputSampleRate*that.f32_size);
    //that.DM = DownloadManager(262144);

    that.flush = async function() {
        MHFSCL.mhfs_cl_decoder_flush(that.ptr);
    };

    that.closeCurrentTrack = async function() {
        if(that.track) {
            that.track.close();
            that.track = null;
        }
    };

    that.close = async function(){
        await that.closeCurrentTrack();
        MHFSCL.mhfs_cl_decoder_close(that.ptr);
        that.ptr = 0;
        that.returnDataAlloc.free();
        that.deinterleaveDataAlloc.free();
    };
    
    // modifies track
    that.openTrack = async function(signal, intrack, starttime) {
        let doseek = starttime;
        do {
            const url = intrack.url;
            if(that.track) {
                if(that.track.url === url) {
                    doseek = 1;
                    break;
                }
                await that.track.close();
                that.track = null;
                if(signal.aborted) {
                    throw("abort after closing track");
                }                                
            }
            that.track = await MHFSCLTrack(signal, url, that.DM);
        } while(0);

        if(doseek) {
            that.track.seekSecs(starttime);
        }
        intrack.duration = that.track.duration;

        if(signal.aborted) {
            console.log('');
            await that.track.close();
            that.track = null;
            throw("abort after open track success");
        }       
    };
	
	that.seek_input_pcm_frames = async function(pcmFrameIndex) {
        if(!that.track) throw("nothing to seek on");
        that.track.seek(pcmFrameIndex);
    };

    that.seek = async function(floatseconds) {
        if(!that.track) throw("nothing to seek on");
        that.track.seekSecs(floatseconds);
    }

    that.read_pcm_frames_f32_deinterleaved = async function(todec, destdata, mysignal) {
              
        while(1) {              
            // attempt to decode the samples
            const rd = that.returnDataAlloc.ptr;
            const code = MHFSCL.mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved(that.ptr, that.track.ptr, todec, destdata, rd);
            const retdata = MHFSCL.UINT32Value(rd);

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
        let theerror;
        let returnval;
        const destdata = that.deinterleaveDataAlloc.with(todec*that.f32_size);
        try {
            const frames = await that.read_pcm_frames_f32_deinterleaved(todec, destdata, mysignal);
            if(frames) {
                const audiobuffer = new AudioBuffer({'length' : frames, 'numberOfChannels' : that.outputChannelCount, 'sampleRate' : that.outputSampleRate});
                const chanPtrs = new Uint32Array(MHFSCL.Module.HEAPU8.buffer, destdata, that.outputChannelCount);
                for( let i = 0; i < that.outputChannelCount; i++) {
                    const buf = new Float32Array(MHFSCL.Module.HEAPU8.buffer, chanPtrs[i], frames);
                    audiobuffer.copyToChannel(buf, i);
                }
                returnval = audiobuffer;
            }            
        }
        catch(error) {
            theerror = error;
        }
        finally {
            if(theerror) throw(theerror);
            return returnval;
        }        
    };

    that.read_pcm_frames_f32_arrs = async function(todec, mysignal) {
        let theerror;
        let returnval;
        const destdata = that.deinterleaveDataAlloc.with(todec*that.f32_size);
        try {
            const frames = await that.read_pcm_frames_f32_deinterleaved(todec, destdata, mysignal);
            if(frames) {
                const chanPtrs = new Uint32Array(MHFSCL.Module.HEAPU8.buffer, destdata, that.outputChannelCount);
                const obj = { 'length' : frames, 'chanData' : []};
                for( let i = 0; i < that.outputChannelCount; i++) {
                    obj.chanData[i] = new Float32Array(MHFSCL.Module.HEAPU8.buffer, chanPtrs[i], frames);
                }
                returnval = obj;
            }
        }
        catch(error) {
            theerror = error;
        }
        finally {
            if(theerror) throw(theerror);
            return returnval;
        }
    };
	
	return that;
};
export { MHFSCLDecoder };


Module().then(function(MHFSCLMod){
    MHFSCL.Module = MHFSCLMod;

    // mhfs_cl_track* functions
    MHFSCL.mhfs_cl_track_init = MHFSCLMod.cwrap('mhfs_cl_track_init', null, ["number", "number", "string", "string", "number"]);
    MHFSCL.mhfs_cl_track_deinit = MHFSCLMod.cwrap('mhfs_cl_track_deinit', null, ["number"]);
    MHFSCL.mhfs_cl_track_add_block = MHFSCLMod.cwrap('mhfs_cl_track_add_block', "number", ["number", "number", "number"]);
    MHFSCL.mhfs_cl_track_load_metadata = MHFSCLMod.cwrap('mhfs_cl_track_load_metadata', "number", ["number", "number", "number", "number"]);
    MHFSCL.mhfs_cl_track_seek_to_pcm_frame = MHFSCLMod.cwrap('mhfs_cl_track_seek_to_pcm_frame', "number", ["number", "number"]);
    MHFSCL.mhfs_cl_track_read_pcm_frames_f32 = MHFSCLMod.cwrap('mhfs_cl_track_read_pcm_frames_f32', "number", ["number", "number", "number", "number"]);

    MHFSCL.mhfs_cl_track_meta_audioinfo_durationInSecs = MHFSCLMod.cwrap('mhfs_cl_track_meta_audioinfo_durationInSecs', "number", ["number"]);

    // mhfs_cl_track util functions
    MHFSCL.mhfs_cl_djb2 = MHFSCLMod.cwrap('mhfs_cl_djb2', "number", ["number", "number"]);

    // mhfs_cl_track* constants
    MHFSCL.mhfs_cl_track_return_data_sizeof = MHFSCLMod.ccall('mhfs_cl_track_return_data_sizeof', "number");
    if(MHFSCL.mhfs_cl_track_return_data_sizeof !== 4) {
        throw("Must update usage of MHFSCL.UINT32Value, unexpected MHFSCL.mhfs_cl_track_return_data_sizeof value");
    }
    MHFSCL.mhfs_cl_track_sizeof =  MHFSCLMod.ccall('mhfs_cl_track_sizeof', "number");
    MHFSCL.MHFS_CL_TRACK_SUCCESS = MHFSCLMod.ccall('MHFS_CL_TRACK_SUCCESS_func', "number");
    MHFSCL.MHFS_CL_TRACK_GENERIC_ERROR = MHFSCLMod.ccall('MHFS_CL_TRACK_GENERIC_ERROR_func', "number");
    MHFSCL.MHFS_CL_TRACK_NEED_MORE_DATA = MHFSCLMod.ccall('MHFS_CL_TRACK_NEED_MORE_DATA_func', "number");

    MHFSCL.TRACK_M_AUDIOINFO = MHFSCLMod.ccall('MHFS_CL_TRACK_M_AUDIOINFO_func', "number");
    MHFSCL.TRACK_M_TAGS  = MHFSCLMod.ccall('MHFS_CL_TRACK_M_TAGS_func', "number");
    MHFSCL.TRACK_M_PICTURE = MHFSCLMod.ccall('MHFS_CL_TRACK_M_PICTURE_func', "number");

    // mhfs_cl_track* access struct members
    MHFSCL.mhfs_cl_track_currentFrame =  MHFSCLMod.cwrap('mhfs_cl_track_currentFrame', "number", ["number"]);

    MHFSCL.mhfs_cl_track_meta_audioinfo_totalPCMFrameCount = MHFSCLMod.cwrap('mhfs_cl_track_meta_audioinfo_totalPCMFrameCount', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_audioinfo_sampleRate = MHFSCLMod.cwrap('mhfs_cl_track_meta_audioinfo_sampleRate', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_audioinfo_bitsPerSample = MHFSCLMod.cwrap('mhfs_cl_track_meta_audioinfo_bitsPerSample', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_audioinfo_channels = MHFSCLMod.cwrap('mhfs_cl_track_meta_audioinfo_channels', "number", ["number"]);

    MHFSCL.mhfs_cl_track_meta_picture_type = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_type', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_mime_size = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_mime_size', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_mime = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_mime', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_desc_size = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_desc_size', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_desc = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_desc', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_data_size = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_data_size', "number", ["number"]);
    MHFSCL.mhfs_cl_track_meta_picture_data = MHFSCLMod.cwrap('mhfs_cl_track_meta_picture_data', "number", ["number"]);

    // mhfs_cl_decoder functions
    MHFSCL.mhfs_cl_decoder_open = MHFSCLMod.cwrap('mhfs_cl_decoder_open', "number", ["number", "number", "number"]);
    MHFSCL.mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved = MHFSCLMod.cwrap('mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved', "number", ["number", "number", "number", "number", "number"]);
    MHFSCL.mhfs_cl_decoder_close = MHFSCLMod.cwrap('mhfs_cl_decoder_close', null, ["number"]);
    MHFSCL.mhfs_cl_decoder_flush = MHFSCLMod.cwrap('mhfs_cl_decoder_flush', null, ["number"]);


    // link callbacks in
    MHFSCL.pMHFSCLTrackOnMeta = MHFSCL.Module.addFunction(MHFSCLTrackOnMeta, 'viii');

    // finish setup
    MHFSCL.PTRSIZE = 4;

    MHFSCL.UINT32Value = function(ptr) {
        return MHFSCL.Module.HEAPU32[ptr >> 2];
    };

    MHFSCL.AlignedSize = function(size) {
        return Math.ceil(size/4) * 4;
    };

    console.log('MHFSCL is ready!');
    MHFSCL.ready = true;
    if(MHFSCL.on_ready) {
        MHFSCL.on_ready();
    }    
});









