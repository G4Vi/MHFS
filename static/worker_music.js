'use strict'
importScripts('music_libflac.js');

async function convertToWav(e) {
    let ftwdata = await FlacToWav(new Uint8Array(e.data.flac));
    let result = { 'message' : 'FlacToWav', 'wav' : ftwdata};
    self.postMessage(result, [ftwdata]);
    console.log(ftwdata ); 
}

async function convertToFloat32(e) {
    let ftwdata = await FLACToFloat32(new Uint8Array(e.data.flac));
    let bufas = [];
    ftwdata[1].forEach(elm => bufas.push(elm.buffer));
    let result = { 'message' : 'FLACToFloat32', 'metadata' : ftwdata[0], 'chandata' : bufas};
    
    self.postMessage(result, bufas);
    console.log(ftwdata ); 
}

self.addEventListener('message', function(e) {
    if(e.data.message == 'FlacToWav') { 
        convertToWav(e);
    }
    else if(e.data.message == 'FLACToFloat32') {
        convertToFloat32(e);
    }
}, false);

