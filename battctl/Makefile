CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
PREFIX  ?= /usr/local

all: battctl

battctl: battctl.c
	$(CC) $(CFLAGS) -o $@ $<

install: battctl
	./install.sh

uninstall:
	./install.sh uninstall

clean:
	rm -f battctl

.PHONY: all install uninstall clean
