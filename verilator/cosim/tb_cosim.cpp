// Lockstep co-simulation driver: runs a pacputest ROM on the sequential core
// (A, the reference) and the pipelined core (B) and compares every retired
// instruction and interruption -- IAOQ front, word, nullification, trap
// vector, the PSW and all 32 GRs after it -- in program order. The cores
// run at their own pace; the streams are queued and matched event by event.
//   Vcosim_top +rom=<hex> [--max-cycles N] [--log FILE] [--quiet]
#include "Vcosim_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

struct Ev {
	unsigned long long cyc;
	bool trap, nul;
	uint32_t iaoq, insn, psw, vec;
	uint32_t gr[32];
};

static bool same(const Ev& a, const Ev& b, std::string& why) {
	char buf[200];
	if (a.trap != b.trap) { why = "event kind (trap vs retire)"; return false; }
	if (a.trap) {
		if (a.vec != b.vec) { snprintf(buf, sizeof buf, "trap vector %u vs %u", a.vec, b.vec); why = buf; return false; }
	}
	if (a.iaoq != b.iaoq) { snprintf(buf, sizeof buf, "IAOQ %08x vs %08x", a.iaoq, b.iaoq); why = buf; return false; }
	if (a.insn != b.insn) { snprintf(buf, sizeof buf, "insn %08x vs %08x", a.insn, b.insn); why = buf; return false; }
	if (a.nul != b.nul) { why = "nullified flag"; return false; }
	if (a.psw != b.psw) { snprintf(buf, sizeof buf, "PSW %08x vs %08x", a.psw, b.psw); why = buf; return false; }
	for (int i = 0; i < 32; i++)
		if (a.gr[i] != b.gr[i]) { snprintf(buf, sizeof buf, "GR%d %08x vs %08x", i, a.gr[i], b.gr[i]); why = buf; return false; }
	return true;
}

static void print_ev(const char* tag, const Ev& e) {
	fprintf(stderr, "  %s %10llu %s %08x %08x%s psw=%08x", tag, e.cyc, e.trap ? "TRAP" : "    ", e.iaoq, e.insn,
	        e.nul ? " (nul)" : "", e.psw);
	if (e.trap) fprintf(stderr, " vec=%u", e.vec);
	fprintf(stderr, "\n");
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	unsigned long long max_cycles = 400000000ULL;
	const char* logpath = nullptr;
	bool quiet = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
		else if (!strcmp(argv[i], "--quiet")) quiet = true;
	}
	FILE* log = logpath ? fopen(logpath, "w") : nullptr;
	Vcosim_top* top = new Vcosim_top;
	std::deque<Ev> qa, qb;
	std::vector<Ev> hist;             // last matched events
	std::string ua, ub, tail;
	unsigned long long cyc = 0, matched = 0;
	bool a_done = false, b_done = false, mismatch = false;
	top->clk_a = 0; top->clk_b = 0; top->rst_n = 0;
	unsigned long long cyc_a = 0, cyc_b = 0, last_a = 0, last_b = 0;
	const size_t LEAD = 2000;          // events one core may be ahead before it is paused
	for (; cyc < max_cycles && !mismatch; cyc++) {
		top->rst_n = cyc > 4;
		bool run_a = qa.size() < LEAD || cyc <= 4;
		bool run_b = qb.size() < LEAD || cyc <= 4;
		if (run_a) { top->clk_a = 1; cyc_a++; }
		if (run_b) { top->clk_b = 1; cyc_b++; }
		top->eval();
		if (run_a) {
			if (top->a_uart_strobe) { char c = top->a_uart_byte; if (c != '\r') { ua.push_back(c); if (log) fputc(c, log); } }
			if (top->a_retire || top->a_trap) {
				Ev e; e.cyc = cyc_a; e.trap = top->a_trap; e.nul = top->a_nul; e.iaoq = top->a_iaoq_f; e.insn = top->a_insn;
				e.psw = top->a_psw; e.vec = top->a_vec; for (int i = 0; i < 32; i++) e.gr[i] = top->a_gr[i];
				qa.push_back(e); last_a = cyc_a;
			}
		}
		if (run_b) {
			if (top->b_uart_strobe) { char c = top->b_uart_byte; if (c != '\r') ub.push_back(c); }
			if (top->b_retire || top->b_trap) {
				Ev e; e.cyc = cyc_b; e.trap = top->b_trap; e.nul = top->b_nul; e.iaoq = top->b_iaoq_f; e.insn = top->b_insn;
				e.psw = top->b_psw; e.vec = top->b_vec; for (int i = 0; i < 32; i++) e.gr[i] = top->b_gr[i];
				qb.push_back(e); last_b = cyc_b;
			}
		}
		while (!qa.empty() && !qb.empty()) {
			std::string why;
			if (!same(qa.front(), qb.front(), why)) {
				fprintf(stderr, "cosim: MISMATCH after %llu matched events: %s\n", matched, why.c_str());
				fprintf(stderr, " recent matched events (seq core cycle):\n");
				for (auto& h : hist) print_ev("  ", h);
				fprintf(stderr, " diverging event:\n");
				print_ev("A", qa.front()); print_ev("B", qb.front());
				fprintf(stderr, " GRs (A vs B) that differ:\n");
				for (int i = 0; i < 32; i++)
					if (qa.front().gr[i] != qb.front().gr[i])
						fprintf(stderr, "   r%-2d %08x %08x\n", i, qa.front().gr[i], qb.front().gr[i]);
				mismatch = true;
				break;
			}
			hist.push_back(qa.front());
			if (hist.size() > 12) hist.erase(hist.begin());
			qa.pop_front(); qb.pop_front(); matched++;
		}
		// a core that has retired nothing for a long time while the other waits on it is stuck
		if (!a_done && qa.empty() && !qb.empty() && cyc_a - last_a > 2000000) {
			fprintf(stderr, "cosim: the sequential core retired nothing for 2M cycles (pipelined core %zu events ahead) after %llu matched events\n", qb.size(), matched);
			for (auto& h : hist) print_ev("  ", h);
			mismatch = true;
		}
		if (!b_done && qb.empty() && !qa.empty() && cyc_b - last_b > 2000000) {
			fprintf(stderr, "cosim: the pipelined core retired nothing for 2M cycles (sequential core %zu events ahead) after %llu matched events\n", qa.size(), matched);
			for (auto& h : hist) print_ev("  ", h);
			mismatch = true;
		}
		if (!a_done && (ua.find("== end") != std::string::npos || ua.find("!! ") != std::string::npos)) a_done = true;
		if (!b_done && (ub.find("== end") != std::string::npos || ub.find("!! ") != std::string::npos)) b_done = true;
		if (a_done && b_done && qa.empty() && qb.empty()) break;
		top->clk_a = 0; top->clk_b = 0; top->eval();
	}
	if (ua != ub && !mismatch) {
		fprintf(stderr, "cosim: UART output differs (A %zu bytes, B %zu bytes)\n", ua.size(), ub.size());
		mismatch = true;
	}
	if (!quiet || mismatch)
		fprintf(stderr, "cosim: %llu / %llu cycles (seq / pipe), %llu events matched%s%s\n", cyc_a, cyc_b, matched,
		        mismatch ? " -- MISMATCH" : " -- identical", cyc >= max_cycles ? " (cycle limit)" : "");
	if (log) fclose(log);
	delete top;
	return mismatch ? 1 : 0;
}
