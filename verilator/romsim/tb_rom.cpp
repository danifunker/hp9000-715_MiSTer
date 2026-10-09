// Headless run of the whole machine (verilator/sim.v, `emu`) on HP's boot
// ROM: loads the ROM through the ioctl download (as hps_io does, so the
// loader's patch applies), prints the serial console, the front-panel LED
// byte whenever it changes (the chassis code's LED part), and stops on a
// string, a halt, or a cycle limit. tests/run-rom.sh uses it.
//
//   obj_dir_rom/Vemu [--rom FILE] [+eeprom=HEX] [--max-cycles N] [--until STR (after --type's text, if any)]
//                    [--type STR] [--type-after STR (default BOOT_ADMIN>; "" = at once)]
//                    [--then AFTER STR ...] (more typing, each after AFTER appears; AFTER = @CYCLE: at
//                    that cycle instead) [--ps2] (typing goes to the PS/2 keyboard as set-2 key
//                    events, US layout, for a console on graphics) [--serial-log FILE]
//                    [--model 0|1|2] [--ram-lg N] [--leds] [--buserr]
//                    [--trace N] [--trace-from CYCLE] [--traps] [--stamp] [--sample N] [--gsctrace] [--scsitrace] [--miotrace] [--evtrace]
//                    [--turbo N [--turbo-after CYCLE] [--turbo-until CYCLE]]  (CR16 N x faster from
//                    --turbo-after, default 30M, until --turbo-until -- an OS needs the real rate:
//                    shortens the ROM's delays; selftest1's timer test needs the real rate)
//                    [--disk0 IMG] [--disk1 IMG] [--cd ISO]   (SCSI IDs 6, 5, 2; disks are written
//                    unless --snapshot: then writes stay in memory, like QEMU's -snapshot;
//                    --sdtrace logs every block request)
//                    [--save-at CYCLE FILE] [--save-on STR FILE] [--restore FILE]   (whole-model
//                    checkpoints, at a cycle or when the console first prints STR; a restored
//                    run keeps the cycle count, and needs the same build)
//                    [--memdump CYCLE ADDR LEN FILE]   (the ideal RAM, LEN bytes from physical ADDR, at CYCLE)
//                    [--fbshot CYCLE FILE] (may repeat) [--fbshot-end FILE]   (Artist's screen as a PPM: the
//                    active area of the VRAM through LUT0, at CYCLE / when the run ends) [--arttrace]
//                    (every Artist operation: fills, moves, pixel writes, reads, LUT loads)
//                    [--watch A B]   (every retired load/store whose physical address is in [A, B): hit flags, the data)
//                    [--watchval V]  (every retired load whose data is V, with its virtual and physical address)
//                    [--pcwatch PC]  (that instruction's retirements, with the same fields; may repeat)
//                    [--fptrace [--fptrace-from CYCLE]]   (the FP unit: every operation issued, its
//                    operands, result and the FPSR before and after, FP loads' data, FP stores' data)
//                    [--wtrace A B]   (every cycle from A to B: the core's W and M stages and the
//                    TLB's state, with a dump of all TLB entries at A and at B; reads the model's
//                    internal signals, so it follows pa_core / pa_tlb renames)
#include "Vemu.h"
#include "Vemu___024root.h"
#include "verilated.h"
#include "verilated_save.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static Vemu* top;
static unsigned long long fptrace_from = 0;
static bool fptrace = false;

