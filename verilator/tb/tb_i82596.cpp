// tb_i82596 -- rtl/lasi/i82596.sv on its own, against a memory and a
// Main_MiSTer-style mailbox: the start-up handshake, PORT self-test and
// alternative SCP, the initialisation (ISCP busy, CX|CNA), IA setup and
// configure, an internal-loopback frame into a simplified RFD, the ROM's
// "Trying LAN" sequence (docs: the session's ROM analysis; RFDs of 14 bytes
// + RBDs, internal and external loopback, the RBD pointer the chip writes,
// RU abort, the RU state already written when the command word clears,
// padding), a Linux-style flexible RFD/RBD ring fed from the bridge's RX
// slots (address filter, FCS stripped, RBD chaining, EL), and transmits
// through TBD chains into the TX slots.
//   make -C verilator tb_i82596
#include "Vi82596.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <functional>

static Vi82596* t;
static uint64_t cyc = 0;
static int fails = 0;
static std::vector<uint8_t> mem(1 << 20);
static std::vector<uint64_t> mbx(8192);
static unsigned rnd_state = 7;
static unsigned rnd() { rnd_state = rnd_state * 1103515245u + 12345u; return (rnd_state >> 16) & 0x7FFF; }

static void w8(uint32_t a, uint8_t v) { mem[a] = v; }
static void w16(uint32_t a, uint16_t v) { mem[a] = v >> 8; mem[a + 1] = v; }
static void wp(uint32_t a, uint32_t v) { w16(a, v & 0xFFFF); w16(a + 2, v >> 16); }   // a pointer: low half first
static uint16_t r16(uint32_t a) { return mem[a] << 8 | mem[a + 1]; }
static uint32_t rp(uint32_t a) { return r16(a) | (uint32_t)r16(a + 2) << 16; }

static const uint32_t SCP = 0x17A0, ISCP = 0x17B4, SCB = 0x17BC;
static int dma_wait = -1, nb_wait = -1;
static uint16_t stat_at_clear = 0xFFFF;               // the SCB status when the chip last cleared the command
static void bus_step() {
	t->dma_ack = 0;
	if (!t->dma_req) dma_wait = -1;
	else {
		if (dma_wait < 0) dma_wait = 2 + rnd() % 20;
		if (dma_wait-- == 0) {
			uint32_t a = t->dma_addr & 0xFFFF8;
			if (t->dma_we) {
				for (int i = 0; i < 8; i++)
					if (t->dma_be >> (7 - i) & 1) mem[a + i] = t->dma_wdata >> (56 - 8 * i);
				if (a == ((SCB + 2) & ~7u) && (t->dma_be >> (7 - ((SCB + 2) & 7)) & 1))
					stat_at_clear = mem[SCB] << 8 | mem[SCB + 1];
			} else {
				uint64_t d = 0;
				for (int i = 0; i < 8; i++) d = d << 8 | mem[a + i];
				t->dma_rdata = d;
			}
			t->dma_ack = 1; dma_wait = -1;
		}
	}
	t->nb_ack = 0;
	if (!t->nb_req) nb_wait = -1;
	else {
		if (nb_wait < 0) nb_wait = 2 + rnd() % 20;
		if (nb_wait-- == 0) {
			if (t->nb_we) mbx[t->nb_addr] = t->nb_wdata;
			else t->nb_rdata = mbx[t->nb_addr];
			t->nb_ack = 1; nb_wait = -1;
		}
	}
}
static int irq_edges = 0, irq_q = 0;
static void tick() {
	bus_step();
	t->clk = 1; t->eval();
	t->clk = 0; t->eval();
	cyc++;
	if (t->irq && !irq_q) irq_edges++;
	irq_q = t->irq;
}
static void run(int n) { for (int i = 0; i < n; i++) tick(); }
static void wr(uint32_t off, uint32_t v) {
	t->req = 1; t->we = 1; t->addr = off; t->wdata = v; tick(); t->req = 0; tick();
}
static void port(uint32_t v) { wr(4, v & 0xFFFF); wr(4, v >> 16); }
static void expect(const char* what, uint32_t got, uint32_t want) {
	if (got != want) { printf("FAIL: %s: %08x, expected %08x\n", what, got, want); fails++; }
	else printf("ok   %s = %08x\n", what, got);
}

