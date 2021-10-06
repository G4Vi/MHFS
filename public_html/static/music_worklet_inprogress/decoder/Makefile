# source ~/emsdk/emsdk_env.sh
CC:=emcc
SRCDIR?=src
OUTDIR?=bin
TARGET:=$(OUTDIR)/drflac.js

CFLAGS:=-DNETWORK_DR_FLAC_FORCE_REDBOOK -DDR_FLAC_NO_OGG -s'EXPORTED_RUNTIME_METHODS=["cwrap", "ccall"]' -sEXPORT_ES6=1 -sASSERTIONS=1 -sALLOW_MEMORY_GROWTH=1 -sMODULARIZE=1

all: CFLAGS += -O3
all: $(TARGET)

$(TARGET): $(SRCDIR)/drflac_cache.c
	mkdir -p $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $^

debug: CFLAGS += -O0 -g4 --source-map-base ./src/ -s SAFE_HEAP=1
debug: $(TARGET)
	rsync -a $(SRCDIR) $(OUTDIR)/
	cp $(OUTDIR)/drflac.wasm.map $(OUTDIR)/src/drflac.wasm.map

clean:
	rm -rf $(OUTDIR)/*

.PHONY: debug clean
