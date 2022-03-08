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

document.getElementById("artview").addEventListener('click', function(ev) {
    document.getElementById("artview").style.display = 'none';
});

const clamp = (num, min, max) => Math.min(Math.max(num, min), max);

const WindowManager = function() {
    const that = {};

    // adds a window to the window stack and updates Z
    const AddWindow = function(awindow) {
        let zindexToUse = 2;
        if(that.windowstack) {
            that.windowstack.domwindow.getElementsByClassName("movableWindowTitleBar")[0].style.backgroundColor = "#0095FF";
            zindexToUse = parseInt(that.windowstack.domwindow.style.zIndex)+1;
            awindow.prev = that.windowstack;
            that.windowstack.next = awindow;
        }
        that.windowstack = awindow;
        awindow.domwindow.getElementsByClassName("movableWindowTitleBar")[0].style.backgroundColor = "#0000FF";
        awindow.domwindow.style.zIndex = zindexToUse;
    };

     // removes a window to the window stack and updates Z
    const RemoveWindow = function(awindow) {
        let nextwindow = awindow.next;
        const prevwindow = awindow.prev;
        // remove awindow from the list
        if(prevwindow) {
            awindow.prev = undefined;
            prevwindow.next = nextwindow;
        }
        if(nextwindow) {
            awindow.next = undefined;
            nextwindow.prev = prevwindow;
        }
        else {
            that.windowstack = prevwindow;
        }
        // move the next windows down
        for(; nextwindow; nextwindow = nextwindow.next) {
            nextwindow.domwindow.style.zIndex--;
        }
    };

    // Creates Window, Adds to window stack, and shows
    that.CreateMovableWindow = function(titleText, contentElm) {
        const header = document.getElementsByClassName("header")[0];
        const footer = document.getElementsByClassName("footer")[0];
        let pointerX;
        let pointerY;
        const MovableWindowOnMouseDown = function(e) {
            e = e || window.event;
            e.preventDefault();
            pointerX = e.clientX;
            pointerY = e.clientY;
            document.onmouseup = MovableWindowRelease;
            document.onmousemove = MovableWindowMove;
        };

        const MovableWindowMove = function(e) {
            e = e || window.event;
            e.preventDefault();

            const realPointerX = e.clientX;
            const realPointerY = e.clientY;

            let xDelta = realPointerX - pointerX;
            let yDelta = realPointerY - pointerY;

            // set the element's new position:
            // pointerX and pointerY can only be valid positions for targeted window
            // clamp the delta to avoid moving the window offscreen
            if(xDelta !== 0) {
                // If the image was resized out of bounds, fix it
                const csswidthstr = movableWindow.style.width;
                if(csswidthstr) {
                    const csswidth = parseInt(csswidthstr);
                    const maxwidth = document.getElementsByTagName("body")[0].offsetWidth - movableWindow.offsetLeft;
                    if(csswidth > maxwidth) {
                        movableWindow.style.width = maxwidth;
                    }
                }

                const minXDelta = 0-movableWindow.offsetLeft;
                const maxXDelta = (document.getElementsByTagName("body")[0].offsetWidth - movableWindow.offsetWidth) - movableWindow.offsetLeft;
                xDelta = clamp(xDelta, minXDelta, maxXDelta);
                const newleft = movableWindow.offsetLeft + xDelta;
                movableWindow.style.maxWidth  = document.getElementsByTagName("body")[0].offsetWidth - newleft;
                movableWindow.style.left = newleft;
                pointerX += xDelta;
            }
            if(yDelta !== 0) {
                // If the image was resized out of bounds, fix it
                const cssheightstr = movableWindow.style.height;
                if(cssheightstr) {
                    const cssheight = parseInt(cssheightstr);
                    const maxheight = (footer.offsetTop - movableWindow.offsetTop);
                    if(cssheight > maxheight) {
                        movableWindow.style.height = maxheight;
                    }
                }

                const minYDelta = header.offsetHeight - movableWindow.offsetTop;
                const maxYDelta = footer.offsetTop - (movableWindow.offsetTop+movableWindow.offsetHeight);
                yDelta = clamp(yDelta, minYDelta, maxYDelta);
                const newtop = movableWindow.offsetTop + yDelta;
                movableWindow.style.top = newtop;
                movableWindow.style.maxHeight = (footer.offsetTop - newtop);
                movableWindowContent.style.maxHeight = (footer.offsetTop - newtop) - 20;
                pointerY += yDelta;
            }
        };

        const MovableWindowRelease = function(e) {
            document.onmouseup = null;
            document.onmousemove = null;
        };

        const closeButton = document.createElement("span");
        closeButton.setAttribute("class", "movableWindowCloseButton");
        closeButton.textContent = "×";

        const movableWindowTitleBar = document.createElement("div");
        movableWindowTitleBar.setAttribute("class", "movableWindowTitleBar");
        movableWindowTitleBar.onmousedown = MovableWindowOnMouseDown;
        const movableWindowTitleText = document.createElement("div");
        movableWindowTitleText.setAttribute("class", "movableWindowTitleText");
        movableWindowTitleText.textContent = titleText;

        movableWindowTitleBar.appendChild(movableWindowTitleText);
        movableWindowTitleBar.appendChild(closeButton);


        const movableWindowContent = document.createElement("div");
        movableWindowContent.setAttribute("class", "movableWindowContent");
        movableWindowContent.appendChild(contentElm);

        const movableWindow = document.createElement("div");
        movableWindow.setAttribute("class", "movableWindow");
        movableWindow.appendChild(movableWindowTitleBar);
        movableWindow.appendChild(movableWindowContent);

        const headerBottom = header.offsetHeight;
        movableWindow.style.top = headerBottom;
        movableWindow.style.maxHeight = (footer.offsetTop - headerBottom);
        movableWindow.style.maxWidth  = document.getElementsByTagName("body")[0].offsetWidth;
        movableWindowContent.style.maxHeight = (footer.offsetTop - headerBottom) - 20;

        const fullwindow = { 'domwindow' : movableWindow};

        // remove from dom and the window stack
        closeButton.addEventListener('click', function() {
            movableWindow.remove();
            RemoveWindow(fullwindow);
            if(that.windowstack) {
                that.windowstack.domwindow.getElementsByClassName("movableWindowTitleBar")[0].style.backgroundColor = "#0000FF";
            }
        });

        // on mouse down move window to topmost
        const makeTopMost = function() {
            const nextwindow = fullwindow.next;
            // already topmost if no next window
            if(!nextwindow) {
                return;
            }

            // remove from stack
            RemoveWindow(fullwindow);

            // place topmost
            AddWindow(fullwindow);
        };
        movableWindow.onmousedown = makeTopMost;

        // add to the window stack as topmost
        AddWindow(fullwindow);

        // finally show the window
        document.getElementsByTagName("body")[0].appendChild(movableWindow);
    };

    return that;
};
const WM = WindowManager();



