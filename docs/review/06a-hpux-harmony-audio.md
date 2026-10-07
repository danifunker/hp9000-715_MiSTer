# HP-UX 10.20: what the Harmony (LASI audio, SVERSION 0x7B) driver needs

From a disassembly of the HP-UX 10.20 kernel extracted from the QEMU disk
image (addresses are kernel virtual addresses in that `vmunix`; `Lasi_ers.txt`
and `CS4215.txt` are in `docs/reference/txt/`). Part of the OS track
(`06-os-hpux-linux.md`).

## 0. Does this kernel use it? No.

- `audio_link` (0x4fb98) has no callers; its only reference is the audio
  `drv_ops` (DS$ 0x416930, open/close/read/write/ioctl/select at +0x48..0x6c).
  Nothing passes 0x416930 to `wsio_install_driver`; `driver_install`
  (0x3e26b8..0x3e2780) has no audio entry and `roms/hpux/system` does not list
  `audio`. `audio_pci_attach` is unreferenced; `audio2_probe` is called only
  from the unreachable `audio_open`.
- `audio2_probe` only acts on "9000/720", "/730", "/750": `pdc_call(12, 0,
  0xF1000000)`, `iovalidate(0xF1000000,0,0x10)`, `audio_attach(0x7f, 0)`.
- Every reachable beep path (`ite_beep` -> `kbd_beep` 0x18da78,
  `audio_beeper` 0x18d950, `beep_ioctl` 0x1df528, `dobeep_ioctl_cmd`
  0x1df628, the three `r8042_ioctl` calls) checks `audio_devices` (0x444068),
  which only `audio_attach` sets; otherwise they fall back to HIL, absent on a
  PS/2 715. **This kernel never touches 0xF0104000.** The rest describes a
  kernel built with `audio` in its system file.

## 1. Matching and attach

`audio_link` saves `core_attach` and installs `audio_attach(id, isc)`
(0x176ff0), which accepts ids 0x7a, 0x7e, 0x7f, 0x7b, 0xc0 and chains the
rest. Softc 500 bytes, type at sc+8:

| SVERSION | type | variant |
|---|---|---|
| 0x7A, 0x7E | 0 "audio1" | older byte-register audio |
| **0x7B**, 0x7F | **1 "audio2" (Harmony)** | 0x7F = SGC card; isc=0 defaults HPA to 0xF1000000 |
| 0xC0 | 2 "audio3" | PCI |

- HPA from isc+0xc0. Ids 0x7e/0x7b/0xc0 set cc |= 0x00100000 ("system beeper").
- **Presence** is judged only by RESET reading back, CNTL.C clearing and DIAG
  non-zero (never ID or CNTL Rev). Failure -> "audio_attach(): audio
  configuration failed", chain to the saved attach; no hang, no panic.
- Success: `audio2_get_irq` (0x18d3f0, table 0x413cf0): 720/730 -> 20,
  750/755 -> 19, others -> **18 = LASI bit 13 (mask 0x2000)**;
  `isrlink(isc, audio2_isr, 18, ...)`; isc+0xd0 = `audio_init`; `isc_claim`.

## 2. Registers (offsets from HPA, 32-bit accesses)

| Off | Reg | Use | Bits |
|---|---|---|---|
| 0x00 | ID | diagnostic only (`audio_test_rw_register` 0x2443f0) | -- |
| 0x04 | RESET | R in attach (==1), W 0; pulse W1/W0 in set_config | bit 0; others read 0 |
| 0x08 | CNTL | W (never with C); R polls bit 31 | 7:6 DF, 5 ST, 4:0 rate; C bit 31 |
| 0x0C | GAINCTL | W everywhere gains/outputs/inputs change | see 6 |
| 0x10 | PNXTADD | W only in ISR | 4 KB-aligned physical |
| 0x14 | PCURADD | R for metering ioctl only | -- |
| 0x18 | RNXTADD | W only in ISR | -- |
| 0x1C | RCURADD | R for metering only | -- |
| 0x20 | DSTATUS | R/W in ISR, dma_stop, write, rcv_on, beeper, ioctl | IE 0x80000000, PN 0x200, PC 0x100, RN 0x002, RC 0x001; "busy" = &0x101 |
| 0x24 | OV | W 0; R then W 0 | bit 0 |
| 0x28 | PIO | raw set/get ioctl only; never initialised | -- |
| 0x3C | DIAG | R in set_config, tested != 0 | -- |

Matches the LASI ERS (`Lasi_ers.txt` 2094-2100 RESET, 2117-2122 C set by any
write, 2181-2189 rates, 2283-2305 NXTADD low 12 bits zero, 2319-2343
DSTATUS, 2415-2442 GAINCTL, 2457-2465 OV, 2482-2495 PIO, 2504-2509 DIAG).

## 3. Init sequence

**Attach (0x177374):** allocate buffers; R RESET, if 1 wait 100 ms then W 0;
W GAINCTL = **0x0FF00186** (HE/LE/SE on, IS=mic, MA=F, LI=RI=0, LO=RO=6);
`audio2_set_config(sc, 0x48, strict=1)`; no DSTATUS write (IE stays 0).

