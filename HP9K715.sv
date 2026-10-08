//============================================================================
//  HP 9000 Model 715 -- MiSTer top (docs/design/system.md)
//
//  The machine (rtl/hp715.sv) on one 64 MHz clock with: system RAM in the
//  SDRAM module (rtl/mister/sdram64.sv), the boot ROM image and the ECC
//  check store in DDR3 (rtl/mister/ddr3_port.sv), the EEPROM's image on an
//  SD-card slot (rtl/mister/eeprom_save.sv), the LASI RS-232 port on the
//  MiSTer UART, PS/2 keyboard and mouse from hps_io, the MiSTer clock into
//  the LASI RTC. Until Artist exists the video shows the RS-232 console
//  as text (rtl/mister/serial_term.sv) with the front-panel LEDs, and the
//  MiSTer keyboard types into it (rtl/mister/ps2_ascii.sv) as well as
//  reaching the LASI PS/2 port.
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

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"HP9K715;UART9600:19200:38400:57600:115200;",
	"-;",
	// slots 0/2/3 are the SCSI images (IDs 6, 5 and the CD-ROM at 2);
	// slot 1 is the 8 KB EEPROM image: loaded before the machine leaves
	// reset, saved back when the firmware changes it. "SC": remembered.
	"SC0,HDAIMG,SCSI disk (ID 6);",
	"SC2,HDAIMG,SCSI disk (ID 5);",
	"SC3,ISO,CD-ROM (ID 2);",
	"SC1,EEP,Mount EEPROM;",
	"-;",
	"O[2:1],Model (on reset),715/64,715/80,715/100;",
	"O[5:3],RAM (on reset),16MB,32MB,64MB,128MB;",
	"O[9:8],SDRAM read capture,Edge 3,Edge 2.75,Edge 2.5,Edge 4;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"T[6],TOC (front panel);",
	"T[7],Soft power off;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

localparam VDNUM = 4;           // 0 disk ID 6, 1 EEPROM, 2 disk ID 5, 3 CD-ROM
wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
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
	.status_menumask(16'd0),

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

wire sdram_ready, ee_ready;
wire reset_req = RESET | status[0] | buttons[1] | rom_dl | ~rom_loaded | ~pll_locked | ~sdram_ready | ~ee_ready;
reg  [15:0] rst_cnt = 16'hFFFF;
always @(posedge clk_sys)
	if (reset_req) rst_cnt <= 16'hFFFF;
	else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
wire m_reset = rst_cnt != 0;

// model and RAM size, latched while the machine is in reset; RAM no larger
// than the module (sdram_sz[1:0]: 1 = 32 MB, 2 = 64 MB, 3 = 128 MB)
reg  [1:0] cfg_model;
reg  [3:0] cfg_ram_lg;
wire [3:0] want_lg = 4'd4 + status[5:3];
wire [3:0] max_lg  = sdram_sz[1:0] == 2'd3 ? 4'd7 : sdram_sz[1:0] == 2'd2 ? 4'd6 : 4'd5;
always @(posedge clk_sys) if (m_reset) begin
	cfg_model  <= status[2:1] == 2'd3 ? 2'd0 : status[2:1];
	cfg_ram_lg <= want_lg > max_lg ? max_lg : want_lg;
end

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
// the serial console on the screen and the MiSTer keyboard typing into it
wire        con_tx, con_rx_full, kbd_ascii_stb;
wire  [7:0] con_tx_byte, kbd_ascii;
ps2_ascii ps2_ascii (.clk(clk_sys), .rst(m_reset), .ps2_key(ps2_key), .strobe(kbd_ascii_stb), .ascii(kbd_ascii));

hp715 #(.CLK_HZ(64_000_000)) hp715
(
	.clk(clk_sys), .reset(m_reset),
	.cfg_model(cfg_model), .cfg_ram_lg(cfg_ram_lg), .sim_cr16_mul(4'd0),
	.soft_pwr_n(softoff_cnt == 0), .toc_button(status[6]),
	.led_latch(leds), .led_strobe(led_strobe), .lasi_pcr(pcr),
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
	.chk_ack(chk_ack), .chk_rdata(chk_rdata),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid),
	.rom_rdata(rom_rdata), .rom_inval(rom_dl),
	.uart_txd(UART_TXD), .uart_rxd(UART_RXD), .uart_tap_strobe(con_tx), .uart_tap_byte(con_tx_byte),
	.uart_inj_strobe(kbd_ascii_stb && !con_rx_full), .uart_inj_byte(kbd_ascii), .uart_inj_full(con_rx_full),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
	.img_present(img_present), .img_blocks(img_blocks), .sd_lba(m_lba), .sd_blk_cnt(m_blk_cnt),
	.sd_rd(m_rd), .sd_wr(m_wr), .sd_ack({sd_ack[3], sd_ack[2], sd_ack[0]}), .sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout), .sd_buff_din(m_buff_din), .sd_buff_wr(sd_buff_wr), .scsi_activity(scsi_act),
	.rtc_set(rtc_set), .rtc_value(TIMESTAMP[31:0]),
	.ee_haddr(ee_haddr), .ee_hwe(ee_hwe), .ee_hwdata(ee_hwdata), .ee_hrdata(ee_hrdata),
	.ee_dirty(ee_dirty), .ee_dirty_clr(ee_dirty_clr),
	.dbg_ctl(8'd0), .dbg_retire(), .dbg_nullified(), .dbg_iaoq_f(), .dbg_iaoq_b(), .dbg_insn(),
	.dbg_trap(), .dbg_trap_vec(), .dbg_psw(), .dbg_halted(), .dbg_buserr(), .dbg_buserr_addr(),
	.dbg_gr(gr)
);

///////////////////////   MEMORY   ///////////////////////////////

sdram64 #(.CLK_HZ(64_000_000)) sdram
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .rst(~pll_locked), .rd_mode(status[9:8]), .ready(sdram_ready),
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr[26:0]), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

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
	.clk(clk_sys), .rst(~pll_locked), .ready(ee_ready), .osd_open(OSD_STATUS),
	.img_mounted(img_mounted[1]), .img_size(img_size),
	.sd_lba(sd_lba[1]), .sd_blk_cnt(sd_blk_cnt[1]), .sd_rd(sd_rd[1]), .sd_wr(sd_wr[1]), .sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[1]),
	.sd_buff_wr(sd_buff_wr),
	.ee_haddr(ee_haddr), .ee_hwe(ee_hwe), .ee_hwdata(ee_hwdata), .ee_hrdata(ee_hrdata),
	.ee_dirty(ee_dirty), .ee_dirty_clr(ee_dirty_clr)
);

