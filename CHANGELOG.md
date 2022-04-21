# MHFS Changelog

## [0.2.0](https://github.com/G4Vi/MHFS/compare/v0.1.0...v0.2.0) - 2022-04-21
### AudioWorklet Player
#### Added
- WAV and MP3 streaming, decoding, and playing
- Loading cover art from inside the audio file or the MHFS server
- Loading metadata (Title, Artist, Album, etc) from FLAC vorbis comments
- Showing metadata and cover art in player instead of file path when available
- MediaSession api support for usage of media keys and out of page audio control
- New playback modes, `Repeat (Playlist)`, `Random`, and `Reverse`.
- Playback view with large cover art display
- Resizable and movable image viewer
#### Changed
- miniaudio is now used for decoding instead of using dr_flac directly
- decoder is now saved and restored on running out of data instead of being reinitialized
- Reduced copying of decoded data / allocating and freeing memory
#### Fixed
- Play/Pause button sometimes displaying wrong state, now always synced to the audiocontext

### Server
#### Added
- `/music_dl` now sends totalPCMFrameCount via `X-MHFS-totalPCMFrameCount` header when sending mp3 files (Used as fallback value for calculating mp3 duration)
#### Changed
- Request query string parsing now groups values of identical keys instead of overwriting
- `/music` without `fmt` param now in most cases sends the AudioWorklet player to Linux clients
- Improved UTF8 support
- Improved HTTP response building
#### Fixed
- fixed bad parsing in torrent_file_information when filename in rtxmlrpc output is surrounded by double quotes instead of single quotes
- ` /torrent?infohash` - fixed filenames being url encoded instead of html escaped
- `/music` - ptrack params not being passed on when redirecting
#### Removed
- GDRIVE plugin, it was disabled and unmaintained

### Other
- Updated README.md to have better music player info, have screenshot, and mention the gapless player uses miniaudio instead of dr_flac.

## [0.1.0](https://github.com/G4Vi/MHFS/releases/tag/v0.1.0) - 2021-10-07
### Added
- poll based event loop
- HTTP 1.1 server
- subprocess managment
- Music subsystem
  - Auto-rescans
  - Several web players
  - serverside transcoding, resampling, and segmenting
- Video subsystem
  - Transcoding to various formats (mp3, hls)
  - M3U8 playlist generation
  - Kodi formatted open directory interface
  - Youtube-dl frontend
- Torrent subsystem
  - interaction with rtorrent via rtxmlrpc
  - various pages