**`audio2_set_config(sc, cntl, strict)` (0x1623e8):** return if the CNTL
shadow already matches; W GAINCTL = shadow & ~0x0E000000, wait 500 us; W
CNTL, poll C every 100 us x20. If C clears: wait 1 ms, poll DIAG != 0 every
10 us x100 (3 tries, then strict returns 1 / lenient prints "Audio hardware
clock appears dead"); on success store shadow, wait 1 ms, restore GAINCTL,
W OV = 0. If C stays set ~2 ms: RESET pulse (100 ms), retry; up to 20 resets
("Audio hardware failed. Not recoverable with reset"). All loops bounded;
worst strict case ~105 ms.

**Open (0x173bb4):** `audio_dma_stop`, W GAINCTL = 0x0FF00186,
set_config(0x48, lenient).

## 4. Interrupt (`audio2_isr` 0x180a58)

R DSTATUS; R again and W value & 0x7FFFFFFF (IE off, writing back read-only
bits -- hardware must ignore them). Test mode (cc & 0x40000): wake, return.
If PN: fill/flush a page, W PNXTADD once. If RN: W RNXTADD once. Keep-alive:
if data pending, cc & 0x13100, or silence counter sc+0xbc non-zero, set IE
again. **The ISR acks nothing else**: the interrupt clears only through IE=0
and the NXTADD writes (ERS 2320-2322, 2350-2367).

IE is set by `audio_write` (0x2406cc), `audio_rcv_on` (0x2427e4),
`audio2_beeper` (0x18d830) and ioctl (0x170f58). `audio_dma_stop`
(0x173d80) waits for DSTATUS & 0x101 == 0 (sleep 10 ticks x30 = 3 s, else
"Could not stop audio dma!"), then clears IE. Format/rate/config ioctls
return EBUSY while & 0x101.

## 5. DMA

- 4 KB pages, 8 KB (2-page) buffers; `audio_alloc_n_map` (0x176dd0) maps each
  page via `pa_map` -> `ltor` (physical address), stored as {addr,len} arrays.
- Buffers: "silence" 8 KB (playback idle stream and beeps, pages alternate),
  "graveyard" 8 KB (RNXTADD target when not recording -- hardware writes
  record data there), beep 8 KB, a 130-byte wave table (0x7B only).
- PNXTADD = `array[(cursor-base)>>12].addr` + in-page offset for user data.
- **Non-coherent:** `io_flushcache` (fdc + sync) before playback DMA,
  `io_purgecache` (pdc) for record data.

## 6. Formats, rates, gains

Rate code = XS:DFR as the CS4215 Data Format register (`CS4215.txt` 995-1017):

| Hz | 8000 | 11025 | 16000 | 22050 | 32000 | 44100 | 48000 |
|---|---|---|---|---|---|---|---|
| code | 0x08 | 0x11 | 0x09 | 0x13 | 0x0B | 0x15 | 0x0E |

| HP-UX format | DF | meaning | silence byte |
|---|---|---|---|
| 0 | 01 | u-law | 0x55 |
| 1 | 10 | A-law | 0xFF |
| 2, 3 | 00 | 16-bit BE two's complement | 0 |
| 4 | **11** | 8-bit unsigned (ERS says reserved; CS4215 defines it) | 0x80 |

ST = 0x20. GAINCTL = `(shadow & 0xFF000000) | MA<<20 | LI<<16 | RI<<12 |
LO<<6 | RO`; LI = (2g+1)/3 (g 0..22 dB), LO = (2(9-g)+1)/3 (0x3F off),
MA = (3-m)/6 (0xF off). Outputs: SE 0x02000000 speaker, HE 0x08000000
headphone, LE 0x04000000 line. Input: IS=1 mic, else line.

## 7. Beeper (only with audio attached)

`audio2_beeper` (0x18d5d0): GAINCTL = 0x02F00000 | att<<6 | att (speaker
only); save CNTL/gain; set_config(0x0B = 32 kHz 16-bit mono); sine into the
beep buffer (40-15000 Hz, ms x 64 bytes); IE on. Default bell ~731 Hz,
80 ms. `beep_fill` (0x1807f8) feeds pages through PNXTADD. `beeper_restore`
(0x18b778) waits for DSTATUS & 0x101 == 0 (prints "beeper_restore: dma
still occurring" every 1 s), then restores CNTL and gain.

## 8. Timing

`busywait` (0x131168) spins on CR16. C must clear within ~2 ms; DIAG
non-zero within ~1 ms; DMA stop 3 s; no hang or panic on misbehaving
hardware (Linux, in contrast, spins forever on C: `harmony.c:109`).

## 9. FPGA requirements

- **For this kernel:** none -- but decode 0xF0104000-0xF0104FFF without a
  bus error for firmware and other kernels.
- **For an audio-enabled kernel, MUST:** RESET powers up 1 and reads back
  (unused bits 0); any CNTL write sets C, which clears within ~1-2 ms; DIAG
  reads non-zero (constant or toggling SCLK); GAINCTL/OV/PIO stored; DSTATUS
  IE read/write, PN/PC/RN/RC read-only, reset PN=RN=1, PC=RC=0; a PNXTADD
  write clears PN, an RNXTADD write clears RN; IRQ = IE & (PN|RN), dropped
  at once when IE=0 (else an interrupt storm); playback DMA from physical
  4 KB pages (big-endian word packing, ERS 2384-2409) paced by the sample
  rate; record DMA writes (zeros acceptable) or at least consumes RNXTADD;
  PC/RC clear once IE=0 and both pages are used, or every open waits 3 s.
- **MAY:** ignore ID / CNTL Rev (or return 0x00140000), approximate
  PCURADD/RCURADD, record zeros, no OV source.
- **Minimal stub:** RESET reads back, C self-clears, DIAG=1, IE stored, IRQ
  never asserted, PC/RC read 0 -> attach succeeds, beeps silent, no hangs.

Helper scripts used: session scratchpad `drivers/audio/` (fn.sh, callers.py,
findref2.py, extracted *.s).
