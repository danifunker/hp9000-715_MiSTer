/* pacputest interruption vector table and the common trap handler.
 *
 * Every vector records what happened in the trap log (_traplog, RAM) and
 * resumes at the instruction after the one that trapped, so a test can
 * provoke a trap and then look at the log:
 *
 *   +0  interruption number      +16 IPSW
 *   +4  IIR                      +20 IIAOQ front (the trapping insn)
 *   +8  ISR (data traps, else 0) +24 IIAOQ back
 *   +12 IOR (data traps, else 0) +28 count of interruptions taken
 *
 * The handler works only in the shadowed registers (r1, r8, r9, r16, r17,
 * r24, r25), deliberately clobbers them, and returns with RFIR, so every
 * trap also checks that the shadow registers come back (PA-RISC 1.1
 * "shadow registers"; PCX-L implements them).
 */
	.section .ivt, "ax"
	.align	2048
	.globl	_ivt
_ivt:
	.irp	n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	ldi	\n, %r1
	b	trap_common
	nop
	nop
	nop
	nop
	nop
	nop
	.endr

	.text
trap_common:
	ldil	L%_traplog, %r8
	ldo	R%_traplog(%r8), %r8
	stw	%r1, 0(%r8)
	mfctl	%cr19, %r24
	stw	%r24, 4(%r8)
	/* ISR and IOR are defined only for data-reference interruptions */
	ldil	L%data_traps, %r24
	ldo	R%data_traps(%r24), %r24
	ldwx,s	%r1(%r24), %r25
	mfctl	%cr20, %r24
	and	%r24, %r25, %r24
	stw	%r24, 8(%r8)
	mfctl	%cr21, %r24
	and	%r24, %r25, %r24
	stw	%r24, 12(%r8)
	mfctl	%cr22, %r24
	stw	%r24, 16(%r8)
	/* the offset queue: read front, advance, read back */
	mfctl	%cr18, %r16
	mtctl	%r0, %cr18
	mfctl	%cr18, %r17
	stw	%r16, 20(%r8)
	stw	%r17, 24(%r8)
	ldw	28(%r8), %r24
	ldo	1(%r24), %r24
	stw	%r24, 28(%r8)
	/* resume after the trapping insn: queue = (back, back + 4) */
	mtctl	%r17, %cr18
	ldo	4(%r17), %r17
	mtctl	%r17, %cr18
	mfctl	%cr17, %r16
	mtctl	%r0, %cr17
	mfctl	%cr17, %r17
	mtctl	%r17, %cr17
	mtctl	%r17, %cr17
	/* prove RFIR restores the shadowed registers */
	ldi	-1, %r1
	ldi	-1, %r9
	ldi	-1, %r16
	ldi	-1, %r24
	ldi	-1, %r25
	rfir
	nop

	.section .rodata
	.align	4
data_traps:	/* per interruption number: all-ones if ISR/IOR are defined */
	.word	0, 0, 0, 0, 0, 0, 0, 0			/* 0-7 */
	.word	0, 0, 0, 0, 0, 0, 0, -1			/* 8-15: 15 data TLB miss */
	.word	0, -1, -1, -1, -1, -1, 0, 0		/* 16-23: 17-21 data */
	.word	0, 0, -1, -1, -1, 0, 0, 0		/* 24-31: 26-28 data */
