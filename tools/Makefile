CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c99 -pedantic

brutalctl: brutalctl.c ../brutal_uapi.h
	$(CC) $(CFLAGS) -o $@ $<

.PHONY: clean
clean:
	$(RM) brutalctl
