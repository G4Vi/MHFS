//self.FLAC_SCRIPT_LOCATION = 'libflac.js/';
//importScripts('libflac.js/libflac4-1.3.2.wasm.js');
self.FLAC_SCRIPT_LOCATION = 'libflac.js/min/';
importScripts('libflac.js/min/libflac4-1.3.2.min.wasm.js');

let Tracks = [];
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

function concatTypedArrays(a, b) { // a, b TypedArray of same type
    var c = new (a.constructor)(a.length + b.length);
    c.set(a, 0);
    c.set(b, a.length);
    return c;
}

async function TryDecodeFlacBuf(track, binData) {
    if(typeof Flac === 'undefined') {
        console.log('DecodeFlac, no Flac - setInterval');
        let promise = new Promise((resolve, reject) => {
            let itertimer;
            function onIter() {                
                if(typeof Flac === 'undefined') {
                    console.log('DecodeFlac, no Flac - setInterval');
                    return;
                }                
                clearInterval(itertimer);
                resolve("success");            
            };
            itertimer = setInterval(onIter, 5);            
        });
        let result = await promise;       
    }
    if(!Flac.isReady()) {
        console.log('DecodeFlac, Flac not ready, handler added');
        let promise = new Promise((resolve, reject) => {
            Flac.on('ready', function(libFlac){
                resolve("suc2");
            });
        });    
        let result = await promise;
        console.log('flac loaded');        
    }    
    
    track.bytesLeft -= binData.buffer.byteLength;
    if(! track.binData) {
        track.binData = binData;
        track.currentDataOffset = 0;
        track.decData = [];
        track.decFrames = 0;
        track.curSample = 0;
    }
    else {
        track.binData = concatTypedArrays(track.binData, binData);
    }
	
    var flac_ok = 1;    
	
    if(! track.flac_decoder) {
        track.flac_decoder = Flac.create_libflac_decoder(false); 
        if (track.flac_decoder != 0){
            
	        /** @memberOf decode */
            function read_callback_fn(bufferSize){	          	
                console.log('decode read callback, buffer bytes max=', bufferSize);
                
                var start = track.currentDataOffset;
                var csize =track.binData.buffer.byteLength;
                var end = track.currentDataOffset === csize? -1 : Math.min(track.currentDataOffset + bufferSize, csize);
                
                var _buffer;
                var numberOfReadBytes;
                if(end !== -1){
                    
                    _buffer = track.binData.subarray(track.currentDataOffset, end);
                    numberOfReadBytes = end - track.currentDataOffset;
                    
                    track.currentDataOffset = end;
                } else {
                    console.log('no bytes left');
                    numberOfReadBytes = 0;
                }
                //console.log(_buffer);
                return {buffer: _buffer, readDataLength: numberOfReadBytes, error: false};
            }
            
            /** @memberOf decode */
            function write_callback_fn(buffer){
                // buffer is the decoded audio data, Uint8Array
                //console.log('decode write callback', buffer);
                //track.decData.push(buffer);
                track.decData.push(buffer);
                console.log("write_callback decdata len " + track.decData.length);
            }
            
            /** @memberOf decode */
            function metadata_callback_fn(data){
                console.info('meta data: ', data);
                track.meta_data = data;               		
                for(var n in track.meta_data){
                    console.log( n + ' ' + 	track.meta_data[n]);
                }	
            }
	        /** @memberOf decode */
	        function error_callback_fn(decoder, err, client_data){
	            console.log('decode error callback', err);
	        }
            var init_status = Flac.init_decoder_stream(track.flac_decoder, read_callback_fn, write_callback_fn, error_callback_fn, metadata_callback_fn);
            

		    
		    
            flac_ok &= init_status == 0;
            console.log("flac init     : " + flac_ok);//DEBUG
	    } else {
	    	var msg = 'Error initializing the decoder.';
	        console.error(msg);
	    	return;
        }        
    }
	

	
	function readmeta() {
		let is_last = 0;
		let type;
		let flac_return = 1;
		is_last = (track.binData[track.data_offset] & 0x80) == 0x80;
		type = track.binData[track.data_offset] & 0x7F;
		let size = ((track.binData[track.data_offset+1] << 16) & 0xFF0000) | ((track.binData[track.data_offset+2] << 8) & 0xFF00) | track.binData[track.data_offset+3];
		console.log('metablock size ' + size + ' is_last ' + is_last + ' type ' + type + 'offset ' + track.data_offset);
		if(track.binData.length < roundUp(track.data_offset + 4 + size, 8192)) {
			console.log('not enough data for current meta');
            return false;		
		}
		flac_return &= Flac.FLAC__stream_decoder_process_single(track.flac_decoder);
		state = Flac.FLAC__stream_decoder_get_state(track.flac_decoder);
        track.data_offset += (4 + size);		
        if(is_last) {
            track.metaleft = 0;
        }
        console.log('flac_return ' + flac_return + 'state ' + state, 'track.data_offset ' + track.data_offset);
        return true;        
	}
	
	function isframe() {
		let synccode = ((track.binData[track.data_offset] << 6)	& 0x3FC0) | ((track.binData[track.data_offset+1] >> 2) & 0x3F);
		return (synccode == 0x3FFE);
	}
	
	
    if(! track.meta_data) {
		console.log('no meta');
		if(track.binData.length < (8+34)) {			
			console.log('not enough data for streaminfo');
			return;
		}
        track.data_offset = 4;
		track.metaleft = 1;
        readmeta();		
    }
	while(track.metaleft) {		
		if(isframe()) {
			console.log('unexpected frame before meta was done');
            track.metaleft = 0;
            return;			
		}
		if(!readmeta()) return;			
	}
	console.log('isframe ' + isframe());
	return;	
}


