`timescale 1ns / 1ps
//============================================================================
//  HP 9000/715 -- Verilator simulation top
//
//  `emu` here is the SIMULATION top: the machine (rtl/hp715.sv) with
//  behavioural memories -- system RAM, the ECC check store, the boot ROM
//  store (filled through rtl/rom_loader.sv by the ioctl download, so the
//  STUBS S-011 patch is applied as on the board) -- and a small video
//  generator that shows the eight front-panel LEDs until Artist exists.
//  sim_main.cpp (GUI) and romsim/tb_rom.cpp (headless) both drive it.
//
//  sim_status: [1:0] model (0 = 715/64, 1 = /80, 2 = /100),
//              [5:2] RAM = 2^n MB (0 = the default, 16 MB; at most RAM_LG_MAX)
//              [9:6] CR16 speed-up (0 = real rate): shortens the ROM's
//                    delays; selftest1's timer test needs the real rate
//  +eeprom=<hex> preloads the EEPROM (rtl/hp_xbus.sv); blank otherwise.
//============================================================================

module emu #(
	parameter int RAM_LG_MAX = 6          // the RAM array: 2^6 = 64 MB
)
(
	input         clk_sys,
	input         reset,
	input  [31:0] sim_status,
	input  [7:0]  sim_trace,       // trace switches (rtl/hp715.sv dbg_ctl)

	// PS/2 keyboard and mouse, in hps_io's format
	input  [10:0] ps2_key,
	input  [24:0] ps2_mouse,

	// Video
	output [7:0]  VGA_R,
	output [7:0]  VGA_G,
	output [7:0]  VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_HB,
	output        VGA_VB,
	output        CE_PIXEL,

	// Audio
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,

	// Boot ROM download (hps_io ioctl, index 0 = boot.rom)
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [7:0]  ioctl_index,
	output        ioctl_wait,

	// Serial console: every byte the LASI UART starts to send, and bytes
	// typed into its receiver
	output        uart_tx_strobe,
	output [7:0]  uart_tx_byte,
	input         uart_rx_strobe,
	input  [7:0]  uart_rx_byte,
	output        uart_rx_full,

	// SCSI images, as hps_io's block devices (512-byte blocks, 16-bit
	// buffer): slot 0 = disk ID 6, 1 = disk ID 5, 2 = CD-ROM ID 2
	input  [2:0]  img_present,
	input  [31:0] img_blocks [3],
	output [31:0] sd_lba [3],
	output [5:0]  sd_blk_cnt [3],
	output [2:0]  sd_rd,
	output [2:0]  sd_wr,
	input  [2:0]  sd_ack,
	input  [12:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din [3],
	input         sd_buff_wr,

	// Front panel
	output [7:0]  leds,            // the LED latch (active low)
	output        led_strobe,      // a chassis code was written
	input         toc_button,
	input         soft_power_off,

	// CPU debug taps
	output [31:0] debug_iaoq_f,
	output [31:0] debug_iaoq_b,
	output [31:0] debug_insn,
	output        debug_retire,
	output        debug_nullified,
	output        debug_trap,
	output [5:0]  debug_trap_vec,
	output [31:0] debug_psw,
	output        debug_halted,
	output        debug_buserr,
	output [31:0] debug_buserr_addr
);

localparam int RAM_WORDS = 1 << (RAM_LG_MAX + 17);     // 64-bit words
localparam int CHK_WORDS = 1 << (RAM_LG_MAX + 15);     // one per 32-byte line

wire [3:0] ram_lg = sim_status[5:2] == 4'd0 ? 4'd4 :
                    sim_status[5:2] > 4'(RAM_LG_MAX) ? 4'(RAM_LG_MAX) : sim_status[5:2];

//----------------------------------------------------------------------------
// Boot ROM store, written by the loader
//----------------------------------------------------------------------------
logic        rl_busy, rl_wr;
logic [17:3] rl_waddr;
logic [63:0] rl_wdata;
rom_loader #(.INDEX(8'd0)) u_rl (
	.clk(clk_sys), .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(ioctl_index), .busy(rl_busy),
	.wr(rl_wr), .waddr(rl_waddr), .wdata(rl_wdata));
assign ioctl_wait = 1'b0;

logic [63:0] rom [32768];
always_ff @(posedge clk_sys) if (rl_wr) rom[rl_waddr] <= rl_wdata;

// machine reset: the input, and the download (plus a little while after it)
logic [7:0] rst_cnt;
always_ff @(posedge clk_sys)
	if (reset || rl_busy) rst_cnt <= 8'd255;
	else if (rst_cnt != 8'd0) rst_cnt <= rst_cnt - 8'd1;
`ifdef SDRAM_MODEL
wire sdram_ready;
wire m_reset = reset || rl_busy || rst_cnt != 8'd0 || !sdram_ready;
`else
wire m_reset = reset || rl_busy || rst_cnt != 8'd0;
`endif

