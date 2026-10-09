// Unit bench for rtl/artist/artist.sv: drives its GSC port, serves its VRAM
// port from a model with random latency and stalls, and checks the VRAM after
// every drawing operation against a reference model of the semantics in
// docs/design/artist.md (pixel by pixel: plane mask, raster op, transparency,
// BINC mask, clipping, overlapping moves, colour expansion), plus the
// register file, the bus errors, the CPU reads and the colour map.
//
//   make -C verilator tb_artist      (runs it; exit status 0 = pass)
#include "Vartist.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <deque>

static Vartist* t;
static uint64_t cyc = 0;
static int fails = 0;

// ------------------------------------------------------------- VRAM model
static std::vector<uint8_t> vram(2048 * 1024), ref(2048 * 1024);
static uint32_t lut0[256];
static unsigned rnd_state = 1;
static unsigned rnd() { rnd_state = rnd_state * 1103515245u + 12345u; return (rnd_state >> 16) & 0x7FFF; }

struct Mem {
	int st = 0;              // 0 idle, 1 write burst, 2 read latency/beats
	unsigned addr = 0, left = 0, idx = 0;
	int wait = 0;
	bool we = false;
} mem;

static uint64_t vword(unsigned a) { uint64_t w = 0; for (int j = 0; j < 8; j++) w |= (uint64_t)vram[a * 8 + j] << (8 * j); return w; }

// inputs for the next rising edge, from the outputs after the last one
static void mem_step() {
	t->vr_ack = 0; t->vr_wready = 0; t->vr_rvalid = 0;
	switch (mem.st) {
	case 0:
		if (t->vr_req) {
			if (mem.wait < 0) mem.wait = rnd() % 6;
			if (mem.wait-- > 0) break;
			mem.wait = -1;
			mem.addr = t->vr_addr; mem.left = t->vr_len; mem.idx = 0; mem.we = t->vr_we;
			if (mem.left == 0 || mem.left > 64) { printf("FAIL: burst length %u\n", mem.left); fails++; }
			if (mem.addr + mem.left > 262144 || ((mem.addr & 255) + mem.left) > 256) {
				printf("FAIL: burst crosses a row: addr %05x len %u\n", mem.addr, mem.left); fails++;
			}
			t->vr_ack = 1;
			if (mem.we) {
				if (!t->vr_wvalid) { printf("FAIL: write request without beat 0\n"); fails++; }
				t->vr_wready = 1;
				mem.st = 1;
			} else { mem.st = 2; mem.wait = 3 + rnd() % 15; }
		} else mem.wait = -1;
		break;
	case 1:      // the beat offered now is taken at the next edge if vr_wready
		if (t->vr_wvalid && rnd() % 5 != 0) t->vr_wready = 1;
		break;
	case 2:
		if (mem.wait > 0) { mem.wait--; break; }
		if (rnd() % 7 == 0) break;      // a gap
		t->vr_rvalid = 1; t->vr_rdata = vword(mem.addr + mem.idx);
		break;
	}
}
// after the edge: commit what the edge took
static void mem_commit(bool wready, bool rvalid, uint64_t wdata, unsigned wbe) {
	if (wready) {
		unsigned a = mem.addr + mem.idx;
		for (int j = 0; j < 8; j++) if (wbe >> j & 1) vram[a * 8 + j] = (wdata >> (8 * j)) & 0xFF;
		mem.idx++;
		if (mem.idx == mem.left) mem.st = 0;
	}
	if (rvalid) { mem.idx++; if (mem.idx == mem.left) mem.st = 0; }
}

static void tick() {
	mem_step();
	bool wready = t->vr_wready, rvalid = t->vr_rvalid;
	uint64_t wdata = t->vr_wdata; unsigned wbe = t->vr_be;
	t->clk = 1; t->eval();
	mem_commit(wready, rvalid, wdata, wbe);
	if (t->pal_wr) lut0[t->pal_addr] = t->pal_rgb;
	t->clk = 0; t->eval();
	cyc++;
}

