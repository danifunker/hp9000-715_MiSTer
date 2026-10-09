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
// the attribute plane (vr_addr[18]): word {y, x[10:6]}, pixel x in bit x[5:0]
static std::vector<uint64_t> aram(32768);
static std::vector<uint8_t> aref(2048 * 1024);
static uint32_t lut[512];
static unsigned rnd_state = 1;
static unsigned rnd() { rnd_state = rnd_state * 1103515245u + 12345u; return (rnd_state >> 16) & 0x7FFF; }

struct Mem {
	int st = 0;              // 0 idle, 1 write burst, 2 read latency/beats
	unsigned addr = 0, left = 0, idx = 0;
	int wait = 0;
	bool we = false;
} mem;

static uint64_t vword(unsigned a) {
	if (a >> 18 & 1) return aram[a & 32767];
	uint64_t w = 0; for (int j = 0; j < 8; j++) w |= (uint64_t)vram[(a & 262143) * 8 + j] << (8 * j); return w;
}

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
			bool attr = mem.addr >> 18 & 1;
			if ((attr && ((mem.addr & 0x7FFF) >= 32768 || (mem.addr & 31) + mem.left > 32 || (mem.addr & 0x38000))) ||
			    (!attr && (mem.addr + mem.left > 262144 || ((mem.addr & 255) + mem.left) > 256))) {
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
		if (a >> 18 & 1) {
			if (wbe != 0xFF) { printf("FAIL: attribute write with byte enables %02x\n", wbe); fails++; }
			aram[a & 32767] = wdata;
		} else
			for (int j = 0; j < 8; j++) if (wbe >> j & 1) vram[a * 8 + j] = (wdata >> (8 * j)) & 0xFF;
		mem.idx++;
		if (mem.idx == mem.left) mem.st = 0;
	}
	if (rvalid) { mem.idx++; if (mem.idx == mem.left) mem.st = 0; }
}

// the display's line fetch (rf_*): its own port, random latency and gaps
struct RF { int st = 0; unsigned addr = 0, left = 0, idx = 0; int wait = -1; } rf;
static void rf_step() {
	t->rf_ack = 0; t->rf_rvalid = 0;
	if (rf.st == 0) {
		if (t->rf_req) {
			if (rf.wait < 0) rf.wait = rnd() % 8;
			if (rf.wait-- > 0) return;
			rf.wait = -1; rf.addr = t->rf_addr; rf.left = t->rf_len; rf.idx = 0;
			if (rf.left == 0 || rf.left > 64) { printf("FAIL: fetch length %u\n", rf.left); fails++; }
			t->rf_ack = 1; rf.st = 1; rf.wait = 4 + rnd() % 20;
		}
	} else {
		if (rf.wait > 0) { rf.wait--; return; }
		if (rnd() % 9 == 0) return;
		t->rf_rvalid = 1; t->rf_rdata = vword(rf.addr + rf.idx);
	}
}
static void rf_commit(bool rvalid) { if (rvalid && ++rf.idx == rf.left) { rf.st = 0; rf.wait = -1; } }

// a frame from the video outputs: rows of DE pixels after the end of a vertical sync
static std::vector<uint32_t> frame;
static int cap_st = 0, cap_x = 0, cap_y = 0, cap_w = 0;
static bool prev_vs = false, prev_de = false;
static void capture() {
	bool vs = t->vid_vs, de = t->vid_de;
	if (cap_st == 1 && prev_vs && !vs) { cap_st = 2; cap_y = 0; cap_x = 0; frame.clear(); }
	else if (cap_st == 2) {
		if (de) { frame.push_back(t->vid_r << 16 | t->vid_g << 8 | t->vid_b); cap_x++; }
		if (prev_de && !de) { if (cap_y == 0) cap_w = cap_x; cap_y++; cap_x = 0; }
		if (vs) cap_st = 3;
	}
	prev_vs = vs; prev_de = de;
}

