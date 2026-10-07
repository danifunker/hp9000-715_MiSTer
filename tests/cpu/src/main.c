/* pacputest main: run every generated group and print its vectors.
 *
 * Output (one line per vector, then a CRC per group) is compared host-side
 * against the reference log: QEMU -M 715 for instructions QEMU models
 * correctly, a Python model for the ones it does not (tests/cpu/README.md).
 *
 *   == <suite> <group> <vectors>
 *   <idx> <word0> <word1> ...
 *   -- <group> crc <crc32> traps <n>
 *
 * "traps" counts the interruptions the group took (src/ivt.S keeps the
 * count): the handler resumes after a faulting insn, so an unexpected trap
 * would otherwise show up only as odd data.
 */
#include "pacputest.h"

static unsigned results[4096 * 4] __attribute__((aligned(8)));
extern volatile unsigned _traplog[8];

static unsigned crc32_update(unsigned crc, unsigned w)
{
	for (int b = 0; b < 32; b++) {
		unsigned bit = ((w >> (31 - b)) ^ (crc >> 31)) & 1;
		crc = (crc << 1) ^ (bit ? 0x04C11DB7u : 0);
	}
	return crc;
}

int main(void)
{
	uart_init();
	puts_("\npacputest ");
	puts_(tsuite_name);
	puts_("\n");

	for (int g = 0; g < tgroup_count; g++) {
		const struct tgroup *t = &tgroups[g];
		unsigned crc = 0xFFFFFFFFu;

		unsigned traps0 = _traplog[7];
		t->run(results);
		unsigned traps = _traplog[7] - traps0;
		puts_("== ");
		puts_(t->name);
		puts_(" ");
		puthex(t->vectors, 4);
		puts_("\n");
		for (int v = 0; v < t->vectors; v++) {
			puthex(v, 4);
			for (int w = 0; w < t->words; w++) {
				unsigned x = results[v * t->words + w];
				uart_putc(' ');
				puthex(x, 8);
				crc = crc32_update(crc, x);
			}
			uart_putc('\n');
		}
		puts_("-- ");
		puts_(t->name);
		puts_(" crc ");
		puthex(~crc, 8);
		puts_(" traps ");
		puthex(traps, 4);
		puts_("\n");
	}
	return 0;
}

void tst_halt(void)
{
	puts_("\n== end\n");
}

void tst_hpmc(void)
{
	puts_("\n!! HPMC/TOC taken -- no handler\n");
}
