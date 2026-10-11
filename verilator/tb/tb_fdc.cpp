// tb_fdc -- rtl/lasi/lasi_fdc.sv on its own (SIM_FAST: a step millisecond
// is 64 clocks): HP's PDC 1.6 floppy self-test as it runs with fastboot off
// (HW 4.9; the ROM's sub-tests at 0xF000F904 .. 0xF0010200, replayed access
// by access), HP-UX 11i's pc_fdc probe of a drive (docs/review/10: unit
// reset, the reset interrupt, SPECIFY, RECALIBRATE ending in equipment
// check, the SENSE INTERRUPT STATUS sequence), and the other 765 commands.
//   make -C verilator tb_fdc
#include "Vlasi_fdc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vlasi_fdc* t;
static uint64_t cyc = 0;
static int fails = 0;
static std::vector<uint8_t> mem(1 << 16);
static unsigned rnd_state = 11;
static unsigned rnd() { rnd_state = rnd_state * 1103515245u + 12345u; return (rnd_state >> 16) & 0x7FFF; }

// DMA: the request is held until ack; the answer after a random latency
static int dma_wait = -1;
static int dma_words = 0;
static void dma_step() {
	t->dma_ack = 0;
	if (!t->dma_req) { dma_wait = -1; return; }
	if (dma_wait < 0) dma_wait = 2 + rnd() % 20;
	if (dma_wait-- > 0) return;
	uint32_t a = t->dma_addr & 0xFFF8;
	if (t->dma_we) {
		for (int i = 0; i < 8; i++)
			if (t->dma_be >> (7 - i) & 1) mem[a + i] = t->dma_wdata >> (56 - 8 * i);
	} else {
		uint64_t d = 0;
		for (int i = 0; i < 8; i++) d = d << 8 | mem[a + i];
		t->dma_rdata = d;
	}
	t->dma_ack = 1; dma_wait = -1; dma_words++;
}
static void tick() {
	dma_step();
	t->clk = 1; t->eval();
	t->clk = 0; t->eval();
	cyc++;
}
static void idle(int n) { for (int i = 0; i < n; i++) tick(); }

// page A byte registers: offset, byte lane 0 (as `ldb`/`stb` at the offset)
static uint8_t rb(uint32_t off) {
	t->req = 1; t->we = 0; t->pd = 0; t->addr = off; t->be = 0x8; tick(); t->req = 0; tick();
	return t->rdata >> 24;
}
static void wb(uint32_t off, uint8_t v) {
	t->req = 1; t->we = 1; t->pd = 0; t->addr = off; t->be = 0x8; t->wdata = (uint32_t)v << 24; tick();
	t->req = 0; tick();
}
// page D words
static uint32_t rd_d(uint32_t off) {
	t->req = 1; t->we = 0; t->pd = 1; t->addr = off; t->be = 0xF; tick(); t->req = 0; tick();
	return t->rdata;
}
static void wr_d(uint32_t off, uint32_t v) {
	t->req = 1; t->we = 1; t->pd = 1; t->addr = off; t->be = 0xF; t->wdata = v; tick(); t->req = 0; tick();
}
static void expect(const char* what, uint32_t got, uint32_t want) {
	if (got != want) { printf("FAIL: %s: %x, expected %x\n", what, got, want); fails++; }
	else printf("ok   %s = %x\n", what, got);
}
enum { DATA = 0x04, MSR = 0x08, FIFO = 0x14, CTL = 0x18, STAT = 0x1C, CCR = 0x20, DOR = 0x40 };
static void mb(uint32_t a, uint8_t v) { mem[a] = v; mem[a + 1] = 0x11; mem[a + 2] = 0x22; mem[a + 3] = 0x33; }

