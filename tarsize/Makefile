
CFLAGS=-Wall -fPIC
LDFLAGS=-shared
LDLIBS=-ldl

all: tarsize.so tarpart.so

tarsize.so: tarsize.c
	$(CC) $(CFLAGS) $(LDFLAGS) $(LDLIBS) -o $@ $^

tarpart.so: tarpart.c
	$(CC) $(CFLAGS) $(LDFLAGS) $(LDLIBS) -o $@ $^

clean:
	rm -f tarsize.so tarpart.so

.PHONY: clean all