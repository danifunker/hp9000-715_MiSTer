// tb_cdaudio -- rtl/scsi/scsi_targets.sv's CD-ROM with rtl/scsi/cd_audio.sv:
// an initiator on the byte-level bus and an hps_io-style block device that
// serves a synthetic disc the way Main_MiSTer does (support/hp9k): data
// blocks, the track table at 0xC0000000 and frame f at 0x80000000 + 5f.
// Disc: track 1 data at LBA 0, track 2 audio at 1000, track 3 audio at
// 1300, lead-out at 1500; sample k of frame f is L = f * 1000 + k, R = -L.
//   make -C verilator tb_cdaudio
#include "Vscsi_targets.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <cstdlib>

static Vscsi_targets* t;
static uint64_t cyc = 0;
static int fails = 0;

// ------------------------------------------------------------ the disc
static const uint32_t T2 = 1000, T3 = 1300, LEAD = 1500;
static uint8_t disc_byte(uint64_t blk, int i) {
	if (blk >= 0xC0000000ULL) {                          // the track table
		if (blk != 0xC0000000ULL) return 0;
		static uint8_t toc[1024]; static bool made = false;
		if (!made) {
			made = true;
			struct { int ctl, trk; uint32_t lba; } e[4] = {{0x14, 1, 0}, {0x10, 2, T2}, {0x10, 3, T3}, {0x10, 0xAA, LEAD}};
			toc[0] = 1; toc[1] = 3; toc[2] = 4; toc[3] = 1;
			for (int n = 0; n < 4; n++) {
				uint8_t* p = toc + 8 + 8 * n; uint32_t a = e[n].lba + 150;
				p[0] = e[n].ctl; p[1] = e[n].trk; p[2] = a / 4500; p[3] = a / 75 % 60; p[4] = a % 75;
				p[5] = e[n].lba >> 16; p[6] = e[n].lba >> 8; p[7] = e[n].lba;
			}
		}
		return i < 1024 ? toc[i] : 0;
	}
	if (blk >= 0x80000000ULL) {                          // the audio window
		uint64_t off = (blk - 0x80000000ULL) * 512 + i;
		uint32_t f = off / 2560, fo = off % 2560;
		if (fo >= 2352) return 0;
		uint32_t k = fo / 4; int16_t l = (int16_t)(f * 1000 + k), r = -l;
		int16_t v = (fo & 2) ? r : l;
		return (fo & 1) ? (uint16_t)v >> 8 : (uint16_t)v & 0xFF;
	}
	return (uint8_t)(blk * 7 + i * 3);                   // data
}

// ------------------------------------------------------------ the block device (slot 2)
static int bd_st = 0, bd_wait = 0, bd_w = 0, bd_n = 0;
static uint64_t bd_lba;
static void bd_step() {
	t->sd_buff_wr = 0;
	if (bd_st == 0) {
		if (t->sd_rd & 4) { bd_st = 1; bd_wait = 20 + (cyc % 13); bd_lba = t->sd_lba[2]; bd_n = (t->sd_blk_cnt[2] + 1) * 256; bd_w = 0; }
	} else if (bd_st == 1) {
		if (--bd_wait <= 0) { t->sd_ack = 4; bd_st = 2; }
	} else if (bd_st == 2) {
		if (bd_w < bd_n) {
			uint64_t blk = bd_lba + bd_w / 256; int b = (bd_w % 256) * 2;
			t->sd_buff_addr = bd_w; t->sd_buff_dout = disc_byte(blk, b) | disc_byte(blk, b + 1) << 8;
			t->sd_buff_wr = 1; bd_w++;
		} else { t->sd_ack = 0; bd_st = 0; }
	}
}

static std::vector<int16_t> outs;
static int16_t last_out = 0x7FFF;
static bool capture = false;
static void tick() {
	bd_step();
	t->clk = 1; t->eval(); t->clk = 0; t->eval();
	cyc++;
	if (capture && (int16_t)t->cd_l != last_out) { outs.push_back((int16_t)t->cd_l); }
	last_out = (int16_t)t->cd_l;
}

