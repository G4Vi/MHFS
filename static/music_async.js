function loadScripts(scriptUrls, cb){
	function loadNext(err){
		if(err){
			console.error('error ', err);
			return cb(err);
		}
		scriptUrls.length? loadScripts(scriptUrls, cb) : cb(null);
	}
	var s = scriptUrls.shift();
	addScript(s, loadNext);
}

function addScript(scriptUrl, cb) {

	var head = document.getElementsByTagName('head')[0];
	var script = document.createElement('script');
	script.type = 'text/javascript';
	script.src = scriptUrl;
	script.onload = function() {
		cb && cb.call(this, null);
	};
	script.onerror = function(e) {
		var msg = 'Loading script failed for "' + scriptUrl + '" ';
		cb? cb.call(this, msg + e) : console.error(msg, e);
	};
	head.appendChild(script);
}


let theParams = new URLSearchParams(window.location.search);

if(!theParams.get('noworker')) {
    window.MusicWorker = new Worker('static/worker_music.js');

    const _FlacToWav = async(thedata) => {
        let myp = new Promise(function(resolve) {       
            MusicWorker.onmessage = function(event) {
                if(event.data.message == 'FlacToWav') {
                    resolve(event.data.wav);
                }           
            };
            MusicWorker.postMessage({'message' : 'FlacToWav',  'flac': thedata.buffer}, [thedata.buffer]);       
        });
    
       let res = await myp;
       return res;
    };
    
    Object.defineProperty(window, 'FlacToWav', {
        value: _FlacToWav,
        configurable: false,
        writable: false
    });
    
    const _FLACToFloat32 = async(thedata) => {
        let myp = new Promise(function(resolve) {       
            MusicWorker.onmessage = function(event) {
                if(event.data.message == 'FLACToFloat32') {
                    let res = [];
                    res[0] = event.data.metadata;
                    res[1] = [];
                    event.data.chandata.forEach( elm => res[1].push(new Float32Array(elm)));                     
                    resolve(res);
                }           
            };
            MusicWorker.postMessage({'message' : 'FLACToFloat32',  'flac': thedata.buffer}, [thedata.buffer]);       
        });
    
       let res = await myp;
       return res;
    };
    
    Object.defineProperty(window, 'FLACToFloat32', {
        value: _FLACToFloat32,
        configurable: false,
        writable: false
    });
}
else {
    loadScripts(['static/music_libflac.js'], function(){});
}

