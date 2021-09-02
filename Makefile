# source ~/emsdk/emsdk_env.sh
DECODERDIR:=public_html/static/music_worklet_inprogress/decoder
PLAYERDIR:=public_html/static/music_worklet_inprogress/player
MUSICINCDIR=public_html/static/music_inc

.PHONY: all
all: XS music_worklet music_inc tarsize

# don't build perl XS module
.PHONY: noxs
noxs: music_worklet music_inc tarsize

.PHONY: clean
clean: XS_clean music_worklet_clean music_inc_clean tarsize_clean

.PHONY: tarsize
tarsize:
	$(MAKE) -C tarsize

.PHONY: tarsize_clean
tarsize_clean:
	$(MAKE) -C tarsize clean

.PHONY: XS
XS:
	$(MAKE) -C XS -f ActualMakefile.mk

.PHONY: XS_clean
XS_clean:
	$(MAKE) -C XS -f ActualMakefile.mk clean

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
