KERNEL_RELEASE  ?= $(shell uname -r)
KERNEL_DIR      ?= /lib/modules/$(KERNEL_RELEASE)/build
# Modules for a clang-built kernel (CONFIG_CC_IS_CLANG) must be built with LLVM=1
KERNEL_CONFIG   := $(firstword $(wildcard $(KERNEL_DIR)/include/config/auto.conf $(KERNEL_DIR)/.config /boot/config-$(KERNEL_RELEASE)))
KBUILD_LLVM     := $(if $(KERNEL_CONFIG),$(if $(shell grep -qs '^CONFIG_CC_IS_CLANG=y' $(KERNEL_CONFIG) && echo y),LLVM=1))
DKMS_TARBALL    ?= dkms.tar.gz
TAR             ?= tar
CLANG_FORMAT    ?= clang-format-18
SRCS            := brutal.h brutal_uapi.h brutal_cc.c brutal_sockopt.c brutal_rules.c brutal_genl.c tools/brutalctl.c tools/brutal_netlink.c tools/brutal_netlink.h tools/Makefile .clang-format
FORMAT_SRCS     := $(filter %.c %.h,$(SRCS))
obj-m           += brutal.o
brutal-objs     := brutal_cc.o brutal_sockopt.o brutal_rules.o brutal_genl.o

BRUTAL_BUILD_ID ?= $(shell id=$$(if test -r .tbc-release; then sed -nE 's/^COMMIT=([0-9a-f]{40})$$/\1/p' .tbc-release | head -n1; elif command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then git rev-parse HEAD; fi); if printf '%s' "$$id" | grep -Eq '^[0-9a-f]{40}$$'; then printf '%s' "$$id"; else printf '%040d' 0; fi)

ccflags-y := -std=gnu99 -DBRUTAL_BUILD_ID=\"$(BRUTAL_BUILD_ID)\"

.PHONY: all clean load unload
.PHONY: .always-make

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) $(KBUILD_LLVM) modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) $(KBUILD_LLVM) clean

load:
	sudo insmod brutal.ko

unload:
	sudo rmmod brutal

.PHONY: format format-check
format:
	$(CLANG_FORMAT) --style=file -i $(FORMAT_SRCS)

format-check:
	$(CLANG_FORMAT) --style=file --dry-run --Werror $(FORMAT_SRCS)

.PHONY: dkms-tarball clean-dkms-tarball clean-dkms.conf

.always.make:

dkms.conf: ./scripts/mkdkmsconf.sh .always-make
	BRUTAL_BUILD_ID="$(BRUTAL_BUILD_ID)" ./scripts/mkdkmsconf.sh > dkms.conf

clean-dkms.conf:
	$(RM) dkms.conf

$(DKMS_TARBALL): dkms.conf Makefile $(SRCS)
	$(TAR) --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
		-zcf $(DKMS_TARBALL) \
		--transform 's,^,./dkms_source_tree/,' \
		dkms.conf \
		Makefile \
		$(SRCS)

dkms-tarball: $(DKMS_TARBALL)

clean-dkms-tarball:
	$(RM) $(DKMS_TARBALL)