async function downloadFlac(name) {
    Tracks[name] = {};
    Tracks[name].trackname = name;
    let url = getURL(name);
    let response = await fetch(url);
    let reader = response.body.getReader();
    Tracks[name].CL = response.headers.get('Content-Length');
    console.log('CL ' + Tracks[name].CL);
    Tracks[name].bytesLeft = Tracks[name].CL;
    
    Tracks[name].startsample = 0;
    
    var binData;
    while(1) {
        let {value: chunk, done: readerDone} = await reader.read();
        if(chunk){
            console.log('chunk length ' + chunk.length);
            await TryDecodeFlacBuf(Tracks[name], chunk);
            //binData = binData ? concatTypedArrays(binData, chunk) : chunk;                        
            //if(binData.length == this.CL) {
            //    await TryDecodeFlacBuf(this, binData);
            //    await TryDecodeFlacBuf(this, new Uint8Array());
            //}
        }//
        if(readerDone) {
            console.log('dl of ' + Tracks[name].trackname + ' done');
            return;
        }
    }    
}

async function queueFlac(trackname, duration, skiptime) {
    let track = Tracks[trackname];
	if(! track.meta_data  || track.metaleft) {
		console.log('metadata left not queuing');
        self.postMessage({'message': 'decode_no_meta'});
        return;		
	}
	track.decData = track.decData || [];
	
	let datareq = roundUp(track.meta_data['max_framesize'], 8192);
	let samples = track.meta_data['sampleRate'] * duration;
	let frames  = Math.ceil(samples/track.meta_data['max_blocksize']);
	
	var flac_return = 1;
	var state = 0;
	while(((track.binData.buffer.byteLength - track.currentDataOffset) >= datareq) ||(track.bytesLeft == 0))  {
		flac_return &= Flac.FLAC__stream_decoder_process_single(track.flac_decoder);
        //need to check decoder state: state == 4: end of stream ( > 4: error)
		state = Flac.FLAC__stream_decoder_get_state(track.flac_decoder);
		if((!flac_return) || (state > 3)) {
			if(flac_return && (state == 4)) {
				console.log("decoding success flac_return:" + flac_return + " state " + state);
				break;
			}
			console.log("decoding error flac_return:" + flac_return + " state " + state);
			break;
		}
		console.log("decoded frames " + track.decData.length);
        if(track.decData.length >= frames) {
			let decodedsamples = 0;
		    for(var i = 0; i < track.decData.length; i++) {
		    	decodedsamples += (track.decData[i][0].length / 2);			
		    }
			console.log('decoded samples 1 ' + decodedsamples); 
			if(decodedsamples >= samples) break;
        }			
	}	
	if(track.decData.length >= frames) {
		frames = track.decData.length;
		let decodedsamples = 0;
		for(var i = 0; i < track.decData.length; i++) {
			decodedsamples += (track.decData[i][0].length / 2);			
		}		
		console.log('decoded samples ' + decodedsamples);		
		
		let leftoversamples = decodedsamples - samples;
		console.log('decoded samples (leftover) ' + leftoversamples);
		track.decDataSave = [];
		// save leftoversamples for later
		if(leftoversamples > 0) {
		    let bytespersample = track.meta_data['bitsPerSample'] / 8;			
			track.decDataSave[0] = [];
		    for(var i = 0; i < track.meta_data['channels']; i++) {
                track.decDataSave[0][i] =  track.decData[frames-1][i].subarray( track.decData[frames-1][i].length - (leftoversamples * bytespersample));
                track.decData[frames-1][i] = track.decData[frames-1][i].subarray(0, track.decData[frames-1][i].length - (leftoversamples * bytespersample));               	
		    }
			decodedsamples = 0;
            for(var i = 0; i < track.decDataSave.length; i++) {
		    	decodedsamples += (track.decDataSave[i][0].length / 2);			
		    }
            if(decodedsamples != leftoversamples) alert(1);			
			
		}
		decodedsamples = 0;
        for(var i = 0; i < track.decData.length; i++) {
			decodedsamples += (track.decData[i][0].length / 2);			
		}		
		console.log('decoded samples 2 ' + decodedsamples);	
        
		
        	
		//console.log(track.decData);
		
		/*let wav = toWav(track.meta_data, track.decData);		
		track.decData = track.decDataSave;
		let incomingdata = await MainAudioContext.decodeAudioData(wav);*/		
		
		
		function toint16(byteA, byteB) {
			var sign = byteB & (1 << 7);
            var x = (((byteB & 0xFF) << 8) | (byteA & 0xFF));
            if (sign) {
               x = 0xFFFF0000 | x;  // fill in most significant bits with 1's
            }
            return x;			
		}		
		
		let div = Math.pow(2, track.meta_data['bitsPerSample'] - 1);
        let chans = [];
        
        for(var i = 0; i < track.meta_data['channels']; i++) {
            let abuf = new ArrayBuffer(4*samples);
            let buf  = new Float32Array(abuf); 			
			//let buf = new Float32Array(samples);
			let bufindex = 0;           
			for(var j = 0; j < frames; j++) {
				//const view = new DataView(track.decData[j][i].buffer);                
				for(var k = 0; k < track.decData[j][i].length; k += 2){
					//let s16value = view.getInt16(k, 1);
					let s16value = toint16(track.decData[j][i][k], track.decData[j][i][k+1]);
                    buf[bufindex++] = (s16value / 0x7FFF);
					//buf[bufindex++] = s16value / div;
					//buf[bufindex++] = (s16value + 0.5) / (0x7FFF + 0.5);
                    //buf[bufindex++] = (s16value > 0) ? (s16value / 0x7FFF) : (s16value / 0x8000); 
                    //buf[bufindex++] = (s16value < 0) ? (s16value / 0x8000) : (s16value / 0x7FFF); 
                    //buf[bufindex++] = (s16value >= 0x8000) ? -(0x10000 - s16value) / 0x8000 : s16value / 0x7FFF;                                                            
					if((buf[bufindex-1] > 1) || (buf[bufindex-1] < -1)) {
						console.log('CLAMPING FLOAT');
						if(buf[bufindex-1] > 1) buf[bufindex-1] = 1;
					    if(buf[bufindex-1] < -1) buf[bufindex-1] = -1; 	
					}                  				
				}

			}
			console.log('bufindex ' + bufindex, 'samples ' + samples);
            chans[i] = abuf;					
		}    
		track.decData = track.decDataSave;
        self.postMessage({'message': 'decodedone', 'samplerate' : track.meta_data['sampleRate'], 'samples' : samples, 'channels': track.meta_data['channels'],   'abuf' : chans}, chans);        
	}	
}

