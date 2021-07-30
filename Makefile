# source ~/emsdk/emsdk_env.sh
DECODERDIR:=static/music_worklet_inprogress/decoder
PLAYERDIR:=static/music_worklet_inprogress/player

all: Mytest music_worklet

Mytest:
	$(MAKE) -C Mytest -f ActualMakefile.mk

music_worklet_decoder:
	$(MAKE) -C $(DECODERDIR)

music_worklet_player:
	$(MAKE) -C $(PLAYERDIR)

music_worklet: music_worklet_decoder music_worklet_player

Mytest_clean:
	$(MAKE) -C Mytest -f ActualMakefile.mk clean

music_worklet_decoder_clean:
	$(MAKE) -C $(DECODERDIR) clean

music_worklet_player_clean:
	$(MAKE) -C $(PLAYERDIR) clean

music_worklet_clean: music_worklet_decoder_clean music_worklet_player_clean

clean: Mytest_clean music_worklet_clean

.PHONY: all clean Mytest music_worklet music_worklet_decoder music_worklet_player Mytest_clean music_worklet_decoder_clean music_worklet_player_clean music_worklet_clean