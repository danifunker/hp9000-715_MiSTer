// tb_ps2dev -- rtl/lasi/ps2_dev.sv: a host command's answer comes before
// key bytes still queued (they are dropped, as a real keyboard drops its
// output buffer), the identification, the scan-code set change, keys after.
//   make -C verilator tb_ps2dev
#include "Vps2_dev.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vps2_dev* t;
static int fails = 0;
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
static void key(int code, bool pressed, bool ext = false) {
	unsigned tog = (t->ps2_key >> 10 & 1) ^ 1;
	t->ps2_key = tog << 10 | (pressed ? 1 : 0) << 9 | (ext ? 1 : 0) << 8 | (code & 0xFF);
	for (int i = 0; i < 4; i++) tick();
}
static void cmd(int b) { t->tx_valid = 1; t->tx_byte = b; tick(); t->tx_valid = 0; tick(); }
static std::vector<int> read_all(int n_max, int clocks = 2000000) {
	std::vector<int> v;
	for (int i = 0; i < clocks && (int)v.size() < n_max; i++) {
		t->rx_ready = 1;
		if (t->rx_valid) v.push_back(t->rx_byte);
		tick();
	}
	t->rx_ready = 0;
	return v;
}
static void expect(const char* what, const std::vector<int>& got, const std::vector<int>& want) {
	bool ok = got == want;
	printf("%s %s:", ok ? "ok  " : "FAIL", what);
	for (int b : got) printf(" %02X", b);
	if (!ok) { printf("  (expected"); for (int b : want) printf(" %02X", b); printf(")"); fails++; }
	printf("\n");
}
int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vps2_dev;
	t->rst = 1; t->tx_valid = 0; t->rx_ready = 0; t->ps2_key = 0; t->ps2_mouse = 0;
	for (int i = 0; i < 4; i++) tick();
	t->rst = 0; tick();
	// keys queue while the host does not read
	key(0x1C, true); key(0x1C, false); key(0x32, true);
	cmd(0xF2);                                   // identify, with key bytes still queued
	expect("F2 answered first, queued keys dropped", read_all(5), {0xFA, 0xAB, 0x83});
	// the X server's sequence: keys arriving while it sets LEDs and scan-code set 3
	key(0x23, true);
	cmd(0xED); key(0x2B, true);
	expect("ED acknowledged before the key typed after it was queued...", read_all(1), {0xFA});
	cmd(0x07);
	expect("...and its parameter acknowledged, the key dropped", read_all(4, 300000), {0xFA});
	cmd(0xF0); cmd(0x03);
	expect("F0 03 (scan-code set 3)", read_all(4, 300000), {0xFA});
	key(0x1C, true); key(0x1C, false);
	expect("A in set 3", read_all(4), {0x1C, 0xF0, 0x1C});
	cmd(0xFF);
	expect("reset: FA, AA after the self-test", read_all(3, 3000000), {0xFA, 0xAA});
	printf("%s\n", fails ? "FAILED" : "PASS");
	delete t;
	return fails ? 1 : 0;
}
