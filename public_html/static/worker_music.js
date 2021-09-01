'use strict'
importScripts('music_libflac.js', 'music_drflac.js');

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

async function convertURLToFloat32(e) {
    let ftwdata = await FLACURLToFloat32('../'+e.data.url, e.data.starttime, e.data.duration);
    let bufas = [];
    ftwdata[1].forEach(elm => bufas.push(elm.buffer));
    let result = { 'message' : 'FLACURLToFloat32', 'metadata' : ftwdata[0], 'chandata' : bufas};    
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
    else if(e.data.message == 'FLACURLToFloat32') {
        convertURLToFloat32(e);
    }
}, false);


