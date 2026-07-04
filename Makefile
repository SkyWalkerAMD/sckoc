CFLAGS ?= -Wall -O2 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64

all: rdmsr hsmp-msg
rdmsr: rdmsr.c version.h ; $(CC) $(CFLAGS) -I. $< -o $@
hsmp-msg: hsmp-msg.c ; $(CC) -Wall -O2 $< -o $@
install: ; bash install.sh
clean: ; rm -f rdmsr hsmp-msg
.PHONY: all install clean