function decDataToSamples(decData) {
    let decodedsamples = 0;
	for(var i = 0; i < decData.length; i++) {
		decodedsamples += (decData[i][0].length / 2);			
	}
    return decodedsamples;
}


async function flacReady(track) {
    if(! track) {
        console.log('FlacWorker: track doesnt exist');
        return false;
    }
	if(! track.meta_data  || track.metaleft) {
		console.log('FlacWorker: metadata left, flacinfo not yet available');        
        return false;		
	}   
    return true;    
}

function toint16(byteA, byteB) {
	var sign = byteB & (1 << 7);
    var x = (((byteB & 0xFF) << 8) | (byteA & 0xFF));
    if (sign) {
       x = 0xFFFF0000 | x;  // fill in most significant bits with 1's
    }
    return x;			
}

async function decodeFlac(track, dessamples, outbuffer, startindex) {
	track.decData = track.decData || [];
	let datareq = roundUp(track.meta_data['max_framesize'], 8192);
	let samples = dessamples;
	let frames  = Math.ceil(samples/track.meta_data['max_blocksize']);
    var flac_return = 1;
	var state = 0;
	while(((track.binData.buffer.byteLength - track.currentDataOffset) >= datareq) ||(track.bytesLeft == 0))  {
		flac_return &= Flac.FLAC__stream_decoder_process_single(track.flac_decoder);
        //need to check decoder state: state == 4: end of stream ( > 4: error)
		state = Flac.FLAC__stream_decoder_get_state(track.flac_decoder);
		if((!flac_return) || (state > 3)) {
			if(flac_return && (state == 4)) {
				console.log("decoding success flac_return:" + flac_return + " state " + state);
                frames = track.decData.length;
                samples = decDataToSamples(track.decData);                
				break;
			}
			console.log("decoding error flac_return:" + flac_return + " state " + state);
			break;
		}
		console.log("decoded frames " + track.decData.length);
        if(track.decData.length >= frames) {
            let decodedsamples = decDataToSamples(track.decData);			
			if(decodedsamples >= samples) break;
        }			
	}
    if(track.decData.length < frames) {
        return;      
    }
    frames = track.decData.length;
    let decodedsamples = decDataToSamples(track.decData);
    console.log('decoded samples ' + decodedsamples);
	let leftoversamples = decodedsamples - samples;
	console.log('decoded samples (leftover) ' + leftoversamples);
	track.decDataSave = [];
	// save leftoversamples for later
	if(leftoversamples > 0) {
	    let bytespersample = track.meta_data['bitsPerSample'] / 8;			
		track.decDataSave[0] = [];
	    for(var i = 0; i < track.meta_data['channels']; i++) {
            track.decDataSave[0][i] =  track.decData[frames-1][i].subarray( track.decData[frames-1][i].length - (leftoversamples * bytespersample));
            track.decData[frames-1][i] = track.decData[frames-1][i].subarray(0, track.decData[frames-1][i].length - (leftoversamples * bytespersample));               	
	    }
		decodedsamples = 0;
        for(var i = 0; i < track.decDataSave.length; i++) {
	    	decodedsamples += (track.decDataSave[i][0].length / 2);			
	    }
        if(decodedsamples != leftoversamples) alert(1);			
		
	}
	decodedsamples = decDataToSamples(track.decData);	
	console.log('decoded samples after save ' + decodedsamples);
		
	
	let div = Math.pow(2, track.meta_data['bitsPerSample'] - 1);
   
    let nextbufindex;
    for(var i = 0; i < track.meta_data['channels']; i++) {       
        let buf  = new Float32Array(outbuffer[i]);		
		let bufindex = startindex;          
		for(var j = 0; j < frames; j++) {
			//const view = new DataView(track.decData[j][i].buffer);                
			for(var k = 0; k < track.decData[j][i].length; k += 2){
				//let s16value = view.getInt16(k, 1);
				let s16value = toint16(track.decData[j][i][k], track.decData[j][i][k+1]);
                buf[bufindex++] = (s16value / 0x7FFF);
				//buf[bufindex++] = s16value / div;
				//buf[bufindex++] = (s16value + 0.5) / (0x7FFF + 0.5);
                //buf[bufindex++] = (s16value > 0) ? (s16value / 0x7FFF) : (s16value / 0x8000); 
                //buf[bufindex++] = (s16value < 0) ? (s16value / 0x8000) : (s16value / 0x7FFF); 
                //buf[bufindex++] = (s16value >= 0x8000) ? -(0x10000 - s16value) / 0x8000 : s16value / 0x7FFF;                                                            
				if((buf[bufindex-1] > 1) || (buf[bufindex-1] < -1)) {
					console.log('CLAMPING FLOAT');
					if(buf[bufindex-1] > 1) buf[bufindex-1] = 1;
				    if(buf[bufindex-1] < -1) buf[bufindex-1] = -1; 	
				}                  				
			}

		}
		console.log('bufindex ' + bufindex, 'samples ' + samples);
        nextbufindex = bufindex;
        					
	}    
	track.decData = track.decDataSave;
    let isStart = (track.curSample == 0);    
    track.curSample += samples;
    console.log('setting curSample of ' + track.trackname + ' to ' + track.curSample);
    if(track.curSample > track.meta_data['total_samples']) {        
        alert(1);
    }
    let isLast = (track.curSample == track.meta_data['total_samples']);
    return {'startindex' : nextbufindex, 'samples' : samples, 'isStart' : isStart, 'isLast' : isLast};
    
}

