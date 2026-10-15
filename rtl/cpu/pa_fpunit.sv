// PA-7100LC floating-point unit: the FP register file, the status and
// exception registers, the decode of the FP operation word and the sequencing
// of the arithmetic engine (pa_fpu) -- docs/design/cpu.md 3.5, 4.3.12, 6.11;
// ERS ch. 7; ACD ch. 6.
//
// Everything happens in program order at the core's W stage: an operation
// (FU_FP) is accepted when its instruction commits (S_RD: the register
// numbers are captured, the operands are read from the register file during
// the next cycle into hold registers, and the engine starts the cycle after
// that, from flip-flops -- cpu-timing.md 4.5); an FP load writes its target
// when it commits; an FP store reads its source in W. The core holds any FP
// instruction in D while an operation is in E/M/W or in flight here
// (`busy`), so there are no register hazards to track (the simplest correct
// version; P-016 notes the lost overlap). One operation at a time.
//
// The register file fr4..fr31 is MLAB LUT-RAM with asynchronous reads, one
// copy per read port (two operands, the store source), every write going to
// all three (the pa_regfile scheme; one array with three read ports would
// not infer a memory and cost 1.8k flip-flops plus the read muxes, fit 10).
//
// FPSR (fr0L) in Verilog bits: flags V Z O U I = [31:27], C = [26], the
// compare queue PA 10:20 = [21:11] (also the model/revision written by
// COPR,0,0), RM = [10:9], T = [6], D = [5], enables V Z O U I = [4:0].
// fr0R, fr1L..fr3R are exception registers 1..7; the hardware writes only
// exception register 2 (fr1L) = {code, instruction bits 6:31} on the
// unimplemented exception, which also sets T (sec. 3.5).
module pa_fpunit
    import pa_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        issue,          // an FP operation commits this cycle
    input  logic [31:0] insn,           // the instruction in W (operations, loads, stores)
    input  logic        st_dbl,         // the store in W is a doubleword (the core's decoded size: no opcode decode on the store-data path, fit 19)
    input  logic        ld_we,          // an FP load commits: write insn's target
    input  logic [63:0] ld_data,        // the doubleword (FLDD) or the word in [31:0] (FLDW)
    input  logic        st_commit,      // an FP store commits (FSTD fr0 clears T)
    output logic [63:0] st_data,        // insn's store source: a doubleword, or the word in [31:0]
    output logic        busy,           // an operation is in flight (FP instructions hold in D)
    output logic        fpsr_t,         // FPSR.T: the next FP instruction traps 14
    output logic [31:0] fpsr_o
);
    // ---------------------------------------------------------------- registers
    logic [31:0] fpsr;
    logic [31:0] xr [7];                // exception registers 1..7 = fr0R, fr1L, fr1R, fr2L, fr2R, fr3L, fr3R
    // fr4..fr31 (entries 0..3 unused): left and right halves, one copy per read port
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] frl_a [32], frl_b [32], frl_s [32];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] frr_a [32], frr_b [32], frr_s [32];
    assign fpsr_t = fpsr[6];
    assign fpsr_o = fpsr;

    function automatic logic [63:0] rd_ff(input logic [4:0] r);
        case (r[1:0])
            2'd0: rd_ff = {fpsr, xr[0]};
            2'd1: rd_ff = {xr[1], xr[2]};
            2'd2: rd_ff = {xr[3], xr[4]};
            default: rd_ff = {xr[5], xr[6]};
        endcase
    endfunction
    // three read ports: the two operands and the store source. As an operand
    // of a non-load/store instruction fr0 "encodes a floating-point +0 or a
    // fixed-point 0" (ACD p.6-4, 6-9): HP's compilers zero registers with
    // FCPY fr0 and compare against fr0; only FSTD/FSTW fr0 read the status.
    // Found 2026-10-09: awk's `fcmp,dbl,< fr4,fr0` compared against the
    // status word, so its truth tests went wrong and its loops never ended.
    // fr1-fr3 as operands are undefined (ACD p.6-5); they read as themselves.
    logic [4:0]  rd_a_n, rd_b_n, rd_s_n;
    logic [63:0] rd_a, rd_b, rd_s;
    assign rd_a = (rd_a_n == 5'd0) ? 64'd0 : (rd_a_n < 5'd4) ? rd_ff(rd_a_n) : {frl_a[rd_a_n], frr_a[rd_a_n]};
    assign rd_b = (rd_b_n == 5'd0) ? 64'd0 : (rd_b_n < 5'd4) ? rd_ff(rd_b_n) : {frl_b[rd_b_n], frr_b[rd_b_n]};
    assign rd_s = (rd_s_n < 5'd4) ? rd_ff(rd_s_n) : {frl_s[rd_s_n], frr_s[rd_s_n]};
    // a single operand (left-justified for the engine) from the selected half
    function automatic logic [63:0] opnd(input logic [63:0] r, input logic single, input logic half);
        return (single && half) ? {r[31:0], 32'd0} : r;
    endfunction

    // ---------------------------------------------------------------- decode of the operation word
    typedef enum logic [2:0] { K_UNIMPL, K_OP, K_FMA, K_FTEST, K_FID } kind_e;
    kind_e      d_kind;
    fpu_op_e    d_op;
    logic       d_sgl, d_dsgl, d_sdest;           // operand format, convert destination, single result
    logic [4:0] d_cond;
    logic [4:0] d_r1, d_r2, d_t;                  // register numbers
    logic       d_h1, d_h2, d_ht;                 // halves (0E singles)
    logic [4:0] d_tm, d_ra, d_ta;                 // FMPYADD/SUB/CFXT
    logic       d_htm, d_hra, d_hta, d_fsub, d_cfxt;
    logic [5:0] d_code;
    // the 5-bit single specifier of 06/26: 0-15 -> fr(16+s)L, 16-31 -> fr(s)R
    function automatic logic [5:0] fma_spec(input logic [4:0] s, input logic single);   // {half, reg}
        return !single ? {1'b0, s} : s[4] ? {1'b1, s} : {1'b0, 1'b1, s[3:0]};
    endfunction
    always_comb begin
        logic [5:0] maj;
        logic [1:0] cls, fmt, sf, df;
        logic [2:0] sub;
        logic       is0e;
        maj = insn[31:26]; cls = insn[10:9]; is0e = maj == 6'h0E;
        d_kind = K_UNIMPL; d_op = F_RESERVED; d_sgl = 1'b0; d_dsgl = 1'b0; d_sdest = 1'b0; d_cond = insn[4:0];
        d_r1 = insn[25:21]; d_r2 = insn[20:16]; d_t = insn[4:0];
        d_h1 = is0e & insn[7]; d_h2 = is0e & insn[12]; d_ht = is0e & insn[6];
        d_tm = 5'd0; d_ra = 5'd0; d_ta = 5'd0; d_htm = 1'b0; d_hra = 1'b0; d_hta = 1'b0;
        d_fsub = 1'b0; d_cfxt = 1'b0;
        fmt = is0e ? {1'b0, insn[11]} : insn[12:11];
        sub = insn[15:13];
        sf = insn[12:11]; df = insn[14:13];
        case (maj)
            6'h0C, 6'h0E: begin
                d_code = is0e ? 6'b001011 : 6'b001001;
                d_sgl = fmt == 2'd0; d_sdest = d_sgl;
                case (cls)
                    2'd0: begin                                             // class 0
                        if (fmt[1]) d_kind = K_UNIMPL;                      // quad / undefined format
                        else case (sub)
                            3'd0: if (insn == 32'h3000_0000) d_kind = K_FID;
                            3'd2: begin d_kind = K_OP; d_op = F_CPY; end
                            3'd3: begin d_kind = K_OP; d_op = F_ABS; end
                            3'd4: begin d_kind = K_OP; d_op = F_SQRT; end
                            3'd5: begin d_kind = K_OP; d_op = F_RND; end    // the engine reports it unimplemented
                            default: ;                                      // 1, 6, 7: PA 2.0 FNEG/FNEGABS, reserved
                        endcase
                    end
                    2'd1: begin                                             // class 1: conversions
                        d_sgl = sf == 2'd0; d_dsgl = df == 2'd0; d_sdest = d_dsgl;
                        if (sf[1] || df[1] || insn[17]) d_kind = K_UNIMPL;  // quad / undefined, PA 2.0 unsigned
                        else case (insn[16:15])
                            2'd0: begin                                     // FCNVFF: sgl,sgl = FCPY sgl; dbl,dbl = FABS dbl (ERS s.7.2.5)
                                d_kind = K_OP;
                                d_op = (sf == df) ? (sf[0] ? F_ABS : F_CPY) : F_CNVFF;
                            end
                            2'd1: begin d_kind = K_OP; d_op = F_CNVXF; end
                            2'd2: begin d_kind = K_OP; d_op = F_CNVFX; end
                            default: begin d_kind = K_OP; d_op = F_CNVFXT; end
                        endcase
                    end
                    2'd2: begin                                             // class 2: FCMP, FTEST
                        if (insn[5]) begin                                  // the N bit: FTEST (0C, sub 1), else undefined
                            if (!is0e && sub == 3'd1 && ftest_valid(insn[4:0])) d_kind = K_FTEST;
                        end else if (!fmt[1]) begin d_kind = K_OP; d_op = F_CMP; end
                    end
                    default: begin                                          // class 3: arithmetic, XMPYU
                        if (is0e && insn[8]) begin                          // fixed-point: XMPYU only
                            if (sub == 3'd2 && !insn[11]) begin d_kind = K_OP; d_op = F_XMPYU; d_sgl = 1'b1; d_sdest = 1'b0; end
                        end else if (!fmt[1]) case (sub)
                            3'd0: begin d_kind = K_OP; d_op = F_ADD; end
                            3'd1: begin d_kind = K_OP; d_op = F_SUB; end
                            3'd2: begin d_kind = K_OP; d_op = F_MPY; end
                            3'd3: begin d_kind = K_OP; d_op = F_DIV; end
                            default: ;
                        endcase
                    end
                endcase
            end
            6'h06, 6'h26: begin                                             // FMPYADD / FMPYSUB / FMPYCFXT
                logic single;
                single = insn[5];
                d_code = (maj == 6'h26) ? 6'b100011 : 6'b000011;
                d_kind = K_FMA; d_fsub = maj == 6'h26; d_sgl = single; d_sdest = single;
                {d_h1, d_r1} = fma_spec(insn[25:21], single);              // rm1
                {d_h2, d_r2} = fma_spec(insn[20:16], single);              // rm2
                {d_hta, d_ta} = fma_spec(insn[15:11], single);
                {d_hra, d_ra} = fma_spec(insn[10:6], single);
                {d_htm, d_tm} = fma_spec(insn[4:0], single);
                d_cfxt = insn[10:6] == 5'd0;
            end
            default: d_code = 6'd0;
        endcase
    end

    // ---------------------------------------------------------------- store source
    always_comb begin
        rd_s_n = insn[4:0];
        st_data = st_dbl ? rd_s : {32'd0, insn[6] ? rd_s[31:0] : rd_s[63:32]};
    end

    // ---------------------------------------------------------------- engine
    logic        eng_start, eng_busy, eng_done, eng_we, eng_unimpl, eng_cmp;
    fpu_op_e     eng_op;
    logic        eng_sgl, eng_dsgl;
    logic [63:0] eng_a, eng_b, eng_result;
    logic [4:0]  eng_flags, eng_cond;
    pa_fpu u_eng (
        .clk(clk), .rst_n(rst_n), .start(eng_start), .op(eng_op), .sgl(eng_sgl), .dsgl(eng_dsgl),
        .a(eng_a), .b(eng_b), .rm(fpsr[10:9]), .dmode(fpsr[5]), .enables(fpsr[4:0]), .cond(eng_cond),
        .busy(eng_busy), .done(eng_done), .result(eng_result), .result_we(eng_we), .flags(eng_flags),
        .unimpl(eng_unimpl), .cmp_c(eng_cmp));

    // ---------------------------------------------------------------- sequencing
    typedef enum logic [2:0] { S_IDLE, S_RD, S_OP, S_FMA_MPY, S_FMA_RD, S_FMA_ADD, S_FMA_WR } st_e;
    st_e st;
    assign busy = st != S_IDLE;
    // the operation in flight
    logic [31:0] cur_insn;
    logic [5:0]  cur_code;
    logic [4:0]  cur_r1, cur_r2, cur_t;
    logic        cur_h1, cur_h2, cur_ht, cur_sdest, cur_cmp, cur_fma, cur_dsgl;
    fpu_op_e     cur_op;
    logic [4:0]  cur_cond;
    logic [4:0]  cur_tm, cur_ra, cur_ta;
    logic        cur_htm, cur_hra, cur_hta, cur_fsub, cur_cfxt, cur_sgl;
    logic [63:0] fma_res1;
    logic        fma_we1, fma_unimpl;
    logic [4:0]  fma_flags;

    // operand read ports, addressed from the captured operation: r1/r2 for the
    // operation (or the multiply of a multi-op), ra/ta for the second FMA step
    always_comb begin
        if (st == S_FMA_RD) begin rd_a_n = cur_cfxt ? cur_ta : cur_ra; rd_b_n = cur_ta; end
        else                begin rd_a_n = cur_r1; rd_b_n = cur_r2; end
    end
    // The engine reads op / formats / operands throughout the operation, so they
    // are captured in the read cycle (S_RD, S_FMA_RD) and held until it is done;
    // the start pulse follows one cycle later, so the engine starts from flip-flops.
    fpu_op_e     hold_op;
    logic        hold_sgl, hold_dsgl;
    logic [4:0]  hold_cond;
    logic [63:0] hold_a, hold_b;
    logic        start_r;
    assign eng_start = start_r;
    assign eng_op = hold_op; assign eng_sgl = hold_sgl; assign eng_dsgl = hold_dsgl; assign eng_cond = hold_cond;
    assign eng_a = hold_a; assign eng_b = hold_b;
    always_ff @(posedge clk) begin
        if (!rst_n) start_r <= 1'b0;
        else start_r <= (st == S_RD) || (st == S_FMA_RD);
        if (st == S_RD) begin
            hold_op <= cur_fma ? F_MPY : cur_op; hold_sgl <= cur_sgl; hold_dsgl <= cur_dsgl; hold_cond <= cur_cond;
            hold_a <= opnd(rd_a, cur_sgl, cur_h1); hold_b <= opnd(rd_b, cur_sgl, cur_h2);
        end else if (st == S_FMA_RD) begin
            hold_sgl <= cur_sgl; hold_cond <= cur_cond;
            if (cur_cfxt) begin                                             // ta <- FCNVFXT(ta), 32-bit integer
                hold_op <= F_CNVFXT; hold_dsgl <= 1'b1;
                hold_a <= opnd(rd_a, cur_sgl, cur_hta); hold_b <= 64'd0;
            end else begin
                hold_op <= cur_fsub ? F_SUB : F_ADD;                        // ta <- ra + ta, or ta - ra (FMPYSUB)
                hold_dsgl <= cur_sgl;
                if (cur_fsub) begin hold_a <= opnd(rd_b, cur_sgl, cur_hta); hold_b <= opnd(rd_a, cur_sgl, cur_hra); end
                else          begin hold_a <= opnd(rd_a, cur_sgl, cur_hra); hold_b <= opnd(rd_b, cur_sgl, cur_hta); end
            end
        end
    end

    // register writes (one per cycle: loads never commit while an operation is in flight)
    logic        wr_en, wr_single, wr_half;
    logic [4:0]  wr_n;
    logic [63:0] wr_data;
    always_comb begin
        wr_en = 1'b0; wr_single = 1'b0; wr_half = 1'b0; wr_n = 5'd0; wr_data = 64'd0;
        if (ld_we) begin
            wr_en = 1'b1; wr_n = insn[4:0];
            if (insn[31:26] == 6'h09) begin wr_single = 1'b1; wr_half = insn[6]; wr_data = {ld_data[31:0], 32'd0}; end
            else wr_data = ld_data;
        end else if (st == S_OP && eng_done && !eng_unimpl && eng_we) begin
            wr_en = 1'b1; wr_n = cur_t; wr_single = cur_sdest; wr_half = cur_ht; wr_data = eng_result;
        end else if (st == S_FMA_ADD && eng_done && !eng_unimpl && !fma_unimpl && eng_we) begin
            wr_en = 1'b1; wr_n = cur_ta; wr_data = eng_result;              // the add's result (or the int32 of FMPYCFXT)
            wr_single = cur_sgl || cur_cfxt; wr_half = cur_hta;             // dbl FMPYCFXT: the MSW of ta
        end else if (st == S_FMA_WR && fma_we1) begin
            wr_en = 1'b1; wr_n = cur_tm; wr_single = cur_sgl; wr_half = cur_htm; wr_data = fma_res1;
        end
    end
    wire wr_l = wr_en && (!wr_single || !wr_half);
    wire wr_r = wr_en && (!wr_single || wr_half);
    wire [31:0] wr_lv = wr_data[63:32];
    wire [31:0] wr_rv = wr_single ? wr_data[63:32] : wr_data[31:0];

    always_ff @(posedge clk) begin
        if (wr_l && wr_n >= 5'd4) begin frl_a[wr_n] <= wr_lv; frl_b[wr_n] <= wr_lv; frl_s[wr_n] <= wr_lv; end
        if (wr_r && wr_n >= 5'd4) begin frr_a[wr_n] <= wr_rv; frr_b[wr_n] <= wr_rv; frr_s[wr_n] <= wr_rv; end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; fpsr <= 32'd0;
            for (int i = 0; i < 7; i++) xr[i] <= 32'd0;
            cur_insn <= 0; cur_code <= 0; cur_r1 <= 0; cur_r2 <= 0; cur_t <= 0; cur_h1 <= 0; cur_h2 <= 0; cur_ht <= 0;
            cur_sdest <= 0; cur_cmp <= 0; cur_fma <= 0; cur_dsgl <= 0; cur_op <= F_RESERVED; cur_cond <= 0;
            cur_tm <= 0; cur_ra <= 0; cur_ta <= 0; cur_htm <= 0; cur_hra <= 0; cur_hta <= 0;
            cur_fsub <= 0; cur_cfxt <= 0; cur_sgl <= 0; fma_res1 <= 0; fma_we1 <= 0; fma_unimpl <= 0; fma_flags <= 0;
        end else begin
            // fr0..fr3 written by FP loads
            if (wr_en && wr_n < 5'd4) begin
                case (wr_n[1:0])
                    2'd0: begin if (wr_l) fpsr <= wr_lv; if (wr_r) xr[0] <= wr_rv; end
                    2'd1: begin if (wr_l) xr[1] <= wr_lv; if (wr_r) xr[2] <= wr_rv; end
                    2'd2: begin if (wr_l) xr[3] <= wr_lv; if (wr_r) xr[4] <= wr_rv; end
                    default: begin if (wr_l) xr[5] <= wr_lv; if (wr_r) xr[6] <= wr_rv; end
                endcase
            end
            // FSTD fr0 stored the status with T, then clears it (sec. 3.5)
            if (st_commit && insn[31:26] == 6'h0B && insn[4:0] == 5'd0) fpsr[6] <= 1'b0;

            case (st)
                S_IDLE: if (issue) begin
                    cur_insn <= insn; cur_code <= d_code;
                    cur_r1 <= d_r1; cur_r2 <= d_r2; cur_h1 <= d_h1; cur_h2 <= d_h2;
                    cur_op <= d_op; cur_sgl <= d_sgl; cur_dsgl <= d_dsgl; cur_cond <= d_cond;
                    cur_fma <= d_kind == K_FMA;
                    case (d_kind)
                        K_FID: fpsr[21:11] <= {6'h0D, 5'h01};                   // model 0x0D, revision 1 (ERS s.7.1)
                        K_FTEST: ;                                               // nullification is decided in E
                        K_UNIMPL: begin fpsr[6] <= 1'b1; xr[1] <= {d_code, insn[25:0]}; end
                        K_OP: begin
                            cur_t <= d_t; cur_ht <= d_ht; cur_sdest <= d_sdest; cur_cmp <= d_op == F_CMP;
                            st <= S_RD;
                        end
                        default: begin                                           // K_FMA
                            cur_tm <= d_tm; cur_ra <= d_ra; cur_ta <= d_ta;
                            cur_htm <= d_htm; cur_hra <= d_hra; cur_hta <= d_hta;
                            cur_fsub <= d_fsub; cur_cfxt <= d_cfxt;
                            fma_unimpl <= 1'b0; fma_we1 <= 1'b0;
                            st <= S_RD;
                        end
                    endcase
                end
                S_RD: st <= cur_fma ? S_FMA_MPY : S_OP;                          // operands captured, start follows
                S_OP: if (eng_done) begin
                    st <= S_IDLE;
                    if (eng_unimpl) begin fpsr[6] <= 1'b1; xr[1] <= {cur_code, cur_insn[25:0]}; end
                    else begin
                        fpsr[31:27] <= fpsr[31:27] | eng_flags;
                        if (cur_cmp) begin                                       // the compare queue (ERS s.7.4.3)
                            fpsr[26] <= eng_cmp; fpsr[21] <= fpsr[26]; fpsr[20:11] <= fpsr[21:12];
                        end
                    end
                end
                S_FMA_MPY: if (eng_done) begin                                   // then read ra/ta for the add
                    fma_res1 <= eng_result; fma_we1 <= eng_we; fma_unimpl <= eng_unimpl; fma_flags <= eng_flags;
                    st <= S_FMA_RD;
                end
                S_FMA_RD: st <= S_FMA_ADD;
                S_FMA_ADD: if (eng_done) begin
                    if (eng_unimpl || fma_unimpl) begin                          // neither result, no flag
                        fpsr[6] <= 1'b1; xr[1] <= {cur_code, cur_insn[25:0]};
                        st <= S_IDLE;
                    end else begin
                        fpsr[31:27] <= fpsr[31:27] | eng_flags | fma_flags;
                        st <= S_FMA_WR;
                    end
                end
                S_FMA_WR: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