static void tick() {
	mem_step(); rf_step();
	bool wready = t->vr_wready, rvalid = t->vr_rvalid, frv = t->rf_rvalid;
	uint64_t wdata = t->vr_wdata; unsigned wbe = t->vr_be;
	t->clk = 1; t->eval();
	mem_commit(wready, rvalid, wdata, wbe);
	rf_commit(frv);
	if (t->pal_wr) lut[t->pal_addr] = t->pal_rgb;
	capture();
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
	uint32_t dstxy = 0, lenxy = 0, srcxy = 0, binc_dst = 0, binc_src = 0, r80 = 0, xfer = 0, r80c = 0; int frow = 0;
	bool pat = false;        // a dashed vector is open (0x100ECC/EC4 .. a DST write)
} R;
static uint32_t curcol[4];
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
	if ((((ba >> 12) & 15) == 6 || ((ba >> 12) & 15) == 7)) return;     // cursor bitmaps: not in the image
	if (((ba >> 12) & 15) == 15) { stg[x & 511] = d & 0xFFFFFF; return; }
	if (!image(ba) || y >= 1024) return;
	bool transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1), maskena = R.ibo >> 29 & 1;
	if (((ba >> 27) & 15) == 5) {
		bool ind = ((ba >> 24) & 7) == 6;
		for (int i = 0; i < 32 && x + i < 2048; i++) {
			int b = d >> (31 - i) & 1;
			if (!(be >> (3 - i / 8) & 1)) continue;          // 8 pixels per byte lane
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
	if (R.cp && ((R.dst_ba >> 12) & 15) == 13 && x < 2048 && y < 1024) {
		// the attribute plane: each pixel's LUT := CONTROL_PLANE bit 24
		for (int r = 0; r < h && y + r < 1024; r++)
			for (int i = 0; i < w && x + i < 2048; i++) aref[(y + r) * 2048 + x + i] = R.cp >> 24 & 1;
		return;
	}
	if (R.cp || !image(R.dst_ba) || x >= 2048 || y >= 1024) return;
	bool transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1);
	for (int r = 0; r < h && y + r < 1024; r++)
		for (int i = 0; i < w && x + i < 2048; i++) {
			int b = R.xfer >> (31 - i % 32) & 1;        // TRANSFER_DATA picks FG/BG
			if (!b && transp) continue;
			ref_px(x + i, y + r, b ? R.fg : R.bg);
		}
}
static void ref_move(uint32_t sxy, uint32_t dxy, uint32_t wh) {
	int sx = sxy >> 16, sy = sxy & 0xFFFF, x = dxy >> 16, y = dxy & 0xFFFF, w = wh >> 16, h = wh & 0xFFFF;
	if (R.cp || !image(R.dst_ba) || x >= 2048 || y >= 1024 || sx >= 2048 || sy >= 1024 || !w || !h) return;
	w = std::min(w, std::min(2048 - x, 2048 - sx)); h = std::min(h, std::min(1024 - y, 1024 - sy));
	std::vector<uint8_t> src(w * h);
	for (int r = 0; r < h; r++) for (int i = 0; i < w; i++) src[r * w + i] = ref[(sy + r) * 2048 + sx + i];
	bool expand = ((R.dst_ba >> 24) & 7) == 6, transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1);
	int j = (R.src_ba >> 16) & 31;
	for (int r = 0; r < h; r++)
		for (int i = 0; i < w; i++) {
			uint8_t v = src[r * w + i];
			if (expand) { int b = j ? (v >> (j & 7) & 1) : (v & R.pm) != 0; if (!b && transp) continue; v = b ? R.fg : R.bg; }
			ref_px(x + i, y + r, v);
		}
}

// vectors, as X's ngleBiffVectorEmulator steps them (docs/review/09 5.4): plot,
// then if e >= 0 the minor axis moves and e -= dec, else e += inc; the major axis
// always moves. The colour bit is ph (TRANSFER_DATA[31], flipped per dash)
struct Vec { int x = 0, y = 0, e = 0, inc = 0, dec = 0, sx = 1, sy = 1, ph = 1; bool ymaj = false; } V;
static void vec_draw(int n) {
	bool transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1);
	for (; n > 0; n--) {
		if (!R.cp && image(R.dst_ba) && (V.ph || !transp)) ref_px(V.x, V.y, V.ph ? R.fg : R.bg);
		bool minor = V.e >= 0;
		V.e += minor ? -V.dec : V.inc;
		if (V.ymaj) { V.y += V.sy; if (minor) V.x += V.sx; }
		else { V.x += V.sx; if (minor) V.y += V.sy; }
	}
}
// from a point to another: returns the major delta
static int vec_to(uint32_t from, uint32_t to) {
	int x0 = (int16_t)(from >> 16), y0 = (int16_t)from, dx = (int16_t)(to >> 16) - x0, dy = (int16_t)to - y0;
	int adx = abs(dx), ady = abs(dy);
	V.x = x0; V.y = y0; V.sx = dx < 0 ? -1 : 1; V.sy = dy < 0 ? -1 : 1;
	V.ymaj = ady >= adx;
	int maj = V.ymaj ? ady : adx, mnr = V.ymaj ? adx : ady;
	V.e = 2 * mnr - maj - ((V.ymaj ? dx >= 0 : dy >= 0) ? 1 : 0);
	V.inc = 2 * mnr; V.dec = 2 * (maj - mnr); V.ph = R.xfer >> 31;
	return maj;
}
// from DST with the terms in LEN (dx, dy) and SRC (major-axis sign, error term)
static void vec_terms() {
	int dx = (int16_t)(R.lenxy >> 16), dy = (int16_t)R.lenxy, sh = (int16_t)(R.srcxy >> 16);
	V.x = (int16_t)(R.dstxy >> 16); V.y = (int16_t)R.dstxy; V.sx = dx < 0 ? -1 : 1; V.sy = dy < 0 ? -1 : 1;
	V.ymaj = sh >= 0;
	V.e = (int16_t)R.srcxy - ((V.ymaj ? dx >= 0 : dy >= 0) ? 1 : 0);
	V.inc = 2 * (V.ymaj ? abs(dx) : abs(dy)); V.dec = 2 * abs(sh); V.ph = R.xfer >> 31;
}