// ------------------------------------------------------------ the initiator
static bool wait_req(int max = 2000000) { for (int i = 0; i < max; i++) { if (t->req) return true; tick(); } return false; }
static void ack_byte(uint8_t out = 0) { t->idata = out; t->ack = 1; tick(); t->ack = 0; tick(); }
// one command: returns the status, data in din (data out from dout)
static int command(const std::vector<uint8_t>& cdb, std::vector<uint8_t>* din = nullptr, const std::vector<uint8_t>* dout = nullptr) {
	t->sel = 1; t->sel_id = 2; t->sel_atn = 0; tick(); t->sel = 0;
	int status = -1; size_t ci = 0, oi = 0;
	for (int guard = 0; guard < 100000; guard++) {
		if (!wait_req()) { printf("FAIL: no REQ (phase %d)\n", t->phase); fails++; return -1; }
		switch (t->phase) {
			case 2: ack_byte(ci < cdb.size() ? cdb[ci] : 0); ci++; break;                // COMMAND
			case 1: if (din) din->push_back(t->tdata); ack_byte(); break;                  // DATA IN
			case 0: ack_byte(dout && oi < dout->size() ? (*dout)[oi] : 0); oi++; break;    // DATA OUT
			case 3: status = t->tdata; ack_byte(); break;                                  // STATUS
			case 7: ack_byte(); for (int i = 0; i < 20; i++) tick(); return status;      // MESSAGE IN
			default: ack_byte(); break;
		}
	}
	return status;
}
static void expect(const char* what, long got, long want) {
	if (got != want) { printf("FAIL: %s: %ld, expected %ld\n", what, got, want); fails++; }
	else printf("ok   %s = %ld\n", what, got);
}
static void expect_bytes(const char* what, const std::vector<uint8_t>& got, const std::vector<uint8_t>& want) {
	bool ok = got == want;
	printf("%s %s:", ok ? "ok  " : "FAIL", what);
	for (auto b : got) printf(" %02x", b);
	if (!ok) { printf("\n     expected:"); for (auto b : want) printf(" %02x", b); fails++; }
	printf("\n");
}
static std::vector<uint8_t> subq(bool msf) {
	std::vector<uint8_t> d;
	command({0x42, (uint8_t)(msf ? 2 : 0), 0x40, 1, 0, 0, 0, 0, 16, 0}, &d);
	return d;
}
static void run(long n) { for (long i = 0; i < n; i++) tick(); }

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	t = new Vscsi_targets;
	t->rst = 1; t->sel = 0; t->ack = 0; t->ackhold = 0; t->atn = 0; t->brst = 0; t->cd_change = 0;
	t->img_present = 4; t->img_blocks[0] = 0; t->img_blocks[1] = 0; t->img_blocks[2] = LEAD * 4;
	t->sd_ack = 0;
	for (int i = 0; i < 5; i++) tick();
	t->rst = 0; tick();

	std::vector<uint8_t> d;
	// READ TOC, LBA form, from track 1
	d.clear(); expect("READ TOC status", command({0x43, 0, 0, 0, 0, 0, 0, 0, 100, 0}, &d), 0);
	expect_bytes("READ TOC (LBA)", d, {0x00, 0x22, 1, 3,
		0, 0x14, 1, 0, 0, 0, 0, 0,   0, 0x10, 2, 0, 0, 0, 0x03, 0xE8,
		0, 0x10, 3, 0, 0, 0, 0x05, 0x14,   0, 0x10, 0xAA, 0, 0, 0, 0x05, 0xDC});
	// M:S:F, from track 3: 1300 + 150 = 0:19:25, 1650 = 0:22:00
	d.clear(); command({0x43, 2, 0, 0, 0, 0, 3, 0, 100, 0}, &d);
	expect_bytes("READ TOC (MSF, from track 3)", d, {0x00, 0x12, 1, 3,
		0, 0x10, 3, 0, 0, 0, 19, 25,   0, 0x10, 0xAA, 0, 0, 0, 22, 0});
	// format 1 (session): the first track
	d.clear(); command({0x43, 0, 0, 0, 0, 0, 0, 0, 12, 0x40}, &d);
	expect_bytes("READ TOC (session)", d, {0x00, 0x0A, 1, 1, 0, 0x14, 1, 0, 0, 0, 0, 0});
	d = subq(false); expect("sub-channel before a play: no status", d.size() > 1 ? d[1] : -1, 0x15);

	// PLAY AUDIO MSF from track 2 (0:15:25) for 3 frames
	outs.clear(); capture = true;
	expect("PLAY AUDIO MSF", command({0x47, 0, 0, 0, 15, 25, 0, 15, 28, 0}), 0);
	run(20000);
	d = subq(true);
	expect("playing: status", d[1], 0x11);
	expect("playing: track", d[6], 2);
	expect("playing: absolute M:S:F (0:15:25)", d[9] << 16 | d[10] << 8 | d[11], 15 << 8 | 25);
	run(3 * 588 * 1452);
	capture = false;
	{
		int bad = 0; size_t n = 0;
		for (uint32_t f = T2; f < T2 + 3; f++)
			for (uint32_t k = 0; k < 588; k++, n++) {
				int16_t want = (int16_t)(f * 1000 + k);
				if (n >= outs.size() || outs[n] != want) { if (bad < 4) printf("  sample %zu: %d, expected %d\n", n, n < outs.size() ? outs[n] : 0, want); bad++; }
			}
		expect("3 frames of samples, in order", bad, 0);
	}
	d = subq(false); expect("after the play: completed", d[1], 0x13);
	d = subq(false); expect("... reported once, then no status", d[1], 0x15);

	// pause / resume
	command({0x45, 0, 0, 0, (uint8_t)(T3 >> 8), (uint8_t)T3, 0, 0, 50, 0});
	run(3 * 588 * 1452);
	command({0x4B, 0, 0, 0, 0, 0, 0, 0, 0, 0});
	run(5000);
	d = subq(false); expect("paused", d[1], 0x12);
	expect("paused: silent", (int16_t)t->cd_l, 0);
	uint32_t at = d[13] << 16 | d[14] << 8 | d[15];
	run(200000);
	expect("paused: past the first frames", at >= 2, 1);
	d = subq(false); expect("paused: position held", d[13] << 16 | d[14] << 8 | d[15], at);
	command({0x4B, 0, 0, 0, 0, 0, 0, 0, 1, 0});
	run(5000);
	d = subq(false); expect("resumed", d[1], 0x11);
	expect("track 3", d[6], 3);

	// the volume: MODE SELECT page 0x0E, ports at 0x80 -> half
	{
		std::vector<uint8_t> p = {0, 0, 0, 0,  0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x80, 0x02, 0x80, 0, 0, 0, 0};
		expect("MODE SELECT page 0x0E", command({0x15, 0x10, 0, 0, (uint8_t)p.size(), 0}, nullptr, &p), 0);
		d.clear(); command({0x1A, 0, 0x0E, 0, 0xFF, 0}, &d);
		expect("MODE SENSE page 0x0E: port 0 volume", d.size() > 21 ? d[4 + 8 + 9] : -1, 0x80);
		// two frames of track 2 at that volume: (L * 129) >> 8 (only changes are captured)
		command({0x4E, 0, 0, 0, 0, 0, 0, 0, 0, 0});
		outs.clear(); capture = true;
		command({0x47, 0, 0, 0, 15, 25, 0, 15, 27, 0});
		run(2 * 588 * 1452 + 30000); capture = false;
		std::vector<int16_t> want;
		for (uint32_t f = T2; f < T2 + 2; f++)
			for (uint32_t k = 0; k < 588; k++) {
				int16_t e = (int16_t)(((int)(int16_t)(f * 1000 + k) * 129) >> 8);
				if (want.empty() || want.back() != e) want.push_back(e);
			}
		while (!outs.empty() && outs.back() == 0) outs.pop_back();        // the end of the play
		int bad = 0;
		for (size_t i = 0; i < want.size(); i++) if (i >= outs.size() || outs[i] != want[i]) bad++;
		printf("     %zu changes, %zu expected\n", outs.size(), want.size());
		for (size_t i = 0; i < 3 && i < outs.size(); i++) printf("     first %zu: %d (want %d)\n", i, outs[i], i < want.size() ? want[i] : 0);
		for (size_t i = outs.size() > 3 ? outs.size() - 3 : 0; i < outs.size(); i++) printf("     last %zu: %d (want %d)\n", i, outs[i], i < want.size() ? want[i] : 0);
		expect("half volume: every sample (L * 129) >> 8", bad == 0 && outs.size() == want.size(), 1);
	}
	command({0x4E, 0, 0, 0, 0, 0, 0, 0, 0, 0});
	run(5000);
	expect("STOP: silent", (int16_t)t->cd_l, 0);
	d = subq(false); expect("STOP: no status", d[1], 0x15);

	// PLAY AUDIO TRACK/INDEX: track 3 only
	command({0x48, 0, 0, 0, 3, 1, 0, 3, 1, 0});
	run(20000);
	d = subq(false);
	expect("PLAY TRACK 3: track", d[6], 3);
	expect("PLAY TRACK 3: absolute LBA", d[8] << 24 | d[9] << 16 | d[10] << 8 | d[11], T3);

	// a data read ends the play and returns the data
	d.clear();
	expect("READ(10) LBA 5, 1 block", command({0x28, 0, 0, 0, 0, 5, 0, 0, 1, 0}, &d), 0);
	{
		int bad = 0;
		for (int i = 0; i < 2048 && i < (int)d.size(); i++) if (d[i] != disc_byte(5 * 4 + i / 512, i % 512)) bad++;
		expect("READ data", (long)d.size() == 2048 && !bad, 1);
	}
	run(5000);
	d = subq(false); expect("the read stopped the play", d[1], 0x15);

	// a new disc: the table is read again
	t->cd_change = 1; tick(); t->cd_change = 0;
	d.clear(); command({0x43, 0, 0, 0, 0, 0, 0, 0, 4, 0}, &d);
	expect_bytes("READ TOC after a disc change (header)", d, {0x00, 0x22, 1, 3});

	printf("%s (%llu cycles)\n", fails ? "FAILED" : "PASS", (unsigned long long)cyc);
	delete t;
	return fails ? 1 : 0;
}
