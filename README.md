# MHFS - Media HTTP File Server
#### Stream your own music and video library via your browser and standard media players.

## Setup
`.doc/dependencies.txt` required.

You likely need to create `.conf/settings.pl` to specify folder paths and network settings. See the source in `server.pl` to see what's needed.

## Build

emscripten is required to build wasm.  `make -j4`. A build without the XS extension can be done with `make -j4 noxs`

## Run

`perl server.pl`

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

## License
Unless otherwise noted GPL v2.0, see LICENSE. Just ask if you need something different (email is in `git log`).
