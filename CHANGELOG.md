# MHFS Changelog
## [0.6.0](https://github.com/G4Vi/MHFS/compare/v0.5.1...v0.6.0) - 2024-10-21
### App-MHFS-v0.6.0
#### Added
- Kodi JSON API `/kodi/movies` and `/kodi/tv`
    - TMDB metadata and art fetching
    - Supports multiple editions of movies and multiple files per movie.
      Multi-part rar is not supported yet.
    - movies loads from multiple file sources
- Kodi video add-on
- Promise system (MHFS::Promise) to reduce callback hell.
#### Fixed
- MHFS::Process - Fix incorrect fcntl error handling and usage for turning on
  O_NONBLOCK, fixes [GH#1](https://github.com/G4Vi/MHFS/issues/1)
- Web Music Player stack overflow on emscripten 3.1.27 and higher by
  hardcoding stack size to 128KB.
- Web Music Player adding collections (Parent nodes of disc dirs) to playlist
#### Changed
- MHFS::Settings - change default receive request timeout from 75 to 10 seconds
### MHFS-XS-v0.2.4
- Link `-latomic` on 32-bit ARM
### Alien-Tar-Size-v0.2.2 [unchanged]
### Alien-libFLAC-v0.2.0 [unchanged]

## [0.5.1](https://github.com/G4Vi/MHFS/compare/v0.5.0...v0.5.1) - 2022-12-03
- Version is no longer based on App-MHFS version. MHFS releases will
note which distributions are included.
### Alien-Tar-Size-v0.2.2
- Added better preprocessor check for OS check
### MHFS-XS-v0.2.3
- Disable unused miniaudio APIs to remove threading requirement
### Alien-libFLAC-v0.2.0 [unchanged]
### App-MHFS-v0.5.0 [unchanged]

## [0.5.0](https://github.com/G4Vi/MHFS/compare/v0.4.1...v0.5.0) - 2022-11-14
### Alien-libFLAC
#### Fixed
- insufficient dependency gathering (switched to `pkg-config`)
### Alien-Tar-Size
#### Fixed
- BSD builds by making libdl optional
#### Added
- #include check before compiling
- Fail out with OS unsupported if attempted to build on Windows
### App-MHFS
#### Added
- Binary releases via APPerl: `mhfs.com`
#### Fixed
- Makefile.PL OS check erroring out with wrong message
#### Changed
- moved MHFS::EventLoop::Poll::Linux archname check to MHFS::EventLoop::Poll::Linux::Timer
- use newest emcc in builds now
- reduce redundancy of turning on nonblocking socket operation
- settings loading to support Windows environments (MHFS does not work on Windows yet)

## [0.4.1](https://github.com/G4Vi/MHFS/compare/v0.4.0...v0.4.1) - 2022-07-15
### App-MHFS
#### Added
- OS check by importing `Time::HiRes::clock_gettime` in Makefile.PL
#### Fixed
- unsufficient Perl version checks in Makefile.PL, now requires perl 5.14.0 or greater
#### Changed
- integer size check in `MHFS::Plugin::GetVideo` is now a plugin loading error instead of a
compile time error for MHFS.
### MHFS-XS
#### Fixed
- Stopped overriding CCFLAGS to fix perl being built with different settings
- builds with non-MULTIPLICITY 5.20.2 perl; `-lpthread` added to libs

## [0.4.0](https://github.com/G4Vi/MHFS/compare/v0.3.0...v0.4.0) - 2022-07-11
### Added
- Automated builds via github ci `.github/workflows/build.yml`
- cpanfile for easier dev and ci operation
- instructions for installing from cpan to README.md

### Fixed
- Compile error when building MHFS::XS with non-MULTIPLICITY perl

## [0.3.0](https://github.com/G4Vi/MHFS/compare/v0.2.0...v0.3.0) - 2022-06-30
#### Added
- Added downloading media via torrent
    - Added HTTP Torrent Tracker
        - designed to handle clients on LAN and WAN without leaking LAN IPs outside
    - Added creating torrents from media items
    - When an item is requested, a torrent is created, added to the tracker, and added to rtorrent to start seeding, so it can be downloaded instantly.
- Added improved client host validation with `X-MHFS-PROXY_KEY` for secure reverse proxying
- Added automatic youtube-dl binary downloading and installing for MHFS use
- Added installation and packaging via cpan distributions
  - Added using File::ShareDir for APPDIR

#### Changed
- MHFS prefix was added to modules in server.pl, `MHFS::Plugin` prefix was added to plugins
- `MEDIALIBRARIES` is now interpreted into `MEDIASOURCES` and supports mapping to multiple sources
    * However, not all the code handles multiple sources yet
- `MHFS::Plugin::MusicLibrary` now uses `MEDIASOURCES` instead of it's own sources
- Broke up EventLoop::Poll into EventLoop::Poll::Base, EventLoop::Poll::Linux, and EventLoop::Poll
- Made tarsize and libFLAC into Alien modules to ease building and installing
- switched XS to vendored miniaudio submodule
- temp directory now uses `$XDG_CACHE_HOME` or `~/.cache` by default
    * cookies are now stored in temp directory, inaccessible to web routes
- Torrent are now loaded into rtorrent from memory instead of writing to disk first
- playlists are now accessed via `/playlist` route instead of `/get_video`
- `/get_video` now uses a callback to generate the `create_cmd` instead of `eval`
- `/video/fmp4` fmt was integrated to `/get_video` instead of having its own route
- `/video/kodi` is now accessed via `/kodi`, kodi stuff was moved into `MHFS::Plugin::Kodi`
- Open directories are now managed by `MHFS::Plugin::OpenDirectory` and served from `/od`

#### Fixed
- JSMpeg's query string messing up its format

#### Removed
- search from `/get_video` to increase speed and accuracy
- removed HLS on demand and several broken `/get_video` formats and players
- gapless music player

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