// the mailbox (word offsets)
enum { MAGIC = 0, GEN = 1, TXW = 2, TXR = 3, RXW = 4, RXR = 5, MAC = 6 };
static const uint32_t TXS = 0x200, RXS = 0xA00;
static void post_rx(const std::vector<uint8_t>& f) {     // Main: a frame, its FCS appended, into the next RX slot
	uint64_t w = mbx[RXW];
	uint32_t s = RXS + 0x100 * (w % 16);
	std::vector<uint8_t> b(f);
	for (int i = 0; i < 4; i++) b.push_back(0xC0 + i);
	size_t n = b.size();
	b.resize((b.size() + 7) & ~7u);
	for (size_t i = 0; i < b.size(); i += 8) {
		uint64_t d = 0;
		for (int j = 7; j >= 0; j--) d = d << 8 | b[i + j];
		mbx[s + 1 + i / 8] = d;
	}
	mbx[s] = n;
	mbx[RXW] = w + 1;
}
static std::vector<uint8_t> tx_slot(uint64_t i) {
	uint32_t s = TXS + 0x100 * (i % 8);
	std::vector<uint8_t> f(mbx[s] & 0x7FF);
	for (size_t k = 0; k < f.size(); k++) f[k] = mbx[s + 1 + k / 8] >> (8 * (k % 8));
	return f;
}

