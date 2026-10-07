// PA-7100LC pipelined core: the D, E, M and W stages (docs/design/cpu.md 6).
//
//   D  decode (pa_decode) to a control word, GR read with the W-stage
//      write-through bypass, PC-relative branch target, static prediction
//      (backward conditional branches, BL and GATE are predicted taken, never
//      in the delay slot of a branch -- ERS s.5.3.7), the load-use interlock
//      on instruction fields 6:10 / 11:15 (ERS s.5.3.9), the interlock behind
//      MTCTL/MTSP until they commit, and the forwarding selects for E.
//   E  operand forwarding from M and W, ALU / shifter / MAX-1 / AGU, branch
//      resolution and redirect, nullify-next, the group-3 traps an
//      instruction raises by itself (illegal, privileged, overflow, ...).
//   M  the cache / TLB stage: here only the space-register read for the
//      data access (the caches and the TLB arrive with STUBS S-005).
//   W  commit: GR writes (two ports), PSW / CR / SR / DR updates, the
//      uncached data access (issued from W, non-speculative, in order), the
//      interruption priority select and entry sequence, replay / flush.
//
// Every instruction carries (iaoq_f, iaoq_b, iasq_f, iasq_b) from fetch to W;
// IIAOQ on an interruption is exactly that pair. The committed PSW is
// written only in W, so PSW.N / PSW.B as seen by the instruction in W are
// its own "nullified" and "after a taken branch" flags (cpu.md 6.2).
//
// Pipeline costs (cpu-timing.md): predicted-taken branch 1 bubble,
// mispredicted or GR-based branch 2, load-use 1, MTCTL/MTSP up to 3,
// serialising instructions (RFI, SSM/RSM/MTSM, DIAG, TLB/cache ops) and
// interruptions flush the pipeline (5 bubbles), uncached loads stall W.
module pa_core
    import pa_pkg::*;