// ------------------------------------------------------------- GSC
static uint32_t last_rd; static bool last_err;
static void gsc(bool we, uint32_t a, uint32_t d, unsigned be = 0xF) {
	t->req = 1; t->we = we; t->addr = a; t->wdata = d; t->be = be;
	tick();
	t->req = 0;
	for (int n = 0; n < 2000000; n++) {
		if (t->ack) { last_rd = t->rdata; last_err = t->err; tick(); return; }
		tick();
	}
	printf("FAIL: no ack for %s %08x\n", we ? "write" : "read", a); fails++; exit(1);
}
static void wait_idle() { for (int n = 0; n < 4000000 && t->busy; n++) tick(); }

// ------------------------------------------------------------- reference model
struct Regs {
	uint32_t dst_ba = 0, src_ba = 0, fg = 0, bg = 0, pm = 0, ibo = 0, mask = 0, cp = 0;
	uint32_t dstxy = 0, lenxy = 0, srcxy = 0, binc_dst = 0, binc_src = 0; int row = 0;
} R;
static uint32_t stg[512];

static uint8_t rop8(int r, uint8_t s, uint8_t d) {
	uint8_t o = 0;
	for (int i = 0; i < 8; i++) { int sb = s >> i & 1, db = d >> i & 1; o |= ((r >> ((!sb) * 2 + (!db))) & 1) << i; }
	return o;
}
static void ref_px(int x, int y, uint8_t v) {
	if (x < 0 || x >= 2048 || y < 0 || y >= 1024) return;
	uint8_t pm = R.pm & 0xFF, d = ref[y * 2048 + x];
	ref[y * 2048 + x] = (d & ~pm) | (rop8((R.ibo >> 8) & 15, v, d) & pm);
}
static bool image(uint32_t ba) { int b = (ba >> 12) & 15; return !(b == 6 || b == 7 || b == 13 || b == 15); }
static void fb_xy(uint32_t ba, uint32_t off, int& x, int& y) {
	if (((ba >> 21) & 7) == 3) { x = off & 2044; y = (off >> 11) & 1023; }
	else { x = (off >> 2) & 2047; y = (off >> 13) & 2047; }
}
static void ref_put1(int x, int y, uint32_t d, unsigned be);
// the STI state area is kept in both rows (artist.sv e_mirror)
static void ref_put(int x, int y, uint32_t d, unsigned be) {
	ref_put1(x, y, d, be);
	if (R.dst_ba == 0x13602000 && x >= 1536 && x < 1680 && (y == 384 || y == 776))
		ref_put1(x, y == 384 ? 776 : 384, d, be);
}
static void ref_put1(int x, int y, uint32_t d, unsigned be) {
	uint32_t ba = R.dst_ba;
	if (((ba >> 12) & 15) == 15) { stg[x & 511] = d & 0xFFFFFF; return; }
	if (!image(ba) || y >= 1024) return;
	bool transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1), maskena = R.ibo >> 29 & 1;
	if (((ba >> 27) & 15) == 5) {
		bool ind = ((ba >> 24) & 7) == 6;
		for (int i = 0; i < 32 && x + i < 2048; i++) {
			int b = d >> (31 - i) & 1;
			if (maskena && !(R.mask >> (31 - i) & 1)) continue;
			if (!b && transp) continue;
			ref_px(x + i, y, b ? (ind ? R.fg : 1) : (ind ? R.bg : 0));
		}
	} else {
		for (int i = 0; i < 4 && x + i < 2048; i++) {
			if (!(be >> (3 - i) & 1)) continue;
			if (maskena && !(R.mask >> (31 - i) & 1)) continue;
			ref_px(x + i, y, d >> (24 - 8 * i));
		}
	}
}
static void ref_fill(uint32_t dxy, uint32_t wh) {
	int x = dxy >> 16, y = dxy & 0xFFFF, w = wh >> 16, h = wh & 0xFFFF;
	if (R.cp || !image(R.dst_ba) || x >= 2048 || y >= 1024) return;
	uint8_t c = (R.ibo & 2) ? R.fg : R.bg;
	for (int r = 0; r < h && y + r < 1024; r++)
		for (int i = 0; i < w && x + i < 2048; i++) ref_px(x + i, y + r, c);
}
static void ref_move(uint32_t sxy, uint32_t dxy, uint32_t wh) {
	int sx = sxy >> 16, sy = sxy & 0xFFFF, x = dxy >> 16, y = dxy & 0xFFFF, w = wh >> 16, h = wh & 0xFFFF;
	if (R.cp || !image(R.dst_ba) || x >= 2048 || y >= 1024 || sx >= 2048 || sy >= 1024 || !w || !h) return;
	w = std::min(w, std::min(2048 - x, 2048 - sx)); h = std::min(h, std::min(1024 - y, 1024 - sy));
	std::vector<uint8_t> src(w * h);
	for (int r = 0; r < h; r++) for (int i = 0; i < w; i++) src[r * w + i] = ref[(sy + r) * 2048 + sx + i];
	bool expand = ((R.dst_ba >> 24) & 7) == 6, transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1);
	for (int r = 0; r < h; r++)
		for (int i = 0; i < w; i++) {
			uint8_t v = src[r * w + i];
			if (expand) { int b = (v & R.pm) != 0; if (!b && transp) continue; v = b ? R.fg : R.bg; }
			ref_px(x + i, y + r, v);
		}
}

