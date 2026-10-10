// tb_harmony -- rtl/lasi/harmony.sv on its own: the registers as the ROM,
// HP-UX and Linux use them (docs/review/06a, Lasi ERS 6.4), the ROM's two
// loopback DMA tests (HW 4.8: CNTL 0x12E, record = play; 0x22E, record one
// sample behind), chained-page playback in u-law and 16-bit stereo through
// the interrupt protocol, the output's attenuation and enables, the rate.
//   make -C verilator tb_harmony
#include "Vharmony.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <vector>

static Vharmony* t;
static uint64_t cyc = 0;
static int fails = 0;
static std::vector<uint8_t> mem(1 << 20);           // physical 0 .. 1 MB
static unsigned rnd_state = 7;
static unsigned rnd() { rnd_state = rnd_state * 1103515245u + 12345u; return (rnd_state >> 16) & 0x7FFF; }

// DMA: the request is held until ack; the answer after a random latency
static int dma_wait = -1;
static void dma_step() {
	t->dma_ack = 0;
	if (!t->dma_req) { dma_wait = -1; return; }
	if (dma_wait < 0) dma_wait = 2 + rnd() % 30;
	if (dma_wait-- > 0) return;
	uint32_t a = t->dma_addr & 0xFFFF8;
	if (t->dma_we) {
		for (int i = 0; i < 8; i++)
			if (t->dma_be >> (7 - i) & 1) mem[a + i] = t->dma_wdata >> (56 - 8 * i);
	} else {
		uint64_t d = 0;
		for (int i = 0; i < 8; i++) d = d << 8 | mem[a + i];
		t->dma_rdata = d;
	}
	t->dma_ack = 1; dma_wait = -1;
}

// every new output sample (out_new), wherever the bench is
static std::vector<std::pair<int16_t,int16_t>> samples;
static void tick() {
	dma_step();
	t->clk = 1; t->eval();
	t->clk = 0; t->eval();
	cyc++;
	if (t->out_new) samples.push_back({(int16_t)t->out_l, (int16_t)t->out_r});
}

static uint32_t rd(uint32_t off) {
	t->req = 1; t->we = 0; t->addr = off; tick(); t->req = 0; tick();
	return t->rdata;
}
static void wr(uint32_t off, uint32_t v) {
	t->req = 1; t->we = 1; t->addr = off; t->wdata = v; t->be = 0xF; tick(); t->req = 0; tick();
}
static void expect(const char* what, uint32_t got, uint32_t want) {
	if (got != want) { printf("FAIL: %s: %08x, expected %08x\n", what, got, want); fails++; }
	else printf("ok   %s = %08x\n", what, got);
}
static void wait_c() { for (int n = 0; n < 100000 && (rd(0x08) & 0x80000000u); n++) ; }
// wait for DSTATUS to read v (up to n clocks)
static bool wait_ds(uint32_t v, long n) {
	for (long i = 0; i < n; i += 2) if (rd(0x20) == v) return true;
	return false;
}

