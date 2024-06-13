# source ~/emsdk/emsdk_env.sh
SHELL := /bin/sh
DECODERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/decoder
PLAYERDIR:=App-MHFS/share/public_html/static/music_worklet_inprogress/player
MUSICINCDIR=App-MHFS/share/public_html/static/music_inc

# MHFSVERSION := $(shell perl -I App-MHFS/lib -MApp::MHFS -e 'print substr($$App::MHFS::VERSION, 1)' 2>/dev/null)
MHFSVERSION:=0.5.1
APPERLM := $(shell command -v apperlm || echo perl -I$$(realpath ../Perl-Dist-APPerl/lib) $$(realpath ../Perl-Dist-APPerl/script/apperlm))

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
	rm -f App-MHFS/share/public_html/static/kodi/plugin.video.mhfs.zip
	$(MAKE) -C App-MHFS veryclean

# dists
.PHONY: unsafedists
unsafedists: Alien-Tar-Size/Makefile Alien-libFLAC/Makefile MHFS-XS/Makefile music_worklet music_inc App-MHFS/Makefile kodi_plugin
	$(MAKE) -C Alien-Tar-Size manifest && $(MAKE) -C Alien-Tar-Size distcheck && $(MAKE) -C Alien-Tar-Size dist
	$(MAKE) -C Alien-libFLAC manifest && $(MAKE) -C Alien-libFLAC distcheck && $(MAKE) -C Alien-libFLAC dist
	$(MAKE) -C MHFS-XS manifest && $(MAKE) -C MHFS-XS distcheck && $(MAKE) -C MHFS-XS dist
	$(MAKE) -C App-MHFS manifest && $(MAKE) -C App-MHFS distcheck && $(MAKE) -C App-MHFS dist

.PHONY: dists
dists: clean
	$(MAKE) unsafedists

apperl/HTML-Template:
	cd apperl && perl download_package.pl HTML::Template
	cd apperl && tar xf HTML-Template.*
	cd apperl && mv HTML-Template-* HTML-Template
	cd apperl && rm HTML-Template.*

apperl/URI:
	cd apperl && perl download_package.pl URI
	cd apperl && tar xf URI.*
	cd apperl && mv URI-* URI
	cd apperl && rm URI.*

apperl/Class-Inspector:
	cd apperl && perl download_package.pl Class::Inspector
	cd apperl && tar xf Class-Inspector.*
	cd apperl && mv Class-Inspector-* Class-Inspector
	cd apperl && rm Class-Inspector.*

apperl/File-ShareDir:
	cd apperl && perl download_package.pl File::ShareDir
	cd apperl && tar xf File-ShareDir.*
	cd apperl && mv File-ShareDir-* File-ShareDir
	cd apperl && rm File-ShareDir.*

apperl/File-ShareDir-Install:
	cd apperl && perl download_package.pl File::ShareDir::Install
	cd apperl && tar xf File-ShareDir-Install.*
	cd apperl && mv File-ShareDir-Install-* File-ShareDir-Install
	cd apperl && rm File-ShareDir-Install.*

apperl/App-MHFS: release
	rm -rf apperl/MHFS* apperl/App-MHFS*
	cd apperl && tar xf ../MHFS*.tar
	cd apperl && tar xf MHFS_*/App-MHFS-*
	cd apperl && mv App-MHFS-* App-MHFS
	cd apperl && rm -r MHFS*

.PHONY: apperl
apperl: apperl/HTML-Template apperl/URI apperl/Class-Inspector apperl/File-ShareDir apperl/File-ShareDir-Install apperl/App-MHFS
	cd apperl && $(APPERLM) checkout mhfs
	cd apperl && $(APPERLM) configure
	cd apperl && $(APPERLM) build

.PHONY: MHFS_$(MHFSVERSION)
MHFS_$(MHFSVERSION): dists
	[ ! -f $@.tar ]
	[ ! -d $@ ]
	rm -rf $@
	mkdir -p $@
	mv Alien-libFLAC/Alien-libFLAC-*.tar.gz $@/
	mv Alien-Tar-Size/Alien-Tar-Size-*.tar.gz $@/
	mv MHFS-XS/MHFS-XS-*.tar.gz $@/
	mv App-MHFS/App-MHFS-*.tar.gz $@/
	cp LICENSE $@/
	cp README.md $@/
	cp CHANGELOG.md $@/
	cp -r resources $@/
	cp MHFS_music_2022_04-21_smaller.png $@/
	tar -cf $@.tar $@ --owner=0 --group=0

.PHONY: release
release: MHFS_$(MHFSVERSION)

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

# Kodi plugin
.PHONY: kodi_plugin
kodi_plugin:
	zip -r plugin.video.mhfs.zip plugin.video.mhfs
	mkdir -p App-MHFS/share/public_html/static/kodi
	mv plugin.video.mhfs.zip App-MHFS/share/public_html/static/kodi

# App-MHFS
App-MHFS/Makefile: App-MHFS/Makefile.PL
	cd App-MHFS && perl Makefile.PL

.PHONY: App-MHFS
App-MHFS: App-MHFS/Makefile music_worklet music_inc kodi_plugin
	$(MAKE) -C App-MHFS