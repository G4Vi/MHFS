# MHFS - Media HTTP File Server
#### Stream your own music and video library via your browser and standard media players.

## Setup
`.doc/dependencies.txt` required.

You likely need to create `.conf/settings.pl` to specify folder paths and network settings. See the source in `server.pl` to see what's needed.

## Build

emscripten is required to build wasm.  `cd drflac_wasm && perl build_cache.pl && cd .. && perl build.pl`

## Run

`perl server.pl`

### License
Unless otherwise noted GPL v2.0, see LICENSE. Just ask if you need something different (email is in `git log`).

### Notes

video is accessed with `/video`

`M3U` files can be opened in vlc to stream from there.

music player is by default accessed with `/music`

`static/music_worklet_inprogress` The main audio player. Unfortunately Linux has poor support for `audio worklet` and older browsers have no support for it, so older versions of the music player are included.

`/music?legacy=1` minimal js, use html audio tag

`/music` on linux, gapless player, requests flac segments of a track from `MHFS` and uses `AudioBufferSourceNode`

`/static/music_inc/` similar to the gapless player, but doesn't buffer the whole track ahead of time.
