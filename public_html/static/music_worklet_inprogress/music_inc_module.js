import {default as MHFSPlayer} from './player/mhfsplayer.js'

// times in seconds
const AQMaxDecodedTime = 20;    // maximum time decoded, but not queued
const DesiredChannels = 2;
const DesiredSampleRate = 44100;

let SBAR_UPDATING = 0;

(async function () {

Number.prototype.toHHMMSS = function () {
    var sec_num = Math.floor(this); //parseInt(this, 10); // don't forget the second param
    var hours = Math.floor(sec_num / 3600);
    var minutes = Math.floor((sec_num - (hours * 3600)) / 60);
    var seconds = sec_num - (hours * 3600) - (minutes * 60);
    var str;
    if (hours > 0) {
        if (hours < 10) { hours = "0" + hours; }
        str = hours + ':'
    }
    else {
        str = '';
    }
    //if (minutes < 10) {minutes = "0"+minutes;}
    if (seconds < 10) { seconds = "0" + seconds; }
    return str + minutes + ':' + seconds;
}

const SetCurtimeText = function(seconds) {   
    curtimetxt.value = seconds.toHHMMSS();
}

const SetEndtimeText = function(seconds) {   
    endtimetxt.value = seconds.toHHMMSS();
}

const imgSetArt = function(artelm, arturl) {
    if(arturl) {
        const onArtElmError = function() {
            artelm.removeEventListener('error', onArtElmError);
            artelm.src = MHFSPLAYER.backuparturl();
        };
        artelm.addEventListener('error', onArtElmError);
        artelm.setAttribute("src", arturl);
    }
    else {
        artelm.setAttribute("src", MHFSPLAYER.backuparturl());
    }
}

let ArtCnt = 0;
const TrackHTML = function(track, isLoading) {
    const trackdiv = document.createElement("div");
    trackdiv.setAttribute('class', 'trackdiv');
    if(track) {
        const arturl = MHFSPLAYER.getarturl(track);
        const artelm = document.createElement("img");
        artelm.setAttribute("class", "albumart");
        artelm.setAttribute("alt", "album art");
        imgSetArt(artelm, arturl);

        // we want to show the art big when clicked
        // if the big image or any album art is clicked, hide the big image
        // if the album art is a different image, show that instead
        const fsimg = document.createElement("img");
        fsimg.setAttribute("class", "fsalbumart");
        imgSetArt(fsimg, arturl);
        fsimg.setAttribute("alt", "album art");
        const fsimgid = "a"+ArtCnt;
        ArtCnt++;
        fsimg.setAttribute("id", fsimgid);
        fsimg.addEventListener('click', function(ev) {
            this.remove();
        });
        artelm.addEventListener('click', function(ev) {
            const fsimages = document.getElementsByClassName("fsalbumart");
            if(fsimages[0]) {
                const isSameImage = fsimages[0].id === fsimgid;
                fsimages[0].remove();
                if(isSameImage) {
                    return;
                }
            }
            document.getElementsByTagName('body')[0].appendChild(fsimg);
        });

        trackdiv.appendChild(artelm);
    }
    let trackname = track ? track.trackname : '';
    if(isLoading) {
        trackname += ' {LOADING}';
    }
    const metadiv = document.createElement("div");
    metadiv.setAttribute('class', 'trackmetadata')
    const textnode = document.createTextNode(trackname);
    metadiv.appendChild(textnode)
    trackdiv.appendChild(metadiv);
    return trackdiv;
}


let GuiNextTrack;
let GuiCurrentTrack;
let GuiCurrentTrackWasLoading;
let GuiPrevTrack;

const UpdateTrackImage = function(track) {
    const guitracks = [GuiPrevTrack, GuiCurrentTrack, GuiNextTrack];
    for( const gt of guitracks) {
        if(!gt) continue;
        if(gt.trackname !== track.trackname) continue;
        let boxelm;
        if(gt === GuiPrevTrack) {
            boxelm = prevtxt;
        }
        else if(gt === GuiCurrentTrack) {
            boxelm = playtxt;
        }
        else if(gt === GuiNextTrack) {
            boxelm = nexttxt;
        }
        const artelm = boxelm.querySelector('.albumart');
        artelm.src = MHFSPLAYER.getarturl(track);
        // todo fsart?
    }
}

const SetNextTrack = function(track, isLoading) {
    if(!GuiNextTrack || (track !== GuiNextTrack)) {
        GuiNextTrack = track;
        nexttxt.replaceChildren(TrackHTML(track, isLoading));
    }
}

const SetPrevTrack = function(track, isLoading) {
    if(!GuiPrevTrack || (track !== GuiPrevTrack)) {
        GuiPrevTrack = track;
        prevtxt.replaceChildren(TrackHTML(track, isLoading));
    }
}

const SetPlayTrack = function(track, isLoading) {
    if(!GuiCurrentTrack || (track !== GuiCurrentTrack)) {
        GuiCurrentTrack = track;
        playtxt.replaceChildren(TrackHTML(track, isLoading));
    }
    else if(isLoading !== GuiCurrentTrackWasLoading) {
        let trackname = track ? track.trackname : '';
        if(isLoading) {
            trackname += ' {LOADING}';
        }
        playtxt.getElementsByClassName("trackmetadata")[0].textContent = trackname;
    }
    GuiCurrentTrackWasLoading = isLoading;
}

const SetSeekbarValue = function(seconds) {
    seekbar.value = seconds;           
}

const InitPPText = function(playerstate) {
    if(playerstate === "suspended") {
        ppbtn.textContent = "PLAY";
    }
    else if(playerstate === "running"){
        ppbtn.textContent = "PAUSE";
    }
}

const onQueueUpdate = function(track) {
    if(track) {
        SetPrevTrack(track.prev);
        SetPlayTrack(track);
        SetNextTrack(track.next);
    }
};

const geturl = function(trackname) {
    let url = '../../music_dl?name=' + encodeURIComponent(trackname);
    //url  += '&max_sample_rate=' + DesiredSampleRate;
    //url  += '&fmt=flac';
    return url;
}

const getarturl = function(trackname) {
    let artpathname = trackname;
    const lastSlash = artpathname .lastIndexOf('/');
    if(lastSlash !== -1) {
        artpathname = artpathname.substring(0, lastSlash);
    }
    const url = '../../music_art?name=' + encodeURIComponent(artpathname);
    return url;
}

const onTrackEnd = function(nostart) {
    SBAR_UPDATING = 0;
    if(nostart) {
        SetCurtimeText(0);
        SetSeekbarValue(0);
        InitPPText('suspended');
    }
};


const MHFSPLAYER = await MHFSPlayer({'sampleRate' : DesiredSampleRate, 'channels' : DesiredChannels, 'maxdecodetime' : AQMaxDecodedTime, 'gui' : {
    'OnQueueUpdate'   : onQueueUpdate,
    'geturl'          : geturl,
    'getarturl'       : getarturl,
    'SetCurtimeText'  : SetCurtimeText,
    'SetEndtimeText'  : SetEndtimeText,
    'SetSeekbarValue' : SetSeekbarValue,
    'SetPrevTrack'    : SetPrevTrack,
    'SetPlayTrack'    : SetPlayTrack,
    'SetNextTrack'    : SetNextTrack,
    'InitPPText'      : InitPPText,
    'onTrackEnd'      : onTrackEnd,
    'UpdateTrackImage' : UpdateTrackImage
}});

const prevbtn    = document.getElementById("prevbtn");
const seekbar    = document.getElementById("seekbar");
const ppbtn      = document.getElementById("ppbtn");
const curtimetxt = document.getElementById("curtime");
const endtimetxt = document.getElementById("endtime");
const nexttxt    = document.getElementById('next_text');
const prevtxt    = document.getElementById('prev_text');
const playtxt    = document.getElementById('play_text');
const dbarea     = document.getElementById('musicdb');

// BEGIN UI handlers
document.getElementById('playback_order').addEventListener('change', function(e){
    MHFSPLAYER.pborderchange(e.target.value);
});
 
 ppbtn.addEventListener('click', function (e) {
    if ((ppbtn.textContent == 'PAUSE')) {
        MHFSPLAYER.pause();         
        ppbtn.textContent = 'PLAY';                        
    }
    else if ((ppbtn.textContent == 'PLAY')) {
        MHFSPLAYER.play();
        ppbtn.textContent = 'PAUSE';
    }
 });
 
 seekbar.addEventListener('mousedown', function (e) {
    if(!SBAR_UPDATING) {
                
    }
    SBAR_UPDATING = 1;
 });
 
 seekbar.addEventListener('change', function (e) {    
    if(!SBAR_UPDATING) {
        return;
    }
    SBAR_UPDATING = 0;
    MHFSPLAYER.seek(e.target.value);                
 });

 //seekbar.addEventListener('mouseup', function(e) {
 //   SBAR_UPDATING = 0;
 //});
 
 prevbtn.addEventListener('click', function (e) {
    MHFSPLAYER.prev();        
 });
 
 nextbtn.addEventListener('click', function (e) {        
    MHFSPLAYER.next();    
 });
 
 const volslider = document.getElementById("volslider");
 volslider.addEventListener('input', function(e) {
    MHFSPLAYER.setVolume(e.target.value);
 });

 document.addEventListener('keydown', function(event) {
    if(event.key === ' ') {
        event.preventDefault();
        event.stopPropagation();
        ppbtn.click();
    }
    else if(event.key === 'ArrowRight') {
        event.preventDefault();
        event.stopPropagation();
        nextbtn.click();
    }
    else if(event.key === 'ArrowLeft') {
        event.preventDefault();
        event.stopPropagation();
        prevbtn.click();
    }
    else if(event.key === '+') {
        event.preventDefault();
        event.stopPropagation();
        volslider.stepUp(5);
        MHFSPLAYER.setVolume(volslider.value);
    }
    else if(event.key === '-') {
        event.preventDefault();
        event.stopPropagation();
        volslider.stepDown(5);
        MHFSPLAYER.setVolume(volslider.value);
    }
 });

 document.addEventListener('keyup', function(event) {
    if((event.key === ' ') || (event.key === 'ArrowRight') ||(event.key === 'ArrowLeft') || (event.key === '+') || (event.key === '-')) {
        event.preventDefault();
        event.stopPropagation();
    }
 });

 const GetItemPath = function (elm) {
    var els = [];
    var lastitem;
    do {
        var elmtemp = elm;
        while (elmtemp.firstChild) {
            elmtemp = elmtemp.firstChild;
        }
        if (elmtemp.textContent != lastitem) {
            lastitem = elmtemp.textContent;
            els.unshift(elmtemp.textContent);
        }

        elm = elm.parentNode;
    } while (elm.id != 'musicdb');
    var path = '';
    //console.log(els);
    els.forEach(function (part) {
        path += part + '/';
    });
    path = path.slice(0, -1);
    return path;
}

const GetChildTracks = function(path, nnodes) {
    path += '/';
    var nodes = [];
    for (var i = nnodes.length; i--; nodes.unshift(nnodes[i]));
    var tracks = [];
    nodes.splice(0, 1);
    nodes.forEach(function (node) {
        if (node.childNodes.length == 1) {
            var newnodes = node.childNodes[0].childNodes[0].childNodes[0].childNodes;
            var nodearr = [];
            for (var i = newnodes.length; i--; nodearr.unshift(newnodes[i]));
            var felm = nodearr[0].childNodes[0].textContent;
            var ttracks = GetChildTracks(path + felm, nodearr);
            tracks = tracks.concat(ttracks);
        }
        else {
            tracks.push(path + node.childNodes[0].childNodes[0].textContent);
        }

    });
    return tracks;
}

// play or queue clicked tracks
dbarea.addEventListener('click', function (e) {
    do {
        if(e.target.tagName !== 'A') break;
        let operation;
        if(e.target.textContent === 'Queue') {
            operation = MHFSPLAYER.queuetracks;
        }
        else if(e.target.textContent === 'Play'){
            operation = MHFSPLAYER.playtracks;
        }
        else {
            break;
        }
        const path = GetItemPath(e.target.parentNode.parentNode);
        if (e.target.parentNode.tagName === 'TD') {
            operation([path]);
        }
        else if(e.target.parentNode.tagName === 'TH')  {
            const tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
            operation(tracks);
        }
        else {
            break;
        }
        e.preventDefault();
    } while(0);
    e.stopPropagation();
 });
 // End ui handlers



const GraphicsLoop = function() {
    if(SBAR_UPDATING) {        
        
    }
    // display the tracktime
    else if(MHFSPLAYER.isplaying()) {        
        const curTime = MHFSPLAYER.tracktime();        
        SetCurtimeText(curTime);
        SetSeekbarValue(curTime);
    }    
    window.requestAnimationFrame(GraphicsLoop);
};
window.requestAnimationFrame(GraphicsLoop);
})();

