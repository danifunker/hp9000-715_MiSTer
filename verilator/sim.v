`timescale 1ns / 1ps
//============================================================================
//  HP 9000/715 -- Verilator simulation top
//
//  `emu` here is the SIMULATION top: the sim-friendly port surface that
//  sim_main.cpp drives (the MiSTer framework's sys_top is not simulated).
//
//  Bring-up stage 0: the machine does not exist yet, so the MiSTer
//  template's demo core paints the video window and paces frames
//  (docs/STUBS.md S-001). The port list is already the machine's: option
//  bits, PS/2, video, audio, the ROM download, a serial-console tap and CPU
//  debug taps, so sim_main.cpp does not change shape when the machine
//  replaces the demo core.
//============================================================================

module emu
(
	input         clk_sys,
	input         reset,

	// Stand-ins for the MiSTer status word (the OSD options):
	//   sim_status[2] TV mode for the template (0 NTSC, 1 PAL)
	input  [31:0] sim_status,

	// PS/2 keyboard and mouse, in hps_io's format (LASI PS/2 when it exists)
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

	// Boot ROM download (hps_io ioctl, index 0 = boot.rom). The sim can
	// also preload the ROM with $readmemh once the machine exists.
	input         ioctl_download,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [7:0]  ioctl_index,
	output        ioctl_wait,

	// Serial console tap: one strobe per byte the LASI UART transmits
	// (the CPU test ROM and the PDC report through it)
	output        uart_tx_strobe,
	output [7:0]  uart_tx_byte,

	// CPU debug taps
	output [31:0] debug_iaoq_f,    // instruction address offset queue, front
	output [31:0] debug_iaoq_b,    // ... and back
	output [31:0] debug_insn,      // instruction at the front of the queue
	output        debug_retire,    // one pulse per retired instruction
	output        debug_halted     // CPU stopped (halt / fatal machine check)
);

//----------------------------------------------------------------------------
// Placeholder: the template demo core (docs/STUBS.md S-001)
//----------------------------------------------------------------------------
wire       ce_pix;
wire [7:0] video;
wire       hbl, vbl, hs, vs;

mycore mycore
(
	.clk(clk_sys),
	.reset(reset),
	.pal(sim_status[2]),
	.scandouble(1'b0),
	.ce_pix(ce_pix),
	.hvcnt_atzero(),
	.HBlank(hbl),
	.HSync(hs),
	.VBlank(vbl),
	.VSync(vs),
	.video(video)
);

assign CE_PIXEL = ce_pix;
assign VGA_R    = video;
assign VGA_G    = video;
assign VGA_B    = video;
assign VGA_HS   = hs;
assign VGA_VS   = vs;
assign VGA_HB   = hbl;
assign VGA_VB   = vbl;

assign AUDIO_L  = 16'd0;
assign AUDIO_R  = 16'd0;
assign ioctl_wait = 1'b0;

assign uart_tx_strobe = 1'b0;
assign uart_tx_byte   = 8'd0;

assign debug_iaoq_f = 32'd0;
assign debug_iaoq_b = 32'd0;
assign debug_insn   = 32'd0;
assign debug_retire = 1'b0;
assign debug_halted = 1'b0;

endmodule
