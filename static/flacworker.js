// flacworker.js

let URLSTART;
let URLEND;
let URLBASEURI;

function getURL(trackname) {
    let url = URLSTART + encodeURIComponent(trackname) + URLEND;
    return new URL(url, URLBASEURI).href; 
}

function roundUp(x, multiple) {
	var rem = x % multiple;
    if(rem == 0) {
    	return x;		
    }
    else {
		return x + multiple - rem;	    	
    }		
}

function toint16(byteA, byteB) {
	var sign = byteB & (1 << 7);
    var x = (((byteB & 0xFF) << 8) | (byteA & 0xFF));
    if (sign) {
       x = 0xFFFF0000 | x;  // fill in most significant bits with 1's
    }
    return x;			
}

let PlaybackQueue = [];
let DownloadController = new AbortController();
let DownloadStopSignal = DownloadController.signal;
let CacheTimer;

function WavDecoder(trackname, starttime) {
    this.trackname = trackname;
    this._url = getURL(trackname);
    this._AudioStartOffset = 44;
    this.maxBufferSize = 4*1048576;
    this.buffer = new Uint8Array(this.maxBufferSize*2);
    this.bufferSize = 0;
    this.starttime = starttime;
    this._ReadOffset = 0;
    
    this.readHeader = function() {
        let asbytes = new DataView(this.buffer.buffer);
        let littleEndian = true;
        this.channels   = asbytes.getUint16(22, littleEndian);
        this.samplerate = asbytes.getUint32(24, littleEndian);
        this.bitspersample = asbytes.getUint16(34, littleEndian);        
        this._AudioDataSize = asbytes.getUint32(40, littleEndian);  
        this._BytesPerSample =  this.bitspersample / 8;       
        this.totalPCMframes = this._AudioDataSize /  (this._BytesPerSample * this.channels);
        console.log('WAV :');
        console.log(this);
        //this._ReadOffset = 44;
        
        // remove the header from the buffer
        if(this.bufferSize == 44) {
            this.bufferSize = 0;
            return;            
        }
        this.buffer.copyWithin(0, 44);
        this.bufferSize -= 44;        
    }
    
    // seeking can be a lot simpler if you know the metadata already
    this.softseek = async function(dessample) {
        this.bufferSize = 0;
        this._ReadOffset = this._AudioStartOffset + (dessample * this.channels * this._BytesPerSample);
        let request = new Request(this._url, {
            method :  'GET',
            headers : { 'Range': ('bytes='+this._ReadOffset+'-')},
            signal: DownloadStopSignal         
        });
        let response = await fetch(request);
        let reader = response.body.getReader();
        this._reader = reader;
        this.skipsamples = dessample;
        await DoCache(20, -1);
        return true;  
    };
    
    this.seek = async function() {
        let range = this.starttime == 0 ? 'bytes=0-' : 'bytes=0-43';
        let request = new Request(this._url, {
            method :  'GET',
            headers : { 'Range': range},
            signal: DownloadStopSignal            
        });
        let response = await fetch(request);
        let contentrange = response.headers.get('Content-Range');
        let re = /\/(\d+)/;
        let res = re.exec(contentrange);
        if(!res) return false;           
        this._size = Number(res[1]);
        if(this._size < 44) return false; 
        
        let reader = response.body.getReader();
        while(1) {
           let {value: chunk, done: readerDone} = await reader.read();
           if(chunk){
               console.log('chunk length ' + chunk.length); 
               this.buffer.set(chunk, this.bufferSize);
               this.bufferSize += chunk.length;
               this._ReadOffset += chunk.length;
               if(this.bufferSize >= 44) {
                   this.readHeader();                   
                   if(this.starttime == 0) {
                       this._reader = reader;
                       await DoCache(20, -1);       
                       return true;
                   }
                   break;
               }                   
           }
           else {
               return false;
           }               
        }
        
        let dessample = Math.floor(this.starttime * this.samplerate);
        return await this.softseek(dessample);                   
    };
    
    /*
    this.fillCache = function(bytesToCache) {
        if(this.bufferSize >= this.maxBufferSize) {
            console.log('no more bytes to cache in ' + this.trackname);
            //return 0;
            return this.bufferSize;             
        }
        let bufferBytesLeft = this.maxBufferSize - this.bufferSize;
        bytesToCache = (bufferBytesLeft < bytesToCache) ? bufferBytesLeft : bytesToCache;
        let bytesleft = this._size - this._ReadOffset;
        let bytesdesired = (bytesleft > bytesToCache) ? bytesToCache : bytesleft;
        if((bytesdesired > 0) &&  {
            console.log('copying from xhr');
            let bytesdownloaded = 0;
            let download = this.xhr.response;
            if(download.length > this.
            
        }           
    }
    */
    
    this.cache = async function(bytesToCache) {
        if(this.bufferSize >= this.maxBufferSize) {
            console.log('no more bytes to cache in ' + this.trackname);
            //return 0;
            
            return this.bufferSize;             
        }
        let bufferBytesLeft = this.maxBufferSize - this.bufferSize;
        bytesToCache = (bufferBytesLeft < bytesToCache) ? bufferBytesLeft : bytesToCache;
        let bytesleft = this._size - this._ReadOffset;
        let bytesdesired = (bytesleft > bytesToCache) ? bytesToCache : bytesleft;
        let bytesdownloaded = 0;
        while(bytesdownloaded < bytesdesired) {
           let {value: chunk, done: readerDone} = await this._reader.read();
           if(chunk){
               this._ReadOffset += chunk.length;
               console.log('chunk length ' + chunk.length);
               bytesdownloaded += chunk.length;
               if((chunk.length + this.bufferSize) > this.buffer.length) {
                   console.log('what the fuck, trying to overrun buffer');
                   break;
               }                   
               this.buffer.set(chunk, this.bufferSize);
               this.bufferSize += chunk.length;              
           }
           else {
               return 0;
           }       
        }
        console.log('cache size ' + this.bufferSize);  
       
        return this.bufferSize;        
    }
    
   
    this.read = async function(samples, outbuffer, outbufindex) {    
        let samples_left = Math.floor(this.bufferSize + this._size  - this._ReadOffset) / (this.channels * this._BytesPerSample);
        console.log('samples_left: ' + samples_left + ' totalsamples ' + this.totalPCMframes);
        if(samples_left < samples) {
            console.log('clamped samples to ' + samples_left);
            samples = samples_left;            
        }
        let pcmsize = (samples * this.channels * this._BytesPerSample);
        let isLast = 0;
        if(samples == samples_left) {
            console.log('set isLast');
            isLast = 1;
        }
        let isStart = 0;
        if(samples_left == this.totalPCMframes) {
            console.log('set isStart');
            isStart = 1;            
        }
        
        if(this.bufferSize < pcmsize) {
            console.log('not enough data');
            return false;            
        }
        
        /*
        let lastindex = (samples * this.channels * this._BytesPerSample) + this._ReadOffset - 1;
        if(lastindex > (this._size - 1)) {
            lastindex = this._size - 1;
            console.log('clamped lastindex to ' + lastindex);
            samples = (lastindex - this._ReadOffset + 1) / (this._BytesPerSample * this.channels);
        }
        let pcmsize = (samples * this.channels * this._BytesPerSample);
    
        let isStart = 0;
        if(this._ReadOffset == this._AudioStartOffset) {
            isStart = 1;            
        }
        if(this.starttime !== null) {
            isStart = 1;
            this.starttime = null;           
        }
        let isLast = 0;
        if(lastindex == (this._size - 1)) {
            isLast = 1;
        }
        console.log('lastIndex ' + lastindex);        
        */
        
        // download more if necessary
        /*while(this.bufferSize < pcmsize) {
           let {value: chunk, done: readerDone} = await this._reader.read();
           if(chunk){
               console.log('chunk length ' + chunk.length); 
               this.buffer.set(chunk, this.bufferSize);
               this.bufferSize += chunk.length;              
           }
           else {
               return false;
           }       
        }
        
        this._ReadOffset += pcmsize;
        if(this._ReadOffset == this._size) {
            console.log('read entire file ' + this.trackname);            
        }*/
        
        // create a buffer to output the raw data to
        let dataarr = new Uint8Array(pcmsize); 
        dataarr.set(this.buffer.slice(0, pcmsize));
        this.buffer.copyWithin(0, pcmsize);
        this.bufferSize -= pcmsize;   
        
        // convert to float
        let outbufs = [];
        for(var i = 0; i < this.channels; i++) { 
            outbufs[i] = new Float32Array(outbuffer[i]);
        }
        
        for(j = 0; j < pcmsize;) {
            for(var i = 0; i < this.channels; i++) {
                let s16value = toint16(dataarr[j], dataarr[j+1]);
                //outbufs[i][outbufindex] = (s16value / 0x8000);
                outbufs[i][outbufindex] = (s16value / 0x7FFF) * 0.9;
                if((outbufs[i][outbufindex] > 1) || (outbufs[i][outbufindex] < -1)) {
					console.log('CLAMPING FLOAT');
					if(outbufs[i][outbufindex] > 1) outbufs[i][outbufindex] = 1;
				    if(outbufs[i][outbufindex] < -1) outbufs[i][outbufindex] = -1; 	
				}                
                j+=2;
            }
            outbufindex++;            
        }
        
        let ret = {'samples' : samples, 'isStart' : isStart, 'isLast' : isLast};
        if(this.skipsamples) {
            ret.isStart = 1;
            ret.skipsamples = this.skipsamples;            
            this.skipsamples = null;
        }
        
        return ret;        
    };

          
}

