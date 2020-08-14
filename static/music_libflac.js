'use strict'
var global;
if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
    console.log('I am in a web worker');
    global = self;
    global.startPath = '';
    global.loadScripts = function(first) {
        importScripts(...first);
    };
} else {
    console.log('I am NOT in a web worker');
    global = window;
    global.startPath = 'static/';     
}
global.FLAC_SCRIPT_LOCATION = startPath+'libflac.js/dist/';

/**
 * adapted (with minor changes) from:
 * https://stackoverflow.com/a/47880734/4278324
 *
 * @return {boolean} TRUE if WebAssembly is supported & can be used
 */
var isWebAssemblySupported = function(){
	try {
		if (typeof WebAssembly === "object" && typeof WebAssembly.instantiate === "function") {
			const module = new WebAssembly.Module(Uint8Array.of(0x0, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00));
			if (module instanceof WebAssembly.Module){
				return new WebAssembly.Instance(module) instanceof WebAssembly.Instance;
			}
		}
	} catch (e) {}
	return false;
};

var wasmDisable = false;
var min = true;
var variant = min ? 'min/' : '';
var lib;
if(!wasmDisable && isWebAssemblySupported()){
	lib = 'libflac.'+variant.replace('/', '.')+'wasm.js';
} else {
	lib = 'libflac.'+variant.replace('/', '.')+'js';
}
var libFile = global.FLAC_SCRIPT_LOCATION.replace('//','/') + lib;

loadScripts([libFile, startPath+'libflac.js/decode-func.js', startPath+'libflac.js/util/data-util.js'], function(){});

function DeclareGlobalFunc(name, value) {
    Object.defineProperty(global, name, {
        value: value,
        configurable: false,
        writable: false
    });
};

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

const toWav =  (metadata, decData) => {
    let samples = interleave(decData, metadata.channels, metadata.bitsPerSample);
	let dataView = encodeWAV(samples, metadata.sampleRate, metadata.channels, metadata.bitsPerSample);
    return dataView.buffer;
};

const FlacToWav = async (thedata) => {
    while(typeof Flac === 'undefined') {
        console.log('worker_music: no Flac sleeping 5');
        await sleep(5);
    }
    if(!Flac.isReady()) {
        console.log('worker_music: waiting for flac to be ready');
        await waitForEvent(Flac, 'ready');
    }

    let decData = [];
    let result = decodeFlac(thedata, decData, false);
    console.log('decoded data array: ', decData);

    if(result.error){
        console.log(result.error);
        return;
    }

    let metaData = result.metaData;
    if(metaData){
        for(var n in metaData){
                console.log( n + ' ' +  metaData[n]);
        }
    }

    return toWav(metaData, decData);
};


function toint16(byteA, byteB) {
    var sign = byteB & (1 << 7);
    var x = (((byteB & 0xFF) << 8) | (byteA & 0xFF));
    if (sign) {
       x = 0xFFFF0000 | x;  // fill in most significant bits with 1's
    }
    return x;
}

/*
DataView.prototype.getInt24 = function(pos, littleEndian) {
    this.getInt16(pos, val >> 8, littleEndian);
    this.getInt8(pos+2, val & ~4294967040, littleEndian); // this "magic number" masks off the first 16 bits
}*/


function toint24(byteA, byteB, byteC) {
    let sign = byteC & (1 << 7);
    let x = ((byteC & 0xFF) << 16) | ((byteB & 0xFF) << 8) | (byteA & 0xFF);
    if (sign) {
       x = 0xFF000000 | x;  // fill in most significant bits with 1's
       //throw('x is ' + x + ' byteA ' + byteA + ' byteB '+ byteB + ' byteC ' + byteC);
    }
    return x;
}

function toint32(byteA, byteB, byteC, byteD) {
    return ((byteD & 0xFF) << 24)  | ((byteC & 0xFF) << 16) | ((byteB & 0xFF) << 8) | (byteA & 0xFF);
}

