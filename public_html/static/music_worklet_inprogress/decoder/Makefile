# source ~/emsdk/emsdk_env.sh
CC:=emcc
SRCDIR?=src
MINIAUDIODIR?=../../../../miniaudio
OUTDIR?=bin
TARGET:=$(OUTDIR)/drflac.js

CFLAGS:=-I$(MINIAUDIODIR) -DMA_NO_DEVICE_IO -DMA_NO_THREADING -DMA_NO_ENCODING -DDR_FLAC_BUFFER_SIZE=65536 -DDR_FLAC_NO_OGG -s'EXPORTED_RUNTIME_METHODS=["cwrap", "ccall"]' -sEXPORT_ES6=1 -sASSERTIONS=1 -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1

all: CFLAGS += -O3
all: $(TARGET)

$(TARGET): $(SRCDIR)/drflac_cache.c $(MINIAUDIODIR)/miniaudio.h $(SRCDIR)/block_vf.h $(SRCDIR)/mhfs_decoder.h $(SRCDIR)/network_drflac.h
	mkdir -p $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

debug: CFLAGS += -O0 -g4 --source-map-base ./src/ -s SAFE_HEAP=1
debug: $(TARGET)
	rsync -a $(SRCDIR) $(OUTDIR)/
	cp $(MINIAUDIODIR)/miniaudio.h $(OUTDIR)/src/
	cat $(OUTDIR)/drflac.wasm.map | sed -e 's|$(MINIAUDIODIR)/miniaudio.h|src/miniaudio.h|' > $(OUTDIR)/src/drflac.wasm.map

clean:
	rm -rf $(OUTDIR)/*

.PHONY: debug clean