function PlaybackItem(trackname) {
    this.starttime = 0;
    this.trackname = trackname;
    this.decoder   = null;
    console.log('Creating PlaybackItem ' + trackname);
    this.iscreated = false;
    this.CreateDecoder = async function() {
        this.decoder = new WavDecoder(trackname, this.starttime);
        let res = await this.decoder.seek();
        if(!res) {
            this.decoder = null;            
        }
        else {
            this.iscreated = true;
        }
    };        
}

async function Cache(cachebytes) {
    let jobid = -1;    
    for(i = 0; i < PlaybackQueue.length; i++) {
        let playbackItem = PlaybackQueue[i];
        if(playbackItem.decoder === null) {
            console.log('job id: ' + jobid + ' waiting for decoder');
            try {
                await playbackItem.CreateDecoder();
                console.log('job id: ' + jobid + ' decoder created');
            }
            catch(e) {
                console.log('job id: ' + jobid + ' decoder create failed (catch) ' + e);
                continue;
            }
            if(!playbackItem.decoder) {
                console.log('job id: ' + jobid + ' decoder create failed');
                continue;                
            }
        }
        cachebytes -= await playbackItem.decoder.cache(cachebytes);
        if(cachebytes <= 0) {
            break;
        }
        if(playbackItem.decoder._ReadOffset == playbackItem.decoder._size) {
            continue;        
        }
        else {
            //playbackItem.decoder.cache(cachebytes);
            break;
        }           
    }  
}