let WorkingName = null;
async function pumpAudio(tracks, duration, repeat, skiptime, jobid) {
    if(skiptime !== null) {
        console.log('skiptime is defined ' + skiptime);        
        if(WorkingName !== null) {
            console.log('setting curSample of ' + WorkingName + ' to 0');
            Flac.FLAC__stream_decoder_reset(Tracks[WorkingName].flac_decoder);
            Tracks[WorkingName].curSample = 0;
            Tracks[WorkingName].currentDataOffset = 0;            
            Tracks[WorkingName].decData = [];
            WorkingName = null;            
        }            
    }
    let track = Tracks[tracks[0]];
    if(! track) {
        downloadFlac(tracks[0]);
        console.log('FlacWorker: Need to download');
        self.postMessage({'message': 'track_doesnt_exist', 'jobid' : jobid});
        return;        
    }
    if(! await flacReady(track)) {
        console.log('FlacWorker: flacReady failed');
        self.postMessage({'message': 'flac_not_ready', 'jobid' : jobid});
        return;        
    }
    let outbuffer = [];
    let samples = track.meta_data['sampleRate'] * duration;
    let dessamples = samples;
    let startindex = 0;
    let channels = track.meta_data['channels'];
    let samplerate = track.meta_data['sampleRate'];
    let bitspersample = track.meta_data['bitsPerSample'];
    if(bitspersample != 16) {
        console.log('FlacWorker: bitspersample not 16 is not implemented');
        return;
    }
    
    for( let i = 0; i < channels;  i++) {
        outbuffer[i] = new ArrayBuffer(4*dessamples); // sizeof(Float32) * number of samples           
    }    
    
    let i = 0;
    let tickevents =[];
    let tick = 0;
    let tickindex = 0;    
    while(1){
        WorkingName = tracks[i];
        let res = await decodeFlac(track, dessamples, outbuffer, startindex);
        if(!res) {
            console.log('FlacWorker: decodeFlac failed');        
        }
        startindex = res.startindex;
        console.log('desamples ' + dessamples + ' res.samples ' + res.samples);
        dessamples -= res.samples;       
        if(res.isStart) {
            tickevents[tickindex] = tickevents[tickindex] || { 'tick' : tick, 'inctrack' : 0};
            tickevents[tickindex].samples = res.samples;
            tickevents[tickindex].total_samples = track.meta_data['total_samples'];
            tickevents[tickindex].trackname = track.trackname;  
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
            if(!repeat){
                tickevents[tickindex].inctrack++;
            }                            
        }       
        if(dessamples == 0) break;        
        if(!repeat) {
            // reseting encoder
            Flac.FLAC__stream_decoder_reset(track.flac_decoder);
            track.curSample = 0;
            track.currentDataOffset = 0; 
            
            i++;
            // no more tracks
            if(!tracks[i]) {
                if(dessamples == samples) {
                    console.log('FlacWorker: no samples encoded');
                    self.postMessage({'message': 'no_samples_encoded', 'jobid' : jobid});
                    return;
                }                    
                console.log('FlacWorker: no more tracks, encoding ' + dessamples + ' of silence');
                break;
            }
            track = Tracks[tracks[i]];
            // unable to load the track            
            if(! await flacReady(track)) {
                console.log('FlacWorker: track not ready, encoding ' + dessamples + ' of silence');
                break;
            }
            // different number of channels
            if(track.meta_data['channels'] != channels) {
                console.log('FlacWorker: next track has different number of channels, encoding ' + dessamples + ' of silence');
                break;                
            }
            // different samplerate
            if(track.meta_data['sampleRate'] != samplerate) {
                console.log('FlacWorker: next track has different samplerate, encoding ' + dessamples + ' of silence');
                break;                
            }
        }
        else {
            // reset flac head location
            console.log('FlacWorker: repeat');
            //break;
            Flac.FLAC__stream_decoder_reset(track.flac_decoder);
            track.curSample = 0;
            track.currentDataOffset = 0;            
        }            
    }
    
    // if there's still desired samples at this point, encode silence
    // optimize this, is it necessary?
    for(let j = 0; j < channels; j++) {
        let buf = new Float32Array(outbuffer[j]);
        let bufindex = startindex;
        for(let i = 0; i < dessamples; i++, bufindex++) {
            buf[bufindex] = 0;            
        }
    }
    console.log('FlacWorker: outputting samples: ' + samples + ' samplerate: ' + samplerate + ' channels: ' + channels);
    self.postMessage({'message': 'decodedone', 'samplerate' : samplerate, 'samples' : samples, 'channels': channels,   'tickevents': tickevents, 'jobid' : jobid, 'abuf' : outbuffer}, outbuffer);  
}

