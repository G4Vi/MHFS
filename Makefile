# source ~/emsdk/emsdk_env.sh
DECODERDIR:=public_html/static/music_worklet_inprogress/decoder
PLAYERDIR:=public_html/static/music_worklet_inprogress/player
MUSICINCDIR=public_html/static/music_inc

all: XS music_worklet music_inc

noxs: music_worklet music_inc

XS:
	$(MAKE) -C XS -f ActualMakefile.mk

music_worklet_decoder:
	$(MAKE) -C $(DECODERDIR)

music_worklet_player:
	$(MAKE) -C $(PLAYERDIR)

music_worklet: music_worklet_decoder music_worklet_player

music_inc:
	$(MAKE) -C $(MUSICINCDIR)

XS_clean:
	$(MAKE) -C XS -f ActualMakefile.mk clean

music_worklet_decoder_clean:
	$(MAKE) -C $(DECODERDIR) clean

music_worklet_player_clean:
	$(MAKE) -C $(PLAYERDIR) clean

music_worklet_clean: music_worklet_decoder_clean music_worklet_player_clean

music_inc_clean:
	$(MAKE) -C $(MUSICINCDIR) clean

clean: XS_clean music_worklet_clean music_inc_clean

.PHONY: all clean noxs XS music_worklet music_worklet_decoder music_worklet_player XS_clean music_worklet_decoder_clean music_worklet_player_clean music_worklet_clean music_inc music_inc_clean