// --wtrace: the pipeline's W/M stages and the TLB, from the model's internals
#define CORE_(x) top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__u_core__DOT__##x
#define TLB_(x)  top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__u_tlb__DOT__##x
static void dump_tlb(unsigned long long t) {
	fprintf(stderr, "[%12llu] TLB valid %016llx lockout %016llx lockin %016llx used %016llx\n", t,
	        (unsigned long long)TLB_(valid), (unsigned long long)TLB_(lockout), (unsigned long long)TLB_(lockin),
	        (unsigned long long)TLB_(used));
	for (int i = 0; i < 64; i++) {
		unsigned long long tg = TLB_(tag)[i], py = TLB_(pay)[i];
		fprintf(stderr, "  e%02d %c%c sp %04llx vpn %05llx rpn %05llx ar %02llx aid %04llx tdbu %llx\n", i,
		        ((TLB_(valid) >> i) & 1) ? 'V' : '-', ((TLB_(lockout) >> i) & 1) ? 'L' : '-', tg >> 20, tg & 0xFFFFF,
		        py >> 26, (py >> 19) & 0x7F, (py >> 4) & 0x7FFF, py & 0xF);
	}
	for (int i = 0; i < 8; i++)
		fprintf(stderr, "  b%d %c%c sp %04x vpn %04x mask %02x trans %04x\n", i, ((TLB_(b_valid) >> i) & 1) ? 'V' : '-',
		        ((TLB_(b_lockout) >> i) & 1) ? 'L' : '-', TLB_(b_space)[i], TLB_(b_vpn)[i], TLB_(b_mask)[i], TLB_(b_trans)[i]);
}
static void wtrace_line(unsigned long long t) {
	fprintf(stderr, "%12llu W v%d st%d nul%d %08x ea %08x sp %04x rpn %05x trap %2d walk%d wkn%d hit%d cch%d pdir %08x"
	        " | M v%d %08x ea %08x | TLB st%d tag %09llx pg%d b%d lkhit%d lkrpn %05x\n", t,
	        CORE_(w_valid), CORE_(wst), CORE_(w_nul), CORE_(w_iaoq_f), CORE_(w_ea), CORE_(w_space), CORE_(w_rpn),
	        CORE_(w_trap), CORE_(w_walk), CORE_(w_walkable_now), CORE_(w_hit), CORE_(w_cached), CORE_(w_pdir_a),
	        CORE_(m_valid), CORE_(m_iaoq_f), CORE_(m_ea), TLB_(st),
	        (unsigned long long)top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__tlb_lk_tag_r, TLB_(pg_hit), TLB_(b_hit),
	        top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__tlb_lk_hit, top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__tlb_lk_rpn);
	// the D-cache engine every cycle of the window
#define DC_(x) top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__u_dcache__DOT__##x
#define CPU_(x) top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__##x
	fprintf(stderr, "%12s   dc st%d op%d req%d done%d err%d addr %08x rpn %05x idx %04x traddr %03x draddr %04x tq %05x qhit%d"
	        " dq %016llx twe%d twa %03x dwe%d dwa %04x fill %x cnt%d rd2 %08x%08x_%08x%08x\n", "",
	        DC_(st), CPU_(dc_op), CPU_(dc_op_req), CPU_(dc_op_done), CPU_(dc_op_err), CPU_(dc_op_addr), CPU_(dc_op_rpn),
	        DC_(op_idx), DC_(t_raddr), DC_(d_raddr), DC_(tq_rpn), DC_(q_hit), (unsigned long long)DC_(d_q)[0] | ((unsigned long long)DC_(d_q)[1] << 32),
	        DC_(t_we), DC_(t_waddr), DC_(d_we), DC_(d_waddr), DC_(fill_got), DC_(cnt),
	        CPU_(dc_op_rd2)[3], CPU_(dc_op_rd2)[2], CPU_(dc_op_rd2)[1], CPU_(dc_op_rd2)[0]);
	// the walker's view: the PDIR entry it read (words 0-3), its verdict, the CR28 it will write, CR28 now
	if (CORE_(wst) == 5 || CORE_(wst) == 8 || CORE_(wst) == 9)
		fprintf(stderr, "%12s   walker pdir %08x %08x %08x %08x cr28we%d cr28val %08x tr4 %08x dr24 %08x dr25 %08x\n", "",
		        top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__dc_op_rd2[3], top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__dc_op_rd2[2], top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__dc_op_rd2[1], top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__dc_op_rd2[0],
		        CORE_(w_cr28_we), CORE_(w_cr28_val), CORE_(tr)[4], CORE_(dr24), CORE_(dr25));
}
// --fptrace: the FP unit's events (pa_fpunit): every FP operation issued at W
// commit with the FPSR before it, the operands the engine starts from, its
// result and the FPSR afterwards, every FP load's data and every FP store's
#define FPU_(x) top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__u_fpu__DOT__##x
static void fptrace_line(unsigned long long t) {
	unsigned insn = CORE_(w_insn), op = insn >> 26;
	bool commit = CORE_(w_commit) && !CORE_(w_nul);
	bool is_fp = op == 0x0C || op == 0x0E || op == 0x06 || op == 0x26;
	bool is_fpm = op == 0x09 || op == 0x0B;
	if (commit && is_fp)
		fprintf(stderr, "%12llu FP issue  pc %08x insn %08x fpsr %08x\n", t, CORE_(w_iaoq_f), insn, FPU_(fpsr));
	if (commit && is_fpm && !(insn & 0x200))
		fprintf(stderr, "%12llu FP load   pc %08x insn %08x data %016llx ea %08x\n", t, CORE_(w_iaoq_f), insn,
		        (unsigned long long)CORE_(w_ld), CORE_(w_ea));
	if (commit && is_fpm && (insn & 0x200))
		fprintf(stderr, "%12llu FP store  pc %08x insn %08x data %016llx ea %08x\n", t, CORE_(w_iaoq_f), insn,
		        (unsigned long long)top->rootp->emu__DOT__u_hp715__DOT__u_cpu__DOT__fp_st_data, CORE_(w_ea));
	if (FPU_(start_r))
		fprintf(stderr, "%12llu FP start  op %d sgl %d a %016llx b %016llx cond %d\n", t, FPU_(hold_op), FPU_(hold_sgl),
		        (unsigned long long)FPU_(hold_a), (unsigned long long)FPU_(hold_b), FPU_(hold_cond));
	if (FPU_(eng_done))
		fprintf(stderr, "%12llu FP done   result %016llx we %d cmp %d flags %02x unimpl %d st %d fpsr %08x\n", t,
		        (unsigned long long)FPU_(eng_result), FPU_(eng_we), FPU_(eng_cmp), FPU_(eng_flags), FPU_(eng_unimpl),
		        FPU_(st), FPU_(fpsr));
}
// --memdump CYCLE ADDR LEN FILE: the ideal RAM array (64-bit words, byte 0 of
// a doubleword in bits 63:56) written out big-endian as the CPU sees it
static void dump_mem(const char* file, unsigned long long addr, unsigned long long len) {
	FILE* f = fopen(file, "wb");
	if (!f) { perror(file); return; }
	for (unsigned long long a = addr; a < addr + len; a++) {
		unsigned long long q = top->rootp->emu__DOT__ram[a >> 3];
		fputc((q >> (8 * (7 - (a & 7)))) & 0xFF, f);
	}
	fclose(f);
	fprintf(stderr, "romsim: dumped %llu bytes at %08llx to %s\n", len, addr, file);
}
// --fbshot: Artist's screen (the VRAM array in sim.v through LUT0, copied here
// from its writes),
// the active area (1280 x 1024 until the ROM programs a mode), as a PPM
static unsigned lut0[256];
static void fbshot(const char* file) {
	unsigned w = top->gfx_width, h = top->gfx_height;
	if (w == 0 || w > 2048 || h == 0 || h > 1024) { w = 1280; h = 1024; }
	FILE* f = fopen(file, "wb");
	if (!f) { perror(file); return; }
	fprintf(f, "P6\n%u %u\n255\n", w, h);
	for (unsigned y = 0; y < h; y++)
		for (unsigned x = 0; x < w; x++) {
			unsigned long long q = top->rootp->emu__DOT__vram[y * 256 + x / 8];
			unsigned rgb = lut0[(q >> (8 * (x & 7))) & 0xFF];
			fputc(rgb >> 16, f); fputc((rgb >> 8) & 0xFF, f); fputc(rgb & 0xFF, f);
		}
	fclose(f);
	fprintf(stderr, "romsim: Artist screen %ux%u (video %s) to %s\n", w, h, top->gfx_on ? "on" : "off", file);
}
static uint64_t cyc = 0;

