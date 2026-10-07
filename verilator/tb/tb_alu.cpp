// Unit bench for rtl/cpu/pa_alu.sv: replays port-level vectors made by
// tests/cpu/unit_vectors.py from the CPU test suites' QEMU reference logs.
//   make tb_alu
#include "Vpa_alu.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* path = argc > 1 ? argv[1] : "obj_dir_tb/alu_vectors.txt";
	FILE* f = fopen(path, "r");
	if (!f) { perror(path); return 2; }
	Vpa_alu* m = new Vpa_alu;
	char line[512];
	long n = 0, bad = 0;
	std::map<std::string, std::pair<long, long>> per;   // group -> (n, bad)
	while (fgets(line, sizeof line, f)) {
		unsigned a, b, cbin, ash, lo, lop, inv, cin, dc, cls, cc, cf, cbwe, chk, er, ec, ecb;
		char name[128] = "";
		if (sscanf(line, "%x %x %x %x %x %x %x %x %x %x %x %x %x %x | %x %x %x # %127s",
		           &a, &b, &cbin, &ash, &lo, &lop, &inv, &cin, &dc, &cls, &cc, &cf, &cbwe, &chk,
		           &er, &ec, &ecb, name) < 17) continue;
		m->a = a; m->b = b; m->cb_in = cbin; m->a_shift = ash; m->logic_op = lo; m->lop = lop;
		m->inv_b = inv; m->cin_sel = cin; m->dcor = dc; m->cond_class = cls;
		m->cond_c = cc; m->cond_f = cf;
		m->eval();
		unsigned cb = cbwe ? m->cb_out : cbin;
		bool ok = (!(chk & 1) || m->result == er) && (!(chk & 2) || m->cond_sat == ec) &&
		          (!(chk & 4) || cb == ecb);
		n++;
		per[name].first++;
		if (!ok) {
			bad++;
			if (per[name].second++ < 3)
				printf("FAIL %-14s a=%08x b=%08x cb_in=%02x  result %08x/%08x cond %u/%u cb %02x/%02x\n",
				       name, a, b, cbin, m->result, er, m->cond_sat, ec, cb, ecb);
		}
	}
	long gbad = 0;
	for (auto& p : per) if (p.second.second) gbad++;
	printf("tb_alu: %ld vectors, %ld mismatches, %ld of %zu groups failing\n",
	       n, bad, gbad, per.size());
	delete m;
	return bad ? 1 : 0;
}