static const uint8_t MYMAC[6] = { 0x08, 0x00, 0x09, 0x12, 0x34, 0x56 };
static const uint8_t BC6[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
static std::vector<uint8_t> frame(const uint8_t* da, int len, int seed) {
	std::vector<uint8_t> f(len);
	for (int i = 0; i < len; i++) f[i] = i < 6 ? da[i] : i < 12 ? 0x20 + i : (uint8_t)(seed * 7 + i * 13);
	return f;
}

static void scb_cmd(uint16_t c) { w16(SCB + 2, c); wr(8, 1); run(2000); }

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vi82596;
	t->rst = 1; t->rst_lan = 0; run(5); t->rst = 0;
	mbx[TXW] = 5; mbx[TXR] = 41; mbx[RXW] = 0x1502140d41403094ull; mbx[RXR] = 3;   // stale memory
	run(1000);
	expect("mailbox magic", mbx[MAGIC] >> 32, 0x48504554);
	expect("ring pointers zeroed", (mbx[TXW] | mbx[TXR] | mbx[RXW] | mbx[RXR]) != 0, 0);

	// self-test, then the ROM's alternative SCP (0x17A2 = 0x17A0 | 2)
	memset(&mem[0x1000], 0xFF, 8);
	port(0x1001); run(500);
	expect("self-test signature", rp(0x1000), 0);
	expect("self-test result", rp(0x1004), 0);
	port(0x17A2); run(10);
	w8(SCP + 3, 0x6C); wp(SCP + 8, ISCP);
	wp(ISCP, 1); wp(ISCP + 4, SCB);
	irq_edges = 0;
	wr(8, 1); run(1000);
	expect("ISCP busy cleared", rp(ISCP), 0);
	expect("SCB status after init", r16(SCB), 0xA000);
	expect("interrupt", irq_edges, 1);
	scb_cmd(0xA000);
	expect("SCB status acked", r16(SCB), 0x0000);
	expect("SCB command cleared", r16(SCB + 2), 0);
	expect("interrupt down", t->irq, 0);

	// IA setup -> configure (internal loopback) -> transmit 60 bytes; RU start on a simplified RFD
	w16(0x2000, 0); w16(0x2002, 0x0001); wp(0x2004, 0x2020);
	for (int i = 0; i < 6; i++) w8(0x2008 + i, MYMAC[i]);
	static const uint8_t cfg[14] = { 0x8E, 0xC8, 0x80, 0x6E, 0x00, 0x60, 0x00, 0xF2, 0x00, 0x00, 0x40, 0xFB, 0x00, 0x7F };
	w16(0x2020, 0); w16(0x2022, 0x0002); wp(0x2024, 0x2044);
	for (int i = 0; i < 14; i++) w8(0x2028 + i, cfg[i]);
	std::vector<uint8_t> f0 = frame(MYMAC, 60, 1);
	w16(0x2044, 0); w16(0x2046, 0xA004); wp(0x2048, 0xFFFFFFFF);  // EL | I | transmit, simplified
	wp(0x204C, 0xFFFFFFFF); w16(0x2050, 0x8000 | 60);
	memcpy(&mem[0x2054], f0.data(), 60);
	w16(0x3000, 0); w16(0x3002, 0x8000); wp(0x3004, 0x3000); wp(0x3008, 0xFFFFFFFF);
	w16(0x300C, 0); w16(0x300E, 1518);
	wp(SCB + 4, 0x2000); wp(SCB + 8, 0x3000);
	irq_edges = 0;
	scb_cmd(0x0110);
	expect("IA CB status", r16(0x2000), 0xA000);
	expect("configure CB status", r16(0x2020), 0xA000);
	expect("transmit CB status", r16(0x2044), 0xA000);
	expect("mailbox station address", mbx[MAC] >> 32, 0x80000800);
	expect("mailbox station address low", (uint32_t)mbx[MAC], 0x09123456);
	expect("RFD status", r16(0x3000), 0xA000);
	expect("RFD count", r16(0x300C), 0xC000 | 60);
	expect("loopback frame", memcmp(&mem[0x3010], f0.data(), 60), 0);
	expect("SCB status CX FR CNA RNR, RU no resources", r16(SCB), 0xF020);
	expect("interrupts", irq_edges, 1);
	scb_cmd(0xF000);
	expect("SCB status acked", r16(SCB), 0x0020);

	// the ROM's "Trying LAN": hardware reset, self-test, alternative SCP, CA; configure 0x2E, IA,
	// RU start on 10 RFDs (size 14) + 10 RBDs (256 bytes); configure 0x6E + a 60-byte frame; 0xEE + another
	wr(0, 1); run(50);
	port(0x1001); run(500); port(0x17A2); wr(8, 1); run(1000);
	expect("ROM: init status", r16(SCB) >> 12, 0xA);
	scb_cmd(0xA000);
	static const uint8_t rcfg[12] = { 0x8C, 0xC8, 0x00, 0x2E, 0x00, 0x60, 0x00, 0xF2, 0x00, 0x00, 0x40, 0xFD };
	auto rom_cb = [](uint16_t cmd, std::function<void(uint32_t)> body) {
		uint32_t c = 0x1F00;
		memset(&mem[c], 0, 0x80);
		w16(c, 0); w16(c + 2, 0x8000 | cmd); wp(c + 4, 0xFFFFFFFF);
		body(c);
		wp(SCB + 4, c);
		w16(SCB + 2, (mem[SCB + 2] << 8 | mem[SCB + 3]) | 0x0100); wr(8, 1); run(3000);
		uint16_t st = r16(c);
		scb_cmd(r16(SCB) & 0xF000);
		return st;
	};
	auto rom_conf = [&](uint8_t b3) {
		return rom_cb(2, [&](uint32_t c) { for (int i = 0; i < 12; i++) w8(c + 8 + i, i == 3 ? b3 : rcfg[i]); });
	};
	expect("ROM: configure", rom_conf(0x2E), 0xA000);
	expect("ROM: IA setup", rom_cb(1, [](uint32_t c) { memcpy(&mem[c + 8], MYMAC, 6); }), 0xA000);
	for (int n = 0; n < 10; n++) {
		uint32_t r = 0x800 + 0x20 * n, b = 0x940 + 0x20 * n;
		w16(r, 0); w16(r + 2, n == 9 ? 0x8008 : 0x0008); wp(r + 4, n == 9 ? 0x800 : r + 0x20);
		wp(r + 8, n == 0 ? 0x940 : 0xFFFFFFFF); w16(r + 12, 0); w16(r + 14, 14);
		w16(b, 0); wp(b + 4, n == 9 ? 0x940 : b + 0x20); wp(b + 8, 0xA80 + 0x100 * n); w16(b + 12, n == 9 ? 0x8100 : 0x100);
	}
	wp(SCB + 8, 0x800);
	w16(SCB + 2, 0x0010); wr(8, 1); run(2000);
	expect("ROM: RU state ready when the command cleared", stat_at_clear >> 4 & 0xF, 4);
	std::vector<uint8_t> lf(60, 0x55);
	memcpy(&lf[0], MYMAC, 6); memcpy(&lf[6], MYMAC, 6); lf[12] = 0x08; lf[13] = 0x00;
	auto rom_tx = [&](const std::vector<uint8_t>& f) {
		memcpy(&mem[0x1E00], f.data(), f.size());
		return rom_cb(4, [&](uint32_t c) {
			w16(c + 2, 0x800C); wp(c + 8, c + 0x40); w16(c + 12, 0);
			w16(c + 0x40, 0x8000 | f.size()); wp(c + 0x44, 0xFFFFFFFF); wp(c + 0x48, 0x1E00);
		});
	};
	expect("ROM: configure internal loopback", rom_conf(0x6E), 0xA000);
	expect("ROM: transmit", rom_tx(lf), 0xA000);
	expect("ROM: RFD 0x800 status", r16(0x800), 0xA000);
	expect("ROM: RFD 0x800 count", r16(0x80C) & 0x3FFF, 14);
	expect("ROM: RFD source address", memcmp(&mem[0x816], MYMAC, 6), 0);
	expect("ROM: RBD 0x940 count", r16(0x940), 0xC000 | 46);
	expect("ROM: frame", memcmp(&mem[0x810], lf.data(), 14) || memcmp(&mem[0xA80], lf.data() + 14, 46), 0);
	expect("ROM: RFD 0x820 told its RBD", rp(0x828), 0x960);
	expect("ROM: configure external loopback", rom_conf(0xEE), 0xA000);
	lf[20] = 0x11;
	expect("ROM: transmit 2", rom_tx(lf), 0xA000);
	expect("ROM: RFD 0x820 status", r16(0x820), 0xA000);
	expect("ROM: RFD 0x820 RBD", rp(0x828), 0x960);
	expect("ROM: frame 2", memcmp(&mem[0xB80], lf.data() + 14, 46), 0);
	expect("ROM: configure", rom_conf(0x2E), 0xA000);
	w16(SCB + 2, 0x0040); wr(8, 1); run(2000);
	expect("ROM: RU idle after the abort", stat_at_clear >> 4 & 0xF, 0);
	scb_cmd(r16(SCB) & 0xF000);
	// a short frame to the bridge is padded (configure byte 11 LNGFLD = 0)
	uint64_t txp = mbx[TXW];
	std::vector<uint8_t> arp = frame(BC6, 42, 9);
	expect("ROM: short transmit", rom_tx(arp), 0xA000);
	std::vector<uint8_t> arp60(arp); arp60.resize(60, 0);
	expect("ROM: padded to 60", tx_slot(txp) == arp60, 1);

	// configure as Linux (no loopback, CRC in memory), RFD ring with RBDs, frames from the bridge
	for (int i = 0; i < 14; i++) w8(0x2028 + i, cfg[i]);
	w8(0x2028 + 3, 0x2E); w8(0x2028 + 11, 0xFF);
	w16(0x2020, 0); w16(0x2022, 0x8002);
	wp(SCB + 4, 0x2020);
	for (int i = 0; i < 4; i++) {
		uint32_t r = 0x4000 + 32 * i;
		w16(r, 0); w16(r + 2, i == 3 ? 0x8008 : 0x0008); wp(r + 4, 0x4000 + 32 * ((i + 1) % 4));
		wp(r + 8, i == 0 ? 0x5000 : 0xFFFFFFFF); w16(r + 12, 0); w16(r + 14, 0);
	}
	for (int i = 0; i < 8; i++) {
		uint32_t b = 0x5000 + 32 * i;
		w16(b, 0); wp(b + 4, 0x5000 + 32 * ((i + 1) % 8)); wp(b + 8, 0x10000 + 0x200 * i); w16(b + 12, 512);
	}
	wp(SCB + 8, 0x4000);
	scb_cmd(0x0110);
	expect("configure CB status", r16(0x2020), 0xA000);
	expect("RU ready", r16(SCB) & 0x00F0, 0x0040);
	static const uint8_t BC[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, OTHER[6] = { 0x08, 0x00, 0x09, 0x99, 0x99, 0x99 };
	std::vector<uint8_t> f1 = frame(MYMAC, 104, 2), f2 = frame(BC, 64, 3), f3 = frame(OTHER, 64, 4), f4 = frame(MYMAC, 1204, 5);
	post_rx(f1); post_rx(f2); post_rx(f3); post_rx(f4);
	run(60000);
	expect("RXR took all four", mbx[RXR], 4);
	expect("RFD0 status", r16(0x4000), 0xA000);
	expect("RFD0 RBD", rp(0x4008), 0x5000);
	expect("RFD0 count (the frame went on into RBDs: no EOF)", r16(0x400C), 0x4000);
	expect("RBD0 count", r16(0x5000), 0xC000 | 104);
	expect("frame 1", memcmp(&mem[0x10000], f1.data(), 104), 0);
	expect("RFD1 (broadcast) status", r16(0x4020), 0xA000);
	expect("RFD1 RBD", rp(0x4028), 0x5020);
	expect("frame 2", memcmp(&mem[0x10200], f2.data(), 64), 0);
	expect("RFD2 (frame 4, not 3) RBD", rp(0x4048), 0x5040);
	expect("RBD2 count", r16(0x5040), 0x4000 | 512);
	expect("RBD3 count", r16(0x5060), 0x4000 | 512);
	expect("RBD4 count", r16(0x5080), 0xC000 | (1204 - 1024));
	expect("frame 4 a", memcmp(&mem[0x10400], f4.data(), 512), 0);
	expect("frame 4 b", memcmp(&mem[0x10600], f4.data() + 512, 512), 0);
	expect("frame 4 c", memcmp(&mem[0x10800], f4.data() + 1024, 1204 - 1024), 0);
	expect("RBD5 untouched", r16(0x50A0), 0);
	expect("RFD3 untouched", r16(0x4060), 0);
	expect("SCB status FR (CNA from the configure)", r16(SCB) & 0xF0F0, 0x6040);
	scb_cmd(0x6000);

	// the last RFD (EL): a frame there leaves the RU without resources
	post_rx(frame(MYMAC, 80, 6));
	run(20000);
	expect("RFD3 status", r16(0x4060), 0xA000);
	expect("RFD3 RBD continues the list", rp(0x4068), 0x50A0);
	expect("SCB status FR RNR, no resources", r16(SCB) & 0xF0F0, 0x5020);
	scb_cmd(0x5000);

	// transmits: one TBD, then two chained TBDs
	std::vector<uint8_t> t1 = frame(OTHER, 98, 7), t2 = frame(BC, 70, 8);
	memcpy(&mem[0x20000], t1.data(), 98);
	memcpy(&mem[0x20101], t2.data(), 40); memcpy(&mem[0x20203], t2.data() + 40, 30);
	w16(0x6000, 0); w16(0x6002, 0x0004 | 0x0008); wp(0x6004, 0x6040); wp(0x6008, 0x6100); w16(0x600C, 0);
	w16(0x6100, 0x8000 | 98); wp(0x6104, 0xFFFFFFFF); wp(0x6108, 0x20000);
	w16(0x6040, 0); w16(0x6042, 0xA00C); wp(0x6044, 0xFFFFFFFF); wp(0x6048, 0x6120); w16(0x604C, 0);
	w16(0x6120, 40); wp(0x6124, 0x6140); wp(0x6128, 0x20101);
	w16(0x6140, 0x8000 | 30); wp(0x6144, 0xFFFFFFFF); wp(0x6148, 0x20203);
	wp(SCB + 4, 0x6000);
	uint64_t txw0 = mbx[TXW];
	scb_cmd(0x0100); run(20000);
	expect("TX CB 1", r16(0x6000), 0xA000);
	expect("TX CB 2", r16(0x6040), 0xA000);
	expect("TXW", mbx[TXW] - txw0, 2);
	expect("TX frame 1", tx_slot(txw0) == t1, 1);
	expect("TX frame 2", tx_slot(txw0 + 1) == t2, 1);
	expect("SCB status CX CNA, CU idle", r16(SCB) & 0xFF00, 0xA000);

	// RFDs with their own data area (64 bytes) and the RBD list in the first RFD only:
	// a small frame fits the first RFD, the next (large) one must still find the RBDs
	for (int i = 0; i < 4; i++) {
		uint32_t r = 0x7000 + 0x60 * i;
		memset(&mem[r], 0, 0x60);
		w16(r + 2, i == 3 ? 0x8008 : 0x0008); wp(r + 4, 0x7000 + 0x60 * ((i + 1) % 4));
		wp(r + 8, i == 0 ? 0x7400 : 0xFFFFFFFF); w16(r + 14, 64);
	}
	for (int i = 0; i < 4; i++) {
		uint32_t b = 0x7400 + 32 * i;
		w16(b, 0); wp(b + 4, 0x7400 + 32 * ((i + 1) % 4)); wp(b + 8, 0x30000 + 0x800 * i); w16(b + 12, 1536);
	}
	wp(SCB + 8, 0x7000);
	scb_cmd(0x0010); scb_cmd(r16(SCB) & 0xF000);
	std::vector<uint8_t> small = frame(MYMAC, 60, 11), big = frame(MYMAC, 300, 12);
	post_rx(small); post_rx(big);
	run(40000);
	expect("RFD area: small frame", r16(0x7000), 0xA000);
	expect("RFD area: small frame count (EOF, F, 60)", r16(0x700C), 0xC000 | 60);
	expect("RFD area: large frame", r16(0x7060), 0xA000);
	expect("RFD area: large frame's RBD", rp(0x7068), 0x7400);
	expect("RFD area: 64 bytes in the RFD", r16(0x706C), 0x4000 | 64);
	expect("RFD area: the rest in RBD 0", r16(0x7400), 0xC000 | (300 - 64));
	expect("RFD area: frame", memcmp(&mem[0x7070], big.data(), 64) || memcmp(&mem[0x30000], big.data() + 64, 300 - 64), 0);
	scb_cmd(0x0040); scb_cmd(r16(SCB) & 0xF000);

	// source address insertion (configure byte 3 bit 3 = 0, HP-UX's lan2): the frame in memory is
	// destination + type + data, on the wire destination + station address + type + data
	for (int i = 0; i < 14; i++) w8(0x2028 + i, cfg[i]);
	w8(0x2028 + 3, 0x26); w8(0x2028 + 11, 0xFF);
	w16(0x2020, 0); w16(0x2022, 0x8002); wp(SCB + 4, 0x2020);
	scb_cmd(0x0100); scb_cmd(r16(SCB) & 0xF000);
	std::vector<uint8_t> sarp(BC6, BC6 + 6);
	sarp.push_back(0x08); sarp.push_back(0x06);
	for (int i = 0; i < 40; i++) sarp.push_back(i);
	memcpy(&mem[0x20300], sarp.data(), sarp.size());
	w16(0x6000, 0); w16(0x6002, 0x800C); wp(0x6004, 0xFFFFFFFF); wp(0x6008, 0x6100); w16(0x600C, 0);
	w16(0x6100, 0x8000 | sarp.size()); wp(0x6104, 0xFFFFFFFF); wp(0x6108, 0x20300);
	wp(SCB + 4, 0x6000);
	txw0 = mbx[TXW];
	scb_cmd(0x0100); run(20000);
	std::vector<uint8_t> wire(BC6, BC6 + 6);
	wire.insert(wire.end(), MYMAC, MYMAC + 6);
	wire.insert(wire.end(), sarp.begin() + 6, sarp.end());
	expect("TX with the source address inserted", tx_slot(txw0) == wire, 1);

	printf("%s: %d failure(s), %llu cycles\n", fails ? "FAIL" : "PASS", fails, (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
