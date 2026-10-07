# HP-UX 10.20: LASI PS/2, RS-232 and parallel drivers -- what the FPGA must provide

From a disassembly of the HP-UX 10.20 kernel (`vmunix` from the QEMU disk
image; addresses are kernel virtual). Part of the OS track
(`06-os-hpux-linux.md`).

All three drivers attach the same way: `X_install` -> `X_link` saves
`core_attach` and installs `X_attach(sversion, isc)`, which claims matching
modules and chains the rest. HPA = `isc+0xC0`. Every hardware access is a
byte access (`ldb`/`stb`). `busywait(n)` = n us polling CR16 (0x131168); a
tick is 10 ms.

## 1. ps2 -- PS/2 keyboard and mouse (SVERSION 0x84)

**Attach/init.** `ps2_attach` (0x1df798) matches 0x84; `ps2_address_to_iface`
(0x1df8b0) keys on `HPA & ~0xFFF` (a second PDC module in the same page, e.g.
the mouse at +0x100, is just claimed); one interface only; `ps2_init`
(0x1df920) from attach. **Port discovery** (0x1df990-0x1df9bc): ID at base+3,
low nibble must be 0; then base + n*0x100 for n = 1..15 while `ID & 0xF ==
n`. The 4 KB block is multiply mapped (`Lasi_ers.txt` 3300-3306), so +0x200
mirrors port 0 and the count stops at 2 -- **never return ID==n at +n*0x100
for n >= 2.** `isrlink(isc, ps2_isr, 5)` (0x1dfb44): HP-UX irq 5 = LASI IMR
bit 26 (ERS 3939).

**Registers** (byte registers at word stride; HP-UX uses byte lane 3, Linux
gscps2 lane 0 -- replicate read data on all lanes, take writes from the
addressed lane):

| Off | R / W | Use |
|---|---|---|
| +3 | R ID / W RESET | read ID, clear low nibble, write back = reset (flush FIFOs, disable) |
| +7 | R RCVDATA / W XMTDATA | |
| +B | CONTROL (W) | only 0x01 ENBL, 0x00, 0x20 (DIAG, CLK=DAT=0: forced inhibit) |
| +F | STATUS (R) | 0x01 RBNE, 0x02 TBNE, 0x0C TERR\|PERR, 0x0D, 0x10 CMPINTR; DATSHD/CLKSHD never read |

**Byte I/O.** `ps2_writebyte_timeout` (0x1e2808): poll TBNE up to 1000 x
500 us ("TBNE active", return 8), write +7, CONTROL=1.
`ps2_readbyte_timeout` (0x1e28d8): poll STATUS & 0x0D, 1000 x 500 us; read
+7; on TERR/PERR drain, and if empty reset, CONTROL=1, send 0xFE;
`ps2_readbyte_retrans` retries 4x. `ps2_sendbyte_with_ack` (0x1e2768):
expects 0xFA, resends on 0xFE (4x), other byte -> 0x0A, timeout -> 8.

**Boot identification** (`ps2_boot_ident` 0x1dfb80, per port): RESET,
CONTROL=1, 20 ms; CONTROL=0, 20 ms; RESET, CONTROL=0x20, 20 ms; send 0xF5 --
timeout with TBNE still 1 (0x1dfc80) => **no device** (RESET, CONTROL=1);
timeout with TBNE=0 or bad ack => type 3 (generic). Send 0xF2: 0x00 => mouse
(type 1, nothing more sent); 0xAB then 0x83/0x86 => keyboard (type 2); else
type 3. Types 2/3 then get 0xF4. A missing device costs ~0.5 s per port and
**never hangs**, provided TBNE stays set when nothing clocks the line.