// register writes through the GSC, mirrored into the reference
static const uint32_t REG = 0xF8000000, FB = 0xF9000000;
static void wr(uint32_t off, uint32_t d) {
	switch (off) {
	case 0x118000: R.dst_ba = R.src_ba = d; break;
	case 0x118004: R.dst_ba = d; break;
	case 0x118008: R.src_ba = d; break;
	case 0x11800C: R.cp = d; break;
	case 0x118010: R.fg = d & 0xFF; break;
	case 0x118014: R.bg = d & 0xFF; break;
	case 0x118018: R.pm = d; break;
	case 0x11801C: R.ibo = d; break;
	case 0x118024: case 0x1005A0: R.mask = d; break;
	case 0x100480: R.binc_src = d; break;
	case 0x1004A0: R.binc_dst = d; R.row = 0; break;
	case 0x100800: R.dstxy = d; break;
	case 0x100804: R.lenxy = d; break;
	case 0x100808: R.srcxy = d; break;
	case 0x100A04: R.lenxy = d; ref_fill(R.dstxy, R.lenxy); break;
	case 0x100A00: R.dstxy = d; ref_fill(R.dstxy, R.lenxy); break;
	case 0x100B00: R.dstxy = d; ref_move(R.srcxy, R.dstxy, R.lenxy); break;
	case 0x100B04: R.lenxy = d; ref_move(R.srcxy, R.dstxy, R.lenxy); break;
	case 0x100620: case 0x100600: {
		int x, y; fb_xy(R.dst_ba, R.binc_dst & 0xFFFFFF, x, y);
		ref_put(x, y + R.row, d, 0xF);
		if (off == 0x100620) R.row++;
		else { int otc = (R.dst_ba >> 27) & 15; R.binc_dst += otc == 5 ? 0x80 : (((R.dst_ba >> 12) & 15) == 15 || otc == 7) ? 4 : 0x10; }
		break;
	}
	case 0x300118:
		if (d >> 31) {
			int sx = (R.binc_src >> 2) & 2047, off2 = (d >> 16) & 0x3FF, n = d & 0x3FF;
			if (n == 0 || n > 512) n = 512;
			for (int i = 0; i < n; i++) if (off2 + i < 256) { /* expected LUT0 */ }
		}
		break;
	}
	gsc(true, REG + off, d);
	wait_idle();
}
static void fbw(uint32_t off, uint32_t d, unsigned be = 0xF) {
	int x, y; fb_xy(R.dst_ba, off, x, y);
	ref_put(x, y, d, be);
	gsc(true, FB + off, d, be);
	wait_idle();
}
static uint32_t rd(uint32_t a) { gsc(false, a, 0); return last_rd; }