// --ps2: a character as set-2 key events ({pressed, E0, code}), US layout
static bool ps2_events(char c, std::vector<unsigned>& ev) {
	static const char* lo = "abcdefghijklmnopqrstuvwxyz0123456789`-=\\[];',./ \r\b\t\x1b";
	static const char* hi = "ABCDEFGHIJKLMNOPQRSTUVWXYZ)!@#$%^&*(~_+|{}:\"<>?";
	static const unsigned char code[] = {
		0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D,
		0x15, 0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A,
		0x45, 0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46,
		0x0E, 0x4E, 0x55, 0x5D, 0x54, 0x5B, 0x4C, 0x52, 0x41, 0x49, 0x4A, 0x29, 0x5A, 0x66, 0x0D, 0x76 };
	const char* p;
	bool shift = false;
	unsigned k;
	if (c && (p = strchr(lo, c))) k = code[p - lo];
	else if (c && (p = strchr(hi, c))) { k = code[p - hi]; shift = true; }
	else return false;
	if (shift) ev.push_back(0x200 | 0x12);
	ev.push_back(0x200 | k); ev.push_back(k);
	if (shift) ev.push_back(0x12);
	return true;
}

// hps_io's block devices, for the SCSI images: the core raises sd_rd/sd_wr
// with sd_lba and sd_blk_cnt; we raise sd_ack, move (sd_blk_cnt+1) x 512
// bytes as 16-bit words (the earlier byte in the low half) through
// sd_buff_*, and drop sd_ack.
struct BlkDev {
	FILE* f = nullptr;
	uint64_t size = 0;
	std::map<uint64_t, std::vector<uint8_t>> overlay;   // --snapshot: sectors written
};
static BlkDev blk[3];
static bool snapshot = false;
static bool sdtrace = false;    // --sdtrace: every block-device request

