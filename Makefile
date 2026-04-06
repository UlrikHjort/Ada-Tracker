PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin

CARGS   := -gnat2022 -gnata -gnatwae -gnato -fstack-check -g
SRCDIRS := src src/formats src/engine src/ui
AICARGS := $(patsubst %,-aI%,$(SRCDIRS))

.PHONY: all clean install

ifneq ($(shell command -v gprbuild 2>/dev/null),)
all:
	gprbuild -P tracker.gpr

clean:
	gprclean -P tracker.gpr
else
all: | bin obj
	gnatmake $(AICARGS) -D obj -o bin/tracker_main src/tracker_main.adb \
	  -cargs $(CARGS) \
	  -largs -lSDL2

clean:
	$(RM) -r obj bin

bin obj:
	mkdir -p $@
endif

install: all
	install -Dm755 bin/tracker_main $(BINDIR)/tracker
