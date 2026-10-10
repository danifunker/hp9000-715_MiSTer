// Harmony, LASI's audio unit (page 4, 0xF0104000, IRQ = LASI bit 13; Lasi
// ERS 6.4; docs/review/06a; the CS4215 codec behind it), SVERSION 0x7B.
//
// Registers (32-bit; ERS 6.4.2-6.4.8): ID 0x00140000 (no Teleshare option,
// so the ROM finds no RJ-16/ISDN modules at +0x40/+0x60/+0x70); RESET bit 0
// (powers up 1: the codec held); CNTL: any write sets C (bit 31, control
// mode), which clears C_CLKS later -- bits 17:0 are kept (9:8 LS loopback,
// 7:6 DF format, 5 ST stereo, 4:0 XS/SR rate), Rev reads 0; GAINCTL 27:0;
// PNXTADD/RNXTADD (4 KB pages, the low 12 bits forced 0), PCURADD/RCURADD
// (the next byte address, writable for tests); DSTATUS: IE (31) read/write,
// PN (9), PC (8), RN (1), RC (0) read only, PN = RN = 1 at reset; OV bit 0
// (never set: there is no input); PIO (PI mirrors PO); DIAG bit 0, the
// codec's SCLK: toggles in data mode, 1 otherwise.
//
// DMA (ERS 6.4.4): playback and record run together, a 4 KB page at a time.
// Writing PNXTADD clears PN, RNXTADD clears RN; with the DMA stopped the
// RNXTADD write starts both -- each next page becomes the current one, PC/RC
// set, PN/RN set again (the next ones wanted). At the end of a page the next
// one is taken if it was given (N clears ... N set again), else that DMA
// stops (C clear). IRQ = IE and PN and RN (LASI takes its rising edge; the
// drivers clear IE in their handler and set it again, ERS 6.4.4).
// Every sample period (the rate from XS/SR, a phase accumulator on clk) the
// playback takes one sample's bytes from memory (prefetched a doubleword or
// two ahead) and the record side writes one: silence, or with the codec's
// loopback (LS = 01: the sample just played, LS = 10: the one before; the
// ROM's audio test checks both, HW 4.8) the played bytes.
//
// The output (out_l, out_r, a new value each sample period, held): the
// sample in 16-bit linear (from 16-bit, u-law, A-law or 8-bit unsigned),
// attenuated by LO/RO (1.5 dB steps), silent unless one of the headphone,
// line or speaker outputs (HE/LE/SE) is on, or while the codec is held or
// in control mode, or when playback is not running. Not modelled: the
// monitor path (MA; there is no input), input gains, OV (STUBS P-003).
module harmony #(
    parameter int CLK_HZ = 64_000_000,
    parameter int C_CLKS = CLK_HZ / 5000        // control mode: 200 us
) (
    input  logic        clk,
    input  logic        rst,            // machine reset, IORESET bit 3 (RST_AUD_L) clear
    // registers: req a one-cycle strobe, rdata valid the cycle after
    input  logic        req, we,
    input  logic [11:0] addr,
    input  logic [3:0]  be,             // be[3] = byte 0 = wdata[31:24]
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        irq,
    // DMA: one doubleword, held until dma_ack ([7] of dma_be = byte offset 0)
    output logic        dma_req, dma_we,
    output logic [31:0] dma_addr,
    output logic [7:0]  dma_be,
    output logic [63:0] dma_wdata,
    input  logic        dma_ack, dma_err,
    input  logic [63:0] dma_rdata,
    // the codec's outputs, out_new for a clock when they change to the next sample
    output logic signed [15:0] out_l, out_r,
    output logic        out_new
);
    // ------------------------------------------------------------ registers
    logic        reset_b, ctl_c, ie, pn, pc, rn, rc, ov;
    logic [17:0] cntl;
    logic [27:0] gain;
    logic [19:0] pnxt, rnxt;
    logic [31:0] pcur, rcur;
    logic [1:0]  po;
    localparam int CW = $clog2(C_CLKS + 1);
    logic [CW-1:0] c_cnt;
    logic [31:0] acc;

    wire [1:0] df = cntl[7:6];
    wire       st = cntl[5];
    wire [1:0] ls = cntl[9:8];
    wire [2:0] bps = df == 2'd0 ? (st ? 3'd4 : 3'd2) : (st ? 3'd2 : 3'd1);   // bytes a sample
    wire       data_mode = !reset_b && !ctl_c;

    function automatic logic [31:0] bmerge(input logic [31:0] o, input logic [31:0] d, input logic [3:0] b);
        return {b[3] ? d[31:24] : o[31:24], b[2] ? d[23:16] : o[23:16], b[1] ? d[15:8] : o[15:8], b[0] ? d[7:0] : o[7:0]};
    endfunction

    // the phase step of a sample rate: crystal / divider (CS4215 XS/SR), as
    // constants (2^32 * fs / CLK_HZ)
    localparam longint X1 = 24_576_000, X2 = 16_934_400, CK = CLK_HZ;
    localparam logic [31:0] R_8000  = 32'((X1 << 32) / (3072 * CK)), R_16000 = 32'((X1 << 32) / (1536 * CK)),
                            R_27429 = 32'((X1 << 32) / (896 * CK)),  R_32000 = 32'((X1 << 32) / (768 * CK)),
                            R_48000 = 32'((X1 << 32) / (512 * CK)),  R_9600  = 32'((X1 << 32) / (2560 * CK)),
                            R_5513  = 32'((X2 << 32) / (3072 * CK)), R_11025 = 32'((X2 << 32) / (1536 * CK)),
                            R_18900 = 32'((X2 << 32) / (896 * CK)),  R_22050 = 32'((X2 << 32) / (768 * CK)),
                            R_37800 = 32'((X2 << 32) / (448 * CK)),  R_44100 = 32'((X2 << 32) / (384 * CK)),
                            R_33075 = 32'((X2 << 32) / (512 * CK)),  R_6615  = 32'((X2 << 32) / (2560 * CK));
    function automatic logic [31:0] rate_step(input logic [4:0] xsr);
        case (xsr)
            5'b01_000: return R_8000;   5'b01_001: return R_16000; 5'b01_010: return R_27429;
            5'b01_011: return R_32000;  5'b01_110: return R_48000; 5'b01_111: return R_9600;
            5'b10_000: return R_5513;   5'b10_001: return R_11025; 5'b10_010: return R_18900;
            5'b10_011: return R_22050;  5'b10_100: return R_37800; 5'b10_101: return R_44100;
            5'b10_110: return R_33075;  5'b10_111: return R_6615;
            default:   return R_8000;                               // illegal codes
        endcase
    endfunction

    // ------------------------------------------------------------ G.711
    function automatic logic signed [15:0] ulaw(input logic [7:0] u);
        logic [7:0]  v;
        logic [15:0] t;
        v = ~u;
        t = ({12'd0, v[3:0]} << 3) + 16'h84;
        t = t << v[6:4];
        return v[7] ? $signed(16'h84 - t) : $signed(t - 16'h84);
    endfunction
    function automatic logic signed [15:0] alaw(input logic [7:0] a);
        logic [7:0]  v;
        logic [15:0] t;
        v = a ^ 8'h55;
        t = {12'd0, v[3:0]} << 4;
        if (v[6:4] == 3'd0) t = t + 16'd8;
        else t = (t + 16'h108) << (v[6:4] - 3'd1);
        return v[7] ? $signed(t) : -$signed(t);
    endfunction
    function automatic logic signed [15:0] dec8(input logic [7:0] b);
        case (df)
            2'd1: return ulaw(b);
            2'd2: return alaw(b);
            default: return $signed({b ^ 8'h80, 8'h00});              // 8-bit unsigned
        endcase
    endfunction
    // a sample of silence in the current format (right-aligned)
    function automatic logic [31:0] silence();
        logic [7:0] s;
        s = df == 2'd1 ? 8'hFF : df == 2'd2 ? 8'hD5 : df == 2'd3 ? 8'h80 : 8'h00;
        return {4{s}};
    endfunction

    // output attenuation, 1.5 dB a step (0x3F: off): round(32768 * 10^(-0.075 n))
    function automatic logic [15:0] atten(input logic [5:0] n);
        case (n)
            6'd0: return 16'd32768; 6'd1: return 16'd27554; 6'd2: return 16'd23170; 6'd3: return 16'd19484;
            6'd4: return 16'd16384; 6'd5: return 16'd13777; 6'd6: return 16'd11585; 6'd7: return 16'd9742;
            6'd8: return 16'd8192;  6'd9: return 16'd6889;  6'd10: return 16'd5793; 6'd11: return 16'd4871;
            6'd12: return 16'd4096; 6'd13: return 16'd3444; 6'd14: return 16'd2896; 6'd15: return 16'd2435;
            6'd16: return 16'd2048; 6'd17: return 16'd1722; 6'd18: return 16'd1448; 6'd19: return 16'd1218;
            6'd20: return 16'd1024; 6'd21: return 16'd861;  6'd22: return 16'd724;  6'd23: return 16'd609;
            6'd24: return 16'd512;  6'd25: return 16'd431;  6'd26: return 16'd362;  6'd27: return 16'd304;
            6'd28: return 16'd256;  6'd29: return 16'd215;  6'd30: return 16'd181;  6'd31: return 16'd152;
            6'd32: return 16'd128;  6'd33: return 16'd108;  6'd34: return 16'd91;   6'd35: return 16'd76;
            6'd36: return 16'd64;   6'd37: return 16'd54;   6'd38: return 16'd45;   6'd39: return 16'd38;
            6'd40: return 16'd32;   6'd41: return 16'd27;   6'd42: return 16'd23;   6'd43: return 16'd19;
            6'd44: return 16'd16;   6'd45: return 16'd13;   6'd46: return 16'd11;   6'd47: return 16'd10;
            6'd48: return 16'd8;    6'd49: return 16'd7;    6'd50: return 16'd6;    6'd51: return 16'd5;
            6'd52: return 16'd4;    6'd53: return 16'd3;    6'd54: return 16'd3;    6'd55: return 16'd2;
            6'd56: return 16'd2;    6'd57: return 16'd2;    6'd58: return 16'd1;    6'd59: return 16'd1;
            6'd60: return 16'd1;    6'd61: return 16'd1;    6'd62: return 16'd1;    default: return 16'd0;
        endcase
    endfunction

    // ------------------------------------------------------------ the DMA's buffers
    // playback: the doubleword at pcur (cur) and the one after it (nxt);
    // record: the doubleword being filled (rb) and one waiting to be written (wq)
    logic        cur_v, nxt_v, wq_v;
    logic [28:0] cur_a, nxt_a, wq_a, rb_a;
    logic [63:0] cur_d, nxt_d, wq_d, rb_d;
    logic [7:0]  wq_be, rb_be;
    logic [1:0]  d_which;                   // the request in flight: 0 write, 1 cur, 2 nxt
    logic        tick_pend;
    logic        rc_drain;                  // record stopped, RC kept until its last write is done
    logic [31:0] prev_raw;
    logic signed [15:0] s_l, s_r;
    logic        s_new, s_on;

    assign irq = ie && pn && rn;

    always_ff @(posedge clk) begin
        logic [32:0] a_n;
        logic [31:0] raw, rec;
        logic [2:0]  o;
        logic [31:0] pcur_n, rcur_n, w;
        s_new <= 1'b0;
        if (rst) begin
            reset_b <= 1'b1; ctl_c <= 1'b0; cntl <= 18'd0; gain <= 28'd0; ie <= 1'b0;
            pn <= 1'b1; pc <= 1'b0; rn <= 1'b1; rc <= 1'b0; ov <= 1'b0; po <= 2'd0;
            pnxt <= 20'd0; rnxt <= 20'd0; pcur <= 32'd0; rcur <= 32'd0; c_cnt <= '0; acc <= 32'd0;
            cur_v <= 1'b0; nxt_v <= 1'b0; wq_v <= 1'b0; rb_be <= 8'd0; dma_req <= 1'b0;
            tick_pend <= 1'b0; prev_raw <= 32'd0; s_on <= 1'b0; s_l <= 16'sd0; s_r <= 16'sd0; rc_drain <= 1'b0;
        end else begin
            // ---- the codec's clock: a sample period while in data mode
            a_n = {1'b0, acc} + {1'b0, rate_step(cntl[4:0])};
            if (data_mode) begin
                acc <= a_n[31:0];
                if (a_n[32]) tick_pend <= 1'b1;
            end
            if (ctl_c) begin
                if (c_cnt == '0) ctl_c <= 1'b0; else c_cnt <= c_cnt - 1'd1;
            end
            // the record DMA has finished once its last doubleword is in memory
            if (rc_drain && !wq_v) begin rc <= 1'b0; rc_drain <= 1'b0; end

            // ---- a DMA transfer finished
            if (dma_req && dma_ack) begin
                dma_req <= 1'b0;
                case (d_which)
                    2'd0: wq_v <= 1'b0;
                    2'd1: begin cur_v <= 1'b1; cur_a <= dma_addr[31:3]; cur_d <= dma_rdata; end
                    default: begin nxt_v <= 1'b1; nxt_a <= dma_addr[31:3]; nxt_d <= dma_rdata; end
                endcase
            end else if (tick_pend && !(pc && !(cur_v && cur_a == pcur[31:3]))) begin
                // ---- a sample period (not in the cycle a transfer lands, and
                // not before playback's doubleword is there: at the start of
                // the DMA the first one is still being fetched -- the real
                // chip fills its FIFO first)
                tick_pend <= 1'b0;
                raw = silence();
                if (pc) begin
                    o = pcur[2:0];
                    if (cur_v && cur_a == pcur[31:3])
                        for (int i = 0; i < 4; i++)
                            if (3'(i) < bps && int'(o) + i < 8) raw[8 * (int'(bps) - 1 - i) +: 8] = cur_d[63 - 8 * (int'(o) + i) -: 8];
                    pcur_n = pcur + {29'd0, bps};
                    if (pcur_n[2:0] == 3'd0 && nxt_v && nxt_a == pcur_n[31:3]) begin
                        cur_v <= 1'b1; cur_a <= nxt_a; cur_d <= nxt_d; nxt_v <= 1'b0;
                    end
                    if (pcur_n[12] != pcur[12]) begin                 // the end of the page
                        if (!pn) begin pcur <= {pnxt, 12'd0}; pn <= 1'b1; end
                        else begin pcur <= pcur_n; pc <= 1'b0; end
                    end else pcur <= pcur_n;
                end
                // the output sample
                s_new <= 1'b1; s_on <= pc;
                if (df == 2'd0) begin
                    s_l <= st ? $signed(raw[31:16]) : $signed(raw[15:0]);
                    s_r <= $signed(raw[15:0]);
                end else begin
                    s_l <= dec8(st ? raw[15:8] : raw[7:0]);
                    s_r <= dec8(raw[7:0]);
                end
                // the record side
                rec = ls == 2'd1 || ls == 2'd3 ? raw : ls == 2'd2 ? prev_raw : silence();
                prev_raw <= raw;
                if (rc && !rc_drain) begin
                    logic [63:0] d;
                    logic [7:0]  b;
                    o = rcur[2:0];
                    d = rb_d; b = rb_be;
                    for (int i = 0; i < 4; i++)
                        if (3'(i) < bps && int'(o) + i < 8) begin
                            d[63 - 8 * (int'(o) + i) -: 8] = rec[8 * (int'(bps) - 1 - i) +: 8];
                            b[7 - (int'(o) + i)] = 1'b1;
                        end
                    rcur_n = rcur + {29'd0, bps};
                    if (rcur_n[2:0] == 3'd0 || rcur_n[12] != rcur[12]) begin
                        // the doubleword is complete: to the write slot (a
                        // still-pending older one is overwritten; at <= 48
                        // kHz a write has two sample periods to finish)
                        wq_v <= 1'b1; wq_a <= rcur[31:3]; wq_d <= d; wq_be <= b; rb_be <= 8'd0;
                    end else begin rb_d <= d; rb_be <= b; end
                    if (rcur_n[12] != rcur[12]) begin
                        if (!rn) begin rcur <= {rnxt, 12'd0}; rn <= 1'b1; end
                        else begin rcur <= rcur_n; rc_drain <= 1'b1; end
                    end else rcur <= rcur_n;
                end
            end else if (!dma_req) begin
                // ---- the next transfer: a record write, then the current
                // playback doubleword, then the one after it (not across a page)
                if (wq_v) begin
                    dma_req <= 1'b1; dma_we <= 1'b1; dma_addr <= {wq_a, 3'd0}; dma_be <= wq_be; dma_wdata <= wq_d;
                    d_which <= 2'd0;
                end else if (pc && !(cur_v && cur_a == pcur[31:3])) begin
                    dma_req <= 1'b1; dma_we <= 1'b0; dma_addr <= {pcur[31:3], 3'd0}; dma_be <= 8'hFF;
                    d_which <= 2'd1;
                end else if (pc && pcur[11:3] != 9'h1FF && !(nxt_v && nxt_a == pcur[31:3] + 29'd1)) begin
                    dma_req <= 1'b1; dma_we <= 1'b0; dma_addr <= {pcur[31:3] + 29'd1, 3'd0}; dma_be <= 8'hFF;
                    d_which <= 2'd2;
                end
            end

            // ---- register writes
            if (req && we) case (addr[11:2])
                10'h01: if (be[0]) reset_b <= wdata[0];
                10'h02: begin
                    w = bmerge({14'd0, cntl}, wdata, be); cntl <= w[17:0];
                    ctl_c <= 1'b1; c_cnt <= CW'(C_CLKS);
                end
                10'h03: begin w = bmerge({4'd0, gain}, wdata, be); gain <= w[27:0]; end
                10'h04: begin pnxt <= wdata[31:12]; pn <= 1'b0; end
                10'h05: begin pcur <= wdata; end
                10'h06: begin
                    rnxt <= wdata[31:12]; rn <= 1'b0;
                    // the second address starts both DMAs when they are stopped
                    if (!rc) begin rcur <= {wdata[31:12], 12'd0}; rc <= 1'b1; rn <= 1'b1; rb_be <= 8'd0; end
                    if (!pc && !pn) begin pcur <= {pnxt, 12'd0}; pc <= 1'b1; pn <= 1'b1; end
                end
                10'h07: rcur <= wdata;
                10'h08: if (be[3]) ie <= wdata[31];
                10'h09: if (be[0] && !wdata[0]) ov <= 1'b0;
                10'h0A: if (be[0]) po <= wdata[3:2];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ reads
    always_ff @(posedge clk) begin
        if (req && !we) case (addr[11:2])
            10'h00: rdata <= 32'h0014_0000;
            10'h01: rdata <= {31'd0, reset_b};
            10'h02: rdata <= {ctl_c, 13'd0, cntl};
            10'h03: rdata <= {4'd0, gain};
            10'h04: rdata <= {pnxt, 12'd0};
            10'h05: rdata <= pcur;
            10'h06: rdata <= {rnxt, 12'd0};
            10'h07: rdata <= rcur;
            10'h08: rdata <= {ie, 21'd0, pn, pc, 6'd0, rn, rc};
            10'h09: rdata <= {31'd0, ov};
            10'h0A: rdata <= {28'd0, po, po};
            10'h0F: rdata <= {31'd0, data_mode ? acc[25] : 1'b1};
            default: rdata <= 32'd0;
        endcase
    end

    // ------------------------------------------------------------ the output
    logic signed [31:0] m_l, m_r;
    logic        o_on, o_new;
    always_ff @(posedge clk) begin
        o_new <= s_new;
        o_on <= s_on && data_mode && |gain[27:25];
        m_l <= s_l * $signed({1'b0, atten(gain[11:6])});
        m_r <= s_r * $signed({1'b0, atten(gain[5:0])});
        out_new <= o_new && !rst;
        if (rst) begin out_l <= 16'sd0; out_r <= 16'sd0; end
        else if (o_new) begin
            out_l <= o_on ? m_l[30:15] : 16'sd0;
            out_r <= o_on ? m_r[30:15] : 16'sd0;
        end
    end
endmodule