let PlaybackQueue = [];

function WavDecoder(trackname) {
    this.trackname = trackname;
    this._url = getURL(trackname);
    
    this.myconstructor = async function ()
    {
        let request = new Request(this._url, {
            method :  'GET',
            headers : { 'Range': 'bytes=0-43'}        
        });
        let response = await fetch(request);
        let contentrange = response.headers.get('Content-Range');
        let re = /\/(\d+)/;
        let res = re.exec(contentrange);
        if(res) this._size = Number(res[1]);        
        let abuf = await response.arrayBuffer();
        let asbytes = new DataView(abuf);
        let littleEndian = true;
        this.channels   = asbytes.getUint16(22, littleEndian);
        this.samplerate = asbytes.getUint32(24, littleEndian);
        this.bitspersample = asbytes.getUint16(34, littleEndian);        
        this._AudioDataSize = asbytes.getUint32(40, littleEndian);  
        this._BytesPerSample =  this.bitspersample / 8;       
        this.totalPCMframes = this._AudioDataSize /  (this._BytesPerSample * this.channels);
        console.log('WAV :');
        console.log(this);
        this._ReadOffset = 44;
        
    };
   
    
    this._AudioStartOffset = 44;
    this._ReadOffset = 44;
    
    this.maxBufferSize = 4*1048576;
    this.buffer = new Uint8Array(this.maxBufferSize);
    this.bufferSize = 0;
    this.cache = async function(cacheleft) {
        if(this.bufferSize == this.maxBufferSize) {
            console.log('not buffering, buffer maxed out');
            return 0;
        }
        if((this.bufferSize + this._ReadOffset) == this._size) {
            console.log('not buffering, no more data left in track');
            return 0;            
        }
        else if((this.bufferSize + this._ReadOffset) >= this._size){
            console.log('not buffering, SHOULD NEVER GET HERE');
            return 0;            
        }
        //let downloadEndIndex =  this.maxBufferSize + this._ReadOffset - 1;
        let downloadEndIndex = cacheleft+this.bufferSize + this._ReadOffset - 1;
        if(downloadEndIndex > (this._size - 1)) {
            downloadEndIndex = this._size - 1;
            console.log('clamped download end index to ' + downloadEndIndex);
        }
        let downloadsize = (downloadEndIndex - (this._ReadOffset + this.bufferSize)+1);
        if(downloadsize > this.maxBufferSize) {
            console.log('download size is fucked up');            
        }
        
        console.log('downloadendindex ' + downloadEndIndex + ' buffersize ' + this.bufferSize + 'readoffset ' + this._ReadOffset);
        let request = new Request(this._url, {
            method :  'GET',
            headers : { 'Range': ('bytes=' + (this._ReadOffset + this.bufferSize) + '-' + downloadEndIndex)}        
        });
        let bufsizegoingin = this.bufferSize;
        let response = await fetch(request);
        let reader = response.body.getReader();
        while(1) {
            let {value: chunk, done: readerDone} = await reader.read();
            if(chunk){
                console.log('chunk length ' + chunk.length + 'buffersize ' + this.bufferSize + ' bufsize going in ' + bufsizegoingin);
                if((chunk.length + this.bufferSize) > this.maxBufferSize) {
                    console.log('report in report in people');
                    return;                    
                }                    
                this.buffer.set(chunk, this.bufferSize);
                this.bufferSize += chunk.length;
            }
            if(readerDone) {
                console.log('caching done' + downloadsize);
                return downloadsize;
            }
        }               
    }
    
    
    this.read = function(samples, outbuffer, outbufindex) {        
        
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
        let isLast = 0;
        if(lastindex == (this._size - 1)) {
            isLast = 1;
        }
        console.log('lastIndex ' + lastindex);
        // create a buffer to output the raw data to
        let dataarr = new Uint8Array(pcmsize); 
        // copy from cached
        let tocopy = 0;
        if(this.bufferSize > 0) {
            tocopy = this.bufferSize > pcmsize ? pcmsize : this.bufferSize;
            dataarr.set(this.buffer.slice(0, tocopy));
            this.bufferSize -= tocopy;
            if(this.bufferSize > 0) {
                this.buffer.copyWithin(0, tocopy);
            }
            this._ReadOffset += tocopy;            
        }
        // download if necessary
        if(tocopy < pcmsize) {
            /*let request = new Request(this._url, {
                method :  'GET',
                headers : { 'Range': ('bytes=' + this._ReadOffset + '-' + lastindex)}        
            });
            this._ReadOffset += (pcmsize - tocopy);       
            let response = await fetch(request);
            let aBuf = await response.arrayBuffer();
            dataarr.set(aBuf, tocopy);*/
            return null;            
        }    
        
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
        
        return {'samples' : samples, 'isStart' : isStart, 'isLast' : isLast};        
    };
    
    this.seek = function(samples) {
        this.bufferSize = 0;
        this._ReadOffset = this._AudioStartOffset + (samples * this.channels * this._BytesPerSample);        
    };    
}

