let MainAudioContext;
let GainNode;
let NextBufferTime;
let BUFFER_S = 0.250;
let TRACK;

function CreateAudioContext(options) {
    let mycontext = (window.hasWebKit) ? new webkitAudioContext(options) : (typeof AudioContext != "undefined") ? new AudioContext(options) : null;
    GainNode = mycontext.createGain();
    GainNode.connect(mycontext.destination);
    return mycontext;
}

function MainAudioLoop() {
    if (NextBufferTime <= MainAudioContext.currentTime) {           
        NextBufferTime = MainAudioContext.currentTime + BUFFER_S;
    }
    // don't queue if we have plenty buffered
    let timeToQueue = Math.min(10 - (NextBufferTime - MainAudioContext.currentTime), 0.100);
    if(timeToQueue <  0.100) {
        return;
    }

    let timeToActuallyQueue = Math.min(timeToQueue, TRACK.duration-TRACK.queued)
    if(timeToActuallyQueue <= 0 ) {
        return;
    }

}

async function Track(name) {
    let nwdrflac = await NetworkDrFlac_open(name);
    if(!nwdrflac) {
        console.error('failed to NetworkDrFlac_open');
        return;
    }
    return {
        'nwdrflac' : nwdrflac,
        'duration' : nwdrflac.totalPCMFrameCount / nwdrflac.sampleRate,
        'queued'   : 0
    };
}

MainAudioContext = CreateAudioContext({'sampleRate' : 44100 });
NextBufferTime = MainAudioContext.currentTime;



// BEGIN UI handlers
var prevbtn    = document.getElementById("prevbtn");
var sktxt      = document.getElementById("seekfield");
var seekbar    = document.getElementById("seekbar");
var ppbtn      = document.getElementById("ppbtn");
var rptrackbtn = document.getElementById("repeattrack");
var curtimetxt = document.getElementById("curtime");
var endtimetxt = document.getElementById("endtime");
var nexttxt    = document.getElementById('next_text');
var prevtxt    = document.getElementById('prev_text');
var playtxt    = document.getElementById('play_text');
var dbarea     = document.getElementById('musicdb');
rptrackbtn.addEventListener('change', function(e) {         
   
 });
 
 ppbtn.addEventListener('click', function (e) {
     if (ppbtn.textContent == 'PAUSE') {
         MainAudioContext.suspend();           
         ppbtn.textContent = 'PLAY';                        
     }
     else if (ppbtn.textContent == 'PLAY') {
         MainAudioContext.resume();
         ppbtn.textContent = 'PAUSE';
     }
 });
 
 seekbar.addEventListener('mousedown', function (e) {

 });
 
 seekbar.addEventListener('change', function (e) {
     
 });
 
 prevbtn.addEventListener('click', function (e) {

 });
 
 nextbtn.addEventListener('click', function (e) {        

 });
 
 document.getElementById("volslider").addEventListener('input', function(e) {
     GainNode.gain.setValueAtTime(e.target.value, MainAudioContext.currentTime); 
 });
 
 dbarea.addEventListener('click', function (e) {
     if (e.target !== e.currentTarget) {
         console.log(e.target + ' clicked with text ' + e.target.textContent);
         if (e.target.textContent == 'Queue') {
             path = GetItemPath(e.target.parentNode.parentNode);
             console.log("Queuing - " + path);
             if (e.target.parentNode.tagName == 'TD') {
                 queueTrack(path);
             }
             else {
                 var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                 queueTracks(tracks);
             }
             e.preventDefault();
         }
         else if (e.target.textContent == 'Play') {
             path = GetItemPath(e.target.parentNode.parentNode);
             console.log("Playing - " + path);
             if (e.target.parentNode.tagName == 'TD') {
                 playTrackNow(path);
             }
             else {
                 var tracks = GetChildTracks(path, e.target.parentNode.parentNode.parentNode.childNodes);
                 playTracksNow(tracks);
             }
             e.preventDefault();
         }
     }
     e.stopPropagation();
 });
 // End ui handlers