static void blk_read(BlkDev& d, uint64_t lba, uint8_t* p, size_t n) {
	if (d.f) { fseeko(d.f, (off_t)lba * 512, SEEK_SET); size_t got = fread(p, 1, n, d.f); (void)got; }
	for (size_t k = 0; k < n / 512; k++) {
		auto it = d.overlay.find(lba + k);
		if (it != d.overlay.end()) memcpy(p + 512 * k, it->second.data(), 512);
	}
}

static void blk_write(BlkDev& d, uint64_t lba, const uint8_t* p, size_t n) {
	if (!d.f) return;
	if (snapshot) {
		for (size_t k = 0; k < n / 512; k++) d.overlay[lba + k].assign(p + 512 * k, p + 512 * (k + 1));
	} else {
		fseeko(d.f, (off_t)lba * 512, SEEK_SET); fwrite(p, 1, n, d.f); fflush(d.f);
	}
}
static struct {
	int st = 0;           // 0 idle, 1 reading, 2 writing
	int n = 0;            // slot
	uint32_t words = 0, w = 0;
	std::vector<uint8_t> buf;
	uint64_t lba = 0;
	int phase = 0;
} sd;

static void sd_step() {
	top->sd_buff_wr = 0;
	switch (sd.st) {
	case 0:
		for (int n = 0; n < 3; n++)
			if (((top->sd_rd | top->sd_wr) >> n) & 1) {
				sd.n = n; sd.lba = top->sd_lba[n];
				sd.words = (top->sd_blk_cnt[n] + 1) * 256; sd.w = 0; sd.phase = 0;
				if (sdtrace)
					fprintf(stderr, "[%12llu] sd%d %s lba %llu x%u\n", (unsigned long long)cyc, n,
					        ((top->sd_rd >> n) & 1) ? "rd" : "wr", (unsigned long long)sd.lba, sd.words / 256);
				sd.buf.assign(sd.words * 2, 0);
				top->sd_ack = 1 << n;
				if ((top->sd_rd >> n) & 1) {
					blk_read(blk[n], sd.lba, sd.buf.data(), sd.buf.size());
					sd.st = 1;
				} else sd.st = 2;
				break;
			}
		break;
	case 1:   // one word every 4 cycles
		if (++sd.phase & 3) break;
		if (sd.w < sd.words) {
			top->sd_buff_addr = sd.w;
			top->sd_buff_dout = sd.buf[2 * sd.w] | (sd.buf[2 * sd.w + 1] << 8);
			top->sd_buff_wr = 1;
			sd.w++;
		} else { top->sd_ack = 0; sd.st = 0; }
		break;
	case 2:   // set the address, read the word two cycles later
		if ((++sd.phase & 3) == 1) top->sd_buff_addr = sd.w;
		else if ((sd.phase & 3) == 0) {
			uint16_t v = top->sd_buff_din[sd.n];
			sd.buf[2 * sd.w] = v & 0xFF; sd.buf[2 * sd.w + 1] = v >> 8;
			if (++sd.w == sd.words) {
				blk_write(blk[sd.n], sd.lba, sd.buf.data(), sd.buf.size());
				top->sd_ack = 0; sd.st = 0;
			}
		}
		break;
	}
}

