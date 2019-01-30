var theParent = document.getElementById('medialist');
theParent.addEventListener("click", SetVideo, false);

function SetVideo(e){    
	if(e.target === e.currentTarget) {
            return;
	}
	console.log('SetVideo - target: ' + e.target);
	var path = e.target.getAttribute('data-file');
	if(path === null) {
	    return;
	}
    e.stopPropagation();
    e.preventDefault();
    
	path = decodeURIComponent(path);
    console.log('path ' + path)  
    _SetVideo("get_video?name=" + path + "&fmt=" + CURRENT_FORMAT);
    window.location.hash = '#video';
}