static int16_t ulaw(uint8_t u) {          // Sun's g711.c
	u = ~u; int t = ((u & 0x0F) << 3) + 0x84; t <<= (u & 0x70) >> 4;
	return (u & 0x80) ? (0x84 - t) : (t - 0x84);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vharmony;
	t->rst = 1; t->req = 0;
	for (int i = 0; i < 4; i++) tick();
	t->rst = 0; tick();

	// ---- reset values (ERS 6.4)
	expect("ID", rd(0x00), 0x00140000);
	expect("RESET powers up 1", rd(0x04), 1);
	expect("CNTL at reset", rd(0x08), 0);
	expect("DSTATUS at reset (PN, RN)", rd(0x20), 0x00000202);
	expect("DIAG while the codec is held", rd(0x3C), 1);
	// CNTL: any write sets C; the low 18 bits read back (the ROM writes walking ones without waiting)
	{
		int bad = 0;
		for (int b = 0; b < 18; b++) { wr(0x08, 1u << b); if ((rd(0x08) & 0x3FFFF) != (1u << b)) bad++; }
		expect("CNTL walking ones (low 18 bits)", bad, 0);
		expect("CNTL sets C", rd(0x08) >> 31, 1);
		uint64_t c0 = cyc; wait_c();
		printf("     C cleared after %llu clocks\n", (unsigned long long)(cyc - c0));
		expect("C clears", rd(0x08) >> 31, 0);
	}
	wr(0x0C, 0xFFFFFFFF); expect("GAINCTL 28 bits", rd(0x0C), 0x0FFFFFFF);
	wr(0x14, 0x12345678); expect("PCURADD writable", rd(0x14), 0x12345678);
	wr(0x1C, 0x9ABCDEF0); expect("RCURADD writable", rd(0x1C), 0x9ABCDEF0);
	wr(0x28, 0xC); expect("PIO (PI mirrors PO)", rd(0x28), 0xF);

	// ---- the ROM's audio DMA test (F_f00106b4): loopback 01, then 10
	const uint32_t PLAY = 0x10000, REC = 0x20000;
	for (int pass = 0; pass < 2; pass++) {
		for (int k = 0; k < 1024; k++) {
			uint32_t v = k < 512 ? (1u << (k & 31)) : ~(1u << (k & 31));
			v ^= k * 0x01010101u;
			for (int j = 0; j < 4; j++) mem[PLAY + 4 * k + j] = v >> (24 - 8 * j);
			for (int j = 0; j < 4; j++) mem[REC + 4 * k + j] = 0;
		}
		wr(0x0C, 0x00F00FFF);
		wr(0x04, 1); for (int i = 0; i < 1000; i++) tick(); wr(0x04, 0);
		wr(0x08, pass == 0 ? 0x12E : 0x22E); wait_c();
		bool irq_seen = false;
		wr(0x20, pass == 0 ? 0x80000000 : 0);
		if (t->irq) irq_seen = true;
		wr(0x10, PLAY); wr(0x18, REC);
		uint32_t ie = pass == 0 ? 0x80000000 : 0;
		expect(pass == 0 ? "loopback 01: DMA running (0x80000303)" : "loopback 10: DMA running (0x303)", rd(0x20), ie | 0x303);
		uint64_t c0 = cyc;
		bool done = wait_ds(ie | 0x202, 4000000);
		printf("     the page took %llu clocks (1024 samples at 48 kHz: %d)\n", (unsigned long long)(cyc - c0), 64000000 / 48000 * 1024);
		expect(pass == 0 ? "loopback 01: DMA done (0x80000202)" : "loopback 10: DMA done (0x202)", rd(0x20), ie | 0x202);
		if (pass == 0) expect("the interrupt with IE (IE, PN, RN)", irq_seen, 1);
		int bad = 0, off = pass == 0 ? 0 : 1;
		for (int k = 0; k + off < 1024; k++)
			for (int j = 0; j < 4; j++) if (mem[PLAY + 4 * k + j] != mem[REC + 4 * (k + off) + j]) {
				if (bad < 4) printf("  word %d: play %02x%02x%02x%02x, record %02x%02x%02x%02x\n", k,
					mem[PLAY + 4 * k], mem[PLAY + 4 * k + 1], mem[PLAY + 4 * k + 2], mem[PLAY + 4 * k + 3],
					mem[REC + 4 * (k + off)], mem[REC + 4 * (k + off) + 1], mem[REC + 4 * (k + off) + 2], mem[REC + 4 * (k + off) + 3]);
				bad++; break; }
		expect(pass == 0 ? "record = play (loopback 01)" : "record = play one sample later (loopback 10)", bad, 0);
		(void)done;
	}

	// ---- playback: u-law mono at 48 kHz over three chained pages (the
	// interrupt protocol: IE off, the next addresses, IE on again while
	// pages remain), speaker on, no attenuation; record into a "graveyard"
	{
		const uint32_t P0 = 0x40000, GY = 0x80000;
		for (int i = 0; i < 3 * 4096; i++) mem[P0 + i] = (i * 7 + i / 13) & 0xFF;
		wr(0x20, 0); wr(0x0C, 0x02F00000); wr(0x08, 0x4E); wait_c();      // DF 01 u-law, mono, 48 kHz
		int given = 0, irqs = 0;
		std::vector<int16_t> got;
		samples.clear();
		wr(0x20, 0x80000000);
		uint64_t c0 = cyc;
		while (cyc - c0 < 20000000 && (given == 0 || (rd(0x20) & 0x101))) {
			if (t->irq) {
				irqs++;
				uint32_t ds = rd(0x20); wr(0x20, ds & 0x7FFFFFFF);
				if ((ds & 0x200) && given < 3) wr(0x10, P0 + 4096 * given);
				if ((ds & 0x002) && given < 3) { wr(0x18, GY); given++; }
				if (given < 3) wr(0x20, 0x80000000);
			}
			for (int i = 0; i < 8; i++) tick();
		}
		for (auto& p : samples) got.push_back(p.first);
		printf("     %d interrupts, %zu samples, DSTATUS %08x\n", irqs, got.size(), rd(0x20));
		expect("u-law: three pages given", given, 3);
		expect("u-law: playback stopped after the last page (PC = RC = 0)", rd(0x20) & 0x101, 0);
		// the samples: the first sample periods before the DMA started are silent;
		// then every byte of the three pages in order
		size_t st = 0;
		while (st < got.size() && got[st] == 0) st++;
		int bad = 0;
		for (int i = 0; i < 3 * 4096; i++) {
			int16_t want = ulaw(mem[P0 + i]);
			if (st + i >= got.size() || got[st + i] != want) { if (bad < 4) printf("  sample %d: %d, expected %d\n", i, st + i < got.size() ? got[st + i] : -99999, want); bad++; }
		}
		if (mem[P0] == 0xFF || ulaw(mem[P0]) == 0) printf("     (the first sample decodes to 0)\n");
		expect("u-law samples across the page chain", bad, 0);
	}

	// ---- the samples themselves: 16-bit stereo at 48 kHz from one page,
	// headphones on; LO 0 dB, RO 6 dB (4 steps: x0.5)
	{
		const uint32_t P = 0x50000, GY = 0x80000;
		for (int k = 0; k < 1024; k++) {
			int16_t l = (int16_t)(k * 31 - 16000), r = (int16_t)(12000 - k * 23);
			mem[P + 4 * k] = l >> 8; mem[P + 4 * k + 1] = l; mem[P + 4 * k + 2] = r >> 8; mem[P + 4 * k + 3] = r;
		}
		wr(0x20, 0); wr(0x0C, 0x08F00004); wr(0x08, 0x2E); wait_c();
		wr(0x10, P); wr(0x18, GY);
		samples.clear();
		uint64_t c0 = cyc;
		while (cyc - c0 < 3000000 && (rd(0x20) & 0x101)) for (int i = 0; i < 8; i++) tick();
		// the samples from the first one played (the periods before the DMA's start are silent)
		std::vector<std::pair<int,int>> s;
		for (auto& p : samples) if (!s.empty() || p.first || p.second) s.push_back({p.first, p.second});
		uint64_t took = cyc - c0;
		int bad = 0;
		// every sample's left value is distinct, so the changes are the samples
		for (size_t i = 0; i < s.size() && i < 1024; i++) {
			int16_t l = (int16_t)(i * 31 - 16000), r = (int16_t)(12000 - i * 23);
			int wl = l, wr_ = (int)std::floor(r * 16384.0 / 32768.0);
			if (s[i].first != wl || std::abs(s[i].second - wr_) > 1) { if (bad < 4) printf("  sample %zu: %d %d, expected %d %d\n", i, s[i].first, s[i].second, wl, wr_); bad++; }
		}
		expect("16-bit stereo samples (1024)", s.size() >= 1024 ? 1024 : s.size(), 1024);
		expect("16-bit stereo values, LO 0 dB / RO -6 dB", bad, 0);
		double hz = 1024.0 * 64e6 / took;
		printf("     1024 samples in %llu clocks: %.1f Hz\n", (unsigned long long)took, hz);
		(void)hz;
		expect("48 kHz within 0.5 %", std::fabs(hz - 48000) < 240, 1);
	}
	// outputs off: no sound
	{
		const uint32_t P = 0x50000, GY = 0x80000;
		wr(0x0C, 0x00F00000); wr(0x10, P); wr(0x18, GY);
		samples.clear();
		int nz = 0; uint64_t c0 = cyc;
		while ((rd(0x20) & 0x101) && cyc - c0 < 3000000) for (int i = 0; i < 8; i++) tick();
		for (auto& p : samples) if (p.first || p.second) nz++;
		expect("HE = LE = SE = 0: silent", nz, 0);
		expect("... while it played", samples.size() > 1000, 1);
	}
	expect("DIAG in data mode toggles", [&]{ int ones = 0; for (int i = 0; i < 200; i++) { ones += rd(0x3C) & 1; for (int j = 0; j < 37; j++) tick(); } return ones > 20 && ones < 180; }(), 1);

	printf("%s (%llu cycles)\n", fails ? "FAILED" : "PASS", (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