/*
const AQDecTime = function() {
    let dectime = 0;  
    
    for(let i = 0; i < MHFSPLAYER.AudioQueue.length; i++) {
        for(let j = 0; j < MHFSPLAYER.AudioQueue[i].buffers.length; j++) {
            dectime += MHFSPLAYER.AudioQueue[i].buffers[j].buffer.length;
        }        
    }    

    return dectime; 
}

const QState = {
    'NO_TRACK'   : 1,
    'TRACK_OPEN' : 2,
    'TRACK_SEEK': 3,
    'YIELD      : 4,
    'YEILD_FULL : 5,  
    'TRACK_READ' : 6
};

let QueueInfo;
/*
track,
seektime,
decoder,
pbtrack
on_decode_complete,
abortcontroller


const DECODER;
const DoQueue = function(qi) {
    if(qi !== QueueInfo) {
        return;
    }

    const qi = QueueInfo;
    if(qi.state === QState.NO_TRACK) {
        if(!qi.track) return;
        qi.state = QState.TRACK_OPEN;
    }
    const track = qi.track;
    if(qi.state === QState.TRACK_OPEN) {
        DECODER.openURL(track.url, mysignal).then((resolve) => {
            qi.state = QState.TRACK_SEEK;
            DoQueue(qi);
        });
        else
        qi.state = QState.NEW_TRACK
        return;
    }
    if(qi.state === QState.TRACK_SEEK){
        
    }
};

const SetQueue = function(track, seektime) {
    if(QueueInfo) {
        QueueInfo.on_async_complete = function(){};
        QueueInfo.abortcontroller.abort();        
    }
    QueueInfo = {
        'track' : track,
        'seektime' : seektime,
        'abortcontroller' : new AbortController()
    };    
};


let PTrackUrlParams;
const _BuildPTrack = function() {
    PTrackUrlParams = new URLSearchParams();
    if (MAX_SAMPLE_RATE) PTrackUrlParams.append('max_sample_rate', MAX_SAMPLE_RATE);
    if (BITDEPTH) PTrackUrlParams.append('bitdepth', BITDEPTH);
    if (USESEGMENTS) PTrackUrlParams.append('segments', USESEGMENTS);
    if (USEINCREMENTAL) PTrackUrlParams.append('inc', USEINCREMENTAL);
    Tracks.forEach(function (track) {
        PTrackUrlParams.append('ptrack', track.trackname);
    });
    
   for(let track = MHFSPLAYER.Tracks_HEAD; track; track = track.next) {
    PTrackUrlParams.append('ptrack', track.trackname);
}
}

const BuildPTrack = function() {
 // window.history.replaceState is slow :(
 setTimeout(function() {
 _BuildPTrack();
 var urlstring = PTrackUrlParams.toString();
 if (urlstring != '') {
     console.log('replace state begin');
     //window.history hangs the page
     //window.history.replaceState('playlist', 'Title', '?' + urlstring);        
     console.log('replace state end');
 }
 }, 5000);
}


// Main

// queue the tracks in the url
let orig_ptracks = urlParams.getAll('ptrack');
if (orig_ptracks.length > 0) {
 QueueTracks(orig_ptracks);
}

const DataCallback = function(pOutput, frameCount) {    
    const atime = MHFSPLAYER.ac.currentTime;
    let qtime = MHFSPLAYER._ab._writer._rb._capacity-frameCount;    
    
    let outputOffset = 0;

    // Add a 100 ms delay if we fell to far behind
    if(qtime < 4410) {
        const toskip = Math.min(frameCount, 4410);
        outputOffset += toskip;
        frameCount -= toskip;
        qtime += toskip;
    }        
    
    for(let aqindex = 0; MHFSPLAYER.AudioQueue[aqindex]; aqindex++) {
        // no more data to write, done
        if(frameCount === 0) return;
        
        const item = MHFSPLAYER.AudioQueue[aqindex];
        // skip past queued items
        if(item.queued) continue;
        const toread = Math.min(item.sampleCount, frameCount);
        // no more data to read, done
        if(toread === 0) return;
        // add in more audio
        MHFSPLAYER.decoderdatareader.read(pOutput, toread, outputOffset);
        outputOffset += toread;        
        frameCount -= toread;
        item.sampleCount -= toread;
        ProcessTimes(item, toread, atime+(qtime/MHFSPLAYER.sampleRate));
        item.queued = item.donedecode && (item.sampleCount === 0);
        qtime += toread;
        // item not done, done
        if(!item.queued) return;
    }    
};

const PumpAudioQueueB = async function() {
    while(1) {
        const space = MHFSPLAYER._ab.getspace();
        if(space > 0) {
            // TEMP
            let arrs = [];
            for(let i = 0; i < MHFSPLAYER.channels; i++) {
                arrs[i] = new Float32Array(space);
            }
            DataCallback(arrs, space);
            MHFSPLAYER._ab.write(arrs);        
        }
        const mysignal = MHFSPLAYER.FACAbortController.signal;
        await abortablesleep(250, mysignal);
    }   
};

*/