const CreateImageViewer = function(title, imageURL) {
    const imgelm = document.createElement("img");
    imgelm.setAttribute("class", "artviewimg");
    imgelm.setAttribute("alt", "imageviewimage");
    imgelm.setAttribute('src', imageURL);
    WM.CreateMovableWindow("Image View - " + title, imgelm);
};

const TrackHTML = function(track, isLoading) {
    const trackdiv = document.createElement("div");
    trackdiv.setAttribute('class', 'trackdiv');
    if(track) {
        const artelm = document.createElement("img");
        artelm.setAttribute("class", "albumart");
        artelm.setAttribute("alt", "album art");
        artelm.setAttribute('src', MHFSPLAYER.getarturl(track));
        // Open the image viewer if the art is clicked
        artelm.addEventListener('click', function(ev) {
            CreateImageViewer(track.trackname, MHFSPLAYER.getarturl(track));
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

// artview
//const artview = document.getElementById("artview");
//const artviewimg = document.getElementsByClassName("artviewimg")[0];
//artviewimg.src = MHFSPLAYER.getarturl(track);
//artview.style.display = 'block';

let GuiNextTrack;
let GuiCurrentTrack;
let GuiCurrentTrackWasLoading;
let GuiPrevTrack;

const UpdateTrackImage = function(track) {
    const guitracks = [GuiPrevTrack, GuiCurrentTrack, GuiNextTrack];
    for( const gt of guitracks) {
        if(!gt) continue;
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
        const newurl = MHFSPLAYER.getarturl(gt);
        if(artelm.src !== newurl) {
            console.log('update url from ' + artelm.src + ' to ' + newurl);
            artelm.src = newurl;
        }
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

const onACStateUpdate = function(playerstate) {
    if(playerstate === "suspended") {
        ppbtn.textContent = "PLAY";
    }
    else if(playerstate === "running"){
        ppbtn.textContent = "PAUSE";
    }
}

let DRAWUPDATE;
const onQueueUpdate = function(update) {
    DRAWUPDATE = update;
    // if a track ended, the manual seekbar movement is invalid
    if(update.trackended) {
        SBAR_UPDATING = 0;
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

const onTrackEnd = function(isLast) {
    SBAR_UPDATING = 0;
    if(isLast) {
        SetCurtimeText(0);
        SetSeekbarValue(0);
    }
};

const prevbtn    = document.getElementById("prevbtn");
const seekbar    = document.getElementById("seekbar");
const ppbtn      = document.getElementById("ppbtn");
const curtimetxt = document.getElementById("curtime");
const endtimetxt = document.getElementById("endtime");
const nexttxt    = document.getElementById('next_text');
const prevtxt    = document.getElementById('prev_text');
const playtxt    = document.getElementById('play_text');
const dbarea     = document.getElementById('musicdb');

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
    'onACStateUpdate' : onACStateUpdate,
    'onTrackEnd'      : onTrackEnd,
    'UpdateTrackImage' : UpdateTrackImage
}});


// BEGIN UI handlers
document.getElementById('playback_order').addEventListener('change', function(e){
    MHFSPLAYER.pborderchange(e.target.value);
});
 
 ppbtn.addEventListener('click', function (e) {
    if ((ppbtn.textContent == 'PAUSE')) {
        MHFSPLAYER.pause();
    }
    else if ((ppbtn.textContent == 'PLAY')) {
        MHFSPLAYER.play();
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
    if(DRAWUPDATE) {
        const track = DRAWUPDATE.track;
        const duration =  track.duration || 0;
        seekbar.max = duration;
        SetEndtimeText(duration);
        SetPrevTrack(track.prev);
        SetPlayTrack(track, DRAWUPDATE.trackstate === 'loading');
        SetNextTrack(track.next);
        if(DRAWUPDATE.trackstate === 'loading') {
            SetCurtimeText(DRAWUPDATE.curtime || 0);
            if(!DRAWUPDATE.curtime) SetSeekbarValue(0);
        }
        else if(DRAWUPDATE.trackstate === 'ended') {
            SetCurtimeText(0);
            SetSeekbarValue(0);
        }
        DRAWUPDATE = undefined;
    }
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
*/
