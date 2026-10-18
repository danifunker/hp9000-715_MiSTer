//============================================================================
//  HP 9000 Model 715 -- MiSTer top (docs/design/system.md)
//
//  The machine (rtl/hp715.sv) on one 64 MHz clock with: system RAM in the
//  SDRAM module (rtl/mister/sdram64.sv), the boot ROM image and the ECC
//  check store in DDR3 (rtl/mister/ddr3_port.sv), the EEPROM's image on an
//  SD-card slot (rtl/mister/eeprom_save.sv), the LASI RS-232 port on the
//  MiSTer UART, PS/2 keyboard and mouse from hps_io, the MiSTer clock into
//  the LASI RTC. Artist's VRAM and attribute plane are in DDR3 too; Artist
//  makes the picture itself (rtl/artist/artist_video.sv: both colour maps,
//  the hardware cursor, 64 MHz pixels) and it is the core's video while the
//  Artist's video is on (OSD "Display"); otherwise the video shows the
//  RS-232 console as text (rtl/mister/serial_term.sv) with the front-panel
//  LEDs, and the MiSTer keyboard types into it (rtl/mister/ps2_ascii.sv) as
//  well as reaching the LASI PS/2 port.
//
//  boot.rom (HP's PDC 1.6, games/HP9K715/boot.rom) is loaded by the MiSTer
//  at core start (ioctl index 0); the machine waits in reset until it has
//  arrived.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Harmony's codec output (rtl/lasi/harmony.sv), signed 16-bit, held between samples
wire [15:0] audio_l, audio_r;
assign AUDIO_S = 1;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////


`include "build_id.v"
// The OSD follows docs/osd-standard.md: the media and Load ROM, Memory and
// Network interface on the top page, then Machine (P1), Video (P2), Input
// (P3) and Advanced (P5). Every setting but the media, Input and the buttons
// waits for the next reset ("Apply and reset"; cfg below), and "Changes
// pending" (menumask bit 0) shows while one differs from what is running.
localparam CONF_STR = {
	"HP9K715;UART9600:19200:38400:57600:115200;",
	"-;",
	// slots 0/2/3 are the SCSI images (IDs 6, 5 and the CD-ROM at 2), "SC":
	// remembered; F0 loads another boot ROM through the boot0.rom path
	// (ioctl index 0) for this session only (a core start loads boot0.rom)
	"SC0,HDAIMG,Pri. disk (ID 6);",
	"SC2,HDAIMG,Disk (ID 5);",
	"SC3,ISO,CD-ROM (ID 2);",
	"F0,ROM,Load ROM;",
	"-;",
	"O[5:3],Memory,32MB,64MB,128MB,16MB;",
	// read by Main's 82596 bridge (support/hp9k), so it acts at once (STUBS S-027)
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
	// slot 1 is the 8 KB EEPROM image: loaded before the machine leaves
	// reset, saved back when the firmware changes it
	"P5SC1,EEP,EEPROM image;",

	// status bits 8, 9 and 18 were development options until 2026-10-18:
	// left unused so a saved config cannot turn them into something else
	"v,0;",
	"V,v",`BUILD_DATE
};

localparam VDNUM = 4;           // 0 disk ID 6, 1 EEPROM, 2 disk ID 5, 3 CD-ROM
wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire         cfg_pending;   // an OSD setting differs from the running one (below)
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [15:0] sdram_sz;
wire  [32:0] TIMESTAMP;

wire        ioctl_download, ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire        ioctl_wait;

wire [31:0] sd_lba[VDNUM];
wire  [5:0] sd_blk_cnt[VDNUM];
wire [VDNUM-1:0] sd_rd, sd_wr, sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[VDNUM];
wire        sd_buff_wr;
wire [VDNUM-1:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(VDNUM), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, cfg_pending}),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sdram_sz(sdram_sz),
	.TIMESTAMP(TIMESTAMP)
);

///////////////////////   CLOCKS   ///////////////////////////////

// one 64 MHz clock for everything: the machine, SDRAM, DDRAM, video; the
// SDRAM's own clock is the same frequency, phase-shifted (rtl/mister/sdram64.sv)
wire clk_sys, clk_sdram, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

