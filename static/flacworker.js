self.FLAC_SCRIPT_LOCATION = 'libflac.js/';
importScripts('libflac.js/libflac4-1.3.2.wasm.js');

let Tracks = [];

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
	//await queueFlac(track, 1, 0);
	//console.log('after await');
	return;	
}


async function downloadFlac(name, url) {
    Tracks[name] = {};
    let response = await fetch(url);
    let reader = response.body.getReader();
    Tracks[name].CL = response.headers.get('Content-Length');
    console.log('CL ' + Tracks[name].CL);
    Tracks[name].bytesLeft = Tracks[name].CL;
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
	if(duration != 1) {
		console.log('duration of not 1 not supported');		
	}
	track.decData = track.decData || [];
	duration = 1;
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
		let decodedsaved = 0;
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

self.addEventListener('message', function(e) {
  if(e.data.message == 'decode') {  
      queueFlac(e.data.trackname, e.data.duration, e.data.skiptime);
  }
  else if(e.data.message == 'download') {
      downloadFlac(e.data.trackname, e.data.url);      
  } 
}, false);
