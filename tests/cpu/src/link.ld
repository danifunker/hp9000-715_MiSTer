/* pacputest: bare-metal PA-RISC 1.1 test ROM for the HP 9000/715.
 *
 * The image is a boot ROM: code and read-only data at 0xF0000000 (the CPU
 * resets to 0xF0000004), initialised data copied to RAM by crt0, bss and the
 * stack in low RAM. The same ELF boots QEMU (-M 715 -bios), and its raw
 * binary is the boot.rom of the Verilator sim and of the board.
 */
OUTPUT_FORMAT("elf32-hppa-linux")
OUTPUT_ARCH(hppa)
ENTRY(_reset)

MEMORY
{
	ROM (rx)  : ORIGIN = 0xF0000000, LENGTH = 256K
	RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 960K
}

SECTIONS
{
	.text : {
		KEEP(*(.vectors))          /* 0xF0000000: HPMC/TOC word, reset */
		. = ALIGN(2048);
		KEEP(*(.ivt))              /* interruption vector table (IVA) */
		*(.text .text.*)
		*(.rodata .rodata.*)
		. = ALIGN(8);
	} > ROM

	.data : {
		_data_start = .;
		*(.data .data.*)
		. = ALIGN(8);
		_data_end = .;
	} > RAM AT > ROM
	_data_load = LOADADDR(.data);

	.bss (NOLOAD) : {
		_bss_start = .;
		*(.bss .bss.*) *(COMMON)
		. = ALIGN(8);
		_bss_end = .;
	} > RAM

	/* gcc addresses data as dp-relative (sym - $global$); dp = $global$ */
	$global$ = _data_start;

	_stack_base = 0x00080000;      /* grows upward on PA-RISC */
	_ramtest_base = 0x00100000;    /* scratch RAM for load/store tests */
	_traplog = 0x000F0000;         /* trap log written by src/ivt.S */

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.PARISC.unwind) }
}
