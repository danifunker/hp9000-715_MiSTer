# pacputest -- bare-metal PA-RISC 1.1 CPU test ROMs (tests/cpu/README.md)
#
#   make            build every suite ROM (build/<suite>.elf and .bin)
#   make qemu       run them on QEMU -M 715 -> ref/qemu/<suite>.log
CROSS   ?= hppa-linux-gnu-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
SIZE    = $(CROSS)size

CFLAGS = -O1 -mpa-risc-1-1 -mschedule=7100LC -mdisable-fpregs -mno-space-regs \
	-ffreestanding -nostdlib -fno-builtin -fno-pic \
	-fno-asynchronous-unwind-tables -Wall -Isrc

SUITES = alu1 alu2 shift mem branch trap fp fpedge max1 sys
COMMON = src/crt0.S src/ivt.S src/main.c src/uart.c

all: $(SUITES:%=build/%.bin)

build/gen_%.S build/gen_%.c build/gen_%.json: gen_tests.py
	@mkdir -p build
	python3 gen_tests.py $* build

build/%.elf: build/gen_%.S build/gen_%.c $(COMMON) src/pacputest.h src/link.ld
	$(CC) $(CFLAGS) -T src/link.ld -o $@ $(COMMON) build/gen_$*.S build/gen_$*.c -lgcc
	@$(SIZE) $@ | tail -1

build/%.bin: build/%.elf
	$(OBJCOPY) -O binary $< $@

qemu: $(SUITES:%=ref/qemu/%.log)

ref/qemu/%.log: build/%.elf run_qemu.py
	@mkdir -p ref/qemu
	python3 run_qemu.py $< $@

clean:
	rm -rf build

.PHONY: all qemu clean
.PRECIOUS: build/gen_%.S build/gen_%.c build/gen_%.json build/%.elf
