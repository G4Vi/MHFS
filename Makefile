# source ~/emsdk/emsdk_env.sh
DECODERDIR:=static/music_worklet_inprogress/decoder
PLAYERDIR:=static/music_worklet_inprogress/player
MUSICINCDIR=static/music_inc

all: Mytest music_worklet music_inc

Mytest:
	$(MAKE) -C Mytest -f ActualMakefile.mk

music_worklet_decoder:
	$(MAKE) -C $(DECODERDIR)

music_worklet_player:
	$(MAKE) -C $(PLAYERDIR)

music_worklet: music_worklet_decoder music_worklet_player

music_inc:
	$(MAKE) -C $(MUSICINCDIR)

Mytest_clean:
	$(MAKE) -C Mytest -f ActualMakefile.mk clean

music_worklet_decoder_clean:
	$(MAKE) -C $(DECODERDIR) clean

music_worklet_player_clean:
	$(MAKE) -C $(PLAYERDIR) clean

music_worklet_clean: music_worklet_decoder_clean music_worklet_player_clean

music_inc_clean:
	$(MAKE) -C $(MUSICINCDIR) clean

clean: Mytest_clean music_worklet_clean music_inc_clean

.PHONY: all clean Mytest music_worklet music_worklet_decoder music_worklet_player Mytest_clean music_worklet_decoder_clean music_worklet_player_clean music_worklet_clean music_inc music_inc_clean