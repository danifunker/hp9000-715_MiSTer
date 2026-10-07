// Unit bench for rtl/cpu/pa_ldst.sv: replays the mem suite. The bench owns
// a 64-byte window (filled as the ROM's mem_fill does) and performs each
// access using only what the unit outputs: address, byte enables, store
// data, extracted load data and the new base. Reference: QEMU's mem log.
//   make tb_ldst
#include "Vpa_ldst.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

static const unsigned AREA = 0x00100000;

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* path = argc > 1 ? argv[1] : "obj_dir_tb/mem_vectors.txt";
	FILE* f = fopen(path, "r");
	if (!f) { perror(path); return 2; }
	Vpa_ldst* m = new Vpa_ldst;
	static char line[4096];
	long n = 0, bad = 0;
	std::map<std::string, long> fails;
	while (fgets(line, sizeof line, f)) {
		unsigned base, index, disp, ui, sc, eib, bt, size, stbys, src, kind, bwe;
		unsigned win[16], exp_win[16], er5, er3;
		char* p = line;
		int used = 0;
		if (sscanf(p, "%x %x %x %x %x %x %x %x %x %x %x %x |%n", &base, &index, &disp, &ui, &sc,
		           &eib, &bt, &size, &stbys, &src, &kind, &bwe, &used) < 12) continue;
		p += used;
		for (int i = 0; i < 16; i++) { sscanf(p, "%x%n", &win[i], &used); p += used; }
		sscanf(p, " | %x %x |%n", &er5, &er3, &used); p += used;
		for (int i = 0; i < 16; i++) { sscanf(p, "%x%n", &exp_win[i], &used); p += used; }
		char name[64] = "";
		char* h = strchr(p, '#');
		if (h) sscanf(h + 1, "%63s", name);

		m->base = base; m->index = index; m->disp = disp; m->use_index = ui; m->scale = sc;
		m->ea_is_base = eib; m->base_trunc = bt; m->size = size; m->stbys = stbys;
		m->st_src = src; m->ld_word = 0;
		m->eval();
		unsigned ea = m->ea;
		unsigned r5 = src, r3 = base;
		bool inwin = ea >= AREA && ea < AREA + 64;
		if (inwin) {
			unsigned& w = win[(ea - AREA) >> 2];
			if (kind == 0 || kind == 2) {
				m->ld_word = w;
				m->eval();
				r5 = m->ld_data;
				if (kind == 2) w = 0;               // load and clear
			} else {
				for (int b = 0; b < 4; b++)
					if (m->st_be & (8 >> b)) {
						unsigned sh = 8 * (3 - b);
						w = (w & ~(0xFFu << sh)) | (m->st_data & (0xFFu << sh));
					}
			}
		}
		if (bwe) r3 = m->new_base;
		bool ok = inwin && !m->unaligned && r5 == er5 && (r3 - AREA) == er3 &&
		          !memcmp(win, exp_win, sizeof win);
		n++;
		if (!ok) {
			bad++;
			if (fails[name]++ < 3) {
				printf("FAIL %-10s base=%08x idx=%08x disp=%08x ea=%08x%s  r5 %08x/%08x r3off %08x/%08x\n",
				       name, base, index, disp, ea, m->unaligned ? " UNALIGNED" : "",
				       r5, er5, r3 - AREA, er3);
				for (int i = 0; i < 16; i++)
					if (win[i] != exp_win[i])
						printf("      window[%2d] %08x/%08x\n", i, win[i], exp_win[i]);
			}
		}
	}
	printf("tb_ldst: %ld vectors, %ld mismatches, %zu groups failing\n", n, bad, fails.size());
	delete m;
	return bad ? 1 : 0;
}