static void check(const char* what) {
	int bad = 0;
	for (int i = 0; i < 2048 * 1024; i++)
		if (vram[i] != ref[i]) {
			if (bad < 8) printf("  %s: pixel %d,%d is %02x, expected %02x\n", what, i % 2048, i / 2048, vram[i], ref[i]);
			bad++;
		}
	if (bad) { printf("FAIL: %s: %d pixels differ\n", what, bad); fails++; }
	else printf("ok   %s\n", what);
}
static void expect(const char* what, uint32_t got, uint32_t want) {
	if (got != want) { printf("FAIL: %s: %08x, expected %08x\n", what, got, want); fails++; }
	else printf("ok   %s = %08x\n", what, got);
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vartist;
	for (int i = 0; i < 2048 * 1024; i++) vram[i] = ref[i] = rnd() & 0xFF;     // DDR3 powers up with junk
	t->rst_n = 0; t->chip_rst = 0; t->req = 0; t->dbg_trace = argc > 1;
	for (int i = 0; i < 4; i++) tick();
	t->rst_n = 1; tick();

	// ---- decode and identification (08 1.1)
	gsc(false, 0xF8000000, 0); expect("HPA 0xF8000000 bus error", last_err, 1);
	gsc(false, 0xF8300004, 0); expect("0xF8300004 answers", last_err, 0);
	gsc(false, 0xF8381000, 0); expect("0xF8381000 bus error", last_err, 1);
	gsc(false, 0xF8380004, 0); expect("0xF8380004 at reset", last_rd, 0x6DC20006);
	gsc(true, 0xF8380004, 0x6DC20106); gsc(false, 0xF8380004, 0);
	expect("0x380004 reset in progress", last_rd & 0x100, 0x100);
	for (int i = 0; i < 30; i++) tick();
	gsc(false, 0xF8380004, 0); expect("0x380004 reset done, timer enable cleared", last_rd, 0x6CC20006);
	gsc(true, 0xF8380004, 0x01000000); gsc(false, 0xF8380004, 0); expect("0x380004 timer enable", last_rd, 0x6DC20006);
	gsc(true, 0xF8300218, 0xEBC00341); expect("MISC_VIDEO", rd(0xF8300218), 0xEBC00341);
	gsc(true, 0xF8300200, 0x3F2F2F0F); gsc(true, 0xF8300208, 0xFF3C0202);
	expect("signature at 1280x1024", rd(0xF830023C), 0xAC4FFDAC);
	gsc(true, 0xF8300007, 0x00000001, 0x1); expect("0x300004 byte 7", rd(0xF8300004), 0x00000001);
	gsc(true, 0xF8100088, 0x00010000); expect("state word 0x100088", rd(0xF8100088), 0x00010000);
	gsc(true, 0xF8100000, 0x12345678); gsc(true, 0xF8100002, 0x0000ABCD, 0x3);
	expect("state word 0x100000 byte merge", rd(0xF8100000), 0x1234ABCD);

	// ---- the ROM's VRAM probe (08 0.3, 4.1)
	wr(0x118000, 0x2EA02000); wr(0x118010, 0); wr(0x118018, 0xFF); wr(0x11801C, 0x85000302);
	fbw(0, 0xFFFFFFFF); fbw(0x400000, 0xFFFFFFFF);
	wr(0x118010, 0xFF);
	fbw(0, 0x0A7CF583); fbw(0x400000, 0x385FC7A0);
	check("probe writes");
	expect("probe read FB+0", rd(FB), 0x0A7CF583);
	expect("probe read FB+0x400000", rd(FB + 0x400000), 0x385FC7A0);

	// ---- byte mode (the STI state area at 1536,776)
	wr(0x118024, 0xFFFFFFFF); wr(0x11801C, 0x85000300); wr(0x118000, 0x13602000);
	fbw(0x184600, 0x11223344); fbw(0x184604, 0x55667788);
	fbw(0x184600, 0x00AA0000, 0x4); fbw(0x184604, 0x000000BB, 0x1);
	check("byte-mode stores (the STI state area, both rows)");
	expect("state area mirror at y=384", rd(FB + 0x0C0600), 0x11AA3344);
	expect("byte-mode word read", rd(FB + 0x184600), 0x11AA3344);
	expect("byte-mode word read 2", rd(FB + 0x184604), 0x556677BB);

	// ---- fills: whole-screen clear (plane mask FF), text-plane fill (RMW), odd edges, rops
	wr(0x118000, 0x2EA02000); wr(0x11801C, 0x03000300); wr(0x118010, 0); wr(0x118014, 0); wr(0x118018, 0xFF);
	wr(0x100800, 0); wr(0x100A04, (1280 << 16) | 1024);
	check("clear 1280x1024");
	wr(0x11801C, 0x20000302); wr(0x118010, 5); wr(0x118018, 7);
	wr(0x100800, (3 << 16) | 5); wr(0x100A04, (77 << 16) | 9);
	check("fill FG through plane mask 7");
	wr(0x11801C, 0x20000600 | 2); wr(0x118010, 0xC3); wr(0x118018, 0xFF);
	wr(0x100800, (1 << 16) | 2); wr(0x100A04, (1 << 16) | 3);
	check("1-pixel-wide xor fill");
	wr(0x11801C, 0x00000300); wr(0x118014, 0x9A);
	wr(0x100800, (2040 << 16) | 1020); wr(0x100A04, (100 << 16) | 100);
	check("fill clipped at the VRAM edge");
	wr(0x11800C, 0x102); wr(0x100800, 0); wr(0x100A04, (64 << 16) | 64); wr(0x11800C, 0);
	check("fill with CONTROL_PLANE set does nothing");

	// ---- a pattern to move, then moves in every direction
	wr(0x118000, 0x13602000); wr(0x11801C, 0x85000300); wr(0x118018, 0xFF);
	for (int y = 100; y < 140; y++)
		for (int x = 96; x < 200; x += 4) fbw((y << 11) | x, rnd() << 17 ^ rnd() << 2 ^ rnd());
	check("pattern");
	wr(0x118000, 0x10A02000); wr(0x11801C, 0x20000300); wr(0x118018, 0xFF);
	wr(0x100808, (96 << 16) | 100); wr(0x100804, (100 << 16) | 40); wr(0x100B00, (301 << 16) | 103);
	check("move right/down, misaligned");
	wr(0x100808, (301 << 16) | 103); wr(0x100804, (100 << 16) | 40); wr(0x100B00, (295 << 16) | 99);
	check("overlapping move up/left");
	wr(0x100808, (295 << 16) | 99); wr(0x100804, (100 << 16) | 40); wr(0x100B00, (299 << 16) | 110);
	check("overlapping move down/right");
	wr(0x100808, (299 << 16) | 110); wr(0x100804, (100 << 16) | 40); wr(0x100B00, (305 << 16) | 110);
	check("overlapping move right, same rows");
	wr(0x100808, (305 << 16) | 110); wr(0x100804, (100 << 16) | 40); wr(0x100B00, (298 << 16) | 110);
	check("overlapping move left, same rows");
	wr(0x118018, 7);
	wr(0x100808, (0 << 16) | 16); wr(0x100804, (1280 << 16) | 1008); wr(0x100B00, (0 << 16) | 0);
	check("scroll 1280x1008 up 16 lines in the text planes");
	wr(0x118018, 0xF8); wr(0x11801C, 0x20000600);
	wr(0x100808, (100 << 16) | 100); wr(0x100804, (64 << 16) | 8); wr(0x100B00, (400 << 16) | 400);
	check("xor move in the non-text planes");

	// ---- colour-change move (block_move flags.color): 0x28A0 source, 0x2EA0 destination
	wr(0x11801C, 0x20000300); wr(0x118018, 7); wr(0x118010, 2); wr(0x118014, 6);
	wr(0x118008, 0x28A02000); wr(0x118004, 0x2EA02000);
	wr(0x100808, (100 << 16) | 100); wr(0x100804, (50 << 16) | 20); wr(0x100B00, (700 << 16) | 300);
	check("colour-change move");

	// ---- glyphs through BINC: 8 wide, rows to 0x100620, mask = top 8 bits
	wr(0x118000, 0x2EA02000); wr(0x11801C, 0x20000300); wr(0x118018, 7); wr(0x118010, 1); wr(0x118014, 0);
	for (int c = 0; c < 3; c++) {
		int gx = 13 + 8 * c, gy = 600;
		wr(0x1004A0, 0x01000000 | gy << 13 | gx << 2); wr(0x1005A0, 0xFF000000);
		for (int r = 0; r < 16; r++) wr(0x100620, (uint32_t)(rnd() & 0xFF) << 24);
	}
	check("three glyphs");
	// a 40-wide glyph row via 0x100600 (full word, then a partial one)
	wr(0x1005A0, 0xFFFFFFFF); wr(0x1004A0, 0x01000000 | 650 << 13 | 21 << 2);
	wr(0x100600, 0xF0F0F0F1); wr(0x1005A0, 0xFF000000); wr(0x100600, 0xA5000000);
	check("wide glyph row");
	expect("BINC dst read-back", rd(0xF8118028), 0x01000000 | 650 << 13 | (21 + 64) << 2);
	// transparent background (IBO bit 1), 0x2EA0 CPU write
	wr(0x11801C, 0x00000302); wr(0x118018, 0xFF); wr(0x118010, 0x44);
	fbw((700 << 13) | (5 << 2), 0x81818181);
	check("transparent-background bitmap write");

	// ---- CPU reads: 4 pixels at an odd x in long mode, a bitmap read across 5 words
	wr(0x118000, 0x13A02000);
	{
		uint32_t want = 0; int x = 301, y = 105;
		for (int i = 0; i < 4; i++) want |= ref[y * 2048 + x + i] << (24 - 8 * i);
		expect("long-mode 4-pixel read", rd(FB + (y << 13 | x << 2)), want);
	}
	wr(0x118000, 0x2EA02000); wr(0x118018, 0x07);
	{
		uint32_t want = 0; int x = 299, y = 107;
		for (int i = 0; i < 32; i++) want |= (uint32_t)((ref[y * 2048 + x + i] & 7) != 0) << (31 - i);
		expect("bitmap read (plane mask 7)", rd(FB + (y << 13 | x << 2)), want);
	}

	// ---- colour map: 256 entries staged at 0..255, loaded into LUT0
	wr(0x118000, 0x3BA0F000); wr(0x118018, 0xFF); wr(0x11801C, 0x300);
	for (int i = 0; i < 256; i++) fbw(i << 2, (i * 0x10101 ^ 0x5A3C96) & 0xFFFFFF);
	wr(0x100480, 0); wr(0x300118, 0x80000100); wr(0x300118, 0x81000100);
	{
		int bad = 0;
		for (int i = 0; i < 256; i++) if (lut0[i] != ((i * 0x10101 ^ 0x5A3C96) & 0xFFFFFF)) bad++;
		if (bad) { printf("FAIL: LUT0: %d entries wrong\n", bad); fails++; } else printf("ok   LUT0 loaded\n");
	}
	// Linux's way: BINC writes to entries 0x100+i, loaded from source x 0x100
	wr(0x118000, 0xBBE0F000);
	wr(0x1004A0, 0x100 << 2);
	for (int i = 0; i < 256; i++) wr(0x100600, 0xFF0000 - i);
	wr(0x100480, 0x400); wr(0x300118, 0x80000100);
	{
		int bad = 0;
		for (int i = 0; i < 256; i++) if (lut0[i] != (uint32_t)(0xFF0000 - i)) bad++;
		if (bad) { printf("FAIL: LUT0 via BINC: %d entries wrong\n", bad); fails++; } else printf("ok   LUT0 loaded via BINC\n");
	}
	expect("busy clear", rd(0xF8300000), 0);
	check("final VRAM");

	printf("%s (%llu cycles)\n", fails ? "FAILED" : "PASS", (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