**Runtime state machine** (`ps2_ctl_state` 0x1e0d60): idle -> CONTROL=0 for
1 tick; RESET + CONTROL=0x20 for 1 tick (`ps2_soft_inhibit_stateaction`
0x1e0efc); TBNE still set => error ("TBNE set after inhibit interval"), else
XMTDATA <- command then CONTROL=1 (0x1e0fd0/0x1e0fdc); ack timeout 400 ticks;
parameter bytes and resends are written while ENBL is already 1 (0x1e10dc,
0x1e1300).

**Commands sent.** Keyboard setup (`ps2_ite_kbd_set` 0x1e0620): `F0 03`
(scancode set 3), `FC <code>` for the 8 modifier keysyms 0xFFE1-0xFFEA,
`ED <leds>` (0x04 Caps), `F4`. `ps2_ite_ratedelay_set`: `F3 23`. Caps light:
`ED 04/00`. Hot-plug: any byte on an empty port -> F5, F2 (0x1e0440). The
kernel never enables the mouse; X does, via ioctl -> `ps2_ctl`.

**ISR** (`ps2_isr` 0x1e1b40): read STATUS on each port (kick state machine);
return unless **port 0's STATUS has CMPINTR** (0x1e1c00); for each port with
RBNE read +7 and re-read STATUS -- if RBNE now 0 and TERR/PERR: RESET,
XMTDATA <- 0xFE while disabled, CONTROL=0x20, 150 us, CONTROL=1
(0x1e1c98-0x1e1cc4); loop while port 0 CMPINTR (0x1e1e8c).

`lasi_function_info`: `core_create_child` (0x83484-0x834a4) matches the
halfword at entry+4 against the last hardware-path element (0xFFFF wildcard),
so 0xB/0xC only pick the description string; irq 5 in all three entries.

**FPGA must:** two ports with ID 0 and 1 and the mirroring above; RESET
flushes and disables; an XMTDATA write while disabled is latched (TBNE=1) and
sent when ENBL=1, writes while TBNE=1 ignored; **TBNE=1 forever with no
device**; 4-deep RX FIFO; CMPINTR = OR of both ports' pending data, visible
in port 0's STATUS (stuck at 1 => ISR loops forever); LASI edge on CMPINTR
0->1; CONTROL=0 and 0x20 inhibit (device emulation queues, not drops); device
emulation answers F5/F4/F2/F0/FC/ED/F3 with FA, F2 with AB 83 (keyboard) or
00 (mouse), supports set 3, resends on FE, replies within 0.5 s.
**May** omit loopback (LPBXR), DIAG line shadows, TERR/PERR (tie 0).

## 2. asio0 -- built-in RS-232 (SVERSION 0x8C)

**Attach/init.** `asio0_attach` (0x182398) claims 0x8C, 0x8D, 0x75 (also
hooks `pci_attach`). `asio0_init` (0x5b8c8): for 0x8C the registers are at
**HPA+0x800 = LASI+0x5800, 1-byte stride** (0x5baec; QEMU `machine.c:607`
and Linux 8250_gsc agree); 0x8D has no offset; the dummy read at 0xF0810000
is for 0x75 (ASP) only. `isrlink(isc, asio0_intr, -1)` takes irq 26 (IMR
bit 5) from the isc.

**Init:** FCR <- 0x01 (0x5bc40), FCR <- 0x0D (0x5bc98: FIFO + TX reset + DMA
bit; RX reset never used); drain RBR while LSR.DR, max 16 (0x5bd48); MCR <-
0x08 (0x5bdcc); console port -> `asio0_who_init` (B9600, `asio0_param`).
`asio0_param` (0x1fa290): LCR from cflag (CSIZE>>5, CSTOPB 0x04, PARENB
0x08, even 0x10); IER |= 0x0A, plus 0x05 if CREAD (RX drained first).
`asio0_hw_init` (0x1fb8f8): **spin on LSR.TEMT (0x40) every 10 us with no
timeout** (0x1fbb9c); LCR|0x80, DLM, DLL, LCR, IER (0x1fbb44-0x1fbb70).

