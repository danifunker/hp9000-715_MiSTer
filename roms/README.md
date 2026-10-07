# Boot ROM

## HP firmware (the target)

`hp715_pdc_rev1.6.bin` is HP's boot ROM for the 715/64, 715/80, 715/100 and
725/100: PDC, IODC, the Boot Console Handler (`BOOT_ADMIN>`), the built-in
graphics' STI code and fonts. It is revision 1.6, from HP's firmware patch
`PF_C7X50016` (1995-09-29). **Not for the 715/100XC**, which must stay on 1.2.

It is HP's code and is not committed (`.gitignore`). To recreate it:

```bash
mkdir -p roms/hp-firmware && cd roms/hp-firmware
curl -O https://paco.parisc-linux.org/firmware/715/C7X50016.frm
curl -O https://paco.parisc-linux.org/firmware/715/C7X50016.text
sum -s C7X50016.frm                # must print 48275 1446 (the value in C7X50016.text)
cd ../..
tools/hpfw/hpfw.py extract roms/hp-firmware/C7X50016.frm roms/hp-firmware/lif
cp roms/hp-firmware/lif/IMAGE1A.payload.bin roms/hp715_pdc_rev1.6.bin
```

| file | sha256 |
|---|---|
| `C7X50016.frm` (740,352 bytes) | `5a0f86d6c1c65b0f1c7e0cd8ca16e97ab6d7d8552781700c415c77e9f7211ef8` |
| `hp715_pdc_rev1.6.bin` (258,728 bytes) | `9f3b45fa74e81016cfc93b64ecd08929d55b7e3456797b1830b501b7003ecac7` |

### What is in the .frm

The `.frm` is a bootable LIF tape image. HP's instructions `dd` it to tape and
boot it; `UPDATE` then programs the flash.

| LIF file | bytes | what |
|---|---:|---|
| `ISL` | 61,440 | Initial System Loader |
| `AUTO` | 256 | ISL autoboot command |
| `ODE`, `SYSLIB` | 118,784 / 172,032 | Offline Diagnostic Environment and its library |
| `REBOOT`, `UPDATE` | 28,672 / 61,440 | the flash update program |
| `DAGGER` | 30,208 | not identified yet |
| `IMAGE1A` | 259,072 | **the ROM**: a 256-byte "Firmware Image Hdr. v1.00" + 258,728-byte payload; the header's word-sum checksum (0xa8bb80fc) matches |
| `IMAGE1B` | 512 | a second image whose payload is the two bytes `"1\n"` |

The payload is the flash contents from `0xF0000000` (the CPU resets to
`0xF0000004`). The flash is 256 KB (two Am29F010 on LASI's 8-bit ROM bus,
per the LASI ERS), so the payload stops 3,416 bytes short of the top; stable
storage probably lives there (to be confirmed in the disassembly).

## SeaBIOS-hppa (the open fallback)

QEMU's firmware, LGPLv3, source in `~/src/qemu-11.1.1/roms/seabios-hppa`. It
has a 715/64 profile but needs QEMU-only hooks removed before it can run on
real hardware -- `docs/review/05-firmware-pdc-iodc-sti.md` (e).