///////////////////////   VIDEO (the serial console)   ////////////

// 640x480 at 21.3 MHz (one pixel every third clock, 680 x 525 total, 59.7
// Hz): the machine's RS-232 console as text, the front-panel LEDs and the
// power LED (green while LASI's PWR_ON_L is clear, blinking with FLASH_LED)
// on a status line -- until Artist exists (STUBS S-018)
reg  [1:0] pdiv = 0;
reg  [9:0] hc = 0, vc = 0;
reg  [24:0] blink = 0;
always @(posedge clk_sys) begin
	blink <= blink + 1'd1;
	pdiv <= (pdiv == 2'd2) ? 2'd0 : pdiv + 1'd1;
	if (pdiv == 2'd2) begin
		if (hc == 10'd679) begin hc <= 0; vc <= (vc == 10'd524) ? 10'd0 : vc + 1'd1; end
		else hc <= hc + 1'd1;
	end
end
wire       pwr_on = !pcr[1] && (!pcr[0] || blink[24]);

serial_term serial_term
(
	.clk(clk_sys), .rst(m_reset),
	.tx_strobe(con_tx), .tx_byte(con_tx_byte),
	.leds(leds), .pwr(pwr_on),
	.pix_ce(pdiv == 2'd0), .hc(hc), .vc(vc),
	.hs_in(hc >= 10'd656 && hc < 10'd672), .vs_in(vc >= 10'd490 && vc < 10'd492),
	.de_in(hc < 10'd640 && vc < 10'd480),
	.r(VGA_R), .g(VGA_G), .b(VGA_B), .hs(VGA_HS), .vs(VGA_VS), .de(VGA_DE)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = pdiv == 2'd0;

///////////////////////   LEDS   /////////////////////////////////

// user LED: LED4, the OS heartbeat; power LED: LASI's
assign LED_USER  = !leds[3];
assign LED_POWER = {1'b1, pwr_on};
assign LED_DISK  = {1'b1, scsi_act};      // a SCSI command in progress

endmodule
