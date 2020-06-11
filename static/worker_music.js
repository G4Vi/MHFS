'use strict'
self.FLAC_SCRIPT_LOCATION = 'libflac.js/dist/';
// importScripts('libflac.js/util/check-support.js');

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
var libFile = self.FLAC_SCRIPT_LOCATION.replace('//','/') + lib;
importScripts(libFile, 'libflac.js/decode-func.js', 'libflac.js/util/data-util.js');

const sleep = m => new Promise(r => setTimeout(r, m));

function waitForEvent(obj, event) {
    return new Promise(function(resolve) {
        obj.on(event, function() {
            resolve();
        });
    });
}

function toWav(metadata, decData) {
    let samples = interleave(decData, metadata.channels, metadata.bitsPerSample);
	let dataView = encodeWAV(samples, metadata.sampleRate, metadata.channels, metadata.bitsPerSample);
    return dataView.buffer;
}

async function FlacToWav(thedata) {
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
}

async function convertToWav(e) {
    let ftwdata = await FlacToWav(new Uint8Array(e.data.flac));
    let result = { 'message' : 'FlacToWav', 'wav' : ftwdata};
    self.postMessage(result, [ftwdata]);
    console.log(ftwdata ); 
}

self.addEventListener('message', function(e) {
    if(e.data.message == 'FlacToWav') { 
        convertToWav(e);
    }
}, false);