async function DoCache(ms, cachebytes) {
    if(CacheTimer) {        
        clearTimeout(CacheTimer);
    }
    
    if(cachebytes == -1) {
        console.log('fast start cache bytes');
        //cachebytes = 1048576;
        cachebytes = 1048576/2;         
    }   
    await Cache(cachebytes);
    CacheTimer = setTimeout( function() {
        DoCache(ms, (4*1048576));        
    }, ms);
}

async function pumpAudioAll(duration, jobid) {
    
    if(PlaybackQueue.length == 0) {
         self.postMessage({'message': 'at_end_of_queue', 'jobid' : jobid});
         return;         
    }
    
    let samplerate = 0;
    let channels = 0;
    let bitspersample = 0;
    let samples = 0;
    let remsamples = 0;
    let outbuffer = [];
    
    let toremove = 0;        
    let tickevents = [];
    let tick = 0;
    let tickindex = 0;
    
    for(let i = 0; i < PlaybackQueue.length; i++) {
        let playbackItem = PlaybackQueue[i];
        if(playbackItem.decoder === null) {
            console.log('job id: ' + jobid + ' waiting for decoder');
            try {
                await playbackItem.CreateDecoder();
                console.log('job id: ' + jobid + ' decoder created');
            }
            catch(e) {
                console.log('job id: ' + jobid + ' decoder create failed (catch) ' + e);
                continue;
            }
            if(!playbackItem.decoder) {
                console.log('job id: ' + jobid + ' decoder create failed');
                continue;                
            }
        }
        
        if( i == 0) {
            samplerate = playbackItem.decoder.samplerate;
            channels   = playbackItem.decoder.channels;
            bitspersample = playbackItem.decoder.bitspersample;
            samples = duration * samplerate;
            remsamples = samples;

            for( let i = 0; i < channels;  i++) {
                outbuffer[i] = new ArrayBuffer(4*samples); // sizeof(Float32) * number of samples           
            }             
        }
        else {            
            if(playbackItem.decoder.samplerate != samplerate) break;
            if(playbackItem.decoder.channels != channels) break;            
        }
        let outbufferindex = samples - remsamples;
        let res;
        try {
            console.log('job id: ' + jobid + ' waiting for decoder read');
            res = await playbackItem.decoder.read(remsamples, outbuffer, outbufferindex);
            if(!res) {
                 console.log('job id: ' + jobid + ' decoder read failed (null)');
                 continue;
            }
        }
        catch(e) {
            console.log('job id: ' + jobid + ' decoder read failed (catch) ' + e);
            continue;            
        }
        console.log('job id: ' + jobid + ' decoder read success');
        if(res.isStart) {
            isStart = 0;
            tickevents[tickindex] = tickevents[tickindex] || { 'tick' : tick, 'inctrack' : 0};
            tickevents[tickindex].samples = res.samples;
            tickevents[tickindex].total_samples = playbackItem.decoder.totalPCMframes;
            tickevents[tickindex].trackname = playbackItem.decoder.trackname;
            tickevents[tickindex].skipsamples = res.skipsamples || 0;
            this.skipsamples = 0;               
            // only increase the tickindex when the tick used and over
            if(res.samples > 0) {
                tickindex++;                
            }            
        }
        tick += res.samples;           
        if(res.isLast) {                                
            tickevents[tickindex] = tickevents[tickindex] || { 'tick' : tick, 'inctrack' : 0};
            tickevents[tickindex].samples = 0;
            tickevents[tickindex].total_samples = 0;
            tickevents[tickindex].trackname = null;
            tickevents[tickindex].skipsamples = 0;
            tickevents[tickindex].inctrack++;                
            toremove++;                
        }
         
        remsamples -= res.samples;
        if(remsamples == 0) {
            break;
        }            
    }
    
    if(toremove > 0) {
        PlaybackQueue.splice(0, toremove);            
    }
    
     
    let dessamples = samples;
    // if there's still desired samples at this point, encode silence
    if(remsamples > 0) {
        console.log('encoding ' + remsamples + ' of silence ');
    }
    for(let j = 0; j < channels; j++) {
        let buf = new Float32Array(outbuffer[j]);
        let bufindex = dessamples - remsamples;
        for(let i = 0; i < remsamples; i++, bufindex++) {
            buf[bufindex] = 0;            
        }
    } 
    let result = {};   
    result.jobid = jobid;
    result.message = 'decodedone';
    result.samplerate = samplerate;
    result.channels = channels;
    result.bitspersample = bitspersample;
    result.remsamples = remsamples;
    result.tickevents = tickevents;
    result.samples = samples;
    result.outbuffer = outbuffer;
    
    // hack
    if(samples == 0) {
        self.postMessage({'message': 'no_data', 'jobid' : jobid});
        return;
    }
    
    console.log('FlacWorker: outputting samples: ' + samples + ' samplerate: ' + samplerate + ' channels: ' + channels);    
    self.postMessage(result, outbuffer);        
}