function Cache() {
    this.decoders = [];
    this.cache = async function() {        
        let cachesize = 4 *1048576;
        let cacheleft = cachesize;
      
        for(i = 0; ; i++) {
            decoder = this.decoders[i];
            if(!decoder) {
                let track = PlaybackQueue.shift();
                if(! track) break;
                this.decoders[i] = new WavDecoder(track);
                if(!this.decoders[i]) break;
                decoder = this.decoders[i];
                await decoder.myconstructor();                     
            }
            cacheleft -= decoder.bufferSize;            
            cacheleft -= (await decoder.cache(cacheleft));
            if(cacheleft == 0) break;
            console.log('still cacheleft ' + cacheleft);                    
        }
        console.log('done caching decoders length' + this.decoders.length + ' playbackqueuelegnth ' + PlaybackQueue.length + 'amount cached ' + (cachesize - cacheleft));
        return cachesize - cacheleft;        
    }
    
    this.skipsamples = 0;
    
    this.seek = function(skiptime) {
        let samplerate = this.decoders[0].samplerate;
        this.skipsamples =  Math.round(samplerate * skiptime);
        this.decoders[0].seek(this.skipsamples);        
    }

    this.read = function(duration) {
        let samplerate = this.decoders[0].samplerate;        
        let channels   = this.decoders[0].channels;
        let bitspersample = this.decoders[0].bitspersample;
        if(bitspersample != 16) {
            console.log('FlacWorker: bitspersample not 16 is not implemented');
            return;
        }
        
        let samples = duration * samplerate; 
        let outbuffer = [];        
        for( let i = 0; i < channels;  i++) {
            outbuffer[i] = new ArrayBuffer(4*samples); // sizeof(Float32) * number of samples           
        }  

        
        let remsamples = samples;     
        
        let toremove = 0;        
        let tickevents = [];
        let tick = 0;
        let tickindex = 0;
        for(let i = 0; i < this.decoders.length; i++) {
            let decoder = this.decoders[i];
            if(decoder.channels != channels) break;
            if(decoder.samplerate != samplerate) break;
            let outbufferindex = samples - remsamples;
            let res = decoder.read(remsamples, outbuffer, outbufferindex);
            if(! res) {                
                console.log('decode error on ' + decoder.trackname);
                return null;                
            }
            // note the tick events
            if(res.isStart || this.skipsamples) {
                isStart = 0;
                tickevents[tickindex] = tickevents[tickindex] || { 'tick' : tick, 'inctrack' : 0};
                tickevents[tickindex].samples = res.samples;
                tickevents[tickindex].total_samples = decoder.totalPCMframes;
                tickevents[tickindex].trackname = decoder.trackname;
                tickevents[tickindex].skipsamples = this.skipsamples;
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
            this.decoders.splice(0, toremove);            
        }
        
        return {'samplerate' : samplerate, 'channels' : channels, 'bitspersample' : bitspersample, 'remsamples' : remsamples, 'tickevents' : tickevents, 'samples' : samples, 'outbuffer' : outbuffer};
    };        
}

let CACHE = new Cache();

async function pumpAudioAll(duration, jobid) {
    if(!CACHE.decoders[0]) {       
        let cached = await CACHE.cache();
        if(cached == 0) {
            console.log('end of queue');
            self.postMessage({'message': 'at_end_of_queue', 'jobid' : jobid});
            return;
        }
        console.log('after no decoder seeking');        
    }    
   
    let result = CACHE.read(duration);
    if(!result) {
        self.postMessage({'message': 'track_doesnt_exist', 'jobid' : jobid});
        return;
    }        
    let dessamples = result.samples;
    // if there's still desired samples at this point, encode silence
    for(let j = 0; j < result.channels; j++) {
        let buf = new Float32Array(result.outbuffer[j]);
        let bufindex = dessamples - result.remsamples;
        for(let i = 0; i < result.remsamples; i++, bufindex++) {
            buf[bufindex] = 0;            
        }
    }              
    result.jobid = jobid;
    result.message = 'decodedone';
    console.log('FlacWorker: outputting samples: ' + result.samples + ' samplerate: ' + result.samplerate + ' channels: ' + result.channels);
    self.postMessage(result, result.outbuffer);
    CACHE.cache();
}

async function Seek(skiptime, tracks, duration, jobid) {
    if(typeof skiptime === 'undefined') {
          skiptime = null;
    }
    PlaybackQueue = tracks;
    CACHE.decoders = [];
    await CACHE.cache();
    CACHE.seek(skiptime);       
    await CACHE.cache();
    pumpAudioAll(duration, jobid);    
}

self.addEventListener('message', function(e) {
  if(e.data.message == 'decode') {
      console.log('FlacWorker: queueFlac message is deprecated');      
      queueFlac(e.data.trackname, e.data.duration, skiptime);
  }
  else if(e.data.message == 'pumpAudio') {
      let skiptime = e.data.skiptime;
      if(typeof skiptime === 'undefined') {
          skiptime = null;
      }
      //pumpAudio(e.data.tracks, e.data.duration, e.data.repeat, skiptime, e.data.jobid);
      pumpAudioAll(e.data.duration, e.data.jobid);       
  }
  else if(e.data.message == "seek") {
      Seek(e.data.skiptime, e.data.tracks, e.data.duration, e.data.jobid);           
  }
  else if(e.data.message == "pushPlaybackQueue") {
      PlaybackQueue.push(e.data.tracks);  
  } 
  else if(e.data.message == 'download') {
      console.log('FlacWorker: download message is deprecated');
      downloadFlac(e.data.trackname);      
  }
  else if(e.data.message == 'setup') {
      URLSTART = e.data.urlstart;
      URLEND   = e.data.urlend;
      URLBASEURI = e.data.urlbaseuri;
  }      
}, false);
