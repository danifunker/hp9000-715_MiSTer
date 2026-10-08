// The NCR 53C710 SCSI I/O processor inside LASI (page 6, F010_6000;
// docs/review/06d; the 53C710 data manual, chapters 4 and 5; HW 4.5).
//
// Host side: LASI wires the chip in BIG_LIT mode, so the 32-bit word at
// +0x100 + 4k holds the little-endian registers 4k..4k+3 with register 4k in
// bits 7:0 -- a GSC byte enable be[i] selects register 4k + i. +0x000 is the
// unit's reset (written by the ROM, never by HP-UX).
//
// SCRIPTS: block moves (direct, indirect, table indirect), SELECT (with
// ATN, relative / table-indirect forms), WAIT DISCONNECT, WAIT RESELECT
// (SIGP takes the alternate address, before or during the wait), SET/CLEAR
// ATN/ACK/TARGET/CARRY, register read-modify-write and moves to/from SFBR
// (= / OR / AND / ADD with carry), JUMP/CALL/RETURN/INT with phase, data and
// carry compares and wait-for-valid-phase, memory-to-memory moves (also to
// and from the chip's own registers). Initiator mode only (target-mode
// opcodes are illegal), no low-level mode, no single step, no watchdog,
// DWT ignored (STUBS S-021).
//
// Data moves go straight between the SCSI byte stream and memory through a
// one-doubleword buffer (DMA port: one doubleword per transaction), so the
// DMA FIFO is empty whenever the chip halts: DSTAT.DFE reads 1 then, and
// DFIFO's byte counter follows DBC (HP-UX's residual = (DFIFO - DBC) & 0x7F
// is 0). The FIFO's lanes exist for the host's diagnostic access (CTEST6
// with CTEST4.FBL, flags in CTEST1).
//
// The SCSI bus is the byte-level one of rtl/scsi/scsi_targets.sv.
module ncr53c710 #(
    parameter int STO_CLKS = 16_000_000     // selection timeout (250 ms at 64 MHz)
) (
    input  logic        clk,
    input  logic        rst,                // machine reset or LASI IORESET bit 0
    // host (LASI page 6)
    input  logic        req,
    input  logic        we,
    input  logic [11:0] addr,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,              // valid the cycle after req (the LASI register reads)
    output logic        irq,
    // DMA (rtl/mioc.sv dma_*): one doubleword, held until dma_ack
    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,
    output logic [7:0]  dma_be,             // [7] = byte offset 0
    output logic [63:0] dma_wdata,
    input  logic        dma_ack,
    input  logic        dma_err,
    input  logic [63:0] dma_rdata,
    // the SCSI bus
    output logic        sb_sel,
    output logic [2:0]  sb_sel_id,
    output logic        sb_sel_atn,
    input  logic        sb_sel_done,
    input  logic        sb_sel_fail,
    input  logic        sb_bsy,
    input  logic        sb_req,
    input  logic [2:0]  sb_phase,
    input  logic [7:0]  sb_tdata,
    output logic        sb_ack,
    output logic [7:0]  sb_idata,
    output logic        sb_ackhold,
    output logic        sb_atn,
    output logic        sb_rst
);
    // --------------------------------------------------------- registers
    logic [7:0]  scntl0, scntl1, sdid, sien, scid, sxfer, sodl, socl, sfbr, sidl, sbcl_w;
    logic [7:0]  dstat_st, sstat0_st;          // interrupt status bits (DFE separately)
    logic [7:0]  dstat_pend, sstat0_pend;      // stacked
    logic [7:0]  sstat1_flags;
    logic [2:0]  latched_phase;                // SSTAT2 phase: latched at REQ
    logic [31:0] dsa, temp, dnad, dsp, dsps, scratch;
    logic [7:0]  ctest0, ctest4, ctest5, ctest7, ctest8_w, lcrc;
    logic [23:0] dbc;
    logic [7:0]  dcmd;
    logic [7:0]  dmode, dien, dwt, dcntl;
    logic        sigp, abrt_req, srst, carry;
    logic        con;                          // connected
    logic        bsy_q;                        // BSY last cycle (CON drops on its falling edge)
    logic        bad_par_q;                    // forcing bad parity onto the bus last cycle
    logic        target_mode;
    // diagnostic DMA FIFO: 4 lanes x 16 bytes (+ parity)
    logic [8:0]  dff [4][16];
    logic [4:0]  dff_n [4];
    logic [3:0]  dff_rd [4], dff_wr [4];
    logic        dfp_latch;
    logic [6:0]  dfifo_cnt;                    // byte-offset counter

    wire  [31:0] adder = dsa + dbc_ext;        // the ADDER register: an informative sum
    wire  [31:0] dbc_ext = {8'd0, dbc};
    wire         dfe = (dff_n[0] | dff_n[1] | dff_n[2] | dff_n[3]) == 5'd0 && !wb_valid;
    wire  [7:0]  dstat = {dfe, dstat_st[6:0]};
    wire         sip = sstat0_st != 8'd0;
    wire         dip = dstat_st[6:0] != 7'd0;
    wire  [7:0]  istat = {abrt_req, srst, sigp, 1'b0, con, 1'b0, sip, dip};
    wire  [7:0]  sstat1 = {sstat1_flags[7:2], sb_rst, 1'b0};
    wire  [7:0]  sstat2 = {4'd0, 1'b0, latched_phase};
    wire  [7:0]  sbcl_r = {sb_req, sb_ack, sb_bsy, sb_sel, sb_atn, sb_phase};
    wire  [7:0]  sbdl = (scntl1[6] || ctest4[4]) ? sodl : (sb_req ? sb_tdata : 8'h00);
    wire  [7:0]  ctest1 = {dff_n[3] == 0, dff_n[2] == 0, dff_n[1] == 0, dff_n[0] == 0,
                           dff_n[3] == 16, dff_n[2] == 16, dff_n[1] == 16, dff_n[0] == 16};
    wire  [7:0]  ctest2 = {1'b0, sigp, 1'b1, 1'b0, dfp_latch, 1'b0, 1'b0, 1'b1};
    wire  [7:0]  ctest8 = {4'h2, ctest8_w[3], 1'b0, ctest8_w[1:0]};   // revision 2

    assign irq = ((sstat0_st & sien) != 8'd0) || ((dstat_st[6:0] & dien[6:0]) != 7'd0);

    // register read (LE address), and whether reading it has a side effect
    function automatic logic [7:0] reg_rd(input logic [5:0] a);
        case (a)
            6'h00: return scntl0;   6'h01: return {scntl1[7:5], con, scntl1[3:0]};
            6'h02: return sdid;     6'h03: return sien;
            6'h04: return scid;     6'h05: return sxfer;
            6'h06: return sodl;     6'h07: return socl;
            6'h08: return sfbr;     6'h09: return sidl;
            6'h0A: return sbdl;     6'h0B: return sbcl_r;
            6'h0C: return dstat;    6'h0D: return sstat0_st;
            6'h0E: return sstat1;   6'h0F: return sstat2;
            6'h10: return dsa[7:0]; 6'h11: return dsa[15:8]; 6'h12: return dsa[23:16]; 6'h13: return dsa[31:24];
            6'h14: return ctest0;   6'h15: return ctest1;
            6'h16: return ctest2;   6'h17: return 8'h00;                   // CTEST3: SCSI FIFO (empty)
            6'h18: return ctest4;   6'h19: return ctest5;
            6'h1A: return dff[ctest4[1:0]][dff_rd[ctest4[1:0]]][7:0];      // CTEST6: the FIFO lane's bottom byte
            6'h1B: return ctest7;
            6'h1C: return temp[7:0]; 6'h1D: return temp[15:8]; 6'h1E: return temp[23:16]; 6'h1F: return temp[31:24];
            6'h20: return {1'b0, dfifo_cnt};
            6'h21: return istat;    6'h22: return ctest8;   6'h23: return lcrc;
            6'h24: return dbc[7:0]; 6'h25: return dbc[15:8]; 6'h26: return dbc[23:16]; 6'h27: return dcmd;
            6'h28: return dnad[7:0]; 6'h29: return dnad[15:8]; 6'h2A: return dnad[23:16]; 6'h2B: return dnad[31:24];
            6'h2C: return dsp[7:0]; 6'h2D: return dsp[15:8]; 6'h2E: return dsp[23:16]; 6'h2F: return dsp[31:24];
            6'h30: return dsps[7:0]; 6'h31: return dsps[15:8]; 6'h32: return dsps[23:16]; 6'h33: return dsps[31:24];
            6'h34: return scratch[7:0]; 6'h35: return scratch[15:8]; 6'h36: return scratch[23:16]; 6'h37: return scratch[31:24];
            6'h38: return dmode;    6'h39: return dien;     6'h3A: return dwt;   6'h3B: return dcntl;
            6'h3C: return adder[7:0]; 6'h3D: return adder[15:8]; 6'h3E: return adder[23:16]; 6'h3F: return adder[31:24];
            default: return 8'h00;
        endcase
    endfunction

    // ------------------------------------------------- the SCRIPTS engine
    typedef enum logic [4:0] {
        E_IDLE, E_FETCH, E_DECODE, E_IND,
        E_BM_WAIT, E_BM_BYTE, E_BM_RD, E_BM_GIVE, E_BM_END,
        E_SEL, E_SEL_WAIT, E_STO, E_WDISC, E_WRESEL,
        E_TC_WAIT, E_TC_EVAL,
        E_MM_RD, E_MM_WR, E_FLUSH, E_INT, E_FAULT
    } est_e;
    est_e est;

    logic [2:0]  fcnt;                // fetch word count
    logic [31:0] ins0;                // DCMD|DBC as fetched
    logic        first_byte;
    logic        fl_next;             // after E_FLUSH: fetch the next instruction (else halt)
    logic [31:0] sto_cnt;
    logic        mm_regsrc, mm_regdst;
    // the one-doubleword write buffer and read cache
    logic        wb_valid;
    logic [31:3] wb_addr;
    logic [63:0] wb_data;
    logic [7:0]  wb_be;
    logic        rc_valid;
    logic [31:3] rc_addr;
    logic [63:0] rc_data;
    // DMA engine
    typedef enum logic [1:0] { D_IDLE, D_BUSY } dst_e;
    dst_e dmst;
    logic        d_go, d_done, d_err;      // pulse in, pulse out
    logic        d_we;
    logic [31:0] d_addr;
    logic [7:0]  d_be;
    logic [63:0] d_wdata, d_rdata;


    wire [7:0] reg_imm = ins0[15:8];
    wire [5:0] reg_adr = ins0[21:16];

    function automatic logic [31:0] sext24(input logic [23:0] v);
        return {{8{v[23]}}, v};
    endfunction

    // byte k (0 = lowest address) of a big-endian doubleword
    function automatic logic [7:0] dw_byte(input logic [63:0] d, input logic [2:0] k);
        return d[63 - 8*k -: 8];
    endfunction

    // the doubleword DMA engine
    always_ff @(posedge clk) begin
        d_done <= 1'b0; d_err <= 1'b0;
        if (rst || srst) begin dmst <= D_IDLE; dma_req <= 1'b0; end
        else case (dmst)
            D_IDLE: if (d_go) begin
                dma_req <= 1'b1; dma_we <= d_we; dma_addr <= {d_addr[31:3], 3'd0}; dma_be <= d_be;
                dma_wdata <= d_wdata; dmst <= D_BUSY;
            end
            default: if (dma_ack) begin
                dma_req <= 1'b0; d_rdata <= dma_rdata; d_done <= 1'b1; d_err <= dma_err; dmst <= D_IDLE;
            end
        endcase
    end
    wire d_idle = dmst == D_IDLE && !d_go && !d_done;

    // ---------------------------------------------------------- the FSM

    // the host's register access: the read data and the write strobes are
    // combined with the engine in one always block below
    wire        h_reg = addr[11:6] == 6'b000100;     // +0x100-0x13F
    wire [3:0]  h_k = addr[5:2];

    always_ff @(posedge clk) begin
        logic [7:0] set_s0, set_ds;
        logic       pop_rd;
        set_s0 = 8'd0; set_ds = 8'd0;
        sb_sel <= 1'b0; sb_ack <= 1'b0;
        d_go <= 1'b0;
        pop_rd = 1'b0;

        if (rst || srst) begin
            scntl0 <= 8'hC0; scntl1 <= 8'd0; sdid <= 8'd0; sien <= 8'd0; scid <= 8'd0; sxfer <= 8'd0;
            sodl <= 8'd0; socl <= 8'd0; sfbr <= 8'd0; sidl <= 8'd0; sbcl_w <= 8'd0;
            dstat_st <= 8'd0; sstat0_st <= 8'd0; dstat_pend <= 8'd0; sstat0_pend <= 8'd0; sstat1_flags <= 8'd0;
            latched_phase <= 3'd0; dsa <= 32'd0; temp <= 32'd0; dnad <= 32'd0; dsp <= 32'd0; dsps <= 32'd0;
            scratch <= 32'd0; ctest0 <= 8'd0; ctest4 <= 8'd0; ctest5 <= 8'd0; ctest7 <= 8'd0; ctest8_w <= 8'd0;
            lcrc <= 8'd0; dbc <= 24'd0; dcmd <= 8'd0; dmode <= 8'd0; dien <= 8'd0; dwt <= 8'd0;
            if (rst) dcntl <= 8'd0; else dcntl <= dcntl & 8'h20;          // the soft reset keeps EA
            if (rst) srst <= 1'b0;
            sigp <= 1'b0; abrt_req <= 1'b0; carry <= 1'b0; con <= 1'b0; target_mode <= 1'b0;
            bsy_q <= 1'b0; bad_par_q <= 1'b0;
            sb_atn <= 1'b0; sb_ackhold <= 1'b0; sb_rst <= 1'b0;
            for (int l = 0; l < 4; l++) begin dff_n[l] <= 5'd0; dff_rd[l] <= 4'd0; dff_wr[l] <= 4'd0; end
            dfp_latch <= 1'b0; dfifo_cnt <= 7'd0;
            est <= E_IDLE; wb_valid <= 1'b0; rc_valid <= 1'b0;
        end
        if (rst) ;
        else if (srst) begin
            // ISTAT.RST holds the chip in reset until the host clears it
            if (req && we && h_reg && h_k == 4'd8 && be[1] && !wdata[14]) srst <= 1'b0;
        end else begin
            // -------------------------------------------- host register access
            if (req && !h_reg) rdata <= 32'd0;          // +0x000-0x0FF, +0x140-: nothing
            if (req && h_reg) begin
                if (!we) begin
                    rdata <= {reg_rd({h_k, 2'd3}), reg_rd({h_k, 2'd2}), reg_rd({h_k, 2'd1}), reg_rd({h_k, 2'd0})};
                    // read side effects
                    if (h_k == 4'd3 && be[0]) begin            // DSTAT read: clear (and unstack)
                        dstat_st <= dstat_pend; dstat_pend <= 8'd0;
                    end
                    if (h_k == 4'd3 && be[1]) begin            // SSTAT0
                        sstat0_st <= sstat0_pend; sstat0_pend <= 8'd0;
                    end
                    if (h_k == 4'd5 && be[2]) sigp <= 1'b0;   // CTEST2 clears SIGP
                    if (h_k == 4'd6 && be[2]) pop_rd = 1'b1;   // CTEST6 pops the FIFO lane
                end else begin
                    for (int i = 0; i < 4; i++) if (be[i]) begin
                        logic [5:0] a;
                        logic [7:0] v;
                        a = {h_k, 2'(i)}; v = wdata[8*i +: 8];
                        case (a)
                            6'h00: scntl0 <= v;
                            6'h01: begin
                                scntl1 <= v;
                                sb_rst <= v[3];
                                if (v[3] && !scntl1[3]) set_s0[1] = 1'b1;   // our own RST edge
                                con <= v[4] ? 1'b1 : (v[4] == 1'b0 && scntl1[4] && !sb_bsy) ? 1'b0 : con;
                            end
                            6'h02: sdid <= v;     6'h03: sien <= v;
                            6'h04: scid <= v;     6'h05: sxfer <= v;
                            6'h06: sodl <= v;     6'h07: socl <= v;
                            6'h0B: sbcl_w <= v;
                            6'h10: dsa[7:0] <= v; 6'h11: dsa[15:8] <= v; 6'h12: dsa[23:16] <= v; 6'h13: dsa[31:24] <= v;
                            6'h14: ctest0 <= v;
                            6'h18: ctest4 <= v;
                            6'h19: begin
                                ctest5 <= v & 8'h3F;
                                if (v[7]) dnad <= dnad + 32'd1;           // ADCK
                                if (v[6]) dbc <= dbc - 24'd1;             // BBCK
                            end
                            6'h1A: begin                                 // CTEST6: push into the lane
                                logic [1:0] l;
                                l = ctest4[1:0];
                                if (dff_n[l] != 5'd16) begin
                                    dff[l][dff_wr[l]] <= {ctest7[3], v};
                                    dff_wr[l] <= dff_wr[l] + 4'd1; dff_n[l] <= dff_n[l] + 5'd1;
                                end
                            end
                            6'h1B: ctest7 <= v;
                            6'h1C: temp[7:0] <= v; 6'h1D: temp[15:8] <= v; 6'h1E: temp[23:16] <= v; 6'h1F: temp[31:24] <= v;
                            6'h20: dfifo_cnt <= v[6:0];
                            6'h21: begin                                 // ISTAT
                                abrt_req <= v[7];
                                if (v[6]) srst <= 1'b1;
                                sigp <= v[5];
                                if (v[7] && est != E_IDLE) begin set_ds[4] = 1'b1; est <= E_IDLE; end
                                else if (v[7]) set_ds[4] = 1'b1;
                            end
                            6'h22: begin
                                ctest8_w <= v;
                                if (v[2]) for (int l = 0; l < 4; l++) begin   // CLF
                                    dff_n[l] <= 5'd0; dff_rd[l] <= 4'd0; dff_wr[l] <= 4'd0;
                                end
                            end
                            6'h23: lcrc <= 8'd0;
                            6'h24: dbc[7:0] <= v; 6'h25: dbc[15:8] <= v; 6'h26: dbc[23:16] <= v; 6'h27: dcmd <= v;
                            6'h28: dnad[7:0] <= v; 6'h29: dnad[15:8] <= v; 6'h2A: dnad[23:16] <= v; 6'h2B: dnad[31:24] <= v;
                            6'h2C: dsp[7:0] <= v; 6'h2D: dsp[15:8] <= v; 6'h2E: dsp[23:16] <= v;
                            6'h2F: begin dsp[31:24] <= v; if (!dmode[0]) est <= E_FETCH; end   // writing DSP's MSB starts
                            6'h30: dsps[7:0] <= v; 6'h31: dsps[15:8] <= v; 6'h32: dsps[23:16] <= v; 6'h33: dsps[31:24] <= v;
                            6'h34: scratch[7:0] <= v; 6'h35: scratch[15:8] <= v; 6'h36: scratch[23:16] <= v; 6'h37: scratch[31:24] <= v;
                            6'h38: dmode <= v;   6'h39: dien <= v;   6'h3A: dwt <= v;
                            6'h3B: begin dcntl <= v & 8'hFB; if (v[2]) est <= E_FETCH; end   // STD
                            default: ;
                        endcase
                    end
                end
            end
            if (pop_rd) begin
                logic [1:0] l;
                l = ctest4[1:0];
                dfp_latch <= dff[l][dff_rd[l]][8];
                if (dff_n[l] != 5'd0) begin dff_rd[l] <= dff_rd[l] + 4'd1; dff_n[l] <= dff_n[l] - 5'd1; end
            end
            if (sb_req) latched_phase <= sb_phase;
            // CON drops when the target releases BSY (the host may set it in
            // low-level mode, so it is not simply !BSY)
            bsy_q <= sb_bsy;
            if (bsy_q && !sb_bsy && est == E_IDLE) con <= 1'b0;
            // SSTAT0.PAR: the only parity error we can have is the one the
            // chip forces itself -- driving the bus (ADB) with AESP and parity
            // checking on; the IODC's loopback self-check (HW 4.5, ROM
            // F_f002dc2c) expects it latched
            bad_par_q <= scntl1[6] && scntl1[2] && scntl0[3];
            if (scntl1[6] && scntl1[2] && scntl0[3] && !bad_par_q) set_s0[0] = 1'b1;

            // ------------------------------------------------ the engine
            case (est)
                E_IDLE: fcnt <= 3'd0;

                // fetch the instruction: 2 words (3 for a memory move)
                E_FETCH: begin
                    if (d_idle && !wb_valid) begin
                        d_go <= 1'b1; d_we <= 1'b0; d_addr <= dsp; d_be <= 8'hFF;
                    end else if (wb_valid && d_idle) begin
                        d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                        wb_valid <= 1'b0;
                        est <= E_FLUSH; fl_next <= 1'b1;                // write back, then fetch again
                    end
                    if (d_done) begin
                        logic [31:0] w;
                        w = dsp[2] ? d_rdata[31:0] : d_rdata[63:32];
                        if (d_err) begin set_ds[5] = 1'b1; est <= E_IDLE; end
                        else begin
                            case (fcnt)
                                3'd0: begin ins0 <= w; dcmd <= w[31:24]; dbc <= w[23:0]; end
                                3'd1: begin dsps <= w; dnad <= w; end
                                default: temp <= w;
                            endcase
                            dsp <= dsp + 32'd4;
                            fcnt <= fcnt + 3'd1;
                            if ((fcnt == 3'd1 && ins0[31:30] != 2'b11) || fcnt == 3'd2) est <= E_DECODE;
                        end
                    end
                end

                E_DECODE: begin
                    first_byte <= 1'b1;
                    case (ins0[31:30])
                        2'b00: begin                                     // block move
                            if (target_mode || !ins0[27]) begin set_ds[0] = 1'b1; est <= E_IDLE; end   // target / reserved
                            else if (ins0[28] || ins0[29]) begin
                                // table indirect (DSA + offset) or indirect: fetch count/address
                                d_go <= 1'b1; d_we <= 1'b0; d_be <= 8'hFF;
                                d_addr <= ins0[28] ? dsa + sext24(dsps[23:0]) : dsps;
                                fcnt <= 3'd0; est <= E_IND;
                            end else if (dbc == 24'd0) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                            else est <= E_BM_WAIT;
                        end
                        2'b01: begin
                            if (ins0[29:27] >= 3'b101) begin
                                // register read / write
                                logic [7:0] src, res;
                                logic [8:0] sum;
                                logic       rdsfbr;
                                rdsfbr = ins0[29:27] == 3'b101;        // move from SFBR
                                src = rdsfbr ? sfbr : reg_rd(reg_adr);
                                if (!rdsfbr && reg_adr == 6'h16) sigp <= 1'b0;   // reading CTEST2 clears SIGP
                                if (!rdsfbr && reg_adr == 6'h0C) begin dstat_st <= dstat_pend; dstat_pend <= 8'd0; end
                                if (!rdsfbr && reg_adr == 6'h0D) begin sstat0_st <= sstat0_pend; sstat0_pend <= 8'd0; end
                                sum = {1'b0, src} + {1'b0, reg_imm} + {8'd0, ins0[24] & carry};
                                case (ins0[26:25])
                                    2'b00: res = reg_imm;
                                    2'b01: res = src | reg_imm;
                                    2'b10: res = src & reg_imm;
                                    default: begin res = sum[7:0]; carry <= sum[8]; end
                                endcase
                                if (ins0[29:27] == 3'b110) sfbr <= res;           // move to SFBR
                                else begin
                                    // RMW or move from SFBR: write the register
                                    case (reg_adr)
                                        6'h00: scntl0 <= res; 6'h01: begin scntl1 <= res; sb_rst <= res[3]; end
                                        6'h02: sdid <= res; 6'h03: sien <= res; 6'h04: scid <= res; 6'h05: sxfer <= res;
                                        6'h06: sodl <= res; 6'h07: socl <= res; 6'h08: sfbr <= res;
                                        6'h10: dsa[7:0] <= res; 6'h11: dsa[15:8] <= res; 6'h12: dsa[23:16] <= res; 6'h13: dsa[31:24] <= res;
                                        6'h14: ctest0 <= res; 6'h18: ctest4 <= res; 6'h1B: ctest7 <= res;
                                        6'h1C: temp[7:0] <= res; 6'h1D: temp[15:8] <= res; 6'h1E: temp[23:16] <= res; 6'h1F: temp[31:24] <= res;
                                        6'h21: begin sigp <= res[5]; end
                                        6'h23: lcrc <= res;
                                        6'h24: dbc[7:0] <= res; 6'h25: dbc[15:8] <= res; 6'h26: dbc[23:16] <= res;
                                        6'h28: dnad[7:0] <= res; 6'h29: dnad[15:8] <= res; 6'h2A: dnad[23:16] <= res; 6'h2B: dnad[31:24] <= res;
                                        6'h30: dsps[7:0] <= res; 6'h31: dsps[15:8] <= res; 6'h32: dsps[23:16] <= res; 6'h33: dsps[31:24] <= res;
                                        6'h34: scratch[7:0] <= res; 6'h35: scratch[15:8] <= res; 6'h36: scratch[23:16] <= res; 6'h37: scratch[31:24] <= res;
                                        6'h38: dmode <= res; 6'h39: dien <= res; 6'h3A: dwt <= res; 6'h3B: dcntl <= res & 8'hFB;
                                        default: ;
                                    endcase
                                end
                                est <= E_FETCH; fcnt <= 3'd0;
                            end else case (ins0[29:27])
                                3'b000: begin                               // SELECT
                                    if (ins0[25]) begin
                                        // table indirect: ID and SXFER from DSA + offset
                                        d_go <= 1'b1; d_we <= 1'b0; d_be <= 8'hFF;
                                        d_addr <= dsa + sext24(ins0[23:0]); fcnt <= 3'd0; est <= E_IND;
                                    end else begin
                                        sdid <= ins0[23:16]; est <= E_SEL;
                                    end
                                end
                                3'b001: est <= E_WDISC;                     // WAIT DISCONNECT
                                3'b010: est <= E_WRESEL;                    // WAIT RESELECT
                                3'b011, 3'b100: begin                       // SET / CLEAR
                                    logic s;
                                    s = ins0[29:27] == 3'b011;
                                    if (ins0[3]) sb_atn <= s;
                                    if (ins0[6]) sb_ackhold <= s;
                                    if (ins0[9]) begin target_mode <= s; scntl0[0] <= s; end
                                    if (ins0[10]) carry <= s;
                                    est <= E_FETCH; fcnt <= 3'd0;
                                end
                                default: begin set_ds[0] = 1'b1; est <= E_IDLE; end
                            endcase
                        end
                        2'b10: begin                                     // transfer control
                            if (ins0[29:27] > 3'b011) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                            else if (ins0[16] && con) est <= E_TC_WAIT;
                            else est <= E_TC_EVAL;
                        end
                        default: begin                                   // memory move
                            if (ins0[29:24] != 6'd0 || dsps[1:0] != temp[1:0]) begin set_ds[0] = 1'b1; est <= E_IDLE; end
                            else if (dbc == 24'd0) begin est <= E_FETCH; fcnt <= 3'd0; end
                            else begin
                                dnad <= dsps; est <= E_MM_RD;
                                mm_regsrc <= dsps[31:6] == 26'h3C0_4184;     // F010_6100-F010_613F: our registers
                                mm_regdst <= temp[31:6] == 26'h3C0_4184;
                            end
                        end
                    endcase
                end

                // the indirect fetches: block move {count, address} / select {ID, SXFER}
                E_IND: if (d_done) begin
                    logic [31:0] w;
                    w = d_addr[2] ? d_rdata[31:0] : d_rdata[63:32];
                    if (d_err) begin set_ds[5] = 1'b1; est <= E_IDLE; end
                    else if (ins0[31:30] == 2'b01) begin
                        sdid <= w[23:16]; sxfer <= w[15:8]; est <= E_SEL;
                    end else if (fcnt == 3'd0 && ins0[28]) begin
                        dbc <= w[23:0]; fcnt <= 3'd1;
                        d_go <= 1'b1; d_addr <= d_addr + 32'd4;
                    end else begin
                        dnad <= w;
                        est <= (dbc == 24'd0 && !(ins0[28] && fcnt == 3'd0)) ? E_IDLE : E_BM_WAIT;
                        if (dbc == 24'd0 && !(ins0[28] && fcnt == 3'd0)) set_ds[0] = 1'b1;
                    end
                end

                // ---- block move: wait for REQ, compare the phase, move the bytes
                E_BM_WAIT: begin
                    if (!sb_bsy) begin set_s0[2] = 1'b1; con <= 1'b0; sb_ackhold <= 1'b0; est <= E_FLUSH; fl_next <= 1'b0; end   // UDC
                    else if (sb_req) begin
                        if (sb_phase != ins0[26:24]) begin set_s0[7] = 1'b1; est <= E_FLUSH; fl_next <= 1'b0; end      // phase mismatch
                        else begin
                            sb_ackhold <= 1'b0;
                            if (sb_phase[0]) est <= E_BM_BYTE;               // IN
                            else est <= E_BM_RD;                             // OUT: fetch the byte first
                        end
                    end
                end
                // IN: take the byte into the write buffer
                E_BM_BYTE: begin
                    if (wb_valid && wb_addr != dnad[31:3]) begin
                        if (d_idle) begin
                            d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                            wb_valid <= 1'b0;
                        end
                    end else if (d_idle) begin
                        logic [7:0] b;
                        b = sb_tdata;
                        if (!wb_valid) begin wb_valid <= 1'b1; wb_addr <= dnad[31:3]; wb_be <= 8'd0; end
                        wb_data[63 - 8*dnad[2:0] -: 8] <= b;
                        wb_be[7 - dnad[2:0]] <= 1'b1;
                        if (!wb_valid) wb_be <= 8'h80 >> dnad[2:0];
                        rc_valid <= 1'b0;
                        sidl <= b;
                        if (first_byte) sfbr <= b;
                        first_byte <= 1'b0;
                        lcrc <= lcrc ^ b;
                        dnad <= dnad + 32'd1; dbc <= dbc - 24'd1; dfifo_cnt <= dfifo_cnt - 7'd1;
                        sb_ack <= 1'b1;
                        // the last byte of a MESSAGE IN move keeps ACK asserted
                        if (dbc == 24'd1 && sb_phase == 3'b111) sb_ackhold <= 1'b1;
                        est <= E_BM_END;
                    end
                end
                // OUT: read the byte (cached doubleword), then give it
                E_BM_RD: begin
                    if (rc_valid && rc_addr == dnad[31:3]) est <= E_BM_GIVE;
                    else if (wb_valid && d_idle) begin
                        d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                        wb_valid <= 1'b0;
                    end else if (d_idle && !wb_valid) begin
                        d_go <= 1'b1; d_we <= 1'b0; d_addr <= dnad; d_be <= 8'hFF;
                    end
                    if (d_done && !d_we) begin
                        if (d_err) begin set_ds[5] = 1'b1; est <= E_IDLE; end
                        else begin rc_valid <= 1'b1; rc_addr <= dnad[31:3]; rc_data <= d_rdata; est <= E_BM_GIVE; end
                    end
                end
                E_BM_GIVE: begin
                    logic [7:0] b;
                    b = dw_byte(rc_data, dnad[2:0]);
                    sb_idata <= b; sodl <= b;
                    lcrc <= lcrc ^ b;
                    // MESSAGE OUT: ATN drops before the last byte
                    if (dbc == 24'd1 && sb_phase == 3'b110) sb_atn <= 1'b0;
                    dnad <= dnad + 32'd1; dbc <= dbc - 24'd1; dfifo_cnt <= dfifo_cnt - 7'd1;
                    sb_ack <= 1'b1;
                    est <= E_BM_END;
                end
                // after each byte: the target drops REQ; then the next byte or done
                E_BM_END: if (!sb_ack && !sb_req) begin
                    if (dbc == 24'd0) begin est <= E_FLUSH; fl_next <= 1'b1; end
                    else est <= E_BM_WAIT;
                end

                // ---- SELECT: wait for the target, or time out
                E_SEL: begin
                    sb_sel <= 1'b1;
                    for (int i = 0; i < 8; i++) if (sdid[i]) sb_sel_id <= 3'(i);
                    sb_sel_atn <= ins0[24];
                    sto_cnt <= 32'd0;
                    est <= E_SEL_WAIT;
                end
                E_SEL_WAIT: begin
                    if (sb_sel_done) begin
                        con <= 1'b1;
                        if (ins0[24]) sb_atn <= 1'b1;
                        // with COM set, the IDs go to LCRC only
                        lcrc <= sdid | scid;
                        if (!dcntl[0]) sfbr <= sdid | scid;
                        est <= E_FETCH; fcnt <= 3'd0;
                    end else if (sb_sel_fail) est <= E_STO;
                end
                E_STO: begin
                    sto_cnt <= sto_cnt + 32'd1;
                    if (sto_cnt == STO_CLKS) begin set_s0[5] = 1'b1; est <= E_IDLE; end
                end
                E_WDISC: if (!sb_bsy) begin con <= 1'b0; sb_ackhold <= 1'b0; est <= E_FETCH; fcnt <= 3'd0; end
                E_WRESEL: if (sigp) begin
                    // SIGP: the alternate address
                    dsp <= ins0[26] ? dsp + sext24(dsps[23:0]) : dsps;
                    est <= E_FETCH; fcnt <= 3'd0;
                end

                // ---- transfer control
                E_TC_WAIT: begin
                    if (!sb_bsy) begin set_s0[2] = 1'b1; con <= 1'b0; est <= E_IDLE; end
                    else if (sb_req && !sb_ackhold) est <= E_TC_EVAL;
                end
                E_TC_EVAL: begin
                    logic pm, dm, cnd, take;
                    logic [2:0] ph;
                    ph = sb_req ? sb_phase : latched_phase;
                    pm = ph == ins0[26:24];
                    dm = ((sfbr ^ ins0[7:0]) & ~ins0[15:8]) == 8'd0;
                    if (ins0[21]) cnd = carry;
                    else if (ins0[17] && ins0[18]) cnd = ins0[19] ? (pm && dm) : !(!pm && !dm);
                    else if (ins0[17]) cnd = pm;
                    else if (ins0[18]) cnd = dm;
                    else cnd = 1'b1;
                    take = ins0[19] ? cnd : !cnd;
                    if (!ins0[17] && !ins0[18] && !ins0[21]) take = ins0[19];
                    if (take) case (ins0[29:27])
                        3'b000: begin dsp <= ins0[23] ? dsp + sext24(dsps[23:0]) : dsps; est <= E_FETCH; fcnt <= 3'd0; end
                        3'b001: begin temp <= dsp; dsp <= ins0[23] ? dsp + sext24(dsps[23:0]) : dsps; est <= E_FETCH; fcnt <= 3'd0; end
                        3'b010: begin dsp <= temp; est <= E_FETCH; fcnt <= 3'd0; end
                        default: begin est <= E_FLUSH; fl_next <= 1'b0; set_ds[2] = 1'b1; end   // INT: SIR
                    endcase
                    else begin est <= E_FETCH; fcnt <= 3'd0; end
                end

                // ---- memory move: byte by byte through the read cache / write buffer
                E_MM_RD: begin
                    if (mm_regsrc) begin
                        rc_data[63 - 8*dnad[2:0] -: 8] <= reg_rd(dnad[5:0]);
                        rc_addr <= dnad[31:3]; rc_valid <= 1'b1; est <= E_MM_WR;
                    end else if (rc_valid && rc_addr == dnad[31:3]) est <= E_MM_WR;
                    else if (wb_valid && d_idle) begin
                        d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                        wb_valid <= 1'b0;
                    end else if (d_idle && !wb_valid) begin
                        d_go <= 1'b1; d_we <= 1'b0; d_addr <= dnad; d_be <= 8'hFF;
                    end
                    if (d_done && !d_we) begin
                        if (d_err) begin set_ds[5] = 1'b1; est <= E_IDLE; end
                        else begin rc_valid <= 1'b1; rc_addr <= dnad[31:3]; rc_data <= d_rdata; est <= E_MM_WR; end
                    end
                end
                E_MM_WR: begin
                    logic [7:0] b;
                    b = dw_byte(rc_data, dnad[2:0]);
                    if (mm_regsrc) rc_valid <= 1'b0;
                    if (mm_regdst) begin
                        // a register as the destination
                        case (temp[5:0])
                            6'h34: scratch[7:0] <= b; 6'h35: scratch[15:8] <= b; 6'h36: scratch[23:16] <= b; 6'h37: scratch[31:24] <= b;
                            6'h10: dsa[7:0] <= b; 6'h11: dsa[15:8] <= b; 6'h12: dsa[23:16] <= b; 6'h13: dsa[31:24] <= b;
                            6'h1C: temp[7:0] <= b; 6'h1D: temp[15:8] <= b; 6'h1E: temp[23:16] <= b; 6'h1F: temp[31:24] <= b;
                            default: ;
                        endcase
                        dnad <= dnad + 32'd1; temp <= temp + 32'd1; dbc <= dbc - 24'd1;
                        est <= (dbc == 24'd1) ? E_FLUSH : E_MM_RD; fl_next <= 1'b1;
                    end else if (wb_valid && wb_addr != temp[31:3]) begin
                        if (d_idle) begin
                            d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                            wb_valid <= 1'b0;
                        end
                    end else if (d_idle) begin
                        if (!wb_valid) begin wb_valid <= 1'b1; wb_addr <= temp[31:3]; wb_be <= 8'h80 >> temp[2:0]; end
                        else wb_be[7 - temp[2:0]] <= 1'b1;
                        wb_data[63 - 8*temp[2:0] -: 8] <= b;
                        if (rc_addr == temp[31:3]) rc_valid <= 1'b0;     // the read cache is stale
                        dnad <= dnad + 32'd1; temp <= temp + 32'd1; dbc <= dbc - 24'd1;
                        est <= (dbc == 24'd1) ? E_FLUSH : E_MM_RD; fl_next <= 1'b1;
                    end
                end

                // write back the buffer; then the next instruction (fl_next)
                // or the halt with the interrupt already raised
                E_FLUSH: begin
                    if (wb_valid && d_idle) begin
                        d_go <= 1'b1; d_we <= 1'b1; d_addr <= {wb_addr, 3'd0}; d_be <= wb_be; d_wdata <= wb_data;
                        wb_valid <= 1'b0;
                    end else if (!wb_valid && d_idle) begin
                        rc_valid <= 1'b0;
                        if (fl_next) begin est <= E_FETCH; fcnt <= 3'd0; end
                        else est <= E_IDLE;
                    end
                    if (d_done && d_err) begin set_ds[5] = 1'b1; est <= E_IDLE; wb_valid <= 1'b0; end
                end
                default: est <= E_IDLE;
            endcase

            // ------------------------------------- interrupt status, stacked
            if (set_s0 != 8'd0 || set_ds != 8'd0) begin
                if (sip || dip) begin
                    sstat0_pend <= sstat0_pend | set_s0; dstat_pend <= dstat_pend | set_ds;
                end else begin
                    sstat0_st <= sstat0_st | set_s0; dstat_st <= dstat_st | set_ds;
                end
            end
            // an INT instruction halts with the vector in DSPS (already there)
        end
    end
endmodule
