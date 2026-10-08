// Headless run of the whole machine (verilator/sim.v, `emu`) on HP's boot
// ROM: loads the ROM through the ioctl download (as hps_io does, so the
// loader's patch applies), prints the serial console, the front-panel LED
// byte whenever it changes (the chassis code's LED part), and stops on a
// string, a halt, or a cycle limit. tests/run-rom.sh uses it.
//
//   obj_dir_rom/Vemu [--rom FILE] [+eeprom=HEX] [--max-cycles N] [--until STR]
//                    [--type STR] [--type-after STR] [--serial-log FILE]
//                    [--model 0|1|2] [--ram-lg N] [--leds] [--buserr]
//                    [--trace N] [--trace-from CYCLE] [--traps] [--stamp] [--sample N] [--gsctrace]
//                    [--turbo N [--turbo-after CYCLE]]  (CR16 N x faster after CYCLE, default 30M:
//                    shortens the ROM's delays; selftest1's timer test needs the real rate)
//                    [--disk0 IMG] [--disk1 IMG] [--cd ISO]   (SCSI IDs 6, 5, 2; disks are written)
//                    [--save-at CYCLE FILE] [--restore FILE]   (whole-model checkpoints;
//                    a restored run keeps the cycle count, and needs the same build)
#include "Vemu.h"
#include "verilated.h"
#include "verilated_save.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vemu* top;
static uint64_t cyc = 0;

// hps_io's block devices, for the SCSI images: the core raises sd_rd/sd_wr
// with sd_lba and sd_blk_cnt; we raise sd_ack, move (sd_blk_cnt+1) x 512
// bytes as 16-bit words (the earlier byte in the low half) through
// sd_buff_*, and drop sd_ack.
struct BlkDev {
	FILE* f = nullptr;
	uint64_t size = 0;
};
static BlkDev blk[3];
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
				sd.buf.assign(sd.words * 2, 0);
				top->sd_ack = 1 << n;
				if ((top->sd_rd >> n) & 1) {
					if (blk[n].f) { fseeko(blk[n].f, (off_t)sd.lba * 512, SEEK_SET);
					                size_t got = fread(sd.buf.data(), 1, sd.buf.size(), blk[n].f); (void)got; }
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
				if (blk[sd.n].f) { fseeko(blk[sd.n].f, (off_t)sd.lba * 512, SEEK_SET);
				                   fwrite(sd.buf.data(), 1, sd.buf.size(), blk[sd.n].f); fflush(blk[sd.n].f); }
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
	int model = 0, ram_lg = 0;
	bool show_leds = false, show_buserr = false, show_traps = false, stamp = false;
	unsigned long long sample = 0; uint64_t save_at = 0;
	unsigned trace_flags = 0, turbo = 0;
	uint64_t turbo_after = 30000000, flags_from = 0;
	const char* save_file = nullptr;
	const char* restore_file = nullptr;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](void) -> const char* { return i + 1 < argc ? argv[++i] : ""; };
		if (a == "--rom") rom = next();
		else if (a == "--max-cycles") max_cycles = strtoull(next(), 0, 0);
		else if (a == "--until") until = next();
		else if (a == "--type") type_str = next();
		else if (a == "--type-after") type_after = next();
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
			const char* path = next();
			blk[n].f = fopen(path, n == 2 ? "rb" : "r+b");
			if (!blk[n].f) { fprintf(stderr, "cannot open %s\n", path); return 2; }
			fseeko(blk[n].f, 0, SEEK_END); blk[n].size = ftello(blk[n].f);
		}
		else if (a == "--l1trace") trace_flags |= 2;
		else if (a == "--flags-from") flags_from = strtoull(next(), 0, 0);
		else if (a == "--turbo") turbo = atoi(next());
		else if (a == "--turbo-after") turbo_after = strtoull(next(), 0, 0);
		else if (a == "--save-at") { save_at = strtoull(next(), 0, 0); save_file = next(); }
		else if (a == "--restore") restore_file = next();
		else if (a == "--sample") sample = strtoull(next(), 0, 0);
		else if (a == "--trace") trace = strtoull(next(), 0, 0);
		else if (a == "--trace-from") trace_from = strtoull(next(), 0, 0);
		else if (a[0] != '+') { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	// escape sequences in --type: \r \n
	std::string typed;
	for (size_t k = 0; k < type_str.size(); k++) {
		if (type_str[k] == '\\' && k + 1 < type_str.size()) {
			char c = type_str[++k];
			typed.push_back(c == 'r' ? '\r' : c == 'n' ? '\n' : c == 'e' ? 27 : c);
		} else typed.push_back(type_str[k]);
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
	size_t typed_pos = 0;
	bool typing = false;
	int last_led = -1, rc = 1;
	const char* why = "cycle limit";
	while (cyc - start < max_cycles) {
		top->uart_rx_strobe = 0;
		if (typing && typed_pos < typed.size() && cyc >= next_type && !top->uart_rx_full) {
			top->uart_rx_strobe = 1; top->uart_rx_byte = typed[typed_pos++];
			next_type = cyc + 20000;
		}
		sd_step();
		tick();
		unsigned long long t = cyc - start;
		top->sim_status = (model & 3) | ((ram_lg & 15) << 2) | (t >= turbo_after ? (turbo & 15) << 6 : 0);
		if (flags_from && t == flags_from) top->sim_trace = trace_flags;
		if (save_file && t == save_at) {
			VerilatedSave os;
			os.open(save_file);
			os << start << cyc;
			os << *top;
			os.close();
			fprintf(stderr, "romsim: saved %s at cycle %llu\n", save_file, t);
		}
		if (top->uart_tx_strobe) {
			char c = (char)top->uart_tx_byte;
			if (c != '\r') {
				if (stamp && (out.empty() || out.back() == '\n')) printf("[%12llu] ", t);
				fputc(c, stdout); fflush(stdout);
				if (log) { fputc(c, log); fflush(log); }
				out.push_back(c);
				if (out.size() > 4096) out.erase(0, out.size() - 2048);
			}
			if (!typing && !typed.empty() && out.find(type_after) != std::string::npos) {
				typing = true; next_type = cyc + 200000;
			}
			if (!until.empty() && out.find(until) != std::string::npos) { rc = 0; why = "found"; break; }
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
	if (log) fclose(log);
	top->final();
	delete top;
	return rc;
}