**Baud clock.** `highspeed_baudmap` (0x4008e0): 50->9216, 110->4189,
9600->48, 19200->24, 38400->12, 57600->8, 115200->4, 230400->2, 460800->1 =>
a 7.3728 MHz reference (baud base 460800). Real LASI uses 40/5.5 = 7.2727 MHz
(ERS 3106-3108), ~1.4 % slow; QEMU and Linux use 7272727. Either works;
7.3728 MHz gives exact rates.

**Open/control.** `asio0_open`: FCR <- ((minor>>8)&0xC0) | 0x09 (RX trigger
from minor bits 14-15, 0x1f921c). TX burst per THRE interrupt =
`asio0_tx_limit` {1,4,8,12} by minor bits 12-13 (console 12, 0x5bb58);
`asio0_xmit` writes THR up to that limit **without checking LSR** -> TX FIFO
>= 12. `asio0_control`: op 5 FCR <- trigger|0x0D; op 6 drain RX; break via
LCR bit 0x40 (0x1fb40c/0x1fb478); drain polls TEMT with `delay(5)`; MCR
(0x1fb5c8-0x1fb648) normally 0x0F, hardware flow 0x0A|DTR (bit 2 clear =
LASI hardware-RTS mode, ERS 3097).

**ISR** (`asio0_intr` 0x1fa4a0): read IIR (+2) until bit 0 = 1; decode
`(IIR>>1)&3` (so the 0xCC timeout counts as receive): 0 -> MSR
(`asio0_modemstat` 0x1fb780 reads +6); 1 -> THRE (relies on the IIR read
clearing it), soft xmit; 2/3 -> read LSR (BI/FE/OE/PE per char), RBR while
DR, kick xmit if THRE. Closed tty: IER &= ~5. MSR bits: CTS 0x10, DSR 0x20,
RI 0x40, DCD 0x80, TERI 0x04; `asio0_modemcheck` also polls each second; CTS
flow control in software.

Never: UART-type or FIFO probe, scratch test, write to LASI reset at HPA+0.
`asio0_revision` is a what-string (PHNE_17642, 99/02/19). Diagnostic ioctl
0xC0084411 / write can peek/poke offsets 0-7 (0x1f9e74).

**rs232_\*** is the polled UART for the kernel debugger (RDB), only from
`rdb_ident_comm_port`; `rs232_ident_port` knows HPA 0xF0105000;
`rs232_init` (0x27da20) checks: after FCR=1, **IIR must read 0xC1**; LCR=0x83
reads back; DLL=0x30, FCR=0x07, MCR=0x07.

**FPGA must:** a true 16550A (16-byte FIFOs, trigger levels, character
timeout); correct IIR priority, IIR read clears THRE, bit 0 = 1 when idle,
bits 7:6 = 11 with FIFOs on; **TEMT = 1 when idle** (else boot hangs in
`asio0_hw_init`); LSR/MSR reads clear their status bits; LASI irq 26 held
until cleared; modem inputs tied to 0xB0 (DCD+DSR+CTS) without real lines.
**May** skip MCR bit-2 auto-RTS, the FCR DMA bit, loopback; SCR plain.

## 3. CentIf -- parallel port (SVERSION 0x74), DMA only

**Attach/init.** `CentIf_attach` (0x182d38) matches 0x74; DMA base =
**HPA-0x1000 = LASI+0x1000**, mapped `io_map_regs(..., 0x488)` (0x182d7c);
HPA 0xF0824000 (ASP) special-cased. `CentIf_init` (0x520a0): `Reset`, then
`isrlink(..., CentIf_isr, 24)` (irq 24 = IMR bit 7).

**Reset** (0x5a0b0): slv+0x805 <- 0 (ints off); dma+0x00D <- 1 (master
clear); slv+0x000 <- 1 (slave reset); 1 ms; slv+0x802 <- 0xC8 (NINIT low,
NSLIN high); 51 us; slv+0x802 <- 0xC4; slv+0x806 (TDC0) <- ceil((MHz-22)/6)
(7 at 64 MHz; LASI ignores TDC0). TDC1 (0x807) never written.

