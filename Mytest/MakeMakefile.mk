SHELL := /bin/sh
all: Makefile
	$(MAKE)

Makefile: Makefile.PL
	perl Makefile.PL

clean:
	$(MAKE) clean || [ ! -f Makefile ]
	rm -f Makefile

.PHONY: all