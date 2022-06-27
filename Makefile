# source ~/emsdk/emsdk_env.sh
SHELL := /bin/sh
DECODERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/decoder
PLAYERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/player
MUSICINCDIR=App-MHFS/share/public_html/static/music_inc

# build everything
.PHONY: all
all: XS music_worklet music_inc tarsize App-MHFS

# build everything, but XS
.PHONY: noxs
noxs: music_worklet music_inc tarsize App-MHFS

# clean everything
.PHONY: clean
clean: XS_clean music_worklet_clean music_inc_clean tarsize_clean App-MHFS_clean

# tarsize
Alien-Tar-Size/Makefile: Alien-Tar-Size/Makefile.PL Alien-Tar-Size/alienfile
	cd Alien-Tar-Size && perl Makefile.PL

.PHONY: Alien-Tar-Size
Alien-Tar-Size: Alien-Tar-Size/Makefile
	$(MAKE) -C Alien-Tar-Size

.PHONY: Alien-Tar-Size_clean
Alien-Tar-Size_clean:
	$(MAKE) -C Alien-Tar-Size clean || [ ! -f Alien-Tar-Size/Makefile ]
	rm Alien-Tar-Size/Makefile.old || [ ! -f Alien-Tar-Size/Makefile.old ]

#   now just an alias for Alien-Tar-Size
.PHONY: tarsize tarsize_clean
tarsize: Alien-Tar-Size
tarsize_clean: Alien-Tar-Size_clean

# XS extension module for server
#   XS dependencies
Alien-libFLAC/Makefile: Alien-libFLAC/Makefile.PL Alien-libFLAC/alienfile
	cd Alien-libFLAC && perl Makefile.PL

#       HACK, only build Alien-libFLAC if it's deps changed so we don't constantly rebuild the XS module
Alien-libFLAC.dummy: Alien-libFLAC/Makefile Alien-libFLAC/lib/Alien/libFLAC.pm
	$(MAKE) -C Alien-libFLAC
	touch Alien-libFLAC.dummy

.PHONY: Alien-libFLAC_clean
Alien-libFLAC_clean:
	$(MAKE) -C Alien-libFLAC clean || [ ! -f Alien-libFLAC/Makefile ]
	rm Alien-libFLAC/Makefile.old || [ ! -f Alien-libFLAC/Makefile.old ]
	rm Alien-libFLAC.dummy || [ ! -f Alien-libFLAC.dummy ]

#   XS extension module
XS/Makefile: XS/Makefile.PL Alien-libFLAC.dummy
	cd XS && perl -I ../Alien-libFLAC/blib/lib Makefile.PL

.PHONY: XS
XS: XS/Makefile
	$(MAKE) -C XS

.PHONY: XS_clean
XS_clean: Alien-libFLAC_clean
	$(MAKE) -C XS clean || [ ! -f XS/Makefile ]
	rm XS/Makefile.old || [ ! -f XS/Makefile.old ]

# App-MHFS
App-MHFS/Makefile: App-MHFS/Makefile.PL
	cd App-MHFS && perl Makefile.PL

.PHONY: App-MHFS
App-MHFS: App-MHFS/Makefile
	$(MAKE) -C App-MHFS

.PHONY: App-MHFS_clean
App-MHFS_clean:
	$(MAKE) -C App-MHFS clean || [ ! -f App-MHFS/Makefile ]
	rm App-MHFS/Makefile.old || [ ! -f App-MHFS/Makefile.old ]

# Web music players
.PHONY: music_worklet
music_worklet: music_worklet_decoder music_worklet_player

.PHONY: music_worklet_clean
music_worklet_clean: music_worklet_decoder_clean music_worklet_player_clean

.PHONY: music_worklet_decoder
music_worklet_decoder:
	$(MAKE) -C $(DECODERDIR)

.PHONY: music_worklet_decoder_clean
music_worklet_decoder_clean:
	$(MAKE) -C $(DECODERDIR) clean

.PHONY: music_worklet_player
music_worklet_player:
	$(MAKE) -C $(PLAYERDIR)

.PHONY: music_worklet_player_clean
music_worklet_player_clean:
	$(MAKE) -C $(PLAYERDIR) clean

.PHONY: music_inc
music_inc:
	$(MAKE) -C $(MUSICINCDIR)

.PHONY: music_inc_clean
music_inc_clean:
	$(MAKE) -C $(MUSICINCDIR) clean