//----------------------------------------------------------------------------
// The machine
//----------------------------------------------------------------------------
logic        ram_req, ram_we, ram_line, ram_ack, ram_wready, ram_rvalid;
logic [1:0]  ram_rbeat;
logic [27:0] ram_addr;
logic [7:0]  ram_be;
logic [63:0] ram_wdata, ram_rdata;
logic        chk_req, chk_we, chk_ack;
logic [22:0] chk_addr;
logic [3:0]  chk_be;
logic [31:0] chk_wdata, chk_rdata;
logic        rom_req, rom_ack, rom_rvalid;
logic [17:5] rom_addr;
logic [63:0] rom_rdata;
logic [31:0] gr [32];
logic [31:0] pcr;

hp715 #(.CLK_HZ(64_000_000), .SIM_FAST(1'b1)) u_hp715 (
	.clk(clk_sys), .reset(m_reset),
	.cfg_model(sim_status[1:0]), .cfg_ram_lg(ram_lg), .sim_cr16_mul(sim_status[9:6]),
	.soft_pwr_n(!soft_power_off), .toc_button(toc_button),
	.led_latch(leds), .led_strobe(led_strobe), .lasi_pcr(pcr),
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
	.chk_ack(chk_ack), .chk_rdata(chk_rdata),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid),
	.rom_rdata(rom_rdata), .rom_inval(rl_busy),
	.uart_txd(), .uart_rxd(1'b1), .uart_tap_strobe(uart_tx_strobe), .uart_tap_byte(uart_tx_byte),
	.uart_inj_strobe(uart_rx_strobe), .uart_inj_byte(uart_rx_byte), .uart_inj_full(uart_rx_full),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
	.img_present(img_present), .img_blocks(img_blocks), .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr), .scsi_activity(),
	.rtc_set(1'b0), .rtc_value(32'd0),
	.ee_haddr(11'd0), .ee_hwe(1'b0), .ee_hwdata(32'd0), .ee_hrdata(), .ee_dirty(), .ee_dirty_clr(1'b0),
	.dbg_ctl(sim_trace), .dbg_retire(debug_retire), .dbg_nullified(debug_nullified), .dbg_iaoq_f(debug_iaoq_f),
	.dbg_iaoq_b(debug_iaoq_b), .dbg_insn(debug_insn), .dbg_trap(debug_trap), .dbg_trap_vec(debug_trap_vec),
	.dbg_psw(debug_psw), .dbg_halted(debug_halted), .dbg_buserr(debug_buserr),
	.dbg_buserr_addr(debug_buserr_addr), .dbg_gr(gr));

