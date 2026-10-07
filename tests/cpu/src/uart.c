/* LASI RS-232 (16550A) at 0xF0105800, byte registers at a one-byte stride
 * (docs/review/06b section 2). QEMU -M 715 maps its 16550 there too.
 */
#include "pacputest.h"

#define UART_BASE 0xF0105800u
#define UART_THR  0
#define UART_IER  1
#define UART_FCR  2
#define UART_LCR  3
#define UART_MCR  4
#define UART_LSR  5
#define LSR_THRE  0x20

static inline void uart_w(unsigned reg, unsigned char v)
{
	*(volatile unsigned char *)(UART_BASE + reg) = v;
}

static inline unsigned char uart_r(unsigned reg)
{
	return *(volatile unsigned char *)(UART_BASE + reg);
}

void uart_init(void)
{
	uart_w(UART_IER, 0x00);
	uart_w(UART_LCR, 0x83);		/* DLAB, 8N1 */
	uart_w(UART_THR, 48);		/* 9600 baud from 7.3728 MHz / 16 */
	uart_w(UART_IER, 0);
	uart_w(UART_LCR, 0x03);
	uart_w(UART_FCR, 0x07);		/* FIFOs on and cleared */
	uart_w(UART_MCR, 0x03);
}

void uart_putc(char c)
{
	if (c == '\n')
		uart_putc('\r');
	while (!(uart_r(UART_LSR) & LSR_THRE))
		;
	uart_w(UART_THR, (unsigned char)c);
}

void puts_(const char *s)
{
	while (*s)
		uart_putc(*s++);
}

void puthex(unsigned v, int digits)
{
	static const char hex[] = "0123456789abcdef";
	for (int i = digits - 1; i >= 0; i--)
		uart_putc(hex[(v >> (4 * i)) & 0xF]);
}
