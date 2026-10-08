// Unit bench for rtl/cpu/pa_fpu.sv: replays the fp suite's vectors (from
// tests/cpu/unit_vectors.py: QEMU's results as expectation, or model.py's
// for the fp and fpedge suites with `fpmodel`) through the engine alone, one
// multi-cycle operation at a time.   make tb_fpu
// An operation the engine declares unimplemented (the PCX-L delayed trap,
// handled by software on the real machine) is counted, not failed, unless
// the vector's check mask bit 4 says the expectation covers it.
#include "Vpa_fpu.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

static void tick(Vpa_fpu* m) { m->clk = 0; m->eval(); m->clk = 1; m->eval(); }

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* path = argc > 1 ? argv[1] : "obj_dir_tb/fp_vectors.txt";
	FILE* f = fopen(path, "r");
	if (!f) { perror(path); return 2; }
	Vpa_fpu* m = new Vpa_fpu;
	m->rst_n = 0; m->start = 0; tick(m); tick(m); m->rst_n = 1; tick(m);
	char line[512];
	long n = 0, bad = 0, unimpl = 0, unimpl_ok = 0, maxcyc = 0;
	std::map<std::string, std::pair<long, long>> per;
	std::map<std::string, long> unimp;
	std::map<std::string, long> latency;        // per mnemonic+format: the longest start -> done
	bool verbose = argc > 2 && std::string(argv[2]) == "-v";
	while (fgets(line, sizeof line, f)) {
		unsigned op, sgl, dsgl, rm, cond, ahi, alo, bhi, blo, chk, ehi, elo, efl, ec, eun = 0;
		char name[128] = "";
		int nf = sscanf(line, "%x %u %u %u %x %x %x %x %x %x | %x %x %x %u %u # %127s",
		                &op, &sgl, &dsgl, &rm, &cond, &ahi, &alo, &bhi, &blo, &chk, &ehi, &elo, &efl, &ec, &eun, name);
		if (nf < 14) continue;
		if (nf == 14) sscanf(line, "%*x %*u %*u %*u %*x %*x %*x %*x %*x %*x | %*x %*x %*x %*u # %127s", name);
		m->op = op; m->sgl = sgl; m->dsgl = dsgl; m->rm = rm; m->cond = cond;
		m->a = ((unsigned long long)ahi << 32) | alo; m->b = ((unsigned long long)bhi << 32) | blo;
		m->dmode = 0; m->enables = 0;
		m->start = 1; tick(m); m->start = 0;
		long cyc = 1;
		while (!m->done && cyc < 400) { tick(m); cyc++; }
		if (cyc > maxcyc) maxcyc = cyc;
		n++; per[name].first++;
		{
			std::string key(name);
			size_t dot = key.find('.');
			if (dot != std::string::npos) key = key.substr(0, dot);
			if (key.rfind("fcmp", 0) == 0) key = key.substr(0, key.find(',', 5));
			if (!m->unimpl && cyc > latency[key]) latency[key] = cyc;
		}
		if (!m->done) {
			bad++; if (per[name].second++ < 3) printf("FAIL %-22s no done after %ld cycles\n", name, cyc);
			m->rst_n = 0; tick(m); m->rst_n = 1; tick(m);
			continue;
		}
		if ((chk & 16) && (m->unimpl != 0) != (eun != 0)) {
			bad++;
			if (per[name].second++ < 3)
				printf("FAIL %-22s a=%08x%08x b=%08x%08x rm=%u  unimplemented %u, expected %u (%ld cyc)\n",
				       name, ahi, alo, bhi, blo, rm, m->unimpl, eun, cyc);
			tick(m); continue;
		}
		if (m->unimpl && (chk & 16)) { unimpl_ok++; tick(m); continue; }
		if (m->unimpl) { unimpl++; unimp[name]++; tick(m); continue; }
		unsigned long long r = m->result, e = ((unsigned long long)ehi << 32) | elo;
		bool ok = true;
		if (chk & 1) ok &= (r == e) && m->result_we;
		if (chk & 2) ok &= ((r >> 32) == ehi) && m->result_we;
		if (chk & 4) ok &= (m->flags == efl);
		if (chk & 8) ok &= (m->cmp_c == ec);
		if (!ok) {
			bad++;
			if (per[name].second++ < 3)
				printf("FAIL %-22s a=%08x%08x b=%08x%08x rm=%u  result %016llx/%016llx we=%u flags %02x/%02x c %u/%u (%ld cyc)\n",
				       name, ahi, alo, bhi, blo, rm, r, e, m->result_we, m->flags, efl, m->cmp_c, ec, cyc);
		}
		tick(m);
	}
	if (unimpl && !(unimp.size() > 40))
		for (auto& u : unimp) printf("unimplemented %-22s %ld of %ld\n", u.first.c_str(), u.second, per[u.first].first);
	if (verbose)
		for (auto& l : latency) printf("latency %-20s %ld cycles (start -> done)\n", l.first.c_str(), l.second);
	long gbad = 0;
	for (auto& p : per) if (p.second.second) gbad++;
	printf("tb_fpu: %ld vectors, %ld mismatches, %ld unimplemented as expected, %ld unimplemented (not checked), %ld of %zu groups failing, longest op %ld cycles\n",
	       n, bad, unimpl_ok, unimpl, gbad, per.size(), maxcyc);
	delete m;
	return bad ? 1 : 0;
}
