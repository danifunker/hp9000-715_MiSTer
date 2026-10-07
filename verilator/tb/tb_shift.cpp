// Unit bench for rtl/cpu/pa_shift.sv (vectors from tests/cpu/unit_vectors.py).
//   make tb_shift
#include "Vpa_shift.h"
#include "verilated.h"
#include <cstdio>
#include <map>
#include <string>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* path = argc > 1 ? argv[1] : "obj_dir_tb/shift_vectors.txt";
	FILE* f = fopen(path, "r");
	if (!f) { perror(path); return 2; }
	Vpa_shift* m = new Vpa_shift;
	char line[512];
	long n = 0, bad = 0;
	std::map<std::string, std::pair<long, long>> per;
	while (fgets(line, sizeof line, f)) {
		unsigned r1, r2, told, imm, op, sign, zf, ui, amt, len, cc, chk, er, ec;
		char name[128] = "";
		if (sscanf(line, "%x %x %x %x %x %x %x %x %x %x %x %x | %x %x # %127s",
		           &r1, &r2, &told, &imm, &op, &sign, &zf, &ui, &amt, &len, &cc, &chk, &er, &ec, name) < 14)
			continue;
		m->r1 = r1; m->r2 = r2; m->t_old = told; m->imm5 = imm; m->op = op; m->sign = sign;
		m->zero_fill = zf; m->use_imm = ui; m->amount = amt; m->len = len; m->cond_c = cc;
		m->eval();
		bool ok = (!(chk & 1) || m->result == er) && (!(chk & 2) || m->cond_sat == ec);
		n++;
		per[name].first++;
		if (!ok) {
			bad++;
			if (per[name].second++ < 3)
				printf("FAIL %-12s r1=%08x r2=%08x t=%08x imm=%02x amt=%u len=%u  result %08x/%08x cond %u/%u\n",
				       name, r1, r2, told, imm, amt, len, m->result, er, m->cond_sat, ec);
		}
	}
	long gbad = 0;
	for (auto& p : per) if (p.second.second) gbad++;
	printf("tb_shift: %ld vectors, %ld mismatches, %ld of %zu groups failing\n",
	       n, bad, gbad, per.size());
	delete m;
	return bad ? 1 : 0;
}
