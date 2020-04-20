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
        
        
    };
   
    
    this._AudioStartOffset = 44;
    this._ReadOffset = 44;    
    
    this.read = async function(samples, outbuffer, outbufindex) {
        
        
        let index = (samples * this.channels * this._BytesPerSample) + this._ReadOffset - 1;
        if(index > (this._size - 1)) {
            index = this._size - 1;
            console.log('clamped index to ' + index);
            samples = (index - this._ReadOffset + 1) / (this._BytesPerSample * this.channels);
        }
        let pcmsize = (samples * this.channels * this._BytesPerSample);
    
        let isStart = 0;
        if(this._ReadOffset == this._AudioStartOffset) {
            isStart = 1;            
        }
        let isLast = 0;
        if(index == (this._size - 1)) {
            isLast = 1;
        }
        
        let request = new Request(this._url, {
            method :  'GET',
            headers : { 'Range': ('bytes=' + this._ReadOffset + '-' + index)}        
        });
        this._ReadOffset += pcmsize;       
        let response = await fetch(request);
        let aBuf = await response.arrayBuffer();
        let dataarr = new Uint8Array(aBuf);
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
        this._ReadOffset = this._AudioStartOffset + (samples * this.channels * this._BytesPerSample);        
    };    
}

let DECODER;
async function Decoder(trackname) {
    if(! trackname) {
        DECODER = null;
        return;        
    }
    if(DECODER && (DECODER.trackname != trackname)) {
        //DECODER.close();
        DECODER = null;        
    }
    if(!DECODER) {
        //let testWav = /\.wav$/i;
        //if(testWav.test(trackname)) {
        if(1) {
            DECODER = new WavDecoder(trackname);
            await DECODER.myconstructor();
        }
        else {
            console.log('other decoder ENOTIMPLEMENTED');
        }            
    }
    return DECODER;    
}


async function pumpAudioAll(tracks, duration,repeat, skiptime, jobid) {

    if(! await Decoder(tracks[0])) {
        self.postMessage({'message': 'track_doesnt_exist', 'jobid' : jobid});
        return;        
    }
    let samplerate = DECODER.samplerate;
    let dessamples = duration * samplerate;
    //dessamples = 44100 * 1;
    let remsamples = dessamples;
    function StartIndex() { return (dessamples - remsamples);};
    let channels   = DECODER.channels;
    let bitspersample = DECODER.bitspersample;
    let outbuffer = [];
    if(bitspersample != 16) {
        console.log('FlacWorker: bitspersample not 16 is not implemented');
        return;
    }    
    for( let i = 0; i < channels;  i++) {
        outbuffer[i] = new ArrayBuffer(4*dessamples); // sizeof(Float32) * number of samples           
    }     
    let tickevents = [];
    let tick = 0;
    let tickindex = 0;
    let skipsamples = null;
    if(skiptime === null) {
        // copy from cache                
    }
    else {
        skipsamples = Math.round(skiptime * DECODER.samplerate);
        DECODER.seek(skipsamples);
    }
    if(remsamples) {
        let i = 0;
        do {
            let res = await DECODER.read(remsamples, outbuffer, StartIndex());
            if(! res) {
                DECODER = null;
                console.log('decode error on ' + tracks[i]);                
            }
            // note the tick events
            if(res.isStart || skipsamples) {
                isStart = 0;
                tickevents[tickindex] = tickevents[tickindex] || { 'tick' : tick, 'inctrack' : 0};
                tickevents[tickindex].samples = res.samples;
                tickevents[tickindex].total_samples = DECODER.totalPCMframes;
                tickevents[tickindex].trackname = DECODER.trackname;
                tickevents[tickindex].skipsamples = skipsamples;
                skipsamples = null;                
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
                if(!repeat){
                    tickevents[tickindex].inctrack++;
                }                            
            }           
            
            remsamples -= res.samples;
            if(remsamples == 0) {
                break;
            }                
            // queue the next track
            if(!repeat) {
                i++;
                if( ! tracks[i]) {
                    if(dessamples == remsamples) {
                        console.log('FlacWorker: no samples encoded');
                        self.postMessage({'message': 'no_samples_encoded', 'jobid' : jobid});
                        return;
                    }                    
                    console.log('FlacWorker: no more tracks, encoding ' + remsamples + ' of silence');
                    break;                    
                }
                if(! await Decoder(tracks[i])) {
                    self.postMessage({'message': 'track_doesnt_exist', 'jobid' : jobid});
                    return;        
                }
                if(DECODER.channels != channels) break;
                if(DECODER.samplerate != samplerate) break;
            }
            else {
                DECODER.seek(0);
            }          
        } while(1);
        // if there's still desired samples at this point, encode silence
        // optimize this, is it necessary?
        for(let j = 0; j < channels; j++) {
            let buf = new Float32Array(outbuffer[j]);
            let bufindex = StartIndex();
            for(let i = 0; i < remsamples; i++, bufindex++) {
                buf[bufindex] = 0;            
            }
        }
              
    }
    console.log('FlacWorker: outputting samples: ' + dessamples + ' samplerate: ' + samplerate + ' channels: ' + channels);
    self.postMessage({'message': 'decodedone', 'samplerate' : samplerate, 'samples' : dessamples, 'channels': channels,   'tickevents': tickevents, 'jobid' : jobid, 'abuf' : outbuffer}, outbuffer);
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
      pumpAudioAll(e.data.tracks, e.data.duration, e.data.repeat, skiptime, e.data.jobid);       
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