// Artist's pixel clock: its own PLL, reconfigured to the programmed mode's
// frequency (VIDEO below; rtl/pll_video.v)
wire clk_pix, pix_locked;
reg  prst_s1 = 1'b1, prst_pix = 1'b1;   // its side held while it is retargeted

altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
) sdramclk_ddr (
	.datain_h(1'b1), .datain_l(1'b0), .outclock(clk_sdram), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
);

///////////////////////   RESET, CONFIGURATION   /////////////////

// the boot ROM download (ioctl index 0, the whole low byte: boot1.rom etc.
// come at index n << 6)
wire        rom_dl = ioctl_download && ioctl_index[7:0] == 8'd0;
reg         rom_loaded = 0;
always @(posedge clk_sys) if (rom_dl) rom_loaded <= 1'b1;

wire sdram_ready, ee_ready, ee_loaded;
wire reset_req = RESET | status[0] | buttons[1] | rom_dl | ~rom_loaded | ~pll_locked | ~sdram_ready | ~ee_ready | ee_loaded;
reg  [15:0] rst_cnt = 16'hFFFF;
always @(posedge clk_sys)
	if (reset_req) rst_cnt <= 16'hFFFF;
	else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
wire m_reset = rst_cnt != 0;

// model and RAM size, latched while the machine is in reset; RAM no larger
// than the module (sdram_sz[1:0]: 1 = 32 MB, 2 = 64 MB, 3 = 128 MB). The RAM
// option lists 32MB first (the default, 2026-10-14): index 0..3 = 32, 64,
// 128, 16 MB
reg  [1:0] cfg_model;
reg  [3:0] cfg_ram_lg;
wire [3:0] want_lg = 4'd4 + 4'((status[5:3] + 3'd1) & 3'd3);
wire [3:0] max_lg  = sdram_sz[1:0] == 2'd3 ? 4'd7 : sdram_sz[1:0] == 2'd2 ? 4'd6 : 4'd5;
always @(posedge clk_sys) if (m_reset) begin
	cfg_model  <= status[2:1] == 2'd3 ? 2'd0 : status[2:1];
	cfg_ram_lg <= want_lg > max_lg ? max_lg : want_lg;
end

// the settings the machine runs with: the OSD's values, taken while the
// machine is in reset (Apply and reset, the board's button, a core start or
// a ROM load), so a change waits for the next reset (docs/osd-standard.md).
// The media, Input (Swap Alt/Win keys), the buttons (T[6], T[7]) and the
// Network interface (Main reads it itself) act at once and stay out of it.
reg [125:0] cfg = 0;
always @(posedge clk_sys) if (m_reset) cfg <= status[125:0];
assign cfg_pending = {status[5:1], status[11:10], status[17:15], status[125:121]}
                  != {cfg[5:1],    cfg[11:10],    cfg[17:15],    cfg[125:121]};
wire [1:0] ar = cfg[122:121];

// Input: Swap Alt/Win keys (status[19], at once): left Alt <-> left GUI,
// right Alt <-> right GUI (ps2_key: [8] extended, [7:0] the set-2 code)
function automatic [8:0] alt_win(input [8:0] k);
	case (k)
		9'h011: alt_win = 9'h11F;   // left Alt -> left GUI
		9'h11F: alt_win = 9'h011;
		9'h111: alt_win = 9'h127;   // right Alt -> right GUI
		9'h127: alt_win = 9'h111;
		default: alt_win = k;
	endcase
endfunction
wire [10:0] kbd_key = status[19] ? {ps2_key[10:9], alt_win(ps2_key[8:0])} : ps2_key;

// the soft power button: held "pressed" for 2 s (HP-UX polls it at 4 Hz, Linux at 1 Hz)
reg [27:0] softoff_cnt = 0;
reg        stat7_q = 0;
always @(posedge clk_sys) begin
	stat7_q <= status[7];
	if (status[7] && !stat7_q) softoff_cnt <= 28'd128_000_000;
	else if (softoff_cnt != 0) softoff_cnt <= softoff_cnt - 1'd1;
end

// the RTC: the MiSTer's time (seconds since 1970) whenever hps_io updates it
reg ts_q = 0;
always @(posedge clk_sys) ts_q <= TIMESTAMP[32];
wire rtc_set = TIMESTAMP[32] != ts_q;

///////////////////////   THE MACHINE   //////////////////////////

wire        ram_req, ram_we, ram_line, ram_ack, ram_wready, ram_rvalid;
wire [27:0] ram_addr;
wire  [7:0] ram_be;
wire [63:0] ram_wdata, ram_rdata;
wire  [1:0] ram_rbeat;
wire        chk_req, chk_we, chk_ack;
wire [22:0] chk_addr;
wire  [3:0] chk_be;
wire [31:0] chk_wdata, chk_rdata;
wire        rom_req, rom_ack, rom_rvalid;
wire [17:5] rom_addr;
wire [63:0] rom_rdata;
wire  [7:0] leds;
wire        led_strobe;
wire [31:0] pcr;
wire [10:0] ee_haddr;
wire        ee_hwe, ee_dirty, ee_dirty_clr;
wire [31:0] ee_hwdata, ee_hrdata;
wire [31:0] gr [32];
wire        scsi_act;
wire         dbg_ev_valid;
wire [111:0] dbg_ev;
wire         tr_req, tr_ack;
wire  [15:0] tr_idx;
wire [255:0] tr_data;
// the serial console on the screen and the MiSTer keyboard typing into it
wire        con_tx, con_rx_full, kbd_ascii_stb;
wire  [7:0] con_tx_byte, kbd_ascii;
ps2_ascii ps2_ascii (.clk(clk_sys), .rst(m_reset), .ps2_key(kbd_key), .strobe(kbd_ascii_stb), .ascii(kbd_ascii));

// Artist's VRAM (DDR3 at 0x3300_0000), its attribute plane (0x3340_0000) and its display
wire        vr_req, vr_we, vr_ack, vr_wvalid, vr_wready, vr_rvalid;
wire [18:0] vr_addr;
wire  [6:0] vr_len;
wire [63:0] vr_wdata, vr_rdata;
wire  [7:0] vr_be;
wire        rf_req, rf_ack, rf_rvalid;
wire [18:0] rf_addr;
wire  [6:0] rf_len;
wire [63:0] rf_rdata;
wire        gfx_on, gfx_pal_wr;
wire [11:0] gfx_width, gfx_height;
wire  [2:0] gfx_pix_mode;
wire  [7:0] gfx_r, gfx_g, gfx_b;
wire        gfx_hs, gfx_vs, gfx_de, gfx_underrun;
wire  [8:0] gfx_pal_addr;
wire [23:0] gfx_pal_rgb;
wire        nb_req, nb_we, nb_ack;
wire [12:0] nb_addr;
wire [63:0] nb_wdata, nb_rdata;

// the debug recorder (rtl/hp715.sv dbg_ev_*, rtl/mister/trace_ddr3.sv, tools/mister/trace_*)
// is a debug build's: `set_global_assignment -name VERILOG_MACRO "HP9K715_DEBUG=1"` in the
// QSF (docs/design/system.md 10, build 49); a release build leaves it out (about 700 ALMs)
`ifdef HP9K715_DEBUG
localparam bit DBG_RECORDER = 1'b1;
`else
localparam bit DBG_RECORDER = 1'b0;
`endif
hp715 #(.CLK_HZ(64_000_000), .HAS_ARTIST(1'b1), .EE_INIT("rtl/mister/hp715_default.hex"), .DBG_RECORDER(DBG_RECORDER)) hp715
(
	.clk(clk_sys), .reset(m_reset), .pclk(clk_pix), .prst(prst_pix),
	.cfg_model(cfg_model), .cfg_ram_lg(cfg_ram_lg), .sim_cr16_mul(4'd0), .cfg_boot(cfg[17:15]),
	.soft_pwr_n(softoff_cnt == 0), .toc_button(status[6]),
	.led_latch(leds), .led_strobe(led_strobe), .lasi_pcr(pcr), .audio_l(audio_l), .audio_r(audio_r), .cd_change(img_mounted[3]),
	.nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
	.chk_ack(chk_ack), .chk_rdata(chk_rdata),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid),
	.rom_rdata(rom_rdata), .rom_inval(rom_dl),
	.uart_txd(UART_TXD), .uart_rxd(UART_RXD), .uart_tap_strobe(con_tx), .uart_tap_byte(con_tx_byte),
	.uart_inj_strobe(kbd_ascii_stb && !con_rx_full), .uart_inj_byte(kbd_ascii), .uart_inj_full(con_rx_full),
	.ps2_key(kbd_key), .ps2_mouse(ps2_mouse),
	.img_present(img_present), .img_blocks(img_blocks), .sd_lba(m_lba), .sd_blk_cnt(m_blk_cnt),
	.sd_rd(m_rd), .sd_wr(m_wr), .sd_ack({sd_ack[3], sd_ack[2], sd_ack[0]}), .sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout), .sd_buff_din(m_buff_din), .sd_buff_wr(sd_buff_wr), .scsi_activity(scsi_act),
	.rtc_set(rtc_set), .rtc_value(TIMESTAMP[31:0]),
	.ee_haddr(ee_haddr), .ee_hwe(ee_hwe), .ee_hwdata(ee_hwdata), .ee_hrdata(ee_hrdata),
	.ee_dirty(ee_dirty), .ee_dirty_clr(ee_dirty_clr),
	.vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_ack(vr_ack),
	.vr_wvalid(vr_wvalid), .vr_wdata(vr_wdata), .vr_be(vr_be), .vr_wready(vr_wready),
	.vr_rvalid(vr_rvalid), .vr_rdata(vr_rdata),
	.rf_req(rf_req), .rf_addr(rf_addr), .rf_len(rf_len), .rf_ack(rf_ack), .rf_rvalid(rf_rvalid), .rf_rdata(rf_rdata),
	.gfx_on(gfx_on), .gfx_width(gfx_width), .gfx_height(gfx_height), .gfx_pix_mode(gfx_pix_mode),
	.gfx_r(gfx_r), .gfx_g(gfx_g), .gfx_b(gfx_b), .gfx_hs(gfx_hs), .gfx_vs(gfx_vs), .gfx_de(gfx_de),
	.gfx_underrun(gfx_underrun),
	.gfx_pal_wr(gfx_pal_wr), .gfx_pal_addr(gfx_pal_addr), .gfx_pal_rgb(gfx_pal_rgb),
	.dbg_ctl(8'd0), .dbg_shot(status[127:64]), .dbg_retire(), .dbg_nullified(), .dbg_iaoq_f(), .dbg_iaoq_b(), .dbg_insn(),
	.dbg_trap(), .dbg_trap_vec(), .dbg_psw(), .dbg_halted(), .dbg_buserr(), .dbg_buserr_addr(),
	.dbg_gr(gr), .dbg_ev_valid(dbg_ev_valid), .dbg_ev(dbg_ev)
);

// the debug event ring in DDR3 at 0x3200_0000 (tools/mister/trace_dump.py), debug builds only
generate if (DBG_RECORDER) begin : g_trace
	trace_ddr3 #(.LG_N(16)) trace_ddr3
	(
		.clk(clk_sys), .rst(m_reset), .ev_valid(dbg_ev_valid), .ev(dbg_ev),
		.tr_req(tr_req), .tr_idx(tr_idx), .tr_data(tr_data), .tr_ack(tr_ack), .drops()
	);
end else begin : g_no_trace
	assign tr_req = 1'b0; assign tr_idx = 16'd0; assign tr_data = 256'd0;
end endgenerate

///////////////////////   MEMORY   ///////////////////////////////

sdram64 #(.CLK_HZ(64_000_000)) sdram
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .rst(~pll_locked), .rd_mode(2'd0), .ready(sdram_ready),  // edge 3 (STUBS S-019; the OSD choice went 2026-10-18)
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr[26:0]), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

// a copy of LUT0 and LUT1, the active size and video-on in DDR3 at
// 0x3320_0000 for the board tools (tools/mister/board.sh vram renders the
// VRAM with it and the attribute plane): written 4096 clocks after the last
// palette change, and when the size or video-on changes; word i = entries
// 2i, 2i+1 (0x00RRGGBB; 256-511 = LUT1), word 256 = {height, width, video on}
reg  [23:0] lut_e [256], lut_o [256];
reg  [23:0] lut_qe, lut_qo;
reg  [12:0] lut_quiet = 0;
reg         lut_dirty = 0, lt_req = 0, lt_rd = 0, lt_rd2 = 0;
reg   [8:0] lt_addr;
reg  [63:0] lt_data;
wire        lt_ack;
reg  [24:0] lut_geom = 0;
always @(posedge clk_sys) begin
	if (gfx_pal_wr) begin
		if (gfx_pal_addr[0]) lut_o[gfx_pal_addr[8:1]] <= gfx_pal_rgb;
		else                 lut_e[gfx_pal_addr[8:1]] <= gfx_pal_rgb;
	end
	lut_qe <= lut_e[lt_addr[7:0]];
	lut_qo <= lut_o[lt_addr[7:0]];
end
always @(posedge clk_sys) begin
	lt_rd <= 1'b0; lt_rd2 <= lt_rd;
	if (gfx_pal_wr || {gfx_height, gfx_width, gfx_on} != lut_geom) begin
		lut_dirty <= 1'b1; lut_quiet <= 0; lut_geom <= {gfx_height, gfx_width, gfx_on};
	end else if (lut_dirty && !lt_req && !lt_rd && !lt_rd2) begin
		if (lut_quiet != 13'h1FFF) lut_quiet <= lut_quiet + 1'd1;
		else begin lut_dirty <= 1'b0; lt_addr <= 9'd0; lt_rd <= 1'b1; end
	end
	// lt_rd: the entries of lt_addr are read this cycle; lt_rd2: the word goes out
	if (lt_rd2) begin
		lt_req <= 1'b1;
		lt_data <= lt_addr[8] ? {39'd0, lut_geom} : {8'd0, lut_qo, 8'd0, lut_qe};
	end
	if (lt_req && lt_ack) begin
		lt_req <= 1'b0;
		if (lt_addr != 9'd256) begin lt_addr <= lt_addr + 1'd1; lt_rd <= 1'b1; end
	end
end

wire        rl_busy, rl_wr, ld_busy;
wire [17:3] rl_waddr;
wire [63:0] rl_wdata;
rom_loader #(.INDEX(8'd0)) rom_loader
(
	.clk(clk_sys), .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr[24:0]),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index[7:0]), .busy(rl_busy),
	.wr(rl_wr), .waddr(rl_waddr), .wdata(rl_wdata)
);
assign ioctl_wait = ld_busy;

assign DDRAM_CLK = clk_sys;
ddr3_port ddr3
(
	.clk(clk_sys), .rst(~pll_locked),
	.ld_wr(rl_wr), .ld_addr(rl_waddr), .ld_data(rl_wdata), .ld_busy(ld_busy),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid), .rom_rdata(rom_rdata),
	.chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
	.chk_ack(chk_ack), .chk_rdata(chk_rdata),
	.tr_req(tr_req), .tr_idx(tr_idx), .tr_data(tr_data), .tr_ack(tr_ack),
	.lt_req(lt_req), .lt_addr(lt_addr), .lt_data(lt_data), .lt_ack(lt_ack),
	.nb_req(nb_req), .nb_we(nb_we), .nb_addr(nb_addr), .nb_wdata(nb_wdata), .nb_ack(nb_ack), .nb_rdata(nb_rdata),
	.vr_req(vr_req), .vr_we(vr_we), .vr_addr(vr_addr), .vr_len(vr_len), .vr_ack(vr_ack),
	.vr_wvalid(vr_wvalid), .vr_wdata(vr_wdata), .vr_be(vr_be), .vr_wready(vr_wready),
	.vr_rvalid(vr_rvalid), .vr_rdata(vr_rdata),
	.rf_req(rf_req), .rf_addr(rf_addr), .rf_len(rf_len), .rf_ack(rf_ack), .rf_rvalid(rf_rvalid), .rf_rdata(rf_rdata),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

// SD slots 0, 2, 3: the SCSI images (the machine's slots 0, 1, 2); 1: the EEPROM
reg  [2:0]  img_present = 0;
reg  [31:0] img_blocks [3];
wire [31:0] m_lba [3];
wire  [5:0] m_blk_cnt [3];
wire  [2:0] m_rd, m_wr;
wire [15:0] m_buff_din [3];
localparam int SLOT [3] = '{0, 2, 3};
always @(posedge clk_sys)
	for (int i = 0; i < 3; i++)
		if (img_mounted[SLOT[i]]) begin
			img_present[i] <= img_size != 0;
			img_blocks[i]  <= img_size[40:9];
		end
genvar gi;
generate for (gi = 0; gi < 3; gi = gi + 1) begin : g_sd
	assign sd_lba[SLOT[gi]] = m_lba[gi];
	assign sd_blk_cnt[SLOT[gi]] = m_blk_cnt[gi];
	assign sd_rd[SLOT[gi]] = m_rd[gi];
	assign sd_wr[SLOT[gi]] = m_wr[gi];
	assign sd_buff_din[SLOT[gi]] = m_buff_din[gi];
end endgenerate
eeprom_save #(.CLK_HZ(64_000_000)) eeprom_save
(
	.clk(clk_sys), .rst(~pll_locked), .ready(ee_ready), .loaded(ee_loaded), .blank_if_none(1'b0), .osd_open(OSD_STATUS),  // no OSD "Blank" since 2026-10-18
	.img_mounted(img_mounted[1]), .img_size(img_size),
	.sd_lba(sd_lba[1]), .sd_blk_cnt(sd_blk_cnt[1]), .sd_rd(sd_rd[1]), .sd_wr(sd_wr[1]), .sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[1]),
	.sd_buff_wr(sd_buff_wr),
	.ee_haddr(ee_haddr), .ee_hwe(ee_hwe), .ee_hwdata(ee_hwdata), .ee_hrdata(ee_hrdata),
	.ee_dirty(ee_dirty), .ee_dirty_clr(ee_dirty_clr)
);

///////////////////////   VIDEO   ////////////////////////////////

// Artist makes its own picture (rtl/artist/artist_video.sv) at the timing
// the firmware programs, on its own pixel clock clk_pix (STUBS S-024): the
// ROM's monitor records give 1280x1024 at 60 Hz (108.181 MHz; its 72, 75
// and 50 Hz records, 110-135 MHz, are shown with that timing: the scaler's
// input does not take more on this device), 1024x768 at 60-75 Hz ...
// 640x480 at 60 Hz (25.175); artist.sv's pix_mode names the clock and the
// state machine below reconfigures the PLL to it. Every pixel goes through
// LUT0/LUT1 by the attribute plane, the hardware cursor laid over it. OSD
// "Display" (Graphics is the default, 2026-10-14): Auto = Artist while its video is on, else the serial console;
// Graphics = always Artist; Serial console = never. Auto keeps Artist once
// its video has been on since the machine's reset: a blanked screen (X's
// screen saver clears MISC_VIDEO bits 27/25) stays black, as on a 715,
// instead of turning into the console view. The serial console is 640x480
// at 27.05 MHz (108.181 / 4; 858 x 525, 60.04 Hz), so it needs the static
// clock and Artist's 1280x1024 modes do too: a normal boot never
// reconfigures. Both outputs carry the picture: the scaler, and the analog
// VGA at the real monitor timing. The scaler's window: "Original" aspect =
// square pixels (the active size) for Artist, 4:3 for the console; OSD
// "Scale" (default V-Integer: 1024 lines 1:1 on a 1080-line HDMI mode, a
// fit when the mode has fewer lines) computed from the HDMI mode by
// sys/video_freak.sv. The HDMI mode itself is the MiSTer's (MiSTer.ini
// video_mode).
reg  gfx_seen = 1'b0;
always @(posedge clk_sys) gfx_seen <= m_reset ? 1'b0 : gfx_seen | gfx_on;
wire gfx_show = cfg[11:10] == 2'd2 ? 1'b0 : cfg[11:10] == 2'd0 ? 1'b1 : gfx_on | gfx_seen;   // 0 Graphics, 1 Auto, 2 serial
// the clock the shown picture needs (0 = 108.181 MHz, the console's too)
reg  [2:0] pix_want = 3'd0;
always @(posedge clk_sys) pix_want <= gfx_show ? gfx_pix_mode : 3'd0;

wire [63:0] pix_to_pll, pix_from_pll;
pll_video pllv
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_pix),
	.locked(pix_locked),
	.reconfig_to_pll(pix_to_pll),
	.reconfig_from_pll(pix_from_pll)
);

wire        pixcfg_wait;
reg         pixcfg_write = 0;
reg   [5:0] pixcfg_addr = 0;
reg  [31:0] pixcfg_data = 0;
pll_cfg_hdmi pllv_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(pixcfg_wait),
	.mgmt_write(pixcfg_write),
	.mgmt_address(pixcfg_addr),
	.mgmt_writedata(pixcfg_data),
	.reconfig_to_pll(pix_to_pll),
	.reconfig_from_pll(pix_from_pll)
);

// The PLL's settings per pix_mode: {M, C0, K} as Main_MiSTer writes the HDMI
// PLL's (video.cpp setPLL: a divider d is {odd, (d+1)/2 high, d/2 low}; N
// bypassed; Fvco = 50 MHz x (M + K/2^32) in 650..1250 MHz, Fout = Fvco / C0).
function [95:0] pix_cfg(input [2:0] i);
	case (i)
		3'd1:    pix_cfg = {32'h00020706, 32'h00000404, 32'h88AEFB2B};  //  84.587: M 13, C 8
		3'd2:    pix_cfg = {32'h00000707, 32'h00020504, 32'h2CCCCCCD};  //  78.750: M 14, C 9
		3'd3:    pix_cfg = {32'h00020706, 32'h00020504, 32'h80000000};  //  75.000: M 13, C 9
		3'd4:    pix_cfg = {32'h00000707, 32'h00020605, 32'h1A9E6EEB};  //  64.109: M 14, C 11
		3'd5:    pix_cfg = {32'h00020706, 32'h00000707, 32'hDC28F5C3};  //  49.500: M 13, C 14
		3'd6:    pix_cfg = {32'h00020706, 32'h00020B0A, 32'h3AE147AE};  //  31.500: M 13, C 21
		3'd7:    pix_cfg = {32'h00020706, 32'h00000D0D, 32'h174BC6A8};  //  25.175: M 13, C 26
		default: pix_cfg = {32'h00020807, 32'h00020403, 32'h25350093};  // 108.181: M 15, C 7 (static)
	endcase
endfunction

// The retarget (on CLK_50M, the reconfiguration block's clock): the wanted
// clock must hold for 42 ms (the ROM writes the timing words one at a time),
// then M, N, C0, charge pump, bandwidth, K and start, as Main_MiSTer does
// for the HDMI PLL; the pixel side is held (black, prst_pix) from the
// decision until 40 ms after the PLL has locked again, so the scaler and a
// monitor see a clean blank, not a frame at two rates.
reg pix_quiet = 1'b0;
always @(posedge CLK_50M) begin : pix_reconfig
	reg  [2:0] w_s1 = 3'd0, w_s2 = 3'd0, cur = 3'd0;
	reg [20:0] hold = 21'd0;
	reg [21:0] settle = 22'd0;
	reg  [3:0] st = 4'd0;
	reg [95:0] cfg;
	w_s1 <= pix_want; w_s2 <= w_s1;
	hold <= (w_s2 != w_s1 || w_s2 == cur) ? 21'd0 : hold + 1'd1;
	if (st != 0 || !pix_locked) settle <= 22'd2_000_000;
	else if (settle != 0) settle <= settle - 1'd1;
	pix_quiet <= st != 0 || settle != 0 || !pix_locked;
	if (!pixcfg_wait) begin
		pixcfg_write <= 1'b0;
		case (st)
			4'd0: if (&hold && pix_locked) begin cur <= w_s2; cfg <= pix_cfg(w_s2); st <= 4'd1; end
			4'd1: begin pixcfg_addr <= 6'd4; pixcfg_data <= cfg[95:64]; pixcfg_write <= 1'b1; st <= 4'd2; end  // M
			4'd2: begin pixcfg_addr <= 6'd3; pixcfg_data <= 32'h00010000; pixcfg_write <= 1'b1; st <= 4'd3; end // N bypassed
			4'd3: begin pixcfg_addr <= 6'd5; pixcfg_data <= cfg[63:32]; pixcfg_write <= 1'b1; st <= 4'd4; end  // C0
			4'd4: begin pixcfg_addr <= 6'd9; pixcfg_data <= 32'd2; pixcfg_write <= 1'b1; st <= 4'd5; end        // charge pump
			4'd5: begin pixcfg_addr <= 6'd8; pixcfg_data <= 32'd7; pixcfg_write <= 1'b1; st <= 4'd6; end        // bandwidth
			4'd6: begin pixcfg_addr <= 6'd7; pixcfg_data <= cfg[31:0]; pixcfg_write <= 1'b1; st <= 4'd7; end   // K
			4'd7: begin pixcfg_addr <= 6'd2; pixcfg_data <= 32'd0; pixcfg_write <= 1'b1; st <= 4'd8; end        // start
			default: st <= 4'd0;
		endcase
	end
end
always @(posedge clk_pix) begin prst_s1 <= pix_quiet; prst_pix <= prst_s1; end

// the serial console: 640x480 in 858 x 525 at 27.05 MHz (a pixel every
// fourth clk_pix at 108.181 MHz: 31.52 kHz, 60.04 Hz); the machine's RS-232 console as
// text, the front-panel LEDs and the power LED (green while LASI's PWR_ON_L
// is clear, blinking with FLASH_LED) on a status line (STUBS S-018)
reg  [1:0] pdiv = 0;
reg  [9:0] hc = 0, vc = 0;
reg  [24:0] blink = 0;
always @(posedge clk_sys) blink <= blink + 1'd1;
always @(posedge clk_pix) begin
	pdiv <= pdiv + 1'd1;
	if (pdiv == 2'd3) begin
		if (hc == 10'd857) begin hc <= 0; vc <= (vc == 10'd524) ? 10'd0 : vc + 1'd1; end
		else hc <= hc + 1'd1;
	end
end
wire       pwr_on = !pcr[1] && (!pcr[0] || blink[24]);
wire [7:0] st_r, st_g, st_b;
wire       st_hs, st_vs, st_de;

serial_term serial_term
(
	.clk(clk_sys), .rst(m_reset), .pclk(clk_pix),
	.tx_strobe(con_tx), .tx_byte(con_tx_byte),
	.leds(leds), .pwr(pwr_on),
	.pix_ce(pdiv == 2'd0), .hc(hc), .vc(vc),
	.hs_in(hc >= 10'd656 && hc < 10'd752), .vs_in(vc >= 10'd490 && vc < 10'd492),
	.de_in(hc < 10'd640 && vc < 10'd480),
	.r(st_r), .g(st_g), .b(st_b), .hs(st_hs), .vs(st_vs), .de(st_de)
);

// the shown picture, black while the clock is being retargeted
reg  show_s1 = 1'b0, show_pix = 1'b0;
always @(posedge clk_pix) begin show_s1 <= gfx_show; show_pix <= show_s1; end
wire [2:0] scale_osd = cfg[125:123];
wire       vid_de;
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vid_de),
	.ARX((!ar) ? (gfx_show ? gfx_width : 12'd4) : (ar - 1'd1)),
	.ARY((!ar) ? (gfx_show ? gfx_height : 12'd3) : 12'd0),
	.CROP_SIZE(12'd0), .CROP_OFF(5'd0),
	.SCALE(scale_osd == 3'd0 ? 3'd1 : scale_osd == 3'd1 ? 3'd0 : scale_osd)
);

assign CLK_VIDEO = clk_pix;
assign CE_PIXEL  = show_pix ? 1'b1 : pdiv == 2'd0;
assign {VGA_HS, VGA_VS} = show_pix ? {gfx_hs, gfx_vs} : {st_hs, st_vs};
assign {VGA_R, VGA_G, VGA_B, vid_de} = prst_pix ? 25'd0 : show_pix ? {gfx_r, gfx_g, gfx_b, gfx_de}
                                                                    : {st_r, st_g, st_b, st_de};

///////////////////////   LEDS   /////////////////////////////////

// user LED: LED4, the OS heartbeat; power LED: LASI's
assign LED_USER  = !leds[3];
assign LED_POWER = {1'b1, pwr_on};
assign LED_DISK  = {1'b1, scsi_act};      // a SCSI command in progress

endmodule