async function Seek(skiptime, tracks, duration, jobid) {
    if(typeof skiptime === 'undefined') {
          skiptime = null;
    }
    
    DownloadController.abort();
    DownloadController = new AbortController();
    DownloadStopSignal = DownloadController.signal;
    skiptime = skiptime || 0;
    //if((tracks.length == PlaybackQueue.length) && (PlaybackQueue[0].decoder) && (PlaybackQueue[0].iscreated)) {
    if(0){        
        let dessample = Math.floor(skiptime * PlaybackQueue[0].decoder.samplerate);
        await PlaybackQueue[0].decoder.softseek(dessample);        
    }
    else
    {
        PlaybackQueue = [];
        tracks.forEach( function(elm) {            
            PlaybackQueue.push(new PlaybackItem(elm));
        });
        PlaybackQueue[0].starttime = skiptime;        
    }
    pumpAudioAll(duration, jobid); 
        
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

self.addEventListener('message', function(e) {
  if(e.data.message == 'pumpAudio') {
      let skiptime = e.data.skiptime;
      if(typeof skiptime === 'undefined') {
          skiptime = null;
      }      
      pumpAudioAll(e.data.duration, e.data.jobid);       
  }
  else if(e.data.message == "seek") {
      Seek(e.data.skiptime, e.data.tracks, e.data.duration, e.data.jobid);           
  }
  else if(e.data.message == "pushPlaybackQueue") {
      PlaybackQueue.push(new PlaybackItem(e.data.track));
  }  
  else if(e.data.message == 'setup') {
      URLSTART = e.data.urlstart;
      URLEND   = e.data.urlend;
      URLBASEURI = e.data.urlbaseuri;
  }      
}, false);