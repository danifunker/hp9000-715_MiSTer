// LASI's PC floppy (Lasi ERS ch. 10; docs/review/10-hpux-fdc.md): the
// WD37C65C's registers in LASI page A (0xF010A000) and LASI's floppy DMA
// registers in page D (0xF010D000), with NO DRIVE attached (STUBS S-028).
//
// Page A, byte registers (each byte lane of the word reads the same):
//   +0x000 W   unit reset (any write; Linux writes ~0, HP-UX 0)
//   +0x004 R/W FDC data (765 command bytes in, result bytes out)
//   +0x008 R   FDC main status (MSR: 7 RQM, 6 DIO, 5 NDM, 4 CB, 3:0 drive busy)
//   +0x014 R/W LASI FIFO data (4 bytes; slave writes need WE)
//   +0x018 R/W LASI floppy control (0 WE mem->FDC, 1 RE FDC->mem, 2 FDC_IE, 3 DMA_IE)
//   +0x01C R   LASI floppy status (0 FULL, 1 EMPTY, 2 DMA_IRQ; 3 = high-density
//              sense, HP-UX's fdc_check_media reads it: 0 here)
//   +0x020 W   FDC control (CCR, data rate; ignored) / R: DIR, bit 7 disk change (1: no disk)
//   +0x040 R/W FDC operations (DOR: 1:0 drive, 2 !reset, 3 DMA/INT enable, 7:4 motors)
// Page D, words:
//   +0x000     FDAR: 31:12 page, 11:2 word offset (R/W), 0 DMA_EN (read only)
//   +0x004     DMA enable: 0 DMA_EN (R/W), the rest FDAR's (read only)
//
// The 765 (as QEMU's 82077 model, hw/block/fdc.c, for INT): reset (DOR bit
// 2 low, a unit reset, IORESET bit 5) raises INT on release with four
// "ready changed" statuses; SENSE INTERRUPT STATUS returns the next one
// (0xC0 | drive), or a finished SEEK/RECALIBRATE's ST0 and PCN, or 0x80, and
// drops INT; a finished seek raises INT and discards what is left of the
// reset statuses. With no drive: RECALIBRATE steps 77 times at SPECIFY's step
// rate and ends with ST0 = 0x70 | drive (abnormal termination, seek end,
// equipment check: HP-UX 11i's pflop probe then decides there is no drive);
// SEEK steps |NCN - PCN| times and ends normally; READ/WRITE DATA, READ ID,
// FORMAT, READ TRACK and the SCANs end at once with ST0 = 0x40, ST1 = 0x01
// (missing address mark) and INT; SENSE DRIVE STATUS answers ST3 = 0x20
// (ready) | head | drive; SPECIFY sets the step rate; everything else
// (VERSION, CONFIGURE ...: a WD37C65C is a 765A) answers 0x80. No data
// phase (S-028). INT reaches LASI only with DOR bit 3, as on a PC.
//
// The DMA side (ERS 10.2): with DMA_EN, LASI keeps the FIFO full from memory
// (WE) or empty to memory (RE), one GSC word per byte, the byte in the
// word's most significant lane, the word offset counting up and wrapping in
// the page; DMA_IRQ (status bit 2) is set while the offset is 0x1FF or 0x3FF
// and held while DMA_IE is 1. The interrupt (LASI bit 20) is FDC INT with
// FDC_IE or DMA_IRQ with DMA_IE.
module lasi_fdc #(
    parameter int CLK_HZ   = 64_000_000,
    parameter bit SIM_FAST = 1'b0          // a step takes (16 - SRT) x 64 clocks instead of milliseconds
) (
    input  logic        clk,
    input  logic        rst,               // machine reset or IORESET bit 5 (ext) clear
    // registers: page A (pd = 0) or D (pd = 1); rdata the cycle after req
    input  logic        req, we, pd,
    input  logic [11:0] addr,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        irq,
    // DMA: one doubleword, held until dma_ack ([7] of dma_be = byte offset 0)
    output logic        dma_req, dma_we,
    output logic [31:0] dma_addr,
    output logic [7:0]  dma_be,
    output logic [63:0] dma_wdata,
    input  logic        dma_ack,
    input  logic [63:0] dma_rdata
);
    localparam int MS_CLKS = SIM_FAST ? 64 : CLK_HZ / 1000;

    // byte lane of a one-byte access (be[3] = byte 0)
    logic [1:0] lane;
    always_comb casez (be)
        4'b1???: lane = 2'd0;
        4'b01??: lane = 2'd1;
        4'b001?: lane = 2'd2;
        default: lane = 2'd3;
    endcase
    wire [7:0] wbyte = wdata[31 - 8*lane -: 8];
    wire       a_sel = req && !pd;
    wire       d_sel = req && pd;
    wire       w_reset = a_sel && we && addr[11:2] == 10'd0;   // +0x000: unit reset
    wire       w_data  = a_sel && we && addr[11:2] == 10'd1;
    wire       r_data  = a_sel && !we && addr[11:2] == 10'd1;
    wire       w_fifo  = a_sel && we && addr[11:2] == 10'd5;
    wire       r_fifo  = a_sel && !we && addr[11:2] == 10'd5;
    wire       w_ctl   = a_sel && we && addr[11:2] == 10'd6;
    wire       w_dor   = a_sel && we && addr[11:2] == 10'd16;
    wire       urst    = rst || w_reset;

    // =================================================== the 765 (no drive)
    localparam logic [1:0] PH_IDLE = 2'd0, PH_CMD = 2'd1, PH_RES = 2'd2;
    localparam logic [1:0] RT_INV = 2'd0, RT_SI = 2'd1, RT_SD = 2'd2, RT_RW = 2'd3;
    logic [7:0] dor;
    logic       dor2_q;
    logic [1:0] phase, rtype;
    logic [7:0] cmd [6];                    // opcode, drive/head, C, H, R, N (later bytes dropped)
    logic [3:0] ccnt, cneed;                // command bytes received / needed
    logic [2:0] ridx, rlen;                 // result byte / count
    logic       rint;                       // this result phase raised INT (cleared by its last byte)
    logic [7:0] si_st0, si_pcn;             // SENSE INTERRUPT STATUS's answer
    logic [3:0] srt;                        // SPECIFY's step rate
    logic [7:0] pcn [4];
    logic       int_pend;
    logic [2:0] reset_sensei;
    logic [7:0] sk_st0;                     // a finished seek's ST0
    logic [1:0] sk_drv;
    logic       sk_busy, sk_recal;
    logic [7:0] sk_steps, sk_ncn;
    logic [16:0] ms_div;
    logic [4:0]  st_ms;                     // milliseconds left in this step

    // bytes a command takes, by opcode[4:0] (0 = invalid: one result byte 0x80)
    function automatic logic [3:0] cmd_len(input logic [4:0] op);
        case (op)
            5'h03: return 4'd3;                                     // SPECIFY
            5'h04, 5'h07, 5'h0A: return 4'd2;                       // SENSE DRIVE, RECALIBRATE, READ ID
            5'h08: return 4'd1;                                     // SENSE INTERRUPT STATUS
            5'h0F: return 4'd3;                                     // SEEK
            5'h0D: return 4'd6;                                     // FORMAT TRACK
            5'h02, 5'h05, 5'h06, 5'h09, 5'h0C, 5'h11, 5'h19, 5'h1D: return 4'd9;
            default: return 4'd0;
        endcase
    endfunction

    // the current result byte
    logic [7:0] res;
    always_comb case (rtype)
        RT_INV: res = 8'h80;
        RT_SI:  res = ridx == 3'd0 ? si_st0 : si_pcn;
        RT_SD:  res = {5'b00100, cmd[1][2:0]};                 // ST3: ready, head, drive
        default: case (ridx)
            3'd0: res = {5'b01000, cmd[1][2:0]};               // ST0: abnormal termination
            3'd1: res = 8'h01;                                  // ST1: missing address mark
            3'd2: res = 8'h00;                                  // ST2
            default: res = cmd[ridx - 3'd1];                    // C, H, R, N as given
        endcase
    endcase

    wire fdc_rst = urst || !dor[2];
    wire rqm = !fdc_rst && dor2_q;
    wire [7:0] msr = !rqm ? 8'h00 : {1'b1, phase == PH_RES, 1'b0, phase != PH_IDLE,
                                     sk_busy ? 4'(1) << sk_drv : 4'd0};
    wire fdc_int = int_pend && dor[3];

    always_ff @(posedge clk) begin
        if (urst) dor <= 8'd0;
        else if (w_dor) dor <= wbyte;
        dor2_q <= !fdc_rst;

        if (fdc_rst) begin
            phase <= PH_IDLE; ccnt <= 4'd0; ridx <= 3'd0; rint <= 1'b0;
            int_pend <= 1'b0; reset_sensei <= 3'd0; sk_busy <= 1'b0;
            for (int i = 0; i < 4; i++) pcn[i] <= 8'd0;
            if (urst) srt <= 4'd0;
        end else begin
            // release from reset: INT with four "ready changed" statuses
            if (!dor2_q) begin int_pend <= 1'b1; reset_sensei <= 3'd4; end

            // the seek in progress, a step every (16 - SRT) ms
            if (sk_busy) begin
                if (ms_div != 17'd0) ms_div <= ms_div - 17'd1;
                else begin
                    ms_div <= 17'(MS_CLKS - 1);
                    if (st_ms > 5'd1) st_ms <= st_ms - 5'd1;
                    else if (sk_steps > 8'd1) begin
                        st_ms <= 5'd16 - {1'b0, srt}; sk_steps <= sk_steps - 8'd1;
                    end else begin
                        sk_busy <= 1'b0;
                        pcn[sk_drv] <= sk_recal ? 8'd0 : sk_ncn;
                        sk_st0[7:4] <= sk_recal ? 4'h7 : 4'h2;   // equipment check / seek end
                        int_pend <= 1'b1; reset_sensei <= 3'd0;
                    end
                end
            end

            // result bytes out
            if (r_data && phase == PH_RES) begin
                if (ridx == rlen - 3'd1) begin
                    phase <= PH_IDLE; ridx <= 3'd0;
                    if (rint) begin int_pend <= 1'b0; rint <= 1'b0; end
                end else ridx <= ridx + 3'd1;
            end

            // command bytes in
            if (w_data && phase != PH_RES) begin
                logic [3:0] need;
                need = phase == PH_IDLE ? cmd_len(wbyte[4:0]) : cneed;
                if (phase == PH_IDLE) begin cmd[0] <= wbyte; cneed <= need; end
                else if (ccnt < 4'd6) cmd[ccnt[2:0]] <= wbyte;
                if (ccnt + 4'd1 < need) begin
                    phase <= PH_CMD; ccnt <= ccnt + 4'd1;
                end else begin
                    // the command is complete: execute it
                    logic [4:0] op;
                    logic [7:0] b1, b2;
                    op = phase == PH_IDLE ? wbyte[4:0] : cmd[0][4:0];
                    b1 = ccnt == 4'd1 ? wbyte : cmd[1];
                    b2 = wbyte;                                  // the last byte (SEEK's NCN, SPECIFY's 2nd)
                    ccnt <= 4'd0; ridx <= 3'd0; phase <= PH_RES;
                    case (op)
                        5'h03: begin srt <= b1[7:4]; phase <= PH_IDLE; end
                        5'h04: begin rtype <= RT_SD; rlen <= 3'd1; end
                        5'h07, 5'h0F: begin
                            phase <= PH_IDLE;
                            sk_busy <= 1'b1; sk_drv <= b1[1:0]; sk_st0[3:0] <= {1'b0, b1[2:0]};
                            sk_recal <= op == 5'h07; sk_ncn <= b2;
                            ms_div <= 17'(MS_CLKS - 1); st_ms <= 5'd16 - {1'b0, srt};
                            if (op == 5'h07) sk_steps <= 8'd77;
                            else sk_steps <= b2 > pcn[b1[1:0]] ? b2 - pcn[b1[1:0]] : pcn[b1[1:0]] - b2;
                            if (op == 5'h0F && b2 == pcn[b1[1:0]]) sk_steps <= 8'd1;
                        end
                        5'h08: begin
                            rtype <= RT_SI;
                            if (reset_sensei != 3'd0) begin
                                si_st0 <= {6'b110000, 2'(3'd4 - reset_sensei)};
                                si_pcn <= pcn[2'(3'd4 - reset_sensei)];
                                reset_sensei <= reset_sensei - 3'd1;
                                rlen <= 3'd2; int_pend <= 1'b0;
                            end else if (int_pend) begin
                                si_st0 <= sk_st0; si_pcn <= pcn[sk_drv];
                                rlen <= 3'd2; int_pend <= 1'b0;
                            end else rlen <= 3'd1;           // no interrupt pending: invalid
                            if (reset_sensei == 3'd0 && !int_pend) rtype <= RT_INV;
                        end
                        5'h02, 5'h05, 5'h06, 5'h09, 5'h0A, 5'h0C, 5'h0D, 5'h11, 5'h19, 5'h1D: begin
                            rtype <= RT_RW; rlen <= 3'd7;
                            int_pend <= 1'b1; reset_sensei <= 3'd0; rint <= 1'b1;
                        end
                        default: begin rtype <= RT_INV; rlen <= 3'd1; end
                    endcase
                end
            end
        end
    end

    // ===================================================== LASI's wrapper
    logic [3:0]  ctl;                       // 0 WE, 1 RE, 2 FDC_IE, 3 DMA_IE
    logic [7:0]  fifo [4];
    logic [1:0]  f_rd, f_wr;
    logic [2:0]  f_cnt;
    logic [19:0] fd_page;
    logic [9:0]  fd_off;
    logic        dma_en, dirq;
    wire  f_full = f_cnt == 3'd4, f_empty = f_cnt == 3'd0;
    wire  hit = fd_off == 10'h1FF || fd_off == 10'h3FF;

    // the FIFO: at most one push and one pop a cycle (the DMA wins over the CPU)
    wire  d_push = dma_req && dma_ack && !dma_we;
    wire  d_pop  = dma_req && dma_ack && dma_we;
    wire  push = !f_full && (d_push || (w_fifo && ctl[0]));
    wire  pop  = !f_empty && (d_pop || r_fifo);
    wire [7:0] push_byte = d_push ? (dma_addr[2] ? dma_rdata[31:24] : dma_rdata[63:56]) : wbyte;

    always_ff @(posedge clk) begin
        if (urst) begin
            ctl <= 4'd0; f_rd <= 2'd0; f_wr <= 2'd0; f_cnt <= 3'd0;
            fd_page <= 20'd0; fd_off <= 10'd0; dma_en <= 1'b0; dirq <= 1'b0; dma_req <= 1'b0;
        end else begin
            if (w_ctl) ctl <= wbyte[3:0];
            if (push) begin fifo[f_wr] <= push_byte; f_wr <= f_wr + 2'd1; end
            if (pop) f_rd <= f_rd + 2'd1;
            f_cnt <= f_cnt + {2'd0, push} - {2'd0, pop};
            dirq <= hit || (dirq && ctl[3]);

            if (d_sel && we && addr[11:2] == 10'd0) begin fd_page <= wdata[31:12]; fd_off <= wdata[11:2]; end
            if (d_sel && we && addr[11:2] == 10'd1) dma_en <= wdata[0];

            // the DMA: one word at a time, the offset counting on each one done
            if (dma_req && dma_ack) begin
                dma_req <= 1'b0;
                fd_off <= fd_off + 10'd1;
            end else if (!dma_req && dma_en) begin
                if (ctl[0] && !ctl[1] && f_cnt < 3'd4 && !(w_fifo && ctl[0])) begin
                    dma_req <= 1'b1; dma_we <= 1'b0;
                end else if (ctl[1] && !ctl[0] && !f_empty && !(r_fifo && f_cnt == 3'd1)) begin
                    dma_req <= 1'b1; dma_we <= 1'b1;
                end
            end
        end
    end
    assign dma_addr  = {fd_page, fd_off, 2'b00};
    assign dma_be    = fd_off[0] ? 8'h0F : 8'hF0;
    assign dma_wdata = {2{fifo[f_rd], 24'd0}};
    assign irq = (fdc_int && ctl[2]) || (dirq && ctl[3]);

    // ======================================================== register reads
    always_ff @(posedge clk) begin
        logic [7:0] b;
        b = 8'd0;
        case (addr[11:2])
            10'd1:  b = phase == PH_RES ? res : 8'd0;
            10'd2:  b = msr;
            10'd5:  b = fifo[f_rd];
            10'd6:  b = {4'd0, ctl};
            10'd7:  b = {5'd0, dirq, f_empty, f_full};
            10'd8:  b = 8'h80;                                  // DIR: disk changed (no disk)
            10'd16: b = dor;
            default: ;
        endcase
        if (req) rdata <= pd ? (addr[11:3] == 9'd0 ? {fd_page, fd_off, 1'b0, dma_en} : 32'd0)  // FDAR, enable
                                 : {4{b}};
    end
endmodule