const FLACToFloat32 = async (thedata) => {
    while(typeof Flac === 'undefined') {
        console.log('FLACToFloat32, no Flac sleeping 5');
        await sleep(5);
    }
    if(!Flac.isReady()) {
        await waitForEvent(Flac, 'ready');
    }
    let decData = [];
    let result = decodeFlac(thedata, decData, true);
    // decData's arrays have little endian sample values
    //console.log('decoded data array: ', decData);
    if(result.error){
        console.log(result.error);
        return;
    }
    let metaData = result.metaData;
        if(metaData){
                for(var n in metaData){
                        console.log( n + ' ' +  metaData[n]);
                }
    }

    let chanData = [];
    let chanIndex = [];
    for(let i = 0; i < metaData.channels; i++) {
        chanData[i] = new Float32Array(metaData.total_samples);
        chanIndex[i] = 0;
    }

    if(metaData.bitsPerSample == 16) {
        for(let i = 0; i < decData.length; i++) {
            for(let j = 0; j < metaData.channels; j++) {
                for(let k = 0; k < decData[i][j].length; k+=2) {
                    chanData[j][chanIndex[j]] = toint16(decData[i][j][k], decData[i][j][k+1]) / 0x7FFF;
                    if((chanData[j][chanIndex[j]] > 1) || (chanData[j][chanIndex[j]] < -1)) {
                        console.log('CLAMPING FLOAT');
                        if(chanData[j][chanIndex[j]] > 1) chanData[j][chanIndex[j]] = 1;
                        if(chanData[j][chanIndex[j]] < -1) chanData[j][chanIndex[j]] = -1;
                    }
                    chanIndex[j]++;
                }
            }
        }
    }
    else if(metaData.bitsPerSample == 24) {
        for(let i = 0; i < decData.length; i++) {
            for(let j = 0; j < metaData.channels; j++) {
                for(let k = 0; k < decData[i][j].length; k+=4) {
                    //chanData[j][chanIndex[j]] = toint24(decData[i][j][k], decData[i][j][k+1],decData[i][j][k+2]) / 0x7FFFFF;
                    // the above works, but libflac js outputs int32s, so this can be done ~ cheaper with no branching conversion
                    chanData[j][chanIndex[j]] = toint32(decData[i][j][k], decData[i][j][k+1],decData[i][j][k+2], decData[i][j][k+3]) / 0x7FFFFF;
                    //chanData[j][chanIndex[j]] *= 0.1; // volume by scaling float32
                    if((chanData[j][chanIndex[j]] > 1) || (chanData[j][chanIndex[j]] < -1)) {
                        console.log('CLAMPING FLOAT');
                        if(chanData[j][chanIndex[j]] > 1) chanData[j][chanIndex[j]] = 1;
                        if(chanData[j][chanIndex[j]] < -1) chanData[j][chanIndex[j]] = -1;
                    }
                    chanIndex[j]++;
                }
            }
        }
    }
    else {
        throw(metaData.bitsPerSample + " bps not handled");
    }

    return [metaData, chanData];
};



const decodeFlacURL = function(theURL, decData, isVerify, isOgg){

	var flac_decoder,
		VERIFY = true,
		flac_ok = 1,
		meta_data;

    var currentDataOffset = 0;
    
    var size;
    {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", theURL, false);  // synchronous request
        xhr.send(null);
        size = xhr.getResponseHeader("Content-Length");
    }
   

	VERIFY = isVerify || false;

	/** @memberOf decode */
	function read_callback_fn(bufferSize){

		console.log('  decode read callback, buffer bytes max=', bufferSize);

		var end = currentDataOffset === size? -1 : Math.min(currentDataOffset + bufferSize, size);

		var _buffer;
		var numberOfReadBytes;
		if(end !== -1){
            var xhr = new XMLHttpRequest();
            
            xhr.open("GET", theURL, false);  // synchronous request
            xhr.responseType = 'arraybuffer';
            xhr.setRequestHeader('Range', 'bytes=' + currentDataOffset + '-' + (end-1));
            xhr.send(null);
            let todec = new Uint8Array(xhr.response.byteLength);
            todec.set(new Uint8Array(xhr.response));
            _buffer = todec;            
            //_buffer = binData.subarray(currentDataOffset, end);
			numberOfReadBytes = end - currentDataOffset;

			currentDataOffset = end;
		} else {
			numberOfReadBytes = 0;
		}

		return {buffer: _buffer, readDataLength: numberOfReadBytes, error: false};
	}

	/** @memberOf decode */
	function write_callback_fn(buffer){
		// buffer is the decoded audio data, Uint8Array
//	    console.log('decode write callback', buffer);
		decData.push(buffer);
	}

	/** @memberOf decode */
	function metadata_callback_fn(data){
		console.info('meta data: ', data);
		meta_data = data;
	}

	/** @memberOf decode */
	function error_callback_fn(err, errMsg){
		console.log('decode error callback', err, errMsg);
	}

	// check: is file a compatible flac-file?
	/*if (flac_file_processing_check_flac_format(binData, isOgg) == false){
		var container = isOgg? 'OGG/' : '';
		return {error: 'Wrong '+container+'FLAC file format', status: 1};
	}*/

	// init decoder
	flac_decoder = Flac.create_libflac_decoder(VERIFY);

	if (flac_decoder != 0){
		var init_status = Flac.init_decoder_stream(flac_decoder, read_callback_fn, write_callback_fn, error_callback_fn, metadata_callback_fn, isOgg);
		flac_ok &= init_status == 0;
		console.log("flac init     : " + flac_ok);//DEBUG
	} else {
		var msg = 'Error initializing the decoder.';
		console.error(msg);
		return {error: msg, status: 1};
	}

	// decode flac data

	var isDecodePartial = true;
	var flac_return = 1;
	if(!isDecodePartial){
		//variant 1: decode stream at once / completely

		flac_return &= Flac.FLAC__stream_decoder_process_until_end_of_stream(flac_decoder);
		if (flac_return != true){
			console.error('encountered error during decoding data');
		}

	} else {
		//variant 2: decode data chunks

		//request to decode data chunks until end-of-stream is reached:
		var state = 0;
		while(state <= 3 && flac_return != false){

			flac_return &= Flac.FLAC__stream_decoder_process_single(flac_decoder);
			//need to check decoder state: state == 4: end of stream ( > 4: error)
			state = Flac.FLAC__stream_decoder_get_state(flac_decoder);
		}

		flac_ok &= flac_return != false
	}

	// finish Decoding
	flac_ok &= Flac.FLAC__stream_decoder_finish(flac_decoder);
	if(flac_ok != 1){
		//TODO get/return description for state
		flac_ok = Flac.FLAC__stream_decoder_get_state(flac_decoder);
	}

	Flac.FLAC__stream_decoder_delete(flac_decoder);

	return {metaData: meta_data, status: flac_ok};
}


