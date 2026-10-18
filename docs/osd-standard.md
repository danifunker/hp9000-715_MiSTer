# OSD standard for computer cores

One menu layout for the MiSTer computer cores (HP 9000/715, HP 9000/385,
the Mac cores, SGI Indy, SPARCstation, RS/6000, Pippin ...), so a user who
knows one core's OSD knows them all. It uses only what stock Main_MiSTer's
menu already supports (`menu.cpp`, `user_io.cpp`).

## The rules

1. **Media changes and Input settings take effect at once. Every other
   setting waits for the next reset.** (Input's keyboard and mouse
   settings don't change the machine, so they never need a reboot;
   buttons are actions and act when pressed. A setting Main reads itself,
   like the HP cores' network bridge reading Network interface, also acts
   at once, until Main takes it from the core instead.) The top page has one action, **Apply and reset**, which
   resets the machine with the settings as they are in the OSD. Any other
   reset (the board's reset button, a core reload) also applies them.
2. **The top page holds only, in this order:**
   1. **the media**: every drive the machine has (hard disks, CD-ROMs,
      floppies, tapes ...), as many as it has, in the order that suits
      that machine (by SCSI ID, by the machine's own drive names). This
      block is the core's own; the standard doesn't prescribe it, except
      that it **starts with the primary boot disk** and ends with **Load
      ROM** (below). Only the first row is labelled `Pri.`: the disk the
      machine boots from by default (`Pri. disk (ID 6)` on the HP 9000/715,
      `Pri. disk (ID 0)` on the Macs). Main shows the label only while the
      slot is empty (a mounted slot shows its file name instead), and it
      describes the default: firmware settings can boot elsewhere, which
      the core's README says.
   2. **Memory** and **Network interface**,
   3. the submenus, in page order (Machine, Video, Input, Audio, Advanced),
   4. the "Changes pending" notice and **Apply and reset**.

   Nothing else goes on the top page; every other setting is in a
   submenu. There is no network submenu: Network interface `None`
   disconnects the NIC (a built-in chip stays visible to the OS with no
   link; a plug-in card is removed from the machine).
3. **Submenus have fixed page numbers in every core:**

   | page | title | holds |
   |---|---|---|
   | P1 | Machine | **what the machine is**: model, CPU speed, caches; then, at the bottom, **every one-press button**, wherever the original had it: the case's (soft power off, TOC, NMI, reset switch) and the keyboard's (a Mac's Power key, a Sun's Stop-A, Ctrl-Alt-Del) |
   | P2 | Video | display source (graphics / serial console), monitor type, aspect ratio, scale |
   | P3 | Input | keyboard and mouse **settings** (they apply at once): Swap Alt/Win keys, keyboard layout, joystick / ADB controller, "stick moves pointer". Buttons go in Machine. |
   | P4 | Audio | audio on/off, MT32-pi |
   | P5 | Advanced | **the firmware and how it boots**: boot mode / device, fast boot, autoboot, console redirect; the firmware's saved settings (EEPROM / NVRAM / PRAM image); disk-cache and timing workarounds |
   | P9 | Debug | bring-up options, **only in debug builds** |

   A core leaves out a page it has nothing for. The numbers never shift,
   so "P2 is Video" holds in every core and in every README.
4. **Every core has Load ROM**, the last row of the media block on the
   top page: `"F0,ROM,Load ROM;"` (extensions to suit the core; a core
   that already loads its ROM through another index keeps it, e.g. the
   MacPPC7300's `F1`). It is **not remembered** (`F`, not `FC`): a normal start always loads
   `games/<core>/boot0.rom` (or `boot.rom`), and Load ROM or an MGL file
   picks another ROM for that session only, so an MGL never changes the
   default. Loading a ROM counts as media: it resets the machine at once.

   It has to be on the top page, never hidden: Main's MGL support looks
   for the row an MGL names (`<file type="f" index="0" .../>`) only among
   the rows drawn on the top page, and drops the MGL when it isn't there
   (`menu.cpp`, "F/S option not found -> deactivate mgl"). The same holds
   for every disk slot an MGL mounts. An MGL with another ROM:

   ```xml
   <mistergamedescription>
     <rbf>_Unstable/HP9K715</rbf>
     <file delay="1" type="f" index="0" path="../../../../games/HP9K715/pdc_rev1.5.rom"/>
   </mistergamedescription>
   ```
5. **Hide what doesn't apply, and keep its space.** Two rows that never
   apply at the same time can share one line instead (the MT32-pi's
   `Munt ROM` with Synth = Munt, `SoundFont` with Synth = FluidSynth: an
   `H<b>` row and an `h<b>` row, no blank).
   Otherwise a row that can't
   apply to the machine as configured (a stick option with no controller, a memory size larger
   than the SDRAM module) is hidden, and a blank line takes its place, so
   the rows below never move. Hiding follows the OSD values live, so a row
   comes and goes as soon as the controlling option changes, without
   waiting for Apply and reset. Rows a core never has are left out of its
   CONF_STR.
6. **Pending changes are shown.** While any setting in the OSD differs from
   what the machine is running (Input settings and buttons excluded), a notice row on the top page says so
   ("Changes pending" above Apply and reset). It disappears at the reset.
7. **The default comes first** in every value list, so a core with no
   saved settings starts from the first value of each row.
8. **Standard names and value lists** (a core leaves out values it cannot
   do, but keeps the order):

   | row | values |
   |---|---|
   | `Pri. disk (ID n)` | the first media row only: the default boot disk |
   | `Disk (ID n)` | a hard-disk image at SCSI ID n (or `Disk n` without SCSI IDs) |
   | `CD-ROM (ID n)` | a CD image |
   | `Memory` | sizes, smallest that runs the usual OS first |
   | `Swap Alt/Win keys` | `No, Yes`: in every core with a keyboard. Yes swaps the left and right Alt and Win (GUI) keys, so the key next to the space bar sends the other one. A Mac core reads Win as Command and Alt as Option. |
   | `Network interface` | `eth0, None, eth1, wlan0, macvlan, tap0` (None: the NIC disconnected) |
   | `Aspect ratio` | `Original, Full Screen, [ARC1], [ARC2]` |
   | `Scale` | the core's best mode first (`V-Integer` for workstation rasters) |

9. **Short rows.** An OSD row is 28 characters: keep labels to about 16
   and values to about 11. Since every setting waits for the reset, rows
   need no "(on reset)" suffix.
10. **No development rows in release builds.** Bring-up options (capture
   points, debug video, test patterns, "blank NVRAM" choices) live on P9
   inside `` `ifdef <CORE>_DEBUG``.
11. **Saved settings stay valid.** Moving a row between pages does not move
   its status bits, so saved `.CFG` files keep working. When the meaning of
   stored values changes (a list reordered, a default moved to the front,
   bits reused), bump the config version `"v,N;"`: Main then drops `.CFG`
   files saved under another version instead of misreading them.

## The layout

```
HP9K715
  Pri. disk (ID 6)         hpux1020.img      <- media: immediate
  Disk (ID 5)              hpux1111.img
  CD-ROM (ID 2)            -
  Load ROM                                   <- boot0.rom unless chosen
  ---------------------------------------
  Memory                   32MB
  Network interface        eth0
  ---------------------------------------
  Machine                  >                 <- P1
  Video                    >                 <- P2
  Advanced                 >                 <- P5
  ---------------------------------------
   Changes pending                           <- shown only while pending
  Apply and reset
```

Pages are reached with Enter and left with Left/Back. Main's "recent"
key toggles a flat view that shows every page inline on the top page.

## How Main reads it (CONF_STR mechanics)

| syntax | meaning |
|---|---|
| `Fn,EXT,Label;` | a file loaded through ioctl index n (`FCn`: remembered in `config/<core>.f<n>` and loaded again at the next start) |
| `SCn,EXT,Label;` | a mounted image in slot n, remembered (`config/<core>.s<n>`) and mounted again at the next core start. Use `SC`, not `S`. |
| `Pn,Title;` | a submenu entry (n = 1..9) that opens page n |
| `Pn` before a row | that row lives on page n (`P1O[2:1],Model,...;`, `P5SC1,EEP,EEPROM image;`) |
| `-;` / `Pn-;` | a separator |
| `-,Text;` | a text row that can't be selected |
| `H<b>` / `h<b>` before a row | hide the row when menumask bit b is 1 / 0 |
| `D<b>` / `d<b>` before a row | grey the row out when menumask bit b is 1 / 0 |
| `R[0],Label;` | pulse status bit 0 (reset) and close the OSD |
| `v,N;` | config version; `.CFG` files from another version are dropped |

The menumask bits come from the core: `hps_io`'s `status_menumask` input.

A row hidden with its space kept is a pair: the row with `H<b>` and a blank
line with `h<b>` right after it, so exactly one of the two shows:

```
"H1O[47],Stick moves pointer,No,Yes;",
"h1-;",
```

## The RTL pattern

Latch every setting at reset; never read `status` for a setting directly.

```verilog
// the settings the machine runs with: taken from the OSD at every reset
// (Apply and reset = status[0], the board's reset, a core reload)
reg [127:0] cfg;
always @(posedge clk_sys) if (reset_req) cfg <= status;

// "Changes pending": an OSD value differs from the running one. List the
// setting fields explicitly and leave out bit 0 (reset) and the trigger
// bits (T[n] buttons). HP9K715: settings 5:1, 17:10, 125:121; TOC and soft
// power off are T[6], T[7].
wire pending = {status[5:1], status[17:10], status[125:121]}
            != {cfg[5:1],    cfg[17:10],    cfg[125:121]};

// rows that don't apply: computed from the live OSD values (status), not
// cfg, so a row hides as soon as its controlling option changes
wire no_stick = status[46:44] == 3'd1;   // Mac example: ADB controller None

hps_io #(...) hps_io (
    ...
    .status_menumask({14'd0, no_stick, pending}),  // bit 0: "h0-,Changes pending;"
                                                 // bit 1: "H1O[47],Stick..." + "h1-;"
    ...
);
```

Input settings (the Swap Alt/Win keys row, mouse and stick options) read
`status` directly, not `cfg`, and stay out of `pending`: they apply at once.

Then use `cfg[...]` everywhere a setting is used: memory size, model, video
source, aspect ratio, scale, network interface. Trigger buttons (`T[n]`:
TOC, NMI, soft power off) stay live. They are actions, not settings.

Media slots are live by nature: Main mounts an image when it is chosen, and
the core sees `img_mounted` at once.

## Example: HP 9000/715

The status bits stay where they were, so saved settings carry over. The
interface list was already eth0-first and `None` is the old `Off` renamed,
so no version bump is needed.

```verilog
localparam CONF_STR = {
	"HP9K715;UART9600:19200:38400:57600:115200;",
	"-;",
	"SC0,HDAIMG,Pri. disk (ID 6);",
	"SC2,HDAIMG,Disk (ID 5);",
	"SC3,ISO,CD-ROM (ID 2);",
	"F0,ROMBIN,Load ROM;",
	"-;",
	"O[5:3],Memory,32MB,64MB,128MB,16MB;",
	"O[14:12],Network interface,eth0,None,eth1,macvlan,tap0;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[2:1],Model,715/64,715/80,715/100;",
	"P1-;",
	"P1T[6],TOC (front panel);",
	"P1T[7],Soft power off;",

	"P2O[11:10],Display,Graphics,Auto,Serial console;",
	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[125:123],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",

	"P3O[19],Swap Alt/Win keys,No,Yes;",

	"P5O[17:15],Boot mode,Normal,BOOT_ADMIN,ISL,Single-user,LVM maint.,Network,CD/DVD;",
	"P5-;",
	"P5SC1,EEP,EEPROM image;",

	"v,0;",
	"V,v",`BUILD_DATE
};
```

## Moving a core over

1. Sort its rows into the top page and P1-P5 by the tables above, and put
   bring-up rows on P9 under `` `ifdef <CORE>_DEBUG``.
2. For every row that depends on another setting (or on the board, like
   the SDRAM size), add its menumask bit and the `H<b>` row + `h<b>-;`
   blank pair.
3. Latch `status` into `cfg` at reset and switch every setting to `cfg`;
   add the `pending` compare and the `h0-,Changes pending;` row.
4. Rename rows to the standard names and drop "(on reset)" suffixes.
5. If any value list changed order or meaning, bump `v,N`.
6. Check it the way a user would: start the core from the menu, change
   settings in the OSD, see "Changes pending", press Apply and reset.
