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
//importScripts(libFile, 'libflac.js/decode-func.js', 'libflac.js/util/data-util.js');

loadScripts([libFile, startPath+'libflac.js/decode-func.js', startPath+'libflac.js/util/data-util.js'], function(){});

const sleep = m => new Promise(r => setTimeout(r, m));

const waitForEvent = (obj, event) => {
return new Promise(function(resolve) {
    obj.on(event, function() {
        resolve();
    });
});
};

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
