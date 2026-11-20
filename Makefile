# Локальные сокращения. В CI всё то же самое дергает workflow.
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: kernel rootfs image all clean

kernel:
	bash $(ROOT)scripts/build-kernel.sh

rootfs:
	sudo -E bash $(ROOT)scripts/make-rootfs.sh

image:
	bash $(ROOT)scripts/make-image.sh

all: kernel rootfs image

clean:
	rm -rf $(ROOT)out
