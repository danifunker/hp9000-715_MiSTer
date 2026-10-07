/* pacputest startup: reset vector, stack, data copy, bss clear, main().
 *
 * 0xF0000000 is where a PA7100LC sends HPMC and TOC; 0xF0000004 is reset.
 * The stack grows upward from _stack_base (the PA-RISC convention: sp points
 * past the frame, the frame marker sits below it).
 */
	.section .vectors, "ax"
	.globl	_vectors
_vectors:
	b,n	_hpmc_entry		/* 0xF0000000: HPMC / TOC */
	.globl	_reset
_reset:
	b,n	_start			/* 0xF0000004: reset */
	.word	0, 0

	.text
	.globl	_start
_start:
	/* interrupts off, a clean PSW is what reset gives us (PL0, real mode) */
	mtctl	%r0, %cr15		/* EIEM = 0 */
	ldil	L%_ivt, %r1		/* IVA = our vector table (src/ivt.S) */
	ldo	R%_ivt(%r1), %r1
	mtctl	%r1, %cr14
	/* Normalise the PSW with an RFI, as firmware does: IPSW = Q only.
	 * Q = 1 makes interruptions record IIAOQ/IIASQ/IIR/ISR/IOR (ACD p.4-16;
	 * QEMU records them regardless, a real CPU does not), and the RFI also
	 * clears PSW.M, which a PA7100LC resets to 1 and only an RFI or an
	 * interruption can clear (QEMU resets it to 0). The CR17/18 writes
	 * fill the IIA queues (PSW.Q is 0 here). */
	mtctl	%r0, %cr17
	mtctl	%r0, %cr17
	ldil	L%1f, %r1
	ldo	R%1f(%r1), %r1
	mtctl	%r1, %cr18
	ldo	4(%r1), %r1
	mtctl	%r1, %cr18
	ldi	8, %r1
	mtctl	%r1, %cr22
	rfi
	nop
1:

	/* stack and data pointer */
	ldil	L%_stack_base, %sp
	ldo	R%_stack_base+64(%sp), %sp
	ldil	L%$global$, %dp
	ldo	R%$global$(%dp), %dp

	/* copy .data from ROM to RAM */
	ldil	L%_data_load, %r3
	ldo	R%_data_load(%r3), %r3
	ldil	L%_data_start, %r4
	ldo	R%_data_start(%r4), %r4
	ldil	L%_data_end, %r5
	ldo	R%_data_end(%r5), %r5
1:	comb,>>=,n %r4, %r5, 2f
	ldw,ma	4(%r3), %r6
	b	1b
	stw,ma	%r6, 4(%r4)
2:
	/* clear .bss */
	ldil	L%_bss_start, %r4
	ldo	R%_bss_start(%r4), %r4
	ldil	L%_bss_end, %r5
	ldo	R%_bss_end(%r5), %r5
3:	comb,>>=,n %r4, %r5, 4f
	b	3b
	stw,ma	%r0, 4(%r4)
4:
	bl	main, %rp
	nop

	/* main returned: report, then park */
	.globl	_halt
_halt:
	bl	tst_halt, %rp
	nop
5:	b,n	5b

_hpmc_entry:
	/* HPMC or TOC with no handler installed: say so and stop */
	ldil	L%_stack_base, %sp
	ldo	R%_stack_base+0x4000(%sp), %sp
	ldil	L%$global$, %dp
	ldo	R%$global$(%dp), %dp
	bl	tst_hpmc, %rp
	nop
6:	b,n	6b
