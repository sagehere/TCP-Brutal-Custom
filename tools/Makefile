CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c99 -pedantic

brutalctl: brutalctl.c brutal_netlink.c brutal_netlink.h ../brutal_uapi.h
	$(CC) $(CFLAGS) -o $@ brutalctl.c brutal_netlink.c

.PHONY: clean
clean:
	$(RM) brutalctl