static void tick() {
	top->clk_sys = 0; top->eval();
	top->clk_sys = 1; top->eval();
	cyc++;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* rom = "../roms/hp715_pdc_rev1.6.bin";
	const char* logpath = nullptr;
	unsigned long long max_cycles = 2000000000ULL, trace = 0, trace_from = 0;
	std::string until, type_str, type_after = "BOOT_ADMIN>";
	// what to type into the serial port: --type TEXT (after --type-after,
	// default the first BOOT_ADMIN>), then each --then AFTER TEXT in order;
	// each AFTER is looked for in the output since the previous text went in
	struct Step { std::string after, text; };
	std::vector<Step> steps;
	int model = 0, ram_lg = 0;
	bool show_leds = false, show_buserr = false, show_traps = false, stamp = false;
	unsigned long long sample = 0; uint64_t save_at = 0;
	unsigned long long wtrace_a = 0, wtrace_b = 0;
	unsigned trace_flags = 0, turbo = 0;
	uint64_t turbo_after = 30000000, turbo_until = ~0ull, flags_from = 0;
	const char* save_file = nullptr;
	std::string save_on;
	const char* blk_path[3] = {nullptr, nullptr, nullptr};
	const char* restore_file = nullptr;
	unsigned long long memdump_at = 0, memdump_addr = 0, memdump_len = 0; const char* memdump_file = nullptr;
	unsigned long long watch_a = 0, watch_b = 0;   // --watch A B: retired loads/stores with an EA in [A, B)
	unsigned wp_ea = 0, wp_rpn = 0, wp_hit = 0, wp_cch = 0, wp_ld = 0, wp_res = 0;
	unsigned watch_val = 0; bool watch_val_on = false, watch_on = false;   // --watchval V: retired loads whose data is V
	std::vector<unsigned> pcwatch;                        // --pcwatch PC: that instruction's retirements
	std::map<unsigned long long, std::string> fbshots;   // --fbshot CYCLE FILE
	const char* fbshot_end = nullptr;
	bool ps2 = false;                                    // --ps2: type on the PS/2 keyboard
	std::vector<unsigned> kev;                           // its pending key events
	size_t kev_pos = 0;
	unsigned kev_tog = 0;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](void) -> const char* { return i + 1 < argc ? argv[++i] : ""; };
		if (a == "--rom") rom = next();
		else if (a == "--max-cycles") max_cycles = strtoull(next(), 0, 0);
		else if (a == "--until") until = next();
		else if (a == "--type") type_str = next();
		else if (a == "--type-after") type_after = next();
		else if (a == "--then") { std::string w = next(); steps.push_back({w, next()}); }
		else if (a == "--serial-log") logpath = next();
		else if (a == "--model") model = atoi(next());
		else if (a == "--ram-lg") ram_lg = atoi(next());
		else if (a == "--leds") show_leds = true;
		else if (a == "--buserr") show_buserr = true;
		else if (a == "--traps") show_traps = true;
		else if (a == "--stamp") stamp = true;
		else if (a == "--gsctrace") trace_flags |= 1;
		else if (a == "--disk0" || a == "--disk1" || a == "--cd") {
			int n = a == "--disk0" ? 0 : a == "--disk1" ? 1 : 2;
			blk_path[n] = next();
		}
		else if (a == "--l1trace") trace_flags |= 2;
		else if (a == "--scsitrace") trace_flags |= 4;
		else if (a == "--miotrace") trace_flags |= 8;
		else if (a == "--evtrace") trace_flags |= 16;
		else if (a == "--arttrace") trace_flags |= 32;
		else if (a == "--fbshot") { unsigned long long c = strtoull(next(), 0, 0); fbshots[c] = next(); }
		else if (a == "--fbshot-end") fbshot_end = next();
		else if (a == "--ps2") ps2 = true;
		else if (a == "--flags-from") flags_from = strtoull(next(), 0, 0);
		else if (a == "--turbo") turbo = atoi(next());
		else if (a == "--turbo-after") turbo_after = strtoull(next(), 0, 0);
		else if (a == "--turbo-until") turbo_until = strtoull(next(), 0, 0);
		else if (a == "--save-at") { save_at = strtoull(next(), 0, 0); save_file = next(); }
		else if (a == "--save-on") { save_on = next(); save_file = next(); }
		else if (a == "--snapshot") snapshot = true;
		else if (a == "--sdtrace") sdtrace = true;
		else if (a == "--restore") restore_file = next();
		else if (a == "--sample") sample = strtoull(next(), 0, 0);
		else if (a == "--wtrace") { wtrace_a = strtoull(next(), 0, 0); wtrace_b = strtoull(next(), 0, 0); }
		else if (a == "--fptrace") fptrace = true;
		else if (a == "--fptrace-from") fptrace_from = strtoull(next(), 0, 0);
		else if (a == "--trace") trace = strtoull(next(), 0, 0);
		else if (a == "--trace-from") trace_from = strtoull(next(), 0, 0);
		else if (a == "--watch") { watch_a = strtoull(next(), 0, 0); watch_b = strtoull(next(), 0, 0); watch_on = true; }
		else if (a == "--pcwatch") { pcwatch.push_back(strtoul(next(), 0, 0)); watch_on = true; }
		else if (a == "--watchval") { watch_val = strtoul(next(), 0, 0); watch_on = true; watch_val_on = true; }
		else if (a == "--memdump") { memdump_at = strtoull(next(), 0, 0); memdump_addr = strtoull(next(), 0, 0);
		                             memdump_len = strtoull(next(), 0, 0); memdump_file = next(); }
		else if (a[0] != '+') { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	for (int n = 0; n < 3; n++) {
		if (!blk_path[n]) continue;
		blk[n].f = fopen(blk_path[n], n == 2 || snapshot ? "rb" : "r+b");
		if (!blk[n].f) { fprintf(stderr, "cannot open %s\n", blk_path[n]); return 2; }
		fseeko(blk[n].f, 0, SEEK_END); blk[n].size = ftello(blk[n].f);
	}
	// escape sequences in --type: \r \n
	if (!type_str.empty()) steps.insert(steps.begin(), Step{type_after, type_str});
	for (auto& st : steps) {
		std::string t;
		for (size_t k = 0; k < st.text.size(); k++) {
			if (st.text[k] == '\\' && k + 1 < st.text.size()) {
				char c = st.text[++k];
				t.push_back(c == 'r' ? '\r' : c == 'n' ? '\n' : c == 'e' ? 27 : c);
			} else t.push_back(st.text[k]);
		}
		st.text = t;
	}

	FILE* f = fopen(rom, "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", rom); return 2; }
	std::vector<unsigned char> img;
	int ch;
	while ((ch = fgetc(f)) != EOF) img.push_back((unsigned char)ch);
	fclose(f);
	if (img.size() & 1) img.push_back(0);
	FILE* log = logpath ? fopen(logpath, "w") : nullptr;

	top = new Vemu;
	top->reset = 1;
	top->sim_status = (model & 3) | ((ram_lg & 15) << 2);
	top->ps2_key = 0; top->ps2_mouse = 0;
	top->uart_rx_strobe = 0; top->toc_button = 0; top->soft_power_off = 0;
	top->img_present = 0;
	for (int n = 0; n < 3; n++) {
		top->img_blocks[n] = blk[n].size / 512;
		if (blk[n].f) top->img_present |= 1 << n;
	}
	top->sd_ack = 0; top->sd_buff_wr = 0;
	uint64_t start;
	if (restore_file) {
		VerilatedRestore is;
		is.open(restore_file);
		is >> start >> cyc;
		is >> *top;
		is.close();
		fprintf(stderr, "romsim: restored %s at cycle %llu\n", restore_file, cyc - start);
	} else {
		for (int k = 0; k < 8; k++) tick();
		// the ROM download, 16 bits per write, the earlier byte in the low half
		top->ioctl_index = 0; top->ioctl_download = 1;
		tick();
		for (size_t k = 0; k < img.size(); k += 2) {
			top->ioctl_addr = k; top->ioctl_dout = img[k] | (img[k + 1] << 8); top->ioctl_wr = 1;
			tick();
			top->ioctl_wr = 0;
			tick();
		}
		top->ioctl_download = 0;
		tick();
		top->reset = 0;
		start = cyc;
	}

	std::string out;
	top->sim_trace = flags_from ? 0 : trace_flags;
	unsigned long long retired = 0, traps = 0, traced = 0, next_type = 0;
	size_t typed_pos = 0, step = 0;
	bool save_pending = false;   // --save-on matched, waiting for the block device
	bool bol = true;   // the console is at the beginning of a line (--stamp)
	bool typing = !steps.empty() && steps[0].after.empty();   // --type-after "": type at once (after a restore)
	if (typing) next_type = cyc + 200000;
	int last_led = -1, rc = 1;
	const char* why = "cycle limit";
	while (cyc - start < max_cycles) {
		top->uart_rx_strobe = 0;
		// a step that waits for a cycle (AFTER = @CYCLE)
		if (!typing && step < steps.size() && steps[step].after.size() > 1 && steps[step].after[0] == '@' &&
		    cyc - start >= strtoull(steps[step].after.c_str() + 1, 0, 0)) { typing = true; next_type = cyc + 1000; }
		// PS/2: one key event every 30000 cycles
		if (kev_pos < kev.size() && cyc >= next_type) {
			kev_tog ^= 1;
			top->ps2_key = (kev_tog << 10) | kev[kev_pos++];
			next_type = cyc + 30000;
		} else if (ps2 && typing && kev_pos == kev.size() && cyc >= next_type) {
			const std::string& typed = steps[step].text;
			kev.clear(); kev_pos = 0;
			if (!ps2_events(typed[typed_pos], kev)) fprintf(stderr, "romsim: no PS/2 key for %02x\n", (unsigned char)typed[typed_pos]);
			typed_pos++;
			if (typed_pos == typed.size()) {
				out.clear(); typing = false; typed_pos = 0; step++;
				if (step < steps.size() && steps[step].after.empty()) { typing = true; next_type = cyc + 200000; }
			}
		} else if (!ps2 && typing && cyc >= next_type && !top->uart_rx_full) {
			const std::string& typed = steps[step].text;
			top->uart_rx_strobe = 1; top->uart_rx_byte = typed[typed_pos++];
			next_type = cyc + 20000;
			if (typed_pos == typed.size()) {
				// the next step (and --until) look at what follows
				out.clear(); typing = false; typed_pos = 0; step++;
				if (step < steps.size() && steps[step].after.empty()) { typing = true; next_type = cyc + 200000; }
			}
		}
		sd_step();
		if (watch_on) { wp_ea = CORE_(w_ea); wp_rpn = CORE_(w_rpn); wp_hit = CORE_(w_hit); wp_cch = CORE_(w_cached); wp_ld = CORE_(ld_data); wp_res = CORE_(w_result); }
		tick();
		if (top->gfx_pal_wr) lut0[top->gfx_pal_addr] = top->gfx_pal_rgb;
		unsigned long long t = cyc - start;
		if (memdump_file && t == memdump_at) { dump_mem(memdump_file, memdump_addr, memdump_len); memdump_file = nullptr; }
		if (!fbshots.empty() && t == fbshots.begin()->first) { fbshot(fbshots.begin()->second.c_str()); fbshots.erase(fbshots.begin()); }
		if (fptrace && t >= fptrace_from) fptrace_line(t);
		if (wtrace_b && t >= wtrace_a && t <= wtrace_b) {
			if (t == wtrace_a) dump_tlb(t);
			wtrace_line(t);
			if (t == wtrace_b) dump_tlb(t);
		}
		top->sim_status = (model & 3) | ((ram_lg & 15) << 2) | (t >= turbo_after && t < turbo_until ? (turbo & 15) << 6 : 0);
		if (flags_from && t == flags_from) top->sim_trace = trace_flags;
		auto save = [&]() {
			VerilatedSave os;
			os.open(save_file);
			os << start << cyc;
			os << *top;
			os.close();
			fprintf(stderr, "romsim: saved %s at cycle %llu\n", save_file, t);
		};
		// a checkpoint does not hold the block device's transfer state
		// (sd_step above), so it waits for the device to be idle
		bool sd_idle = sd.st == 0 && !top->sd_rd && !top->sd_wr;
		if (save_file && save_on.empty() && t >= save_at && sd_idle) { save(); save_file = nullptr; }
		if (save_pending && sd_idle) { save(); save_pending = false; save_on.clear(); save_file = nullptr; }
		if (top->uart_tx_strobe) {
			char c = (char)top->uart_tx_byte;
			if (c != '\r') {
				if (stamp && bol) printf("[%12llu] ", t);
				bol = c == '\n';
				fputc(c, stdout); fflush(stdout);
				if (log) { fputc(c, log); fflush(log); }
				out.push_back(c);
				if (out.size() > 4096) out.erase(0, out.size() - 2048);
			}
			if (!typing && step < steps.size() && steps[step].after[0] != '@' && out.find(steps[step].after) != std::string::npos) {
				typing = true; next_type = cyc + 200000;
			}
			if (!save_on.empty() && out.find(save_on) != std::string::npos) save_pending = true;
			if (!until.empty() && step == steps.size() && out.find(until) != std::string::npos) {
				rc = 0; why = "found"; break;
			}
		}
		if (top->led_strobe && show_leds) {
			int led = (~top->leds) & 0xFF;
			if (led != last_led) fprintf(stderr, "[%12llu] LED %02X\n", t, led);
			last_led = led;
		}
		if (top->debug_buserr && show_buserr)
			fprintf(stderr, "[%12llu] bus error %08X (iaoq %08X)\n", t, top->debug_buserr_addr, top->debug_iaoq_f);
		if (top->debug_retire) {
			retired++;
			if (watch_on) {
				unsigned op = top->debug_insn >> 26;
				bool mem = (op >= 0x10 && op <= 0x13) || (op >= 0x18 && op <= 0x1B) || op == 0x03 || op == 0x09 || op == 0x0B;
				// debug_retire is registered: the W-stage values of the retiring
				// instruction are the previous cycle's (wp_*, sampled below)
				unsigned pa = (wp_rpn << 12) | (wp_ea & 0xFFF);          // the translated (physical) address
				bool is_load = mem && !((op >= 0x18 && op <= 0x1B) || op == 0x09 || op == 0x0B) && !(op == 0x03 && (top->debug_insn & 0x200));
				bool pc_hit = false;
				for (unsigned pc : pcwatch) if (top->debug_iaoq_f == pc) pc_hit = true;
				if (pc_hit || (mem && ((watch_b && pa >= watch_a && pa < watch_b) || (watch_val_on && is_load && wp_ld == watch_val)))) {
					unsigned tr = (op >= 0x18) ? (top->debug_insn >> 16) & 31 : (top->debug_insn & 31);   // stores: r; loads: t
					fprintf(stderr, "%12llu watch %08x %08x ea %08x pa %08x hit%d cch%d r%u ld_data %08x w_result %08x\n", t,
					        top->debug_iaoq_f, top->debug_insn, wp_ea, pa, wp_hit, wp_cch, tr, wp_ld, wp_res);
				}
			}
			if (trace && t >= trace_from && traced < trace) {
				fprintf(stderr, "%12llu %08x %08x%s\n", t, top->debug_iaoq_f, top->debug_insn,
				        top->debug_nullified ? " (n)" : "");
				traced++;
			}
		}
		if (top->debug_trap) {
			traps++;
			if (show_traps || (trace && t >= trace_from && traced < trace))
				fprintf(stderr, "[%12llu] TRAP %u at %08x psw %08x\n", t, top->debug_trap_vec, top->debug_iaoq_f,
				        top->debug_psw);
		}
		if (top->debug_halted) { why = "halted"; break; }
		if (sample && t % sample == 0)
			fprintf(stderr, "[%12llu] sample IAOQ %08x insn %08x psw %08x\n", t, top->debug_iaoq_f, top->debug_insn,
			        top->debug_psw);
	}
	fprintf(stderr, "\nromsim: %s after %llu cycles, %llu instructions, %llu interruptions; LED %02X, IAOQ %08X\n",
	        why, cyc - start, retired, traps, (~top->leds) & 0xFF, top->debug_iaoq_f);
	if (fbshot_end) fbshot(fbshot_end);
	if (log) fclose(log);
	top->final();
	delete top;
	return rc;
}