/*
const FLACURLToFloat32 = async (theURL) => {
    while(typeof Flac === 'undefined') {
        console.log('FLACToFloat32, no Flac sleeping 5');
        await sleep(5);
    }
    if(!Flac.isReady()) {
        await waitForEvent(Flac, 'ready');
    }
    let decData = [];
    let result = decodeFlacURL(theURL, decData, true);
    // decData's arrays have little endian sample values
    //console.log('decoded data array: ', decData);
    if(result.error){
        console.log(result.error);
        return;
    }
    let metaData = result.metaData;
        if(metaData){
                for(var n in metaData){
                        console.log( n + ' ' +  metaData[n]);
                }
    }

    let chanData = [];
    let chanIndex = [];
    for(let i = 0; i < metaData.channels; i++) {
        chanData[i] = new Float32Array(metaData.total_samples);
        chanIndex[i] = 0;
    }

    if(metaData.bitsPerSample == 16) {
        for(let i = 0; i < decData.length; i++) {
            for(let j = 0; j < metaData.channels; j++) {
                for(let k = 0; k < decData[i][j].length; k+=2) {
                    chanData[j][chanIndex[j]] = toint16(decData[i][j][k], decData[i][j][k+1]) / 0x7FFF;
                    if((chanData[j][chanIndex[j]] > 1) || (chanData[j][chanIndex[j]] < -1)) {
                        console.log('CLAMPING FLOAT');
                        if(chanData[j][chanIndex[j]] > 1) chanData[j][chanIndex[j]] = 1;
                        if(chanData[j][chanIndex[j]] < -1) chanData[j][chanIndex[j]] = -1;
                    }
                    chanIndex[j]++;
                }
            }
        }
    }
    else if(metaData.bitsPerSample == 24) {
        for(let i = 0; i < decData.length; i++) {
            for(let j = 0; j < metaData.channels; j++) {
                for(let k = 0; k < decData[i][j].length; k+=4) {
                    //chanData[j][chanIndex[j]] = toint24(decData[i][j][k], decData[i][j][k+1],decData[i][j][k+2]) / 0x7FFFFF;
                    // the above works, but libflac js outputs int32s, so this can be done ~ cheaper with no branching conversion
                    chanData[j][chanIndex[j]] = toint32(decData[i][j][k], decData[i][j][k+1],decData[i][j][k+2], decData[i][j][k+3]) / 0x7FFFFF;
                    //chanData[j][chanIndex[j]] *= 0.1; // volume by scaling float32
                    if((chanData[j][chanIndex[j]] > 1) || (chanData[j][chanIndex[j]] < -1)) {
                        console.log('CLAMPING FLOAT');
                        if(chanData[j][chanIndex[j]] > 1) chanData[j][chanIndex[j]] = 1;
                        if(chanData[j][chanIndex[j]] < -1) chanData[j][chanIndex[j]] = -1;
                    }
                    chanIndex[j]++;
                }
            }
        }
    }
    else {
        throw(metaData.bitsPerSample + " bps not handled");
    }

    return [metaData, chanData];
};
*/