#(
    parameter logic [5:0] CPU_REVISION = 6'd0       // DR0 bits 0:5 (cpu-requests #2)
) (
    input  logic        clk,
    input  logic        rst_n,

    // from / to pa_fetch
    input  logic        f2_valid,
    input  logic [31:0] f2_insn,
    input  logic [31:0] f2_iaoq_f, f2_iaoq_b,
    input  logic [15:0] f2_iasq_f, f2_iasq_b,
    input  logic        f2_err,
    output logic        adv_f2,
    output logic        drained,
    output logic        uib_inval,
    output logic        redir,
    output logic        redir_kill_all,
    output logic [31:0] redir_target, redir_back,
    output logic [15:0] redir_space, redir_back_space,
    output logic        redir_new_space,
    output logic [31:0] redir_slot,

    // BIU data port
    output logic        d_req, d_we,
    output logic [31:0] d_addr,
    output logic [7:0]  d_be,
    output logic [63:0] d_wdata,
    output logic        d_rclr,
    input  logic        d_ack, d_err,
    input  logic [63:0] d_rdata,
    input  logic        sb_empty,
    input  logic        sb_err,

    // interrupts and configuration
    input  logic        eir_set,
    input  logic [4:0]  eir_num,
    input  logic        toc_req,
    input  logic        hpmc_req,
    input  logic        lpmc_req,
    input  logic        powerfail,
    input  logic        soft_pwr_n,     // DR25 bit 0: 1 = button not pressed
    input  logic [15:0] cfg_tq, cfg_tr, cfg_td,

    // debug taps
    output logic        dbg_retire,
    output logic        dbg_nullified,
    output logic [31:0] dbg_iaoq_f, dbg_iaoq_b,
    output logic [15:0] dbg_iasq_f,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec,
    output logic [1:0]  dbg_gr_we,
    output logic [4:0]  dbg_gr_num0, dbg_gr_num1,
    output logic [31:0] dbg_gr_data0, dbg_gr_data1,
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic [31:0] dbg_gr [32]
);
    // ================================================================ architectural state
    logic [15:0] sr [8];
    logic [31:0] psw;
    logic [31:0] rctr, iva, eiem, eirr, iir, ior, ipsw;
    logic [31:0] pid [4];
    logic [7:0]  ccr;
    logic [4:0]  sar;
    logic [15:0] iiasq_f, iiasq_b, isr;
    logic [31:0] iiaoq_f, iiaoq_b;
    logic [31:0] tr [8];
    logic [31:0] dr0, dr8, dr24, dr25, dr26, dr27, dr28, dr29;
    logic        toc_mask, toc_pend, hpmc_pend;
    logic [31:0] cr16_cnt;
    logic        cr16_match;

    localparam int P_E = 26, P_S = 25, P_T = 24, P_H = 23, P_L = 22, P_N = 21, P_X = 20,
                   P_B = 19, P_C = 18, P_V = 17, P_M = 16, P_R = 4, P_Q = 3, P_P = 2,
                   P_D = 1, P_I = 0;

    pa_cr16 u_cr16 (.clk(clk), .rst_n(rst_n), .tq(cfg_tq), .tr(cfg_tr), .td(cfg_td),
                    .wr_counter(cr16_wr_cnt), .wr_compare(cr16_wr_cmp), .wdata(w_result),
                    .counter(cr16_cnt), .match(cr16_match));

    // ================================================================ pipeline registers
    // ---- D
    logic        d_valid, d_ferr;
    logic [31:0] d_insn, d_iaoq_f, d_iaoq_b;
    logic [15:0] d_iasq_f, d_iasq_b;
    // ---- E
    logic        e_valid, e_nul, e_err, e_pred, e_bflag;
    logic [31:0] e_insn, e_iaoq_f, e_iaoq_b, e_gra, e_grb, e_target;
    logic [15:0] e_iasq_f, e_iasq_b;
    ctrl_t       e_c;
    logic [2:0]  e_fa_sel, e_fb_sel;      // 0 reg, 1 M port0, 2 M port1, 3 W port0, 4 W port1
    logic [1:0]  e_cb_sel, e_v_sel, e_sar_sel;  // 0 PSW/reg, 1 M, 2 W
    // ---- M
    logic        m_valid, m_nul, m_err, m_taken, m_nullify, m_new_space;
    logic [31:0] m_insn, m_iaoq_f, m_iaoq_b, m_result, m_base, m_ea, m_target;
    logic [15:0] m_iasq_f, m_iasq_b;
    logic [5:0]  m_trap;
    logic        m_trap_data;
    logic [7:0]  m_cb;
    logic        m_v;
    logic [1:0]  m_spsel;
    logic [3:0]  m_be;
    logic [31:0] m_stdata;
    ctrl_t       m_c;
    // ---- W
    logic        w_valid, w_nul, w_err, w_taken, w_nullify, w_new_space;
    logic [31:0] w_insn, w_iaoq_f, w_iaoq_b, w_result, w_base, w_ea, w_target;
    logic [15:0] w_iasq_f, w_iasq_b, w_space;
    logic [5:0]  w_trap;
    logic        w_trap_data;
    logic [7:0]  w_cb;
    logic        w_v;
    logic [3:0]  w_be;
    logic [31:0] w_stdata;
    ctrl_t       w_c;
    logic [31:0] w_ld;
    logic        w_lderr;

    // nullify / taken-branch state for instructions entering E
    logic        pending_nul, prev_taken;
    // group 4 trap armed for the next instruction
    logic        g4_pend;
    logic [5:0]  g4_vec;

    // ================================================================ W-stage control (declared early)
    typedef enum logic [1:0] { W_RUN, W_WAIT, W_DONE } wst_e;
    wst_e        wst;
    logic        w_hold, w_commit, w_redir, w_trap_take;
    logic        we0, we1;
    logic [4:0]  wa0, wa1;
    logic [31:0] wd0, wd1;

    // global advance: nothing moves while W holds
    wire adv = !w_hold;

    // ================================================================ D stage
    ctrl_t dc;
    pa_decode u_dec (.insn(d_insn), .c(dc));

    logic [31:0] rd0, rd1, gra_d, grb_d;
    pa_regfile u_rf (
        .clk(clk), .rst_n(rst_n), .ra0(dc.ra), .ra1(dc.rb), .rd0(rd0), .rd1(rd1),
        .we0(we0), .we1(we1), .wa0(wa0), .wa1(wa1), .wd0(wd0), .wd1(wd1),
        .shr_capture(shr_capture), .shr_restore(shr_restore), .dbg_gr(dbg_gr));
    logic shr_capture, shr_restore;

    // W write-through bypass (port 0 wins)
    always_comb begin
        gra_d = rd0; grb_d = rd1;
        if (dc.ra != 0) begin
            if (we0 && wa0 == dc.ra) gra_d = wd0;
            else if (we1 && wa1 == dc.ra) gra_d = wd1;
        end
        if (dc.rb != 0) begin
            if (we0 && wa0 == dc.rb) grb_d = wd0;
            else if (we1 && wa1 == dc.rb) grb_d = wd1;
        end
    end

    // interlocks
    wire [4:0] d_f6_10  = d_insn[25:21];
    wire [4:0] d_f11_15 = d_insn[20:16];
    wire e_late = e_c.fu == FU_LOAD || (e_c.fu == FU_SYS && e_c.sysop == SYS_LDSID);
    wire ld_use = e_valid && !e_nul && e_late && e_c.rt != 0 &&
                  (e_c.rt == d_f6_10 || e_c.rt == d_f11_15);
    function automatic logic ser_stall(input ctrl_t c);
        ser_stall = (c.fu == FU_SYS) && (c.sysop == SYS_MTSP || (c.sysop == SYS_MTCTL && c.cr != 5'd11));
    endfunction
    wire ser_pending = (e_valid && ser_stall(e_c)) || (m_valid && ser_stall(m_c)) || (w_valid && ser_stall(w_c));
    wire d_stall = d_valid && (ld_use || ser_pending);
    wire adv_d = adv && !d_stall;              // D -> E this cycle
    assign adv_f2 = adv_d;                     // F2 -> D (also when D is empty)

    // forwarding selects for the instruction entering E (what will be in M / W then)
    function automatic logic [2:0] fsel(input logic [4:0] r);
        fsel = 3'd0;
        if (r != 0) begin
            if (e_valid && !e_nul && e_c.rt_we && e_c.rt == r)              fsel = 3'd1;
            else if (e_valid && !e_nul && e_c.base_we && e_c.rb == r)       fsel = 3'd2;
            else if (m_valid && !m_nul && m_c.rt_we && m_c.rt == r)         fsel = 3'd3;
            else if (m_valid && !m_nul && m_c.base_we && m_c.rb == r)       fsel = 3'd4;
        end
    endfunction
    wire e_mtsar = e_c.fu == FU_SYS && e_c.sysop == SYS_MTCTL && e_c.cr == 5'd11;
    wire m_mtsar = m_c.fu == FU_SYS && m_c.sysop == SYS_MTCTL && m_c.cr == 5'd11;
    wire [1:0] d_cb_sel  = (e_valid && !e_nul && e_c.cb_we) ? 2'd1 : (m_valid && !m_nul && m_c.cb_we) ? 2'd2 : 2'd0;
    wire [1:0] d_v_sel   = (e_valid && !e_nul && e_c.ds)    ? 2'd1 : (m_valid && !m_nul && m_c.ds)    ? 2'd2 : 2'd0;
    wire [1:0] d_sar_sel = (e_valid && !e_nul && e_mtsar)   ? 2'd1 : (m_valid && !m_nul && m_mtsar)   ? 2'd2 : 2'd0;

    // static prediction
    wire e_is_branch = e_valid && e_c.fu == FU_BRANCH;
    wire [31:0] d_target_pc = d_iaoq_f + 32'd8 + dc.disp;
    wire [31:0] d_target = (dc.br == BR_GATE) ? {d_target_pc[31:2], 2'b00} : d_target_pc;   // GATE: PL 0 (C = 0)
    wire d_pred = d_valid && dc.fu == FU_BRANCH && !dc.illegal && !e_is_branch &&
                  ((dc.br == BR_COND && dc.disp[31]) || dc.br == BR_BL || dc.br == BR_GATE);
    wire d_redir = d_pred && adv_d;

    // ================================================================ E stage
    // operands
    logic [31:0] fa, fb, opa;
    always_comb begin
        case (e_fa_sel)
            3'd1: fa = m_result; 3'd2: fa = m_base; 3'd3: fa = wd0; 3'd4: fa = wd1;
            default: fa = e_gra;
        endcase
        case (e_fb_sel)
            3'd1: fb = m_result; 3'd2: fb = m_base; 3'd3: fb = wd0; 3'd4: fb = wd1;
            default: fb = e_grb;
        endcase
        opa = e_c.a_imm ? e_c.imm : fa;
    end
    wire [7:0] cb_in  = (e_cb_sel == 2'd1) ? m_cb : (e_cb_sel == 2'd2) ? w_cb : psw[15:8];
    wire       v_in   = (e_v_sel == 2'd1)  ? m_v  : (e_v_sel == 2'd2)  ? w_v  : psw[P_V];
    wire [4:0] sar_in = (e_sar_sel == 2'd1) ? m_result[4:0] : (e_sar_sel == 2'd2) ? w_result[4:0] : sar;
    wire [1:0] cur_pl = e_iaoq_f[1:0];

    // ---- ALU
    logic [31:0] alu_res;
    logic [7:0]  alu_cb;
    logic        alu_cond, alu_sv, alu_uv, alu_v;
    pa_alu u_alu (
        .a(opa), .b(fb), .cb_in(cb_in), .a_shift(e_c.a_shift), .logic_op(e_c.logic_op),
        .lop(e_c.lop), .inv_b(e_c.inv_b), .cin_sel(e_c.cin_sel), .dcor(e_c.dcor), .ds(e_c.ds),
        .psw_v(v_in), .cond_class(e_c.cond_class), .cond_c(e_c.cond_c), .cond_f(e_c.cond_f),
        .result(alu_res), .cb_out(alu_cb), .cond_sat(alu_cond), .sv(alu_sv), .uv(alu_uv),
        .v_out(alu_v));

    // ---- shifter
    logic [31:0] sh_res;
    logic        sh_cond;
    wire [4:0] sh_amount = e_c.sh_sar ? sar_in : e_c.sh_amount;
    pa_shift u_sh (
        .r1(fa), .r2(fb), .t_old(fb), .imm5(e_c.sh_imm5), .op(e_c.sh_op), .sign(e_c.sh_sign),
        .zero_fill(e_c.sh_zero), .use_imm(e_c.sh_imm), .amount(sh_amount), .len(e_c.sh_len),
        .cond_c(e_c.cond_c), .result(sh_res), .cond_sat(sh_cond));

    // ---- MAX-1
    logic [31:0] mx_res;
    pa_max1 u_mx (.a(fa), .b(fb), .op(e_c.mx_op), .sat(e_c.mx_sat), .sa(e_c.mx_sa), .result(mx_res));

    // ---- AGU and store formatting
    logic [31:0] ls_ea, ls_new_base, ls_wd, ls_ld_unused;
    logic        ls_unaligned;
    logic [3:0]  ls_be;
    pa_ldst u_ls (
        .base(fb), .index(fa), .disp(e_c.imm), .use_index(e_c.use_index), .scale(e_c.scale),
        .ea_is_base(e_c.ea_is_base), .base_trunc(e_c.base_trunc), .size(e_c.size),
        .ea(ls_ea), .new_base(ls_new_base), .unaligned(ls_unaligned),
        .stbys(e_c.stbys), .st_src(fa), .st_be(ls_be), .st_data(ls_wd),
        .ld_word(32'd0), .ld_data(ls_ld_unused));

    // ---- branches
    logic        br_taken, br_new_space, movb_cond, bit_val;
    logic [31:0] br_target;
    wire [31:0] e_seq = e_iaoq_b + 32'd4;           // link value, and the not-taken resume address
    always_comb begin
        case (e_c.cond_c)
            3'd0: movb_cond = 1'b0;
            3'd1: movb_cond = (opa == 0);
            3'd2: movb_cond = opa[31];
            3'd3: movb_cond = opa[0];
            3'd4: movb_cond = 1'b1;
            3'd5: movb_cond = (opa != 0);
            3'd6: movb_cond = ~opa[31];
            default: movb_cond = ~opa[0];
        endcase
        bit_val = fa[5'd31 - sh_amount];
        br_new_space = 1'b0;
        br_target    = e_target;
        br_taken     = 1'b1;
        case (e_c.br)
            BR_COND: case (e_c.brcond)
                BC_ALU:   br_taken = alu_cond;
                BC_SHIFT: br_taken = movb_cond;
                default:  br_taken = e_c.cond_f ? ~bit_val : bit_val;
            endcase
            BR_BL:   ;
            BR_GATE: br_target = {e_target[31:2], 2'b00};              // C = 0: PL 0
            BR_BLR:  br_target = e_iaoq_f + 32'd8 + {fa[28:0], 3'b000};
            BR_BV: begin
                br_target = fb + {fa[28:0], 3'b000};
                if (br_target[1:0] < cur_pl) br_target[1:0] = cur_pl;
            end
            default: begin                                               // BE / BLE
                br_target = fb + e_c.disp;
                if (br_target[1:0] < cur_pl) br_target[1:0] = cur_pl;
                br_new_space = 1'b1;
            end
        endcase
    end
    wire br_back = e_c.disp[31];
    wire e_taken = e_is_branch && !e_nul && br_taken;
    wire br_nullify = (e_c.br == BR_COND) ? (e_c.nul & (br_taken ^ br_back)) : e_c.nul;

    // ---- nullify next
    logic e_nullify;
    always_comb begin
        e_nullify = 1'b0;
        if (e_valid && !e_nul) case (e_c.fu)
            FU_ALU:    e_nullify = e_c.nullify_cond & alu_cond;
            FU_SHIFT:  e_nullify = sh_cond;
            FU_BRANCH: e_nullify = br_nullify;
            default: ;
        endcase
    end

    // ---- control register read
    function automatic logic cr_priv_read(input logic [4:0] n, input logic s_bit);
        case (n)
            5'd11:        cr_priv_read = 1'b0;
            5'd26, 5'd27: cr_priv_read = 1'b0;
            5'd16:        cr_priv_read = s_bit;
            default:      cr_priv_read = 1'b1;
        endcase
    endfunction
    logic [31:0] cr_rd, dr_rd;
    always_comb begin
        case (e_c.cr)
            5'd0:  cr_rd = rctr;
            5'd8:  cr_rd = {16'd0, pid[0][15:0]};
            5'd9:  cr_rd = {16'd0, pid[1][15:0]};
            5'd10: cr_rd = {24'd0, ccr};
            5'd11: cr_rd = {27'd0, sar_in};
            5'd12: cr_rd = {16'd0, pid[2][15:0]};
            5'd13: cr_rd = {16'd0, pid[3][15:0]};
            5'd14: cr_rd = iva;
            5'd15: cr_rd = eiem;
            5'd16: cr_rd = cr16_cnt;
            5'd17: cr_rd = {16'd0, iiasq_f};
            5'd18: cr_rd = iiaoq_f;
            5'd19: cr_rd = iir;
            5'd20: cr_rd = {16'd0, isr};
            5'd21: cr_rd = ior;
            5'd22: cr_rd = ipsw;
            5'd23: cr_rd = eirr;
            5'd24, 5'd25, 5'd26, 5'd27, 5'd28, 5'd29, 5'd30, 5'd31: cr_rd = tr[e_c.cr[2:0]];
            default: cr_rd = 32'd0;
        endcase
        case (e_c.cr)
            5'd0:  dr_rd = dr0;
            5'd8:  dr_rd = dr8;
            5'd24: dr_rd = dr24;
            5'd25: dr_rd = dr25;
            5'd26: dr_rd = dr26;
            5'd27: dr_rd = dr27;
            5'd28: dr_rd = dr28;
            5'd29: dr_rd = dr29;
            default: dr_rd = 32'd0;
        endcase
    end

    // ---- result mux (what reaches W's write port 0 for non-load instructions)
    logic [31:0] e_result;
    always_comb begin
        e_result = alu_res;
        case (e_c.fu)
            FU_ALU:    e_result = e_c.clr_result ? 32'd0 : alu_res;
            FU_SHIFT:  e_result = sh_res;
            FU_MAX1:   e_result = mx_res;
            FU_BRANCH: begin
                if (e_c.link) e_result = (e_c.br == BR_GATE) ? {e_seq[31:2], cur_pl} : e_seq;
                else if (e_c.brcond == BC_SHIFT) e_result = opa;        // MOVB / MOVIB
                else e_result = alu_res;                                 // ADDB / ADDIB
            end
            FU_SYS: case (e_c.sysop)
                SYS_MFSP:  e_result = {16'd0, sr[e_c.sr]};
                SYS_MFCTL: e_result = cr_rd;
                default:   e_result = fa;                                // MTCTL/MTSP/MTSM source
            endcase
            FU_DIAG: e_result = (e_c.sysop == DG_MFCPU) ? dr_rd : fa;
            default: ;
        endcase
    end

    // ---- traps raised in E (group 3, in ACD priority order)
    logic [5:0] e_trap;
    logic       e_trap_data;
    always_comb begin
        e_trap = TRAP_NONE;
        e_trap_data = 1'b0;
        if (e_err) e_trap = TRAP_HPMC;
        else if (e_c.fu == FU_DIAG && cur_pl != 2'd0)          // DIAG: privilege before the encoding check
            e_trap = TRAP_PRIV_OP;
        else if (e_c.illegal || (e_c.fu == FU_BRANCH && e_c.br == BR_GATE && e_bflag))
            e_trap = TRAP_ILLEGAL;
        else if (e_c.priv && cur_pl != 2'd0)
            e_trap = TRAP_PRIV_OP;
        else if (e_c.assist || e_c.fu == FU_FP)
            e_trap = TRAP_ASSIST_EM;
        else case (e_c.fu)
            FU_ALU: begin
                if (e_c.trap_ovf && alu_sv)        e_trap = TRAP_OVERFLOW;
                else if (e_c.trap_cond && alu_cond) e_trap = TRAP_COND;
            end
            FU_SYS: case (e_c.sysop)
                SYS_BREAK: e_trap = TRAP_BREAK;
                SYS_MTSP:  if (e_c.sr[2] && e_c.sr[1:0] != 2'b00 && cur_pl != 0) e_trap = TRAP_PRIV_REG;
                SYS_MTCTL: if (e_c.cr != 5'd11 && cur_pl != 0)                 e_trap = TRAP_PRIV_REG;
                SYS_MFCTL: if (cr_priv_read(e_c.cr, psw[P_S]) && cur_pl != 0)  e_trap = TRAP_PRIV_REG;
                default: ;
            endcase
            FU_LOAD, FU_STORE: if (ls_unaligned) begin e_trap = TRAP_UNALIGNED; e_trap_data = 1'b1; end
            default: ;
        endcase
    end

    // ---- E redirect: resolve against the prediction
    wire e_mispred = e_is_branch && (e_taken != e_pred);
    wire e_redir = adv && e_mispred;
    assign redir          = e_redir || d_redir;
    assign redir_new_space = e_redir && e_taken && br_new_space;
    assign redir_slot     = e_redir ? e_iaoq_b : d_iaoq_b;

    // ================================================================ M stage
    wire [15:0] m_space = (m_c.s2 != 0) ? sr[m_c.s2] : sr[{1'b1, m_spsel}];
    wire [31:0] m_result2 = (m_c.fu == FU_SYS && m_c.sysop == SYS_LDSID) ? {16'd0, m_space} : m_result;

    // ================================================================ W stage
    wire [1:0] w_pl = w_iaoq_f[1:0];
    wire w_is_mem   = w_c.fu == FU_LOAD || w_c.fu == FU_STORE;
    wire w_is_load  = w_c.fu == FU_LOAD;
    wire w_is_sync  = w_c.fu == FU_SYS && w_c.sysop == SYS_SYNC;
    wire w_is_rfi   = w_c.fu == FU_SYS && (w_c.sysop == SYS_RFI || w_c.sysop == SYS_RFIR);
    wire w_flush    = (w_c.fu == FU_SYS && (w_c.sysop == SYS_RFI || w_c.sysop == SYS_RFIR ||
                       w_c.sysop == SYS_SSM || w_c.sysop == SYS_RSM || w_c.sysop == SYS_MTSM)) ||
                      w_c.fu == FU_DIAG || w_c.fu == FU_MMU;
    wire w_exec = w_valid && !w_nul;

    // ---- interruption select at the first W cycle
    logic [5:0] w_vec;
    logic       w_before;                 // taken before the instruction (groups 1, 2, 4)
    wire take_ext = psw[P_I] && ((eirr & eiem) != 0);
    wire take_lpmc = psw[P_I] && lpmc_req;
    wire take_rctr = psw[P_R] && rctr[31];
    always_comb begin
        w_vec = TRAP_NONE; w_before = 1'b1;
        if (g4_pend)                                    w_vec = g4_vec;
        else if (!psw[P_M] && (hpmc_req || hpmc_pend))  w_vec = TRAP_HPMC;
        else if (toc_pend && !toc_mask)                 w_vec = TRAP_TOC;
        else if (take_rctr)                             w_vec = TRAP_RCTR;
        else if (take_ext)                              w_vec = TRAP_EXT;
        else if (take_lpmc)                             w_vec = TRAP_LPMC;
        else if (!w_nul && w_trap != TRAP_NONE && !(w_trap == TRAP_HPMC && psw[P_M])) begin
            w_vec = w_trap; w_before = 1'b0;
        end
    end
    wire w_run_trap = w_valid && wst == W_RUN && w_vec != TRAP_NONE;
    wire w_ld_trap  = w_valid && wst == W_DONE && w_lderr && !psw[P_M];
    assign w_trap_take = w_run_trap || w_ld_trap;

    // ---- data access from W
    wire w_mem_go = w_exec && w_is_mem && wst == W_RUN && !w_run_trap;
    always_comb begin
        d_req = 1'b0; d_we = 1'b0; d_rclr = 1'b0;
        d_addr = w_ea; d_be = 8'd0; d_wdata = {w_stdata, w_stdata};
        if (w_c.fu == FU_STORE) d_be = w_ea[2] ? {4'b0000, w_be} : {w_be, 4'b0000};
        else                    d_be = w_ea[2] ? 8'h0F : 8'hF0;
        if (w_mem_go) begin
            d_req = 1'b1; d_we = (w_c.fu == FU_STORE); d_rclr = w_c.ldcw;
        end else if (wst == W_WAIT) begin
            d_req = 1'b1; d_rclr = w_c.ldcw;
        end
    end
    // load data formatting at the ack
    wire [31:0] ld_word = w_ea[2] ? d_rdata[31:0] : d_rdata[63:32];
    logic [31:0] ld_data;
    always_comb case (w_c.size)
        2'd0:    ld_data = {24'd0, ld_word[8 * (3 - w_ea[1:0]) +: 8]};
        2'd1:    ld_data = {16'd0, w_ea[1] ? ld_word[15:0] : ld_word[31:16]};
        default: ld_data = ld_word;
    endcase

    // W holds while an access is in flight or the store buffer is full
    always_comb begin
        w_hold = 1'b0;
        if (w_valid) case (wst)
            W_RUN:  w_hold = (w_mem_go && (w_is_load || !d_ack)) ||
                             (w_exec && w_is_sync && !sb_empty && !w_run_trap);
            W_WAIT: w_hold = 1'b1;
            default: w_hold = 1'b0;
        endcase
    end
    // the instruction leaves W this cycle (commit or trap)
    assign w_commit = w_valid && !w_hold && !w_trap_take;

    // ---- GR write ports
    wire [31:0] w_wd0_val = (wst == W_DONE) ? w_ld :
                            (w_c.fu == FU_SYS && (w_c.sysop == SYS_SSM || w_c.sysop == SYS_RSM)) ? {25'd0, psw[6:0]} :
                            w_result;
    always_comb begin
        we0 = w_commit && !w_nul && w_c.rt_we && w_c.rt != 0;
        we1 = w_commit && !w_nul && w_c.base_we && w_c.rb != 0;
        wa0 = w_c.rt; wd0 = w_wd0_val;
        wa1 = w_c.rb; wd1 = w_base;
    end
    assign shr_restore = w_commit && !w_nul && ((w_c.fu == FU_SYS && w_c.sysop == SYS_RFIR) ||
                                                (w_c.fu == FU_DIAG && w_c.sysop == DG_SHDW_GR));
    assign shr_capture = w_trap_take || (w_commit && !w_nul && w_c.fu == FU_DIAG && w_c.sysop == DG_GR_SHDW);

    // ---- W redirect: trap, RFI, flush
    logic [31:0] psw_next;
    assign w_redir = w_trap_take || (w_commit && !w_nul && w_flush);
    assign redir_kill_all = w_redir;
    wire [31:0] vec_addr = (w_vec == TRAP_HPMC || w_vec == TRAP_TOC) ? 32'hF000_0000 : {iva[31:10], w_vec[4:0], 5'd0};
    always_comb begin
        redir_back = 32'd0;
        if (w_trap_take)      begin redir_back = vec_addr + 32'd4; end
        else if (w_is_rfi)    begin redir_back = iiaoq_b; end
        else                  begin redir_back = w_iaoq_b + 32'd4; end
    end
    // the fetch state after a kill-all redirect: (front, back) and their spaces
    always_comb begin
        if (w_redir) begin
            if (w_trap_take)   begin redir_target = vec_addr; redir_space = 16'd0;    redir_back_space = 16'd0; end
            else if (w_is_rfi) begin redir_target = iiaoq_f;  redir_space = iiasq_f;  redir_back_space = iiasq_b; end
            else               begin redir_target = w_iaoq_b; redir_space = w_iasq_b; redir_back_space = w_iasq_b; end
        end else begin
            redir_target = e_redir ? (e_taken ? br_target : e_seq) : d_target;
            redir_space = sr[e_c.sr];
            redir_back_space = redir_space;
        end
    end
    assign cr16_wr_cmp = w_commit && !w_nul && w_c.fu == FU_SYS  && w_c.sysop == SYS_MTCTL && w_c.cr == 5'd16;
    assign cr16_wr_cnt = w_commit && !w_nul && w_c.fu == FU_DIAG && w_c.sysop == DG_MTCPU  && w_c.cr == 5'd1;
    logic cr16_wr_cmp, cr16_wr_cnt;

    assign drained = !d_valid && !e_valid && !m_valid && !w_valid && sb_empty;
    assign uib_inval = w_commit && w_exec && w_is_sync;

    // ================================================================ sequential logic
    integer i;
    // psw after this cycle's W action (for the nullify / taken state on a redirect)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            d_valid <= 1'b0; e_valid <= 1'b0; m_valid <= 1'b0; w_valid <= 1'b0;
            d_ferr <= 0; d_insn <= 0; d_iaoq_f <= 0; d_iaoq_b <= 0; d_iasq_f <= 0; d_iasq_b <= 0;
            e_nul <= 0; e_err <= 0; e_pred <= 0; e_bflag <= 0; e_insn <= 0; e_iaoq_f <= 0; e_iaoq_b <= 0;
            e_iasq_f <= 0; e_iasq_b <= 0; e_gra <= 0; e_grb <= 0; e_target <= 0; e_c <= '0;
            e_fa_sel <= 0; e_fb_sel <= 0; e_cb_sel <= 0; e_v_sel <= 0; e_sar_sel <= 0;
            m_nul <= 0; m_err <= 0; m_taken <= 0; m_nullify <= 0; m_new_space <= 0; m_insn <= 0;
            m_iaoq_f <= 0; m_iaoq_b <= 0; m_iasq_f <= 0; m_iasq_b <= 0; m_result <= 0; m_base <= 0;
            m_ea <= 0; m_target <= 0; m_trap <= 0; m_trap_data <= 0; m_cb <= 0; m_v <= 0; m_spsel <= 0;
            m_be <= 0; m_stdata <= 0; m_c <= '0;
            w_nul <= 0; w_err <= 0; w_taken <= 0; w_nullify <= 0; w_new_space <= 0; w_insn <= 0;
            w_iaoq_f <= 0; w_iaoq_b <= 0; w_iasq_f <= 0; w_iasq_b <= 0; w_result <= 0; w_base <= 0;
            w_ea <= 0; w_target <= 0; w_trap <= 0; w_trap_data <= 0; w_cb <= 0; w_v <= 0; w_space <= 0;
            w_be <= 0; w_stdata <= 0; w_c <= '0; w_ld <= 0; w_lderr <= 0;
            pending_nul <= 1'b0; prev_taken <= 1'b0;
        end else begin
            // ---- W redirect kills everything younger (and W leaves)
            if (w_redir) begin
                d_valid <= 1'b0; e_valid <= 1'b0; m_valid <= 1'b0; w_valid <= 1'b0;
                pending_nul <= psw_next[P_N];
                prev_taken  <= psw_next[P_B];
            end else begin
                // ---- M -> W, E -> M
                if (adv) begin
                    w_valid <= m_valid; w_nul <= m_nul; w_err <= m_err; w_taken <= m_taken;
                    w_nullify <= m_nullify; w_new_space <= m_new_space; w_insn <= m_insn;
                    w_iaoq_f <= m_iaoq_f; w_iaoq_b <= m_iaoq_b; w_iasq_f <= m_iasq_f; w_iasq_b <= m_iasq_b;
                    w_result <= m_result2; w_base <= m_base; w_ea <= m_ea; w_target <= m_target;
                    w_trap <= m_trap; w_trap_data <= m_trap_data; w_cb <= m_cb; w_v <= m_v;
                    w_space <= m_space; w_be <= m_be; w_stdata <= m_stdata; w_c <= m_c;

                    m_valid <= e_valid; m_nul <= e_nul; m_err <= e_err; m_taken <= e_taken;
                    m_nullify <= e_nullify; m_new_space <= e_taken && br_new_space; m_insn <= e_insn;
                    m_iaoq_f <= e_iaoq_f; m_iaoq_b <= e_iaoq_b; m_iasq_f <= e_iasq_f; m_iasq_b <= e_iasq_b;
                    m_result <= e_result; m_base <= ls_new_base; m_ea <= ls_ea; m_target <= br_target;
                    m_trap <= e_trap; m_trap_data <= e_trap_data; m_cb <= alu_cb; m_v <= alu_v;
                    m_spsel <= fb[31:30]; m_be <= ls_be; m_stdata <= ls_wd; m_c <= e_c;
                    if (e_valid) begin
                        pending_nul <= e_nullify;
                        prev_taken  <= e_taken;
                    end
                end
                // ---- D -> E (or a bubble when D stalls)
                if (adv) begin
                    if (adv_d) begin
                        e_valid <= d_valid;
                        e_nul   <= e_valid ? e_nullify : pending_nul;
                        e_bflag <= e_valid ? e_taken : prev_taken;
                        e_err <= d_ferr; e_insn <= d_insn; e_iaoq_f <= d_iaoq_f;
                        e_iaoq_b <= (e_redir && d_valid) ? redir_target : d_iaoq_b;
                        e_iasq_f <= d_iasq_f;
                        e_iasq_b <= (e_redir && d_valid && redir_new_space) ? redir_space : d_iasq_b;
                        e_gra <= gra_d; e_grb <= grb_d; e_target <= d_target; e_c <= dc;
                        e_pred <= d_pred;
                        e_fa_sel <= fsel(dc.ra); e_fb_sel <= fsel(dc.rb);
                        e_cb_sel <= d_cb_sel; e_v_sel <= d_v_sel; e_sar_sel <= d_sar_sel;
                    end else begin
                        e_valid <= 1'b0;
                        // a stalled delay slot still gets patched
                        if (e_redir && d_valid) begin
                            d_iaoq_b <= redir_target;
                            if (redir_new_space) d_iasq_b <= redir_space;
                        end
                    end
                end
                // ---- F2 -> D
                if (adv_d) begin
                    d_valid <= f2_valid;
                    d_insn <= f2_insn; d_ferr <= f2_err;
                    d_iaoq_f <= f2_iaoq_f; d_iasq_f <= f2_iasq_f;
                    d_iaoq_b <= d_redir ? d_target : f2_iaoq_b;   // the F2 instruction is D's delay slot
                    d_iasq_b <= f2_iasq_b;
                    if (e_redir) begin
                        // E's delay slot: D's instruction if D held one, else the one
                        // entering from F2; anything else is the wrong path
                        if (!d_valid && f2_valid && f2_iaoq_f == redir_slot) begin
                            d_iaoq_b <= redir_target;
                            if (redir_new_space) d_iasq_b <= redir_space;
                        end else
                            d_valid <= 1'b0;
                    end
                end
            end
            // ---- W state and the load data
            if (!w_valid || w_commit || w_trap_take) wst <= W_RUN;
            else if (wst == W_RUN && w_mem_go && w_is_load) wst <= W_WAIT;
            else if (wst == W_WAIT && d_ack) begin wst <= W_DONE; w_ld <= ld_data; w_lderr <= d_err; end
        end
    end

    // the W-stage architectural writes
    task automatic enter_interruption(input logic [5:0] vec);
        logic [31:0] ip;
        ip = psw;
        ip[P_N] = w_nul;
        ipsw <= ip;
        if (psw[P_Q]) begin
            iiaoq_f <= w_iaoq_f; iiaoq_b <= w_iaoq_b;
            iiasq_f <= w_iasq_f; iiasq_b <= w_iasq_b;
            if (!w_before) iir <= w_insn;
            if (!w_before && w_trap_data) begin isr <= w_space; ior <= w_ea; end
        end
        psw <= psw_next;
        if (vec == TRAP_TOC) begin toc_mask <= 1'b1; toc_pend <= 1'b0; end
        if (vec == TRAP_HPMC) hpmc_pend <= 1'b0;
        g4_pend <= 1'b0;
    endtask

    // the PSW after this cycle's commit / trap (also feeds the nullify state)
    always_comb begin
        psw_next = psw;
        if (w_trap_take) begin
            psw_next = 32'd0;
            if (w_vec == TRAP_HPMC) psw_next[P_M] = 1'b1;
            psw_next[P_E] = dr0[31-23];
        end else if (w_commit) begin
            if (w_nul) begin
                psw_next[P_N] = 1'b0; psw_next[P_X] = 1'b0; psw_next[P_B] = 1'b0;
            end else if (w_is_rfi) begin
                psw_next = ipsw;
            end else begin
                psw_next[P_N] = w_nullify;
                psw_next[P_B] = w_taken;
                psw_next[P_X] = 1'b0;
                if (w_c.fu == FU_ALU) begin
                    if (w_c.cb_we) psw_next[15:8] = w_cb;
                    if (w_c.ds) psw_next[P_V] = w_v;
                end
                if (w_c.fu == FU_SYS) case (w_c.sysop)
                    SYS_SSM:  psw_next[6:0] = (psw[6:0] | w_c.sm_imm[6:0]) & 7'b0011111;
                    SYS_RSM:  psw_next[6:0] = psw[6:0] & ~w_c.sm_imm[6:0];
                    SYS_MTSM: psw_next[6:0] = w_result[6:0] & 7'b0011111;
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 8; i++) begin sr[i] <= 16'd0; tr[i] <= 32'd0; end
            for (i = 0; i < 4; i++) pid[i] <= 32'd0;
            psw <= 32'd0; psw[P_M] <= 1'b1;
            rctr <= 0; iva <= 0; eiem <= 0; eirr <= 0; iir <= 0; ior <= 0; ipsw <= 0;
            ccr <= 0; sar <= 0; iiasq_f <= 0; iiasq_b <= 0; isr <= 0; iiaoq_f <= 0; iiaoq_b <= 0;
            dr0 <= {CPU_REVISION, 26'd0} | 32'h0000_0200;
            dr8 <= 32'h0000_2000; dr24 <= 0; dr25 <= 32'h8000_0009; dr26 <= 0; dr27 <= 0; dr28 <= 0; dr29 <= 0;
            toc_mask <= 1'b1; toc_pend <= 1'b0; hpmc_pend <= 1'b0;
            g4_pend <= 1'b0; g4_vec <= 0;
            dbg_retire <= 0; dbg_nullified <= 0; dbg_trap <= 0; dbg_trap_vec <= 0; dbg_iaoq_f <= 0;
            dbg_iaoq_b <= 0; dbg_iasq_f <= 0; dbg_insn <= 0; dbg_halted <= 0;
            dbg_gr_we <= 0; dbg_gr_num0 <= 0; dbg_gr_num1 <= 0; dbg_gr_data0 <= 0; dbg_gr_data1 <= 0;
        end else begin
            dbg_retire <= 1'b0; dbg_nullified <= 1'b0; dbg_trap <= 1'b0; dbg_halted <= 1'b0;
            dbg_gr_we <= {we1, we0}; dbg_gr_num0 <= wa0; dbg_gr_num1 <= wa1;
            dbg_gr_data0 <= wd0; dbg_gr_data1 <= wd1;

            // asynchronous requests
            if (cr16_match) eirr[31] <= 1'b1;
            if (eir_set) eirr[31 - eir_num] <= 1'b1;
            if (toc_req) toc_pend <= 1'b1;
            if (sb_err) hpmc_pend <= 1'b1;
            dr25[31] <= soft_pwr_n;                          // DR25 bit 0 (PA numbering)

            if (w_trap_take) begin
                enter_interruption(w_vec);
                dbg_trap <= 1'b1; dbg_trap_vec <= w_vec;
                dbg_iaoq_f <= w_iaoq_f; dbg_iaoq_b <= w_iaoq_b; dbg_iasq_f <= w_iasq_f; dbg_insn <= w_insn;
            end else if (w_commit) begin
                dbg_retire <= 1'b1; dbg_nullified <= w_nul;
                dbg_iaoq_f <= w_iaoq_f; dbg_iaoq_b <= w_iaoq_b; dbg_iasq_f <= w_iasq_f; dbg_insn <= w_insn;
                psw <= psw_next;
                g4_pend <= 1'b0;
                if (!w_nul) begin
                    if (psw[P_R]) rctr <= rctr - 32'd1;
                    // group 4 traps armed for the next instruction (cpu.md 3.1)
                    if (!w_is_rfi) begin
                        if (w_taken && psw[P_T]) begin g4_pend <= 1'b1; g4_vec <= TRAP_TAKEN_BR; end
                        else if (psw[P_H] && w_iaoq_b[1:0] < w_pl) begin g4_pend <= 1'b1; g4_vec <= TRAP_HPT; end
                        else if (psw[P_L] && w_iaoq_b[1:0] > w_pl) begin g4_pend <= 1'b1; g4_vec <= TRAP_LPT; end
                    end
                    case (w_c.fu)
                        FU_BRANCH: if (w_c.br == BR_BLE) sr[0] <= w_iasq_b;
                        FU_SYS: case (w_c.sysop)
                            SYS_RFI, SYS_RFIR: ;                     // psw_next covers the PSW
                            SYS_MTSP: sr[w_c.sr] <= w_result[15:0];
                            SYS_MTCTL: case (w_c.cr)
                                5'd0:  rctr <= w_result;
                                5'd8:  pid[0] <= w_result;
                                5'd9:  pid[1] <= w_result;
                                5'd10: ccr <= w_result[7:0];
                                5'd11: sar <= w_result[4:0];
                                5'd12: pid[2] <= w_result;
                                5'd13: pid[3] <= w_result;
                                5'd14: iva <= w_result;
                                5'd15: eiem <= w_result;
                                5'd16: ;                                 // cr16_wr_cmp
                                5'd17: begin iiasq_f <= iiasq_b; iiasq_b <= w_result[15:0]; end
                                5'd18: begin iiaoq_f <= iiaoq_b; iiaoq_b <= w_result; end
                                5'd19: iir <= w_result;
                                5'd20: isr <= w_result[15:0];
                                5'd21: ior <= w_result;
                                5'd22: ipsw <= w_result;
                                5'd23: eirr <= (eirr | ({31'd0, cr16_match} << 31) | (eir_set ? (32'h8000_0000 >> eir_num) : 32'd0)) & ~w_result;
                                5'd24, 5'd25, 5'd26, 5'd27, 5'd28, 5'd29, 5'd30, 5'd31: tr[w_c.cr[2:0]] <= w_result;
                                default: ;
                            endcase
                            default: ;
                        endcase
                        FU_DIAG: case (w_c.sysop)
                            DG_MTCPU: case (w_c.cr)
                                // DR0: bits 6, 8, 10, 12:15 (PA) are W1C, 0:5, 19, 30, 31 read-only
                                // read-only 0xFC001003 (rev, FAST_MODE, HIT, PARERR), W1C 0x02AF0000, stored 0x0150EFFC
                                5'd0: dr0 <= (dr0 & 32'hFC00_1003) | (w_result & 32'h0150_EFFC) | (dr0 & 32'h02AF_0000 & ~w_result);
                                5'd1: ;                                  // cr16_wr_cnt
                                5'd8: dr8 <= {16'd0, w_result[15:0]};
                                5'd24: dr24 <= w_result;
                                5'd25: dr25 <= {dr25[31], w_result[30:0]};
                                5'd26: dr26 <= w_result;
                                5'd27: dr27 <= w_result;
                                5'd28: dr28 <= w_result;
                                5'd29: dr29 <= w_result;
                                default: ;
                            endcase
                            DG_TOC_EN:  toc_mask <= 1'b0;
                            DG_TOC_DIS: toc_mask <= 1'b1;
                            default: ;
                        endcase
                        default: ;
                    endcase
                end
            end
        end
    end
    assign dbg_psw = psw;
endmodule