// register writes through the GSC, mirrored into the reference
static const uint32_t REG = 0xF8000000, FB = 0xF9000000;
static void wr(uint32_t off, uint32_t d, unsigned be = 0xF) {
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
	case 0x1004A0: R.binc_dst = d; break;
	case 0x100080: R.r80 = d; break;
	case 0x100800: R.dstxy = d; R.pat = false; break;
	case 0x100804: R.lenxy = d; break;
	case 0x100808: R.srcxy = d; break;
	case 0x100820: R.xfer = d; break;
	case 0x100A04: R.lenxy = d; ref_fill(R.dstxy, R.lenxy); if (R.r80 == 0x7D || R.r80 == 8) R.dstxy += R.lenxy & 0xFFFF; break;
	case 0x100A00: R.dstxy = d; R.pat = false; ref_fill(R.dstxy, R.lenxy); if (R.r80 == 0x7D || R.r80 == 8) R.dstxy += R.lenxy & 0xFFFF; break;
	case 0x100A20: R.xfer = d; ref_fill(R.dstxy, R.lenxy); if (R.r80 == 0x7D || R.r80 == 8) R.dstxy += R.lenxy & 0xFFFF; break;
	case 0x100AA0: case 0x1008A0: {
		int n = off == 0x100AA0 ? 0 : R.frow, h = R.lenxy & 0xFFFF, x = R.dstxy >> 16, y = R.dstxy & 0xFFFF;
		bool transp = (R.ibo >> 28 & 1) || (R.ibo >> 1 & 1);
		for (int k = 0; k < 2; k++) {
			if (n + k >= h || y + n + k >= 1024) continue;
			uint32_t row = k ? d & 0xFFFF : d >> 16;
			for (int i = 0; i < 16 && x + i < 2048; i++) {
				int b = row >> (15 - i) & 1;
				if (!b && transp) continue;
				ref_px(x + i, y + n + k, b ? R.fg : R.bg);
			}
		}
		R.frow = n + 2;
		if (n + 2 >= h) R.dstxy += (R.lenxy >> 16) << 16;
		break;
	}
	case 0x100E44: case 0x100E04: case 0x100C40: {
		if (off == 0x100C40) R.dstxy = d;
		int maj = vec_to(R.dstxy, d);
		vec_draw(maj + (off != 0x100E04));
		R.dstxy = d; R.pat = false;
		break;
	}
	case 0x10080C: R.r80c = d; break;
	case 0x100EC4: vec_to(R.dstxy, d); vec_draw(R.r80c >> 16); R.dstxy = d; R.pat = true; break;
	case 0x100ECC: R.r80c = d; vec_to(R.dstxy, R.lenxy); vec_draw(d >> 16); R.pat = true; break;
	case 0x100CCC:
		R.r80c = d;
		if (R.pat) V.ph ^= 1;
		else vec_terms();
		vec_draw(d >> 16);
		break;
	case 0x100B00: R.dstxy = d; R.pat = false; ref_move(R.srcxy, R.dstxy, R.lenxy); break;
	case 0x100B04: R.lenxy = d; ref_move(R.srcxy, R.dstxy, R.lenxy); break;
	case 0x1005C0: case 0x100600: case 0x100620: case 0x100640: case 0x100660:
	case 0x100680: case 0x1006A0: case 0x1006C0: case 0x1006E0: {
		int x, y; fb_xy(R.dst_ba, R.binc_dst & 0xFFFFFF, x, y);
		ref_put(x, y, d, 0xF);
		int otc = (R.dst_ba >> 27) & 15, lng = ((R.dst_ba >> 21) & 7) != 3;
		uint32_t dx = otc == 5 ? 32 : (((R.dst_ba >> 12) & 15) == 15 || otc == 7) ? 1 : 4, dy = lng ? 0x2000 : 0x800;
		if (lng) dx <<= 2;
		bool xp = off == 0x1005C0 || off == 0x100600 || off == 0x100680 || off == 0x1006C0;
		bool xm = off == 0x100660 || off == 0x1006A0 || off == 0x1006E0;
		bool yp = off == 0x100620 || off == 0x100680 || off == 0x1006A0;
		bool ym = off == 0x100640 || off == 0x1006C0 || off == 0x1006E0;
		R.binc_dst += (xp ? dx : 0) - (xm ? dx : 0) + (yp ? dy : 0) - (ym ? dy : 0);
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
	gsc(true, REG + off, d, be);
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
	for (int i = 0; i < 2048 * 1024; i++) {
		if (vram[i] != ref[i]) {
			if (bad < 8) printf("  %s: pixel %d,%d is %02x, expected %02x\n", what, i % 2048, i / 2048, vram[i], ref[i]);
			bad++;
		}
		int a = aram[i / 64] >> (i % 64) & 1;
		if (a != aref[i]) {
			if (bad < 8) printf("  %s: attribute of %d,%d is %d, expected %d\n", what, i % 2048, i / 2048, a, aref[i]);
			bad++;
		}
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
	for (int i = 0; i < 32768; i++) aram[i] = (uint64_t)rnd() << 49 ^ (uint64_t)rnd() << 30 ^ (uint64_t)rnd() << 15 ^ rnd();
	// (Artist clears the attribute plane after a reset: aref stays all LUT0)
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
	wr(0x100820, 0xFFFFFFFF); wr(0x11801C, 0x20000302); wr(0x118010, 5); wr(0x118018, 7);
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

	// ---- BINC in every direction (NGLE manual 4): a 3x3 walk of 32-pixel words
	wr(0x118000, 0x2EA02000); wr(0x11801C, 0x00000300); wr(0x118018, 0xFF); wr(0x118010, 0x31); wr(0x118014, 0x07);
	wr(0x1004A0, 0x01000000 | 800 << 13 | 64 << 2);
	{
		const uint32_t dirs[] = {0x100600, 0x100680, 0x100620, 0x1006A0, 0x100660, 0x1006E0, 0x100640, 0x1006C0, 0x1005C0};
		for (uint32_t o : dirs) wr(o, rnd() << 17 ^ rnd() << 2 ^ rnd());
	}
	check("BINC data ports, all directions");
	expect("BINC dst after the walk", rd(0xF8118028), R.binc_dst);
	// fills that advance DST y (0x100080 = 0x7D)
	wr(0x100080, 0x7D); wr(0x11801C, 0x00000302); wr(0x118010, 0x5A);
	wr(0x100800, (900 << 16) | 700); wr(0x100A04, (40 << 16) | 3); wr(0x100A04, (20 << 16) | 2); wr(0x100A04, (60 << 16) | 4);
	wr(0x100080, 0);
	check("stacked fills (0x100080 = 0x7D)");

	// ---- fills from TRANSFER_DATA: an opaque stipple, a transparent one, 0x100A20 pattern rows
	wr(0x118000, 0x2EA02000); wr(0x118018, 0xFF); wr(0x118010, 0x61); wr(0x118014, 0x16);
	wr(0x11801C, 0x23000300); wr(0x100820, 0xF0F0A5C3); wr(0x100800, (1000 << 16) | 10); wr(0x100A04, (70 << 16) | 4);
	wr(0x11801C, 0x23000302); wr(0x100820, 0x0F0F3C3C); wr(0x100800, (1003 << 16) | 20); wr(0x100A04, (45 << 16) | 3);
	wr(0x100080, 0x08); wr(0x11801C, 0x23000300); wr(0x100800, (1100 << 16) | 30); wr(0x100804, (40 << 16) | 1);
	for (int r = 0; r < 6; r++) wr(0x100A20, 0x80402010u >> r | 0x01020408u << r);
	wr(0x100080, 0);
	check("fills from TRANSFER_DATA, 0x100A20 rows");
	// ---- glyph rows by halfword stores (X's sth to 0x100620: byte enables 1100)
	wr(0x11801C, 0x13000302); wr(0x118010, 0x2B);
	wr(0x1004A0, 0x30000000 | 40 << 13 | 1203 << 2);
	for (int r = 0; r < 10; r++) {
		uint32_t h = (0xA55A + r * 0x1357) & 0xFFFF;
		int x, y; fb_xy(R.dst_ba, R.binc_dst & 0xFFFFFF, x, y); ref_put(x, y, h << 16 | h, 0xC); R.binc_dst += 0x2000;
		gsc(true, REG + 0x100620, h << 16 | h, 0xC); wait_idle();
	}
	check("halfword glyph rows (16 pixels each)");
	// ---- the font engine: 0x100AA0 / 0x1008A0, two rows a word, DST x += LEN w after h rows
	wr(0x11801C, 0x23000302); wr(0x118010, 0x3C); wr(0x1005A0, 0x00FFFF00);
	wr(0x100800, (1300 << 16) | 40); wr(0x100804, (9 << 16) | 7);
	for (int g = 0; g < 3; g++) {
		wr(0x100AA0, 0x7E008100 + g); wr(0x1008A0, 0x81008100 ^ g << 9); wr(0x1008A0, 0xFF00C3C3); wr(0x1008A0, 0x3C00DEAD);
	}
	check("font engine: three glyphs");
	// ---- lines: x-major, y-major, backwards, exclusive end, a polyline
	wr(0x118018, 0xFF); wr(0x100820, 0xFFFFFFFF); wr(0x11801C, 0x23000302); wr(0x118010, 0x5D);
	wr(0x100800, (1400 << 16) | 50); wr(0x100E44, (1460 << 16) | 71);
	wr(0x100800, (1420 << 16) | 50); wr(0x100E44, (1431 << 16) | 99);
	wr(0x100800, (1499 << 16) | 99); wr(0x100E04, (1470 << 16) | 60);
	wr(0x100800, (1500 << 16) | 50); wr(0x100E04, (1530 << 16) | 50); wr(0x100E04, (1530 << 16) | 80); wr(0x100E44, (1500 << 16) | 80);
	check("lines");
	// ---- clipped lines (X's ucrxSolid_PolySegment after duClipVector): DST = the first pixel
	// shown, LEN = (dx, dy), SRC = (|dy| - |dx|, error term), sth 0x100CCC = pixels; each must
	// draw exactly the tail of the whole line from its k-th pixel
	{
		auto wrh = [](uint32_t off, unsigned h) { wr(off, h << 16 | h, 0xC); };
		struct L { int x0, y0, x1, y1, k; } ls[] = {
			{1560, 300, 1610, 317, 7}, {1560, 330, 1571, 391, 20}, {1650, 399, 1590, 380, 11},
			{1650, 300, 1640, 360, 0}, {1580, 420, 1620, 420, 13}, {1600, 430, 1650, 480, 9}};
		bool same = true;
		for (const L& l : ls) {
			// the model's whole line, and its state after k pixels
			uint32_t a = l.x0 << 16 | l.y0, b = l.x1 << 16 | l.y1;
			int maj = vec_to(a, b);
			std::vector<std::pair<int, int>> full;
			Vec s = V;
			for (int i = 0; i <= maj; i++) { full.push_back({V.x, V.y}); bool m = V.e >= 0; V.e += m ? -V.dec : V.inc;
				if (V.ymaj) { V.y += V.sy; if (m) V.x += V.sx; } else { V.x += V.sx; if (m) V.y += V.sy; } }
			V = s;
			for (int i = 0; i < l.k; i++) { bool m = V.e >= 0; V.e += m ? -V.dec : V.inc;
				if (V.ymaj) { V.y += V.sy; if (m) V.x += V.sx; } else { V.x += V.sx; if (m) V.y += V.sy; } }
			int dx = l.x1 - l.x0, dy = l.y1 - l.y0, bias = (V.ymaj ? dx >= 0 : dy >= 0) ? 1 : 0;
			uint32_t dst = (uint32_t)V.x << 16 | (V.y & 0xFFFF), len = (uint32_t)(dx & 0xFFFF) << 16 | (dy & 0xFFFF);
			uint32_t src = (uint32_t)((abs(dy) - abs(dx)) & 0xFFFF) << 16 | ((V.e + bias) & 0xFFFF);
			// the parametric form, run in the model, must give the same pixels
			R.dstxy = dst; R.lenxy = len; R.srcxy = src; vec_terms();
			for (int i = l.k; i <= maj; i++) {
				if (V.x != full[i].first || V.y != full[i].second) same = false;
				bool m = V.e >= 0; V.e += m ? -V.dec : V.inc;
				if (V.ymaj) { V.y += V.sy; if (m) V.x += V.sx; } else { V.x += V.sx; if (m) V.y += V.sy; }
			}
			wr(0x100800, dst); wr(0x100804, len); wr(0x100808, src); wrh(0x100CCC, maj + 1 - l.k);
		}
		if (!same) { printf("FAIL: the model's parametric vectors leave the whole lines\n"); fails++; }
		check("clipped lines (DST/LEN/SRC + 0x100CCC)");
		// ---- dashed lines: a segment (0x100ECC + 0x100CCC dashes; on-off, gaps transparent),
		// a double dash starting in a gap (opaque: gaps in BG), a dashed polyline (0x10080C +
		// 0x100EC4 per vertex, TRANSFER_DATA = the phase of the dash it starts in)
		wr(0x11801C, 0x23000302); wr(0x118010, 0x4E); wr(0x118014, 0x19); wr(0x100080, 0);
		wr(0x100820, 0xFFFFFFFF); wr(0x100800, (1560 << 16) | 500); wr(0x100804, (1620 << 16) | 530);
		wrh(0x100ECC, 5); for (int n : {3, 7, 2, 9, 4, 6, 3, 8, 5, 9, 4}) wrh(0x100CCC, n);
		wr(0x11801C, 0x23000300); wr(0x100820, 0);
		wr(0x100800, (1640 << 16) | 560); wr(0x100804, (1600 << 16) | 500);
		wrh(0x100ECC, 2); for (int n : {6, 4, 6, 4, 6, 4, 6, 4, 6, 13}) wrh(0x100CCC, n);
		wr(0x11801C, 0x23000302); wr(0x100820, 0xFFFFFFFF); wr(0x100800, (1700 << 16) | 500);
		wrh(0x10080C, 4); wr(0x100EC4, (1740 << 16) | 500); for (int n : {4, 4, 4, 4, 4, 4, 4, 4, 4}) wrh(0x100CCC, n);
		wr(0x100820, 0); wrh(0x10080C, 3); wr(0x100EC4, (1740 << 16) | 540); for (int n : {4, 4, 4, 4, 4, 4, 4, 4, 4, 2}) wrh(0x100CCC, n);
		wr(0x100820, 0xFFFFFFFF); wrh(0x10080C, 2); wr(0x100EC4, (1705 << 16) | 560);
		check("dashed lines (0x100ECC, 0x10080C + 0x100EC4, 0x100CCC dashes)");
		// ---- points through 0x100C40 (the vector emulator's pixels)
		wr(0x100080, 0x3003C); wr(0x100804, 0); wr(0x100808, 0);
		for (int i = 0; i < 6; i++) wr(0x100C40, (uint32_t)(1760 + 3 * i) << 16 | (500 + i * i));
		wr(0x100080, 0);
		check("points (0x100C40)");
	}
	// ---- X's backdrop repaint after a window move (board, build 22/23, recorder): one
	// 16-row band of the tile uploaded through BINC (fstd pairs to 0x100600/4 included),
	// then replicated by moves: 4 px left, doubling right, then the band down
	{
		wr(0x118000, 0x13A01000); wr(0x11801C, 0x23000300); wr(0x118018, 0xFF); wr(0x1005A0, 0xFFFFFFFF);
		for (int y = 752; y < 768; y++) {
			wr(0x1004A0, (uint32_t)y << 13 | 216 << 2);
			for (int k = 0; k < 4; k++) wr(0x100600, 0x2A2A2A2Au + (uint32_t)(y - 752) * 0x01000000u + k);
		}
		struct M { int sx, sy, w, h, dx, dy; } mv[] = {
			{228, 752, 4, 16, 212, 752}, {216, 752, 16, 16, 232, 752}, {216, 752, 32, 16, 248, 752},
			{216, 752, 64, 16, 280, 752}, {216, 752, 128, 16, 344, 752}, {216, 752, 256, 16, 472, 752},
			{216, 752, 384, 16, 728, 752}, {212, 759, 900, 9, 212, 743}, {212, 752, 900, 16, 212, 768},
			{212, 752, 900, 32, 212, 784}, {212, 752, 900, 13, 212, 816}};
		for (const M& m : mv) {
			wr(0x100808, m.sx << 16 | m.sy); wr(0x100804, m.w << 16 | m.h); wr(0x100B00, m.dx << 16 | m.dy);
			if (getenv("TB_STEP")) { char b[64]; snprintf(b, sizeof b, "move %d,%d %dx%d -> %d,%d", m.sx, m.sy, m.w, m.h, m.dx, m.dy); check(b); }
		}
		check("X's backdrop band and its replication by moves");
		// narrow moves (one source word or two) in every width and several lane offsets,
		// each row different, so a stale line-buffer word shows as a row slip
		wr(0x118000, 0x13602000); wr(0x11801C, 0x85000300);
		for (int y = 860; y < 872; y++)
			for (int x = 1200; x < 1264; x += 4) fbw((y << 11) | x, (uint32_t)(y * 0x01030507u + x * 0x00090B0Du));
		wr(0x118000, 0x13A01000); wr(0x11801C, 0x23000300);
		int n = 0;
		for (int w = 1; w <= 8; w++)
			for (int sa : {0, 3, 4, 7})
				for (int da : {0, 2, 4, 6}) {
					int sx = 1200 + 8 * (n % 6) + sa, dx = 1300 + 16 * (n % 40) + da, dy = 880 + 6 * (n / 40);
					wr(0x100808, sx << 16 | 860); wr(0x100804, w << 16 | 5); wr(0x100B00, dx << 16 | dy);
					n++;
				}
		check("narrow moves, widths 1-8, all lane offsets");
	}
	// ---- a recolouring move from bit plane 2 (SRC BA J = 2)
	wr(0x11801C, 0x23000300); wr(0x118018, 0xFF); wr(0x118010, 0x77); wr(0x118014, 0x11);
	wr(0x118008, 0x28A22000); wr(0x118004, 0x2EA02000);
	wr(0x100808, (96 << 16) | 100); wr(0x100804, (40 << 16) | 8); wr(0x100B00, (1600 << 16) | 120);
	check("recolouring move from plane 2");

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
		for (int i = 0; i < 512; i++) if (lut[i] != ((i % 256 * 0x10101 ^ 0x5A3C96) & 0xFFFFFF)) bad++;
		if (bad) { printf("FAIL: LUT0/LUT1: %d entries wrong\n", bad); fails++; } else printf("ok   LUT0 and LUT1 loaded\n");
	}
	// Linux's way: BINC writes to entries 0x100+i, loaded from source x 0x100
	wr(0x118000, 0xBBE0F000);
	wr(0x1004A0, 0x100 << 2);
	for (int i = 0; i < 256; i++) wr(0x100600, 0xFF0000 - i);
	wr(0x100480, 0x400); wr(0x300118, 0x80000100);
	{
		int bad = 0;
		for (int i = 0; i < 256; i++) if (lut[i] != (uint32_t)(0xFF0000 - i)) bad++;
		if (bad) { printf("FAIL: LUT0 via BINC: %d entries wrong\n", bad); fails++; } else printf("ok   LUT0 loaded via BINC\n");
	}
	// cursor colours (LUT blt type 2) must not touch LUT0
	wr(0x118000, 0x3BA0F000);
	for (int i = 0; i < 4; i++) fbw(i << 2, 0x111111 * (i + 1));
	wr(0x100480, 0); wr(0x300118, 0x80008004);
	{
		int bad = 0;
		for (int i = 0; i < 256; i++) if (lut[i] != (uint32_t)(0xFF0000 - i)) bad++;
		if (bad) { printf("FAIL: a cursor-colour LUT blt changed LUT0 (%d entries)\n", bad); fails++; } else printf("ok   cursor-colour LUT blt leaves LUT0\n");
	}
	expect("busy clear", rd(0xF8300000), 0);
	check("VRAM before the cursor");

	// ---- the display (artist_video.sv): LUT0/LUT1 by the attribute plane, the cursor laid over
	{
		// a 1280x1024 mode, video on; reg19's porches give hbp = 0x2F + 0x2F + 2 = 96
		gsc(true, 0xF8300200, 0x3F2F2F0F); gsc(true, 0xF8300208, 0xFF3C0202); gsc(true, 0xF8300218, 0xEBC00341);
		// distinct LUT0 and LUT1
		wr(0x118000, 0x3BA0F000); wr(0x118018, 0xFF); wr(0x11801C, 0x300);
		for (int i = 0; i < 512; i++) fbw(i << 2, i < 256 ? (i * 0x050301 + 0x102030) & 0xFFFFFF : (i * 0x0A0B07 ^ 0x80FF00) & 0xFFFFFF);
		wr(0x100480, 0); wr(0x300118, 0x80000200);
		// windows with their colour map in LUT1 (X's nglePolyPaintAttr), one 1 pixel wide, one ragged
		wr(0x118004, 0x2EA0D000); wr(0x11801C, 0x23000302); wr(0x100820, 0xFFFFFFFF);
		wr(0x11800C, 0x01000102);
		wr(0x100800, (100 << 16) | 100); wr(0x100A04, (300 << 16) | 200);
		wr(0x100800, (701 << 16) | 50); wr(0x100A04, (1 << 16) | 500);
		wr(0x100800, (813 << 16) | 607); wr(0x100A04, (67 << 16) | 3);
		wr(0x11800C, 0x00000102);
		wr(0x100800, (150 << 16) | 150); wr(0x100A04, (64 << 16) | 64);      // LUT0 again inside the first
		wr(0x11800C, 0);
		check("attribute plane after the paints");
		// the cursor: colours, image = a diagonal band, mask = image plus a border
		uint32_t cfg = 0xE0F0D0, cbg = 0x203040;
		wr(0x118000, 0x3BA0F000);
		fbw(0, 0); fbw(4, 0); fbw(8, cbg); fbw(12, cfg);
		wr(0x100480, 0); wr(0x300118, 0x80008004);
		static uint64_t img[64], msk[64];
		for (int r = 0; r < 64; r++) {
			img[r] = 0; msk[r] = 0;
			for (int c = 0; c < 64; c++) {
				bool in = c >= r - 3 && c <= r + 3, m = c >= r - 6 && c <= r + 6;
				if (in) img[r] |= 1ull << (63 - c);
				if (m) msk[r] |= 1ull << (63 - c);
			}
		}
		wr(0x11801C, 0x00000300);
		for (int b = 6; b <= 7; b++) {
			wr(0x118000, 0x28A00000 | b << 12);
			for (int r = 0; r < 64; r++) {
				uint64_t v = b == 6 ? img[r] : msk[r];
				fbw(r << 13 | 0 << 2, v >> 32); fbw(r << 13 | 32 << 2, v & 0xFFFFFFFF);
			}
		}
		wr(0x118000, 0x13602000);
		auto pos = [&](int x, int y) {      // CURSOR_POS for the sprite at (x, y >= 0), as X computes it (09 3.4)
			int v = x + 384 - 16; return (uint32_t)((v >> 2) << 19 | (v & 3) << 16 | (1023 - y));
		};
		auto grab = [&]() {                 // the next whole frame from the video outputs
			cap_st = 1;
			for (int n = 0; n < 4000000 && cap_st != 3; n++) tick();
			if (cap_st != 3) { printf("FAIL: no frame\n"); fails++; }
		};
		// cx, cy: the sprite's row 0 / column 0; rows above `top` are not shown
		auto expect_frame = [&](const char* what, bool on, int cx, int cy, int top) {
			grab(); grab();                 // the first may have started before the last change
			int bad = 0;
			if (cap_w != 1280 || cap_y != 1024) { printf("FAIL: %s: frame %dx%d\n", what, cap_w, cap_y); fails++; return; }
			for (int y = 0; y < 1024; y++)
				for (int x = 0; x < 1280; x++) {
					int i = y * 2048 + x, c = x - cx, r = y - cy;
					uint32_t want = lut[aref[i] << 8 | ref[i]];
					if (on && c >= 0 && c < 64 && r >= 0 && r < 64 && y >= top && (msk[r] >> (63 - c) & 1))
						want = img[r] >> (63 - c) & 1 ? cfg : cbg;
					uint32_t got = frame[y * 1280 + x];
					if (got != want) { if (bad < 6) printf("  %s: %d,%d is %06x, expected %06x\n", what, x, y, got, want); bad++; }
				}
			if (bad) { printf("FAIL: %s: %d pixels\n", what, bad); fails++; } else printf("ok   %s\n", what);
		};
		expect_frame("picture through LUT0/LUT1, no cursor", false, 0, 0, 0);
		gsc(true, 0xF8300100, pos(100, 200)); gsc(true, 0xF8300104, 0x80);
		expect_frame("cursor at 100,200", true, 100, 200, 0);
		// drawing under it: the cursor stays, the VRAM never sees it
		wr(0x11801C, 0x00000302); wr(0x118010, 0x44); wr(0x118000, 0x2EA02000);
		wr(0x100800, (110 << 16) | 210); wr(0x100A04, (30 << 16) | 10);
		check("VRAM under the cursor after a fill");
		expect_frame("cursor over the fill", true, 100, 200, 0);
		gsc(true, 0xF8300100, pos(-20, 900));
		expect_frame("cursor at -20,900", true, -20, 900, 0);
		gsc(true, 0xF8300100, pos(1250, 1000));
		expect_frame("cursor at 1250,1000 (clipped right and below)", true, 1250, 1000, 0);
		// above the top edge: X writes y' = 0 and the cut-off rows in CURSOR_CTRL[5:0]
		gsc(true, 0xF8300100, pos(300, 0)); gsc(true, 0xF8300104, 0x80 | 10);
		expect_frame("cursor at 300,-10 (10 rows cut off)", true, 300, -10, 0);
		gsc(true, 0xF8300104, 0x00);
		expect_frame("cursor off", false, 0, 0, 0);
		expect("display underruns", t->vid_underrun, 0);
	}
	check("final VRAM");

	printf("%s (%llu cycles)\n", fails ? "FAILED" : "PASS", (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