`ifdef SDRAM_MODEL
//----------------------------------------------------------------------------
// System RAM as on the board: rtl/mister/sdram64.sv on a behavioural chip
// (verilator/sim_sdram_chip.sv, one 64 MB rank), SDRAM_CLK in phase
//----------------------------------------------------------------------------
wire  [15:0] sd_dq;
logic [12:0] sd_a;
logic [1:0]  sd_ba;
logic        sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
sdram64 #(.CLK_HZ(64_000_000)) u_sdram (
	.clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .rd_mode(2'd3), .ready(sdram_ready),
	.ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr[26:0]), .ram_be(ram_be),
	.ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
	.ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
	.SDRAM_DQ(sd_dq), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
	.SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke));
sim_sdram_chip #(.INV_CS(0)) u_sdram_chip (.clk(clk_sys), .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas),
	.nWE(sd_nwe), .ba(sd_ba), .a(sd_a), .dqmh(sd_dqmh), .dqml(sd_dqml), .dq(sd_dq), .ctl_drives(u_sdram.dq_oe));
`else
//----------------------------------------------------------------------------
// System RAM: acknowledge the cycle after the request, then one beat per
// cycle (a line wraps from ram_addr[4:3])
//----------------------------------------------------------------------------
logic [63:0] ram [RAM_WORDS];
logic [1:0]  r_state;              // 0 idle, 1 reading, 2 writing
logic [27:0] r_addr;
logic [1:0]  r_beat, r_left;
logic [7:0]  r_be;
wire  [RAM_LG_MAX+16:0] r_widx = {r_addr[RAM_LG_MAX+19:5], r_beat};
always_ff @(posedge clk_sys) begin
	ram_ack <= 1'b0; ram_rvalid <= 1'b0; ram_wready <= 1'b0;
	case (r_state)
		2'd0: if (ram_req && !ram_ack) begin
			ram_ack <= 1'b1; r_addr <= ram_addr; r_beat <= ram_addr[4:3]; r_be <= ram_be;
			r_left <= ram_line ? 2'd3 : 2'd0;
			r_state <= ram_we ? 2'd2 : 2'd1;
		end
		2'd1: begin
			ram_rvalid <= 1'b1; ram_rdata <= ram[r_widx]; ram_rbeat <= r_beat;
			r_beat <= r_beat + 2'd1; r_left <= r_left - 2'd1;
			if (r_left == 2'd0) r_state <= 2'd0;
		end
		default: begin
			if (!ram_wready) ram_wready <= 1'b1;
			if (ram_wready) begin
				for (int b = 0; b < 8; b++) if (r_be[b]) ram[r_widx][8*b +: 8] <= ram_wdata[8*b +: 8];
				r_beat <= r_beat + 2'd1; r_left <= r_left - 2'd1;
				if (r_left == 2'd0) r_state <= 2'd0;
				else ram_wready <= 1'b1;
			end
		end
	endcase
	if (reset) r_state <= 2'd0;
end
`endif

// check store
logic [31:0] chk [CHK_WORDS];
wire  [RAM_LG_MAX+14:0] c_idx = chk_addr[RAM_LG_MAX+14:0];
always_ff @(posedge clk_sys) begin
	chk_ack <= 1'b0;
	if (chk_req && !chk_ack) begin
		chk_ack <= 1'b1;
		if (chk_we) begin
			for (int b = 0; b < 4; b++) if (chk_be[b]) chk[c_idx][8*b +: 8] <= chk_wdata[8*b +: 8];
		end else chk_rdata <= chk[c_idx];
	end
end

// boot ROM: four beats after the acknowledge
logic [1:0] rm_beat;
logic       rm_busy;
logic [17:5] rm_line;
always_ff @(posedge clk_sys) begin
	rom_ack <= 1'b0; rom_rvalid <= 1'b0;
	if (!rm_busy) begin
		if (rom_req && !rom_ack) begin rom_ack <= 1'b1; rm_busy <= 1'b1; rm_beat <= 2'd0; rm_line <= rom_addr; end
	end else begin
		rom_rvalid <= 1'b1; rom_rdata <= rom[{rm_line, rm_beat}];
		rm_beat <= rm_beat + 2'd1;
		if (rm_beat == 2'd3) rm_busy <= 1'b0;
	end
	if (reset) rm_busy <= 1'b0;
end

//----------------------------------------------------------------------------
// Video: 640x480 at 16 MHz pixel clock, the eight LEDs as squares (lit =
// latch bit clear), plus the power LED (green, from LASI PCR)
//----------------------------------------------------------------------------
logic [1:0] pdiv;
logic [9:0] hc, vc;
always_ff @(posedge clk_sys) begin
	pdiv <= pdiv + 2'd1;
	if (pdiv == 2'd3) begin
		if (hc == 10'd799) begin hc <= 10'd0; vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1; end
		else hc <= hc + 10'd1;
	end
end
assign CE_PIXEL = pdiv == 2'd3;
assign VGA_HB = hc >= 10'd640;
assign VGA_VB = vc >= 10'd480;
assign VGA_HS = hc >= 10'd656 && hc < 10'd752;
assign VGA_VS = vc >= 10'd490 && vc < 10'd492;
wire       in_row = vc >= 10'd200 && vc < 10'd240;
wire [9:0] hx = hc - 10'd80;
wire       in_led = in_row && hc >= 10'd80 && hc < 10'd560 && hx[5:0] < 6'd40;
wire [2:0] led_n = 3'd7 - hx[8:6];                      // LED8 on the left
wire       lit = in_led && !leds[led_n];
wire       pwr = vc >= 10'd300 && vc < 10'd320 && hc >= 10'd300 && hc < 10'd340 && !pcr[1];
assign VGA_R = (VGA_HB || VGA_VB) ? 8'd0 : lit ? 8'hFF : in_led ? 8'h30 : 8'd0;
assign VGA_G = (VGA_HB || VGA_VB) ? 8'd0 : lit ? 8'hB0 : pwr ? 8'hFF : in_led ? 8'h20 : 8'd0;
assign VGA_B = 8'd0;

assign AUDIO_L = 16'd0;
assign AUDIO_R = 16'd0;

endmodule
