#include "Vtb_term.h"
#include "verilated.h"
int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	Vtb_term* t = new Vtb_term;
	for (long i = 0; i < 20000000 && !Verilated::gotFinish(); i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
	t->final(); delete t; return 0;
}
