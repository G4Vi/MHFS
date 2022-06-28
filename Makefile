# source ~/emsdk/emsdk_env.sh
SHELL := /bin/sh
DECODERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/decoder
PLAYERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/player
MUSICINCDIR=App-MHFS/share/public_html/static/music_inc

# build everything
.PHONY: all
all: Alien-Tar-Size Alien-libFLAC.dummy MHFS-XS music_worklet music_inc App-MHFS

# build everything, but MHFS-XS
.PHONY: noxs
noxs: Alien-Tar-Size music_worklet music_inc App-MHFS

# clean everything
.PHONY: clean
clean: Alien-Tar-Size/Makefile Alien-libFLAC/Makefile MHFS-XS/Makefile $(DECODERDIR)/Makefile $(PLAYERDIR)/Makefile $(MUSICINCDIR)/Makefile App-MHFS/Makefile
	$(MAKE) -C Alien-libFLAC veryclean
	rm Alien-libFLAC.dummy || [ ! -f Alien-libFLAC.dummy ]
	$(MAKE) -C Alien-Tar-Size veryclean
	$(MAKE) -C MHFS-XS veryclean
	$(MAKE) -C $(DECODERDIR) clean
	$(MAKE) -C $(PLAYERDIR) clean
	$(MAKE) -C $(MUSICINCDIR) clean
	$(MAKE) -C App-MHFS veryclean

# dists
.PHONY: unsafedists
unsafedists: Alien-Tar-Size/Makefile Alien-libFLAC/Makefile MHFS-XS/Makefile music_worklet music_inc App-MHFS/Makefile
	$(MAKE) -C Alien-Tar-Size manifest && $(MAKE) -C Alien-Tar-Size distcheck && $(MAKE) -C Alien-Tar-Size dist
	$(MAKE) -C Alien-libFLAC manifest && $(MAKE) -C Alien-libFLAC distcheck && $(MAKE) -C Alien-libFLAC dist
	$(MAKE) -C MHFS-XS manifest && $(MAKE) -C MHFS-XS distcheck && $(MAKE) -C MHFS-XS dist
	$(MAKE) -C App-MHFS manifest && $(MAKE) -C App-MHFS distcheck && $(MAKE) -C App-MHFS dist

.PHONY: dists
dists: clean
	$(MAKE) unsafedists

# Alien-Tar-Size
Alien-Tar-Size/Makefile: Alien-Tar-Size/Makefile.PL Alien-Tar-Size/alienfile
	cd Alien-Tar-Size && perl Makefile.PL

.PHONY: Alien-Tar-Size
Alien-Tar-Size: Alien-Tar-Size/Makefile
	$(MAKE) -C Alien-Tar-Size

# MHFS-XS extension module for server
#   MHFS-XS dependencies
Alien-libFLAC/Makefile: Alien-libFLAC/Makefile.PL Alien-libFLAC/alienfile
	cd Alien-libFLAC && perl Makefile.PL

#       HACK, only build Alien-libFLAC if it's deps changed so we don't constantly rebuild the MHFS-XS module
Alien-libFLAC.dummy: Alien-libFLAC/Makefile Alien-libFLAC/lib/Alien/libFLAC.pm
	$(MAKE) -C Alien-libFLAC
	touch Alien-libFLAC.dummy

#   MHFS-XS extension module
MHFS-XS/Makefile: MHFS-XS/Makefile.PL Alien-libFLAC.dummy
	cd MHFS-XS && perl -I ../Alien-libFLAC/blib/lib Makefile.PL

.PHONY: MHFS-XS
MHFS-XS: MHFS-XS/Makefile
	$(MAKE) -C MHFS-XS

# Web music players
.PHONY: music_worklet
music_worklet: music_worklet_decoder music_worklet_player

.PHONY: music_worklet_decoder
music_worklet_decoder:
	$(MAKE) -C $(DECODERDIR)

.PHONY: music_worklet_player
music_worklet_player:
	$(MAKE) -C $(PLAYERDIR)

.PHONY: music_inc
music_inc:
	$(MAKE) -C $(MUSICINCDIR)

# App-MHFS
App-MHFS/Makefile: App-MHFS/Makefile.PL
	cd App-MHFS && perl Makefile.PL

.PHONY: App-MHFS
App-MHFS: App-MHFS/Makefile music_worklet music_inc
	$(MAKE) -C App-MHFS