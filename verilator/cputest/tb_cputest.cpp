// Runs one pacputest ROM (tests/cpu) on the RTL core and writes its serial
// output, for tests/cpu/compare.py.
//   obj_dir_ct/Vcputest_top +rom=<hex> [--log FILE] [--max-cycles N] [--trace N]
#include "Vcputest_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* logpath = nullptr;
	unsigned long long max_cycles = 400000000ULL, trace = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--log") && i + 1 < argc) logpath = argv[++i];
		else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace = strtoull(argv[++i], 0, 0);
	}
	FILE* log = logpath ? fopen(logpath, "w") : stdout;
	Vcputest_top* top = new Vcputest_top;
	std::string tail;
	unsigned long long cyc = 0, retired = 0, traps = 0, traced = 0, fp_stall = 0;
	top->clk = 0; top->rst_n = 0;
	for (; cyc < max_cycles; cyc++) {
		top->rst_n = cyc > 4;
		top->clk = 1; top->eval();
		if (top->uart_tx_strobe) {
			char ch = (char)top->uart_tx_byte;
			if (ch != '\r') { fputc(ch, log); tail.push_back(ch); }
			if (tail.size() > 64) tail.erase(0, tail.size() - 64);
			if (tail.find("== end") != std::string::npos || tail.find("!! ") != std::string::npos) {
				if (tail.find("!! ") != std::string::npos) {
					// let the line finish
					for (int k = 0; k < 20000; k++) { top->clk = 0; top->eval(); top->clk = 1; top->eval();
						if (top->uart_tx_strobe && top->uart_tx_byte != '\r') fputc(top->uart_tx_byte, log); }
				}
				break;
			}
		}
		if (top->dbg_fp_stall) fp_stall++;
		if (top->dbg_retire) {
			retired++;
			if (traced < trace) {
				fprintf(stderr, "%10llu %08x %08x%s\n", cyc, top->dbg_iaoq_f, top->dbg_insn,
				        top->dbg_nullified ? " (nullified)" : "");
				traced++;
			}
		}
		if (top->dbg_trap) {
			traps++;
			if (traced < trace) fprintf(stderr, "%10llu TRAP %u\n", cyc, top->dbg_trap_vec);
		}
		top->clk = 0; top->eval();
	}
	fflush(log);
	fprintf(stderr, "cputest: %llu cycles, %llu instructions retired, %llu interruptions, %llu FP stall cycles%s\n",
	        cyc, retired, traps, fp_stall, cyc >= max_cycles ? " -- CYCLE LIMIT" : "");
	if (logpath) fclose(log);
	delete top;
	return cyc >= max_cycles ? 1 : 0;
}