// the ROM's helpers: wait for MSR == v (20 ms there), drain the FIFO
static bool wait_msr(uint8_t v, int n = 5000) {
	for (int i = 0; i < n; i++) if (rb(MSR) == v) return true;
	return false;
}
static bool wait_stat(uint8_t bit, int n = 20000) {
	for (int i = 0; i < n; i++) if (rb(STAT) & bit) return true;
	return false;
}
// HP-UX's fdc_cmd_out / fdc_results_in
static bool cmd_out(uint8_t b) {
	for (int i = 0; i < 50; i++) if ((rb(MSR) & 0xC0) == 0x80) { wb(DATA, b); return true; }
	printf("FAIL: cmd_out(%02x): MSR %02x\n", b, rb(MSR)); fails++;
	return false;
}
static int results(uint8_t* r, int max) {
	int n = 0;
	for (;;) {
		int i; uint8_t m = 0;
		for (i = 0; i < 50; i++) if ((m = rb(MSR)) & 0x80) break;
		if (i == 50) { printf("FAIL: results: no RQM\n"); fails++; return n; }
		if (!(m & 0x40)) return n;
		if (n == max) { printf("FAIL: results: more than %d\n", max); fails++; return n; }
		r[n++] = rb(DATA);
	}
}
static bool wait_irq(int n) {
	for (int i = 0; i < n; i++) { if (t->irq) return true; tick(); }
	return false;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vlasi_fdc;
	t->rst = 1; t->req = 0;
	idle(4);
	t->rst = 0; tick();

	// ---- after a machine reset: the FDC held in reset, the FIFO empty
	expect("reset MSR", rb(MSR), 0x00);
	expect("reset status", rb(STAT), 0x02);
	expect("reset irq", t->irq, 0);

	// ---- ROM 0xF000F904: control 0, DMA off, DOR 0 then 0x0C, MSR == 0x80
	printf("-- ROM: FDC reset\n");
	wb(CTL, 0); wr_d(0x004, 0); wb(DOR, 0); idle(320); wb(DOR, 0x0C);
	expect("MSR after reset", wait_msr(0x80), 1);
	expect("no irq without FDC_IE", t->irq, 0);

	// ---- ROM 0xF000F9B0: drain the FIFO (already empty)
	expect("FIFO empty", rb(STAT) & 2, 2);

	// ---- ROM 0xF000FA24: slave FIFO
	printf("-- ROM: FIFO slave test\n");
	wr_d(0x004, 0); wb(CTL, 1);
	wb(FIFO, 0xFF); expect("1 byte: status", rb(STAT) & 7, 0);
	wb(FIFO, 0x00); expect("2 bytes: status", rb(STAT) & 7, 0);
	wb(FIFO, 0xAA); expect("3 bytes: status", rb(STAT) & 7, 0);
	wb(FIFO, 0x55); expect("4 bytes: status & 6", rb(STAT) & 6, 0);
	expect("4 bytes: FULL", rb(STAT) & 1, 1);
	expect("read 1", rb(FIFO), 0xFF); expect("3 left: status", rb(STAT) & 7, 0);
	expect("read 2", rb(FIFO), 0x00); expect("2 left: status", rb(STAT) & 7, 0);
	expect("read 3", rb(FIFO), 0xAA); expect("1 left: status", rb(STAT) & 7, 0);
	expect("read 4", rb(FIFO), 0x55); expect("empty: status & 5", rb(STAT) & 5, 0);
	expect("empty: EMPTY", rb(STAT) & 2, 2);
	wb(CTL, 0);
	wb(FIFO, 0x99); expect("slave write without WE ignored", rb(STAT) & 2, 2);

	// ---- ROM 0xF000FB68: DMA memory -> FIFO, across offset 0x1FF and the page's end
	printf("-- ROM: DMA mem -> FIFO\n");
	wb(CTL, 0); wr_d(0x004, 0);
	mb(0x47F8, 0xFF); mb(0x47FC, 0x00); mb(0x4800, 0xAA); mb(0x4804, 0x55); mb(0x4808, 0x01);
	expect("irq before", t->irq, 0);
	wb(CTL, 9);
	wr_d(0x000, 0x47F8); wr_d(0x004, 1);
	expect("DMA_IRQ", wait_stat(4), 1);
	expect("irq (DMA_IE)", t->irq, 1);
	idle(200);
	expect("FULL", rb(STAT) & 1, 1);
	expect("FIFO 1", rb(FIFO), 0xFF); idle(640);
	expect("FIFO 2", rb(FIFO), 0x00); idle(640);
	expect("FIFO 3", rb(FIFO), 0xAA); idle(640);
	expect("FIFO 4", rb(FIFO), 0x55); idle(640);
	expect("FIFO 5 (refilled)", rb(FIFO), 0x01);
	wr_d(0x004, 0); idle(100);
	for (int i = 0; i < 8 && !(rb(STAT) & 2); i++) rb(FIFO);
	expect("drained", rb(STAT) & 2, 2);
	wb(CTL, 1);
	expect("DMA_IRQ cleared by DMA_IE = 0", rb(STAT) & 4, 0);
	expect("irq cleared", t->irq, 0);
	wb(CTL, 9);
	mb(0x4FF8, 0x01); mb(0x4FFC, 0x55); mb(0x4000, 0xAA); mb(0x4004, 0x00); mb(0x4008, 0xFF);
	wr_d(0x000, 0x4FF8); wr_d(0x004, 1);
	expect("FDAR read: enable bit", rd_d(0x000) & 1, 1);
	expect("DMA_IRQ at 0x3FF", wait_stat(4), 1);
	idle(200);
	expect("FIFO 1", rb(FIFO), 0x01); idle(640);
	expect("FIFO 2", rb(FIFO), 0x55); idle(640);
	expect("FIFO 3 (wrapped)", rb(FIFO), 0xAA); idle(640);
	expect("FIFO 4", rb(FIFO), 0x00); idle(640);
	expect("FIFO 5", rb(FIFO), 0xFF);
	wr_d(0x004, 0); wb(CTL, 0); idle(100);
	for (int i = 0; i < 8 && !(rb(STAT) & 2); i++) rb(FIFO);
	expect("drained", rb(STAT) & 2, 2);
	expect("FDAR page/offset", rd_d(0x000) & ~3u, rd_d(0x004) & ~3u);

	// ---- ROM 0xF000FF4C: FIFO -> memory
	printf("-- ROM: DMA FIFO -> mem\n");
	wb(CTL, 1); wr_d(0x004, 0);
	wb(FIFO, 0xFF); wb(FIFO, 0x00); wb(FIFO, 0xAA); wb(FIFO, 0x55);
	wb(CTL, 0xA);
	expect("no DMA_IRQ yet", rb(STAT) & 4, 0);
	wr_d(0x000, 0x47F8); wr_d(0x004, 1);
	expect("DMA_IRQ", wait_stat(4), 1);
	idle(200);
	expect("EMPTY", rb(STAT) & 2, 2);
	wr_d(0x004, 0);
	expect("mem 47F8", mem[0x47F8], 0xFF); expect("mem 47FC", mem[0x47FC], 0x00);
	expect("mem 4800", mem[0x4800], 0xAA); expect("mem 4804", mem[0x4804], 0x55);
	expect("mem 4805 (low lanes 0)", mem[0x4805], 0x00);
	wb(CTL, 1);
	wb(FIFO, 0x55); wb(FIFO, 0xAA); wb(FIFO, 0x00); wb(FIFO, 0xFF);
	wb(CTL, 0xA);
	wr_d(0x000, 0x4FF8); wr_d(0x004, 1);
	expect("DMA_IRQ", wait_stat(4), 1);
	idle(200);
	expect("status DMA_IRQ|EMPTY", rb(STAT) & 6, 6);
	wr_d(0x004, 0);
	expect("mem 4FF8", mem[0x4FF8], 0x55); expect("mem 4FFC", mem[0x4FFC], 0xAA);
	expect("mem 4000", mem[0x4000], 0x00); expect("mem 4004", mem[0x4004], 0xFF);
	wb(CTL, 0);

	// ---- ROM 0xF0010200: SENSE INTERRUPT STATUS after the reset
	printf("-- ROM: SENSE INTERRUPT STATUS\n");
	expect("MSR idle", wait_msr(0x80), 1);
	wb(DATA, 0x08);
	expect("MSR result", wait_msr(0xD0), 1);
	expect("ST0 (polling, drive 0)", rb(DATA), 0xC0);   // the ROM reads one byte and leaves

	// ---- HP-UX 11i: fdc_reset, then pflop_probe's open of drive 0 (fdd_recal)
	printf("-- HP-UX: fdc_reset\n");
	wb(0x000, 0);                          // unit reset
	expect("unit reset: MSR", rb(MSR), 0x00);
	wb(CTL, 4); wb(DOR, 0); idle(128); wb(DOR, 0x0C); idle(640);
	expect("reset interrupt", t->irq, 1);
	printf("-- HP-UX: RECALIBRATE drive 0\n");
	wr_d(0x004, 0); wb(CTL, 0);
	expect("irq off with FDC_IE = 0", t->irq, 0);
	expect("FIFO empty", rb(STAT) & 2, 2);
	wb(CCR, 0);
	cmd_out(0x03); cmd_out(0xDF); cmd_out(0x02);          // SPECIFY: SRT 0xD (3 ms), HUT, HLT
	expect("MSR after SPECIFY", rb(MSR), 0x80);
	wb(DOR, 0x1C);                                         // motor 0, drive 0
	expect("DIR: disk change", rb(CCR), 0x80);
	wb(CTL, 4);
	expect("reset interrupt still pending", t->irq, 1);
	cmd_out(0x07); cmd_out(0x00);
	expect("MSR: drive 0 busy", rb(MSR), 0x81);
	cmd_out(0x08);
	uint8_t r[16];
	int n = results(r, 16);
	expect("SENSE INT 1: count", n, 2); expect("ST0 = ready change", r[0], 0xC0);
	expect("irq dropped", t->irq, 0);
	uint64_t c0 = cyc;
	expect("recalibrate interrupt", wait_irq(100000), 1);
	printf("     after %llu clocks (77 steps x 3 x 64 = %d)\n", (unsigned long long)(cyc - c0), 77 * 3 * 64);
	expect("MSR idle", rb(MSR), 0x80);
	cmd_out(0x08);
	n = results(r, 16);
	expect("SENSE INT 2: count", n, 2);
	expect("ST0 = abnormal, SE, EC", r[0], 0x70); expect("PCN", r[1], 0);
	expect("irq dropped", t->irq, 0);
	cmd_out(0x08);
	n = results(r, 16);
	expect("SENSE INT 3: count", n, 1); expect("invalid", r[0], 0x80);
	// the same on drive 1, and a seek
	cmd_out(0x07); cmd_out(0x01);
	expect("recalibrate 1 interrupt", wait_irq(100000), 1);
	cmd_out(0x08); n = results(r, 16);
	expect("drive 1: ST0", r[0], 0x71);
	printf("-- SEEK, READ DATA, SENSE DRIVE STATUS, VERSION\n");
	cmd_out(0x0F); cmd_out(0x04); cmd_out(5);
	expect("MSR: seek, no result phase", rb(MSR) & 0xF0, 0x80);
	expect("seek interrupt", wait_irq(100000), 1);
	cmd_out(0x08); n = results(r, 16);
	expect("seek: count", n, 2); expect("seek: ST0", r[0], 0x24); expect("seek: PCN", r[1], 5);
	const uint8_t rdcmd[9] = { 0xE6, 0x04, 5, 1, 3, 2, 18, 0x1B, 0xFF };
	for (int i = 0; i < 9; i++) cmd_out(rdcmd[i]);
	expect("read: interrupt", wait_irq(1000), 1);
	n = results(r, 16);
	expect("read: count", n, 7);
	expect("read: ST0", r[0], 0x44); expect("read: ST1", r[1], 0x01); expect("read: ST2", r[2], 0x00);
	expect("read: C", r[3], 5); expect("read: H", r[4], 1); expect("read: R", r[5], 3); expect("read: N", r[6], 2);
	expect("read: irq dropped", t->irq, 0);
	cmd_out(0x04); cmd_out(0x05); n = results(r, 16);
	expect("sense drive: count", n, 1); expect("ST3", r[0], 0x25);
	cmd_out(0x10); n = results(r, 16);
	expect("VERSION: count", n, 1); expect("VERSION: invalid", r[0], 0x80);
	wb(DOR, 0x14);                                         // DMA/INT gate off
	cmd_out(0x07); cmd_out(0x00);
	idle(77 * 3 * 64 + 2000);
	expect("INT gated by DOR bit 3", t->irq, 0);
	wb(DOR, 0x1C);
	expect("INT ungated", t->irq, 1);

	printf("%s (%d failures, %d DMA words, %llu clocks)\n", fails ? "FAIL" : "PASS", fails, dma_words,
	       (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