**Mode** (`CentIf_DevInit` 0x1eb758, minor&7 -> ModeCtl slv+0x804):

| minor | ModeCtl | meaning |
|---|---|---|
| 1 | 0x30 | mode 1 + Biden |
| 2 | 0x50 | mode 2 + Biden |
| 4 | 0x90 | mode 4 (stream) + Biden |
| 5 | 0x28 | mode 1 + Fstb |
| 6 | 0x48 | mode 2 + Fstb |
| 3 | -- | bidirectional: writes 0x50; reads ModeCtl 0x70 (mode 3, not on LASI), ParDevCtl 0xE6, DMA mode 0x08 (I/O->memory, not on LASI) |
| 0, 7 | error | |

**Write path** (`CentIf_transfer` 0x1eb988): interrupt mask 0x80, 8 KB
chunks; `core_dma_build_chain` (with `fdcache_conditionally` -- memory
flushed before DMA); `ProcessChainElement` (0x1ec168) per chunk:

| register | write |
|---|---|
| dma+0x0C | 1 (clear byte pointer) |
| dma+0x00 | addr[7:0], addr[15:8] |
| dma+0x87 | addr[23:16] |
| dma+0x487 | addr[31:24] |
| dma+0x0C | 1 |
| dma+0x01 | (len-1)[7:0], [15:8] |
| dma+0x401 | (len-1)[23:16] |
| slv+0x805 | 0x80 (DMA-done enable) |
| dma+0x0E | 1 (clear mask: start) |

The DMA Mode register is not written; master clear must leave write mode.
**Chunk split:** an even-length chunk >= 64 bytes goes as len-21 bytes, then
21 bytes reprogramming **only the count** (0x13=20, 0, 0) and unmasking
(0x1ebfb0) -- the Current Address must have advanced byte-exactly.

**Interrupts.** `CentIf_isr` only soft-triggers `RealIntrHndlr` (0x1ebd40):
read IECtlStat r; write `en & ~r`, then `en`; `r & 0x90 == 0x80` -> next
chunk / 21-byte tail / done (IECtlStat <- 0, `core_dma_cleanup`); `r & 0x90
== 0x90` while writing -> **stall** (the NACK request 0x10 must never read
set when not enabled). No hardware timeout; `CentIf_abort` (0x1ebc08, on a
signal): IECtlStat <- 0, read ModeCtl and write 0, read the remaining count
(byte pointer, dma+1 twice, dma+0x401), `Reset`, restore ModeCtl. HP-UX never
reads ParData/ParStatus (+0x800/+0x801); `CharDrv_ioctl` returns EINVAL.

**FPGA must:** decode slave registers at LASI+0x2000 / +0x2800-0x2807 and DMA
registers at LASI+0x1000 (0x0, 0x1, 0xB, 0xC, 0xD, 0xE, 0x87, 0x401, 0x487);
8237-style byte-pointer flip-flop and count readback (terminal count at
0xFFFFFF); master clear -> mask=1, mode=write, pointer=0; start on clear-mask
(0x0E); bus-master word reads with byte-granular start/length (no
coherency); handshake modes 1, 2, 4 and Fstb; ModeCtl readable; IECtlStat
(write sets enables, writing 0 clears that request; requests latch only when
enabled, or reads masked by enables); DMA-done (bit 7) after the last byte
handshakes, edge on irq 24. **May** omit read DMA, mode 3, the DMA
status/mask/single-mask/FIFO-limit registers, the drst page, TDC0.
PC-style ParData/ParStatus/ParDevCtl PIO only matters for Linux
(parport_gsc). QEMU has no LASI parallel DMA, so HP-UX printing cannot work
there.

Helper scripts: session scratchpad `drivers/periph/` (`rng.sh START END`,
`ps2_all.txt`, `ps2_ctl.txt`, `asio_all.txt`, `cent_all.txt`).