/*
const TQueue = function() {
    let that = {};
    that._items = [];
    that._isrunning = 0;
    
    that.push = async function(item) {
        that._items.push(item);
        if(!that._isrunning) {
            that._isrunning = 1;
            while(let item = that._items.shift()) {
                await item;                
            }
            that._isrunning = 0;
        }        
    };
    
    
    return that;
};
*/


/*
let AudioTime = 0;
const ProcessFrames = function(aqitem, newlength, frametime) {
    if(aqitem.endTime && (AudioTime > aqitem.endTime)) {
        aqitem.skiptime += (aqitem.endTime - aqitem._starttime);
        aqitem.starttime = null;
    }
    if(!aqitem.starttime) {
        aqitem.starttime = time - aqitem.skiptime;
        aqitem._starttime = time;
        aqitem.needsstart = 1;  
    }

    aqitem.endTime = time + (struct_buffer.buffer.length/MHFSPLAYER.ac.sampleRate);
};

const DataCallback = function(pOutput, frameCount) {    
    queuetime = AudioTime + TotalFrames
    AudioTime += frameCount;
    let outputOffset = 0;

    // Add a 100 ms delay if we fell to far behind
    if((queuetime - AudioTime) < 4410) {
        const toskip = Math.min(frameCount, 4410);
        outputOffset += toskip;
        frameCount -= toskip;
        queuetime += toskip;
    }        
    
    for(aqindex = 0; MHFSPLAYER.AudioQueue[aqindex]; aqindex++) {
        // no more data to write, done
        if(frameCount === 0) return;
        
        const item = MHFSPLAYER.AudioQueue[aqindex];
        // skip past queued items
        if(item.queued) continue;
        const toread = Math.min(item.sampleCount, frameCount);
        // no more data to read, done
        if(toread === 0) return;
        // add in more audio
        AudioRingBuffer.read(pOutput, toread, outputOffset);
        outputOffset += toread;        
        frameCount -= toread;
        item.sampleCount -= toread;
        ProcessFrames(item, toread, queuetime);
        item.queued = item.donedecode && (item.sampleCount === 0);
        queuetime += toread;
        // item not done, done
        if(!item.queued) return;
    }    
};
*/