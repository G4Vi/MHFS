# MHFS - Media HTTP File Server
#### Stream your own music and video library via your browser and standard media players.

## Setup

### Grab the repo 

`git clone https://github.com/G4Vi/MHFS.git && cd MHFS`

### Setup perl
Installing packages under system perl is not recommended. `perlbrew` installs perl completely seperately from system perl. `local::lib` still uses system perl, but allows libraries to be installed seperately. 
<details>
<summary>Setup perlbrew distribution</summary>

`export PERLBREW_ROOT=ABSPATHTOREPO/perl5/perlbrew` replacing `ABSPATHTOREPO` with the absolute path to the repo<br>
`curl -L https://install.perlbrew.pl | bash`<br>
`source "$PERLBREW_ROOT/etc/bashrc"`<br>
`perlbrew install perl-5.34.0`<br>
`perlbrew list`<br>
`perlbrew switch perl-5.34.0` where `perl-5.34.0` is the version listed.<br>
`perlbrew install-cpamn`

`cd /usr/include/x86_64-linux-gnu/ && h2ph -r -l . && cd sys && h2ph syscall.h && cd ABSPATHTOREPO` where `/usr/include/x86_64-linux-gnu` is the kernel header files and `ABSPATHTOREPO` is the absolute path to the repo used before.

</details>
OR<br>
<details>
<summary>Setup local::lib</summary>
<code>wget https://cpan.metacpan.org/authors/id/H/HA/HAARG/local-lib-2.000024.tar.gz && tar xvf local-lib-2.000024.tar.gz`</code><br>
<code>cd local-lib-2.000024 && perl Makefile.PL --bootstrap</code><br>
<code>eval $(perl -I$HOME/perl5/lib/perl5 -Mlocal::lib)</code><br>
<code>curl -L https://cpanmin.us | perl - App::cpanminus</code>
</details>


### Install dependencies

`cpanm --installdeps .`

[Optional] Install `ffmpeg` and `sox` somewhere into path. i.e. `apt-get install ffmpeg sox`
- `ffmpeg` is used for transcoding in the MusicLibrary subsystem and for videos in the video subsystem.
- `sox` is used for resampling in the MusicLibrary subsystem

[Optional] Install `youtube-dl` to the MHFS bin dir `cd MHFS/bin && wget https://yt-dl.org/downloads/latest/youtube-dl`   
- used for Youtube subsystem

<details>
<summary>[Optional] Install libflac with headers [needed for server-side audio decoding and encoding] </summary> 
<details>
<summary>Build and install libflac inside MHFS::XS</summary>
Download, configure, and make it:<br>

`mkdir -p XS/thirdparty && cd XS/thirdparty && wget http://downloads.xiph.org/releases/flac/flac-1.3.3.tar.xz`<br>

`tar xvf flac-1.3.3.tar.xz && cd flac-1.3.3 && ./configure --enable-ogg=no && make`
</details>
OR<br>
Install from your package manager i.e <code>apt-get install libflac-dev</code>.
</details>

### [Optional] Build XS module (for server-side decoding and encoding) [libflac required]

`libflac` is required to build the XS module for server-side decoding and encoding. [See install info under *Install dependencies*]

Build the XS module (from the root of the project)
`make XS`

### Configure settings
Start the server, `perl server.pl` to create the setting file [`settings.pl`].

Settings are loaded from [$XDG_CONFIG_DIRS](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)`/mhfs`, by default `$HOME/.config/mhfs`. If `settings.pl` is not found, it is created. Fill in your settings as needed.

`HOST` - address to bind too, i.e. `'127.0.0.1'` for localhost or `'0.0.0.0'` for all interfaces.

`PORT` - port to bind too, i.e. `8000`.

`ALLOWED_REMOTEIP_HOSTS` - whitelist to specify allowed remote ip addresses, an optional required `Host` header value, and an absolute url override if desired. By default the absolute url is derived from the `Host` header. [CIDR](https://datatracker.ietf.org/doc/html/rfc4632#section-3.1) notation is supported to allow remote ip address ranges in a single item.
```perl
'ALLOWED_REMOTEIP_HOSTS' => [
    # localhost connections for reverse proxy, use https://domain.net/mhfs to build absolute urls
    ['127.0.0.1', undef, 'https://domain.net/mhfs'],
    ['192.168.1.0/24'], # anyone on our LAN
    ['0.0.0.0/0', 'domain.net:8000'] # direct connections with the correct Host header
],
```

`MEDIALIBRARIES` - hash of library to folder path mapping. The libraries `movies` and `tv` are used by the video subsystem.
```perl
'MEDIALIBRARIES' => {
    'movies' => "/path/to/movies",
    'tv'     => "/path/to/tv",
    'music' => "/path/to/music",
}
```

`MusicLibrary` - Music subsystem / plugin settings
```perl
'MusicLibrary' => {
    'enabled' => 1,
    # multiple sources may be specified
    'sources' => [
        { 'type' => 'local', 'folder' => '/path/to/music'},
    ]
}
```
Timeouts are used to boot idle or non-responsive connections.

`recvrequestimeout` - maximum time [in seconds] to recieve an http request line and headers. Starts when no request is active on connection. default value: `TIMEOUT`

`sendresponsetimeout` - maximum time [in seconds] allowed between `send`'s when sending an http response. default value: `TIMEOUT`

`TIMEOUT` - the default timeout value [in seconds] for the timeouts. default value: `75`

## Run

`perl server.pl`

### Headless setup
TODO: See `doc/mhfs.service.skel`

## Usage

Navigate to the url, by default `http://127.0.0.1:8080/` you are presented with a few different routes:

`/music` to enter the music library and player. See below for info on the `MusicLibrary` subsystem.

`/video` to enter the movie and tv library and player. See below for info on the `Video` subsystem.

## Subsystems

### MusicLibrary subsystem

The music player is by default accessed with `/music`.

#### music players

`/static/music_worklet_inprogress` The main audio player. Unfortunately Linux has poor support for `audio worklet` and older browsers have no support for it, so older versions of the music player are included.

`/music?fmt=legacy` minimal js, uses html audio tag

`/music` on linux, gapless player, requests flac segments of a track from `MHFS` and uses `AudioBufferSourceNode`

`/static/music_inc/` similar to the gapless player, but doesn't buffer the whole track ahead of time.

#### API
`/music` Request a music player or the music library in a variety of formats. See `MusicLibrary::SendLibrary`.

`/music_dl?name=folderpath` Download a track [or part of one] by filename with optional resampling, channel mixing, and encoding. See `MusicLibrary::SendLocalTrack`.

`/music_resources?name=folderpath` Download a flac audio track's vorbis comments as json. See `MusicLibrary::SendResources`. 

### Video subsystem

The video player is accessed with `/video`.

For convenience `M3U` playlist files are provided to ease streaming outside of the browser in software such as vlc. Note, this may only work well on LAN.

#### Kodi / XBMC

The video subsystem is accessible via http sources in kodi. MHFS attempts to provide your libraries with kodi's desired naming structures, so that it will be organized with metadata accurately.

`/video/kodi/movies/` - Kodi formatted *Movies* directory listing

`/video/kodi/tv/` - Kodi formatted *TV* directory listing

## Development Info

emscripten is required to build wasm.  A full build is done with `make -j4`. A build without the XS extension can be done with `make -j4 noxs`

`./debug.pl` is provided to kill instances of MHFS, build MHFS [including emscripten and XS], and launch `server.pl`.

## License
Unless otherwise noted GPL v2.0, see LICENSE. Contact me if you need something different (email is in `git log`).
