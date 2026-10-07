// Unit bench for rtl/cpu/pa_max1.sv: vectors from the max1 suite, expected
// values from tests/cpu/model.py (QEMU traps MAX-1 on PA 1.1).
//   make tb_max1
#include "Vpa_max1.h"
#include "verilated.h"
#include <cstdio>
#include <map>
#include <string>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* path = argc > 1 ? argv[1] : "obj_dir_tb/max1_vectors.txt";
	FILE* f = fopen(path, "r");
	if (!f) { perror(path); return 2; }
	Vpa_max1* m = new Vpa_max1;
	char line[256];
	long n = 0, bad = 0;
	std::map<std::string, long> fails;
	while (fgets(line, sizeof line, f)) {
		unsigned a, b, op, sat, sa, er;
		char name[64] = "";
		if (sscanf(line, "%x %x %x %x %x | %x # %63s", &a, &b, &op, &sat, &sa, &er, name) < 6)
			continue;
		m->a = a; m->b = b; m->op = op; m->sat = sat; m->sa = sa;
		m->eval();
		n++;
		if (m->result != er) {
			bad++;
			if (fails[name]++ < 3)
				printf("FAIL %-10s a=%08x b=%08x  result %08x/%08x\n", name, a, b, m->result, er);
		}
	}
	printf("tb_max1: %ld vectors, %ld mismatches, %zu groups failing\n", n, bad, fails.size());
	delete m;
	return bad ? 1 : 0;
}
