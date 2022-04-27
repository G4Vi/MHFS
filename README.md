# MHFS - Media HTTP File Server
#### Stream your own music and video library via your browser and standard media players.
- HTTP/1.1 server [keepalive, byte serving, chunked encoding, and more]
- Gapless streaming web audio player using AudioWorklet and [miniaudio](https://raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.h) with fallback players for incompatible browsers
- server-side audio and video transcoding
- Kodi open directory interface for playing from kodi as http source [video only currently]
- M3U8 playlist interface for easy streaming in video players such as VLC
- [Incomplete] web video players to stream your movies and tv shows in the browser
- automatic media library scanning
- `youtube-dl` web interface

![screenshot of MHFS Music](MHFS_music_2022_04-21_smaller.png)

## Setup

### Download MHFS

Download from [releases](https://github.com/G4Vi/MHFS/releases) (compiled Wasm included) and extract.<br>
or<br>
Clone `git clone https://github.com/G4Vi/MHFS.git` (emscripten required to build web audio player Wasm).

Both options optionally require a c compiler to build perl XS modules and `tarsize`.

### Setup perl
Installing packages under system perl is not recommended. `local::lib` still uses system perl, but allows libraries to be installed seperately. The instructions here will use `local::lib`, but `perlbrew` can be used instead to install with it's own  perl.
<details>
<summary>Setup local::lib</summary>
NOTE: If installing to run as another user, see <a href="#setup-account-to-run-mhfs">Advanced Setup/Setup account</a> <code>local::lib</code> info.

`wget https://cpan.metacpan.org/authors/id/H/HA/HAARG/local-lib-2.000024.tar.gz && tar xvf local-lib-2.000024.tar.gz`<br>
`cd local-lib-2.000024 && perl Makefile.PL --bootstrap`<br>
`make test && make install`<br>
`eval $(perl -I$HOME/perl5/lib/perl5 -Mlocal::lib)`<br>
`curl -L https://cpanmin.us | perl - App::cpanminus`
</details>
or<br>
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


### Install dependencies

`cpanm --installdeps .`

[Optional] Install `ffmpeg` and `sox` somewhere into path. i.e. `apt-get install ffmpeg sox`
- `ffmpeg` is used for transcoding in the MusicLibrary subsystem and for videos in the video subsystem.
- `sox` is used for resampling in the MusicLibrary subsystem

[Optional] Install `youtube-dl` to the MHFS bin dir `cd MHFS/bin && wget https://yt-dl.org/downloads/latest/youtube-dl && chmod +x youtube-dl`
- used for Youtube subsystem

[Optional] Install libFLAC with headers. i.e. `apt-get install libflac-dev`. libFLAC is required to build the XS module [needed for server-side audio decoding and encoding]. `Alien::libFLAC` will download and build libFLAC from source if not found.

### Compile C code

`make XS tarsize` - If you downloaded a release tarball as the Wasm is already compiled.

`make -j4` - To build everything including the Wasm for the web audio players. [emscripten required] [Highly recommended if you cloned]

`make` targets:
- `XS` module - [Optional] used for server-side decoding and encoding [libflac with headers required]
- `tarsize` - used to quickly compute the size of a tar before it's built in order to provide an accurate `Content-Length` of a tar download.
- `music_worklet` - AudioWorklet based gapless web audio player [emscripten required]
- `music_inc` - fallback web audio player [emscripten required]

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

### Advanced Setup / Running as a service

#### Reverse Proxy
To add TLS and allows access without entering a port in the URL, reverse proxying is recommended. Instructions for `apache2`, but it's similar for nginx:
Setup [Let's Encrypt certbot](https://certbot.eff.org/instructions) to manage TLS if not already setup. Add the following to your site config i.e. `/etc/apache2/sites-available/000-default-le-ssl.conf` replacing `mhfs` with the name you want on your site. Keep the trailing slashes [or absense of] the same.
```apache2
RewriteEngine On
RewriteRule ^/mhfs$ mhfs/ [R,L]
<Location "/mhfs/">
  AddOutputFilterByType DEFLATE application/json
  AddOutputFilterByType DEFLATE text/html
  AddOutputFilterByType DEFLATE application/javascript
  AddOutputFilterByType DEFLATE text/plain
  AddOutputFilterByType DEFLATE text/css
  AddOutputFilterByType DEFLATE application/wasm
  ProxyPass "http://127.0.0.1:8000/"
</Location>
```
Reload apache2 `# service apache2 reload`

#### Setup account to run MHFS
`# adduser --system mhfs` - create the daemon user and home directory

`# chown -R YOURUSERNAME:YOURUSERNAME /home/mhfs` - allow your account to manage mhfs

Setup mhfs using YOUR account (NOT the mhfs acc or root) inside of `/home/mhfs`.

For `local::lib`:
use `perl Makefile.PL --bootstrap=/home/mhfs/perl5` for the local lib build command and `eval "$(perl -I/home/mhfs/perl5/lib/perl5 -Mlocal::lib=/home/mhfs/perl5)"` to activate.

Run MHFS, move config under `mhfs` user, and configure as needed.
`perl server.pl`, Control-C. `mkdir -p /home/mhfs/.config && mv ~/.config/mhfs /home/mhfs/.config`

Allow MHFS to write temp files and update youtube-dl. `# chown -R mhfs:nogroup /home/mhfs/MHFS/public_html/tmp /home/mhfs/MHFS/bin/youtube-dl`

Switch to the mhfs user: `su - mhfs -s /bin/bash`. Run mhfs: `perl server.pl`.  Verify it works in a browser.

#### Setup as systemd service
A sample service set to use the local::lib is provided.

```bash
cp doc/mhfs.service /etc/systemd/system/mhfs.service
systemctl daemon-reload
systemctl enable mhfs.service
systemctl start mhfs.service
```

## Usage

Navigate to the url, by default `http://127.0.0.1:8080/` you are presented with a few different routes:

`/music` to enter the music library and player. See below for info on the `MusicLibrary` subsystem.

`/video` to enter the movie and tv library and player. See below for info on the `Video` subsystem.

## Subsystems

### MusicLibrary subsystem

The music player is by default accessed with `/music`.

#### Music players

`/music?fmt=worklet` - `AudioWorklet` based player.
- Gapless streaming of FLAC, WAV, and MP3 without needing server-side decoding support
- Shows embedded or file based cover art.
- Shows metadata (Trackname, Artist, and Album) instead of file path.
- Keyboard based controls and MediaSession support for media key usage.

`/music?fmt=legacy` - Legacy browser player. Uses html audio tag to load and play audio.

`/music?fmt=gapless` - Gapless player. Uses server-side audio segmenting to allow gapless streaming with `AudioBufferSourceNode`s without downloading the whole track first.

`/music?fmt=musicinc` - Incremental gapless player. Like the gapless player, but only buffers a fixed amount ahead instead of buffering the whole track.

#### API
`/music` Request a music player or the music library in a variety of formats. See `MusicLibrary::SendLibrary`.

`/music_dl?name=folderpath` Download a track [or part of one] by filename with optional resampling, channel mixing, and encoding. See `MusicLibrary::SendLocalTrack`.

`/music_resources?name=folderpath` Download a flac audio track's vorbis comments as json. See `MusicLibrary::SendResources`. 

### Video subsystem

The video player is accessed with `/video`.

For convenience `M3U` playlist files are provided to ease streaming outside of the browser in software such as VLC. Note, this may only work well on LAN.

#### Kodi / XBMC

The video subsystem is accessible via http sources in kodi. MHFS attempts to provide your libraries with kodi's desired naming structures, so that it will be organized with metadata accurately.

`/video/kodi/movies/` - Kodi formatted *Movies* directory listing

`/video/kodi/tv/` - Kodi formatted *TV* directory listing

## Development Info

emscripten is required to build Wasm.  A full build is done with `make -j4`. A build without the XS extension can be done with `make -j4 noxs`

`./debug.pl` is provided to kill instances of MHFS, build MHFS [including emscripten and XS], and launch `server.pl`.

## Thanks
[Tejas Rao](https://github.com/trao1011) for source code review early on. [mackron](https://github.com/mackron) for great audio libraries and answering questions.

## License
Unless otherwise noted GPL v2.0, see LICENSE. Contact me if you need something different (email is in `git log`).
